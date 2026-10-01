import Foundation

/// State of the `/usr/local/bin/password-filler-mcp` symlink that puts the
/// bundled MCP binary on the user's `PATH` (design.md D7).
public enum CommandLineToolStatus: Equatable {
    /// Symlink pointing at the binary inside the running app bundle.
    case installed
    /// Nothing at the link path.
    case missing
    /// Symlink to another location — an old or moved app bundle.
    case pointsElsewhere(destination: String)
    /// A regular file or directory sits at the link path. It belongs to
    /// someone else and is never replaced.
    case blockedByFile

    /// Reads the link path without following the symlink. Throws on any
    /// file-system error other than "does not exist".
    public static func evaluate(linkPath: String, expectedTarget: String) throws -> CommandLineToolStatus {
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: linkPath)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .blockedByFile
        }
        let rawDestination = try fileManager.destinationOfSymbolicLink(atPath: linkPath)
        let destination = rawDestination.hasPrefix("/")
            ? rawDestination
            : (linkPath as NSString).deletingLastPathComponent + "/" + rawDestination
        let standardizedDestination = (destination as NSString).standardizingPath
        guard standardizedDestination == (expectedTarget as NSString).standardizingPath else {
            return .pointsElsewhere(destination: standardizedDestination)
        }
        return .installed
    }
}
