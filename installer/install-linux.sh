#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SUPPORT_DIR="$HOME/.config/passwordfiller"
BINARY_SRC="$SCRIPT_DIR/passwordfiller-host-linux"
BINARY_DEST="$SUPPORT_DIR/passwordfiller-host"
CONFIG_PATH="$SUPPORT_DIR/config.json"
HOST_NAME="app.passwordfiller"
EXTENSION_ID="ebcpahcihmnibmplnblcikgjiicmpcff"
FIREFOX_EXT_ID="passwordfiller@app"

CHROME_NMH="$HOME/.config/google-chrome/NativeMessagingHosts"
BRAVE_NMH="$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
FIREFOX_NMH="$HOME/.mozilla/native-messaging-hosts"

# --- Preflight ---
if [ ! -f "$BINARY_SRC" ]; then
  echo "ERROR: $BINARY_SRC not found. Make sure the binary is in the same directory as this script."
  exit 1
fi

# --- 1. Install binary ---
mkdir -p "$SUPPORT_DIR"
cp "$BINARY_SRC" "$BINARY_DEST"
chmod +x "$BINARY_DEST"
echo "Binary installed: $BINARY_DEST"

# --- 2. Check 1Password CLI ---
if ! command -v op &>/dev/null; then
  echo ""
  echo "WARNING: 1Password CLI (op) not found."
  echo "Install it: https://developer.1password.com/docs/cli/get-started/#install"
  echo ""
fi

# --- 3. Config ---
if [ ! -f "$CONFIG_PATH" ]; then
  echo ""
  read -rp "1Password account URL (e.g. team.1password.com): " ACCOUNT
  if [ -z "$ACCOUNT" ]; then
    echo "ERROR: No account URL provided. Run this script again to configure."
    exit 1
  fi
  if command -v python3 &>/dev/null; then
    python3 -c "import sys, json; print(json.dumps({'op_account': sys.argv[1], 'op_tag': '.htaccess'}))" "$ACCOUNT" > "$CONFIG_PATH"
  else
    ACCOUNT_ESC=$(printf '%s' "$ACCOUNT" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"op_account":"%s","op_tag":".htaccess"}\n' "$ACCOUNT_ESC" > "$CONFIG_PATH"
  fi
  chmod 600 "$CONFIG_PATH"
  echo "Config saved: $CONFIG_PATH"
else
  echo "Config already exists: $CONFIG_PATH"
fi

# --- 4. Register native messaging host ---
mkdir -p "$CHROME_NMH" "$BRAVE_NMH" "$FIREFOX_NMH"

cat > "$CHROME_NMH/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Password Filler - reads credentials from 1Password",
  "path": "$BINARY_DEST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
EOF

cp "$CHROME_NMH/$HOST_NAME.json" "$BRAVE_NMH/$HOST_NAME.json"

cat > "$FIREFOX_NMH/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Password Filler - reads credentials from 1Password",
  "path": "$BINARY_DEST",
  "type": "stdio",
  "allowed_extensions": ["$FIREFOX_EXT_ID"]
}
EOF
echo "Native messaging registered"

# --- 5. Install Firefox extension ---
LATEST_XPI=""
if command -v curl &>/dev/null; then
  GITHUB_RESPONSE=$(curl --fail -sSL "https://api.github.com/repos/andreasisaak/password-filler/releases/latest" 2>/dev/null || echo "")
  if [ -n "$GITHUB_RESPONSE" ] && command -v python3 &>/dev/null; then
    LATEST_XPI=$(printf '%s' "$GITHUB_RESPONSE" | python3 -c \
      "import sys, json; data = json.load(sys.stdin); urls = [a['browser_download_url'] for a in data.get('assets', []) if a['name'].endswith('.xpi')]; print(urls[0] if urls else '')" \
      2>/dev/null || echo "")
  fi
  if [ -z "$LATEST_XPI" ] && [ -n "$GITHUB_RESPONSE" ]; then
    LATEST_XPI=$(printf '%s' "$GITHUB_RESPONSE" | grep '"browser_download_url"' | grep '\.xpi' | head -1 | sed 's/.*"browser_download_url": "\(.*\)".*/\1/' || echo "")
  fi
fi

if [ -n "$LATEST_XPI" ]; then
  XPI_PATH=$(mktemp /tmp/passwordfiller.XXXXXX.xpi)
  if curl --fail -sSL "$LATEST_XPI" -o "$XPI_PATH" 2>/dev/null; then
    echo ""
    echo "Firefox extension downloaded: $XPI_PATH"
    if command -v firefox &>/dev/null; then
      firefox "$XPI_PATH" 2>/dev/null &
      echo "Firefox should prompt you to install the extension."
    else
      echo "Open this file in Firefox to install: $XPI_PATH"
    fi
  fi
fi

# --- 6. Done ---
echo ""
echo "Done. Install the Chrome extension from:"
echo "https://chromewebstore.google.com/detail/password-filler/ebcpahcihmnibmplnblcikgjiicmpcff"
echo ""
echo "Then click the extension icon and press 'Refresh from 1Password'."
