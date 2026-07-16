#!/usr/bin/env bash
# Stock GNU Org timestamp chords through real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-timestamp-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-timestamp.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export TZ=UTC
export LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS="$root/snapshots"
mkdir -p "$HOME" "$WORKDIR" "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS"

fixture="$root/timestamps.org"
cat >"$fixture" <<'EOF'
* TODO Timestamp task
Insert active:
Insert inactive:
Replace active: <2026-07-17 Fri 09:30-10:30 +1w -2d>
Convert inactive: <2026-07-20 Mon +2w>
Shift me: [2026-07-15 Wed 08:00-09:00 +1m]
Forced time:
Immediate:
Cancelled:
EOF
cp "$fixture" "$root/original.org"

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-timestamp-fixture.lisp")"
session="lem-org-timestamp-$id"
failed=0

cleanup() {
  lem_stop "$session" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-20s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-20s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

mx() {
  local command="$1"
  tmux_cmd send-keys -t "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.3
  tmux_cmd send-keys -t "$session" Enter
}

snapshot() {
  local number="$1"
  mx lem-yath-test-org-timestamp-snapshot || return 1
  lem_wait_for "$session" "Timestamp snapshot $number" 10 >/dev/null || return 1
  test -f "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-$number"
}

goto_marker() {
  mx "lem-yath-test-timestamp-goto-$1"
  sleep 0.3
}

lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"
if ! lem_wait_for "$session" 'Timestamp task' 40 >/dev/null; then
  fail startup 'timestamp fixture did not open'
  exit 1
fi
tmux_cmd send-keys -t "$session" Escape
sleep 1

if mx lem-yath-test-org-timestamp-bindings &&
   lem_wait_for "$session" 'Timestamp bindings captured' 10 >/dev/null &&
   grep -q '^C-c \. LEM-YATH-ORG-TIMESTAMP$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c ! LEM-YATH-ORG-TIMESTAMP-INACTIVE$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c Left LEM-YATH-ORG-CONTEXT-SHIFT-LEFT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c Right LEM-YATH-ORG-CONTEXT-SHIFT-RIGHT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-x u UNDO$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^Shift-Left LEM-YATH-ORG-CONTEXT-SHIFT-LEFT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^Shift-Right LEM-YATH-ORG-CONTEXT-SHIFT-RIGHT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings"; then
  pass bindings 'stock timestamp and horizontal-shift chords resolve'
else
  fail bindings 'one or more stock chords did not resolve'
fi

goto_marker active
tmux_cmd send-keys -t "$session" C-z End
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '+2d 14:30'
  tmux_cmd send-keys -t "$session" Enter
else
  fail active-prompt 'C-c . did not open the timestamp prompt'
fi
if snapshot 1 &&
   grep -q '^Insert active:<2026-07-17 Fri 14:30>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-1" &&
   cmp -s "$fixture" "$root/original.org"; then
  pass active 'relative active timestamp remains an unsaved buffer edit'
else
  fail active 'active timestamp text or save behavior differed'
fi

goto_marker inactive
tmux_cmd send-keys -t "$session" End
tmux_cmd send-keys -t "$session" C-c '!'
if lem_wait_for "$session" 'Inactive timestamp \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Enter
else
  fail inactive-prompt 'C-c ! did not open the inactive prompt'
fi
if snapshot 2 &&
   grep -q '^Insert inactive:\[2026-07-15 Wed\]$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-2"; then
  pass inactive 'empty input accepts the bracketed inactive default'
else
  fail inactive 'inactive default was not inserted correctly'
fi

goto_marker replace
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Timestamp \[2026-07-17 09:30-10:30\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '++1m 11:00-12:15'
  tmux_cmd send-keys -t "$session" Enter
else
  fail replace-prompt 'existing timestamp values were not offered'
fi
if snapshot 3 &&
   grep -q '^Replace active: <2026-08-17 Mon 11:00-12:15 +1w -2d>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-3"; then
  pass replace 'replacement keeps repeater/warning suffixes and changes the range'
else
  fail replace 'timestamp replacement lost syntax or computed the wrong date'
fi

tmux_cmd send-keys -t "$session" C-x u
if snapshot 4 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-4" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-2"; then
  pass undo 'one Emacs undo restores the complete prior timestamp'
else
  fail undo 'replacement was not one undoable editor command'
fi

goto_marker convert
tmux_cmd send-keys -t "$session" C-c '!'
if lem_wait_for "$session" 'Inactive timestamp \[2026-07-20\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Enter
else
  fail convert-prompt 'active timestamp did not open for inactive conversion'
fi
if snapshot 5 &&
   grep -q '^Convert inactive: \[2026-07-20 Mon +2w\]$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-5"; then
  pass convert 'C-c ! changes delimiter type while preserving suffixes'
else
  fail convert 'active-to-inactive conversion differed'
fi

goto_marker shift
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.4
if snapshot 6 &&
   grep -q '^Shift me: \[2026-07-16 Thu 08:00-09:00 +1m\]$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-6"; then
  pass shift-right 'C-c Right advances only the timestamp date'
else
  fail shift-right 'right shift damaged or failed to move the timestamp'
fi
tmux_cmd send-keys -t "$session" C-c Left
sleep 0.4
if snapshot 7 &&
   grep -q '^Shift me: \[2026-07-15 Wed 08:00-09:00 +1m\]$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-7"; then
  pass shift-left 'C-c Left reverses the timestamp shift'
else
  fail shift-left 'left shift did not restore the timestamp'
fi

goto_marker forced
tmux_cmd send-keys -t "$session" End
tmux_cmd send-keys -t "$session" C-u C-c '!'
if lem_wait_for "$session" 'Inactive timestamp \[2026-07-15 12:00\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Enter
else
  fail forced-prompt 'universal prefix did not offer the current time'
fi
if snapshot 8 &&
   grep -q '^Forced time:\[2026-07-15 Wed 12:00\]$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-8"; then
  pass forced-time 'universal prefix includes time in an inactive timestamp'
else
  fail forced-time 'prefixed timestamp omitted or changed the current time'
fi

goto_marker immediate
tmux_cmd send-keys -t "$session" End
tmux_cmd send-keys -t "$session" C-u C-u C-c .
sleep 0.5
if snapshot 9 &&
   grep -q '^Immediate:<2026-07-15 Wed 12:00>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-9"; then
  pass immediate 'double universal prefix inserts the current timestamp directly'
else
  fail immediate 'double-prefix current timestamp insertion differed'
fi

goto_marker cancel
tmux_cmd send-keys -t "$session" End
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" C-g
else
  fail cancel-prompt 'cancellation did not reach the timestamp prompt'
fi
if snapshot 10 &&
   grep -q '^Cancelled:$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-10"; then
  pass cancellation 'C-g leaves the insertion point untouched'
else
  fail cancellation 'prompt cancellation mutated the buffer'
fi

goto_marker cancel
mx lem-yath-test-org-timestamp-read-only
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Org buffer is read-only' 10 >/dev/null; then
  pass read-only 'read-only buffers fail before prompting'
else
  fail read-only 'read-only timestamp insertion did not fail closed'
fi
mx lem-yath-test-org-timestamp-writable

goto_marker heading
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.5
if snapshot 11 &&
   grep -q '^\* NEXT Timestamp task$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-11" &&
   grep -q '^\* NEXT Timestamp task$' "$fixture"; then
  pass todo-context 'horizontal shift cycles heading TODO and saves like the profile'
else
  fail todo-context 'heading-context shift did not cycle and persist TODO state'
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'Org timestamp TUI checks passed.\n'
