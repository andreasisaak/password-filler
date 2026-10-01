---
name: password-filler
description: |
  This skill should be used when a page, staging, dev or production site, URL, curl call,
  script or Playwright run hits HTTP Basic Auth, htaccess or a 401 — including a plain status
  check that returns 401 — and before reporting a 401, telling the user a protected site cannot
  be reached, or asking them to log in.
  Password Filler supplies the credentials from 1Password without exposing them: Chrome,
  Playwright MCP with --extension, and `password-filler-mcp run` for scripts.
license: GPL-3.0-or-later
compatibility: Claude Code on macOS with Password Filler (PasswordFiller.app) installed and its "For AI Agents" switch on
metadata:
  author: Andreas Isaak
  version: 1.0.0
---

# Reaching htaccess-protected sites with Password Filler

Password Filler is a macOS app that holds the user's HTTP Basic Auth (htaccess)
credentials from 1Password and answers the login for them. You never need, ask
for, or see a username or password — so do not ask the user to log in, and do not
assume a protected site is out of reach. Pick the path that matches the tool you
are using:

| Tool | What to do |
|---|---|
| Claude in Chrome | Open the URL. The Password Filler extension answers the login before any dialog appears. |
| Playwright MCP | Works only if it was started with `--extension` (it then drives the user's Chrome through the Playwright MCP Bridge extension). Its own fresh browser gets 401. |
| curl, scripts, Playwright tests, any CLI | Wrap the command in `password-filler-mcp run`. |

A `401` from curl or a script usually just means the request went out without
credentials. Before reporting it, repeat the request through `run`; report the
`401` only if it persists, and then say which host lacks a matching item.

To check which hosts are covered, call the `list_hosts` tool of the
`password-filler` MCP server. It returns hostnames only. Subdomains of a listed
domain usually match too, so a missing exact host is not proof that it fails.

## Chrome

Navigate to the protected URL as you would any other page. If a page still shows a
login dialog, the host has no matching 1Password item — tell the user which host,
instead of offering to type credentials.

## Playwright MCP

Playwright MCP in its default mode launches its own browser without the Password
Filler extension and gets `401` / `ERR_INVALID_AUTH_CREDENTIALS`. If that happens,
tell the user to start it with `--extension` (it then controls their real Chrome,
where the extension fills the login), or use a Playwright script through `run`.

## Scripts and CLI tools: `password-filler-mcp run`

```bash
password-filler-mcp run --url <http(s)-URL> -- sh -c '<command using "$HTACCESS_USER" and "$HTACCESS_PASSWORD">'
```

`run` asks Password Filler for the credentials of the URL's host, exports them as
`HTACCESS_USER` and `HTACCESS_PASSWORD`, and executes the command. Two rules keep
this working and the values out of the conversation:

- **Single quotes around the `sh -c` script.** With double quotes, or without
  `sh -c`, your own shell expands `$HTACCESS_USER` before `run` has set it, and the
  command gets empty values.
- **Do not print the variables** (`echo`, `printenv`, `env`, `set -x`). The point
  is that the credentials never reach the transcript.

curl:

```bash
password-filler-mcp run --url https://staging.example.com/ -- sh -c 'curl -sS -u "$HTACCESS_USER:$HTACCESS_PASSWORD" https://staging.example.com/'
```

Playwright test suite — read the variables in the config, then wrap the run:

```ts
// playwright.config.ts
use: {
  httpCredentials: {
    username: process.env.HTACCESS_USER!,
    password: process.env.HTACCESS_PASSWORD!,
    origin: 'https://staging.example.com',
  },
},
```

```bash
password-filler-mcp run --url https://staging.example.com -- sh -c 'npx playwright test'
```

Python Playwright: `browser.new_context(http_credentials={"username": os.environ["HTACCESS_USER"], "password": os.environ["HTACCESS_PASSWORD"]})`.

## When `run` fails

`run` prints the reason on stderr and exits with a fixed code. Relay the meaning to
the user; none of these are fixed by retrying with different quoting.

| Exit | Meaning | Tell the user |
|---|---|---|
| 64 | Wrong invocation (no `--url`, no `--`, no command, not an http(s) URL) | Nothing — fix the call |
| 65 | No unique 1Password item for this host | Check the item carries the `.htaccess` tag and this host's URL; click Refresh in the Password Filler menu bar |
| 69 | Password Filler is not running | Start PasswordFiller.app |
| 77 | The "For AI Agents" switch is off, or Password Filler rejected the binary | Turn on Password Filler → Settings → For AI Agents → Enable local MCP server (German: Einstellungen → Für KI-Agenten); update Password Filler if it is already on |
| 126 / 127 | The command itself could not run / was not found | Fix the command |

`command not found: password-filler-mcp` means the switch was never turned on on
this Mac — turning it on installs the command to `/usr/local/bin`.

## Requirements

- macOS with PasswordFiller.app running ([download](https://andreasisaak.github.io/password-filler/)).
- Settings → For AI Agents → Enable local MCP server switched on.
- A 1Password item per site with the tag `.htaccess` and the site's URL.
