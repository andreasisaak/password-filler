#!/bin/bash
# Stoppt alle Agents, löscht Socket, startet frisch signiertes Binary.
# Läuft in der *aktuellen* Shell, damit OP-Session env-Vars erben könnten.
set -u

AGENT="/Users/isaak/sites/password-filler/mac/build/Debug/PasswordFillerAgent"
SOCK="$HOME/Library/Application Support/app.passwordfiller/daemon.sock"

pkill -9 -f PasswordFillerAgent 2>/dev/null
sleep 1
echo "--- Running agents ---"
ps auxww | grep PasswordFillerAgent | grep -v grep || echo "(alle tot)"

rm -f "$SOCK"

"$AGENT" > /tmp/pf-agent.out 2> /tmp/pf-agent.err &
NEW=$!
echo "startet pid=$NEW"
sleep 2

if ps -p "$NEW" >/dev/null; then
  echo "✅ lebt"
else
  echo "❌ sofort beendet"
  echo "--- stderr ---"
  cat /tmp/pf-agent.err
  echo "--- latest crash report ---"
  ls -t "$HOME/Library/Logs/DiagnosticReports/"PasswordFillerAgent* 2>/dev/null | head -1 | xargs -I{} head -40 {}
fi
