import AppKit
import EventKit
import os

private nonisolated let calendarLog = Logger(subsystem: "dev.upthere.app", category: "calendar")

/// Writes finished timers to Calendar as events.
final class CalendarLogger {
    private let store = EKEventStore()
    private(set) var lastError: String?

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Calendars that can take new events.
    func calendars() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Creates an "Upthere" calendar next to the default one (iCloud or local).
    func createUpthereCalendar() throws -> EKCalendar {
        if let existing = calendars().first(where: { $0.title == "Upthere" }) { return existing }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Upthere"
        calendar.cgColor = NSColor(srgbRed: 0.35, green: 0.78, blue: 1.0, alpha: 1).cgColor
        calendar.source =
            store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .calDAV || $0.sourceType == .local }
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    func log(_ entry: TimerEntry, calendarID: String?) {
        guard isAuthorized else { return }
        let calendar = calendarID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
        guard let calendar else { return }
        let fields = Self.fields(for: entry)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = fields.title
        event.startDate = fields.start
        event.endDate = fields.end
        event.notes = fields.notes
        do {
            try store.save(event, span: .thisEvent, commit: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            calendarLog.error("couldn't save event: \(error.localizedDescription, privacy: .public)")
        }
    }

    struct Fields: Equatable {
        var title: String
        var start: Date
        var end: Date
        var notes: String
    }

    /// Event fields for an entry (pure, for tests).
    nonisolated static func fields(for entry: TimerEntry) -> Fields {
        var notes: String
        if let countdown = entry.countdown {
            notes = "Countdown \(TimerParser.compact(countdown))"
            let over = entry.activeTime - countdown
            if over >= 60 { notes += " (+\(TimerParser.compact(over)) over)" }
        } else {
            notes = "Count-up"
        }
        let wall = entry.end.timeIntervalSince(entry.start)
        if wall - entry.activeTime >= 60 { notes += " · \(TimerParser.compact(wall - entry.activeTime)) paused" }
        notes += " · logged by Upthere"
        return Fields(title: entry.label, start: entry.start, end: max(entry.end, entry.start.addingTimeInterval(60)), notes: notes)
    }
}
