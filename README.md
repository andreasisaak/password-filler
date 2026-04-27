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

## Daily usage

- Visit any `.htaccess`-tagged URL — credentials fill automatically, no dialog
- Click the menu-bar icon to see status, item count, last refresh, and the full list with vault badges (items appearing in multiple vaults collapse into one row with a "*N* Vaults" badge)
- **Refresh** triggers `op item list` + per-item `op item get` (~13 s for ~30 items, bounded to 5 parallel calls so 1Password's auth-queue doesn't stall)
- Cache TTL is configurable in Settings (1 / 3 / 7 / 14 / 30 days, default 7). Entries past TTL are evicted on read

The Agent runs in the background as a LaunchAgent and re-launches automatically after reboot. Cache survives reboot (encrypted with a per-Mac AES-256-GCM key), so Basic-Auth fills work immediately after login without a fresh Touch-ID prompt.

## Updates

The macOS app auto-updates via [Sparkle 2.x](https://sparkle-project.org). Updates are signed with ed25519 and silently installed without an admin prompt — no `.pkg` postinstall, no privilege escalation. Click `Settings → About → Check for Updates` to check manually.

The Chrome/Firefox/Brave extensions auto-update via the Chrome Web Store and Firefox AMO respectively.

## Privacy & security

- Credentials are fetched on-demand from your local 1Password app via the bundled `op` CLI. Nothing leaves your Mac
- The cache is encrypted at rest with a per-Mac AES-256-GCM key stored in the macOS Keychain — credentials are never written to disk in plaintext
- When you revoke 1Password access (`op signout` or removing the account), the next refresh fails with `noAccounts` and the cache is wiped on the next poll cycle (≤30 min, debounced on wake)
- The XPC channel between Agent and Main-App / Safari extensions is restricted by Mach-Service name to processes signed with team ID `A5278RL7RX`
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

The full QA checklist for releases is in [`mac/TESTING.md`](mac/TESTING.md) — 11 scenarios covering every browser, Touch-ID lifecycle, offboarding, app-rename, Sparkle round-trip, and uninstall.

## Repository layout

```
mac/                Native macOS app (Swift + xcodegen)
  PasswordFiller/   SwiftUI menu-bar main app
  Agent/            LaunchAgent daemon (XPC + cache)
  CredProvider/     Safari ASCredentialProvider extension
  SafariExt/        Safari Web Extension
  NMHBridge/        pf-nmh-bridge stdio ↔ socket proxy
  Tests/            XCTest unit + integration suites (77 tests)
  TESTING.md        Manual smoke-test checklist
extension/          MV3 extension for Chrome/Firefox/Brave (proxy-only)
installer/          Shared entitlements + ExportOptions
scripts/            CWS ZIP builder + Sparkle appcast updater
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
