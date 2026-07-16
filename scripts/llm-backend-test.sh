#!/usr/bin/env bash
# Real-TUI, credential-free acceptance for OpenRouter and native agent CLIs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-backend-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-backend.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_BACKEND_REPORT="$root/report"
export LEM_YATH_LLM_FAKE_LOG="$root/log"
export LEM_YATH_LLM_FAKE_BIN="$root/bin/"
export OPENROUTER_API_KEY='test-key-not-a-credential'
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-backend-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-backend.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe LLM backend cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_YATH_LLM_FAKE_LOG" \
  "$LEM_YATH_LLM_FAKE_BIN"
: >"$LEM_YATH_LLM_BACKEND_REPORT"
bash_bin=$(command -v bash)
for executable in curl claude codex grok; do
  cp "$here/scripts/llm-fake-backend.sh" "$LEM_YATH_LLM_FAKE_BIN$executable"
  sed -i "1c#!$bash_bin" "$LEM_YATH_LLM_FAKE_BIN$executable"
  chmod +x "$LEM_YATH_LLM_FAKE_BIN$executable"
done

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() {
  printf 'PASS  %-30s %s\n' "$1" "$2"
}

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_LLM_BACKEND_REPORT" >&2 || true
  printf '\n--- fake argv files ---\n' >&2
  find "$LEM_YATH_LLM_FAKE_LOG" -maxdepth 1 -type f -printf '%f\n' \
    2>/dev/null | sort >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_BACKEND_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
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
    if grep -qE "$pattern" "$LEM_YATH_LLM_BACKEND_REPORT"; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

send_key() {
  lem_keys "$session" "$1"
  sleep 0.15
}

assert_argv() {
  local label=$1 file=$2
  shift 2
  local -a actual=() expected=("$@")
  if [ ! -f "$file" ]; then
    die "$label" "missing argv capture $file"
  fi
  mapfile -d '' -t actual <"$file"
  if (( ${#actual[@]} != ${#expected[@]} )); then
    die "$label" "argv length ${#actual[@]} != ${#expected[@]}"
  fi
  local index
  for index in "${!expected[@]}"; do
    if [[ "${actual[$index]}" != "${expected[$index]}" ]]; then
      die "$label" "argv[$index] differed"
    fi
  done
  pass "$label" 'native argv matched exactly'
}

fixture="$(lem-yath_lisp_string "$here/scripts/llm-backend-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)"; then
  die boot 'could not start the isolated tmux/Lem process'
fi
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the backend fixture'
fi
pass boot 'configured Lem loaded the isolated backend fixture'

send_key F2
if ! wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  die static-contracts 'command, session validation, or parser contract failed'
fi
pass static-contracts 'native argv and bounded parser contracts passed'

send_key F3
if ! wait_state '^STATE active=no openrouter=yes '; then
  die openrouter-stream 'SSE chunks did not reach the live output buffer'
fi
pass openrouter-stream 'fake SSE chunks streamed through the editor queue'

send_key F4
if ! wait_state 'active=no .*claude1=yes .*thinking=yes tool=yes tool-result=yes .*claude-id=claude-session-1'; then
  die claude-first 'Claude text, activity, or session metadata was missing'
fi
send_key F4
if ! wait_state 'active=no .*claude2=yes .*claude-id=claude-session-1'; then
  die claude-resume 'Claude resume request did not complete'
fi
pass claude-stream 'Claude events rendered and the second request resumed'

send_key F9
if ! wait_report_count '^NEW claude=none$' 1; then
  die claude-new-session 'new-session command did not clear Claude metadata'
fi
send_key F4
if ! wait_state 'active=no .*claude3=yes .*claude-id=claude-session-1'; then
  die claude-fresh 'Claude did not start fresh after clearing the session'
fi
pass claude-new-session 'explicit new conversation suppressed resume argv'

send_key F8
if ! wait_state '^STATE active=yes '; then
  die request-active 'slow fake request was not registered as active'
fi
send_key F5
sleep 0.4
if [ -e "$LEM_YATH_LLM_FAKE_LOG/codex.count" ]; then
  die duplicate-guard 'a second backend launched while one request was active'
fi
send_key F7
if ! wait_state 'active=no .*aborted=yes '; then
  die request-abort 'active process was not terminated and finalized'
fi
pass request-lifecycle 'duplicate launch was rejected and abort finalized safely'

send_key F5
if ! wait_state 'active=no .*codex1=yes .*command=yes file=yes .*codex-id=codex-thread-1'; then
  die codex-first 'Codex response, activity, or thread metadata was missing'
fi
send_key F5
if ! wait_state 'active=no .*codex2=yes .*codex-id=codex-thread-1'; then
  die codex-resume 'Codex resume request did not complete'
fi
pass codex-stream 'Codex activity rendered and the second request resumed'

send_key F6
if ! wait_state 'active=no .*grok1=yes .*grok-id=grok-session-1'; then
  die grok-first 'Grok text or session metadata was missing'
fi
send_key F6
if ! wait_state 'active=no .*grok2=yes .*grok-id=grok-session-1'; then
  die grok-resume 'Grok resume request did not complete'
fi
pass grok-stream 'Grok events rendered and the second request resumed'

system='Short, direct answers. Skip extra context unless it changes correctness.'
composed_prefix=$'System instructions:\nShort, direct answers. Skip extra context unless it changes correctness.\n\nUser message:\n'

assert_argv claude-first-argv "$LEM_YATH_LLM_FAKE_LOG/claude.1.argv" \
  -p 'claude prompt' --output-format stream-json --verbose \
  --append-system-prompt "$system"
assert_argv claude-resume-argv "$LEM_YATH_LLM_FAKE_LOG/claude.2.argv" \
  -p 'claude prompt' --output-format stream-json --verbose \
  --resume claude-session-1 --append-system-prompt "$system"
assert_argv claude-fresh-argv "$LEM_YATH_LLM_FAKE_LOG/claude.3.argv" \
  -p 'claude prompt' --output-format stream-json --verbose \
  --append-system-prompt "$system"

assert_argv codex-first-argv "$LEM_YATH_LLM_FAKE_LOG/codex.1.argv" \
  exec --json -s read-only "${composed_prefix}codex prompt"
assert_argv codex-resume-argv "$LEM_YATH_LLM_FAKE_LOG/codex.2.argv" \
  exec resume codex-thread-1 --json -s read-only \
  "${composed_prefix}codex prompt"

grok_tail=(--output-format streaming-json -m grok-build --sandbox read-only \
  --permission-mode dontAsk --disable-web-search --no-subagents --no-plan)
assert_argv grok-first-argv "$LEM_YATH_LLM_FAKE_LOG/grok.1.argv" \
  -p "${composed_prefix}grok prompt" "${grok_tail[@]}"
assert_argv grok-resume-argv "$LEM_YATH_LLM_FAKE_LOG/grok.2.argv" \
  -p "${composed_prefix}grok prompt" --output-format streaming-json \
  -r grok-session-1 -m grok-build --sandbox read-only \
  --permission-mode dontAsk --disable-web-search --no-subagents --no-plan

python3 - "$LEM_YATH_LLM_FAKE_LOG/curl.1.argv" <<'PY'
import json
import pathlib
import sys

args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
args = [value.decode() for value in args]
assert args[:4] == ["-sN", "https://openrouter.ai/api/v1/chat/completions",
                   "-H", "Content-Type: application/json"]
assert args[4:6] == ["-H", "Authorization: Bearer test-key-not-a-credential"]
assert args[6] == "-d"
body = json.loads(args[7])
assert body["model"] == "openrouter/auto" and body["stream"] is True
assert body["temperature"] == 0.2 and body["max_tokens"] == 800
assert body["messages"] == [
    {"role": "system", "content": "Short, direct answers. Skip extra context unless it changes correctness."},
    {"role": "user", "content": "openrouter prompt"},
]
PY
pass openrouter-request 'endpoint, authorization, and JSON body matched exactly'

printf 'All LLM backend tests passed.\n'
