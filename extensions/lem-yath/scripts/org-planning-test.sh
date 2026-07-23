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
* TODO Cookie task
DEADLINE: <2026-07-22 Wed +1w -3d> SCHEDULED: <2026-07-17 Fri +1w --2d>
* TODO Region parent
Region parent body.
** TODO Region child
Region child body.
* TODO Region sibling
* TODO Region outside
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
  tmux_cmd send-keys -t "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  lem_wait_for "$session" "Command: $command" 10 >/dev/null || return 1
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

if mx lem-yath-test-org-date-static &&
   lem_wait_for "$session" 'Org date static passed' 10 >/dev/null &&
   grep -q '^PASS$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/date-static"; then
  pass date-parser 'named, partial, relative, ISO-week, and invalid forms match Org semantics'
else
  fail date-parser "shared date parser diverged: $(cat "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/date-static" 2>/dev/null)"
fi

tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Schedule date \[2026-07-15\]' 10 >/dev/null; then
  if lem_capture "$session" | grep -q 'June 2026' &&
     lem_capture "$session" | grep -q 'July 2026' &&
     lem_capture "$session" | grep -q 'August 2026'; then
    pass calendar-popup 'the date prompt displays the surrounding three months'
  else
    fail calendar-popup 'the three-month calendar was absent or clipped'
  fi
  tmux_cmd send-keys -t "$session" -l 'fri'
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
  tmux_cmd send-keys -t "$session" -l '>'
  tmux_cmd send-keys -t "$session" Enter
else
  fail reschedule-prompt 'existing schedule did not reopen the date prompt'
fi

if snapshot 3 &&
   grep -q '^DEADLINE: <2026-07-22 Wed> SCHEDULED: <2026-08-17 Mon>$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-3" &&
   test "$(sed -n '2p' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-3" | grep -o 'SCHEDULED:' | wc -l)" -eq 1; then
  pass reschedule 'calendar month motion replaces the existing field once'
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
if grep -q '^active=NORMAL buffer=NORMAL$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/mode-6"; then
  pass prompt-state 'the date prompt restored the source buffer to Normal state'
else
  fail prompt-state "date prompt state diverged: $(cat "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/mode-6" 2>/dev/null)"
fi

tmux_cmd send-keys -t "$session" C-z
sleep 0.3
mx lem-yath-test-org-planning-goto-cookie
tmux_cmd send-keys -t "$session" C-c C-d
if lem_wait_for "$session" 'Deadline date \[2026-07-22\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '++1d'
  tmux_cmd send-keys -t "$session" Enter
else
  fail preserve-prompt 'cookie deadline did not offer its existing date'
fi
if snapshot 7 &&
   grep -q '^DEADLINE: <2026-07-23 Thu +1w -3d> SCHEDULED: <2026-07-17 Fri +1w --2d>$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-7"; then
  pass preserve-cookies 'ordinary rescheduling preserves repeater and warning syntax'
else
  fail preserve-cookies 'rescheduling discarded or changed planning cookies'
fi

tmux_cmd send-keys -t "$session" C-u C-u C-c C-d
if lem_wait_for "$session" 'Warn starting from \[2026-07-23\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '2026-07-18'
  tmux_cmd send-keys -t "$session" Enter
else
  fail warning-prompt 'double prefix did not open the deadline warning prompt'
fi
if snapshot 8 &&
   grep -q '^DEADLINE: <2026-07-23 Thu +1w -5d> SCHEDULED: <2026-07-17 Fri +1w --2d>$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-8"; then
  pass warning-cookie 'double prefix replaces only the deadline warning cookie'
else
  fail warning-cookie 'deadline warning update damaged its repeater or schedule'
fi

tmux_cmd send-keys -t "$session" C-u C-u C-c C-s
if lem_wait_for "$session" 'Delay until \[2026-07-17\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '2026-07-20'
  tmux_cmd send-keys -t "$session" Enter
else
  fail delay-prompt 'double prefix did not open the scheduled-delay prompt'
fi
if snapshot 9 &&
   grep -q '^DEADLINE: <2026-07-23 Thu +1w -5d> SCHEDULED: <2026-07-17 Fri +1w -3d>$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-9"; then
  pass delay-cookie 'double prefix replaces --delay syntax and preserves its repeater'
else
  fail delay-cookie 'scheduled-delay update damaged the planning line'
fi

mx lem-yath-test-org-planning-goto-planned
tmux_cmd send-keys -t "$session" C-u C-c C-d
sleep 0.5
if snapshot 10 &&
   ! sed -n '1,3p' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-10" | grep -q 'DEADLINE:' &&
   grep -q '^SCHEDULED: <2026-07-17 Fri>$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-10"; then
  pass remove-one 'a universal prefix removes only the requested field'
else
  fail remove-one 'prefixed deadline removal damaged the planning line'
fi

tmux_cmd send-keys -t "$session" C-u C-c C-s
sleep 0.5
if snapshot 11 &&
   [ "$(sed -n '1,3p' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-11")" = \
     $'* TODO Planned task\nBody remains here.\n* TODO Cookie task' ] &&
   grep -q '^DEADLINE: <2026-07-23 Thu +1w -5d> SCHEDULED: <2026-07-17 Fri +1w -3d>$' \
     "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-11"; then
  pass remove-line 'removing the final field deletes the complete planning line'
else
  fail remove-line 'final-field removal left whitespace or a blank line'
fi

tmux_cmd send-keys -t "$session" C-u C-u C-c C-s
sleep 0.5
if lem_capture "$session" | grep -q 'No schedule information to update' &&
   snapshot 12 &&
   cmp -s "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-12" \
          "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-11"; then
  pass missing-cookie 'double prefix refuses a missing planning field without prompting'
else
  fail missing-cookie 'missing-field cookie update prompted or mutated the buffer'
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

# GNU Org maps planning commands over every headline in an active region,
# including nested headings, and prompts independently for each one.
tmux_cmd send-keys -t "$session" C-z
sleep 0.3
mx lem-yath-test-org-planning-goto-region
lem_wait_for "$session" 'Planning region ready' 10 >/dev/null ||
  fail region-ready 'region setup command did not settle'
tmux_cmd send-keys -t "$session" Escape
sleep 0.3
tmux_cmd send-keys -t "$session" -l v
tmux_cmd send-keys -t "$session" -l a
tmux_cmd send-keys -t "$session" -l R
tmux_cmd send-keys -t "$session" F8
lem_wait_for "$session" 'Planning region targets recorded' 10 >/dev/null ||
  fail region-targets-probe 'Visual target probe did not run'
if grep -q '^visual=T line=T$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/region-targets" &&
   grep -q '^\* TODO Region parent$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/region-targets" &&
   grep -q '^\*\* TODO Region child$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/region-targets" &&
   ! grep -q 'Region sibling' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/region-targets"; then
  pass region-targets 'the Evil-Org subtree object exposes parent and child headlines'
else
  fail region-targets \
    "Visual subtree targets diverged: $(tr '\n' '|' < "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/region-targets" 2>/dev/null)"
fi
tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Schedule date \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '+1d'
  tmux_cmd send-keys -t "$session" Enter
else
  fail region-first-prompt 'Visual scheduling did not prompt for the parent'
fi
if lem_wait_for "$session" 'Schedule date \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '+2d'
  tmux_cmd send-keys -t "$session" Enter
else
  fail region-second-prompt 'Visual scheduling did not prompt for the child'
fi
sleep 0.5
if snapshot 13 &&
   grep -A1 '^\* TODO Region parent$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-13" |
     grep -q '^SCHEDULED: <2026-07-16 Thu>$' &&
   grep -A1 '^\*\* TODO Region child$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-13" |
     grep -q '^SCHEDULED: <2026-07-17 Fri>$' &&
   ! grep -A1 '^\* TODO Region sibling$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-13" |
     grep -q 'SCHEDULED:' &&
   ! grep -A1 '^\* TODO Region outside$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-13" |
     grep -q 'SCHEDULED:'; then
  pass region-schedule 'Visual scheduling prompts for selected nested headlines only'
else
  fail region-schedule \
    "Visual scheduling changed the wrong headline set; targets: $(tr '\n' '|' < "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/region-targets" 2>/dev/null)"
fi

# Pinned GNU Org keeps earlier region edits when a later per-heading prompt is
# cancelled.  Exercise that non-atomic edge explicitly rather than promising a
# stronger cancellation boundary than the source configuration provides.
tmux_cmd send-keys -t "$session" Escape
sleep 0.3
mx lem-yath-test-org-planning-goto-region
lem_wait_for "$session" 'Planning region ready' 10 >/dev/null ||
  fail region-cancel-ready 'cancellation region setup did not settle'
tmux_cmd send-keys -t "$session" Escape
sleep 0.3
tmux_cmd send-keys -t "$session" -l v
tmux_cmd send-keys -t "$session" -l a
tmux_cmd send-keys -t "$session" -l R
tmux_cmd send-keys -t "$session" C-c C-d
if lem_wait_for "$session" 'Deadline date \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '+4d'
  tmux_cmd send-keys -t "$session" Enter
else
  fail region-cancel-first 'Visual deadline did not prompt for the parent'
fi
if lem_wait_for "$session" 'Deadline date \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" C-g
else
  fail region-cancel-second 'Visual deadline did not reach the child prompt'
fi
sleep 0.5
if snapshot 14 &&
   grep -A1 '^\* TODO Region parent$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-14" |
     grep -q '^DEADLINE: <2026-07-19 Sun> SCHEDULED:' &&
   ! grep -A1 '^\*\* TODO Region child$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-14" |
     grep -q 'DEADLINE:' &&
   ! grep -A1 '^\* TODO Region sibling$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-14" |
     grep -q 'DEADLINE:'; then
  pass region-cancel 'later cancellation retains only the earlier GNU Org edit'
else
  fail region-cancel 'region cancellation did not match GNU Org partial progress'
fi

# A Visual subtree object supplies an exact parent/child region.  One prefix
# removes scheduling from both headings and one Emacs-state undo restores the
# complete multi-heading command.
tmux_cmd send-keys -t "$session" Escape
sleep 0.3
mx lem-yath-test-org-planning-goto-region
lem_wait_for "$session" 'Planning region ready' 10 >/dev/null ||
  fail region-remove-ready 'removal region setup did not settle'
tmux_cmd send-keys -t "$session" Escape
sleep 0.3
tmux_cmd send-keys -t "$session" -l v
tmux_cmd send-keys -t "$session" -l a
tmux_cmd send-keys -t "$session" -l R
tmux_cmd send-keys -t "$session" C-z
sleep 0.3
tmux_cmd send-keys -t "$session" C-u C-c C-s
sleep 0.5
if snapshot 15 &&
   ! grep -A2 '^\* TODO Region parent$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-15" |
     grep -q 'SCHEDULED:' &&
   ! grep -A2 '^\*\* TODO Region child$' "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-15" |
     grep -q 'SCHEDULED:'; then
  pass region-remove 'a prefix removes the field across a Visual subtree only'
else
  fail region-remove 'Visual prefix removal escaped or missed the subtree'
fi
tmux_cmd send-keys -t "$session" C-/
sleep 0.5
if snapshot 16 &&
   cmp -s "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-16" \
          "$LEM_YATH_ORG_PLANNING_SNAPSHOTS/state-14"; then
  pass region-undo 'one undo restores every field removed by the region command'
else
  fail region-undo 'region planning split into multiple undo steps'
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'Org planning TUI checks passed.\n'
