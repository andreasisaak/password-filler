# Password Filler

Chrome/Firefox/Brave extension that auto-fills HTTP Basic Auth dialogs from 1Password. No more manually entering staging credentials.

## How it works

1. A server responds with `401 + WWW-Authenticate: Basic`
2. The extension intercepts the request via `webRequest.onAuthRequired` — before the browser dialog appears
3. Credentials are fetched from 1Password via a native messaging host + `op` CLI
4. The auth dialog never shows — the page loads directly

## Installation

**Prerequisites:**
- [1Password desktop app](https://1password.com/downloads) — signed in to your account
- Chrome, Firefox, or Brave

**Steps:**

1. Download `password-filler.pkg` from the [latest release](https://github.com/andreasisaak/password-filler/releases/latest)
2. Double-click and run the installer — it will ask for your 1Password account URL (e.g. `yourteam.1password.com`) and install everything automatically
3. In 1Password: **Settings → Developer → Enable "Integrate with 1Password CLI"**
4. Restart your browser — the extension installs itself automatically
5. Click the extension icon → **Refresh from 1Password** (Touch ID prompt appears once)

## 1Password configuration

Tag your login items with `.htaccess` in 1Password. The extension reads credentials from:

- **Custom sections** named `htaccess`, `basicauth`, `basic auth`, `htpasswd`, `WEBUSER`, or similar (case-insensitive)
- **Standard login fields** (username + password) as fallback

The URLs stored on the 1Password item are used for matching — no separate config needed.

## URL matching

Credentials are matched in three stages:

1. **Exact hostname** — `staging1.example.com` matches directly
2. **Domain suffix** — `new.sub.example.com` matches via base domain `example.com`
3. **Depth tiebreak** — when multiple items share a base domain, the item whose hostnames match the same subdomain depth wins

## Daily usage

- The cache persists across browser restarts — only refresh when credentials change in 1Password
- Visit any `.htaccess`-protected URL — credentials fill automatically, no dialog
- Click the extension icon → **Refresh from 1Password** to reload after credential changes

## Updates

The extension and native host update automatically — no action required.

## Supported browsers

| Browser | Status |
|---------|--------|
| Chrome  | Supported |
| Brave   | Supported |
| Firefox | Supported |
| Safari  | Not supported (`webRequest.onAuthRequired` unavailable in MV3) |

## Troubleshooting

**Credentials are not filled**
- Click "Refresh from 1Password" in the popup — cache may be empty
- Make sure 1Password desktop is running and unlocked
- Check that "Integrate with 1Password CLI" is enabled in 1Password Settings → Developer

**Item not matched for a URL**
- Verify the 1Password item is tagged with `.htaccess`
- Check that a URL matching the domain is stored on the item

**Check the log**

```bash
tail -f ~/Library/Logs/passwordfiller.log
```

## Privacy

Password Filler does not collect, transmit, or share any user data.

- All credential lookups happen entirely on your device via the local 1Password CLI
- No data is sent to any external server
- Passwords are never written to disk by this extension
- `chrome.storage.local` stores only the list of site names and domains — no passwords
- A log file is written to `~/Library/Logs/passwordfiller.log` containing matched domain names for debugging — this file is only readable by you
