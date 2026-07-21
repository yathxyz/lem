#!/usr/bin/env bash
# Evil-Org agenda remote undo in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-undo-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-undo.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_UNDO_REPORT="$root/report"
export TZ=UTC
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR/mcp"

saved_file="$WORKDIR/saved.org"
timestamp_file="$WORKDIR/timestamp.org"
bulk_file="$WORKDIR/bulk.org"
archive_source="$WORKDIR/archive.org"
archive_file="${archive_source}_archive"
clock_file="$WORKDIR/clock.org"
refresh_file="$WORKDIR/refresh.org"
intervening_file="$WORKDIR/intervening.org"
session="lem-agenda-undo-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-undo-fixture.lisp")"
init="$(lem-yath_lisp_string "$LEM_YATH_SOURCE/init.lisp")"
FAILED=0
REPORT_SERIAL=0

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
  sed -n '1,260p' "$LEM_YATH_AGENDA_UNDO_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 100); do
    grep -qE "$pattern" "$LEM_YATH_AGENDA_UNDO_REPORT" 2>/dev/null && return 0
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

report() {
  REPORT_SERIAL=$((REPORT_SERIAL + 1))
  tmux_cmd send-keys -t "$session" F2
  wait_report "^REPORT serial=${REPORT_SERIAL} "
}

type_slow() {
  local value="$1" index
  for ((index = 0; index < ${#value}; index++)); do
    tmux_cmd send-keys -t "$session" -l "${value:index:1}"
    sleep 0.04
  done
}

printf '%s\n' '* TODO Undo saved sentinel' >"$saved_file"
printf '%s\n' \
  '* TODO Undo timestamp sentinel' \
  'DEADLINE: <2026-07-13 Mon +1w -2d>' \
  >"$timestamp_file"
printf '%s\n' \
  '* TODO Undo bulk alpha sentinel' \
  '* TODO Undo bulk beta sentinel' \
  >"$bulk_file"
printf '%s\n' \
  '* TODO Undo archive sentinel' \
  'Archive body sentinel.' \
  >"$archive_source"
printf '%s\n' '* TODO Undo clock sentinel' >"$clock_file"
printf '%s\n' '* TODO Undo refresh sentinel' >"$refresh_file"
printf '%s\n' '* TODO Undo intervening sentinel' >"$intervening_file"
: >"$LEM_YATH_AGENDA_UNDO_REPORT"

lem_start \
  "$session" \
  --eval "(progn (unless (find-package \"LEM-YATH\") (load #P$init)) (load #P$fixture) (funcall (intern \"LEM-YATH-AGENDA-SUMMARY\" \"LEM-YATH\")))"
if ! lem_wait_for "$session" 'Undo refresh sentinel' 30 >/dev/null; then
  fail startup 'the undo fixture agenda did not render'
  exit 1
fi

report || true
if grep -q "^REPORT serial=1 records=0 labels= u=LEM-YATH-AGENDA-UNDO gr=LEM-YATH-AGENDA-REFRESH$" \
     "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass binding 'Normal-state u resolves to remote agenda undo'
else
  fail binding 'the effective agenda u or gr binding differed'
fi
tmux_cmd send-keys -t "$session" u
if lem_wait_for "$session" 'No further undo information' 10 >/dev/null; then
  pass empty 'u reports an empty remote-undo history'
else
  fail empty 'u did not report an empty history'
fi

# Two autosaved mutations remain on disk while u walks their live-buffer undo
# nodes newest-first.
tmux_cmd send-keys -t "$session" F3 K
lem_wait_for "$session" 'TODO[[:space:]]+\[#B\][[:space:]]+Undo saved sentinel' 30 >/dev/null || true
tmux_cmd send-keys -t "$session" F3 t
if lem_wait_for "$session" 'TODO \[t\]odo' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" n
else
  fail saved-prompt 't did not open the configured fast-key selector'
fi
lem_wait_for "$session" 'NEXT[[:space:]]+\[#B\][[:space:]]+Undo saved sentinel' 30 >/dev/null || true
report || true
if grep -Fqx '* NEXT [#B] Undo saved sentinel' "$saved_file" &&
   grep -q '^REPORT serial=2 records=2 labels=org-agenda-todo,org-agenda-priority ' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass saved-stack 'saved priority and TODO edits formed two remote transactions'
else
  fail saved-stack 'saved edits or their transaction order differed'
fi

tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" 'TODO[[:space:]]+\[#B\][[:space:]]+Undo saved sentinel' 30 >/dev/null || true
report || true
if grep -Fqx '* NEXT [#B] Undo saved sentinel' "$saved_file" &&
   grep -q '^REPORT serial=3 records=1 labels=org-agenda-priority ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx 'SAVED serial=3 modified=yes text="* TODO [#B] Undo saved sentinel"' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass saved-undo-latest 'first u reverted TODO live without rewriting the saved file'
else
  fail saved-undo-latest 'first u crossed the save boundary or reverted the wrong edit'
fi

tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" 'TODO[[:space:]]+Undo saved sentinel' 30 >/dev/null || true
report || true
if grep -Fqx '* NEXT [#B] Undo saved sentinel' "$saved_file" &&
   grep -q '^REPORT serial=4 records=0 labels= ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx 'SAVED serial=4 modified=yes text="* TODO Undo saved sentinel"' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass saved-undo-prior 'second u reverted the earlier priority transaction only in memory'
else
  fail saved-undo-prior 'second u did not reach the preceding source undo node'
fi

# p is intentionally unsaved; undo returns the source to its saved node.
tmux_cmd send-keys -t "$session" F4 p
if lem_wait_for "$session" 'Date \[2026-07-13\]' 10 >/dev/null; then
  type_slow '2026-07-14 09:15-10:30'
  tmux_cmd send-keys -t "$session" Enter
else
  fail timestamp-prompt 'p did not offer the represented timestamp'
fi
lem_wait_for "$session" 'Undo timestamp sentinel.*2026-07-14' 30 >/dev/null || true
report || true
if grep -Fqx 'DEADLINE: <2026-07-13 Mon +1w -2d>' "$timestamp_file" &&
   grep -Fqx 'TIMESTAMP serial=5 modified=yes planning="DEADLINE: <2026-07-14 Tue 09:15-10:30 +1w -2d>"' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -q '^REPORT serial=5 records=1 labels=org-agenda-date-prompt ' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass timestamp-edit 'p recorded one unsaved remote transaction with suffixes intact'
else
  fail timestamp-edit 'p saved, split, or lost the represented timestamp'
fi
tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" 'Undo timestamp sentinel.*2026-07-13' 30 >/dev/null || true
report || true
if grep -Fqx 'TIMESTAMP serial=6 modified=no planning="DEADLINE: <2026-07-13 Mon +1w -2d>"' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -q '^REPORT serial=6 records=0 labels= ' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass timestamp-undo 'u restored the exact saved timestamp and modified state'
else
  fail timestamp-undo 'u did not return p to the saved source node'
fi

# Pinned Org records each bulk target separately, in source order.
tmux_cmd send-keys -t "$session" F5 m F6 m x t
if lem_wait_for "$session" 'Todo state:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l NEXT
  tmux_cmd send-keys -t "$session" Enter
else
  fail bulk-prompt 'bulk TODO did not open one shared prompt'
fi
lem_wait_for "$session" 'Acted on 2 entries' 20 >/dev/null || true
report || true
if grep -Fqx '* NEXT Undo bulk alpha sentinel' "$bulk_file" &&
   grep -Fqx '* NEXT Undo bulk beta sentinel' "$bulk_file" &&
   grep -q '^REPORT serial=7 records=2 labels=org-agenda-bulk-todo,org-agenda-bulk-todo ' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass bulk-stack 'bulk TODO produced one remote record per source row'
else
  fail bulk-stack 'bulk TODO did not preserve per-row undo granularity'
fi
tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" 'TODO[[:space:]]+Undo bulk beta sentinel' 30 >/dev/null || true
report || true
if grep -q '^REPORT serial=8 records=1 ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx 'BULK serial=8 modified=yes alpha="* NEXT Undo bulk alpha sentinel" beta="* TODO Undo bulk beta sentinel"' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx '* NEXT Undo bulk beta sentinel' "$bulk_file"; then
  pass bulk-undo-latest 'first u restored the last processed row without saving'
else
  fail bulk-undo-latest 'first bulk u restored the wrong target or touched disk'
fi
tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" 'TODO[[:space:]]+Undo bulk alpha sentinel' 30 >/dev/null || true
report || true
if grep -q '^REPORT serial=9 records=0 ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx 'BULK serial=9 modified=yes alpha="* TODO Undo bulk alpha sentinel" beta="* TODO Undo bulk beta sentinel"' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass bulk-undo-prior 'second u restored the first processed row'
else
  fail bulk-undo-prior 'second bulk u did not exhaust the per-row stack'
fi

# Archive destination persistence is intentionally outside remote undo.
tmux_cmd send-keys -t "$session" F7 d A
lem_wait_for "$session" 'Subtree archived in file' 20 >/dev/null || true
report || true
if ! grep -q 'Undo archive sentinel' "$archive_source" &&
   grep -q 'Undo archive sentinel' "$archive_file" &&
   grep -q '^REPORT serial=10 records=1 labels=org-agenda-archive ' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass archive-edit 'archive saved its destination and registered only its source edit'
else
  fail archive-edit 'archive persistence or remote record scope differed'
fi
tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" 'Undo archive sentinel' 30 >/dev/null || true
report || true
if ! grep -q 'Undo archive sentinel' "$archive_source" &&
   grep -q 'Undo archive sentinel' "$archive_file" &&
   grep -Fqx 'ARCHIVE serial=11 modified=yes text="* TODO Undo archive sentinel"' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass archive-undo 'u restored the live source while retaining the saved archive copy'
else
  fail archive-undo 'archive undo rewrote disk or failed to restore the source buffer'
fi

# Stock agenda clock-in participates in remote undo; its runtime tracker must
# not survive removal of the open CLOCK line.
tmux_cmd send-keys -t "$session" F8 I
wait_file_pattern '^CLOCK: \[2026-07-12 Sun 12:00\]$' "$clock_file" || true
report || true
if grep -q '^CLOCK: \[2026-07-12 Sun 12:00\]$' "$clock_file" &&
   grep -q '^REPORT serial=12 records=1 labels=org-agenda-clock-in ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -q '^CLOCK serial=12 modified=no open=1 logbook=1 active=yes$' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass clock-edit 'clock-in saved and registered one source transaction'
else
  fail clock-edit 'clock-in source or remote transaction differed'
fi
tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" 'Undo clock sentinel' 30 >/dev/null || true
report || true
if grep -q '^CLOCK: \[2026-07-12 Sun 12:00\]$' "$clock_file" &&
   grep -q '^REPORT serial=13 records=0 ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -q '^CLOCK serial=13 modified=yes open=0 logbook=0 active=no$' "$LEM_YATH_AGENDA_UNDO_REPORT"; then
  pass clock-undo 'u removed the live clock group and cleared runtime state without saving'
else
  fail clock-undo 'clock undo left source structure or runtime state inconsistent'
fi

# Explicit agenda redo is a history boundary, as in GNU Org.
tmux_cmd send-keys -t "$session" F9 K
lem_wait_for "$session" '\[#B\][[:space:]]+Undo refresh sentinel' 30 >/dev/null || true
report || true
tmux_cmd send-keys -t "$session" g r
lem_wait_for "$session" '\[#B\][[:space:]]+Undo refresh sentinel' 30 >/dev/null || true
report || true
tmux_cmd send-keys -t "$session" u
empty_after_refresh=0
lem_wait_for "$session" 'No further undo information' 10 >/dev/null && empty_after_refresh=1
report || true
if grep -q '^REPORT serial=14 records=1 labels=org-agenda-priority ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -q '^REPORT serial=15 records=0 ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx '* TODO [#B] Undo refresh sentinel' "$refresh_file" &&
   grep -Fqx 'REFRESH serial=16 modified=no text="* TODO [#B] Undo refresh sentinel"' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   [ "$empty_after_refresh" = 1 ]; then
  pass refresh-boundary 'gr discarded remote history without changing the saved source'
else
  fail refresh-boundary 'gr retained history or u changed the refreshed source'
fi

# org-with-remote-undo delegates to the source buffer's current undo head. An
# intervening local edit is therefore undone before the older agenda mutation;
# consuming the agenda record does not snapshot-restore that mutation.
tmux_cmd send-keys -t "$session" F10 K
lem_wait_for "$session" '\[#B\][[:space:]]+Undo intervening sentinel' 30 >/dev/null || true
report || true
tmux_cmd send-keys -t "$session" F11
report || true
tmux_cmd send-keys -t "$session" u
lem_wait_for "$session" '\[#B\][[:space:]]+Undo intervening sentinel' 30 >/dev/null || true
report || true
if grep -q '^REPORT serial=17 records=1 labels=org-agenda-priority ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx 'INTERVENING serial=18 modified=yes text="* TODO [#B] Undo intervening sentinel local"' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -q '^REPORT serial=19 records=0 ' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx 'INTERVENING serial=19 modified=no text="* TODO [#B] Undo intervening sentinel"' "$LEM_YATH_AGENDA_UNDO_REPORT" &&
   grep -Fqx '* TODO [#B] Undo intervening sentinel' "$intervening_file"; then
  pass intervening-edit 'u consumed the agenda record while undoing the newest local source group'
else
  fail intervening-edit 'u snapshot-restored the agenda mutation or missed the local source group'
fi

if [ "$FAILED" = 0 ]; then
  printf '\nAgenda undo TUI tests passed.\n'
else
  printf '\nAgenda undo TUI tests failed.\n' >&2
  exit 1
fi
