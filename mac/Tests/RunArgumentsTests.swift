import XCTest

/// Covers `RunArguments.parse` — the argument contract of
/// `password-filler-mcp run --url <url> -- <command> [args…]` (FR-E5).
final class RunArgumentsTests: XCTestCase {

    func testValidInvocationParsesURLHostAndCommand() throws {
        let parsed = try RunArguments.parse(["--url", "https://Staging.Example.com/path?q=1", "--", "curl", "-s", "https://staging.example.com/"])
        XCTAssertEqual(parsed, RunArguments(
            url: URL(string: "https://Staging.Example.com/path?q=1")!,
            hostname: "staging.example.com",
            command: ["curl", "-s", "https://staging.example.com/"]
        ))
    }

    func testArgumentsWithSpacesStaySeparate() throws {
        let parsed = try RunArguments.parse(["--url", "http://a.example.com", "--", "sh", "-c", "curl -u \"$HTACCESS_USER:$HTACCESS_PASSWORD\" x"])
        XCTAssertEqual(parsed.command, ["sh", "-c", "curl -u \"$HTACCESS_USER:$HTACCESS_PASSWORD\" x"])
    }

    func testLaterDoubleDashBelongsToTheCommand() throws {
        let parsed = try RunArguments.parse(["--url", "https://a.example.com", "--", "git", "log", "--", "file"])
        XCTAssertEqual(parsed.command, ["git", "log", "--", "file"])
    }

    func testMissingURLIsRejected() {
        XCTAssertThrowsError(try RunArguments.parse(["--", "curl"])) { error in
            XCTAssertEqual(error as? RunArgumentsError, .missingURL)
        }
        XCTAssertThrowsError(try RunArguments.parse(["--url", "--", "curl"])) { error in
            XCTAssertEqual(error as? RunArgumentsError, .missingURL)
        }
    }

    func testMissingSeparatorIsRejected() {
        XCTAssertThrowsError(try RunArguments.parse(["--url", "https://a.example.com", "curl"])) { error in
            XCTAssertEqual(error as? RunArgumentsError, .missingSeparator)
        }
    }

    func testEmptyCommandIsRejected() {
        XCTAssertThrowsError(try RunArguments.parse(["--url", "https://a.example.com", "--"])) { error in
            XCTAssertEqual(error as? RunArgumentsError, .missingCommand)
        }
    }

    func testUnexpectedOptionIsRejected() {
        XCTAssertThrowsError(try RunArguments.parse(["--url", "https://a.example.com", "--verbose", "--", "curl"])) { error in
            XCTAssertEqual(error as? RunArgumentsError, .unexpectedArgument("--verbose"))
        }
    }

    func testNonHTTPSchemeIsRejected() {
        XCTAssertThrowsError(try RunArguments.parse(["--url", "ftp://a.example.com", "--", "curl"])) { error in
            XCTAssertEqual(error as? RunArgumentsError, .invalidURL("ftp://a.example.com"))
        }
    }

    func testURLWithoutHostIsRejected() {
        for url in ["https://", "staging.example.com", "https:///path"] {
            XCTAssertThrowsError(try RunArguments.parse(["--url", url, "--", "curl"]), url) { error in
                XCTAssertEqual(error as? RunArgumentsError, .invalidURL(url), url)
            }
        }
    }
}
