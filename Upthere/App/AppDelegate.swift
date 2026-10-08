import AppKit
import os

nonisolated let log = Logger(subsystem: "dev.upthere.app", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences()
    let updater = Updater()
    private(set) lazy var nowPlaying = NowPlayingModel(prefs: prefs)
    private(set) lazy var claude = ClaudeModel()
    private(set) lazy var queue = QueueModel(prefs: prefs)
    private(set) lazy var timers = TimerModel()
    let calendar = CalendarLogger()
    private var hotKey: HotKey?
    private var timerInput: TimerInputController?
    private var notch: NotchWindowController?
    private var settings: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []
    private var visualizerStopTask: Task<Void, Never>?

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }
        terminateCleanlyOnSignals()

        nowPlaying.start()
        if prefs.claudeEnabled { claude.start() }
        HookInstaller.refreshInstalledHelperIfNeeded()
        syncClaudePreferences()
        syncVisualizer()
        setUpTimers()
        updater.start()

        notch = NotchWindowController(
            nowPlaying: nowPlaying,
            claude: claude,
            prefs: prefs,
            queue: queue,
            timers: timers,
            actions: NotchActions(
                openSettings: { [weak self] in self?.showSettings() },
                openTimerInput: { [weak self] in self?.timerInput?.show() },
                checkForUpdates: { [weak self] in self?.updater.checkForUpdates() },
                quit: { NSApp.terminate(nil) }
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioVisualizer.shared.stop()
        nowPlaying.stop()
        claude.stop()
    }

    /// Runs the weekly transcript scan only while it's displayed.
    private func syncClaudePreferences() {
        let (weekly, account) = withObservationTracking {
            (prefs.claudeEnabled && prefs.needsWeeklyTokenScan, prefs.claudeEnabled && prefs.accountUsage)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncClaudePreferences() } }
        }
        claude.weeklyScanEnabled = weekly
        claude.accountUsageEnabled = account
    }

    private func setUpTimers() {
        timerInput = TimerInputController(timers: timers) { [weak self] in self?.notch?.geometry }
        hotKey = HotKey { [weak self] in self?.timerInput?.toggle() }
        syncHotKey()
        timers.onFinish = { [weak self] entry in
            guard let self else { return }
            guard self.prefs.timerKeepShort || entry.activeTime >= 60 else { return }
            if self.prefs.timerCalendar { self.calendar.log(entry, calendarID: self.prefs.timerCalendarID) }
        }
        timers.onAlert = { [weak self] _ in
            if self?.prefs.timerSound == true { NSSound(named: "Glass")?.play() }
        }
    }

    private func syncHotKey() {
        let preset = withObservationTracking { prefs.timerHotKey } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncHotKey() } }
        }
        hotKey?.register(preset)
    }

    /// Taps the player's audio only while music plays with the live
    /// visualizer on and live sound bars are on screen. When the bars go
    /// away (e.g. the ear switches to the cover) the tap stops after a short
    /// grace period, so quick layout swaps don't restart it.
    private func syncVisualizer() {
        let (target, enabled) = withObservationTracking { () -> (String?, Bool) in
            guard prefs.liveVisualizer else { return (nil, false) }
            guard VisualizerViewers.shared.count > 0, let current = nowPlaying.current, current.isPlaying else {
                return (nil, true)
            }
            return (current.parentBundleID ?? current.bundleID, true)
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncVisualizer() } }
        }
        visualizerStopTask?.cancel()
        if !enabled { AudioVisualizer.shared.resetFailures() }
        if target == nil, enabled, AudioVisualizer.shared.runningBundleID != nil {
            visualizerStopTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                AudioVisualizer.shared.run(for: nil)
            }
            return
        }
        AudioVisualizer.shared.run(for: target)
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
            settings = SettingsWindowController(
                prefs: prefs, nowPlaying: nowPlaying, claude: claude, queue: queue, calendar: calendar,
                updater: updater)
        }
        settings?.show()
    }
}
