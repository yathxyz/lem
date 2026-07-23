#!/usr/bin/env bash
# Real PostgreSQL and installed-wrapper TUI coverage for the pgmacs workflow.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-pg-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-pg.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
mkdir -p "$HOME" "$WORKDIR" "$XDG_CACHE_HOME"

TMUX_BIN="$(command -v tmux)"
initdb_bin="$(command -v initdb)"
pg_ctl_bin="$(command -v pg_ctl)"
psql_bin="$(command -v psql)"
export TMUX_BIN

source "$here/scripts/tui-driver.sh"

session="lem-yath-pg-$id"
pgdata="$root/pgdata"
pgsocket="$root/socket"
pgport=$((20000 + $$ % 20000))
source_file="$root/source.txt"
injection_marker="$root/injected"
pg_started=0
failed=0

cleanup() {
  lem_stop "$session"
  if [ "$pg_started" = 1 ]; then
    "$pg_ctl_bin" -D "$pgdata" -m immediate -w stop >/dev/null 2>&1 || true
  fi
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.25
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  lem_keys "$session" Enter
}

submit_query() {
  local sql=$1
  mx lem-yath-pg-query || return 1
  lem_wait_for "$session" 'SQL:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$sql"
  lem_keys "$session" Enter
}

mkdir -p "$pgsocket"
if ! "$initdb_bin" -D "$pgdata" --auth=trust --encoding=UTF8 --no-locale \
    --username=postgres >"$root/initdb.log" 2>&1; then
  fail postgres-start 'could not initialize the private PostgreSQL cluster'
  sed -n '1,80p' "$root/initdb.log"
  exit 1
fi
if ! "$pg_ctl_bin" -D "$pgdata" -l "$root/postgres.log" \
    -o "-F -k $pgsocket -p $pgport" -w start >/dev/null 2>&1; then
  fail postgres-start 'could not start the private PostgreSQL cluster'
  sed -n '1,80p' "$root/postgres.log"
  exit 1
fi
pg_started=1

export PGHOST="$pgsocket"
export PGPORT="$pgport"
export PGDATABASE=postgres
export PGUSER=postgres
conninfo="host=$pgsocket port=$pgport dbname=postgres user=postgres"

if "$psql_bin" -v ON_ERROR_STOP=1 \
    -c 'CREATE TABLE lem_yath_items (id integer PRIMARY KEY, note text NOT NULL)' \
    -c "INSERT INTO lem_yath_items VALUES (1, 'alpha')" >/dev/null; then
  pass postgres-start 'private PostgreSQL fixture is ready'
else
  fail postgres-start 'could not create the PostgreSQL fixture'
  exit 1
fi

printf 'pg source sentinel\n' >"$source_file"

# Prove psql comes from the installed wrapper rather than the test runner's
# PostgreSQL input: the outer editor environment has no usable PATH.
outer_path=$PATH
PATH=/nonexistent
lem_start "$session" "$source_file"
PATH=$outer_path

if lem_wait_for "$session" 'pg source sentinel' 40 >/dev/null; then
  pass installed-boot 'the installed wrapper opened the source buffer'
else
  fail installed-boot 'the installed wrapper did not become ready' "$session"
  exit 1
fi

if mx pgmacs &&
   lem_wait_for "$session" 'PostgreSQL connection string' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l "$conninfo"
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'lem_yath_items' 20 >/dev/null; then
    screen=$(lem_capture "$session")
    if grep -Fq 'table_schema' <<<"$screen" &&
       grep -Fq 'table_name' <<<"$screen" &&
       grep -Fq 'BASE TABLE' <<<"$screen"; then
      pass pgmacs-entry 'M-x pgmacs accepted conninfo and listed real tables'
    else
      fail pgmacs-entry 'the table list omitted its schema metadata' "$session"
    fi
  else
    fail pgmacs-entry 'M-x pgmacs did not list the fixture table' "$session"
  fi
else
  fail pgmacs-entry 'the exact pgmacs entry did not prompt for a connection' "$session"
fi

lem_keys "$session" q
sleep 0.5
screen=$(lem_capture "$session")
if grep -Fq 'pg source sentinel' <<<"$screen" &&
   ! grep -Fq 'lem_yath_items' <<<"$screen"; then
  pass quit-source 'mode-priority q restored the source buffer'
else
  fail quit-source 'q did not return from the PostgreSQL view' "$session"
fi

if submit_query 'SELECT id, note FROM lem_yath_items ORDER BY id' &&
   lem_wait_for "$session" 'alpha' 20 >/dev/null; then
  screen=$(lem_capture "$session")
  if grep -Fq 'id | note' <<<"$screen" &&
     grep -Fq '1  | alpha' <<<"$screen"; then
    pass query-render 'the physical query prompt rendered aligned CSV results'
  else
    fail query-render 'the query result was not aligned as expected' "$session"
  fi
else
  fail query-render 'the physical query workflow did not finish' "$session"
fi

"$psql_bin" -v ON_ERROR_STOP=1 \
  -c "INSERT INTO lem_yath_items VALUES (2, 'beta')" >/dev/null
lem_keys "$session" g
if lem_wait_for "$session" '2  | beta' 20 >/dev/null; then
  pass refresh 'mode-priority g re-ran the captured last query'
else
  fail refresh 'g did not refresh the result after an external change' "$session"
fi

lem_keys "$session" q
lem_wait_for "$session" 'pg source sentinel' 10 >/dev/null ||
  fail refresh-source 'refresh navigation did not preserve the source buffer' "$session"

safe_sql="SELECT 'safe' AS value; -- ; touch $injection_marker"
if submit_query "$safe_sql" && lem_wait_for "$session" 'safe' 20 >/dev/null &&
   [ ! -e "$injection_marker" ]; then
  pass argv-safety 'SQL metacharacters remained one direct psql argument'
else
  fail argv-safety 'query text escaped into a shell or did not execute safely' "$session"
fi

lem_keys "$session" q
lem_wait_for "$session" 'pg source sentinel' 10 >/dev/null || true
if submit_query 'SELECT * FROM definitely_missing_relation' &&
   lem_wait_for "$session" 'psql error' 20 >/dev/null; then
  screen=$(lem_capture "$session")
  if grep -Fq 'definitely_missing_relation' <<<"$screen"; then
    pass query-error 'psql failures rendered in the focused result buffer'
  else
    fail query-error 'the failure view omitted the server diagnostic' "$session"
  fi
else
  fail query-error 'a failed query did not produce the error view' "$session"
fi

lem_keys "$session" q
lem_wait_for "$session" 'pg source sentinel' 10 >/dev/null || true
if mx lem-yath-pg-set-connection &&
   lem_wait_for "$session" 'Conninfo' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l \
    "host=$pgsocket dbname=postgres password=topsecret"
  lem_keys "$session" Enter
  sleep 0.5
  if mx pgmacs &&
     lem_wait_for "$session" 'PostgreSQL connection string' 10 >/dev/null; then
    screen=$(lem_capture "$session")
    if grep -Fq "port=$pgport" <<<"$screen" &&
       ! grep -Fq 'topsecret' <<<"$screen"; then
      pass password-boundary 'embedded passwords were refused before psql argv construction'
    else
      fail password-boundary 'the rejected password replaced the prior safe conninfo' "$session"
    fi
    lem_keys "$session" Escape
  else
    fail password-boundary 'the retained connection state could not be inspected' "$session"
  fi
else
  fail password-boundary 'the connection command did not accept input' "$session"
fi

if [ "$failed" = 0 ]; then
  echo 'PG TEST PASSED'
else
  echo 'PG TEST FAILED'
  exit 1
fi
