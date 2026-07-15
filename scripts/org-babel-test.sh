#!/usr/bin/env bash
# Configured Org Babel execution through the real ncurses editor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-babel-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-babel.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_ORG_BABEL_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR" "$WORKDIR/subdir"

fixture="$WORKDIR/babel.org"
fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-babel-fixture.lisp")"
session="lem-org-babel-$id"
failed=0
pgdata="$root/pgdata"
pgsocket="$root/pgsocket"
pgport=$((30000 + ($$ % 20000)))
pg_started=0

cleanup() {
  if [ "$pg_started" -eq 1 ]; then
    pg_ctl -D "$pgdata" -m immediate -w stop >/dev/null 2>&1 || true
  fi
  lem_stop "$session" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

mx() {
  local command="$1"
  tmux_cmd send-keys -t "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  tmux_cmd send-keys -t "$session" Enter
  sleep 0.5
}

goto_block() { mx "lem-yath-test-babel-goto-$1"; }

report_block() {
  : >"$LEM_YATH_ORG_BABEL_REPORT"
  mx lem-yath-test-babel-report || return 1
  grep '^BLOCK ' "$LEM_YATH_ORG_BABEL_REPORT" | tail -n1
}

execute_confirmed() {
  tmux_cmd send-keys -t "$session" C-c C-c
  lem_wait_for "$session" 'Execute .* source block' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" y
}

cat >"$fixture" <<'EOF'
:PROPERTIES:
:header-args:sqlite: :db fixture.sqlite
:END:

* Shell replacement
#+begin_src bash :results output
printf 'shell-ok\nsecond-line\n'
#+end_src

#+RESULTS:
: stale

* SQLite trusted execution
#+begin_src sqlite
create table sample(value text);
insert into sample values ('db-ok');
select 'db-ok' as status, value from sample;
#+end_src

* Python
#+begin_src python
print('python-ok')
#+end_src

* C
#+begin_src C :results output
#include <stdio.h>
int main(void) { puts("c-ok"); return 0; }
#+end_src

* Directory
#+begin_src sh :dir subdir :results output
printf '%s\n' "$PWD"
#+end_src

* None
#+begin_src bash :results none
touch none-created
#+end_src

* Cancellation
#+begin_src shell
touch cancelled-created
#+end_src

* Unsupported Emacs Lisp
#+begin_src emacs-lisp
(message "must-not-run")
#+end_src
EOF

mkdir -p "$pgsocket"
if ! initdb -D "$pgdata" --auth=trust --encoding=UTF8 --no-locale \
    --username=postgres >"$root/initdb.log" 2>&1; then
  printf 'FAIL  %-24s %s\n' postgres-start 'could not initialize the private PostgreSQL cluster'
  sed -n '1,80p' "$root/initdb.log"
  exit 1
fi
if ! pg_ctl -D "$pgdata" -l "$root/postgres.log" \
    -o "-F -k $pgsocket -p $pgport" -w start >/dev/null 2>&1; then
  printf 'FAIL  %-24s %s\n' postgres-start 'could not start the private PostgreSQL cluster'
  sed -n '1,80p' "$root/postgres.log"
  exit 1
fi
pg_started=1

cat >>"$fixture" <<EOF

* PostgreSQL
#+begin_src sql :engine postgres :dbuser postgres :dbpassword ignored :dbhost $pgsocket :dbport $pgport :database postgres
select 'pg-ok' as status, 42 as answer;
#+end_src
EOF

: >"$LEM_YATH_ORG_BABEL_REPORT"
lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"
if ! lem_wait_for "$session" 'Shell replacement' 40 >/dev/null; then
  fail startup "Babel fixture did not open"
  exit 1
fi
sleep 1
tmux_cmd send-keys -t "$session" Escape
sleep 0.25

mx lem-yath-test-babel-binding-report
if grep -q '^BINDING LEM-YATH-ORG-CONTEXT-ACTION$' "$LEM_YATH_ORG_BABEL_REPORT"; then
  pass binding 'C-c C-c dispatches through the Org context command'
else
  fail binding 'C-c C-c did not resolve to the Org dispatcher'
fi

: >"$LEM_YATH_ORG_BABEL_REPORT"
mx lem-yath-test-babel-table-format-report
if grep -q 'TABLE-FORMAT kind=TABLE length=[1-9][0-9]*' \
    "$LEM_YATH_ORG_BABEL_REPORT" &&
   grep -qF 'text=| status | value |||---+---||| db-ok | db-ok |' \
    "$LEM_YATH_ORG_BABEL_REPORT"; then
  pass table-format 'database table conversion is finite and structurally exact'
else
  fail table-format 'database table conversion was malformed'
  sed -n '/^TABLE-FORMAT /p' "$LEM_YATH_ORG_BABEL_REPORT"
fi

goto_block shell
if execute_confirmed && lem_wait_for "$session" 'Executed bash source block' 20 >/dev/null; then
  shell_report="$(report_block)"
  if grep -q 'result="#+RESULTS:|: shell-ok|: second-line|' <<<"$shell_report"; then
    pass shell 'confirmed Bash output replaced the adjacent stale result'
  else
    fail shell 'Bash result replacement was not exact'
  fi
else
  fail shell 'confirmed Bash block did not finish'
fi

tmux_cmd send-keys -t "$session" u
sleep 0.4
goto_block shell
shell_undo_report="$(report_block)"
if grep -q 'result="#+RESULTS:|: stale|' <<<"$shell_undo_report"; then
  pass undo 'result replacement is one undoable edit'
else
  fail undo 'one undo did not restore the complete stale result'
fi

goto_block sqlite
tmux_cmd send-keys -t "$session" C-c C-c
if lem_wait_for "$session" 'Executed sqlite source block' 20 >/dev/null; then
  sqlite_report="$(report_block)"
  if grep -q 'db="fixture.sqlite"' <<<"$sqlite_report" &&
     grep -q 'result="#+RESULTS:|.*| status | value |.*| db-ok | db-ok |' <<<"$sqlite_report" &&
     [ -f "$WORKDIR/fixture.sqlite" ]; then
    pass sqlite 'trusted SQLite inherited its property and inserted an Org table'
  else
    fail sqlite 'SQLite property inheritance, table output, or database path failed'
  fi
else
  fail sqlite 'trusted SQLite unexpectedly prompted or failed'
fi

goto_block python
if execute_confirmed && lem_wait_for "$session" 'Executed python source block' 20 >/dev/null; then
  python_report="$(report_block)"
  if grep -q 'result="#+RESULTS:|: python-ok|' <<<"$python_report"; then
    pass python 'configured Python defaults to captured output'
  else
    fail python 'Python output result was incorrect'
  fi
else
  fail python 'confirmed Python block did not finish'
fi

goto_block c
if execute_confirmed && lem_wait_for "$session" 'Executed c source block' 20 >/dev/null; then
  c_report="$(report_block)"
  if grep -q 'result="#+RESULTS:|: c-ok|' <<<"$c_report"; then
    pass c 'configured C block compiled and ran'
  else
    fail c 'C output result was incorrect'
  fi
else
  fail c 'confirmed C block did not finish'
fi

goto_block directory
if execute_confirmed && lem_wait_for "$session" 'Executed bash source block' 20 >/dev/null; then
  directory_report="$(report_block)"
  if grep -q ": $WORKDIR/subdir|" <<<"$directory_report"; then
    pass directory ':dir resolved relative to the Org file'
  else
    fail directory ':dir did not select the expected working directory'
  fi
else
  fail directory 'confirmed :dir block did not finish'
fi

goto_block none
if execute_confirmed && lem_wait_for "$session" 'Executed bash source block' 20 >/dev/null; then
  none_report="$(report_block)"
  if grep -q 'result="NONE"' <<<"$none_report" && [ -f "$WORKDIR/none-created" ]; then
    pass results-none ':results none executed without inserting a result'
  else
    fail results-none ':results none did not preserve the buffer contract'
  fi
else
  fail results-none 'confirmed :results none block did not finish'
fi

goto_block cancel
tmux_cmd send-keys -t "$session" C-c C-c
if lem_wait_for "$session" 'Execute bash source block' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" n
  sleep 0.5
  if [ ! -e "$WORKDIR/cancelled-created" ]; then
    pass cancellation 'declining confirmation left the filesystem untouched'
  else
    fail cancellation 'declined source block still executed'
  fi
else
  fail cancellation 'unsafe shell block did not request confirmation'
fi

goto_block elisp
tmux_cmd send-keys -t "$session" C-c C-c
if lem_wait_for "$session" 'Emacs Lisp blocks require Emacs' 10 >/dev/null; then
  pass emacs-lisp 'Emacs Lisp fails explicitly instead of being mis-evaluated as CL'
else
  fail emacs-lisp 'unsupported Emacs Lisp did not produce the explicit boundary'
fi

goto_block postgres
if execute_confirmed && lem_wait_for "$session" 'Executed sql source block' 20 >/dev/null; then
  postgres_report="$(report_block)"
  if grep -q 'result="#+RESULTS:|.*| status | answer |.*| pg-ok | 42 |' \
      <<<"$postgres_report"; then
    pass postgresql 'PostgreSQL headers, private password environment, and table results work'
  else
    fail postgresql 'PostgreSQL header handling or table output was incorrect'
  fi
else
  fail postgresql 'confirmed PostgreSQL block did not finish'
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'Org Babel TUI checks passed.\n'
