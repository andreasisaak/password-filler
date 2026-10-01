import Foundation
import Security

/// Code-signing identity of a running process, resolved from its PID and
/// validated against a requirement before any field is trusted.
struct CodeIdentity {
    /// `errSecSuccess` when the code was resolved, validated and its signing
    /// information read; the first failing `OSStatus` otherwise.
    let status: OSStatus
    /// Name of the step that produced a failing `status`, for logs.
    let failedStep: String
    let identifier: String?
    let teamIdentifier: String?

    static func resolve(pid: pid_t, requirement: SecRequirement) -> CodeIdentity {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            return failure(guestStatus, at: "SecCodeCopyGuestWithAttributes")
        }
        let validityStatus = SecCodeCheckValidity(code, [], requirement)
        guard validityStatus == errSecSuccess else {
            return failure(validityStatus, at: "SecCodeCheckValidity")
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return failure(staticStatus, at: "SecCodeCopyStaticCode")
        }
        // kSecCSSigningInformation is required for kSecCodeInfoTeamIdentifier.
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess, let dictionary = information as? [String: Any] else {
            return failure(informationStatus == errSecSuccess ? errSecCSInternalError : informationStatus,
                           at: "SecCodeCopySigningInformation")
        }
        return CodeIdentity(
            status: errSecSuccess,
            failedStep: "",
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }

    private static func failure(_ status: OSStatus, at step: String) -> CodeIdentity {
        CodeIdentity(status: status, failedStep: step, identifier: nil, teamIdentifier: nil)
    }
}
