import SwiftUI

struct MusicSettings: View {
    @Bindable var prefs: Preferences
    let queue: QueueModel
    @State private var spotifyConnected = false
    @State private var spotifyBusy = false
    @State private var spotifyError: String?

    var body: some View {
        Form {
            Section("Now Playing") {
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
                Toggle("Show title and artist when the track changes", isOn: $prefs.announceTracks)
                Toggle("Live visualizer (bars follow the music)", isOn: $prefs.liveVisualizer)
                    .help("Analyzes the player's audio in real time. macOS asks once for permission to capture app audio.")
                if prefs.liveVisualizer && VisualizerStatus.shared.failed {
                    FixRow(
                        message: "Upthere can't hear the player, so the bars use a stand-in animation. Allow it under System Audio Recording.",
                        button: "Open Privacy Settings…"
                    ) { PrivacySettings.open("Privacy_ScreenCapture") }
                }
                Toggle("Scroll sideways on the music ear to seek", isOn: $prefs.scrollToSeek)
                Toggle("Scroll up/down on the music ear for volume", isOn: $prefs.scrollForVolume)
                LabeledContent("Keep paused music for") {
                    Stepper("\(Int(prefs.pausedLingerMinutes)) min", value: $prefs.pausedLingerMinutes, in: 0...60, step: 1)
                }
            }

            Section {
                Toggle("Show upcoming songs (when only music is shown)", isOn: $prefs.showQueue)
                TextField("Spotify Client ID", text: $prefs.spotifyClientID, prompt: Text("from developer.spotify.com"))
                    .disableAutocorrection(true)
                LabeledContent("Redirect URI") {
                    Text(SpotifyAuth.redirectURI).monospaced().textSelection(.enabled).foregroundStyle(.secondary)
                    CopyButton(value: SpotifyAuth.redirectURI)
                }
                LabeledContent("Spotify") {
                    if spotifyConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        Button("Disconnect") {
                            queue.disconnectSpotify()
                            spotifyConnected = false
                        }
                    } else if spotifyBusy {
                        Text("Waiting for the browser…").foregroundStyle(.secondary)
                        Button("Cancel") { queue.cancelSpotifyConnect() }
                    } else {
                        Button("Connect Spotify") { connectSpotify() }
                            .disabled(prefs.spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let spotifyError { ErrorText(message: spotifyError) }
            } header: {
                Text("Up Next")
            } footer: {
                SettingsFooter(
                    text: "Spotify only shares its queue through its Web API. Create a free app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), add the redirect URI above, select Web API, and paste its Client ID here. Jumping to a song needs Spotify Premium. Apple Music works without setup (playlist order; shuffle isn't exposed)."
                )
            }
            .onAppear { spotifyConnected = queue.spotify.isConnected }

            Section {
                Picker("Pinned player", selection: $prefs.pinnedPlayer) {
                    Text("None").tag(String?.none)
                    ForEach(pinCandidates, id: \.self) { bundleID in
                        PlayerLabel(bundleID: bundleID).tag(Optional(bundleID))
                    }
                }
                Toggle("Use MediaRemote adapter (all players)", isOn: $prefs.useMediaRemoteAdapter)
            } header: {
                Text("Advanced")
            } footer: {
                SettingsFooter(
                    text: "The pinned player is always shown and controlled when it has a track loaded, even while a browser plays video. Without the adapter, only Spotify and Music are supported."
                )
            }
        }
        .settingsTab()
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

    private func connectSpotify() {
        spotifyBusy = true
        spotifyError = nil
        Task {
            do {
                try await queue.connectSpotify(clientID: prefs.spotifyClientID.trimmingCharacters(in: .whitespaces))
                spotifyConnected = true
            } catch SpotifyAuth.AuthError.cancelled {
                spotifyError = nil  // the user cancelled or the browser was left; nothing to explain
            } catch {
                spotifyError = error.localizedDescription
            }
            spotifyBusy = false
            NSApp.activate()
        }
    }
}
