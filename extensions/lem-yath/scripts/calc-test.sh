#!/usr/bin/env bash
# Real-ncurses coverage for the configured GNU Calc / Evil-Collection surface.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-calc-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-calc.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_CALC_REPORT="$root/report"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
: >"$LEM_YATH_CALC_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-calc-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  sed -n '1,200p' "$LEM_YATH_CALC_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_CALC_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

report_after() {
  local before=$1 pattern=$2
  lem_keys "$session" F2
  local index=0
  while ((index < 60)); do
    if (( $(grep -c '^STATE ' "$LEM_YATH_CALC_REPORT" 2>/dev/null || true) > before )) &&
       tail -n 1 "$LEM_YATH_CALC_REPORT" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

state_count() {
  grep -c '^STATE ' "$LEM_YATH_CALC_REPORT" 2>/dev/null || true
}

open_calc() {
  lem_keys "$session" Escape Escape M-x
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l 'calc'
  sleep 0.4
  lem_keys "$session" Enter
  lem_wait_for "$session" '\*Calculator\*' 20 >/dev/null
}

fixture="$(lem-yath_lisp_string "$here/scripts/calc-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"

if lem_wait_for "$session" 'CALC ORIGIN' 60 >/dev/null &&
   lem_wait_for "$session" 'NORMAL' 10 >/dev/null &&
   wait_report '^READY$' 60; then
  pass boot 'configured Lem loaded the Calc origin in Normal state'
else
  fail boot 'Calc fixture did not become ready'
fi

open_calc
before=$(state_count)
if report_after "$before" '^STATE buffer=\*Calculator\* mode=CALC-MODE state=NORMAL windows=2 height=8 readonly=yes modified=no stack= precision=12 angle=deg$'; then
  pass calc-open 'M-x calc opened a compact read-only Normal-state RPN window'
else
  fail calc-open 'M-x calc window, mode, state, or initial stack differed'
fi

# Numeric entry is a non-Evil recursive prompt.  The physical keys mirror
# Evil-Collection Calc: a digit starts entry and Return commits it.
lem_keys "$session" 2
lem_wait_for "$session" 'Calc: 2' 10 >/dev/null
lem_keys "$session" Enter
lem_keys "$session" 3
lem_wait_for "$session" 'Calc: 3' 10 >/dev/null
lem_keys "$session" Enter
lem_keys "$session" +
before=$(state_count)
if report_after "$before" 'stack=5 precision=12 angle=deg$'; then
  pass rpn-arithmetic 'digit prompts and + reduced two stack entries to 5'
else
  fail rpn-arithmetic 'numeric entry or RPN addition differed'
fi

# Algebraic entry deliberately exercises qalc's useful units surface.
lem_keys "$session" "'"
lem_wait_for "$session" 'Algebraic:' 10 >/dev/null
tmux_cmd send-keys -t "$session" -l '2 m to cm'
lem_keys "$session" Enter
before=$(state_count)
if report_after "$before" 'stack=200 cm\|5 precision=12 angle=deg$'; then
  pass algebraic-units 'apostrophe entry evaluated a unit conversion above the RPN stack'
else
  fail algebraic-units 'algebraic entry or unit conversion differed'
fi

# The explicit Emacs customization makes Escape abort digit entry.  No qalc
# process or stack mutation should happen before the prompt returns.
lem_keys "$session" 9
lem_wait_for "$session" 'Calc: 9' 10 >/dev/null
tmux_cmd send-keys -t "$session" -l '99'
lem_keys "$session" Escape
sleep 0.4
before=$(state_count)
if report_after "$before" 'stack=200 cm\|5 precision=12 angle=deg$'; then
  pass entry-escape 'Escape aborted digit entry without mutating the stack'
else
  fail entry-escape 'aborted digit entry changed the calculator'
fi

lem_keys "$session" C-j
lem_keys "$session" Tab
before=$(state_count)
if report_after "$before" 'stack=200 cm\|5\|5 precision=12 angle=deg$'; then
  pass stack-motion 'C-j over and Tab roll-down used GNU Calc stack order'
else
  fail stack-motion 'over or roll-down stack order differed'
fi

lem_keys "$session" u
before=$(state_count)
if report_after "$before" 'stack=5\|200 cm\|5 precision=12 angle=deg$'; then
  lem_keys "$session" D
  before=$(state_count)
  if report_after "$before" 'stack=200 cm\|5\|5 precision=12 angle=deg$'; then
    pass undo-redo 'u and D traversed calculator operations independently of buffer undo'
  else
    fail undo-redo 'Calc redo did not restore the rolled stack'
  fi
else
  fail undo-redo 'Calc undo did not restore the pre-roll stack'
fi

# Change angle modes through the Evil-Collection m prefix and verify degree
# semantics through a real transcendental calculation.
lem_keys "$session" m d
lem_keys "$session" 3
lem_wait_for "$session" 'Calc: 3' 10 >/dev/null
tmux_cmd send-keys -t "$session" -l '0'
lem_keys "$session" Enter
lem_keys "$session" S
before=$(state_count)
if report_after "$before" 'stack=0\.5\|200 cm\|5\|5 precision=12 angle=deg$'; then
  pass angle-unary 'm d plus S evaluated sin(30 degrees) as 0.5'
else
  fail angle-unary 'degree mode or unary trigonometry differed'
fi

# Precision changes use the ordinary prompt editing map.  P then renders pi at
# the new precision, proving that the setting reaches the evaluator.
lem_keys "$session" C-p
lem_wait_for "$session" 'Calc precision:' 10 >/dev/null
lem_keys "$session" C-a C-k
tmux_cmd send-keys -t "$session" -l '20'
lem_keys "$session" Enter
lem_keys "$session" P
before=$(state_count)
if report_after "$before" 'stack=3\.1415926535897932385\|0\.5\|200 cm\|5\|5 precision=20 angle=deg$'; then
  pass precision-pi 'C-p changed qalc precision and P pushed pi'
else
  fail precision-pi 'precision prompt or pi rendering differed'
fi

lem_keys "$session" M-k
lem_keys "$session" Delete
lem_keys "$session" p p
before=$(state_count)
if report_after "$before" 'stack=3\.1415926535897932385\|0\.5\|200 cm\|5\|5 precision=20 angle=deg$'; then
  pass copy-yank 'M-k, Delete, and pp round-tripped the top through the kill ring'
else
  fail copy-yank 'Calc copy/yank did not restore the top entry'
fi

# A failed backend parse is transactional: it should show an editor error and
# retain the exact stack.
lem_keys "$session" "'"
lem_wait_for "$session" 'Algebraic:' 10 >/dev/null
tmux_cmd send-keys -t "$session" -l 'garbage ???'
lem_keys "$session" Enter
sleep 0.5
before=$(state_count)
if report_after "$before" 'stack=3\.1415926535897932385\|0\.5\|200 cm\|5\|5 precision=20 angle=deg$'; then
  pass failed-evaluation 'invalid algebraic input left the stack unchanged'
else
  fail failed-evaluation 'failed evaluation partially mutated the stack'
fi

before_origin=$(grep -c '^ORIGIN ' "$LEM_YATH_CALC_REPORT" 2>/dev/null || true)
lem_keys "$session" q
sleep 0.5
lem_keys "$session" F4
if wait_report '^ORIGIN buffer=calc-origin state=NORMAL windows=1 text=CALC ORIGIN$' 10 &&
   (( $(grep -c '^ORIGIN ' "$LEM_YATH_CALC_REPORT" 2>/dev/null || true) > before_origin )); then
  pass calc-quit 'q removed the Calc split and restored the exact origin buffer'
else
  fail calc-quit 'q did not restore the origin layout'
fi

open_calc
before=$(state_count)
if report_after "$before" 'stack=3\.1415926535897932385\|0\.5\|200 cm\|5\|5 precision=20 angle=deg$'; then
  pass session-reuse 'reopening Calc retained its stack and modes'
else
  fail session-reuse 'the reusable Calc session lost its state'
fi

lem_keys "$session" q

if ((failed)); then
  exit 1
fi

printf '\n%s\n' 'CALC TEST PASSED'
