#!/usr/bin/env bash
# GNU Org scheduled-delay and deadline-warning behavior in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-reminder-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-reminder.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_REMINDER_REPORT="$root/report"
export TZ=UTC
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR"

work_file="$WORKDIR/reminders.org"
original_file="$root/reminders.original"
session="lem-agenda-reminder-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-reminder-fixture.lisp")"
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
  sed -n '1,240p' "$LEM_YATH_AGENDA_REMINDER_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 120); do
    grep -qE "$pattern" "$LEM_YATH_AGENDA_REMINDER_REPORT" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

printf '%s\n' \
  '* TODO Past deadline sentinel' \
  'DEADLINE: <2026-07-11 Sat>' \
  '* TODO Today deadline sentinel' \
  'DEADLINE: <2026-07-12 Sun>' \
  '* TODO Tomorrow deadline sentinel' \
  'DEADLINE: <2026-07-13 Mon>' \
  '* TODO Boundary deadline sentinel' \
  'DEADLINE: <2026-07-26 Sun>' \
  '* TODO Beyond boundary deadline exclusion sentinel' \
  'DEADLINE: <2026-07-27 Mon>' \
  '* TODO Explicit warning sentinel' \
  'DEADLINE: <2026-07-14 Tue -2d>' \
  '* TODO Before explicit warning sentinel' \
  'DEADLINE: <2026-07-15 Wed -2d>' \
  '* TODO Scheduled past sentinel' \
  'SCHEDULED: <2026-07-10 Fri>' \
  '* TODO Scheduled delay active sentinel' \
  'SCHEDULED: <2026-07-10 Fri -1d>' \
  '* TODO Scheduled delay hidden sentinel' \
  'SCHEDULED: <2026-07-10 Fri -3d>' \
  '* TODO Scheduled today delayed exclusion sentinel' \
  'SCHEDULED: <2026-07-12 Sun -3d>' \
  '* TODO Dual planning sentinel' \
  'SCHEDULED: <2026-07-13 Mon> DEADLINE: <2026-07-14 Tue>' \
  '* DONE Done future deadline sentinel' \
  'DEADLINE: <2026-07-13 Mon>' \
  '* CANCELLED Cancelled past schedule sentinel' \
  'SCHEDULED: <2026-07-10 Fri>' \
  '* DONE Done today schedule sentinel' \
  'SCHEDULED: <2026-07-12 Sun>' \
  '* Late timed event sentinel <2026-07-12 Sun 10:00>' \
  '* Early timed event sentinel <2026-07-12 Sun 9:00>' \
  '* TODO [#A] Priority upcoming deadline sentinel' \
  'DEADLINE: <2026-07-26 Sun>' \
  '* TODO [#C] Low priority past schedule sentinel' \
  'SCHEDULED: <2026-07-10 Fri>' \
  >"$work_file"
cp "$work_file" "$original_file"
: >"$LEM_YATH_AGENDA_REMINDER_REPORT"

lem_start \
  "$session" \
  --eval "(progn (unless (find-package \"LEM-YATH\") (load #P$init)) (load #P$fixture) (funcall (intern \"LEM-YATH-AGENDA\" \"LEM-YATH\")))"
if ! lem_wait_for "$session" 'Past deadline sentinel' 30 >/dev/null; then
  fail startup 'the reminder agenda did not render'
  exit 1
fi

tmux_cmd send-keys -t "$session" F4
wait_report '^DONE rows=22$' || true
static_ok=1
[ "$(grep -c '^ROW ' "$LEM_YATH_AGENDA_REMINDER_REPORT")" = 22 ] || static_ok=0
grep -qE '^ROW section=OVERDUE source=2026-07-11 display=2026-07-11 .*Past deadline sentinel.*\[DEADLINE 2026-07-11\]' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
grep -qE '^ROW section=TODAY source=2026-07-11 display=2026-07-12 .*reminder=DEADLINE-OVERDUE days=1 .*Past deadline sentinel.*\[ 1 d\. ago: 2026-07-11\]' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
grep -qE '^ROW section=TODAY source=2026-07-13 display=2026-07-12 .*reminder=DEADLINE-UPCOMING days=1 .*Tomorrow deadline sentinel.*\[In   1 d\.: 2026-07-13\]' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
grep -qE '^ROW section=TODAY source=2026-07-26 display=2026-07-12 .*reminder=DEADLINE-UPCOMING days=14 .*Boundary deadline sentinel.*\[In  14 d\.: 2026-07-26\]' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
grep -qE '^ROW section=TODAY source=2026-07-14 display=2026-07-12 .*reminder=DEADLINE-UPCOMING days=2 .*Explicit warning sentinel' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
grep -qE '^ROW section=TODAY source=2026-07-10 display=2026-07-12 .*reminder=SCHEDULED-PAST days=2 .*Scheduled past sentinel.*\[Sched\. 2x: 2026-07-10\]' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
grep -qE '^ROW section=TODAY source=2026-07-10 display=2026-07-12 .*reminder=SCHEDULED-PAST days=2 .*Scheduled delay active sentinel' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
[ "$(grep -c '^ROW .*Dual planning sentinel' "$LEM_YATH_AGENDA_REMINDER_REPORT")" = 3 ] || static_ok=0
grep -qE '^ROW section=UPCOMING source=2026-07-13 display=2026-07-13 .*Done future deadline sentinel' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
grep -qE '^ROW section=TODAY source=2026-07-12 display=2026-07-12 .*Done today schedule sentinel' "$LEM_YATH_AGENDA_REMINDER_REPORT" || static_ok=0
if grep -qE '^ROW .*Beyond boundary|^ROW .*Scheduled delay hidden|^ROW .*Scheduled today delayed|^ROW .*Cancelled past|^ROW section=TODAY .*Before explicit warning|^ROW .*reminder=(DEADLINE|SCHEDULED)-.*Done future' "$LEM_YATH_AGENDA_REMINDER_REPORT"; then
  static_ok=0
fi
row_number() {
  grep -n "^ROW section=TODAY .*${1}" "$LEM_YATH_AGENDA_REMINDER_REPORT" |
    head -n 1 | cut -d: -f1
}
early_row="$(row_number 'Early timed event sentinel')"
late_row="$(row_number 'Late timed event sentinel')"
high_row="$(row_number 'Priority upcoming deadline sentinel')"
scheduled_row="$(row_number 'Scheduled past sentinel')"
today_deadline_row="$(row_number 'Today deadline sentinel')"
tomorrow_row="$(row_number 'Tomorrow deadline sentinel')"
boundary_row="$(row_number 'Boundary deadline sentinel')"
low_row="$(row_number 'Low priority past schedule sentinel')"
if [ -z "$early_row" ] || [ -z "$late_row" ] || [ -z "$high_row" ] ||
   [ -z "$scheduled_row" ] || [ -z "$today_deadline_row" ] ||
   [ -z "$tomorrow_row" ] || [ -z "$boundary_row" ] || [ -z "$low_row" ] ||
   ! [ "$early_row" -lt "$late_row" ] ||
   ! [ "$late_row" -lt "$high_row" ] ||
   ! [ "$high_row" -lt "$scheduled_row" ] ||
   ! [ "$scheduled_row" -lt "$today_deadline_row" ] ||
   ! [ "$today_deadline_row" -lt "$tomorrow_row" ] ||
   ! [ "$tomorrow_row" -lt "$boundary_row" ] ||
   ! [ "$boundary_row" -lt "$low_row" ]; then
  static_ok=0
fi
if [ "$static_ok" = 1 ] && cmp -s "$work_file" "$original_file"; then
  pass boundaries 'leaders, time/urgency order, priorities, delays, and dual rows match Org'
else
  fail boundaries 'reminder rows, exclusions, or immutable source differed'
fi

# A physical Evil-Org H on a projected reminder must edit its real planning
# timestamp and restore point to the corresponding refreshed reminder row.
tmux_cmd send-keys -t "$session" F5 H
if lem_wait_for "$session" 'Scheduled past sentinel.*Sched. 3x: 2026-07-09' 30 >/dev/null &&
   grep -q '^SCHEDULED: <2026-07-09 Thu>$' "$work_file"; then
  tmux_cmd send-keys -t "$session" F6
  wait_report '^POINT source=2026-07-09 display=2026-07-12 reminder=SCHEDULED-PAST days=3 ' || true
  if grep -q '^POINT source=2026-07-09 display=2026-07-12 reminder=SCHEDULED-PAST days=3 ' "$LEM_YATH_AGENDA_REMINDER_REPORT"; then
    pass reminder-edit 'H edited the source date and retained the projected row'
  else
    fail reminder-edit 'refresh did not restore the projected reminder identity'
  fi
else
  fail reminder-edit 'H did not mutate the source timestamp through the reminder'
fi

if [ "$FAILED" = 0 ]; then
  printf 'All agenda reminder tests passed.\n'
else
  exit 1
fi
