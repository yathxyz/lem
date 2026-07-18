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
#+PROPERTY: COLOR_ALL red "deep blue"
#+PROPERTY: COLOR_ALL+ green
* TODO Timestamp task
Insert active:
Insert inactive:
Replace active: <2026-07-17 Fri 09:30-10:30 +1w -2d>
Convert inactive: <2026-07-20 Mon +2w>
Shift me: [2026-07-15 Wed 08:00-09:00 +1m]
Forced time:
Immediate:
Cancelled:
Range active:
Range mixed:
Range existing: <2026-07-10 Fri +1w>
Range interrupted:
Range cancelled:
* TODO Clock shifts
:LOGBOOK:
CLOCK: [2026-07-18 Sat 10:01]--[2026-07-18 Sat 11:31] =>  9:99
CLOCK: [2026-07-18 Sat 12:00]--[2026-07-18 Sat 13:30] =>  1:30
CLOCK: [2026-07-18 Sat 14:00]--[2026-07-18 Sat 15:30] =>  1:30
CLOCK: [2024-01-31 Wed 10:00]--[2024-01-31 Wed 11:30] =>  1:30
CLOCK: [2026-07-20 Mon 08:00]--[2026-07-20 Mon 09:30] =>  1:30
CLOCK: [2020-02-29 Sat 10:00]--[2020-02-29 Sat 11:30] =>  1:30
CLOCK: [2026-07-18 Sat 16:00]
CLOCK: [2026-07-18 Sat 18:00]--[2026-07-18 Sat 19:30] =>  1:30
CLOCK: [2026-07-18 Sat 20:00]--[2026-07-18 Sat 21:30] =>  1:30
:END:
Outside clock shift
* Shift contexts
- first
  shift continuation
  - child
- second
Horizontal table:
| left | middle | right |
|------+--------+-------|
| low  | center | high  |
#+TBLFM: $3=$1
Vertical year: <2020-02-29 Sat>
Vertical month: <2024-01-31 Wed>
Vertical day: <2026-07-20 Mon>
Vertical hour: <2026-07-18 Sat 23:00-23:30>
Vertical minute: <2026-07-18 Sat 10:01-11:31>
Vertical end: <2026-07-18 Sat 10:00-11:31>
Vertical prefix: <2026-07-18 Sat 14:00-15:30>
Vertical bracket: <2026-07-18 Sat>
Vertical readonly: <2026-07-18 Sat>
* TODO Priority new
* TODO [#A] Priority high
* Property parent
:PROPERTIES:
:STAGE_ALL: Backlog "In progress" Done :ETC
:END:
** Property child
:PROPERTIES:
:STAGE: Backlog
:COLOR: red
:LOCAL_ALL: red blue
:LOCAL: green
:FLAG: [-]
:FLAG_REVERSE: [-]
:SOLE_ALL: only
:SOLE: only
:MISSING: value
:READONLY_ALL: one two
:READONLY: one
:END:
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
   grep -q '^C-c Up LEM-YATH-ORG-CONTEXT-SHIFT-UP$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c Down LEM-YATH-ORG-CONTEXT-SHIFT-DOWN$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-x u UNDO$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^Shift-Left LEM-YATH-ORG-CONTEXT-SHIFT-LEFT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^Shift-Right LEM-YATH-ORG-CONTEXT-SHIFT-RIGHT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^Shift-Up LEM-YATH-ORG-CONTEXT-SHIFT-UP$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^Shift-Down LEM-YATH-ORG-CONTEXT-SHIFT-DOWN$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-Shift-h LEM-YATH-ORG-SHIFTCONTROLLEFT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-Shift-l LEM-YATH-ORG-SHIFTCONTROLRIGHT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-Shift-k LEM-YATH-ORG-SHIFTCONTROLUP$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-Shift-j LEM-YATH-ORG-SHIFTCONTROLDOWN$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c H LEM-YATH-ORG-SHIFTCONTROLLEFT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c L LEM-YATH-ORG-SHIFTCONTROLRIGHT$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c K LEM-YATH-ORG-SHIFTCONTROLUP$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings" &&
   grep -q '^C-c J LEM-YATH-ORG-SHIFTCONTROLDOWN$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/bindings"; then
  pass bindings 'stock, Evil-Org, and terminal-fallback timestamp chords resolve'
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

goto_marker range-active
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '+2d'
  tmux_cmd send-keys -t "$session" Enter
  lem_wait_for "$session" 'Inserted <2026-07-17 Fri>' 10 >/dev/null
  tmux_cmd send-keys -t "$session" C-c .
  if lem_wait_for "$session" 'Timestamp \[2026-07-17\]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l '+4d'
    tmux_cmd send-keys -t "$session" Enter
  else
    fail range-active-second 'second C-c . did not default from the first timestamp'
  fi
else
  fail range-active-first 'first C-c . did not open the timestamp prompt'
fi
if snapshot 12 &&
   grep -q '^Range active:<2026-07-17 Fri>--<2026-07-19 Sun>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-12"; then
  pass range-active 'successive C-c . commands insert an active date range'
else
  fail range-active 'successive active timestamps did not form the expected range'
fi

goto_marker range-mixed
tmux_cmd send-keys -t "$session" C-c '!'
if lem_wait_for "$session" 'Inactive timestamp \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Enter
  lem_wait_for "$session" 'Inserted \[2026-07-15 Wed\]' 10 >/dev/null
  tmux_cmd send-keys -t "$session" C-c .
  if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l '+1d'
    tmux_cmd send-keys -t "$session" Enter
  else
    fail range-mixed-second 'active range end did not follow an inactive timestamp'
  fi
else
  fail range-mixed-first 'inactive range start did not open its prompt'
fi
if snapshot 13 &&
   grep -q '^Range mixed:\[2026-07-15 Wed\]--<2026-07-16 Thu>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-13"; then
  pass range-mixed 'active and inactive timestamp commands share succession'
else
  fail range-mixed 'mixed timestamp commands did not form the expected range'
fi

goto_marker range-existing
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Timestamp \[2026-07-10\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '++1d'
  tmux_cmd send-keys -t "$session" Enter
  lem_wait_for "$session" 'Updated <2026-07-11 Sat +1w>' 10 >/dev/null
  tmux_cmd send-keys -t "$session" C-c .
  if lem_wait_for "$session" 'Timestamp \[2026-07-11\]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l '++2d'
    tmux_cmd send-keys -t "$session" Enter
  else
    fail range-existing-second 'replacement did not leave point after the timestamp'
  fi
else
  fail range-existing-first 'existing timestamp did not open its prompt'
fi
if snapshot 14 &&
   grep -q '^Range existing: <2026-07-11 Sat +1w>--<2026-07-13 Mon>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-14"; then
  pass range-existing 'replacement preserves the start suffix and appends a clean end'
else
  fail range-existing 'existing timestamp range creation differed'
fi

goto_marker range-interrupted
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Enter
  lem_wait_for "$session" 'Inserted <2026-07-15 Wed>' 10 >/dev/null
  tmux_cmd send-keys -t "$session" Left Right
  tmux_cmd send-keys -t "$session" C-c .
  if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l '+3d'
    tmux_cmd send-keys -t "$session" Enter
  else
    fail range-interrupted-second 'timestamp replacement prompt did not reopen'
  fi
else
  fail range-interrupted-first 'interruption case did not insert its first timestamp'
fi
if snapshot 15 &&
   grep -q '^Range interrupted:<2026-07-18 Sat>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-15"; then
  pass range-interrupted 'ordinary movement breaks timestamp succession'
else
  fail range-interrupted 'an intervening command incorrectly created a range'
fi

goto_marker range-cancelled
tmux_cmd send-keys -t "$session" C-c .
if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Enter
  lem_wait_for "$session" 'Inserted <2026-07-15 Wed>' 10 >/dev/null
  tmux_cmd send-keys -t "$session" C-c .
  if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" C-g
    sleep 0.3
    tmux_cmd send-keys -t "$session" C-c .
    if lem_wait_for "$session" 'Timestamp \[2026-07-15\]' 10 >/dev/null; then
      tmux_cmd send-keys -t "$session" -l '+1d'
      tmux_cmd send-keys -t "$session" Enter
    else
      fail range-cancelled-third 'timestamp prompt did not recover after cancellation'
    fi
  else
    fail range-cancelled-second 'range-end prompt did not open before cancellation'
  fi
else
  fail range-cancelled-first 'cancellation case did not insert its first timestamp'
fi
if snapshot 16 &&
   grep -q '^Range cancelled:<2026-07-16 Thu>$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-16"; then
  pass range-cancelled 'cancelled timestamp command breaks succession'
else
  fail range-cancelled 'cancellation left a stale range continuation'
fi

goto_marker clock-heading
tmux_cmd send-keys -t "$session" C-c L
tmux_cmd send-keys -t "$session" C-c H
sleep 0.3
if snapshot 17 &&
   grep -q '^\* TODO Clock shifts$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-17"; then
  pass todo-set 'next/previous set leave the sole TODO keyword set unchanged'
else
  fail todo-set 'Shift-Control TODO-set behavior changed the sole keyword set'
fi

goto_marker clock-minute
tmux_cmd send-keys -t "$session" C-c K
sleep 0.3
if snapshot 18 &&
   grep -q '^CLOCK: \[2026-07-18 Sat 10:05\]--\[2026-07-18 Sat 11:35\] =>  1:30$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-18"; then
  pass clock-minute 'unprefixed Shift-Control rounds forward and preserves duration'
else
  fail clock-minute 'synchronous minute rounding or duration repair differed'
fi

tmux_cmd send-keys -t "$session" C-x u
sleep 0.3
if snapshot 19 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-19" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-17"; then
  pass clock-undo 'one Emacs undo restores both endpoints and the duration suffix'
else
  fail clock-undo 'synchronous CLOCK adjustment was not one undo transaction'
fi

goto_marker clock-hour
tmux_cmd send-keys -t "$session" C-c K
sleep 0.3
if snapshot 20 &&
   grep -q '^CLOCK: \[2026-07-18 Sat 13:00\]--\[2026-07-18 Sat 14:30\] =>  1:30$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-20"; then
  pass clock-hour 'cursor-selected hour shifts both endpoints by one hour'
else
  fail clock-hour 'hour-unit selection or synchronous shift differed'
fi

goto_marker clock-prefix
tmux_cmd send-keys -t "$session" C-u 3 C-c K
sleep 0.3
if snapshot 21 &&
   grep -q '^CLOCK: \[2026-07-18 Sat 14:03\]--\[2026-07-18 Sat 15:33\] =>  1:30$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-21"; then
  pass clock-prefix 'numeric prefix uses exact minutes without five-minute rounding'
else
  fail clock-prefix 'prefixed CLOCK adjustment ignored or rounded the prefix'
fi

goto_marker clock-month
tmux_cmd send-keys -t "$session" C-c K
sleep 0.3
if snapshot 22 &&
   grep -q '^CLOCK: \[2024-03-02 Sat 10:00\]--\[2024-03-02 Sat 11:30\] =>  1:30$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-22"; then
  pass clock-calendar 'month overflow matches the pinned GNU Org oracle'
else
  fail clock-calendar 'calendar-unit overflow differed from GNU Org'
fi

goto_marker clock-day
tmux_cmd send-keys -t "$session" C-c K
sleep 0.3
goto_marker clock-year
tmux_cmd send-keys -t "$session" C-c K
sleep 0.3
if snapshot 23 &&
   grep -q '^CLOCK: \[2026-07-21 Tue 08:00\]--\[2026-07-21 Tue 09:30\] =>  1:30$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-23" &&
   grep -q '^CLOCK: \[2021-03-01 Mon 10:00\]--\[2021-03-01 Mon 11:30\] =>  1:30$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-23"; then
  pass clock-date-fields 'day and leap-year fields match pinned Org rollover'
else
  fail clock-date-fields 'day or year cursor-unit adjustment differed'
fi

goto_marker clock-open
tmux_cmd send-keys -t "$session" C-c K
sleep 0.3
if snapshot 24 &&
   grep -q '^CLOCK: \[2026-07-18 Sat 16:05\]$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-24"; then
  pass clock-open 'a lone running CLOCK timestamp follows Org documented fallback'
else
  fail clock-open 'open CLOCK adjustment crashed or changed the wrong field'
fi

tmux_cmd send-keys -t "$session" C-c J
sleep 0.3
if snapshot 25 &&
   grep -q '^CLOCK: \[2026-07-18 Sat 16:00\]$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-25"; then
  pass clock-down 'Shift-Control down reverses the rounded minute adjustment'
else
  fail clock-down 'downward CLOCK adjustment changed the wrong unit or direction'
fi

goto_marker clock-meta
tmux_cmd send-keys -t "$session" M-K
sleep 0.3
if snapshot 26 &&
   grep -q '^CLOCK: \[2026-07-18 Sat 18:00\]--\[2026-07-18 Sat 19:35\] =>  1:35$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-26"; then
  pass clock-meta 'M-K adjusts only the selected endpoint and recomputes duration'
else
  fail clock-meta 'Shift-Meta CLOCK endpoint adjustment remained unavailable'
fi

goto_marker clock-read-only
mx lem-yath-test-org-timestamp-read-only
tmux_cmd send-keys -t "$session" C-c K
if lem_wait_for "$session" 'Org buffer is read-only' 10 >/dev/null; then
  pass clock-read-only 'CLOCK commands refuse before mutating a read-only line'
else
  fail clock-read-only 'read-only CLOCK adjustment did not fail closed'
fi
mx lem-yath-test-org-timestamp-writable
if snapshot 27 &&
   grep -q '^CLOCK: \[2026-07-18 Sat 20:00\]--\[2026-07-18 Sat 21:30\] =>  1:30$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-27"; then
  pass clock-read-only-state 'read-only refusal leaves the CLOCK byte-identical'
else
  fail clock-read-only-state 'read-only refusal altered CLOCK text'
fi

goto_marker outside-clock
tmux_cmd send-keys -t "$session" C-c K
if lem_wait_for "$session" 'Not at a CLOCK log' 10 >/dev/null; then
  pass clock-context 'Shift-Control clock adjustment refuses outside CLOCK logs'
else
  fail clock-context 'non-CLOCK context did not report a bounded refusal'
fi

goto_marker list-continuation
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 28 &&
   grep -q '^+ first$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-28" &&
   grep -q '^  shift continuation$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-28" &&
   grep -q '^  - child$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-28" &&
   grep -q '^+ second$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-28"; then
  pass list-bullet 'Shift-Right cycles the complete list level from - to +'
else
  fail list-bullet 'list-level bullet cycling changed the wrong lines'
fi

tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 29 &&
   grep -q '^1\. first$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-29" &&
   grep -q '^   shift continuation$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-29" &&
   grep -q '^   - child$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-29" &&
   grep -q '^2\. second$' "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-29"; then
  pass list-numbering 'bullet-width changes preserve child and continuation structure'
else
  fail list-numbering 'ordered conversion or structural indentation differed'
fi

tmux_cmd send-keys -t "$session" C-x u
sleep 0.3
if snapshot 30 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-30" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-28"; then
  pass list-undo 'one Emacs undo restores the complete prior list level'
else
  fail list-undo 'list bullet cycling split into multiple undo steps'
fi

goto_marker table-first
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 31 &&
   grep -q '^| middle | left   | right |$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-31" &&
   grep -q '^#+TBLFM: \$3=\$1$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-31"; then
  pass table-cell 'Shift-Right swaps one table cell and preserves formulas'
else
  fail table-cell 'horizontal table-cell movement changed the wrong structure'
fi

tmux_cmd send-keys -t "$session" C-x u
sleep 0.3
if snapshot 32 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-32" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-30"; then
  pass table-undo 'one Emacs undo restores the complete aligned table'
else
  fail table-undo 'table-cell movement split into multiple undo steps'
fi

goto_marker table-last
tmux_cmd send-keys -t "$session" C-c Right
if lem_wait_for "$session" 'Cannot move table cell further' 10 >/dev/null &&
   snapshot 33 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-33" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-32"; then
  pass table-edge 'edge movement refuses before changing or aligning the table'
else
  fail table-edge 'edge refusal mutated the table or did not report failure'
fi

goto_marker vertical-year
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.3
if snapshot 34 &&
   grep -q '^Vertical year: <2021-03-01 Mon>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-34"; then
  pass vertical-year 'Shift-Up changes the selected year with GNU overflow'
else
  fail vertical-year 'ordinary timestamp year movement differed'
fi

goto_marker vertical-month
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.2
goto_marker vertical-day
tmux_cmd send-keys -t "$session" C-c Down
sleep 0.2
goto_marker vertical-hour
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.2
goto_marker vertical-end
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.2
goto_marker vertical-prefix
tmux_cmd send-keys -t "$session" C-u 3 C-c Up
sleep 0.3
if snapshot 35 &&
   grep -q '^Vertical month: <2024-03-02 Sat>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-35" &&
   grep -q '^Vertical day: <2026-07-19 Sun>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-35" &&
   grep -q '^Vertical hour: <2026-07-19 Sun 00:00-00:30>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-35" &&
   grep -q '^Vertical end: <2026-07-18 Sat 10:00-11:35>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-35" &&
   grep -q '^Vertical prefix: <2026-07-18 Sat 14:03-15:33>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-35"; then
  pass vertical-fields 'month/day/hour/end-only/prefix shifts match GNU Org'
else
  fail vertical-fields 'one or more ordinary timestamp field shifts differed'
fi

goto_marker vertical-minute
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.3
if snapshot 36 &&
   grep -q '^Vertical minute: <2026-07-18 Sat 10:05-11:35>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-36"; then
  pass vertical-minute 'minute rounding moves both ends of an ordinary range'
else
  fail vertical-minute 'ordinary timestamp minute rounding or range repair differed'
fi

tmux_cmd send-keys -t "$session" C-c Down
sleep 0.3
if snapshot 37 &&
   grep -q '^Vertical minute: <2026-07-18 Sat 10:00-11:30>$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-37"; then
  pass vertical-down 'Shift-Down rounds backward and preserves range duration'
else
  fail vertical-down 'ordinary timestamp downward rounding differed'
fi

goto_marker vertical-bracket
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.3
if snapshot 38 &&
   grep -q '^Vertical bracket: \[2026-07-18 Sat\]$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-38"; then
  pass vertical-bracket 'Shift-Up on a bracket toggles timestamp activity'
else
  fail vertical-bracket 'timestamp bracket dispatch did not toggle delimiter type'
fi

goto_marker vertical-readonly
mx lem-yath-test-org-timestamp-read-only
lem_wait_for "$session" 'Timestamp buffer read-only' 10 >/dev/null
tmux_cmd send-keys -t "$session" C-c Up
if lem_wait_for "$session" 'Org buffer is read-only' 10 >/dev/null &&
   snapshot 39 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-39" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-38"; then
  pass vertical-read-only 'ordinary timestamp shifting refuses before mutation'
else
  fail vertical-read-only 'read-only ordinary timestamp changed or did not refuse'
fi
mx lem-yath-test-org-timestamp-writable
lem_wait_for "$session" 'Timestamp buffer writable' 10 >/dev/null

goto_marker priority-new
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.2
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.3
goto_marker priority-high
tmux_cmd send-keys -t "$session" C-c Down
sleep 0.3
if snapshot 40 &&
   grep -q '^\* TODO \[#A\] Priority new$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-40" &&
   grep -q '^\* TODO \[#B\] Priority high$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-40" &&
   grep -q '^\* TODO Priority new$' "$fixture" &&
   grep -q '^\* TODO \[#A\] Priority high$' "$fixture"; then
  pass vertical-priority 'A/B/C priority steps match Org and remain unsaved'
else
  fail vertical-priority 'heading priority stepping or persistence differed'
fi

goto_marker list-second
tmux_cmd send-keys -t "$session" C-c Up
sleep 0.3
mx lem-yath-test-org-timestamp-point
if lem_wait_for "$session" 'Timestamp point captured' 10 >/dev/null &&
   grep -q '^column=0 line=+ first$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/point"; then
  pass vertical-list-up 'Shift-Up navigates to the previous direct sibling'
else
  fail vertical-list-up 'list navigation did not land at the prior sibling BOL'
fi
tmux_cmd send-keys -t "$session" C-c Down
sleep 0.3
mx lem-yath-test-org-timestamp-point
if lem_wait_for "$session" 'Timestamp point captured' 10 >/dev/null &&
   grep -q '^column=0 line=+ second$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/point"; then
  pass vertical-list-down 'Shift-Down returns to the next direct sibling'
else
  fail vertical-list-down 'list navigation did not land at the next sibling BOL'
fi

goto_marker table-first
tmux_cmd send-keys -t "$session" C-c Down
sleep 0.3
if snapshot 41 &&
   grep -q '^| low  | middle | right |$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-41" &&
   grep -q '^| left | center | high  |$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-41" &&
   grep -q '^#+TBLFM: \$3=\$1$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-41"; then
  pass vertical-table 'Shift-Down swaps cells across a horizontal rule'
else
  fail vertical-table 'vertical table-cell movement or hline skipping differed'
fi

tmux_cmd send-keys -t "$session" C-x u
sleep 0.3
if snapshot 42 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-42" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-40"; then
  pass vertical-table-undo 'one Emacs undo restores both table rows'
else
  fail vertical-table-undo 'vertical table movement split into multiple undo steps'
fi

goto_marker table-bottom
tmux_cmd send-keys -t "$session" C-c Down
if lem_wait_for "$session" 'Cannot move table cell further' 10 >/dev/null &&
   snapshot 43 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-43" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-42"; then
  pass vertical-table-edge 'bottom-edge movement refuses byte-identically'
else
  fail vertical-table-edge 'bottom-edge refusal mutated or aligned the table'
fi

goto_marker property-stage
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 44 &&
   grep -q '^:STAGE: In progress$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-44" &&
   grep -q '^:STAGE: Backlog$' "$fixture"; then
  pass property-inherit 'inherited _ALL values decode quoted text without saving'
else
  fail property-inherit 'inherited or quoted property cycling differed'
fi

tmux_cmd send-keys -t "$session" C-c Right
sleep 0.2
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 45 &&
   grep -q '^:STAGE: Backlog$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-45"; then
  pass property-wrap 'forward property cycling wraps and ignores :ETC'
else
  fail property-wrap 'forward property cycling did not wrap at the final value'
fi

tmux_cmd send-keys -t "$session" C-c Left
sleep 0.3
if snapshot 46 &&
   grep -q '^:STAGE: Done$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-46"; then
  pass property-reverse 'Shift-Left cycles inherited values in reverse'
else
  fail property-reverse 'reverse property cycling selected the wrong value'
fi

tmux_cmd send-keys -t "$session" C-x u
sleep 0.3
if snapshot 47 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-47" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-45"; then
  pass property-undo 'one Emacs undo restores one complete property cycle'
else
  fail property-undo 'property cycling was not one undoable editor command'
fi

goto_marker property-color
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 48 &&
   grep -q '^:COLOR: deep blue$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-48"; then
  pass property-file 'file-wide _ALL keywords provide quoted allowed values'
else
  fail property-file 'file-wide property allowed values were not inherited'
fi
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 49 &&
   grep -q '^:COLOR: green$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-49"; then
  pass property-append 'file-wide KEY+ values extend the property cycle'
else
  fail property-append 'appended file-wide property values were omitted'
fi

goto_marker property-local
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 50 &&
   grep -q '^:LOCAL: red$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-50"; then
  pass property-unlisted 'an unlisted current value enters at the first value'
else
  fail property-unlisted 'unlisted property fallback selected the wrong value'
fi

goto_marker property-flag
tmux_cmd send-keys -t "$session" C-c Right
sleep 0.3
if snapshot 51 &&
   grep -q '^:FLAG: \[ \]$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-51"; then
  pass property-checkbox 'checkbox properties use the GNU unchecked/checked cycle'
else
  fail property-checkbox 'checkbox property fallback selected the wrong value'
fi
goto_marker property-flag-reverse
tmux_cmd send-keys -t "$session" C-c Left
sleep 0.3
if snapshot 52 &&
   grep -q '^:FLAG_REVERSE: \[X\]$' \
     "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-52"; then
  pass property-checkbox-reverse 'reverse checkbox cycling chooses checked'
else
  fail property-checkbox-reverse 'reverse checkbox property fallback differed'
fi

goto_marker property-missing
tmux_cmd send-keys -t "$session" C-c Right
if lem_wait_for "$session" \
     'Allowed values for this property have not been defined' 10 >/dev/null &&
   snapshot 53 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-53" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-52"; then
  pass property-missing 'missing _ALL declarations refuse byte-identically'
else
  fail property-missing 'missing allowed values mutated or failed ambiguously'
fi

goto_marker property-sole
tmux_cmd send-keys -t "$session" C-c Right
if lem_wait_for "$session" 'Only one allowed value for this property' \
     10 >/dev/null &&
   snapshot 54 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-54" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-53"; then
  pass property-single 'a sole unchanged value refuses byte-identically'
else
  fail property-single 'single-value property handling mutated or differed'
fi

goto_marker property-read-only
mx lem-yath-test-org-timestamp-read-only
lem_wait_for "$session" 'Timestamp buffer read-only' 10 >/dev/null
tmux_cmd send-keys -t "$session" C-c Right
if lem_wait_for "$session" 'Org buffer is read-only' 10 >/dev/null &&
   snapshot 55 &&
   cmp -s "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-55" \
          "$LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS/state-54"; then
  pass property-read-only 'read-only property cycling refuses before mutation'
else
  fail property-read-only 'read-only property cycling changed the buffer'
fi
mx lem-yath-test-org-timestamp-writable

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'Org timestamp TUI checks passed.\n'
