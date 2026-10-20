import Foundation

/// Reads a typed reminder: "call mom tomorrow 5pm !! #family @home" →
/// title "call mom", due tomorrow 17:00, medium priority, tag "family",
/// list query "home". Pure, for tests.
nonisolated enum ReminderParser {
    enum Priority: Int, CaseIterable, Sendable {
        case none = 0, low = 9, medium = 5, high = 1

        var marks: String {
            switch self {
            case .none: ""
            case .low: "!"
            case .medium: "!!"
            case .high: "!!!"
            }
        }

        var title: String {
            switch self {
            case .none: "No priority"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }

        /// EventKit's 0–9 scale back to the four levels Reminders shows.
        init(eventKit value: Int) {
            switch value {
            case 1...4: self = .high
            case 5: self = .medium
            case 6...9: self = .low
            default: self = .none
            }
        }
    }

    struct Due: Equatable, Sendable {
        var date: Date
        /// false = all-day (a date with no time).
        var hasTime: Bool
    }

    struct Parsed: Equatable, Sendable {
        var title: String
        var due: Due?
        var priority: Priority = .none
        var tags: [String] = []
        /// What followed "@", to be matched against the list names.
        var listQuery: String?
    }

    /// `isList` decides whether "@word" names a list; when it doesn't, the
    /// word stays in the title (an email, a handle).
    static func parse(_ input: String, detectDates: Bool = true, isList: (String) -> Bool = { _ in true }) -> Parsed {
        var words: [String] = []
        var parsed = Parsed(title: "")
        for word in input.split(whereSeparator: \.isWhitespace).map(String.init) {
            if word.count > 1, word.hasPrefix("#") {
                let tag = word.dropFirst().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                if !tag.isEmpty, !parsed.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                    parsed.tags.append(String(tag))
                }
            } else if word.count > 1, word.hasPrefix("@"), isList(String(word.dropFirst())) {
                parsed.listQuery = String(word.dropFirst())
            } else if let level = ["!": Priority.low, "!!": .medium, "!!!": .high][word] {
                parsed.priority = level
            } else {
                words.append(word)
            }
        }
        var text = words.joined(separator: " ")
        if detectDates, let (due, range) = detectDue(in: text) {
            parsed.due = due
            text.removeSubrange(range)
            // "call mom on" / "pay rent by" read oddly once the date is gone.
            text = text.split(separator: " ").joined(separator: " ")
            for dangling in [" on", " at", " by", " due"] where text.lowercased().hasSuffix(dangling) {
                text.removeLast(dangling.count)
            }
        }
        parsed.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return parsed
    }

    nonisolated(unsafe) private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The first date in the text, and where it was.
    static func detectDue(in text: String) -> (Due, Range<String.Index>)? {
        guard let detector,
            let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let date = match.date, let range = Range(match.range, in: text)
        else { return nil }
        let phrase = text[range].lowercased()
        // The detector puts date-only phrases ("tomorrow") at noon.
        let noon = Calendar.current.dateComponents([.hour, .minute], from: date) == DateComponents(hour: 12, minute: 0)
        let saysTime = phrase.contains(where: \.isNumber) && !isDateOnly(phrase) || phrase.contains("noon")
        return (Due(date: date, hasTime: !noon || saysTime), range)
    }

    /// "oct 24", "24/10", "2026-10-24": numbers that are a date, not a time.
    private static func isDateOnly(_ phrase: String) -> Bool {
        !phrase.contains(":") && !phrase.contains("am") && !phrase.contains("pm")
            && !phrase.contains(" at ") && !phrase.contains("in ")
    }

    /// "Today", "Tomorrow 17:00", "Fri 24 Oct", localised.
    static func describe(_ due: Due, now: Date = .now) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(due.date) {
            day = String(localized: "Today")
        } else if calendar.isDateInTomorrow(due.date) {
            day = String(localized: "Tomorrow")
        } else if calendar.isDateInYesterday(due.date) {
            day = String(localized: "Yesterday")
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: due.date).day,
            (0..<7).contains(days)
        {
            day = due.date.formatted(.dateTime.weekday(.wide))
        } else {
            day = due.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        guard due.hasTime else { return day }
        return "\(day) \(due.date.formatted(date: .omitted, time: .shortened))"
    }
}
