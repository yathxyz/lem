#!/usr/bin/env bash
# Real-ncurses coverage for Helpful-style typed symbol selection.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-help-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-help.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_HELP_SOURCE="$here/lem-yath/src/help.lisp"
mkdir -p "$HOME" "$WORKDIR/roam"

source "$here/scripts/tui-driver.sh"

session="lem-yath-help-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-26s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

open_help_prompt() {
  local suffix=$1 prompt=$2
  lem_keys "$session" Escape
  sleep 0.4
  lem_keys "$session" Escape
  sleep 0.4
  lem_keys "$session" Space h "$suffix"
  lem_wait_for "$session" "$prompt" 20 >/dev/null
}

fixture="$(lem-yath_lisp_string "$here/scripts/help-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"
if lem_wait_for "$session" 'NORMAL|Dashboard' 40 >/dev/null; then
  pass boot 'configured Lem loaded the help fixture'
else
  fail boot 'Lem did not reach the dashboard' "$session"
fi

if open_help_prompt k 'Callable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath::lem-yath-help-test-callabl'
  lem_wait_for "$session" 'Callable: lem-yath::lem-yath-help-test-callabl' 20 >/dev/null
  sleep 0.5
  screen=$(lem_capture "$session")
  if grep -Fq 'LEM-YATH::LEM-YATH-HELP-TEST-CALLABLE' <<<"$screen" &&
     grep -Fq 'function' <<<"$screen" &&
     grep -Fq 'ALPHA &OPTIONAL' <<<"$screen" &&
     grep -Fq 'BETA)' <<<"$screen" &&
     grep -Fq 'Zyzzyva-callable-documentation' <<<"$screen"; then
    pass callable-metadata 'SPC h k showed type, signature, and documentation'
  else
    fail callable-metadata 'the callable row lacked typed Marginalia fields' "$session"
  fi
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Zyzzyva-callable-documentation' 10 >/dev/null; then
    pass callable-selection 'Return described the exact non-command function'
  else
    fail callable-selection 'Return did not open the selected callable' "$session"
  fi
  lem_keys "$session" Space
  sleep 0.5
else
  fail callable-binding 'SPC h k did not open the callable prompt' "$session"
fi

if open_help_prompt k 'Callable:'; then
  tmux_cmd send-keys -t "$session" -l 'zyzzyva-callable-documentation'
  sleep 1
  if ! lem_capture "$session" | grep -Fq 'LEM-YATH::LEM-YATH-HELP-TEST-CALLABLE'; then
    pass metadata-display-only 'documentation did not become completion input'
  else
    fail metadata-display-only 'a callable matched through annotation text' "$session"
  fi
else
  fail metadata-display-only 'could not reopen the callable prompt' "$session"
fi

if open_help_prompt v 'Variable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath::*lem-yath-help-test-value'
  lem_wait_for "$session" 'Variable: lem-yath::\*lem-yath-help-test-value' 20 >/dev/null
  sleep 0.5
  screen=$(lem_capture "$session")
  if grep -Fq 'variable' <<<"$screen" &&
     grep -Fq '(ALPHA BETA GAMMA)' <<<"$screen" &&
     grep -Fq 'Zyzzyva-variable-documentation' <<<"$screen"; then
    pass variable-metadata 'SPC h v showed type, bounded value, and documentation'
  else
    fail variable-metadata 'the variable row lacked typed Marginalia fields' "$session"
  fi
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Zyzzyva-variable-documentation' 10 >/dev/null; then
    pass variable-selection 'Return described the exact variable'
  else
    fail variable-selection 'Return did not open the selected variable' "$session"
  fi
  lem_keys "$session" Space
  sleep 0.5
else
  fail variable-binding 'SPC h v did not open the variable prompt' "$session"
fi

if open_help_prompt v 'Variable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath::*lem-yath-help-test-api-key'
  lem_wait_for "$session" 'Variable: lem-yath::\*lem-yath-help-test-api-key' 20 >/dev/null
  sleep 0.5
  screen=$(lem_capture "$session")
  if grep -Fq '*****' <<<"$screen" &&
     ! grep -Fq 'ZYZZYVA-SECRET-MUST-NEVER-RENDER' <<<"$screen"; then
    lem_keys "$session" Enter
    sleep 0.5
    if lem_capture "$session" | grep -Fq '*****' &&
       ! lem_capture "$session" | grep -Fq 'ZYZZYVA-SECRET-MUST-NEVER-RENDER'; then
      pass secret-censoring 'credential values stayed hidden in prompt and help buffer'
    else
      fail secret-censoring 'the final help buffer exposed a credential value' "$session"
    fi
    lem_keys "$session" Space
    sleep 0.5
  else
    fail secret-censoring 'the completion row exposed or omitted the censored value' "$session"
  fi
else
  fail secret-censoring 'could not open the credential variable prompt' "$session"
fi

if open_help_prompt v 'Variable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath-help-other::*lem-yath-help-test-value*'
  sleep 1
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Zyzzyva-other-package-documentation' 10 >/dev/null &&
     lem_capture "$session" | grep -Fq 'OTHER-PACKAGE-VALUE'; then
    pass qualified-identity 'same-named symbols remained package-distinct'
  else
    fail qualified-identity 'qualified selection resolved the wrong symbol' "$session"
  fi
  lem_keys "$session" Space
  sleep 0.5
else
  fail qualified-identity 'could not reopen the variable prompt' "$session"
fi

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" F8
if lem_wait_for "$session" 'HELP-RELOADED' 10 >/dev/null &&
   open_help_prompt k 'Callable:'; then
  pass reload 'source reload retained the exact leader workflow'
else
  fail reload 'source reload broke the callable workflow' "$session"
fi

if ((failed)); then
  printf '\nHELP TEST FAILED\n'
  exit 1
fi

printf '\nHELP TEST PASSED\n'
