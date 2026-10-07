import AppKit
import Observation

/// Merges all now-playing sources, applies the player filter and decides what
/// the notch shows. Commands are routed to the app that is actually shown.
@Observable
final class NowPlayingModel {
    /// What the notch shows (may be paused).
    private(set) var current: PlaybackSnapshot?
    private(set) var artwork: Artwork?
    /// True while the collapsed notch should show music (playing, or paused recently).
    private(set) var isLive = false
    private(set) var adapterHealthy = false

    @ObservationIgnored private let prefs: Preferences
    @ObservationIgnored private let adapter = MediaRemoteAdapterSource()
    @ObservationIgnored private let native = NativePlayerSource()
    @ObservationIgnored private let artworkStore = ArtworkStore()
    /// Latest known state per player; the adapter only reports the elected player.
    @ObservationIgnored private var players: [String: PlaybackSnapshot] = [:]
    @ObservationIgnored private var adapterElected: String?
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var pausedSince: Date?

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    func start() {
        adapter.onSnapshot = { [weak self] in self?.adapterUpdate($0) }
        adapter.onArtwork = { [weak self] key, data in self?.artworkStore.ingest(key: key, data: data) }
        adapter.onHealthChange = { [weak self] healthy in
            self?.adapterHealthy = healthy
            if !healthy { self?.refreshNativePlayers() }
        }
        native.onSnapshot = { [weak self] bundleID, snapshot in self?.nativeUpdate(bundleID, snapshot) }
        native.onArtworkURL = { [weak self] key, url in self?.artworkStore.ingest(key: key, url: url) }
        artworkStore.onLoaded = { [weak self] key in
            guard let self, key == self.current?.trackKey else { return }
            self.artwork = self.artworkStore.artwork(for: key)
        }

        native.start()
        if prefs.useMediaRemoteAdapter && adapter.isAvailable {
            adapter.start()
        } else {
            refreshNativePlayers()
        }
        observePreferences()
    }

    func stop() {
        adapter.stop()
        native.stop()
        lingerTask?.cancel()
    }

    // MARK: Source updates

    private func adapterUpdate(_ snapshot: PlaybackSnapshot?) {
        let previous = adapterElected
        adapterElected = snapshot?.bundleID
        if let snapshot {
            prefs.notePlayerSeen(snapshot.bundleID)
            players[snapshot.bundleID] = snapshot
        } else if let previous, !NativePlayerSource.supported.contains(previous) {
            // Spotify/Music keep their own state via notifications; other
            // apps vanish when they stop being the elected player.
            players.removeValue(forKey: previous)
        }
        // A filtered app (e.g. a browser) took over: make sure we still know
        // the state of the music apps hiding behind it.
        if let snapshot, !prefs.allowsPlayer(snapshot.bundleID, parent: snapshot.parentBundleID) {
            refreshNativePlayers(onlyUnknown: true)
        }
        recompute()
    }

    private func nativeUpdate(_ bundleID: String, _ snapshot: PlaybackSnapshot?) {
        if let snapshot {
            prefs.notePlayerSeen(bundleID)
            // Keep richer adapter data (artwork) when it describes the same track.
            if let existing = players[bundleID], existing.source == .adapter,
                existing.trackKey == snapshot.trackKey, adapterElected == bundleID
            {
                var merged = existing
                merged.isPlaying = snapshot.isPlaying
                merged.rate = snapshot.rate
                if snapshot.elapsed > 0 || !snapshot.isPlaying {
                    merged.elapsed = snapshot.elapsed
                    merged.timestamp = snapshot.timestamp
                }
                players[bundleID] = merged
            } else {
                players[bundleID] = snapshot
            }
        } else {
            players.removeValue(forKey: bundleID)
        }
        recompute()
    }

    private func refreshNativePlayers(onlyUnknown: Bool = false) {
        for bundleID in NativePlayerSource.supported where NativePlayerSource.isRunning(bundleID) {
            if onlyUnknown && players[bundleID] != nil { continue }
            native.refresh(bundleID)
        }
    }

    // MARK: Arbitration

    private func recompute() {
        let candidates = players.values.filter { prefs.allowsPlayer($0.bundleID, parent: $0.parentBundleID) }
        let chosen: PlaybackSnapshot?
        if let pinned = prefs.pinnedPlayer, let snapshot = candidates.first(where: { $0.bundleID == pinned }),
            snapshot.isPlaying || !candidates.contains(where: \.isPlaying)
        {
            chosen = snapshot
        } else if let elected = adapterElected, let snapshot = players[elected], snapshot.isPlaying,
            candidates.contains(where: { $0.bundleID == elected })
        {
            chosen = snapshot
        } else if let playing = candidates.filter(\.isPlaying).max(by: { $0.timestamp < $1.timestamp }) {
            chosen = playing
        } else if let pinned = prefs.pinnedPlayer, let snapshot = candidates.first(where: { $0.bundleID == pinned }) {
            chosen = snapshot
        } else {
            chosen = candidates.max(by: { $0.timestamp < $1.timestamp })
        }

        if current != chosen { current = chosen }
        if let chosen {
            let art = artworkStore.artwork(for: chosen.trackKey)
            if artwork != art { artwork = art }
            if art == nil, chosen.source == .native, chosen.bundleID == KnownPlayers.spotify,
                !artworkStore.has(chosen.trackKey)
            {
                native.refresh(KnownPlayers.spotify)
            }
        } else if artwork != nil {
            artwork = nil
        }
        updateLiveness()
    }

    private func updateLiveness() {
        lingerTask?.cancel()
        guard let current else {
            pausedSince = nil
            isLive = false
            return
        }
        if current.isPlaying {
            pausedSince = nil
            if !isLive { isLive = true }
            return
        }
        let since = pausedSince ?? .now
        pausedSince = since
        let remaining = prefs.pausedLingerMinutes * 60 - Date.now.timeIntervalSince(since)
        guard remaining > 0 else {
            if isLive { isLive = false }
            return
        }
        if !isLive { isLive = true }
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.isLive = false
        }
    }

    private func observePreferences() {
        withObservationTracking {
            _ = prefs.playerFilter
            _ = prefs.allowedPlayers
            _ = prefs.pinnedPlayer
            _ = prefs.pausedLingerMinutes
            _ = prefs.useMediaRemoteAdapter
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.prefs.useMediaRemoteAdapter { self.adapter.start() } else { self.adapter.stop() }
                self.refreshNativePlayers(onlyUnknown: true)
                self.recompute()
                self.observePreferences()
            }
        }
    }

    // MARK: Commands

    func send(_ command: MediaCommand) {
        guard let current else { return }
        // Talk to Spotify/Music directly so commands never hit a browser tab.
        // Other apps are only shown while they are the elected player, so the
        // adapter's MediaRemote command reaches them.
        if NativePlayerSource.supported.contains(current.bundleID) {
            native.send(command, to: current.bundleID)
        } else if adapterElected == current.bundleID {
            adapter.send(command)
        }
        applyOptimistically(command)
    }

    private func applyOptimistically(_ command: MediaCommand) {
        guard var snapshot = current else { return }
        switch command {
        case .togglePlayPause:
            snapshot.elapsed = snapshot.position()
            snapshot.timestamp = .now
            snapshot.isPlaying.toggle()
            snapshot.rate = snapshot.isPlaying ? 1 : 0
        case .seek(let seconds):
            snapshot.elapsed = seconds
            snapshot.timestamp = .now
        case .next, .previous:
            return
        }
        players[snapshot.bundleID] = snapshot
        recompute()
    }

    func activatePlayerApp() {
        guard let bundleID = current?.parentBundleID ?? current?.bundleID,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate()
    }
}
