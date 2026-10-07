import Foundation

/// A Claude Code hook invocation, as forwarded by `upthere-hook`.
nonisolated struct HookEvent: Sendable, Equatable {
    enum Kind: String, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case notification = "Notification"
        case stop = "Stop"
        case subagentStop = "SubagentStop"
        case preCompact = "PreCompact"
        case sessionEnd = "SessionEnd"
    }

    var kind: Kind
    var sessionID: String
    var cwd: String?
    var transcriptPath: String?
    var toolName: String?
    var toolDetail: String?
    var message: String?
    var notificationType: String?
    var terminalBundleID: String?
    var terminalProgram: String?

    /// Parses the envelope `{"v":1,"term":…,"bundle":…,"payload":{…}}`.
    /// A bare hook payload (no envelope) is accepted too, for testing.
    static func parse(_ data: Data) -> HookEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = root["payload"] as? [String: Any] ?? root
        guard let name = payload["hook_event_name"] as? String, let kind = Kind(rawValue: name),
            let sessionID = payload["session_id"] as? String
        else { return nil }

        let toolName = payload["tool_name"] as? String
        let toolInput = payload["tool_input"] as? [String: Any]
        return HookEvent(
            kind: kind,
            sessionID: sessionID,
            cwd: payload["cwd"] as? String,
            transcriptPath: payload["transcript_path"] as? String,
            toolName: toolName,
            toolDetail: toolName.flatMap { ToolInfo.detail(tool: $0, input: toolInput ?? [:]) },
            message: payload["message"] as? String,
            notificationType: payload["notification_type"] as? String,
            terminalBundleID: root["bundle"] as? String,
            terminalProgram: root["term"] as? String
        )
    }
}

nonisolated enum ToolInfo {
    /// A short human label for what a tool call is touching.
    static func detail(tool: String, input: [String: Any]) -> String? {
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func fileName(_ key: String) -> String? {
            string(key).map { ($0 as NSString).lastPathComponent }
        }
        let raw: String?
        switch tool {
        case "Bash":
            raw = string("description") ?? string("command")?.components(separatedBy: .newlines).first
        case "Read", "Write", "Edit", "MultiEdit":
            raw = fileName("file_path")
        case "NotebookEdit":
            raw = fileName("notebook_path")
        case "Grep", "Glob":
            raw = string("pattern")
        case "WebFetch":
            raw = string("url").flatMap { URL(string: $0)?.host() }
        case "WebSearch":
            raw = string("query")
        case "Task", "Agent":
            raw = string("description") ?? string("subagent_type")
        default:
            raw = string("description") ?? string("file_path").map { ($0 as NSString).lastPathComponent }
        }
        guard let raw else { return nil }
        return raw.count > 80 ? String(raw.prefix(79)) + "…" : raw
    }

    /// `mcp__github__create_issue` → `github · create issue`.
    static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return tool }
        let server = parts[0].count > 20 ? String(parts[0].prefix(8)) : parts[0]
        return "\(server) · \(parts[1...].joined(separator: " ").replacingOccurrences(of: "_", with: " "))"
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        case _ where tool.hasPrefix("mcp__"): "puzzlepiece.extension"
        default: "wrench.and.screwdriver"
        }
    }
}

extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
