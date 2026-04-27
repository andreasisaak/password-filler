import XCTest

final class OpClientTests: XCTestCase {

    // MARK: - parseWhoami (pure function, no subprocess)

    func testParseWhoamiSuccessReturnsAuthenticated() {
        let stdout =
            #"{"url":"team.1password.com","email":"user@example.com","# +
            #""user_uuid":"ABC","account_uuid":"XYZ"}"#
        let result = OpClient.parseWhoami(stdout: stdout, stderr: "", exitCode: 0)
        XCTAssertEqual(result, .authenticated(account: "team.1password.com"))
    }

    func testParseWhoamiSuccessWithoutURLFallsBackToUUID() {
        let stdout = #"{"account_uuid":"XYZ"}"#
        let result = OpClient.parseWhoami(stdout: stdout, stderr: "", exitCode: 0)
        XCTAssertEqual(result, .authenticated(account: "XYZ"))
    }

    func testParseWhoamiLockedFromRequestDelegatedSession() {
        let stderr = "[ERROR] 2026/04/21 16:15:00 RequestDelegatedSession failed: session has expired"
        let result = OpClient.parseWhoami(stdout: "", stderr: stderr, exitCode: 1)
        XCTAssertEqual(result, .locked)
    }

    func testParseWhoamiLockedFromSessionExpiredMessage() {
        let stderr = "[ERROR] session has expired, please sign in again"
        let result = OpClient.parseWhoami(stdout: "", stderr: stderr, exitCode: 1)
        XCTAssertEqual(result, .locked)
    }

    func testParseWhoamiNoAccounts() {
        let stderr = "[ERROR] No accounts configured. Run `op account add` first."
        let result = OpClient.parseWhoami(stdout: "", stderr: stderr, exitCode: 1)
        XCTAssertEqual(result, .noAccounts)
    }

    func testParseWhoamiAccountIsNotSignedIn() {
        // `op` started emitting this phrasing when the account metadata is
        // still on disk but the desktop-app-auth session is gone. Commit
        // 799aec7 reclassified it from `.unknown` to `.locked` so the popover
        // shows the right "1Password gesperrt" hint instead of a vague
        // "Unbekannter Fehler". Test guards against regressing to the old
        // classification.
        let stderr = "[ERROR] account team.1password.com is not signed in"
        let result = OpClient.parseWhoami(stdout: "", stderr: stderr, exitCode: 1)
        XCTAssertEqual(result, .locked)
    }

    func testParseWhoamiNotCurrentlySignedIn() {
        // Sister phrasing from the same 1P-CLI error family as
        // `testParseWhoamiAccountIsNotSignedIn` — `op` has used both forms
        // across minor versions. Both must map to `.locked`.
        let stderr = "[ERROR] you are not currently signed in to any accounts"
        let result = OpClient.parseWhoami(stdout: "", stderr: stderr, exitCode: 1)
        XCTAssertEqual(result, .locked)
    }

    func testParseWhoamiUnknownErrorIsPreserved() {
        let stderr = "[ERROR] network unreachable"
        let result = OpClient.parseWhoami(stdout: "", stderr: stderr, exitCode: 6)
        if case let .unknown(capturedStderr, capturedExit) = result {
            XCTAssertEqual(capturedStderr, stderr)
            XCTAssertEqual(capturedExit, 6)
        } else {
            XCTFail("Expected .unknown, got \(result)")
        }
    }

    // MARK: - Path resolution

    func testBinaryNotFoundWhenNoCandidateExists() throws {
        // Use a bogus bundled URL in a temp dir that definitely doesn't contain `op`.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let client = OpClient(
            bundledOpURL: tmpDir.appendingPathComponent("op"),
            account: nil,
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
}
