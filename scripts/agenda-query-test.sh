#!/usr/bin/env bash
# Physical Org tag/property/text query and multi-occur coverage.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-query-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-query.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_QUERY_REPORT="$root/report"
export TZ=UTC
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR/mcp"

work_file="$WORKDIR/query.org"
original_file="$root/query.original"
session="lem-agenda-query-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-query-fixture.lisp")"
FAILED=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-20s %s\n' "$1" "$2"; }
fail() {
  FAILED=1
  printf 'FAIL  %-20s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,200p' "$LEM_YATH_AGENDA_QUERY_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 180); do
    grep -qE "$pattern" "$LEM_YATH_AGENDA_QUERY_REPORT" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

send_keys() { tmux_cmd send-keys -t "$session" "$@"; }
send_text() { tmux_cmd send-keys -t "$session" -l "$1"; }

printf '%s\n' \
  '#+CATEGORY: querycat' \
  '#+FILETAGS: :global:' \
  '* Parent query sentinel :parent:' \
  ':PROPERTIES:' \
  ':OWNER: Ada Lovelace' \
  ':END:' \
  '** TODO Child query sentinel :blue:' \
  ':PROPERTIES:' \
  ':SCORE: 15' \
  ':END:' \
  'alpha' \
  'beta occur needle' \
  '** DONE Done query sentinel :blue:' \
  ':PROPERTIES:' \
  ':SCORE: 20' \
  ':END:' \
  'completed body' \
  '* NEXT Next query sentinel :blue:' \
  'unique beta' \
  '* Plain tagged query sentinel :blue:' \
  'plain tagged body' \
  '* Plain body query sentinel' \
  'ordinary unique beta' \
  '* COMMENT Suppressed query sentinel :blue:' \
  'unique beta' \
  '* Archived query sentinel :ARCHIVE:blue:' \
  'unique beta' \
  >"$work_file"
cp "$work_file" "$original_file"
: >"$LEM_YATH_AGENDA_QUERY_REPORT"

lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$work_file"
if ! lem_wait_for "$session" 'Parent query sentinel' 40 >/dev/null; then
  fail startup 'the clean query fixture did not start'
  exit 1
fi
send_keys Escape
sleep 0.2

send_keys Space m a
lem_wait_for "$session" 'Match a TAGS/PROP/TODO query' 15 >/dev/null || true
send_keys m
lem_wait_for "$session" 'Match:' 10 >/dev/null || true
send_keys C-g
if lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null &&
   ! lem_capture "$session" | grep -q 'Headlines with TAGS match'; then
  pass query-cancel 'C-g left a matcher prompt at the original source'
else
  fail query-cancel 'matcher prompt cancellation opened or changed a view'
fi

run_query() {
  local key="$1" query="$2" header="$3"
  send_keys Space m a
  lem_wait_for "$session" 'Match a TAGS/PROP/TODO query' 15 >/dev/null || return 1
  send_keys "$key"
  sleep 0.15
  send_text "$query"
  send_keys Enter
  lem_wait_for "$session" "$header" 30 >/dev/null
}

if run_query m 'parent+blue' 'Headlines with TAGS match' ; then
  send_keys C-c z q
  wait_report '^STATE command=TAGS query="parent\+blue" rows=2 ' || true
fi
if grep -q '^STATE command=TAGS query="parent+blue" rows=2 .*Child query sentinel.*Done query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass inherited-tags 'm ANDed inherited and local tags in source order'
else
  fail inherited-tags 'm did not preserve Org inherited-tag semantics'
fi

send_keys C-c z e
wait_report '^EDGE kind=TAGS query="parent|blue-parent"' || true
edge_ok=1
grep -q '^EDGE kind=TAGS query="parent|blue-parent" rows=5 names=("Parent query sentinel" "Child query sentinel" "Done query sentinel" "Next query sentinel" "Plain tagged query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="{\^bl}" rows=4 ' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="OWNER={Ada\.\*}" rows=1 names=("Parent query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="MISSING=0" rows=6 ' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="MISSING=\*0" rows=0 names=NIL' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="LEVEL>=2" rows=2 names=("Child query sentinel" "Done query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="TODO=\\"DONE\\"" rows=1 names=("Done query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="blue/-DONE" rows=3 names=("Child query sentinel" "Next query sentinel" "Plain tagged query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=TAGS query="blue/TODO|DONE" rows=2 names=("Child query sentinel" "Done query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=SEARCH query=":+uni" rows=0 names=NIL' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=SEARCH query=":+unique" rows=2 names=("Next query sentinel" "Plain body query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=SEARCH query="+{uni\.\.e} -ordinary" rows=1 names=("Next query sentinel")' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=SEARCH query="+\\"unique beta\\"" rows=2 ' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=SEARCH query="!completed body" rows=0 names=NIL' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
grep -q '^EDGE kind=SEARCH query="UNIQUE BETA" rows=2 ' "$LEM_YATH_AGENDA_QUERY_REPORT" || edge_ok=0
if [ "$edge_ok" = 1 ]; then
  pass matcher-edges 'Org 9.8.5 OR/negative/regexp/starred/property and search modifiers agree'
else
  fail matcher-edges 'one differential Org 9.8.5 matcher/search edge diverged'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query m 'SCORE>=20' 'Headlines with TAGS match' ; then
  send_keys C-c z q
  wait_report '^STATE command=TAGS query="SCORE>=20" rows=1 ' || true
fi
if grep -q '^STATE command=TAGS query="SCORE>=20" rows=1 .*Done query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass property 'numeric property matching selected the exact heading'
else
  fail property 'numeric property comparison diverged from Org matching'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query m 'OWNER="Ada Lovelace"' 'Headlines with TAGS match' ; then
  send_keys C-c z q
  wait_report '^STATE command=TAGS query="OWNER=' || true
fi
if grep -q '^STATE command=TAGS query="OWNER=\\"Ada Lovelace\\"" rows=1 .*Parent query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass quoted-property 'quoted local string properties retained embedded spaces'
else
  fail quoted-property 'quoted property matching or local scope diverged'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query m 'blue/DONE' 'Headlines with TAGS match' ; then
  send_keys C-c z q
  wait_report '^STATE command=TAGS query="blue/DONE" rows=1 ' || true
fi
if grep -q '^STATE command=TAGS query="blue/DONE" rows=1 .*Done query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass todo-clause 'm applied the slash TODO clause after tag matching'
else
  fail todo-clause 'the slash TODO matcher selected the wrong state'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query m 'blue/!' 'Headlines with TAGS match' ; then
  send_keys C-c z q
  wait_report '^STATE command=TAGS query="blue/!" rows=2 ' || true
fi
if grep -q '^STATE command=TAGS query="blue/!" rows=2 .*Child query sentinel.*Next query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT" &&
   ! grep -q '^STATE command=TAGS query="blue/!" .*Done query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass todo-open 'slash ! retained only non-done TODO states'
else
  fail todo-open 'slash ! did not enforce Org open-TODO semantics'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query M 'blue' 'Headlines with TAGS match' ; then
  send_keys C-c z q
  wait_report '^STATE command=TAGS-TODO query="blue" rows=3 ' || true
fi
if grep -q '^STATE command=TAGS-TODO query="blue" rows=3 .*Child query sentinel.*Done query sentinel.*Next query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT" &&
   ! grep -q '^STATE command=TAGS-TODO query="blue" .*Plain tagged query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass todo-any 'M included open and done TODO states but excluded plain headings'
else
  fail todo-any 'M did not use Org all-TODO-state semantics'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query s 'alpha beta' 'Search words' ; then
  send_keys C-c z q
  wait_report '^STATE command=SEARCH query="alpha beta" rows=1 ' || true
fi
if grep -q '^STATE command=SEARCH query="alpha beta" rows=1 .*Child query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass phrase 's expanded phrase whitespace across source lines'
else
  fail phrase 'phrase search did not span arbitrary whitespace'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query s '+unique -ordinary' 'Search words' ; then
  send_keys C-c z q
  wait_report '^STATE command=SEARCH query="\+unique -ordinary" rows=1 ' || true
fi
if grep -q '^STATE command=SEARCH query="+unique -ordinary" rows=1 .*Next query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass boolean 's combined required and forbidden Boolean snippets'
else
  fail boolean 'Boolean search inclusion/exclusion diverged'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query s '*Next query' 'Search words' ; then
  send_keys C-c z q
  wait_report '^STATE command=SEARCH query="\*Next query" rows=1 ' || true
fi
if grep -q '^STATE command=SEARCH query="\*Next query" rows=1 .*Next query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass headline-only 'leading * restricted phrase matching to headline text'
else
  fail headline-only 'headline-only search failed to select the heading'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
if run_query S 'unique beta' 'Search words' ; then
  send_keys C-c z q
  wait_report '^STATE command=SEARCH query="unique beta" rows=1 ' || true
fi
if grep -q '^STATE command=SEARCH query="unique beta" rows=1 .*Next query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT" &&
   ! grep -q '^STATE command=SEARCH query="unique beta" .*Plain body query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass search-todo 'S retained only open TODO entries'
else
  fail search-todo 'S included a done or non-TODO heading'
fi

send_keys q
lem_wait_for "$session" 'Parent query sentinel' 10 >/dev/null || true
send_keys Space m a
lem_wait_for "$session" 'Multi-occur in all agenda files' 15 >/dev/null || true
send_keys /
sleep 0.15
send_text 'occur needle'
send_keys Enter
if lem_wait_for "$session" 'beta occur needle' 30 >/dev/null; then
  send_keys g j
  sleep 0.15
  send_keys Enter
  if lem_wait_for "$session" 'beta occur needle' 15 >/dev/null &&
     lem_capture "$session" | grep -qE 'query\.org.*12:5'; then
    pass multi-occur '/ reused source-backed Occur and Return visited the match'
  else
    fail multi-occur 'Return did not visit the physical Org match'
  fi
else
  fail multi-occur '/ did not search all agenda file buffers'
fi

send_keys A
send_text ' unsaved-live-sentinel'
send_keys C-[
lem_wait_for "$session" 'unsaved-live-sentinel' 10 >/dev/null || true
if run_query s 'unsaved-live-sentinel' 'Search words' ; then
  send_keys C-c z q
  wait_report '^STATE command=SEARCH query="unsaved-live-sentinel" rows=1 ' || true
fi
if grep -q '^STATE command=SEARCH query="unsaved-live-sentinel" rows=1 .*Child query sentinel' "$LEM_YATH_AGENDA_QUERY_REPORT"; then
  pass live-unsaved 's searched the immutable snapshot of a modified live Org buffer'
else
  fail live-unsaved 'query scan ignored or mishandled the unsaved live source'
fi

cmp -s "$work_file" "$original_file" ||
  fail safety 'query and occur views changed their Org source'

if [ "$FAILED" -ne 0 ]; then
  printf '\nAgenda query tests failed.\n' >&2
  exit 1
fi
printf '\nAll agenda query checks passed.\n'
