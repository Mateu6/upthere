import AppKit
import Observation
import os

private nonisolated let queueLog = Logger(subsystem: "dev.upthere.app", category: "queue")

nonisolated struct QueueItem: Identifiable, Equatable, Sendable {
    /// Position in the upcoming list (0 = next).
    let position: Int
    let title: String
    let artist: String
    let artworkURL: URL?
    /// Spotify URI (`spotify:track:…`), for jumping straight to it.
    var uri: String? = nil
    var id: String { "\(position)|\(title)|\(artist)" }
}

/// Upcoming songs for the current player: Spotify via its Web API (after
/// signing in), Music via AppleScript (current playlist order).
@Observable
final class QueueModel {
    enum Status: Equatable {
        case idle
        case loading
        case needsSpotifyLogin
        case unsupported
        case error(String)
    }

    private(set) var items: [QueueItem] = []
    private(set) var status: Status = .idle

    @ObservationIgnored let spotify: SpotifyAuth
    @ObservationIgnored private var loadedFor: String?
    @ObservationIgnored private var snapshot: PlaybackSnapshot?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(prefs: Preferences) {
        spotify = SpotifyAuth(clientID: prefs.spotifyClientID)
    }

    /// Loads the queue for `snapshot` unless it's already loaded for that track.
    func refresh(for snapshot: PlaybackSnapshot?, force: Bool = false) {
        self.snapshot = snapshot
        guard let snapshot else {
            items = []
            status = .idle
            loadedFor = nil
            return
        }
        guard force || loadedFor != snapshot.trackKey else { return }
        loadedFor = snapshot.trackKey
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load(for: snapshot)
        }
    }

    private func load(for snapshot: PlaybackSnapshot) async {
        switch snapshot.bundleID {
        case KnownPlayers.spotify:
            spotify.migrateConnectionFlag()
            guard spotify.isConnected else {
                set([], .needsSpotifyLogin)
                return
            }
            if items.isEmpty { status = .loading }
            do {
                let queue = try await SpotifyAPI(auth: spotify).queue()
                guard !Task.isCancelled else { return }
                set(queue, .idle)
            } catch {
                queueLog.error("spotify queue: \(error.localizedDescription, privacy: .public)")
                set([], spotify.isConnected ? .error(error.localizedDescription) : .needsSpotifyLogin)
            }
        case KnownPlayers.music:
            if items.isEmpty { status = .loading }
            let queue = await MusicQueue.upcoming()
            guard !Task.isCancelled else { return }
            set(queue, .idle)
        default:
            set([], .unsupported)
        }
    }

    private func set(_ items: [QueueItem], _ status: Status) {
        if self.items != items { self.items = items }
        if self.status != status { self.status = status }
    }

    /// Jumps to an upcoming song.
    func play(_ item: QueueItem, player bundleID: String) {
        Task {
            do {
                switch bundleID {
                case KnownPlayers.spotify: try await SpotifyAPI(auth: spotify).jump(to: item)
                case KnownPlayers.music: await MusicQueue.play(position: item.position)
                default: break
                }
            } catch {
                // Shown briefly, then Up Next comes back.
                status = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(5))
                if case .error = status { status = .idle }
                refresh(for: snapshot, force: true)
            }
        }
    }

    func connectSpotify(clientID: String) async throws {
        spotify.clientID = clientID
        try await spotify.connect()
        loadedFor = nil
    }

    func disconnectSpotify() {
        spotify.disconnect()
        loadedFor = nil
        set([], .needsSpotifyLogin)
    }
}

/// The parts of the Spotify Web API we use.
struct SpotifyAPI {
    let auth: SpotifyAuth

    func queue() async throws -> [QueueItem] {
        let data = try await request("GET", "/v1/me/player/queue")
        return Self.parseQueue(data)
    }

    /// Plays an upcoming song directly. Spotify has no "play queue item N",
    /// so when the song is part of the playing playlist or album it restarts
    /// that context at the song and checks it landed there (if not, what
    /// was playing is put back). Otherwise (songs you queued by hand) it
    /// skips there with the sound muted, so the songs in between aren't
    /// heard. Needs Spotify Premium.
    func jump(to item: QueueItem) async throws {
        let player = await state()
        let deviceID = (player?["device"] as? [String: Any])?["id"] as? String
        let onDevice = deviceID.map { "?device_id=\($0)" } ?? ""
        if let uri = item.uri, let context = Self.jumpContext(player) {
            do {
                _ = try await request(
                    "PUT", "/v1/me/player/play" + onDevice, body: ["context_uri": context, "offset": ["uri": uri]])
                if await landed(on: uri) { return }
                queueLog.notice("jump within \(context, privacy: .public) didn't land; restoring")
            } catch {
                queueLog.notice("jump within \(context, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            await restore(player, onDevice: onDevice)
        }
        let device = player?["device"] as? [String: Any]
        let volume = (device?["supports_volume"] as? Bool ?? false) ? device?["volume_percent"] as? Int : nil
        if volume != nil { _ = try? await request("PUT", "/v1/me/player/volume?volume_percent=0") }
        var failure: Error?
        do {
            for _ in 0..<min(item.position + 1, 20) { _ = try await request("POST", "/v1/me/player/next" + onDevice) }
        } catch {
            failure = error
        }
        if let volume { _ = try? await request("PUT", "/v1/me/player/volume?volume_percent=\(volume)") }
        if let failure { throw failure }
    }

    private func state() async -> [String: Any]? {
        guard let data = try? await request("GET", "/v1/me/player"), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Spotify applies a play command asynchronously; give it a moment.
    private func landed(on uri: String) async -> Bool {
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(250))
            if let item = await state()?["item"] as? [String: Any], item["uri"] as? String == uri { return true }
        }
        return false
    }

    /// Puts back the song (and position) that was playing before a jump.
    private func restore(_ player: [String: Any]?, onDevice: String) async {
        guard let player, let current = (player["item"] as? [String: Any])?["uri"] as? String else { return }
        var body: [String: Any] = ["position_ms": player["progress_ms"] as? Int ?? 0]
        if let context = Self.jumpContext(player) {
            body["context_uri"] = context
            body["offset"] = ["uri": current]
        } else {
            body["uris"] = [current]
        }
        _ = try? await request("PUT", "/v1/me/player/play" + onDevice, body: body)
        if player["is_playing"] as? Bool == false { _ = try? await request("PUT", "/v1/me/player/pause" + onDevice) }
    }

    /// The playing playlist or album, which can be restarted at a given song.
    /// (Artist and other contexts don't accept an offset.)
    nonisolated static func jumpContext(_ player: [String: Any]?) -> String? {
        guard let context = player?["context"] as? [String: Any],
            let type = context["type"] as? String, ["playlist", "album"].contains(type)
        else { return nil }
        return context["uri"] as? String
    }

    /// Spotify's own reason, e.g. `{"error":{"status":403,"message":"Player
    /// command failed: Restriction violated","reason":"UNKNOWN"}}`.
    nonisolated static func error(status: Int, body: Data) -> SpotifyAuth.AuthError {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        if error?["reason"] as? String == "PREMIUM_REQUIRED" {
            return .player("Jumping to a song needs Spotify Premium")
        }
        if let message = error?["message"] as? String, !message.isEmpty {
            return .player(message.replacingOccurrences(of: "Player command failed: ", with: ""))
        }
        return .badResponse(status, String(decoding: body, as: UTF8.self))
    }

    nonisolated static func parseQueue(_ data: Data) -> [QueueItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let queue = json["queue"] as? [[String: Any]]
        else { return [] }
        return queue.prefix(20).enumerated().compactMap { index, item in
            guard let name = item["name"] as? String else { return nil }
            // Tracks have artists; podcast episodes have a show.
            let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            let show = (item["show"] as? [String: Any])?["name"] as? String
            let images =
                ((item["album"] as? [String: Any])?["images"] as? [[String: Any]])
                ?? (item["images"] as? [[String: Any]]) ?? []
            // Smallest image that's still sharp at our size.
            let image = images.sorted { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
                .first { ($0["width"] as? Int ?? 0) >= 60 } ?? images.last
            return QueueItem(
                position: index, title: name, artist: artists?.joined(separator: ", ") ?? show ?? "",
                artworkURL: (image?["url"] as? String).flatMap(URL.init(string:)), uri: item["uri"] as? String)
        }
    }

    private func request(
        _ method: String, _ path: String, body: [String: Any]? = nil, retry: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.spotify.com" + path)!)
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {
            auth.invalidateAccessToken()
            return try await self.request(method, path, body: body, retry: false)
        }
        guard (200..<300).contains(status) else {
            queueLog.error("spotify \(method, privacy: .public) \(path, privacy: .public): \(status) \(String(decoding: data, as: UTF8.self), privacy: .public)")
            throw Self.error(status: status, body: data)
        }
        return data
    }
}

/// Music.app's upcoming tracks: the current playlist after the current
/// track (with shuffle on, Music doesn't expose the shuffled order).
enum MusicQueue {
    static func upcoming(limit: Int = 15) async -> [QueueItem] {
        guard NativePlayerSource.isRunning(KnownPlayers.music) else { return [] }
        let source = """
            tell application "Music"
                set out to ""
                try
                    set pl to current playlist
                    set i to index of current track
                    set n to count of tracks of pl
                    set last_ to i + \(limit)
                    if last_ > n then set last_ to n
                    repeat with k from (i + 1) to last_
                        set t to track k of pl
                        set out to out & (name of t) & tab & (artist of t) & linefeed
                    end repeat
                end try
                return out
            end tell
            """
        guard let output = await ScriptRunner.run(source) else { return [] }
        return parse(output)
    }

    nonisolated static func parse(_ output: String) -> [QueueItem] {
        output.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let title = parts.first, !title.isEmpty else { return nil }
            return QueueItem(
                position: index, title: String(title), artist: parts.count > 1 ? String(parts[1]) : "", artworkURL: nil)
        }
    }

    static func play(position: Int) async {
        _ = await ScriptRunner.run(
            "tell application \"Music\" to play track ((index of current track) + \(position + 1)) of current playlist")
    }
}
