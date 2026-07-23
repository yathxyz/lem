#!/usr/bin/env bash
# Real-TUI acceptance for cached asynchronous OpenRouter model discovery.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-models-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-models.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_OPENROUTER_MODEL_CACHE="$root/model-cache/models.json"
export LEM_YATH_OPENROUTER_MODEL_REFRESH=1
export LEM_YATH_LLM_MODELS_REPORT="$root/report"
export LEM_YATH_LLM_MODELS_LOG="$root/log"
export LEM_YATH_LLM_MODELS_CURL="$root/bin/curl"
export OPENROUTER_API_KEY='model-catalog-test-secret'
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$root/bin" "$root/log" \
  "$(dirname "$LEM_YATH_OPENROUTER_MODEL_CACHE")"
chmod 700 "$(dirname "$LEM_YATH_OPENROUTER_MODEL_CACHE")"
printf '%s\n' \
  '{"version":1,"models":["cached/model","openrouter/auto","cached/model"]}' \
  >"$LEM_YATH_OPENROUTER_MODEL_CACHE"
chmod 600 "$LEM_YATH_OPENROUTER_MODEL_CACHE"
cp "$here/scripts/llm-models-fake-curl.py" "$root/bin/curl"
sed -i "1c#!$(command -v python3)" "$root/bin/curl"
chmod +x "$root/bin/curl"
export PATH="$root/bin:$PATH"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-models-$id"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-models.*) [ -d "$root" ] && rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe model-test cleanup path: %s\n' \
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
  sed -n '1,260p' "$LEM_YATH_LLM_MODELS_REPORT" >&2 || true
  printf '\n--- curl captures ---\n' >&2
  find "$LEM_YATH_LLM_MODELS_LOG" -maxdepth 1 -type f -printf '%f\n' \
    2>/dev/null | sort >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_MODELS_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_LLM_MODELS_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_file() {
  local pathname=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if [ -f "$pathname" ]; then return 0; fi
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
    if grep -qE "$pattern" "$LEM_YATH_LLM_MODELS_REPORT" 2>/dev/null; then
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
  fixture="$(lem-yath_lisp_string "$here/scripts/llm-models-fixture.lisp")"
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" &&
    wait_report '^READY ' "$BOOT_TIMEOUT"
}

if ! start_fixture; then
  die boot 'could not start the isolated cache phase'
fi
if ! grep -qE '^READY source=CACHE values=cached/model,openrouter/auto timer=yes$' \
  "$LEM_YATH_LLM_MODELS_REPORT"; then
  die cache-startup 'private cache was not loaded before network refresh'
fi
pass cache-startup 'cached models were available immediately and kept source order'

send_key F2
if ! wait_report '^SUMMARY STATIC PASS failures=0$'; then
  die static-contracts 'model validation, menu, endpoint, or timer contract failed'
fi
pass static-contracts 'bounds, ordering, menu, and authenticated endpoint passed'

if ! wait_file "$LEM_YATH_LLM_MODELS_LOG/curl.1.config"; then
  send_key F3
  die idle-refresh 'five-second idle timer did not launch the background request'
fi
if ! wait_state \
  '^STATE source=NETWORK count=3 values=provider/new,openrouter/auto,provider/second model=openrouter/auto running=no timer=no '; then
  die idle-refresh 'five-second idle refresh did not apply the fetched catalog'
fi
pass idle-refresh 'idle timer refreshed asynchronously and filtered malformed entries'

python3 - "$LEM_YATH_LLM_MODELS_LOG/curl.1.argv" \
  "$LEM_YATH_LLM_MODELS_LOG/curl.1.config" \
  "$LEM_YATH_OPENROUTER_MODEL_CACHE" <<'PY'
import json
from pathlib import Path
import stat
import sys

argv = Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
argv = [value.decode() for value in argv]
assert argv == ["--silent", "--show-error", "--fail-with-body",
                "--max-time", "30", "--config", "-"]
joined = "\0".join(argv)
assert "model-catalog-test-secret" not in joined
assert "openrouter.ai" not in joined

config = Path(sys.argv[2]).read_text(encoding="utf-8")
assert 'request = "GET"' in config
assert 'url = "https://openrouter.ai/api/v1/models/user"' in config
assert "Authorization: Bearer model-catalog-test-secret" in config

cache = Path(sys.argv[3])
assert stat.S_IMODE(cache.stat().st_mode) == 0o600
assert stat.S_IMODE(cache.parent.stat().st_mode) == 0o700
assert json.loads(cache.read_text(encoding="utf-8")) == {
    "version": 1,
    "models": ["provider/new", "openrouter/auto", "provider/second"],
}
assert not list(cache.parent.glob("models.json.tmp.*"))
PY
pass secure-refresh 'request stayed off argv and cache replacement remained private'

send_key Space
send_key g
send_key l
if ! lem_wait_for "$session" 'open full LLM menu' "$WAIT_TIMEOUT" >/dev/null; then
  die compact-menu 'SPC g l did not show the compact preset menu'
fi
send_key m
if ! lem_wait_for "$session" 'response tokens:' "$WAIT_TIMEOUT" >/dev/null; then
  die full-menu 'compact m did not open the full LLM menu'
fi
send_key m
if ! lem_wait_for "$session" 'Model:' "$WAIT_TIMEOUT" >/dev/null; then
  die model-prompt 'full-menu model action did not open completion'
fi
for _ in $(seq 1 15); do send_key BSpace; done
send_literal second
if ! lem_wait_for "$session" 'provider/second' "$WAIT_TIMEOUT" >/dev/null; then
  die model-completion 'partial model input did not expose the discovered candidate'
fi
send_key Enter
send_key q
send_key F3
if ! wait_report 'model=provider/second running=no'; then
  die model-selection 'completion did not select the discovered model'
fi
pass model-selection 'physical menu completion selected a discovered model'

lem_stop "$session"
: >"$LEM_YATH_LLM_MODELS_REPORT"
unset OPENROUTER_API_KEY
export LEM_YATH_OPENROUTER_MODEL_REFRESH=0
if ! start_fixture; then
  die restart 'could not start the offline/public-endpoint phase'
fi
if ! grep -qE \
  '^READY source=CACHE values=provider/new,openrouter/auto,provider/second timer=no$' \
  "$LEM_YATH_LLM_MODELS_REPORT"; then
  die offline-cache 'fresh Lem did not restore the network catalog offline'
fi
pass offline-cache 'fresh Lem restored the catalog without a network request'

send_key F4
if ! wait_state \
  '^STATE source=NETWORK count=3 values=provider/new,openrouter/auto,provider/second .*running=no timer=no url=https://openrouter.ai/api/v1/models auth=no$'; then
  die public-refresh 'manual keyless refresh did not use the public endpoint'
fi
python3 - "$LEM_YATH_LLM_MODELS_LOG/curl.2.argv" \
  "$LEM_YATH_LLM_MODELS_LOG/curl.2.config" <<'PY'
from pathlib import Path
import sys

argv = Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
argv = [value.decode() for value in argv]
assert argv == ["--silent", "--show-error", "--fail-with-body",
                "--max-time", "30", "--config", "-"]
config = Path(sys.argv[2]).read_text(encoding="utf-8")
assert 'url = "https://openrouter.ai/api/v1/models"' in config
assert "Authorization:" not in config
PY
pass public-refresh 'manual refresh used the public catalog without authorization'

printf 'All OpenRouter model-discovery tests passed.\n'
