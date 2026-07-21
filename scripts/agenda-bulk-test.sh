#!/usr/bin/env bash
# GNU Org/Evil-Org agenda bulk-action dispatch in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-bulk-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-bulk.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_BULK_REPORT="$root/report"
export TZ=UTC
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR/mcp"

work_file="$WORKDIR/bulk.org"
archive_file="${work_file}_archive"
session="lem-agenda-bulk-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-bulk-fixture.lisp")"
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
  sed -n '1,240p' "$LEM_YATH_AGENDA_BULK_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern="$1" expected="$2" count i
  for i in $(seq 1 100); do
    count="$(grep -cE "$pattern" "$LEM_YATH_AGENDA_BULK_REPORT" 2>/dev/null || true)"
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

wait_file_count() {
  local pattern="$1" expected="$2" file="$3" count i
  for i in $(seq 1 100); do
    count="$(grep -cE "$pattern" "$file" 2>/dev/null || true)"
    [ "$count" -ge "$expected" ] && return 0
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

wait_agenda() {
  lem_wait_for "$session" 'Bulk current fallback sentinel' 20 >/dev/null
}

send_chord() {
  tmux_cmd send-keys -t "$session" "$@"
}

printf '%s\n' \
  '* TODO Bulk TODO alpha sentinel :old:' \
  '* TODO Bulk TODO beta sentinel' \
  '* TODO Bulk current fallback sentinel' \
  '* TODO Bulk schedule alpha sentinel' \
  '* TODO Bulk schedule beta sentinel' \
  '* TODO Bulk archive alpha sentinel' \
  'Archive alpha body.' \
  '* TODO Bulk archive beta sentinel' \
  '* Refile target sentinel' \
  '** Existing refile child sentinel' \
  '* TODO Bulk refile alpha sentinel' \
  '* TODO Bulk refile beta sentinel' \
  '* TODO Bulk stale sentinel' \
  >"$work_file"
: >"$LEM_YATH_AGENDA_BULK_REPORT"

lem_start \
  "$session" \
  --eval "(progn (unless (find-package \"LEM-YATH\") (load #P$init)) (load #P$fixture) (funcall (intern \"LEM-YATH-AGENDA-SUMMARY\" \"LEM-YATH\")))"
if ! wait_agenda; then
  fail startup 'the fixture agenda did not render'
  exit 1
fi

# Evil-Org shadows base B with x in Normal state; C-z exposes GNU B.
send_chord C-c z k
wait_report_count '^STATE state=normal ' 1 || true
send_chord C-z
send_chord C-c z k
wait_report_count '^STATE state=emacs ' 1 || true
state_ok=1
grep -q '^STATE state=normal x=LEM-YATH-AGENDA-BULK-ACTION ' \
  "$LEM_YATH_AGENDA_BULK_REPORT" || state_ok=0
grep -q '^STATE state=emacs x=SELF-INSERT B=LEM-YATH-AGENDA-BULK-ACTION ' \
  "$LEM_YATH_AGENDA_BULK_REPORT" || state_ok=0
if [ "$state_ok" = 1 ]; then
  pass state-maps 'Evil x and GNU B follow the effective state split'
else
  fail state-maps 'bulk dispatcher bindings differed'
fi
send_chord C-z

# One TODO choice applies to every explicit mark, then default marks clear.
send_chord C-c z 1
send_chord m
send_chord C-c z 2
send_chord m
send_chord x t
if lem_wait_for "$session" 'Todo state:' 10 >/dev/null; then
  send_chord -l 'NEXT'
  send_chord Enter
else
  fail todo-prompt 'bulk TODO did not open the pinned completion prompt'
fi
lem_wait_for "$session" 'Acted on 2 entries' 20 >/dev/null || true
wait_agenda || true
send_chord C-c z k
todo_ok=1
grep -q '^\* NEXT Bulk TODO alpha sentinel ' "$work_file" || todo_ok=0
grep -q '^\* NEXT Bulk TODO beta sentinel$' "$work_file" || todo_ok=0
wait_report_count '^STATE state=normal .*marks=0 rendered=0$' 1 || todo_ok=0
if [ "$todo_ok" = 1 ]; then
  pass todo 'one TODO selection persisted across two marks and cleared them'
else
  fail todo 'bulk TODO state or mark clearing differed'
fi

# With no marks, x falls back to the current row and accepts one new tag.
send_chord C-c z 3
send_chord x +
if lem_wait_for "$session" 'Tag to add:' 10 >/dev/null; then
  send_chord -l 'bulk'
  send_chord Enter
  wait_file_pattern '^\* TODO Bulk current fallback sentinel.*:bulk:$' \
    "$work_file" || true
  wait_agenda || true
  if grep -q '^\* TODO Bulk current fallback sentinel.*:bulk:$' "$work_file" &&
     [ "$(grep -c ':bulk:$' "$work_file")" = 1 ]; then
    pass current-fallback 'an unmarked x action changed only the current row'
  else
    fail current-fallback 'current-row fallback changed the wrong source set'
  fi
else
  fail current-fallback 'the shared tag prompt did not open'
fi

send_chord C-c z 3
send_chord x -
if lem_wait_for "$session" 'Tag to remove:' 10 >/dev/null; then
  send_chord -l 'bulk'
  send_chord Enter
  wait_file_without_pattern \
    '^\* TODO Bulk current fallback sentinel.*:bulk:$' "$work_file" || true
  wait_agenda || true
  if grep -q '^\* TODO Bulk current fallback sentinel$' "$work_file"; then
    pass tag-remove 'the inverse bulk tag action removed the selected tag'
  else
    fail tag-remove 'bulk tag removal left or damaged the heading suffix'
  fi
else
  fail tag-remove 'the shared remove-tag prompt did not open'
fi

# The base-map B path shares one schedule date across all marked entries.
send_chord C-c z 4
send_chord m
send_chord C-c z 5
send_chord m
send_chord C-z
send_chord B s
if lem_wait_for "$session" 'Schedule date' 10 >/dev/null; then
  send_chord -l '2026-07-18'
  send_chord Enter
  wait_file_count '^SCHEDULED: <2026-07-18 Sat>$' 2 "$work_file" || true
  wait_agenda || true
  schedule_ok=1
  [ "$(grep -c '^SCHEDULED: <2026-07-18 Sat>$' "$work_file")" = 2 ] || schedule_ok=0
  if [ "$schedule_ok" = 1 ]; then
    pass schedule 'GNU B scheduled two marked headings from one date prompt'
  else
    fail schedule 'bulk scheduling did not persist both planning fields'
  fi
else
  fail schedule 'GNU B did not open the schedule prompt'
fi
send_chord C-z

# Deadline uses the same marked-set contract through Evil x, with one prompt.
send_chord C-c z 4
send_chord m
send_chord C-c z 5
send_chord m
send_chord x d
if lem_wait_for "$session" 'Deadline date' 10 >/dev/null; then
  send_chord -l '2026-07-17'
  send_chord Enter
  wait_file_count '^DEADLINE: <2026-07-17 Fri>' 2 "$work_file" || true
  wait_agenda || true
  deadline_ok=1
  [ "$(grep -c '^DEADLINE: <2026-07-17 Fri> SCHEDULED: <2026-07-18 Sat>$' \
      "$work_file")" = 2 ] || deadline_ok=0
  if [ "$deadline_ok" = 1 ]; then
    pass deadline 'Evil x set two deadlines from one shared date prompt'
  else
    fail deadline 'bulk deadlines did not preserve the planning-line shape'
  fi
else
  fail deadline 'Evil x did not open the deadline prompt'
fi

# Unsupported sibling archive must retain marks; $ then archives both in
# source order and clears them only after successful persistence.
send_chord C-c z 6
send_chord m
send_chord C-c z 7
send_chord m
send_chord x q
send_chord C-c z k
cancel_ok=1
wait_report_count '^STATE state=normal .*marks=2 rendered=2$' 1 || cancel_ok=0
[ ! -e "$archive_file" ] || cancel_ok=0
if [ "$cancel_ok" = 1 ]; then
  pass cancel 'quitting the dispatcher retained both marks and sources'
else
  fail cancel 'dispatcher cancellation mutated or cleared the selection'
fi

send_chord x A
lem_wait_for "$session" 'not supported; marks kept' 10 >/dev/null || true
send_chord C-c z k
unsupported_ok=1
wait_report_count '^STATE state=normal .*marks=2 rendered=2$' 1 || unsupported_ok=0
[ ! -e "$archive_file" ] || unsupported_ok=0
if [ "$unsupported_ok" = 1 ]; then
  pass unsupported 'archive-sibling refusal retained both marks and sources'
else
  fail unsupported 'an unsupported action mutated or cleared the selection'
fi

send_chord x '$'
lem_wait_for "$session" 'Acted on 2 entries' 20 >/dev/null || true
wait_agenda || true
archive_ok=1
grep -q '^\* TODO Bulk archive alpha sentinel$' "$archive_file" || archive_ok=0
grep -q '^\* TODO Bulk archive beta sentinel$' "$archive_file" || archive_ok=0
! grep -q 'Bulk archive .* sentinel' "$work_file" || archive_ok=0
send_chord C-c z k
wait_report_count '^STATE state=normal .*marks=0 rendered=0$' 2 || archive_ok=0
if [ "$archive_ok" = 1 ]; then
  pass archive 'two marked subtrees archived in order and cleared their marks'
else
  fail archive 'bulk archive persistence or mark clearing differed'
fi

# Refile prompts once, keeps source order, and appends both as target children.
send_chord C-c z 8
send_chord m
send_chord C-c z 9
send_chord m
send_chord x r
if lem_wait_for "$session" 'Refile subtree' 10 >/dev/null; then
  send_chord -l 'Refile target sentinel'
  send_chord Enter
  lem_wait_for "$session" 'Acted on 2 entries' 20 >/dev/null || true
  wait_agenda || true
  refile_ok=1
  target_line="$(grep -n '^\* Refile target sentinel$' "$work_file" | cut -d: -f1)"
  existing_line="$(grep -n '^\*\* Existing refile child sentinel$' "$work_file" | cut -d: -f1)"
  alpha_line="$(grep -n '^\*\* TODO Bulk refile alpha sentinel$' "$work_file" | cut -d: -f1)"
  beta_line="$(grep -n '^\*\* TODO Bulk refile beta sentinel$' "$work_file" | cut -d: -f1)"
  [ -n "$target_line" ] && [ -n "$existing_line" ] &&
    [ -n "$alpha_line" ] && [ -n "$beta_line" ] || refile_ok=0
  if [ "$refile_ok" = 1 ]; then
    [ "$target_line" -lt "$existing_line" ] &&
      [ "$existing_line" -lt "$alpha_line" ] &&
      [ "$alpha_line" -lt "$beta_line" ] || refile_ok=0
  fi
  if [ "$refile_ok" = 1 ]; then
    pass refile 'one target prompt moved two subtrees in source order'
  else
    fail refile 'bulk refile hierarchy or ordering differed'
  fi
else
  fail refile 'bulk refile did not open its single target prompt'
fi

# A live marked point survives unrelated insertions, but an edited heading is
# rejected before the dispatcher prompts or saves anything.
send_chord C-c z 0
send_chord m
send_chord C-c z s
wait_report_count '^STALE modified=yes text="\* TODO Bulk stale sentinel changed"$' 1 || true
send_chord x
lem_wait_for "$session" 'Agenda source changed; refresh before editing' 10 >/dev/null || true
send_chord C-c z k
stale_ok=1
grep -q '^\* TODO Bulk stale sentinel$' "$work_file" || stale_ok=0
wait_report_count '^STATE state=normal .*marks=1 rendered=1$' 1 || stale_ok=0
if [ "$stale_ok" = 1 ]; then
  pass stale-safety 'changed marked source was refused unsaved with marks retained'
else
  fail stale-safety 'stale bulk dispatch saved, mutated, or cleared its mark'
fi

if [ "$FAILED" = 0 ]; then
  printf 'All agenda bulk-action checks passed.\n'
else
  exit 1
fi
