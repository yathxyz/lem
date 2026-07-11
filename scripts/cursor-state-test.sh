#!/usr/bin/env bash
# Real-ncurses cursor/state parity, including raw DECSCUSR byte assertions.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-cursor-state-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-cursor-state.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_CURSOR_STATE_REPORT="$root/report"
export LEM_YATH_CURSOR_STATE_SOURCE="$here/lem-yath/src/cursor-state.lisp"

session="lem-yath-cursor-state-$id"
raw="$root/raw"
source_file="$root/cursor-source.txt"
parser="$here/scripts/cursor-state-raw.py"
export LEM_YATH_CURSOR_RAW="$raw"
export LEM_YATH_CURSOR_PARSER="$parser"

cleanup() {
  if declare -F lem_stop >/dev/null; then
    lem_stop "$session" || true
  fi
  case "${root:-}" in
    */lem-yath-cursor-state.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe cursor-state cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

mkdir -p "$HOME" "$XDG_CACHE_HOME"
: >"$LEM_YATH_CURSOR_STATE_REPORT"
: >"$raw"
printf 'CURSOR_SENTINEL alpha\nsecond line\n' >"$source_file"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

validate_timeout() {
  local name=$1 value=$2
  if [[ ! $value =~ ^[1-9][0-9]{0,2}$ ]] || ((10#$value > 600)); then
    printf '%s must be an integer from 1 through 600, got: %s\n' \
      "$name" "$value" >&2
    exit 2
  fi
}

validate_timeout BOOT_TIMEOUT "$BOOT_TIMEOUT"
validate_timeout WAIT_TIMEOUT "$WAIT_TIMEOUT"

pass() {
  printf 'PASS  %-28s %s\n' "$1" "$2"
}

die() {
  printf 'FAIL  %-28s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- screen attributes ---\n' >&2
  tmux_cmd capture-pane -t "$session" -p -e 2>/dev/null \
    | sed -n '1,8p' | sed -n l >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_CURSOR_STATE_REPORT" >&2 || true
  printf '\n--- raw shape events ---\n' >&2
  LC_ALL=C grep -aoE "$(printf '\033')\\[[0-9]+ q" "$raw" \
    | od -An -tx1c >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_CURSOR_STATE_REPORT" 2>/dev/null || true
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

raw_size() {
  wc -c <"$raw" | tr -d ' '
}

settled_raw_size() {
  local previous=-1 current stable=0 index=0
  while ((index < WAIT_TIMEOUT * 10)); do
    current=$(raw_size)
    if [[ $current == "$previous" ]]; then
      stable=$((stable + 1))
      if ((stable >= 2)); then
        printf '%s\n' "$current"
        return 0
      fi
    else
      previous=$current
      stable=0
    fi
    sleep 0.1
    index=$((index + 1))
  done
  return 1
}

wait_shape_after() {
  local offset=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if python3 "$parser" "$raw" "$offset" "$expected" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  python3 "$parser" "$raw" "$offset" "$expected" >&2 || true
  return 1
}

wait_screen() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if lem_capture "$session" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

send_key() {
  lem_keys "$session" "$1"
  sleep 0.16
}

assert_cursor_background() {
  local codes=$1 timeout=${2:-$WAIT_TIMEOUT} code pattern screen index=0
  local escape
  escape="$(printf '\033')"
  while ((index < timeout * 4)); do
    screen="$(tmux_cmd capture-pane -t "$session" -p -e)"
    for code in ${codes//,/ }; do
      pattern="${escape}\\[7m(${escape}\\[[0-9;:]+m)*${escape}\\[${code}m"
      if LC_ALL=C grep -Eq "$pattern" <<<"$screen"; then
        return 0
      fi
    done
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

record_state() {
  local before
  before=$(report_count '^STATE ')
  send_key F12
  wait_report_count '^STATE ' "$((before + 1))"
}

assert_last_state() {
  local pattern=$1
  tail -n 1 "$LEM_YATH_CURSOR_STATE_REPORT" | grep -qE "$pattern"
}

transition() {
  local label=$1 key=$2 screen=$3 shape=$4 background=$5 state_pattern=$6
  local offset
  offset=$(settled_raw_size) || die "$label" 'raw terminal stream did not settle'
  send_key "$key"
  wait_screen "$screen" || die "$label" "modeline did not reach $screen"
  wait_shape_after "$offset" "$shape" || \
    die "$label" "final raw cursor shape was not DECSCUSR $shape"
  assert_cursor_background "$background" || \
    die "$label" "cursor cell did not use SGR background $background"
  record_state || die "$label" 'state recorder did not run'
  assert_last_state "$state_pattern" || \
    die "$label" 'logical state did not match the rendered profile'
  pass "$label" "logical state, cursor cell, and DECSCUSR $shape agree"
}

fixture="$(lem-yath_lisp_string "$here/scripts/cursor-state-fixture.lisp")"
form="$(lem-yath_with_loaded_form "(load #P$fixture)")"

tmux_cmd kill-session -t "$session" 2>/dev/null || true
tmux_cmd new-session -d -s "$session" -x 120 -y 35 bash
tmux_cmd set-option -t "$session" remain-on-exit on
tmux_cmd pipe-pane -O -t "$session" \
  'python3 "$LEM_YATH_CURSOR_PARSER" capture "$LEM_YATH_CURSOR_RAW"'
printf -v command '%q ' "$LEM_BIN" --eval "$form" "$source_file"
lem_keys "$session" -l "exec $command"
lem_keys "$session" Enter

if ! wait_screen 'NORMAL' "$BOOT_TIMEOUT" ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not reach the initial normal state'
fi
if ! wait_shape_after 0 2 || ! assert_cursor_background 41,101; then
  die boot 'initial NORMAL terminal profile was not applied before the first key'
fi
# A clean cache compilation can leave Lem's compiler notification over the
# source briefly.  The initial profile above is already proven; dismiss only
# that notification before invoking fixture diagnostics.
sleep 0.5
send_key Escape
if ! record_state ||
   ! assert_last_state \
     '^STATE .* state=NORMAL type=box configured=red .* global=vi visual=none mark=no point=1 '; then
  die boot 'initial NORMAL logical state could not be recorded'
fi
pass boot 'initial NORMAL emitted a red box profile during startup'

send_key F7
if ! wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  die static-contracts 'state objects, hooks, C-z, or C-x t bindings differ'
fi
pass static-contracts 'cursor objects, hook ownership, and prefixes are exact'

operator_offset=$(settled_raw_size) || die operator-C-z 'raw terminal stream did not settle'
send_key d
send_key C-z
if ! wait_screen 'NORMAL' || ! wait_shape_after "$operator_offset" 2 ||
   ! assert_cursor_background 41,101 || ! record_state ||
   ! assert_last_state \
     '^STATE .* state=NORMAL type=box configured=red .* visual=none mark=no point=1 return=none '; then
  die operator-C-z 'C-z inside operator-pending desynchronized the buffer state'
fi
pass operator-C-z 'C-z safely canceled operator-pending without entering EMACS'

transition insert i 'INSERT' 5 42,102 \
  '^STATE .* state=INSERT type=bar configured=green .* global=vi visual=none mark=no point=1 '
transition normal-from-insert Escape 'NORMAL' 2 41,101 \
  '^STATE .* state=NORMAL type=box configured=red .* global=vi visual=none mark=no point=1 '
transition visual-char v 'VISUAL' 2 47,107 \
  '^STATE .* state=VISUAL type=box configured=default .* global=vi visual=char mark=yes point=1 '
transition emacs-from-visual C-z 'EMACS' 2 46,106 \
  '^STATE .* state=EMACS type=box configured=cyan .* global=vi visual=none mark=yes point=1 return=VISUAL '
transition visual-from-emacs C-z 'VISUAL' 2 47,107 \
  '^STATE .* state=VISUAL type=box configured=default .* global=vi visual=char mark=yes point=1 return=none '
transition normal-from-char Escape 'NORMAL' 2 41,101 \
  '^STATE .* state=NORMAL type=box configured=red .* global=vi visual=none mark=no point=1 '
transition visual-line V 'V-LINE' 2 47,107 \
  '^STATE .* state=V-LINE type=box configured=default .* global=vi visual=line mark=yes point=1 '
transition normal-from-line Escape 'NORMAL' 2 41,101 \
  '^STATE .* state=NORMAL type=box configured=red .* global=vi visual=none mark=no point=1 '
transition visual-block C-v 'V-BLOCK' 2 47,107 \
  '^STATE .* state=V-BLOCK type=box configured=default .* global=vi visual=block mark=yes point=1 '
transition normal-from-block Escape 'NORMAL' 2 41,101 \
  '^STATE .* state=NORMAL type=box configured=red .* global=vi visual=none mark=no point=1 '
transition replace R 'REPLACE' 4 47,107 \
  '^STATE .* state=REPLACE type=underline configured=default .* global=vi visual=none mark=no point=1 '
transition normal-from-replace Escape 'NORMAL' 2 41,101 \
  '^STATE .* state=NORMAL type=box configured=red .* global=vi visual=none mark=no point=1 '

transition emacs-from-normal C-z 'EMACS' 2 46,106 \
  '^STATE .* state=EMACS type=box configured=cyan .* global=vi visual=none mark=no point=1 return=NORMAL '

send_key C-f
record_state || die emacs-fallback 'C-f prevented state recording'
if ! assert_last_state '^STATE .* state=EMACS .* mark=no point=2 return=NORMAL '; then
  die emacs-fallback 'ordinary global C-f did not move inside EMACS state'
fi
send_key C-b
pass emacs-fallback 'ordinary Emacs/global movement remains available'

send_key C-Space
send_key C-f
record_state || die emacs-region 'region state was not recordable'
if ! assert_last_state '^STATE .* state=EMACS .* visual=none mark=yes point=2 return=NORMAL '; then
  die emacs-region 'mark activation forced EMACS into VISUAL or lost the mark'
fi
send_key M-w
record_state || die emacs-region 'copy state was not recordable'
if ! assert_last_state '^STATE .* state=EMACS .* visual=none mark=no point=2 return=NORMAL kill=C$'; then
  die emacs-region 'M-w did not copy the Emacs region and stay in EMACS'
fi
pass emacs-region 'C-Space/C-f/M-w retained genuine Emacs region semantics'

transition normal-from-emacs C-z 'NORMAL' 2 41,101 \
  '^STATE .* state=NORMAL type=box configured=red .* global=vi visual=none mark=no point=2 return=none '

send_key 0
transition insert-before-emacs i 'INSERT' 5 42,102 \
  '^STATE .* state=INSERT type=bar configured=green .* point=1 '
transition emacs-from-insert C-z 'EMACS' 2 46,106 \
  '^STATE .* state=EMACS type=box configured=cyan .* point=1 return=INSERT '
transition insert-from-emacs C-z 'INSERT' 5 42,102 \
  '^STATE .* state=INSERT type=bar configured=green .* point=1 return=none '

prompt_offset=$(settled_raw_size) || die prompt-entry 'raw terminal stream did not settle'
send_key F11
if ! wait_screen 'Cursor prompt:' || ! wait_shape_after "$prompt_offset" 2; then
  die prompt-entry 'prompt did not switch to its box cursor state'
fi
prompt_exit_offset=$(settled_raw_size) || die prompt-restore 'raw terminal stream did not settle'
send_key C-g
if ! wait_screen 'INSERT' || ! wait_shape_after "$prompt_exit_offset" 5 ||
   ! assert_cursor_background 42,102 ||
   ! wait_report_count '^PROMPT aborted state=INSERT$' 1; then
  die prompt-restore 'canceling the prompt did not restore INSERT exactly'
fi
pass prompt-restore 'prompt roundtrip restored the source INSERT profile'

other_offset=$(settled_raw_size) || die buffer-other 'raw terminal stream did not settle'
send_key F9
if ! wait_screen 'NORMAL.*\*cursor-state-other\*' ||
   ! wait_shape_after "$other_offset" 2 || ! assert_cursor_background 41,101 ||
   ! record_state ||
   ! assert_last_state '^STATE buffer=\*cursor-state-other\* state=NORMAL .* point=1 '; then
  die buffer-other 'new buffer did not initialize independently in NORMAL'
fi
source_offset=$(settled_raw_size) || die buffer-source 'raw terminal stream did not settle'
send_key F8
if ! wait_screen 'INSERT.*cursor-source\.txt' ||
   ! wait_shape_after "$source_offset" 5 || ! assert_cursor_background 42,102 ||
   ! record_state ||
   ! assert_last_state '^STATE buffer=cursor-source\.txt state=INSERT .* point=1 '; then
  die buffer-source 'source buffer did not retain INSERT across the switch'
fi
pass buffer-isolation 'buffer switching restored independent cursor states'

transition source-emacs-buffer-local C-z 'EMACS.*cursor-source\.txt' 2 46,106 \
  '^STATE buffer=cursor-source\.txt state=EMACS .* point=1 return=INSERT '
transition other-normal-buffer-local F9 'NORMAL.*\*cursor-state-other\*' 2 41,101 \
  '^STATE buffer=\*cursor-state-other\* state=NORMAL .* point=1 return=none '
transition other-emacs-buffer-local C-z 'EMACS.*\*cursor-state-other\*' 2 46,106 \
  '^STATE buffer=\*cursor-state-other\* state=EMACS .* point=1 return=NORMAL '
transition source-emacs-restored F8 'EMACS.*cursor-source\.txt' 2 46,106 \
  '^STATE buffer=cursor-source\.txt state=EMACS .* point=1 return=INSERT '
transition source-insert-restored C-z 'INSERT.*cursor-source\.txt' 5 42,102 \
  '^STATE buffer=cursor-source\.txt state=INSERT .* point=1 return=none '
transition other-emacs-restored F9 'EMACS.*\*cursor-state-other\*' 2 46,106 \
  '^STATE buffer=\*cursor-state-other\* state=EMACS .* point=1 return=NORMAL '
transition other-normal-restored C-z 'NORMAL.*\*cursor-state-other\*' 2 41,101 \
  '^STATE buffer=\*cursor-state-other\* state=NORMAL .* point=1 return=none '
transition source-insert-final F8 'INSERT.*cursor-source\.txt' 5 42,102 \
  '^STATE buffer=cursor-source\.txt state=INSERT .* point=1 return=none '
pass buffer-local-emacs 'two buffers retained independent EMACS return states'

reload_before=$(report_count '^RELOAD ')
reload_offset=$(settled_raw_size) || die reload-idempotence 'raw terminal stream did not settle'
send_key F10
if ! wait_report_count \
     '^RELOAD state-same=yes emacs-same=yes activate=1 deactivate=1 exit=1 switch=1$' \
     "$((reload_before + 1))" ||
   ! wait_shape_after "$reload_offset" 5 || ! assert_cursor_background 42,102; then
  die reload-idempotence 'double source reload changed state, hooks, or profile'
fi
send_key F7
if ! wait_report_count '^SUMMARY STATIC PASS failures=0$' 2; then
  die reload-idempotence 'post-reload static contracts failed'
fi
pass reload-idempotence 'double reload retained instances, hooks, bindings, and INSERT'

exit_offset=$(settled_raw_size) || die exit-restore 'raw terminal stream did not settle'
send_key C-x
send_key C-c
i=0
while ((i < WAIT_TIMEOUT * 4)); do
  if [[ $(tmux_cmd display-message -p -t "$session" '#{pane_dead}' 2>/dev/null) == 1 ]]; then
    break
  fi
  sleep 0.25
  i=$((i + 1))
done
if [[ $(tmux_cmd display-message -p -t "$session" '#{pane_dead}' 2>/dev/null) != 1 ]]; then
  die exit-restore 'Lem did not exit cleanly'
fi
exit_status=$(tmux_cmd display-message -p -t "$session" '#{pane_dead_status}')
if [[ $exit_status != 0 ]]; then
  die exit-restore "Lem exited with status $exit_status"
fi
sleep 0.4
if ! wait_shape_after "$exit_offset" 2; then
  die exit-restore 'final terminal cursor event was not a steady box'
fi
pass exit-restore 'status 0 exit restored a steady box cursor for the shell'

printf 'All cursor-state tests passed.\n'
