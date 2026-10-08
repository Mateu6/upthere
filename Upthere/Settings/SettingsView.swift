import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    private let window: NSWindow

    init(
        prefs: Preferences, nowPlaying: NowPlayingModel, claude: ClaudeModel, queue: QueueModel,
        calendar: CalendarLogger, updater: Updater
    ) {
        let controller = NSHostingController(
            rootView: SettingsView(
                prefs: prefs, nowPlaying: nowPlaying, claude: claude, queue: queue, calendar: calendar, updater: updater))
        window = NSWindow(contentViewController: controller)
        window.title = "Upthere Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 680))
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var prefs: Preferences
    let nowPlaying: NowPlayingModel
    let claude: ClaudeModel
    let queue: QueueModel
    let calendar: CalendarLogger
    @Bindable var updater: Updater
    @State private var calendars: [(id: String, title: String)] = []
    @State private var calendarAuthorized = false
    @State private var calendarError: String?
    @State private var spotifyConnected = false
    @State private var spotifyBusy = false
    @State private var spotifyError: String?

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hooksInstalled = HookInstaller.isInstalled
    @State private var hookError: String?
    @State private var statusLineInstalled = HookInstaller.isStatusLineInstalled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(NotchTheme.allCases) { Text($0.title).tag($0) }
                }
                if prefs.theme == .clear {
                    Picker("Glass", selection: $prefs.glassTint) {
                        ForEach(GlassTint.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Black gradient (like Aurora)", isOn: $prefs.clearBlackFade)
                }
                Picker("Display", selection: $prefs.display) {
                    ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Center piece without a notch", selection: $prefs.centerPiece) {
                    ForEach(CenterPiece.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("On screens without a notch, what sits in the middle when Claude, music and timers all show")
                LabeledContent("Keep ear open after leaving") {
                    Slider(value: $prefs.earCloseDelay, in: 0...2, step: 0.1)
                        .frame(width: 180)
                    Text(String(format: "%.1f s", prefs.earCloseDelay)).monospacedDigit().frame(width: 50, alignment: .trailing)
                }
                LabeledContent("Max ear width") {
                    Slider(value: $prefs.maxEarWidth, in: 180...480, step: 10)
                        .frame(width: 180)
                    Text("\(Int(prefs.maxEarWidth)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }

            Section {
                Picker("Show media from", selection: $prefs.playerFilter) {
                    ForEach(PlayerFilterMode.allCases) { Text($0.title).tag($0) }
                }
                if prefs.playerFilter == .onlySelected {
                    ForEach(prefs.seenPlayers, id: \.self) { bundleID in
                        Toggle(isOn: allowedBinding(bundleID)) { PlayerLabel(bundleID: bundleID) }
                    }
                    if prefs.seenPlayers.isEmpty {
                        Text("Play something and it will show up here.").foregroundStyle(.secondary)
                    }
                }
                Picker("Pinned player", selection: $prefs.pinnedPlayer) {
                    Text("None").tag(String?.none)
                    ForEach(pinCandidates, id: \.self) { bundleID in
                        PlayerLabel(bundleID: bundleID).tag(Optional(bundleID))
                    }
                }
                LabeledContent("Keep paused music for") {
                    Stepper("\(Int(prefs.pausedLingerMinutes)) min", value: $prefs.pausedLingerMinutes, in: 0...60, step: 1)
                }
                Toggle("Show title and artist when the track changes", isOn: $prefs.announceTracks)
                Toggle("Live visualizer (bars follow the music)", isOn: $prefs.liveVisualizer)
                    .help("Analyzes the player's audio in real time. macOS asks once for permission to capture app audio.")
                Toggle("Scroll sideways on the music ear to seek", isOn: $prefs.scrollToSeek)
                Toggle("Scroll up/down on the music ear for volume", isOn: $prefs.scrollForVolume)
                Toggle("Use MediaRemote adapter (all players)", isOn: $prefs.useMediaRemoteAdapter)
            } header: {
                Text("Now Playing")
            } footer: {
                Text(
                    "The pinned player is always shown and controlled when it has a track loaded, even while a browser plays video. Without the adapter, only Spotify and Music are supported."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Start a timer with", selection: $prefs.timerHotKey) {
                    ForEach(HotKey.Preset.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Add finished timers to Calendar", isOn: $prefs.timerCalendar)
                    .onChange(of: prefs.timerCalendar) { _, on in if on { requestCalendar() } }
                if prefs.timerCalendar {
                    if calendarAuthorized {
                        Picker("Calendar", selection: $prefs.timerCalendarID) {
                            Text("Default calendar").tag(String?.none)
                            ForEach(calendars, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                        }
                        if !calendars.contains(where: { $0.title == "Upthere" }) {
                            Button("Create “Upthere” calendar") { createCalendar() }
                        }
                    } else {
                        Button("Allow Calendar access") { requestCalendar() }
                    }
                    if let calendarError { Text(calendarError).foregroundStyle(.red).font(.caption) }
                }
                Toggle("Keep entries shorter than a minute", isOn: $prefs.timerKeepShort)
                Toggle("Sound when a countdown ends", isOn: $prefs.timerSound)
            } header: {
                Text("Timers")
            } footer: {
                Text(
                    "Type “review PR” to count up, or “waiting for CI 15m” to count down. Up to \(TimerModel.maxTimers) at once; each one becomes its own calendar event when you stop it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { reloadCalendars() }

            Section {
                Toggle("Show upcoming songs (when only music is shown)", isOn: $prefs.showQueue)
                TextField("Spotify Client ID", text: $prefs.spotifyClientID, prompt: Text("from developer.spotify.com"))
                    .disableAutocorrection(true)
                LabeledContent("Spotify") {
                    if spotifyConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") {
                            queue.disconnectSpotify()
                            spotifyConnected = false
                        }
                    } else {
                        Button(spotifyBusy ? "Waiting for browser…" : "Connect Spotify") { connectSpotify() }
                            .disabled(spotifyBusy || prefs.spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let spotifyError {
                    Text(spotifyError).foregroundStyle(.red).font(.caption)
                }
            } header: {
                Text("Up Next")
            } footer: {
                Text(
                    "Spotify only shares its queue through its Web API. Create a free app at developer.spotify.com/dashboard, add the redirect URI \(SpotifyAuth.redirectURI), select Web API, and paste its Client ID here. Jumping to a song needs Spotify Premium. Apple Music works without setup (playlist order; shuffle isn't exposed)."
                )
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .onAppear { spotifyConnected = queue.spotify.isConnected }

            Section {
                Toggle("Show Claude Code activity", isOn: $prefs.claudeEnabled)
                    .onChange(of: prefs.claudeEnabled) { _, enabled in
                        if enabled { claude.start() } else { claude.stop() }
                    }
                LabeledContent("Claude Code hooks") {
                    if hooksInstalled {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") { runHooks(HookInstaller.uninstall) }
                    } else {
                        Button("Connect Claude Code") { runHooks(HookInstaller.install) }
                    }
                }
                if let hookError {
                    Text(hookError).foregroundStyle(.red).font(.caption)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text(
                    "Adds hooks to ~/.claude/settings.json (a backup is saved next to it). The hook only forwards events to Upthere over a local socket and never blocks Claude."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                usageRow("Session", isOn: $prefs.infoSession, format: $prefs.infoSessionFormat,
                         percent: "% of 5-hour limit", amount: "Tokens this session")
                usageRow("Week", isOn: $prefs.infoWeek, format: $prefs.infoWeekFormat,
                         percent: "% of weekly limit", amount: "Tokens, last 7 days")
                usageRow("Context window", isOn: $prefs.infoContext, format: $prefs.infoContextFormat,
                         percent: "% used", amount: "Tokens")
                Toggle("Tokens until auto-compact", isOn: $prefs.infoAutoCompact)
                Picker("Context window size", selection: $prefs.contextWindow) {
                    ForEach(ContextWindowSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Session cost", isOn: $prefs.infoCost)
                Toggle("Model", isOn: $prefs.infoModel)
                Toggle("Show when limits reset", isOn: $prefs.infoResetTimes)
                Picker("Ring around Claude icon", selection: $prefs.usageRing) {
                    ForEach(UsageRing.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Read plan limits from my Claude login", isOn: $prefs.accountUsage)
                    .help("Reads the Claude Code login from your Keychain (macOS asks once) and asks api.anthropic.com for your usage, like the Claude app. Never changes the login.")
                Toggle("Keep showing usage when Claude is idle", isOn: $prefs.showUsageWhenIdle)
                LabeledContent("Status line (terminal only)") {
                    if statusLineInstalled {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect") { runStatusLine(HookInstaller.uninstallStatusLine) }
                    } else {
                        Button("Connect status line") { runStatusLine(HookInstaller.installStatusLine) }
                    }
                }
            } header: {
                Text("Claude info")
            } footer: {
                Text(
                    "Plan limits come from your Claude login (same numbers as the Claude app; the endpoint is undocumented and may change) or, for Claude Code in a terminal, its status line. Token amounts are counted from local transcripts."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(updater.currentVersion)") {
                    Button("Check Now", action: updater.checkForUpdates)
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            Section("About") {
                Link("github.com/Mateu6/upthere", destination: URL(string: "https://github.com/Mateu6/upthere")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
    }

    private func usageRow(
        _ title: String, isOn: Binding<Bool>, format: Binding<UsageFormat>, percent: String, amount: String
    ) -> some View {
        HStack {
            Toggle(title, isOn: isOn)
            Spacer()
            Picker(title, selection: format) {
                Text(percent).tag(UsageFormat.percent)
                Text(amount).tag(UsageFormat.amount)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!isOn.wrappedValue)
        }
    }

    private func reloadCalendars() {
        calendarAuthorized = calendar.isAuthorized
        calendars = calendar.calendars().map { ($0.calendarIdentifier, $0.title) }
    }

    private func requestCalendar() {
        Task {
            _ = await calendar.requestAccess()
            reloadCalendars()
        }
    }

    private func createCalendar() {
        do {
            let created = try calendar.createUpthereCalendar()
            prefs.timerCalendarID = created.calendarIdentifier
            calendarError = nil
        } catch {
            calendarError = error.localizedDescription
        }
        reloadCalendars()
    }

    private func connectSpotify() {
        spotifyBusy = true
        spotifyError = nil
        Task {
            do {
                try await queue.connectSpotify(clientID: prefs.spotifyClientID.trimmingCharacters(in: .whitespaces))
                spotifyConnected = true
            } catch {
                spotifyError = error.localizedDescription
            }
            spotifyBusy = false
            NSApp.activate()
        }
    }

    private func runStatusLine(_ action: () throws -> Void) {
        do {
            try action()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        statusLineInstalled = HookInstaller.isStatusLineInstalled
    }

    private var pinCandidates: [String] {
        var ids = prefs.seenPlayers
        for id in [KnownPlayers.spotify, KnownPlayers.music] where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private func allowedBinding(_ bundleID: String) -> Binding<Bool> {
        Binding {
            prefs.allowedPlayers.contains(bundleID)
        } set: { allowed in
            prefs.allowedPlayers.removeAll { $0 == bundleID }
            if allowed { prefs.allowedPlayers.append(bundleID) }
        }
    }

    private func runHooks(_ action: () throws -> Void) {
        do {
            try action()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        hooksInstalled = HookInstaller.isInstalled
    }
}

struct PlayerLabel: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 6) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Text(bundleID)
            }
        }
    }
}
