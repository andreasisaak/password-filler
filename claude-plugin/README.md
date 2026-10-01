# Password Filler for Claude Code

Claude Code plugin for [Password Filler](https://andreasisaak.github.io/password-filler/), the macOS app that fills HTTP Basic Auth (htaccess) logins from 1Password. With the plugin, Claude reaches htaccess-protected staging, dev and production sites without the credentials appearing in the conversation.

## What it adds

- **Skill `password-filler`** — tells Claude which path to take: open the URL in Chrome (the Password Filler extension answers the login), use Playwright MCP with `--extension` (needs the Playwright MCP Bridge extension in Chrome), or wrap curl, scripts and Playwright tests in `password-filler-mcp run`.
- **MCP server `password-filler`** — the `password-filler-mcp` command bundled with the app. Tool `list_hosts` returns the hostnames Password Filler covers, never credentials.

## Requirements

- macOS with Password Filler 1.5 or newer, running.
- In Password Filler: Settings → For AI Agents → Enable local MCP server. Turning the switch on creates the symlink `/usr/local/bin/password-filler-mcp` into the app (macOS asks for an administrator password once). Turning it off blocks all requests but keeps the symlink; remove it with `sudo rm /usr/local/bin/password-filler-mcp`.
- 1Password items tagged `.htaccess` with the site's URL.

## Installation

In Claude Code:

```text
/plugin marketplace add andreasisaak/password-filler
/plugin install password-filler@password-filler
```

## How `run` works

```bash
password-filler-mcp run --url https://staging.example.com/ -- sh -c 'curl -sS -u "$HTACCESS_USER:$HTACCESS_PASSWORD" https://staging.example.com/'
```

`run` fetches the credentials for the URL's host from Password Filler, exports them as `HTACCESS_USER` and `HTACCESS_PASSWORD`, and executes the command — the same pattern as `dotenvx run` or `op run`. Keep the single quotes around the `sh -c` script; with double quotes your shell expands the variables before `run` has set them. When `run` fails it exits with a fixed code (64 usage, 65 no matching 1Password item, 69 Password Filler not running, 77 switch off); the table in [`skills/password-filler/SKILL.md`](skills/password-filler/SKILL.md#when-run-fails) explains each.

## Security

The credentials do not reach the conversation on their own. A command started with `run` receives them and could print them; that is the same protection level as environment variables from `dotenvx`. The switch in Password Filler is consent, not a barrier against malicious software running as your user. While it is off, `run` exits with code 77 and `list_hosts` reports an error.

## License

GPL-3.0-or-later — see [LICENSE](../LICENSE).
