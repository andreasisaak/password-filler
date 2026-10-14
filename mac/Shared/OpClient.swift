import Foundation

public enum OpClientError: Error, Equatable {
    case binaryNotFound
    case decodingFailed(String)
    case processFailed(stderr: String, exitCode: Int32)
    case timeout(command: String)
    /// The configured `op_account` cannot be reconciled with the accounts `op`
    /// actually knows, and the choice is genuinely ambiguous. The associated
    /// string is a user-facing, actionable message.
    case accountUnavailable(String)
}

/// One entry from `op account list --format=json` (`user_uuid` / `account_uuid`).
public struct OpAccount: Decodable, Equatable, Sendable {
    public let url: String
    public let email: String
    public let userId: String
    public let accountId: String

    enum CodingKeys: String, CodingKey {
        case url
        case email
        case userId = "user_uuid"
        case accountId = "account_uuid"
    }

    public init(url: String, email: String, userId: String, accountId: String) {
        self.url = url
        self.email = email
        self.userId = userId
        self.accountId = accountId
    }

    /// True when `identifier` exactly equals one of this account's identifying
    /// strings — the same set `op --account <value>` accepts as a filter.
    public func matches(_ identifier: String) -> Bool {
        [url, email, userId, accountId].contains(identifier)
    }
}

/// Wraps the `op` (1Password CLI) binary. Every call runs as a subprocess with
/// a timeout (`timeout`, default 60 s).
public final class OpClient {

    /// Bundle resource URL (`Contents/Resources/op`) if the binary ships inside the .app.
    private let bundledOpURL: URL?
    /// Timeout for each subprocess.
    public let timeout: TimeInterval

    /// Cached resolved path to the `op` binary (found via `resolveOpPath`).
    private var cachedOpPath: String?

    public init(
        bundledOpURL: URL? = Bundle.main.url(forResource: "op", withExtension: nil),
        timeout: TimeInterval = 60
    ) {
        self.bundledOpURL = bundledOpURL
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

    /// Lists every account `op` knows. Runs without an `--account` filter, so
    /// it works even while accounts are locked or signed out — which is
    /// exactly the state we recover from when `op_account` is stale
    /// (`resolveAccountArgument`).
    public func listAccounts() throws -> [OpAccount] {
        let args = buildArgs(["account", "list"], account: nil)
        let result = try runProcess(args: args)
        guard result.exitCode == 0 else {
            throw OpClientError.processFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
        return try decode([OpAccount].self, from: result.stdout)
    }

    /// Reconciles the configured `op_account` hint (empty = none) against the
    /// accounts `op` actually knows and returns the `--account` value to use
    /// for this refresh. Throws `accountUnavailable` only when the choice is
    /// genuinely ambiguous: picking the wrong account could fill credentials
    /// from the wrong vault, so we refuse to guess.
    public func resolveAccountArgument(configured: String) throws -> String {
        try Self.resolveAccount(configured: configured, accounts: try listAccounts())
    }

    /// Pure resolution policy — exposed so it can be unit-tested without
    /// spawning a real `op` subprocess. See `resolveAccountArgument`.
    public static func resolveAccount(configured: String, accounts: [OpAccount]) throws -> String {
        guard let onlyAccount = accounts.first else {
            throw OpClientError.accountUnavailable(
                "No 1Password account is available. Open 1Password and sign in.")
        }

        if !configured.isEmpty {
            if let match = accounts.first(where: { $0.matches(configured) }) {
                return match.url
            }
            // Configured value matches nothing `op` knows.
            if accounts.count == 1 {
                // Only one real account exists — the config is stale; heal to it.
                return onlyAccount.url
            }
            throw OpClientError.accountUnavailable(
                "1Password account \"\(configured)\" was not found. "
                + "Available: \(accounts.map(\.url).joined(separator: ", ")). "
                + "Pick the right one in Settings.")
        }

        // No hint configured.
        if accounts.count == 1 { return onlyAccount.url }
        throw OpClientError.accountUnavailable(
            "Several 1Password accounts are available "
            + "(\(accounts.map(\.url).joined(separator: ", "))). "
            + "Choose one in Settings.")
    }

    public func itemList(tag: String, account: String) throws -> [ItemSummary] {
        let args = buildArgs(["item", "list", "--tags", tag], account: account)
        let result = try runProcess(args: args)
        guard result.exitCode == 0 else {
            throw OpClientError.processFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
        return try decode([ItemSummary].self, from: result.stdout)
    }

    public func itemGet(id: String, account: String) throws -> FullItem {
        let args = buildArgs(["item", "get", id], account: account)
        let result = try runProcess(args: args)
        guard result.exitCode == 0 else {
            throw OpClientError.processFailed(stderr: result.stderr, exitCode: result.exitCode)
        }
        return try decode(FullItem.self, from: result.stdout)
    }

    // MARK: - Subprocess primitives

    private func buildArgs(_ command: [String], account: String?) -> [String] {
        var args = command
        if let account {
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
