import Foundation

/// The playback state of one media player at a point in time.
/// Progress is never streamed: `elapsed` is the position at `timestamp`,
/// and views extrapolate from there.
nonisolated struct PlaybackSnapshot: Equatable, Sendable {
    var bundleID: String
    var parentBundleID: String?
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval?
    var elapsed: TimeInterval
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var source: Source

    enum Source: Sendable { case adapter, native }

    var trackKey: String { "\(bundleID)|\(title)|\(artist)|\(album)" }

    func position(at date: Date = .now) -> TimeInterval {
        var value = elapsed
        if isPlaying { value += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        if let duration, duration > 0 { value = min(value, duration) }
        return max(0, value)
    }

    func progress(at date: Date = .now) -> Double {
        guard let duration, duration > 0 else { return 0 }
        return position(at: date) / duration
    }
}

nonisolated enum MediaCommand: Sendable, Equatable {
    case togglePlayPause
    case next
    case previous
    case seek(TimeInterval)
}
