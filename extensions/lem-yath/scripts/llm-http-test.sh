#!/usr/bin/env bash
# Real-TUI, credential-free acceptance for Perplexity and Copilot Chat.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-http-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-http.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_HTTP_REPORT="$root/report"
export LEM_YATH_LLM_HTTP_LOG="$root/log"
export LEM_YATH_LLM_HTTP_CURL="$root/bin/curl"
export LEM_YATH_COPILOT_TOKEN_DIRECTORY="$root/tokens/"
export PERPLEXITY_API_KEY='perplexity-api-secret'
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-http-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-http.*) [ -d "$root" ] && rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe LLM HTTP cleanup path: %s\n' "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_YATH_LLM_HTTP_LOG" "$root/bin" \
  "$LEM_YATH_COPILOT_TOKEN_DIRECTORY"
chmod 700 "$LEM_YATH_COPILOT_TOKEN_DIRECTORY"
: >"$LEM_YATH_LLM_HTTP_REPORT"
cp "$here/scripts/llm-http-fake-curl.py" "$LEM_YATH_LLM_HTTP_CURL"
sed -i "1c#!$(command -v python3)" "$LEM_YATH_LLM_HTTP_CURL"
chmod +x "$LEM_YATH_LLM_HTTP_CURL"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_LLM_HTTP_REPORT" >&2 || true
  printf '\n--- curl files ---\n' >&2
  find "$LEM_YATH_LLM_HTTP_LOG" -maxdepth 1 -type f -printf '%f\n' \
    2>/dev/null | sort >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_HTTP_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_LLM_HTTP_REPORT"; then return 0; fi
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
    if grep -qE "$pattern" "$LEM_YATH_LLM_HTTP_REPORT"; then return 0; fi
    index=$((index + 1))
  done
  return 1
}

send_key() { lem_keys "$session" "$1"; sleep 0.15; }

fixture="$(lem-yath_lisp_string "$here/scripts/llm-http-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)"; then
  die boot 'could not start the isolated tmux/Lem process'
fi
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report '^READY$' "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the HTTP fixture'
fi
pass boot 'configured Lem loaded the isolated HTTP fixture'

send_key F2
if ! wait_report '^SUMMARY STATIC PASS failures=0$'; then
  die static-contracts 'backend, preset, curl, or session contract failed'
fi
pass static-contracts 'provider and secret-boundary contracts passed'

send_key F3
if ! wait_state '^STATE active=no perplexity=yes citations=yes '; then
  die perplexity-stream 'streamed answer or final citations were missing'
fi
pass perplexity-stream 'SSE answer and bounded citations rendered'

send_key F4
if ! wait_state 'login-code=yes login-done=yes .*github=yes'; then
  die copilot-login 'device code flow did not persist authorization'
fi
pass copilot-login 'device flow handled pending authorization and persisted token'

send_key F5
if ! wait_state 'active=no .*copilot1=yes .*github=yes session=yes modes=700/600/600'; then
  die copilot-stream 'token exchange or first Copilot stream failed'
fi
pass copilot-stream 'short-lived token exchange and SSE answer rendered'

send_key F6
if ! wait_state 'active=no .*copilot1=yes copilot2=yes .*modes=700/600/600'; then
  die copilot-renewal 'expired session token was not renewed'
fi
if [[ "$(<"$LEM_YATH_LLM_HTTP_LOG/renewal.count")" != 2 ]]; then
  die copilot-renewal 'expected exactly two Copilot token exchanges'
fi
pass copilot-renewal 'expired session token renewed automatically'

send_key F9
if ! wait_report '^RELOAD pass machine=stable method=present$'; then
  die reload 'provider reload changed identity or lost dispatch method'
fi
pass reload 'double reload preserved provider identity and dispatch'

python3 - "$LEM_YATH_LLM_HTTP_LOG" <<'PY'
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
configs = [path.read_text() for path in sorted(root.glob("curl.*.config"))]
argvs = [path.read_bytes().split(b"\0")[:-1] for path in sorted(root.glob("curl.*.argv"))]
expected_argv = [
    b"--silent", b"--show-error", b"--fail-with-body",
    b"--max-time", b"30", b"--config", b"-",
]
expected_stream_argv = [
    b"--silent", b"--show-error", b"--fail-with-body", b"--no-buffer",
    b"--max-time", b"300", b"--config", b"-",
]
for argv in argvs:
    assert argv in (expected_argv, expected_stream_argv), argv
    joined = b"\0".join(argv)
    for secret in (b"perplexity-api-secret", b"device-secret",
                   b"github-access-secret", b"copilot-session-secret",
                   b"perplexity prompt", b"copilot prompt"):
        assert secret not in joined

perplexity = next(c for c in configs if "api.perplexity.ai/chat/completions" in c)
assert "Authorization: Bearer perplexity-api-secret" in perplexity
pbody = json.loads(re.search(r'data-binary = (".*")', perplexity).group(1))
pbody = json.loads(pbody)
assert pbody["model"] == "sonar" and pbody["stream"] is True
assert pbody["messages"][-1]["content"] == "perplexity prompt"

device = next(c for c in configs if "login/device/code" in c)
assert "client_id=Iv1.b507a08c87ecfe98&scope=read%3Auser" in device
oauth = [c for c in configs if "login/oauth/access_token" in c]
assert len(oauth) == 2 and all("device_code=device-secret" in c for c in oauth)

renewals = [c for c in configs if "copilot_internal/v2/token" in c]
assert len(renewals) == 2
assert all("Authorization: token github-access-secret" in c for c in renewals)

chats = [c for c in configs if "api.githubcopilot.com/chat/completions" in c]
assert len(chats) == 2
for index, chat in enumerate(chats, 1):
    assert f"Authorization: Bearer copilot-session-secret-{index}" in chat
    assert "openai-intent: conversation-panel" in chat
    assert "copilot-integration-id: vscode-chat" in chat
    assert re.search(r"x-request-id: [0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}", chat)
    assert re.search(r"vscode-machineid: [0-9a-f]{65}", chat)
    body = json.loads(re.search(r'data-binary = (".*")', chat).group(1))
    body = json.loads(body)
    assert body["model"] == "gpt-4.1" and body["stream"] is True

all_argv = b"".join(b"\0".join(argv) for argv in argvs)
all_config = "".join(configs)
assert b"github-access-secret" not in all_argv
assert "github-access-secret" in all_config
PY
pass credential-boundary 'all secrets and request bodies stayed off process argv'

printf 'All LLM HTTP provider tests passed.\n'
