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
export LEM_YATH_FORMATTING_UNSET="$nested/unset.fmtfixture"
export LEM_YATH_FORMATTING_FALSE="$false_dir/false.fmtfixture"
export LEM_YATH_FORMATTING_BYTES="$project/bytes.txt"
export LEM_YATH_FORMATTING_MANUAL="$nested/"'manual ; $(touch FORMATTER_INJECTED).py'
export LEM_YATH_FORMATTING_AUTO="$nested/automatic.py"
export LEM_YATH_FORMATTING_FAILURE="$nested/failure.py"

whitespace_initial=$'untouched   \ntouched   '
printf '%s' "$whitespace_initial" >"$LEM_YATH_FORMATTING_TRUE"
printf '%s' "$whitespace_initial" >"$LEM_YATH_FORMATTING_UNSET"
printf '%s' "$whitespace_initial" >"$LEM_YATH_FORMATTING_FALSE"
printf '%s' 'initial bytes' >"$LEM_YATH_FORMATTING_BYTES"

python_initial=$'prefix_value=1\nKEEP_MARKER = "stay"\nTAIL_MARKER=2'
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_MANUAL"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_AUTO"
printf '%s' "$python_initial" >"$LEM_YATH_FORMATTING_FAILURE"

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
  sleep 0.25
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
lem_start_lem-yath_eval "$session" "(load #P$fixture)" \
  "$LEM_YATH_FORMATTING_MANUAL"
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the formatting fixture'
fi
pass boot 'configured Lem opened the real Python file in ncurses'

if run_mx lem-yath-test-formatting-static-checks &&
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

# Automatic formatting uses the after-save policy: an initial successful save,
# one CLI invocation, and one silent rewrite leave disk and buffer formatted
# and clean.
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

# Failure occurs after the initial write.  Partial stdout is discarded, the
# saved unformatted content remains clean in buffer and on disk, and no LSP
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
    if [[ "$line" == *'lsp=0' ]] &&
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
