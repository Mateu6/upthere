// upthere-hook: forwards a Claude Code hook payload (stdin) to the Upthere app
// over a Unix domain socket.
//
//   upthere-hook                         hook mode (prints nothing)
//   upthere-hook statusline [--then CMD] status-line mode: forwards the JSON,
//       then runs CMD (the user's previous status line) with the same input,
//       or prints a compact line of its own.
//
// It must never slow Claude down, so it:
//   - avoids Foundation (fast cold start),
//   - gives up immediately if the app isn't listening,
//   - caps the time spent writing,
//   - always exits 0 (and prints nothing in hook mode).
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

/// Index just past the first occurrence of `needle` at or after `from`.
func find(_ hay: [UInt8], _ needle: String, from: Int = 0) -> Int? {
    let n = Array(needle.utf8)
    guard !n.isEmpty, hay.count >= n.count else { return nil }
    var i = from
    while i <= hay.count - n.count {
        if hay[i] == n[0] && Array(hay[i..<i + n.count]) == n { return i + n.count }
        i += 1
    }
    return nil
}

/// The value after `"key":` inside `"section"` (no JSON parser needed).
func rawValue(_ bytes: [UInt8], key: String, after section: String) -> [UInt8]? {
    guard let s = find(bytes, "\"\(section)\""), var i = find(bytes, "\"\(key)\":", from: s) else { return nil }
    while i < bytes.count && bytes[i] == UInt8(ascii: " ") { i += 1 }
    var j = i
    if j < bytes.count && bytes[j] == UInt8(ascii: "\"") {
        j += 1
        while j < bytes.count && bytes[j] != UInt8(ascii: "\"") { j += 1 }
        return Array(bytes[(i + 1)..<j])
    }
    while j < bytes.count && (bytes[j] == UInt8(ascii: ".") || (bytes[j] >= 48 && bytes[j] <= 57)) { j += 1 }
    return j > i ? Array(bytes[i..<j]) : nil
}

func percent(_ bytes: [UInt8], after section: String) -> Int? {
    guard let raw = rawValue(bytes, key: "used_percentage", after: section) else { return nil }
    let text = String(decoding: raw, as: UTF8.self)
    return Int(text.split(separator: ".").first ?? "")
}

/// The default status line: model, context and plan usage.
func summary(_ payload: [UInt8]) -> String {
    var parts: [String] = []
    if let model = rawValue(payload, key: "display_name", after: "model") {
        parts.append(String(decoding: model, as: UTF8.self))
    }
    if let ctx = percent(payload, after: "context_window") { parts.append("ctx \(ctx)%") }
    if let five = percent(payload, after: "five_hour") { parts.append("5h \(five)%") }
    if let week = percent(payload, after: "seven_day") { parts.append("wk \(week)%") }
    return parts.joined(separator: " · ")
}

/// The controlling terminal (e.g. "/dev/ttys004"), inherited from Claude,
/// so the app can bring forward the exact tab.
func controllingTTY() -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, info.kp_eproc.e_tdev != -1,
        let name = devname(info.kp_eproc.e_tdev, S_IFCHR)
    else { return nil }
    let tty = String(cString: name)
    return tty.hasPrefix("tty") ? "/dev/" + tty : nil
}

func send(_ payload: [UInt8], kind: String?) {
    guard payload.first == UInt8(ascii: "{"), let path = socketPath(), let fd = connectSocket(path) else { return }
    // Envelope: the hook process inherits the terminal's environment, which
    // tells the app which window to bring forward when the session is clicked
    // (the Claude app's session id, or the terminal and its tty).
    var message = Array(
        "{\"v\":1,\"kind\":\(jsonString(kind)),\"term\":\(jsonString(env("TERM_PROGRAM"))),\"bundle\":\(jsonString(env("__CFBundleIdentifier"))),\"host\":\(jsonString(env("CLAUDE_CODE_HOST_SESSION_ID"))),\"tty\":\(jsonString(controllingTTY())),\"ppid\":\(getppid()),\"payload\":"
            .utf8)
    message.append(contentsOf: payload)
    message.append(contentsOf: Array("}\n".utf8))
    writeAll(fd, message)
    close(fd)
}

/// Replaces this process with `sh -c command`, feeding it `payload` on stdin.
func chain(to command: String, payload: [UInt8]) -> Never {
    var fds: [Int32] = [0, 0]
    if pipe(&fds) == 0 {
        writeAll(fds[1], payload)  // status-line JSON fits in the pipe buffer
        close(fds[1])
        dup2(fds[0], STDIN_FILENO)
        close(fds[0])
    }
    let args = ["/bin/sh", "-c", command]
    var cArgs = args.map { strdup($0) } + [nil]
    execv("/bin/sh", &cArgs)
    exit(0)
}

let arguments = CommandLine.arguments
let payload = readStdin()

if arguments.count > 1 && arguments[1] == "statusline" {
    send(payload, kind: "statusline")
    if arguments.count > 3 && arguments[2] == "--then" {
        chain(to: arguments[3], payload: payload)
    }
    print(summary(payload))
    exit(0)
}

send(payload, kind: nil)
exit(0)
