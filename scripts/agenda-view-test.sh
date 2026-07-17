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
export TZ=UTC
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
  '* TODO Sunday view sentinel' \
  'DEADLINE: <2026-07-19 Sun>' \
  '* TODO Next Monday view sentinel' \
  'SCHEDULED: <2026-07-20 Mon>' \
  '* TODO Month end view sentinel' \
  'SCHEDULED: <2026-07-31 Fri>' \
  '* TODO August view sentinel' \
  'SCHEDULED: <2026-08-05 Wed>' \
  '* Ranged view sentinel <2026-07-15 Wed>--<2026-07-18 Sat>' \
  '* TODO Unscheduled view sentinel' \
  '* TODO Clock span view sentinel' \
  ':LOGBOOK:' \
  'CLOCK: [2026-07-17 Fri 10:00]--[2026-07-17 Fri 11:00] =>  1:00' \
  'CLOCK: [2026-08-05 Wed 10:00]--[2026-08-05 Wed 12:00] =>  2:00' \
  ':END:' \
  >"$work_file"
cp "$work_file" "$original_file"
: >"$LEM_YATH_AGENDA_VIEW_REPORT"

lem_start \
  "$session" \
  --eval "(progn (unless (find-package \"LEM-YATH\") (load #P$init)) (load #P$fixture) (funcall (intern \"LEM-YATH-AGENDA\" \"LEM-YATH\")))"
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

send_keys g D w
lem_wait_for "$session" 'Week 2026-07-13..2026-07-19' 30 >/dev/null || true
send_keys C-c z 1
wait_report '^STATE week ' || true
week_ok=1
grep -q '^STATE week span=week start=2026-07-13 end=2026-07-19 .*point-date=2026-07-17 headers=7 ' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '2026-07-13|.*Monday view sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
grep -q '2026-07-19|.*Sunday view sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT" || week_ok=0
if [ "$week_ok" = 1 ]; then
  pass week-view 'gD w aligned to Monday and rendered all seven date sections'
else
  fail week-view 'weekly alignment, point restoration, or date grouping differed'
fi

send_keys g D t
lem_wait_for "$session" 'Fortnight 2026-07-13..2026-07-26' 30 >/dev/null || true
send_keys C-c z f
wait_report '^STATE fortnight ' || true
if grep -q '^STATE fortnight span=fortnight start=2026-07-13 end=2026-07-26 .*point-date=2026-07-17 headers=14 ' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass fortnight-view 'gD t rendered the Monday-aligned fourteen-day span'
else
  fail fortnight-view 'fortnight boundaries or selected date restoration differed'
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
if grep -q '^STATE goto span=week start=2026-08-05 end=2026-08-11 .*point-date=2026-08-05 headers=7 .*2026-08-05|.*August view sentinel' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
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
day_ok=1
grep -q '^STATE day span=day start=2026-08-05 end=2026-08-05 .*point-date=2026-08-05 headers=1 ' "$LEM_YATH_AGENDA_VIEW_REPORT" || day_ok=0
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
  grep -q '^STATE year span=year start=2026-01-01 end=2026-12-31 header="Agenda  (Year 2026-01-01..2026-12-31)"' "$LEM_YATH_AGENDA_VIEW_REPORT" 2>/dev/null && break
  sleep 0.1
done
if grep -q '^STATE year span=year start=2026-01-01 end=2026-12-31 .*point-date=2026-08-09 headers=365 ' "$LEM_YATH_AGENDA_VIEW_REPORT"; then
  pass year-view 'gD y confirmed and rendered the full leap-aware year span'
else
  fail year-view 'year confirmation, boundaries, or date sections differed'
fi

send_keys g D Space
lem_wait_for "$session" 'Agenda  \(2026-08-09\)' 30 >/dev/null || true
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
