#!/usr/bin/env bash
# Real-TUI acceptance for cached asynchronous ChatGPT Codex model discovery.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-codex-models-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-codex-models.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_CODEX_AUTH_FILE="$HOME/.codex/auth.json"
export LEM_YATH_CODEX_MODEL_CACHE="$root/model-cache/models.json"
export LEM_YATH_CODEX_MODEL_REFRESH=1
export LEM_YATH_LLM_CODEX_MODELS_REPORT="$root/report"
export LEM_YATH_LLM_CODEX_MODELS_LOG="$root/log"
export LEM_YATH_LLM_CODEX_MODELS_CURL="$root/bin/curl"
mkdir -p "$HOME/.codex" "$XDG_CACHE_HOME" "$root/bin" "$root/log" \
  "$(dirname "$LEM_YATH_CODEX_MODEL_CACHE")"
chmod 700 "$HOME/.codex" "$(dirname "$LEM_YATH_CODEX_MODEL_CACHE")"
printf '%s\n' \
  '{"version":1,"models":["gpt-5.3-codex","unknown","gpt-5.3-codex"]}' \
  >"$LEM_YATH_CODEX_MODEL_CACHE"
chmod 600 "$LEM_YATH_CODEX_MODEL_CACHE"
cp "$here/scripts/llm-codex-models-fake-curl.py" "$root/bin/curl"
sed -i "1c#!$(command -v python3)" "$root/bin/curl"
chmod +x "$root/bin/curl"
printf '%s\n' '#!/usr/bin/env bash' \
  'touch "$LEM_YATH_LLM_CODEX_MODELS_LOG/browser-opened"' \
  >"$root/bin/xdg-open"
chmod +x "$root/bin/xdg-open"
export PATH="$root/bin:$PATH"

base64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
access_payload="$(printf '%s' '{"exp":4102444800}' | base64url)"
printf '%s\n' \
  "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"x.$access_payload.y\",\"refresh_token\":\"codex-model-refresh-secret\",\"account_id\":\"acct-model-test\"}}" \
  >"$LEM_YATH_CODEX_AUTH_FILE"
chmod 600 "$LEM_YATH_CODEX_AUTH_FILE"

source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-codex-models-$id"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-25}"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-codex-models.*) [ -d "$root" ] && rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe Codex model-test cleanup path: %s\n' \
         "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,300p' "$LEM_YATH_LLM_CODEX_MODELS_REPORT" >&2 || true
  printf '\n--- protocol files ---\n' >&2
  find "$LEM_YATH_LLM_CODEX_MODELS_LOG" -maxdepth 1 -type f -printf '%f\n' \
    2>/dev/null | sort >&2 || true
  exit 1
}

wait_report() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_LLM_CODEX_MODELS_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_probe_count() {
  local expected=$1 timeout=${2:-$WAIT_TIMEOUT} index=0 value
  while ((index < timeout * 4)); do
    value="$(cat "$LEM_YATH_LLM_CODEX_MODELS_LOG/curl.count" 2>/dev/null || true)"
    if [[ "$value" == "$expected" ]]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_state() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    lem_keys "$session" F3
    sleep 0.25
    if grep -qE "$pattern" "$LEM_YATH_LLM_CODEX_MODELS_REPORT" 2>/dev/null; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

send_key() { lem_keys "$session" "$1"; sleep 0.15; }
send_literal() { tmux_cmd send-keys -t "$session" -l -- "$1"; sleep 0.2; }

start_fixture() {
  local fixture
  fixture="$(lem-yath_lisp_string "$here/scripts/llm-codex-models-fixture.lisp")"
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" &&
    wait_report '^READY ' "$BOOT_TIMEOUT"
}

if ! start_fixture; then
  die boot 'could not start the isolated cached-model phase'
fi
if ! grep -qE \
  '^READY source=CACHE values=gpt-5.3-codex timer=yes$' \
  "$LEM_YATH_LLM_CODEX_MODELS_REPORT"; then
  die cache-startup 'private cache was not loaded before probing'
fi
pass cache-startup 'cached supported models were available immediately'

send_key F2
if ! wait_report '^SUMMARY STATIC PASS failures=0$'; then
  die static-contracts 'candidate, payload, preset, or menu contract failed'
fi
pass static-contracts 'Emacs candidate and compatible-preset contracts passed'

if ! wait_probe_count 4; then
  die idle-refresh 'five-second idle timer did not probe all four candidates'
fi
if ! wait_state \
  '^STATE source=NETWORK count=2 values=gpt-5.4,gpt-5.3-codex model=gpt-5.3-codex running=no timer=no$'; then
  die idle-refresh 'supported 200/429 models were not applied in policy order'
fi
pass idle-refresh 'asynchronous probes accepted HTTP 200 and 429 only'

python3 - "$LEM_YATH_LLM_CODEX_MODELS_LOG" \
  "$LEM_YATH_CODEX_MODEL_CACHE" <<'PY'
import json
from pathlib import Path
import re
import stat
import sys

root = Path(sys.argv[1])
cache = Path(sys.argv[2])
expected_models = ["gpt-5.4", "gpt-5.3-codex", "gpt-5.2-codex", "gpt-5-codex"]
for number, model in enumerate(expected_models, 1):
    argv = (root / f"curl.{number}.argv").read_bytes().split(b"\0")[:-1]
    assert argv == [
        b"--silent", b"--show-error", b"--fail-with-body",
        b"--write-out", b"\\n__LEM_YATH_HTTP_STATUS__:%{http_code}\\n",
        b"--max-time", b"30", b"--config", b"-",
    ], argv
    joined = b"\0".join(argv)
    for secret in (b"codex-model-refresh-secret", b"acct-model-test", b"Reply with exactly OK"):
        assert secret not in joined
    config = (root / f"curl.{number}.config").read_text(encoding="utf-8")
    assert 'request = "POST"' in config
    assert 'url = "https://chatgpt.com/backend-api/codex/responses"' in config
    assert "Authorization: Bearer x." in config
    assert "chatgpt-account-id: acct-model-test" in config
    assert "originator: codex_cli_rs" in config
    assert re.search(r"session_id: [0-9A-Fa-f-]{36}", config)
    match = re.search(r'^data-binary = (".*")$', config, re.MULTILINE)
    body = json.loads(json.loads(match.group(1)))
    assert body == {
        "model": model,
        "instructions": "You are Codex, based on GPT-5. You are running as a coding agent in the Codex CLI on a user's computer.",
        "input": [{
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": "Reply with exactly OK."}],
        }],
        "store": False,
        "stream": True,
    }

assert stat.S_IMODE(cache.stat().st_mode) == 0o600
assert stat.S_IMODE(cache.parent.stat().st_mode) == 0o700
assert json.loads(cache.read_text(encoding="utf-8")) == {
    "version": 1,
    "models": ["gpt-5.4", "gpt-5.3-codex"],
}
assert not list(cache.parent.glob("models.json.tmp.*"))
PY
pass secure-refresh 'credentials stayed off argv and cache replacement stayed private'

send_key Space
send_key g
send_key l
if ! lem_wait_for "$session" 'open full LLM menu' "$WAIT_TIMEOUT" >/dev/null; then
  die compact-menu 'SPC g l did not open the compact preset menu'
fi
send_key m
if ! lem_wait_for "$session" 'response tokens:' "$WAIT_TIMEOUT" >/dev/null; then
  die full-menu 'compact m did not open the full LLM menu'
fi
send_key m
if ! lem_wait_for "$session" 'Model:' "$WAIT_TIMEOUT" >/dev/null; then
  die model-prompt 'full-menu model action did not open catalog completion'
fi
for _ in $(seq 1 20); do send_key BSpace; done
send_literal 5.4
if ! lem_wait_for "$session" 'gpt-5.4' "$WAIT_TIMEOUT" >/dev/null; then
  die model-completion 'partial input did not expose the supported candidate'
fi
send_key Enter
send_key q
if ! wait_state 'model=gpt-5.4 running=no timer=no$'; then
  die model-selection 'completion did not select the supported Codex model'
fi
pass model-selection 'physical menu completion selected a discovered model'

lem_stop "$session"
: >"$LEM_YATH_LLM_CODEX_MODELS_REPORT"
rm -f "$LEM_YATH_CODEX_AUTH_FILE"
if ! start_fixture; then
  die restart 'could not start the missing-auth cache phase'
fi
if ! grep -qE \
  '^READY source=CACHE values=gpt-5.4,gpt-5.3-codex timer=yes$' \
  "$LEM_YATH_LLM_CODEX_MODELS_REPORT"; then
  die offline-cache 'fresh Lem did not restore the supported catalog'
fi
sleep 15
send_key F3
if ! wait_report \
  '^STATE source=CACHE count=2 values=gpt-5.4,gpt-5.3-codex model=gpt-5.4 running=no timer=no$' \
  3; then
  die missing-auth 'automatic refresh did not finish quietly without auth'
fi
if [[ "$(cat "$LEM_YATH_LLM_CODEX_MODELS_LOG/curl.count")" != 4 ]] ||
   [[ -e "$LEM_YATH_LLM_CODEX_MODELS_LOG/browser-opened" ]]; then
  die missing-auth 'automatic refresh attempted network or browser login without auth'
fi
pass missing-auth 'fresh Lem restored cache without network or browser login'

printf 'All ChatGPT Codex model-discovery tests passed.\n'
