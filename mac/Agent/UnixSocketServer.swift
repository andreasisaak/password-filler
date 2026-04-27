import Foundation
import Darwin
import os.log

/// AF_UNIX stream server that mirrors the legacy Chrome Native-Messaging protocol
/// (UInt32 little-endian length prefix + UTF-8 JSON body).
///
/// Wire-compatible with `host/htpasswd-host.js` (`git show HEAD~3`), so the
/// `pf-nmh-bridge` can keep speaking the same protocol it speaks to Chromium.
public final class UnixSocketServer {

    public static var defaultSocketURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("app.passwordfiller", isDirectory: true)
            .appendingPathComponent("daemon.sock", isDirectory: false)
    }

    private let socketURL: URL
    private let service: AgentService
    private let log = Logger(subsystem: "app.passwordfiller.agent", category: "socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "app.passwordfiller.agent.socket.accept")
    private let workQueue = DispatchQueue(label: "app.passwordfiller.agent.socket.work", attributes: .concurrent)

    public init(
        service: AgentService,
        socketURL: URL = UnixSocketServer.defaultSocketURL
    ) {
        self.service = service
        self.socketURL = socketURL
    }

    // MARK: - Lifecycle

    public func start() throws {
        try ensureSocketParentExists()

        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw SocketError.setup("socket() failed errno=\(errno)")
        }

        // Allow rebind after crash.
        var reuse: Int32 = 1
        _ = Darwin.setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Unlink any stale socket from a previous run.
        _ = Darwin.unlink(socketURL.path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < sunPathSize else {
            Darwin.close(socketFD)
            throw SocketError.setup("socket path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { cStr in
                _ = path.withCString { src in strcpy(cStr, src) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw SocketError.setup("bind() failed errno=\(errno)")
        }

        // User-only permissions on the socket file (defense in depth — Shared
        // Keychain + XPC are the real security boundaries).
        _ = Darwin.chmod(socketURL.path, 0o600)

        guard Darwin.listen(socketFD, 16) == 0 else {
            Darwin.close(socketFD)
            throw SocketError.setup("listen() failed errno=\(errno)")
        }

        listenFD = socketFD

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptLoop() }
        source.setCancelHandler { Darwin.close(socketFD) }
        source.resume()
        acceptSource = source

        log.info("UnixSocket listening on \(self.socketURL.path, privacy: .public)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
    }

    private func ensureSocketParentExists() throws {
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenFD, sockaddrPtr, &len)
                }
            }
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                log.error("accept() failed errno=\(errno, privacy: .public)")
                return
            }
            workQueue.async { [weak self] in
                self?.handleClient(socketFD: client)
            }
        }
    }

    // MARK: - Per-client handler

    private func handleClient(socketFD: Int32) {
        defer { Darwin.close(socketFD) }
        while let request = readFramed(socketFD: socketFD) {
            let response = dispatch(request: request)
            writeFramed(socketFD: socketFD, data: response)
        }
    }

    private func readFramed(socketFD: Int32) -> Data? {
        var header = Data(count: 4)
        guard readExact(socketFD: socketFD, into: &header, count: 4) else { return nil }
        let length = header.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).littleEndian
        }
        guard length > 0, length < 1_048_576 else { return nil } // 1 MiB cap
        var body = Data(count: Int(length))
        guard readExact(socketFD: socketFD, into: &body, count: Int(length)) else { return nil }
        return body
    }

    private func readExact(socketFD: Int32, into data: inout Data, count: Int) -> Bool {
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let got: Int = data.withUnsafeMutableBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: offset)
                return Darwin.read(socketFD, base, remaining)
            }
            if got <= 0 { return false }
            remaining -= got
            offset += got
        }
        return true
    }

    private func writeFramed(socketFD: Int32, data: Data) {
        var length = UInt32(data.count).littleEndian
        let headerData = Data(bytes: &length, count: 4)
        writeAll(socketFD: socketFD, data: headerData)
        writeAll(socketFD: socketFD, data: data)
    }

    private func writeAll(socketFD: Int32, data: Data) {
        var remaining = data.count
        var offset = 0
        while remaining > 0 {
            let sent = data.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: offset)
                return Darwin.write(socketFD, base, remaining)
            }
            if sent <= 0 { return }
            remaining -= sent
            offset += sent
        }
    }

    // MARK: - Dispatch

    /// Matches legacy `host/htpasswd-host.js` `handleMessage`:
    ///   - `list`/`refresh` → `{items: [...]}`
    ///   - `lookup` → `{found: true, username, password}` on hit, `{found: false}` on miss
    ///   - `config` → `{op_account: "…"}`
    ///   - `ping` → `{pong: true, cached: N}`
    ///   - unknown → `{error: "Unknown action: X"}`
    private func dispatch(request: Data) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
            return errorResponse("Invalid JSON")
        }
        let action = (json["action"] as? String) ?? ""

        switch action {
        case "ping":
            return encode([
                "pong": true,
                "cached": service.itemCount
            ])

        case "config":
            let cfg = service.currentConfig()
            return encode(["op_account": cfg.opAccount])

        case "lookup":
            guard let host = json["hostname"] as? String else {
                return errorResponse("Missing hostname")
            }
            if let match = service.lookup(host: host) {
                return encode([
                    "found": true,
                    "username": match.username,
                    "password": match.password
                ])
            }
            return encode(["found": false])

        case "list", "refresh":
            return handleListOrRefresh()

        default:
            return errorResponse("Unknown action: \(action)")
        }
    }

    /// Synchronously waits on the async refresh via a semaphore — the caller
    /// protocol is request/response and the client expects the items payload
    /// inline. 120 s covers Touch-ID (~user-speed) + parallel itemGet fan-out
    /// across all 31-ish items with comfortable headroom.
    private func handleListOrRefresh() -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var result: RefreshResult?
        Task { [service] in
            result = await service.performRefresh()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 120)

        let rows = service.displayRows()
        let items = rows.map { row -> [String: Any] in
            [
                "itemId": row.primaryItemId,
                "title": row.title,
                "hostnames": row.hostnames,
                "domains": row.domains,
                "sourceVaults": row.sourceVaults
            ]
        }
        var payload: [String: Any] = ["items": items]
        if let result, !result.success, let message = result.errorMessage {
            payload["error"] = message
        }
        return encode(payload)
    }

    private func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private func errorResponse(_ message: String) -> Data {
        encode(["error": message])
    }

    public enum SocketError: Error, Equatable {
        case setup(String)
    }
}
