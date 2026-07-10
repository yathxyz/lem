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

run_mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  lem_keys "$session" Enter
  sleep 0.25
  lem_keys "$session" Enter
  sleep 0.4
}

enter_insert() {
  lem_keys "$session" i
  lem_wait_for "$session" 'INSERT' 5 >/dev/null
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

if run_mx lem-yath-test-auto-completion-static-checks &&
   wait_report '^SUMMARY STATIC PASS failures=0$' 10; then
  pass static-contracts "threshold, delay, rows, and empty LSP completion passed"
else
  fail static-contracts "static automatic-completion contracts failed"
fi

if run_mx lem-yath-test-auto-dabbrev-setup &&
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
  lem_keys "$session" C-p
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 2)) 5 || true
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
  wait_report_count '^FOCUS ' $((before + 3)) 5 || true
  last=$(grep '^FOCUS ' "$LEM_YATH_AUTO_COMPLETION_REPORT" | tail -n 1 | cut -d' ' -f2-)
  lem_keys "$session" C-n
  lem_keys "$session" F5
  wait_report_count '^FOCUS ' $((before + 4)) 5 || true
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

if run_mx lem-yath-test-auto-dabbrev-setup && enter_insert; then
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

if run_mx lem-yath-test-auto-dabbrev-setup && enter_insert; then
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

if run_mx lem-yath-test-auto-middle-setup &&
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

if run_mx lem-yath-test-auto-primary-setup &&
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

if run_mx lem-yath-test-auto-file-setup &&
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

if run_mx lem-yath-test-auto-cancel-setup &&
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

if run_mx lem-yath-test-auto-async-setup &&
   wait_report '^SETUP async$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l asy
  if wait_report '^REQUEST asy$' 10; then
    tmux_cmd send-keys -t "$session" -l n
    if wait_report '^REQUEST asyn$' 10; then
      lem_keys "$session" F6
      wait_report '^DELIVER old$' 5 || true
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
