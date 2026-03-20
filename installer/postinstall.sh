#!/bin/bash
set -e

SUPPORT_DIR="$HOME/Library/Application Support/passwordfiller"
BINARY_SRC="/Library/Application Support/passwordfiller/passwordfiller-host"
BINARY_DEST="$SUPPORT_DIR/passwordfiller-host"
CONFIG_PATH="$SUPPORT_DIR/config.json"
HOST_NAME="app.passwordfiller"
EXTENSION_ID="hgelgpkdbkoipapbeblddhgfjlebckah"
FIREFOX_EXT_ID="passwordfiller@app"

CHROME_NMH="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
BRAVE_NMH="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
FIREFOX_NMH="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
CHROME_EXT="$HOME/Library/Application Support/Google/Chrome/External Extensions"
BRAVE_EXT="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/External Extensions"
FIREFOX_EXT="$HOME/Library/Application Support/Mozilla/Extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"

# --- 1. Copy binary to user support dir ---
mkdir -p "$SUPPORT_DIR"
cp "$BINARY_SRC" "$BINARY_DEST"
chmod +x "$BINARY_DEST"

# --- 2. Install op CLI if missing ---
if ! command -v op &>/dev/null; then
  OP_VERSION="2.30.3"
  OP_PKG="/tmp/op-install.pkg"
  curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/op_darwin_universal_v${OP_VERSION}.pkg" -o "$OP_PKG"
  installer -pkg "$OP_PKG" -target /
  rm -f "$OP_PKG"
fi

# --- 3. Ask for 1Password account ---
if [ ! -f "$CONFIG_PATH" ]; then
  ACCOUNT=$(osascript -e 'display dialog "Enter your 1Password account URL:" default answer "team.1password.com" with title "Password Filler Setup"' -e 'text returned of result' 2>/dev/null || echo "")
  if [ -z "$ACCOUNT" ]; then
    osascript -e 'display alert "Setup cancelled" message "Password Filler was not fully configured. Re-run the installer to complete setup." as warning'
    exit 1
  fi
  printf '{"op_account":"%s","op_tag":".htaccess"}' "$ACCOUNT" > "$CONFIG_PATH"
fi

# --- 4. Register native messaging host ---
mkdir -p "$CHROME_NMH" "$BRAVE_NMH" "$FIREFOX_NMH"

NMH_JSON=$(printf '{
  "name": "%s",
  "description": "Password Filler — reads credentials from 1Password",
  "path": "%s",
  "type": "stdio"
}' "$HOST_NAME" "$BINARY_DEST")

CHROME_NMH_JSON=$(printf '%s,\n  "allowed_origins": ["chrome-extension://%s/"]\n}' "${NMH_JSON%?}" "$EXTENSION_ID")
echo "$CHROME_NMH_JSON" > "$CHROME_NMH/$HOST_NAME.json"
echo "$CHROME_NMH_JSON" > "$BRAVE_NMH/$HOST_NAME.json"

FIREFOX_NMH_JSON=$(printf '%s,\n  "allowed_extensions": ["%s"]\n}' "${NMH_JSON%?}" "$FIREFOX_EXT_ID")
echo "$FIREFOX_NMH_JSON" > "$FIREFOX_NMH/$HOST_NAME.json"

# --- 5. Register Chrome/Brave external extension ---
mkdir -p "$CHROME_EXT" "$BRAVE_EXT"
EXT_JSON='{"external_update_url":"https://raw.githubusercontent.com/andreasisaak/password-filler/main/updates/chrome.xml"}'
echo "$EXT_JSON" > "$CHROME_EXT/$EXTENSION_ID.json"
echo "$EXT_JSON" > "$BRAVE_EXT/$EXTENSION_ID.json"

# --- 6. Install Firefox extension ---
LATEST_XPI=$(curl -fsSL "https://api.github.com/repos/andreasisaak/password-filler/releases/latest" | grep '"browser_download_url"' | grep '\.xpi' | head -1 | sed 's/.*"browser_download_url": "\(.*\)".*/\1/')
if [ -n "$LATEST_XPI" ]; then
  XPI_PATH="/tmp/passwordfiller.xpi"
  curl -fsSL "$LATEST_XPI" -o "$XPI_PATH"
  open -a Firefox "$XPI_PATH" 2>/dev/null || true
fi

# --- 7. Done ---
osascript -e 'display notification "Restart Chrome to activate the extension. Firefox will prompt you to install the add-on." with title "Password Filler installed"'
