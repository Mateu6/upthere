import Darwin
import Foundation

nonisolated struct TranscriptInfo: Sendable, Equatable {
    var lastText: String?
    var model: String?
    var contextTokens: Int?
    var title: String?
    /// Tokens this session has processed (input, cache reads/writes and
    /// output), counting each API response once.
    var sessionTokens = 0
    /// Esc presses seen since tailing began (Claude Code sends no hook for them).
    var interrupts = 0
    /// The latest tool results seen since tailing began, newest last: a
    /// result for the call Claude was waiting on means you answered.
    var recentToolResults: [String] = []
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
    /// A response spans several lines (one per content block); count it once.
    private var countedMessages: Set<String> = []
    /// False during the first read, so old interrupts and results are skipped.
    private var live = false

    /// Read the whole transcript once for session totals (bounded).
    private static let initialTailBytes: off_t = 96 * 1024 * 1024

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
        // History says nothing about the turn in progress.
        live = false
        readAppended(skipFirstLine: skipFirstLine)
        live = true

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
            Self.apply(line: Data(line), to: &info, counted: &countedMessages)
            if live { Self.applySignals(line: Data(line), to: &info) }
            partial.removeSubrange(partial.startIndex...newline)
        }
        if partial.count > 32 * 1024 * 1024 { partial.removeAll() }
        if info != before { onUpdate(info) }
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let titleMarker = Data(#""type":"custom-title""#.utf8)
    private static let agentNameMarker = Data(#""type":"agent-name""#.utf8)

    private static let userMarker = Data(#""type":"user""#.utf8)
    private static let sidechainMarker = Data(#""isSidechain":true"#.utf8)
    private static let interruptMarker = Data("[Request interrupted by user".utf8)
    private static let toolResultMarker = Data(#""type":"tool_result""#.utf8)
    private static let toolUseIDMarker = Data(#""tool_use_id":""#.utf8)

    /// Interrupts and tool results on the main chain, by byte search only
    /// (tool results can be large).
    static func applySignals(line: Data, to info: inout TranscriptInfo) {
        guard line.range(of: userMarker) != nil, line.range(of: sidechainMarker) == nil else { return }
        if line.range(of: interruptMarker) != nil { info.interrupts += 1 }
        guard line.range(of: toolResultMarker) != nil else { return }
        var searchStart = line.startIndex
        while let marker = line.range(of: toolUseIDMarker, in: searchStart..<line.endIndex) {
            guard let end = line[marker.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { break }
            info.recentToolResults.append(String(decoding: line[marker.upperBound..<end], as: UTF8.self))
            searchStart = end
        }
        if info.recentToolResults.count > 16 { info.recentToolResults.removeFirst(info.recentToolResults.count - 16) }
    }

    /// Cheap byte search before JSON parsing: most lines (tool results,
    /// file contents) are irrelevant and can be large.
    static func apply(line: Data, to info: inout TranscriptInfo) {
        var counted: Set<String> = []
        apply(line: line, to: &info, counted: &counted)
    }

    static func apply(line: Data, to info: inout TranscriptInfo, counted: inout Set<String>) {
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
            let id = message["id"] as? String ?? UUID().uuidString
            if counted.insert(id).inserted {
                info.sessionTokens += total + ((usage["output_tokens"] as? NSNumber)?.intValue ?? 0)
            }
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
