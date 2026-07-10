#!/usr/bin/env bash
# Interactive-behavior tests for the lem-yath Lem port.
#
# Drives a real Lem TUI in tmux (200x50) via scripts/tui-driver.sh and asserts
# on captured screens. Each check prints PASS/FAIL; on FAIL the captured screen
# is dumped. The script exits nonzero if any check fails. All tmux sessions are
# killed on exit (trap), even on Ctrl-C / error.
#
# Session names are unique per invocation via LEM_YATH_CHECK_ID so it is safe to run
# concurrently with other testers and with the boot/compile checks.
#
# Usage:  LEM_YATH_CHECK_ID=itest ./scripts/interactive-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-itest-$$}"

# How long to wait for the (slow) first boot of Lem before giving up.
BOOT_TIMEOUT="${BOOT_TIMEOUT:-40}"
# Generic per-assertion wait.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
# Delay between discrete keystrokes that make up a chord, so the TUI's
# key-sequence reader sees them as separate keys (leader chords, gc + motion).
KEY_DELAY="${KEY_DELAY:-0.25}"

# ---------------------------------------------------------------------------
# Session bookkeeping + cleanup trap
# ---------------------------------------------------------------------------
SESSIONS=()
register_session() { SESSIONS+=("$1"); }
cleanup() {
  for s in "${SESSIONS[@]:-}"; do
    [ -n "$s" ] && tmux_cmd kill-session -t "$s" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
declare -A RESULT
FAILED=0

pass() { # pass <check-name> <message>
  RESULT["$1"]=PASS
  printf 'PASS  %-26s %s\n' "$1" "${2:-}"
}
fail() { # fail <check-name> <message> <session-for-screen-dump>
  RESULT["$1"]=FAIL
  FAILED=1
  printf 'FAIL  %-26s %s\n' "$1" "${2:-}"
  if [ -n "${3:-}" ]; then
    echo "----- screen ($3) -----"
    lem_capture "$3" 2>/dev/null || echo "(no screen)"
    echo "-----------------------"
  fi
}

# Boot a fresh Lem session opening FILE; returns once FILE's contents are on
# screen (or fails the named check and returns 1 on timeout).
boot_with_file() { # boot_with_file <session> <file> <wait-ere> <check-name>
  local s="$1" file="$2" ere="$3" check="$4"
  register_session "$s"
  lem_start_lem-yath "$s" "$file"
  if ! lem_wait_for "$s" "$ere" "$BOOT_TIMEOUT"; then
    fail "$check" "Lem never opened $file (waited ${BOOT_TIMEOUT}s)" "$s"
    return 1
  fi
  # Let the modeline / vi-mode settle.
  sleep 0.5
  return 0
}

# Send discrete keystrokes with a delay between each, so chords register.
send_chord() { # send_chord <session> <key1> <key2> ...
  local s="$1"; shift
  local k
  for k in "$@"; do
    tmux_cmd send-keys -t "$s" "$k"
    sleep "$KEY_DELAY"
  done
}

# Type a literal string in one shot (insert mode).
send_text() { # send_text <session> <string>
  tmux_cmd send-keys -t "$1" -l "$2"
}

# ===========================================================================
# Fixtures
# ===========================================================================
SCRATCH=/tmp/lem-yath-itest.txt
LISPFIX=/tmp/lem-yath-itest.lisp
PYFIX=/tmp/lem-yath-itest.py
SNIPEFIX=/tmp/lem-yath-itest-snipe.txt

printf 'first known line\nsecond known line\nthird known line\n' > "$SCRATCH"
printf '(defun alpha ())\n(defun beta ())\n(defun gamma ())\n' > "$LISPFIX"
printf 'def alpha():\n    pass\ndef beta():\n    pass\n' > "$PYFIX"
printf 'alpha beta gamma\n' > "$SNIPEFIX"

# ===========================================================================
# Check 1: Boot with a scratch file; vi NORMAL state shows in the modeline.
# ===========================================================================
S1="lem-yath-it1-$id"
if boot_with_file "$S1" "$SCRATCH" 'first known line' "01-boot-normal"; then
  if lem_wait_for "$S1" 'NORMAL[[:space:]].*lem-yath-itest\.txt' "$WAIT_TIMEOUT"; then
    pass "01-boot-normal" "modeline shows NORMAL + filename"
  elif lem_capture "$S1" | grep -qE 'NORMAL'; then
    # NORMAL present but maybe not on same modeline row as filename.
    pass "01-boot-normal" "modeline shows NORMAL (filename on screen)"
  else
    fail "01-boot-normal" "no NORMAL indicator in modeline" "$S1"
  fi
fi

# ===========================================================================
# Check 2: Insert-mode roundtrip. i, type, Escape, assert text on screen.
# ===========================================================================
# Reuse S1 (already on the scratch file, cursor at line 1 col 0).
if [ "${RESULT[01-boot-normal]:-}" = PASS ]; then
  MARKER="ZZINSERTEDZZ"
  tmux_cmd send-keys -t "$S1" "i"          # enter insert mode
  sleep "$KEY_DELAY"
  send_text "$S1" "$MARKER"
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$S1" Escape       # back to normal
  sleep "$KEY_DELAY"
  if lem_wait_for "$S1" "$MARKER" "$WAIT_TIMEOUT"; then
    pass "02-insert-roundtrip" "inserted text visible"
  else
    fail "02-insert-roundtrip" "inserted text not on screen" "$S1"
  fi
else
  fail "02-insert-roundtrip" "skipped: boot check failed" ""
fi

# ===========================================================================
# Check 3: Leader chord SPC c c -> Compile prompt ("Compile [").
# ===========================================================================
# Fresh session to start from a clean NORMAL state (no leftover insert text).
S3="lem-yath-it3-$id"
if boot_with_file "$S3" "$SCRATCH" 'first known line' "03-leader-compile"; then
  # Make sure we are in NORMAL (Escape is harmless if already normal).
  tmux_cmd send-keys -t "$S3" Escape
  sleep "$KEY_DELAY"
  send_chord "$S3" "Space" "c" "c"
  if lem_wait_for "$S3" 'Compile \[' "$WAIT_TIMEOUT"; then
    pass "03-leader-compile" "Compile prompt appeared"
    tmux_cmd send-keys -t "$S3" Escape       # cancel the prompt
    sleep "$KEY_DELAY"
  else
    fail "03-leader-compile" "no 'Compile [' prompt after SPC c c" "$S3"
  fi
fi

# ===========================================================================
# Check 4: gc operator. Our gc is an operator at "g c" awaiting a motion.
#   "g c j" should comment the current + next line (2 lines).
# Try the .lisp fixture (line comment ";;") first, then the .py fixture ("#").
# ===========================================================================
gc_check() { # gc_check <session> <file> <wait-ere> <expected-comment-ere> <label>
  local s="$1" file="$2" wait_ere="$3" cmt_ere="$4" label="$5"
  register_session "$s"
  lem_start_lem-yath "$s" "$file"
  if ! lem_wait_for "$s" "$wait_ere" "$BOOT_TIMEOUT"; then
    echo "  (gc/$label) file never opened" >&2
    return 2
  fi
  sleep 0.5
  tmux_cmd send-keys -t "$s" Escape          # ensure NORMAL
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$s" "g"             # move cursor to top with gg
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$s" "g"
  sleep "$KEY_DELAY"
  send_chord "$s" "g" "c" "j"            # gc + j motion = comment 2 lines
  sleep 0.6
  if lem_capture "$s" | grep -qE "$cmt_ere"; then
    return 0
  fi
  return 1
}

S4L="lem-yath-it4l-$id"
S4P="lem-yath-it4p-$id"
gc_lisp_rc=2
gc_py_rc=2

gc_check "$S4L" "$LISPFIX" '\(defun alpha' ';; ?\(defun (alpha|beta)' "lisp"
gc_lisp_rc=$?

if [ "$gc_lisp_rc" = 0 ]; then
  pass "04-gc-operator" "lisp: ';;' prefixes appeared after 'g c j'"
else
  # Try Python fixture with '#'.
  gc_check "$S4P" "$PYFIX" 'def alpha' '# ?def (alpha|beta)' "py"
  gc_py_rc=$?
  if [ "$gc_py_rc" = 0 ]; then
    pass "04-gc-operator" "py: '#' prefixes appeared after 'g c j'"
  else
    # Capture both screens for the bug report.
    fail "04-gc-operator" "no comment prefixes after 'g c j' (lisp rc=$gc_lisp_rc py rc=$gc_py_rc)" "$S4L"
    echo "----- screen (py fixture $S4P) -----"
    lem_capture "$S4P" 2>/dev/null || echo "(no screen)"
    echo "------------------------------------"
  fi
fi

# ===========================================================================
# Check 5: Snipe. File "alpha beta gamma"; from line start, s b e jumps to
#   "beta". We can't read cursor pos from the capture, so we land an "X" via
#   insert and assert it sits immediately before "beta" -> "alpha Xbeta gamma".
# ===========================================================================
S5="lem-yath-it5-$id"
if boot_with_file "$S5" "$SNIPEFIX" 'alpha beta gamma' "05-snipe"; then
  tmux_cmd send-keys -t "$S5" Escape
  sleep "$KEY_DELAY"
  # Move to absolute line start: gg then 0.
  send_chord "$S5" "g" "g"
  tmux_cmd send-keys -t "$S5" "0"
  sleep "$KEY_DELAY"
  # Snipe forward to "be".
  send_chord "$S5" "s" "b" "e"
  sleep "$KEY_DELAY"
  # Insert an X at the landing point and leave insert mode.
  tmux_cmd send-keys -t "$S5" "i"
  sleep "$KEY_DELAY"
  send_text "$S5" "X"
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$S5" Escape
  sleep "$KEY_DELAY"
  if lem_wait_for "$S5" 'alpha Xbeta gamma' "$WAIT_TIMEOUT"; then
    pass "05-snipe" "cursor landed before 'beta' (alpha Xbeta gamma)"
  else
    fail "05-snipe" "X did not land before 'beta'" "$S5"
  fi
fi

# ===========================================================================
# Check 6: SPC f f opens the find-file prompt ("Find File: "), then Escape.
# ===========================================================================
S6="lem-yath-it6-$id"
if boot_with_file "$S6" "$SCRATCH" 'first known line' "06-find-file"; then
  tmux_cmd send-keys -t "$S6" Escape
  sleep "$KEY_DELAY"
  send_chord "$S6" "Space" "f" "f"
  if lem_wait_for "$S6" 'Find File:' "$WAIT_TIMEOUT"; then
    pass "06-find-file" "Find File prompt appeared"
    tmux_cmd send-keys -t "$S6" Escape
    sleep "$KEY_DELAY"
  else
    fail "06-find-file" "no 'Find File:' prompt after SPC f f" "$S6"
  fi
fi

# ===========================================================================
# Check 7: M-x orderless. Send M-x, type "roam find", assert completion popup
#   shows "lem-yath-roam-find".
# ===========================================================================
S7="lem-yath-it7-$id"
if boot_with_file "$S7" "$SCRATCH" 'first known line' "07-mx-orderless"; then
  tmux_cmd send-keys -t "$S7" Escape
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$S7" M-x
  if lem_wait_for "$S7" 'Command:' "$WAIT_TIMEOUT"; then
    sleep "$KEY_DELAY"
    send_text "$S7" "roam find"
    sleep 0.8
    if lem_wait_for "$S7" 'lem-yath-roam-find' "$WAIT_TIMEOUT"; then
      pass "07-mx-orderless" "'roam find' matched lem-yath-roam-find"
    else
      fail "07-mx-orderless" "lem-yath-roam-find not in completion popup" "$S7"
    fi
    tmux_cmd send-keys -t "$S7" Escape
    sleep "$KEY_DELAY"
  else
    fail "07-mx-orderless" "M-x did not open a Command prompt" "$S7"
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "================ SUMMARY ================"
order=(01-boot-normal 02-insert-roundtrip 03-leader-compile 04-gc-operator \
       05-snipe 06-find-file 07-mx-orderless)
for k in "${order[@]}"; do
  printf '  %-26s %s\n' "$k" "${RESULT[$k]:-MISSING}"
done
echo "========================================"

if [ "$FAILED" = 0 ]; then
  echo "INTERACTIVE TEST PASSED"
  exit 0
else
  echo "INTERACTIVE TEST FAILED"
  exit 1
fi
