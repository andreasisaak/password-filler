import XCTest

/// Covers `CommandLineToolStatus.evaluate` — how the Settings tab and the
/// launch repair read `/usr/local/bin/password-filler-mcp` (design.md D7).
final class CommandLineToolStatusTests: XCTestCase {

    private var directory: URL!
    private var linkPath: String { directory.appendingPathComponent("password-filler-mcp").path }
    private let target = "/Applications/PasswordFiller.app/Contents/MacOS/password-filler-mcp"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pf-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testNothingAtPathIsMissing() throws {
        XCTAssertEqual(try CommandLineToolStatus.evaluate(linkPath: linkPath, expectedTarget: target), .missing)
    }

    func testLinkToRunningBundleIsInstalledEvenWhenTargetIsAbsent() throws {
        // The target need not exist in the test; only the link text counts.
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        XCTAssertEqual(try CommandLineToolStatus.evaluate(linkPath: linkPath, expectedTarget: target), .installed)
    }

    func testLinkToMovedBundlePointsElsewhere() throws {
        let old = "/Users/someone/Applications/PasswordFiller.app/Contents/MacOS/password-filler-mcp"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: old)
        XCTAssertEqual(try CommandLineToolStatus.evaluate(linkPath: linkPath, expectedTarget: target),
                       .pointsElsewhere(destination: old))
    }

    func testRelativeLinkIsResolvedAgainstItsDirectory() throws {
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "../bin/tool")
        let expected = (directory.deletingLastPathComponent().appendingPathComponent("bin/tool").path as NSString).standardizingPath
        XCTAssertEqual(try CommandLineToolStatus.evaluate(linkPath: linkPath, expectedTarget: target),
                       .pointsElsewhere(destination: expected))
    }

    func testRegularFileIsBlocked() throws {
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: linkPath))
        XCTAssertEqual(try CommandLineToolStatus.evaluate(linkPath: linkPath, expectedTarget: target), .blockedByFile)
    }

    func testDirectoryIsBlocked() throws {
        try FileManager.default.createDirectory(atPath: linkPath, withIntermediateDirectories: false)
        XCTAssertEqual(try CommandLineToolStatus.evaluate(linkPath: linkPath, expectedTarget: target), .blockedByFile)
    }
}
