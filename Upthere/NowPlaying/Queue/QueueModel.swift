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
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(prefs: Preferences) {
        spotify = SpotifyAuth(clientID: prefs.spotifyClientID)
    }

    /// Loads the queue for `snapshot` unless it's already loaded for that track.
    func refresh(for snapshot: PlaybackSnapshot?, force: Bool = false) {
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
                case KnownPlayers.spotify: try await SpotifyAPI(auth: spotify).skip(times: item.position + 1)
                case KnownPlayers.music: await MusicQueue.play(position: item.position)
                default: break
                }
            } catch {
                status = .error(error.localizedDescription)
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

    /// Spotify has no "play queue item N"; skipping N times gets there.
    /// Needs Spotify Premium.
    func skip(times: Int) async throws {
        for _ in 0..<min(times, 20) { _ = try await request("POST", "/v1/me/player/next") }
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
                artworkURL: (image?["url"] as? String).flatMap(URL.init(string:)))
        }
    }

    private func request(_ method: String, _ path: String, retry: Bool = true) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.spotify.com" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {
            auth.invalidateAccessToken()
            return try await self.request(method, path, retry: false)
        }
        guard (200..<300).contains(status) else {
            if status == 403 && method == "POST" {
                throw SpotifyAuth.AuthError.denied("jumping to a song needs Spotify Premium")
            }
            throw SpotifyAuth.AuthError.badResponse(status, String(decoding: data, as: UTF8.self))
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
