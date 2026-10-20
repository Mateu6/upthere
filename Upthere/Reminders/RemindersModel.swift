import Foundation
import Observation

/// Reminders in Upthere: adding them (the ⌥⌘R field) and the ones pinned to
/// the notch. Pinned reminders stay in sync with Reminders, so one done or
/// deleted elsewhere leaves the notch. Event-driven: EventKit's change
/// notification, plus one wake-up when a pinned reminder turns overdue.
@Observable
final class RemindersModel {
    /// How many pinned reminders the collapsed notch shows by name.
    static let collapsedLimit = 2
    /// Ticking a reminder done waits this long, so a second tick undoes it.
    static let completeDelay: Duration = .seconds(1.6)

    private(set) var pinned: [ReminderItem] = []
    private(set) var lists: [ReminderList] = []
    private(set) var defaultListID: String?
    private(set) var recentTags: [String] = []
    /// Ticked done, waiting out `completeDelay`.
    private(set) var completing: Set<String> = []
    private(set) var isAuthorized = false

    @ObservationIgnored let store: ReminderStore?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pinnedIDs: [String]
    @ObservationIgnored private var completeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var overdueTask: Task<Void, Never>?
    /// Bumped on every change in Reminders, so an open panel can reload.
    private(set) var revision = 0

    init(store: ReminderStore? = nil, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        pinnedIDs = defaults.stringArray(forKey: "pinnedReminders") ?? []
        recentTags = defaults.stringArray(forKey: "reminderRecentTags") ?? []
        store?.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: Reading

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    /// The ones the collapsed notch names: overdue and soonest due first.
    var collapsedReminders: [ReminderItem] {
        let now = Date.now
        let ranked = pinned.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.isOverdue(at: now) != y.isOverdue(at: now) { return x.isOverdue(at: now) }
            switch (x.due?.date, y.due?.date) {
            case let (dx?, dy?) where dx != dy: return dx < dy
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }
        return Array(ranked.prefix(Self.collapsedLimit).map(\.element))
    }

    var hiddenCount: Int { max(0, pinned.count - collapsedReminders.count) }

    func incomplete() async -> [ReminderItem] { await store?.incomplete() ?? [] }

    // MARK: Access

    func requestAccess() async {
        _ = await store?.requestAccess()
        refresh()
    }

    var isDenied: Bool { store?.isDenied ?? false }

    // MARK: Actions

    @discardableResult
    func add(_ draft: ReminderDraft, pin: Bool) throws -> ReminderItem? {
        guard let store else { return nil }
        let item = try store.add(draft)
        rememberTags(draft.tags)
        if pin { self.pin(item) }
        return item
    }

    func togglePin(_ item: ReminderItem) {
        isPinned(item.id) ? unpin(item.id) : pin(item)
    }

    func pin(_ item: ReminderItem) {
        guard !isPinned(item.id) else { return }
        pinnedIDs.append(item.id)
        pinned.append(item)
        saved()
    }

    func unpin(_ id: String) {
        pinnedIDs.removeAll { $0 == id }
        pinned.removeAll { $0.id == id }
        cancelCompletion(id)
        saved()
    }

    /// Ticks a reminder done after a short pause; ticking again undoes it.
    func toggleComplete(_ id: String) {
        if completing.contains(id) { return cancelCompletion(id) }
        completing.insert(id)
        completeTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.completeDelay)
            guard !Task.isCancelled, let self else { return }
            self.completeTasks[id] = nil
            do {
                try self.store?.setCompleted(id, true)
            } catch {
                log.error("couldn't complete reminder: \(error.localizedDescription, privacy: .public)")
            }
            self.completing.remove(id)
            self.pinnedIDs.removeAll { $0 == id }
            self.pinned.removeAll { $0.id == id }
            self.saved()
        }
    }

    private func cancelCompletion(_ id: String) {
        completeTasks.removeValue(forKey: id)?.cancel()
        completing.remove(id)
    }

    // MARK: Syncing

    /// Reloads lists and the pinned reminders from Reminders. A pinned one
    /// that's gone or done elsewhere is unpinned.
    func refresh() {
        guard let store else { return }
        isAuthorized = store.isAuthorized
        guard isAuthorized else { return }
        lists = store.lists()
        defaultListID = store.defaultListID
        var items: [ReminderItem] = []
        for id in pinnedIDs {
            if let item = store.item(id), !item.completed { items.append(item) }
        }
        if items.count != pinnedIDs.count { pinnedIDs = items.map(\.id) }
        pinned = items
        revision += 1
        saved()
    }

    private func rememberTags(_ tags: [String]) {
        for tag in tags.reversed() {
            recentTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
            recentTags.insert(tag, at: 0)
        }
        recentTags = Array(recentTags.prefix(16))
        defaults.set(recentTags, forKey: "reminderRecentTags")
    }

    private func saved() {
        defaults.set(pinnedIDs, forKey: "pinnedReminders")
        armOverdue()
    }

    /// One wake-up for the next pinned reminder to turn overdue, so its
    /// colour changes on time without anything polling.
    private func armOverdue() {
        overdueTask?.cancel()
        let now = Date.now
        guard let next = pinned.compactMap(\.overdueAt).filter({ $0 > now }).min() else { return }
        overdueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.5))
            guard !Task.isCancelled, let self else { return }
            self.pinned = self.pinned  // re-render with the new colour
            self.armOverdue()
        }
    }

    #if DEBUG
    /// Fake pinned reminders for snapshots; never written to Reminders.
    func debugPin(_ items: [ReminderItem]) {
        pinned = items
        armOverdue()
    }
    #endif
}
