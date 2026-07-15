#!/usr/bin/env bash
# Authenticated MCP and physical diff-review coverage for the Claude bridge.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-claude-bridge-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-claude-bridge.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_CLAUDE_MCP_PORT=$((30000 + $$ % 20000))
export LEM_YATH_CLAUDE_MCP_TOKEN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
mkdir -p "$HOME" "$XDG_CACHE_HOME"

source "$here/scripts/tui-driver.sh"

session="lem-yath-claude-bridge-$id"
source_file="$root/source.txt"
endpoint="http://127.0.0.1:$LEM_YATH_CLAUDE_MCP_PORT/mcp"
headers="$root/headers"
body="$root/body"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  lem_keys "$session" Enter
}

mcp_post() {
  local payload=$1
  shift
  curl --silent --show-error --dump-header "$headers" --output "$body" \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $LEM_YATH_CLAUDE_MCP_TOKEN" \
    "$@" --data-binary "$payload" "$endpoint"
}

tool_text() {
  python3 - "$body" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    response = json.load(stream)
print(response["result"]["content"][0]["text"])
PY
}

tool_payload() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

request_id, name, arguments = sys.argv[1:]
print(json.dumps({
    "jsonrpc": "2.0",
    "id": int(request_id),
    "method": "tools/call",
    "params": {"name": name, "arguments": json.loads(arguments)},
}, separators=(",", ":")))
PY
}

printf 'bridge original\n' >"$source_file"
fixture="$(lem-yath_lisp_string "$here/scripts/claude-bridge-fixture.lisp")"
lem_start "$session" --eval "(load #P$fixture)" "$source_file"

if lem_wait_for "$session" 'bridge original' 40 >/dev/null; then
  pass installed-boot 'the installed wrapper opened the source buffer'
else
  fail installed-boot 'the installed wrapper did not become ready' "$session"
  exit 1
fi

if mx lem-yath-claude-bridge-start &&
   lem_wait_for "$session" 'Claude bridge ready' 15 >/dev/null; then
  pass bridge-start 'M-x started the loopback bridge without a prompt'
else
  fail bridge-start 'the bridge command did not start the endpoint' "$session"
  exit 1
fi

config=$(find "$XDG_CACHE_HOME/lem-yath" -maxdepth 1 \
  -name 'claude-mcp-*.json' -print -quit 2>/dev/null || true)
if [ -n "$config" ] && [ "$(stat -c '%a' "$config")" = 600 ] &&
   [ "$(stat -c '%a' "$(dirname "$config")")" = 700 ] &&
   grep -Fq '"type":"http"' "$config" &&
   grep -Fq "Bearer $LEM_YATH_CLAUDE_MCP_TOKEN" "$config" &&
   python3 - <<'PY'
import os
import pathlib

token = os.environ["LEM_YATH_CLAUDE_MCP_TOKEN"].encode()
for commandline in pathlib.Path("/proc").glob("[0-9]*/cmdline"):
    try:
        assert token not in commandline.read_bytes()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        pass
PY
then
  pass private-config 'mode-0600 config contains the token, while process argv does not'
else
  fail private-config 'the private MCP config or argv boundary is wrong'
fi

unauth_code=$(curl --silent --output "$root/unauth" --write-out '%{http_code}' \
  --header 'Content-Type: application/json' \
  --data-binary '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "$endpoint" || true)
if [ "$unauth_code" = 401 ] && grep -Fq 'Unauthorized' "$root/unauth"; then
  pass authentication 'requests without the bearer token receive HTTP 401'
else
  fail authentication "unauthenticated request returned HTTP $unauth_code"
fi

mcp_post \
  '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"lem-yath-test","version":"1"}}}'
session_id=$(awk 'BEGIN{IGNORECASE=1} /^Mcp-Session-Id:/{gsub("\r", "", $2); print $2}' "$headers")
if [ -n "$session_id" ] &&
   python3 - "$body" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)["result"]
assert result["serverInfo"]["name"] == "lem-mcp-server"
assert "tools" in result["capabilities"]
PY
then
  pass initialize 'authenticated MCP initialization returned a session'
else
  fail initialize 'the authenticated initialize handshake failed'
  exit 1
fi

mcp_post \
  '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' \
  --header "Mcp-Session-Id: $session_id"
if python3 - "$body" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    tools = json.load(stream)["result"]["tools"]
names = {tool["name"] for tool in tools}
required = {"buffer_list", "buffer_get_content", "editor_get_screen", "openDiff", "checkDiff"}
assert required <= names, (required - names)
assert "eval_expression" not in names
assert "command_execute" not in names
PY
then
  pass tool-policy 'review and inspection tools are present; eval and command tools are hidden'
else
  fail tool-policy 'the advertised MCP tool policy is unsafe or incomplete'
fi

mcp_post \
  '{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"file:///etc/passwd"}}' \
  --header "Mcp-Session-Id: $session_id"
if grep -Fq 'file:// resources are disabled' "$body"; then
  pass file-boundary 'arbitrary file resources are disabled by default'
else
  fail file-boundary 'the MCP resource endpoint exposed an arbitrary file'
fi

arguments=$(python3 - "$source_file" <<'PY'
import json
import sys
print(json.dumps({
    "old_file_path": sys.argv[1],
    "new_file_contents": "bridge accepted\nsecond line\n",
    "tab_name": "accept-review",
}, separators=(",", ":")))
PY
)
payload=$(tool_payload 5 openDiff "$arguments")
mcp_post "$payload" --header "Mcp-Session-Id: $session_id"
review_id=$(tool_text | python3 -c 'import json,sys; print(json.load(sys.stdin)["review_id"])')
if [ -n "$review_id" ] &&
   lem_wait_for "$session" 'Review .* y accept, q reject' 15 >/dev/null &&
   lem_wait_for "$session" 'bridge accepted' 15 >/dev/null; then
  pass review-open 'MCP opened a focused, read-only unified diff without mutating the file'
else
  fail review-open 'openDiff did not produce the review buffer' "$session"
fi

lem_keys "$session" y
if lem_wait_for "$session" 'bridge accepted' 15 >/dev/null &&
   grep -Fqx 'bridge original' "$source_file"; then
  pass review-accept 'physical y applied the proposal to the live buffer but did not save it'
else
  fail review-accept 'physical acceptance did not restore the edited source buffer' "$session"
fi

payload=$(tool_payload 6 checkDiff "{\"review_id\":\"$review_id\"}")
mcp_post "$payload" --header "Mcp-Session-Id: $session_id"
if [ "$(tool_text | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" = accepted ]; then
  pass review-status 'checkDiff reported the user acceptance'
else
  fail review-status 'checkDiff did not report acceptance'
fi

lem_keys "$session" u
if lem_wait_for "$session" 'bridge original' 15 >/dev/null &&
   ! lem_capture "$session" | grep -Fq 'bridge accepted'; then
  pass review-undo 'the accepted proposal is one ordinary undo transaction'
else
  fail review-undo 'one normal-state undo did not restore the original buffer' "$session"
fi

arguments=$(python3 - "$source_file" <<'PY'
import json
import sys
print(json.dumps({
    "old_file_path": sys.argv[1],
    "new_file_contents": "bridge rejected\n",
    "tab_name": "reject-review",
}, separators=(",", ":")))
PY
)
payload=$(tool_payload 7 openDiff "$arguments")
mcp_post "$payload" --header "Mcp-Session-Id: $session_id"
reject_id=$(tool_text | python3 -c 'import json,sys; print(json.load(sys.stdin)["review_id"])')
lem_wait_for "$session" 'bridge rejected' 15 >/dev/null ||
  fail review-reject 'the rejection proposal did not open' "$session"
lem_keys "$session" q
sleep 0.5
payload=$(tool_payload 8 checkDiff "{\"review_id\":\"$reject_id\"}")
mcp_post "$payload" --header "Mcp-Session-Id: $session_id"
if [ "$(tool_text | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" = rejected ] &&
   lem_capture "$session" | grep -Fq 'bridge original' &&
   ! lem_capture "$session" | grep -Fq 'bridge rejected'; then
  pass review-reject 'physical q rejected the proposal and preserved the live buffer'
else
  fail review-reject 'the rejected proposal changed or displaced the source buffer' "$session"
fi

arguments=$(python3 - "$source_file" <<'PY'
import json
import sys
print(json.dumps({
    "old_file_path": sys.argv[1],
    "new_file_contents": "stale proposal\n",
    "tab_name": "stale-review",
}, separators=(",", ":")))
PY
)
payload=$(tool_payload 9 openDiff "$arguments")
mcp_post "$payload" --header "Mcp-Session-Id: $session_id"
stale_id=$(tool_text | python3 -c 'import json,sys; print(json.load(sys.stdin)["review_id"])')
lem_wait_for "$session" 'stale proposal' 15 >/dev/null ||
  fail review-stale 'the stale proposal did not open' "$session"
lem_keys "$session" F9
lem_keys "$session" y
lem_wait_for "$session" 'stale' 15 >/dev/null ||
  fail review-stale 'accepting a stale proposal did not report refusal' "$session"
payload=$(tool_payload 10 checkDiff "{\"review_id\":\"$stale_id\"}")
mcp_post "$payload" --header "Mcp-Session-Id: $session_id"
if [ "$(tool_text | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" = stale ] &&
   lem_capture "$session" | grep -Fq 'external bridge original' &&
   ! lem_capture "$session" | grep -Fq 'stale proposal'; then
  pass review-stale 'a concurrent source edit made the proposal fail closed'
else
  fail review-stale 'the stale proposal overwrote or displaced the concurrent edit' "$session"
fi
lem_keys "$session" u
lem_wait_for "$session" 'bridge original' 10 >/dev/null ||
  fail review-stale-undo 'the test mutation could not be undone' "$session"

if mx lem-yath-claude-bridge-stop &&
   lem_wait_for "$session" 'Claude bridge stopped' 10 >/dev/null; then
  sleep 0.5
  stopped_code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 1 "$endpoint" 2>/dev/null || true)
  if [ ! -e "$config" ] && [ "$stopped_code" = 000 ]; then
    pass bridge-stop 'M-x stopped the endpoint and removed the private config'
  else
    fail bridge-stop 'the endpoint or its private config survived stop'
  fi
else
  fail bridge-stop 'the bridge stop command did not complete' "$session"
fi

if [ "$failed" = 0 ]; then
  echo 'CLAUDE BRIDGE TEST PASSED'
else
  echo 'CLAUDE BRIDGE TEST FAILED'
  exit 1
fi
