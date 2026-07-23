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

contract_once() {
  lem_keys "$session" F7
  sleep 0.25
}

contract_via_mx() {
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  lem_keys "$session" -l expreg-contract
  sleep 0.15
  lem_keys "$session" Enter
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

assert_stale_contract_noop() {
  local before line expected_hex
  before=$(report_count '^STALE ')
  lem_keys "$session" F6
  if ! wait_report_count '^STALE ' "$((before + 1))"; then
    fail python-contract-stale-tick-noop 'stale contraction probe did not run'
    return
  fi
  line=$(grep '^STALE ' "$report" | tail -n 1)
  expected_hex=$(hex_of 'foo + bar')
  if [[ "$line" == *'visual=yes '* &&
        "$line" == *"selection-hex=$expected_hex" ]]; then
    pass python-contract-stale-tick-noop \
      'a stale buffer tick invalidated the contraction stack'
  else
    fail python-contract-stale-tick-noop \
      "stale contraction changed the active range: $line"
  fi
}

export LEM_YATH_EXPREG_REPORT="$report"
export LEM_YATH_EXPREG_PYTHON_EXPRESSION="$root/expression.py"
export LEM_YATH_EXPREG_PYTHON_DECOY="$root/decoy.py"
export LEM_YATH_EXPREG_PYTHON_MALFORMED="$root/malformed.py"
export LEM_YATH_EXPREG_PYTHON_MALFORMED_NESTED="$root/malformed-nested.py"
export LEM_YATH_EXPREG_JSON="$root/data.json"
export LEM_YATH_EXPREG_JSON_STRING="$root/string.json"
export LEM_YATH_EXPREG_RUST="$root/expression.rs"
export LEM_YATH_EXPREG_FALLBACK="$root/fallback.txt"

printf '%s\n' \
  'result = outer(prefix, inner("(", café_value + 1), wrap(foo + bar))' \
  >"$LEM_YATH_EXPREG_PYTHON_EXPRESSION"
printf '%s\n%s\n%s\n' \
  'message = render("fake ( delimiter ) tail", café_value)' \
  'escaped = render("fake \( escaped_token ) tail", value)' \
  'block = """fake { block_item } tail"""' \
  >"$LEM_YATH_EXPREG_PYTHON_DECOY"
printf '%s\n%s\n' 'result = fn(' '    alpha + beta' \
  >"$LEM_YATH_EXPREG_PYTHON_MALFORMED"
printf '%s\n' 'result = fn(inner(alpha + beta), gamma + delta' \
  >"$LEM_YATH_EXPREG_PYTHON_MALFORMED_NESTED"
printf '%s\n' \
  '{"outer": {"items": ["(", {"café": 42}, true]}, "tail": 0}' \
  >"$LEM_YATH_EXPREG_JSON"
printf '%s\n' '{"text": "fake [ item ] tail"}' \
  >"$LEM_YATH_EXPREG_JSON_STRING"
printf '%s\n' 'fn main() { let result = outer(inner(value + 1)); }' \
  >"$LEM_YATH_EXPREG_RUST"
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

if wait_report_count '^COMMAND contract=yes$' 1; then
  pass contract-command 'M-x expreg-contract is registered'
else
  fail contract-command 'expreg-contract is absent from the command registry'
fi

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
  contract_once
  assert_selection python-contract-call python-expression \
    'outer(prefix, inner("(", café_value + 1), wrap(foo + bar))'
  contract_once
  assert_selection python-contract-arguments python-expression \
    '(prefix, inner("(", café_value + 1), wrap(foo + bar))'
  expand_once
  assert_selection python-expand-after-contract python-expression \
    'outer(prefix, inner("(", café_value + 1), wrap(foo + bar))'
else
  fail python-open 'Python expression fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-cache-sibling \
             python-cache-sibling; then
  lem_keys "$session" v
  sleep 0.2
  expand_once
  assert_selection python-cache-new-visual-word python-cache-sibling 'bar'
  contract_once
  assert_selection python-contract-first-level-noop python-cache-sibling 'bar'
  expand_once
  assert_selection python-cache-new-visual-syntax python-cache-sibling \
    'foo + bar'
  if contract_via_mx; then
    assert_selection python-contract-via-mx python-cache-sibling 'bar'
    expand_once
    assert_selection python-reexpand-new-sequence python-cache-sibling \
      'foo + bar'
    assert_stale_contract_noop
  else
    fail python-contract-via-mx 'M-x prompt did not accept expreg-contract'
  fi
else
  fail python-cache-open 'Python cache sibling fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-arbitrary python-arbitrary; then
  # Forward Visual endpoint is the plus sign.  Pinned Expreg generates from
  # that endpoint, skips no smaller region, and replaces the arbitrary range
  # with the containing binary expression.
  lem_keys "$session" v
  lem_keys "$session" 6 l
  sleep 0.2
  assert_selection python-arbitrary-forward-seed python-arbitrary 'value +'
  expand_once
  assert_selection python-arbitrary-forward python-arbitrary \
    'café_value + 1'
  contract_once
  assert_selection python-arbitrary-forward-contract-noop python-arbitrary \
    'café_value + 1'

  # Reversing the same Visual selection puts the endpoint on "v".  The
  # generated word is skipped into Expreg's previous stack, so expansion lands
  # on the symbol and contraction descends to the generated word—not to the
  # arbitrary original range.
  open_case lem-yath-test-expreg-open-python-arbitrary python-arbitrary
  lem_keys "$session" 6 l
  lem_keys "$session" v
  lem_keys "$session" 6 h
  sleep 0.2
  assert_selection python-arbitrary-reverse-seed python-arbitrary 'value +'
  expand_once
  assert_selection python-arbitrary-reverse python-arbitrary 'café_value'
  contract_once
  assert_selection python-arbitrary-reverse-contract python-arbitrary 'value'
  contract_once
  assert_selection python-arbitrary-reverse-floor python-arbitrary 'value'
  expand_once
  assert_selection python-arbitrary-reverse-reexpand python-arbitrary \
    'café_value'
else
  fail python-arbitrary-open 'Python arbitrary Visual fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-decoy python-decoy; then
  expand_once
  assert_selection python-string-word python-decoy 'delimiter'
  expand_once
  assert_selection python-string-list-inner python-decoy ' delimiter '
  expand_once
  assert_selection python-string-list-outer python-decoy '( delimiter )'
  contract_once
  assert_selection python-string-list-contract python-decoy ' delimiter '
  expand_once
  assert_selection python-string-list-reexpand python-decoy '( delimiter )'
  expand_once
  assert_selection python-string-content python-decoy \
    'fake ( delimiter ) tail'
  expand_once
  assert_selection python-string-quoted python-decoy \
    '"fake ( delimiter ) tail"'
  expand_once
  assert_selection python-string-arguments python-decoy \
    '"fake ( delimiter ) tail", café_value'
  expand_once
  assert_selection python-string-arguments-outer python-decoy \
    '("fake ( delimiter ) tail", café_value)'
  expand_once
  assert_selection python-string-call python-decoy \
    'render("fake ( delimiter ) tail", café_value)'
  expand_once
  assert_selection python-string-assignment python-decoy \
    'message = render("fake ( delimiter ) tail", café_value)'
  expand_once
  assert_selection python-string-exhaustion python-decoy \
    'message = render("fake ( delimiter ) tail", café_value)'
else
  fail python-decoy-open 'Python string-decoy fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-escaped-list \
             python-escaped-list; then
  expand_once
  assert_selection python-escaped-list-word python-escaped-list 'escaped'
  expand_once
  assert_selection python-escaped-list-symbol python-escaped-list \
    'escaped_token'
  expand_once
  assert_selection python-escaped-list-content python-escaped-list \
    'fake \( escaped_token ) tail'
  expand_once
  assert_selection python-escaped-list-quoted python-escaped-list \
    '"fake \( escaped_token ) tail"'
else
  fail python-escaped-list-open 'Python escaped-list fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-block-string \
             python-block-string; then
  expand_once
  assert_selection python-block-string-word python-block-string 'block'
  expand_once
  assert_selection python-block-string-symbol python-block-string 'block_item'
  expand_once
  assert_selection python-block-string-inner python-block-string ' block_item '
  expand_once
  assert_selection python-block-string-outer python-block-string '{ block_item }'
  expand_once
  assert_selection python-block-string-content python-block-string \
    'fake { block_item } tail'
  expand_once
  assert_selection python-block-string-quoted python-block-string \
    '"""fake { block_item } tail"""'
else
  fail python-block-string-open 'Python block-string fixture did not open'
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

if open_case lem-yath-test-expreg-open-json-string-list json-string-list; then
  expand_once
  assert_selection json-string-list-word json-string-list 'item'
  expand_once
  assert_selection json-string-list-inner json-string-list ' item '
  expand_once
  assert_selection json-string-list-outer json-string-list '[ item ]'
  expand_once
  assert_selection json-string-list-content json-string-list \
    'fake [ item ] tail'
  expand_once
  assert_selection json-string-list-quoted json-string-list \
    '"fake [ item ] tail"'
else
  fail json-string-list-open 'JSON string-list fixture did not open'
fi

if open_case lem-yath-test-expreg-open-rust rust; then
  expand_once
  assert_selection rust-word rust 'value'
  expand_once
  assert_selection rust-binary rust 'value + 1'
  expand_once
  assert_selection rust-inner-arguments rust '(value + 1)'
  expand_once
  assert_selection rust-inner-call rust 'inner(value + 1)'
  expand_once
  assert_selection rust-outer-arguments rust '(inner(value + 1))'
  expand_once
  assert_selection rust-outer-call rust 'outer(inner(value + 1))'
else
  fail rust-open 'Rust fixture did not open with parser-backed expansion'
fi

if open_case lem-yath-test-expreg-open-python-malformed python-malformed; then
  expand_once
  expand_once
  assert_selection malformed-clean-subtree python-malformed 'alpha + beta'
  expand_once
  assert_selection malformed-inner-partial python-malformed \
    $'\n    alpha + bet'
  expand_once
  assert_selection malformed-outer-partial python-malformed \
    $'(\n    alpha + beta'
  expand_once
  assert_selection malformed-error python-malformed \
    $'result = fn(\n    alpha + beta'
  contract_once
  assert_selection malformed-contract-outer python-malformed \
    $'(\n    alpha + beta'
  contract_once
  assert_selection malformed-contract-inner python-malformed \
    $'\n    alpha + bet'
  contract_once
  assert_selection malformed-contract-binary python-malformed 'alpha + beta'
  expand_once
  assert_selection malformed-reexpand-inner python-malformed \
    $'\n    alpha + bet'
else
  fail malformed-open 'malformed Python fixture did not open'
fi

if open_case lem-yath-test-expreg-open-python-malformed-nested \
             python-malformed-nested; then
  expand_once
  expand_once
  assert_selection malformed-nested-binary python-malformed-nested \
    'alpha + beta'
  expand_once
  assert_selection malformed-nested-inner-list python-malformed-nested \
    '(alpha + beta)'
  expand_once
  assert_selection malformed-nested-inner-call python-malformed-nested \
    'inner(alpha + beta)'
  expand_once
  assert_selection malformed-nested-outer-partial python-malformed-nested \
    '(inner(alpha + beta)'
  expand_once
  assert_selection malformed-nested-error python-malformed-nested \
    'result = fn(inner(alpha + beta), gamma + delta'
  contract_once
  assert_selection malformed-nested-contract-outer python-malformed-nested \
    '(inner(alpha + beta)'
  contract_once
  assert_selection malformed-nested-contract-call python-malformed-nested \
    'inner(alpha + beta)'
  contract_once
  assert_selection malformed-nested-contract-list python-malformed-nested \
    '(alpha + beta)'
  expand_once
  assert_selection malformed-nested-reexpand-call python-malformed-nested \
    'inner(alpha + beta)'
else
  fail malformed-nested-open 'nested malformed Python fixture did not open'
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
