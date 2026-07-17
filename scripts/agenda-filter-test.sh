#!/usr/bin/env bash
# GNU Org/Evil-Org stacked agenda filters in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-filter-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-filter.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_FILTER_REPORT="$root/report"
export TZ=UTC
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR/mcp"

work_file="$WORKDIR/filter.org"
original_file="$root/filter.original"
session="lem-agenda-filter-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-filter-fixture.lisp")"
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
  sed -n '1,240p' "$LEM_YATH_AGENDA_FILTER_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 120); do
    grep -qE "$pattern" "$LEM_YATH_AGENDA_FILTER_REPORT" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

wait_report_count() {
  local pattern="$1" expected="$2" count i
  for i in $(seq 1 120); do
    count="$(grep -cE "$pattern" "$LEM_YATH_AGENDA_FILTER_REPORT" 2>/dev/null || true)"
    [ "$count" -ge "$expected" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_agenda() {
  lem_wait_for "$session" 'Regexp special filter sentinel' 20 >/dev/null
}

send_keys() {
  tmux_cmd send-keys -t "$session" "$@"
}

printf '%s\n' \
  '#+CATEGORY: FileCat' \
  '#+FILETAGS: :filetag:' \
  '* TODO Alpha root filter sentinel :root:' \
  ':PROPERTIES:' \
  ':CATEGORY: RootCat' \
  ':Effort: 0:30' \
  ':END:' \
  '** TODO Alpha child filter sentinel :child:' \
  ':PROPERTIES:' \
  ':Effort: 1:00' \
  ':END:' \
  '** TODO Alpha other filter sentinel' \
  '* TODO Beta root filter sentinel :beta:' \
  ':PROPERTIES:' \
  ':CATEGORY: BetaCat' \
  ':Effort: 2:00' \
  ':END:' \
  '** TODO Beta child filter sentinel :child:' \
  '* TODO File fallback filter sentinel :plain:' \
  ':PROPERTIES:' \
  ':Effort: 0:10' \
  ':END:' \
  '* TODO Regexp special filter sentinel' \
  >"$work_file"
cp "$work_file" "$original_file"
: >"$LEM_YATH_AGENDA_FILTER_REPORT"

lem_start \
  "$session" \
  --eval "(progn (unless (find-package \"LEM-YATH\") (load #P$init)) (load #P$fixture) (funcall (intern \"LEM-YATH-AGENDA\" \"LEM-YATH\")))"
if ! wait_agenda; then
  fail startup 'the filter fixture agenda did not render'
  exit 1
fi

send_keys C-c z a
send_keys C-c z 0
wait_report '^STATE initial ' || true
send_keys C-c z n
wait_report '^KEYS normal ' || true
metadata_ok=1
grep -q '^STATE initial rows=7 .*cat="RootCat" .*tags=("filetag" "root" "child") effort="1:00" top="Alpha root filter sentinel"' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || metadata_ok=0
grep -q '^KEYS normal sc=LEM-YATH-AGENDA-FILTER-BY-CATEGORY sr=LEM-YATH-AGENDA-FILTER-BY-REGEXP se=LEM-YATH-AGENDA-FILTER-BY-EFFORT st=LEM-YATH-AGENDA-FILTER-BY-TAG s\^=LEM-YATH-AGENDA-FILTER-BY-TOP-HEADLINE ss=LEM-YATH-AGENDA-LIMIT-INTERACTIVELY S=LEM-YATH-AGENDA-FILTER-REMOVE-ALL$' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || metadata_ok=0
grep -q '^DURATION units=90.0 mixed=90.0$' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || metadata_ok=0
if [ "$metadata_ok" = 1 ]; then
  pass metadata-keymaps 'effective metadata and all Evil-Org chords are live'
else
  fail metadata-keymaps 'metadata inheritance or Evil-Org bindings differed'
fi

send_keys s c
send_keys C-c z 1
wait_report '^STATE category ' || true
if grep -q '^STATE category rows=3 header="Agenda  (2026-07-17)  \[Cat:+RootCat\]' \
     "$LEM_YATH_AGENDA_FILTER_REPORT"; then
  pass category 'sc selected the effective inherited category at point'
else
  fail category 'positive category filtering differed'
fi

send_keys s c
send_keys C-c z 2
wait_report '^STATE category-clear ' || true
if grep -q '^STATE category-clear rows=7 header="Agenda  (2026-07-17)"' \
     "$LEM_YATH_AGENDA_FILTER_REPORT"; then
  pass category-toggle 'a second sc removed the category filter'
else
  fail category-toggle 'category toggle did not restore all rows'
fi

send_keys C-c z b
send_keys C-u s c
send_keys C-c z 3
wait_report '^STATE category-negative ' || true
if grep -q '^STATE category-negative rows=5 header="Agenda  (2026-07-17)  \[Cat:-BetaCat\]' \
     "$LEM_YATH_AGENDA_FILTER_REPORT"; then
  pass category-negative 'C-u sc excluded the category at point'
else
  fail category-negative 'prefix-negative category behavior differed'
fi
send_keys S

send_keys C-c z a
send_keys s ^
send_keys C-c z 4
wait_report '^STATE top ' || true
top_ok=1
grep -q '^STATE top rows=3 header="Agenda  (2026-07-17)  \[Top:+Alpha root filter sentinel\]' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || top_ok=0
send_keys g r
for _ in $(seq 1 120); do
  send_keys C-c z 5
  grep -q '^STATE top-refresh rows=3 header="Agenda  (2026-07-17)  \[Top:+Alpha root filter sentinel\]' \
    "$LEM_YATH_AGENDA_FILTER_REPORT" 2>/dev/null && break
  sleep 0.1
done
grep -q '^STATE top-refresh rows=3 header="Agenda  (2026-07-17)  \[Top:+Alpha root filter sentinel\]' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || top_ok=0
if [ "$top_ok" = 1 ]; then
  pass top-refresh 's^ selected a subtree family and survived gr refresh'
else
  fail top-refresh 'top-headline filtering or refresh persistence differed'
fi
send_keys S

send_keys s t
if lem_wait_for "$session" 'Filter\[-\] by tag' 10 >/dev/null; then
  send_keys Tab
  lem_wait_for "$session" 'Tag:' 10 >/dev/null || true
  send_keys -l child
  send_keys Enter
else
  fail tag-prompt 'st did not open Org tag dispatch'
fi
send_keys C-c z 6
wait_report '^STATE tag ' || true
tag_ok=1
grep -q '^STATE tag rows=2 header="Agenda  (2026-07-17)  \[Tag:+child\]' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || tag_ok=0
send_keys C-u C-u s t
lem_wait_for "$session" 'Filter\[-\] by tag' 10 >/dev/null || true
send_keys Tab
lem_wait_for "$session" 'Tag:' 10 >/dev/null || true
send_keys -l root
send_keys Enter
send_keys C-c z 7
wait_report '^STATE tag-stack ' || true
grep -q '^STATE tag-stack rows=1 header="Agenda  (2026-07-17)  \[Tag:+child Tag:+root\]' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || tag_ok=0
if [ "$tag_ok" = 1 ]; then
  pass tag-stack 'st completion and C-u C-u accumulation intersected tags'
else
  fail tag-stack 'tag filtering or accumulation differed'
fi
send_keys S

send_keys s r
if lem_wait_for "$session" 'Narrow to entries matching regexp:' 10 >/dev/null; then
  send_keys -l SPECIAL
  send_keys Enter
else
  fail regexp-prompt 'sr did not open the regexp prompt'
fi
send_keys C-c z 8
wait_report '^STATE regexp ' || true
regexp_ok=1
grep -q '^STATE regexp rows=1 header="Agenda  (2026-07-17)  \[Re:+SPECIAL\]' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || regexp_ok=0
send_keys s r
send_keys C-c z 9
wait_report '^STATE regexp-clear ' || true
grep -q '^STATE regexp-clear rows=7 header="Agenda  (2026-07-17)"' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || regexp_ok=0
if [ "$regexp_ok" = 1 ]; then
  pass regexp-toggle 'sr matched case-folded display text and toggled off'
else
  fail regexp-toggle 'regexp filtering or toggle behavior differed'
fi

send_keys s e
if lem_wait_for "$session" 'Effort operator?' 10 >/dev/null; then
  send_keys '<'
  lem_wait_for "$session" 'Effort \[1\]0' 10 >/dev/null || true
  send_keys 4
else
  fail effort-prompt 'se did not open the Effort operator prompt'
fi
send_keys C-c z e
wait_report '^STATE effort ' || true
effort_ok=1
grep -q '^STATE effort rows=3 header="Agenda  (2026-07-17)  \[Eff:+<1:00\]' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || effort_ok=0
send_keys s e _
send_keys C-c z E
wait_report '^STATE effort-clear ' || true
grep -q '^STATE effort-clear rows=7 header="Agenda  (2026-07-17)"' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || effort_ok=0
if [ "$effort_ok" = 1 ]; then
  pass effort 'se used Org duration thresholds and _ removed the filter'
else
  fail effort 'Effort comparison or explicit removal differed'
fi

send_keys s s e
if lem_wait_for "$session" 'How many entries?' 10 >/dev/null; then
  send_keys 2 Enter
else
  fail limit-prompt 'ss did not open the entry limit prompt'
fi
send_keys C-c z l
wait_report '^STATE limit ' || true
limit_ok=1
grep -q '^STATE limit rows=2 header="Agenda  (2026-07-17)  \[Max-entries:2\]' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || limit_ok=0
send_keys g r
wait_agenda || true
send_keys C-c z L
wait_report '^STATE limit-refresh ' || true
grep -q '^STATE limit-refresh rows=7 header="Agenda  (2026-07-17)"' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || limit_ok=0
if [ "$limit_ok" = 1 ]; then
  pass temporary-limit 'ss limited one generation and gr rebuilt the full view'
else
  fail temporary-limit 'generation-local entry limiting differed'
fi

send_keys C-c z a
send_keys C-z
send_keys C-c z m
wait_report '^KEYS emacs ' || true
base_keys_ok=1
grep -q '^KEYS emacs backslash=LEM-YATH-AGENDA-FILTER-BY-TAG underscore=LEM-YATH-AGENDA-FILTER-BY-EFFORT equals=LEM-YATH-AGENDA-FILTER-BY-REGEXP bar=LEM-YATH-AGENDA-FILTER-REMOVE-ALL tilde=LEM-YATH-AGENDA-LIMIT-INTERACTIVELY less=LEM-YATH-AGENDA-FILTER-BY-CATEGORY caret=LEM-YATH-AGENDA-FILTER-BY-TOP-HEADLINE$' \
  "$LEM_YATH_AGENDA_FILTER_REPORT" || base_keys_ok=0
send_keys '<'
send_keys C-c z c
wait_report '^STATE base-category ' || true
grep -q '^STATE base-category rows=3 ' "$LEM_YATH_AGENDA_FILTER_REPORT" || base_keys_ok=0
send_keys '|'
send_keys C-c z C
wait_report '^STATE base-clear ' || true
grep -q '^STATE base-clear rows=7 ' "$LEM_YATH_AGENDA_FILTER_REPORT" || base_keys_ok=0
if [ "$base_keys_ok" = 1 ]; then
  pass base-aliases 'C-z exposed GNU aliases and their category/clear actions'
else
  fail base-aliases 'GNU base bindings or actions differed'
fi

if cmp -s "$work_file" "$original_file"; then
  pass display-only 'all filters left every Org source byte unchanged'
else
  fail display-only 'filtering unexpectedly changed the Org source'
fi

if [ "$FAILED" = 0 ]; then
  printf 'All agenda filter checks passed.\n'
else
  exit 1
fi
