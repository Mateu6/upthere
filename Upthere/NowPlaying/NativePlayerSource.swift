import AppKit
import os

nonisolated private let nativeLog = Logger(subsystem: "dev.upthere.app", category: "native-player")

/// Spotify and Music.app state straight from the apps themselves.
///
/// Both apps broadcast a distributed notification on every state change, so
/// this costs nothing while idle. AppleScript is used only for commands and
/// for an on-demand refresh (e.g. when a browser is the system's "elected"
/// now-playing app and we still want to show Spotify).
final class NativePlayerSource {
    var onSnapshot: ((String, PlaybackSnapshot?) -> Void)?
    var onArtworkURL: ((String, URL) -> Void)?

    static let supported = [KnownPlayers.spotify, KnownPlayers.music]

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        observers.append(
            dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) {
                [weak self] note in
                let snapshot = Self.spotifySnapshot(note.userInfo ?? [:])
                MainActor.assumeIsolated { self?.onSnapshot?(KnownPlayers.spotify, snapshot) }
            })
        observers.append(
            dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) {
                [weak self] note in
                let snapshot = Self.musicSnapshot(note.userInfo ?? [:])
                MainActor.assumeIsolated {
                    self?.onSnapshot?(KnownPlayers.music, snapshot)
                    // Music's notification carries no position; refresh it via AppleScript.
                    if snapshot != nil { self?.refresh(KnownPlayers.music) }
                }
            })
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    if let bundleID, Self.supported.contains(bundleID) { self?.onSnapshot?(bundleID, nil) }
                }
            })
    }

    func stop() {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Notifications

    nonisolated private static func spotifySnapshot(_ info: [AnyHashable: Any]) -> PlaybackSnapshot? {
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let title = info["Name"] as? String, !title.isEmpty else { return nil }
        return PlaybackSnapshot(
            bundleID: KnownPlayers.spotify,
            title: title,
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: (info["Duration"] as? NSNumber).map { $0.doubleValue / 1000 },
            elapsed: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0,
            timestamp: .now,
            rate: state == "Playing" ? 1 : 0,
            isPlaying: state == "Playing",
            source: .native
        )
    }

    nonisolated private static func musicSnapshot(_ info: [AnyHashable: Any]) -> PlaybackSnapshot? {
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped", let title = info["Name"] as? String, !title.isEmpty else { return nil }
        return PlaybackSnapshot(
            bundleID: KnownPlayers.music,
            title: title,
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: (info["Total Time"] as? NSNumber).map { $0.doubleValue / 1000 },
            elapsed: 0,
            timestamp: .now,
            rate: state == "Playing" ? 1 : 0,
            isPlaying: state == "Playing",
            source: .native
        )
    }

    // MARK: AppleScript

    /// Re-reads a player's full state. Never launches the player.
    func refresh(_ bundleID: String) {
        guard Self.isRunning(bundleID) else { return }
        let appName = bundleID == KnownPlayers.spotify ? "Spotify" : "Music"
        let artwork = bundleID == KnownPlayers.spotify ? "artwork url of t" : "\"\""
        let source = """
            tell application "\(appName)"
                set s to player state as string
                if s is "stopped" then return s
                set t to current track
                return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string) & linefeed & \(artwork)
            end tell
            """
        Task {
            guard let output = await ScriptRunner.run(source) else { return }
            self.applyRefresh(bundleID: bundleID, output: output)
        }
    }

    private func applyRefresh(bundleID: String, output: String) {
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 6, parts[0] != "stopped" else {
            onSnapshot?(bundleID, nil)
            return
        }
        let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) }
        var duration = number(parts[4])
        // Spotify reports milliseconds, Music reports seconds.
        if bundleID == KnownPlayers.spotify { duration = duration.map { $0 / 1000 } }
        let playing = parts[0] == "playing"
        let snapshot = PlaybackSnapshot(
            bundleID: bundleID,
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: duration,
            elapsed: number(parts[5]) ?? 0,
            timestamp: .now,
            rate: playing ? 1 : 0,
            isPlaying: playing,
            source: .native
        )
        onSnapshot?(bundleID, snapshot)
        if parts.count > 6, let url = URL(string: parts[6]), url.scheme == "https" {
            onArtworkURL?(snapshot.trackKey, url)
        }
    }

    func send(_ command: MediaCommand, to bundleID: String) {
        guard Self.isRunning(bundleID) else { return }
        let appName = bundleID == KnownPlayers.spotify ? "Spotify" : "Music"
        let verb: String
        switch command {
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .seek(let seconds): verb = "set player position to \(String(format: "%.2f", max(0, seconds)))"
        }
        Task {
            _ = await ScriptRunner.run("tell application \"\(appName)\" to \(verb)")
            nativeLog.debug("sent \(verb) to \(appName)")
        }
    }
}

/// Runs AppleScript off the main thread via osascript. TCC attributes the
/// Automation permission to Upthere (the responsible process).
enum ScriptRunner {
    static func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                guard proc.terminationStatus == 0 else { return continuation.resume(returning: nil) }
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
