import XCTest

final class OpClientTests: XCTestCase {

    // MARK: - Path resolution

    func testBinaryNotFoundWhenNoCandidateExists() throws {
        // Use a bogus bundled URL in a temp dir that definitely doesn't contain `op`.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let client = OpClient(
            bundledOpURL: tmpDir.appendingPathComponent("op"),
            timeout: 5
        )

        // Simulate empty PATH so system-wide candidates don't interfere.
        let oldPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "/nonexistent", 1)
        defer {
            if let old = oldPath { setenv("PATH", old, 1) } else { unsetenv("PATH") }
        }

        // This test can only assert binaryNotFound if the host dev machine does NOT have
        // `op` installed in standard Homebrew/MacPorts locations. We skip if it's present.
        let standardPaths = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/opt/local/bin/op"]
        guard !standardPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Skipped — `op` is installed system-wide on this machine")
        }

        XCTAssertThrowsError(try client.resolveOpPath()) { error in
            XCTAssertEqual(error as? OpClientError, .binaryNotFound)
        }
    }

    // MARK: - Account resolution (pure policy, no subprocess)

    private static let businessAccount = OpAccount(
        url: "louis-internet.1password.com",
        email: "isaak@louis.info",
        userId: "U5LD53POUBF5RGGWLCAAJD7IXE",
        accountId: "ACCT-LOUIS"
    )
    private static let personalAccount = OpAccount(
        url: "my.1password.com",
        email: "andy.jared@googlemail.com",
        userId: "B3LXZYKGGNC27PBEILATJT6EEA",
        accountId: "ACCT-PERSONAL"
    )

    func testResolveAccountReturnsMatchByURL() throws {
        let resolved = try OpClient.resolveAccount(
            configured: "louis-internet.1password.com",
            accounts: [Self.personalAccount, Self.businessAccount]
        )
        XCTAssertEqual(resolved, "louis-internet.1password.com")
    }

    func testResolveAccountMatchesByEmailAndAccountId() throws {
        let byEmail = try OpClient.resolveAccount(
            configured: "isaak@louis.info",
            accounts: [Self.personalAccount, Self.businessAccount]
        )
        XCTAssertEqual(byEmail, "louis-internet.1password.com")

        let byAccountId = try OpClient.resolveAccount(
            configured: "ACCT-LOUIS",
            accounts: [Self.personalAccount, Self.businessAccount]
        )
        XCTAssertEqual(byAccountId, "louis-internet.1password.com")
    }

    func testResolveAccountSelfHealsStaleConfigWhenOnlyOneAccount() throws {
        // Sven's case: config carries a wrong `op_account` from an old install,
        // but `op` knows exactly one account — resolve to it instead of failing.
        let resolved = try OpClient.resolveAccount(
            configured: "louis-internet.1password.com",
            accounts: [Self.personalAccount]
        )
        XCTAssertEqual(resolved, "my.1password.com")
    }

    func testResolveAccountThrowsWhenStaleConfigAndMultipleAccounts() {
        // No safe guess possible — wrong pick could fill the wrong vault.
        XCTAssertThrowsError(
            try OpClient.resolveAccount(
                configured: "nonexistent.1password.com",
                accounts: [Self.personalAccount, Self.businessAccount]
            )
        ) { error in
            guard case OpClientError.accountUnavailable = error else {
                return XCTFail("Expected .accountUnavailable, got \(error)")
            }
        }
    }

    func testResolveAccountUsesSingleAccountWhenConfigEmpty() throws {
        XCTAssertEqual(
            try OpClient.resolveAccount(configured: "", accounts: [Self.businessAccount]),
            "louis-internet.1password.com"
        )
        XCTAssertEqual(
            try OpClient.resolveAccount(configured: "", accounts: [Self.personalAccount]),
            "my.1password.com"
        )
    }

    func testResolveAccountThrowsWhenConfigEmptyAndMultipleAccounts() {
        XCTAssertThrowsError(
            try OpClient.resolveAccount(
                configured: "",
                accounts: [Self.personalAccount, Self.businessAccount]
            )
        ) { error in
            guard case OpClientError.accountUnavailable = error else {
                return XCTFail("Expected .accountUnavailable, got \(error)")
            }
        }
    }

    func testResolveAccountThrowsWhenNoAccountsExist() {
        XCTAssertThrowsError(
            try OpClient.resolveAccount(configured: "team.1password.com", accounts: [])
        ) { error in
            guard case OpClientError.accountUnavailable = error else {
                return XCTFail("Expected .accountUnavailable, got \(error)")
            }
        }
    }
}
