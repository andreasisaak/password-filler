#!/bin/bash
# End-to-end smoke test for AI-agent access (specs/ai-agent-access, TESTING.md
# scenario 13) against the installed PasswordFiller.app.
#
# Usage: agent-access-smoke.sh <url>
#   url  any https URL whose host has a 1Password item tagged .htaccess
#
# Reads `mcp_enabled` from config.json and checks the matching expectations:
#   switch on : run + curl -> 200, run + Playwright -> 200, list_hosts lists the host
#   switch off: run -> exit 77, list_hosts -> isError
#   always    : a hand-started pf-nmh-bridge gets agent_unreachable
# Credential values are never printed — only status codes and exit codes.
set -uo pipefail

URL="${1:?usage: agent-access-smoke.sh <https-url-of-a-host-with-a-.htaccess-item>}"
HOST="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlsplit(sys.argv[1]).hostname)' "$URL")"
MCP=password-filler-mcp
BRIDGE=/Applications/PasswordFiller.app/Contents/MacOS/pf-nmh-bridge
CONFIG="$HOME/Library/Application Support/passwordfiller/config.json"
# Playwright 1.63.0 drives Chromium 1243, the build in ~/Library/Caches/ms-playwright.
PLAYWRIGHT_VERSION=1.63.0

failures=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1 ($3)"
    else
        echo "FAIL  $1: expected $2, got $3"
        failures=$((failures + 1))
    fi
}

command -v "$MCP" >/dev/null || { echo "FAIL  $MCP not on PATH — turn on Settings → For AI Agents once"; exit 1; }
enabled="$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1])).get("mcp_enabled",False)).lower())' "$CONFIG")"
echo "Host: $HOST — mcp_enabled: $enabled"

# (a) run + curl
curl_status="$("$MCP" run --url "$URL" -- sh -c 'curl -s -o /dev/null -w "%{http_code}" -u "$HTACCESS_USER:$HTACCESS_PASSWORD" "$0"' "$URL" 2>/dev/null)"
curl_exit=$?

# (c) MCP handshake + list_hosts -> "error" | "listed" | "missing"
list_result="$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_hosts"}}' \
    | "$MCP" | tail -1 \
    | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print("error" if r["isError"] else ("listed" if sys.argv[1] in r["content"][0]["text"].split("\n") else "missing"))' "$HOST")"

if [[ "$enabled" == "true" ]]; then
    check "run + curl" "0/200" "$curl_exit/$curl_status"

    # (b) run + Playwright with http_credentials from the environment
    script="$(mktemp -t pf-smoke).py"
    cat > "$script" <<'PY'
import os, sys
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    context = browser.new_context(http_credentials={
        "username": os.environ["HTACCESS_USER"], "password": os.environ["HTACCESS_PASSWORD"]})
    print(context.new_page().goto(sys.argv[1]).status)
    browser.close()
PY
    playwright_status="$("$MCP" run --url "$URL" -- uv run --quiet --no-project --with "playwright==$PLAYWRIGHT_VERSION" python "$script" "$URL" 2>/dev/null | tail -1)"
    rm -f "$script"
    check "run + Playwright" "200" "$playwright_status"

    check "list_hosts" "listed" "$list_result"
else
    check "run while switch off" "77" "$curl_exit"
    check "list_hosts while switch off" "error" "$list_result"
fi

# (d) hand-started bridge
bridge_reply="$(python3 -c 'import json,struct,sys;b=json.dumps({"action":"lookup","hostname":sys.argv[1]}).encode();sys.stdout.buffer.write(struct.pack("<I",len(b))+b)' "$HOST" \
    | "$BRIDGE" 2>/dev/null | tail -c +5)"
# Never echo a reply that carries credentials.
[[ "$bridge_reply" == *password* ]] && bridge_reply="<credentials returned>"
check "hand-started bridge" '{"error":"agent_unreachable"}' "$bridge_reply"

echo "$failures failure(s)"
exit $((failures > 0))
