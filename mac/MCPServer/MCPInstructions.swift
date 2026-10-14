import Foundation

/// Model-facing texts of `password-filler-mcp`: the `instructions` field of
/// the MCP `initialize` result and the error messages shared by `list_hosts`
/// and `run`. English — Claude reads them. Keep in sync with
/// `claude-plugin/skills/password-filler/SKILL.md`.
enum MCPInstructions {

    static let text = """
        Password Filler holds the user's HTTP Basic Auth (htaccess) credentials from 1Password. \
        You never need, ask for, or see them. \
        Claude in Chrome: just open the protected URL — the Password Filler extension answers the login \
        of `https://` pages before any dialog appears (never over plain `http://`); never ask the user to log in. \
        Playwright MCP: works only when started with `--extension`; its own fresh browser gets 401. \
        curl, scripts, Playwright tests: `password-filler-mcp run --url <url> -- sh -c '<command using \
        "$HTACCESS_USER" and "$HTACCESS_PASSWORD">'` — always single quotes around the sh -c script, \
        never print the variables. \
        A 401 from curl or a script usually means the request went out without credentials: \
        repeat it through run before reporting it. \
        Use `list_hosts` to see which hosts are covered; subdomains of a listed domain usually match too.
        """

    static func message(for error: AgentClientError) -> String {
        switch error {
        case .unreachable:
            return "Password Filler is not running (its agent socket is unreachable). "
                + "Ask the user to start PasswordFiller.app, then retry."
        case .disabled:
            return "Password Filler's local MCP server is switched off. Ask the user to turn on "
                + "Password Filler → Settings → For AI Agents → Enable local MCP server "
                + "(German UI: Einstellungen → Für KI-Agenten → Lokalen MCP-Server aktivieren), then retry."
        case .forbidden:
            return "The Password Filler agent did not accept this password-filler-mcp binary "
                + "(or restarted mid-request). Ask the user to update or reinstall Password Filler."
        case .unexpectedResponse(let detail):
            return "Password Filler answered unexpectedly (\(detail)). Ask the user to update Password Filler."
        }
    }
}
