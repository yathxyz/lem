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

cat >"$WORKDIR/people weird \$ ;literal.json" <<'EOF'
[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]
EOF
cat >"$WORKDIR/people.json" <<'EOF'
[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]
EOF
cat >"$WORKDIR/languages.csv" <<'EOF'
person_id,language
1,Lisp
2,Rust
EOF
cat >"$WORKDIR/irregular.json" <<'EOF'
[{"id":1,"active":false,"note":null},{"id":2,"active":true,"note":"ready"}]
EOF
cat >"$WORKDIR/external.org" <<'EOF'
#+name: places
| city   | country |
|--------+---------|
| Dublin | Ireland |
| Vienna | Austria |
EOF

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
  sleep 0.8
}

goto_block() { mx "lem-yath-test-babel-goto-$1"; }

report_block() {
  : >"$LEM_YATH_ORG_BABEL_REPORT"
  mx lem-yath-test-babel-report || return 1
  grep '^BLOCK ' "$LEM_YATH_ORG_BABEL_REPORT" | tail -n1
}

diagnose_dsq() {
  : >"$LEM_YATH_ORG_BABEL_REPORT"
  mx lem-yath-test-babel-dsq-diagnostic >/dev/null || return 1
  grep '^DSQ-DIAGNOSTIC ' "$LEM_YATH_ORG_BABEL_REPORT" | tail -n1
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

* DSQ direct file
#+begin_src dsq :input "people weird $ ;literal.json"
select id, name from {} order by id
#+end_src

#+RESULTS:
: stale-dsq-file

* DSQ local table reference
#+name: colors
|person_id|color|
|---------+-----|
|1|blue|
|2|red|

#+begin_src dsq :input colors :header no :hlines yes
select color from {} order by person_id
#+end_src

* DSQ multiple files
#+begin_src dsq :input people.json languages.csv
select people.name, languages.language
from {0} people join {1} languages on people.id = languages.person_id
order by people.id
#+end_src

* DSQ external Org reference
#+begin_src dsq :input external.org:places
select city from {} order by city
#+end_src

* DSQ named source result
#+name: generated-json
#+begin_src shell
printf '[{"label":"from-result"}]\n'
#+end_src

#+RESULTS:
: [{"label":"from-result"}]

#+begin_src dsq :input generated-json
select label from {}
#+end_src

* DSQ value rendering
#+begin_src dsq :input irregular.json :null-value "?" :false-value "nope"
select id, active, note from {} order by id
#+end_src

* DSQ missing reference
#+begin_src dsq :input missing_reference
select * from missing_reference
#+end_src

#+RESULTS:
: untouched-dsq-failure
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
sleep 2
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

goto_block dsq-file
if execute_confirmed && lem_wait_for "$session" 'Executed dsq source block' 20 >/dev/null; then
  dsq_file_report="$(report_block)"
  if grep -q 'id' <<<"$dsq_file_report" &&
     grep -q 'name' <<<"$dsq_file_report" &&
     { grep -q '1 | Alice' <<<"$dsq_file_report" ||
       grep -q 'Alice | 1' <<<"$dsq_file_report"; } &&
     { grep -q '2 | Bob' <<<"$dsq_file_report" ||
       grep -q 'Bob | 2' <<<"$dsq_file_report"; }; then
    pass dsq-file 'a metacharacter path ran through exact direct argv with default tables'
  else
    fail dsq-file 'DSQ file input or pinned default table rendering was incorrect'
  fi
else
  fail dsq-file 'confirmed DSQ file block did not finish'
fi

tmux_cmd send-keys -t "$session" u
sleep 0.4
goto_block dsq-file
dsq_undo_report="$(report_block)"
if grep -q 'result="#+RESULTS:|: stale-dsq-file|' <<<"$dsq_undo_report"; then
  pass dsq-undo 'DSQ result replacement is one ordinary undo edit'
else
  fail dsq-undo 'one undo did not restore the complete prior DSQ result'
fi

goto_block dsq-table
if execute_confirmed && lem_wait_for "$session" 'Executed dsq source block' 20 >/dev/null; then
  dsq_table_report="$(report_block)"
  if grep -q 'result="#+RESULTS:|| blue |||---||| red |' <<<"$dsq_table_report"; then
    pass dsq-table 'a named live Org table honored header and hline controls'
  else
    fail dsq-table 'named table conversion or DSQ table controls were incorrect'
  fi
else
  diagnose_dsq || true
  fail dsq-table 'confirmed named-table DSQ block did not finish'
fi

goto_block dsq-multiple
if execute_confirmed && lem_wait_for "$session" 'Executed dsq source block' 20 >/dev/null; then
  dsq_multiple_report="$(report_block)"
  if { grep -q 'Alice.*Lisp' <<<"$dsq_multiple_report" ||
       grep -q 'Lisp.*Alice' <<<"$dsq_multiple_report"; } &&
     { grep -q 'Bob.*Rust' <<<"$dsq_multiple_report" ||
       grep -q 'Rust.*Bob' <<<"$dsq_multiple_report"; }; then
    pass dsq-multiple 'multiple JSON and CSV file inputs preserved their argv order'
  else
    fail dsq-multiple 'multiple DSQ file inputs or join output were incorrect'
  fi
else
  diagnose_dsq || true
  fail dsq-multiple 'confirmed multi-input DSQ block did not finish'
fi

goto_block dsq-external
if execute_confirmed && lem_wait_for "$session" 'Executed dsq source block' 20 >/dev/null; then
  dsq_external_report="$(report_block)"
  if grep -q 'Dublin' <<<"$dsq_external_report" &&
     grep -q 'Vienna' <<<"$dsq_external_report"; then
    pass dsq-external 'a cross-file named Org table was converted through a live temp input'
  else
    fail dsq-external 'cross-file named Org reference output was incorrect'
  fi
else
  diagnose_dsq || true
  fail dsq-external 'confirmed external-reference DSQ block did not finish'
fi

goto_block dsq-result
if execute_confirmed && lem_wait_for "$session" 'Executed dsq source block' 20 >/dev/null; then
  dsq_result_report="$(report_block)"
  if grep -q 'from-result' <<<"$dsq_result_report"; then
    pass dsq-result 'a named source block result was detected and queried as JSON'
  else
    fail dsq-result 'named source result resolution was incorrect'
  fi
else
  diagnose_dsq || true
  fail dsq-result 'confirmed named-result DSQ block did not finish'
fi

goto_block dsq-values
if execute_confirmed && lem_wait_for "$session" 'Executed dsq source block' 20 >/dev/null; then
  dsq_values_report="$(report_block)"
  if grep -q 'id' <<<"$dsq_values_report" &&
     grep -q 'active' <<<"$dsq_values_report" &&
     grep -q 'note' <<<"$dsq_values_report" &&
     grep -q '1' <<<"$dsq_values_report" &&
     grep -q 'nope' <<<"$dsq_values_report" &&
     grep -q '?' <<<"$dsq_values_report" &&
     grep -q '2' <<<"$dsq_values_report" &&
     grep -q 't' <<<"$dsq_values_report" &&
     grep -q 'ready' <<<"$dsq_values_report"; then
    pass dsq-values 'false, null, true, strings, and converted numbers use pinned rendering'
  else
    fail dsq-values 'DSQ value rendering headers or number conversion were incorrect'
  fi
else
  fail dsq-values 'confirmed value-rendering DSQ block did not finish'
fi

goto_block dsq-missing
tmux_cmd send-keys -t "$session" C-c C-c
if lem_wait_for "$session" 'Execute dsq source block' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" y
  if lem_wait_for "$session" 'Unknown DSQ Org reference' 10 >/dev/null; then
    dsq_missing_report="$(report_block)"
    if grep -q 'result="#+RESULTS:|: untouched-dsq-failure|' \
        <<<"$dsq_missing_report"; then
      pass dsq-failure 'invalid inputs fail before mutating the prior result'
    else
      fail dsq-failure 'a failed DSQ input changed its existing result'
    fi
  else
    fail dsq-failure 'missing DSQ reference did not fail visibly'
  fi
else
  fail dsq-failure 'DSQ block did not use the configured confirmation boundary'
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
