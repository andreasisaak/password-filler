#!/bin/bash
set -u
AGENT="$HOME/Library/Developer/Xcode/DerivedData/PasswordFiller-gvdxdplililvfueqnnweckoiorkz/Build/Products/Debug/PasswordFillerAgent"
SOCK="$HOME/Library/Application Support/app.passwordfiller/daemon.sock"

rm -f /tmp/pf-agent-stdout.log /tmp/pf-agent-stderr.log
"$AGENT" > /tmp/pf-agent-stdout.log 2> /tmp/pf-agent-stderr.log &
AGENT_PID=$!
echo "started pid=$AGENT_PID"
sleep 1
if ! kill -0 "$AGENT_PID" 2>/dev/null; then
  wait "$AGENT_PID" 2>/dev/null
  echo "AGENT EXITED (code=$?)"
  echo "---stderr---"; cat /tmp/pf-agent-stderr.log
  echo "---stdout---"; cat /tmp/pf-agent-stdout.log
  exit 0
fi

echo "still running"
ls -la "$(dirname "$SOCK")"
echo "---ping---"
/tmp/pf-socket.py ping
PING_RC=$?
echo "ping rc=$PING_RC"

echo "---stderr so far---"
cat /tmp/pf-agent-stderr.log

echo "---cleanup---"
kill "$AGENT_PID" 2>/dev/null
sleep 1
rm -f "$SOCK"
