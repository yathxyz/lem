#!/usr/bin/env bash
# Real-TUI and conversion tests for the carried Lem completion lifecycle patch.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-completion-lifecycle-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-completion-lifecycle.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_LIFECYCLE_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR/roam"

sessions=()
failed=0

cleanup() {
  local session
  for session in "${sessions[@]:-}"; do
    [ -n "$session" ] && lem_stop "$session"
  done
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-10} i=0
  while ((i < timeout * 4)); do
    if [ -f "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT" ] &&
       grep -qE "$pattern" "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT"; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

start_fixture() {
  local session=$1 scratch=$2 fixture
  sessions+=("$session")
  fixture="$(lem-yath_lisp_string "$here/scripts/completion-lifecycle-fixture.lisp")"
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$scratch"
  if ! lem_wait_for "$session" 'NORMAL' 40 >/dev/null; then
    fail boot "Lem did not reach the test buffer" "$session"
    return 1
  fi
  sleep 0.5
}

run_mx() {
  local session=$1 command=$2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.6
  lem_keys "$session" Enter
  sleep 0.3
  lem_keys "$session" Enter
  sleep 0.5
}

scratch1="$root/metadata.txt"
: >"$scratch1"
s1="lem-yath-lifecycle-a-$id"
if start_fixture "$s1" "$scratch1"; then
  if run_mx "$s1" lem-yath-test-completion-static-checks &&
     wait_report '^SUMMARY STATIC PASS failures=0$' 15; then
    pass static-contracts "metadata, singleton, LSP precedence, and generation checks passed"
  else
    fail static-contracts "static lifecycle checks failed" "$s1"
  fi

  if run_mx "$s1" lem-yath-test-completion-metadata &&
     lem_wait_for "$s1" 'ALPHA\(value\) \[function\]' 10 >/dev/null &&
     wait_report '^FOCUS alpha$' 10; then
    pass display-label "popup rendered the display label rather than insertion text"
  else
    fail display-label "distinct display label was not shown" "$s1"
  fi

  lem_keys "$s1" C-n
  if wait_report '^FOCUS beta$' 10; then
    pass focus-callback "C-n focused beta and ran its focus callback"
  else
    fail focus-callback "focus callback did not follow C-n" "$s1"
  fi

  lem_keys "$s1" Enter
  if lem_wait_for "$s1" 'beta_insert' 10 >/dev/null &&
     wait_report '^ACCEPT beta buffer=beta_insert$' 10; then
    pass accept-callback "Return inserted beta_insert and invoked acceptance once"
  else
    fail accept-callback "final selection did not use insertion text and callback" "$s1"
  fi

  alpha_line=$(grep -n -m1 '^FOCUS alpha$' "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT" | cut -d: -f1)
  beta_line=$(grep -n -m1 '^FOCUS beta$' "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT" | cut -d: -f1)
  accept_line=$(grep -n -m1 '^ACCEPT beta buffer=beta_insert$' "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT" | cut -d: -f1)
  if [ -n "$alpha_line" ] && [ -n "$beta_line" ] && [ -n "$accept_line" ] &&
     [ "$alpha_line" -lt "$beta_line" ] && [ "$beta_line" -lt "$accept_line" ]; then
    pass callback-order "focus alpha, focus beta, then accept beta"
  else
    fail callback-order "callback order was not deterministic" "$s1"
  fi
fi

scratch2="$root/async.txt"
: >"$scratch2"
s2="lem-yath-lifecycle-b-$id"
if start_fixture "$s2" "$scratch2"; then
  if run_mx "$s2" lem-yath-test-completion-async &&
     lem_wait_for "$s2" 'INITIAL-A' 10 >/dev/null &&
     wait_report '^REQUEST a$' 10; then
    tmux_cmd send-keys -t "$s2" -l b
    if wait_report '^REQUEST ab$' 10; then
      lem_keys "$s2" Tab
      sleep 0.3
      lem_keys "$s2" Enter
      sleep 0.5
      if ! grep -q '^ACCEPT initial ' "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT"; then
        pass pending-acceptance "Tab and Return could not accept an older displayed generation"
      else
        fail pending-acceptance "an older candidate remained selectable during refresh" "$s2"
      fi
      tmux_cmd send-keys -t "$s2" -l c
      if wait_report '^REQUEST abc$' 10; then
        pass async-requests "typing issued deterministic a, ab, and abc generations"
      else
        fail async-requests "abc request was not captured" "$s2"
      fi
    else
      fail async-requests "ab request was not captured" "$s2"
    fi
  else
    fail async-requests "initial async completion did not open" "$s2"
  fi

  lem_keys "$s2" F5
  if lem_wait_for "$s2" 'FRESH-ABC' 10 >/dev/null &&
     wait_report '^DELIVER fresh$' 10; then
    lem_keys "$s2" F6
    sleep 0.8
    screen=$(lem_capture "$s2")
    if grep -q 'FRESH-ABC' <<<"$screen" &&
       ! grep -q 'STALE-AB' <<<"$screen" &&
       wait_report '^DELIVER stale$' 10; then
      pass stale-rejection "late ab response could not replace current abc candidates"
    else
      fail stale-rejection "stale response changed the popup" "$s2"
    fi
  else
    fail stale-rejection "fresh response was not delivered" "$s2"
  fi

  lem_keys "$s2" Enter
  if lem_wait_for "$s2" 'fresh_insert' 10 >/dev/null &&
     wait_report '^ACCEPT fresh buffer=fresh_insert$' 10; then
    pass fresh-acceptance "accepted candidate remained tied to the latest generation"
  else
    fail fresh-acceptance "latest candidate was not accepted correctly" "$s2"
  fi
fi

echo
if [ -f "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT" ]; then
  sed -n '1,240p' "$LEM_YATH_COMPLETION_LIFECYCLE_REPORT"
fi

if [ "$failed" = 0 ]; then
  echo "COMPLETION LIFECYCLE TEST PASSED"
  exit 0
else
  echo "COMPLETION LIFECYCLE TEST FAILED"
  exit 1
fi
