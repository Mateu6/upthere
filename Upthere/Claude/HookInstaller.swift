import Foundation
import os

nonisolated private let installerLog = Logger(subsystem: "dev.upthere.app", category: "hook-installer")

/// Adds/removes Upthere's entries in `~/.claude/settings.json`.
///
/// The hook command points at a stable copy of the helper in Application
/// Support, so moving or updating the app never breaks Claude Code.
nonisolated enum HookInstaller {
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
        "Stop", "SubagentStop", "PreCompact", "SessionEnd",
    ]
    static let marker = "upthere-hook"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var installedHelperURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/upthere/bin/upthere-hook")
    }

    static var bundledHelperURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "upthere-hook")
    }

    static var command: String { "\"\(installedHelperURL.path)\"" }

    // MARK: Pure transforms (unit tested)

    static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains(where: isOurs) ?? false
        }
    }

    static func installing(into settings: [String: Any], command: String) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if event == "PreToolUse" || event == "PostToolUse" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    static func removing(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let commands = group["hooks"] as? [[String: Any]] else { return group }
                let others = commands.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if others.count == commands.count { return group }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return settings
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains(marker) ?? false
        } ?? false
    }

    // MARK: Disk

    static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    static var isInstalled: Bool {
        (try? isInstalled(in: readSettings())) ?? false
    }

    static func install() throws {
        try copyHelper()
        try write(installing(into: readSettings(), command: command))
        installerLog.info("installed Claude Code hooks")
    }

    static func uninstall() throws {
        try write(removing(from: readSettings()))
        installerLog.info("removed Claude Code hooks")
    }

    /// Keeps the installed helper in sync with the running app's copy.
    static func refreshInstalledHelperIfNeeded() {
        guard FileManager.default.fileExists(atPath: installedHelperURL.path) else { return }
        try? copyHelper()
    }

    private static func copyHelper() throws {
        guard let source = bundledHelperURL else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let dest = installedHelperURL
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.contentsEqual(atPath: source.path, andPath: dest.path) { return }
        let temp = dest.appendingPathExtension("new")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: source, to: temp)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: dest)
        }
    }

    private static func write(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.upthere-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
