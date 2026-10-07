import Darwin
import Foundation

nonisolated struct TranscriptInfo: Sendable, Equatable {
    var lastText: String?
    var model: String?
    var contextTokens: Int?
    var title: String?
}

/// Follows one session's JSONL transcript, reading only appended bytes.
/// The transcript format is undocumented; anything unexpected is skipped so
/// the UI degrades to hook-only data.
nonisolated final class TranscriptTailer: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let onUpdate: @Sendable (TranscriptInfo) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: off_t = 0
    private var partial = Data()
    private var info = TranscriptInfo()

    private static let initialTailBytes: off_t = 512 * 1024

    init(url: URL, queue: DispatchQueue, onUpdate: @escaping @Sendable (TranscriptInfo) -> Void) {
        self.url = url
        self.queue = queue
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { self.open() }
    }

    func stop() {
        queue.async {
            self.source?.cancel()
            self.source = nil
        }
    }

    private func open() {
        guard source == nil else { return }
        fd = Darwin.open(url.path, O_RDONLY | O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let size = lseek(fd, 0, SEEK_END)
        offset = max(0, size - Self.initialTailBytes)
        let skipFirstLine = offset > 0
        readAppended(skipFirstLine: skipFirstLine)

        let fd = self.fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.source?.cancel()
                self.source = nil
                return
            }
            self.readAppended(skipFirstLine: false)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func readAppended(skipFirstLine: Bool) {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        var data = Data()
        while true {
            let n = chunk.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
            guard n > 0 else { break }
            data.append(contentsOf: chunk[0..<n])
            offset += off_t(n)
        }
        guard !data.isEmpty else { return }
        if skipFirstLine, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        partial.append(data)

        let before = info
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            Self.apply(line: Data(line), to: &info)
            partial.removeSubrange(partial.startIndex...newline)
        }
        if partial.count > 32 * 1024 * 1024 { partial.removeAll() }
        if info != before { onUpdate(info) }
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let titleMarker = Data(#""type":"custom-title""#.utf8)
    private static let agentNameMarker = Data(#""type":"agent-name""#.utf8)

    /// Cheap byte search before JSON parsing: most lines (tool results,
    /// file contents) are irrelevant and can be large.
    static func apply(line: Data, to info: inout TranscriptInfo) {
        let isAssistant = line.range(of: assistantMarker) != nil
        let isTitle = !isAssistant && (line.range(of: titleMarker) != nil || line.range(of: agentNameMarker) != nil)
        guard isAssistant || isTitle,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }

        if isTitle {
            if let title = (object["customTitle"] as? String) ?? (object["agentName"] as? String) {
                info.title = title
            }
            return
        }
        guard object["type"] as? String == "assistant", object["isSidechain"] as? Bool != true,
            let message = object["message"] as? [String: Any]
        else { return }

        if let model = message["model"] as? String, !model.hasPrefix("<") { info.model = model }
        if let usage = message["usage"] as? [String: Any] {
            let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            let total = keys.compactMap { (usage[$0] as? NSNumber)?.intValue }.reduce(0, +)
            if total > 0 { info.contextTokens = total }
        }
        if let content = message["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if let text = texts.last?.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
            {
                info.lastText = text.count > 160 ? String(text.prefix(159)) + "…" : text
            }
        }
    }
}
