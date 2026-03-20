#!/bin/bash
# Local test installer — uses artifacts from ./dist/ instead of GitHub Releases
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/../dist"

SUPPORT_DIR="$HOME/Library/Application Support/passwordfiller"
BINARY_SRC="$DIST_DIR/passwordfiller-host"
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

LOCAL_XPI=$(find "$DIST_DIR" -name "*.xpi" | head -1)

# --- Preflight checks ---
if [ ! -f "$BINARY_SRC" ]; then
  echo "ERROR: $BINARY_SRC not found. Run 'npm run build' in host/ first."
  exit 1
fi
if [ -z "$LOCAL_XPI" ]; then
  echo "ERROR: No .xpi found in $DIST_DIR. Run 'web-ext sign' first."
  exit 1
fi

# --- 1. Install binary ---
mkdir -p "$SUPPORT_DIR"
cp "$BINARY_SRC" "$BINARY_DEST"
chmod +x "$BINARY_DEST"
echo "✓ Binary installed: $BINARY_DEST"

# --- 2. Check op CLI ---
if ! command -v op &>/dev/null; then
  echo "ERROR: op CLI not found. Install manually: brew install 1password-cli"
  exit 1
fi
echo "✓ op CLI found: $(op --version)"

# --- 3. Write config ---
if [ ! -f "$CONFIG_PATH" ]; then
  read -p "1Password account URL (e.g. team.1password.com): " ACCOUNT
  printf '{"op_account":"%s","op_tag":".htaccess"}' "$ACCOUNT" > "$CONFIG_PATH"
  echo "✓ Config saved: $CONFIG_PATH"
else
  echo "✓ Config already exists: $CONFIG_PATH"
fi

# --- 4. Register native messaging host ---
mkdir -p "$CHROME_NMH" "$BRAVE_NMH" "$FIREFOX_NMH"

NMH_CHROME=$(cat <<EOF
{
  "name": "$HOST_NAME",
  "description": "Password Filler — reads credentials from 1Password",
  "path": "$BINARY_DEST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
EOF
)
NMH_FIREFOX=$(cat <<EOF
{
  "name": "$HOST_NAME",
  "description": "Password Filler — reads credentials from 1Password",
  "path": "$BINARY_DEST",
  "type": "stdio",
  "allowed_extensions": ["$FIREFOX_EXT_ID"]
}
EOF
)

echo "$NMH_CHROME" > "$CHROME_NMH/$HOST_NAME.json"
echo "$NMH_CHROME" > "$BRAVE_NMH/$HOST_NAME.json"
echo "$NMH_FIREFOX" > "$FIREFOX_NMH/$HOST_NAME.json"
echo "✓ Native messaging registered"

# --- 5. Chrome/Brave external extension ---
mkdir -p "$CHROME_EXT" "$BRAVE_EXT"
EXT_JSON='{"external_update_url":"https://raw.githubusercontent.com/andreasisaak/password-filler/main/updates/chrome.xml"}'
echo "$EXT_JSON" > "$CHROME_EXT/$EXTENSION_ID.json"
echo "$EXT_JSON" > "$BRAVE_EXT/$EXTENSION_ID.json"
echo "✓ Chrome/Brave external extension registered"

# --- 6. Install Firefox extension ---
mkdir -p "$FIREFOX_EXT"
cp "$LOCAL_XPI" "$FIREFOX_EXT/$FIREFOX_EXT_ID.xpi"
echo "✓ Firefox extension installed: $LOCAL_XPI"

# --- 7. Done ---
echo ""
echo "Installation complete. Restart Firefox and Chrome/Brave."
