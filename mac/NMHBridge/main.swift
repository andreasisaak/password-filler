import Foundation
import AppKit
import Darwin

// pf-nmh-bridge
//
// Chrome/Firefox/Brave Native Messaging Host. Proxies length-prefixed JSON
// messages between the browser (stdio) and the Agent (AF_UNIX stream socket
// at ~/Library/Application Support/app.passwordfiller/daemon.sock).
//
// Wire format is identical on both sides: UInt32 little-endian length header
// followed by a UTF-8 JSON body. Bodies are forwarded byte-for-byte — the
// bridge never parses JSON.
//
// FR-26 silent-fail: if the Agent cannot be reached, respond
// {"error":"agent_unreachable"} with the same framing. The extension treats
// that as "fall back to the browser's native Basic-Auth dialog".
//
// D24 stale-bridge self-healing: the browser keeps this process alive for as
// long as it runs — days or weeks — so an app update swaps the bundle
// underneath us while we keep serving. Once the Agent restarts or rejects us
// at its code-signing gate, an established connection breaks mid-request. We
// then exit instead of reconnecting: the browser fires `port.onDisconnect`,
// and the extension spawns a fresh bridge from the current bundle on its next
// request. Reconnecting from a stale process would keep it alive forever.

let socketPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent("Library/Application Support/app.passwordfiller/daemon.sock", isDirectory: false)
        .path
}()

let mainAppURL = URL(fileURLWithPath: "/Applications/PasswordFiller.app")

let maxFrameBytes: UInt32 = 1_048_576 // 1 MiB, matches UnixSocketServer cap

func log(_ message: @autoclosure () -> String) {
    // Chrome surfaces NMH stderr in chrome://extensions devtools for the
    // background worker; helpful for field diagnostics without leaking to
    // the extension protocol.
    FileHandle.standardError.write(Data("[pf-nmh-bridge] \(message())\n".utf8))
}

// MARK: - Framing (matches UnixSocketServer)

func readExact(fd: Int32, count: Int) -> Data? {
    var buf = Data(count: count)
    var offset = 0
    while offset < count {
        let got: Int = buf.withUnsafeMutableBytes { raw -> Int in
            let base = raw.baseAddress!.advanced(by: offset)
            return Darwin.read(fd, base, count - offset)
        }
        if got <= 0 { return nil }
        offset += got
    }
    return buf
}

func writeAll(fd: Int32, data: Data) -> Bool {
    var offset = 0
    let total = data.count
    while offset < total {
        let sent = data.withUnsafeBytes { raw -> Int in
            let base = raw.baseAddress!.advanced(by: offset)
            return Darwin.write(fd, base, total - offset)
        }
        if sent <= 0 { return false }
        offset += sent
    }
    return true
}

func readFramed(fd: Int32) -> Data? {
    guard let header = readExact(fd: fd, count: 4) else { return nil }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length > 0, length < maxFrameBytes else {
        log("frame rejected (length=\(length))")
        return nil
    }
    return readExact(fd: fd, count: Int(length))
}

func writeFramed(fd: Int32, body: Data) -> Bool {
    var length = UInt32(body.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    return writeAll(fd: fd, data: header) && writeAll(fd: fd, data: body)
}

// MARK: - Unix socket

func connectSocket() -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return -1 }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
    if socketPath.utf8.count >= sunPathSize {
        Darwin.close(fd)
        log("socket path too long: \(socketPath)")
        return -1
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { cStr in
            _ = socketPath.withCString { strcpy(cStr, $0) }
        }
    }

    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 {
        Darwin.close(fd)
        return -1
    }
    return fd
}

func launchMainApp() {
    log("launching Main-App at \(mainAppURL.path)")
    NSWorkspace.shared.open(mainAppURL)
}

let agentUnreachableBody = Data(#"{"error":"agent_unreachable"}"#.utf8)

/// An established Agent connection broke mid-request (Agent restarted, or it
/// rejected this process at its code-signing gate — see the D24 note above).
/// Reply to the in-flight request so the extension falls back immediately,
/// then exit so the browser respawns a fresh bridge from the current bundle.
func exitAfterBrokenConnection(socketFD: Int32, reason: String) -> Never {
    log("\(reason), exiting so the browser respawns a fresh bridge")
    _ = writeFramed(fd: stdoutFD, body: agentUnreachableBody)
    Darwin.close(socketFD)
    exit(1)
}

// MARK: - Main loop

let stdinFD = FileHandle.standardInput.fileDescriptor
let stdoutFD = FileHandle.standardOutput.fileDescriptor

// A write to a socket the Agent already closed (Agent restart) or to a stdout
// the browser already closed must surface as EPIPE, not SIGPIPE — the default
// action would kill us before we can reply to the in-flight request and log
// why we exit. Both branches below rely on `writeFramed` returning `false`.
signal(SIGPIPE, SIG_IGN)

var socketFD: Int32 = connectSocket()
var launchAttempted = false

if socketFD < 0 {
    launchMainApp()
    launchAttempted = true
    Thread.sleep(forTimeInterval: 2.0)
    socketFD = connectSocket()
    if socketFD < 0 {
        log("Agent still unreachable after launch+retry")
    }
}

log("started (socket=\(socketFD >= 0 ? "connected" : "unreachable"), pid=\(getpid()))")

while let request = readFramed(fd: stdinFD) {
    if socketFD < 0 {
        socketFD = connectSocket()
        if socketFD < 0 && !launchAttempted {
            launchMainApp()
            launchAttempted = true
            Thread.sleep(forTimeInterval: 2.0)
            socketFD = connectSocket()
        }
    }

    if socketFD < 0 {
        _ = writeFramed(fd: stdoutFD, body: agentUnreachableBody)
        continue
    }

    if !writeFramed(fd: socketFD, body: request) {
        exitAfterBrokenConnection(socketFD: socketFD, reason: "socket write failed")
    }

    guard let response = readFramed(fd: socketFD) else {
        exitAfterBrokenConnection(socketFD: socketFD, reason: "socket read failed")
    }

    if !writeFramed(fd: stdoutFD, body: response) {
        log("stdout closed, exiting")
        break
    }
}

if socketFD >= 0 {
    Darwin.close(socketFD)
}
log("stdin EOF, exiting cleanly")
exit(0)
