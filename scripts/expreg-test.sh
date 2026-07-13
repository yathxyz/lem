#!/usr/bin/env bash
# Parser-backed Expreg progressions through the configured real ncurses editor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-expreg-$$}"
session="lem-yath-expreg-$id"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-expreg.XXXXXX")"
report="$root/report"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() {
  printf 'PASS  %-30s %s\n' "$1" "$2"
}

fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  lem_capture "$session" >&2 2>/dev/null || true
}

hex_of() {
  local value="$1"
  python3 - "$value" <<'PY'
import sys
print("".join(f"{ord(char):02X}" for char in sys.argv[1]))
PY
}

report_count() {
  local count
  count=$(grep -cE "$1" "$report" 2>/dev/null || true)
  printf '%s\n' "${count:-0}"
}

wait_report_count() {
  local pattern="$1" expected="$2" timeout="${3:-12}" i=0
  while (( i < timeout * 4 )); do
    if [ "$(report_count "$pattern")" -ge "$expected" ]; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

run_mx() {
  local command="$1"
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" M-x
  sleep 0.15
  lem_keys "$session" -l "$command"
  lem_keys "$session" Enter
  sleep 0.25
}

open_case() {
  local command="$1" label="$2" before
  before=$(report_count "^OPEN label=$label ")
  run_mx "$command"
  wait_report_count "^OPEN label=$label " "$((before + 1))"
}

expand_once() {
  lem_keys "$session" Space
  sleep 0.15
  lem_keys "$session" v
  sleep 0.25
}

assert_selection() {
  local name="$1" label="$2" expected="$3" before line expected_hex
  before=$(report_count '^STATE index=')
  lem_keys "$session" F8
  if ! wait_report_count '^STATE index=' "$((before + 1))"; then
    fail "$name" 'selection probe did not run'
    return
  fi
  line=$(grep '^STATE index=' "$report" | tail -n 1)
  expected_hex=$(hex_of "$expected")
  if [[ "$line" == *"label=$label "* &&
        "$line" == *'visual=yes '* &&
        "$line" == *"selection-hex=$expected_hex" ]]; then
    pass "$name" "selected [$expected]"
  else
    fail "$name" "expected [$expected], got: $line"
  fi
}

export LEM_YATH_EXPREG_REPORT="$report"
export LEM_YATH_EXPREG_PYTHON_EXPRESSION="$root/expression.py"
export LEM_YATH_EXPREG_PYTHON_DECOY="$root/decoy.py"
export LEM_YATH_EXPREG_PYTHON_MALFORMED="$root/malformed.py"
export LEM_YATH_EXPREG_JSON="$root/data.json"
export LEM_YATH_EXPREG_FALLBACK="$root/fallback.txt"

printf '%s\n' \
  'result = outer(prefix, inner("(", café_value + 1), wrap(foo + bar))' \
  >"$LEM_YATH_EXPREG_PYTHON_EXPRESSION"
printf '%s\n' 'message = render("fake ( delimiter", café_value)' \
  >"$LEM_YATH_EXPREG_PYTHON_DECOY"
printf '%s\n%s\n' 'result = fn(' '    alpha + beta' \
  >"$LEM_YATH_EXPREG_PYTHON_MALFORMED"
printf '%s\n' \
  '{"outer": {"items": ["(", {"café": 42}, true]}, "tail": 0}' \
  >"$LEM_YATH_EXPREG_JSON"
printf '%s\n\n%s\n' 'one < ((alpha beta)) > three' 'next' \
  >"$LEM_YATH_EXPREG_FALLBACK"

fixture="$(lem-yath_lisp_string "$here/scripts/expreg-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"
if ! lem_wait_for "$session" 'Dashboard' 40 >/dev/null ||
   ! wait_report_count '^READY$' 1 40; then
  fail boot 'configured Lem did not load the Expreg fixture'
  exit 1
fi
pass boot 'configured Lem loaded the Expreg fixture'

if open_case lem-yath-test-expreg-open-python-expression python-expression; then
  expand_once
  assert_selection python-subword python-expression 'value'
  expand_once
  assert_selection python-symbol python-expression 'café_value'
  expand_once
  assert_selection python-binary python-expression 'café_value + 1'
  expand_once
  assert_selection python-inner-arguments python-expression \
    '"(", café_value + 1'
  expand_once
  assert_selection python-inner-arguments-outer python-expression \
    '("(", café_value + 1)'
  expand_once
  assert_selection python-inner-call python-expression \
    'inner("(", café_value + 1)'
  expand_once
  assert_selection python-outer-arguments python-expression \
    '(prefix, inner("(", café_value + 1), wrap(foo + bar))'
  expand_once
  assert_selection python-outer-call python-expression \
    'outer(prefix, inner("(", café_value + 1), wrap(foo + bar))'
  expand_once
  assert_selection python-assignment python-expression \
    'result = outer(prefix, inner("(", café_value + 1), wrap(foo + bar))'
  expand_once
  assert_selection python-exhaustion python-expression \
    'result = outer(prefix, inner("(", café_value + 1), wrap(foo + bar))'
else
  fail python-open 'Python expression fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-cache-sibling \
             python-cache-sibling; then
  lem_keys "$session" v
  sleep 0.2
  expand_once
  assert_selection python-cache-new-visual-word python-cache-sibling 'bar'
  expand_once
  assert_selection python-cache-new-visual-syntax python-cache-sibling \
    'foo + bar'
else
  fail python-cache-open 'Python cache sibling fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-decoy python-decoy; then
  expand_once
  assert_selection python-string-word python-decoy 'delimiter'
  expand_once
  assert_selection python-string-content python-decoy 'fake ( delimiter'
  expand_once
  assert_selection python-string-quoted python-decoy '"fake ( delimiter"'
  expand_once
  assert_selection python-string-arguments python-decoy \
    '"fake ( delimiter", café_value'
  expand_once
  assert_selection python-string-arguments-outer python-decoy \
    '("fake ( delimiter", café_value)'
  expand_once
  assert_selection python-string-call python-decoy \
    'render("fake ( delimiter", café_value)'
  expand_once
  assert_selection python-string-assignment python-decoy \
    'message = render("fake ( delimiter", café_value)'
  expand_once
  assert_selection python-string-exhaustion python-decoy \
    'message = render("fake ( delimiter", café_value)'
else
  fail python-decoy-open 'Python string-decoy fixture did not open'
fi

if open_case lem-yath-test-expreg-open-json json; then
  expand_once
  assert_selection json-key-word json 'café'
  expand_once
  assert_selection json-key-string json '"café"'
  expand_once
  assert_selection json-pair json '"café": 42'
  expand_once
  assert_selection json-inner-object json '{"café": 42}'
  expand_once
  assert_selection json-array json '["(", {"café": 42}, true]'
  expand_once
  assert_selection json-items-pair json \
    '"items": ["(", {"café": 42}, true]'
  expand_once
  assert_selection json-enclosing-object json \
    '{"items": ["(", {"café": 42}, true]}'
  expand_once
  assert_selection json-outer-pair json \
    '"outer": {"items": ["(", {"café": 42}, true]}'
  expand_once
  assert_selection json-root-object json \
    '{"outer": {"items": ["(", {"café": 42}, true]}, "tail": 0}'
  expand_once
  assert_selection json-buffer-paragraph json \
    $'{"outer": {"items": ["(", {"café": 42}, true]}, "tail": 0}\n'
  expand_once
  assert_selection json-exhaustion json \
    $'{"outer": {"items": ["(", {"café": 42}, true]}, "tail": 0}\n'
else
  fail json-open 'JSON fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-malformed python-malformed; then
  expand_once
  expand_once
  assert_selection malformed-clean-subtree python-malformed 'alpha + beta'
  expand_once
  assert_selection malformed-assignment python-malformed \
    $'result = fn(\n    alpha + beta'
  expand_once
  assert_selection malformed-exhaustion python-malformed \
    $'result = fn(\n    alpha + beta'
else
  fail malformed-open 'malformed Python fixture did not open'
fi

if open_case lem-yath-test-expreg-open-fallback fallback; then
  expand_once
  assert_selection fallback-word fallback 'alpha'
  expand_once
  assert_selection fallback-inner fallback 'alpha beta'
  expand_once
  assert_selection fallback-first-pair fallback '(alpha beta)'
  expand_once
  assert_selection fallback-second-pair fallback '((alpha beta))'
  expand_once
  assert_selection fallback-paragraph fallback \
    $'one < ((alpha beta)) > three\n'
  expand_once
  assert_selection fallback-exhaustion fallback \
    $'one < ((alpha beta)) > three\n'
else
  fail fallback-open 'plain-text fallback fixture did not open'
fi

if [ "$failed" -eq 0 ]; then
  printf '%s\n' 'All parser-backed Expreg checks passed.'
else
  sed -n '1,240p' "$report" >&2 || true
fi
exit "$failed"
