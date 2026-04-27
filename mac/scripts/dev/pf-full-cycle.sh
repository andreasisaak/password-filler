#!/bin/bash
# Rebuild, resign agent, restart via launchctl, test.
set -u
cd /Users/isaak/sites/password-filler/mac

echo "--- rebuild agent ---"
xcodebuild build \
  -project PasswordFiller.xcodeproj \
  -target PasswordFillerAgent \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  > /tmp/pf-cycle.log 2>&1 &
BGPID=$!
sleep 10
ps auxww | grep -E "clang.*-x c -c /dev/null" | grep -v grep | awk '{print $2}' | xargs -n1 -I{} kill {} 2>/dev/null
wait "$BGPID"
RC=$?
if [[ $RC -ne 0 ]]; then
  echo "BUILD FAILED"
  grep -E "error:" /tmp/pf-cycle.log | head -10
  exit 1
fi
echo "✅ build"

echo "--- copy + sign into /Applications ---"
cp -f /Users/isaak/sites/password-filler/mac/build/Debug/PasswordFillerAgent \
      /Applications/PasswordFiller.app/Contents/MacOS/PasswordFillerAgent
codesign --force --options runtime --sign "Developer ID Application: Andreas Isaak (A5278RL7RX)" \
  /Applications/PasswordFiller.app/Contents/MacOS/PasswordFillerAgent 2>&1 | head -3

echo "--- kick launchd agent ---"
launchctl bootout "gui/$(id -u)/app.passwordfiller.agent" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/app.passwordfiller.agent.plist"
launchctl kickstart -p "gui/$(id -u)/app.passwordfiller.agent"
sleep 2

echo "--- agent state ---"
launchctl print "gui/$(id -u)/app.passwordfiller.agent" 2>&1 | grep -E "state|pid"
ls -la "$HOME/Library/Application Support/app.passwordfiller/daemon.sock" 2>&1

echo "--- refresh test ---"
time "$(dirname "$0")/pf-socket.py" refresh | python3 -c 'import sys,json; d=json.load(sys.stdin); print("items:",len(d.get("items",[]))); print("error:", d.get("error"))'
