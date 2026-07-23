#!/usr/bin/env bash
# Combined real-ncurses acceptance coverage for EditorConfig and formatting.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-formatting-$$}"
if ! root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-formatting.XXXXXX")"; then
  echo "Could not create the formatting test directory." >&2
  exit 1
fi
case "$root" in
  "" | /)
    echo "Refusing unsafe formatting test directory: $root" >&2
    exit 1
    ;;
esac

session="lem-yath-formatting-$id"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_FORMATTING_REPORT="$root/report"
export LEM_YATH_FAKE_FORMATTER_EVENTS="$root/formatter-events.jsonl"
export LEM_YATH_FAKE_FORMATTER_MODE_FILE="$root/formatter-mode"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" "$root/bin"
: >"$LEM_YATH_FORMATTING_REPORT"
: >"$LEM_YATH_FAKE_FORMATTER_EVENTS"
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"

source "$here/scripts/tui-driver.sh"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-formatting.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe formatting-test cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

failed=0
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"

pass() { printf 'PASS  %-31s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-31s %s\n' "$1" "$2" >&2
}

die() {
  fail "$1" "$2"
  printf '%s\n' '--- Lem screen ---' >&2
  lem_capture "$session" >&2 || true
  printf '%s\n' '--- fixture report ---' >&2
  sed -n '1,260p' "$LEM_YATH_FORMATTING_REPORT" >&2 || true
  exit 1
}

for program in editorconfig python3 timeout; do
  if ! command -v "$program" >/dev/null 2>&1; then
    printf 'FAIL  %-31s %s\n' prerequisites \
      "$program is required by formatting-test.sh" >&2
    exit 1
  fi
done

fake_formatter="$here/scripts/fake-formatter.py"
if [ ! -x "$fake_formatter" ]; then
  printf 'FAIL  %-31s %s\n' prerequisites \
    "$fake_formatter must be executable" >&2
  exit 1
fi
export LEM_YATH_TEST_PYTHON
export LEM_YATH_TEST_FAKE_FORMATTER="$fake_formatter"
LEM_YATH_TEST_PYTHON="$(command -v python3)"
export LEM_YATH_TEST_GOOGLE_JAVA_FORMAT
LEM_YATH_TEST_GOOGLE_JAVA_FORMAT="$(command -v google-java-format)"
printf '%s\n' \
  "#!$(command -v bash)" \
  'exec "$LEM_YATH_TEST_PYTHON" "$LEM_YATH_TEST_FAKE_FORMATTER" "$@"' \
  >"$root/bin/black"
chmod +x "$root/bin/black"
export PATH="$root/bin:$PATH"

tree="$root/tree"
project="$tree/project"
nested="$project/nested"
false_dir="$project/false"
mkdir -p "$nested" "$false_dir"

# This property must not cross the root=true boundary below.
printf '%s\n' \
  '[*]' \
  'max_line_length = 13' \
  'tab_width = 99' \
  >"$tree/.editorconfig"

printf '%s\n' \
  'root = true' \
  '' \
  '[*]' \
  'indent_style = tab' \
  'indent_size = 7' \
  'tab_width = 7' \
  'trim_trailing_whitespace = false' \
  'insert_final_newline = true' \
  'end_of_line = crlf' \
  'charset = latin1' \
  '' \
  '[*.py]' \
  'indent_style = space' \
  'indent_size = 2' \
  'trim_trailing_whitespace = true' \
  '' \
  '[true.fmtfixture]' \
  'trim_trailing_whitespace = true' \
  '' \
  '[normalize-error.fmtfixture]' \
  'trim_trailing_whitespace = false' \
  >"$project/.editorconfig"

printf '%s\n' \
  '[*.py]' \
  'indent_size = 6' \
  'trim_trailing_whitespace = unset' \
  'insert_final_newline = false' \
  'end_of_line = lf' \
  'charset = utf-8' \
  '' \
  '[unset.fmtfixture]' \
  'trim_trailing_whitespace = unset' \
  'insert_final_newline = false' \
  'end_of_line = lf' \
  'charset = utf-8' \
  >"$nested/.editorconfig"

printf '%s\n' \
  '[false.fmtfixture]' \
  'trim_trailing_whitespace = false' \
  'insert_final_newline = true' \
  'end_of_line = cr' \
  'charset = utf-8' \
  >"$false_dir/.editorconfig"

export LEM_YATH_FORMATTING_TRUE="$project/true.fmtfixture"
export LEM_YATH_FORMATTING_NORMALIZE_ERROR="$project/normalize-error.fmtfixture"
export LEM_YATH_FORMATTING_UNSET="$nested/unset.fmtfixture"
export LEM_YATH_FORMATTING_FALSE="$false_dir/false.fmtfixture"
export LEM_YATH_FORMATTING_BYTES="$project/bytes.txt"
export LEM_YATH_FORMATTING_MANUAL="$nested/"'manual ; $(touch FORMATTER_INJECTED).py'
export LEM_YATH_FORMATTING_JAVA="$nested/Main.java"
export LEM_YATH_FORMATTING_AUTO="$nested/automatic.py"
export LEM_YATH_FORMATTING_FAILURE="$nested/failure.py"
export LEM_YATH_FORMATTING_TRANSACTION_MANUAL="$nested/transaction-manual.py"
export LEM_YATH_FORMATTING_TRANSACTION_AUTO="$nested/transaction-auto.py"
export LEM_YATH_FORMATTING_TRANSACTION_FINALIZER="$nested/transaction-finalizer.py"
export LEM_YATH_FORMATTING_FINALIZER_MARK="$project/finalizer-mark.py"
export LEM_YATH_FORMATTING_ROLLBACK_FAILURE="$nested/rollback-failure.py"
export LEM_YATH_FORMATTING_READ_ONLY="$nested/read-only.py"

whitespace_initial=$'untouched   \ntouched   '
printf '%s' "$whitespace_initial" >"$LEM_YATH_FORMATTING_TRUE"
printf '%s' $'left   \nright   \nclean' >"$LEM_YATH_FORMATTING_NORMALIZE_ERROR"
printf '%s' "$whitespace_initial" >"$LEM_YATH_FORMATTING_UNSET"
printf '%s' "$whitespace_initial" >"$LEM_YATH_FORMATTING_FALSE"
printf '%s' 'initial bytes' >"$LEM_YATH_FORMATTING_BYTES"

python_initial=$'prefix_value=1\nKEEP_MARKER = "stay"\nTAIL_MARKER=2'
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_MANUAL"
java_initial=$'package example;\npublic class Main{public static void main(String[]args){System.out.println("hi");}}'
printf '%s' "$java_initial" >"$LEM_YATH_FORMATTING_JAVA"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_AUTO"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_FAILURE"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_TRANSACTION_MANUAL"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_TRANSACTION_AUTO"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_TRANSACTION_FINALIZER"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_READ_ONLY"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_ROLLBACK_FAILURE"
printf '%s' $'prefix_value=1   \nKEEP_MARKER = "stay"   \nTAIL_MARKER=2   ' \
  >"$LEM_YATH_FORMATTING_FINALIZER_MARK"

report_count() {
  grep -cE "$1" "$LEM_YATH_FORMATTING_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

event_count() {
  grep -c '^{' "$LEM_YATH_FAKE_FORMATTER_EVENTS" 2>/dev/null || true
}

wait_event_count() {
  local expected=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(event_count) >= expected )); then
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
  sleep 0.4
}

open_fixture() {
  local command=$1 label=$2 before
  before=$(report_count "^OPEN label=$label ")
  run_mx "$command" &&
    wait_report_count "^OPEN label=$label " "$((before + 1))"
}

record_state() {
  local label=$1 before
  before=$(report_count "^STATE label=$label ")
  lem_keys "$session" F5
  wait_report_count "^STATE label=$label " "$((before + 1))"
}

last_state() {
  grep -E "^STATE label=$1 " "$LEM_YATH_FORMATTING_REPORT" | tail -n 1
}

hex_of() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
}

assert_state_hex() {
  local name=$1 label=$2 text_hex=$3 disk_hex=$4 modified=$5 line
  line=$(last_state "$label")
  if [[ "$line" == *"text-hex=$text_hex disk-hex=$disk_hex modified=$modified "* ]]; then
    pass "$name" "$label has the expected buffer and disk bytes"
  else
    fail "$name" "unexpected state: $line"
  fi
}

assert_no_formatter_events() {
  local name=$1 before=$2 after
  after=$(event_count)
  if [ "$after" -eq "$before" ]; then
    pass "$name" 'save did not invoke a CLI formatter'
  else
    fail "$name" "formatter count changed from $before to $after"
  fi
}

save_and_record() {
  local label=$1
  lem_keys "$session" C-x C-s
  sleep 0.5
  record_state "$label"
}

send_leader_format() {
  lem_keys "$session" Space
  sleep 0.12
  lem_keys "$session" b
  sleep 0.12
  lem_keys "$session" f
}

# This direct probe is intentionally the official executable, before Lem is
# started and before any fake program could stand in for EditorConfig.
if resolved=$(editorconfig "$LEM_YATH_FORMATTING_MANUAL" 2>&1) &&
   grep -q '^indent_size=6$' <<<"$resolved" &&
   grep -q '^tab_width=7$' <<<"$resolved" &&
   grep -q '^trim_trailing_whitespace=unset$' <<<"$resolved" &&
   ! grep -q '^max_line_length=' <<<"$resolved"; then
  pass official-editorconfig \
    'the official CLI resolves closer precedence, unset, and root=true'
else
  printf '%s\n' "$resolved" >&2
  fail official-editorconfig 'the official CLI returned unexpected properties'
fi

fixture="$(lem-yath_lisp_string "$here/scripts/formatting-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"
if ! lem_wait_for "$session" 'Dashboard' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the formatting fixture'
fi
pass boot 'configured Lem loaded the formatting fixture in ncurses'

java_expected_file="$root/java-expected"
printf '%s' "$java_initial" | "$LEM_YATH_TEST_GOOGLE_JAVA_FORMAT" - \
  >"$java_expected_file"
java_expected_hex=$(od -An -tx1 "$java_expected_file" | tr -d ' \n' | tr '[:lower:]' '[:upper:]')
if open_fixture lem-yath-test-formatting-open-java java-open &&
   run_mx lem-yath-test-formatting-java-checks &&
   wait_report_count '^SUMMARY JAVA PASS failures=0$' 1; then
  pass java-configuration \
    'Java mode resolves the packaged formatter while JDTLS remains manual'
  send_leader_format
  if lem_wait_for "$session" 'Formatted with JAVA' 30 >/dev/null &&
     record_state java-open; then
    assert_state_hex java-manual-format java-open \
      "$java_expected_hex" "$(hex_of "$java_initial")" yes
  else
    fail java-manual-format 'SPC b f did not complete with google-java-format'
  fi
else
  fail java-configuration 'Java mode, formatter, or manual-JDTLS assertions failed'
fi

if open_fixture lem-yath-test-formatting-open-manual manual-open &&
   run_mx lem-yath-test-formatting-static-checks &&
   wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  pass open-properties \
    'real find-file applied root, precedence, unset, indentation, and the Python backend'
else
  fail open-properties 'one or more open-time property assertions failed'
fi

reload_before=$(report_count '^RELOAD ')
if run_mx lem-yath-test-formatting-reload &&
   wait_report_count '^RELOAD ' "$((reload_before + 1))" &&
   grep -q '^RELOAD editorconfig-hooks=yes formatting-hooks=yes properties=yes spec=yes$' \
     "$LEM_YATH_FORMATTING_REPORT"; then
  pass reload-safe \
    'loading editorconfig.lisp and formatting.lisp twice preserves hooks and state'
else
  fail reload-safe 'production source reload was not idempotent'
fi

# trim=true escalates from ws-butler to whole-file cleanup.  This buffer also
# proves EditorConfig can override the global no-tabs default locally.
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-true true-open &&
   run_mx lem-yath-test-formatting-touch-true &&
   wait_report_count '^TOUCH label=true-touched modified=yes$' 1 &&
   save_and_record true-touched; then
  true_text=$(hex_of $'untouched\ntouched\n')
  true_disk=$(hex_of $'untouched\r\ntouched\r\n')
  assert_state_hex trim-true-all-lines true-touched \
    "$true_text" "$true_disk" no
  line=$(last_state true-touched)
  if [[ "$line" == *'global-tabs=no local-tabs=yes tab-width=7 editorconfig=yes '* ]]; then
    pass no-tabs-override \
      'global spaces remain the default while EditorConfig can opt one buffer into tabs'
  else
    fail no-tabs-override "unexpected indentation state: $line"
  fi
  assert_no_formatter_events no-formatter-for-unmapped-program-mode "$before"
else
  fail trim-true-all-lines 'true-trim fixture did not complete'
fi

# unset removes the inherited true value, so ordinary touched-line cleanup is
# retained; final-newline=false and LF are asserted byte-for-byte.
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-unset unset-open &&
   run_mx lem-yath-test-formatting-touch-unset &&
   wait_report_count '^TOUCH label=unset-touched modified=yes$' 1 &&
   save_and_record unset-touched; then
  unset_expected=$(hex_of $'untouched   \ntouched')
  assert_state_hex trim-unset-touched-only unset-touched \
    "$unset_expected" "$unset_expected" no
  assert_no_formatter_events trim-unset-no-cli "$before"
else
  fail trim-unset-touched-only 'unset-trim fixture did not complete'
fi

# Explicit false follows the configured ws-butler policy too.  CR and a final
# newline make this distinct from the unset case above.
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-false false-open &&
   run_mx lem-yath-test-formatting-touch-false &&
   wait_report_count '^TOUCH label=false-touched modified=yes$' 1 &&
   save_and_record false-touched; then
  false_text=$(hex_of $'untouched   \ntouched\n')
  false_disk=$(hex_of $'untouched   \rtouched\r')
  assert_state_hex trim-false-touched-only false-touched \
    "$false_text" "$false_disk" no
  assert_no_formatter_events trim-false-no-cli "$before"
else
  fail trim-false-touched-only 'false-trim fixture did not complete'
fi

# An unmapped programming buffer normalizes through one retained transaction.
# A late error after ws-butler cleanup and final-newline normalization restores
# all text. The touched-line marker survives that ordinary save and the next
# edit epoch, so a later successful save retries the missed cleanup.
before=$(event_count)
normalize_before=$(report_count '^NORMALIZE-INJECT label=normalize-error changes=')
if open_fixture lem-yath-test-formatting-open-normalize-error normalize-error &&
   run_mx lem-yath-test-formatting-prepare-normalize-error &&
   wait_report_count '^PREPARE label=normalize-error modified=yes$' 1; then
  after_before=$(report_count '^AFTER-SAVE label=normalize-error ')
  lem_keys "$session" C-x C-s
  if wait_report_count '^NORMALIZE-INJECT label=normalize-error changes=' \
       "$((normalize_before + 1))" 8 &&
     wait_report_count '^AFTER-SAVE label=normalize-error ' \
       "$((after_before + 1))" 8 &&
     record_state normalize-error; then
    normalize_original=$'left   \nright   \nclean'
    normalize_disk=$'left   \r\nright   \r\nclean'
    normalize_hex=$(hex_of "$normalize_original")
    assert_state_hex editorconfig-normalize-rollback normalize-error \
      "$normalize_hex" "$(hex_of "$normalize_disk")" no
    line=$(last_state normalize-error)
    normalize_line=$(grep '^NORMALIZE-INJECT label=normalize-error changes=' \
      "$LEM_YATH_FORMATTING_REPORT" | tail -n 1)
    normalize_forward=${normalize_line##*=}
    if [[ "$line" =~ changes=([0-9]+) ]] &&
       [ "${BASH_REMATCH[1]}" -eq "$((normalize_forward * 2))" ] &&
       [ "$(event_count)" -eq "$before" ] &&
       [[ "$line" == *'shadow=yes '* && "$line" == *'trim=NIL '* &&
          "$line" == *'normalization-pending=yes '* ]]; then
      pass editorconfig-normalize-observers \
        'save normalization rollback restored bytes, observer ranges, and retry state'
    else
      fail editorconfig-normalize-observers \
        "combined save-normalization rollback was incoherent: $line"
    fi
  else
    fail editorconfig-normalize-rollback \
      'save-normalization failure was not observed'
  fi
else
  fail editorconfig-normalize-rollback \
    'save-normalization fixture did not initialize'
fi

if run_mx lem-yath-test-formatting-retry-normalize-error &&
   wait_report_count '^RETRY label=normalize-error modified=yes pending=yes$' 1; then
  after_before=$(report_count '^AFTER-SAVE label=normalize-error ')
  lem_keys "$session" C-x C-s
  if wait_report_count '^AFTER-SAVE label=normalize-error ' \
       "$((after_before + 1))" 8 &&
     record_state normalize-error; then
    normalize_retry=$'left   \nright\nclean\n'
    normalize_retry_disk=$'left   \r\nright\r\nclean\r\n'
    assert_state_hex editorconfig-normalize-retry normalize-error \
      "$(hex_of "$normalize_retry")" "$(hex_of "$normalize_retry_disk")" no
    line=$(last_state normalize-error)
    if [[ "$line" == *'shadow=yes '* &&
          "$line" == *'normalization-pending=no '* ]]; then
      pass editorconfig-normalize-retry-state \
        'a later successful save consumed retained touched-line retry state'
    else
      fail editorconfig-normalize-retry-state \
        "successful retry left incoherent state: $line"
    fi
  else
    fail editorconfig-normalize-retry \
      'successful save did not retry pending normalization'
  fi
else
  fail editorconfig-normalize-retry \
    'pending-normalization retry fixture did not initialize'
fi

# A fundamental-mode local file still receives EditorConfig.  Its subsequent
# write proves Latin-1, CRLF, final-newline=true, and absence of auto-format.
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-bytes bytes-open &&
   run_mx lem-yath-test-formatting-prepare-bytes &&
   wait_report_count '^PREPARE label=bytes-ready modified=yes$' 1 &&
   save_and_record bytes-ready; then
  bytes_text='636166E920200A6C696E650A'
  bytes_disk='636166E920200D0A6C696E650D0A'
  assert_state_hex editorconfig-subsequent-bytes bytes-ready \
    "$bytes_text" "$bytes_disk" no
  line=$(last_state bytes-ready)
  if [[ "$line" == *'editorconfig=yes '* && "$line" == *'formatter=none '* ]]; then
    pass editorconfig-all-local-buffers \
      'a non-programming local file received EditorConfig without a formatter'
  else
    fail editorconfig-all-local-buffers "unexpected prose state: $line"
  fi
  assert_no_formatter_events automatic-programming-only "$before"
else
  fail editorconfig-subsequent-bytes 'byte-encoding fixture did not complete'
fi

# Manual formatting is a real visual-state SPC b f.  It changes only the
# buffer, preserves semantic point/mark anchors, and is one undo unit.
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-manual manual-open &&
   run_mx lem-yath-test-formatting-prepare-manual &&
   wait_report_count '^PREPARE label=manual-ready ' 1; then
  send_leader_format
  if wait_event_count "$((before + 1))" && record_state manual-ready; then
    manual_formatted=$'# formatted by fake black\nprefix_value = 1\nKEEP_MARKER = "stay"\nTAIL_MARKER = 2\n'
    assert_state_hex manual-format-buffer manual-ready \
      "$(hex_of "$manual_formatted")" "$(hex_of "$python_initial")" yes
    line=$(last_state manual-ready)
    if [[ "$line" == *'mark=yes '* && "$line" == *'point-keep=yes mark-tail=yes '* ]]; then
      pass manual-point-mark \
        'manual full-buffer formatting preserved point and active mark by token'
    else
      fail manual-point-mark "point or mark drifted: $line"
    fi
    if [ "$(event_count)" -eq "$((before + 1))" ]; then
      pass manual-one-invocation 'SPC b f invoked Black exactly once'
    else
      fail manual-one-invocation "unexpected formatter count: $(event_count)"
    fi
    manual_real=$(realpath "$LEM_YATH_FORMATTING_MANUAL")
    if python3 "$fake_formatter" --verify-event \
         "$LEM_YATH_FAKE_FORMATTER_EVENTS" "$before" \
         "$manual_real" "$root/bin/black"; then
      pass formatter-argv-safety \
        'timeout and Black argv preserve the weird filename as one argument'
    else
      fail formatter-argv-safety 'formatter argv or timeout wrapping was unsafe'
    fi
    if [ ! -e "$nested/FORMATTER_INJECTED" ] &&
       [ ! -e "$WORKDIR/FORMATTER_INJECTED" ]; then
      pass formatter-no-shell 'metacharacters in the filename executed nothing'
    else
      fail formatter-no-shell 'the weird filename created its injection sentinel'
    fi

    lem_keys "$session" Escape
    sleep 0.35
    lem_keys "$session" u
    sleep 0.4
    if record_state manual-ready; then
      assert_state_hex manual-one-undo manual-ready \
        "$(hex_of "$python_initial")" "$(hex_of "$python_initial")" no
    else
      fail manual-one-undo 'state probe after undo did not run'
    fi
  else
    fail manual-format-buffer 'manual format did not invoke the fake Black process'
  fi
else
  fail manual-format-buffer 'manual formatter fixture did not initialize'
fi

# A formatter edit is a transaction even when an after-change hook throws
# after the first live mutation.  The dirty pre-format state, point, mark, and
# prior undo/redo route must all survive exactly.
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
inject_before=$(report_count '^INJECT label=transaction-manual ')
if open_fixture lem-yath-test-formatting-open-transaction-manual \
     transaction-manual &&
   run_mx lem-yath-test-formatting-prepare-transaction-manual &&
   wait_report_count '^PREPARE label=transaction-manual ' 1; then
  send_leader_format
  if wait_event_count "$((before + 1))" &&
     wait_report_count '^INJECT label=transaction-manual ' \
       "$((inject_before + 1))" &&
     record_state transaction-manual; then
    transaction_dirty=$'# transaction edit\nprefix_value=1\nKEEP_MARKER = "stay"\nTAIL_MARKER=2'
    assert_state_hex manual-transaction-rollback transaction-manual \
      "$(hex_of "$transaction_dirty")" "$(hex_of "$python_initial")" yes
    line=$(last_state transaction-manual)
    if [[ "$line" == *'mark=yes '* &&
          "$line" == *'point-keep=yes mark-tail=yes '* &&
          "$line" == *'lsp=0 changes=4 protected=no shadow=yes '* ]]; then
      pass manual-transaction-anchors \
        'rollback restored anchors and notified observers of both inverse edits'
    else
      fail manual-transaction-anchors "rollback moved an anchor: $line"
    fi
    if [ "$(event_count)" -eq "$((before + 1))" ]; then
      pass manual-transaction-one-invocation \
        'the throwing hook did not cause a formatter retry or fallback'
    else
      fail manual-transaction-one-invocation \
        "unexpected formatter count: $(event_count)"
    fi

    lem_keys "$session" Escape
    sleep 0.25
    lem_keys "$session" u
    sleep 0.4
    if record_state transaction-manual; then
      assert_state_hex manual-transaction-undo transaction-manual \
        "$(hex_of "$python_initial")" "$(hex_of "$python_initial")" no
    else
      fail manual-transaction-undo 'the retained pre-format undo route failed'
    fi
    lem_keys "$session" C-r
    sleep 0.4
    if record_state transaction-manual; then
      assert_state_hex manual-transaction-redo transaction-manual \
        "$(hex_of "$transaction_dirty")" "$(hex_of "$python_initial")" yes
    else
      fail manual-transaction-redo 'the retained pre-format redo route failed'
    fi
  else
    fail manual-transaction-rollback \
      'the one-shot after-change failure was not observed'
  fi
else
  fail manual-transaction-rollback \
    'manual transaction fixture did not initialize'
fi

# A local read-only range is discovered before any hunk can mutate.  The
# refusal adds no undo entry and keeps the known user edit as the first undo.
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-read-only read-only-preflight &&
   run_mx lem-yath-test-formatting-prepare-read-only &&
   wait_report_count '^PREPARE label=read-only-preflight ' 1; then
  send_leader_format
  if wait_event_count "$((before + 1))" &&
     record_state read-only-preflight; then
    read_only_dirty=$'# read-only edit\nprefix_value=1\nKEEP_MARKER = "stay"\nTAIL_MARKER=2'
    initial_hex=$(hex_of "$python_initial")
    assert_state_hex formatter-read-only-preflight read-only-preflight \
      "$(hex_of "$read_only_dirty")" "$initial_hex" yes
    line=$(last_state read-only-preflight)
    if [[ "$line" == *'mark=yes '* &&
          "$line" == *'point-keep=yes mark-tail=yes '* &&
          "$line" == *'lsp=0 changes=0 protected=yes shadow=yes '* ]]; then
      pass formatter-read-only-anchors \
        'preflight emitted no change callbacks and preserved anchors/property'
    else
      fail formatter-read-only-anchors "preflight moved an anchor: $line"
    fi
    lem_keys "$session" Escape
    sleep 0.25
    lem_keys "$session" u
    sleep 0.35
    if record_state read-only-preflight; then
      assert_state_hex formatter-read-only-no-undo read-only-preflight \
        "$initial_hex" "$initial_hex" no
    else
      fail formatter-read-only-no-undo 'state probe after the known user undo failed'
    fi
  else
    fail formatter-read-only-preflight \
      'the formatter or state probe did not complete'
  fi
else
  fail formatter-read-only-preflight \
    'read-only preflight fixture did not initialize'
fi

# A throwing formatter hook before the ordinary write must roll formatting back
# and let that one write save the user's original edit.  No ghost formatter undo
# node may appear; the saved user edit remains the first undoable command.
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
inject_before=$(report_count '^INJECT label=transaction-auto ')
if open_fixture lem-yath-test-formatting-open-transaction-auto transaction-auto &&
   run_mx lem-yath-test-formatting-prepare-transaction-auto &&
   wait_report_count '^PREPARE label=transaction-auto modified=yes$' 1; then
  after_before=$(report_count '^AFTER-SAVE label=transaction-auto ')
  lem_keys "$session" C-x C-s
  if wait_report_count '^INJECT label=transaction-auto ' \
       "$((inject_before + 1))" 8 &&
     wait_report_count '^AFTER-SAVE label=transaction-auto ' \
       "$((after_before + 1))" 8 &&
     record_state transaction-auto; then
    transaction_saved=$'# transaction save\nprefix_value=1\nKEEP_MARKER = "stay"\nTAIL_MARKER=2'
    transaction_saved_hex=$(hex_of "$transaction_saved")
    assert_state_hex after-save-transaction-rollback transaction-auto \
      "$transaction_saved_hex" "$transaction_saved_hex" no
    line=$(last_state transaction-auto)
    if [ "$(event_count)" -eq "$((before + 1))" ] &&
       [[ "$line" == *'lsp=0 changes=4 protected=no shadow=yes '* ]]; then
      pass after-save-transaction-one-invocation \
        'failed apply performed no retry and notified coherent inverse callbacks'
    else
      fail after-save-transaction-one-invocation \
        "unexpected formatter count: $(event_count)"
    fi
    lem_keys "$session" u
    sleep 0.4
    if record_state transaction-auto; then
      assert_state_hex after-save-transaction-undo transaction-auto \
        "$(hex_of "$python_initial")" "$transaction_saved_hex" yes
    else
      fail after-save-transaction-undo \
        'the saved user edit was not the first undo step'
    fi
    lem_keys "$session" C-r
    sleep 0.4
    if record_state transaction-auto; then
      assert_state_hex after-save-transaction-redo transaction-auto \
        "$transaction_saved_hex" "$transaction_saved_hex" no
    else
      fail after-save-transaction-redo \
        'redo did not return to the exact saved version'
    fi
  else
    fail after-save-transaction-rollback \
      'save-path mutation failure did not finish cleanly'
  fi
else
  fail after-save-transaction-rollback \
    'after-save transaction fixture did not initialize'
fi

# If the same hook also rejects inverse replay, saving must abort.  The disk
# stays at its previous bytes while the uncertain buffer is visibly dirty with
# truncated history and no fabricated clean/saved identity.
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
persistent_before=$(report_count '^PERSISTENT-INJECT label=rollback-failure ')
if open_fixture lem-yath-test-formatting-open-rollback-failure rollback-failure &&
   run_mx lem-yath-test-formatting-prepare-rollback-failure &&
   wait_report_count '^PREPARE label=rollback-failure modified=yes$' 1; then
  lem_keys "$session" C-x C-s
  if wait_report_count '^PERSISTENT-INJECT label=rollback-failure ' \
       "$((persistent_before + 2))" 8; then
    lem_keys "$session" Escape
    sleep 0.25
    if record_state rollback-failure; then
      line=$(last_state rollback-failure)
      initial_hex=$(hex_of "$python_initial")
      if [ "$(event_count)" -eq "$((before + 1))" ] &&
         [[ "$line" == *"disk-hex=$initial_hex modified=yes "* &&
            "$line" == *'lsp=0 '* && "$line" == *'shadow=yes '* &&
            "$line" == *'undo-truncated=yes undo-clean=none undo-saved=none '* ]]; then
        pass formatter-rollback-fail-dirty \
          'unsafe inverse aborted the save with dirty truncated history'
      else
        fail formatter-rollback-fail-dirty \
          "rollback failure was not visibly fail-closed: $line"
      fi
    else
      fail formatter-rollback-fail-dirty \
        'state probe did not run after the rejected save'
    fi
  else
    fail formatter-rollback-fail-dirty \
      'persistent hook did not reject both forward and inverse edits'
  fi
else
  fail formatter-rollback-fail-dirty \
    'rollback-failure fixture did not initialize'
fi

# A failure after every formatter hunk has applied, inside EditorConfig
# normalization, belongs to the same transaction and restores the initial
# saved bytes rather than exposing a completely formatted intermediate state.
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
normalize_before=$(report_count '^NORMALIZE-INJECT label=transaction-finalizer changes=')
if open_fixture lem-yath-test-formatting-open-transaction-finalizer \
     transaction-finalizer &&
   run_mx lem-yath-test-formatting-prepare-transaction-finalizer &&
   wait_report_count '^PREPARE label=transaction-finalizer modified=yes$' 1; then
  after_before=$(report_count '^AFTER-SAVE label=transaction-finalizer ')
  lem_keys "$session" C-x C-s
  if wait_report_count '^NORMALIZE-INJECT label=transaction-finalizer changes=' \
       "$((normalize_before + 1))" 8 &&
     wait_report_count '^AFTER-SAVE label=transaction-finalizer ' \
       "$((after_before + 1))" 8 &&
     record_state transaction-finalizer; then
    finalizer_saved=$'# transaction finalizer\nprefix_value=1\nKEEP_MARKER = "stay"\nTAIL_MARKER=2'
    finalizer_saved_hex=$(hex_of "$finalizer_saved")
    assert_state_hex after-save-finalizer-rollback transaction-finalizer \
      "$finalizer_saved_hex" "$finalizer_saved_hex" no
    line=$(last_state transaction-finalizer)
    normalize_line=$(grep '^NORMALIZE-INJECT label=transaction-finalizer changes=' \
      "$LEM_YATH_FORMATTING_REPORT" | tail -n 1)
    normalize_forward=${normalize_line##*=}
    if [[ "$line" =~ changes=([0-9]+) ]] &&
       [ "$(event_count)" -eq "$((before + 1))" ] &&
       [ "${BASH_REMATCH[1]}" -eq "$((normalize_forward * 2))" ] &&
       [[ "$line" == *'lsp=0 '* && "$line" == *'shadow=yes '* ]]; then
      pass after-save-finalizer-observers \
        'normalization failure rolled back all formatter edits through observers'
    else
      fail after-save-finalizer-observers \
        "unexpected formatter or observer state: $line"
    fi
    lem_keys "$session" u
    sleep 0.4
    if record_state transaction-finalizer; then
      assert_state_hex after-save-finalizer-undo transaction-finalizer \
        "$(hex_of "$python_initial")" "$finalizer_saved_hex" yes
    else
      fail after-save-finalizer-undo \
        'normalization rollback left a ghost formatter undo node'
    fi
    lem_keys "$session" C-r
    sleep 0.4
    if record_state transaction-finalizer; then
      assert_state_hex after-save-finalizer-redo transaction-finalizer \
        "$finalizer_saved_hex" "$finalizer_saved_hex" no
    else
      fail after-save-finalizer-redo \
        'redo did not return to the exact saved user edit'
    fi
  else
    fail after-save-finalizer-rollback \
      'the post-format normalization failure was not observed'
  fi
else
  fail after-save-finalizer-rollback \
    'normalization transaction fixture did not initialize'
fi

# Successful EditorConfig trimming runs after all formatter hunks inside the
# transaction and must not deactivate the mapped point/mark anchors.
printf '%s\n' format-spaces >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-finalizer-mark finalizer-mark &&
   run_mx lem-yath-test-formatting-prepare-finalizer-mark &&
   wait_report_count '^PREPARE label=finalizer-mark ' 1; then
  after_before=$(report_count '^AFTER-SAVE label=finalizer-mark ')
  lem_keys "$session" C-x C-s
  if wait_report_count '^AFTER-SAVE label=finalizer-mark ' \
       "$((after_before + 1))" 8 &&
     record_state finalizer-mark; then
    mark_formatted=$'# mark save\n# formatted by fake black\nprefix_value = 1\nKEEP_MARKER = "stay"\nTAIL_MARKER = 2\n'
    mark_disk=$'# mark save\r\n# formatted by fake black\r\nprefix_value = 1\r\nKEEP_MARKER = "stay"\r\nTAIL_MARKER = 2\r\n'
    mark_hex=$(hex_of "$mark_formatted")
    assert_state_hex finalizer-mark-format finalizer-mark \
      "$mark_hex" "$(hex_of "$mark_disk")" no
    line=$(last_state finalizer-mark)
    if [ "$(event_count)" -eq "$((before + 1))" ] &&
       [[ "$line" == *'mark=yes '* &&
          "$line" == *'point-keep=yes mark-tail=yes '* &&
          "$line" == *'trim=T '* && "$line" == *'shadow=yes '* ]]; then
      pass finalizer-mark-active \
        'successful normalization preserved the active mapped mark'
    else
      fail finalizer-mark-active "normalization lost an anchor: $line"
    fi
  else
    fail finalizer-mark-format \
      'successful finalizer mark fixture did not save and record'
  fi
else
  fail finalizer-mark-format 'finalizer mark fixture did not initialize'
fi

# Automatic formatting runs before the ordinary write: one CLI invocation and
# one save leave disk and buffer formatted and clean.
printf '%s\n' format >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-auto auto-open &&
   run_mx lem-yath-test-formatting-edit-auto &&
   wait_report_count '^EDIT label=auto-open modified=yes ' 1; then
  after_before=$(report_count '^AFTER-SAVE label=auto-open ')
  lem_keys "$session" C-x C-s
  save_seen=no
  if wait_report_count '^AFTER-SAVE label=auto-open ' \
       "$((after_before + 1))" 8; then
    save_seen=yes
  fi
  state_seen=no
  if record_state auto-open; then
    state_seen=yes
  fi
  if [ "$save_seen" = yes ] && [ "$state_seen" = yes ] &&
     [ "$(event_count)" -ge "$((before + 1))" ]; then
    auto_formatted=$'# user edit\n# formatted by fake black\nprefix_value = 1\nKEEP_MARKER = "stay"\nTAIL_MARKER = 2\n'
    auto_hex=$(hex_of "$auto_formatted")
    assert_state_hex after-save-format auto-open "$auto_hex" "$auto_hex" no
    if [ "$(event_count)" -eq "$((before + 1))" ]; then
      pass after-save-one-invocation \
        'one save invoked one formatter after the reload-safety probe'
    else
      fail after-save-one-invocation "unexpected formatter count: $(event_count)"
    fi
  else
    fail after-save-format \
      "save=$save_seen state=$state_seen events=$(event_count); $(last_state auto-open)"
  fi
else
  fail after-save-format 'automatic formatter fixture did not initialize'
fi

# Failure occurs before the ordinary write.  Partial stdout is discarded,
# ordinary save normalization still trims the touched line, and no LSP
# formatter is consulted after a selected CLI fails.
printf '%s\n' fail >"$LEM_YATH_FAKE_FORMATTER_MODE_FILE"
before=$(event_count)
if open_fixture lem-yath-test-formatting-open-failure failure-open &&
   run_mx lem-yath-test-formatting-edit-failure &&
   wait_report_count '^EDIT label=failure-open modified=yes ' 1; then
  after_before=$(report_count '^AFTER-SAVE label=failure-open ')
  lem_keys "$session" C-x C-s
  save_seen=no
  if wait_report_count '^AFTER-SAVE label=failure-open ' \
       "$((after_before + 1))" 8; then
    save_seen=yes
  fi
  state_seen=no
  if record_state failure-open; then
    state_seen=yes
  fi
  if [ "$save_seen" = yes ] && [ "$state_seen" = yes ] &&
     [ "$(event_count)" -ge "$((before + 1))" ]; then
    failure_saved=$'# failure edit\nprefix_value=1\nKEEP_MARKER = "stay"\nTAIL_MARKER=2'
    failure_hex=$(hex_of "$failure_saved")
    assert_state_hex formatter-failure-saved failure-open \
      "$failure_hex" "$failure_hex" no
    line=$(last_state failure-open)
    if [[ "$line" != *"$(hex_of 'PARTIAL-MUST-NOT-APPLY')"* ]]; then
      pass formatter-failure-no-mutation \
        'failed formatter stdout did not mutate the saved buffer'
    else
      fail formatter-failure-no-mutation 'partial formatter stdout reached the buffer'
    fi
    if [[ "$line" =~ changes=([0-9]+) ]] &&
       [ "${BASH_REMATCH[1]}" -gt 0 ] &&
       [[ "$line" == *'shadow=yes '* ]]; then
      pass formatter-failure-normalization \
        'formatter failure discarded its output but retained transactional save normalization'
    else
      fail formatter-failure-normalization \
        "save normalization did not run coherently after CLI failure: $line"
    fi
    if [[ "$line" == *'lsp=0 '* && "$line" == *'lsp-attempts=0' ]] &&
       [ "$(event_count)" -eq "$((before + 1))" ]; then
      pass formatter-failure-no-fallback \
        'CLI failure invoked once and did not fall back to LSP'
    else
      fail formatter-failure-no-fallback "unexpected failure state: $line"
    fi
  else
    fail formatter-failure-saved \
      "save=$save_seen state=$state_seen events=$(event_count); $(last_state failure-open)"
  fi
else
  fail formatter-failure-saved 'failure formatter fixture did not initialize'
fi

if [ "$failed" -eq 0 ]; then
  printf 'All EditorConfig and formatting checks passed.\n'
else
  printf '%s\n' 'Formatting fixture report:' >&2
  sed -n '1,320p' "$LEM_YATH_FORMATTING_REPORT" >&2 || true
  printf '%s\n' 'Formatter events:' >&2
  sed -n '1,80p' "$LEM_YATH_FAKE_FORMATTER_EVENTS" >&2 || true
fi
exit "$failed"
