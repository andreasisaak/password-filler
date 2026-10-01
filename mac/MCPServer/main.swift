import Foundation
import Darwin

// password-filler-mcp
//
// No arguments: MCP server over stdio for Claude Code and other MCP clients
// (tool `list_hosts`, plus `instructions` on how to reach htaccess sites).
// `run --url <url> -- <command>`: exports the htaccess credentials for the
// URL's host to the command's environment. Both talk to the Agent over its
// Unix socket, which admits this binary as `SocketPeer.mcpClient` only while
// the "For AI Agents" switch is on. Design: specs/ai-agent-access/design.md.

// A client that quits mid-reply must surface as a write error, not SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let usage = """
    usage: password-filler-mcp                 MCP server on stdio
           password-filler-mcp run --url <http(s)-URL> -- <command> [args…]
    """

let client = AgentClient(socketURL: SocketFraming.agentSocketURL)
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case nil:
    // The binary lives in PasswordFiller.app/Contents/MacOS/ and is usually
    // started through the /usr/local/bin symlink.
    let appURL = Bundle.main.executableURL!.resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let version = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
        FileHandle.standardError.write(Data("password-filler-mcp: must run from inside PasswordFiller.app (no app bundle at \(appURL.path))\n".utf8))
        exit(EX_SOFTWARE)
    }
    let handler = MCPRequestHandler(serverVersion: version, hosts: { try client.hosts() })
    StdioServer(handler: handler).run()
    exit(0)
case "run":
    exit(RunCommand.execute(arguments: Array(arguments.dropFirst()), client: client))
default:
    FileHandle.standardError.write(Data("password-filler-mcp: unknown argument \(arguments[0])\n\(usage)\n".utf8))
    exit(EX_USAGE)
}
