import XCTest

/// Covers `BridgeParentPolicy.verdict` — the D25 rule the Agent applies to the
/// parent of every connecting `pf-nmh-bridge`, so only a supported browser can
/// make the bridge ask for credentials.
final class BridgeParentPolicyTests: XCTestCase {

    func testEverySupportedBrowserIsAllowed() {
        for browser in SupportedBrowsers.all {
            XCTAssertEqual(
                BridgeParentPolicy.verdict(
                    identifier: browser.bundleIdentifier,
                    teamIdentifier: browser.teamIdentifier,
                    signatureStatus: errSecSuccess
                ),
                .allowed,
                browser.bundleIdentifier
            )
        }
    }

    func testSupportedIdentifierWithForeignTeamIsRejected() {
        // A re-signed copy of Chrome keeps the identifier but not Google's Team ID.
        XCTAssertEqual(
            BridgeParentPolicy.verdict(identifier: "com.google.Chrome", teamIdentifier: "A5278RL7RX", signatureStatus: errSecSuccess),
            .rejected(reason: "parent com.google.Chrome (Team ID A5278RL7RX) is not a supported browser")
        )
    }

    func testOtherAppOfSupportedTeamIsRejected() {
        // Same Google Team ID, but not a browser that may spawn the bridge.
        XCTAssertEqual(
            BridgeParentPolicy.verdict(identifier: "com.google.drivefs", teamIdentifier: "EQHXZ8M8AV", signatureStatus: errSecSuccess),
            .rejected(reason: "parent com.google.drivefs (Team ID EQHXZ8M8AV) is not a supported browser")
        )
    }

    func testPlatformBinaryWithoutTeamIsRejected() {
        // Shells and launchd (bridge re-parented after its browser exited)
        // are Apple platform binaries without a Team ID.
        XCTAssertEqual(
            BridgeParentPolicy.verdict(identifier: "com.apple.zsh", teamIdentifier: nil, signatureStatus: errSecSuccess),
            .rejected(reason: "parent com.apple.zsh has no Team ID")
        )
    }

    func testMissingIdentifierIsRejected() {
        XCTAssertEqual(
            BridgeParentPolicy.verdict(identifier: nil, teamIdentifier: "EQHXZ8M8AV", signatureStatus: errSecSuccess),
            .rejected(reason: "parent has no signing identifier")
        )
    }

    func testSignatureFailureIsRejectedEvenForSupportedIdentity() {
        // errSecCSReqFailed: unsigned or ad-hoc signed parent.
        XCTAssertEqual(
            BridgeParentPolicy.verdict(identifier: "com.google.Chrome", teamIdentifier: "EQHXZ8M8AV", signatureStatus: errSecCSReqFailed),
            .rejected(reason: "parent signature check failed (OSStatus \(errSecCSReqFailed))")
        )
    }
}
