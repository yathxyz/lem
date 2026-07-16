#!/usr/bin/env bash
# Real-ncurses retained undo-tree and Unicode vundo regressions.
set -uo pipefail

# The visualizer contract includes real Unicode tree glyphs.  Nix builders
# otherwise default to the ASCII C locale and ncurses renders escaped bytes.
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-vundo-$$}"
if ! root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-vundo.XXXXXX")" ||
   [[ -z "$root" || ! -d "$root" ]]; then
  printf 'Unable to create a private vundo test directory\n' >&2
  exit 1
fi

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export XDG_STATE_HOME="$root/state-home"
export WORKDIR="$root/work"
export LEM_YATH_VUNDO_REPORT="$root/report"
export LEM_YATH_VUNDO_SOURCE="$here/lem-yath/src/vundo.lisp"
export LEM_YATH_VUNDO_DIRTY_FILE="$root/dirty.txt"
origin="$root/origin.txt"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$WORKDIR"
: >"$LEM_YATH_VUNDO_REPORT"
: >"$LEM_YATH_VUNDO_DIRTY_FILE"

for n in $(seq 1 160); do
  if [ "$n" -eq 40 ]; then
    printf 'A\n'
  else
    printf 'line-%02d\n' "$n"
  fi
done >"$origin"

source "$here/scripts/tui-driver.sh"

session="lem-yath-vundo-$id"
failed=0

cleanup() {
  lem_stop "$session"
  case "$root" in
    */lem-yath-vundo.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe cleanup path: %s\n' "$root" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_VUNDO_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-15} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

last_report() {
  grep -E "$1" "$LEM_YATH_VUNDO_REPORT" | tail -n 1
}

report_field() {
  local field=$1 line=$2
  printf '%s\n' "$line" | sed -nE "s/.* ${field}=([^ ]+).*/\\1/p"
}

entry_record=''
entry_point=''
entry_view=''
accept_record=''
accept_point=''
accept_view=''
saved_record=''
saved_current=''
saved_clean=''
saved_last=''
stem_entry=''
stem_point=''
stem_view=''

origin_restored() {
  local text=$1 line
  line=$(last_report '^ORIGIN ')
  [[ -n "$entry_point" && -n "$entry_view" &&
     "$line" == *"line40=${text} "* &&
     "$line" == *"point=${entry_point} "* &&
     "$line" == *"view=${entry_view} "* &&
     "$line" == *'modified=yes '* &&
     "$line" == *'read-only=no '* &&
     "$line" == *'focus=origin' ]]
}

send_keys() {
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep 0.18
  done
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l -- "$1"
  sleep 0.2
}

invoke_mx() {
  local command=$1 pattern=$2 timeout=${3:-15} before
  before=$(report_count "$pattern")
  send_keys Escape Escape M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  send_literal "$command"
  send_keys Enter
  wait_report_count "$pattern" "$((before + 1))" "$timeout"
}

invoke_mx_no_report() {
  local command=$1
  send_keys Escape Escape M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  send_literal "$command"
  send_keys Enter
  sleep 0.5
}

press_report() {
  local key=$1 pattern=$2 before
  before=$(report_count "$pattern")
  lem_keys "$session" "$key"
  wait_report_count "$pattern" "$((before + 1))"
}

wait_vundo_boot() {
  local index=0 screen
  while ((index < 240)); do
    screen=$(lem_capture "$session" 2>/dev/null || true)
    if [[ "$screen" == *NORMAL* ]] && (( $(report_count '^READY$') >= 1 )); then
      return 0
    fi
    if [[ "$screen" == *'READ error during LOAD'* ||
          "$screen" == *'unmatched close parenthesis'* ]]; then
      return 1
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/vundo-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$origin"

if wait_vundo_boot; then
  pass boot 'configured Lem loaded the vundo fixture'
else
  fail boot 'fixture did not become ready'
fi

if invoke_mx lem-yath-test-vundo-static '^SUMMARY STATIC ' &&
   grep -q '^SUMMARY STATIC PASS failures=0$' "$LEM_YATH_VUNDO_REPORT"; then
  pass static-bindings 'SPC u, ordinary undo/redo, UI commands, and core API exist'
else
  fail static-bindings 'static vundo contracts failed'
fi

if invoke_mx lem-yath-test-vundo-core-probes '^SUMMARY CORE ' 120 &&
   grep -q '^SUMMARY CORE PASS failures=0$' "$LEM_YATH_VUNDO_REPORT" &&
   grep -q '^PROBE forward-mutating-insert result=pass$' \
     "$LEM_YATH_VUNDO_REPORT" &&
   grep -q '^PROBE forward-mutating-delete result=pass$' \
     "$LEM_YATH_VUNDO_REPORT" &&
   grep -q '^PROBE throwing-mutating-change-group result=pass$' \
     "$LEM_YATH_VUNDO_REPORT" &&
   grep -q '^PROBE state-point-restoration result=pass$' \
     "$LEM_YATH_VUNDO_REPORT"; then
  pass core-invariants \
    'dirty/tick, graph, hook ordering, and invalid move contracts hold'
else
  fail core-invariants 'core retained-tree probes failed'
fi

if invoke_mx lem-yath-test-vundo-reload '^RELOAD before=closed ' &&
   grep -q '^RELOAD before=closed after=closed focus=origin graph-preserved=yes origin-read-only=no bottom=none old-view=n/a$' \
     "$LEM_YATH_VUNDO_REPORT"; then
  pass reload-closed 'double reload while closed preserved origin and graph'
else
  fail reload-closed 'closed reload disturbed vundo state'
fi

# Build a real fork: saved A -> append B -> undo B -> append C.
send_keys Escape 4 0 G '$' A
send_literal B
send_keys Escape
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'modified=yes '*'read-only=no '*'focus=origin' ]]; then
  pass edit-B 'real Vi insertion created the first child state'
else
  fail edit-B 'first branch edit did not produce AB'
fi

send_keys u
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=A '*'modified=no '*'read-only=no '*'focus=origin' ]]; then
  pass ordinary-undo-B 'ordinary u returned to saved A'
else
  fail ordinary-undo-B 'ordinary u did not undo B'
fi

send_keys A
send_literal C
send_keys Escape
# Keep the Vundo entry location far from the edited transaction so cancel and
# accept point/view behavior cannot pass accidentally.
send_keys 1 0 0 G
if press_report F2 '^ORIGIN '; then
  entry_record=$(last_report '^ORIGIN ')
  entry_point=$(report_field point "$entry_record")
  entry_view=$(report_field view "$entry_record")
fi
if [[ "$entry_record" == *'line40=AC '* &&
      "$entry_record" == *'modified=yes '* &&
      "$entry_record" == *'read-only=no '* &&
      "$entry_record" == *'focus=origin' ]]; then
  pass edit-C 'post-undo insertion created newest C'
else
  fail edit-C 'second branch edit did not produce AC'
fi

if [[ -n "$entry_point" && -n "$entry_view" &&
      "$entry_point" == 100:* && "$entry_view" != 1 ]]; then
  pass location-baseline "captured entry point $entry_point and view $entry_view"
else
  fail location-baseline 'could not capture the source point/view baseline'
fi

if press_report F3 '^GRAPH ' &&
   grep -q '^GRAPH valid=yes immutable=yes nodes=3 root-children=2 current-newest=yes preferred-current=yes clean-root=yes saved-root=yes$' \
     "$LEM_YATH_VUNDO_REPORT"; then
  pass retained-branch 'newest C and abandoned B are retained as root siblings'
else
  fail retained-branch 'retained branch graph was malformed or incomplete'
fi

# Open the real Unicode view.  F-keys remain global for black-box probes.
send_keys Space u
if lem_wait_for "$session" '●|○' 10 >/dev/null &&
   press_report F4 '^VIEW open=yes ' &&
   grep -q '^VIEW open=yes focus=yes mode=yes height=3 bottom=yes origin-read-only=yes$' \
     "$LEM_YATH_VUNDO_REPORT" &&
   lem_capture "$session" | grep -qE '●|○' &&
   lem_capture "$session" | grep -q '─' &&
   lem_capture "$session" | grep -qE '│|├|└'; then
  pass unicode-pane 'SPC u focused a three-row Unicode bottom pane'
else
  fail unicode-pane 'vundo pane geometry, focus, locking, or Unicode tree failed'
fi

send_keys b
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=A '*'point=40:'*'read-only=yes '*'focus=vundo' ]]; then
  pass preview-backward 'b previewed parent A at its historical point without leaving vundo'
else
  fail preview-backward 'b did not preview parent A'
fi

send_keys f
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'point=40:'*'read-only=yes '*'focus=vundo' ]]; then
  pass preview-forward 'f returned to preferred C at its historical point'
else
  fail preview-forward 'f did not preview preferred C'
fi

send_keys n
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'read-only=yes '*'focus=vundo' ]]; then
  pass preview-next 'n selected abandoned sibling B'
else
  fail preview-next 'n did not select sibling B'
fi

send_keys p
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'read-only=yes '*'focus=vundo' ]]; then
  pass preview-previous 'p returned to newest sibling C'
else
  fail preview-previous 'p did not return to sibling C'
fi

# The ncurses decoder must deliver the arrow aliases to the Vundo keymap.
send_keys Left
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=A '*'focus=vundo' ]]; then
  pass preview-left 'Left previewed parent A'
else
  fail preview-left 'Left did not invoke Vundo backward'
fi
send_keys Right
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'focus=vundo' ]]; then
  pass preview-right 'Right returned to newest child C'
else
  fail preview-right 'Right did not invoke Vundo forward'
fi
send_keys Down
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'focus=vundo' ]]; then
  pass preview-down 'Down selected sibling B'
else
  fail preview-down 'Down did not invoke Vundo next'
fi
send_keys Up
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'focus=vundo' ]]; then
  pass preview-up 'Up returned to sibling C'
else
  fail preview-up 'Up did not invoke Vundo previous'
fi

# Marked-node diffing is bounded, secure, and must leave `u' owned by Vundo.
send_keys m n d
if press_report T '^VSTATE ';
then
  diff_state=$(last_report '^VSTATE ')
  if [[ "$diff_state" == *'selected=1 marked=2 source=AB focus=vundo diff=live '* &&
        "$diff_state" == *'-AC\n+AB'* ]]; then
    pass marked-diff 'm/n/d compared marked C with selected B in a live diff'
  else
    fail marked-diff 'marked-node diff state or contents were incorrect'
  fi
else
  fail marked-diff 'Vundo state reporter did not run after d'
fi
send_keys u
if press_report T '^VSTATE ' &&
   [[ "$(last_report '^VSTATE ')" == *'selected=1 marked=none source=AB focus=vundo diff=live '* ]]; then
  pass unmark-local 'u removed the Vundo mark without undoing the source'
else
  fail unmark-local 'u escaped the Vundo keymap or changed the selection'
fi
if press_report Y '^KILL-DIFF ' &&
   grep -q '^KILL-DIFF session=open buffers=0 windows=1 error=none$' \
     "$LEM_YATH_VUNDO_REPORT" &&
   press_report T '^VSTATE ' &&
   [[ "$(last_report '^VSTATE ')" == *'selected=1 marked=none source=AB focus=vundo diff=none '* ]]; then
  pass diff-kill-cleanup 'killing the diff buffer removed its split and kept Vundo usable'
else
  fail diff-kill-cleanup 'diff-buffer deletion leaked its split or closed Vundo'
fi
send_keys q
if press_report F2 '^ORIGIN ' && origin_restored AC &&
   [[ "$(last_report '^ORIGIN ')" == *'tree=none diff=none bottom=none '* ]]; then
  pass diff-quit-cleanup 'q closed both temporary views and restored C'
else
  fail diff-quit-cleanup 'q leaked a diff/tree buffer or failed to restore C'
fi

# Reopen for the ordinary q contract below.
send_keys Space u

# q rolls back to the entry state and restores focus.
send_keys n q
if press_report F2 '^ORIGIN ' &&
   origin_restored AC; then
  pass quit-rollback 'q restored entry text, point, view, writability, and focus'
else
  fail quit-rollback 'q failed to restore the complete entry state'
fi

# C-g has the same rollback contract.
send_keys Space u n C-g
if press_report F2 '^ORIGIN ' &&
   origin_restored AC; then
  pass keyboard-quit-rollback 'C-g restored entry text, point, view, and focus'
else
  fail keyboard-quit-rollback 'C-g failed to restore the complete entry state'
fi

# The shared visual leader must dispatch the real Vundo command with an active
# mark, then restore the source without leaking its view.
send_keys v Space u
if press_report F4 '^VIEW open=yes ' &&
   grep -q '^VIEW open=yes focus=yes mode=yes height=3 bottom=yes origin-read-only=yes$' \
     "$LEM_YATH_VUNDO_REPORT"; then
  send_keys n q
  if press_report F2 '^ORIGIN ' && origin_restored AC &&
     [[ "$(last_report '^ORIGIN ')" == *'tree=none diff=none bottom=none '* ]]; then
    pass visual-leader 'visual SPC u opened and rolled back the real Vundo view'
  else
    fail visual-leader 'visual Vundo did not restore and clean the source'
  fi
else
  fail visual-leader 'visual SPC u did not open Vundo'
fi
send_keys Escape

# Direct deletion runs the window-delete hook while Lem is still freeing the
# object.  This must not recurse, double-free, or leave a stale frame pointer.
send_keys Space u n
if press_report X '^DELETE-WINDOW ' &&
   grep -q '^DELETE-WINDOW error=none$' "$LEM_YATH_VUNDO_REPORT" &&
   press_report F2 '^ORIGIN ' && origin_restored AC &&
   [[ "$(last_report '^ORIGIN ')" == *'session=closed tree=none diff=none bottom=none '* ]]; then
  pass direct-window-delete 'direct tree-window deletion rolled back without re-entry'
else
  fail direct-window-delete 'direct tree-window deletion recursed or leaked state'
fi

# A change hook can destroy the UI from inside the temporary source unlock.
# The outer replay must finish, use its preflighted return route, and leave the
# now-closed source writable.
send_keys Space u H b
if grep -q '^ARM change-close=yes$' "$LEM_YATH_VUNDO_REPORT" &&
   press_report F2 '^ORIGIN ' && origin_restored AC &&
   [[ "$(last_report '^ORIGIN ')" == *'session=closed tree=none diff=none bottom=none '* ]]; then
  pass replay-hook-close 'hook-triggered teardown reversed the outer replay and unlocked the source'
else
  fail replay-hook-close 'hook-triggered teardown accepted a preview, relocked, or leaked UI state'
fi

# Closing the owned bottom window without killing its buffer is also cancel.
send_keys Space u n
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'focus=vundo' ]] &&
   invoke_mx_no_report quit-active-window &&
   press_report F2 '^ORIGIN ' && origin_restored AC &&
   [[ "$(last_report '^ORIGIN ')" == *'session=closed tree=none diff=none bottom=none '* ]]; then
  pass window-quit-rollback 'quitting the Vundo window rolled back and released the session'
else
  fail window-quit-rollback 'quitting the Vundo window orphaned or accepted the preview'
fi

# Killing the visualizer buffer itself is a cancel operation.  Lem invokes
# kill hooks before freeing the buffer, so this also guards against recursive
# or double deletion in the cleanup path.
send_keys Space u n
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'read-only=yes '*'focus=vundo' ]] &&
   press_report K '^KILL-TREE ' &&
   grep -q '^KILL-TREE view=deleted session=closed bottom=none focus=origin error=none$' \
     "$LEM_YATH_VUNDO_REPORT" &&
   press_report F2 '^ORIGIN ' && origin_restored AC; then
  pass tree-kill-rollback 'visualizer deletion rolled back once and cleaned up safely'
else
  fail tree-kill-rollback 'visualizer deletion did not cancel and clean up safely'
fi

# Reloading while live must transactionally cancel a different preview.  Then a
# newly loaded session must still navigate and roll back normally.
send_keys Space u n
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'read-only=yes '*'focus=vundo' ]] &&
   press_report F5 '^RELOAD before=open ' &&
   grep -q '^RELOAD before=open after=closed focus=origin graph-preserved=yes origin-read-only=no bottom=none old-view=deleted$' \
     "$LEM_YATH_VUNDO_REPORT" &&
   press_report F2 '^ORIGIN ' && origin_restored AC; then
  send_keys Space u n
  if press_report F2 '^ORIGIN ' &&
     [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'read-only=yes '*'focus=vundo' ]]; then
    send_keys q
    if press_report F2 '^ORIGIN ' && origin_restored AC; then
      pass reload-open 'live reload cancelled safely; reopened navigation works'
    else
      fail reload-open 'reopened session did not roll back cleanly'
    fi
  else
    fail reload-open 'reloaded commands could not reopen and navigate'
  fi
else
  fail reload-open 'live reload did not close and restore the old session'
fi

# A rollback refusal must abort LOAD at its first form.  It must not redefine
# the live mode/session behind the old locked UI; after the refusing hook is
# removed, ordinary q still owns and closes that same session.
send_keys Space u n
if press_report O '^RELOAD-REFUSED ' &&
   grep -q '^RELOAD-REFUSED error=yes same-session=yes source=AB read-only=yes tree=live bottom=live focus=vundo$' \
     "$LEM_YATH_VUNDO_REPORT"; then
  send_keys q
  if press_report F2 '^ORIGIN ' && origin_restored AC &&
     [[ "$(last_report '^ORIGIN ')" == *'session=closed tree=none diff=none bottom=none '* ]]; then
    pass reload-refusal 'refused rollback aborted reload and left the old session usable'
  else
    fail reload-refusal 'the old session could not close after reload refusal'
  fi
else
  fail reload-refusal 'reload swallowed rollback refusal or replaced the live session'
fi

# If another command switches the owned bottom window away while rollback is
# refused, post-command cleanup must reclaim and refocus the same tree UI rather
# than leave a locked orphan.
send_keys Space u n P
if invoke_mx_no_report quit-active-window &&
   press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'read-only=yes '*session=open*'tree=live diff=none bottom=live '*focus=vundo ]]; then
  press_report I '^ARM rollback-refusal=no$' || true
  send_keys q
  if press_report F2 '^ORIGIN ' && origin_restored AC; then
    pass post-command-refusal 'refused close reclaimed the switched-away tree view'
  else
    fail post-command-refusal 'reclaimed view could not close after removing refusal'
  fi
else
  fail post-command-refusal 'refused post-command cleanup orphaned the locked session'
fi

# Opening Vundo again is also transactional: a refused close keeps the old
# session authoritative and prevents a replacement from being installed.
send_keys Space u n P
if press_report N '^REOPEN-REFUSED ' &&
   grep -q '^REOPEN-REFUSED error=yes same-session=yes source=AB read-only=yes tree=live bottom=live focus=vundo$' \
     "$LEM_YATH_VUNDO_REPORT"; then
  press_report I '^ARM rollback-refusal=no$' || true
  send_keys q
  if press_report F2 '^ORIGIN ' && origin_restored AC; then
    pass reopen-refusal 'refused close prevented replacement of the live session'
  else
    fail reopen-refusal 'old session could not close after rejected replacement'
  fi
else
  fail reopen-refusal 'new Vundo open replaced or orphaned a refusing session'
fi

# A delayed leader popup and Vundo both borrow the bottom side window.  The
# pre-existing occupant, including point/view/cursor/hscroll, must survive the
# complete slow-SPC path exactly.
if press_report F8 '^BOTTOM installed=yes$'; then
  lem_keys "$session" Space
  sleep 1.3
  if lem_capture "$session" | grep -q 'transient-mode'; then
    lem_keys "$session" u
    # The initial Unicode-pane case already proves glyph rendering.  Under a
    # loaded Nix builder, capture-pane can transiently escape those glyphs;
    # verify this delayed dispatch through the authoritative live session.
    if press_report F2 '^ORIGIN ' &&
       [[ "$(last_report '^ORIGIN ')" == \
          *'session=open tree=live diff=none bottom=live '*focus=vundo ]]; then
      send_keys n q
      if press_report F9 '^BOTTOM live=' &&
         grep -q '^BOTTOM live=yes buffer=yes same-window=yes height=5 point=4:12 view=2:3 cursor-hidden=yes hscroll=7 session=closed tree=none diff=none$' \
           "$LEM_YATH_VUNDO_REPORT"; then
        pass prior-bottom-slow-leader 'slow leader and Vundo restored the exact prior bottom pane'
      else
        fail prior-bottom-slow-leader 'slow leader/Vundo lost prior bottom-pane state'
      fi
    else
      fail prior-bottom-slow-leader 'Vundo did not open after delayed leader help'
    fi
  else
    fail prior-bottom-slow-leader 'the delayed leader popup was not exercised'
  fi
else
  fail prior-bottom-slow-leader 'could not install the prior bottom pane'
fi
press_report F10 '^BOTTOM cleared=yes$' || fail prior-bottom-clear 'could not clear prior bottom pane'

# Direct deletion cannot reuse the half-freed Vundo window.  The next
# post-command cycle must recreate the displaced pane with the same UX state.
if press_report F8 '^BOTTOM installed=yes$'; then
  send_keys Space u n
  if press_report X '^DELETE-WINDOW ' &&
     grep -q '^DELETE-WINDOW error=none$' "$LEM_YATH_VUNDO_REPORT" &&
     press_report F9 '^BOTTOM live=' &&
     grep -q '^BOTTOM live=yes buffer=yes same-window=no height=5 point=4:12 view=2:3 cursor-hidden=yes hscroll=7 session=closed tree=none diff=none$' \
       "$LEM_YATH_VUNDO_REPORT" &&
     press_report F2 '^ORIGIN ' && origin_restored AC; then
    pass prior-bottom-direct-delete 'direct deletion recreated the prior pane after freeing Vundo'
  else
    fail prior-bottom-direct-delete 'direct deletion dropped or corrupted the prior pane'
  fi
else
  fail prior-bottom-direct-delete 'could not install a pane for direct-delete coverage'
fi
press_report F10 '^BOTTOM cleared=yes$' || fail prior-bottom-clear 'could not clear recreated pane'

# Accept abandoned B, then ordinary u/C-r must follow that accepted branch.
send_keys Space u n
if press_report F2 '^ORIGIN '; then
  accept_record=$(last_report '^ORIGIN ')
  accept_point=$(report_field point "$accept_record")
  accept_view=$(report_field view "$accept_record")
fi
send_keys Enter
if press_report F2 '^ORIGIN ' &&
   [[ -n "$accept_point" && -n "$accept_view" &&
      "$accept_point" != "$entry_point" && "$accept_view" != "$entry_view" &&
      "$(last_report '^ORIGIN ')" == *'line40=AB '*"point=${accept_point} "*"view=${accept_view} "*'modified=yes '*'read-only=no '*'focus=origin' ]]; then
  pass accept-branch 'RET kept a demonstrably different preview location and restored source focus'
else
  fail accept-branch 'RET did not preserve the accepted B preview state'
fi

send_keys u
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=A '*'point=40:'*"view=${accept_view} "*'modified=no '*'read-only=no '*'focus=origin' ]]; then
  send_keys C-r
  if press_report F2 '^ORIGIN ' &&
     [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'point=40:'*"view=${accept_view} "*'modified=yes '*'read-only=no '*'focus=origin' ]]; then
    pass accepted-linear-undo 'ordinary u/C-r follows the accepted B branch'
  else
    fail accepted-linear-undo 'C-r did not redo accepted B'
  fi
else
  fail accepted-linear-undo 'u did not undo accepted B'
fi

# Saving a preview keeps Vundo open and records a real saved node.  l/r follow
# modification chronology across branches; a generic clean marker is not used.
send_keys Space u C-x C-s
if press_report F2 '^ORIGIN '; then
  saved_record=$(last_report '^ORIGIN ')
  saved_current=$(report_field current "$saved_record")
  saved_clean=$(report_field clean "$saved_record")
  saved_last=$(report_field saved "$saved_record")
fi
if [[ -n "${saved_current:-}" && "$saved_current" = "${saved_clean:-}" &&
      "$saved_current" = "${saved_last:-}" &&
      "$saved_record" == *'line40=AB '*'modified=no '*'read-only=yes '*'focus=vundo' &&
      "$(sed -n '40p' "$origin")" = AB ]]; then
  pass preview-save 'C-x C-s saved B without closing or unlocking Vundo'
else
  fail preview-save 'C-x C-s did not establish a live saved B node'
fi
send_keys l
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=A '*'focus=vundo' ]]; then
  pass saved-backward 'l reached the prior saved A node'
else
  fail saved-backward 'l did not move backward by saved-node chronology'
fi
send_keys r
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'focus=vundo' ]]; then
  pass saved-forward 'r reached saved B from A'
else
  fail saved-forward 'r did not move forward by saved-node chronology'
fi
send_keys b f
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'focus=vundo' ]]; then
  send_keys l
  if press_report F2 '^ORIGIN ' &&
     [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'focus=vundo' ]]; then
    pass saved-sibling 'l crossed from unsaved sibling C to saved sibling B'
  else
    fail saved-sibling 'l could not cross branches to saved B'
  fi
else
  fail saved-sibling 'could not establish sibling C before saved navigation'
fi

# Vundo switches to save-event chronology when the selected node is itself
# saved.  Re-saving the older A node must make l walk to the older B save event
# even though B has the newer modification ID; r then returns to re-saved A.
send_keys b C-x C-s
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=A '*'modified=no '*'focus=vundo' ]]; then
  send_keys l
  if press_report F2 '^ORIGIN ' &&
     [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'focus=vundo' ]]; then
    send_keys r
    if press_report F2 '^ORIGIN ' &&
       [[ "$(last_report '^ORIGIN ')" == *'line40=A '*'focus=vundo' ]]; then
      pass saved-event-order 'l/r followed out-of-modification-order save events'
    else
      fail saved-event-order 'r did not return to the newer A save event'
    fi
  else
    fail saved-event-order 'l ignored the older B save event from re-saved A'
  fi
else
  fail saved-event-order 'could not re-save the older A node'
fi

# Restore the B entry as the actual latest save before exercising q.
send_keys l C-x C-s
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'modified=no '*'focus=vundo' &&
      "$(sed -n '40p' "$origin")" = AB ]]; then
  pass saved-event-restore 're-saved B as the latest on-disk entry'
else
  fail saved-event-restore 'could not restore B as the latest save'
fi
send_keys q
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AB '*'modified=no '*'read-only=no '*"session=closed "*'focus=origin' ]]; then
  pass saved-quit 'q restored the saved B entry after cross-branch navigation'
else
  fail saved-quit 'q did not restore the saved B entry'
fi

# Add D beneath C so a/w/e have a real stem to traverse.
send_keys Space u b f Enter
send_keys A
send_literal D
send_keys Escape 1 2 0 G
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=ACD '*'modified=yes '*'focus=origin' ]]; then
  stem_entry=$(last_report '^ORIGIN ')
  stem_point=$(report_field point "$stem_entry")
  stem_view=$(report_field view "$stem_entry")
else
  fail stem-setup 'could not create D below C'
fi
send_keys Space u a
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'focus=vundo' ]]; then
  pass stem-root 'a moved from D to the C stem root'
else
  fail stem-root 'a did not find the current stem root'
fi
send_keys e
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=ACD '*'focus=vundo' ]]; then
  pass stem-end 'e moved from C to the D stem end'
else
  fail stem-end 'e did not find the current stem end'
fi
send_keys a b w
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'focus=vundo' ]]; then
  pass next-root 'w moved from A to the next C stem root'
else
  fail next-root 'w did not find the next stem root'
fi
send_keys q
if press_report F2 '^ORIGIN ' &&
   [[ -n "${stem_point:-}" && -n "${stem_view:-}" &&
      "$(last_report '^ORIGIN ')" == *'line40=ACD '*"point=${stem_point} "*"view=${stem_view} "*'focus=origin' ]]; then
  pass stem-quit 'q restored the distant D entry location after stem travel'
else
  fail stem-quit 'q did not restore D and its entry location'
fi
send_keys u
if press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=AC '*'modified=yes '*'focus=origin' ]]; then
  send_keys C-r
  if press_report F2 '^ORIGIN ' &&
     [[ "$(last_report '^ORIGIN ')" == *'line40=ACD '*'modified=yes '*'focus=origin' ]]; then
    pass stem-linear-undo 'ordinary u/C-r follows the accepted D stem'
  else
    fail stem-linear-undo 'C-r did not restore D'
  fi
else
  fail stem-linear-undo 'u did not undo D to C'
fi

# An after-save hook may destroy Vundo while save temporarily unlocks the
# source.  Cleanup rolls the AC preview back to the ACD entry, and the outer
# save unwind must not relock the now-closed buffer.
send_keys Space u b J C-x C-s
if grep -q '^ARM save-close=yes$' "$LEM_YATH_VUNDO_REPORT" &&
   press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=ACD '*'modified=yes '*'read-only=no '*'session=closed tree=none diff=none bottom=none '*'focus=origin' &&
      "$(sed -n '40p' "$origin")" = AC ]]; then
  pass save-hook-close 'after-save teardown restored the entry and left the source writable'
else
  fail save-hook-close 'after-save teardown relocked, leaked, or accepted the preview'
fi

# Force a real generation change behind the UI lock.  The next motion must
# reject the stale IDs, preserve the truthful edit, close cleanly, and leave a
# graph that can immediately be reopened and rolled back.
send_keys Space u G b
if grep -q '^STALE line40=ACDZ$' "$LEM_YATH_VUNDO_REPORT" &&
   press_report F2 '^ORIGIN ' &&
   [[ "$(last_report '^ORIGIN ')" == *'line40=ACDZ '*'read-only=no '*'session=closed tree=none diff=none bottom=none '*'focus=origin' ]]; then
  send_keys Space u b q
  if press_report F2 '^ORIGIN ' &&
     [[ "$(last_report '^ORIGIN ')" == *'line40=ACDZ '*'read-only=no '*'session=closed tree=none diff=none bottom=none '*'focus=origin' ]]; then
    send_keys u
    if press_report F2 '^ORIGIN ' &&
       [[ "$(last_report '^ORIGIN ')" == *'line40=ACD '*read-only=no*'focus=origin' ]]; then
      pass stale-ui-recovery 'stale generation closed truthfully and the recovered graph reopened'
    else
      fail stale-ui-recovery 'ordinary undo could not remove the stale-edit descendant'
    fi
  else
    fail stale-ui-recovery 'the recovered undo graph could not reopen and roll back'
  fi
else
  fail stale-ui-recovery 'stale generation lost the edit, lock, or UI cleanup'
fi

# Killing the origin while vundo owns the bottom pane must close both safely.
send_keys Space u
if press_report F6 '^KILL ' &&
   grep -q '^KILL origin=deleted view=deleted bottom=none focus-left=yes$' \
     "$LEM_YATH_VUNDO_REPORT"; then
  pass origin-kill-cleanup 'origin deletion released the view, pane, and focus'
else
  fail origin-kill-cleanup 'origin deletion leaked the view or pane'
fi

printf '\n'
cat "$LEM_YATH_VUNDO_REPORT"
if ((failed)); then
  printf 'VUNDO TEST FAILED\n'
  exit 1
fi
printf 'VUNDO TEST PASSED\n'
