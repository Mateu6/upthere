import Foundation

/// Counts tokens across all local Claude Code transcripts for the last
/// 7 days (`~/.claude/projects/**/*.jsonl`), like `ccusage` does.
///
/// Runs on a background queue, re-reads only the bytes appended since the
/// last scan, and counts each API response once even when a resumed session
/// copies earlier messages into a new transcript.
nonisolated final class UsageScanner: @unchecked Sendable {
    struct Entry: Sendable {
        var date: Date
        var tokens: Int
    }

    private let root: URL
    private let queue = DispatchQueue(label: "dev.upthere.usage-scan", qos: .utility)
    private var offsets: [String: UInt64] = [:]
    /// Response id → entry, across all files.
    private var entries: [String: Entry] = [:]

    private static let window: TimeInterval = 7 * 24 * 3600
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    /// Tokens over the last 7 days.
    func scan(completion: @escaping @Sendable (Int) -> Void) {
        queue.async {
            completion(self.scanSync())
        }
    }

    func scanSync(now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-Self.window)
        let fm = FileManager.default
        if let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, modified >= cutoff else { continue }
                let size = UInt64(values?.fileSize ?? 0)
                var offset = offsets[url.path] ?? 0
                if size < offset { offset = 0 }  // rewritten file
                guard size > offset else { continue }
                read(url, from: offset)
            }
        }
        entries = entries.filter { $0.value.date >= cutoff }
        return entries.values.reduce(0) { $0 + $1.tokens }
    }

    private func read(_ url: URL, from offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only complete lines; a partial last line is re-read next time.
        var consumed = 0
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<newline]
            if line.range(of: Self.assistantMarker) != nil { ingest(Data(line)) }
            start = data.index(after: newline)
            consumed = data.distance(from: data.startIndex, to: start)
        }
        offsets[url.path] = offset + UInt64(consumed)
    }

    private func ingest(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "assistant",
            let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            let stamp = object["timestamp"] as? String,
            let date = Self.isoFormatter.date(from: stamp)
        else { return }
        let id = (message["id"] as? String ?? "") + ":" + (object["requestId"] as? String ?? "")
        guard id != ":", entries[id] == nil else { return }
        let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"]
        let tokens = keys.compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
        entries[id] = Entry(date: date, tokens: tokens)
    }
}
