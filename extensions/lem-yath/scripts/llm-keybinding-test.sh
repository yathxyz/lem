#!/usr/bin/env bash
# Real-ncurses coverage for insert-state C-c i without making a network call.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-keybinding-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-keybinding.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_KEYBINDING_REPORT="$root/report"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-keybinding-$id"
source_file="$root/source.txt"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-keybinding.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe LLM-keybinding cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME"
: >"$LEM_YATH_LLM_KEYBINDING_REPORT"
printf 'fixture boot text\n' >"$source_file"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() {
  printf 'PASS  %-26s %s\n' "$1" "$2"
}

die() {
  printf 'FAIL  %-26s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,200p' "$LEM_YATH_LLM_KEYBINDING_REPORT" >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_KEYBINDING_REPORT" 2>/dev/null || true
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

send_key() {
  lem_keys "$session" "$1"
  sleep 0.15
}

send_control_c_i() {
  send_key C-c
  send_key i
}

fixture="$(lem-yath_lisp_string "$here/scripts/llm-keybinding-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$source_file"; then
  die boot 'could not start the isolated tmux/Lem process'
fi

if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the LLM fixture'
fi
pass boot 'configured Lem loaded the isolated backend fixture'

send_key i
if ! lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null; then
  die insert-state 'Lem did not enter Vi insert state'
fi
pass insert-state 'the key sequence starts from real Vi insert state'

send_key F8
if ! wait_report_count '^PASS STATIC C-c-i insert=LEM-YATH-LLM-SEND visual=LEM-YATH-LLM-SEND$' 1; then
  die static-binding 'insert and visual C-c i do not resolve to lem-yath-llm-send'
fi
pass static-binding 'insert and visual C-c i resolve to lem-yath-llm-send'

text_hex='20207072656669782070726F6D7074207375666669780A'

run_case() {
  local setup_key=$1 label=$2 prompt_hex=$3 point=$4 mark=$5 vi=$6
  local expected_text_hex=${7:-$text_hex}
  local setup_before send_before state_before
  setup_before=$(report_count "^SETUP label=$label ")
  send_before=$(report_count '^SEND ')
  state_before=$(report_count "^STATE label=$label ")

  send_key "$setup_key"
  if ! wait_report_count "^SETUP label=$label " "$((setup_before + 1))"; then
    die "$label" 'fixture setup command did not run'
  fi

  send_control_c_i
  if ! wait_report_count '^SEND ' "$((send_before + 1))"; then
    die "$label" 'C-c i did not dispatch to the isolated backend'
  fi

  send_key F12
  if ! wait_report_count "^STATE label=$label " "$((state_before + 1))"; then
    die "$label" 'state recorder did not run after C-c i'
  fi

  if ! grep -qE \
    "^STATE label=$label calls=1 prompt-hex=$prompt_hex text-hex=$expected_text_hex point=$point mark=$mark vi=$vi$" \
    "$LEM_YATH_LLM_KEYBINDING_REPORT"; then
    die "$label" 'prompt, source buffer, selection, or Vi state differed'
  fi
  pass "$label" 'one exact prompt was sent without changing the source buffer'
}

run_case F5 up-to-point 7072656669782070726F6D7074 16 no insert
run_case F9 mid-word 7072656669782070726F6D7074 12 no insert
run_case F11 mid-punctuation 7072656669782E2E2E 8 no insert \
  7072656669782E2E2E207375666669780A
run_case F4 symbol-stop 616C706861 3 no insert \
  616C7068615F62657461207375666669780A

blank_setup_before=$(report_count '^SETUP label=blank ')
blank_send_before=$(report_count '^SEND ')
blank_state_before=$(report_count '^STATE label=blank ')
send_key F10
if ! wait_report_count '^SETUP label=blank ' "$((blank_setup_before + 1))"; then
  die blank 'fixture setup command did not run'
fi
send_control_c_i
sleep 0.4
if (( $(report_count '^SEND ') != blank_send_before )); then
  die blank 'whitespace-only input reached the backend'
fi
send_key F12
if ! wait_report_count '^STATE label=blank ' "$((blank_state_before + 1))" ||
   ! grep -qE '^STATE label=blank calls=0 prompt-hex= text-hex=2020090A point=5 mark=no vi=insert$' \
     "$LEM_YATH_LLM_KEYBINDING_REPORT"; then
  die blank 'blank dispatch changed the buffer, point, state, or backend count'
fi
pass blank 'whitespace-only input did not dispatch a backend request'

run_case F6 forward-region 70726F6D7074 10 yes visual
run_case F7 reverse-region 70726F6D7074 15 yes visual

if (( $(report_count '^SEND ') != 6 )); then
  die exact-once 'the six nonblank key invocations did not produce exactly six sends'
fi
pass exact-once 'each real C-c i invocation dispatched exactly once'

printf 'All LLM keybinding tests passed.\n'
