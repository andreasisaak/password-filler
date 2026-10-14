# Password Filler

Password Filler auto-fills HTTP Basic Auth dialogs from 1Password across
Chrome, Firefox, Brave, and Safari. On macOS the brains live in a native
app (signed + notarized `.dmg`); browser extensions are slim proxies.

## Branch model

- `main` is the **v1.x mainline** since the 2026-04-27 branch swap. Every commit, every release tag, every CI artifact lives here.
- `old-legacy` is the **v0.3.x archive** (Linux + standalone Node-NMH). Frozen, no work targets it.
- `feat/v1-mac-app` is a **transitional mirror** that exists only until the maintainer's v1.0.3 install (which still polls the feat-branch via the old `SUFeedURL`) is replaced by v1.0.4. After that manual upgrade, `feat/v1-mac-app` will be deleted.
- All distribution URLs from v1.0.4 onwards (Sparkle `SUFeedURL`, raw GitHub fetches in CI) point at `main`.

## Architecture

```
mac/                 Native macOS app (Swift, xcodegen-driven Xcode project)
  PasswordFiller/    SwiftUI menu-bar main app (LSUIElement, popover, settings)
  Agent/             LaunchAgent-managed daemon — cache, op CLI, XPC, socket
  CredProvider/      Sandboxed ASCredentialProvider appex (Safari autofill)
  SafariExt/         Sandboxed Safari Web Extension appex (URL observer)
  NMHBridge/         pf-nmh-bridge: Chrome/Firefox/Brave NMH stdio ↔ socket proxy
  MCPServer/         password-filler-mcp: MCP server (list_hosts) + `run` env wrapper for AI agents
  Tests/             XCTest unit + integration suites (161 tests)
  TESTING.md         Manual smoke-test checklist (13 scenarios)
extension/           MV3 extension for Chrome/Firefox/Brave (proxy-only)
claude-plugin/       Claude Code plugin (skill password-filler + .mcp.json → password-filler-mcp)
.claude-plugin/      marketplace.json — makes this repo the plugin marketplace
                     (`/plugin marketplace add andreasisaak/password-filler`). Bump
                     claude-plugin/.claude-plugin/plugin.json `version` on every
                     plugin change, or installed copies never update.
installer/           Shared entitlements + ExportOptions for xcodebuild
scripts/             CWS ZIP builder, Sparkle appcast updater, PSL generator (update-psl.js)
specs/v1-mac-app/    Requirements, design, plan (Kiro-style — completed)
updates/             mac-appcast.xml — Sparkle update feed for the Mac app.
                     Browser update manifests (chrome.xml, firefox.json) are
                     retired in v1.0.3+; CWS + AMO handle browser updates.
dist/                Build artifacts (gitignored)
```

See [specs/v1-mac-app/design.md](specs/v1-mac-app/design.md) for the full
three-process IPC architecture, entitlements matrix, and decision log.

## Build

```bash
brew install xcodegen
cd mac && xcodegen generate
open PasswordFiller.xcodeproj
```

CLI build (matches the CI pipeline):

```bash
xcodebuild -project mac/PasswordFiller.xcodeproj -scheme PasswordFiller -configuration Release archive -archivePath dist/PasswordFiller.xcarchive
```

## Tests

161 XCTests in `mac/Tests/` (0 failures, 1 pre-existing skip when the `op` binary is system-installed):

- `ItemStoreTests` — URL-matching (9 fixtures, incl. foreign tenant on a shared platform), TTL eviction, vault merge, credential extraction, hostname extraction, sharedSuffixLength
- `MergeLogicTests` (inline in ItemStoreTests) — multi-vault collapse
- `CacheTtlTests` (inline in ItemStoreTests) — eviction past TTL, live TTL mutation
- `OpClientTests` — `op` binary path resolution, `op_account` reconciliation (`resolveAccount`)
- `CacheStalenessTests` — `AgentStatus.isCacheExpired` derivation (expired-cache escalation)
- `ConfigStoreTests` — legacy migration, snake-case round-trip, atomic writes
- `PublicSuffixListTests` — eTLD+1 against the full PSL: private platform suffixes, wildcard + exception rules, Punycode IDN suffixes, fail-closed for uncovered hosts
- `StoredItemTests` — `domains` derived, deduplicated, sorted; a stale `domains` key in an old snapshot is ignored
- `SharedHostKeychainTests` — Safari handoff payload: scheme required (legacy entries rejected), round trip, `blocksFill` only for a non-https observation of the same host
- `AgentXPCIntegrationTests` — every `AgentServiceProtocol` method over an anonymous `NSXPCListener`
- `UnixSocketProtocolTests` — UInt32-LE + UTF-8-JSON framing against a temp socket
- `BackwardsCompatTests` — golden-fixture regression guards for the v0.3.x wire shape
- `BridgeStalenessTests` — D24 stale-bridge verdict (cdhash match / mismatch / failed identity lookup)
- `BridgeParentPolicyTests` — D25 bridge-parent verdict (every supported browser, foreign Team ID, other app of a browser team, platform binary, signature failure)
- `SocketDispatchMatrixTests` — D4 socket authorization per `SocketPeer` (`password-filler-mcp` limited to its allow-list)
- `SocketMCPActionsTests` — `hosts` / `run_credentials` behind the `mcp_enabled` switch (refused when off, cache-only, bridge forbidden)
- `MCPRequestHandlerTests` — MCP JSON-RPC: handshake versions, notifications, `tools/list`, `list_hosts` results and errors, error codes, no raw newline
- `RunArgumentsTests` — `password-filler-mcp run --url … -- …` parser
- `CommandLineToolStatusTests` — `/usr/local/bin/password-filler-mcp` link state (missing, installed, moved app, relative link, foreign file/directory)

Run: `xcodebuild test -project mac/PasswordFiller.xcodeproj -scheme PasswordFillerTests -destination 'platform=macOS,arch=arm64'`.

Socket-based tests use `/tmp/pf-...`-style paths because Darwin's `sockaddr_un.sun_path` caps at 104 chars and `NSTemporaryDirectory()` already eats 60+. Don't switch back to `FileManager.default.temporaryDirectory` for socket fixtures.

## Testing locally

1. Build the `PasswordFiller` app scheme in Xcode — never an individual target scheme (target schemes trigger 2-3 min provisioning-profile lookups without producing a runnable product).
2. Copy the built `.app` to `/Applications/` before first launch — the runtime `registerLaunchAgent()` has a Translocation-Guard that aborts + alerts if `Bundle.main.bundlePath` isn't under `/Applications/` or `~/Applications/`.
3. First launch auto-registers the Agent via `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/app.passwordfiller.agent.plist` (plist is generated at runtime — there is no longer a bundled plist under `Contents/Library/LaunchAgents/`) and writes NMH manifests into every installed browser's `NativeMessagingHosts/` directory.
4. Load `extension/` as unpacked in `chrome://extensions` (disable any Web-Store-installed version first); reload after editing `background.js`.
5. Logs: `log show --predicate 'subsystem BEGINSWITH "app.passwordfiller"' --last 10m`. Sensitive fields use `%{private}@` — unlock with `log stream --level=debug`.

**LaunchServices cleanup after dev builds:** Xcode-built `PasswordFiller.app` instances under `~/Library/Developer/Xcode/DerivedData/...` and `/private/tmp/pf-build/...` get registered by `pluginkit` as additional Safari Web Extension and AutoFill provider entries. After every dev rebuild, deregister and remove the stale paths:

```bash
lsregister -u <stale-app-path>
rm -rf <stale-app-path>
lsregister -r -domain user
```

(`lsregister` lives at `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister`.)

The shipped `pf-install.sh` script does this automatically for `mac/build/Debug/PasswordFiller.app` after copying to `/Applications/`.

**Stale bridges after a bundle swap:** swapping `/Applications/PasswordFiller.app` while Chrome/Brave/Firefox run leaves their `pf-nmh-bridge` processes on the old code. The Main-App reaps them on launch (D24); check with `/usr/bin/log show --predicate 'subsystem == "app.passwordfiller.main"' --last 5m | grep bridge-reaper`. On builds ≤ v1.4.1: `pkill -f pf-nmh-bridge`.

**Agent registration architecture:** `launchctl bootstrap` is the only supported path. SMAppService was removed because of an AMFI-LWCR self-constraint mismatch on macOS 26.4.x that SIGKILLed the agent on every spawn. See [specs/launchagent-bypass-smappservice.md](specs/launchagent-bypass-smappservice.md). **Do not re-introduce SMAppService.**

**⚠️ Never `launchctl bootout` standalone before re-launching the App.** `registerLaunchAgent()` has a "plist content unchanged → skip bootstrap" optimization (`PasswordFillerApp.swift`). After a bare `bootout`, the next launch sees the same plist on disk, skips re-bootstrap, then `kickstartIfVersionChanged` fails with `rc=113` because the service is not registered — the App ends up unable to reach the Agent (`Connection init failed at lookup with error 3 - No such process`), and Refresh / Lookups silently do nothing. To recover: either run `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/app.passwordfiller.agent.plist` manually, **or** `rm -f ~/Library/LaunchAgents/app.passwordfiller.agent.plist` before re-launching the App so the unchanged-check fails and the bootstrap path runs. When swapping in a new local archive build, prefer the second form — it forces a clean re-registration regardless of plist content.

## Xcode gotchas

- **Always build the app scheme** (`PasswordFiller`), not individual target schemes — target schemes trigger 2-3 min provisioning-profile lookups.
- **Agent-only sources live in `mac/Agent/`**, not `mac/Shared/`: `ItemStore`, `StoredItem`, `PersistentCache`, `AuditChecker`, `AuditStore`, `BridgeParentPolicy`, `PublicSuffixList*`. Only the Agent and the test target compile `mac/Agent/`, which keeps the ~150 KB Public Suffix List data out of the main app and both appexes. `mac/Shared/` is for code at least one other target needs.
- **Entitlements files are not tracked as dependencies of post-build scripts.** Changing entitlements without a Clean Build may leave old-signed binaries in the build output.
- **Do not re-sign nested binaries in post-build phases** unless the script also re-applies the provisioning profile — Xcode signs tool targets with their own profile during target build; re-signing with `codesign` strips that authorization and launchd SIGKILLs the binary (OS_REASON_EXEC 0x8).
- **Entitlements XML cannot reference `$(AppIdentifierPrefix)`** in files passed directly to `codesign` — only Xcode's entitlements processor expands that variable. Hardcode the Team ID (`A5278RL7RX`) in files the build scripts hand to `codesign`.
- **LaunchAgent plist Label must match the filename** (minus `.plist`). Label `app.passwordfiller.agent` requires filename `app.passwordfiller.agent.plist` — written at runtime to `~/Library/LaunchAgents/` and registered via `launchctl bootstrap gui/$UID …`. Plist-Drift-Detection runs byte-level on the on-disk file (no UserDefaults hash).

## Release

Release a new version by tagging on `main`:

```bash
git tag --list 'v*' --sort=-version:refname | head -3
git pull --rebase origin main && git push origin main && git tag v<X.Y.Z> && git push origin v<X.Y.Z>
```

CI (`release.yml`) triggers on `v*` tags and runs the full pipeline:

```
archive → exportArchive (per-target provisioning profile) → hdiutil DMG
       → codesign DMG → notarytool submit --wait → stapler staple
       → spctl assess → Sparkle sign_update (ed25519 over the DMG)
       → prepend appcast entry → softprops/action-gh-release
       → commit mac-appcast.xml + extension/manifest.json back to main
```

A run takes 3-6 minutes; notarize latency is the dominant cost.

Before tagging, refresh the Public Suffix List with `node scripts/update-psl.js` and commit `mac/Agent/PublicSuffixListRules.swift` if it changed. A platform missing from a stale list lets its tenants match each other (see URL matching), so the release workflow's pre-flight runs `node scripts/update-psl.js --check-age 30` and fails when the list is older than 30 days.

**Sparkle key generation is one-time, on the maintainer's Mac.** See [mac/README.md § Sparkle key generation](mac/README.md#sparkle-key-generation-one-time). The CI fails its pre-flight check without `SPARKLE_PRIVATE_KEY` (repo secret) and `SUPublicEDKey` (in `mac/PasswordFiller/Info.plist`).

## Extension IDs & bundle IDs

| Target | Identifier |
|---|---|
| Chrome/Brave extension | `ebcpahcihmnibmplnblcikgjiicmpcff` |
| Firefox extension | `passwordfiller@app` |
| Native messaging host | `app.passwordfiller` |
| MCP server / `run` binary (signing identifier) | `password-filler-mcp` |
| Main-App bundle ID | `app.passwordfiller` |
| Agent helper-app bundle ID | `app.passwordfiller.agent` |
| CredProvider.appex | `app.passwordfiller.CredProvider` |
| SafariExt.appex | `app.passwordfiller.SafariExt` |
| Agent Mach-Service | `group.A5278RL7RX.app.passwordfiller.agent` |
| App Group | `group.A5278RL7RX.app.passwordfiller` |
| Apple Team ID | `A5278RL7RX` |

Extension IDs must not change across updates — stay on the CWS-ID and Firefox Gecko ID so auto-update reaches existing users transparently.

## Configuration

Agent reads `~/Library/Application Support/passwordfiller/config.json`:

```json
{
  "op_account": "team.1password.com",
  "op_tag": ".htaccess",
  "cache_ttl_days": 7,
  "auto_start": true,
  "auto_refresh_on_start": true,
  "mcp_enabled": false
}
```

Legacy 0.3.x configs (only the first two keys) auto-migrate with defaults via per-key `decodeIfPresent` fallbacks in `Config.init(from:)`.

`mcp_enabled` is the "For AI Agents" switch (default off). While it is on, the Agent answers `password-filler-mcp` on the socket actions `hosts` (cache only, never a refresh) and `run_credentials`; while off both return `{"error":"mcp_disabled"}`. `password-filler-mcp run --url <url> -- <command>` exports the credentials as `HTACCESS_USER` / `HTACCESS_PASSWORD` to the command (dotenvx-level protection: the command could print them). Exit codes: 64 usage, 65 no unique item, 69 Agent not running, 77 switch off. See [specs/ai-agent-access/design.md](specs/ai-agent-access/design.md).

Optional debug/test key `cache_ttl_minutes` (not exposed in the Settings UI): when present it overrides `cache_ttl_days` (`Config.effectiveCacheTtlSeconds`) — set e.g. `30` to observe TTL eviction and the expired-cache escalation within minutes instead of days. Remove the key to return to the day-based TTL. Sub-day TTLs surface via `AgentStatus.ttlSeconds`; the popover then shows "Cache-TTL: N Minuten".

The `op` CLI is **not bundled** — re-signing it strips the AgileBits signature and 1Password's desktop-app-auth then rejects it ("couldn't connect to desktop app"). It is installed via `installer -pkg` to `/usr/local/bin/op`. `OpClient.resolveOpPath` search order: `Bundle.main` resource (absent in shipping builds) → `/opt/homebrew/bin` → `/usr/local/bin` → `/opt/local/bin` → `$PATH`.

`op_account` is a **hint, not a hard filter**. Before each refresh the Agent runs `op account list` and reconciles `op_account` against the accounts `op` actually knows (`OpClient.resolveAccountArgument`):

- `op_account` matches an account (by URL, email, user ID or account ID) → that account is used.
- No match but exactly one account exists → that account is used; the stale `op_account` is ignored (self-heals configs carried over from old installs).
- No match with multiple accounts, or empty `op_account` with multiple accounts → refresh fails with an actionable `accountUnavailable` error; the Agent never guesses, since a wrong pick could fill credentials from the wrong vault.

The sign-in URL in `op account list` is per-user (one colleague signs in via `firma.1password.com`, another via `my.1password.com` for the same tenant), so `op_account` can never be a reliable org-wide constant — the reconciliation step is what makes it work regardless.

## URL matching

Three-stage lookup in the Agent's `ItemStore`:

1. Exact hostname match
2. Domain-suffix match (Public Suffix List) — unique candidate wins
3. Tiebreak: shared suffix length → subdomain depth

Stage 2 uses the full official Public Suffix List (ICANN + PRIVATE sections), generated into `mac/Agent/PublicSuffixListRules.swift` by `node scripts/update-psl.js`. The PRIVATE section is a security boundary, not a nicety: it makes shared platforms (`cloudfront.net`, `herokuapp.com`, `github.io`, `vercel.app`, …) public suffixes, so a stranger's `evil.herokuapp.com` never shares an eTLD+1 with a stored `kunde.herokuapp.com` and cannot pull its credentials with a forged 401. Hosts no rule covers (`localhost`, `*.local`, unknown TLDs) have no eTLD+1 — fail-closed, exact match only. Never replace the list with a hand-curated subset (up to v1.5.0 it did, and every platform tenant was fillable by any other).

`StoredItem.domains` is a computed property over `hostnames`, so it is never persisted and an older snapshot's `domains` key is ignored on decode; `ItemStore.lookup` filters stage-2 candidates by it.

Credentials go only to HTTPS requests. The Chrome/Firefox/Brave extension registers its `webRequest` listeners for `https://*/*` only (`HTTPS_REQUESTS` in `extension/background.js`), so a plain-HTTP 401 gets the browser's own dialog. In Safari, `SafariExtHandler` stores the observed request's scheme next to the host (`SharedHostKeychain.Payload`), and the CredProvider's single gate (`fillIfNotBlocked`) refuses a host whose freshest observation is not `https` (`Payload.blocksFill(forHost:)`). That covers the Basic-Auth dialog path fully; identity-store fills (`.domain` identities, no scheme) are covered only while SafariExt observes the page. `password-filler-mcp run --url` is not covered: the Agent never sees the command's real request.

If both tiebreakers fail (ambiguous), **no credentials returned** — silent failure, check `log show`. Wildcards (`*.example.com` literally stored on a 1P item) are not glob-expanded; they reach real requests via the suffix rule because `eTLD+1` resolves both to the same base domain. See `testWildcardHostnameFallsThroughToSuffixMatch` in `ItemStoreTests`.

## Credential extraction

Agent looks for credentials in 1Password items in order:

1. Fields in a section matching `/(htaccess|basicauth|basic.?auth|htpasswd|webuser)/i`
2. Fallback: top-level `username` + `password` fields

Section match wins if present, even if top-level fields also exist.

## Credential cache

- Agent cache lives in-memory in `ItemStore` and is **persisted encrypted** to disk via `PersistentCache` (AES-256-GCM with a per-Mac key in the macOS Keychain). Cache survives Mac reboot and Agent respawn — no Touch-ID prompt needed before Basic-Auth fills work after login.
- TTL configurable 1/3/7/14/30 days (default 7); evicted on read past TTL.
- **Expired-cache escalation:** `AgentService.getStatus` reports the TTL-pruned item count, and the Main-App derives `AgentStatus.isCacheExpired` (`mac/Shared/CacheStaleness.swift`: connected + 0 items + lastRefresh ≥ one TTL window) to escalate — warning menu-bar icon (`lock.trianglebadge.exclamationmark`), „Cache abgelaufen" popover state, and one user notification per transition (`StaleCacheNotifier`, edge-triggered, re-nudges once per app launch). Rationale: the Agent seeds `connectionState = .connected` from the persisted cache at launch and nothing re-evaluates it after eviction — without the derivation the UI shows „Verbunden · 0 Einträge" forever while fills silently fail.
- **No revoke-triggered eviction.** Policy C (2026-04-23) dropped the `op whoami` revoke poller (`mac/Agent/main.swift`): `whoami` cannot tell "1Password locked" from "CLI trust lost after a new build". A failed refresh keeps the cache too (`AgentService.swift`, stale beats empty for transient failures). So after 1Password access is revoked, cached credentials stay usable until the TTL expires (default 7 days, max 30) — there is no "revoke ⇒ no access" guarantee, and no code path wipes the cache early.
- Extension holds no cache — every `onAuthRequired` round-trips through the `pf-nmh-bridge` to the Agent.
- **Stale-bridge self-healing (D24):** browsers keep `pf-nmh-bridge` alive for as long as they run, so any bundle swap (Sparkle update, DMG drag-drop, dev build) leaves old bridge processes serving. Once the old bundle is gone, the Agent's `PeerAuthorizer` cannot resolve their code identity (`SecCodeCopyGuestWithAttributes` → `100002` = ENOENT) and rejects them — red `!` badge, every lookup falls back to the browser dialog until the browser restarts. Fix is two-sided: the bridge exits on a broken established connection (browser fires `onDisconnect`, the extension respawns within ≤30 s via its status alarm), and the Main-App terminates every bridge whose cdhash differs from the bundled one on each launch (`StaleBridgeReaper`, verdict in `mac/Shared/BridgeStaleness.swift`). Bridges from builds without the fix (≤ v1.4.1) need one manual `pkill -f pf-nmh-bridge` or a browser restart.
- **Bridge parent check (D25):** the bridge itself passes the Team-ID gate no matter who starts it, so the Agent's `PeerAuthorizer` also checks the bridge's parent process (`proc_pidinfo` → `pbi_ppid`, signature against `anchor apple generic`, then signing identifier + Team ID). Only the exact identities in `mac/Shared/SupportedBrowsers.swift` pass (verdict in `mac/Agent/BridgeParentPolicy.swift`); a hand-started bridge or one re-parented to launchd gets `agent_unreachable`. **Limit:** this is a hurdle against accidental misuse (a script or coding agent that starts the bridge by hand and sends `lookup`), not a boundary against a deliberately malicious process of the same user. Such a process can fork the bridge and then `exec` the real Chrome binary under the same PID, or drive a real browser with a throwaway profile and its own NMH manifest; public macOS API cannot tell either case from a genuine browser spawn. `BrowserCatalog` reads its bundle IDs from the same list. Adding a browser means adding its identity there and checking live that its main process (not a helper) spawns the bridge — `mac/TESTING.md` scenario 12. Socket peers are classified per signing identifier (`SocketPeer`): `pf-nmh-bridge` → bridge actions, `password-filler-mcp` → only the actions in `SocketPeer.mcpClientActions` (allow-list, everything else `{"error":"forbidden"}`), any other identifier → connection closed.
- Native messaging timeout: 30 s per message.
- `op item get` fan-out is bounded to 5 in flight (1Password's desktop-app-auth daemon serializes auth checks per parent process; 30+ simultaneous calls pile up in its queue and the later ones time out).

## Build / release gotchas

- **CWS manifest:** `scripts/build-cws-crx.js` strips `browser_specific_settings` (Firefox-only `gecko` block) so CWS doesn't choke on Firefox metadata. The CWS upload artifact is `.cws.zip`. Each release leaves the ZIP under `dist/` and as a GitHub Release asset; the maintainer drops it into the CWS Dashboard manually.
- **Chrome distribution: CWS only (v1.0.3+).** The self-hosted `.crx` track is retired. `scripts/pack-crx.js`, `updates/chrome.xml`, the `key` and `update_url` fields in `extension/manifest.json` are all gone. There was only one self-hosted user (the maintainer) and CWS now serves them too.
- **Firefox distribution: AMO listed (v1.0.3+).** The CI submits via `web-ext sign --channel=listed`; AMO handles auto-update. `gecko.update_url` is gone from the manifest; `updates/firefox.json` is gone from the repo. No XPI in GitHub Releases — Firefox users install from the [AMO listing](https://addons.mozilla.org/firefox/addon/passwordfiller/).
- **Sparkle SUFeedURL** is `https://raw.githubusercontent.com/andreasisaak/password-filler/main/updates/mac-appcast.xml` from v1.0.4 onwards. CI prepends each new release as the topmost `<item>` after `notarytool submit --wait`.
- **Sparkle bootstrap history.** v1.0.0 (manually archived) hardcoded `main` as the feed branch but `main` was still v0.3.x — auto-update broken, replaced by DMG download. v1.0.1–1.0.3 hardcoded `feat/v1-mac-app` while main was still legacy. v1.0.4 hardcodes `main` again now that main is the v1 mainline. Pre-v1.0.4 installs (just the maintainer) need one manual DMG drag-drop to upgrade to v1.0.4; from there Sparkle is self-healing for all future versions.

## License

GPL-3.0 — see [LICENSE](LICENSE). Forks must remain GPL-licensed; closed-source repackaging is not permitted. Same precedent as KeePassXC, the closest architectural sibling. Sparkle (MIT) is GPL-compatible. The 1Password CLI is invoked as a subprocess, which the FSF FAQ classifies as `aggregate` rather than `combined work` — no GPL obligation propagates onto 1Password.
