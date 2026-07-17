#!/usr/bin/env bash
# GNU Org source-block edit sessions through real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-source-edit-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-source-edit.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS="$root/snapshots"
mkdir -p "$HOME" "$WORKDIR" "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS"

fixture="$root/source-edit.org"
cat >"$fixture" <<'EOF'
* Source editing

** Commit
#+begin_src python
def greet():
    print("old")
,* protected heading
,#+protected keyword
#+end_src

** Abort
#+begin_src bash
printf 'abort-original\n'
#+end_src

** Save
#+begin_src python
print("save-original")
#+end_src

** Stale
#+begin_src python
print("stale-original")
#+end_src

** Read only
#+begin_src python
print("read-only-original")
#+end_src

** DSQ
#+begin_src dsq
select name from {}
#+end_src
EOF
cp "$fixture" "$root/original.org"

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-source-edit-fixture.lisp")"
session="lem-org-source-edit-$id"
report="$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/report"
failed=0

cleanup() {
  lem_stop "$session" 2>/dev/null || true
  rm -rf "$root"
}
on_signal() {
  cleanup
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

pass() { printf 'PASS  %-22s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-22s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

mx() {
  local command="$1"
  tmux_cmd send-keys -t "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  tmux_cmd send-keys -t "$session" Enter
  sleep 0.8
}

snapshot() {
  local number="$1"
  mx lem-yath-test-source-edit-snapshot || return 1
  lem_wait_for "$session" "Source edit snapshot $number" 10 >/dev/null || return 1
  test -f "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-$number"
}

goto_marker() {
  mx "lem-yath-test-source-edit-goto-$1"
}

open_source_edit() {
  tmux_cmd send-keys -t "$session" C-c "'"
  lem_wait_for "$session" "Edit, then C-c ' to finish" 10 >/dev/null
}

leave_insert_state() {
  # The first Escape can dismiss a completion popup; the second exits Insert.
  tmux_cmd send-keys -t "$session" Escape Escape
  sleep 0.4
}

: >"$report"
lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"
if ! lem_wait_for "$session" 'Source editing' 40 >/dev/null; then
  fail startup 'source-edit fixture did not open'
  exit 1
fi
tmux_cmd send-keys -t "$session" Escape
sleep 2

mx lem-yath-test-source-edit-bindings
if grep -q "^BINDING C-c ' LEM-YATH-ORG-EDIT-SPECIAL$" "$report"; then
  pass org-binding "C-c ' resolves to the Org source editor"
else
  fail org-binding "C-c ' did not resolve in Org mode"
fi

: >"$report"
goto_marker protected
edit_point_ok=0
source_point_ok=0
if open_source_edit; then
  tmux_cmd send-keys -t "$session" F12
  sleep 0.3
  grep -q '^POINT column=18 text="\* protected heading" modified=no$' \
    "$report" && edit_point_ok=1
  tmux_cmd send-keys -t "$session" C-c "'"
fi
if lem_wait_for "$session" 'Org source block updated' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" F12
  sleep 0.3
  grep -q '^POINT column=19 text=",\* protected heading" modified=no$' \
    "$report" && source_point_ok=1
fi
if [ "$edit_point_ok" -eq 1 ] && [ "$source_point_ok" -eq 1 ]; then
  pass point-mapping 'comma unescaping preserves the logical source position'
else
  fail point-mapping 'source/edit coordinate mapping shifted point'
fi

: >"$report"
goto_marker commit
if open_source_edit &&
   mx lem-yath-test-source-edit-bindings &&
   mx lem-yath-test-source-edit-report &&
   snapshot 1 &&
   grep -q "^BINDING C-c ' LEM-YATH-ORG-EDIT-SRC-EXIT$" "$report" &&
   grep -q '^BINDING C-c C-k LEM-YATH-ORG-EDIT-SRC-ABORT$' "$report" &&
   grep -q '^BINDING C-x C-s LEM-YATH-ORG-EDIT-SRC-SAVE$' "$report" &&
   grep -q '^CURRENT mode=PYTHON-MODE edit=yes modified=no origin-modified=no$' "$report" &&
   ! grep -q '#+begin_src\|#+end_src' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-1" &&
   grep -q '^    print("old")$' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-1" &&
   grep -q '^\* protected heading$' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-1" &&
   grep -q '^#+protected keyword$' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-1"; then
  pass edit-buffer 'language mode, local bindings, indentation, and comma unescaping match Org'
else
  fail edit-buffer 'the dedicated source buffer contract differed'
fi

goto_marker commit
tmux_cmd send-keys -t "$session" A
tmux_cmd send-keys -t "$session" -l ' # edited'
leave_insert_state
tmux_cmd send-keys -t "$session" C-c "'"
if lem_wait_for "$session" 'Org source block updated' 10 >/dev/null &&
   snapshot 2 &&
   grep -q '^    print("old") # edited$' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-2" &&
   grep -q '^,\* protected heading$' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-2" &&
   grep -q '^,#+protected keyword$' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-2" &&
   cmp -s "$fixture" "$root/original.org"; then
  pass commit 'physical edit writes back exactly and remains unsaved'
else
  fail commit 'writeback, escaping, or persistence boundary differed'
fi

tmux_cmd send-keys -t "$session" u
sleep 0.5
if snapshot 3 &&
   cmp -s "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-3" "$root/original.org"; then
  pass undo 'one Vi undo restores the complete source body'
else
  fail undo 'source writeback was not one undoable transaction'
fi

goto_marker abort
if open_source_edit; then
  tmux_cmd send-keys -t "$session" A
  tmux_cmd send-keys -t "$session" -l ' # discarded'
  leave_insert_state
  tmux_cmd send-keys -t "$session" C-c C-k
fi
if lem_wait_for "$session" 'Org source edit aborted' 10 >/dev/null &&
   snapshot 4 &&
   cmp -s "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-4" "$root/original.org"; then
  pass abort 'C-c C-k discards the temporary-buffer edit'
else
  fail abort 'abort changed the Org source buffer'
fi

goto_marker save
if open_source_edit; then
  tmux_cmd send-keys -t "$session" A
  tmux_cmd send-keys -t "$session" -l ' # saved'
  leave_insert_state
  tmux_cmd send-keys -t "$session" C-x C-s
fi
if lem_wait_for "$session" 'Org source block written and saved' 10 >/dev/null; then
  : >"$report"
  mx lem-yath-test-source-edit-report
  if grep -q '^CURRENT mode=PYTHON-MODE edit=yes modified=no origin-modified=no$' "$report" &&
     grep -q '^print("save-original") # saved$' "$fixture"; then
    pass save 'C-x C-s saves the source file and stays in the edit buffer'
  else
    fail save 'save did not retain the edit session or clean both buffers'
  fi
else
  fail save 'C-x C-s did not complete the source save'
fi
tmux_cmd send-keys -t "$session" C-c C-k
lem_wait_for "$session" 'Org source edit aborted' 10 >/dev/null || true
snapshot 5 || fail save-snapshot 'could not snapshot the saved source buffer'
cp "$fixture" "$root/after-save.org"

goto_marker stale
if open_source_edit; then
  tmux_cmd send-keys -t "$session" A
  tmux_cmd send-keys -t "$session" -l ' # candidate'
  leave_insert_state
  mx lem-yath-test-source-edit-external-change
  tmux_cmd send-keys -t "$session" C-c "'"
fi
if lem_wait_for "$session" 'changed while it was being edited' 10 >/dev/null; then
  : >"$report"
  mx lem-yath-test-source-edit-report
  if grep -q '^CURRENT mode=PYTHON-MODE edit=yes modified=yes origin-modified=yes$' "$report"; then
    pass stale-source 'concurrent source changes refuse overwrite and retain the edit session'
  else
    fail stale-source 'stale refusal did not leave a recoverable edit session'
  fi
else
  fail stale-source 'concurrent source mutation was overwritten or not diagnosed'
fi
tmux_cmd send-keys -t "$session" C-c C-k
lem_wait_for "$session" 'Org source edit aborted' 10 >/dev/null || true
if snapshot 6 &&
   grep -q '^external-change$' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-6" &&
   ! grep -q '# candidate' "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-6" &&
   cmp -s "$fixture" "$root/after-save.org"; then
  pass stale-abort 'abort preserves only the external unsaved source mutation'
else
  fail stale-abort 'stale-session abort damaged memory or disk state'
fi

goto_marker abort
if open_source_edit; then
  tmux_cmd send-keys -t "$session" A
  tmux_cmd send-keys -t "$session" -l ' # reload-discarded'
  leave_insert_state
  tmux_cmd send-keys -t "$session" F11
fi
if lem_wait_for "$session" 'Source edit reload cleanup complete' 10 >/dev/null &&
   snapshot 7 &&
   cmp -s "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-7" \
          "$LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS/state-6"; then
  pass reload-cleanup 'reload closes the edit buffer and discards its temporary text'
else
  fail reload-cleanup 'reload left an edit buffer or changed the Org source'
fi

goto_marker read-only
mx lem-yath-test-source-edit-read-only
tmux_cmd send-keys -t "$session" C-c "'"
if lem_wait_for "$session" 'Org buffer is read-only' 10 >/dev/null; then
  pass read-only 'read-only sources fail before creating an edit buffer'
else
  fail read-only 'a read-only source opened or mutated an edit session'
fi
mx lem-yath-test-source-edit-writable

goto_marker heading
tmux_cmd send-keys -t "$session" C-c "'"
if lem_wait_for "$session" 'Point is not in an Org source block' 10 >/dev/null; then
  pass outside-block 'C-c apostrophe fails clearly outside a source block'
else
  fail outside-block 'outside-block source editing did not fail closed'
fi

goto_marker read-only
tmux_cmd send-keys -t "$session" C-z C-u C-c "'"
if lem_wait_for "$session" 'session-buffer editing is not configured' 10 >/dev/null; then
  pass prefix-boundary 'the unsupported Babel-session prefix is explicit'
else
  fail prefix-boundary 'the unsupported prefix was silently ignored'
fi

goto_marker dsq
if open_source_edit; then
  : >"$report"
  mx lem-yath-test-source-edit-report
  if grep -q '^CURRENT mode=SQL-MODE edit=yes modified=no origin-modified=' "$report"; then
    pass dsq-mode 'DSQ source editing uses the SQL major mode'
  else
    fail dsq-mode 'DSQ source editing did not select SQL mode'
  fi
  tmux_cmd send-keys -t "$session" C-c C-k
else
  fail dsq-mode 'DSQ source edit buffer did not open'
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'Org source-edit TUI checks passed.\n'
