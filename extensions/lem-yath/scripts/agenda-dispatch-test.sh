#!/usr/bin/env bash
# Physical Org agenda dispatcher coverage in a clean real-ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-agenda-dispatch-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-agenda-dispatch.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_AGENDA_DISPATCH_REPORT="$root/report"
export TZ=UTC
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR/mcp"

work_file="$WORKDIR/dispatch.org"
original_file="$root/dispatch.original"
session="lem-agenda-dispatch-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/agenda-dispatch-fixture.lisp")"
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
  sed -n '1,160p' "$LEM_YATH_AGENDA_DISPATCH_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 160); do
    grep -qE "$pattern" "$LEM_YATH_AGENDA_DISPATCH_REPORT" 2>/dev/null &&
      return 0
    sleep 0.1
  done
  return 1
}

wait_screen_absent() {
  local pattern="$1" i
  for i in $(seq 1 80); do
    ! lem_capture "$session" | grep -qE "$pattern" && return 0
    sleep 0.1
  done
  return 1
}

send_keys() { tmux_cmd send-keys -t "$session" "$@"; }

printf '%s\n' \
  '* TODO Past dispatch sentinel                                      :FLAGGED:' \
  ':PROPERTIES:' \
  ':THEFLAGGINGNOTE: review\nsource' \
  ':END:' \
  'DEADLINE: <2026-07-10 Fri>' \
  '* TODO Monday dispatch sentinel' \
  'SCHEDULED: <2026-07-13 Mon>' \
  '* NEXT Today dispatch sentinel' \
  'SCHEDULED: <2026-07-17 Fri>' \
  '* TODO Future dispatch sentinel' \
  'SCHEDULED: <2026-08-05 Wed>' \
  '* TODO Unscheduled dispatch sentinel' \
  '* DONE Completed dispatch sentinel' \
  '* Plain dispatch event <2026-07-17 Fri 10:00>' \
  '* Portfolio dispatch sentinel' \
  '** Stuck project dispatch sentinel' \
  '*** Plain project note sentinel' \
  '** Active project dispatch sentinel' \
  '*** NEXTACTION Active project action sentinel' \
  >"$work_file"
cp "$work_file" "$original_file"
: >"$LEM_YATH_AGENDA_DISPATCH_REPORT"

lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$work_file"
if ! lem_wait_for "$session" 'Past dispatch sentinel' 40 >/dev/null; then
  fail startup 'the clean dispatcher fixture did not start'
  exit 1
fi
send_keys Escape
sleep 0.25

send_keys Space m a
if lem_wait_for "$session" 'Agenda for current week or day' 20 >/dev/null &&
   lem_capture "$session" | grep -q 'Agenda and all TODOs' &&
   lem_capture "$session" | grep -q 'Match a TAGS/PROP/TODO query' &&
   lem_capture "$session" | grep -q 'Search for keywords in TODO entries' &&
   lem_capture "$session" | grep -q 'Multi-occur in all agenda files' &&
   lem_capture "$session" | grep -q '? flagged, # stuck'; then
  pass menu 'SPC m a exposed the implemented stock Org dispatcher commands'
else
  fail menu 'the physical dispatcher labels or supported boundary differed'
fi
cancel_ok=1
for abort_key in q Escape C-g; do
  send_keys "$abort_key"
  wait_screen_absent 'Agenda for current week or day' &&
    lem_capture "$session" | grep -q 'Past dispatch sentinel' ||
    cancel_ok=0
  if [ "$abort_key" != C-g ]; then
    send_keys Space m a
    lem_wait_for "$session" 'Agenda for current week or day' 20 >/dev/null ||
      cancel_ok=0
  fi
done
if [ "$cancel_ok" = 1 ]; then
  pass cancel 'q, Escape, and C-g aborted at the original Org source window'
else
  fail cancel 'an abort key changed the origin or opened an agenda'
fi

send_keys Space m a
lem_wait_for "$session" 'Entries with special TODO keyword' 20 >/dev/null || true
send_keys T
lem_wait_for "$session" 'TODO keyword' 10 >/dev/null || true
send_keys q
if lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null; then
  pass keyword-cancel 'q aborted special-keyword selection without an agenda'
else
  fail keyword-cancel 'keyword cancellation changed the origin'
fi

send_keys Space m a
lem_wait_for "$session" 'Agenda for current week or day' 20 >/dev/null || true
send_keys a
lem_wait_for "$session" 'Week 2026-07-13..2026-07-19' 30 >/dev/null || true
send_keys C-c z d
wait_report '^STATE command=AGENDA ' || true
if grep -q '^STATE command=AGENDA span=WEEK keyword=NIL rows=[0-9][0-9]* .*dates=.*2026-07-17' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=AGENDA .*dates=([^)]*2026-07-10' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=AGENDA .*Unscheduled dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=AGENDA .*Future dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass agenda 'a opened the Monday-aligned week without combined TODO sections'
else
  fail agenda 'a retained summary sections or rendered outside its week'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys Space m a
lem_wait_for "$session" 'List of all TODO entries' 20 >/dev/null || true
send_keys t
lem_wait_for "$session" 'Global list of TODO items of type: ALL' 30 >/dev/null || true
send_keys C-c z d
wait_report '^STATE command=TODO span=SUMMARY keyword=NIL ' || true
if grep -q '^STATE command=TODO span=SUMMARY keyword=NIL rows=5 ' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   grep -q '^STATE command=TODO .*Past dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   grep -q '^STATE command=TODO .*Unscheduled dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=TODO span=SUMMARY keyword=NIL .*Completed dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=TODO span=SUMMARY keyword=NIL .*\[SCHEDULED ' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass todo 't rendered every open heading exactly once without planning metadata'
else
  fail todo 't duplicated planned headings, retained dates, or included DONE'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys Space m a
lem_wait_for "$session" '\? flagged, # stuck' 10 >/dev/null || true
send_keys '?'
lem_wait_for "$session" 'Headlines with TAGS match: \+FLAGGED' 30 >/dev/null || true
send_keys g j
if lem_wait_for "$session" 'FLAGGING-NOTE \(\[\?\] for more info\): review//source' 10 >/dev/null; then
  pass flagged-note 'moving onto a flagged row echoed its normalized THEFLAGGINGNOTE'
else
  fail flagged-note 'flagged-row movement did not echo the source property'
fi
send_keys P
lem_wait_for "$session" "Flagging note pushed to kill ring\. Press '\?' again" 10 >/dev/null || true
send_keys C-c z f
wait_report '^NOTE focus=T buffer=T multiline=T kill-raw=T$' || true
if grep -q '^NOTE focus=T buffer=T multiline=T kill-raw=T$' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass flagged-detail 'P kept agenda focus, showed a multiline note, and copied its raw value'
else
  fail flagged-detail 'P changed focus or produced the wrong detail/kill-ring representation'
fi
send_keys C-c z d
wait_report '^STATE command=FLAGGED .*rows=1 ' || true
if grep -q '^STATE command=FLAGGED .*rows=1 .*Past dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=FLAGGED .*Active project' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass flagged '? reused the exact +FLAGGED tag matcher'
else
  fail flagged '? did not isolate the flagged heading'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys Space m a
lem_wait_for "$session" '\? flagged, # stuck' 10 >/dev/null || true
send_keys '#'
lem_wait_for "$session" 'List of stuck projects:' 30 >/dev/null || true
send_keys C-c z d
wait_report '^STATE command=STUCK .*rows=1 ' || true
if grep -q '^STATE command=STUCK .*rows=1 .*Stuck project dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=STUCK .*Active project dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass stuck '# recognized stock raw NEXTACTION outside the configured TODO set'
else
  fail stuck '# misclassified a project subtree'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys Space m a
lem_wait_for "$session" 'Entries with special TODO keyword' 20 >/dev/null || true
send_keys T
lem_wait_for "$session" 'TODO keyword' 10 >/dev/null || true
send_keys d
lem_wait_for "$session" 'Global list of TODO items of type: DONE' 30 >/dev/null || true
send_keys C-c z d
wait_report '^STATE command=TODO span=SUMMARY keyword=DONE ' || true
if grep -q '^STATE command=TODO span=SUMMARY keyword=DONE rows=1 keywords=("DONE") dates=NIL .*Completed dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass keyword 'T selected the configured DONE keyword exactly'
else
  fail keyword 'T did not isolate one configured TODO keyword'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys Space m a
lem_wait_for "$session" 'Agenda and all TODOs' 20 >/dev/null || true
send_keys n
lem_wait_for "$session" '^Agenda  \(2026-07-17\)' 30 >/dev/null || true
send_keys C-c z d
wait_report '^STATE command=SUMMARY span=SUMMARY keyword=NIL ' || true
if grep -q '^STATE command=SUMMARY span=SUMMARY keyword=NIL .*Unscheduled dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   grep -q '^STATE command=SUMMARY span=SUMMARY keyword=NIL .*Today dispatch sentinel' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass combined 'n retained the configured agenda-and-all-TODO summary'
else
  fail combined 'n did not open the established combined summary'
fi

# Repeated < follows Org's buffer -> subtree/region -> unrestricted cycle.
# The restriction is captured from the source before the dispatcher opens and
# remains attached to refreshes of the resulting agenda buffer.
send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys C-c z c
send_keys g g
send_keys Space m a
lem_wait_for "$session" 'unrestricted; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'buffer; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'subtree; < restrict' 10 >/dev/null || true
send_keys t
lem_wait_for "$session" 'Global list of TODO items of type: ALL' 30 >/dev/null || true
send_keys C-c z d
wait_report 'restriction=SUBTREE range=1\.\.5$' || true
if grep -q '^STATE command=TODO .*rows=1 .*Past dispatch sentinel.*restriction=SUBTREE range=1\.\.5$' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=TODO .*rows=1 .*Monday dispatch sentinel.*restriction=SUBTREE' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass subtree-restrict '< < t retained only the source subtree and its exact line range'
else
  fail subtree-restrict 'subtree restriction leaked another heading or lost its boundary'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys C-c z r
lem_wait_for "$session" 'unrestricted; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'buffer; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'region; < restrict' 10 >/dev/null || true
send_keys t
lem_wait_for "$session" 'Global list of TODO items of type: ALL' 30 >/dev/null || true
send_keys C-c z d
wait_report 'restriction=REGION range=6\.\.9$' || true
if grep -q '^STATE command=TODO .*rows=2 .*Monday dispatch sentinel.*Today dispatch sentinel.*restriction=REGION range=6\.\.9$' "$LEM_YATH_AGENDA_DISPATCH_REPORT" &&
   ! grep -q '^STATE command=TODO .*rows=2 .*Past dispatch sentinel.*restriction=REGION' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass region-restrict 'active-region < < t included both and only selected headings'
else
  fail region-restrict 'region restriction used the wrong inclusive/exclusive lines'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys C-c z p
lem_wait_for "$session" 'unrestricted; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'buffer; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'region; < restrict' 10 >/dev/null || true
send_keys s
sleep 0.15
tmux_cmd send-keys -t "$session" -l '2026-07-10'
send_keys Enter
lem_wait_for "$session" 'Search words: 2026-07-10' 30 >/dev/null || true
send_keys C-c z d
wait_report '^STATE command=SEARCH .*rows=0 .*restriction=REGION range=1\.\.1$' || true
if grep -q '^STATE command=SEARCH .*rows=0 .*restriction=REGION range=1\.\.1$' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass partial-region 's ignored matching body text beyond the exact region end'
else
  fail partial-region 'out-of-region body text leaked into restricted search'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys g g
send_keys Space m a
lem_wait_for "$session" 'unrestricted; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'buffer; < restrict' 10 >/dev/null || true
send_keys '>'
lem_wait_for "$session" 'unrestricted; < restrict' 10 >/dev/null || true
send_keys t
lem_wait_for "$session" 'Global list of TODO items of type: ALL' 30 >/dev/null || true
send_keys C-c z d
wait_report 'restriction=NIL range=NIL\.\.NIL$' || true
if grep -q '^STATE command=TODO .*rows=5 .*restriction=NIL range=NIL\.\.NIL$' "$LEM_YATH_AGENDA_DISPATCH_REPORT"; then
  pass restriction-clear '> removed a pending buffer restriction before dispatch'
else
  fail restriction-clear '> left the agenda restricted or changed its TODO rows'
fi

send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys C-c z c
send_keys g g
send_keys Space m a
lem_wait_for "$session" 'unrestricted; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'buffer; < restrict' 10 >/dev/null || true
send_keys '<'
lem_wait_for "$session" 'subtree; < restrict' 10 >/dev/null || true
send_keys /
sleep 0.15
tmux_cmd send-keys -t "$session" -l 'dispatch sentinel'
send_keys Enter
if lem_wait_for "$session" '1 match for "dispatch sentinel"' 30 >/dev/null; then
  pass restricted-occur 'restricted / narrowed source-backed Occur to one subtree'
else
  fail restricted-occur 'restricted / searched outside the selected subtree'
fi

cmp -s "$work_file" "$original_file" ||
  fail safety 'dispatcher views changed their Org source'

# A consecutive second ? is the one intentional mutation in this fixture:
# Org offers to remove both the tag and note, closes the detail split, saves,
# and refreshes the now-empty +FLAGGED view.
send_keys q
lem_wait_for "$session" 'Past dispatch sentinel' 10 >/dev/null || true
send_keys Space m a
lem_wait_for "$session" '\? flagged, # stuck' 10 >/dev/null || true
send_keys '?'
lem_wait_for "$session" 'Headlines with TAGS match: \+FLAGGED' 30 >/dev/null || true
send_keys g j '?'
lem_wait_for "$session" "Flagging note pushed to kill ring\. Press '\?' again" 10 >/dev/null || true
send_keys '?'
lem_wait_for "$session" 'Unflag and remove any flagging note\?' 10 >/dev/null || true
send_keys y
if lem_wait_for "$session" 'Entry unflagged' 10 >/dev/null &&
   grep -qx '\* TODO Past dispatch sentinel' "$work_file" &&
   ! grep -q 'FLAGGED\|THEFLAGGINGNOTE\|^:PROPERTIES:$\|^:END:$' "$work_file" &&
   ! lem_capture "$session" | grep -q '\*Flagging Note\*'; then
  pass flagged-remove 'consecutive ? removed tag, note, empty drawer, and detail split'
else
  fail flagged-remove 'consecutive ? did not persist the exact unflag mutation'
fi

send_keys u
if lem_wait_for "$session" 'Past dispatch sentinel.*FLAGGED' 30 >/dev/null &&
   ! grep -q 'FLAGGED\|THEFLAGGINGNOTE\|^:PROPERTIES:$\|^:END:$' "$work_file"; then
  pass flagged-undo 'u restored the complete flagging metadata live without rewriting disk'
else
  fail flagged-undo 'remote undo lost metadata or crossed the saved-file boundary'
fi

if [ "$FAILED" -ne 0 ]; then
  printf '\nAgenda dispatcher tests failed.\n' >&2
  exit 1
fi
printf '\nAll agenda dispatcher checks passed.\n'
