#!/bin/bash
echo "--- agent os_log letzte 3m ---"
log show --style compact --predicate 'subsystem BEGINSWITH "app.passwordfiller.agent"' --last 3m 2>&1 | tail -25
echo "--- agent stderr ---"
cat /tmp/pf-agent-launchd.err 2>&1 | tail -20
echo "--- running op subprocesses ---"
ps auxww | grep "[/ ]op " | grep -v grep || echo "(keine)"
echo "--- agent process state ---"
ps auxww | grep PasswordFillerAgent | grep -v grep || echo "(nicht aktiv)"
