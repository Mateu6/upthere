import Foundation

/// "waiting for CI 15m" → label "waiting for CI", countdown 15 min.
/// "review PR" → count-up. Durations need a unit ("20m", "1h30m", "90s",
/// "1h 30m"), or follow "for"/"in" ("tea for 4"), so numbers that belong to
/// the label ("PR 42") stay in the label.
nonisolated enum TimerParser {
    struct Parsed: Equatable, Sendable {
        var label: String
        var duration: TimeInterval?
    }

    static func parse(_ input: String) -> Parsed {
        var words = input.split(whereSeparator: \.isWhitespace).map(String.init)
        var total: TimeInterval = 0
        var found = false

        // Consume duration tokens from the end.
        while let last = words.last, let seconds = seconds(in: last) {
            total += seconds
            found = true
            words.removeLast()
        }
        // A bare number after "for"/"in" means minutes.
        if !found, words.count >= 2, let minutes = Double(words[words.count - 1]),
            ["for", "in"].contains(words[words.count - 2].lowercased()), minutes > 0
        {
            total = minutes * 60
            found = true
            words.removeLast(2)
        } else if found, let connector = words.last?.lowercased(), ["for", "in"].contains(connector), words.count > 1 {
            words.removeLast()  // "tea for 4m" → "tea"
        }

        let label = words.joined(separator: " ")
        guard found, total > 0 else { return Parsed(label: input.trimmingCharacters(in: .whitespaces), duration: nil) }
        return Parsed(label: label.isEmpty ? "Timer" : label, duration: total)
    }

    /// "15m", "1h", "1h30m", "1.5h", "90s", "2min", "45sec".
    static func seconds(in token: String) -> TimeInterval? {
        let token = token.lowercased()
        if let match = token.wholeMatch(of: /(\d+)h(\d+)m?/) {
            return Double(match.1)! * 3600 + Double(match.2)! * 60
        }
        guard let match = token.wholeMatch(of: /(\d+(?:\.\d+)?)(h|hr|hrs|hour|hours|m|min|mins|minute|minutes|s|sec|secs|second|seconds)/),
            let value = Double(match.1)
        else { return nil }
        switch match.2.first {
        case "h": return value * 3600
        case "m": return value * 60
        default: return value
        }
    }

    /// 905 → "15:05", 3725 → "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(abs(seconds).rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Compact form for the collapsed notch: "15m", "1h05", "45s".
    static func compact(_ seconds: TimeInterval) -> String {
        let s = Int(abs(seconds).rounded(.up))
        if s < 60 { return "\(s)s" }
        let minutes = Int((abs(seconds) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }
}
