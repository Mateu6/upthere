import Darwin
import Foundation
import os

nonisolated private let hubLog = Logger(subsystem: "dev.upthere.app", category: "claude-hub")

/// Unix-domain socket server receiving hook events from `upthere-hook`.
/// One connection carries one message; the client closes when done. An
/// answer request (`"kind":"answer"`) is the exception: its line is
/// delivered as soon as it's complete and the connection stays open for the
/// reply, until the app answers or the hook goes away.
/// Everything runs on a private queue; parsed events hop to the main actor.
nonisolated final class ClaudeHub: @unchecked Sendable {
    static var defaultSocketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/upthere/claude.sock")
    }

    private let path: String
    private let queue = DispatchQueue(label: "dev.upthere.claude-hub")
    private let onMessage: @Sendable (ClaudeMessage) -> Void
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    private var answers: [Int32: AnswerChannel] = [:]
    private static let answerPrefix = Data(#"{"v":1,"kind":"answer""#.utf8)
    private static let maxMessageSize = 16 * 1024 * 1024

    init(path: String = ClaudeHub.defaultSocketURL.path, onMessage: @escaping @Sendable (ClaudeMessage) -> Void) {
        self.path = path
        self.onMessage = onMessage
    }

    func start() throws {
        try queue.sync { try listen() }
    }

    func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            for (_, client) in clients { client.source.cancel() }
            clients.removeAll()
            for (_, channel) in answers { channel.markClosed() }
            answers.removeAll()
            unlink(path)
        }
    }

    private func listen() throws {
        guard listenSource == nil else { return }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
        hubLog.info("listening on \(self.path, privacy: .public)")
    }

    private func acceptClients(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { close(fd) }
            clients[fd] = (source, Data())
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                guard answers[fd] == nil else { continue }  // nothing more is expected
                clients[fd]?.buffer.append(contentsOf: chunk[0..<n])
                if (clients[fd]?.buffer.count ?? 0) > Self.maxMessageSize { return finish(fd, deliver: false) }
                deliverAnswerIfComplete(fd)
            } else if n == 0 {
                return finish(fd, deliver: true)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                return finish(fd, deliver: false)
            }
        }
    }

    private func finish(_ fd: Int32, deliver: Bool) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.source.cancel()
        if let channel = answers.removeValue(forKey: fd) {
            channel.markClosed()
            return
        }
        guard deliver, let message = ClaudeMessage.parse(client.buffer) else { return }
        onMessage(message)
    }

    /// An answer request is one line; deliver it without waiting for EOF.
    private func deliverAnswerIfComplete(_ fd: Int32) {
        guard let buffer = clients[fd]?.buffer, buffer.starts(with: Self.answerPrefix),
            let newline = buffer.firstIndex(of: 0x0A)
        else { return }
        let channel = AnswerChannel(hub: self, fd: fd)
        answers[fd] = channel
        guard let event = HookEvent.parse(buffer[buffer.startIndex..<newline]),
            let root = try? JSONSerialization.jsonObject(with: buffer[buffer.startIndex..<newline]) as? [String: Any],
            let payload = root["payload"] as? [String: Any], let request = ClaudeRequest.parse(payload: payload)
        else { return reply(fd: fd, "") }
        onMessage(.answer(event, request, channel))
    }

    /// Sends the hook its stdout (empty: no decision) and closes.
    fileprivate func reply(fd: Int32, _ output: String) {
        queue.async { [self] in
            guard clients[fd] != nil else { return }
            var bytes = Array(output.utf8)
            bytes.append(0x0A)
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
            answers.removeValue(forKey: fd)
            finish(fd, deliver: false)
        }
    }
}

/// The open line back to a waiting `upthere-hook answer`.
nonisolated final class AnswerChannel: @unchecked Sendable {
    private weak var hub: ClaudeHub?
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var onClose: (@Sendable () -> Void)?

    fileprivate init(hub: ClaudeHub, fd: Int32) {
        self.hub = hub
        self.fd = fd
    }

    /// The hook prints `output` as its decision; an empty string means none,
    /// and Claude Code asks in the terminal as usual.
    func reply(_ output: String) {
        lock.lock()
        let wasClosed = closed
        closed = true
        onClose = nil
        lock.unlock()
        guard !wasClosed else { return }
        hub?.reply(fd: fd, output)
    }

    /// Called once if the hook goes away first (timed out, Claude stopped).
    func whenClosed(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            return handler()
        }
        onClose = handler
        lock.unlock()
    }

    fileprivate func markClosed() {
        lock.lock()
        let handler = closed ? nil : onClose
        closed = true
        onClose = nil
        lock.unlock()
        handler?()
    }
}
