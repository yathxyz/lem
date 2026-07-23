#!/usr/bin/env bash
# Real-ncurses vterm/Evil behavior, cwd safety, and terminal cleanup.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-terminal-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-terminal.XXXXXX")"
session="lem-yath-terminal-$id"
launch_parent="$root/work"
launch_directory="$root/work;touch injected-marker"
source_file="$launch_directory/source.txt"
injected_marker="$launch_parent/injected-marker"
if [[ -n ${LEM_YATH_TERMINAL_SHELL_OVERRIDE:-} ]]; then
  terminal_shell="$LEM_YATH_TERMINAL_SHELL_OVERRIDE"
else
  terminal_shell="$root/terminal-shell-fixture"
  cp "$here/scripts/terminal-shell-fixture.sh" "$terminal_shell"
  sed -i "1c#!$(command -v bash)" "$terminal_shell"
  chmod +x "$terminal_shell"
fi

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_TERMINAL_REPORT="$root/report"
export LEM_YATH_TERMINAL_CHILD_PID_FILE="$root/child-pid"

cleanup() {
  if declare -F lem_stop >/dev/null; then
    lem_stop "$session" || true
  fi
  case "${root:-}" in
    */lem-yath-terminal.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe terminal cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

source "$here/scripts/tui-driver.sh"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$launch_parent" "$launch_directory"
: >"$LEM_YATH_TERMINAL_REPORT"
printf 'terminal source\n' >"$source_file"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
KEY_DELAY="${KEY_DELAY:-0.18}"

pass() { printf 'PASS  %-27s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-27s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,240p' "$LEM_YATH_TERMINAL_REPORT" >&2 || true
  printf '\n--- injection marker ---\n' >&2
  ls -la "$launch_parent" >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_TERMINAL_REPORT" 2>/dev/null || true
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

wait_pid_gone() {
  local pid=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

send_key() {
  lem_keys "$session" "$1"
  sleep "$KEY_DELAY"
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l "$1"
  sleep "$KEY_DELAY"
}

record_state() {
  local before
  before=$(report_count '^STATE ')
  send_key F12
  wait_report_count '^STATE ' "$((before + 1))"
}

last_state() {
  grep '^STATE ' "$LEM_YATH_TERMINAL_REPORT" | tail -n 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/terminal-fixture.lisp")"
form="$(lem-yath_with_loaded_form "(load #P$fixture)")"
tmux_cmd kill-session -t "$session" 2>/dev/null || true
printf -v command '%q ' env "SHELL=$terminal_shell" \
  "$LEM_BIN" --eval "$form" "$source_file"
tmux_cmd new-session -d -s "$session" -x 160 -y 50 "$command"

if ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT" ||
   ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null; then
  die boot 'configured Lem did not reach the source buffer'
fi

send_key F7
if ! wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  die static-contracts 'terminal aliases, maps, bypasses, or hook ownership differ'
fi
pass static-contracts 'vterm alias and Evil terminal routing are installed once'

send_key M-x
lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null ||
  die vterm-alias 'M-x did not open the command prompt'
send_literal vterm
send_key Enter

expected_cwd="SHELL-READY cwd=<$launch_directory>"
lem_wait_for "$session" "$expected_cwd" "$BOOT_TIMEOUT" >/dev/null ||
  die safe-cwd 'terminal child did not start in the literal launch directory'
if [[ ! -s $LEM_YATH_TERMINAL_CHILD_PID_FILE ]]; then
  die safe-cwd 'terminal child did not publish its process ID'
fi
terminal_child_pid=$(<"$LEM_YATH_TERMINAL_CHILD_PID_FILE")
if [[ ! $terminal_child_pid =~ ^[1-9][0-9]*$ ]] ||
   ! kill -0 "$terminal_child_pid" 2>/dev/null; then
  die safe-cwd 'terminal child process ID was invalid or not live'
fi
lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null ||
  die initial-insert 'new terminal did not enter Insert state'
if [[ -e $injected_marker ]]; then
  die safe-cwd 'the launch directory was interpreted as shell syntax'
fi
record_state || die safe-cwd 'terminal state was not recordable'
last_state | grep -Fq \
  "mode=TERMINAL-MODE state=INSERT directory=<$launch_directory/>" ||
  die safe-cwd 'terminal buffer directory metadata or initial state differed'
pass safe-cwd 'child chdir and buffer metadata preserve literal metacharacters'
pass initial-insert 'M-x vterm starts at the live cursor in Insert state'

send_literal alpha
send_key Enter
lem_wait_for "$session" 'COMMAND:<alpha>' "$WAIT_TIMEOUT" >/dev/null ||
  die raw-input 'Insert-state text and Return did not reach the child'
pass raw-input 'Insert-state controls are raw-sent to the terminal child'

send_key Escape
lem_wait_for "$session" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null ||
  die escape-normal 'Escape did not enter terminal Normal state'
record_state || die escape-normal 'Normal terminal state was not recordable'
normal_before=$(last_state)
grep -Eq 'mode=TERMINAL-COPY-MODE state=NORMAL .* live-normal=yes registry=1 ' \
  <<<"$normal_before" ||
  die escape-normal 'Normal state did not retain a live read-only terminal view'
point_before=$(sed -n 's/.* point=\([0-9][0-9]*\) .*/\1/p' <<<"$normal_before")
send_key k
record_state || die normal-navigation 'state after k was not recordable'
point_after=$(last_state | sed -n 's/.* point=\([0-9][0-9]*\) .*/\1/p')
if [[ -z $point_before || -z $point_after || $point_after -ge $point_before ]]; then
  die normal-navigation 'Normal k did not navigate the read-only terminal buffer'
fi
pass escape-normal 'Escape enters a live terminal Normal/copy view'
pass normal-navigation 'ordinary Vi navigation remains available in Normal state'

send_key i
lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null ||
  die insert-return 'i did not return to raw terminal input'
send_key C-c
send_key C-z
record_state || die escape-toggle 'enabled Escape routing was not recordable'
last_state | grep -Eq \
  'mode=TERMINAL-MODE state=INSERT .* escape-to-vterm=yes ' ||
  die escape-toggle 'C-c C-z did not enable child Escape routing'
send_key Escape
lem_wait_for "$session" 'ESC-RECEIVED' "$WAIT_TIMEOUT" >/dev/null ||
  die escape-toggle 'enabled Escape did not reach the child'
record_state || die escape-toggle 'post-Escape state was not recordable'
last_state | grep -Eq 'mode=TERMINAL-MODE state=INSERT .* escape-to-vterm=yes ' ||
  die escape-toggle 'child-directed Escape left Insert state'
send_key C-c
send_key C-z
send_key Escape
lem_wait_for "$session" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null ||
  die escape-toggle 'disabled Escape routing did not return to Normal state'
pass escape-toggle 'C-c C-z switches Escape between child and editor'

send_key F9
wait_report_count '^SEEDED paste=PASTED$' 1 ||
  die normal-paste 'kill-ring fixture was not installed'
send_key p
send_key Enter
lem_wait_for "$session" 'COMMAND:<PASTED>' "$WAIT_TIMEOUT" >/dev/null ||
  die normal-paste 'Normal p and Return did not paste and submit to the child'
record_state || die normal-paste 'post-submit state was not recordable'
last_state | grep -Eq 'mode=TERMINAL-COPY-MODE state=NORMAL .* live-normal=yes ' ||
  die normal-paste 'Normal paste/submit did not retain live Normal state'
pass normal-paste 'p/P-compatible paste and Normal RET submit stay live'

send_key A
lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null ||
  die insert-variants 'A did not return to Insert state'
send_literal beta
send_key Enter
lem_wait_for "$session" 'COMMAND:<beta>' "$WAIT_TIMEOUT" >/dev/null ||
  die insert-variants 'raw input after A was not cleanly submitted'
send_key C-x
send_key '['
lem_wait_for "$session" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null ||
  die explicit-copy 'C-x [ did not enter Normal/copy view'
pass insert-variants 'i/I/a/A return to the actual live terminal cursor'
pass explicit-copy 'C-x [ remains an explicit copy/Normal transition'

record_state || die cleanup 'pre-kill state was not recordable'
last_state | grep -Eq 'terminal=yes .* registry=1 ' ||
  die cleanup 'live terminal was missing before cleanup'
send_key F8
wait_report_count '^CLEANUP registry=0 ' 1 ||
  die cleanup 'killing the buffer did not remove the terminal registry entry'
wait_pid_gone "$terminal_child_pid" ||
  die cleanup 'killing the buffer did not terminate and reap the terminal child'
if [[ -e $injected_marker ]]; then
  die cleanup 'an injection marker appeared during terminal lifetime'
fi
pass cleanup 'buffer kill removes the terminal registry entry and reaps its child'

printf 'terminal test passed\n'
