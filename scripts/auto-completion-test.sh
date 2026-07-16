#!/usr/bin/env bash
# Real-TUI tests for Corfu/Cape-style automatic in-buffer completion.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-auto-completion-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-auto-completion.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_AUTO_COMPLETION_REPORT="$root/report"
export LEM_YATH_AUTO_COMPLETION_FILE_DIR="$root/files/"
mkdir -p "$HOME" "$WORKDIR/roam" "$LEM_YATH_AUTO_COMPLETION_FILE_DIR"
touch "$LEM_YATH_AUTO_COMPLETION_FILE_DIR/alpha-file.txt"
touch "$LEM_YATH_AUTO_COMPLETION_FILE_DIR/alpine-file.txt"
source "$here/scripts/tui-driver.sh"

session="lem-yath-auto-completion-$id"
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
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-10} i=0
  while ((i < timeout * 4)); do
    if [ -f "$LEM_YATH_AUTO_COMPLETION_REPORT" ] &&
       grep -qE "$pattern" "$LEM_YATH_AUTO_COMPLETION_REPORT"; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-10} i=0 count
  while ((i < timeout * 4)); do
    count=$(grep -cE "$pattern" "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    if [ "$count" -ge "$expected" ]; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

run_fixture_command() {
  local command=$1
  local key
  # Corfu's Escape reset is staged.  Quit completion in one step, then let
  # Escape perform only Vi's Insert-to-Normal transition.
  lem_keys "$session" C-g
  sleep 0.25
  lem_keys "$session" Escape
  sleep 0.25
  lem_wait_for "$session" 'NORMAL' 5 >/dev/null || return 1
  case "$command" in
    lem-yath-test-auto-completion-static-checks) key=s ;;
    lem-yath-test-auto-corfu-setup) key=c ;;
    lem-yath-test-auto-valid-setup) key=v ;;
    lem-yath-test-auto-exact-setup) key=e ;;
    lem-yath-test-auto-corfu-middle-setup) key=r ;;
    lem-yath-test-auto-async-setup) key=a ;;
    lem-yath-test-auto-dabbrev-setup) key=d ;;
    lem-yath-test-auto-corfu-lisp-setup) key=l ;;
    lem-yath-test-auto-middle-setup) key=m ;;
    lem-yath-test-auto-primary-setup) key=p ;;
    lem-yath-test-auto-file-setup) key=f ;;
    lem-yath-test-auto-cape-order-setup) key=q ;;
    lem-yath-test-auto-cape-case-setup) key=k ;;
    lem-yath-test-auto-cancel-setup) key=x ;;
    *) return 1 ;;
  esac
  lem_keys "$session" C-c z "$key"
  sleep 0.4
}

enter_insert() {
  lem_keys "$session" i
  lem_wait_for "$session" 'INSERT' 5 >/dev/null
}

setup_corfu_popup() {
  run_fixture_command lem-yath-test-auto-corfu-setup &&
    wait_report '^SETUP corfu$' 10 &&
    enter_insert &&
    tmux_cmd send-keys -t "$session" -l pre &&
    lem_wait_for "$session" 'previewAlpha' 10 >/dev/null
}

setup_valid_popup() {
  run_fixture_command lem-yath-test-auto-valid-setup &&
    wait_report '^SETUP valid-fold$' 10 &&
    lem_keys "$session" a &&
    lem_wait_for "$session" 'INSERT' 5 >/dev/null &&
    tmux_cmd send-keys -t "$session" -l d &&
    lem_wait_for "$session" 'ValidExtra' 10 >/dev/null
}

setup_exact_popup() {
  run_fixture_command lem-yath-test-auto-exact-setup &&
    wait_report '^SETUP exact$' 10 &&
    lem_keys "$session" a &&
    lem_wait_for "$session" 'INSERT' 5 >/dev/null &&
    tmux_cmd send-keys -t "$session" -l t &&
    lem_wait_for "$session" 'exactExtra' 10 >/dev/null
}

report_corfu_state() {
  local before
  before=$(grep -c '^CORFU STATE ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" F10
  wait_report_count '^CORFU STATE ' $((before + 1)) 5 || return 1
  grep '^CORFU STATE ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/auto-completion-fixture.lisp")"
scratch="$LEM_YATH_AUTO_COMPLETION_FILE_DIR/test-buffer.txt"
: >"$scratch"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$scratch"
if ! lem_wait_for "$session" 'NORMAL' 40 >/dev/null; then
  fail boot "Lem did not reach the test buffer"
else
  pass boot "fixture loaded in the real ncurses editor"
fi

if run_fixture_command lem-yath-test-auto-completion-static-checks &&
   wait_report '^SUMMARY STATIC PASS failures=0$' 10; then
  pass static-contracts "threshold, delay, rows, change groups, and empty LSP passed"
else
  fail static-contracts "static automatic-completion contracts failed"
fi

if setup_valid_popup; then
  valid_prompt=$(report_corfu_state || true)
  valid_accept_before=$(grep -c '^VALID ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" Tab
  sleep 0.2
  valid_tab=$(report_corfu_state || true)
  lem_keys "$session" C-n
  sleep 0.2
  valid_focus=$(report_corfu_state || true)
  lem_keys "$session" C-p
  sleep 0.2
  valid_return=$(report_corfu_state || true)
  lem_keys "$session" Enter
  sleep 0.2
  lem_keys "$session" F7
  valid_accept_after=$(grep -c '^VALID ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  if grep -q 'buffer="valid".*preselect=NIL selected=NIL preview=NIL.*focus=NIL.*items=2 valid-focus=0 valid-accept=0' <<<"$valid_prompt" &&
     grep -q 'buffer="valid".*preselect=NIL selected=NIL preview=NIL.*focus=NIL.*items=2 valid-focus=0 valid-accept=0' <<<"$valid_tab" &&
     grep -q 'preselect=NIL selected="Valid" preview=T.*focus=T.*valid-focus=1 valid-accept=0' <<<"$valid_focus" &&
     grep -q 'preselect=NIL selected=NIL preview=NIL.*focus=NIL.*valid-focus=1 valid-accept=0' <<<"$valid_return" &&
     [ "$valid_accept_after" -eq "$valid_accept_before" ] &&
     wait_report '^STATE none buffer=valid timer=NIL$' 5; then
    pass corfu-preselect-valid "provider-valid case-folded input stayed on the prompt row"
  else
    fail corfu-preselect-valid "valid prompt focus or acceptance diverged: $valid_prompt / $valid_tab / $valid_focus / $valid_return"
  fi
else
  fail corfu-preselect-valid-setup "could not prepare the provider-valid prompt scenario"
fi

if setup_exact_popup; then
  exact_state=$(report_corfu_state || true)
  exact_accept_before=$(grep -c '^VALID ACCEPT exact ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" Tab
  sleep 0.2
  lem_keys "$session" F7
  exact_accept_after=$(grep -c '^VALID ACCEPT exact ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  if grep -q 'buffer="exact".*preselect="exact" selected="exact" preview=NIL.*items=2' <<<"$exact_state" &&
     [ "$exact_accept_after" -eq $((exact_accept_before + 1)) ] &&
     wait_report '^STATE none buffer=exact timer=NIL$' 5; then
    pass corfu-preselect-exact "same-case exact candidate moved first and remained actionable"
  else
    fail corfu-preselect-exact "exact candidate ordering or acceptance diverged: $exact_state"
  fi
else
  fail corfu-preselect-exact-setup "could not prepare the same-case exact scenario"
fi

if setup_corfu_popup; then
  lem_keys "$session" C-n
  lem_keys "$session" M-Space
  tmux_cmd send-keys -t "$session" -l zz
  sleep 0.3
  no_match=$(report_corfu_state || true)
  no_match_accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" Tab
  sleep 0.2
  no_match_tab=$(report_corfu_state || true)
  lem_keys "$session" Enter
  sleep 0.2
  lem_keys "$session" F7
  no_match_accept_after=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  if grep -q 'context=T buffer="pre zz".*preselect=NIL selected=NIL preview=NIL.*focus=NIL.*items=0' <<<"$no_match" &&
     grep -q 'context=T buffer="pre zz".*preselect=NIL selected=NIL preview=NIL.*focus=NIL.*items=0' <<<"$no_match_tab" &&
     [ "$no_match_accept_after" -eq "$no_match_accept_before" ] &&
     wait_report '^STATE none buffer=pre zz timer=NIL$' 5; then
    pass corfu-zero-match "local zero-match cleared focus and rejected stale Tab/Return acceptance"
  else
    fail corfu-zero-match "zero-match retained actionable state: $no_match / $no_match_tab"
  fi
else
  fail corfu-zero-match-setup "could not prepare the local-filter zero-match scenario"
fi

if setup_corfu_popup; then
  before_state=$(report_corfu_state || true)
  lem_keys "$session" C-n
  sleep 0.2
  after_state=$(report_corfu_state || true)
  before_invariants=$(sed -E 's/ preselect=.*$//' <<<"$before_state")
  after_invariants=$(sed -E 's/ preselect=.*$//' <<<"$after_state")
  if [ -n "$before_state" ] &&
     [ "$before_invariants" = "$after_invariants" ] &&
     grep -q 'preselect="previewAlpha" selected="previewBeta" preview=T' <<<"$after_state" &&
     grep -q 'preview-text="previewBeta" group=T owned-floats=1' <<<"$after_state" &&
     grep -q 'geometry=T under-popup=T cursor-hidden=T' <<<"$after_state"; then
    pass corfu-preview "C-n rendered previewBeta in place without touching source or undo state"
  else
    fail corfu-preview "selection preview changed invariants: $before_state -> $after_state"
  fi

  lem_keys "$session" Escape
  sleep 0.2
  reset_state=$(report_corfu_state || true)
  if grep -q 'context=T buffer="pre"' <<<"$reset_state" &&
     grep -q 'preselect="previewAlpha" selected="previewAlpha" preview=NIL' <<<"$reset_state" &&
     grep -q 'owned-floats=0' <<<"$reset_state"; then
    pass corfu-selection-reset "first Escape returned to preselect and kept the popup"
  else
    fail corfu-selection-reset "first Escape did not clear only selection: $reset_state"
  fi

  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" F7
  if wait_report '^STATE none buffer=pre timer=NIL$' 5; then
    pass corfu-unchanged-quit "next Escape quit unchanged completion input"
  else
    fail corfu-unchanged-quit "unchanged second Escape did not close the popup"
  fi
else
  fail corfu-preview-setup "could not prepare the Corfu preview scenario"
fi

# Prompt completion reserves C-u for a universal argument, but an ordinary
# Corfu popup must still fall through to the configured Evil insert action.
if setup_corfu_popup; then
  control_u_before=$(grep -c '^STATE none buffer= timer=NIL$' \
    "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" C-u
  sleep 0.4
  lem_keys "$session" F7
  screen=$(lem_capture "$session")
  if wait_report_count '^STATE none buffer= timer=NIL$' \
       $((control_u_before + 1)) 5 &&
     grep -Fq 'INSERT' <<<"$screen"; then
    pass corfu-control-u-fallthrough \
      'C-u closed the popup, deleted to indentation, and retained Insert state'
  else
    fail corfu-control-u-fallthrough \
      'prompt universal-argument routing leaked into ordinary completion'
  fi
else
  fail corfu-control-u-setup "could not prepare the C-u fallthrough scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" Tab
  if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5 &&
     grep -q '^CORFU ACCEPT previewAlpha count=1 buffer=previewAlpha$' "$LEM_YATH_AUTO_COMPLETION_REPORT"; then
    lem_keys "$session" F7
    accept_after=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    if [ "$accept_after" -eq $((accept_before + 1)) ] &&
       wait_report '^STATE none buffer=previewAlpha timer=NIL$' 5; then
      pass corfu-initial-tab "Tab accepted the initially preselected candidate once"
    else
      fail corfu-initial-tab "Tab did not finish the first candidate exactly once"
    fi
  else
    fail corfu-initial-tab "Tab moved focus or failed to accept previewAlpha"
  fi
else
  fail corfu-tab-setup "could not prepare the initial Tab scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" Tab
  if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5; then
    lem_keys "$session" Escape
    if lem_wait_for "$session" 'NORMAL' 5 >/dev/null; then
      lem_keys "$session" u
      sleep 0.3
      undo_state_before=$(grep -c '^STATE ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
      lem_keys "$session" F7
      wait_report_count '^STATE ' $((undo_state_before + 1)) 5 || true
      undo_state=$(grep '^STATE ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)
      if [ "$undo_state" = 'STATE none buffer= timer=NIL' ]; then
        pass corfu-vi-undo "one normal-state u reverted typed prefix and accepted completion"
      else
        fail corfu-vi-undo "accepted completion did not remain one Vi undo unit"
      fi
    else
      fail corfu-vi-undo "could not leave Insert state after acceptance"
    fi
  else
    fail corfu-vi-undo "Tab did not accept the undo probe candidate"
  fi
else
  fail corfu-vi-undo-setup "could not prepare the Vi undo scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" C-n
  tmux_cmd send-keys -t "$session" -l '!'
  if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5 &&
     [ "$(grep '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)" = 'CORFU ACCEPT previewBeta count=1 buffer=previewBeta' ]; then
    sleep 0.2
    lem_keys "$session" F7
    accept_after=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    if [ "$accept_after" -eq $((accept_before + 1)) ] &&
       wait_report '^STATE none buffer=previewBeta! timer=NIL$' 5; then
      pass corfu-commit-before-input "selected candidate committed once before literal input"
    else
      fail corfu-commit-before-input "literal input did not follow one candidate acceptance"
    fi
  else
    fail corfu-commit-before-input "previewBeta was not committed before punctuation"
  fi
else
  fail corfu-input-setup "could not prepare the commit-before-input scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" C-n
  lem_keys "$session" M-Space
  sleep 0.3
  separator_state=$(report_corfu_state || true)
  accept_after=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  if [ "$accept_after" -eq "$accept_before" ] &&
     grep -q 'context=T buffer="pre "' <<<"$separator_state" &&
     grep -q 'preselect="previewAlpha" selected="previewAlpha" preview=NIL' <<<"$separator_state"; then
    pass corfu-preview-separator "M-Space reset preview, inserted one separator, and refiltered"
  else
    fail corfu-preview-separator "M-Space committed or produced wrong state: $separator_state"
  fi
  lem_keys "$session" C-g
else
  fail corfu-separator-setup "could not prepare the previewed M-Space scenario"
fi

if setup_corfu_popup; then
  prev_before=$(grep -c '^CORFU REQUEST prev$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  tmux_cmd send-keys -t "$session" -l v
  if wait_report_count '^CORFU REQUEST prev$' $((prev_before + 1)) 5; then
    lem_keys "$session" C-n
    lem_keys "$session" Escape
    sleep 0.2
    first_reset=$(report_corfu_state || true)
    pre_before=$(grep -c '^CORFU REQUEST pre$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    lem_keys "$session" Escape
    sleep 0.2
    if wait_report_count '^CORFU REQUEST pre$' $((pre_before + 1)) 5; then
      restored_state=$(report_corfu_state || true)
      lem_keys "$session" Escape
      sleep 0.2
      lem_keys "$session" F7
      if grep -q 'context=T buffer="prev".*selected="previewAlpha" preview=NIL' <<<"$first_reset" &&
         grep -q 'context=T buffer="pre".*group=T' <<<"$restored_state" &&
         wait_report '^STATE none buffer=pre timer=NIL$' 5; then
        pass corfu-staged-escape "Escape reset selection, restored input, then quit"
      else
        fail corfu-staged-escape "three Escape stages diverged: $first_reset / $restored_state"
      fi
    else
      fail corfu-staged-escape "input reset did not refresh the original query"
    fi
  else
    fail corfu-staged-escape "edited query did not refresh before Escape"
  fi
else
  fail corfu-escape-setup "could not prepare the staged Escape scenario"
fi

if setup_corfu_popup; then
  prev_before=$(grep -c '^CORFU REQUEST prev$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  tmux_cmd send-keys -t "$session" -l v
  if wait_report_count '^CORFU REQUEST prev$' $((prev_before + 1)) 5; then
    accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    lem_keys "$session" C-g
    sleep 0.2
    lem_keys "$session" F7
    accept_after=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    if [ "$accept_after" -eq "$accept_before" ] &&
       wait_report '^STATE none buffer=prev timer=NIL$' 5; then
      pass corfu-c-g "C-g retained typed input without accepting a candidate"
    else
      fail corfu-c-g "C-g reset or committed completion input"
    fi
  else
    fail corfu-c-g "edited query did not refresh before C-g"
  fi
else
  fail corfu-c-g-setup "could not prepare the C-g scenario"
fi

if run_fixture_command lem-yath-test-auto-corfu-middle-setup &&
   wait_report '^SETUP corfu-middle$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l e
  if lem_wait_for "$session" 'previewAlpha' 10 >/dev/null; then
    lem_keys "$session" C-n
    sleep 0.2
    middle_preview=$(report_corfu_state || true)
    if grep -q 'context=T buffer="preZZ"' <<<"$middle_preview" &&
       grep -q 'selected="previewBeta" preview=T preview-text="previewBeta"' <<<"$middle_preview" &&
       grep -q 'geometry=T under-popup=T cursor-hidden=T' <<<"$middle_preview"; then
      pass corfu-full-range-preview "preview replaced the visible full token but not source text"
    else
      fail corfu-full-range-preview "middle-token preview leaked or left suffix: $middle_preview"
    fi
    lem_keys "$session" Escape
    sleep 0.2
    lem_keys "$session" Escape
    sleep 0.2
  else
    fail corfu-full-range-preview "middle-token popup did not appear"
  fi
else
  fail corfu-middle-setup "could not prepare the full-range preview scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" C-n
  lem_keys "$session" BSpace
  if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5; then
    sleep 0.05
    backspace_state=$(report_corfu_state || true)
    if [ "$(grep '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)" = 'CORFU ACCEPT previewBeta count=1 buffer=previewBeta' ] &&
       grep -q 'buffer="previewBet"' <<<"$backspace_state"; then
      pass corfu-commit-before-backspace "Backspace committed selection before deleting one character"
    else
      fail corfu-commit-before-backspace "Backspace did not follow candidate acceptance: $backspace_state"
    fi
  else
    fail corfu-commit-before-backspace "Backspace did not commit the selected candidate"
  fi
else
  fail corfu-backspace-setup "could not prepare the Backspace scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" C-n
  lem_keys "$session" M-BSpace
  if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5; then
    sleep 0.05
    word_kill_state=$(report_corfu_state || true)
    if [ "$(grep '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)" = 'CORFU ACCEPT previewBeta count=1 buffer=previewBeta' ] &&
       grep -q 'buffer=""' <<<"$word_kill_state"; then
      pass corfu-backward-word-kill "M-Backspace retained Corfu preview and edit semantics"
    else
      fail corfu-backward-word-kill "M-Backspace diverged in ordinary completion: $word_kill_state"
    fi
  else
    fail corfu-backward-word-kill "M-Backspace did not commit the selected candidate"
  fi
else
  fail corfu-backward-word-setup "could not prepare the M-Backspace scenario"
fi

if setup_corfu_popup; then
  lem_keys "$session" C-/
  sleep 0.2
  corfu_control_slash=$(report_corfu_state || true)
  if grep -q 'context=NIL buffer="pre"' <<<"$corfu_control_slash"; then
    pass corfu-control-slash-fallthrough \
      "prompt-local C-/ left ordinary completion on Lem's redo path"
  else
    fail corfu-control-slash-fallthrough \
      "prompt-local undo leaked into ordinary completion: $corfu_control_slash"
  fi
else
  fail corfu-control-slash-setup "could not prepare the C-/ scenario"
fi

if setup_corfu_popup; then
  lem_keys "$session" M-y
  sleep 0.2
  corfu_meta_y=$(report_corfu_state || true)
  if grep -q 'context=NIL buffer="pre"' <<<"$corfu_meta_y"; then
    pass corfu-meta-y-fallthrough \
      "prompt-local M-y replayed ordinary yank-pop without source mutation"
  else
    fail corfu-meta-y-fallthrough \
      "prompt-local yank-pop leaked into ordinary completion: $corfu_meta_y"
  fi
else
  fail corfu-meta-y-setup "could not prepare the M-y scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" C-n
  lem_keys "$session" Space
  if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5; then
    sleep 0.2
    lem_keys "$session" F7
    if [ "$(grep '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)" = 'CORFU ACCEPT previewBeta count=1 buffer=previewBeta' ] &&
       wait_report '^STATE none buffer=previewBeta  timer=NIL$' 5; then
      pass corfu-commit-before-space "Space committed selection before inserting one separator"
    else
      fail corfu-commit-before-space "Space did not follow candidate acceptance once"
    fi
  else
    fail corfu-commit-before-space "Space did not commit the selected candidate"
  fi
else
  fail corfu-space-setup "could not prepare the Space scenario"
fi

if setup_corfu_popup; then
  lem_keys "$session" C-n
  sleep 0.2
  tmux_cmd resize-window -t "$session" -x 170 -y 45
  sleep 0.5
  resized_state=$(report_corfu_state || true)
  tmux_cmd resize-window -t "$session" -x 180 -y 50
  sleep 0.3
  if grep -q 'context=T buffer="pre"' <<<"$resized_state" &&
     grep -q 'selected="previewBeta" preview=T.*owned-floats=1' <<<"$resized_state"; then
    pass corfu-resize "resize recomputed one preview without source mutation"
  else
    fail corfu-resize "resize lost or duplicated the selected preview: $resized_state"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
else
  fail corfu-resize-setup "could not prepare the resize scenario"
fi

if setup_corfu_popup; then
  lem_keys "$session" C-n
  lem_keys "$session" F2
  if wait_report '^SENTINEL made$' 5; then
    with_sentinel=$(report_corfu_state || true)
    lem_keys "$session" C-g
    sleep 0.2
    after_quit=$(report_corfu_state || true)
    if grep -q 'preview=T.*owned-floats=1 all-floats=3.*sentinel=T' <<<"$with_sentinel" &&
       grep -q 'context=NIL buffer="pre".*owned-floats=0 all-floats=1.*sentinel=T' <<<"$after_quit"; then
      pass corfu-owned-cleanup "quit removed only completion floats and preserved an unrelated float"
    else
      fail corfu-owned-cleanup "completion cleanup damaged float ownership: $with_sentinel / $after_quit"
    fi
    lem_keys "$session" F3
    wait_report '^SENTINEL cleared$' 5 || true
  else
    fail corfu-owned-cleanup "could not create the unrelated sentinel float"
  fi
else
  fail corfu-owned-cleanup-setup "could not prepare the owned-cleanup scenario"
fi

if setup_corfu_popup; then
  lem_keys "$session" C-n
  source_delete_before=$(grep -c '^SOURCE DELETE ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" F1
  if wait_report_count '^SOURCE DELETE ' $((source_delete_before + 1)) 5; then
    source_delete=$(grep '^SOURCE DELETE ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)
    if [ "$source_delete" = 'SOURCE DELETE context=NIL session=NIL buffer="pre" floats=0 accept=0 windows=1' ]; then
      pass corfu-source-window-delete "deleting the owner window removed context, preview, and transaction"
    else
      fail corfu-source-window-delete "source deletion leaked completion state: $source_delete"
    fi
  else
    fail corfu-source-window-delete "source-window deletion command did not complete"
  fi
else
  fail corfu-source-window-delete-setup "could not prepare the source-window deletion scenario"
fi

if run_fixture_command lem-yath-test-auto-async-setup &&
   wait_report '^SETUP async$' 10 && enter_insert; then
  request_before=$(grep -c '^REQUEST asy$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  tmux_cmd send-keys -t "$session" -l asy
  if wait_report_count '^REQUEST asy$' $((request_before + 1)) 10; then
    lem_keys "$session" F11
    if wait_report '^DELIVER current$' 5 &&
       lem_wait_for "$session" 'asyncAlpha' 5 >/dev/null; then
      lem_keys "$session" C-n
      sleep 0.2
      async_preview=$(report_corfu_state || true)
      nil_before=$(grep -c '^DELIVER nil$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
      lem_keys "$session" F12
      if wait_report_count '^DELIVER nil$' $((nil_before + 1)) 5; then
        sleep 0.2
        async_nil=$(report_corfu_state || true)
        if grep -q 'selected="asyncBeta" preview=T.*owned-floats=1' <<<"$async_preview" &&
           grep -q 'context=NIL buffer="asy".*owned-floats=0 all-floats=0' <<<"$async_nil"; then
          pass corfu-async-nil-cleanup "nil async result removed context and owned preview"
        else
          fail corfu-async-nil-cleanup "async cleanup leaked state: $async_preview / $async_nil"
        fi
      else
        fail corfu-async-nil-cleanup "nil async delivery command did not run"
      fi
    else
      fail corfu-async-nil-cleanup "async candidates were not presented"
    fi
  else
    fail corfu-async-nil-cleanup "async request did not start"
  fi
else
  fail corfu-async-nil-setup "could not prepare async preview cleanup"
fi

if run_fixture_command lem-yath-test-auto-dabbrev-setup &&
   wait_report '^SETUP dabbrev$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l al
  sleep 0.35
  if ! lem_capture "$session" | grep -q 'alphaCandidate'; then
    pass prefix-threshold "two characters did not open the popup"
  else
    fail prefix-threshold "completion opened before the three-character prefix"
  fi

  tmux_cmd send-keys -t "$session" -l p
  sleep 0.05
  if ! lem_capture "$session" | grep -q 'alphaCandidate'; then
    pass idle-delay "popup remained closed before 200 ms"
  else
    fail idle-delay "popup opened before the configured delay"
  fi

  if lem_wait_for "$session" 'alphaCandidate[0-9][0-9]' 10 >/dev/null; then
    pass dabbrev-popup "same-mode dynamic abbreviations appeared after 200 ms"
  else
    fail dabbrev-popup "dynamic-abbreviation popup did not appear"
  fi

  screen=$(lem_capture "$session")
  visible=$(grep -oE 'alphaCandidate[0-9]{2}' <<<"$screen" | sort -u | wc -l | tr -d ' ')
  if [ "$visible" = 10 ]; then
    pass ten-row-window "exactly ten of twelve candidates were visible"
  else
    fail ten-row-window "expected ten visible candidates, saw $visible"
  fi
  if ! grep -q 'alphaForeignCandidate' <<<"$screen"; then
    pass same-mode-scope "a candidate from another major mode was excluded"
  else
    fail same-mode-scope "dabbrev leaked a different-major-mode candidate"
  fi

  before=$(grep -c '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 1)) 5 || true
  first=$(grep '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1 | cut -d' ' -f2-)

  lem_keys "$session" M-n
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 2)) 5 || true
  meta_next=$(grep '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1 | cut -d' ' -f2-)
  lem_keys "$session" M-p
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 3)) 5 || true
  meta_back=$(grep '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1 | cut -d' ' -f2-)
  if [ -n "$first" ] && [ "$meta_next" != "$first" ] &&
     [ "$meta_back" = "$first" ]; then
    pass meta-navigation "M-n/M-p still moved ordinary popup candidates"
  else
    fail meta-navigation "ordinary popup focus changed $first -> $meta_next -> $meta_back"
  fi

  lem_keys "$session" C-p
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 4)) 5 || true
  first_again=$(grep '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1 | cut -d' ' -f2-)
  if [ -n "$first" ] && [ "$first" = "$first_again" ]; then
    pass no-cycle-first "C-p stayed on the first candidate"
  else
    fail no-cycle-first "C-p wrapped from $first to $first_again"
  fi

  for _ in $(seq 1 20); do
    lem_keys "$session" C-n
  done
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 5)) 5 || true
  last=$(grep '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1 | cut -d' ' -f2-)
  lem_keys "$session" C-n
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 6)) 5 || true
  last_again=$(grep '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1 | cut -d' ' -f2-)
  if [ -n "$last" ] && [ "$last" != "$first" ] && [ "$last" = "$last_again" ]; then
    pass no-cycle-last "C-n stayed on the last of all twelve candidates"
  else
    fail no-cycle-last "last-candidate boundary changed from $last to $last_again"
  fi

  lem_keys "$session" Enter
  sleep 0.4
  lem_keys "$session" F7
  if wait_report "^STATE none buffer=$last timer=NIL$" 5; then
    pass dabbrev-acceptance "Return inserted the selected fallback candidate"
  else
    fail dabbrev-acceptance "selected dabbrev candidate was not inserted"
  fi
else
  fail dabbrev-setup "could not prepare the dabbrev scenario"
fi

if run_fixture_command lem-yath-test-auto-dabbrev-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'alphaCandidate[0-9][0-9]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l '('
    sleep 0.3
    lem_keys "$session" F7
    screen=$(lem_capture "$session")
    if ! grep -q 'alphaCandidate' <<<"$screen" &&
       wait_report '^STATE none buffer=alp\(\) timer=NIL$' 5; then
      pass electric-pair-cancellation "an opener inserted its pair and closed the popup"
    else
      fail electric-pair-cancellation "electric insertion left a stale popup or wrong buffer"
    fi
  else
    fail electric-pair-cancellation "could not open the electric-pair test popup"
  fi
else
  fail electric-pair-setup "could not prepare the electric-pair scenario"
fi

if run_fixture_command lem-yath-test-auto-dabbrev-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'alphaCandidate[0-9][0-9]' 10 >/dev/null; then
    lem_keys "$session" F8
    sleep 0.3
    lem_keys "$session" F7
    screen=$(lem_capture "$session")
    if ! grep -q 'alphaCandidate' <<<"$screen" &&
       wait_report '^STATE none buffer=alp timer=NIL$' 5; then
      pass movement-cancellation "a non-completion movement closed the popup"
    else
      fail movement-cancellation "the popup survived moving outside its range"
    fi
  else
    fail movement-cancellation "could not open the movement test popup"
  fi
else
  fail movement-setup "could not prepare the movement scenario"
fi

if setup_corfu_popup; then
  accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  lem_keys "$session" C-n
  lem_keys "$session" F8
  if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5; then
    lem_keys "$session" F7
    if [ "$(grep '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)" = 'CORFU ACCEPT previewBeta count=1 buffer=previewBeta' ] &&
       wait_report '^STATE none buffer=previewBeta timer=NIL$' 5; then
      pass corfu-selected-movement "movement committed the selected semantic preview before moving"
    else
      fail corfu-selected-movement "selected movement lost or duplicated the previewed candidate"
    fi
  else
    fail corfu-selected-movement "movement did not commit the selected preview"
  fi
else
  fail corfu-selected-movement-setup "could not prepare selected movement"
fi

if run_fixture_command lem-yath-test-auto-corfu-lisp-setup &&
   wait_report '^SETUP corfu-lisp paredit=T$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l pre
  if lem_wait_for "$session" 'previewAlpha' 10 >/dev/null; then
    accept_before=$(grep -c '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    lem_keys "$session" C-n
    tmux_cmd send-keys -t "$session" -l '('
    if wait_report_count '^CORFU ACCEPT ' $((accept_before + 1)) 5; then
      lem_keys "$session" F7
      if [ "$(grep '^CORFU ACCEPT ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)" = 'CORFU ACCEPT previewBeta count=1 buffer=previewBeta' ] &&
         wait_report '^STATE none buffer=previewBeta \(\) timer=NIL$' 5; then
        pass corfu-selected-paredit "Paredit opener ran after committing the selected preview"
      else
        fail corfu-selected-paredit "Paredit did not receive the post-commit opener"
      fi
    else
      fail corfu-selected-paredit "selected preview was not committed before Paredit"
    fi
  else
    fail corfu-selected-paredit "Lisp Corfu popup did not appear"
  fi
else
  fail corfu-selected-paredit-setup "could not prepare Lisp/Paredit completion"
fi

if run_fixture_command lem-yath-test-auto-dabbrev-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'alphaCandidate[0-9][0-9]' 10 >/dev/null; then
    origin_before=$(grep -c '^ORIGIN completion-mode=' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    lem_keys "$session" F9
    sleep 0.3
    lem_keys "$session" F7
    wait_report_count '^ORIGIN completion-mode=' $((origin_before + 1)) 5 || true
    screen=$(lem_capture "$session")
    origin_state=$(grep '^ORIGIN completion-mode=' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1)
    if ! grep -q 'alphaCandidate' <<<"$screen" &&
       wait_report '^STATE none buffer= timer=NIL$' 5 &&
       [ "$origin_state" = 'ORIGIN completion-mode=NIL' ]; then
      pass buffer-switch-cancellation "switching buffers cleaned the origin mode and popup"
    else
      fail buffer-switch-cancellation "completion leaked across a buffer switch"
    fi
  else
    fail buffer-switch-cancellation "could not open the buffer-switch test popup"
  fi
else
  fail buffer-switch-setup "could not prepare the buffer-switch scenario"
fi

if run_fixture_command lem-yath-test-auto-middle-setup &&
   wait_report '^SETUP middle$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l n
  if lem_wait_for "$session" 'banana' 10 >/dev/null; then
    lem_keys "$session" Enter
    sleep 0.3
    lem_keys "$session" F7
    if wait_report '^STATE none buffer=banana timer=NIL$' 5; then
      pass middle-token-range "acceptance replaced the full existing symbol"
    else
      fail middle-token-range "acceptance left the old symbol suffix behind"
    fi
  else
    fail middle-token-range "middle-of-token completion did not appear"
  fi
else
  fail middle-token-setup "could not prepare the middle-of-token scenario"
fi

if run_fixture_command lem-yath-test-auto-primary-setup &&
   wait_report '^SETUP primary$' 10 && enter_insert; then
  primary_before=$(grep -c '^PRIMARY ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  tmux_cmd send-keys -t "$session" -l pri
  if lem_wait_for "$session" 'primaryOnlyCandidate' 10 >/dev/null; then
    sleep 0.3
    primary_after=$(grep -c '^PRIMARY ' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    if [ "$primary_after" -eq $((primary_before + 1)) ]; then
      pass debounce "rapid typing queried the provider exactly once"
    else
      fail debounce "expected one provider query, observed $((primary_after - primary_before))"
    fi
    lem_keys "$session" F5
    if wait_report '^STATE context automatic=T max=10 cycle=NIL items=1 popup=T buffer=pri$' 5; then
      pass singleton-display "one automatic candidate displayed without insertion"
    else
      fail singleton-display "automatic singleton changed the typed prefix"
    fi
    if ! lem_capture "$session" | grep -q 'privateFallbackCandidate'; then
      pass primary-exclusive "mode-local provider remained authoritative"
    else
      fail primary-exclusive "Cape fallback leaked into a primary provider"
    fi
    lem_keys "$session" Enter
    if wait_report '^ACCEPT primary buffer=primaryOnlyCandidate$' 5; then
      pass primary-acceptance "Return accepted the primary candidate once"
    else
      fail primary-acceptance "primary candidate acceptance failed"
    fi
  else
    fail singleton-display "primary singleton popup did not appear"
  fi
else
  fail primary-setup "could not prepare the primary-provider scenario"
fi

if run_fixture_command lem-yath-test-auto-file-setup &&
   wait_report '^SETUP file directory=' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l ./a
  if lem_wait_for "$session" 'alpha-file.txt' 10 >/dev/null; then
    pass file-short-prefix "file completion bypassed the three-symbol threshold"
    lem_keys "$session" Enter
    sleep 0.3
    lem_keys "$session" F7
    if wait_report '^STATE none buffer=\./alpha-file\.txt timer=NIL$' 5; then
      pass file-acceptance "file completion preserved the directory prefix"
    else
      fail file-acceptance "file candidate did not replace only its final component"
    fi
  else
    fail file-short-prefix "file-at-point fallback did not appear"
  fi
else
  fail file-setup "could not prepare the file scenario"
fi

if run_fixture_command lem-yath-test-auto-cape-order-setup &&
   wait_report '^SETUP cape-order directory=' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l ./alp
  if lem_wait_for "$session" '/alphaDabbrev' 10 >/dev/null; then
    screen=$(lem_capture "$session")
    if ! grep -q 'alpha-file.txt' <<<"$screen"; then
      pass cape-ordered-fallback "a path-shaped dabbrev candidate preempted Cape file completion"
    else
      fail cape-ordered-fallback "file candidates leaked beside the first nonempty Cape provider"
    fi
    lem_keys "$session" Enter
    sleep 0.3
    lem_keys "$session" F7
    if wait_report '^STATE none buffer=\./alphaDabbrev timer=NIL$' 5; then
      pass cape-dabbrev-range "Cape dabbrev replaced its slash-prefixed range"
    else
      fail cape-dabbrev-range "Cape dabbrev used the wrong path replacement range"
    fi
  else
    fail cape-ordered-fallback "path-shaped dabbrev did not win the ordered fallback"
  fi
else
  fail cape-ordered-setup "could not prepare the ordered Cape scenario"
fi

if run_fixture_command lem-yath-test-auto-cape-order-setup &&
   wait_report '^SETUP cape-order directory=' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l phb
  sleep 0.5
  lem_keys "$session" F7
  screen=$(lem_capture "$session")
  if ! grep -q 'prettyHugeBuffer' <<<"$screen" &&
     wait_report '^STATE none buffer=phb timer=NIL$' 5; then
    pass cape-prefix-only "Cape dabbrev did not turn Orderless into a global word matcher"
  else
    fail cape-prefix-only "a non-prefix dabbrev candidate bypassed Cape's dynamic table"
  fi
else
  fail cape-prefix-setup "could not prepare the Cape prefix scenario"
fi

if run_fixture_command lem-yath-test-auto-cape-case-setup &&
   wait_report '^SETUP cape-case$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l Alp
  if lem_wait_for "$session" 'AlphaDabbrev' 10 >/dev/null; then
    lem_keys "$session" Enter
    sleep 0.3
    lem_keys "$session" F7
    if wait_report '^STATE none buffer=AlphaDabbrev timer=NIL$' 5; then
      pass cape-initial-case "Cape Dabbrev preserved an initial-cap input"
    else
      fail cape-initial-case "initial-cap acceptance inserted the wrong case"
    fi
  else
    fail cape-initial-case "initial-cap Dabbrev candidate did not appear"
  fi
else
  fail cape-initial-case-setup "could not prepare initial-cap completion"
fi

if run_fixture_command lem-yath-test-auto-cape-case-setup &&
   wait_report '^SETUP cape-case$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l ALP
  if lem_wait_for "$session" 'ALPHADABBREV' 10 >/dev/null; then
    lem_keys "$session" Enter
    sleep 0.3
    lem_keys "$session" F7
    if wait_report '^STATE none buffer=ALPHADABBREV timer=NIL$' 5; then
      pass cape-upper-case "Cape Dabbrev promoted an all-caps input"
    else
      fail cape-upper-case "all-caps acceptance inserted the wrong case"
    fi
  else
    fail cape-upper-case "all-caps Dabbrev candidate did not appear"
  fi
else
  fail cape-upper-case-setup "could not prepare all-caps completion"
fi

if run_fixture_command lem-yath-test-auto-cancel-setup &&
   wait_report '^SETUP cancel$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l can
  lem_keys "$session" Escape
  sleep 0.5
  lem_keys "$session" F7
  screen=$(lem_capture "$session")
  if ! grep -q 'cancelShouldNotAppear' <<<"$screen" &&
     wait_report '^STATE none buffer=can timer=NIL$' 5; then
    pass escape-cancellation "Escape invalidated the pending wall timer"
  else
    fail escape-cancellation "completion survived leaving insert state"
  fi
else
  fail cancel-setup "could not prepare the cancellation scenario"
fi

if run_fixture_command lem-yath-test-auto-async-setup &&
   wait_report '^SETUP async$' 10 && enter_insert; then
  asy_before=$(grep -c '^REQUEST asy$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
  tmux_cmd send-keys -t "$session" -l asy
  if wait_report_count '^REQUEST asy$' $((asy_before + 1)) 10; then
    asyn_before=$(grep -c '^REQUEST asyn$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
    tmux_cmd send-keys -t "$session" -l n
    if wait_report_count '^REQUEST asyn$' $((asyn_before + 1)) 10; then
      deliver_before=$(grep -c '^DELIVER old$' "$LEM_YATH_AUTO_COMPLETION_REPORT" 2>/dev/null || true)
      lem_keys "$session" F6
      if wait_report_count '^DELIVER old$' $((deliver_before + 1)) 5; then
        sleep 0.3
        lem_keys "$session" F7
        screen=$(lem_capture "$session")
        if ! grep -q 'STALE-ASY' <<<"$screen" &&
           wait_report '^STATE none buffer=asyn timer=NIL$' 5; then
          pass async-cancellation "an old async result could not reopen the popup"
        else
          fail async-cancellation "a canceled async generation remained active"
        fi
      else
        fail async-cancellation "could not deliver the stale async callback"
      fi
    else
      fail async-cancellation "edited prefix did not issue a replacement request"
    fi
  else
    fail async-cancellation "initial automatic async request was not issued"
  fi
else
  fail async-setup "could not prepare the async scenario"
fi

echo
if [ -f "$LEM_YATH_AUTO_COMPLETION_REPORT" ]; then
  sed -n '1,260p' "$LEM_YATH_AUTO_COMPLETION_REPORT"
fi

if [ "$failed" = 0 ]; then
  echo "AUTO COMPLETION TEST PASSED"
  exit 0
else
  echo "AUTO COMPLETION TEST FAILED"
  exit 1
fi
