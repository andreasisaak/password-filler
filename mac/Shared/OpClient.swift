import Foundation

/// Result of `op whoami`.
public enum WhoamiResult: Equatable, Sendable {
    case authenticated(account: String)
    case locked
    case noAccounts
    case timeout
    case unknown(stderr: String, exitCode: Int32)
}

public enum OpClientError: Error, Equatable {
    case binaryNotFound
    case decodingFailed(String)
    case processFailed(stderr: String, exitCode: Int32)
    case timeout(command: String)
}

/// Thin abstraction implemented by `OpClient`. Exists so that tests (and, if
/// ever needed, alternate backends) can substitute their own `whoami()` without
/// spawning the real 1Password CLI.
public protocol WhoamiProvider {
    func whoami() throws -> WhoamiResult
}

/// Wraps the `op` (1Password CLI) binary. Every call runs as a subprocess with
/// a 30 s timeout (matching the legacy Node-host).
///
/// Every public method that hits 1Password (`itemList`, `itemGet`) calls
/// `whoami()` first and bails out with a typed error on `.locked`, `.noAccounts`,
/// etc. — avoiding fragile stderr parsing on the real calls (decision D20).
public final class OpClient: WhoamiProvider {

    /// Bundle resource URL (`Contents/Resources/op`) if the binary ships inside the .app.
    private let bundledOpURL: URL?
    /// Account shorthand passed as `--account <value>` on every call.
    public let account: String?
    /// Timeout for each subprocess.
    public let timeout: TimeInterval

    /// Cached resolved path to the `op` binary (found via `resolveOpPath`).
    private var cachedOpPath: String?

    public init(
        bundledOpURL: URL? = Bundle.main.url(forResource: "op", withExtension: nil),
        account: String? = nil,
        timeout: TimeInterval = 60
    ) {
        self.bundledOpURL = bundledOpURL
        self.account = account
        self.timeout = timeout
    }

    // MARK: - Path resolution

    /// Order: bundled (`Contents/Resources/op`) → `/opt/homebrew/bin/op`
    /// → `/usr/local/bin/op` → `/opt/local/bin/op` → `PATH` lookup.
    public func resolveOpPath() throws -> String {
        if let cached = cachedOpPath { return cached }

        let candidates: [String] = [
            bundledOpURL?.path,
            "/opt/homebrew/bin/op",
            "/usr/local/bin/op",
            "/opt/local/bin/op",
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            cachedOpPath = candidate
            return candidate
        }

        // Fall back to `env PATH` lookup via `/usr/bin/env`.
        if let envPath = lookupInPath("op") {
            cachedOpPath = envPath
            return envPath
        }

        throw OpClientError.binaryNotFound
    }

    private func lookupInPath(_ binary: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":").map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - High-level commands

    public func whoami() throws -> WhoamiResult {
        let args = buildArgs(["whoami"])
        let result = try runProcess(args: args)
        return Self.parseWhoami(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    public func itemList(tag: String) throws -> [ItemSummary] {
        try preflight()
        let args = buildArgs(["item", "list", "--tags", tag])
        let result = try runProcess(args: args)
        guard result.exitCode == 0 else {
            throw OpClientError.processFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
        return try decode([ItemSummary].self, from: result.stdout)
    }

    public func itemGet(id: String) throws -> FullItem {
        let args = buildArgs(["item", "get", id])
        let result = try runProcess(args: args)
        guard result.exitCode == 0 else {
            throw OpClientError.processFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
        return try decode(FullItem.self, from: result.stdout)
    }

    /// `op whoami` as a soft preflight. Only `.noAccounts` is a hard stop —
    /// that's the authoritative signal that 1P access was revoked (FR-12a).
    /// `.locked` / `.unknown` / `.timeout` pass through so that the next real
    /// `op` call can establish a Desktop-App-Auth session via Touch-ID (which
    /// `op whoami` itself deliberately does NOT trigger).
    private func preflight() throws {
        switch try whoami() {
        case .authenticated, .locked, .timeout, .unknown:
            return
        case .noAccounts:
            throw OpClientError.processFailed(
                stderr: "no accounts configured (1Password access revoked?)",
                exitCode: -1
            )
        }
    }

    // MARK: - Error parsing (pure, unit-testable)

    /// Parses `op whoami` output into a `WhoamiResult`. Exposed as a pure function so
    /// error-detection can be covered by XCTest without spawning a real subprocess.
    ///
    /// Heuristics mirror what legacy `htpasswd-host.js` (and 1P support threads)
    /// observe in practice:
    ///   - locked: stderr contains "RequestDelegatedSession" or "session has expired"
    ///   - noAccounts: stderr contains "No accounts configured"
    public static func parseWhoami(stdout: String, stderr: String, exitCode: Int32) -> WhoamiResult {
        if exitCode == 0 {
            // `op whoami --format=json` returns an object like
            // {"url":"my.1password.com","email":"foo","user_uuid":"...","account_uuid":"..."}
            if let data = stdout.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let account = (obj["url"] ?? obj["account_uuid"]) as? String {
                return .authenticated(account: account)
            }
            return .authenticated(account: "")
        }

        let lower = stderr.lowercased()
        if lower.contains("no accounts configured") || lower.contains("no account") && lower.contains("configured") {
            return .noAccounts
        }
        if lower.contains("requestdelegatedsession") || lower.contains("session has expired")
            || lower.contains("session expired") || lower.contains("not currently signed in")
            || lower.contains("is not signed in")
        {
            return .locked
        }
        return .unknown(stderr: stderr, exitCode: exitCode)
    }

    // MARK: - Subprocess primitives

    private func buildArgs(_ command: [String]) -> [String] {
        var args = command
        if let account, !account.isEmpty {
            args.append(contentsOf: ["--account", account])
        }
        args.append(contentsOf: ["--format", "json"])
        return args
    }

    private func decode<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
        guard let data = stdout.data(using: .utf8) else {
            throw OpClientError.decodingFailed("non-utf8 stdout")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpClientError.decodingFailed(String(describing: error))
        }
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runProcess(args: [String]) throws -> ProcessResult {
        let opPath = try resolveOpPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: opPath)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Prepend well-known Homebrew paths so that the binary itself can find
        // its sibling libraries even when the parent process has a stripped PATH
        // (e.g. launchd-spawned Agent).
        var env = ProcessInfo.processInfo.environment
        let prepend = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        let existingPath = env["PATH"] ?? ""
        env["PATH"] = existingPath.isEmpty ? prepend : "\(prepend):\(existingPath)"
        process.environment = env

        try process.run()

        // Drain both pipes on background queues *while* the process runs —
        // the default macOS pipe buffer is only 64 KiB, and `op item list`
        // for ~30 items easily fills it. Waiting for exit before reading
        // deadlocks the subprocess on stdout write and costs us the whole
        // timeout budget.
        let stdoutData = ByteBox()
        let stderrData = ByteBox()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global().async {
            stdoutData.set(stdout.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            stderrData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        // Enforce timeout by scheduling a termination after `timeout` seconds.
        let timedOut = TimeoutFlag()
        let workItem = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)

        process.waitUntilExit()
        workItem.cancel()
        readGroup.wait()

        if timedOut.value {
            throw OpClientError.timeout(command: args.prefix(3).joined(separator: " "))
        }

        return ProcessResult(
            stdout: String(decoding: stdoutData.value, as: UTF8.self),
            stderr: String(decoding: stderrData.value, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
}

/// Thread-safe `Data` container for concurrent pipe drains.
private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = Data()
    var value: Data { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; _value = data }
}

/// Tiny thread-safe boolean used by `runProcess` to distinguish timeouts from real exits.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        _value = true
    }
}
