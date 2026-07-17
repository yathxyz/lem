#!/usr/bin/env bash
# Org agenda source, grouping, navigation, and lifecycle tests in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_REPORT="$root/report"
export TZ=UTC
mkdir -p \
  "$HOME" \
  "$WORKDIR/roam" \
  "$PUBLIC_ORG_DIR/nested" \
  "$PUBLIC_ORG_DIR/mcp"

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/agenda-fixture.lisp")"
source_file="$WORKDIR/source.org"
work_file="$WORKDIR/same.org"
public_file="$PUBLIC_ORG_DIR/same.org"
mcp_file="$PUBLIC_ORG_DIR/mcp/mcp.org"
timestamp_file="$WORKDIR/timestamp-edit.org"
archive_file="${work_file}_archive"
session="lem-agenda-$id"
FAILED=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  FAILED=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  if [ -f "$LEM_YATH_AGENDA_REPORT" ]; then
    sed -n '1,240p' "$LEM_YATH_AGENDA_REPORT"
  fi
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 100); do
    grep -qE "$pattern" "$LEM_YATH_AGENDA_REPORT" && return 0
    sleep 0.1
  done
  return 1
}

wait_report_count() {
  local pattern="$1" expected="$2" count i
  for i in $(seq 1 100); do
    count="$(grep -cE "$pattern" "$LEM_YATH_AGENDA_REPORT" || true)"
    [ "$count" -ge "$expected" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_file_pattern() {
  local pattern="$1" file="$2" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && grep -qE "$pattern" "$file" && return 0
    sleep 0.1
  done
  return 1
}

wait_file_without_pattern() {
  local pattern="$1" file="$2" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && ! grep -qE "$pattern" "$file" && return 0
    sleep 0.1
  done
  return 1
}

wait_file_last_line() {
  local pattern="$1" file="$2" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && tail -n 1 "$file" | grep -qE "$pattern" && return 0
    sleep 0.1
  done
  return 1
}

wait_file_line() {
  local pattern="$1" file="$2" line="$3" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && sed -n "${line}p" "$file" | grep -qE "$pattern" && return 0
    sleep 0.1
  done
  return 1
}

type_slow() {
  local text="$1" index
  for ((index = 0; index < ${#text}; index++)); do
    tmux_cmd send-keys -t "$session" -l "${text:index:1}"
    sleep 0.05
  done
}

wait_screen_absent() {
  local pattern="$1" i
  for i in $(seq 1 100); do
    ! lem_capture "$session" | grep -qE "$pattern" && return 0
    sleep 0.1
  done
  return 1
}

printf '%s\n' \
  '#+title: Agenda launch source' \
  '' \
  'Agenda source buffer sentinel.' \
  >"$source_file"

printf '%s\n' \
  '* TODO Work unscheduled sentinel' \
  '* TODO Overdue work sentinel' \
  'DEADLINE: <2026-07-11 Sat>' \
  '* NEXT Today work sentinel' \
  'SCHEDULED: <2026-07-12 Sun>' \
  '* WAITING Upcoming work sentinel' \
  'DEADLINE: <2026-07-15 Wed>' \
  '* HOLD Hold work sentinel' \
  '* DONE Done dated sentinel' \
  'SCHEDULED: <2026-07-12 Sun>' \
  '* CANCELLED Cancelled dated sentinel' \
  'DEADLINE: <2026-07-12 Sun>' \
  '* TODO Far future sentinel' \
  'SCHEDULED: <2026-07-30 Thu>' \
  '* Plain today sentinel' \
  'SCHEDULED: <2026-07-12 Sun>' \
  '* TODO Body planning text sentinel' \
  'This example says SCHEDULED: <2026-07-12 Sun> but is ordinary body text.' \
  '* TODO Dual planning sentinel' \
  'SCHEDULED: <2026-07-12 Sun> DEADLINE: <2026-07-15 Wed>' \
  '* TODO Invalid planning sentinel' \
  'SCHEDULED: <2026-02-30 Mon>' \
  '* Heading event sentinel <2026-07-12 Sun>' \
  '* Body event sentinel' \
  'Meeting <2026-07-13 Mon 10:00>' \
  '* Range event sentinel <2026-07-14 Tue>--<2026-07-16 Thu>' \
  '* Repeating event sentinel <2026-07-01 Wed +1w>' \
  '* Daily repeat sentinel <2026-07-11 Sat +2d>' \
  '* Catch-up repeat sentinel <2026-07-01 Wed ++1w>' \
  '* Restart repeat sentinel <2026-07-01 Wed .+1w>' \
  '* Monthly repeat sentinel <2026-06-15 Mon +1m>' \
  '* Yearly repeat sentinel <2025-07-15 Tue +1y>' \
  '* DONE Completed event sentinel <2026-07-13 Mon>' \
  '* Inactive event exclusion sentinel [2026-07-14 Tue]' \
  '* COMMENT Comment subtree exclusion sentinel <2026-07-13 Mon>' \
  '** TODO Comment child exclusion sentinel' \
  '* Archived subtree exclusion sentinel :ARCHIVE:' \
  '<2026-07-13 Mon>' \
  '** TODO Archive child exclusion sentinel' \
  '* Source block exclusion sentinel' \
  '#+BEGIN_SRC text' \
  '<2026-07-13 Mon>' \
  '#+END_SRC' \
  '* Comment line exclusion sentinel :alpha:' \
  '# <2026-07-13 Mon>' \
  '* Archive parent sentinel :parenttag:shared:' \
  '** TODO Archive action sentinel :localtag:shared:' \
  'DEADLINE: <2026-07-14 Tue>' \
  ':PROPERTIES:' \
  ':CUSTOM: keep' \
  ':ARCHIVE_TIME: old' \
  ':END:' \
  'Archive body sentinel.' \
  '*** NEXT Archive child sentinel' \
  'Child body sentinel.' \
  '* TODO After archive sentinel' \
  '* Refile source parent sentinel' \
  '** TODO Refile action sentinel :movetag:' \
  'Refile body sentinel.' \
  '*** NEXT Refile child sentinel' \
  'Refile child body.' \
  '* Refile [[id:target][target]] sentinel :targettag:' \
  'Target body sentinel.' \
  '** Existing target child sentinel' \
  'Existing target body.' \
  >"$work_file"

printf '%s\n' \
  '#+title: Public agenda' \
  '#+ARCHIVE: custom-archive.org::* Archived' \
  '* SOMEDAY Public visit sentinel' \
  >"$public_file"

printf '%s\n' \
  '* TODO MCP today sentinel' \
  'SCHEDULED: <2026-07-12 Sun>' \
  >"$mcp_file"

printf '%s\n' '* TODO Nested work exclusion sentinel' \
  >"$WORKDIR/roam/nested.org"
printf '%s\n' '* TODO Nested public exclusion sentinel' \
  >"$PUBLIC_ORG_DIR/nested/nested.org"
printf '%s\n' '* TODO Hidden file exclusion sentinel' \
  >"$WORKDIR/.hidden.org"
printf '%s\n' '* TODO Uppercase extension exclusion sentinel' \
  >"$WORKDIR/uppercase.ORG"
: >"$LEM_YATH_AGENDA_REPORT"

lem_start "$session" --eval "(load #P$fixture_lisp)" "$source_file"
if ! lem_wait_for "$session" 'Agenda source buffer sentinel' 40 >/dev/null; then
  fail startup "fixture did not open"
  exit 1
fi
tmux_cmd send-keys -t "$session" Escape
sleep 0.25

# Open through the real leader key, then report the effective mode and entries.
tmux_cmd send-keys -t "$session" Space m a
if ! lem_wait_for "$session" 'Overdue work sentinel' 40 >/dev/null; then
  fail leader "SPC m a did not render the agenda"
else
  tmux_cmd send-keys -t "$session" F4
  wait_report '^REPORT-DONE serial=1$' || true
  static_ok=1
  grep -qE '^STATIC serial=1 mode=LEM-YATH-AGENDA-MODE date=2026-07-12 roots=3 files=4 generation=[1-9][0-9]* return=LEM-YATH-AGENDA-VISIT gr=LEM-YATH-AGENDA-REFRESH gR=LEM-YATH-AGENDA-REFRESH t=LEM-YATH-AGENDA-TODO p=LEM-YATH-AGENDA-DATE-PROMPT schedule=LEM-YATH-AGENDA-SCHEDULE deadline=LEM-YATH-AGENDA-DEADLINE ct=LEM-YATH-AGENDA-SET-TAGS tags=LEM-YATH-AGENDA-SET-TAGS q=QUIT-ACTIVE-WINDOW J=LEM-YATH-AGENDA-PRIORITY-DOWN K=LEM-YATH-AGENDA-PRIORITY-UP H=LEM-YATH-AGENDA-DATE-EARLIER L=LEM-YATH-AGENDA-DATE-LATER dd=LEM-YATH-AGENDA-KILL-ENTRY ce=LEM-YATH-AGENDA-SET-EFFORT shift-left=LEM-YATH-AGENDA-DATE-EARLIER shift-right=LEM-YATH-AGENDA-DATE-LATER dA=LEM-YATH-AGENDA-ARCHIVE da=LEM-YATH-AGENDA-ARCHIVE-WITH-CONFIRMATION dollar=LEM-YATH-AGENDA-ARCHIVE archive=LEM-YATH-AGENDA-ARCHIVE refile=LEM-YATH-AGENDA-REFILE kill-hooks=1 modified=no undo=no running=no pending=no$' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "ROOT serial=1 index=1 path=$WORKDIR/" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "ROOT serial=1 index=2 path=$PUBLIC_ORG_DIR/" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "ROOT serial=1 index=3 path=$PUBLIC_ORG_DIR/mcp/" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=1 path=$work_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=2 path=$source_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=3 path=$public_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=4 path=$mcp_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -q '^OPEN-MOTION serial=1 tab=LEM-YATH-AGENDA-GOTO shift-return=LEM-YATH-AGENDA-GOTO gtab=LEM-YATH-AGENDA-GOTO gj=LEM-YATH-AGENDA-NEXT-ITEM gk=LEM-YATH-AGENDA-PREVIOUS-ITEM Cj=LEM-YATH-AGENDA-NEXT-ITEM Ck=LEM-YATH-AGENDA-PREVIOUS-ITEM$' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -q '^TAG-COMPLETION serial=1 known=alpha,ARCHIVE,localtag,movetag,parenttag,shared,targettag items=:alpha:,:localtag:$' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  [ "$(grep -c '^ENTRY serial=1 ' "$LEM_YATH_AGENDA_REPORT")" = 33 ] || static_ok=0
  grep -qE '^ENTRY serial=1 section=OVERDUE .*Overdue work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Today work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Plain today sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*MCP today sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Upcoming work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Heading event sentinel.*\[EVENT 2026-07-12\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Body planning text sentinel.*\[EVENT 2026-07-12\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Body event sentinel.*\[EVENT 2026-07-13 10:00\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*DONE.*Completed event sentinel.*\[EVENT 2026-07-13\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  [ "$(grep -c '^ENTRY serial=1 section=UPCOMING .*Range event sentinel.*\[EVENT 2026-07-1[4-6] [1-3]/3\]' "$LEM_YATH_AGENDA_REPORT")" = 3 ] || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Repeating event sentinel.*\[EVENT 2026-07-15\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  [ "$(grep -c '^ENTRY serial=1 section=UPCOMING .*Daily repeat sentinel.*\[EVENT 2026-07-1[3579]\]' "$LEM_YATH_AGENDA_REPORT")" = 4 ] || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Catch-up repeat sentinel.*\[EVENT 2026-07-15\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Restart repeat sentinel.*\[EVENT 2026-07-15\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Monthly repeat sentinel.*\[EVENT 2026-07-15\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Yearly repeat sentinel.*\[EVENT 2026-07-15\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Work unscheduled sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Hold work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Public visit sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Body planning text sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Invalid planning sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  [ "$(grep -c '^ENTRY serial=1 .*Dual planning sentinel' "$LEM_YATH_AGENDA_REPORT")" = 2 ] || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Dual planning sentinel.*\[SCHEDULED 2026-07-12\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Dual planning sentinel.*\[DEADLINE 2026-07-15\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^WARNING serial=1 .*Invalid Org planning date.*2026-02-30' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  if grep -qE '^ENTRY serial=1 .*Nested (work|public)|^ENTRY serial=1 .*Hidden file|^ENTRY serial=1 .*Uppercase extension|^ENTRY serial=1 .*Done dated|^ENTRY serial=1 .*Cancelled dated|^ENTRY serial=1 .*Far future|^ENTRY serial=1 .*Inactive event exclusion|^ENTRY serial=1 .*Comment (subtree|child|line) exclusion|^ENTRY serial=1 .*Archive(d| child) .*exclusion|^ENTRY serial=1 .*Source block exclusion' "$LEM_YATH_AGENDA_REPORT"; then
    static_ok=0
  fi
  if [ "$static_ok" = 1 ]; then
    pass sources "exact roots, top-level files, grouping, filtering, and Vi keys"
  else
    fail sources "source set, grouping, or effective keymap differed"
  fi
fi

# Add mutation-only targets after the baseline source/grouping assertions so
# these focused commands do not weaken the established 33-row oracle.
printf '%s\n' \
  '* TODO Effort action sentinel' \
  '* TODO Delete action sentinel' \
  'Delete body sentinel.' \
  '** Delete child sentinel' \
  'Delete child body sentinel.' \
  '* TODO Delete one-line sentinel' \
  '* TODO Date shift planning sentinel' \
  'SCHEDULED: <2026-07-10 Fri>' \
  '* Date shift event sentinel <2026-07-14 Tue>--<2026-07-15 Wed>' \
  '* Time shift event sentinel <2026-07-13 Mon 23:30-23:45>' \
  >>"$work_file"
tmux_cmd send-keys -t "$session" g r
if ! lem_wait_for "$session" 'Effort action sentinel' 40 >/dev/null; then
  fail agenda-mutations-setup "new agenda mutation fixtures did not refresh"
fi

# Evil-Org ce and GNU C-c C-x e set a validated Effort property, preserve an
# existing drawer, save immediately, and retain the logical agenda row.
tmux_cmd send-keys -t "$session" C-c e c e
if lem_wait_for "$session" 'Effort:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'not-a-duration'
  tmux_cmd send-keys -t "$session" Enter
  sleep 0.3
  if ! grep -q '^:Effort:' "$work_file"; then
    pass effort-invalid "ce rejects an invalid duration before source mutation"
  else
    fail effort-invalid "an invalid duration created an Effort property"
  fi
else
  fail effort-prompt "ce did not open the Effort prompt"
fi

tmux_cmd send-keys -t "$session" c e
if lem_wait_for "$session" 'Effort:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '1:30'
  tmux_cmd send-keys -t "$session" Enter
  if wait_file_pattern '^:Effort:   1:30$' "$work_file" &&
     lem_wait_for "$session" 'Effort action sentinel' 40 >/dev/null; then
    pass effort "ce inserted, saved, refreshed, and retained GNU Effort syntax"
  else
    fail effort "ce did not persist the expected property drawer value"
  fi
else
  fail effort-prompt "ce did not reopen the Effort prompt"
fi

tmux_cmd send-keys -t "$session" C-c C-x e
if lem_wait_for "$session" 'Effort:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '2h'
  tmux_cmd send-keys -t "$session" Enter
  if wait_file_pattern '^:Effort:   2h$' "$work_file" &&
     [ "$(grep -c '^:Effort:' "$work_file")" = 1 ]; then
    pass effort-gnu-alias "C-c C-x e replaced the existing Effort exactly once"
  else
    fail effort-gnu-alias "the GNU Effort alias duplicated or lost the property"
  fi
else
  fail effort-gnu-alias "C-c C-x e did not open the Effort prompt"
fi

# Evil-Org L moves a past planning date directly to today under GNU's default;
# H then moves it one ordinary calendar day earlier.
tmux_cmd send-keys -t "$session" C-c p L
if wait_file_pattern '^SCHEDULED: <2026-07-12 Sun>$' "$work_file" &&
   lem_wait_for "$session" 'Date shift planning sentinel.*SCHEDULED 2026-07-12' 40 >/dev/null; then
  pass agenda-date-catchup "L moved a past planning date directly to today"
else
  fail agenda-date-catchup "L did not apply GNU's past-to-today rule"
fi
tmux_cmd send-keys -t "$session" H
if wait_file_pattern '^SCHEDULED: <2026-07-11 Sat>$' "$work_file" &&
   lem_wait_for "$session" 'Date shift planning sentinel.*SCHEDULED 2026-07-11' 40 >/dev/null; then
  pass agenda-date-day "H shifted, saved, refreshed, and retained the planning row"
else
  fail agenda-date-day "H did not shift the planning date one day earlier"
fi

# A selected range row identifies the exact source token.  H/L shift both
# endpoints atomically instead of changing an unrelated timestamp on the same
# heading or only one side of the range.
tmux_cmd send-keys -t "$session" C-c r H
if wait_file_pattern '^\* Date shift event sentinel <2026-07-13 Mon>--<2026-07-14 Tue>$' "$work_file" &&
   lem_wait_for "$session" 'Date shift event sentinel.*EVENT 2026-07-13' 40 >/dev/null; then
  pass agenda-date-range "H shifted both event-range endpoints and retained its row"
else
  fail agenda-date-range "H did not shift the exact event range"
fi
tmux_cmd send-keys -t "$session" L
if wait_file_pattern '^\* Date shift event sentinel <2026-07-14 Tue>--<2026-07-15 Wed>$' "$work_file" &&
   lem_wait_for "$session" 'Date shift event sentinel.*EVENT 2026-07-14' 40 >/dev/null; then
  pass agenda-date-range-return "L restored both event-range endpoints"
else
  fail agenda-date-range-return "L failed to shift the event range later"
fi

# GNU universal-prefix modes shift hours or the default five-minute increment;
# a following unprefixed opposite command continues the selected unit.
tmux_cmd send-keys -t "$session" C-c h C-z
sleep 0.2
tmux_cmd send-keys -t "$session" C-u C-c C-x Right
if wait_file_pattern '^\* Time shift event sentinel <2026-07-14 Tue 00:30-00:45>$' "$work_file" &&
   lem_wait_for "$session" 'Time shift event sentinel.*EVENT 2026-07-14 00:30' 40 >/dev/null; then
  pass agenda-date-hour "C-u shifted the complete time range across midnight"
else
  fail agenda-date-hour "the GNU hour shift did not preserve the time range"
fi
tmux_cmd send-keys -t "$session" C-c C-x Left
if wait_file_pattern '^\* Time shift event sentinel <2026-07-13 Mon 23:30-23:45>$' "$work_file" &&
   lem_wait_for "$session" 'Time shift event sentinel.*EVENT 2026-07-13 23:30' 40 >/dev/null; then
  pass agenda-date-hour-repeat "an unprefixed opposite command continued hour mode"
else
  fail agenda-date-hour-repeat "hour continuation did not return the timestamp"
fi
tmux_cmd send-keys -t "$session" C-u C-u C-c C-x Right
if wait_file_pattern '^\* Time shift event sentinel <2026-07-13 Mon 23:35-23:50>$' "$work_file" &&
   lem_wait_for "$session" 'Time shift event sentinel.*EVENT 2026-07-13 23:35' 40 >/dev/null; then
  pass agenda-date-minute "C-u C-u used the default five-minute increment"
else
  fail agenda-date-minute "the GNU minute shift used the wrong increment"
fi
tmux_cmd send-keys -t "$session" C-c C-x Left
wait_file_pattern '^\* Time shift event sentinel <2026-07-13 Mon 23:30-23:45>$' "$work_file" || true
lem_wait_for "$session" 'Time shift event sentinel.*EVENT 2026-07-13 23:30' 40 >/dev/null || true
tmux_cmd send-keys -t "$session" C-z
sleep 0.2

# Evil-Org dd confirms a multi-line subtree at the pinned default threshold.
# Cancellation is atomic; acceptance removes every child and all duplicate
# agenda rows.  GNU C-k in Emacs state deletes a one-line entry without asking.
tmux_cmd send-keys -t "$session" C-c d d d
if lem_wait_for "$session" 'Delete entry with 4 lines' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" n
  sleep 0.3
  if grep -q '^\* TODO Delete action sentinel$' "$work_file"; then
    pass agenda-delete-cancel "declining dd left the complete subtree untouched"
  else
    fail agenda-delete-cancel "declining dd still changed the source"
  fi
else
  fail agenda-delete-prompt "dd did not confirm a multi-line subtree"
fi
tmux_cmd send-keys -t "$session" d d
if lem_wait_for "$session" 'Delete entry with 4 lines' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" y
  if wait_file_without_pattern 'Delete action sentinel|Delete child sentinel' "$work_file" &&
     lem_wait_for "$session" 'Delete one-line sentinel' 40 >/dev/null; then
    pass agenda-delete "dd deleted and saved the complete subtree"
  else
    fail agenda-delete "dd left source or rendered subtree remnants"
  fi
else
  fail agenda-delete-prompt "dd did not reopen its confirmation"
fi

tmux_cmd send-keys -t "$session" C-c k C-z C-k
if wait_file_without_pattern 'Delete one-line sentinel' "$work_file"; then
  pass agenda-delete-gnu-alias "C-k deleted a one-line entry without confirmation"
else
  fail agenda-delete-gnu-alias "GNU C-k did not delete the one-line source entry"
fi
tmux_cmd send-keys -t "$session" C-z
sleep 0.2

# Evil-Org da asks before using the configured default archive command.  dA
# performs the same subtree move directly.  Lem persists the archive first so
# an interrupted second save can duplicate a subtree but cannot lose it.
tmux_cmd send-keys -t "$session" F1
tmux_cmd send-keys -t "$session" d a
if lem_wait_for "$session" 'Archive this subtree or entry' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" n
  sleep 0.3
  if grep -q '^\*\* TODO Archive action sentinel' "$work_file" &&
     [ ! -e "$archive_file" ]; then
    pass archive-cancel "da cancellation leaves source and destination untouched"
  else
    fail archive-cancel "declining da still changed an archive file"
  fi
else
  fail archive-cancel "da did not request Evil-Org's confirmation"
fi

tmux_cmd send-keys -t "$session" d A
archive_ok=1
wait_file_pattern '^\* TODO Archive action sentinel' "$archive_file" || archive_ok=0
wait_file_without_pattern 'Archive action sentinel|Archive child sentinel' \
  "$work_file" || archive_ok=0
if grep -q 'Archive action sentinel\|Archive child sentinel' "$work_file"; then
  archive_ok=0
fi
grep -q '^\* Archive parent sentinel' "$work_file" || archive_ok=0
grep -q '^\* TODO After archive sentinel$' "$work_file" || archive_ok=0
grep -q '^#    -\*- mode: org -\*-$' "$archive_file" || archive_ok=0
grep -qF "Archived entries from file $work_file" "$archive_file" || archive_ok=0
grep -qE '^\* TODO Archive action sentinel +:localtag:shared:$' "$archive_file" || archive_ok=0
grep -q '^DEADLINE: <2026-07-14 Tue>$' "$archive_file" || archive_ok=0
grep -q '^:CUSTOM: keep$' "$archive_file" || archive_ok=0
grep -q '^:ARCHIVE_TIME: 2026-07-12 Sun 12:00$' "$archive_file" || archive_ok=0
grep -qF ":ARCHIVE_FILE: $work_file" "$archive_file" || archive_ok=0
grep -q '^:ARCHIVE_OLPATH: Archive parent sentinel$' "$archive_file" || archive_ok=0
grep -q '^:ARCHIVE_CATEGORY: same$' "$archive_file" || archive_ok=0
grep -q '^:ARCHIVE_TODO: TODO$' "$archive_file" || archive_ok=0
grep -q '^:ARCHIVE_ITAGS: parenttag$' "$archive_file" || archive_ok=0
grep -q '^\*\* NEXT Archive child sentinel$' "$archive_file" || archive_ok=0
grep -q '^Child body sentinel\.$' "$archive_file" || archive_ok=0
tmux_cmd send-keys -t "$session" F4
wait_report '^REPORT-DONE serial=2$' || archive_ok=0
if grep -qE '^ENTRY serial=2 .*Archive (action|child) sentinel' "$LEM_YATH_AGENDA_REPORT"; then
  archive_ok=0
fi
if [ "$archive_ok" = 1 ]; then
  pass archive "dA moved, annotated, saved, and removed a complete subtree"
else
  fail archive "default subtree archive differed from the pinned Org shape"
fi

# With the user's nil org-refile-targets, GNU Org offers same-file level-one
# headings.  C-c C-w must cancel without mutation, then complete an existing
# target and append the whole subtree as that target's last child.
tmux_cmd send-keys -t "$session" F1
refile_before="$(sha256sum "$work_file" | cut -d' ' -f1)"
tmux_cmd send-keys -t "$session" C-c C-w
if lem_wait_for "$session" 'Refile subtree.*Refile action sentinel.*to:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Escape
  sleep 0.3
  if [ "$(sha256sum "$work_file" | cut -d' ' -f1)" = "$refile_before" ]; then
    pass refile-cancel "C-c C-w cancellation leaves the source untouched"
  else
    fail refile-cancel "cancelling the refile prompt changed the source"
  fi
else
  fail refile-cancel "C-c C-w did not open the same-file target prompt"
fi

tmux_cmd send-keys -t "$session" F1
tmux_cmd send-keys -t "$session" C-c C-w
if lem_wait_for "$session" 'Refile subtree.*Refile action sentinel.*to:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'Refile tar'
  if lem_wait_for "$session" 'Refile target sentinel' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" C-n
    tmux_cmd send-keys -t "$session" Tab
    if lem_wait_for "$session" 'to:[[:space:]]+Refile target sentinel' 10 >/dev/null; then
      tmux_cmd send-keys -t "$session" Enter
      wait_file_last_line '^Refile child body sentinel\.$' "$work_file" || true
      wait_screen_absent 'Scanning\.\.\.' || true
    else
      fail refile-completion "Tab did not insert the matching level-one target"
      tmux_cmd send-keys -t "$session" Escape
    fi
  else
    fail refile-completion "the target completion did not offer the level-one heading"
    tmux_cmd send-keys -t "$session" Escape
  fi
else
  fail refile-prompt "C-c C-w did not reopen the target prompt"
fi

refile_target_line="$(grep -n '^\* Refile \[\[id:target\]\[target\]\] sentinel ' "$work_file" | cut -d: -f1)"
refile_existing_line="$(grep -n '^\*\* Existing target child sentinel$' "$work_file" | cut -d: -f1)"
refile_action_line="$(grep -n '^\*\* TODO Refile action sentinel ' "$work_file" | cut -d: -f1)"
refile_child_line="$(grep -n '^\*\*\* NEXT Refile child sentinel$' "$work_file" | cut -d: -f1)"
refile_source_line="$(grep -n '^\* Refile source parent sentinel$' "$work_file" | cut -d: -f1)"
refile_ok=1
[ -n "$refile_target_line" ] || refile_ok=0
[ -n "$refile_existing_line" ] || refile_ok=0
[ -n "$refile_action_line" ] || refile_ok=0
[ -n "$refile_child_line" ] || refile_ok=0
[ -n "$refile_source_line" ] || refile_ok=0
if [ "$refile_ok" = 1 ]; then
  [ "$refile_target_line" -eq $((refile_source_line + 1)) ] || refile_ok=0
  [ "$refile_existing_line" -eq $((refile_target_line + 2)) ] || refile_ok=0
  [ "$refile_action_line" -eq $((refile_existing_line + 2)) ] || refile_ok=0
  [ "$refile_child_line" -eq $((refile_action_line + 2)) ] || refile_ok=0
fi
grep -qE '^\*\* TODO Refile action sentinel +:movetag:$' "$work_file" || refile_ok=0
grep -q '^Refile body sentinel\.$' "$work_file" || refile_ok=0
grep -q '^Refile child body\.$' "$work_file" || refile_ok=0
[ "$(grep -c 'Refile action sentinel' "$work_file")" = 1 ] || refile_ok=0
if [ "$refile_ok" = 1 ]; then
  tmux_cmd send-keys -t "$session" F6
  if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$work_file line=$refile_action_line .*TODO.*Refile action sentinel.*:movetag:"; then
    pass refile "C-c C-w completed, moved, saved, refreshed, and retained its row"
  else
    fail refile "the source moved correctly but agenda refresh lost its logical row"
  fi
else
  fail refile "the persisted subtree did not match the pinned Org hierarchy and order"
fi

# A file-local override would route data somewhere other than the configured
# default.  That broader archive grammar is intentionally unsupported and must
# refuse before creating the default destination or changing the source.
tmux_cmd send-keys -t "$session" F5
tmux_cmd send-keys -t "$session" d A
if lem_wait_for "$session" 'Custom Org archive location' 10 >/dev/null &&
   grep -q '^\* SOMEDAY Public visit sentinel$' "$public_file" &&
   [ ! -e "${public_file}_archive" ] &&
   [ ! -e "$PUBLIC_ORG_DIR/custom-archive.org" ]; then
  pass archive-custom "dA fails closed on a file-local archive destination"
else
  fail archive-custom "dA ignored or partially applied a custom archive route"
fi

# Evil-Org agenda t opens the configured one-key TODO selector, persists the
# chosen state immediately, and refreshes every duplicate agenda row.
tmux_cmd send-keys -t "$session" F12
sleep 0.2
tmux_cmd send-keys -t "$session" t
sleep 0.2
tmux_cmd send-keys -t "$session" n
if lem_wait_for "$session" 'NEXT[[:space:]]+Work unscheduled sentinel' 40 >/dev/null &&
   grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  tmux_cmd send-keys -t "$session" F6
  if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$work_file line=1 .*NEXT.*Work unscheduled sentinel"; then
    pass todo "t selects NEXT, saves, refreshes, and retains the logical row"
  else
    fail todo "agenda TODO refresh lost the selected logical row"
  fi
else
  fail todo "agenda TODO selection did not persist and refresh"
fi

# Evil-Org J/K preserve GNU Org's default-priority and repeated-wrap rules.
priority_ok=1
tmux_cmd send-keys -t "$session" K
if ! lem_wait_for "$session" 'NEXT[[:space:]]+\[#B\][[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT \[#B\] Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" K
if ! lem_wait_for "$session" 'NEXT[[:space:]]+\[#A\][[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT \[#A\] Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" K
if ! lem_wait_for "$session" 'NEXT[[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" K
if ! lem_wait_for "$session" 'NEXT[[:space:]]+\[#C\][[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT \[#C\] Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" J
if ! lem_wait_for "$session" 'NEXT[[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" J
if ! lem_wait_for "$session" 'NEXT[[:space:]]+\[#A\][[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT \[#A\] Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" K
if ! lem_wait_for "$session" 'NEXT[[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
# A non-priority command breaks repetition; a fresh J must also start at B.
tmux_cmd send-keys -t "$session" F6
sleep 0.2
tmux_cmd send-keys -t "$session" J
if ! lem_wait_for "$session" 'NEXT[[:space:]]+\[#B\][[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT \[#B\] Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" J
if ! lem_wait_for "$session" 'NEXT[[:space:]]+\[#C\][[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT \[#C\] Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
tmux_cmd send-keys -t "$session" J
if ! lem_wait_for "$session" 'NEXT[[:space:]]+Work unscheduled sentinel' 40 >/dev/null ||
   ! grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  priority_ok=0
fi
if [ "$priority_ok" = 1 ]; then
  pass priority "J/K matched default B, A/B/C movement, and repeated wrap"
else
  fail priority "one or more priority transitions did not render and persist"
fi

# Evil-Org ct and GNU Org C-c C-q replace local tags, with completion from the
# configured agenda sources and immediate aligned source persistence.
tmux_cmd send-keys -t "$session" c t
if lem_wait_for "$session" 'Tags:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l :al
  if lem_wait_for "$session" ':alpha:' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" C-n
    tmux_cmd send-keys -t "$session" Tab
    if lem_wait_for "$session" 'Tags:[[:space:]]+:alpha:' 10 >/dev/null; then
      tmux_cmd send-keys -t "$session" Enter
      if lem_wait_for "$session" 'NEXT.*Work unscheduled sentinel.*:alpha:' 40 >/dev/null &&
         grep -qE '^\* NEXT Work unscheduled sentinel +:alpha:$' "$work_file"; then
        tmux_cmd send-keys -t "$session" F6
        if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$work_file line=1 .*NEXT.*Work unscheduled sentinel.*:alpha:"; then
          pass tags-completion "ct completed, aligned, saved, refreshed, and retained its row"
        else
          fail tags-completion "tag refresh lost the selected logical row"
        fi
      else
        fail tags-completion "completed tag did not render and persist"
      fi
    else
      fail tags-completion "Tab did not insert the known source tag"
      tmux_cmd send-keys -t "$session" Escape
    fi
  else
    fail tags-completion "the prompt did not offer a known agenda-source tag"
    tmux_cmd send-keys -t "$session" Escape
  fi
else
  fail tags-prompt "ct did not open the tags prompt"
fi

tmux_cmd send-keys -t "$session" C-c C-q
if lem_wait_for "$session" 'Tags:[[:space:]]+:alpha:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" F5
  if wait_report 'PROMPT-POINT input=":alpha:" offset=7'; then
    pass tags-initial-point "the existing tag prompt opened at the input end"
  else
    fail tags-initial-point "the existing tag prompt did not place point at the end"
  fi
  for _ in $(seq 1 7); do tmux_cmd send-keys -t "$session" BSpace; done
  tmux_cmd send-keys -t "$session" -l ':beta:gamma:beta:'
  tmux_cmd send-keys -t "$session" Enter
  if lem_wait_for "$session" 'NEXT.*Work unscheduled sentinel.*:beta:gamma:' 40 >/dev/null &&
     grep -qE '^\* NEXT Work unscheduled sentinel +:beta:gamma:$' "$work_file"; then
    pass tags-replace "C-c C-q canonicalized and replaced multiple local tags"
  else
    fail tags-replace "replacement tags did not render and persist"
  fi
else
  fail tags-replace "C-c C-q did not reopen with current tags"
fi

tmux_cmd send-keys -t "$session" c t
if lem_wait_for "$session" 'Tags:[[:space:]]+:beta:gamma:' 10 >/dev/null; then
  for _ in $(seq 1 12); do tmux_cmd send-keys -t "$session" BSpace; done
  tmux_cmd send-keys -t "$session" Enter
  if wait_file_pattern '^\* NEXT Work unscheduled sentinel$' "$work_file" &&
     lem_wait_for "$session" 'NEXT[[:space:]]+Work unscheduled sentinel' 40 >/dev/null; then
    pass tags-clear "an empty tag prompt removed the suffix and saved"
  else
    fail tags-clear "clearing tags left source syntax behind"
  fi
else
  fail tags-clear "ct did not reopen with replacement tags"
fi

# GNU Org's agenda chords remain available under Evil-Org. Relative dates use
# the agenda's current day and source planning fields retain Org's order.
tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Schedule date' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l +2d
  tmux_cmd send-keys -t "$session" Enter
  if lem_wait_for "$session" 'SCHEDULED 2026-07-14' 40 >/dev/null &&
     grep -q '^SCHEDULED: <2026-07-14 Tue>$' "$work_file"; then
    pass schedule "C-c C-s resolves a relative date, saves, and refreshes"
  else
    fail schedule "agenda scheduling did not persist the relative date"
  fi
else
  fail schedule-prompt "C-c C-s did not open the schedule date prompt"
fi

tmux_cmd send-keys -t "$session" C-c C-d
if lem_wait_for "$session" 'Deadline date' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 2026-07-16
  tmux_cmd send-keys -t "$session" Enter
  if lem_wait_for "$session" 'DEADLINE 2026-07-16' 40 >/dev/null &&
     grep -q '^DEADLINE: <2026-07-16 Thu> SCHEDULED: <2026-07-14 Tue>$' "$work_file"; then
    tmux_cmd send-keys -t "$session" F6
    if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$work_file line=1 .*DEADLINE 2026-07-16"; then
      pass deadline "C-c C-d prepends, saves, refreshes, and retains its row"
    else
      fail deadline "deadline refresh lost the selected logical row"
    fi
  else
    fail deadline "agenda deadline did not preserve Org planning order"
  fi
else
  fail deadline-prompt "C-c C-d did not open the deadline date prompt"
fi

# Updating an existing field replaces it in place instead of duplicating or
# reordering the other planning field.
tmux_cmd send-keys -t "$session" C-c C-s
if lem_wait_for "$session" 'Schedule date' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 2026-07-15
  tmux_cmd send-keys -t "$session" Enter
  if lem_wait_for "$session" 'SCHEDULED 2026-07-15' 40 >/dev/null &&
     grep -q '^DEADLINE: <2026-07-16 Thu> SCHEDULED: <2026-07-15 Wed>$' "$work_file"; then
    pass reschedule "an existing planning field was replaced once in place"
  else
    fail reschedule "rescheduling duplicated or reordered planning fields"
  fi
else
  fail reschedule-prompt "C-c C-s did not reopen for an existing field"
fi

# GNU Org's double prefix edits warning/delay cookies relative to the existing
# field.  A single prefix removes the field, saves, refreshes, and follows the
# same logical heading to its remaining planning row or unscheduled TODO row.
tmux_cmd send-keys -t "$session" C-z
sleep 0.3
tmux_cmd send-keys -t "$session" C-u C-u C-c C-s
if lem_wait_for "$session" 'Delay until \[2026-07-15\]' 10 >/dev/null; then
  type_slow 2026-07-18
  tmux_cmd send-keys -t "$session" Enter
  if wait_file_line '^DEADLINE: <2026-07-16 Thu> SCHEDULED: <2026-07-15 Wed -3d>$' "$work_file" 2 &&
     wait_screen_absent 'Delay until' &&
     lem_wait_for "$session" 'SCHEDULED 2026-07-15' 40 >/dev/null; then
    pass agenda-delay "double prefix adds a persisted scheduled-delay cookie"
  else
    fail agenda-delay "agenda scheduled-delay update did not save or refresh"
  fi
else
  fail agenda-delay-prompt "double prefix did not open the scheduled-delay prompt"
fi

tmux_cmd send-keys -t "$session" C-u C-u C-c C-d
if lem_wait_for "$session" 'Warn starting from \[2026-07-16\]' 10 >/dev/null; then
  type_slow 2026-07-14
  tmux_cmd send-keys -t "$session" Enter
  if wait_file_line '^DEADLINE: <2026-07-16 Thu -2d> SCHEDULED: <2026-07-15 Wed -3d>$' "$work_file" 2 &&
     wait_screen_absent 'Warn starting from' &&
     lem_wait_for "$session" 'DEADLINE 2026-07-16' 40 >/dev/null; then
    pass agenda-warning "double prefix adds a persisted deadline warning cookie"
  else
    fail agenda-warning "agenda deadline-warning update did not save or refresh"
  fi
else
  fail agenda-warning-prompt "double prefix did not open the deadline-warning prompt"
fi

tmux_cmd send-keys -t "$session" C-u C-c C-d
if wait_file_line '^SCHEDULED: <2026-07-15 Wed -3d>$' "$work_file" 2 &&
   lem_wait_for "$session" 'SCHEDULED 2026-07-15' 40 >/dev/null; then
  pass agenda-remove-deadline "one prefix removes only the deadline and follows the schedule row"
else
  fail agenda-remove-deadline "agenda deadline removal damaged or lost the remaining row"
fi

tmux_cmd send-keys -t "$session" C-u C-c C-s
if wait_file_line '^\* TODO Overdue work sentinel$' "$work_file" 2 &&
   lem_wait_for "$session" 'NEXT[[:space:]]+Work unscheduled sentinel' 40 >/dev/null; then
  tmux_cmd send-keys -t "$session" C-z
  sleep 0.3
  tmux_cmd send-keys -t "$session" F6
  if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$work_file line=1 .*NEXT.*Work unscheduled sentinel"; then
    pass agenda-remove-schedule "removing the final field follows the unscheduled TODO row"
  else
    fail agenda-remove-schedule "final planning removal lost the logical heading"
  fi
else
  fail agenda-remove-schedule "final planning field was not removed and refreshed"
  tmux_cmd send-keys -t "$session" C-z
  sleep 0.3
fi

run_timestamp_prompt_tests() {
# Evil-Org p follows the agenda row's exact timestamp marker.  The configured
# Emacs command deliberately leaves this remote edit unsaved; automatic and
# manual refreshes must therefore parse the modified live source buffer.
printf '%s\n' \
  '* TODO Timestamp prompt planning sentinel' \
  'SCHEDULED: <2026-07-14 Tue +1w -2d>' \
  '* Timestamp prompt event sentinel <2026-07-13 Mon 10:00-11:00 +1w -2d>' \
  '* TODO Timestamp prompt no-date sentinel' \
  >"$timestamp_file"
tmux_cmd send-keys -t "$session" g r
lem_wait_for "$session" 'Timestamp prompt planning sentinel' 40 >/dev/null || true
tmux_cmd send-keys -t "$session" C-c v p
if lem_wait_for "$session" 'Date \[2026-07-14\]' 10 >/dev/null; then
  type_slow '2026-07-16 09:15-10:30'
  lem_wait_for "$session" 'Date.*2026-07-16 09:15-10:30' 10 >/dev/null || true
  sleep 0.3
  tmux_cmd send-keys -t "$session" Enter
else
  fail agenda-date-prompt "p did not offer the represented planning timestamp"
fi
if lem_wait_for "$session" 'Timestamp prompt planning sentinel.*SCHEDULED 2026-07-16' 40 >/dev/null &&
   grep -q '^SCHEDULED: <2026-07-14 Tue +1w -2d>$' "$timestamp_file"; then
  pass agenda-date-prompt "p changed the exact planning token without saving it"
else
  fail agenda-date-prompt "p lost the planning row, suffix, or unsaved boundary"
fi
tmux_cmd send-keys -t "$session" g r
sleep 1
if lem_wait_for "$session" 'Timestamp prompt planning sentinel.*SCHEDULED 2026-07-16' 40 >/dev/null; then
  pass agenda-live-refresh "gr reads the immutable snapshot of a modified live Org buffer"
else
  fail agenda-live-refresh "gr reverted an unsaved live agenda timestamp to disk"
fi

# The remote edit is one source-buffer undo transaction.  Returning to the
# agenda and refreshing must reveal the original in-memory timestamp again.
tmux_cmd send-keys -t "$session" C-c v
sleep 0.2
tmux_cmd send-keys -t "$session" F6
wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$timestamp_file line=1 .*Timestamp prompt planning sentinel" || true
tmux_cmd send-keys -t "$session" Enter
sleep 0.4
tmux_cmd send-keys -t "$session" F7
if wait_report "^SOURCE file=$timestamp_file line=1 mode=ORG-MODE text=\"\\* TODO Timestamp prompt planning sentinel\"$"; then
  tmux_cmd send-keys -t "$session" C-z
  sleep 0.2
  tmux_cmd send-keys -t "$session" C-x u
  sleep 0.2
  tmux_cmd send-keys -t "$session" C-z
  sleep 0.2
  tmux_cmd send-keys -t "$session" F8
  lem_wait_for "$session" 'Overdue' 10 >/dev/null || true
  tmux_cmd send-keys -t "$session" g r
else
  fail agenda-date-prompt-undo "Return did not visit the timestamp source row"
fi
if lem_wait_for "$session" 'Timestamp prompt planning sentinel.*SCHEDULED 2026-07-14' 40 >/dev/null; then
  pass agenda-date-prompt-undo "one source undo restored the complete timestamp"
else
  fail agenda-date-prompt-undo "the remote replacement was split across undo steps"
fi

# Cancellation is atomic; an ordinary event edit can replace its time range
# while preserving repeater/warning syntax and still remain unsaved.
tmux_cmd send-keys -t "$session" C-c y p
if lem_wait_for "$session" 'Date \[2026-07-13 10:00-11:00\]' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" Escape
  sleep 0.3
  if grep -q '^\* Timestamp prompt event sentinel <2026-07-13 Mon 10:00-11:00 +1w -2d>$' "$timestamp_file"; then
    pass agenda-date-prompt-cancel "C-g left the exact event token untouched"
  else
    fail agenda-date-prompt-cancel "cancelling p changed the event source"
  fi
else
  fail agenda-date-prompt-cancel "event p did not open with its source default"
fi
tmux_cmd send-keys -t "$session" p
if lem_wait_for "$session" 'Date \[2026-07-13 10:00-11:00\]' 10 >/dev/null; then
  type_slow '2026-07-18 12:30-13:45'
  lem_wait_for "$session" 'Date.*2026-07-18 12:30-13:45' 10 >/dev/null || true
  sleep 0.3
  tmux_cmd send-keys -t "$session" Enter
fi
if lem_wait_for "$session" 'Timestamp prompt event sentinel.*EVENT 2026-07-18 12:30' 40 >/dev/null &&
   grep -q '^\* Timestamp prompt event sentinel <2026-07-13 Mon 10:00-11:00 +1w -2d>$' "$timestamp_file"; then
  tmux_cmd send-keys -t "$session" g r
  sleep 1
  if lem_wait_for "$session" 'Timestamp prompt event sentinel.*EVENT 2026-07-18 12:30' 40 >/dev/null; then
    pass agenda-date-prompt-event "p preserved event suffixes, refreshed, and stayed unsaved"
  else
    fail agenda-date-prompt-event "manual refresh lost the live event edit"
  fi
else
  fail agenda-date-prompt-event "p did not rewrite the event time range in memory"
fi

tmux_cmd send-keys -t "$session" C-c n p
if lem_wait_for "$session" 'Cannot find time stamp' 10 >/dev/null &&
   grep -q '^\* TODO Timestamp prompt no-date sentinel$' "$timestamp_file"; then
  pass agenda-date-prompt-none "p refuses an undated row without prompting or mutation"
else
  fail agenda-date-prompt-none "p treated an undated agenda row as a timestamp"
fi
}

# If a live source buffer has shifted since the scan, the stored line must not
# mutate whichever heading now occupies that location.
tmux_cmd send-keys -t "$session" F12
tmux_cmd send-keys -t "$session" F3
wait_report '^STALE-MADE modified=yes$' || true
tmux_cmd send-keys -t "$session" c t
if lem_wait_for "$session" 'Tags:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l stale
  tmux_cmd send-keys -t "$session" Enter
  sleep 0.4
  tmux_cmd send-keys -t "$session" F2
  if wait_report_count '^STALE-SOURCE modified=yes first="# unsaved stale line" second="\* NEXT Work unscheduled sentinel"$' 1 &&
     grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
    pass tags-stale "ct refused a shifted row without changing or saving its source"
  else
    fail tags-stale "ct changed or saved the wrong source line from a stale row"
  fi
else
  fail tags-stale "ct did not prompt on the stale agenda row"
fi
tmux_cmd send-keys -t "$session" K
sleep 0.4
tmux_cmd send-keys -t "$session" F2
if wait_report_count '^STALE-SOURCE modified=yes first="# unsaved stale line" second="\* NEXT Work unscheduled sentinel"$' 2 &&
   grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  pass priority-stale "K refused a shifted row without changing or saving its source"
else
  fail priority-stale "K changed or saved the wrong source line from a stale row"
fi
tmux_cmd send-keys -t "$session" t
sleep 0.2
tmux_cmd send-keys -t "$session" w
sleep 0.4
tmux_cmd send-keys -t "$session" F2
if wait_report_count '^STALE-SOURCE modified=yes first="# unsaved stale line" second="\* NEXT Work unscheduled sentinel"$' 3 &&
   grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  pass todo-stale "t refused a shifted row without changing or saving its source"
else
  fail todo-stale "t changed or saved the wrong source line from a stale row"
fi

archive_checksum="$(sha256sum "$archive_file" | cut -d' ' -f1)"
tmux_cmd send-keys -t "$session" d A
sleep 0.4
tmux_cmd send-keys -t "$session" F2
if wait_report_count '^STALE-SOURCE modified=yes first="# unsaved stale line" second="\* NEXT Work unscheduled sentinel"$' 4 &&
   [ "$(sha256sum "$archive_file" | cut -d' ' -f1)" = "$archive_checksum" ] &&
   grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  pass archive-stale "dA refused a shifted row before touching either file"
else
  fail archive-stale "dA archived or saved from a stale agenda row"
fi

tmux_cmd send-keys -t "$session" C-c C-w
sleep 0.4
tmux_cmd send-keys -t "$session" F2
if wait_report_count '^STALE-SOURCE modified=yes first="# unsaved stale line" second="\* NEXT Work unscheduled sentinel"$' 5 &&
   grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  pass refile-stale "C-c C-w refused a shifted row before prompting or saving"
else
  fail refile-stale "C-c C-w moved or saved from a stale agenda row"
fi
tmux_cmd send-keys -t "$session" C-c z
sleep 0.2

# q must close the popped agenda and restore the source view.
tmux_cmd send-keys -t "$session" q
sleep 0.5
if lem_capture "$session" | grep -q 'Agenda source buffer sentinel' &&
   ! lem_capture "$session" | grep -q 'Overdue work sentinel'; then
  pass quit "q returns from the agenda popup"
else
  fail quit "q did not restore the source view"
fi

# Reopen, select an entry, and use the real Return key to visit its exact file/line.
visit_ok=0
tmux_cmd send-keys -t "$session" Escape
sleep 0.2
tmux_cmd send-keys -t "$session" Space m a
if lem_wait_for "$session" 'Public visit sentinel' 40 >/dev/null; then
  : >"$LEM_YATH_AGENDA_REPORT"
  tmux_cmd send-keys -t "$session" F5 g k F6
  if wait_report '^POINT mode=LEM-YATH-AGENDA-MODE file=.* line=[0-9]+ text=.*$' &&
     ! grep -q 'Public visit sentinel' "$LEM_YATH_AGENDA_REPORT"; then
    tmux_cmd send-keys -t "$session" g j F6
    if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$public_file line=3 .*Public visit sentinel"; then
      : >"$LEM_YATH_AGENDA_REPORT"
      tmux_cmd send-keys -t "$session" 2 g k F6
      if wait_report '^POINT mode=LEM-YATH-AGENDA-MODE file=.* line=[0-9]+ text=.*$' &&
         ! grep -q 'Public visit sentinel' "$LEM_YATH_AGENDA_REPORT"; then
        tmux_cmd send-keys -t "$session" 2 g j F6
        if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$public_file line=3 .*Public visit sentinel"; then
          pass item-motion "gk/gj skip decoration and honor Evil counts between source rows"
        else
          fail item-motion "counted gj did not return across two source-backed rows"
        fi
      else
        fail item-motion "counted gk did not move across two source-backed rows"
      fi
    else
      fail item-motion "gj did not return to the next source-backed agenda row"
    fi
  else
    fail item-motion "gk did not reach the previous source-backed agenda row"
  fi

  : >"$LEM_YATH_AGENDA_REPORT"
  tmux_cmd send-keys -t "$session" F5 Tab
  if lem_wait_for "$session" 'Public agenda' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" F7
  fi
  if wait_report "^SOURCE file=$public_file line=3 mode=ORG-MODE text=\"\\* SOMEDAY Public visit sentinel\"$"; then
    pass goto-other-window "Tab opened the exact agenda source in another window"
  else
    fail goto-other-window "Tab did not open the exact source-backed row"
  fi
  tmux_cmd send-keys -t "$session" F8
  lem_wait_for "$session" 'Public visit sentinel' 10 >/dev/null || true

  tmux_cmd send-keys -t "$session" F5
  sleep 0.2
  tmux_cmd send-keys -t "$session" F6
  if wait_report "^POINT mode=LEM-YATH-AGENDA-MODE file=$public_file line=3 .*Public visit sentinel"; then
    tmux_cmd send-keys -t "$session" Enter
    if lem_wait_for "$session" 'Public agenda' 10 >/dev/null; then
      sleep 0.3
      tmux_cmd send-keys -t "$session" F7
    fi
  fi
  if wait_report "^SOURCE file=$public_file line=3 mode=ORG-MODE text=\"\\* SOMEDAY Public visit sentinel\"$"; then
    visit_ok=1
    pass visit "Return follows stored source properties to the exact duplicate-name file"
  else
    fail visit "Return opened the wrong file or line"
  fi
else
  fail reopen "agenda did not reopen"
fi

if [ "$visit_ok" != 1 ]; then
  printf '\nAgenda TUI tests failed.\n' >&2
  exit 1
fi

# Return to the agenda, mutate a top-level source, and coalesce repeated real gr keys.
tmux_cmd send-keys -t "$session" F8
lem_wait_for "$session" 'Overdue work sentinel' 10 >/dev/null || true
printf '%s\n' '* TODO Refreshed top-level sentinel' >>"$work_file"
tmux_cmd send-keys -t "$session" g r g r g r
if lem_wait_for "$session" 'Refreshed top-level sentinel' 40 >/dev/null; then
  tmux_cmd send-keys -t "$session" F4
  wait_report '^REPORT-DONE serial=3$' || true
  if grep -qE '^ENTRY serial=3 section=TODOS .*Refreshed top-level sentinel' "$LEM_YATH_AGENDA_REPORT"; then
    pass refresh "gr rebuilds from changed agenda sources"
  else
    fail refresh "screen refreshed but source properties were absent"
  fi
else
  fail refresh "gr did not rebuild the agenda"
fi

# One failed root must warn without discarding healthy work/public entries.
tmux_cmd send-keys -t "$session" F11
lem_wait_for "$session" 'Injected agenda root failure' 40 >/dev/null || true
tmux_cmd send-keys -t "$session" F4
if wait_report '^REPORT-DONE serial=4$' &&
   grep -qE '^ENTRY serial=4 .*Work unscheduled sentinel' "$LEM_YATH_AGENDA_REPORT" &&
   grep -qE '^ENTRY serial=4 .*Public visit sentinel' "$LEM_YATH_AGENDA_REPORT" &&
   ! grep -qE '^ENTRY serial=4 .*MCP today sentinel' "$LEM_YATH_AGENDA_REPORT" &&
   grep -qE '^WARNING serial=4 .*Injected agenda root failure' "$LEM_YATH_AGENDA_REPORT"; then
  pass discovery "a failed root warns while healthy roots remain visible"
else
  fail discovery "one failed root erased healthy agenda sources or stayed silent"
fi
tmux_cmd send-keys -t "$session" g r
lem_wait_for "$session" 'MCP today sentinel' 40 >/dev/null || true

run_timestamp_prompt_tests

# A delayed old generation must not overwrite a newer render.
tmux_cmd send-keys -t "$session" F9
if wait_report '^RACE old-accepted=no new-present=yes old-present=no generation=[1-9][0-9]*$' &&
   lem_wait_for "$session" 'New generation sentinel' 10 >/dev/null &&
   ! lem_capture "$session" | grep -q 'Old generation sentinel'; then
  pass generation "stale asynchronous results cannot overwrite newer content"
else
  fail generation "an older generation was accepted or replaced the new result"
fi

# Killing the agenda invalidates outstanding work and rejects late delivery.
tmux_cmd send-keys -t "$session" F10
if wait_report '^KILL live=no stale-accepted=no$'; then
  pass cleanup "killed agenda buffers reject late renders"
else
  fail cleanup "late delivery touched a killed buffer"
fi

if [ "$FAILED" = 0 ]; then
  printf '\nAgenda TUI tests passed.\n'
else
  printf '\nAgenda TUI tests failed.\n' >&2
  exit 1
fi
