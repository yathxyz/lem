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
  >"$work_file"

printf '%s\n' \
  '#+title: Public agenda' \
  '' \
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
  grep -qE '^STATIC serial=1 mode=LEM-YATH-AGENDA-MODE date=2026-07-12 roots=3 files=4 generation=[1-9][0-9]* return=LEM-YATH-AGENDA-VISIT g=LEM-YATH-AGENDA-REFRESH t=LEM-YATH-AGENDA-TODO q=QUIT-ACTIVE-WINDOW kill-hooks=1 modified=no undo=no running=no pending=no$' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "ROOT serial=1 index=1 path=$WORKDIR/" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "ROOT serial=1 index=2 path=$PUBLIC_ORG_DIR/" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "ROOT serial=1 index=3 path=$PUBLIC_ORG_DIR/mcp/" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=1 path=$work_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=2 path=$source_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=3 path=$public_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qF "FILE serial=1 index=4 path=$mcp_file" "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  [ "$(grep -c '^ENTRY serial=1 ' "$LEM_YATH_AGENDA_REPORT")" = 12 ] || static_ok=0
  grep -qE '^ENTRY serial=1 section=OVERDUE .*Overdue work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Today work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Plain today sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*MCP today sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Upcoming work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Work unscheduled sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Hold work sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Public visit sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Body planning text sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODOS .*Invalid planning sentinel' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  [ "$(grep -c '^ENTRY serial=1 .*Dual planning sentinel' "$LEM_YATH_AGENDA_REPORT")" = 2 ] || static_ok=0
  grep -qE '^ENTRY serial=1 section=TODAY .*Dual planning sentinel.*\[SCHEDULED 2026-07-12\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^ENTRY serial=1 section=UPCOMING .*Dual planning sentinel.*\[DEADLINE 2026-07-15\]' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  grep -qE '^WARNING serial=1 .*Invalid Org planning date.*2026-02-30' "$LEM_YATH_AGENDA_REPORT" || static_ok=0
  if grep -qE '^ENTRY serial=1 .*Nested (work|public)|^ENTRY serial=1 .*Hidden file|^ENTRY serial=1 .*Uppercase extension|^ENTRY serial=1 .*Done dated|^ENTRY serial=1 .*Cancelled dated|^ENTRY serial=1 .*Far future' "$LEM_YATH_AGENDA_REPORT"; then
    static_ok=0
  fi
  if [ "$static_ok" = 1 ]; then
    pass sources "exact roots, top-level files, grouping, filtering, and Vi keys"
  else
    fail sources "source set, grouping, or effective keymap differed"
  fi
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

# If a live source buffer has shifted since the scan, the stored line must not
# mutate whichever heading now occupies that location.
tmux_cmd send-keys -t "$session" F12
tmux_cmd send-keys -t "$session" F3
wait_report '^STALE-MADE modified=yes$' || true
tmux_cmd send-keys -t "$session" t
sleep 0.2
tmux_cmd send-keys -t "$session" w
sleep 0.4
tmux_cmd send-keys -t "$session" F2
if wait_report '^STALE-SOURCE modified=yes first="# unsaved stale line" second="\* NEXT Work unscheduled sentinel"$' &&
   grep -q '^\* NEXT Work unscheduled sentinel$' "$work_file"; then
  pass todo-stale "a stale agenda row failed closed without saving the wrong line"
else
  fail todo-stale "a stale agenda row changed or saved the wrong source line"
fi

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

# Return to the agenda, mutate a top-level source, and coalesce repeated real g keys.
tmux_cmd send-keys -t "$session" F8
lem_wait_for "$session" 'Overdue work sentinel' 10 >/dev/null || true
printf '%s\n' '* TODO Refreshed top-level sentinel' >>"$work_file"
tmux_cmd send-keys -t "$session" g g g
if lem_wait_for "$session" 'Refreshed top-level sentinel' 40 >/dev/null; then
  tmux_cmd send-keys -t "$session" F4
  wait_report '^REPORT-DONE serial=2$' || true
  if grep -qE '^ENTRY serial=2 section=TODOS .*Refreshed top-level sentinel' "$LEM_YATH_AGENDA_REPORT"; then
    pass refresh "g rebuilds from changed agenda sources"
  else
    fail refresh "screen refreshed but source properties were absent"
  fi
else
  fail refresh "g did not rebuild the agenda"
fi

# One failed root must warn without discarding healthy work/public entries.
tmux_cmd send-keys -t "$session" F11
lem_wait_for "$session" 'Injected agenda root failure' 40 >/dev/null || true
tmux_cmd send-keys -t "$session" F4
if wait_report '^REPORT-DONE serial=3$' &&
   grep -qE '^ENTRY serial=3 .*Work unscheduled sentinel' "$LEM_YATH_AGENDA_REPORT" &&
   grep -qE '^ENTRY serial=3 .*Public visit sentinel' "$LEM_YATH_AGENDA_REPORT" &&
   ! grep -qE '^ENTRY serial=3 .*MCP today sentinel' "$LEM_YATH_AGENDA_REPORT" &&
   grep -qE '^WARNING serial=3 .*Injected agenda root failure' "$LEM_YATH_AGENDA_REPORT"; then
  pass discovery "a failed root warns while healthy roots remain visible"
else
  fail discovery "one failed root erased healthy agenda sources or stayed silent"
fi
tmux_cmd send-keys -t "$session" g
lem_wait_for "$session" 'MCP today sentinel' 40 >/dev/null || true

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
