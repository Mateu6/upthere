import AppKit
import EventKit
import os

private nonisolated let remindersLog = Logger(subsystem: "dev.upthere.app", category: "reminders")

/// A Reminders list, with its colour brought into the ears' palette.
nonisolated struct ReminderList: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var title: String
    /// The list's hue; shown at the ears' lightness and chroma (as timers).
    var hue: Double

    var tone: OKLCH { OKLCH(0.80, 0.12, hue) }
}

/// A reminder as the notch and the panel show it: a copy, so nothing holds
/// on to EventKit objects.
nonisolated struct ReminderItem: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var list: ReminderList
    var due: ReminderParser.Due?
    var priority: ReminderParser.Priority
    var completed: Bool

    func isOverdue(at now: Date = .now) -> Bool {
        guard let due, !completed else { return false }
        return due.hasTime ? due.date < now : due.date < Calendar.current.startOfDay(for: now)
    }

    /// When it turns overdue (for the one wake-up that re-colours it).
    var overdueAt: Date? {
        guard let due, !completed else { return nil }
        return due.hasTime ? due.date : Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: due.date))
    }
}

/// What the panel saves.
nonisolated struct ReminderDraft: Equatable, Sendable {
    var title: String
    var listID: String?
    var due: ReminderParser.Due?
    var priority: ReminderParser.Priority = .none
    var tags: [String] = []
    var flagged = false
}

/// Apple's Reminders through EventKit. Asks for access only when the
/// reminder field is first opened; `onChange` fires when anything changes
/// in Reminders (here, in the app, or synced from another device).
final class ReminderStore {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    // MARK: Access

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Asked before and refused: only System Settings can turn it on.
    var isDenied: Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .denied, .restricted, .writeOnly: true
        default: false
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if granted { store.reset() }
        return granted
    }

    // MARK: Reading

    func lists() -> [ReminderList] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).map(Self.list)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var defaultListID: String? { isAuthorized ? store.defaultCalendarForNewReminders()?.calendarIdentifier : nil }

    func item(_ id: String) -> ReminderItem? {
        guard isAuthorized, let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.item(reminder)
    }

    /// Every reminder not yet done, across all lists.
    func incomplete() async -> [ReminderItem] {
        guard isAuthorized else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.item))
            }
        }
    }

    // MARK: Writing

    func add(_ draft: ReminderDraft) throws -> ReminderItem {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.calendar =
            draft.listID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewReminders()
        reminder.priority = draft.priority.rawValue
        if let due = draft.due {
            let fields: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due.date)
            // A time means "remind me then", as in Reminders.
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        // EventKit has no tags: they go in the notes as hashtags, where
        // Reminders' search finds them.
        if !draft.tags.isEmpty { reminder.notes = draft.tags.map { "#\($0)" }.joined(separator: " ") }
        try store.save(reminder, commit: true)
        let item = Self.item(reminder)
        if draft.flagged { Self.flag(item.id) }
        return item
    }

    func setCompleted(_ id: String, _ done: Bool) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = done
        try store.save(reminder, commit: true)
    }

    /// Opens the reminder in Reminders.
    static func reveal(_ id: String) {
        let deepLink = URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")
        if let deepLink, NSWorkspace.shared.open(deepLink) { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    /// Flags aren't in EventKit either; Reminders' own scripting sets them
    /// (asks for Automation access to Reminders the first time).
    private static func flag(_ id: String) {
        Task {
            let script = "tell application \"Reminders\" to set flagged of (reminder id \"x-apple-reminder://\(id)\") to true"
            if await ScriptRunner.run(script) == nil { remindersLog.error("couldn't flag reminder") }
        }
    }

    // MARK: Converting

    nonisolated private static func list(_ calendar: EKCalendar) -> ReminderList {
        let hue = calendar.color.flatMap { OKLCH($0) }?.h ?? 235
        return ReminderList(id: calendar.calendarIdentifier, title: calendar.title, hue: hue)
    }

    nonisolated private static func item(_ reminder: EKReminder) -> ReminderItem {
        var due: ReminderParser.Due?
        if let components = reminder.dueDateComponents, let date = Calendar.current.date(from: components) {
            due = .init(date: date, hasTime: components.hour != nil)
        }
        return ReminderItem(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "", list: list(reminder.calendar),
            due: due, priority: .init(eventKit: reminder.priority), completed: reminder.isCompleted)
    }
}
