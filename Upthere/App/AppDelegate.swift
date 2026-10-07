import AppKit
import os

nonisolated let log = Logger(subsystem: "dev.upthere.app", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences()
    private(set) lazy var nowPlaying = NowPlayingModel(prefs: prefs)
    private(set) lazy var claude = ClaudeModel()
    private var notch: NotchWindowController?
    private var settings: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        terminateCleanlyOnSignals()

        nowPlaying.start()
        if prefs.claudeEnabled { claude.start() }
        HookInstaller.refreshInstalledHelperIfNeeded()

        notch = NotchWindowController(
            nowPlaying: nowPlaying,
            claude: claude,
            prefs: prefs,
            actions: NotchActions(
                openSettings: { [weak self] in self?.showSettings() },
                quit: { NSApp.terminate(nil) }
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        claude.stop()
    }

    /// `kill`/logout send signals that skip applicationWillTerminate; route
    /// them through a normal terminate so the adapter child is stopped too.
    private func terminateCleanlyOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(prefs: prefs, nowPlaying: nowPlaying, claude: claude)
        }
        settings?.show()
    }
}
