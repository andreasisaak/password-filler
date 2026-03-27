#!/bin/bash
set -e

BINARY_SRC="/usr/lib/passwordfiller/passwordfiller-host"
HOST_NAME="app.passwordfiller"
EXTENSION_ID="ebcpahcihmnibmplnblcikgjiicmpcff"
FIREFOX_EXT_ID="passwordfiller@app"

# Detect the user who ran sudo
INSTALL_USER="${SUDO_USER:-}"
if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = "root" ]; then
  INSTALL_USER=$(who | awk 'NR==1{print $1}' 2>/dev/null || echo "")
fi
if [ -z "$INSTALL_USER" ] || [ "$INSTALL_USER" = "root" ]; then
  echo "WARNING: Could not detect install user. Run 'passwordfiller-setup' to complete setup."
  exit 0
fi

USER_HOME=$(getent passwd "$INSTALL_USER" | cut -d: -f6)
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  exit 0
fi

SUPPORT_DIR="$USER_HOME/.config/passwordfiller"
BINARY_DEST="$SUPPORT_DIR/passwordfiller-host"
CONFIG_PATH="$SUPPORT_DIR/config.json"

CHROME_NMH="$USER_HOME/.config/google-chrome/NativeMessagingHosts"
BRAVE_NMH="$USER_HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
FIREFOX_NMH="$USER_HOME/.mozilla/native-messaging-hosts"
CHROME_EXT="$USER_HOME/.config/google-chrome/External Extensions"
BRAVE_EXT="$USER_HOME/.config/BraveSoftware/Brave-Browser/External Extensions"

# --- 1. Copy binary to user dir ---
mkdir -p "$SUPPORT_DIR"
cp "$BINARY_SRC" "$BINARY_DEST"
chmod +x "$BINARY_DEST"
chown "$INSTALL_USER" "$BINARY_DEST"

# --- 2. Ask for 1Password account ---
if [ ! -f "$CONFIG_PATH" ]; then
  echo ""
  echo "Password Filler Setup"
  echo "---------------------"
  read -rp "Enter your 1Password account URL (e.g. team.1password.com): " ACCOUNT
  if [ -z "$ACCOUNT" ]; then
    echo "Skipped. Run 'passwordfiller-setup' to configure later."
  else
    if command -v python3 &>/dev/null; then
      python3 -c "import sys, json; print(json.dumps({'op_account': sys.argv[1], 'op_tag': '.htaccess'}))" "$ACCOUNT" > "$CONFIG_PATH"
    else
      ACCOUNT_ESC=$(printf '%s' "$ACCOUNT" | sed 's/\\/\\\\/g; s/"/\\"/g')
      printf '{"op_account":"%s","op_tag":".htaccess"}\n' "$ACCOUNT_ESC" > "$CONFIG_PATH"
    fi
    chmod 600 "$CONFIG_PATH"
    chown "$INSTALL_USER" "$CONFIG_PATH"
  fi
fi

# --- 3. Register native messaging host ---
mkdir -p "$CHROME_NMH" "$BRAVE_NMH" "$FIREFOX_NMH"
chown "$INSTALL_USER" "$CHROME_NMH" "$BRAVE_NMH" "$FIREFOX_NMH"

cat > "$CHROME_NMH/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Password Filler - reads credentials from 1Password",
  "path": "$BINARY_DEST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
EOF
chown "$INSTALL_USER" "$CHROME_NMH/$HOST_NAME.json"
cp "$CHROME_NMH/$HOST_NAME.json" "$BRAVE_NMH/$HOST_NAME.json"
chown "$INSTALL_USER" "$BRAVE_NMH/$HOST_NAME.json"

cat > "$FIREFOX_NMH/$HOST_NAME.json" <<EOF
{
  "name": "$HOST_NAME",
  "description": "Password Filler - reads credentials from 1Password",
  "path": "$BINARY_DEST",
  "type": "stdio",
  "allowed_extensions": ["$FIREFOX_EXT_ID"]
}
EOF
chown "$INSTALL_USER" "$FIREFOX_NMH/$HOST_NAME.json"

# --- 4. Chrome/Brave external extension ---
mkdir -p "$CHROME_EXT" "$BRAVE_EXT"
chown "$INSTALL_USER" "$CHROME_EXT" "$BRAVE_EXT"
EXT_JSON='{"external_update_url":"https://clients2.google.com/service/update2/crx"}'
printf '%s\n' "$EXT_JSON" > "$CHROME_EXT/$EXTENSION_ID.json"
chown "$INSTALL_USER" "$CHROME_EXT/$EXTENSION_ID.json"
printf '%s\n' "$EXT_JSON" > "$BRAVE_EXT/$EXTENSION_ID.json"
chown "$INSTALL_USER" "$BRAVE_EXT/$EXTENSION_ID.json"

echo ""
echo "Password Filler installed."
echo "Chrome/Brave: Install from https://chromewebstore.google.com/detail/password-filler/ebcpahcihmnibmplnblcikgjiicmpcff"
echo "Firefox: restart Firefox — the extension will be prompted for install."
echo ""
echo "Then click the extension icon and press 'Refresh from 1Password'."
