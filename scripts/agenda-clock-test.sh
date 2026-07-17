#!/usr/bin/env bash
# State-specific Org agenda clocks and bulk marks in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-clock-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-clock.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_CLOCK_REPORT="$root/report"
export TZ=UTC
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR/mcp"

work_file="$WORKDIR/clock.org"
public_file="$PUBLIC_ORG_DIR/public.org"
session="lem-agenda-clock-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-clock-fixture.lisp")"
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
  sed -n '1,240p' "$LEM_YATH_AGENDA_CLOCK_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern="$1" expected="$2" i count
  for i in $(seq 1 100); do
    count="$(grep -cE "$pattern" "$LEM_YATH_AGENDA_CLOCK_REPORT" 2>/dev/null || true)"
    [ "$count" -ge "$expected" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_file_pattern() {
  local pattern="$1" file="$2" i
  for i in $(seq 1 100); do
    grep -qE "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_agenda() {
  lem_wait_for "$session" 'Clock one sentinel' 20 >/dev/null
}

send_chord() {
  tmux_cmd send-keys -t "$session" "$@"
}

printf '%s\n' \
  '* TODO Clock one sentinel' \
  'SCHEDULED: <2026-07-12 Sun>' \
  ':PROPERTIES:' \
  ':OWNER: yath' \
  ':END:' \
  'Clock one body.' \
  '* TODO Clock two sentinel' \
  'Clock two body.' \
  '* TODO Clock three sentinel' \
  ':LOGBOOK:' \
  'CLOCK: [2026-07-12 Sun 10:00]--[2026-07-12 Sun 10:30] =>  0:30' \
  ':END:' \
  'Clock three body.' \
  '* TODO Duplicate clock sentinel' \
  'SCHEDULED: <2026-07-12 Sun> DEADLINE: <2026-07-13 Mon>' \
  'Duplicate body.' \
  '* TODO Semantic clock decoy sentinel' \
  '#+BEGIN_SRC text' \
  'CLOCK: [2026-07-12 Sun 09:00]' \
  '#+END_SRC' \
  >"$work_file"
printf '%s\n' \
  '* TODO Public clock sentinel' \
  'Public body.' \
  >"$public_file"
: >"$LEM_YATH_AGENDA_CLOCK_REPORT"

lem_start \
  "$session" \
  --eval "(progn (unless (find-package \"LEM-YATH\") (load #P$init)) (load #P$fixture) (funcall (intern \"LEM-YATH-AGENDA\" \"LEM-YATH\")))"
if ! wait_agenda; then
  fail startup 'the fixture agenda command did not render'
  exit 1
fi

# The effective maps intentionally differ: Evil motion uses the stock global
# clock, while C-z Emacs state exposes the user's delegated clock functions.
send_chord C-c z k
wait_report_count '^KEYS state=normal ' 1 || true
send_chord C-z
send_chord C-c z k
wait_report_count '^KEYS state=emacs ' 1 || true
keys_ok=1
grep -q '^KEYS state=normal I=LEM-YATH-AGENDA-CLOCK-IN O=LEM-YATH-AGENDA-CLOCK-OUT cg=LEM-YATH-AGENDA-CLOCK-GOTO cc=LEM-YATH-AGENDA-CLOCK-CANCEL J=LEM-YATH-AGENDA-PRIORITY-DOWN X=LEM-YATH-STRUCTURAL-DELETE-PREVIOUS-CHAR plus=VI-NEXT-LINE minus=VI-PREVIOUS-LINE control-goto=LEM-YATH-AGENDA-CLOCK-GOTO control-cancel=LEM-YATH-AGENDA-CLOCK-CANCEL ' "$LEM_YATH_AGENDA_CLOCK_REPORT" || keys_ok=0
grep -q '^KEYS state=emacs I=LEM-YATH-AGENDA-CLOCK-IN-ADDITIONAL O=LEM-YATH-AGENDA-CLOCK-OUT-OPEN-CLOCKS cg=SELF-INSERT cc=SELF-INSERT J=LEM-YATH-AGENDA-CLOCK-GOTO X=LEM-YATH-AGENDA-CLOCK-CANCEL plus=LEM-YATH-AGENDA-PRIORITY-UP minus=LEM-YATH-AGENDA-PRIORITY-DOWN control-goto=LEM-YATH-AGENDA-CLOCK-GOTO control-cancel=LEM-YATH-AGENDA-CLOCK-CANCEL m=LEM-YATH-AGENDA-BULK-MARK .*u=LEM-YATH-AGENDA-BULK-UNMARK U=LEM-YATH-AGENDA-BULK-UNMARK-ALL M-m=LEM-YATH-AGENDA-BULK-TOGGLE M-star=LEM-YATH-AGENDA-BULK-TOGGLE-ALL$' "$LEM_YATH_AGENDA_CLOCK_REPORT" || keys_ok=0
if [ "$keys_ok" = 1 ]; then
  pass state-maps 'clock, priority, and mark keys follow pinned Evil/base shadowing'
else
  fail state-maps 'effective agenda maps differed'
fi
send_chord C-z

# Mark-all, invert-all, regexp mark, and unmark-all exercise the visible >
# marker and the complete rendered row set without touching source files.
send_chord '*'
send_chord C-c z r
wait_report_count '^STATE state=normal marks=7 rendered=7 ' 1 || true
send_chord '~'
send_chord C-c z r
wait_report_count '^STATE state=normal marks=0 rendered=0 ' 1 || true
send_chord '%'
if lem_wait_for "$session" 'Mark entries matching regexp' 10 >/dev/null; then
  send_chord -l 'Clock one sentinel'
  send_chord Enter
  send_chord C-c z r
  wait_report_count '^STATE state=normal marks=1 rendered=1 ' 1 || true
  send_chord M
  send_chord C-c z r
  if wait_report_count '^STATE state=normal marks=0 rendered=0 ' 2; then
    pass bulk-surface 'all, invert, regexp, and clear preserve visible marks'
  else
    fail bulk-surface 'bulk mark counts or prefixes differed'
  fi
else
  fail bulk-surface '% did not open the regexp prompt'
fi

# Stock I creates a LOGBOOK after planning/properties, repeating I is a true
# no-op, and clocking into another row closes the first at the shared time.
send_chord C-c z 1
send_chord I
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 12:00\]$' "$work_file" || true
wait_agenda || true
stock_shape=1

# Evil-Org uses cg/cc while the underlying agenda map uses J/X. Goto prefers
# the rendered clock row; cancel removes an otherwise empty LOGBOOK as one
# unsaved source edit, matching org-clock-cancel rather than the autosaved
# clock-in/out advice in the user's configuration.
send_chord C-c z 2
send_chord c g
send_chord C-c z r
wait_report_count '^STATE state=normal .*global=yes point-line=1 ' 1 || stock_shape=0
send_chord C-c z 2
send_chord C-z
send_chord J
send_chord C-c z r
wait_report_count '^STATE state=emacs .*global=yes point-line=1 ' 1 || stock_shape=0
send_chord C-z

send_chord C-c z v
send_chord c g
send_chord C-c z l
wait_report_count '^CLOCK-LOCATION file=clock\.org line=1 text="\* TODO Clock one sentinel"$' 1 || stock_shape=0
send_chord C-c z b
send_chord g
sleep 0.3
wait_agenda || stock_shape=0

send_chord c c
lem_wait_for "$session" 'Clock canceled' 10 >/dev/null || stock_shape=0
send_chord C-c z x
wait_report_count '^CLOCK-SOURCE modified=yes open=1 logbook=1 active=no$' 1 || stock_shape=0
[ "$(grep -c '^CLOCK: \[' "$work_file")" = 3 ] || stock_shape=0
[ "$(grep -c '^:LOGBOOK:$' "$work_file")" = 2 ] || stock_shape=0

send_chord C-c z o
wait_report_count '^SOURCE-CONTEXT file=clock\.org ' 1 || stock_shape=0
if grep -q '^SOURCE-CONTEXT file=clock\.org state=emacs ' "$LEM_YATH_AGENDA_CLOCK_REPORT"; then
  send_chord C-z
elif ! grep -q '^SOURCE-CONTEXT file=clock\.org state=normal u=VI-UNDO$' "$LEM_YATH_AGENDA_CLOCK_REPORT"; then
  stock_shape=0
fi
send_chord u
send_chord C-c z y
wait_report_count '^CLOCK-SOURCE modified=no open=2 logbook=2 active=no$' 1 || stock_shape=0
send_chord C-r
send_chord C-c z y
wait_report_count '^CLOCK-SOURCE modified=yes open=1 logbook=1 active=no$' 2 || stock_shape=0
send_chord C-c z b
wait_agenda || stock_shape=0

send_chord C-c z 1
send_chord I
sleep 0.3
wait_agenda || true
send_chord C-z
send_chord X
lem_wait_for "$session" 'Clock canceled' 10 >/dev/null || stock_shape=0
send_chord C-c z x
wait_report_count '^CLOCK-SOURCE modified=yes open=1 logbook=1 active=no$' 3 || stock_shape=0
send_chord C-z
send_chord C-c z 1
send_chord I
sleep 0.3
wait_agenda || true

awk '
  /^\* TODO Clock one sentinel$/ { in_one=1 }
  /^\* TODO Clock two sentinel$/ { in_one=0 }
  in_one { print }
' "$work_file" | diff -u - <(printf '%s\n' \
  '* TODO Clock one sentinel' \
  'SCHEDULED: <2026-07-12 Sun>' \
  ':PROPERTIES:' \
  ':OWNER: yath' \
  ':END:' \
  ':LOGBOOK:' \
  'CLOCK: [2026-07-12 Sun 12:00]' \
  ':END:' \
  'Clock one body.') >/dev/null || stock_shape=0
stock_repeat_hash="$(sha256sum "$work_file" | cut -d' ' -f1)"
send_chord C-c z 1
send_chord I
sleep 0.3
[ "$(sha256sum "$work_file" | cut -d' ' -f1)" = "$stock_repeat_hash" ] || stock_shape=0
send_chord C-c z a
send_chord C-c z 2
send_chord I
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 12:15\]$' "$work_file" || stock_shape=0
wait_agenda || true
grep -q '^CLOCK: \[2026-07-12 Sun 12:00\]--\[2026-07-12 Sun 12:15\] =>  0:15$' "$work_file" || stock_shape=0
send_chord C-c z b
send_chord O
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 12:15\]--\[2026-07-12 Sun 12:45\] =>  0:30$' "$work_file" || stock_shape=0
wait_agenda || true
send_chord C-c z r
wait_report_count '^STATE state=normal marks=0 rendered=0 global=no ' 1 || stock_shape=0
if [ "$stock_shape" = 1 ]; then
  pass stock-clock 'global clock goto/cancel, drawer shape, continuation, switch, and save match Org'
else
  fail stock-clock 'stock global clock shape or lifecycle differed'
fi

# Two rendered rows may point at one source heading.  Marking both must process
# both Org-style markers: the first starts, and the duplicate reports open.
send_chord C-c z c
send_chord C-c z d
send_chord m
send_chord C-c z D
send_chord m
send_chord C-c z r
wait_report_count '^STATE state=normal marks=2 rendered=2 ' 1 || true
send_chord C-z
send_chord I
delegated_message=1
lem_wait_for "$session" 'Started 1 delegated clock; 1 already open' 10 >/dev/null || delegated_message=0
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 13:00\]$' "$work_file" || delegated_message=0
wait_agenda || true
[ "$(grep -c '^CLOCK: \[2026-07-12 Sun 13:00\]$' "$work_file")" = 1 ] || delegated_message=0
send_chord C-c z r
wait_report_count '^STATE state=emacs marks=2 rendered=2 global=no ' 1 || delegated_message=0
send_chord I
lem_wait_for "$session" 'Started 0 delegated clocks; 2 already open' 10 >/dev/null || delegated_message=0
send_chord C-c z e
send_chord O
lem_wait_for "$session" 'Stopped 1 open Org clock' 10 >/dev/null || delegated_message=0
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 13:00\]--\[2026-07-12 Sun 13:30\] =>  0:30$' "$work_file" || delegated_message=0
wait_agenda || true
send_chord U
send_chord C-c z r
wait_report_count '^STATE state=emacs marks=0 rendered=0 global=no ' 1 || delegated_message=0
if [ "$delegated_message" = 1 ]; then
  pass marked-delegation 'duplicate marked rows share time, deduplicate by open state, and survive refresh'
else
  fail marked-delegation 'marked delegated clock behavior differed'
fi

# With no marks, base I starts one additional clock at point; base O closes
# every open clock in all top-level agenda files while ignoring source blocks.
send_chord C-c z f
send_chord C-c z 3
send_chord I
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 14:00\]$' "$work_file" || true
wait_agenda || true
send_chord C-c z p
send_chord I
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 14:00\]$' "$public_file" || true
wait_agenda || true
send_chord C-c z g
send_chord O
all_files_ok=1
lem_wait_for "$session" 'Stopped 2 open Org clocks' 10 >/dev/null || all_files_ok=0
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 14:00\]--\[2026-07-12 Sun 14:30\] =>  0:30$' "$public_file" || all_files_ok=0
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 14:00\]--\[2026-07-12 Sun 14:30\] =>  0:30$' "$work_file" || all_files_ok=0
grep -q '^CLOCK: \[2026-07-12 Sun 09:00\]$' "$work_file" || all_files_ok=0
if grep -q '^CLOCK: \[2026-07-12 Sun 14:00\]$' "$work_file" "$public_file"; then
  all_files_ok=0
fi
if [ "$all_files_ok" = 1 ]; then
  pass all-files 'unmarked base O closes semantic clocks across agenda files only'
else
  fail all-files 'all-file close count, persistence, or source-block filtering differed'
fi

# Unlike a plain numeric row, a row marked before an intervening source edit
# owns a live source point.  The delegated command must follow that point,
# persist the edit, refresh the row number, and retain the mark.
wait_agenda || true
send_chord C-z
send_chord C-c z h
send_chord C-c z p
send_chord m
send_chord C-c z p
send_chord C-c z s
send_chord C-z
send_chord I
marked_shift_ok=1
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 15:00\]$' "$public_file" || marked_shift_ok=0
wait_agenda || true
send_chord C-c z r
wait_report_count '^STATE state=emacs marks=1 rendered=1 global=no point-line=2 ' 1 || marked_shift_ok=0
send_chord C-c z i
send_chord O
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 15:00\]--\[2026-07-12 Sun 15:15\] =>  0:15$' "$public_file" || marked_shift_ok=0
grep -q '^# unsaved stale clock row$' "$public_file" || marked_shift_ok=0
wait_agenda || true
send_chord U
if [ "$marked_shift_ok" = 1 ]; then
  pass marked-live-point 'marked operations survive earlier source insertion and restore the refreshed row'
else
  fail marked-live-point 'a marked live source point became stale or lost its rendered mark'
fi

# A plain agenda row retains its scanned numeric source identity.  An unsaved
# insertion before it must fail closed rather than clocking the wrong heading.
wait_agenda || true
send_chord C-z
send_chord C-c z 1
stale_disk_hash="$(sha256sum "$work_file" | cut -d' ' -f1)"
send_chord C-c z s
send_chord I
stale_ok=1
lem_wait_for "$session" 'Agenda clock-in failed: Agenda source changed' 10 >/dev/null || stale_ok=0
sleep 0.2
[ "$(sha256sum "$work_file" | cut -d' ' -f1)" = "$stale_disk_hash" ] || stale_ok=0
if [ "$stale_ok" = 1 ]; then
  pass stale-safety 'unmarked stale source coordinates fail before mutation or save'
else
  fail stale-safety 'a stale row mutated or saved the source'
fi

if [ "$FAILED" = 0 ]; then
  printf 'All agenda clock and bulk-mark checks passed.\n'
else
  exit 1
fi
