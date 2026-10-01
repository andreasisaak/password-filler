import Foundation
import Darwin
import os.log

/// `password-filler-mcp run`: fetches the credentials for the URL's host from
/// the Agent, exports them as `HTACCESS_USER` / `HTACCESS_PASSWORD` and execs
/// the command (pattern of `dotenvx run` / `op run`). The values never reach
/// stdout or stderr.
///
/// Exit codes follow sysexits(3): 64 usage, 65 no matching item, 69 Agent not
/// running, 70 unexpected Agent reply, 77 switch off or binary rejected; 126 /
/// 127 when the command cannot be executed / found.
enum RunCommand {

    private static let log = Logger(subsystem: "app.passwordfiller.mcp", category: "run")

    /// Returns only on failure, with the exit code; on success the process
    /// image is replaced by the command.
    static func execute(arguments: [String], client: AgentClient) -> Int32 {
        let parsed: RunArguments
        do {
            parsed = try RunArguments.parse(arguments)
        } catch {
            printError("\(error)\n\(RunArguments.usage)")
            return EX_USAGE
        }

        let credentials: RunCredentials?
        do {
            credentials = try client.runCredentials(hostname: parsed.hostname)
        } catch let error as AgentClientError {
            log.error("run for \(parsed.hostname, privacy: .private) failed: \(String(describing: error), privacy: .public)")
            printError(MCPInstructions.message(for: error))
            return exitCode(for: error)
        } catch {
            log.error("run for \(parsed.hostname, privacy: .private) failed: \(String(describing: error), privacy: .public)")
            printError("could not ask Password Filler for credentials: \(error)")
            return EX_SOFTWARE
        }
        guard let credentials else {
            log.info("run for \(parsed.hostname, privacy: .private): no matching item")
            printError("no unique 1Password item tagged .htaccess matches \(parsed.hostname). "
                + "If the item exists, ask the user to click Refresh in the Password Filler menu bar; "
                + "if several items match this host, their hostnames need to be made distinct.")
            return EX_DATAERR
        }

        setenv("HTACCESS_USER", credentials.username, 1)
        setenv("HTACCESS_PASSWORD", credentials.password, 1)
        log.info("run for \(parsed.hostname, privacy: .private): exec \(parsed.command[0], privacy: .public)")

        let argv = parsed.command.map { strdup($0) } + [nil]
        execvp(parsed.command[0], argv)
        let execErrno = errno
        printError("cannot run \(parsed.command[0]): \(String(cString: strerror(execErrno)))")
        return execErrno == ENOENT ? 127 : 126
    }

    private static func exitCode(for error: AgentClientError) -> Int32 {
        switch error {
        case .unreachable: return EX_UNAVAILABLE
        case .disabled, .forbidden: return EX_NOPERM
        case .unexpectedResponse: return EX_SOFTWARE
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("password-filler-mcp run: \(message)\n".utf8))
    }
}
