import Foundation
import Observation

enum PlayerFilterMode: String, CaseIterable, Identifiable {
    case all
    case excludeBrowsers
    case onlySelected

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All players"
        case .excludeBrowsers: "Exclude browsers"
        case .onlySelected: "Only selected apps"
        }
    }
}

enum DisplayChoice: String, CaseIterable, Identifiable {
    case builtIn
    case main

    var id: String { rawValue }
    var title: String {
        switch self {
        case .builtIn: "Built-in display (notch)"
        case .main: "Main display"
        }
    }
}

/// User preferences, persisted to UserDefaults on every change.
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var playerFilter: PlayerFilterMode { didSet { save(playerFilter.rawValue, "playerFilter") } }
    var allowedPlayers: [String] { didSet { save(allowedPlayers, "allowedPlayers") } }
    var pinnedPlayer: String? { didSet { save(pinnedPlayer, "pinnedPlayer") } }
    var seenPlayers: [String] { didSet { save(seenPlayers, "seenPlayers") } }
    var useMediaRemoteAdapter: Bool { didSet { save(useMediaRemoteAdapter, "useMediaRemoteAdapter") } }
    var pausedLingerMinutes: Double { didSet { save(pausedLingerMinutes, "pausedLingerMinutes") } }
    var claudeEnabled: Bool { didSet { save(claudeEnabled, "claudeEnabled") } }
    var maxEarWidth: Double { didSet { save(maxEarWidth, "maxEarWidth") } }
    var display: DisplayChoice { didSet { save(display.rawValue, "display") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playerFilter = PlayerFilterMode(rawValue: defaults.string(forKey: "playerFilter") ?? "") ?? .excludeBrowsers
        allowedPlayers = defaults.stringArray(forKey: "allowedPlayers") ?? []
        pinnedPlayer = defaults.string(forKey: "pinnedPlayer")
        seenPlayers = defaults.stringArray(forKey: "seenPlayers") ?? []
        useMediaRemoteAdapter = defaults.object(forKey: "useMediaRemoteAdapter") as? Bool ?? true
        pausedLingerMinutes = defaults.object(forKey: "pausedLingerMinutes") as? Double ?? 5
        claudeEnabled = defaults.object(forKey: "claudeEnabled") as? Bool ?? true
        maxEarWidth = defaults.object(forKey: "maxEarWidth") as? Double ?? 340
        display = DisplayChoice(rawValue: defaults.string(forKey: "display") ?? "") ?? .builtIn
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Whether media from `bundleID` (optionally hosted by `parent`, e.g. a
    /// web app inside a browser) may be shown and controlled.
    func allowsPlayer(_ bundleID: String, parent: String? = nil) -> Bool {
        if bundleID == pinnedPlayer { return true }
        switch playerFilter {
        case .all:
            return true
        case .excludeBrowsers:
            return !KnownPlayers.isBrowser(bundleID) && !(parent.map(KnownPlayers.isBrowser) ?? false)
        case .onlySelected:
            return allowedPlayers.contains(bundleID)
        }
    }

    func notePlayerSeen(_ bundleID: String) {
        guard !seenPlayers.contains(bundleID) else { return }
        seenPlayers.append(bundleID)
    }
}

nonisolated enum KnownPlayers {
    static let spotify = "com.spotify.client"
    static let music = "com.apple.Music"

    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.kagi.kagimacOS", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.sigmaos.sigmaos.macos",
        "org.torproject.torbrowser", "net.waterfox.waterfox", "ai.perplexity.comet",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        browsers.contains(bundleID) || bundleID.hasPrefix("com.google.Chrome.app.")
            || bundleID.hasPrefix("com.microsoft.edgemac.app.") || bundleID.hasPrefix("com.brave.Browser.app.")
    }
}
