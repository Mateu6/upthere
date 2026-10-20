import Foundation

/// One of Claude's multiple-choice questions (AskUserQuestion).
nonisolated struct ClaudeQuestion: Sendable, Equatable {
    struct Option: Sendable, Equatable {
        var label: String
        var description: String?
    }

    var question: String
    var header: String?
    var options: [Option]
    var multiSelect: Bool
}

/// Something Claude waits on that the notch can answer. It arrives from
/// `upthere-hook answer`, which holds the hook open until the app replies.
nonisolated struct ClaudeRequest: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case questions([ClaudeQuestion])
        /// ExitPlanMode: the plan's first line, when Claude Code sent it.
        case plan(summary: String?)
        /// `target` is exactly what will run or change: the command for
        /// Bash, the file for edits. `rule` spells out "Always allow".
        case permission(tool: String, target: String?, rule: String?)
    }

    let id: UUID
    let sessionID: String
    let kind: Kind
    let received: Date
    /// The tool's input as sent, echoed back with the answer.
    let toolInput: Data
    /// `permission_suggestions` as sent, for "Always allow".
    let suggestions: Data?

    /// Clicks this soon after the request appears are ignored, so an ear
    /// opening under the pointer can't take a click meant for something else.
    static let wakeDelay: TimeInterval = 0.35

    var isAwake: Bool { Date.now.timeIntervalSince(received) >= Self.wakeDelay }

    static func parse(payload: [String: Any], received: Date = .now) -> ClaudeRequest? {
        guard let sessionID = payload["session_id"] as? String, let event = payload["hook_event_name"] as? String,
            let tool = payload["tool_name"] as? String
        else { return nil }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        guard let inputData = try? JSONSerialization.data(withJSONObject: input) else { return nil }

        let kind: Kind
        var suggestions: Data?
        switch (event, tool) {
        case ("PreToolUse", "AskUserQuestion"):
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap(question)
            guard !questions.isEmpty else { return nil }
            kind = .questions(questions)
        case ("PreToolUse", "ExitPlanMode"):
            let summary = (input["plan"] as? String)?.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#* ")) }
                .first { !$0.isEmpty }
            kind = .plan(summary: summary)
        case ("PermissionRequest", _):
            let raw = payload["permission_suggestions"] as? [[String: Any]]
            if let raw, !raw.isEmpty { suggestions = try? JSONSerialization.data(withJSONObject: raw) }
            kind = .permission(tool: tool, target: target(tool: tool, input: input), rule: rule(raw))
        default:
            return nil
        }
        return ClaudeRequest(
            id: UUID(), sessionID: sessionID, kind: kind, received: received, toolInput: inputData,
            suggestions: suggestions)
    }

    private static func question(_ raw: [String: Any]) -> ClaudeQuestion? {
        guard let text = raw["question"] as? String else { return nil }
        let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> ClaudeQuestion.Option? in
            guard let label = option["label"] as? String, !label.isEmpty else { return nil }
            return ClaudeQuestion.Option(label: label, description: option["description"] as? String)
        }
        guard !options.isEmpty else { return nil }
        return ClaudeQuestion(
            question: text, header: raw["header"] as? String, options: options,
            multiSelect: raw["multiSelect"] as? Bool ?? false)
    }

    /// Exactly what's being allowed: never a paraphrase.
    static func target(tool: String, input: [String: Any]) -> String? {
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        switch tool {
        case "Bash":
            return string("command")?.replacingOccurrences(of: "\n", with: " ⏎ ")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let path = string("file_path") ?? string("notebook_path") else { return nil }
            let url = URL(fileURLWithPath: path)
            return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        case "WebFetch":
            return string("url")
        default:
            return ToolInfo.detail(tool: tool, input: input)
        }
    }

    /// `Bash(npm run lint)` from the first suggested allow rule.
    static func rule(_ suggestions: [[String: Any]]?) -> String? {
        guard let suggestion = suggestions?.first(where: { ($0["behavior"] as? String) != "deny" }),
            let rule = (suggestion["rules"] as? [[String: Any]])?.first,
            let tool = rule["toolName"] as? String
        else { return nil }
        guard let content = (rule["ruleContent"] as? String)?.nilIfEmpty else { return ToolInfo.displayName(tool) }
        return "\(ToolInfo.displayName(tool))(\(content))"
    }
}

/// What you picked in the notch.
nonisolated enum ClaudeAnswer: Sendable, Equatable {
    /// Question text → the labels picked (several for multi-select).
    case options([String: [String]])
    case approvePlan
    case keepPlanning
    case allow
    case allowAlways
    case deny
    case denyAndStop
}

extension ClaudeRequest {
    /// The hook's stdout for `answer`, or nil when it doesn't fit the request.
    func output(for answer: ClaudeAnswer) -> String? {
        let input = (try? JSONSerialization.jsonObject(with: toolInput)) as? [String: Any] ?? [:]
        let specific: [String: Any]
        switch (kind, answer) {
        case (.questions, .options(let picked)):
            var updated = input
            updated["answers"] = picked.mapValues { $0.joined(separator: ", ") }
            specific = ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]
        case (.plan, .approvePlan):
            specific = ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": input]
        case (.plan, .keepPlanning):
            specific = [
                "hookEventName": "PreToolUse", "permissionDecision": "deny",
                "permissionDecisionReason": "The user wants to keep planning. Ask what to change before trying again.",
            ]
        case (.permission, .allow):
            specific = ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]
        case (.permission, .allowAlways):
            var decision: [String: Any] = ["behavior": "allow"]
            if let suggestions, let rules = try? JSONSerialization.jsonObject(with: suggestions) {
                decision["updatedPermissions"] = rules
            }
            specific = ["hookEventName": "PermissionRequest", "decision": decision]
        case (.permission, .deny):
            specific = [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": "The user denied this from the notch."],
            ]
        case (.permission, .denyAndStop):
            specific = [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": "The user denied this and stopped you.", "interrupt": true],
            ]
        default:
            return nil
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["hookSpecificOutput": specific], options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The short confirmation shown after a click.
    func echo(for answer: ClaudeAnswer) -> (text: String, symbol: String) {
        switch answer {
        case .options(let picked):
            let labels = picked.values.flatMap { $0 }
            return (labels.count == 1 ? labels[0] : "\(labels.count) answers sent", "checkmark")
        case .approvePlan: return ("Plan approved", "checkmark")
        case .keepPlanning: return ("Keep planning", "arrow.uturn.backward")
        case .allow: return ("Allowed", "checkmark")
        case .allowAlways: return ("Always allowed", "checkmark")
        case .deny: return ("Denied", "hand.raised.fill")
        case .denyAndStop: return ("Denied and stopped", "stop.fill")
        }
    }
}
