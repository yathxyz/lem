#!/usr/bin/env bash
# GNU Org/Evil-Org agenda spans and date navigation in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-view-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-view.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_VIEW_REPORT="$root/report"
export TZ=Europe/Dublin
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR/mcp"

work_file="$WORKDIR/view.org"
original_file="$root/view.original"
session="lem-agenda-view-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-view-fixture.lisp")"
init="$(lem-yath_lisp_string "$LEM_YATH_SOURCE/init.lisp")"
FAILED=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-22s %s\n' "$1" "$2"; }
fail() {
  FAILED=1
  printf 'FAIL  %-22s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,240p' "$LEM_YATH_AGENDA_VIEW_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 160); do
    grep -qE "$pattern" "$LEM_YATH_AGENDA_VIEW_REPORT" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_clock_state() {
  local pattern="$1" i
  for i in $(seq 1 160); do
    send_keys C-c z c
    grep -qE "$pattern" "$LEM_YATH_AGENDA_VIEW_REPORT" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

send_keys() { tmux_cmd send-keys -t "$session" "$@"; }
wait_agenda() { lem_wait_for "$session" 'Unscheduled view sentinel' 30 >/dev/null; }

printf '%s\n' \
  '* TODO Past view sentinel' \
  'DEADLINE: <2026-07-10 Fri>' \
  '* TODO Monday view sentinel' \
  'SCHEDULED: <2026-07-13 Mon>' \
  '* TODO Today view sentinel' \
  'SCHEDULED: <2026-07-17 Fri>' \
  '* Late grid sentinel <2026-07-17 Fri 10:00>' \
  '* Early grid range sentinel <2026-07-17 Fri 9:00-10:30>' \
  '* Hourly repeat sentinel <2026-07-17 Fri 08:30 +36h>' \
  '* Cross timed range sentinel <2026-07-17 Fri 15:30>--<2026-07-18 Sat 16:45>' \
  '* TODO Headline morning sentinel 9:30-10:15' \
  'SCHEDULED: <2026-07-17 Fri>' \
  '* TODO Headline lunch sentinel 12pm--1:05pm' \
  'DEADLINE: <2026-07-17 Fri>' \
  '* TODO Planning stamp sentinel 7am' \
  'SCHEDULED: <2026-07-17 Fri 11:20-11:50>' \
  '* TODO Link time sentinel [[https://example.test/9:45][clock]]' \
  'SCHEDULED: <2026-07-17 Fri>' \
  '* TODO Sunday view sentinel' \
  'DEADLINE: <2026-07-19 Sun>' \
  '* TODO Next Monday view sentinel' \
  'SCHEDULED: <2026-07-20 Mon>' \
  '* TODO Month end view sentinel' \
  'SCHEDULED: <2026-07-31 Fri>' \
  '* TODO August view sentinel' \
  'SCHEDULED: <2026-08-05 Wed>' \
  '* August grid range sentinel <2026-08-05 Wed 15:30-16:00>' \
  '* Ranged view sentinel <2026-07-15 Wed>--<2026-07-18 Sat>' \
  '* TODO Unscheduled view sentinel' \
  '* TODO Clock span view sentinel' \
  ':LOGBOOK:' \
  'CLOCK: [2026-07-17 Fri 10:00]--[2026-07-17 Fri 11:00] =>  1:00' \
  'CLOCK: [2026-08-05 Wed 10:00]--[2026-08-05 Wed 12:00] =>  2:00' \
  ':END:' \
  '* Anniversary fixture' \
  ':PROPERTIES:' \
  ':CATEGORY: Ann' \
  ':END:' \
  '%%(org-anniversary 2004 3 29) Birthday sentinel is %d years old.' \
  '%%(progn (error "unsafe")) Unsafe diary sentinel' \
  >"$work_file"
cp "$work_file" "$original_file"
: >"$LEM_YATH_AGENDA_VIEW_REPORT"

lem_start \
  "$session" \
  --eval "(progn (unless (find-package \"LEM-YATH\") (load #P$init)) (load #P$fixture) (funcall (intern \"LEM-YATH-AGENDA-SUMMARY\" \"LEM-YATH\")))"
if ! wait_agenda; then
  fail startup 'the agenda view fixture did not render'
  exit 1
fi

send_keys C-c z 0
send_keys C-c z n
wait_report '^KEYS normal ' || true
keys_ok=1
grep -q '^STATE initial span=summary start=2026-07-17 end=2026-07-24 header="Agenda  (2026-07-17)"' "$LEM_YATH_AGENDA_VIEW_REPORT" || keys_ok=0
grep -q '^KEYS normal earlier=LEM-YATH-AGENDA-EARLIER later=LEM-YATH-AGENDA-LATER dispatch=LEM-YATH-AGENDA-VIEW-MODE-DISPATCH today=LEM-YATH-AGENDA-GOTO-TODAY goto=LEM-YATH-AGENDA-GOTO-DATE refresh=LEM-YATH-AGENDA-REFRESH refresh-all=LEM-YATH-AGENDA-REFRESH$' "$LEM_YATH_AGENDA_VIEW_REPORT" || keys_ok=0
if [ "$keys_ok" = 1 ]; then
  pass keymap 'the effective Evil-Org view and refresh chords are live'
else
  fail keymap 'the effective view keymap or default summary differed'
fi

send_keys C-c z g
send_keys g j
send_keys C-c z p
wait_report '^POINT first ' || true
send_keys g j
send_keys C-c z P
wait_report '^POINT second ' || true
send_keys g j
send_keys C-c z q
wait_report '^POINT third ' || true
if grep -q '^POINT first grid=NIL file=yes time=08:30 end=NIL .*Hourly repeat sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" &&
   grep -q '^POINT second grid=NIL file=yes time=9:00 end=10:30 .*Early grid range sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" &&
   grep -q '^POINT third grid=NIL file=yes time=9:30 end=10:15 .*Headline morning sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass grid-motion 'gj skipped decorations and retained event/headline time metadata'
else
  fail grid-motion 'grid rows captured motion or source-backed time metadata was lost'
fi

send_keys g D w
lem_wait_for "$session" 'Week 2026-07-13..2026-07-19' 30 >/dev/null || true
send_keys C-c z 1
wait_report '^STATE week ' || true
wait_report '^TIMELINE week ' || true
week_ok=1
grep -q '^STATE week span=week start=2026-07-13 end=2026-07-19 .*point-date=2026-07-17 headers=7 ' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '2026-07-13|.*Monday view sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '2026-07-19|.*Sunday view sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q 'Early grid range sentinel.*\[EVENT 2026-07-17 9:00-10:30\]' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q 'Headline morning sentinel  \[SCHEDULED 2026-07-17 9:30-10:15\]' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q 'Headline lunch sentinel  \[DEADLINE 2026-07-17 12:00-13:05\]' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q 'Planning stamp sentinel 7am  \[SCHEDULED 2026-07-17 11:20-11:50\]' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q 'Link time sentinel .*9:45.*\[SCHEDULED 2026-07-17\]' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '2026-07-17|.*Cross timed range sentinel --<2026-07-18 Sat 16:45>.*\[EVENT 2026-07-17 15:30 1/2\]' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '2026-07-18|.*Cross timed range sentinel <2026-07-17 Fri 15:30>--.*\[EVENT 2026-07-18 16:45 2/2\]' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '^TIMELINE week grid-0800,item-0830,item-0900-1030,item-0930-1015,grid-1000,item-1000,item-1120-1150,grid-1200,item-1200-1305,now-1300,grid-1400,item-1530,grid-1600,grid-1800,grid-2000$' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '^HOURLY week dates=2026-07-17,2026-07-18$' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
if [ "$week_ok" = 1 ]; then
  pass week-view 'gD w aligned to Monday and rendered all seven date sections'
else
  fail week-view 'weekly alignment, point restoration, or date grouping differed'
fi

send_keys g D t
lem_wait_for "$session" 'Fortnight 2026-07-13..2026-07-26' 30 >/dev/null || true
send_keys C-c z f
wait_report '^STATE fortnight ' || true
wait_report '^HOURLY fortnight ' || true
if grep -q '^STATE fortnight span=fortnight start=2026-07-13 end=2026-07-26 .*point-date=2026-07-17 headers=14 ' "$LEM_YATH_AGENDA_VIEW_REPORT" &&
   grep -q '^HOURLY fortnight dates=2026-07-17,2026-07-18,2026-07-20,2026-07-21,2026-07-23,2026-07-24,2026-07-26$' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass fortnight-view 'gD t rendered the Monday-aligned fourteen-day span'
else
  fail fortnight-view 'fortnight boundaries, hour repeater dates, or point restoration differed'
fi
send_keys g D w
lem_wait_for "$session" 'Week 2026-07-13..2026-07-19' 30 >/dev/null || true

send_keys ']' ']'
lem_wait_for "$session" 'Week 2026-07-20..2026-07-26' 30 >/dev/null || true
send_keys C-c z 2
wait_report '^STATE later ' || true
later_ok=1
grep -q '^STATE later span=week start=2026-07-20 end=2026-07-26 .*point-date=2026-07-24 headers=7 ' "$LEM_YATH_AGENDA_VIEW_REPORT" || later_ok=0
grep -q '2026-07-20|.*Next Monday view sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" || later_ok=0
send_keys '[' '['
lem_wait_for "$session" 'Week 2026-07-13..2026-07-19' 30 >/dev/null || true
send_keys C-c z 3
wait_report '^STATE earlier ' || true
grep -q '^STATE earlier span=week start=2026-07-13 end=2026-07-19 .*point-date=2026-07-17 headers=7 ' "$LEM_YATH_AGENDA_VIEW_REPORT" || later_ok=0
if [ "$later_ok" = 1 ]; then
  pass span-motion ']] and [[ moved one current span while retaining day offset'
else
  fail span-motion 'span navigation or relative point restoration differed'
fi

send_keys ']' ']'
lem_wait_for "$session" 'Week 2026-07-20..2026-07-26' 30 >/dev/null || true
send_keys .
lem_wait_for "$session" 'Week 2026-07-13..2026-07-19' 30 >/dev/null || true
send_keys C-c z 4
wait_report '^STATE today ' || true
if grep -q '^STATE today span=week start=2026-07-13 end=2026-07-19 .*point-date=2026-07-17 headers=7 ' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass today '. returned to and selected today in the current span type'
else
  fail today 'today navigation did not rebuild and select the current week'
fi

send_keys g d
lem_wait_for "$session" 'Agenda date' 10 >/dev/null || true
send_keys -l 2026-08-05
send_keys Enter
lem_wait_for "$session" 'Week 2026-08-05..2026-08-11' 30 >/dev/null || true
send_keys C-c z 5
wait_report '^STATE goto ' || true
wait_report '^TIMELINE goto ' || true
if grep -q '^STATE goto span=week start=2026-08-05 end=2026-08-11 .*point-date=2026-08-05 headers=7 .*2026-08-05|.*August view sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" &&
   grep -q '^TIMELINE goto item-0830,item-1530-1600$' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass goto-date 'gd used Org date input and retained the current seven-day span'
else
  fail goto-date 'gd did not rebuild from or select the requested date'
fi

send_keys g D m
lem_wait_for "$session" 'Month 2026-08-01..2026-08-31' 30 >/dev/null || true
send_keys C-c z 6
wait_report '^STATE month ' || true
if grep -q '^STATE month span=month start=2026-08-01 end=2026-08-31 .*point-date=2026-08-05 headers=31 ' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass month-view 'gD m canonicalized the selected date to its full month'
else
  fail month-view 'month boundaries or selected date restoration differed'
fi

send_keys g D d
lem_wait_for "$session" 'Day 2026-08-05' 30 >/dev/null || true
send_keys C-c z 7
wait_report '^STATE day ' || true
wait_report '^TIMELINE day ' || true
day_ok=1
grep -q '^STATE day span=day start=2026-08-05 end=2026-08-05 .*point-date=2026-08-05 headers=1 ' "$LEM_YATH_AGENDA_VIEW_REPORT" || day_ok=0
grep -q '^TIMELINE day grid-0800,item-0830,grid-1000,grid-1200,grid-1400,item-1530-1600,grid-1600,grid-1800,grid-2000$' "$LEM_YATH_AGENDA_VIEW_REPORT" || day_ok=0
send_keys C-u ']' ']'
lem_wait_for "$session" 'Day 2026-08-09' 30 >/dev/null || true
send_keys C-c z 8
wait_report '^STATE day-prefix ' || true
grep -q '^STATE day-prefix span=day start=2026-08-09 end=2026-08-09 .*point-date=2026-08-09 headers=1 ' "$LEM_YATH_AGENDA_VIEW_REPORT" || day_ok=0
if [ "$day_ok" = 1 ]; then
  pass day-prefix 'daily view and C-u ]] used Evil interactive-p count semantics'
else
  fail day-prefix 'daily span or universal-count motion differed'
fi

send_keys g D y
lem_wait_for "$session" 'entire year' 10 >/dev/null || true
send_keys y
for _ in $(seq 1 160); do
  send_keys C-c z 9
  grep -q '^ANNIVERSARY year date=2026-03-29 category=Ann file=yes ' "$LEM_YATH_AGENDA_VIEW_REPORT" 2>/dev/null && break
  sleep 0.1
done
if grep -q '^STATE year span=year start=2026-01-01 end=2026-12-31 .*point-date=2026-08-09 headers=365 .*2026-03-29|.*Ann:.*Birthday sentinel is 22 years old.*\[DIARY 2026-03-29\]' "$LEM_YATH_AGENDA_VIEW_REPORT" &&
   grep -q '^ANNIVERSARY year date=2026-03-29 category=Ann file=yes .*Ann:.*Birthday sentinel is 22 years old' "$LEM_YATH_AGENDA_VIEW_REPORT" &&
   ! grep -q 'Unsafe diary sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass year-view 'gD y rendered the year and safe configured anniversary sexps'
else
  fail year-view 'year boundaries, anniversary expansion, metadata, or source identity differed'
fi

send_keys C-c z a
send_keys Enter
send_keys C-c z v
wait_report '^ANNIVERSARY-SOURCE ' || true
if grep -q "^ANNIVERSARY-SOURCE file=$work_file line=[0-9][0-9]* text=\"%%(org-anniversary 2004 3 29) Birthday sentinel is %d years old.\"$" "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass anniversary-visit 'Return opened the exact read-only diary source line'
else
  fail anniversary-visit 'the anniversary source identity or Return visit differed'
fi

send_keys g D Space
lem_wait_for "$session" 'Agenda  \(2026-03-29\)' 30 >/dev/null || true
send_keys .
lem_wait_for "$session" 'Agenda  \(2026-07-17\)' 30 >/dev/null || true
send_keys c r
clock_ok=1
wait_clock_state '^STATE clock span=summary start=2026-07-17 end=2026-07-24 .*clock=2026-07-17..2026-07-24/60$' || clock_ok=0
send_keys g d
lem_wait_for "$session" 'Agenda date' 10 >/dev/null || true
send_keys -l 2026-08-05
send_keys Enter
wait_clock_state '^STATE clock span=summary start=2026-08-05 end=2026-08-12 .*clock=2026-08-05..2026-08-12/120$' || clock_ok=0
if [ "$clock_ok" = 1 ]; then
  pass clock-range 'clock reports followed every selected inclusive agenda span'
else
  fail clock-range 'clock report bounds or totals stayed on the old summary span'
fi

send_keys c r
lem_wait_for "$session" 'Clocktable mode is off' 10 >/dev/null || true
send_keys g D Space
lem_wait_for "$session" 'Agenda  \(2026-08-05\)' 30 >/dev/null || true
send_keys .
lem_wait_for "$session" 'Agenda  \(2026-07-17\)' 30 >/dev/null || true
send_keys C-c z s
wait_report '^STATE summary ' || true
send_keys C-z
send_keys C-c z e
wait_report '^KEYS emacs ' || true
reset_ok=1
grep -q '^STATE summary span=summary start=2026-07-17 end=2026-07-24 header="Agenda  (2026-07-17)"' "$LEM_YATH_AGENDA_VIEW_REPORT" || reset_ok=0
grep -q '^KEYS emacs g=LEM-YATH-AGENDA-REFRESH dispatch=SELF-INSERT$' "$LEM_YATH_AGENDA_VIEW_REPORT" || reset_ok=0
cmp -s "$work_file" "$original_file" || reset_ok=0
if [ "$reset_ok" = 1 ]; then
  pass reset-state 'gD SPC restored the summary; Emacs g and sources stayed intact'
else
  fail reset-state 'reset, state-specific key ownership, or display-only safety differed'
fi

if [ "$FAILED" -ne 0 ]; then
  printf '\nAgenda view tests failed.\n' >&2
  exit 1
fi
printf '\nAll agenda view checks passed.\n'
