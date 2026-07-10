#!/usr/bin/env bash
# Real-ncurses regression for LSP CompletionItem snippet acceptance.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-lsp-snippet-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-lsp-snippet.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_LSP_SNIPPET_TEST_REPORT="$root/report"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
: >"$LEM_YATH_LSP_SNIPPET_TEST_REPORT"

session="lem-yath-lsp-snippet-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-32s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-32s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LSP_SNIPPET_TEST_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_LSP_SNIPPET_TEST_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
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

run_mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  lem_keys "$session" Enter
  sleep 0.25
  lem_keys "$session" Enter
  sleep 0.5
}

hex_of() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
}

record_state() {
  local label=$1 before
  before=$(report_count "^STATE label=$label ")
  lem_keys "$session" F12
  wait_report_count "^STATE label=$label " "$((before + 1))"
}

last_state() {
  grep "^STATE label=$1 " "$LEM_YATH_LSP_SNIPPET_TEST_REPORT" | tail -1
}

assert_state() {
  local name=$1 label=$2 expected_text=$3 line expected_hex fragment
  shift 3
  line=$(last_state "$label")
  expected_hex=$(hex_of "$expected_text")
  if [[ "$line" != *"text-hex=$expected_hex "* ]]; then
    fail "$name" "wrong text state: $line"
    return
  fi
  for fragment in "$@"; do
    if [[ "$line" != *"$fragment"* ]]; then
      fail "$name" "missing '$fragment' in: $line"
      return
    fi
  done
  pass "$name" "$label produced the expected text and lifecycle state"
}

fixture="$(lem-yath_lisp_string "$here/scripts/lsp-snippet-fixture.lisp")"
scratch="$root/fixture.txt"
: >"$scratch"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$scratch"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  pass boot "configured Lem loaded the LSP snippet fixture"
else
  fail boot "fixture did not become ready"
fi

if run_mx lem-yath-test-lsp-snippet-static-checks &&
   wait_report '^SUMMARY STATIC PASS failures=0$' 15; then
  pass static-contracts "capability, format, range, and exact-once checks passed"
else
  fail static-contracts "one or more static contracts failed"
fi

if run_mx lem-yath-test-lsp-snippet-insert-setup &&
   lem_wait_for "$session" 'INSERT-SNIPPET' 10 >/dev/null &&
   record_state insert; then
  assert_state insert-popup insert 'pri' \
    'active=no' 'completion=yes' 'focus=INSERT-SNIPPET'
  lem_keys "$session" Enter
  sleep 0.4
  if record_state insert; then
    assert_state insert-accept insert 'print(value)' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail insert-popup "insertText snippet popup did not open"
fi

if run_mx lem-yath-test-lsp-snippet-text-edit-setup &&
   lem_wait_for "$session" 'FUNCTION-SNIPPET' 10 >/dev/null &&
   record_state text-edit; then
  assert_state text-edit-before text-edit 'foTAIL' \
    'active=no' 'completion=yes'
  lem_keys "$session" Tab
  sleep 0.4
  if record_state text-edit; then
    assert_state text-edit-accept text-edit 'fn(name, name)' \
      'active=yes' 'field=1' 'completion=no'
  fi
  lem_keys "$session" i
  sleep 0.2
  tmux_cmd send-keys -t "$session" -l arg
  sleep 0.15
  if record_state text-edit; then
    assert_state text-edit-mirror text-edit 'fn(arg, arg)' \
      'active=yes' 'field=1'
  fi
  lem_keys "$session" Tab
  sleep 0.3
  if record_state text-edit; then
    assert_state text-edit-exit text-edit 'fn(arg, arg)' \
      'active=no' 'field=none' 'completion=no'
  fi
else
  fail text-edit-before "TextEdit snippet popup did not open"
fi

if run_mx lem-yath-test-lsp-snippet-insert-replace-setup &&
   lem_wait_for "$session" 'INSERT-REPLACE-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state insert-replace; then
    assert_state insert-replace-range insert-replace 'ir(x)' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail insert-replace-range "InsertReplaceEdit snippet popup did not open"
fi

if run_mx lem-yath-test-lsp-snippet-plain-setup &&
   lem_wait_for "$session" 'PLAIN-ITEM' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state plain; then
    assert_state plain-format plain 'plain$1${2:x}' \
      'active=no' 'completion=no'
  fi
else
  fail plain-format "plain-format completion did not open"
fi

if run_mx lem-yath-test-lsp-snippet-multiple-setup &&
   lem_wait_for "$session" 'A-FOO' 10 >/dev/null &&
   lem_wait_for "$session" 'B-FAR' 10 >/dev/null; then
  lem_keys "$session" Tab
  sleep 0.3
  if record_state multiple; then
    assert_state no-partial-syntax multiple 'f' \
      'active=no' 'completion=yes' 'focus=B-FAR'
  fi
  lem_keys "$session" Enter
  sleep 0.4
  if record_state multiple; then
    assert_state multiple-accept multiple 'far(y)' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail no-partial-syntax "multiple snippet candidates did not open"
fi

if run_mx lem-yath-test-lsp-snippet-malformed-setup &&
   lem_wait_for "$session" 'BROKEN-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state malformed; then
    assert_state malformed-fail-closed malformed 'bad' \
      'active=no' 'completion=no'
  fi
else
  fail malformed-fail-closed "malformed snippet completion did not open"
fi

inert_text='`(progn (setf *lsp-snippet-test-pwned* t) "BAD")`-safe'
if run_mx lem-yath-test-lsp-snippet-inert-setup &&
   lem_wait_for "$session" 'INERT-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state inert; then
    assert_state server-code-inert inert "$inert_text" \
      'active=yes' 'field=1' 'completion=no' 'pwned=no'
  fi
else
  fail server-code-inert "inert-code snippet completion did not open"
fi

echo
sed -n '1,260p' "$LEM_YATH_LSP_SNIPPET_TEST_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "LSP SNIPPET TEST PASSED"
  exit 0
else
  echo "LSP SNIPPET TEST FAILED"
  exit 1
fi
