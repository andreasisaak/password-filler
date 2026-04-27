# Manual Smoke-Test Checklist

Run this checklist end-to-end **after every release build** and **before shipping
a stable tag**. It covers user-facing scenarios that XCTest can't reach — Touch-ID
prompts, browser UI, System Settings integration, and multi-process lifecycle.

Report results in the release PR / tag notes. If any item fails, fix before
tagging stable; a failing item on an RC build is acceptable if documented.

**Prerequisites:**
- macOS 14.0+ host
- 1Password 8 desktop app installed + signed in to the production account
- `op` CLI installed via 1Password desktop integration (Settings → Developer
  → „Integrate with 1Password CLI")
- Chrome, Firefox, Brave, Vivaldi (optional), and Safari installed
- The notarized `.dmg` under test copied to `/Applications/PasswordFiller.app`
- `~/Library/Application Support/passwordfiller/config.json` deleted so the
  onboarding wizard is triggered fresh

---

## 1. 4-Browser Basic-Auth Fill Matrix

For **each** of Chrome, Firefox, Brave, and Safari:

1. Open a known Basic-Auth-protected URL from the 1Password `.htaccess` vault
   (e.g. `https://staging.example.com/`).
2. Native Basic-Auth dialog appears briefly, then disappears automatically.
3. Page loads authenticated (no challenge, content renders).

**Pass criteria:** no manual credential entry in any of the four browsers.
**Fail indicators:** dialog stays up → extension/NMH unreachable, or hostname
mismatch in 1Password item.

- [ ] Chrome
- [ ] Firefox
- [ ] Brave
- [ ] Safari (via CredProvider.appex — first use shows 1-click „Password
      Filler" picker, subsequent uses silent)

## 2. Touch-ID Prompt Count

1. Reboot the Mac (clean 1P session state).
2. Launch `PasswordFiller.app`. If onboarding was completed previously, the
   menu-bar icon appears immediately.
3. Click menu-bar icon → popover opens → click „Aktualisieren".
4. **Expect exactly 1 Touch-ID prompt.**
5. Within 10 minutes, trigger refresh again (Chrome to new URL / manual
   refresh). **Expect 0 additional prompts.**
6. Wait > 10 minutes idle, repeat. **Expect 1 new prompt** (desktop-app-auth
   TTL expired).

- [ ] 1 prompt on first refresh after reboot
- [ ] 0 prompts within the 10-minute window
- [ ] 1 fresh prompt after idle > 10 min

## 3. 1Password-Lock Scenario

1. With the menu-bar popover showing „Verbunden", lock 1Password
   (`⌘⇧L` inside the 1P app).
2. Click „Aktualisieren" in the popover.
3. Popover status should switch to **„1Password gesperrt"** with an
   unlock-hint button.
4. Unlock 1P via Touch-ID.
5. Click „Aktualisieren" again → status returns to „Verbunden · N Einträge".

- [ ] Lock state detected and surfaced with correct label
- [ ] Unlock + retry succeeds

## 4. Offboarding Simulation

1. Edit `~/Library/Application Support/passwordfiller/config.json` — set
   `op_account` to a bogus value (e.g. `"bogus.1password.com"`). Save.
2. From menu-bar popover: Einstellungen → Allgemein → change TTL once (any
   value) to force `reloadConfig`.
3. Click „Aktualisieren" in popover.
4. Popover should show **Fehler-Icon** + the real 1P error (e.g. „op exit 1:
   no accounts configured …").
5. Basic-Auth fills for already-cached hosts **still work** (cache survives
   until TTL expires) — test by hitting one of them in a browser.

- [ ] Refresh surfaces the right error text
- [ ] Existing cache still serves until TTL eviction

## 5. Cache-TTL Change

1. Einstellungen → Allgemein → Cache-TTL auf **1 Tag** setzen.
2. Popover: TTL-Anzeige im Secondary-Text aktualisiert sich sofort
   („Cache-TTL: 1 Tag").
3. Wait 25 hours (or adjust Mac-time forwards — see `systemsetup` with
   admin rights, revert afterwards).
4. Try a Basic-Auth fill for a cached host. Popover status should evict
   the entry on next lookup — fill should trigger a fresh browser challenge
   or a refresh.

- [ ] TTL change persists across restarts
- [ ] Eviction observable on next lookup past TTL

## 6. App-Rename Test (FR EC-3)

1. Quit `PasswordFiller.app` and the Agent (`launchctl bootout gui/$UID/app.passwordfiller.agent`).
2. Rename `/Applications/PasswordFiller.app` → `/Applications/Test.app`.
3. Launch the renamed `.app`.
4. Open a Basic-Auth URL in Chrome — fill still works.
5. Verify NMH manifests under
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`
   (and sibling dirs) now point at the new path.

- [ ] Basic-Auth fill works after rename
- [ ] NMH manifests rewritten to the new bundle path

## 7. App-Move Test

1. Move `/Applications/PasswordFiller.app` → `~/Applications/PasswordFiller.app`.
2. Launch the moved `.app`.
3. Basic-Auth fill works in one browser.

- [ ] Fill works from user Applications folder
- [ ] Translocation-Guard did not alert (only triggers if `.app` is run
      from Downloads / DMG-mount, not `~/Applications/`)

## 8. Sparkle Update Round-Trip

1. Install v1.0.0-rc1 DMG from GitHub Release.
2. Quit any existing PasswordFiller instance.
3. Launch the installed rc1 build. Menu-bar icon appears.
4. Ensure the `SUFeedURL` in `Info.plist` points at a feed where a newer
   version exists (for the RC phase this is `feat/v1-mac-app` branch).
5. In the running app: Einstellungen → Über → „Auf Updates prüfen".
6. Sparkle should detect the newer version, download, verify, prompt once,
   silent-install without admin password, and auto-relaunch on the new version.
7. Menu-bar icon reappears, About-tab shows the new version string.

- [ ] Update detected
- [ ] No admin password prompt
- [ ] Relaunch lands on new version

## 9. Merge-Display (Multi-Vault Case)

1. In 1P, have two items with identical `title`, `URL`, username, password
   — one in vault „Shared", one in any other vault.
2. Trigger refresh in the menu-bar popover.
3. Popover shows **one** row for the item with a badge labeled
   „aus 2 Vaults" (or „2 Vaults" depending on locale).

- [ ] Identical items collapse
- [ ] Badge lists both source vaults

## 10. Settings UX

Walk all four tabs. After each toggle / text-field edit:

- [ ] Close Einstellungen window — re-open — value persisted
- [ ] Auto-save happens without a dedicated „Save" button
- [ ] `config.json` on disk reflects the change (check with
      `cat ~/Library/Application\ Support/passwordfiller/config.json`)
- [ ] No data loss when Einstellungen is closed with `⌘W` mid-edit

## 11. Uninstall

1. Quit `PasswordFiller.app`.
2. Drag the `.app` to Trash.
3. Run `launchctl list | grep passwordfiller`. The Agent may still show —
   that's expected until next login.
4. Log out + back in (or reboot).
5. Run `launchctl list | grep passwordfiller` again → **no output**
   (bootout cleaned up the now-missing-binary label).
6. Open a Basic-Auth URL in Chrome → native dialog appears (no silent
   fill, extension either falls back or errors).

- [ ] Trash delete succeeds (no "app in use" error)
- [ ] Agent fully gone after next login
- [ ] Basic-Auth falls back to native dialog

---

## Cross-Machine Verification

Run items 1, 3, and 8 on a **second Mac** with a **different 1Password
account** (e.g. a colleague's machine). Purpose: catch account-specific
bugs (vault permission quirks, URL-match surprises).

- [ ] Second-machine smoke pass

---

## Known Non-Blocking Items

- **F5 race** (Phase 5 learnings): on-demand Agent respawn may race with the
  first XPC call from CredProvider; retry with 200/500/1000 ms backoff
  masks this in practice. Re-verify under notarized build if Safari silent
  fill ever fails the first time.
- **F4**: cancelling the empty AutoFill system dialog when no hostname
  matches is by-design (silent `cancel`, no user feedback beyond an empty
  Safari picker).
- **Freshness-Expiry**: if the SafariExt-written host in the Shared Keychain
  is older than 300 s, CredProvider cancels the fill. Manually verifiable
  by waiting 6 min after navigating, then triggering a Basic-Auth request.
