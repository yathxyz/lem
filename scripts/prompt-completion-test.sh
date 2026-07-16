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

screen_has_toggle_candidate() {
  local screen=$1 candidate=$2
  grep -F "$candidate" <<<"$screen" | grep -Fq 'toggle-candidate'
}

close_prompt() {
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
}

prescient_toggle_test() {
  local name=$1 query=$2 candidate=$3 before=$4 after=$5
  shift 5
  if ! invoke_prompt_command lem-yath-test-prescient-toggle-prompt \
       'Prescient fixture:'; then
    fail "$name" 'the Prescient fixture prompt did not open' "$session"
    return
  fi
  tmux_cmd send-keys -t "$session" -l "$query"
  sleep 0.7
  local screen
  screen=$(lem_capture "$session")
  if { [ "$before" = present ] && ! screen_has_toggle_candidate "$screen" "$candidate"; } ||
     { [ "$before" = absent ] && screen_has_toggle_candidate "$screen" "$candidate"; }; then
    fail "$name" "the baseline candidate was not $before" "$session"
    close_prompt
    return
  fi
  lem_keys "$session" "$@"
  sleep 0.7
  screen=$(lem_capture "$session")
  if { [ "$after" = present ] && screen_has_toggle_candidate "$screen" "$candidate"; } ||
     { [ "$after" = absent ] && ! screen_has_toggle_candidate "$screen" "$candidate"; }; then
    pass "$name" "the prompt-local toggle changed $candidate from $before to $after"
  else
    fail "$name" "the candidate did not become $after" "$session"
  fi
  close_prompt
}

fixture="$(lem-yath_lisp_string "$here/scripts/prompt-completion-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"
if ! lem_wait_for "$session" 'NORMAL|Dashboard' 40 >/dev/null ||
   ! wait_report_count '^READY$' 1 40; then
  fail boot "Lem did not initialize the prompt fixture" "$session"
else
  pass boot "configured Lem opened both file-backed fixture buffers"
fi
sleep 0.8

# Preserve the everyday Emacs yank-pop workflow over deterministic kill-ring
# entries, including insertion at the empty read-only field boundary.
prompt_edit_before=$(grep -c '^PROMPT-EDIT-SELECT value=quick-lookup$' \
  "$LEM_YATH_PROMPT_COMPLETION_REPORT" 2>/dev/null || true)
if invoke_prompt_command lem-yath-test-prompt-kill-ring 'Prompt edit:'; then
  lem_keys "$session" C-y
  sleep 0.4
  screen=$(lem_capture "$session")
  if ! grep -Fq 'Prompt edit: fixture-preset' <<<"$screen"; then
    fail prompt-emacs-kill-ring-yank \
      'C-y did not restore the most recently killed prompt input' "$session"
    close_prompt
  else
    lem_keys "$session" M-y
    sleep 0.8
    screen=$(lem_capture "$session")
  fi
  if grep -Fq 'Prompt edit: quick-lookup' <<<"$screen" &&
     grep -Fq 'quick-lookup' <<<"$screen"; then
    lem_keys "$session" Enter
    if wait_report_count '^PROMPT-EDIT-SELECT value=quick-lookup$' \
         $((prompt_edit_before + 1)); then
      pass prompt-emacs-kill-ring \
        'mark exchange, region kill, yank, and yank-pop retained completion'
    else
      fail prompt-emacs-kill-ring \
        'Return did not accept the yank-pop result' "$session"
    fi
  else
    fail prompt-emacs-kill-ring \
      'mark or kill-ring editing damaged the prompt boundary' "$session"
    close_prompt
  fi
else
  fail prompt-emacs-kill-ring 'the kill-ring prompt did not open' "$session"
fi

# Mark/exchange the full editable field, kill it without entering the label,
# and yank it back at the zero-width boundary.
prompt_edit_before=$(grep -c '^PROMPT-EDIT-SELECT value=quick-lookup$' \
  "$LEM_YATH_PROMPT_COMPLETION_REPORT" 2>/dev/null || true)
if invoke_prompt_command lem-yath-test-prompt-line-editing \
     'Prompt edit: quick-lookup'; then
  lem_keys "$session" C-a
  lem_keys "$session" C-Space
  lem_keys "$session" C-e
  lem_keys "$session" C-x C-x
  lem_keys "$session" C-w
  lem_keys "$session" C-y
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Fq 'Prompt edit: quick-lookup' <<<"$screen" &&
     grep -Fq 'quick-lookup' <<<"$screen"; then
    lem_keys "$session" Enter
    if wait_report_count '^PROMPT-EDIT-SELECT value=quick-lookup$' \
         $((prompt_edit_before + 1)); then
      pass prompt-emacs-region-kill \
        'C-SPC, C-x C-x, C-w, and C-y preserved the prompt boundary'
    else
      fail prompt-emacs-region-kill \
        'Return did not accept the restored killed region' "$session"
    fi
  else
    fail prompt-emacs-region-kill \
      'region kill/yank did not restore the protected prompt input' "$session"
    close_prompt
  fi
else
  fail prompt-emacs-region-kill 'the region-kill prompt did not open' \
    "$session"
fi

prompt_edit_before=$(grep -c '^PROMPT-EDIT-SELECT value=quick-lookup$' \
  "$LEM_YATH_PROMPT_COMPLETION_REPORT" 2>/dev/null || true)
if invoke_prompt_command lem-yath-test-prompt-line-editing \
     'Prompt edit: quick-lookup'; then
  lem_keys "$session" C-a
  lem_keys "$session" C-Space
  lem_keys "$session" M-f
  lem_keys "$session" M-w
  lem_keys "$session" C-e
  lem_keys "$session" C-y
  lem_keys "$session" C-/
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Fq 'Prompt edit: quick-lookup' <<<"$screen" &&
     grep -Fq 'quick-lookup' <<<"$screen"; then
    lem_keys "$session" Enter
    if wait_report_count '^PROMPT-EDIT-SELECT value=quick-lookup$' \
         $((prompt_edit_before + 1)); then
      pass prompt-emacs-copy-region \
        'M-w copied the protected region and prompt undo restored its yank'
    else
      fail prompt-emacs-copy-region \
        'Return did not accept the post-copy undo result' "$session"
    fi
  else
    fail prompt-emacs-copy-region \
      'copy/yank/undo did not preserve the prompt input' "$session"
    close_prompt
  fi
else
  fail prompt-emacs-copy-region 'the copy-region prompt did not open' "$session"
fi

# GNU minibuffers put C-/, C-_, and C-x u on undo.  The initial undo must not
# enter the protected label; later undos restore the prior query and repaint
# completion without dismissing the prompt.
prompt_edit_before=$(grep -c '^PROMPT-EDIT-SELECT value=quick-lookup$' \
  "$LEM_YATH_PROMPT_COMPLETION_REPORT" 2>/dev/null || true)
if invoke_prompt_command lem-yath-test-prompt-line-editing \
     'Prompt edit: quick-lookup'; then
  lem_keys "$session" C-/
  tmux_cmd send-keys -t "$session" -l X
  lem_keys "$session" C-/
  tmux_cmd send-keys -t "$session" -l Y
  lem_keys "$session" C-x u
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Fq 'Prompt edit: quick-lookup' <<<"$screen" &&
     grep -Fq 'quick-lookup' <<<"$screen"; then
    lem_keys "$session" Enter
    if wait_report_count '^PROMPT-EDIT-SELECT value=quick-lookup$' \
         $((prompt_edit_before + 1)); then
      pass prompt-emacs-undo \
        'C-/ and C-x u restored input without crossing the prompt boundary'
    else
      fail prompt-emacs-undo \
        'Return did not accept the physically undone prompt value' "$session"
    fi
  else
    fail prompt-emacs-undo \
      'prompt undo damaged the label, input, or live completion' "$session"
    close_prompt
  fi
else
  fail prompt-emacs-undo 'the undo prompt did not open' "$session"
fi

# Evil is disabled in the configured Emacs minibuffer, so standard Emacs line
# editing remains active while Vertico is visible.  Exercise the corresponding
# Lem prompt behavior against a nonempty initial value.
if invoke_prompt_command lem-yath-test-prompt-line-editing \
     'Prompt edit: quick-lookup'; then
  # The third backward word kill starts on the empty editable field.  It must
  # leave the prompt label intact while the completion provider remains live.
  lem_keys "$session" C-e
  lem_keys "$session" M-BSpace
  lem_keys "$session" M-BSpace
  lem_keys "$session" M-BSpace
  tmux_cmd send-keys -t "$session" -l quick-lookup
  lem_keys "$session" C-a
  tmux_cmd send-keys -t "$session" -l X
  lem_keys "$session" C-e
  tmux_cmd send-keys -t "$session" -l Y
  lem_keys "$session" C-a
  lem_keys "$session" C-k
  tmux_cmd send-keys -t "$session" -l fixture-preset
  lem_keys "$session" C-a
  lem_keys "$session" M-f
  lem_keys "$session" M-d
  lem_keys "$session" C-y
  lem_keys "$session" M-b
  lem_keys "$session" C-b
  lem_keys "$session" C-f
  lem_keys "$session" C-d
  tmux_cmd send-keys -t "$session" -l p
  lem_keys "$session" C-e
  lem_keys "$session" C-t
  lem_keys "$session" C-t
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Fq 'Prompt edit: fixture-preset' <<<"$screen" &&
     grep -Fq 'fixture-preset' <<<"$screen"; then
    lem_keys "$session" Enter
    if wait_report_count '^PROMPT-EDIT-SELECT value=fixture-preset$' 1; then
      pass prompt-emacs-line-editing \
        'Emacs line, character, boundary-safe word-kill, yank, and transpose keys stayed live'
    else
      fail prompt-emacs-line-editing \
        'Return did not accept the physically edited prompt value' "$session"
    fi
  else
    fail prompt-emacs-line-editing \
      'line editing did not replace the initial value with live completion' \
      "$session"
    close_prompt
  fi
else
  fail prompt-emacs-line-editing 'the line-editing prompt did not open' \
    "$session"
fi

# Vertico keeps the prompt editable after a zero-result query and repopulates
# candidates as soon as the query becomes valid again.  Exercise the actual
# M-x command provider first, including its Marginalia-style documentation.
lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" M-x
if lem_wait_for "$session" 'Command:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath-test-buffer-promptx'
  lem_wait_for "$session" 'Command: lem-yath-test-buffer-promptx' 10 \
    >/dev/null || true
  screen=$(lem_capture "$session")
  if grep -Fq 'Command: lem-yath-test-buffer-promptx' <<<"$screen" &&
     ! grep -Fq 'Open the configured buffer prompt over the fixture buffers.' \
       <<<"$screen"; then
    pass command-zero-results 'M-x retained the unmatched query without stale candidates'
  else
    fail command-zero-results 'M-x did not settle on a clean zero-result prompt' "$session"
  fi
  lem_keys "$session" BSpace
  lem_wait_for "$session" 'Command: lem-yath-test-buffer-prompt([^x]|$)' 10 \
    >/dev/null || true
  screen=$(lem_capture "$session")
  if grep -Fq 'Command: lem-yath-test-buffer-prompt' <<<"$screen" &&
     grep -Fq 'Open the configured buffer prompt over the fixture buffers.' \
       <<<"$screen"; then
    pass command-zero-recovery 'Backspace restored the exact M-x candidate in place'
  else
    fail command-zero-recovery 'M-x candidates did not recover after Backspace' "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail command-zero-results 'M-x prompt did not open' "$session"
fi

chmod 640 "$LEM_YATH_PROMPT_COMPLETION_ROOT/files/nested/alpha-report.txt"
touch -d '2020-01-02 03:04:05 UTC' \
  "$LEM_YATH_PROMPT_COMPLETION_ROOT/files/nested/alpha-report.txt"

# Buffer metadata remains display-only and reports state, size, mode, and path.
if invoke_prompt_command lem-yath-test-buffer-prompt 'Fixture buffer:'; then
  tmux_cmd send-keys -t "$session" -l annotation-dirty
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Eq 'annotation-dirty\.py.*\*\*-.*7.*Python.*buffers/annotation-dirty\.py' \
       <<<"$screen"; then
    pass buffer-state-annotations \
      'modified Python buffer showed status, size, mode, and path'
  else
    fail buffer-state-annotations \
      'modified buffer metadata was incomplete or reordered' "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail buffer-state-annotations 'configured buffer prompt did not open' "$session"
fi

if invoke_prompt_command lem-yath-test-buffer-prompt 'Fixture buffer:'; then
  tmux_cmd send-keys -t "$session" -l annotation-readonly
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Eq 'annotation-readonly\.txt.*%%-.*9.*Fundamental.*buffers/annotation-readonly\.txt' \
       <<<"$screen"; then
    pass buffer-read-only-annotation \
      'read-only buffer showed its distinct status and metadata'
  else
    fail buffer-read-only-annotation \
      'read-only buffer metadata was incomplete' "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail buffer-read-only-annotation 'configured buffer prompt did not open' "$session"
fi

if invoke_prompt_command lem-yath-test-buffer-prompt 'Fixture buffer:'; then
  tmux_cmd send-keys -t "$session" -l annotation-readonly-modified
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Eq 'annotation-readonly-modified\.txt.*%\*-.*6.*Fundamental' \
       <<<"$screen"; then
    pass buffer-combined-state \
      'read-only modified buffer preserved both Marginalia status flags'
  else
    fail buffer-combined-state \
      'combined read-only and modified state collapsed one flag' "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail buffer-combined-state 'configured buffer prompt did not open' "$session"
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
  tmux_cmd send-keys -t "$session" -l sharedx
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Fq 'Fixture buffer: sharedx' <<<"$screen" &&
     ! grep -Eq 'shared\.txt.*buffers/(one|two)/shared\.txt' <<<"$screen"; then
    pass buffer-zero-results 'buffer prompt retained an unmatched query without stale rows'
  else
    fail buffer-zero-results 'buffer prompt did not enter a clean zero-result state' "$session"
  fi
  lem_keys "$session" BSpace
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Fq 'Fixture buffer: shared' <<<"$screen" &&
     grep -q 'buffers/one/shared.txt' <<<"$screen" &&
     grep -q 'buffers/two/shared.txt' <<<"$screen"; then
    pass buffer-zero-recovery 'Backspace restored both annotated buffer candidates'
  else
    fail buffer-zero-recovery 'buffer candidates did not recover after Backspace' "$session"
  fi

  # Once completion has ended on zero results, a further regexp character can
  # also make Prescient matching valid again ("z|" has an empty alternative).
  lem_keys "$session" C-g
  sleep 0.2
  lem_keys "$session" Escape
  if invoke_prompt_command lem-yath-test-buffer-prompt 'Fixture buffer:'; then
    tmux_cmd send-keys -t "$session" -l z
    sleep 0.5
    tmux_cmd send-keys -t "$session" -l '|'
    sleep 0.8
    screen=$(lem_capture "$session")
    if grep -Fq 'Fixture buffer: z|' <<<"$screen" &&
       grep -q 'buffers/one/shared.txt' <<<"$screen"; then
      pass buffer-insert-recovery 'further regexp input reopened buffer candidates'
    else
      fail buffer-insert-recovery 'non-deletion input could not recover completion' "$session"
    fi
  else
    fail buffer-insert-recovery 'second configured buffer prompt did not open' "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail buffer-zero-results 'configured buffer prompt did not open' "$session"
fi

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

# vertico-prescient-mode installs this exact prompt-local map at M-s.  Exercise
# every method plus both folding variables through real terminal key events.
prescient_toggle_test prescient-anchored FiFiAt find-file-at-point \
  absent present M-s a
prescient_toggle_test prescient-fuzzy ayc axbyc absent present M-s f
prescient_toggle_test prescient-initialism sr string-repeat \
  present absent M-s i
prescient_toggle_test prescient-literal cafe café present absent M-s l
prescient_toggle_test prescient-prefix str-r string-repeat \
  absent present M-s p
prescient_toggle_test prescient-regexp '^needle$' needle \
  present absent M-s r
prescient_toggle_test prescient-character-fold cafe café \
  present absent M-s "'"
prescient_toggle_test prescient-case-fold alpha Alpha \
  present absent M-s c

# A prefix argument makes one method exclusive.  Literal-prefix then rejects
# an interior literal while retaining a true candidate prefix, and refusing to
# toggle off the sole method leaves the prompt usable.
if invoke_prompt_command lem-yath-test-prescient-toggle-prompt \
     'Prescient fixture:'; then
  tmux_cmd send-keys -t "$session" -l pha
  sleep 0.7
  screen=$(lem_capture "$session")
  if screen_has_toggle_candidate "$screen" alpha; then
    # Lem's universal-argument command enters its own key reader.  Give that
    # reader one terminal turn before delivering the M-s chord, as a person
    # naturally does when pressing the keys.
    lem_keys "$session" C-u
    sleep 0.2
    lem_keys "$session" M-s P
    sleep 0.7
    screen=$(lem_capture "$session")
    if ! screen_has_toggle_candidate "$screen" alpha &&
       grep -Fq 'phantom' <<<"$screen" &&
       grep -Eq 'PRESCIENT-STATE command=LEM-YATH-PRESCIENT-TOGGLE-LITERAL-PREFIX argument=4 methods=LITERAL-PREFIX' \
         "$LEM_YATH_PROMPT_COMPLETION_REPORT"; then
      pass prescient-literal-prefix \
        'C-u M-s P selected only candidate/word-prefix matching'
    else
      fail prescient-literal-prefix \
        'exclusive literal-prefix filtering returned the wrong candidates' \
        "$session"
    fi
    lem_keys "$session" M-s P
    sleep 0.5
    screen=$(lem_capture "$session")
    guard_state=$(grep \
      '^PRESCIENT-STATE command=LEM-YATH-PRESCIENT-TOGGLE-LITERAL-PREFIX ' \
      "$LEM_YATH_PROMPT_COMPLETION_REPORT" | tail -1)
    if grep -Fq 'phantom' <<<"$screen" &&
       grep -Fq 'argument=NIL methods=LITERAL-PREFIX' <<<"$guard_state" &&
       grep -Fq 'Prescient fixture:' <<<"$screen"; then
      pass prescient-only-method-guard \
        'the sole active filter could not be disabled accidentally'
    else
      fail prescient-only-method-guard \
        'the sole-method guard did not preserve the prompt' "$session"
    fi
  else
    fail prescient-literal-prefix \
      'the default literal baseline did not contain alpha' "$session"
  fi
  close_prompt
else
  fail prescient-literal-prefix 'the Prescient fixture prompt did not open' \
    "$session"
fi

# The preceding folding changes lived on deleted prompt buffers.  A fresh
# prompt must start from smart-case, character-folded defaults again.
if invoke_prompt_command lem-yath-test-prescient-toggle-prompt \
     'Prescient fixture:'; then
  tmux_cmd send-keys -t "$session" -l cafe
  sleep 0.7
  screen=$(lem_capture "$session")
  if screen_has_toggle_candidate "$screen" café; then
    pass prescient-prompt-local-state \
      'a fresh prompt restored the configured Prescient defaults'
  else
    fail prescient-prompt-local-state \
      'a previous prompt leaked its matching state' "$session"
  fi
  close_prompt
else
  fail prescient-prompt-local-state 'the fresh fixture prompt did not open' \
    "$session"
fi

# File prompt: narrow the first path component, use Vertico-style Tab to insert
# a slash-terminated directory without exiting, then narrow the nested files.
selected_file_name=""
if invoke_prompt_command lem-yath-test-file-prompt 'Fixture file:' &&
   lem_wait_for "$session" 'nested/' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l nestedx
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Eq 'Fixture file: .*nestedx' <<<"$screen" &&
     ! grep -Eq 'nested/[[:space:]]+drwx' <<<"$screen"; then
    pass file-zero-results 'file prompt retained an unmatched path component without stale rows'
  else
    fail file-zero-results 'file prompt did not enter a clean zero-result state' "$session"
  fi
  lem_keys "$session" BSpace
  sleep 0.8
  screen=$(lem_capture "$session")
  if grep -Eq 'Fixture file: .*nested[[:space:]]' <<<"$screen" &&
     grep -Eq 'nested/[[:space:]]+drwx' <<<"$screen"; then
    pass file-zero-recovery 'Backspace restored the slash-terminated directory candidate'
  else
    fail file-zero-recovery 'path candidates did not recover after Backspace' "$session"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail file-zero-results 'configured file prompt did not open' "$session"
fi

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

    screen=$(lem_capture "$session")
    if grep -Eq 'alpha-report\.txt.*-rw-r-----.*6.*2020 Jan 02' \
         <<<"$screen"; then
      pass file-annotations \
        'file candidate showed permissions, size, and deterministic mtime'
    else
      fail file-annotations \
        'file metadata was missing or participated in the wrong column' "$session"
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
