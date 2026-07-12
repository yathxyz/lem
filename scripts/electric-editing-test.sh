#!/usr/bin/env bash
# Real-TUI tests for electric-pair and delete-selection parity.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-electric-editing-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-electric-editing.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_ELECTRIC_EDITING_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR" "$XDG_CACHE_HOME" "$root/fixtures"
: > "$LEM_YATH_ELECTRIC_EDITING_REPORT"

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
failed=0
sessions=()

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

report_count() {
  grep -cE "$1" "$LEM_YATH_ELECTRIC_EDITING_REPORT" 2>/dev/null || true
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

hex_of() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
}

fixture="$(lem-yath_lisp_string "$here/scripts/electric-editing-fixture.lisp")"

start_session() {
  local session=$1 file=$2 ready_before
  ready_before=$(report_count '^READY$')
  sessions+=("$session")
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$file"
  wait_report_count '^READY$' "$((ready_before + 1))" "$BOOT_TIMEOUT" &&
    lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null
}

stop_session() {
  local session=$1
  lem_stop "$session"
}

send_literal() {
  local session=$1 text=$2
  tmux_cmd send-keys -t "$session" -l "$text"
  sleep 0.15
}

leave_insert() {
  lem_keys "$1" Escape
  # Let ncurses resolve a lone ESC before the following function key; without
  # this delay it can be interpreted as that key's Meta prefix.
  sleep 0.35
}

ensure_insert() {
  local session=$1
  if ! lem_capture "$session" | grep -q 'INSERT'; then
    lem_keys "$session" i
    lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null
  fi
}

record_result() {
  local session=$1 label=$2 before
  before=$(report_count "^RESULT label=$label ")
  lem_keys "$session" F12
  wait_report_count "^RESULT label=$label " "$((before + 1))"
}

last_result() {
  grep "^RESULT label=$1 " "$LEM_YATH_ELECTRIC_EDITING_REPORT" | tail -1
}

assert_result() {
  local name=$1 label=$2 text=$3 point=$4 mark=$5 session=$6
  local line hex
  line=$(last_result "$label")
  hex=$(hex_of "$text")
  if [[ "$line" == *"text-hex=$hex point=$point mark=$mark "* ]]; then
    pass "$name" "$label produced the expected text, point, and mark state"
  else
    fail "$name" "unexpected result: $line" "$session"
  fi
}

assert_text_result() {
  local name=$1 label=$2 text=$3 session=$4 line hex
  line=$(last_result "$label")
  hex=$(hex_of "$text")
  if [[ "$line" == *"text-hex=$hex "* ]]; then
    pass "$name" "$label produced the expected buffer text"
  else
    fail "$name" "unexpected result: $line" "$session"
  fi
}

invoke_setup() {
  local session=$1 command=$2 label=$3 before
  before=$(report_count "^SETUP label=$label$")
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.4
  lem_keys "$session" Enter
  wait_report_count "^SETUP label=$label$" "$((before + 1))"
}

plain_file="$root/fixtures/plain.txt"
existing_file="$root/fixtures/existing.txt"
escaped_file="$root/fixtures/escaped.txt"
python_file="$root/fixtures/pairs.py"
lisp_file="$root/fixtures/pairs.lisp"
hook_file="$root/fixtures/hooks.txt"
count_file="$root/fixtures/count.txt"
open_space_file="$root/fixtures/open-space.txt"
close_space_file="$root/fixtures/close-space.txt"
open_newline_file="$root/fixtures/open-newline.txt"
balanced_file="$root/fixtures/balanced.txt"
balanced_space_file="$root/fixtures/balanced-space.txt"
balanced_string_file="$root/fixtures/balanced-string.txt"
unmatched_quote_file="$root/fixtures/unmatched-quote.txt"
spaced_quote_file="$root/fixtures/spaced-quote.txt"
escaped_open_file="$root/fixtures/escaped-open.txt"
even_escaped_open_file="$root/fixtures/even-escaped-open.txt"
replace_file="$root/fixtures/replace.txt"
region_file="$root/fixtures/region.txt"
lisp_region_file="$root/fixtures/region.lisp"
visual_file="$root/fixtures/visual.txt"
: > "$plain_file"
printf ')' > "$existing_file"
printf '\\z' > "$escaped_file"
: > "$python_file"
: > "$lisp_file"
: > "$hook_file"
: > "$count_file"
printf '  )' > "$open_space_file"
printf '  )' > "$close_space_file"
printf '  \n)' > "$open_newline_file"
printf '()' > "$balanced_file"
printf '(  )' > "$balanced_space_file"
printf '"()"' > "$balanced_string_file"
printf '"' > "$unmatched_quote_file"
printf '"  "' > "$spaced_quote_file"
printf '\\z' > "$escaped_open_file"
printf '\\\\z' > "$even_escaped_open_file"
printf 'abcdef' > "$replace_file"
: > "$region_file"
: > "$lisp_region_file"
printf 'abcdef' > "$visual_file"

plain_session="lem-yath-electric-plain-$id"
if start_session "$plain_session" "$plain_file"; then
  lem_keys "$plain_session" i
  send_literal "$plain_session" '('
  send_literal "$plain_session" x
  send_literal "$plain_session" ')'
  send_literal "$plain_session" y
  leave_insert "$plain_session"
  if record_result "$plain_session" plain.txt; then
    assert_result pair-close-skip plain.txt '(x)y' 4 no "$plain_session"
  else
    fail pair-close-skip "plain result probe did not run" "$plain_session"
  fi
  lem_keys "$plain_session" u
  if record_result "$plain_session" plain.txt; then
    assert_text_result pair-insert-undo plain.txt '' "$plain_session"
  else
    fail pair-insert-undo "undo result probe did not run" "$plain_session"
  fi
else
  fail plain-boot "plain buffer did not initialize" "$plain_session"
fi
stop_session "$plain_session"

existing_session="lem-yath-electric-existing-$id"
if start_session "$existing_session" "$existing_file"; then
  lem_keys "$existing_session" i
  send_literal "$existing_session" '('
  send_literal "$existing_session" x
  leave_insert "$existing_session"
  if record_result "$existing_session" existing.txt; then
    assert_result existing-closer-reuse existing.txt '(x)' 2 no "$existing_session"
  else
    fail existing-closer-reuse "existing-closer probe did not run" "$existing_session"
  fi
else
  fail existing-closer-boot "existing-closer buffer did not initialize" "$existing_session"
fi
stop_session "$existing_session"

escaped_session="lem-yath-electric-escaped-$id"
if start_session "$escaped_session" "$escaped_file"; then
  lem_keys "$escaped_session" l
  lem_keys "$escaped_session" i
  send_literal "$escaped_session" '"'
  leave_insert "$escaped_session"
  if record_result "$escaped_session" escaped.txt; then
    assert_result escaped-quote escaped.txt '\"z' 2 no "$escaped_session"
  else
    fail escaped-quote "escaped-quote probe did not run" "$escaped_session"
  fi
else
  fail escaped-quote-boot "escaped-quote buffer did not initialize" "$escaped_session"
fi
stop_session "$escaped_session"

python_session="lem-yath-electric-python-$id"
if start_session "$python_session" "$python_file"; then
  lem_keys "$python_session" i
  for character in '(' '[' '{' '"' "'" "'" '"' '}' ']' ')' x; do
    send_literal "$python_session" "$character"
  done
  leave_insert "$python_session"
  if record_result "$python_session" pairs.py; then
    assert_result python-syntax-pairs pairs.py "([{\"''\"}])x" 11 no "$python_session"
  else
    fail python-syntax-pairs "Python result probe did not run" "$python_session"
  fi
else
  fail python-boot "Python buffer did not initialize" "$python_session"
fi
stop_session "$python_session"

lisp_session="lem-yath-electric-lisp-$id"
lisp_ready=false
if start_session "$lisp_session" "$lisp_file"; then
  lisp_ready=true
  lem_keys "$lisp_session" i
  for character in '(' '[' '{' '"' '"' '}' ']' ')' x; do
    send_literal "$lisp_session" "$character"
  done
  leave_insert "$lisp_session"
  if record_result "$lisp_session" pairs.lisp; then
    assert_result paredit-precedence pairs.lisp '([{""}])x' 9 no "$lisp_session"
    line=$(last_result pairs.lisp)
    if [[ "$line" == *'paredit=yes' ]]; then
      pass paredit-active "Lisp delimiter keys remained owned by Paredit"
    else
      fail paredit-active "Paredit was not active: $line" "$lisp_session"
    fi
  else
    fail paredit-precedence "Lisp result probe did not run" "$lisp_session"
  fi
else
  fail lisp-boot "Lisp buffer did not initialize" "$lisp_session"
fi

if $lisp_ready; then
if invoke_setup "$lisp_session" lem-yath-test-electric-lisp-completion-setup lisp-completion; then
  ensure_insert "$lisp_session"
  send_literal "$lisp_session" alp
  if lem_wait_for "$lisp_session" 'alpha-char-p' "$WAIT_TIMEOUT" >/dev/null; then
    send_literal "$lisp_session" '('
    if record_result "$lisp_session" lisp-completion; then
      assert_result paredit-completion-opener lisp-completion 'alp ()' 6 no "$lisp_session"
    else
      fail paredit-completion-opener "Lisp completion opener probe did not run" "$lisp_session"
    fi
  else
    fail paredit-completion-opener "Lisp completion popup did not open" "$lisp_session"
  fi
else
  fail paredit-completion-opener "Lisp completion setup failed" "$lisp_session"
fi

if invoke_setup "$lisp_session" lem-yath-test-electric-lisp-completion-setup lisp-completion; then
  ensure_insert "$lisp_session"
  send_literal "$lisp_session" alp
  if lem_wait_for "$lisp_session" 'alpha-char-p' "$WAIT_TIMEOUT" >/dev/null; then
    send_literal "$lisp_session" '|'
    if record_result "$lisp_session" lisp-completion; then
      assert_result paredit-completion-fence lisp-completion 'alp||' 5 no "$lisp_session"
    else
      fail paredit-completion-fence "Lisp completion fence probe did not run" "$lisp_session"
    fi
  else
    fail paredit-completion-fence "Lisp completion popup did not open" "$lisp_session"
  fi
else
  fail paredit-completion-fence "Lisp completion setup failed" "$lisp_session"
fi
fi
stop_session "$lisp_session"

count_session="lem-yath-electric-count-$id"
if start_session "$count_session" "$count_file"; then
  if invoke_setup "$count_session" lem-yath-test-electric-empty-emacs empty-emacs; then
    lem_keys "$count_session" M-3
    send_literal "$count_session" '('
    if record_result "$count_session" empty-emacs; then
      assert_result counted-pair-insert empty-emacs '((()))' 4 no "$count_session"
    else
      fail counted-pair-insert "counted pair probe did not run" "$count_session"
    fi
  else
    fail counted-pair-insert "counted pair setup failed" "$count_session"
  fi

  if invoke_setup "$count_session" lem-yath-test-electric-empty-emacs empty-emacs; then
    lem_keys "$count_session" M-3
    send_literal "$count_session" '"'
    if record_result "$count_session" empty-emacs; then
      assert_result counted-quote-insert empty-emacs '""""""' 4 no "$count_session"
    else
      fail counted-quote-insert "counted quote probe did not run" "$count_session"
    fi
  else
    fail counted-quote-insert "counted quote setup failed" "$count_session"
  fi

  if invoke_setup "$count_session" lem-yath-test-electric-count-existing count-existing; then
    lem_keys "$count_session" M-3
    send_literal "$count_session" '('
    if record_result "$count_session" count-existing; then
      assert_result counted-existing-close count-existing '(((  )' 4 no "$count_session"
    else
      fail counted-existing-close "counted existing-close probe did not run" "$count_session"
    fi
  else
    fail counted-existing-close "counted existing-close setup failed" "$count_session"
  fi

  if invoke_setup "$count_session" lem-yath-test-electric-count-quote-existing count-quote-existing; then
    lem_keys "$count_session" M-3
    send_literal "$count_session" '"'
    if record_result "$count_session" count-quote-existing; then
      assert_result counted-existing-quote count-quote-existing '""""' 4 no "$count_session"
    else
      fail counted-existing-quote "counted existing-quote probe did not run" "$count_session"
    fi
  else
    fail counted-existing-quote "counted existing-quote setup failed" "$count_session"
  fi

  if invoke_setup "$count_session" lem-yath-test-electric-count-odd-escape count-odd-escape; then
    lem_keys "$count_session" M-3
    send_literal "$count_session" '('
    if record_result "$count_session" count-odd-escape; then
      assert_result counted-odd-escape count-odd-escape '\((())z' 5 no "$count_session"
    else
      fail counted-odd-escape "counted odd-escape probe did not run" "$count_session"
    fi
  else
    fail counted-odd-escape "counted odd-escape setup failed" "$count_session"
  fi

  if invoke_setup "$count_session" lem-yath-test-electric-count-even-escape count-even-escape; then
    lem_keys "$count_session" M-3
    send_literal "$count_session" '('
    if record_result "$count_session" count-even-escape; then
      assert_result counted-even-escape count-even-escape '\\((()))z' 6 no "$count_session"
    else
      fail counted-even-escape "counted even-escape probe did not run" "$count_session"
    fi
  else
    fail counted-even-escape "counted even-escape setup failed" "$count_session"
  fi
else
  fail counted-insert-boot "counted insertion buffer did not initialize" "$count_session"
fi
stop_session "$count_session"

open_space_session="lem-yath-electric-open-space-$id"
if start_session "$open_space_session" "$open_space_file"; then
  lem_keys "$open_space_session" i
  send_literal "$open_space_session" '('
  if record_result "$open_space_session" open-space.txt; then
    assert_result opener-reuses-spaced-close open-space.txt '(  )' 2 no "$open_space_session"
  else
    fail opener-reuses-spaced-close "spaced opener probe did not run" "$open_space_session"
  fi
else
  fail opener-reuses-spaced-close-boot "spaced opener buffer did not initialize" "$open_space_session"
fi
stop_session "$open_space_session"

close_space_session="lem-yath-electric-close-space-$id"
if start_session "$close_space_session" "$close_space_file"; then
  lem_keys "$close_space_session" i
  send_literal "$close_space_session" ')'
  if record_result "$close_space_session" close-space.txt; then
    assert_result closer-skips-whitespace close-space.txt '  )' 4 no "$close_space_session"
  else
    fail closer-skips-whitespace "spaced closer probe did not run" "$close_space_session"
  fi
else
  fail closer-skips-whitespace-boot "spaced closer buffer did not initialize" "$close_space_session"
fi
stop_session "$close_space_session"

open_newline_session="lem-yath-electric-open-newline-$id"
if start_session "$open_newline_session" "$open_newline_file"; then
  lem_keys "$open_newline_session" i
  send_literal "$open_newline_session" '('
  if record_result "$open_newline_session" open-newline.txt; then
    assert_result opener-reuses-multiline-close open-newline.txt $'(  \n)' 2 no "$open_newline_session"
  else
    fail opener-reuses-multiline-close "multiline opener probe did not run" "$open_newline_session"
  fi
else
  fail opener-reuses-multiline-close-boot "multiline opener buffer did not initialize" "$open_newline_session"
fi
stop_session "$open_newline_session"

balanced_session="lem-yath-electric-balanced-$id"
if start_session "$balanced_session" "$balanced_file"; then
  lem_keys "$balanced_session" l
  lem_keys "$balanced_session" i
  send_literal "$balanced_session" '('
  if record_result "$balanced_session" balanced.txt; then
    assert_result balanced-existing-pair balanced.txt '(())' 3 no "$balanced_session"
  else
    fail balanced-existing-pair "balanced-pair probe did not run" "$balanced_session"
  fi
else
  fail balanced-existing-pair-boot "balanced-pair buffer did not initialize" "$balanced_session"
fi
stop_session "$balanced_session"

balanced_space_session="lem-yath-electric-balanced-space-$id"
if start_session "$balanced_space_session" "$balanced_space_file"; then
  lem_keys "$balanced_space_session" l
  lem_keys "$balanced_space_session" i
  send_literal "$balanced_space_session" '('
  if record_result "$balanced_space_session" balanced-space.txt; then
    assert_result balanced-spaced-pair balanced-space.txt '(()  )' 3 no "$balanced_space_session"
  else
    fail balanced-spaced-pair "balanced spaced-pair probe did not run" "$balanced_space_session"
  fi
else
  fail balanced-spaced-pair-boot "balanced spaced-pair buffer did not initialize" "$balanced_space_session"
fi
stop_session "$balanced_space_session"

balanced_string_session="lem-yath-electric-balanced-string-$id"
if start_session "$balanced_string_session" "$balanced_string_file"; then
  lem_keys "$balanced_string_session" l
  lem_keys "$balanced_string_session" l
  lem_keys "$balanced_string_session" i
  send_literal "$balanced_string_session" '('
  if record_result "$balanced_string_session" balanced-string.txt; then
    assert_result balanced-string-pair balanced-string.txt '"(())"' 4 no "$balanced_string_session"
  else
    fail balanced-string-pair "balanced string-pair probe did not run" "$balanced_string_session"
  fi
else
  fail balanced-string-pair-boot "balanced string-pair buffer did not initialize" "$balanced_string_session"
fi
stop_session "$balanced_string_session"

unmatched_quote_session="lem-yath-electric-unmatched-quote-$id"
if start_session "$unmatched_quote_session" "$unmatched_quote_file"; then
  lem_keys "$unmatched_quote_session" i
  send_literal "$unmatched_quote_session" '"'
  if record_result "$unmatched_quote_session" unmatched-quote.txt; then
    assert_result unmatched-quote-reuse unmatched-quote.txt '""' 2 no "$unmatched_quote_session"
  else
    fail unmatched-quote-reuse "unmatched quote probe did not run" "$unmatched_quote_session"
  fi
else
  fail unmatched-quote-reuse-boot "unmatched quote buffer did not initialize" "$unmatched_quote_session"
fi
stop_session "$unmatched_quote_session"

spaced_quote_session="lem-yath-electric-spaced-quote-$id"
if start_session "$spaced_quote_session" "$spaced_quote_file"; then
  lem_keys "$spaced_quote_session" l
  lem_keys "$spaced_quote_session" i
  send_literal "$spaced_quote_session" '"'
  if record_result "$spaced_quote_session" spaced-quote.txt; then
    assert_result quote-skips-whitespace spaced-quote.txt '"  "' 5 no "$spaced_quote_session"
  else
    fail quote-skips-whitespace "spaced quote probe did not run" "$spaced_quote_session"
  fi
else
  fail quote-skips-whitespace-boot "spaced quote buffer did not initialize" "$spaced_quote_session"
fi
stop_session "$spaced_quote_session"

escaped_open_session="lem-yath-electric-escaped-open-$id"
if start_session "$escaped_open_session" "$escaped_open_file"; then
  lem_keys "$escaped_open_session" l
  lem_keys "$escaped_open_session" i
  send_literal "$escaped_open_session" '('
  if record_result "$escaped_open_session" escaped-open.txt; then
    assert_result odd-escaped-opener escaped-open.txt '\(z' 3 no "$escaped_open_session"
  else
    fail odd-escaped-opener "odd escaped opener probe did not run" "$escaped_open_session"
  fi
else
  fail odd-escaped-opener-boot "odd escaped opener buffer did not initialize" "$escaped_open_session"
fi
stop_session "$escaped_open_session"

even_escaped_open_session="lem-yath-electric-even-escaped-open-$id"
if start_session "$even_escaped_open_session" "$even_escaped_open_file"; then
  lem_keys "$even_escaped_open_session" l
  lem_keys "$even_escaped_open_session" l
  lem_keys "$even_escaped_open_session" i
  send_literal "$even_escaped_open_session" '('
  if record_result "$even_escaped_open_session" even-escaped-open.txt; then
    assert_result even-escaped-opener even-escaped-open.txt '\\()z' 4 no "$even_escaped_open_session"
  else
    fail even-escaped-opener "even escaped opener probe did not run" "$even_escaped_open_session"
  fi
else
  fail even-escaped-opener-boot "even escaped opener buffer did not initialize" "$even_escaped_open_session"
fi
stop_session "$even_escaped_open_session"

replace_session="lem-yath-electric-replace-$id"
if start_session "$replace_session" "$replace_file"; then
  lem_keys "$replace_session" R
  send_literal "$replace_session" '('
  if record_result "$replace_session" replace.txt; then
    assert_result vi-replace-isolation replace.txt '(bcdef' 2 no "$replace_session"
  else
    fail vi-replace-isolation "Vi replace probe did not run" "$replace_session"
  fi
else
  fail vi-replace-isolation-boot "Vi replace buffer did not initialize" "$replace_session"
fi
stop_session "$replace_session"

hook_session="lem-yath-electric-hooks-$id"
if start_session "$hook_session" "$hook_file" &&
   invoke_setup "$hook_session" lem-yath-test-electric-hook-setup mode-hooks; then
  send_literal "$hook_session" '('
  leave_insert "$hook_session"
  before=$(report_count '^HOOKS ')
  lem_keys "$hook_session" F10
  if wait_report_count '^HOOKS ' "$((before + 1))"; then
    line=$(grep '^HOOKS ' "$LEM_YATH_ELECTRIC_EDITING_REPORT" | tail -1)
    if [ "$line" = 'HOOKS before=1 after=1 text-hex=2829' ]; then
      pass mode-self-insert-hooks "major-mode before/after methods surrounded electric insertion"
    else
      fail mode-self-insert-hooks "unexpected lifecycle result: $line" "$hook_session"
    fi
  else
    fail mode-self-insert-hooks "mode-hook result probe did not run" "$hook_session"
  fi
else
  fail mode-self-insert-hooks-boot "mode-hook buffer did not initialize" "$hook_session"
fi
stop_session "$hook_session"

region_session="lem-yath-electric-region-$id"
if start_session "$region_session" "$region_file"; then
  if invoke_setup "$region_session" lem-yath-test-electric-forward-replace forward-replace; then
    send_literal "$region_session" X
    if record_result "$region_session" forward-replace; then
      assert_result forward-selection-replace forward-replace 'aXef' 3 no "$region_session"
    else
      fail forward-selection-replace "forward replacement probe did not run" "$region_session"
    fi
  else
    fail forward-selection-replace "forward replacement setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-reverse-replace reverse-replace; then
    send_literal "$region_session" X
    if record_result "$region_session" reverse-replace; then
      assert_result reverse-selection-replace reverse-replace 'aXef' 3 no "$region_session"
    else
      fail reverse-selection-replace "reverse replacement probe did not run" "$region_session"
    fi
  else
    fail reverse-selection-replace "reverse replacement setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-forward-wrap forward-wrap; then
    send_literal "$region_session" '('
    if record_result "$region_session" forward-wrap; then
      assert_result forward-selection-wrap forward-wrap 'a(bcd)ef' 3 no "$region_session"
    else
      fail forward-selection-wrap "forward wrapping probe did not run" "$region_session"
    fi
  else
    fail forward-selection-wrap "forward wrapping setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-forward-wrap forward-wrap; then
    send_literal "$region_session" '('
    send_literal "$region_session" X
    if record_result "$region_session" forward-wrap; then
      assert_result wrap-then-type forward-wrap 'a(Xbcd)ef' 4 no "$region_session"
    else
      fail wrap-then-type "post-wrap insertion probe did not run" "$region_session"
    fi
  else
    fail wrap-then-type "post-wrap insertion setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-reverse-wrap reverse-wrap; then
    send_literal "$region_session" '('
    if record_result "$region_session" reverse-wrap; then
      assert_result reverse-selection-wrap reverse-wrap 'a(bcd)ef' 3 no "$region_session"
    else
      fail reverse-selection-wrap "reverse wrapping probe did not run" "$region_session"
    fi
  else
    fail reverse-selection-wrap "reverse wrapping setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-quote-wrap quote-wrap; then
    send_literal "$region_session" '"'
    if record_result "$region_session" quote-wrap; then
      assert_result quote-selection-wrap quote-wrap 'a"bcd"ef' 3 no "$region_session"
    else
      fail quote-selection-wrap "forward quote probe did not run" "$region_session"
    fi
  else
    fail quote-selection-wrap "quote wrapping setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-reverse-quote-wrap reverse-quote-wrap; then
    send_literal "$region_session" '"'
    if record_result "$region_session" reverse-quote-wrap; then
      assert_result reverse-quote-selection-wrap reverse-quote-wrap 'a"bcd"ef' 7 no "$region_session"
    else
      fail reverse-quote-selection-wrap "reverse quote probe did not run" "$region_session"
    fi
  else
    fail reverse-quote-selection-wrap "reverse quote wrapping setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-forward-wrap forward-wrap; then
    lem_keys "$region_session" M-3
    send_literal "$region_session" '('
    if record_result "$region_session" forward-wrap; then
      assert_result counted-forward-wrap forward-wrap 'a(((bcd)))ef' 5 no "$region_session"
    else
      fail counted-forward-wrap "counted forward-wrap probe did not run" "$region_session"
    fi
  else
    fail counted-forward-wrap "counted forward-wrap setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-reverse-wrap reverse-wrap; then
    lem_keys "$region_session" M-3
    send_literal "$region_session" '('
    if record_result "$region_session" reverse-wrap; then
      assert_result counted-reverse-wrap reverse-wrap 'a(((bcd)))ef' 5 no "$region_session"
    else
      fail counted-reverse-wrap "counted reverse-wrap probe did not run" "$region_session"
    fi
  else
    fail counted-reverse-wrap "counted reverse-wrap setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-quote-wrap quote-wrap; then
    lem_keys "$region_session" M-3
    send_literal "$region_session" '"'
    if record_result "$region_session" quote-wrap; then
      assert_result counted-forward-quote-wrap quote-wrap 'a"""bcd"""ef' 5 no "$region_session"
    else
      fail counted-forward-quote-wrap "counted forward quote probe did not run" "$region_session"
    fi
  else
    fail counted-forward-quote-wrap "counted forward quote setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-reverse-quote-wrap reverse-quote-wrap; then
    lem_keys "$region_session" M-3
    send_literal "$region_session" '"'
    if record_result "$region_session" reverse-quote-wrap; then
      assert_result counted-reverse-quote-wrap reverse-quote-wrap 'a"""bcd"""ef' 11 no "$region_session"
    else
      fail counted-reverse-quote-wrap "counted reverse quote probe did not run" "$region_session"
    fi
  else
    fail counted-reverse-quote-wrap "counted reverse quote setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-zero-mark zero-mark; then
    send_literal "$region_session" X
    if record_result "$region_session" zero-mark; then
      assert_result zero-width-mark zero-mark 'abcXdef' 5 no "$region_session"
    else
      fail zero-width-mark "zero-width probe did not run" "$region_session"
    fi
  else
    fail zero-width-mark "zero-width setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-wrap-undo wrap-undo; then
    send_literal "$region_session" '('
    lem_keys "$region_session" "C-\\"
    if record_result "$region_session" wrap-undo; then
      assert_result wrap-one-undo wrap-undo 'abcdef' 2 no "$region_session"
      line=$(last_result wrap-undo)
      if [[ "$line" == *'mark-point=5 '* ]]; then
        pass wrap-undo-mark "forward undo restored the original inactive mark"
      else
        fail wrap-undo-mark "unexpected forward undo mark: $line" "$region_session"
      fi
    else
      fail wrap-one-undo "wrap undo probe did not run" "$region_session"
    fi
  else
    fail wrap-one-undo "wrap undo setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-reverse-wrap reverse-wrap; then
    send_literal "$region_session" '('
    lem_keys "$region_session" "C-\\"
    if record_result "$region_session" reverse-wrap; then
      assert_result reverse-wrap-one-undo reverse-wrap 'abcdef' 5 no "$region_session"
      line=$(last_result reverse-wrap)
      if [[ "$line" == *'mark-point=2 '* ]]; then
        pass reverse-wrap-undo-mark "reverse undo restored the original inactive mark"
      else
        fail reverse-wrap-undo-mark "unexpected reverse undo mark: $line" "$region_session"
      fi
    else
      fail reverse-wrap-one-undo "reverse wrap undo probe did not run" "$region_session"
    fi
  else
    fail reverse-wrap-one-undo "reverse wrap undo setup failed" "$region_session"
  fi

  if invoke_setup "$region_session" lem-yath-test-electric-read-only read-only; then
    send_literal "$region_session" X
    if record_result "$region_session" read-only; then
      assert_result read-only-selection read-only 'abcdef' 2 yes "$region_session"
    else
      fail read-only-selection "read-only probe did not run" "$region_session"
    fi
  else
    fail read-only-selection "read-only setup failed" "$region_session"
  fi
else
  fail region-boot "region buffer did not initialize" "$region_session"
fi
stop_session "$region_session"

lisp_region_session="lem-yath-electric-lisp-region-$id"
if start_session "$lisp_region_session" "$lisp_region_file"; then
  if invoke_setup "$lisp_region_session" lem-yath-test-electric-lisp-wrap lisp-wrap; then
    send_literal "$lisp_region_session" '('
    if record_result "$lisp_region_session" lisp-wrap; then
      assert_result paredit-selection-wrap lisp-wrap 'a(bcd)ef' 2 no "$lisp_region_session"
      line=$(last_result lisp-wrap)
      if [[ "$line" == *'paredit=yes' ]]; then
        pass paredit-region-active "Paredit stayed active during region wrapping"
      else
        fail paredit-region-active "Paredit was not active: $line" "$lisp_region_session"
      fi
    else
      fail paredit-selection-wrap "Paredit wrapping probe did not run" "$lisp_region_session"
    fi
  else
    fail paredit-selection-wrap "Paredit wrapping setup failed" "$lisp_region_session"
  fi

  if invoke_setup "$lisp_region_session" lem-yath-test-electric-lisp-reverse-wrap lisp-reverse-wrap; then
    send_literal "$lisp_region_session" '('
    if record_result "$lisp_region_session" lisp-reverse-wrap; then
      assert_result paredit-reverse-selection-wrap lisp-reverse-wrap 'a(bcd)ef' 2 no "$lisp_region_session"
    else
      fail paredit-reverse-selection-wrap "Paredit reverse-wrap probe did not run" "$lisp_region_session"
    fi
  else
    fail paredit-reverse-selection-wrap "Paredit reverse-wrap setup failed" "$lisp_region_session"
  fi

  if invoke_setup "$lisp_region_session" lem-yath-test-electric-lisp-quote-wrap lisp-quote-wrap; then
    send_literal "$lisp_region_session" '"'
    if record_result "$lisp_region_session" lisp-quote-wrap; then
      assert_result paredit-quote-selection-wrap lisp-quote-wrap 'a"bcd"ef' 2 yes "$lisp_region_session"
      line=$(last_result lisp-quote-wrap)
      if [[ "$line" == *'mark-point=7 '* ]]; then
        pass paredit-quote-orientation "forward Lispy quote retained the outer selection"
      else
        fail paredit-quote-orientation "unexpected forward quote mark: $line" "$lisp_region_session"
      fi
    else
      fail paredit-quote-selection-wrap "Paredit quote probe did not run" "$lisp_region_session"
    fi
  else
    fail paredit-quote-selection-wrap "Paredit quote setup failed" "$lisp_region_session"
  fi

  if invoke_setup "$lisp_region_session" lem-yath-test-electric-lisp-reverse-quote-wrap lisp-reverse-quote-wrap; then
    send_literal "$lisp_region_session" '"'
    if record_result "$lisp_region_session" lisp-reverse-quote-wrap; then
      assert_result paredit-reverse-quote-wrap lisp-reverse-quote-wrap 'a"bcd"ef' 7 yes "$lisp_region_session"
      line=$(last_result lisp-reverse-quote-wrap)
      if [[ "$line" == *'mark-point=2 '* ]]; then
        pass paredit-reverse-quote-orientation "reverse Lispy quote retained the outer selection"
      else
        fail paredit-reverse-quote-orientation "unexpected reverse quote mark: $line" "$lisp_region_session"
      fi
    else
      fail paredit-reverse-quote-wrap "Paredit reverse quote probe did not run" "$lisp_region_session"
    fi
  else
    fail paredit-reverse-quote-wrap "Paredit reverse quote setup failed" "$lisp_region_session"
  fi

  if invoke_setup "$lisp_region_session" lem-yath-test-electric-lisp-quote-escape-backslash lisp-quote-escape-backslash; then
    send_literal "$lisp_region_session" '"'
    if record_result "$lisp_region_session" lisp-quote-escape-backslash; then
      assert_result paredit-quote-escape-backslash lisp-quote-escape-backslash 'a"b\\c"z' 2 yes "$lisp_region_session"
      line=$(last_result lisp-quote-escape-backslash)
      if [[ "$line" == *'mark-point=8 '* ]]; then
        pass paredit-quote-escape-backslash-mark "escaped selection retained its outer endpoint"
      else
        fail paredit-quote-escape-backslash-mark "unexpected escaped-selection mark: $line" "$lisp_region_session"
      fi
    else
      fail paredit-quote-escape-backslash "Paredit backslash-escape probe did not run" "$lisp_region_session"
    fi
  else
    fail paredit-quote-escape-backslash "Paredit backslash-escape setup failed" "$lisp_region_session"
  fi

  if invoke_setup "$lisp_region_session" lem-yath-test-electric-lisp-quote-escape-quote lisp-quote-escape-quote; then
    send_literal "$lisp_region_session" '"'
    if record_result "$lisp_region_session" lisp-quote-escape-quote; then
      assert_result paredit-quote-escape-quote lisp-quote-escape-quote 'a"b\"q\"c"z' 2 yes "$lisp_region_session"
      line=$(last_result lisp-quote-escape-quote)
      if [[ "$line" == *'mark-point=11 '* ]]; then
        pass paredit-quote-escape-quote-mark "balanced embedded quotes retained the outer endpoint"
      else
        fail paredit-quote-escape-quote-mark "unexpected embedded-quote mark: $line" "$lisp_region_session"
      fi
    else
      fail paredit-quote-escape-quote "Paredit quote-escape probe did not run" "$lisp_region_session"
    fi
  else
    fail paredit-quote-escape-quote "Paredit quote-escape setup failed" "$lisp_region_session"
  fi

  if invoke_setup "$lisp_region_session" lem-yath-test-electric-lisp-replace lisp-replace; then
    send_literal "$lisp_region_session" X
    if record_result "$lisp_region_session" lisp-replace; then
      assert_result paredit-selection-replace lisp-replace 'aXef' 3 no "$lisp_region_session"
    else
      fail paredit-selection-replace "Paredit replacement probe did not run" "$lisp_region_session"
    fi
  else
    fail paredit-selection-replace "Paredit replacement setup failed" "$lisp_region_session"
  fi
else
  fail lisp-region-boot "Lisp region buffer did not initialize" "$lisp_region_session"
fi
stop_session "$lisp_region_session"

visual_session="lem-yath-electric-visual-$id"
if start_session "$visual_session" "$visual_file"; then
  lem_keys "$visual_session" l
  lem_keys "$visual_session" v
  lem_keys "$visual_session" l
  lem_keys "$visual_session" l
  lem_keys "$visual_session" c
  send_literal "$visual_session" X
  leave_insert "$visual_session"
  if record_result "$visual_session" visual.txt; then
    assert_result evil-visual-change visual.txt 'aXef' 2 no "$visual_session"
  else
    fail evil-visual-change "visual change probe did not run" "$visual_session"
  fi
else
  fail visual-boot "visual regression buffer did not initialize" "$visual_session"
fi
stop_session "$visual_session"

echo
cat "$LEM_YATH_ELECTRIC_EDITING_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "ELECTRIC EDITING TEST PASSED"
  exit 0
else
  echo "ELECTRIC EDITING TEST FAILED"
  exit 1
fi
