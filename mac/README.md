# Password Filler — Mac App

Native macOS app for Password Filler v1. See
[`specs/v1-mac-app/`](../specs/v1-mac-app/) for requirements, design, and plan.

## Generate the Xcode project

The `.xcodeproj` is not committed. It is generated from `project.yml` via
[xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd mac
xcodegen generate
open PasswordFiller.xcodeproj
```

## Targets

| Target | Type | Purpose |
|---|---|---|
| `PasswordFiller` | app | SwiftUI menu-bar main app |
| `PasswordFillerAgent` | tool | LaunchAgent-managed daemon (XPC + Unix-Socket) |
| `CredProvider` | app-extension | Safari credential provider (sandboxed) |
| `SafariExt` | app-extension | Safari Web Extension (sandboxed) |
| `pf-nmh-bridge` | tool | Chrome/Firefox/Brave Native-Messaging stdio proxy |

## Build settings

- Team ID: `A5278RL7RX` (Andreas Isaak)
- Signing: Manual (Developer ID Application)
- Deployment target: macOS 14.0 (Sonoma)
- Swift: 5.10
- Hardened runtime on all binaries

## Scheme choice

Always build the **app scheme** (`PasswordFiller`), not individual target
schemes — building target schemes triggers 2-3 min provisioning-profile
lookups without producing a runnable product.

## Sparkle key generation (one-time)

Sparkle 2.x uses ed25519 signatures to verify auto-updates. The key-pair is
generated once by the maintainer, the public half is committed in
`PasswordFiller/Info.plist` as `SUPublicEDKey`, and the private half is
stored as the `SPARKLE_PRIVATE_KEY` repo secret used by the release
workflow. Without both halves the workflow fails its pre-flight check and
Sparkle refuses to install updates.

Run **once**, on the maintainer's Mac (not in CI):

```bash
# Download the Sparkle release that matches Package.resolved (currently 2.9.1)
curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.9.1/Sparkle-2.9.1.tar.xz \
  | tar -xJ -C /tmp
cd /tmp/Sparkle-2.9.1

# Generate the key-pair. The private half lands in the login keychain,
# the public half is printed to stdout. Write it down, you'll need it now.
./bin/generate_keys

# Copy the printed public key into mac/PasswordFiller/Info.plist under
# SUPublicEDKey, then commit:
#   <key>SUPublicEDKey</key>
#   <string>XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX</string>

# Export the private key so GitHub Actions can sign releases with it.
./bin/generate_keys -x /tmp/sparkle-private.key

# Add the private key as a repo secret. The file already contains the
# base64-encoded key on a single line — paste its contents as the secret
# value named SPARKLE_PRIVATE_KEY in GitHub → Settings → Secrets and
# variables → Actions.
cat /tmp/sparkle-private.key

# Shred the exported file — the keychain copy is the source of truth.
rm -P /tmp/sparkle-private.key
```

Rotation: if the private key is ever compromised, generate a new pair,
bump `SUPublicEDKey` in Info.plist, update the secret, and cut a new
release. Existing installs on the old public key can still install the
first update signed by the new pair because Sparkle's update check reads
the *current* app's `SUPublicEDKey` — so the rotation is self-healing as
soon as every install has pulled one update past the rotation point.
