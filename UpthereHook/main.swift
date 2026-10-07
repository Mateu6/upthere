// upthere-hook: forwards a Claude Code hook payload (stdin) to the Upthere app
// over a Unix domain socket. It must never slow Claude down, so it:
//   - avoids Foundation (fast cold start),
//   - gives up immediately if the app isn't listening,
//   - caps the time spent writing,
//   - always exits 0 and prints nothing.
import Darwin

func env(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

func jsonString(_ value: String?) -> String {
    guard let value else { return "null" }
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20:
            let hex = String(scalar.value, radix: 16)
            out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

func readStdin() -> [UInt8] {
    var data: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if n > 0 {
            data.append(contentsOf: chunk[0..<n])
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            break
        }
    }
    while let last = data.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 {
        data.removeLast()
    }
    return data
}

func socketPath() -> String? {
    if let override = env("UPTHERE_SOCKET") { return override }
    guard let home = env("HOME") else { return nil }
    return home + "/Library/Application Support/upthere/claude.sock"
}

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < capacity else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else { close(fd); return nil }
    return fd
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
        if n > 0 {
            offset += n
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            return
        }
    }
}

let payload = readStdin()
guard payload.first == UInt8(ascii: "{"), let path = socketPath(), let fd = connectSocket(path) else {
    exit(0)
}

// Envelope: the hook process inherits the terminal's environment, which tells
// the app which window to bring forward when the session is clicked.
var message = Array(
    "{\"v\":1,\"term\":\(jsonString(env("TERM_PROGRAM"))),\"bundle\":\(jsonString(env("__CFBundleIdentifier"))),\"ppid\":\(getppid()),\"payload\":"
        .utf8)
message.append(contentsOf: payload)
message.append(contentsOf: Array("}\n".utf8))
writeAll(fd, message)
close(fd)
exit(0)
