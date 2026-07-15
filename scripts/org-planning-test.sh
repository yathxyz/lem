#!/usr/bin/env bash
# In-buffer GNU Org scheduling/deadline chords through real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-planning-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-planning.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_ORG_PLANNING_SNAPSHOTS="$root/snapshots"
mkdir -p "$HOME" "$WORKDIR" "$LEM_YATH_ORG_PLANNING_SNAPSHOTS"

fixture="$root/planning.org"
cat >"$fixture" <<'EOF'
* TODO Planned task
Body remains here.
EOF
cp "$fixture" "$root/original.org"

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-planning-fixture.lisp")"
session="lem-org-planning-$id"
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
  tmux_cmd send-keys -t "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.3
  tmux_cmd send-keys -t "$session" Enter
}

snapshot() {
  local number="$1"
  mx lem-yath-test-org-planning-snapshot || return 1
  lem_wait_for "$session" "Planning snapshot $number" 10 >/dev/null || return 1
  test -f "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-$number"
}

lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"
if ! lem_wait_for "$session" 'Planned task' 40 >/dev/null; then
  fail startup 'planning fixture did not open'
  exit 1
fi
tmux_cmd send-keys -t "$session" Escape
sleep 1

if ! mx lem-yath-test-org-planning-bindings; then
  fail bindings-command 'the editor did not accept the binding probe'
  exit 1
fi
sleep 0.5
if grep -q '^C-c C-s LEM-YATH-ORG-SCHEDULE$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/bindings" &&
   grep -q '^C-c C-d LEM-YATH-ORG-DEADLINE$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/bindings"; then
  pass bindings 'stock Org chords resolve in the active mode map'
else
  fail bindings 'one or both planning chords did not resolve'
fi

tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Schedule date \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '+2d'
  tmux_cmd send-keys -t "$session" Enter
else
  fail schedule-prompt 'C-c C-s did not open the date prompt'
fi

if snapshot 1 &&
   grep -q '^SCHEDULED: <2026-07-17 Fri>$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-1" &&
   cmp -s "$fixture" "$root/original.org"; then
  pass schedule 'relative scheduling edits only the live Org buffer'
else
  fail schedule 'relative scheduling or unsaved-buffer behavior differed'
fi

tmux_cmd send-keys -t "$session" C-c C-d
if lem_wait_for "$session" 'Deadline date \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '+1w'
  tmux_cmd send-keys -t "$session" Enter
else
  fail deadline-prompt 'C-c C-d did not open the date prompt'
fi

if snapshot 2 &&
   grep -q '^DEADLINE: <2026-07-22 Wed> SCHEDULED: <2026-07-17 Fri>$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-2"; then
  pass deadline 'deadline insertion preserves the structural planning line'
else
  fail deadline 'deadline insertion produced the wrong date or field order'
fi

tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Schedule date \[2026-07-17\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '++1m'
  tmux_cmd send-keys -t "$session" Enter
else
  fail reschedule-prompt 'existing schedule did not reopen the date prompt'
fi

if snapshot 3 &&
   grep -q '^DEADLINE: <2026-07-22 Wed> SCHEDULED: <2026-08-17 Mon>$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-3" &&
   test "$(grep -o 'SCHEDULED:' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-3" | wc -l)" -eq 1; then
  pass reschedule 'double-relative input replaces the existing field once'
else
  fail reschedule 'existing scheduling was duplicated or miscomputed'
fi

tmux_cmd send-keys -t "$session" u
if snapshot 4 &&
   cmp -s "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-4" \
          "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-2"; then
  pass undo 'one Vi undo restores the complete prior planning line'
else
  fail undo 'rescheduling was not one undoable editor command'
fi

tmux_cmd send-keys -t "$session" C-c C-d
if lem_wait_for "$session" 'Deadline date \[2026-07-22\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" C-g
else
  fail cancel-prompt 'deadline cancellation did not reach the prompt'
fi
sleep 0.5
if snapshot 5 &&
   cmp -s "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-5" \
          "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-4"; then
  pass cancellation 'C-g leaves the planning line untouched'
else
  fail cancellation 'prompt cancellation mutated the buffer'
fi

tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Schedule date \[2026-07-17\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Enter
else
  fail default-prompt 'existing schedule was not offered as the default'
fi
if snapshot 6 &&
   cmp -s "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-6" \
          "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-5"; then
  pass default 'an empty submission accepts the bracketed existing date'
else
  fail default 'empty date submission did not retain the displayed default'
fi

tmux_cmd send-keys -t "$session" C-z
sleep 0.3
tmux_cmd send-keys -t "$session" C-u C-c C-d
sleep 0.5
if snapshot 7 &&
   ! grep -q 'DEADLINE:' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-7" &&
   grep -q '^SCHEDULED: <2026-07-17 Fri>$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-7"; then
  pass remove-one 'a universal prefix removes only the requested field'
else
  fail remove-one 'prefixed deadline removal damaged the planning line'
fi

tmux_cmd send-keys -t "$session" C-u C-c C-s
sleep 0.5
if snapshot 8 &&
   cmp -s "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-8" "$root/original.org"; then
  pass remove-line 'removing the final field deletes the complete planning line'
else
  fail remove-line 'final-field removal left whitespace or a blank line'
fi

mx lem-yath-test-org-planning-read-only
lem_wait_for "$session" 'Planning buffer read-only' 10 >/dev/null || true
tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Org buffer is read-only' 10 >/dev/null; then
  pass read-only 'read-only buffers fail before opening a date prompt'
else
  fail read-only 'read-only planning did not fail closed'
fi
mx lem-yath-test-org-planning-writable

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'Org planning TUI checks passed.\n'
