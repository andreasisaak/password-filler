import Foundation
import os.log

/// stdio transport: one JSON-RPC message per line on stdin, one per line on
/// stdout. stdout carries protocol only; diagnostics go to the unified log.
/// Returns when stdin reaches EOF (the client quit) or stdout is closed.
struct StdioServer {

    let handler: MCPRequestHandler
    private let log = Logger(subsystem: "app.passwordfiller.mcp", category: "stdio")

    init(handler: MCPRequestHandler) {
        self.handler = handler
    }

    func run() {
        log.info("MCP server started (pid=\(getpid(), privacy: .public))")
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let response = handler.handle(line: Data(line.utf8)) else { continue }
            do {
                try FileHandle.standardOutput.write(contentsOf: response + Data("\n".utf8))
            } catch {
                log.error("stdout closed, exiting: \(String(describing: error), privacy: .public)")
                return
            }
        }
        log.info("stdin EOF, exiting")
    }
}
