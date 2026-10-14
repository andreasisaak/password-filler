# Password Filler

Auto-fills HTTP Basic Auth dialogs from 1Password across **Chrome, Firefox, Brave, and Safari** on macOS. No more typing staging credentials, no per-browser refresh, no per-browser Touch-ID prompts.

> **macOS-only.** Linux support was removed in v1.0. The legacy v0.3.x Linux build is still on the GitHub Releases page if you need it.

## Why this exists

Browser extensions alone cannot solve this well. Each browser's extension runs in its own sandbox, opens its own connection to a Native-Messaging Host, and 1Password's desktop app then sees a different parent process per browser — so it asks for Touch-ID approval every single time, in every browser. The cache lives per-browser too, so "refresh from 1Password" has to be clicked separately for Chrome, Firefox, and Brave.

Password Filler v1 fixes that by moving the brain into a **native macOS app**:

- One Touch-ID prompt covers every browser at once
- One credential cache, shared across browsers
- Unified status UI in the menu bar
- Native Safari support via Apple's Credential Provider extension (no `webRequest` hack)

## How it works

```
┌────────────┐    ┌────────────────────────────────┐
│ Chrome /   │    │  Background Agent (LaunchAgent)│
│ Firefox /  │◄───┤  — credential cache (encrypted)│◄── op CLI ── 1Password
│ Brave      │    │  — XPC + Unix-Socket server    │     desktop app
│ extension  │    │  — URL-matching + merge logic  │
└────────────┘    └────────────────────────────────┘
                          ▲          ▲
                          │ XPC      │ XPC
                          │          │
                  ┌───────┴──┐  ┌────┴──────────────┐
                  │ Menu-bar │  │ Safari extensions │
                  │ Main App │  │ (CredProvider     │
                  │ (UI)     │  │  + Web Extension) │
                  └──────────┘  └───────────────────┘
```

When a 401 + `WWW-Authenticate: Basic` arrives:
1. The browser extension catches it before the dialog appears (Chrome/Firefox/Brave via `onAuthRequired`, Safari via the Credential Provider extension)
2. The extension asks the Agent for credentials matching the hostname
3. The Agent returns username + password from its cache (or fetches them via `op` if the cache is stale)
4. The dialog never shows; the page loads authenticated

## Installation

**Prerequisites:**
- macOS 14 (Sonoma) or newer
- [1Password 8 desktop app](https://1password.com/downloads), signed in
- 1Password Settings → Developer → **Integrate with 1Password CLI** enabled
- A 1Password vault with login items tagged `.htaccess`

**Steps:**
1. Download `password-filler-v*.dmg` from the [latest release](https://github.com/andreasisaak/password-filler/releases/latest)
2. Mount the DMG and drag `Password Filler.app` into `/Applications/`
3. Launch from Spotlight or `/Applications/`. The onboarding wizard runs once — confirms 1Password is reachable, asks for your account shorthand and the item tag, kicks off the first refresh
4. **Chrome / Brave:** install the extension from the [Chrome Web Store](https://chromewebstore.google.com/detail/password-filler/ebcpahcihmnibmplnblcikgjiicmpcff)
5. **Firefox:** install from the [AMO listing](https://addons.mozilla.org/firefox/addon/passwordfiller/). Auto-updates via AMO from there.
6. **Safari:** open `Password Filler` from the menu bar → Settings → Security → enable AutoFill provider in System Settings → Passwords → AutoFill. The Safari Web Extension also has to be enabled in Safari → Settings → Extensions

## 1Password configuration

Tag the login items you want auto-filled with `.htaccess` (configurable in app settings). The Agent reads credentials from:

- **Custom sections** named `htaccess`, `basicauth`, `basic auth`, `htpasswd`, `webuser` (case-insensitive, regex)
- **Top-level username + password fields** as fallback

The URL field on the 1Password item drives matching — no separate config needed. Multiple URLs per item work; the longest matching hostname wins.

## URL matching

Three-stage lookup:

1. **Exact hostname** — `staging1.example.com` matches if it's literally in the item's URL list
2. **Domain suffix** — `app.staging1.example.com` matches via eTLD+1 `example.com`
3. **Tiebreak** — when multiple items share a base domain, the one with the longest shared subdomain suffix wins; if depths still tie, the request stays unmatched (silent fail; check the logs)

Wildcards in URLs are not glob-expanded — `*.example.com` matches `app.example.com` because `eTLD+1` resolves both to `example.com`, not because `*` was treated specially.

The base domain comes from the official [Public Suffix List](https://publicsuffix.org), including its section for shared hosting platforms. On a platform such as `herokuapp.com` or `cloudfront.net`, every customer subdomain counts as its own domain: an item for `myapp.herokuapp.com` matches only that host and its subdomains, never `otherapp.herokuapp.com`. Hosts outside the list (`localhost`, `nas.local`) match only exactly.

Password Filler fills only `https://` requests, in Chrome, Firefox, Brave and Safari. A login prompt over plain `http://` shows the browser's own dialog, because the credentials would otherwise travel unencrypted.

## Daily usage

- Visit any `.htaccess`-tagged URL — credentials fill automatically, no dialog
- Click the menu-bar icon to see status, item count, last refresh, and the full list with vault badges (items appearing in multiple vaults collapse into one row with a "*N* Vaults" badge)
- **Refresh** triggers `op item list` + per-item `op item get` (~13 s for ~30 items, bounded to 5 parallel calls so 1Password's auth-queue doesn't stall)
- Cache TTL is configurable in Settings (1 / 3 / 7 / 14 / 30 days, default 7). Entries past TTL are evicted on read

The Agent runs in the background as a LaunchAgent and re-launches automatically after reboot. Cache survives reboot (encrypted with a per-Mac AES-256-GCM key), so Basic-Auth fills work immediately after login without a fresh Touch-ID prompt.

## For AI agents

Coding agents such as Claude Code can reach htaccess-protected sites through Password Filler without the credentials appearing in the conversation. There are three paths:

- **Claude in Chrome** — the agent opens the URL in your Chrome, and the Password Filler extension answers the login as it does for you.
- **Playwright MCP with `--extension`** — Playwright drives your real Chrome (this needs the Playwright MCP Bridge extension in that Chrome), so the extension fills the login. In its default mode Playwright MCP launches its own browser without the extension and gets `401`.
- **curl, scripts and Playwright tests** — `password-filler-mcp run` exports the credentials for the URL's host as `HTACCESS_USER` / `HTACCESS_PASSWORD` to the command, the same pattern as `dotenvx run`:

  ```bash
  password-filler-mcp run --url https://staging.example.com/ -- sh -c 'curl -sS -u "$HTACCESS_USER:$HTACCESS_PASSWORD" https://staging.example.com/'
  ```

  Keep the single quotes around the `sh -c` script: with double quotes the calling shell expands the variables before `run` has set them.

To turn it on, open `Settings → For AI Agents` and enable **Enable local MCP server**. This creates the symlink `/usr/local/bin/password-filler-mcp` into the app; macOS asks for an administrator password once if that directory is not writable. Turning the switch off blocks all requests but keeps the symlink; remove it with `sudo rm /usr/local/bin/password-filler-mcp`. Then install the Claude Code plugin, which adds the MCP server (tool `list_hosts`, hostnames only) and a skill that tells Claude which path to take:

```text
/plugin marketplace add andreasisaak/password-filler
/plugin install password-filler@password-filler
```

**What this protects and what it does not.** The agent never receives the credentials as text. A command it starts with `run` does, and could print them — the same level as environment variables from `dotenvx`. The switch is consent, not a barrier against malicious software running as your user. While it is off, `run` exits with code 77 and the MCP server reports an error.

## Updates

The macOS app auto-updates via [Sparkle 2.x](https://sparkle-project.org). Updates are signed with ed25519 and silently installed without an admin prompt — no `.pkg` postinstall, no privilege escalation. Click `Settings → About → Check for Updates` to check manually.

The Chrome/Firefox/Brave extensions auto-update via the Chrome Web Store and Firefox AMO respectively.

## Privacy & security

- Credentials are fetched on-demand from your local 1Password app via 1Password's own `op` CLI. Nothing leaves your Mac
- The cache is encrypted at rest with a per-Mac AES-256-GCM key stored in the macOS Keychain — credentials are never written to disk in plaintext
- Revoking 1Password access does not wipe the cache. Credentials already cached stay usable until the cache TTL expires (Settings, default 7 days, at most 30). Pick a short TTL if offboarding speed matters to you
- The XPC channel between Agent and Main-App / Safari extensions is restricted by Mach-Service name to processes signed with team ID `A5278RL7RX`
- The Agent answers the Native-Messaging bridge only when a supported browser started it, so a script cannot launch the bridge by hand to read credentials. This is a hurdle against accidental misuse, not a defense against malicious software running as your user
- `password-filler-mcp` gets hostnames and `run` credentials only while `Settings → For AI Agents` is switched on, and cannot use the actions reserved for the browser extensions (`lookup`)
- Logs use Apple's unified logging system with the `app.passwordfiller.*` subsystem. Hostnames and credentials are tagged `private` and only visible to processes running under your user

## Troubleshooting

**Credentials are not filled**
- Check the menu-bar icon: red `lock.slash` means 1Password is locked or unreachable. Unlock 1Password, click `Refresh` in the popover
- Make sure `Integrate with 1Password CLI` is enabled in 1Password Settings → Developer
- Make sure the URL on the 1Password item actually matches the request hostname (silent failures on ambiguous URL matches are intentional — see URL matching)

**Item not appearing after refresh**
- Verify the item is tagged with `.htaccess` (or whatever you configured)
- Verify a URL is set on the item — items without URLs are skipped during refresh

**Read the logs**

```bash
log show --predicate 'subsystem BEGINSWITH "app.passwordfiller"' --last 10m --info
```

For private fields (hostnames, credentials), use `log stream --level=debug --predicate '...'` while reproducing the issue.

**Manual smoke checklist**

The full QA checklist for releases is in [`mac/TESTING.md`](mac/TESTING.md) — 13 scenarios covering every browser, Touch-ID lifecycle, stale `op_account`, app-rename, Sparkle round-trip, and uninstall.

## Repository layout

```
mac/                Native macOS app (Swift + xcodegen)
  PasswordFiller/   SwiftUI menu-bar main app
  Agent/            LaunchAgent daemon (XPC + cache)
  CredProvider/     Safari ASCredentialProvider extension
  SafariExt/        Safari Web Extension
  NMHBridge/        pf-nmh-bridge stdio ↔ socket proxy
  MCPServer/        password-filler-mcp: MCP server + `run` for AI agents
  Tests/            XCTest unit + integration suites (161 tests)
  TESTING.md        Manual smoke-test checklist
extension/          MV3 extension for Chrome/Firefox/Brave (proxy-only)
claude-plugin/      Claude Code plugin (skill + MCP server config)
.claude-plugin/     Plugin marketplace manifest for this repo
installer/          Shared entitlements + ExportOptions
scripts/            CWS ZIP builder, Sparkle appcast updater, Public Suffix List generator
specs/v1-mac-app/   Requirements, design, plan
updates/            Sparkle mac-appcast.xml (Mac app update feed)
```

For build instructions, signing setup, and the one-time Sparkle key generation, see [`mac/README.md`](mac/README.md).

## Status

Open-source utility for anyone who uses 1Password on macOS and runs into HTTP Basic Auth dialogs. The Mac app and Safari support shipped in v1.0.x; the Chrome/Firefox/Brave extension stays at v1.0.x as a slim proxy. v0.3.x (Linux + standalone NMH) is end-of-life.

## License

Copyright © 2026 Andreas Isaak.

Password Filler is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License v3.0](LICENSE) as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

Password Filler is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the [LICENSE](LICENSE) file or <https://www.gnu.org/licenses/gpl-3.0.html> for details.
