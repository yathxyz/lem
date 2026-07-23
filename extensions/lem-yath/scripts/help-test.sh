#!/usr/bin/env bash
# Real-ncurses coverage for typed Helpful inspection and source navigation.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-help-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-help.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_HELP_SOURCE="${LEM_YATH_HELP_SOURCE:-${LEM_YATH_SOURCE:-$here/lem-yath}/src/help.lisp}"
export LEM_YATH_HELP_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR/roam"
: >"$LEM_YATH_HELP_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-help-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

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

return_to_origin() {
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" F7
  lem_wait_for "$session" 'ZYZZYVA-HELP-ORIGIN' 10 >/dev/null
}

wait_report() {
  local pattern=$1 timeout=${2:-10} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_HELP_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

report_state() {
  local pattern=$1
  : >"$LEM_YATH_HELP_REPORT"
  lem_keys "$session" F5
  wait_report "$pattern" 10
}

fixture_path="$root/help-fixture.lisp"
cp "$here/scripts/help-fixture.lisp" "$fixture_path"
fixture="$(lem-yath_lisp_string "$fixture_path")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"
if lem_wait_for "$session" 'ZYZZYVA-HELP-ORIGIN' 40 >/dev/null &&
   lem_wait_for "$session" 'NORMAL' 10 >/dev/null; then
  pass boot 'configured Lem loaded the isolated help fixture'
else
  fail boot 'Lem did not reach the stable origin buffer' "$session"
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
  if lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null; then
    screen=$(lem_capture "$session")
    if grep -Fq 'Source' <<<"$screen" &&
       grep -Fq 'Callers (' <<<"$screen" &&
       grep -Fq 'LEM-YATH::LEM-YATH-HELP-TEST-CALLER' <<<"$screen"; then
      pass callable-selection 'Return opened source-backed callable help with callers'
    else
      fail callable-selection 'callable help lacked source or caller rows' "$session"
    fi
  else
    fail callable-selection 'Return did not open the selected callable' "$session"
  fi

  touch -d '2031-01-02 03:04:05 UTC' "$fixture_path"
  lem_keys "$session" s
  if lem_wait_for "$session" 'Helpful source changed; press g to refresh' 10 >/dev/null; then
    pass stale-source 'a changed source invalidated the rendered location'
  else
    fail stale-source 's followed a stale source offset' "$session"
  fi
  lem_keys "$session" g
  sleep 0.8
  lem_keys "$session" s
  sleep 0.8
  if report_state '^HELP-STATE buffer=help-fixture\.lisp .* token=callable$'; then
    pass source-refresh 'g rebuilt locations and s reached the exact definition'
  else
    fail source-refresh 'refresh did not restore the callable source jump' "$session"
  fi
  return_to_origin
else
  fail callable-binding 'SPC h k did not open the callable prompt' "$session"
fi

if open_help_prompt k 'Callable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath::lem-yath-help-test-callabl'
  sleep 0.7
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null &&
     lem_wait_for "$session" 'Callers \(' 10 >/dev/null; then
    lem_keys "$session" n
    if report_state 'location=LEM-YATH::LEM-YATH-HELP-TEST-CALLABLE token=other$'; then
      lem_keys "$session" n
      if report_state 'location=LEM-YATH::LEM-YATH-HELP-TEST-CALLER token=caller$'; then
        lem_keys "$session" Enter
        sleep 0.8
        if report_state '^HELP-STATE buffer=help-fixture\.lisp .* token=caller$'; then
          pass caller-navigation 'n and RET visited the exact caller definition'
        else
          fail caller-navigation 'RET did not visit the selected caller' "$session"
        fi
      else
        fail caller-navigation 'the second n did not select the caller row' "$session"
      fi
    else
      fail caller-navigation 'the first n did not select the definition row' "$session"
    fi
  else
    fail caller-navigation 'callable help did not expose caller rows' "$session"
  fi
  return_to_origin
else
  fail caller-navigation 'could not reopen callable help for navigation' "$session"
fi

if open_help_prompt k 'Callable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath::lem-yath-help-test-callabl'
  sleep 0.7
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null; then
    lem_keys "$session" p
    if report_state 'location=LEM-YATH::LEM-YATH-HELP-TEST-CALLER token=caller$'; then
      lem_keys "$session" BTab
      if report_state 'location=LEM-YATH::LEM-YATH-HELP-TEST-CALLABLE token=other$'; then
        pass reverse-navigation 'p wrapped backward and S-Tab returned to source'
      else
        fail reverse-navigation 'S-Tab did not select the previous source row' "$session"
      fi
    else
      fail reverse-navigation 'p did not wrap to the final caller row' "$session"
    fi
    lem_keys "$session" q
    sleep 0.5
  else
    fail reverse-navigation 'callable help did not open for reverse navigation' "$session"
  fi
else
  fail reverse-navigation 'could not reopen callable help for reverse navigation' "$session"
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
  if lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null; then
    screen=$(lem_capture "$session")
    if grep -Fq 'Source' <<<"$screen" &&
       grep -Fq 'References (' <<<"$screen" &&
       grep -Fq 'LEM-YATH::LEM-YATH-HELP-TEST-READER' <<<"$screen"; then
      pass variable-selection 'Return opened source-backed variable help with references'
    else
      fail variable-selection 'variable help lacked source or reference rows' "$session"
    fi
    lem_keys "$session" Tab
    if report_state 'location=LEM-YATH::\*LEM-YATH-HELP-TEST-VALUE\* token=other$'; then
      lem_keys "$session" Tab
      if report_state 'location=LEM-YATH::LEM-YATH-HELP-TEST-READER token=reader$'; then
        lem_keys "$session" Enter
        sleep 0.8
        if report_state '^HELP-STATE buffer=help-fixture\.lisp .* token=reader$'; then
          pass reference-navigation 'Tab and RET visited the exact variable reader'
        else
          fail reference-navigation 'RET did not visit the selected variable reader' "$session"
        fi
      else
        fail reference-navigation 'the second Tab did not select the reference row' "$session"
      fi
    else
      fail reference-navigation 'the first Tab did not select the definition row' "$session"
    fi
  else
    fail variable-selection 'Return did not open the selected variable' "$session"
  fi
  return_to_origin
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
    lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null
    if lem_capture "$session" | grep -Fq '*****' &&
       ! lem_capture "$session" | grep -Fq 'ZYZZYVA-SECRET-MUST-NEVER-RENDER'; then
      pass secret-censoring 'credential values stayed hidden in prompt and help buffer'
    else
      fail secret-censoring 'the final help buffer exposed a credential value' "$session"
    fi
    lem_keys "$session" q
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
  if lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null &&
     lem_wait_for "$session" 'Zyzzyva-other-package-documentation' 10 >/dev/null &&
     lem_capture "$session" | grep -Fq 'OTHER-PACKAGE-VALUE'; then
    pass qualified-identity 'same-named symbols remained package-distinct'
  else
    fail qualified-identity 'qualified selection resolved the wrong symbol' "$session"
  fi
  lem_keys "$session" q
  sleep 0.5
else
  fail qualified-identity 'could not reopen the variable prompt' "$session"
fi

return_to_origin
if open_help_prompt k 'Callable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath::lem-yath-help-test-callabl'
  sleep 0.7
  lem_keys "$session" Enter
  lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null
  lem_keys "$session" q
  sleep 0.5
  if report_state '^HELP-STATE buffer=\*Help Origin\* .* position=1:8 .* token=origin$'; then
    pass quit-window 'q restored the exact originating buffer and point'
  else
    fail quit-window 'q did not restore the originating window' "$session"
  fi
else
  fail quit-window 'could not open help for quit-window coverage' "$session"
fi

return_to_origin
lem_keys "$session" Space h K
if lem_wait_for "$session" 'Helpful key:' 10 >/dev/null; then
  lem_keys "$session" F5
  if lem_wait_for "$session" 'Zyzzyva-key-command-documentation' 10 >/dev/null; then
    screen=$(lem_capture "$session")
    if grep -Fq 'Key: F5' <<<"$screen" &&
       grep -Fq 'Type: command' <<<"$screen" &&
       grep -Fq 'Source' <<<"$screen"; then
      pass key-inspection 'SPC h K resolved F5 into the same navigable command help'
    else
      fail key-inspection 'key help omitted the key, command type, or source' "$session"
    fi
    lem_keys "$session" q
    sleep 0.5
  else
    fail key-inspection 'SPC h K did not inspect the resolved command' "$session"
  fi
else
  fail key-inspection 'SPC h K did not begin key capture' "$session"
fi

return_to_origin
lem_keys "$session" Escape Escape M-x
if lem_wait_for "$session" 'Command:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'describe-face'
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Face:' 20 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l 'lem-yath::lem-yath-help-test-face'
    sleep 0.8
    screen=$(lem_capture "$session")
    if grep -Fq 'AaBbYyZz' <<<"$screen" &&
       grep -Fq 'fg #12ab34' <<<"$screen" &&
       grep -Fq 'bg #251144' <<<"$screen" &&
       grep -Fq 'bold' <<<"$screen" &&
       grep -Fq 'underline' <<<"$screen"; then
      pass face-metadata 'M-x describe-face showed the effective face sample and style'
    else
      fail face-metadata 'the face candidate lacked Marginalia-style metadata' "$session"
    fi
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null; then
      screen=$(lem_capture "$session")
      if grep -Fq 'Foreground: #12ab34' <<<"$screen" &&
         grep -Fq 'Background: #251144' <<<"$screen" &&
         grep -Fq 'Bold: yes' <<<"$screen" &&
         grep -Fq 'Underline: T' <<<"$screen" &&
         grep -Fq 'Sample' <<<"$screen"; then
        pass face-selection 'Return opened a themed, read-only face help buffer'
      else
        fail face-selection 'the selected face help omitted effective properties' "$session"
      fi
      lem_keys "$session" s
      sleep 0.8
      if report_state '^HELP-STATE buffer=help-fixture\.lisp .* token=face$'; then
        pass face-source 's visited the defining face form'
      else
        fail face-source 'face help did not retain its source definition' "$session"
      fi
      return_to_origin
    else
      fail face-selection 'Return did not open face help' "$session"
    fi
  else
    fail face-command 'M-x describe-face did not open the Face prompt' "$session"
  fi
else
  fail face-command 'M-x did not open for describe-face' "$session"
fi

return_to_origin
if open_help_prompt k 'Callable:'; then
  tmux_cmd send-keys -t "$session" -l 'lem-yath::lem-yath-help-test-callabl'
  sleep 0.7
  lem_keys "$session" Enter
  lem_wait_for "$session" 'Helpful: q quit' 30 >/dev/null
  lem_keys "$session" F8
  if lem_wait_for "$session" 'HELP-RELOADED' 10 >/dev/null; then
    if report_state '^HELP-STATE buffer=\*Callable Help\* mode=LEM-YATH-HELP-MODE modes=1 '; then
      lem_keys "$session" g
      sleep 0.8
      lem_keys "$session" q
      sleep 0.5
      if report_state '^HELP-STATE buffer=\*Help Origin\* .* position=1:8 .* token=origin$'; then
        pass reload 'reload retained one active mode plus refresh and quit behavior'
      else
        fail reload 'the reloaded help mode lost its originating window' "$session"
      fi
    else
      fail reload 'reload duplicated or detached the active help mode' "$session"
    fi
  else
    fail reload 'source reload did not complete in the active help buffer' "$session"
  fi
else
  fail reload 'could not open callable help for reload coverage' "$session"
fi

if ((failed)); then
  printf '\nHELP TEST FAILED\n'
  exit 1
fi

printf '\nHELP TEST PASSED\n'
