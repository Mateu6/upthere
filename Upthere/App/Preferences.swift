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

enum NotchTheme: String, CaseIterable, Identifiable {
    case classic
    case aurora
    case clear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: "Classic (black)"
        case .aurora: "Aurora (artwork-tinted glass)"
        case .clear: "Glass (Liquid Glass)"
        }
    }
}

/// The Glass theme's tint.
enum GlassTint: String, CaseIterable, Identifiable {
    case clear
    case color

    var id: String { rawValue }
    var title: String { self == .clear ? "Clear" : "Album color" }
}

/// How a usage figure is shown.
enum UsageFormat: String, CaseIterable, Identifiable {
    case percent
    case amount

    var id: String { rawValue }
}

/// Which usage figure fills the ring around Claude's icon.
enum UsageRing: String, CaseIterable, Identifiable {
    case none, session, week, context

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .session: "Session limit (5-hour)"
        case .week: "Weekly limit"
        case .context: "Context window"
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
    /// Seconds an ear stays open after the pointer leaves it.
    var earCloseDelay: Double { didSet { save(earCloseDelay, "earCloseDelay") } }
    var display: DisplayChoice { didSet { save(display.rawValue, "display") } }
    var theme: NotchTheme { didSet { save(theme.rawValue, "theme") } }
    var glassTint: GlassTint { didSet { save(glassTint.rawValue, "glassTint") } }
    var clearBlackFade: Bool { didSet { save(clearBlackFade, "clearBlackFade") } }
    /// Briefly open the music ear with title and artist when the track changes.
    var announceTracks: Bool { didSet { save(announceTracks, "announceTracks") } }
    /// Sound bars follow the actual audio (needs audio-capture permission).
    var liveVisualizer: Bool { didSet { save(liveVisualizer, "liveVisualizer") } }
    var scrollToSeek: Bool { didSet { save(scrollToSeek, "scrollToSeek") } }
    var scrollForVolume: Bool { didSet { save(scrollForVolume, "scrollForVolume") } }

    // Claude info: what the agent ear shows.
    var infoSession: Bool { didSet { save(infoSession, "infoSession") } }
    var infoSessionFormat: UsageFormat { didSet { save(infoSessionFormat.rawValue, "infoSessionFormat") } }
    var infoWeek: Bool { didSet { save(infoWeek, "infoWeek") } }
    var infoWeekFormat: UsageFormat { didSet { save(infoWeekFormat.rawValue, "infoWeekFormat") } }
    var infoContext: Bool { didSet { save(infoContext, "infoContext") } }
    var infoContextFormat: UsageFormat { didSet { save(infoContextFormat.rawValue, "infoContextFormat") } }
    var infoCost: Bool { didSet { save(infoCost, "infoCost") } }
    var infoModel: Bool { didSet { save(infoModel, "infoModel") } }
    var infoResetTimes: Bool { didSet { save(infoResetTimes, "infoResetTimes") } }
    var usageRing: UsageRing { didSet { save(usageRing.rawValue, "usageRing") } }

    /// The 7-day local token count is only computed when it's displayed.
    var needsWeeklyTokenScan: Bool { infoWeek && infoWeekFormat == .amount }

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
        earCloseDelay = defaults.object(forKey: "earCloseDelay") as? Double ?? 0.3
        display = DisplayChoice(rawValue: defaults.string(forKey: "display") ?? "") ?? .builtIn
        theme = NotchTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .classic
        glassTint = GlassTint(rawValue: defaults.string(forKey: "glassTint") ?? "") ?? .clear
        clearBlackFade = defaults.object(forKey: "clearBlackFade") as? Bool ?? false
        announceTracks = defaults.object(forKey: "announceTracks") as? Bool ?? true
        liveVisualizer = defaults.object(forKey: "liveVisualizer") as? Bool ?? false
        scrollToSeek = defaults.object(forKey: "scrollToSeek") as? Bool ?? true
        scrollForVolume = defaults.object(forKey: "scrollForVolume") as? Bool ?? true
        infoSession = defaults.object(forKey: "infoSession") as? Bool ?? true
        infoSessionFormat = UsageFormat(rawValue: defaults.string(forKey: "infoSessionFormat") ?? "") ?? .percent
        infoWeek = defaults.object(forKey: "infoWeek") as? Bool ?? true
        infoWeekFormat = UsageFormat(rawValue: defaults.string(forKey: "infoWeekFormat") ?? "") ?? .percent
        infoContext = defaults.object(forKey: "infoContext") as? Bool ?? true
        infoContextFormat = UsageFormat(rawValue: defaults.string(forKey: "infoContextFormat") ?? "") ?? .percent
        infoCost = defaults.object(forKey: "infoCost") as? Bool ?? false
        infoModel = defaults.object(forKey: "infoModel") as? Bool ?? false
        infoResetTimes = defaults.object(forKey: "infoResetTimes") as? Bool ?? true
        usageRing = UsageRing(rawValue: defaults.string(forKey: "usageRing") ?? "") ?? .none
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
