import Foundation
import os

nonisolated private let adapterLog = Logger(subsystem: "dev.upthere.app", category: "adapter")

/// Streams the system "now playing" state through ungive/mediaremote-adapter.
///
/// One long-lived `/usr/bin/perl` child prints JSON lines; we merge the diffs
/// on a background queue and hand finished snapshots to the main actor.
/// No polling: the child blocks until MediaRemote reports a change.
final class MediaRemoteAdapterSource {
    var onSnapshot: ((PlaybackSnapshot?) -> Void)?
    var onArtwork: ((String, Data) -> Void)?
    var onHealthChange: ((Bool) -> Void)?

    private(set) var isHealthy = false {
        didSet { if oldValue != isHealthy { onHealthChange?(isHealthy) } }
    }

    private var process: Process?
    private var stopped = true
    private var failures = 0
    private var restartTask: Task<Void, Never>?
    private let parser = AdapterStreamParser()

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    private var resources: (script: URL, framework: URL)? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else { return nil }
        let script = base.appendingPathComponent("mediaremote-adapter.pl")
        let framework = base.appendingPathComponent("MediaRemoteAdapter.framework")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.perl.path), fm.fileExists(atPath: script.path),
            fm.fileExists(atPath: framework.path)
        else { return nil }
        return (script, framework)
    }

    var isAvailable: Bool { resources != nil }

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        restartTask?.cancel()
        restartTask = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        isHealthy = false
    }

    private func launch() {
        guard !stopped else { return }
        guard let resources else {
            adapterLog.error("adapter resources or /usr/bin/perl missing")
            isHealthy = false
            return
        }

        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [resources.script.path, resources.framework.path, "stream", "--debounce=40"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let parser = self.parser
        parser.reset()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let events = parser.feed(data)
            guard !events.isEmpty else { return }
            Task { @MainActor [weak self] in self?.deliver(events) }
        }

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in self?.handleExit(status: status) }
        }

        do {
            try process.run()
            self.process = process
            adapterLog.info("adapter started (pid \(process.processIdentifier))")
        } catch {
            adapterLog.error("failed to launch adapter: \(error.localizedDescription)")
            handleExit(status: -1)
        }
    }

    private func deliver(_ events: [AdapterStreamParser.Event]) {
        failures = 0
        isHealthy = true
        for event in events {
            switch event {
            case .snapshot(let snapshot): onSnapshot?(snapshot)
            case .artwork(let key, let data): onArtwork?(key, data)
            }
        }
    }

    private func handleExit(status: Int32) {
        process = nil
        guard !stopped else { return }
        isHealthy = false
        onSnapshot?(nil)
        failures += 1
        // The adapter docs ask not to respawn after fatal errors; we back off
        // exponentially and give up after a handful of attempts.
        guard failures <= 6 else {
            adapterLog.error("adapter keeps failing (status \(status)); falling back to native sources")
            return
        }
        let delay = min(60, pow(2, Double(failures)))
        adapterLog.notice("adapter exited (status \(status)); restarting in \(delay)s")
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    /// Sends a command to the system's current now-playing app.
    func send(_ command: MediaCommand) {
        guard let resources else { return }
        var args = [resources.script.path, resources.framework.path]
        switch command {
        case .togglePlayPause: args += ["send", "2"]
        case .next: args += ["send", "4"]
        case .previous: args += ["send", "5"]
        case .seek(let seconds): args += ["seek", String(Int64(max(0, seconds) * 1_000_000))]
        }
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Incremental parser for the adapter's `stream` output.
/// Confined to the pipe's reader callback; guarded by a lock to be safe.
nonisolated final class AdapterStreamParser: @unchecked Sendable {
    enum Event: Sendable {
        case snapshot(PlaybackSnapshot?)
        case artwork(trackKey: String, data: Data)
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var lastArtworkKey: String?

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoFormatterNoFraction = ISO8601DateFormatter()

    func reset() {
        lock.withLock {
            buffer.removeAll()
            state.removeAll()
            lastArtworkKey = nil
        }
    }

    func feed(_ data: Data) -> [Event] {
        lock.withLock {
            buffer.append(data)
            var events: [Event] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let lineEvents = handle(line: Data(line)) { events += lineEvents }
            }
            return events
        }
    }

    private func handle(line: Data) -> [Event]? {
        guard !line.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = object["payload"] as? [String: Any]
        else { return nil }

        let isDiff = object["diff"] as? Bool ?? false
        if isDiff {
            for (key, value) in payload {
                if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
            }
        } else {
            state = payload
        }

        let snapshot = Self.snapshot(from: state)
        var events: [Event] = [.snapshot(snapshot)]

        // Artwork arrives base64-encoded; only decode it when it changed.
        if let snapshot, payload["artworkData"] != nil || snapshot.trackKey != lastArtworkKey,
            let base64 = state["artworkData"] as? String,
            let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        {
            lastArtworkKey = snapshot.trackKey
            events.append(.artwork(trackKey: snapshot.trackKey, data: data))
        }
        return events
    }

    static func snapshot(from state: [String: Any]) -> PlaybackSnapshot? {
        guard let bundleID = state["bundleIdentifier"] as? String,
            let title = state["title"] as? String, !title.isEmpty
        else { return nil }

        let playing = state["playing"] as? Bool ?? false
        var timestamp = Date()
        if let raw = state["timestamp"] as? String {
            timestamp = isoFormatter.date(from: raw) ?? isoFormatterNoFraction.date(from: raw) ?? Date()
        }
        return PlaybackSnapshot(
            bundleID: bundleID,
            parentBundleID: state["parentApplicationBundleIdentifier"] as? String,
            title: title,
            artist: state["artist"] as? String ?? "",
            album: state["album"] as? String ?? "",
            duration: (state["duration"] as? NSNumber)?.doubleValue,
            elapsed: (state["elapsedTime"] as? NSNumber)?.doubleValue ?? 0,
            timestamp: timestamp,
            rate: (state["playbackRate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0),
            isPlaying: playing,
            source: .adapter
        )
    }
}
