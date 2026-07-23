#!/usr/bin/env bash
# Real-ncurses coverage for the configured SPC m e e eval-last-sexp workflow.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-lisp-eval-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-lisp-eval.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LISP_EVAL_REPORT="$root/report"
export LEM_YATH_LISP_EVAL_SOURCE="${LEM_YATH_SOURCE:-$here/lem-yath}/src/lisp-eval.lisp"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-lisp-eval-$id"
source_file="$root/evaluation.lisp"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-lisp-eval.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe Lisp-eval cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME"
: >"$LEM_YATH_LISP_EVAL_REPORT"
printf '(values)\n' >"$source_file"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() {
  printf 'PASS  %-24s %s\n' "$1" "$2"
}

die() {
  printf 'FAIL  %-24s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,240p' "$LEM_YATH_LISP_EVAL_REPORT" >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LISP_EVAL_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_LISP_EVAL_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

send_key() {
  lem_keys "$session" "$1"
  sleep 0.12
}

send_eval_chord() {
  send_key Space
  send_key m
  send_key e
  send_key e
}

record_until() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    send_key F12
    if grep -qE "$pattern" "$LEM_YATH_LISP_EVAL_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.13
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/lisp-eval-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$source_file"; then
  die boot 'could not start the isolated tmux/Lem process'
fi

if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report '^READY$' "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the Lisp evaluation fixture'
fi
pass boot 'configured Lem loaded a real Common Lisp buffer and self-connection'

send_key F8
if ! wait_report '^PASS STATIC normal=LEM-YATH-LISP-EVAL-LAST-EXPRESSION visual=LEM-YATH-LISP-EVAL-LAST-EXPRESSION command=yes$'; then
  die binding 'SPC m e e is not an executable command in both Vi states'
fi
pass binding 'normal and visual leader maps resolve to the executable wrapper'

send_key Escape
send_key F5
if ! wait_report '^SETUP label=normal value=0 .* vi=normal$'; then
  die normal-eval 'normal-state setup did not run'
fi
send_eval_chord
if ! record_until '^STATE label=normal value=1 text=same point=same mark=no vi=normal$'; then
  die normal-eval 'the physical normal-state chord did not evaluate exactly once'
fi
pass normal-eval 'SPC m e e evaluated the preceding form exactly once without source mutation'

send_key F6
if ! wait_report '^SETUP label=visual value=0 .* vi=normal$'; then
  die visual-eval 'visual-state setup did not run'
fi
send_key v
if ! lem_wait_for "$session" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null; then
  die visual-eval 'Lem did not enter real Vi Visual state'
fi
send_key F7
if ! wait_report '^VISUAL-END .* mark=yes vi=visual$'; then
  die visual-eval 'the fixture could not retain the active Visual selection'
fi
send_eval_chord
if ! record_until '^STATE label=visual value=1 text=same point=same mark=yes vi=visual$'; then
  die visual-eval 'Visual dispatch evaluated the region or changed selection/state'
fi
pass visual-eval 'Visual SPC m e e ignored the region and evaluated only the last form'

send_key Escape
send_key F9
if ! wait_report '^SETUP label=error value=:UNCHANGED .* vi=normal$'; then
  die eval-error 'error setup did not run'
fi
send_eval_chord
if ! lem_wait_for "$session" 'lem-yath intentional evaluation error' "$WAIT_TIMEOUT" >/dev/null; then
  die eval-error 'the remote evaluation error was not surfaced in the editor'
fi
send_key q
if lem_wait_for "$session" 'kill anyway \[y/n\]' 2 >/dev/null; then
  send_key y
fi
closed=0
for ((index = 0; index < WAIT_TIMEOUT * 4; index++)); do
  if ! lem_capture "$session" | grep -q '\*sldb'; then
    closed=1
    break
  fi
  sleep 0.25
done
if [ "$closed" -ne 1 ]; then
  die eval-error 'q did not close the real SLDB error pane'
fi
if ! record_until '^STATE label=error value=:UNCHANGED text=same point=same mark=no vi=normal$'; then
  die eval-error 'an evaluation error mutated source, point, state, or value'
fi
pass eval-error 'remote errors are visible, dismissible, and leave source state untouched'

send_key F10
if ! wait_report '^RELOAD binding=LEM-YATH-LISP-EVAL-LAST-EXPRESSION command=yes$'; then
  die reload 'reloading the evaluation module broke the command or binding'
fi
pass reload 'reloading the module twice preserves one working leader command'

printf 'All Lisp evaluation tests passed.\n'
