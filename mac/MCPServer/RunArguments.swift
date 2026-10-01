import Foundation

enum RunArgumentsError: Error, Equatable, CustomStringConvertible {
    case missingURL
    case unexpectedArgument(String)
    case missingSeparator
    case missingCommand
    case invalidURL(String)

    var description: String {
        switch self {
        case .missingURL: return "missing --url <http(s)-URL>"
        case .unexpectedArgument(let argument): return "unexpected argument before --: \(argument)"
        case .missingSeparator: return "missing -- before the command"
        case .missingCommand: return "missing command after --"
        case .invalidURL(let url): return "not an http(s) URL with a host: \(url)"
        }
    }
}

/// Parsed form of `password-filler-mcp run --url <url> -- <command> [args…]`
/// (the arguments after `run`).
struct RunArguments: Equatable {
    let url: URL
    /// Lowercased host of `url` — what the Agent looks up.
    let hostname: String
    let command: [String]

    static let usage = "usage: password-filler-mcp run --url <http(s)-URL> -- <command> [args…]"

    static func parse(_ arguments: [String]) throws -> RunArguments {
        guard let separatorIndex = arguments.firstIndex(of: "--") else {
            throw RunArgumentsError.missingSeparator
        }
        let options = Array(arguments[..<separatorIndex])
        let command = Array(arguments[(separatorIndex + 1)...])

        guard options.first == "--url" else {
            throw options.isEmpty ? RunArgumentsError.missingURL : RunArgumentsError.unexpectedArgument(options[0])
        }
        guard options.count >= 2 else { throw RunArgumentsError.missingURL }
        guard options.count == 2 else { throw RunArgumentsError.unexpectedArgument(options[2]) }
        guard !command.isEmpty else { throw RunArgumentsError.missingCommand }

        let rawURL = options[1]
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            throw RunArgumentsError.invalidURL(rawURL)
        }
        return RunArguments(url: url, hostname: host.lowercased(), command: command)
    }
}
