#!/usr/bin/env bash
# Real-TUI regressions for buffer and path-aware prompt completion.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-prompt-completion-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-prompt-completion.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_PROMPT_COMPLETION_ROOT="$root/fixture"
export LEM_YATH_PROMPT_COMPLETION_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR" "$LEM_YATH_PROMPT_COMPLETION_ROOT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-prompt-completion-$id"
failed=0

cleanup() {
  lem_stop "$session"
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
  local pattern=$1
  if [ -f "$LEM_YATH_PROMPT_COMPLETION_REPORT" ]; then
    grep -cE "$pattern" "$LEM_YATH_PROMPT_COMPLETION_REPORT" || true
  else
    echo 0
  fi
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-10} i=0
  while ((i < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then return 0; fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

invoke_prompt_command() {
  local command=$1 prompt=$2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.6
  lem_keys "$session" Enter
  lem_wait_for "$session" "$prompt" 10 >/dev/null
}

fixture="$(lem-yath_lisp_string "$here/scripts/prompt-completion-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"
if ! lem_wait_for "$session" 'NORMAL|Dashboard' 40 >/dev/null ||
   ! wait_report_count '^READY$' 1 40; then
  fail boot "Lem did not initialize the prompt fixture" "$session"
else
  pass boot "configured Lem opened both file-backed fixture buffers"
fi

# Delimiter input belongs to the prompt query. It must refresh the candidate
# list rather than invoking ordinary-buffer pairing and closing completion.
if invoke_prompt_command lem-yath-test-buffer-prompt 'Fixture buffer:'; then
  tmux_cmd send-keys -t "$session" -l '('
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -q 'buffers/parens/()paired.txt' <<<"$screen" &&
     grep -Fq 'Fixture buffer: ()' <<<"$screen"; then
    pass delimiter-query "a paired delimiter refreshed the prompt without closing its candidates"
  else
    fail delimiter-query "delimiter input closed or bypassed prompt completion" "$session"
  fi
  lem_keys "$session" BSpace
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -q 'Fixture buffer:' <<<"$screen" &&
     ! grep -Fq 'Fixture buffer: ()' <<<"$screen" &&
     grep -q 'buffers/one/shared.txt' <<<"$screen"; then
    pass delimiter-backspace "paired Backspace cleared the query and restored prompt candidates"
  else
    fail delimiter-backspace "paired Backspace closed or failed to refresh the prompt" "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail delimiter-query "configured buffer prompt did not open" "$session"
fi

# Buffer prompt: both buffers have the same basename, so Lem assigns unique
# labels while retaining each backing path as the completion detail.
if invoke_prompt_command lem-yath-test-buffer-prompt 'Fixture buffer:'; then
  tmux_cmd send-keys -t "$session" -l shared
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -q 'buffers/one/shared.txt' <<<"$screen" &&
     grep -q 'buffers/two/shared.txt' <<<"$screen"; then
    pass buffer-annotations "same-named buffers retained distinct filename details"
  else
    fail buffer-annotations "buffer filename details were not both visible" "$session"
  fi

  # Choose the second displayed candidate and execute the prompt. The prompt
  # Return wrapper records the exact selected buffer label.
  lem_keys "$session" C-n
  sleep 0.2
  lem_keys "$session" Enter
  if wait_report_count '^BUFFER-SELECT ' 1; then
    selected_buffer_path=$(grep '^BUFFER-SELECT ' "$LEM_YATH_PROMPT_COMPLETION_REPORT" |
      tail -1 | sed 's/^.* path=//')
    pass buffer-selection "the real prompt selected $selected_buffer_path"
  else
    selected_buffer_path=""
    fail buffer-selection "buffer prompt did not return a candidate" "$session"
  fi
else
  selected_buffer_path=""
  fail buffer-prompt "configured buffer prompt did not open" "$session"
fi

# Reopening the same query must put the learned candidate first while keeping
# both annotations intact.
if [ -n "$selected_buffer_path" ] &&
   invoke_prompt_command lem-yath-test-buffer-prompt 'Fixture buffer:'; then
  tmux_cmd send-keys -t "$session" -l shared
  sleep 0.8
  screen=$(lem_capture "$session")
  selected_suffix=${selected_buffer_path#*buffers/}
  case "$selected_suffix" in
    one/*) other_suffix='two/shared.txt' ;;
    two/*) other_suffix='one/shared.txt' ;;
    *) other_suffix='' ;;
  esac
  selected_line=$(grep -n -m1 -F "buffers/$selected_suffix" <<<"$screen" | cut -d: -f1)
  other_line=$(grep -n -m1 -F "buffers/$other_suffix" <<<"$screen" | cut -d: -f1)
  if [ -n "$other_suffix" ] && [ -n "$selected_line" ] &&
     [ -n "$other_line" ] && [ "$selected_line" -lt "$other_line" ]; then
    pass buffer-ranking "the selected same-named buffer moved to the first row"
  else
    fail buffer-ranking "learned buffer ranking was not visible" "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
fi

# File prompt: narrow the first path component, use Vertico-style Tab to insert
# a slash-terminated directory without exiting, then narrow the nested files.
selected_file_name=""
if invoke_prompt_command lem-yath-test-file-prompt 'Fixture file:' &&
   lem_wait_for "$session" 'nested/' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l neste
  sleep 0.5
  if lem_wait_for "$session" 'nested/' 5 >/dev/null; then
    pass file-refresh "typing retained path-aware candidates in the automatic popup"
    lem_keys "$session" Tab
    sleep 0.5
    screen=$(lem_capture "$session")
    if grep -q 'nested/' <<<"$screen" &&
       [ "$(report_count '^FILE-SELECT ')" -eq 0 ]; then
      pass directory-semantics "directory acceptance kept the file prompt open with a slash"
    else
      fail directory-semantics "directory candidate did not preserve path semantics" "$session"
    fi

    tmux_cmd send-keys -t "$session" -l al-r
    if lem_wait_for "$session" 'alpha-report.txt' 10 >/dev/null &&
       lem_wait_for "$session" 'alpine-report.txt' 10 >/dev/null; then
      pass partial-components "al-r matched both nested hyphen components"
    else
      fail partial-components "nested partial-component completion failed" "$session"
    fi

    lem_keys "$session" C-n
    sleep 0.2
    lem_keys "$session" Enter
    if wait_report_count '^FILE-SELECT ' 1; then
      selected_file=$(grep '^FILE-SELECT ' "$LEM_YATH_PROMPT_COMPLETION_REPORT" |
        tail -1 | sed -E 's/^FILE-SELECT value=(.*) directory=.*/\1/')
      selected_file_name=${selected_file##*/}
      pass file-selection "the nested prompt selected $selected_file_name"
    else
      fail file-selection "file prompt did not return a candidate" "$session"
    fi
  else
    fail file-refresh "typing invalidated the configured file completion popup" "$session"
    lem_keys "$session" Escape
    sleep 0.2
    lem_keys "$session" Escape
  fi
else
  fail file-prompt "configured file prompt did not open" "$session"
fi

# Repeat the nested query and compare the two actual popup rows, independent
# of the filesystem's initial enumeration order.
if [ -n "$selected_file_name" ] &&
   invoke_prompt_command lem-yath-test-file-prompt 'Fixture file:' &&
   lem_wait_for "$session" 'nested/' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l neste
  sleep 0.5
  if lem_wait_for "$session" 'nested/' 10 >/dev/null; then
    lem_keys "$session" Tab
    sleep 0.3
  fi
  tmux_cmd send-keys -t "$session" -l al-r
  sleep 0.7
  screen=$(lem_capture "$session")
  case "$selected_file_name" in
    alpha-report.txt) other_file_name='alpine-report.txt' ;;
    alpine-report.txt) other_file_name='alpha-report.txt' ;;
    *) other_file_name='' ;;
  esac
  selected_line=$(grep -n -m1 -F "$selected_file_name" <<<"$screen" | cut -d: -f1)
  other_line=$(grep -n -m1 -F "$other_file_name" <<<"$screen" | cut -d: -f1)
  if [ -n "$other_file_name" ] && [ -n "$selected_line" ] &&
     [ -n "$other_line" ] && [ "$selected_line" -lt "$other_line" ]; then
    pass file-ranking "learned ranking reordered nested file candidates"
  else
    fail file-ranking "learned file ranking was not visible" "$session"
  fi
  if grep -q 'nested/' <<<"$screen"; then
    pass ranked-directory-semantics "ranking retained the nested directory prefix"
  else
    fail ranked-directory-semantics "ranked prompt lost its directory prefix" "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
fi

echo
cat "$LEM_YATH_PROMPT_COMPLETION_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "PROMPT COMPLETION TEST PASSED"
  exit 0
else
  echo "PROMPT COMPLETION TEST FAILED"
  exit 1
fi
