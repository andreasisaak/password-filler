import Foundation
import Darwin

public enum SocketFramingError: Error, Equatable {
    /// `connect()` to the Agent socket failed — the Agent is not running.
    case unreachable(errno: Int32)
    /// The Agent closed the connection mid-frame, or a write failed.
    case connectionBroken
    /// A frame header announced zero bytes or more than `maxFrameBytes`.
    case invalidFrameLength(UInt32)
}

/// Client side of the Agent's Unix-socket protocol: UInt32 little-endian
/// length header followed by a UTF-8 JSON body, same as `UnixSocketServer`
/// and `pf-nmh-bridge`. Used by `password-filler-mcp`; the bridge and the
/// server keep their own copies so this file cannot change them.
public enum SocketFraming {

    public static let maxFrameBytes: UInt32 = 1_048_576

    public static var agentSocketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("app.passwordfiller", isDirectory: true)
            .appendingPathComponent("daemon.sock", isDirectory: false)
    }

    /// Opens one connection, sends `request`, reads one response frame and
    /// closes the connection.
    public static func exchange(_ request: Data, at socketURL: URL) throws -> Data {
        let socketFD = try connect(to: socketURL)
        defer { Darwin.close(socketFD) }
        try writeFrame(request, to: socketFD)
        return try readFrame(from: socketFD)
    }

    static func connect(to socketURL: URL) throws -> Int32 {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SocketFramingError.unreachable(errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        precondition(path.utf8.count < pathCapacity, "socket path too long: \(path)")
        withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
            tuplePointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                _ = path.withCString { strcpy(destination, $0) }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let connectErrno = errno
            Darwin.close(socketFD)
            throw SocketFramingError.unreachable(errno: connectErrno)
        }
        return socketFD
    }

    static func writeFrame(_ body: Data, to socketFD: Int32) throws {
        var length = UInt32(body.count).littleEndian
        try writeAll(Data(bytes: &length, count: 4), to: socketFD)
        try writeAll(body, to: socketFD)
    }

    static func readFrame(from socketFD: Int32) throws -> Data {
        let header = try readExact(count: 4, from: socketFD)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length < maxFrameBytes else {
            throw SocketFramingError.invalidFrameLength(length)
        }
        return try readExact(count: Int(length), from: socketFD)
    }

    private static func writeAll(_ data: Data, to socketFD: Int32) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { raw in
                Darwin.write(socketFD, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard sent > 0 else { throw SocketFramingError.connectionBroken }
            offset += sent
        }
    }

    private static func readExact(count: Int, from socketFD: Int32) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(socketFD, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            guard received > 0 else { throw SocketFramingError.connectionBroken }
            offset += received
        }
        return buffer
    }
}
