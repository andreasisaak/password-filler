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
  Tests/             XCTest unit + integration suites (77 tests)
  TESTING.md         Manual smoke-test checklist (11 scenarios)
extension/           MV3 extension for Chrome/Firefox/Brave (proxy-only)
installer/           Shared entitlements + ExportOptions for xcodebuild
scripts/             CWS ZIP builder + Sparkle appcast updater
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

77 XCTests across 8 suites in `mac/Tests/` (0 failures, 1 pre-existing skip when the `op` binary is system-installed):

- `ItemStoreTests` — URL-matching (8 fixtures), TTL eviction, vault merge, credential extraction, hostname extraction, sharedSuffixLength
- `MergeLogicTests` (inline in ItemStoreTests) — multi-vault collapse
- `CacheTtlTests` (inline in ItemStoreTests) — eviction past TTL, live TTL mutation
- `OpClientTests` — `parseWhoami` pure-function tests covering authenticated / locked / noAccounts / unknown
- `ConfigStoreTests` — legacy migration, snake-case round-trip, atomic writes
- `RevokePollerTests` — state machine + ItemStore eviction wiring
- `PublicSuffixListTests` — eTLD+1 resolution
- `AgentXPCIntegrationTests` — every `AgentServiceProtocol` method over an anonymous `NSXPCListener`
- `UnixSocketProtocolTests` — UInt32-LE + UTF-8-JSON framing against a temp socket
- `BackwardsCompatTests` — golden-fixture regression guards for the v0.3.x wire shape

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

**Agent registration architecture:** `launchctl bootstrap` is the only supported path. SMAppService was removed because of an AMFI-LWCR self-constraint mismatch on macOS 26.4.x that SIGKILLed the agent on every spawn. See [specs/launchagent-bypass-smappservice.md](specs/launchagent-bypass-smappservice.md). **Do not re-introduce SMAppService.**

## Xcode gotchas

- **Always build the app scheme** (`PasswordFiller`), not individual target schemes — target schemes trigger 2-3 min provisioning-profile lookups.
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

**Sparkle key generation is one-time, on the maintainer's Mac.** See [mac/README.md § Sparkle key generation](mac/README.md#sparkle-key-generation-one-time). The CI fails its pre-flight check without `SPARKLE_PRIVATE_KEY` (repo secret) and `SUPublicEDKey` (in `mac/PasswordFiller/Info.plist`).

## Extension IDs & bundle IDs

| Target | Identifier |
|---|---|
| Chrome/Brave extension | `ebcpahcihmnibmplnblcikgjiicmpcff` |
| Firefox extension | `passwordfiller@app` |
| Native messaging host | `app.passwordfiller` |
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
  "auto_refresh_on_start": true
}
```

Legacy 0.3.x configs (only the first two keys) auto-migrate with defaults via per-key `decodeIfPresent` fallbacks in `Config.init(from:)`.

The `op` CLI is bundled at `Contents/Resources/op`; fallback search order is `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, then `$PATH`.

## URL matching

Three-stage lookup in the Agent's `ItemStore`:

1. Exact hostname match
2. Domain-suffix match (Public Suffix List) — unique candidate wins
3. Tiebreak: shared suffix length → subdomain depth

If both tiebreakers fail (ambiguous), **no credentials returned** — silent failure, check `log show`. Wildcards (`*.example.com` literally stored on a 1P item) are not glob-expanded; they reach real requests via the suffix rule because `eTLD+1` resolves both to the same base domain. See `testWildcardHostnameFallsThroughToSuffixMatch` in `ItemStoreTests`.

## Credential extraction

Agent looks for credentials in 1Password items in order:

1. Fields in a section matching `/(htaccess|basicauth|basic.?auth|htpasswd|webuser)/i`
2. Fallback: top-level `username` + `password` fields

Section match wins if present, even if top-level fields also exist.

## Credential cache

- Agent cache lives in-memory in `ItemStore` and is **persisted encrypted** to disk via `PersistentCache` (AES-256-GCM with a per-Mac key in the macOS Keychain). Cache survives Mac reboot and Agent respawn — no Touch-ID prompt needed before Basic-Auth fills work after login.
- TTL configurable 1/3/7/14/30 days (default 7); evicted on read past TTL.
- Active revoke polling via `op whoami` every 30 min (+ on `NSWorkspace.didWakeNotification` debounced 5 s) invalidates both the in-memory cache and the on-disk snapshot when 1Password access is revoked. The offboarding guarantee (revoke 1P ⇒ no access anywhere) is preserved despite the on-disk cache.
- Extension holds no cache — every `onAuthRequired` round-trips through the `pf-nmh-bridge` to the Agent.
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
