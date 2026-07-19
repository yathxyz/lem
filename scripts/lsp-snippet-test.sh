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
  pass static-contracts \
    "capability, encoding, range validation, fallback, and lifecycle checks passed"
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

if run_mx lem-yath-test-lsp-snippet-additional-setup &&
   lem_wait_for "$session" 'ADDITIONAL-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state additional; then
    assert_state additional-edits additional 'PRE$1-call(x, x)-POST' \
      'active=yes' 'field=1' 'completion=no'
  fi
  lem_keys "$session" u
  sleep 0.4
  if record_state additional; then
    assert_state additional-one-undo additional 'AAfoTAILZZ' \
      'active=no' 'field=none' 'completion=no'
  fi
else
  fail additional-edits "completion with before/after additional edits did not open"
fi

if run_mx lem-yath-test-lsp-snippet-utf16-setup &&
   lem_wait_for "$session" 'UTF16-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state utf16; then
    assert_state utf16-composite-ranges utf16 'PRE-utf(x)-POST' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail utf16-composite-ranges \
    "UTF-16 completion around astral characters did not open"
fi

if run_mx lem-yath-test-lsp-snippet-frozen-setup &&
   lem_wait_for "$session" 'FROZEN-SNIPPET' 10 >/dev/null &&
   wait_report '^FROZEN local=yes$' 10; then
  tmux_cmd send-keys -t "$session" -l x
  sleep 0.4
  if record_state frozen; then
    assert_state frozen-local-filter-input frozen 'AAfoxTAILZZ' \
      'active=no' 'completion=yes' 'local=yes' 'focus=FROZEN-SNIPPET'
  fi
  if (( $(report_count '^FROZEN provider-count=') == 1 )) &&
     wait_report '^FROZEN provider-count=1$' 1; then
    pass frozen-provider-reuse \
      "typing locally reused the original converted completion batch"
  else
    fail frozen-provider-reuse \
      "typing requested or presented a second provider batch"
  fi
  lem_keys "$session" Enter
  sleep 0.4
  if record_state frozen; then
    assert_state frozen-snapshot-ranges frozen 'AAfrozen(value)-POST' \
      'active=yes' 'field=1' 'completion=no' 'local=no'
  fi
else
  fail frozen-snapshot-ranges \
    "completion batch could not be frozen for local filtering"
fi

if run_mx lem-yath-test-lsp-snippet-out-of-range-additional-setup &&
   lem_wait_for "$session" 'OUT-OF-RANGE-ADDITIONAL-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state out-of-range-additional; then
    assert_state additional-out-of-range-skipped \
      out-of-range-additional 'AAsafe(x)ZZ' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail additional-out-of-range-skipped \
    "completion with an out-of-range additional edit did not open"
fi

if run_mx lem-yath-test-lsp-snippet-overlap-main-setup &&
   lem_wait_for "$session" 'OVERLAP-MAIN-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state overlap-main; then
    assert_state additional-main-overlap-skipped overlap-main 'AAmain(x)ZZ' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail additional-main-overlap-skipped \
    "completion with a primary-overlapping additional edit did not open"
fi

if run_mx lem-yath-test-lsp-snippet-overlap-pair-setup &&
   lem_wait_for "$session" 'OVERLAP-PAIR-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state overlap-pair; then
    assert_state additional-pair-overlap-skipped overlap-pair 'AApair(x)ZZ' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail additional-pair-overlap-skipped \
    "completion with mutually overlapping additional edits did not open"
fi

if run_mx lem-yath-test-lsp-snippet-adjacent-insertion-setup &&
   lem_wait_for "$session" 'ADJACENT-INSERTION-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state adjacent-insertion; then
    assert_state additional-primary-end-survives adjacent-insertion \
      'AAboundary(x)-EDGEZZ' \
      'active=yes' 'field=1' 'completion=no'
  fi
else
  fail additional-primary-end-survives \
    "completion with an adjacent zero-length insertion did not open"
fi

if run_mx lem-yath-test-lsp-snippet-read-only-preflight-setup &&
   lem_wait_for "$session" 'READ-ONLY-PREFLIGHT-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state read-only-preflight; then
    assert_state read-only-preflight-atomic read-only-preflight 'AAfoTAILZZ' \
      'active=no' 'field=none' 'completion=no'
  fi
else
  fail read-only-preflight-atomic \
    "mixed writable/read-only completion did not open"
fi

if run_mx lem-yath-test-lsp-snippet-transaction-rollback-setup &&
   lem_wait_for "$session" 'TRANSACTION-ROLLBACK-SNIPPET' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state transaction-rollback; then
    assert_state throwing-hook-transaction-rollback transaction-rollback \
      'AAfoTAILZZ' 'active=no' 'field=none' 'completion=no' \
      'point=5' 'hook=yes' 'group=no' 'history=yes'
  fi
else
  fail throwing-hook-transaction-rollback \
    "transaction rollback completion did not open"
fi

if run_mx lem-yath-test-lsp-snippet-resolve-setup &&
   lem_wait_for "$session" 'RESOLVE-SNIPPET' 10 >/dev/null; then
  if (( $(report_count '^RESOLVE ') != 0 )); then
    fail resolve-deferred "completion resolved before it was accepted"
  else
    pass resolve-deferred "candidate remained unresolved while merely focused"
  fi
  lem_keys "$session" Enter
  sleep 0.4
  if wait_report '^RESOLVE count=1 label=RESOLVE-SNIPPET token=acceptance$' 10 &&
     record_state resolve; then
    assert_state resolve-on-accept resolve 'RES-resolved(name)-OK' \
      'active=yes' 'field=1' 'completion=no'
    sleep 0.4
    if (( $(report_count '^RESOLVE ') == 1 )); then
      pass resolve-exactly-once "acceptance issued one completionItem/resolve request"
    else
      fail resolve-exactly-once \
        "expected one resolve request, found $(report_count '^RESOLVE ')"
    fi
  else
    fail resolve-on-accept "acceptance did not issue the expected resolve request"
  fi
else
  fail resolve-on-accept "resolvable completion did not open"
fi

if run_mx lem-yath-test-lsp-snippet-resolve-error-setup &&
   lem_wait_for "$session" 'RESOLVE-ERROR-SNIPPET' 10 >/dev/null; then
  if (( $(report_count 'label=RESOLVE-ERROR-SNIPPET ') != 0 )); then
    fail resolve-error-deferred "failing candidate resolved before acceptance"
  else
    pass resolve-error-deferred "failing candidate remained unresolved while focused"
  fi
  lem_keys "$session" Enter
  sleep 0.4
  if wait_report \
       '^RESOLVE count=1 label=RESOLVE-ERROR-SNIPPET token=error$' 10 &&
     record_state resolve-error; then
    assert_state resolve-error-fallback resolve-error 'ORIG-once(value)ZZ' \
      'active=yes' 'field=1' 'completion=no'
    if (( $(report_count 'label=RESOLVE-ERROR-SNIPPET ') == 1 )); then
      pass resolve-error-exactly-once \
        "one failed resolve fell back to the original composite insertion"
    else
      fail resolve-error-exactly-once \
        "expected one failed resolve request, found $(report_count 'label=RESOLVE-ERROR-SNIPPET ')"
    fi
  else
    fail resolve-error-fallback \
      "failed resolve did not fall back to the original completion"
  fi
else
  fail resolve-error-fallback "resolve-error completion did not open"
fi

if run_mx lem-yath-test-lsp-snippet-resolve-conflict-setup &&
   lem_wait_for "$session" 'RESOLVE-CONFLICT-SNIPPET' 10 >/dev/null; then
  if (( $(report_count 'label=RESOLVE-CONFLICT-SNIPPET ') != 0 )); then
    fail resolve-conflict-deferred \
      "conflicting resolved item was requested before acceptance"
  else
    pass resolve-conflict-deferred \
      "conflicting candidate remained unresolved while focused"
  fi
  lem_keys "$session" Enter
  sleep 0.4
  if wait_report \
       '^RESOLVE count=1 label=RESOLVE-CONFLICT-SNIPPET token=conflict$' 10 &&
     record_state resolve-conflict; then
    assert_state resolve-conflict-stable-primary resolve-conflict \
      'NEW-stable(name, name)-EXTRA' \
      'active=yes' 'field=1' 'completion=no'
    if (( $(report_count 'label=RESOLVE-CONFLICT-SNIPPET ') == 1 )); then
      pass resolve-conflict-exactly-once \
        "resolved extras were imported by one acceptance request"
    else
      fail resolve-conflict-exactly-once \
        "expected one conflicting resolve request, found $(report_count 'label=RESOLVE-CONFLICT-SNIPPET ')"
    fi
  else
    fail resolve-conflict-stable-primary \
      "conflicting partial resolve did not preserve the original primary edit"
  fi
else
  fail resolve-conflict-stable-primary "resolve-conflict completion did not open"
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

if run_mx lem-yath-test-lsp-snippet-empty-fallback-setup &&
   lem_wait_for "$session" 'labelFallback' 10 >/dev/null; then
  lem_keys "$session" Enter
  sleep 0.4
  if record_state empty-fallback; then
    assert_state empty-completion-string-fallback empty-fallback \
      'labelFallback' 'active=no' 'completion=no'
  fi
else
  fail empty-completion-string-fallback \
    "empty filterText did not fall back to the completion label"
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
sed -n '1,480p' "$LEM_YATH_LSP_SNIPPET_TEST_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "LSP SNIPPET TEST PASSED"
  exit 0
else
  echo "LSP SNIPPET TEST FAILED"
  exit 1
fi
