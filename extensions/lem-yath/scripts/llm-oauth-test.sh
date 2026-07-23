#!/usr/bin/env bash
# Real-TUI, credential-free acceptance for native Codex and Grok OAuth.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-oauth-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-oauth.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_OAUTH_REPORT="$root/report"
export LEM_YATH_LLM_OAUTH_LOG="$root/log"
export LEM_YATH_LLM_OAUTH_CURL="$root/bin/curl"
export LEM_YATH_LLM_OAUTH_GROK="$root/bin/grok"
export LEM_YATH_CODEX_AUTH_FILE="$HOME/.codex/auth.json"
export LEM_YATH_GROK_AUTH_FILE="$HOME/.grok/auth.json"
export LEM_YATH_CODEX_TEST_PORT=$((20000 + $$ % 20000))
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-oauth-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-oauth.*) [ -d "$root" ] && rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe LLM OAuth cleanup path: %s\n' "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME/.codex" "$HOME/.grok" "$XDG_CACHE_HOME" \
  "$LEM_YATH_LLM_OAUTH_LOG" "$root/bin"
chmod 700 "$HOME/.codex" "$HOME/.grok"
: >"$LEM_YATH_LLM_OAUTH_REPORT"
cp "$here/scripts/llm-oauth-fake-curl.py" "$LEM_YATH_LLM_OAUTH_CURL"
sed -i "1c#!$(command -v python3)" "$LEM_YATH_LLM_OAUTH_CURL"
chmod +x "$LEM_YATH_LLM_OAUTH_CURL"
cp "$here/scripts/llm-oauth-fake-grok.sh" "$LEM_YATH_LLM_OAUTH_GROK"
sed -i "1c#!$(command -v bash)" "$LEM_YATH_LLM_OAUTH_GROK"
chmod +x "$LEM_YATH_LLM_OAUTH_GROK"

base64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
access_payload="$(printf '%s' '{"exp":4102444800}' | base64url)"
id_payload="$(printf '%s' '{"exp":4102444800,"https://api.openai.com/auth":{"chatgpt_account_id":"acct-native"}}' | base64url)"
printf '%s\n' "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null,\"unknown_top\":\"preserve-me\",\"tokens\":{\"access_token\":\"x.$access_payload.y\",\"id_token\":\"x.$id_payload.y\",\"refresh_token\":\"codex-initial-refresh-secret\",\"account_id\":\"acct-native\"},\"last_refresh\":\"2026-01-01T00:00:00.000Z\"}" >"$LEM_YATH_CODEX_AUTH_FILE"
printf '%s\n' '{"https://auth.x.ai::device":{"key":"grok-expired-secret","user_id":"grok-user-1","expires_at":"2000-01-01T00:00:00Z"}}' >"$LEM_YATH_GROK_AUTH_FILE"
chmod 600 "$LEM_YATH_CODEX_AUTH_FILE" "$LEM_YATH_GROK_AUTH_FILE"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-25}"

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,320p' "$LEM_YATH_LLM_OAUTH_REPORT" >&2 || true
  printf '\n--- protocol files ---\n' >&2
  find "$LEM_YATH_LLM_OAUTH_LOG" -maxdepth 1 -type f -printf '%f\n' \
    2>/dev/null | sort >&2 || true
  exit 1
}

wait_report() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_LLM_OAUTH_REPORT"; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_state() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    lem_keys "$session" F12
    sleep 0.25
    if grep -qE "$pattern" "$LEM_YATH_LLM_OAUTH_REPORT"; then return 0; fi
    index=$((index + 1))
  done
  return 1
}

send_key() { lem_keys "$session" "$1"; sleep 0.15; }

fixture="$(lem-yath_lisp_string "$here/scripts/llm-oauth-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)"; then
  die boot 'could not start the isolated tmux/Lem process'
fi
if ! wait_report '^READY$' "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the OAuth fixture'
fi
pass boot 'configured Lem loaded the isolated OAuth fixture'

send_key F2
if ! wait_report '^SUMMARY STATIC PASS failures=0$'; then
  die static-contracts 'payload, auth, header, preset, or PKCE contract failed'
fi
pass static-contracts 'native provider and PKCE contracts passed'

send_key F3
if ! wait_report '^REFRESH pass preserve=yes rotated=yes mode=600$'; then
  die codex-refresh 'token refresh did not preserve compatible auth state'
fi
pass codex-refresh 'refresh rotation preserved CLI auth fields and permissions'

send_key F4
if ! wait_state '^STATE active=no codex=yes .*tools=yes codex-history=4 '; then
  die codex-native '401 renewal, Responses stream, or tool loop failed'
fi
if [[ "$(<"$LEM_YATH_LLM_OAUTH_LOG/codex-refresh.count")" != 2 ]] ||
   [[ "$(<"$LEM_YATH_LLM_OAUTH_LOG/codex-chat.count")" != 3 ]]; then
  die codex-native 'expected one explicit refresh, one 401 refresh, and three rounds'
fi
pass codex-native '401 renewal and Responses tool loop completed'

send_key F5
if ! wait_state '^STATE active=no codex=yes grok=yes tools=yes codex-history=4 grok-history=5 '; then
  die grok-native 'CLI refresh, proxy stream, or tool loop failed'
fi
if [[ "$(<"$LEM_YATH_LLM_OAUTH_LOG/grok-refresh.count")" != 1 ]]; then
  die grok-native 'expired Grok credential was not refreshed exactly once'
fi
pass grok-native 'official-CLI refresh and chat tool loop completed'

send_key F6
if ! wait_state 'login-wait=yes' || ! wait_report '^LOGIN_STATE [A-Za-z0-9_-]+$'; then
  die codex-login 'PKCE login URL or callback state was not published'
fi
state="$(grep -E '^LOGIN_STATE [A-Za-z0-9_-]+$' "$LEM_YATH_LLM_OAUTH_REPORT" | tail -1 | cut -d' ' -f2)"
if ! timeout 5 bash -c '
  exec 3<>/dev/tcp/127.0.0.1/"$1"
  printf "GET /auth/callback?code=login-code-secret&state=%s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" "$2" >&3
  cat <&3 >/dev/null
' _ "$LEM_YATH_CODEX_TEST_PORT" "$state"; then
  die codex-login 'could not complete the loopback callback'
fi
if ! wait_state 'login-done=yes auth-mode=600'; then
  die codex-login 'authorization-code exchange was not persisted'
fi
pass codex-login 'loopback PKCE exchange persisted private CLI-compatible auth'

send_key F9
if ! wait_report '^RELOAD pass codex=present grok=present$'; then
  die reload 'double reload lost a native backend method'
fi
pass reload 'double reload retained both dispatch methods'

python3 - "$LEM_YATH_LLM_OAUTH_LOG" "$LEM_YATH_CODEX_AUTH_FILE" <<'PY'
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
auth = json.loads(Path(sys.argv[2]).read_text())
configs = [path.read_text() for path in sorted(root.glob("curl.*.config"))]
argvs = [path.read_bytes().split(b"\0")[:-1] for path in sorted(root.glob("curl.*.argv"))]
plain = [
    b"--silent", b"--show-error", b"--fail-with-body",
    b"--max-time", b"30", b"--config", b"-",
]
stream = [
    b"--silent", b"--show-error", b"--fail-with-body", b"--no-buffer",
    b"--write-out", b"\\n__LEM_YATH_HTTP_STATUS__:%{http_code}\\n",
    b"--max-time", b"300", b"--config", b"-",
]
for argv in argvs:
    assert argv in (plain, stream), argv
    joined = b"\0".join(argv)
    for secret in (
        b"codex-initial-refresh-secret", b"codex-rotated-refresh-secret",
        b"codex-access-secret", b"grok-expired-secret",
        b"grok-refreshed-secret", b"codex native prompt",
        b"grok native prompt", b"login-code-secret",
    ):
        assert secret not in joined

refreshes = [c for c in configs if "auth.openai.com/oauth/token" in c and "grant_type=refresh_token" in c]
login = [c for c in configs if "auth.openai.com/oauth/token" in c and "grant_type=authorization_code" in c]
assert len(refreshes) == 2 and len(login) == 1
assert "code=login-code-secret" in login[0]
assert "code_verifier=" in login[0]

codex = [c for c in configs if "chatgpt.com/backend-api/codex/responses" in c]
assert len(codex) == 3
session_ids = []
cache_keys = []
for config in codex:
    assert "OpenAI-Beta: responses=experimental" in config
    assert "originator: codex_cli_rs" in config
    session_match = re.search(r"session_id: ([0-9A-Fa-f-]{36})", config)
    assert session_match, config
    session_ids.append(session_match.group(1).lower())
    body = json.loads(json.loads(re.search(r'data-binary = (".*")', config).group(1)))
    assert body["model"] == "gpt-5.4" and body["store"] is False
    assert body["stream"] is True and body["parallel_tool_calls"] is True
    assert body["reasoning"] == {"effort": "medium", "summary": "auto"}
    assert all("function" not in tool and tool["type"] == "function" for tool in body["tools"])
    cache_keys.append(body["prompt_cache_key"])
assert len(set(session_ids)) == 1 and len(set(cache_keys)) == 1
final_codex_body = json.loads(json.loads(re.search(r'data-binary = (".*")', codex[-1]).group(1)))
types = [item["type"] for item in final_codex_body["input"]]
assert types == ["message", "function_call", "function_call_output"], types

grok = [c for c in configs if "cli-chat-proxy.grok.com/v1/chat/completions" in c]
assert len(grok) == 2
for config in grok:
    assert "Authorization: Bearer grok-refreshed-secret" in config
    assert "X-XAI-Token-Auth: xai-grok-cli" in config
    assert "x-grok-client-version: 0.1.211" in config
    assert "x-grok-client-identifier: grok-shell" in config
    assert "x-grok-model-override: grok-build" in config
final_grok_body = json.loads(json.loads(re.search(r'data-binary = (".*")', grok[-1]).group(1)))
roles = [message["role"] for message in final_grok_body["messages"]]
assert roles == ["system", "user", "assistant", "tool"], roles

assert auth["auth_mode"] == "chatgpt"
assert auth["tokens"]["account_id"] == "acct-native-login"
assert auth["tokens"]["refresh_token"] == "codex-login-refresh-secret"

grok_argv = (root / "grok.argv").read_bytes().split(b"\0")[:-1]
assert grok_argv.count(b"models") == 1
assert b"version" in grok_argv
for secret in (b"grok-refreshed-secret", b"codex-login-refresh-secret"):
    assert secret not in (root / "grok.argv").read_bytes()
PY
pass credential-boundary 'tokens, headers, payloads, history, and CLI argv are exact and isolated'

printf 'All native OAuth LLM tests passed.\n'
