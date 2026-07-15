#!/usr/bin/env bash
# Installed-wrapper acceptance coverage for quiet, bounded startup.
set -uo pipefail

id="${LEM_YATH_CHECK_ID:-startup-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-startup.XXXXXX")"
home="$root/home"
cache="$root/cache"
work="$root/work"
socket="lem-yath-startup-$id"
cold_budget_ms="${LEM_YATH_COLD_STARTUP_BUDGET_MS:-30000}"
warm_budget_ms="${LEM_YATH_STARTUP_BUDGET_MS:-10000}"
expected_fasl_count=85
mkdir -p "$home" "$cache" "$work"
export WORKDIR="$work"
unset LEM_HOME
unset ASDF_OUTPUT_TRANSLATIONS

failed=0
launch_started_ns=0
startup_elapsed_ms=0

cleanup() {
  tmux -L "$socket" kill-server 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then
    tmux -L "$socket" capture-pane -t "$3" -p 2>/dev/null || true
  fi
}

lisp_string() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

start_editor() { # start_editor SESSION TRANSCRIPT [LEM-ARGS...]
  local session=$1 transcript=$2 gate editor_command launcher sink
  local editor_bin="${STARTUP_EDITOR_BIN:-$LEM_BIN}"
  local editor_cache="${STARTUP_CACHE_HOME:-$cache}"
  shift 2
  gate="$root/$session.go"
  rm -f "$gate" "$transcript"

  printf -v editor_command '%q ' env \
    "HOME=$home" \
    "XDG_CACHE_HOME=$editor_cache" \
    "TERM=xterm-256color" \
    "LC_ALL=C.UTF-8" \
    "$editor_bin" "$@"
  printf -v launcher \
    'while [ ! -e %q ]; do sleep 0.01; done; exec %s' \
    "$gate" "$editor_command"
  tmux -L "$socket" new-session -d -s "$session" -x 160 -y 45 "$launcher"
  printf -v sink 'cat > %q' "$transcript"
  tmux -L "$socket" pipe-pane -t "$session" "$sink"
  launch_started_ns=$(date +%s%N)
  : >"$gate"
}

stop_editor() {
  tmux -L "$socket" kill-session -t "$1" 2>/dev/null || true
  sleep 0.1
}

wait_for_file() { # wait_for_file PATH BUDGET-MS
  local path=$1 budget_ms=$2 now deadline
  deadline=$((launch_started_ns + budget_ms * 1000000))
  while :; do
    [ -f "$path" ] && return 0
    now=$(date +%s%N)
    (( now >= deadline )) && return 1
    sleep 0.05
  done
}

wait_for_scratch() { # wait_for_scratch SESSION BUDGET-MS
  local session=$1 budget_ms=$2 now deadline screen
  deadline=$((launch_started_ns + budget_ms * 1000000))
  while :; do
    screen=$(tmux -L "$socket" capture-pane -t "$session" -p 2>/dev/null || true)
    if grep -Fq '*scratch*' <<<"$screen" && grep -Eq ' Org( |$)' <<<"$screen"; then
      now=$(date +%s%N)
      startup_elapsed_ms=$(((now - launch_started_ns) / 1000000))
      return 0
    fi
    now=$(date +%s%N)
    (( now >= deadline )) && return 1
    sleep 0.05
  done
}

transcript_is_quiet() {
  ! grep -aEiq \
    'ERROR -|Caught [A-Z]|failed to load|compiling file|debugger invoked' "$1"
}

cold_session="lem-yath-startup-cold-$id"
cold_transcript="$root/cold.transcript"
report="$root/boot-report"
report_form="(progn (uiop:symbol-call :lem-yath :write-boot-report $(lisp_string "$report")) nil)"
start_editor "$cold_session" "$cold_transcript" --eval "$report_form"

if wait_for_file "$report" "$cold_budget_ms" &&
   wait_for_scratch "$cold_session" "$cold_budget_ms"; then
  pass cold-ready "configured Org scratch appeared in ${startup_elapsed_ms}ms"
else
  fail cold-ready "installed wrapper did not become ready within ${cold_budget_ms}ms" \
    "$cold_session"
fi

if [ -f "$report" ] &&
   grep -q '^boot-error: none$' "$report" &&
   grep -q '^boot-ok: T$' "$report" &&
   grep -q '^vi-mode: T$' "$report" &&
   grep -q '^leader-bindings: T$' "$report"; then
  pass cold-config 'the installed wrapper loaded the complete configuration'
else
  fail cold-config 'the installed wrapper boot report was incomplete'
  [ -f "$report" ] && sed -n '1,80p' "$report"
fi

stop_editor "$cold_session"

default_log="$cache/lem-yath/debug.log"
if [ -f "$default_log" ]; then
  pass cached-log 'the default debug log is writable under XDG_CACHE_HOME'
else
  fail cached-log 'the wrapper did not create its default cached debug log'
fi

aot_root=$(sed -n 's/^aot-root: //p' "$report" 2>/dev/null)
aot_count=0
if [ -n "$aot_root" ] && [ "$aot_root" != none ] && [ -d "$aot_root" ]; then
  aot_count=$(find "$aot_root" -type f -name '*.fasl' | wc -l)
fi
if [ "$aot_count" -eq "$expected_fasl_count" ]; then
  pass aot-fasl "all $expected_fasl_count configuration components were compiled by Nix"
else
  fail aot-fasl "the installed AOT output contains $aot_count of $expected_fasl_count FASLs"
fi

if ! find "$cache" -type f -name '*.fasl' -print -quit | grep -q .; then
  pass no-runtime-fasl 'cold startup wrote no configuration FASLs at runtime'
else
  fail no-runtime-fasl 'cold startup compiled configuration into the user cache'
fi

direct_source="$root/direct-source"
direct_cache="$root/direct-cache"
direct_report="$root/direct-report"
source_root="${LEM_YATH_SOURCE:-$PWD/lem-yath}"
cp -R "$source_root" "$direct_source"
chmod -R u+w "$direct_source"
mkdir -p "$direct_cache"
direct_init=$(lisp_string "$direct_source/init.lisp")
direct_form="(progn (load #P$direct_init) (uiop:symbol-call :lem-yath :write-boot-report $(lisp_string "$direct_report")))"
direct_session="lem-yath-startup-direct-$id"
direct_transcript="$root/direct.transcript"
STARTUP_EDITOR_BIN="$LEM_UPSTREAM_BIN" \
STARTUP_CACHE_HOME="$direct_cache" \
  start_editor "$direct_session" "$direct_transcript" --eval "$direct_form"
if wait_for_file "$direct_report" "$cold_budget_ms"; then
  stop_editor "$direct_session"
  direct_count=$(find "$direct_cache" -type f -name '*.fasl' | wc -l)
  if grep -q '^boot-error: none$' "$direct_report" &&
     grep -q '^boot-ok: T$' "$direct_report" &&
     [ "$direct_count" -eq "$expected_fasl_count" ] &&
     ! find "$direct_source" -type f -name '*.fasl' -print -quit | grep -q .; then
    pass direct-cache 'a raw development load cached all FASLs outside its source tree'
  else
    fail direct-cache "development load failed, cached $direct_count of $expected_fasl_count FASLs, or polluted its source"
  fi
else
  fail direct-cache 'the raw development load did not produce a boot report' "$direct_session"
  stop_editor "$direct_session"
fi

if transcript_is_quiet "$cold_transcript"; then
  pass cold-quiet 'cold startup emitted no error or compilation chatter'
else
  fail cold-quiet 'cold startup leaked error or compilation text'
  grep -aEi 'ERROR -|Caught [A-Z]|failed to load|compiling file|debugger invoked' \
    "$cold_transcript" | head -20
fi

warm_session="lem-yath-startup-warm-$id"
warm_transcript="$root/warm.transcript"
start_editor "$warm_session" "$warm_transcript"
if wait_for_scratch "$warm_session" "$warm_budget_ms"; then
  pass warm-ready "AOT-backed Org scratch appeared in ${startup_elapsed_ms}ms"
else
  fail warm-ready "AOT-backed startup exceeded ${warm_budget_ms}ms" "$warm_session"
fi

warm_screen=$(tmux -L "$socket" capture-pane -t "$warm_session" -p 2>/dev/null || true)
if grep -Fq '*scratch*' <<<"$warm_screen" &&
   grep -Eq ' Org( |$)' <<<"$warm_screen" &&
   ! grep -Eq 'Welcome to Lem|Recent Projects|Recent Files|Dashboard' <<<"$warm_screen"; then
  pass blank-scratch 'no-file startup is an empty Org scratch, not a welcome page'
else
  fail blank-scratch 'the no-file startup screen diverged from Emacs' "$warm_session"
fi

stop_editor "$warm_session"
if transcript_is_quiet "$warm_transcript"; then
  pass warm-quiet 'repeated startup emitted no error or compilation chatter'
else
  fail warm-quiet 'repeated startup leaked error or compilation text'
fi

override_session="lem-yath-startup-log-$id"
override_transcript="$root/override.transcript"
override_log="$root/explicit.log"
start_editor "$override_session" "$override_transcript" \
  --log-filename "$override_log"
if wait_for_scratch "$override_session" "$warm_budget_ms"; then
  stop_editor "$override_session"
  if [ -f "$override_log" ]; then
    pass explicit-log 'an explicit --log-filename still overrides the default'
  else
    fail explicit-log 'the explicit log destination was not honored'
  fi
else
  fail explicit-log 'the explicit-log launch did not become ready' "$override_session"
  stop_editor "$override_session"
fi

if [ "$failed" = 0 ]; then
  echo 'STARTUP TEST PASSED'
else
  echo 'STARTUP TEST FAILED'
  exit 1
fi
