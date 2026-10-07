import AppKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    private let window: NSWindow

    init(prefs: Preferences, nowPlaying: NowPlayingModel, claude: ClaudeModel, updater: Updater) {
        let controller = NSHostingController(
            rootView: SettingsView(prefs: prefs, nowPlaying: nowPlaying, claude: claude, updater: updater))
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
    @Bindable var updater: Updater

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
                    Picker("Glass", selection: $prefs.clearGlassStyle) {
                        ForEach(GlassStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Black gradient at the top", isOn: $prefs.clearBlackFade)
                }
                Picker("Display", selection: $prefs.display) {
                    ForEach(DisplayChoice.allCases) { Text($0.title).tag($0) }
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
                Toggle("Session cost", isOn: $prefs.infoCost)
                Toggle("Model", isOn: $prefs.infoModel)
                Toggle("Show when limits reset", isOn: $prefs.infoResetTimes)
                Picker("Ring around Claude icon", selection: $prefs.usageRing) {
                    ForEach(UsageRing.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Plan limits & cost") {
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
                    "Limits (%) and cost come from Claude Code's status line, so Upthere becomes the status line (your existing one keeps running after it). Limits are reported for Pro and Max plans after the first reply in a session. Token amounts are counted from local transcripts."
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
