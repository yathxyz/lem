#!/usr/bin/env bash
# Interactive-behavior tests for the lem-yath Lem port.
#
# Drives a real Lem TUI in tmux (200x50) via scripts/tui-driver.sh and asserts
# on captured screens. Each check prints PASS/FAIL; on FAIL the captured screen
# is dumped. The script exits nonzero if any check fails. All tmux sessions are
# killed on exit (trap), even on Ctrl-C / error.
#
# Session names and fixture directories are unique per invocation, so it is safe
# to run concurrently with other testers and with the boot/compile checks.
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
MAX_LIVE_SESSIONS="${MAX_LIVE_SESSIONS:-12}"
register_session() {
  local oldest
  while (( ${#SESSIONS[@]} >= MAX_LIVE_SESSIONS )); do
    oldest="${SESSIONS[0]}"
    tmux_cmd kill-session -t "$oldest" 2>/dev/null || true
    SESSIONS=("${SESSIONS[@]:1}")
  done
  SESSIONS+=("$1")
}
cleanup() {
  for s in "${SESSIONS[@]:-}"; do
    [ -n "$s" ] && tmux_cmd kill-session -t "$s" 2>/dev/null
  done
  [ -n "${FIXTURE_DIR:-}" ] && rm -rf -- "$FIXTURE_DIR"
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

# Wait until a screen pattern occurs at least EXPECTED times.  This is used
# for linewise paste checks where one grep match is already present before the
# command and a fixed sleep would race the editor's input queue.
lem_wait_for_count() { # lem_wait_for_count <session> <ere> <expected> [timeout]
  local s="$1" pat="$2" expected="$3" timeout="${4:-10}" i=0 count
  while (( i < timeout * 4 )); do
    count="$(lem_capture "$s" | grep -cE "$pat")"
    if (( count >= expected )); then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

# ===========================================================================
# Fixtures
# ===========================================================================
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-itest.XXXXXX")"
SCRATCH="$FIXTURE_DIR/lem-yath-itest.txt"
LISPFIX="$FIXTURE_DIR/lem-yath-itest.lisp"
PYFIX="$FIXTURE_DIR/lem-yath-itest.py"
SNIPEFIX="$FIXTURE_DIR/lem-yath-itest-snipe.txt"
SNIPEREPEATFIX="$FIXTURE_DIR/lem-yath-itest-snipe-repeat.txt"
INDENTFIX="$FIXTURE_DIR/lem-yath-itest-indent.txt"
FILLFIX="$FIXTURE_DIR/lem-yath-itest-fill.txt"
ORGFIX="$FIXTURE_DIR/lem-yath-itest.org"
EXPANDFIX="$FIXTURE_DIR/lem-yath-itest-expand.txt"
CONTROLFIX="$FIXTURE_DIR/lem-yath-itest-control.txt"
SHIFTFIX="$FIXTURE_DIR/lem-yath-itest-shift.txt"
QUOTEFIX="$FIXTURE_DIR/lem-yath-itest-quote.txt"
ORGCONTROLFIX="$FIXTURE_DIR/lem-yath-itest-control.org"
COPYCONTROLFIX="$FIXTURE_DIR/lem-yath-itest-copy-control.txt"
ONENORMALFIX="$FIXTURE_DIR/lem-yath-itest-one-normal.txt"
ONENORMALPROMPTFIX="$FIXTURE_DIR/lem-yath-itest-one-normal-prompt.txt"
ORGRIGHTFIX="$FIXTURE_DIR/lem-yath-itest-right-control.org"
LASTINSERTFIX="$FIXTURE_DIR/lem-yath-itest-last-insert.txt"
CHARREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-char-register.txt"
LINEREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-line-register.txt"
NAMEDREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-named-register.txt"
APPENDREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-append-register.txt"
BLACKHOLEREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-blackhole-register.txt"
VISUALREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-visual-register.txt"
LINENAMEDREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-line-named-register.txt"
REPEATREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-repeat-register.txt"
READONLYREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-readonly-register.txt"
DELETEREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-delete-register.txt"
DOTREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-dot-register.txt"
DIGRAPHFIX="$FIXTURE_DIR/lem-yath-itest-digraph.txt"
REPLACEDIGRAPHFIX="$FIXTURE_DIR/lem-yath-itest-replace-digraph.txt"
SPECIALREGISTERAFIX="$FIXTURE_DIR/lem-yath-itest-special-register-a.txt"
SPECIALREGISTERBFIX="$FIXTURE_DIR/lem-yath-itest-special-register-b.txt"
EXPRESSIONREGISTERFIX="$FIXTURE_DIR/lem-yath-itest-expression-register.txt"

printf 'first known line\nsecond known line\nthird known line\n' > "$SCRATCH"
printf '(defun alpha ())\n(defun beta ())\n(defun gamma ())\n' > "$LISPFIX"
printf 'def alpha():\n    pass\ndef beta():\n    pass\n' > "$PYFIX"
printf 'alpha beta gamma\n' > "$SNIPEFIX"
printf 'ab xx ab yy ab\n' > "$SNIPEREPEATFIX"
printf '    alpha beta\n' > "$INDENTFIX"
printf 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega\n' > "$FILLFIX"
printf '* Heading\nBody\n' > "$ORGFIX"
printf 'one two (alpha beta) three\n\nnext\n' > "$EXPANDFIX"
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "$CONTROLFIX"
printf '        alpha\n    beta\n' > "$SHIFTFIX"
printf 'quote\n' > "$QUOTEFIX"
printf '** Child\n' > "$ORGCONTROLFIX"
printf 'ABOVE\n\nxx\n\nBELOW\n' > "$COPYCONTROLFIX"
printf 'abc def\n' > "$ONENORMALFIX"
printf 'abc def\n' > "$ONENORMALPROMPTFIX"
printf '* Child\n' > "$ORGRIGHTFIX"
printf 'base\n\n' > "$LASTINSERTFIX"
printf 'TOKEN\nhere\n' > "$CHARREGISTERFIX"
printf 'TOKEN\nhere\n' > "$LINEREGISTERFIX"
printf 'ZERO\ncat dog\nsink\n' > "$NAMEDREGISTERFIX"
printf 'red blue green\nsink\n' > "$APPENDREGISTERFIX"
printf 'HISTORY\nKEEP\ntrash here\nsink\n' > "$BLACKHOLEREGISTERFIX"
printf 'alpha beta\nsink\n' > "$VISUALREGISTERFIX"
printf 'LINE\nsink\n' > "$LINENAMEDREGISTERFIX"
printf 'cat\njunk\nsink\n' > "$REPEATREGISTERFIX"
printf 'keep text\n' > "$READONLYREGISTERFIX"
printf 'one two\nsink\n' > "$DELETEREGISTERFIX"
printf 'base\nsink\n' > "$DOTREGISTERFIX"
printf 'base\n' > "$DIGRAPHFIX"
printf 'ABCDE\n' > "$REPLACEDIGRAPHFIX"
printf 'alternate source\n' > "$SPECIALREGISTERAFIX"
printf 'current=\nalternate=\ncommand=\nword other word other word\nslash=\n' \
  > "$SPECIALREGISTERBFIX"
printf 'base\n' > "$EXPRESSIONREGISTERFIX"

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
# Check 4: gc operator. In normal state, "g c j" should comment the current
# and next line. In visual-line state, "V j g c" should comment the selection.
# Exercise both forms in Lisp (line comment ";;") and Python ("#").
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
  if ! lem_capture "$s" | grep -qE "$cmt_ere"; then
    return 1
  fi

  tmux_cmd send-keys -t "$s" "u"             # restore fixture
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$s" "g"
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$s" "g"
  sleep "$KEY_DELAY"
  send_chord "$s" "V" "j" "g" "c"          # comment visual line selection
  sleep 0.6
  lem_capture "$s" | grep -qE "$cmt_ere"
}

S4L="lem-yath-it4l-$id"
S4P="lem-yath-it4p-$id"
gc_lisp_rc=2
gc_py_rc=2

gc_check "$S4L" "$LISPFIX" '\(defun alpha' ';+[[:space:]]+\(defun (alpha|beta)' "lisp"
gc_lisp_rc=$?

gc_check "$S4P" "$PYFIX" 'def alpha' '# ?def (alpha|beta)' "py"
gc_py_rc=$?

if [ "$gc_lisp_rc" = 0 ] && [ "$gc_py_rc" = 0 ]; then
  pass "04-gc-operator" "normal and visual gc worked in Lisp and Python"
else
  fail "04-gc-operator" "missing comment prefixes (lisp rc=$gc_lisp_rc py rc=$gc_py_rc)" "$S4L"
  echo "----- screen (py fixture $S4P) -----"
  lem_capture "$S4P" 2>/dev/null || echo "(no screen)"
  echo "------------------------------------"
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
# Check 7: M-x Prescient. Send M-x, type "roam find", assert completion popup
#   shows "lem-yath-roam-find".
# ===========================================================================
S7="lem-yath-it7-$id"
if boot_with_file "$S7" "$SCRATCH" 'first known line' "07-mx-prescient"; then
  tmux_cmd send-keys -t "$S7" Escape
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$S7" M-x
  if lem_wait_for "$S7" 'Command:' "$WAIT_TIMEOUT"; then
    sleep "$KEY_DELAY"
    send_text "$S7" "roam find"
    sleep 0.8
    if lem_wait_for "$S7" 'lem-yath-roam-find' "$WAIT_TIMEOUT"; then
      pass "07-mx-prescient" "'roam find' matched lem-yath-roam-find"
    else
      fail "07-mx-prescient" "lem-yath-roam-find not in completion popup" "$S7"
    fi
    tmux_cmd send-keys -t "$S7" Escape
    sleep "$KEY_DELAY"
  else
    fail "07-mx-prescient" "M-x did not open a Command prompt" "$S7"
  fi
fi

# ===========================================================================
# Check 8: Native delete operator remains intact alongside evil-surround.
#   "dw" at the start of "alpha beta gamma" must leave "beta gamma".
# ===========================================================================
S8="lem-yath-it8-$id"
if boot_with_file "$S8" "$SNIPEFIX" 'alpha beta gamma' "08-native-delete"; then
  send_chord "$S8" "d" "w"
  if lem_wait_for "$S8" '^[[:space:][:digit:]]*beta gamma[[:space:]]*$' "$WAIT_TIMEOUT"; then
    pass "08-native-delete" "dw deleted the first word"
  else
    fail "08-native-delete" "dw did not produce 'beta gamma'" "$S8"
  fi
fi

# ===========================================================================
# Check 9: Native change operator remains intact alongside evil-surround.
#   "cw", replacement text, Escape must replace the first word and return to
#   NORMAL.
# ===========================================================================
S9="lem-yath-it9-$id"
if boot_with_file "$S9" "$SNIPEFIX" 'alpha beta gamma' "09-native-change"; then
  send_chord "$S9" "c" "w"
  send_text "$S9" "delta"
  tmux_cmd send-keys -t "$S9" Escape
  if lem_wait_for "$S9" '^[[:space:][:digit:]]*delta beta gamma[[:space:]]*$' "$WAIT_TIMEOUT" && \
     lem_wait_for "$S9" 'NORMAL' "$WAIT_TIMEOUT"; then
    pass "09-native-change" "cw replaced the first word and returned to NORMAL"
  else
    fail "09-native-change" "cw replacement or NORMAL state was wrong" "$S9"
  fi
fi

# ===========================================================================
# Check 9b: C-w in insert state uses Vim word boundaries through the configured
#   non-structural dispatcher. From the end of the line it removes "gamma",
#   not merely its final character.
# ===========================================================================
S9W="lem-yath-it9w-$id"
if boot_with_file "$S9W" "$SNIPEFIX" 'alpha beta gamma' "09-insert-C-w"; then
  tmux_cmd send-keys -t "$S9W" A C-w Escape
  if lem_wait_for "$S9W" '^[[:space:][:digit:]]*alpha beta[[:space:]]*$' "$WAIT_TIMEOUT" && \
     lem_wait_for "$S9W" 'NORMAL' "$WAIT_TIMEOUT"; then
    pass "09-insert-C-w" "insert C-w deleted the complete preceding word"
  else
    fail "09-insert-C-w" "insert C-w did not produce 'alpha beta '" "$S9W"
  fi
fi

# ===========================================================================
# Check 10: evil-surround standard keys. Cover ys/ds/cs plus the padded `(`
#   variant used by evil-surround.
# ===========================================================================
S10Q="lem-yath-it10q-$id"
S10C="lem-yath-it10c-$id"
S10P="lem-yath-it10p-$id"
surround_quote_ok=0
surround_change_ok=0
surround_padding_ok=0
if boot_with_file "$S10Q" "$SNIPEFIX" 'alpha beta gamma' "10-evil-surround"; then
  send_chord "$S10Q" "y" "s" "i" "w" '"'
  if lem_wait_for "$S10Q" '^[[:space:][:digit:]]*"alpha" beta gamma[[:space:]]*$' "$WAIT_TIMEOUT"; then
    send_chord "$S10Q" "d" "s" '"'
    lem_capture "$S10Q" | grep -qE '^[[:space:][:digit:]]*alpha beta gamma[[:space:]]*$' && surround_quote_ok=1
  fi
fi
if boot_with_file "$S10C" "$SNIPEFIX" 'alpha beta gamma' "10-evil-surround"; then
  send_chord "$S10C" "y" "s" "i" "w" '"'
  send_chord "$S10C" "c" "s" '"' "'"
  lem_capture "$S10C" | grep -qE "^[[:space:][:digit:]]*'alpha' beta gamma[[:space:]]*$" && surround_change_ok=1
fi
if boot_with_file "$S10P" "$SNIPEFIX" 'alpha beta gamma' "10-evil-surround"; then
  send_chord "$S10P" "y" "s" "i" "w" "("
  if lem_wait_for "$S10P" '^[[:space:][:digit:]]*\( alpha \) beta gamma[[:space:]]*$' "$WAIT_TIMEOUT"; then
    send_chord "$S10P" "d" "s" "("
    lem_capture "$S10P" | grep -qE '^[[:space:][:digit:]]*alpha beta gamma[[:space:]]*$' && surround_padding_ok=1
  fi
fi
if [ "$surround_quote_ok" = 1 ] && [ "$surround_change_ok" = 1 ] && \
   [ "$surround_padding_ok" = 1 ]; then
  pass "10-evil-surround" "ys, ds, cs, and padded delimiters matched evil-surround"
else
  fail "10-evil-surround" "ys, ds, cs, or padded delimiters diverged" "$S10Q"
  echo "----- screen (change $S10C) -----"
  lem_capture "$S10C" 2>/dev/null || echo "(no screen)"
  echo "----- screen (padding $S10P) -----"
  lem_capture "$S10P" 2>/dev/null || echo "(no screen)"
  echo "------------------------------------"
fi

# ===========================================================================
# Check 11: The Emacs leader map applies in visual state too. Enter visual
#   state, then SPC f f must open the same find-file prompt as normal state.
# ===========================================================================
S11="lem-yath-it11-$id"
if boot_with_file "$S11" "$SCRATCH" 'first known line' "11-visual-leader"; then
  tmux_cmd send-keys -t "$S11" "v"
  sleep "$KEY_DELAY"
  send_chord "$S11" "Space" "f" "f"
  if lem_wait_for "$S11" 'Find File:' "$WAIT_TIMEOUT"; then
    pass "11-visual-leader" "SPC f f opened find-file from visual state"
    tmux_cmd send-keys -t "$S11" Escape
  else
    fail "11-visual-leader" "visual-state SPC f f did not open find-file" "$S11"
  fi
fi

# ===========================================================================
# Check 12: Visual d/c must execute immediately even though normal-state d/c
#   dispatch evil-surround when followed by s.
# ===========================================================================
S12D="lem-yath-it12d-$id"
S12C="lem-yath-it12c-$id"
visual_delete_ok=0
visual_change_ok=0
if boot_with_file "$S12D" "$SNIPEFIX" 'alpha beta gamma' "12-visual-operators"; then
  send_chord "$S12D" "v" "l" "d"
  if lem_wait_for "$S12D" '^[[:space:][:digit:]]*pha beta gamma[[:space:]]*$' "$WAIT_TIMEOUT"; then
    visual_delete_ok=1
  fi
fi
if boot_with_file "$S12C" "$SNIPEFIX" 'alpha beta gamma' "12-visual-operators"; then
  send_chord "$S12C" "v" "l" "c"
  send_text "$S12C" "XY"
  tmux_cmd send-keys -t "$S12C" Escape
  if lem_wait_for "$S12C" '^[[:space:][:digit:]]*XYpha beta gamma[[:space:]]*$' "$WAIT_TIMEOUT" && \
     lem_wait_for "$S12C" 'NORMAL' "$WAIT_TIMEOUT"; then
    visual_change_ok=1
  fi
fi
if [ "$visual_delete_ok" = 1 ] && [ "$visual_change_ok" = 1 ]; then
  pass "12-visual-operators" "visual d and c executed without waiting for motions"
else
  fail "12-visual-operators" "visual d or c did not execute immediately" "$S12D"
  echo "----- screen (visual change $S12C) -----"
  lem_capture "$S12C" 2>/dev/null || echo "(no screen)"
  echo "----------------------------------------"
fi

# ===========================================================================
# Check 13: Doubled line operators must retain Vim semantics through the
#   evil-surround dispatch layer: dd, cc, and yyp.
# ===========================================================================
S13D="lem-yath-it13d-$id"
S13C="lem-yath-it13c-$id"
S13Y="lem-yath-it13y-$id"
double_delete_ok=0
double_change_ok=0
double_yank_ok=0
if boot_with_file "$S13D" "$SCRATCH" 'first known line' "13-doubled-operators"; then
  send_chord "$S13D" "d" "d"
  lem_wait_for "$S13D" '^[[:space:][:digit:]]*second known line[[:space:]]*$' "$WAIT_TIMEOUT" && double_delete_ok=1
fi
if boot_with_file "$S13C" "$SCRATCH" 'first known line' "13-doubled-operators"; then
  send_chord "$S13C" "c" "c"
  send_text "$S13C" "replacement"
  tmux_cmd send-keys -t "$S13C" Escape
  lem_wait_for "$S13C" '^[[:space:][:digit:]]*replacement[[:space:]]*$' "$WAIT_TIMEOUT" && double_change_ok=1
fi
if boot_with_file "$S13Y" "$SCRATCH" 'first known line' "13-doubled-operators"; then
  send_chord "$S13Y" "y" "y" "p"
  if lem_wait_for_count "$S13Y" 'first known line' 2 "$WAIT_TIMEOUT"; then
    double_yank_ok=1
  fi
fi
if [ "$double_delete_ok" = 1 ] && [ "$double_change_ok" = 1 ] && \
   [ "$double_yank_ok" = 1 ]; then
  pass "13-doubled-operators" "dd, cc, and yyp retained linewise behavior"
else
  fail "13-doubled-operators" "dd, cc, or yyp lost linewise behavior" "$S13D"
  echo "----- screen (cc $S13C) -----"
  lem_capture "$S13C" 2>/dev/null || echo "(no screen)"
  echo "----- screen (yyp $S13Y) -----"
  lem_capture "$S13Y" 2>/dev/null || echo "(no screen)"
  echo "--------------------------------"
fi

# ===========================================================================
# Check 14: Counts and dot-repeat survive operator dispatch. Both 2dw and dw.
#   must reduce "alpha beta gamma" to "gamma".
# ===========================================================================
S14C="lem-yath-it14c-$id"
S14R="lem-yath-it14r-$id"
count_ok=0
repeat_ok=0
if boot_with_file "$S14C" "$SNIPEFIX" 'alpha beta gamma' "14-count-repeat"; then
  send_chord "$S14C" "2" "d" "w"
  lem_wait_for "$S14C" '^[[:space:][:digit:]]*gamma[[:space:]]*$' "$WAIT_TIMEOUT" && count_ok=1
fi
if boot_with_file "$S14R" "$SNIPEFIX" 'alpha beta gamma' "14-count-repeat"; then
  send_chord "$S14R" "d" "w" "."
  lem_wait_for "$S14R" '^[[:space:][:digit:]]*gamma[[:space:]]*$' "$WAIT_TIMEOUT" && repeat_ok=1
fi
if [ "$count_ok" = 1 ] && [ "$repeat_ok" = 1 ]; then
  pass "14-count-repeat" "2dw and dw. both produced gamma"
else
  fail "14-count-repeat" "operator count or dot-repeat failed" "$S14C"
  echo "----- screen (repeat $S14R) -----"
  lem_capture "$S14R" 2>/dev/null || echo "(no screen)"
  echo "----------------------------------"
fi

# ===========================================================================
# Check 15: evil-snipe repeat and operator bindings. A second s repeats the
#   successful two-character search; operator z is the inclusive snipe motion.
# ===========================================================================
S15R="lem-yath-it15r-$id"
S15O="lem-yath-it15o-$id"
snipe_repeat_ok=0
snipe_operator_ok=0
if boot_with_file "$S15R" "$SNIPEREPEATFIX" 'ab xx ab yy ab' "15-snipe-parity"; then
  send_chord "$S15R" "s" "a" "b" "s"
  tmux_cmd send-keys -t "$S15R" "i"
  sleep "$KEY_DELAY"
  send_text "$S15R" "X"
  tmux_cmd send-keys -t "$S15R" Escape
  sleep "$KEY_DELAY"
  lem_wait_for "$S15R" \
    '^[[:space:][:digit:]]*ab xx ab yy Xab[[:space:]]*$' \
    "$WAIT_TIMEOUT" && snipe_repeat_ok=1
fi
if boot_with_file "$S15O" "$SNIPEFIX" 'alpha beta gamma' "15-snipe-parity"; then
  send_chord "$S15O" "d" "z" "b" "e"
  lem_wait_for "$S15O" \
    '^[[:space:][:digit:]]*ta gamma[[:space:]]*$' \
    "$WAIT_TIMEOUT" && snipe_operator_ok=1
fi
if [ "$snipe_repeat_ok" = 1 ] && [ "$snipe_operator_ok" = 1 ]; then
  pass "15-snipe-parity" "s repeat and inclusive operator z matched evil-snipe"
else
  fail "15-snipe-parity" "s repeat or operator z diverged" "$S15R"
  echo "----- screen (operator $S15O) -----"
  lem_capture "$S15O" 2>/dev/null || echo "(no screen)"
  echo "------------------------------------"
fi

# ===========================================================================
# Check 16: evil-want-C-u-delete. In insert state C-u deletes text back to
#   indentation, not the indentation itself.
# ===========================================================================
S16="lem-yath-it16-$id"
if boot_with_file "$S16" "$INDENTFIX" 'alpha beta' "16-insert-C-u"; then
  tmux_cmd send-keys -t "$S16" "A"
  sleep "$KEY_DELAY"
  send_text "$S16" " extra"
  tmux_cmd send-keys -t "$S16" "C-u"
  sleep "$KEY_DELAY"
  send_text "$S16" "omega"
  tmux_cmd send-keys -t "$S16" Escape
  if lem_wait_for "$S16" '^[[:space:][:digit:]]{0,8}    omega[[:space:]]*$' "$WAIT_TIMEOUT" && \
     lem_wait_for "$S16" 'NORMAL' "$WAIT_TIMEOUT"; then
    pass "16-insert-C-u" "C-u deleted back to indentation"
  else
    fail "16-insert-C-u" "insert-state C-u did not preserve indentation" "$S16"
  fi
fi

# ===========================================================================
# Check 17: SPC y w fills a paragraph to the configured column.
# ===========================================================================
S17="lem-yath-it17-$id"
if boot_with_file "$S17" "$FILLFIX" 'alpha beta gamma' "17-fill-paragraph"; then
  send_chord "$S17" "Space" "y" "w"
  sleep 0.6
  fill_screen="$(lem_capture "$S17")"
  if grep -Fqx \
       'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu' \
       <<<"$fill_screen" && \
     grep -Fqx \
       'xi omicron pi rho sigma tau upsilon phi chi psi omega' \
       <<<"$fill_screen"; then
    pass "17-fill-paragraph" "SPC y w matched Emacs fill-column 70 exactly"
  else
    fail "17-fill-paragraph" "SPC y w did not match Emacs fill-column 70" "$S17"
  fi
fi

# ===========================================================================
# Check 18: SPC m I creates a valid Org ID property drawer at the current
#   heading.
# ===========================================================================
S18="lem-yath-it18-$id"
if boot_with_file "$S18" "$ORGFIX" 'Heading' "18-org-id"; then
  send_chord "$S18" "Space" "m" "I"
  org_id=""
  if lem_wait_for "$S18" \
       'Created Org ID: [0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}' \
       "$WAIT_TIMEOUT"; then
    org_id="$(lem_capture "$S18" | grep -oEi \
      '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' | head -n 1)"
  fi
  # Org may conceal a freshly inserted property drawer.  Exercise the normal
  # global visibility cycle through overview, contents, and all before reading
  # it from the TUI.
  send_chord "$S18" "BTab" "BTab" "BTab"
  org_screen=""
  if [ -n "$org_id" ] && \
     lem_wait_for "$S18" ':PROPERTIES:' "$WAIT_TIMEOUT"; then
    org_screen="$(lem_capture "$S18")"
  fi
  if echo "$org_screen" | grep -q ':PROPERTIES:' && \
     echo "$org_screen" | grep -qiF ":ID: $org_id" && \
     echo "$org_screen" | grep -q ':END:'; then
    pass "18-org-id" "SPC m I created a UUID property"
  else
    fail "18-org-id" "SPC m I did not create a valid property drawer" "$S18"
  fi
fi

# ===========================================================================
# Check 19: SPC y a enables buffer-local auto fill and typing beyond the fill
#   column wraps the paragraph.
# ===========================================================================
S19="lem-yath-it19-$id"
if boot_with_file "$S19" "$FILLFIX" 'alpha beta gamma' "19-auto-fill-toggle"; then
  send_chord "$S19" "Space" "y" "a"
  tmux_cmd send-keys -t "$S19" "A"
  sleep "$KEY_DELAY"
  send_text "$S19" " tail "
  tmux_cmd send-keys -t "$S19" Escape
  if lem_wait_for "$S19" 'tail' "$WAIT_TIMEOUT"; then
    auto_fill_screen="$(lem_capture "$S19")"
  else
    auto_fill_screen=""
  fi
  if echo "$auto_fill_screen" | grep -q 'alpha beta gamma' && \
     echo "$auto_fill_screen" | grep -q 'tail' && \
     ! echo "$auto_fill_screen" | grep -qE 'alpha.*tail'; then
    pass "19-auto-fill-toggle" "SPC y a enabled functional auto fill"
  else
    fail "19-auto-fill-toggle" "SPC y a did not wrap inserted text" "$S19"
  fi
fi

# ===========================================================================
# Check 20: Match the live Emacs state split: Normal C-n/C-p retain Evil
#   paste cycling, while Insert, Visual, and Emacs states use logical lines.
# ===========================================================================
S20N="lem-yath-it20n-$id"
S20I="lem-yath-it20i-$id"
S20V="lem-yath-it20v-$id"
S20E="lem-yath-it20e-$id"
normal_pop_ok=0
insert_motion_ok=0
visual_motion_ok=0
emacs_motion_ok=0
if boot_with_file "$S20N" "$SCRATCH" 'first known line' "20-control-state-split"; then
  send_chord "$S20N" "y" "y" "j" "y" "y" "j" "p"
  if lem_wait_for_count "$S20N" \
       '^[[:space:][:digit:]]*second known line[[:space:]]*$' 2 \
       "$WAIT_TIMEOUT"; then
    tmux_cmd send-keys -t "$S20N" "C-p"
    if lem_wait_for_count "$S20N" \
         '^[[:space:][:digit:]]*first known line[[:space:]]*$' 2 \
         "$WAIT_TIMEOUT"; then
      normal_screen="$(lem_capture "$S20N")"
      if [ "$(grep -cE '^[[:space:][:digit:]]*second known line[[:space:]]*$' \
               <<<"$normal_screen")" = 1 ]; then
        tmux_cmd send-keys -t "$S20N" "C-n"
        if lem_wait_for_count "$S20N" \
             '^[[:space:][:digit:]]*second known line[[:space:]]*$' 2 \
             "$WAIT_TIMEOUT"; then
          normal_screen="$(lem_capture "$S20N")"
          if [ "$(grep -cE '^[[:space:][:digit:]]*first known line[[:space:]]*$' \
                   <<<"$normal_screen")" = 1 ]; then
            normal_pop_ok=1
          fi
        fi
      fi
    fi
  fi
fi
if boot_with_file "$S20I" "$SCRATCH" 'first known line' "20-control-state-split"; then
  send_chord "$S20I" "i" "C-n"
  send_text "$S20I" "X"
  if lem_wait_for "$S20I" 'Xsecond known line' "$WAIT_TIMEOUT"; then
    send_chord "$S20I" "Left" "C-p"
    send_text "$S20I" "Y"
    tmux_cmd send-keys -t "$S20I" Escape
    lem_wait_for "$S20I" 'Yfirst known line' "$WAIT_TIMEOUT" && \
      insert_motion_ok=1
  fi
fi
if boot_with_file "$S20V" "$SCRATCH" 'first known line' "20-control-state-split"; then
  send_chord "$S20V" "v" "C-n" "Escape" "i"
  send_text "$S20V" "X"
  tmux_cmd send-keys -t "$S20V" Escape
  if lem_wait_for "$S20V" 'Xsecond known line' "$WAIT_TIMEOUT"; then
    send_chord "$S20V" "v" "C-p" "Escape" "i"
    send_text "$S20V" "Y"
    tmux_cmd send-keys -t "$S20V" Escape
    lem_wait_for "$S20V" 'Yfirst known line' "$WAIT_TIMEOUT" && \
      visual_motion_ok=1
  fi
fi
if boot_with_file "$S20E" "$SCRATCH" 'first known line' "20-control-state-split"; then
  send_chord "$S20E" "C-z" "C-n"
  send_text "$S20E" "X"
  if lem_wait_for "$S20E" 'Xsecond known line' "$WAIT_TIMEOUT"; then
    send_chord "$S20E" "Left" "C-p"
    send_text "$S20E" "Y"
    lem_wait_for "$S20E" 'Yfirst known line' "$WAIT_TIMEOUT" && \
      emacs_motion_ok=1
  fi
fi
if [ "$normal_pop_ok" = 1 ] && [ "$insert_motion_ok" = 1 ] && \
   [ "$visual_motion_ok" = 1 ] && [ "$emacs_motion_ok" = 1 ]; then
  pass "20-control-state-split" \
    "Normal paste cycling and Insert/Visual/Emacs line motion match Evil"
else
  fail "20-control-state-split" \
    "C-n/C-p state split mismatch (normal=$normal_pop_ok insert=$insert_motion_ok visual=$visual_motion_ok emacs=$emacs_motion_ok)" \
    "$S20N"
fi

# ===========================================================================
# Check 21: Repeated SPC v expands through word, delimiter interior, and the
#   enclosing pair. Visual S then exposes the exact selected range.
# ===========================================================================
S21="lem-yath-it21-$id"
if boot_with_file "$S21" "$EXPANDFIX" 'one two.*alpha beta.*three' "21-expand-region"; then
  send_chord "$S21" "s" "a" "l"
  send_chord "$S21" "Space" "v"
  send_chord "$S21" "Space" "v"
  send_chord "$S21" "Space" "v"
  send_chord "$S21" "S" "]"
  if lem_wait_for "$S21" 'one two \[\(alpha beta\)\] three' "$WAIT_TIMEOUT"; then
    pass "21-expand-region" "repeated SPC v expanded word to enclosing pair"
  else
    fail "21-expand-region" "SPC v did not expand to the enclosing pair" "$S21"
  fi
fi

# ===========================================================================
# Check 22: This Evil configuration keeps Vim's default whole-line Y behavior,
#   even when invoked from the middle of a line.
# ===========================================================================
S22="lem-yath-it22-$id"
if boot_with_file "$S22" "$SCRATCH" 'first known line' "22-Y-linewise"; then
  send_chord "$S22" "w" "Y" "p"
  if lem_wait_for_count "$S22" 'first known line' 2 "$WAIT_TIMEOUT"; then
    pass "22-Y-linewise" "Y yanked the whole line from a mid-line cursor"
  else
    fail "22-Y-linewise" "Y behaved like y$ instead of yy" "$S22"
  fi
fi

# ===========================================================================
# Check 23: Match the effective Evil control-key defaults that differ from
# Lem's stock Vim bindings: normal C-u is a universal argument, insert C-d
# shifts left with Evil rounding and its freshly typed zero shortcut, and
# insert C-v quotes the following physical key.
# ===========================================================================
S23U="lem-yath-it23u-$id"
S23D="lem-yath-it23d-$id"
S23V="lem-yath-it23v-$id"
S23O="lem-yath-it23o-$id"
control_u_ok=0
control_d_ok=0
control_v_ok=0
control_d_org_ok=0

if boot_with_file "$S23U" "$CONTROLFIX" '^one$' "23-control-key-parity"; then
  tmux_cmd send-keys -t "$S23U" "C-u"
  if lem_wait_for "$S23U" 'C-u 4' "$WAIT_TIMEOUT"; then
    send_chord "$S23U" "j" "i"
    send_text "$S23U" "U"
    send_chord "$S23U" Escape
    lem_capture "$S23U" | grep -qE '^Ufive[[:space:]]*$' && control_u_ok=1
  fi
fi

if boot_with_file "$S23D" "$SHIFTFIX" 'alpha' "23-control-key-parity"; then
  send_chord "$S23D" "A" "C-d" Escape "j" "I"
  send_text "$S23D" "0"
  send_chord "$S23D" "C-d" Escape
  sleep 0.5
  shift_screen="$(lem_capture "$S23D")"
  if grep -qE '^    alpha[[:space:]]*$' <<<"$shift_screen" &&
     grep -qE '^beta[[:space:]]*$' <<<"$shift_screen"; then
    control_d_ok=1
  fi
fi

if boot_with_file "$S23O" "$ORGCONTROLFIX" 'Child' "23-control-key-parity"; then
  tmux_cmd send-keys -t "$S23O" M-x
  sleep "$KEY_DELAY"
  send_text "$S23O" "org-mode"
  tmux_cmd send-keys -t "$S23O" Enter
  if lem_wait_for "$S23O" 'Org' "$WAIT_TIMEOUT"; then
    send_chord "$S23O" "i" "C-d" Escape
    send_chord "$S23O" "C-x" "C-s"
  fi
  sleep 0.5
  grep -qxF '* Child' "$ORGCONTROLFIX" && control_d_org_ok=1
fi

if boot_with_file "$S23V" "$QUOTEFIX" '^quote$' "23-control-key-parity"; then
  send_chord "$S23V" "A" "C-v" "C-a"
  send_text "$S23V" "Z"
  send_chord "$S23V" Escape "C-x" "C-s"
  sleep 0.5
  quote_hex="$(od -An -tx1 "$QUOTEFIX" | tr -d '[:space:]')"
  [[ "$quote_hex" == '71756f7465015a0a' ]] && control_v_ok=1
fi

if [ "$control_u_ok" = 1 ] && [ "$control_d_ok" = 1 ] &&
   [ "$control_v_ok" = 1 ] && [ "$control_d_org_ok" = 1 ]; then
  pass "23-control-key-parity" \
    "normal C-u and insert C-d/C-v match the live Evil configuration"
else
  fail "23-control-key-parity" \
    "control-key mismatch (C-u=$control_u_ok C-d=$control_d_ok C-v=$control_v_ok Org-C-d=$control_d_org_ok)" \
    "$S23D"
  echo "----- screen (universal argument $S23U) -----"
  lem_capture "$S23U" 2>/dev/null || echo "(no screen)"
  echo "----- screen (quoted insert $S23V) -----"
  lem_capture "$S23V" 2>/dev/null || echo "(no screen)"
  echo "----- screen (Org C-d $S23O) -----"
  lem_capture "$S23O" 2>/dev/null || echo "(no screen)"
  echo "----------------------------------------------"
fi

# ===========================================================================
# Check 24: Match the remaining unambiguous everyday Evil insert controls:
# C-o executes one complete Normal command, C-t shifts right, and C-y/C-e copy
# from the nearest nonblank line above/below.  Org keeps its local C-t binding.
# ===========================================================================
S24O="lem-yath-it24o-$id"
S24P="lem-yath-it24p-$id"
S24T="lem-yath-it24t-$id"
S24C="lem-yath-it24c-$id"
S24G="lem-yath-it24g-$id"
control_o_ok=0
control_o_undo_ok=0
control_o_abort_ok=0
control_o_prompt_ok=0
control_t_ok=0
control_copy_ok=0
control_t_org_ok=0

if boot_with_file "$S24O" "$ONENORMALFIX" '^abc def$' "24-insert-control-parity"; then
  send_chord "$S24O" "i" "C-o" "d" "w"
  if lem_wait_for "$S24O" 'INSERT' "$WAIT_TIMEOUT"; then
    send_text "$S24O" "X"
    send_chord "$S24O" Escape "C-x" "C-s"
    sleep 0.5
    if grep -qxF 'Xdef' "$ONENORMALFIX"; then
      control_o_ok=1
      send_chord "$S24O" "u" "C-x" "C-s"
      sleep 0.5
      grep -qxF 'def' "$ONENORMALFIX" && control_o_undo_ok=1
      send_chord "$S24O" "i" "C-o" "C-g"
      if lem_wait_for "$S24O" 'INSERT' "$WAIT_TIMEOUT"; then
        send_text "$S24O" "X"
        send_chord "$S24O" Escape "C-x" "C-s"
        sleep 0.5
        grep -qxF 'Xdef' "$ONENORMALFIX" && control_o_abort_ok=1
      fi
    fi
  fi
fi

if boot_with_file "$S24P" "$ONENORMALPROMPTFIX" '^abc def$' "24-insert-control-parity"; then
  send_chord "$S24P" "i" "C-o"
  tmux_cmd send-keys -t "$S24P" M-x
  if lem_wait_for "$S24P" 'Command:' "$WAIT_TIMEOUT"; then
    send_text "$S24P" "forward-char"
    tmux_cmd send-keys -t "$S24P" Enter
    if lem_wait_for "$S24P" 'INSERT' "$WAIT_TIMEOUT"; then
      send_text "$S24P" "X"
      send_chord "$S24P" Escape "C-x" "C-s"
      sleep 0.5
      grep -qxF 'aXbc def' "$ONENORMALPROMPTFIX" && control_o_prompt_ok=1
    fi
  fi
fi

if boot_with_file "$S24T" "$SHIFTFIX" 'alpha' "24-insert-control-parity"; then
  send_chord "$S24T" "A" "C-t" Escape "C-x" "C-s"
  sleep 0.5
  grep -qxF '            alpha' "$SHIFTFIX" && control_t_ok=1
fi

if boot_with_file "$S24C" "$COPYCONTROLFIX" '^ABOVE$' "24-insert-control-parity"; then
  send_chord "$S24C" "j" "j" "A" "C-y" "C-e" Escape "C-x" "C-s"
  sleep 0.5
  sed -n '3p' "$COPYCONTROLFIX" | grep -qxF 'xxOO' && control_copy_ok=1
fi

if boot_with_file "$S24G" "$ORGRIGHTFIX" 'Child' "24-insert-control-parity"; then
  tmux_cmd send-keys -t "$S24G" M-x
  sleep "$KEY_DELAY"
  send_text "$S24G" "org-mode"
  tmux_cmd send-keys -t "$S24G" Enter
  if lem_wait_for "$S24G" 'Org' "$WAIT_TIMEOUT"; then
    send_chord "$S24G" "i" "C-t" Escape "C-x" "C-s"
  fi
  sleep 0.5
  grep -qxF '** Child' "$ORGRIGHTFIX" && control_t_org_ok=1
fi

if [ "$control_o_ok" = 1 ] && [ "$control_o_undo_ok" = 1 ] &&
   [ "$control_o_abort_ok" = 1 ] && [ "$control_o_prompt_ok" = 1 ] &&
   [ "$control_t_ok" = 1 ] &&
   [ "$control_copy_ok" = 1 ] && [ "$control_t_org_ok" = 1 ]; then
  pass "24-insert-control-parity" \
    "insert C-o/C-t/C-y/C-e match the live Evil configuration"
else
  fail "24-insert-control-parity" \
    "insert-control mismatch (C-o=$control_o_ok undo=$control_o_undo_ok abort=$control_o_abort_ok prompt=$control_o_prompt_ok C-t=$control_t_ok copy=$control_copy_ok Org-C-t=$control_t_org_ok)" \
    "$S24O"
  echo "----- screen (one-Normal prompt $S24P) -----"
  lem_capture "$S24P" 2>/dev/null || echo "(no screen)"
  echo "----- screen (shift right $S24T) -----"
  lem_capture "$S24T" 2>/dev/null || echo "(no screen)"
  echo "----- screen (copy controls $S24C) -----"
  lem_capture "$S24C" 2>/dev/null || echo "(no screen)"
  echo "----- screen (Org C-t $S24G) -----"
  lem_capture "$S24G" 2>/dev/null || echo "(no screen)"
  echo "----------------------------------------"
fi

# ===========================================================================
# Check 25: Match Evil's insert-state register controls.  C-a inserts the last
# contiguous insertion; C-r inserts either characterwise or linewise register
# text verbatim.  The new insertion remains a separate undo unit.
# ===========================================================================
S25A="lem-yath-it25a-$id"
S25R="lem-yath-it25r-$id"
S25L="lem-yath-it25l-$id"
last_insert_ok=0
last_insert_undo_ok=0
char_register_ok=0
line_register_ok=0

if boot_with_file "$S25A" "$LASTINSERTFIX" '^base$' "25-insert-registers"; then
  tmux_cmd send-keys -t "$S25A" A
  send_text "$S25A" "foo"
  send_chord "$S25A" Escape "j" "i" "C-a" Escape "C-x" "C-s"
  sleep 0.5
  if cmp -s "$LASTINSERTFIX" <(printf 'basefoo\nfoo\n'); then
    last_insert_ok=1
    send_chord "$S25A" "u" "C-x" "C-s"
    sleep 0.5
    cmp -s "$LASTINSERTFIX" <(printf 'basefoo\n\n') && last_insert_undo_ok=1
  fi
fi

if boot_with_file "$S25R" "$CHARREGISTERFIX" '^TOKEN$' "25-insert-registers"; then
  send_chord "$S25R" "0" "y" "e" "j" "A" "C-r" "0" Escape "C-x" "C-s"
  sleep 0.5
  cmp -s "$CHARREGISTERFIX" <(printf 'TOKEN\nhereTOKEN\n') && char_register_ok=1
fi

if boot_with_file "$S25L" "$LINEREGISTERFIX" '^TOKEN$' "25-insert-registers"; then
  send_chord "$S25L" "y" "y" "j" "A" "C-r" "0" Escape "C-x" "C-s"
  sleep 0.5
  cmp -s "$LINEREGISTERFIX" <(printf 'TOKEN\nhereTOKEN\n\n') && line_register_ok=1
fi

if [ "$last_insert_ok" = 1 ] && [ "$last_insert_undo_ok" = 1 ] &&
   [ "$char_register_ok" = 1 ] && [ "$line_register_ok" = 1 ]; then
  pass "25-insert-registers" \
    "insert C-a/C-r preserve Evil text, register, and undo semantics"
else
  fail "25-insert-registers" \
    "insert-register mismatch (last=$last_insert_ok undo=$last_insert_undo_ok char=$char_register_ok line=$line_register_ok)" \
    "$S25A"
  echo "----- screen (character register $S25R) -----"
  lem_capture "$S25R" 2>/dev/null || echo "(no screen)"
  echo "----- screen (line register $S25L) -----"
  lem_capture "$S25L" 2>/dev/null || echo "(no screen)"
  echo "-----------------------------------------"
fi

# ===========================================================================
# Check 26: Match core Evil register selection through physical keys.  Named
# characterwise, linewise, and Visual writes remain typed; uppercase names
# append; blackhole deletion preserves unnamed/numbered history; selected
# numbered reads work; and dot-repeat retains the selected register and count.
# ===========================================================================
S26N="lem-yath-it26n-$id"
S26A="lem-yath-it26a-$id"
S26B="lem-yath-it26b-$id"
S26V="lem-yath-it26v-$id"
S26L="lem-yath-it26l-$id"
S26R="lem-yath-it26r-$id"
S26I="lem-yath-it26i-$id"
S26D="lem-yath-it26d-$id"
named_register_ok=0
append_register_ok=0
blackhole_register_ok=0
visual_register_ok=0
line_named_register_ok=0
repeat_register_ok=0
readonly_register_ok=0
delete_register_ok=0

if boot_with_file "$S26N" "$NAMEDREGISTERFIX" '^ZERO$' "26-normal-registers"; then
  send_chord "$S26N" "0" "y" "e" "j" "0" '"' "a" "y" "e" \
    "j" '$' '"' "a" "p" '"' "0" "p" "C-x" "C-s"
  sleep 0.5
  cmp -s "$NAMEDREGISTERFIX" <(printf 'ZERO\ncat dog\nsinkcatZERO\n') && named_register_ok=1
fi

if boot_with_file "$S26A" "$APPENDREGISTERFIX" '^red blue green$' "26-normal-registers"; then
  send_chord "$S26A" "0" '"' "a" "y" "e" "w" '"' "A" "y" "e" \
    "j" '$' '"' "a" "p" "C-x" "C-s"
  sleep 0.5
  cmp -s "$APPENDREGISTERFIX" <(printf 'red blue green\nsinkredblue\n') && append_register_ok=1
fi

if boot_with_file "$S26B" "$BLACKHOLEREGISTERFIX" '^HISTORY$' "26-normal-registers"; then
  send_chord "$S26B" "d" "d" "0" "y" "e" "j" "0" '"' "_" "d" "e" \
    "j" '$' "p" '"' "1" "P" "C-x" "C-s"
  sleep 0.5
  cmp -s "$BLACKHOLEREGISTERFIX" <(printf 'KEEP\n here\nHISTORY\nsinkKEEP\n') && blackhole_register_ok=1
fi

if boot_with_file "$S26V" "$VISUALREGISTERFIX" '^alpha beta$' "26-normal-registers"; then
  send_chord "$S26V" "v" "e" '"' "b" "y" "j" "0" "v" "e" \
    '"' "b" "p" "C-x" "C-s"
  sleep 0.5
  cmp -s "$VISUALREGISTERFIX" <(printf 'alpha beta\nalpha\n') && visual_register_ok=1
fi

if boot_with_file "$S26L" "$LINENAMEDREGISTERFIX" '^LINE$' "26-normal-registers"; then
  send_chord "$S26L" '"' "a" "y" "y" "j" '"' "a" "p" "C-x" "C-s"
  sleep 0.5
  cmp -s "$LINENAMEDREGISTERFIX" <(printf 'LINE\nsink\nLINE\n') && line_named_register_ok=1
fi

if boot_with_file "$S26R" "$REPEATREGISTERFIX" '^cat$' "26-normal-registers"; then
  send_chord "$S26R" "0" '"' "a" "y" "e" "j" "0" "y" "e" \
    "j" '$' '"' "a" "2" "p" "." "C-x" "C-s"
  sleep 0.5
  cmp -s "$REPEATREGISTERFIX" <(printf 'cat\njunk\nsinkcatcatcatcat\n') && repeat_register_ok=1
fi

if boot_with_file "$S26I" "$READONLYREGISTERFIX" '^keep text$' "26-normal-registers"; then
  send_chord "$S26I" '"' "%" "d" "w" "0" '"' "_" "p" "i"
  send_text "$S26I" "X"
  send_chord "$S26I" Escape "C-x" "C-s"
  sleep 0.5
  cmp -s "$READONLYREGISTERFIX" <(printf 'Xkeep text\n') && readonly_register_ok=1
fi

if boot_with_file "$S26D" "$DELETEREGISTERFIX" '^one two$' "26-normal-registers"; then
  send_chord "$S26D" "0" '"' "a" "d" "e" "j" '$' \
    '"' "a" "p" '"' "1" "p" "C-x" "C-s"
  sleep 0.5
  cmp -s "$DELETEREGISTERFIX" <(printf ' two\nsinkoneone\n') && delete_register_ok=1
fi

if [ "$named_register_ok" = 1 ] && [ "$append_register_ok" = 1 ] &&
   [ "$blackhole_register_ok" = 1 ] && [ "$visual_register_ok" = 1 ] &&
   [ "$line_named_register_ok" = 1 ] && [ "$repeat_register_ok" = 1 ] &&
   [ "$readonly_register_ok" = 1 ] && [ "$delete_register_ok" = 1 ]; then
  pass "26-normal-registers" \
    "named, appended, blackhole, typed, counted, and repeated registers match Evil"
else
  fail "26-normal-registers" \
    "register mismatch (named=$named_register_ok append=$append_register_ok blackhole=$blackhole_register_ok visual=$visual_register_ok line=$line_named_register_ok repeat=$repeat_register_ok readonly=$readonly_register_ok delete=$delete_register_ok)" \
    "$S26N"
  for session in "$S26A" "$S26B" "$S26V" "$S26L" "$S26R" "$S26I" "$S26D"; do
    echo "----- screen ($session) -----"
    lem_capture "$session" 2>/dev/null || echo "(no screen)"
  done
  echo "--------------------------------"
fi

# ===========================================================================
# Check 27: The read-only dot register exposes the previous contiguous Insert
# session to Normal-state paste, including a count and dot-repeat.
# ===========================================================================
S27="lem-yath-it27-$id"
dot_register_ok=0

if boot_with_file "$S27" "$DOTREGISTERFIX" '^base$' "27-dot-register"; then
  tmux_cmd send-keys -t "$S27" "A"
  send_text "$S27" "foo"
  send_chord "$S27" Escape "j" '$' '"' "." "2" "p" "." "C-x" "C-s"
  sleep 0.5
  cmp -s "$DOTREGISTERFIX" <(printf 'basefoo\nsinkfoofoofoofoo\n') && dot_register_ok=1
fi

if [ "$dot_register_ok" = 1 ]; then
  pass "27-dot-register" \
    'normal ".2p and dot-repeat use the previous contiguous insertion'
else
  fail "27-dot-register" \
    "normal dot-register mismatch (paste=$dot_register_ok)" "$S27"
fi

# ===========================================================================
# Check 28: Insert C-k uses Evil's effective digraph table, reverse-pair
# fallback, invalid-pair fallback, cancellation, and Replace-state restoration.
# ===========================================================================
S28I="lem-yath-it28i-$id"
S28R="lem-yath-it28r-$id"
digraph_insert_ok=0
digraph_replace_ok=0

if boot_with_file "$S28I" "$DIGRAPHFIX" '^base$' "28-insert-digraphs"; then
  send_chord "$S28I" "A" "C-k" "a" "*" "C-k" "*" "a" \
    "C-k" "<" "/" "C-k" "/" ">" "C-k" "q" "z" "C-k" "C-g"
  send_text "$S28I" "x"
  send_chord "$S28I" Escape "C-x" "C-s"
  sleep 0.5
  cmp -s "$DIGRAPHFIX" <(printf 'baseαα〈〉zx\n') && digraph_insert_ok=1
fi

if boot_with_file "$S28R" "$REPLACEDIGRAPHFIX" '^ABCDE$' "28-insert-digraphs"; then
  send_chord "$S28R" "0" "R" "C-k" "a" "*" BSpace \
    "C-k" "<" "/" Escape "C-x" "C-s"
  sleep 0.5
  cmp -s "$REPLACEDIGRAPHFIX" <(printf '〈BCDE\n') && digraph_replace_ok=1
fi

if [ "$digraph_insert_ok" = 1 ] && [ "$digraph_replace_ok" = 1 ]; then
  pass "28-insert-digraphs" \
    "C-k matches Evil direct, reverse, invalid, abort, and Replace behavior"
else
  fail "28-insert-digraphs" \
    "digraph mismatch (insert=$digraph_insert_ok replace=$digraph_replace_ok)" \
    "$S28I"
  echo "----- screen ($S28R) -----"
  lem_capture "$S28R" 2>/dev/null || echo "(no screen)"
  echo "--------------------------------"
fi

# ===========================================================================
# Check 29: Evil's special file, command, and search registers expose text.
# The alternate file follows the most recent suitable other buffer, while
# word searches update / and establish the direction used by n.
# ===========================================================================
S29="lem-yath-it29-$id"
special_register_ok=0

if boot_with_file "$S29" "$SPECIALREGISTERAFIX" '^alternate source$' \
    "29-special-registers"; then
  tmux_cmd send-keys -t "$S29" ":"
  sleep "$KEY_DELAY"
  send_text "$S29" "e $SPECIALREGISTERBFIX"
  tmux_cmd send-keys -t "$S29" Enter
  if lem_wait_for "$S29" '^current=$' "$WAIT_TIMEOUT"; then
    send_chord "$S29" '$' '"' '%' 'p' 'j' '$' '"' '#' 'p' \
      'j' '$' '"' ':' 'p' 'j' '0' '*' 'n' 'r' 'X' \
      '0' 'w' 'w' '#' 'n' 'r' 'Y' 'G' '$' '"' '/' 'p' \
      'C-x' 'C-s'
    sleep 0.5
    cmp -s "$SPECIALREGISTERBFIX" <(
      printf 'current=%s\nalternate=%s\ncommand=e %s\nword other Yord other Xord\nslash=word\n' \
        "$SPECIALREGISTERBFIX" "$SPECIALREGISTERAFIX" \
        "$SPECIALREGISTERBFIX"
    ) && special_register_ok=1
  fi
fi

if [ "$special_register_ok" = 1 ]; then
  pass "29-special-registers" \
    '%, #, :, /, *, #, and n match Evil file/command/search behavior'
else
  fail "29-special-registers" \
    "special register mismatch (paste/search=$special_register_ok)" "$S29"
fi

# ===========================================================================
# Check 30: Evil's expression register evaluates numeric Calc expressions.
# A second empty submission accepts the previous expression, matching Evil's
# retained expression prompt and register-paste workflow.
# ===========================================================================
S30="lem-yath-it30-$id"
expression_register_ok=0

if boot_with_file "$S30" "$EXPRESSIONREGISTERFIX" '^base$' \
    "30-expression-register"; then
  send_chord "$S30" '$' '"' '='
  send_text "$S30" '1+2*3'
  tmux_cmd send-keys -t "$S30" Enter
  send_chord "$S30" 'p' '"' '='
  tmux_cmd send-keys -t "$S30" Enter
  send_chord "$S30" 'p' 'C-x' 'C-s'
  sleep 0.5
  cmp -s "$EXPRESSIONREGISTERFIX" <(printf 'base77\n') && \
    expression_register_ok=1
fi

if [ "$expression_register_ok" = 1 ]; then
  pass "30-expression-register" \
    'numeric = evaluation and retained prompt input match Evil'
else
  fail "30-expression-register" \
    "expression register mismatch (numeric/history=$expression_register_ok)" \
    "$S30"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "================ SUMMARY ================"
order=(01-boot-normal 02-insert-roundtrip 03-leader-compile 04-gc-operator \
       05-snipe 06-find-file 07-mx-prescient 08-native-delete \
       09-native-change 09-insert-C-w 10-evil-surround 11-visual-leader \
       12-visual-operators 13-doubled-operators 14-count-repeat \
       15-snipe-parity 16-insert-C-u 17-fill-paragraph 18-org-id \
       19-auto-fill-toggle 20-control-state-split 21-expand-region \
       22-Y-linewise 23-control-key-parity 24-insert-control-parity \
       25-insert-registers 26-normal-registers 27-dot-register \
       28-insert-digraphs 29-special-registers 30-expression-register)
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
