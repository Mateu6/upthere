import Foundation

/// What arrives on the socket: a hook event, or a status-line snapshot.
nonisolated enum ClaudeMessage: Sendable {
    case hook(HookEvent)
    case statusLine(StatusLineInfo)

    static func parse(_ data: Data) -> ClaudeMessage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if root["kind"] as? String == "statusline" {
            return (root["payload"] as? [String: Any]).flatMap(StatusLineInfo.init).map { .statusLine($0) }
        }
        return HookEvent.parse(data).map { .hook($0) }
    }
}

/// A rolling plan-limit window (claude.ai Pro/Max): % used and reset time.
nonisolated struct LimitWindow: Sendable, Equatable {
    var usedPercent: Double
    var resetsAt: Date
}

/// Account-wide plan usage, as last reported by any session.
nonisolated struct PlanUsage: Sendable, Equatable {
    /// The 5-hour "session" window.
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var updated: Date

    /// Windows past their reset time are stale (Claude Code drops them too).
    func current(at date: Date = .now) -> PlanUsage {
        PlanUsage(
            fiveHour: fiveHour.flatMap { $0.resetsAt > date ? $0 : nil },
            sevenDay: sevenDay.flatMap { $0.resetsAt > date ? $0 : nil },
            updated: updated)
    }
}

/// The JSON Claude Code sends to status-line commands
/// (https://code.claude.com/docs/en/statusline). Every field is optional.
nonisolated struct StatusLineInfo: Sendable, Equatable {
    var sessionID: String
    var sessionName: String?
    var modelName: String?
    var contextPercent: Double?
    var contextTokens: Int?
    var contextSize: Int?
    var costUSD: Double?
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?

    init?(_ json: [String: Any]) {
        guard let id = json["session_id"] as? String else { return nil }
        sessionID = id
        sessionName = json["session_name"] as? String
        modelName = (json["model"] as? [String: Any])?["display_name"] as? String
        let context = json["context_window"] as? [String: Any]
        contextPercent = (context?["used_percentage"] as? NSNumber)?.doubleValue
        contextTokens = (context?["total_input_tokens"] as? NSNumber)?.intValue
        contextSize = (context?["context_window_size"] as? NSNumber)?.intValue
        costUSD = ((json["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue
        let limits = json["rate_limits"] as? [String: Any]
        fiveHour = Self.window(limits?["five_hour"])
        sevenDay = Self.window(limits?["seven_day"])
    }

    private static func window(_ value: Any?) -> LimitWindow? {
        guard let dict = value as? [String: Any],
            let used = (dict["used_percentage"] as? NSNumber)?.doubleValue,
            let resets = (dict["resets_at"] as? NSNumber)?.doubleValue
        else { return nil }
        return LimitWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
    }
}

nonisolated enum TokenFormat {
    /// 950 → "950", 12_300 → "12.3k", 4_560_000 → "4.6M".
    static func short(_ tokens: Int) -> String {
        let value = Double(tokens)
        switch tokens {
        case ..<1000: return "\(tokens)"
        case ..<100_000: return String(format: "%.1fk", value / 1000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: return "\(tokens / 1000)k"
        case ..<100_000_000: return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        default: return "\(tokens / 1_000_000)M"
        }
    }
}
