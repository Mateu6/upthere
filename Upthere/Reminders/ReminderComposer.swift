import Foundation

/// The reminder being typed in the field: the text, plus whatever was
/// picked by hand. A picked value wins over what the text says. Pure, so
/// the view only draws it.
nonisolated struct ReminderComposer: Equatable, Sendable {
    enum DueChoice: Equatable, Sendable {
        /// Whatever date the text mentions.
        case fromText
        /// "No date": a date-like phrase stays in the title.
        case none
        case picked(ReminderParser.Due)
    }

    var text = ""
    var listID: String?
    var dueChoice: DueChoice = .fromText
    var priority: ReminderParser.Priority?
    var flagged = false

    struct Resolved: Equatable, Sendable {
        var title: String
        var list: ReminderList?
        var due: ReminderParser.Due?
        var priority: ReminderParser.Priority
        var tags: [String]
        /// The list came from "@name" in the text.
        var listFromText: Bool
        var dueFromText: Bool
    }

    func resolve(lists: [ReminderList], defaultListID: String?) -> Resolved {
        let named = { (query: String) in Self.list(matching: query, in: lists) }
        let parsed = ReminderParser.parse(text, detectDates: dueChoice == .fromText) { named($0) != nil }
        let textList = parsed.listQuery.flatMap(named)
        let list =
            lists.first { $0.id == listID } ?? textList
            ?? lists.first { $0.id == defaultListID } ?? lists.first
        let due: ReminderParser.Due? =
            switch dueChoice {
            case .fromText: parsed.due
            case .none: nil
            case .picked(let due): due
            }
        return Resolved(
            title: parsed.title, list: list, due: due, priority: priority ?? parsed.priority, tags: parsed.tags,
            listFromText: listID == nil && textList != nil, dueFromText: dueChoice == .fromText && parsed.due != nil)
    }

    func draft(lists: [ReminderList], defaultListID: String?) -> ReminderDraft? {
        let r = resolve(lists: lists, defaultListID: defaultListID)
        guard !r.title.isEmpty else { return nil }
        return ReminderDraft(
            title: r.title, listID: r.list?.id, due: r.due, priority: r.priority, tags: r.tags, flagged: flagged)
    }

    /// The list named after "@": exact name first, then a prefix, ignoring
    /// case and spaces ("@shop" → "Shopping list").
    static func list(matching query: String, in lists: [ReminderList]) -> ReminderList? {
        let squash = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
        let q = squash(query)
        guard !q.isEmpty else { return nil }
        return lists.first { squash($0.title) == q } ?? lists.first { squash($0.title).hasPrefix(q) }
    }

    /// The date menu's quick picks, as in Reminders.
    static func quickDates(now: Date = .now) -> [(title: String, due: ReminderParser.Due)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, hour: Int? = nil) -> ReminderParser.Due {
            let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            guard let hour else { return .init(date: date, hasTime: false) }
            return .init(date: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date, hasTime: true)
        }
        var picks: [(String, ReminderParser.Due)] = [(String(localized: "Today"), day(0))]
        if calendar.component(.hour, from: now) < 18 { picks.append((String(localized: "This evening"), day(0, hour: 18))) }
        picks.append((String(localized: "Tomorrow"), day(1)))
        picks.append((String(localized: "Tomorrow morning"), day(1, hour: 9)))
        // Saturday, and next Monday (weekday numbers: Sunday = 1).
        let weekday = calendar.component(.weekday, from: now)
        let toSaturday = (7 - weekday + 7) % 7
        if toSaturday > 1 { picks.append((String(localized: "This weekend"), day(toSaturday))) }
        picks.append((String(localized: "Next week"), day((9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)))
        return picks
    }
}
