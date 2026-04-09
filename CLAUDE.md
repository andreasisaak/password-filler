# Password Filler

Chrome/Firefox/Brave extension that auto-fills HTTP Basic Auth dialogs from 1Password via native messaging.

## Architecture

```
extension/         Manifest V3 extension (background.js service worker + popup)
host/              Native messaging host (Node.js)
  htpasswd-host.js Main host — talks to 1Password CLI, URL matching, credential cache
  run-host.sh      Wrapper for local dev (sets PATH for nvm/Homebrew, runs node directly)
installer/         macOS .pkg + Linux .deb post-install scripts
scripts/           CRX/CWS packaging scripts
dist/              Build artifacts (gitignored)
updates/           Auto-update manifests (chrome.xml, firefox.json) — committed by CI
```

## Commands

```bash
# Local dev (no build needed — uses run-host.sh → node directly)
# See: Testing section

# Build standalone binary (macOS arm64 + x64)
cd host && npm run build
# Output: dist/htpasswd-host-arm64, dist/htpasswd-host-x64

# Install locally for testing
./install-local.sh   # Requires dist/ artifacts + signed Firefox XPI

# Register native host for local dev (bypasses binary, uses node directly)
# Update NMH JSON path to: host/run-host.sh
```

## Testing Locally

**Always use `run-host.sh` for local dev** — avoids the pkg build + macOS signing dance.

1. Update NMH JSON to point to `run-host.sh`:
```bash
cat > "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/app.passwordfiller.json" <<'EOF'
{
  "name": "app.passwordfiller",
  "path": "/Users/isaak/sites/password-filler/host/run-host.sh",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://ebcpahcihmnibmplnblcikgjiicmpcff/"]
}
EOF
```
2. Load `extension/` as unpacked in `chrome://extensions` (disable Web Store version first)
3. Reload extension (↺) after changes to background.js or htpasswd-host.js
4. Log: `tail -f ~/Library/Logs/passwordfiller.log`

## Binary Gotchas

- **pkg v5 + macOS 15+**: Binaries get SIGKILL'd without JIT entitlements. CI re-signs via `installer/entitlements.plist` (`allow-jit` + `allow-unsigned-executable-memory`). postinstall also re-signs after copy.
- **pkg cache**: `~/.pkg-cache` can cause stale builds. Clear if binary doesn't reflect code changes
- **`strings` won't find your code**: pkg compresses JS into V8 snapshot — can't verify with `strings`

## Release

Always check the latest tag first to determine the next version:
```bash
git tag --list 'v*' --sort=-version:refname | head -3
```

Then release in one line:
```bash
git pull --rebase origin main && git push origin main && git tag v<X.Y.Z> && git push origin v<X.Y.Z>
```

CI (`release.yml`) triggers on `v*` tags: builds binary → packs `.pkg` + `.deb` → signs Firefox XPI → creates GitHub Release → updates `updates/chrome.xml` + `updates/firefox.json`.

## Extension IDs

| Browser | Extension ID |
|---------|-------------|
| Chrome/Brave | `ebcpahcihmnibmplnblcikgjiicmpcff` |
| Firefox | `passwordfiller@app` |
| Native host | `app.passwordfiller` |

## Configuration

Host reads `~/Library/Application Support/passwordfiller/config.json` (macOS) or `~/.config/passwordfiller/config.json` (Linux):
```json
{ "op_account": "team.1password.com", "op_tag": ".htaccess" }
```
Without `config.json`, `op item list` fails silently — no credentials loaded.

`op` CLI path search order: `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, then `$PATH`.

## URL Matching

Three-stage lookup in `handleLookup`:
1. Exact hostname match
2. Domain-suffix match (tldts) — unique candidate wins
3. Tiebreak: shared suffix length → subdomain depth

If both tiebreakers fail (ambiguous), **no credentials returned** — silent failure, check log.

## Credential Extraction

Host looks for credentials in 1Password items in order:
1. Fields in a section matching `/(htaccess|basicauth|basic.?auth|htpasswd|webuser)/i`
2. Fallback: top-level `username` + `password` fields

Section match wins if present, even if top-level fields also exist.

## Credential Cache

- Extension (`credentialCache`): in-memory Map, NOT persisted to disk (only metadata/titles saved). Cleared on service worker restart.
- Host (`cachedItems`): in-memory, 15min TTL. Auto-reloads on next lookup after expiry.
- Negative results cached as `null` in extension — adding a new item to 1Password requires manual Refresh to take effect.
- Parallel fetch: all `op item get` calls run concurrently via `Promise.all`.
- Extension sends one message at a time (FIFO). Host processes via serial async queue.
- Native messaging timeout: **30s per message**. On timeout, result is cached as `null`.

## Build / Release Gotchas

- **macOS binary is arm64 only** — CI builds `node18-macos-arm64`, no universal binary in `.pkg`
- **CWS manifest**: `scripts/build-cws-crx.js` strips `key`, `update_url`, `browser_specific_settings` — Firefox-only fields are silently dropped from CWS submission
- **`install-local.sh` has a syntax error on line ~84** (missing closing `'` on `EXT_JSON`) — script will fail if run directly; use it as reference only
