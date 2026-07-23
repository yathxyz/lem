#!/usr/bin/env bash
# Native Org mode and Evil-Org parity tests through the real ncurses editor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_ORG_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR"

fixture="$root/work/fixture.org"
target="$root/work/target.org"
other="$root/work/other.org"
eof_fixture="$root/work/eof.org"
edge_fixture="$root/work/edge.org"
fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-fixture.lisp")"

write_fixture() {
  printf '%s\n' \
    '#+title: Org fixture' \
    '' \
    '* TODO Parent :work:' \
    ':PROPERTIES:' \
    ':ID: 11111111-1111-4111-8111-111111111111' \
    ':END:' \
    'SCHEDULED: <2026-07-12 Sun>' \
    'Parent body sentinel with *bold* and /italic/.' \
    'Parent second prose line.' \
    '  indented prose sentinel' \
    '** NEXT Child' \
    'Child body sentinel.' \
    '*** Grandchild' \
    'Grand body sentinel.' \
    '* Sibling' \
    'Sibling body sentinel and [[file:target.org][target]].' \
    '' \
    '- [ ] first' \
    '  - nested child sentinel' \
    '- [X] second' \
    '  - second nested sentinel' \
    '' \
    '| name  | value |' \
    '|-------+-------|' \
    '| alpha | beta  |' \
    '| omega | theta |' \
    '' \
    '#+begin_src python' \
    "print('hello')" \
    '#+end_src' \
    '' \
    '  | nested| cell |' \
    '  |-------+------|' \
    '' \
    '|---+-----|' \
    >"$fixture"
  printf '%s\n' 'TARGET FILE SENTINEL' >"$target"
  printf '%s\n' '* Other' 'Other body sentinel.' >"$other"
  printf '%s' '* Tail' >"$eof_fixture"
  printf '%s\n' \
    '* Edge cases' \
    '  - parent' \
    '    - child-a' \
    '    - child-b' \
    '' \
    '- star parent' \
    '  * star child' \
    '' \
    '- tab parent' \
    $'\t- tab child' \
    '' \
    $'-\twide parent' \
    '- wide child' \
    '' \
    '- body item' \
    '  continuation sentinel' \
    '- body next' \
    '' \
    '1. ordered one' \
    '2. ordered two' \
    '' \
    '- separate a' \
    '' \
    '' \
    '- separate b' \
    '' \
    '#+begin_src text' \
    '- source list lookalike' \
    '  - indented source list lookalike' \
    '| source | table |' \
    '#+end_src' \
    '' \
    '#+begin_src text' \
    '#+end_quote' \
    '- mismatched source list' \
    '| mismatched | source |' \
    '#+end_src' \
    '' \
    '* Source owner' \
    '#+begin_src text' \
    '* source fake heading' \
    '#+end_src' \
    '** Source real child' \
    '* Source sibling' \
    '' \
    '#+begin_src text' \
    '#+begin_quote' \
    '* source fake after unmatched begin' \
    '#+end_src' \
    '* Real after literal begin' \
    '' \
    '| formula | middle | result |' \
    '| 1       | 2      | 3      |' \
    '| 4       | 5      | 6      |' \
    '#+TBLFM: $2=$1+$3::@1$3=@2$1::@2$2=remote(foo,$2)+$3' \
    '' \
    '| range column | range result |' \
    '| 1            | 2      |' \
    '#+TBLFM: $1..$2=$1' \
    '' \
    '| range row first  | 1 |' \
    '| range row second | 2 |' \
    '#+TBLFM: @1$1..@2$1=$2' \
    '' \
    '| spaced formula | result |' \
    '| 3              | 4      |' \
    '' \
    '#+TBLFM: $2=$1' \
    '' \
    '| value |' \
    '| -     |' \
    '|       |' \
    '' \
    'CLOCK: [2026-07-12 Sun 10:00]--[2026-07-12 Sun 11:00] =>  1:00' \
    '' \
    '| only |' \
    '' \
    '| disposable |' \
    'AFTER SINGLE ROW' \
    >"$edge_fixture"
}

SESSIONS=()
FAILED=0

cleanup() {
  for session in "${SESSIONS[@]:-}"; do
    [ -n "$session" ] && lem_stop "$session"
  done
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }
fail() {
  FAILED=1
  printf 'FAIL  %-26s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

start_org() {
  local label="$1" session="lem-org-$1-$id"
  : >"$LEM_YATH_ORG_REPORT"
  SESSIONS+=("$session")
  lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"
  if ! lem_wait_for "$session" 'Parent body sentinel' 40 >/dev/null; then
    fail "$label" "fixture did not open" "$session"
    return 1
  fi
  sleep 0.5
  tmux_cmd send-keys -t "$session" Escape
  sleep 0.25
  ORG_SESSION="$session"
}

mx() {
  local session="$1" command="$2" index
  tmux_cmd send-keys -t "$session" Escape Escape
  sleep 0.5
  wait_screen_absent "$session" 'Command:' 5 || return 1
  tmux_cmd send-keys -t "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  for ((index = 0; index < ${#command}; index++)); do
    tmux_cmd send-keys -t "$session" -l -- "${command:index:1}"
    sleep 0.03
  done
  lem_wait_for "$session" "Command: ${command}" 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" Enter
  wait_screen_absent "$session" 'Command:' 10 || return 1
  sleep 0.25
}

wait_screen_absent() {
  local session="$1" pattern="$2" timeout="${3:-10}" attempts=0
  while ((attempts < timeout * 4)); do
    if ! lem_capture "$session" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

wait_report() {
  local pattern="$1" i
  for i in $(seq 1 80); do
    grep -qE "$pattern" "$LEM_YATH_ORG_REPORT" && return 0
    sleep 0.1
  done
  return 1
}

context_report() {
  : >"$LEM_YATH_ORG_REPORT"
  mx "$ORG_SESSION" lem-yath-test-org-context-report || return 1
  grep '^CONTEXT ' "$LEM_YATH_ORG_REPORT" | tail -n1
}

context_hash() {
  sed -n 's/^CONTEXT hash=\([^ ]*\).*/\1/p' <<<"$1"
}

formula_report() {
  : >"$LEM_YATH_ORG_REPORT"
  mx "$ORG_SESSION" lem-yath-test-org-formula-report || return 1
  grep '^FORMULA ' "$LEM_YATH_ORG_REPORT" | tail -n1
}

screen_has() { lem_capture "$1" | grep -qE "$2"; }
screen_lacks() { ! lem_capture "$1" | grep -qE "$2"; }

write_fixture

# 01: real mode selection, semantic parser, prose UI, and negative Evil keys.
if start_org static; then
  mx "$ORG_SESSION" lem-yath-test-org-static-report
  if wait_report '^STATIC mode=ORG-MODE programming=no heading=DOCUMENT-HEADER1-ATTRIBUTE todo=ORG-TODO-ATTRIBUTE drawer=DOCUMENT-METADATA-ATTRIBUTE timestamp=ORG-TIMESTAMP-ATTRIBUTE table=DOCUMENT-TABLE-ATTRIBUTE link=DOCUMENT-LINK-ATTRIBUTE source=DOCUMENT-CODE-BLOCK-ATTRIBUTE$' &&
     wait_report '^KEYS tab-org=yes zero-org=yes end-org=yes I-org=yes A-org=yes t-todo=no T-todo=no return-org=no c-return-org=yes cs-return-org=yes m-o-other=yes$' &&
     screen_has "$ORG_SESSION" 'Org'; then
    pass static "Org mode, semantic faces, and active Evil key-theme boundaries match"
  else
    fail static "mode, attributes, or effective keymaps differed" "$ORG_SESSION"
    cat "$LEM_YATH_ORG_REPORT"
  fi
fi

# 02: local folding, atomic visible movement, reveal, and byte preservation.
if [ -n "${ORG_SESSION:-}" ]; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  sleep 0.4
  folded_ok=0
  if screen_has "$ORG_SESSION" 'Parent.*\[\.\.\.\]' &&
     screen_lacks "$ORG_SESSION" 'Parent body sentinel' &&
     screen_lacks "$ORG_SESSION" 'Child body sentinel' &&
     screen_has "$ORG_SESSION" 'Sibling body sentinel'; then
    folded_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" 9 9 j
  sleep 0.3
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  atomic_ok=0
  wait_report 'POINT .*text="\* TODO Parent :work:" hidden=no modified=no folds=1' &&
    atomic_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" j
  sleep 0.3
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  visible_move_ok=0
  wait_report 'POINT .*text="\* Sibling" hidden=no modified=no folds=1' &&
    visible_move_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-sibling
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  sleep 0.3
  tmux_cmd send-keys -t "$ORG_SESSION" 9 9 j
  sleep 0.3
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  folded_tail_ok=0
  wait_report 'POINT .*text="\* Sibling" hidden=no modified=no folds=2' &&
    folded_tail_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  sleep 0.2
  mx "$ORG_SESSION" lem-yath-test-org-goto-grand-body
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  reveal_ok=0
  if wait_report 'POINT .*text="Grand body sentinel\." hidden=no modified=no folds=0' &&
     screen_has "$ORG_SESSION" 'Grand body sentinel'; then
    reveal_ok=1
  fi
  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  sleep 0.3
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  sleep 0.3
  children_ok=0
  if screen_has "$ORG_SESSION" 'NEXT Child' &&
     screen_lacks "$ORG_SESSION" 'Parent body sentinel' &&
     screen_lacks "$ORG_SESSION" 'Grand body sentinel'; then
    children_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  sleep 0.3
  subtree_ok=0
  screen_has "$ORG_SESSION" 'Parent body sentinel' &&
    screen_has "$ORG_SESSION" 'Grand body sentinel' && subtree_ok=1
  if [ "$folded_ok" = 1 ] && [ "$atomic_ok" = 1 ] &&
     [ "$visible_move_ok" = 1 ] && [ "$folded_tail_ok" = 1 ] &&
     [ "$reveal_ok" = 1 ] && [ "$children_ok" = 1 ] &&
     [ "$subtree_ok" = 1 ] &&
     grep -q 'Parent body sentinel' "$fixture"; then
    pass folding "TAB, atomic visible motion, folded tails, and generic reveal are safe"
  else
    fail folding "fold state, movement, reveal, or byte preservation failed" "$ORG_SESSION"
    cat "$LEM_YATH_ORG_REPORT"
  fi
fi

# 03: Shift-Tab cycles overview, contents, and all even from body text.
if [ -n "${ORG_SESSION:-}" ]; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-parent-body
  tmux_cmd send-keys -t "$ORG_SESSION" BTab
  sleep 0.3
  overview_ok=0
  if screen_has "$ORG_SESSION" 'TODO Parent' &&
     screen_has "$ORG_SESSION" 'Sibling' &&
     screen_lacks "$ORG_SESSION" 'NEXT Child' &&
     screen_lacks "$ORG_SESSION" 'Parent body sentinel'; then
    overview_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" BTab
  sleep 0.3
  contents_ok=0
  if screen_has "$ORG_SESSION" 'NEXT Child' &&
     screen_has "$ORG_SESSION" 'Grandchild' &&
     screen_lacks "$ORG_SESSION" 'Parent body sentinel' &&
     screen_lacks "$ORG_SESSION" 'Grand body sentinel'; then
    contents_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" BTab
  sleep 0.3
  all_ok=0
  screen_has "$ORG_SESSION" 'Parent body sentinel' &&
    screen_has "$ORG_SESSION" 'Grand body sentinel' && all_ok=1
  if [ "$overview_ok" = 1 ] && [ "$contents_ok" = 1 ] &&
     [ "$all_ok" = 1 ]; then
    pass global-fold "Shift-Tab cycles overview/contents/all from body text"
  else
    fail global-fold "global visibility cycle self-cleared or hid the wrong lines" "$ORG_SESSION"
  fi
fi

# 04: heading insertion is structurally safe before siblings and at EOF.
if [ -n "${ORG_SESSION:-}" ]; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  tmux_cmd send-keys -t "$ORG_SESSION" M-Enter
  sleep 0.2
  tmux_cmd send-keys -t "$ORG_SESSION" -l 'Inserted'
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.3
  inserted_line=$(lem_capture "$ORG_SESSION" | grep -n 'Inserted$' | head -n1 | cut -d: -f1)
  sibling_heading_line=$(lem_capture "$ORG_SESSION" | grep -n 'Sibling$' | head -n1 | cut -d: -f1)
  before_sibling_ok=0
  [ -n "$inserted_line" ] && [ -n "$sibling_heading_line" ] &&
    [ "$inserted_line" -lt "$sibling_heading_line" ] &&
    screen_lacks "$ORG_SESSION" 'Inserted.*Sibling' && before_sibling_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-eof-heading-report
  eof_ok=0
  wait_report '^EOF text="\* Tail\|\* After"$' && eof_ok=1
  if [ "$before_sibling_ok" = 1 ] && [ "$eof_ok" = 1 ]; then
    pass headings "M-Return and EOF insertion create separate complete headings"
  else
    fail headings "heading insertion concatenated text or misplaced point" "$ORG_SESSION"
  fi
fi

# 05: every configured TODO state is saved immediately, including nil.
if [ -n "${ORG_SESSION:-}" ]; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  todo_ok=1
  for state in NEXT WAITING HOLD SOMEDAY DONE CANCELLED NONE TODO; do
    tmux_cmd send-keys -t "$ORG_SESSION" C-c C-t
    state_ok=0
    for _ in $(seq 1 50); do
      if [ "$state" = NONE ]; then
        grep -q '^\* Parent :work:$' "$fixture" && { state_ok=1; break; }
      else
        grep -q "^\\* $state Parent :work:\$" "$fixture" &&
          { state_ok=1; break; }
      fi
      sleep 0.1
    done
    if [ "$state_ok" != 1 ]; then
      todo_ok=0
      break
    fi
  done
  if [ "$todo_ok" = 1 ] && ! grep -q '^CLOSED:' "$fixture"; then
    pass todo "C-c C-t persists the complete TODO sequence without CLOSED metadata"
  else
    fail todo "the configured TODO sequence diverged on disk at $state" "$ORG_SESSION"
  fi
fi

# 06: reload is idempotent and killing one Org buffer preserves another fold.
if [ -n "${ORG_SESSION:-}" ]; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  mx "$ORG_SESSION" lem-yath-test-org-reload-report
  reload_ok=0
  wait_report '^RELOAD post=1 change=1 kill=1 association=1 folds=0 tab=yes$' &&
    reload_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-kill-cleanup-report
  kill_ok=0
  wait_report '^KILL current=yes survivor-folds=1 victim-live=no$' && kill_ok=1
  if [ "$reload_ok" = 1 ] && [ "$kill_ok" = 1 ]; then
    pass lifecycle "reload deduplicates state and kill cleanup is buffer-local"
  else
    fail lifecycle "reload or multi-buffer kill cleanup diverged" "$ORG_SESSION"
    cat "$LEM_YATH_ORG_REPORT"
  fi
fi

# 07: Org-aware O/o target new checklist items; the stock chord toggles.
write_fixture
if start_org lists; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-list
  tmux_cmd send-keys -t "$ORG_SESSION" O
  sleep 0.2
  tmux_cmd send-keys -t "$ORG_SESSION" -l 'above item'
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.3
  above_line=$(lem_capture "$ORG_SESSION" | grep -n 'above item$' | head -n1 | cut -d: -f1)
  first_line=$(lem_capture "$ORG_SESSION" | grep -n 'first$' | head -n1 | cut -d: -f1)
  above_ok=0
  [ -n "$above_line" ] && [ -n "$first_line" ] &&
    [ "$above_line" -lt "$first_line" ] && above_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-list
  tmux_cmd send-keys -t "$ORG_SESSION" o
  sleep 0.2
  tmux_cmd send-keys -t "$ORG_SESSION" -l 'new child'
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.3
  continuation_ok=0
  screen_has "$ORG_SESSION" 'new child$' && continuation_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-list
  tmux_cmd send-keys -t "$ORG_SESSION" C-c C-x C-b
  sleep 0.3
  toggle_ok=0
  screen_has "$ORG_SESSION" '☑.*first$' && toggle_ok=1
  if [ "$above_ok" = 1 ] && [ "$continuation_ok" = 1 ] &&
     [ "$toggle_ok" = 1 ]; then
    pass lists "O/o edit the new checklist item and C-c C-x C-b toggles it"
  else
    fail lists "list insertion target, continuation, or checkbox toggle failed" "$ORG_SESSION"
  fi
fi

# 08: table O/TAB target cells; indentation and hline-only tables survive.
if [ -n "${ORG_SESSION:-}" ]; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-table
  tmux_cmd send-keys -t "$ORG_SESSION" O
  sleep 0.2
  tmux_cmd send-keys -t "$ORG_SESSION" -l gamma
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.3
  gamma_line=$(lem_capture "$ORG_SESSION" | grep -n 'gamma' | head -n1 | cut -d: -f1)
  alpha_line=$(lem_capture "$ORG_SESSION" | grep -n 'alpha' | head -n1 | cut -d: -f1)
  above_row_ok=0
  [ -n "$gamma_line" ] && [ -n "$alpha_line" ] &&
    [ "$gamma_line" -lt "$alpha_line" ] && above_row_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-table
  tmux_cmd send-keys -t "$ORG_SESSION" Tab
  sleep 0.3
  tmux_cmd send-keys -t "$ORG_SESSION" i
  tmux_cmd send-keys -t "$ORG_SESSION" -l X
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.3
  advance_ok=0
  screen_has "$ORG_SESSION" 'alpha[[:space:]]+│ Xbeta[[:space:]]+│' &&
    advance_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-indented-table
  tmux_cmd send-keys -t "$ORG_SESSION" C-c C-c
  sleep 0.3
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  indentation_ok=0
  grep -qF 'text="  | nested' "$LEM_YATH_ORG_REPORT" && indentation_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-hline-only
  tmux_cmd send-keys -t "$ORG_SESSION" C-c C-c
  sleep 0.3
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  hline_ok=0
  grep -qF 'text="|---+-----|"' "$LEM_YATH_ORG_REPORT" && hline_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-table-hline-second
  tmux_cmd send-keys -t "$ORG_SESSION" BTab
  sleep 0.3
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  hline_previous_ok=0
  grep -qF 'column=10 text="| name  | value |"' \
    "$LEM_YATH_ORG_REPORT" && hline_previous_ok=1
  if [ "$above_row_ok" = 1 ] && [ "$advance_ok" = 1 ] &&
     [ "$indentation_ok" = 1 ] && [ "$hline_ok" = 1 ] &&
     [ "$hline_previous_ok" = 1 ]; then
    pass table "O/TAB target new cells and alignment preserves table structure"
  else
    fail table "row target, cell movement, indentation, or hline handling failed" "$ORG_SESSION"
    printf 'table flags above=%s advance=%s indentation=%s hline=%s previous=%s\n' \
      "$above_row_ok" "$advance_ok" "$indentation_ok" "$hline_ok" \
      "$hline_previous_ok"
  fi
fi

# 09: relative file links resolve from the Org buffer's directory.
if [ -n "${ORG_SESSION:-}" ]; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-link
  tmux_cmd send-keys -t "$ORG_SESSION" C-c C-o
  if lem_wait_for "$ORG_SESSION" 'TARGET FILE SENTINEL' 10 >/dev/null; then
    pass links "C-c C-o opened a relative file link"
  else
    fail links "relative link did not open its target" "$ORG_SESSION"
  fi
fi

# 10: the active additional theme dispatches by Org context and exact scope.
if start_org structure; then
  baseline_report=$(context_report)
  baseline_hash=$(context_hash "$baseline_report")

  # Lowercase horizontal Meta changes only the current heading.
  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  tmux_cmd send-keys -t "$ORG_SESSION" M-l
  sleep 0.3
  heading_local_report=$(context_report)
  heading_local_ok=0
  grep -q ' levels=2,2,3 ' <<<"$heading_local_report" && heading_local_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-h
  sleep 0.3
  heading_local_restore=$(context_report)
  heading_local_restore_ok=0
  [ "$(context_hash "$heading_local_restore")" = "$baseline_hash" ] &&
    heading_local_restore_ok=1

  # Uppercase horizontal Meta changes the complete subtree.
  tmux_cmd send-keys -t "$ORG_SESSION" M-L
  sleep 0.3
  heading_tree_report=$(context_report)
  heading_tree_ok=0
  grep -q ' levels=2,3,4 ' <<<"$heading_tree_report" && heading_tree_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-H
  sleep 0.3
  heading_tree_restore=$(context_report)
  heading_tree_restore_ok=0
  [ "$(context_hash "$heading_tree_restore")" = "$baseline_hash" ] &&
    heading_tree_restore_ok=1

  # Lowercase vertical Meta moves a complete heading subtree.
  tmux_cmd send-keys -t "$ORG_SESSION" M-j
  sleep 0.3
  heading_move_report=$(context_report)
  heading_move_ok=0
  heading_lines=$(sed -n 's/.* headings=\([^ ]*\).*/\1/p' \
    <<<"$heading_move_report")
  IFS=',' read -r parent_line child_line grand_line sibling_line \
    <<<"$heading_lines"
  [ "$sibling_line" -lt "$parent_line" ] &&
    [ "$parent_line" -lt "$child_line" ] &&
    [ "$child_line" -lt "$grand_line" ] && heading_move_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-k
  sleep 0.3
  heading_move_restore=$(context_report)
  heading_move_restore_ok=0
  [ "$(context_hash "$heading_move_restore")" = "$baseline_hash" ] &&
    heading_move_restore_ok=1

  # List indentation is local and leaves the item's child at its old depth.
  mx "$ORG_SESSION" lem-yath-test-org-goto-second-list
  tmux_cmd send-keys -t "$ORG_SESSION" M-l
  sleep 0.3
  list_local_report=$(context_report)
  list_local_ok=0
  grep -qE ' lists=[0-9]+/0,[0-9]+/2,[0-9]+/2,[0-9]+/2 ' \
    <<<"$list_local_report" && list_local_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-h
  sleep 0.3
  list_local_restore=$(context_report)
  list_local_restore_ok=0
  [ "$(context_hash "$list_local_restore")" = "$baseline_hash" ] &&
    list_local_restore_ok=1

  # Moving an item carries its complete item tree and reverses exactly.
  mx "$ORG_SESSION" lem-yath-test-org-goto-list
  tmux_cmd send-keys -t "$ORG_SESSION" M-j
  sleep 0.3
  list_move_report=$(context_report)
  list_move_ok=0
  list_fields=$(sed -n 's/.* lists=\([^ ]*\) table=.*/\1/p' \
    <<<"$list_move_report")
  IFS=',/' read -r first_line first_indent first_child_line first_child_indent \
    second_line second_indent second_child_line second_child_indent \
    <<<"$list_fields"
  [ "$second_line" -lt "$second_child_line" ] &&
    [ "$second_child_line" -lt "$first_line" ] &&
    [ "$first_line" -lt "$first_child_line" ] && list_move_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-k
  sleep 0.3
  list_move_restore=$(context_report)
  list_move_restore_ok=0
  [ "$(context_hash "$list_move_restore")" = "$baseline_hash" ] &&
    list_move_restore_ok=1

  # Uppercase horizontal Meta indents the list item and its child together.
  mx "$ORG_SESSION" lem-yath-test-org-goto-second-list
  tmux_cmd send-keys -t "$ORG_SESSION" M-L
  sleep 0.3
  list_tree_report=$(context_report)
  list_tree_ok=0
  grep -qE ' lists=[0-9]+/0,[0-9]+/2,[0-9]+/2,[0-9]+/4 ' \
    <<<"$list_tree_report" && list_tree_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-H
  sleep 0.3
  list_tree_restore=$(context_report)
  list_tree_restore_ok=0
  [ "$(context_hash "$list_tree_restore")" = "$baseline_hash" ] &&
    list_tree_restore_ok=1

  # Tables route horizontal keys to columns and vertical keys to rows.
  mx "$ORG_SESSION" lem-yath-test-org-goto-table
  tmux_cmd send-keys -t "$ORG_SESSION" M-l
  sleep 0.3
  table_column_report=$(context_report)
  table_column_ok=0
  if grep -qF 'header="| value | name  |"' <<<"$table_column_report" &&
     grep -qF 'alpha="| beta  | alpha |"' <<<"$table_column_report" &&
     grep -qF 'omega="| theta | omega |"' <<<"$table_column_report"; then
    table_column_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" M-h
  sleep 0.3
  table_column_restore=$(context_report)
  table_column_restore_ok=0
  [ "$(context_hash "$table_column_restore")" = "$baseline_hash" ] &&
    table_column_restore_ok=1

  tmux_cmd send-keys -t "$ORG_SESSION" M-j
  sleep 0.3
  table_row_report=$(context_report)
  table_row_ok=0
  omega_line=$(sed -n 's/.* omega="[^"]*"\/\([0-9]*\).*/\1/p' \
    <<<"$table_row_report")
  alpha_line=$(sed -n 's/.* alpha="[^"]*"\/\([0-9]*\).*/\1/p' \
    <<<"$table_row_report")
  [ -n "$omega_line" ] && [ -n "$alpha_line" ] &&
    [ "$omega_line" -lt "$alpha_line" ] && table_row_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-k
  sleep 0.3
  table_row_restore=$(context_report)
  table_row_restore_ok=0
  [ "$(context_hash "$table_row_restore")" = "$baseline_hash" ] &&
    table_row_restore_ok=1

  # A plus sign is a field boundary while point is on a horizontal rule.
  mx "$ORG_SESSION" lem-yath-test-org-goto-table-hline-second
  tmux_cmd send-keys -t "$ORG_SESSION" M-h
  sleep 0.3
  table_hline_move_report=$(context_report)
  table_hline_move_ok=0
  if grep -qF 'header="| value | name  |"' <<<"$table_hline_move_report" &&
     grep -qF 'alpha="| beta  | alpha |"' <<<"$table_hline_move_report" &&
     grep -qF 'omega="| theta | omega |"' <<<"$table_hline_move_report"; then
    table_hline_move_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" M-l
  sleep 0.3
  table_hline_move_restore=$(context_report)
  table_hline_move_restore_ok=0
  [ "$(context_hash "$table_hline_move_restore")" = "$baseline_hash" ] &&
    table_hline_move_restore_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-table-hline-second
  tmux_cmd send-keys -t "$ORG_SESSION" M-H
  sleep 0.3
  table_hline_delete_report=$(context_report)
  table_hline_delete_ok=0
  if grep -q ' table=4/1 ' <<<"$table_hline_delete_report" &&
     grep -qF 'header="| name  |"' <<<"$table_hline_delete_report" &&
     grep -qF 'alpha="| alpha |"' <<<"$table_hline_delete_report" &&
     grep -qF 'omega="| omega |"' <<<"$table_hline_delete_report"; then
    table_hline_delete_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" u
  sleep 0.3
  table_hline_delete_restore=$(context_report)
  table_hline_delete_restore_ok=0
  [ "$(context_hash "$table_hline_delete_restore")" = "$baseline_hash" ] &&
    table_hline_delete_restore_ok=1

  # Uppercase table commands insert/delete columns and rows at point.
  mx "$ORG_SESSION" lem-yath-test-org-goto-table-hline-second
  tmux_cmd send-keys -t "$ORG_SESSION" M-L
  sleep 0.3
  table_insert_column_report=$(context_report)
  table_insert_column_ok=0
  grep -q ' table=4/3 ' <<<"$table_insert_column_report" &&
    grep -qF 'alpha="| alpha |   | beta  |"' \
      <<<"$table_insert_column_report" && table_insert_column_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-H
  sleep 0.3
  table_insert_column_restore=$(context_report)
  table_insert_column_restore_ok=0
  [ "$(context_hash "$table_insert_column_restore")" = "$baseline_hash" ] &&
    table_insert_column_restore_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-table-hline-second
  tmux_cmd send-keys -t "$ORG_SESSION" j
  tmux_cmd send-keys -t "$ORG_SESSION" M-K
  sleep 0.3
  table_delete_row_report=$(context_report)
  table_delete_row_ok=0
  grep -q ' table=3/2 ' <<<"$table_delete_row_report" &&
    grep -qF 'alpha="MISSING"/0' <<<"$table_delete_row_report" &&
    table_delete_row_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" u
  sleep 0.3
  table_delete_row_restore=$(context_report)
  table_delete_row_restore_ok=0
  [ "$(context_hash "$table_delete_row_restore")" = "$baseline_hash" ] &&
    table_delete_row_restore_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-table
  tmux_cmd send-keys -t "$ORG_SESSION" M-J
  sleep 0.3
  table_insert_row_report=$(context_report)
  table_insert_row_ok=0
  grep -q ' table=5/2 ' <<<"$table_insert_row_report" &&
    table_insert_row_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" u
  sleep 0.3
  table_insert_row_restore=$(context_report)
  table_insert_row_restore_ok=0
  [ "$(context_hash "$table_insert_row_restore")" = "$baseline_hash" ] &&
    table_insert_row_restore_ok=1

  prose_safe_ok=0
  prose_line_ok=0
  prose_line_restore_ok=0
  # Ordinary prose falls back to word motion and never edits its heading.
  if start_org structure-prose; then
    prose_baseline_report=$(context_report)
    prose_baseline_hash=$(context_hash "$prose_baseline_report")
    mx "$ORG_SESSION" lem-yath-test-org-goto-parent-body
    tmux_cmd send-keys -t "$ORG_SESSION" M-l
    sleep 0.2
    prose_motion_report=$(context_report)
    grep -q 'point="Parent body sentinel.*"/6 modified=no$' \
      <<<"$prose_motion_report" &&
      [ "$(context_hash "$prose_motion_report")" = "$prose_baseline_hash" ] &&
      prose_safe_ok=1

    tmux_cmd send-keys -t "$ORG_SESSION" M-J
    sleep 0.3
    prose_line_report=$(context_report)
    prose_lines=$(sed -n 's/.* prose=\([^ ]*\).*/\1/p' \
      <<<"$prose_line_report")
    IFS=',' read -r prose_one_line prose_two_line <<<"$prose_lines"
    [ "$prose_two_line" -lt "$prose_one_line" ] && prose_line_ok=1
    tmux_cmd send-keys -t "$ORG_SESSION" M-K
    sleep 0.3
    prose_line_restore=$(context_report)
    [ "$(context_hash "$prose_line_restore")" = "$prose_baseline_hash" ] &&
      prose_line_restore_ok=1
  fi

  if [ "$heading_local_ok" = 1 ] && [ "$heading_local_restore_ok" = 1 ] &&
     [ "$heading_tree_ok" = 1 ] && [ "$heading_tree_restore_ok" = 1 ] &&
     [ "$heading_move_ok" = 1 ] && [ "$heading_move_restore_ok" = 1 ] &&
     [ "$list_local_ok" = 1 ] && [ "$list_local_restore_ok" = 1 ] &&
     [ "$list_move_ok" = 1 ] && [ "$list_move_restore_ok" = 1 ] &&
     [ "$list_tree_ok" = 1 ] && [ "$list_tree_restore_ok" = 1 ] &&
     [ "$table_column_ok" = 1 ] && [ "$table_column_restore_ok" = 1 ] &&
     [ "$table_row_ok" = 1 ] && [ "$table_row_restore_ok" = 1 ] &&
     [ "$table_hline_move_ok" = 1 ] &&
     [ "$table_hline_move_restore_ok" = 1 ] &&
     [ "$table_hline_delete_ok" = 1 ] &&
     [ "$table_hline_delete_restore_ok" = 1 ] &&
     [ "$table_insert_column_ok" = 1 ] &&
     [ "$table_insert_column_restore_ok" = 1 ] &&
     [ "$table_delete_row_ok" = 1 ] &&
     [ "$table_delete_row_restore_ok" = 1 ] &&
     [ "$table_insert_row_ok" = 1 ] &&
     [ "$table_insert_row_restore_ok" = 1 ] &&
     [ "$prose_safe_ok" = 1 ] && [ "$prose_line_ok" = 1 ] &&
     [ "$prose_line_restore_ok" = 1 ]; then
    pass structure "Meta keys dispatch safely across headings, lists, tables, and prose"
  else
    fail structure "one or more context-specific structural operations differed" "$ORG_SESSION"
    printf '%s\n' \
      "$heading_local_report" "$heading_local_restore" \
      "$heading_tree_report" "$heading_tree_restore" \
      "$heading_move_report" "$heading_move_restore" \
      "$list_local_report" "$list_local_restore" \
      "$list_move_report" "$list_move_restore" \
      "$list_tree_report" "$list_tree_restore" \
      "$table_column_report" "$table_column_restore" \
      "$table_row_report" "$table_row_restore" \
      "$table_hline_move_report" "$table_hline_move_restore" \
      "$table_hline_delete_report" "$table_hline_delete_restore" \
      "$table_insert_column_report" "$table_insert_column_restore" \
      "$table_delete_row_report" "$table_delete_row_restore" \
      "$table_insert_row_report" "$table_insert_row_restore" \
      "${prose_motion_report:-}" "${prose_line_report:-}" \
      "${prose_line_restore:-}"
    cat "$LEM_YATH_ORG_REPORT"
  fi
fi

# 11: incomplete rich semantics fail closed instead of corrupting structure.
if start_org structure-edge; then
  mx "$ORG_SESSION" lem-yath-test-org-open-edge
  edge_baseline_report=$(context_report)
  edge_baseline_hash=$(context_hash "$edge_baseline_report")

  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-child-b
  tmux_cmd send-keys -t "$ORG_SESSION" M-h
  sleep 0.3
  nested_outdent_report=$(context_report)
  nested_outdent_ok=0
  grep -q 'point="  - child-b"/' <<<"$nested_outdent_report" &&
    [ "$(context_hash "$nested_outdent_report")" != "$edge_baseline_hash" ] &&
    nested_outdent_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-l
  sleep 0.3
  nested_restore_report=$(context_report)
  nested_restore_ok=0
  [ "$(context_hash "$nested_restore_report")" = "$edge_baseline_hash" ] &&
    nested_restore_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-star-child
  tmux_cmd send-keys -t "$ORG_SESSION" M-h
  sleep 0.3
  star_outdent_report=$(context_report)
  star_outdent_ok=0
  grep -q 'point="- star child"/' <<<"$star_outdent_report" &&
    star_outdent_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" u
  sleep 0.3
  star_restore_report=$(context_report)
  star_restore_ok=0
  [ "$(context_hash "$star_restore_report")" = "$edge_baseline_hash" ] &&
    star_restore_ok=1

  # Real subtree edits ignore source-block heading lookalikes entirely.
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-source-owner
  tmux_cmd send-keys -t "$ORG_SESSION" M-L
  sleep 0.3
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-source-fake-heading
  source_fake_report=$(context_report)
  source_fake_ok=0
  grep -q 'point="\* source fake heading"/0' <<<"$source_fake_report" &&
    source_fake_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-source-real-child
  source_real_child_report=$(context_report)
  source_real_child_ok=0
  grep -q 'point="\*\*\* Source real child"/0' \
    <<<"$source_real_child_report" && source_real_child_ok=1
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-source-owner
  tmux_cmd send-keys -t "$ORG_SESSION" M-H
  sleep 0.3
  source_subtree_restore=$(context_report)
  source_subtree_restore_ok=0
  [ "$(context_hash "$source_subtree_restore")" = "$edge_baseline_hash" ] &&
    source_subtree_restore_ok=1

  # A literal unmatched begin marker in source content must not hide the
  # first real heading after the source block.
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-real-after-literal-begin
  tmux_cmd send-keys -t "$ORG_SESSION" M-l
  sleep 0.3
  real_after_literal_report=$(context_report)
  real_after_literal_ok=0
  grep -q 'point="\*\* Real after literal begin"/1' \
    <<<"$real_after_literal_report" && real_after_literal_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" M-h
  sleep 0.3
  real_after_literal_restore=$(context_report)
  real_after_literal_restore_ok=0
  [ "$(context_hash "$real_after_literal_restore")" = \
    "$edge_baseline_hash" ] && real_after_literal_restore_ok=1

  # Dash-only and empty cells are data rows, not horizontal rules.
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-sparse-data
  tmux_cmd send-keys -t "$ORG_SESSION" C-c C-c
  sleep 0.3
  sparse_data_report=$(context_report)
  sparse_data_ok=0
  [ "$(context_hash "$sparse_data_report")" = "$edge_baseline_hash" ] &&
    sparse_data_ok=1

  # Associated formula lines follow GNU Org's numeric-reference repair pass.
  # Each production key is followed by one physical Vi undo so the cases are
  # independent and the complete table/formula edit remains one transaction.
  formula_repairs_ok=1
  formula_case() {
    local command="$1" key="$2" expected="$3" report changed restore
    mx "$ORG_SESSION" "$command"
    tmux_cmd send-keys -t "$ORG_SESSION" "$key"
    sleep 0.3
    report=$(formula_report)
    changed=$(context_report)
    if ! grep -qF "$expected" <<<"$report" ||
       [ "$(context_hash "$changed")" = "$edge_baseline_hash" ]; then
      formula_repairs_ok=0
      guard_report="$report"
      return
    fi
    tmux_cmd send-keys -t "$ORG_SESSION" u
    sleep 0.3
    restore=$(context_report)
    if [ "$(context_hash "$restore")" != "$edge_baseline_hash" ]; then
      formula_repairs_ok=0
      guard_report="$restore"
    fi
  }

  formula_case lem-yath-test-org-goto-edge-formula M-l \
    'formulas=("#+TBLFM: $1=$2+$3::@1$3=@2$2::@2$1=remote(foo,$2)+$3")'
  formula_case lem-yath-test-org-goto-edge-formula M-L \
    'formulas=("#+TBLFM: $3=$2+$4::@1$4=@2$2::@2$3=remote(foo,$2)+$4")'
  formula_case lem-yath-test-org-goto-edge-formula-middle M-H \
    'formulas=("#+TBLFM: @1$2=@2$1::")'
  formula_case lem-yath-test-org-goto-edge-formula-first M-j \
    'formulas=("#+TBLFM: $2=$1+$3::@1$3=@3$1::@3$2=remote(foo,$2)+$3")'
  formula_case lem-yath-test-org-goto-edge-formula-first M-J \
    'formulas=("#+TBLFM: $2=$1+$3::@1$3=@3$1::@3$2=remote(foo,$2)+$3")'
  formula_case lem-yath-test-org-goto-edge-formula-first M-K \
    'formulas=("#+TBLFM: $2=$1+$3::@1$3=@INVALID$1::")'

  # A blank line severs table/formula association in pinned GNU Org.  The
  # table remains editable, while the separated formula is byte-identical.
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-spaced-formula
  tmux_cmd send-keys -t "$ORG_SESSION" M-l
  sleep 0.3
  spaced_formula_report=$(formula_report)
  spaced_formula_context=$(context_report)
  spaced_formula_ok=0
  if grep -qF 'spaced=("| result | spaced formula |"' \
       <<<"$spaced_formula_report" &&
     grep -qF 'spaced-formulas=NIL' <<<"$spaced_formula_report" &&
     grep -qF 'spaced-raw="#+TBLFM: $2=$1"' \
       <<<"$spaced_formula_report" &&
     [ "$(context_hash "$spaced_formula_context")" != "$edge_baseline_hash" ]; then
    spaced_formula_ok=1
  fi
  tmux_cmd send-keys -t "$ORG_SESSION" u
  sleep 0.3
  spaced_formula_restore=$(context_report)
  [ "$(context_hash "$spaced_formula_restore")" = "$edge_baseline_hash" ] ||
    spaced_formula_ok=0

  edge_guards_ok=1
  for spec in \
    'lem-yath-test-org-goto-edge-tab-child M-h' \
    'lem-yath-test-org-goto-edge-wide-child M-l' \
    'lem-yath-test-org-goto-edge-body-item M-l' \
    'lem-yath-test-org-goto-edge-ordered M-j' \
    'lem-yath-test-org-goto-edge-separate M-j' \
    'lem-yath-test-org-goto-edge-source-list M-l' \
    'lem-yath-test-org-goto-edge-source-table M-l' \
    'lem-yath-test-org-goto-edge-mismatched-list M-l' \
    'lem-yath-test-org-goto-edge-mismatched-table M-l' \
    'lem-yath-test-org-goto-edge-source-fake-heading M-l' \
    'lem-yath-test-org-goto-edge-source-fake-heading M-L' \
    'lem-yath-test-org-goto-edge-source-fake-heading M-k' \
    'lem-yath-test-org-goto-edge-source-fake-after-begin M-l' \
    'lem-yath-test-org-goto-edge-source-fake-after-begin M-L' \
    'lem-yath-test-org-goto-edge-source-fake-after-begin M-k' \
    'lem-yath-test-org-goto-edge-clock M-J' \
    'lem-yath-test-org-goto-edge-range-column M-H' \
    'lem-yath-test-org-goto-edge-range-row M-K' \
    'lem-yath-test-org-goto-edge-one-column M-H'; do
    command=${spec% *}
    key=${spec##* }
    mx "$ORG_SESSION" "$command"
    tmux_cmd send-keys -t "$ORG_SESSION" "$key"
    sleep 0.2
    guard_report=$(context_report)
    if [ "$(context_hash "$guard_report")" != "$edge_baseline_hash" ]; then
      edge_guards_ok=0
      break
    fi
  done

  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-one-row
  tmux_cmd send-keys -t "$ORG_SESSION" M-K
  sleep 0.3
  one_row_delete_report=$(context_report)
  one_row_delete_ok=0
  grep -q 'point="AFTER SINGLE ROW"/0' <<<"$one_row_delete_report" &&
    [ "$(context_hash "$one_row_delete_report")" != "$edge_baseline_hash" ] &&
    one_row_delete_ok=1
  tmux_cmd send-keys -t "$ORG_SESSION" u
  sleep 0.3
  one_row_restore_report=$(context_report)
  one_row_restore_ok=0
  [ "$(context_hash "$one_row_restore_report")" = "$edge_baseline_hash" ] &&
    one_row_restore_ok=1

  if [ "$nested_outdent_ok" = 1 ] && [ "$nested_restore_ok" = 1 ] &&
     [ "$star_outdent_ok" = 1 ] && [ "$star_restore_ok" = 1 ] &&
     [ "$source_fake_ok" = 1 ] && [ "$source_real_child_ok" = 1 ] &&
     [ "$source_subtree_restore_ok" = 1 ] &&
     [ "$real_after_literal_ok" = 1 ] &&
     [ "$real_after_literal_restore_ok" = 1 ] &&
     [ "$sparse_data_ok" = 1 ] &&
     [ "$formula_repairs_ok" = 1 ] && [ "$spaced_formula_ok" = 1 ] &&
     [ "$edge_guards_ok" = 1 ] && [ "$one_row_delete_ok" = 1 ] &&
     [ "$one_row_restore_ok" = 1 ]; then
    pass structure-edge "table formulas repair exactly while unsafe structural edits fail closed"
  else
    fail structure-edge "an edge operation crossed scope or changed guarded bytes" "$ORG_SESSION"
    printf '%s\n' "$nested_outdent_report" "$nested_restore_report" \
      "$star_outdent_report" "$star_restore_report" \
      "$source_fake_report" "$source_real_child_report" \
      "$source_subtree_restore" \
      "$real_after_literal_report" "$real_after_literal_restore" \
      "$sparse_data_report" \
      "${spaced_formula_report:-}" "${spaced_formula_restore:-}" \
      "${guard_report:-}" "$one_row_delete_report" "$one_row_restore_report"
  fi
fi

# 12: Evil-Org's unconditional 0/$/I/A base bindings retain their exact
# configured endpoint and insertion policy.  org-special-ctrl-a/e is nil in
# the pinned Emacs profile: I uses literal column zero for headings/items and
# indentation for prose, while A stays at the literal line end after tags.
if start_org endpoints; then
  mx "$ORG_SESSION" lem-yath-test-org-goto-list
  tmux_cmd send-keys -t "$ORG_SESSION" I
  tmux_cmd send-keys -t "$ORG_SESSION" -l 'item-prefix '
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.2
  item_i_ok=0
  screen_has "$ORG_SESSION" '^item-prefix - \[ \] first' && item_i_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-indented-prose
  tmux_cmd send-keys -t "$ORG_SESSION" I
  tmux_cmd send-keys -t "$ORG_SESSION" -l 'prose-prefix '
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.2
  prose_i_ok=0
  screen_has "$ORG_SESSION" '^  prose-prefix indented prose sentinel' &&
    prose_i_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  tmux_cmd send-keys -t "$ORG_SESSION" A
  tmux_cmd send-keys -t "$ORG_SESSION" -l ' end-sentinel'
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.2
  append_ok=0
  screen_has "$ORG_SESSION" 'Parent :work: end-sentinel$' && append_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-parent
  tmux_cmd send-keys -t "$ORG_SESSION" I
  tmux_cmd send-keys -t "$ORG_SESSION" -l 'heading-prefix '
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.2
  heading_i_ok=0
  screen_has "$ORG_SESSION" '^heading-prefix \* TODO Parent' && heading_i_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-goto-indented-prose
  tmux_cmd send-keys -t "$ORG_SESSION" '$'
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  end_report=$(grep '^POINT ' "$LEM_YATH_ORG_REPORT" | tail -n1)
  end_ok=0
  grep -qF 'column=37 text="  prose-prefix indented prose sentinel"' \
    <<<"$end_report" && end_ok=1
  : >"$LEM_YATH_ORG_REPORT"
  tmux_cmd send-keys -t "$ORG_SESSION" 0
  mx "$ORG_SESSION" lem-yath-test-org-point-report
  zero_ok=0
  grep -qF 'column=0 text="  prose-prefix indented prose sentinel"' \
    "$LEM_YATH_ORG_REPORT" && zero_ok=1

  mx "$ORG_SESSION" lem-yath-test-org-open-edge
  mx "$ORG_SESSION" lem-yath-test-org-goto-edge-source-indented-list
  tmux_cmd send-keys -t "$ORG_SESSION" I
  tmux_cmd send-keys -t "$ORG_SESSION" -l 'source-prefix '
  tmux_cmd send-keys -t "$ORG_SESSION" Escape
  sleep 0.2
  source_i_ok=0
  screen_has "$ORG_SESSION" '^  source-prefix - indented source list lookalike' &&
    source_i_ok=1

  if [ "$item_i_ok" = 1 ] && [ "$prose_i_ok" = 1 ] &&
     [ "$append_ok" = 1 ] && [ "$heading_i_ok" = 1 ] &&
     [ "$end_ok" = 1 ] && [ "$zero_ok" = 1 ] &&
     [ "$source_i_ok" = 1 ]; then
    pass endpoints "0/$/I/A match configured Evil-Org endpoint and insertion semantics"
  else
    fail endpoints "an Evil-Org endpoint or insertion command diverged" "$ORG_SESSION"
    printf 'endpoint flags item-I=%s prose-I=%s A=%s heading-I=%s end=%s zero=%s source-I=%s\n' \
      "$item_i_ok" "$prose_i_ok" "$append_ok" "$heading_i_ok" \
      "$end_ok" "$zero_ok" "$source_i_ok"
    printf '%s\n' "$end_report"
    cat "$LEM_YATH_ORG_REPORT"
  fi
fi

if [ "$FAILED" = 0 ]; then
  echo "ORG TEST PASSED"
  exit 0
fi
echo "ORG TEST FAILED" >&2
exit 1
