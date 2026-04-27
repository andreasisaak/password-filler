#!/bin/bash
# Install a launchctl-friendly copy of the LaunchAgent plist into
# ~/Library/LaunchAgents/ with an absolute Program path. Mirrors the
# production flow from PasswordFillerApp.swift — useful for forced
# re-registration during development without launching the UI.
# Keeps parity with D9 (LimitLoadToSessionType=Aqua) and D10
# (ProcessType=Interactive); the StandardOut/ErrorPath entries are
# dev-only debugging aids that the production flow omits.
#
# Historical note (Phase-3 finding G2): the original version used a
# `cat > "$TARGET" <<EOF … EOF` heredoc to write the plist. On this
# Mac (zsh host shell invoking `bash …`) the heredoc hangs silently
# — `bash -x` shows the last executed step as `+ cat`, then nothing.
# Root-cause not nailed down (line-ending suspicion, not confirmed).
# PlistBuddy is robust against that class of problem, produces a
# well-formed plist without hand-written XML, and is available on
# every macOS out of the box.

set -u

TARGET="$HOME/Library/LaunchAgents/app.passwordfiller.agent.plist"
AGENT="/Applications/PasswordFiller.app/Contents/MacOS/PasswordFillerAgent"
LABEL="app.passwordfiller.agent"
MACH_SERVICE="group.A5278RL7RX.app.passwordfiller.agent"
PLISTBUDDY="/usr/libexec/PlistBuddy"

if [[ ! -x "$AGENT" ]]; then
  echo "❌ Agent binary not found at $AGENT"
  exit 1
fi

if [[ ! -x "$PLISTBUDDY" ]]; then
  echo "❌ PlistBuddy not found at $PLISTBUDDY (unexpected on macOS)"
  exit 1
fi

# Unload any previous version (ignore errors if not loaded)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$TARGET"

# Write the plist via PlistBuddy. The -c commands run sequentially on
# the freshly-created empty plist; any error aborts with a clear
# message (PlistBuddy prints to stderr, exit code > 0).
mkdir -p "$HOME/Library/LaunchAgents"
"$PLISTBUDDY" \
  -c "Clear dict" \
  -c "Add :Label string $LABEL" \
  -c "Add :Program string $AGENT" \
  -c "Add :ProgramArguments array" \
  -c "Add :ProgramArguments:0 string $AGENT" \
  -c "Add :MachServices dict" \
  -c "Add :MachServices:$MACH_SERVICE bool true" \
  -c "Add :LimitLoadToSessionType string Aqua" \
  -c "Add :ProcessType string Interactive" \
  -c "Add :RunAtLoad bool false" \
  -c "Add :KeepAlive bool false" \
  -c "Add :StandardOutPath string /tmp/pf-agent-launchd.out" \
  -c "Add :StandardErrorPath string /tmp/pf-agent-launchd.err" \
  "$TARGET"

echo "--- plist written ---"
"$PLISTBUDDY" -c "Print" "$TARGET"

echo "--- bootstrap ---"
launchctl bootstrap "gui/$(id -u)" "$TARGET"
echo "bootstrap rc=$?"

echo "--- kickstart (on-demand trigger) ---"
launchctl kickstart -p "gui/$(id -u)/$LABEL"
echo "kickstart rc=$?"
sleep 2

echo "--- status ---"
launchctl print "gui/$(id -u)/$LABEL" 2>&1 | head -15

echo "--- socket ---"
ls -la "$HOME/Library/Application Support/app.passwordfiller/daemon.sock" 2>&1

echo "--- agent stderr ---"
cat /tmp/pf-agent-launchd.err 2>&1 | head -5
