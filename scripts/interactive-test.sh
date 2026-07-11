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
SNIPEREPEATFIX=/tmp/lem-yath-itest-snipe-repeat.txt
INDENTFIX=/tmp/lem-yath-itest-indent.txt
FILLFIX=/tmp/lem-yath-itest-fill.txt
ORGFIX=/tmp/lem-yath-itest.org
EXPANDFIX=/tmp/lem-yath-itest-expand.txt

printf 'first known line\nsecond known line\nthird known line\n' > "$SCRATCH"
printf '(defun alpha ())\n(defun beta ())\n(defun gamma ())\n' > "$LISPFIX"
printf 'def alpha():\n    pass\ndef beta():\n    pass\n' > "$PYFIX"
printf 'alpha beta gamma\n' > "$SNIPEFIX"
printf 'ab xx ab yy ab\n' > "$SNIPEREPEATFIX"
printf '    alpha beta\n' > "$INDENTFIX"
printf 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega\n' > "$FILLFIX"
printf '* Heading\nBody\n' > "$ORGFIX"
printf 'one two (alpha beta) three\n\nnext\n' > "$EXPANDFIX"

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
  sleep "$KEY_DELAY"
  if lem_capture "$S9" | grep -qE '^[[:space:][:digit:]]*delta beta gamma[[:space:]]*$' && \
     lem_capture "$S9" | grep -qE 'NORMAL'; then
    pass "09-native-change" "cw replaced the first word and returned to NORMAL"
  else
    fail "09-native-change" "cw replacement or NORMAL state was wrong" "$S9"
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
  sleep "$KEY_DELAY"
  if lem_capture "$S12C" | grep -qE '^[[:space:][:digit:]]*XYpha beta gamma[[:space:]]*$' && \
     lem_capture "$S12C" | grep -qE 'NORMAL'; then
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
  lem_capture "$S13D" | grep -qE '^[[:space:][:digit:]]*second known line[[:space:]]*$' && double_delete_ok=1
fi
if boot_with_file "$S13C" "$SCRATCH" 'first known line' "13-doubled-operators"; then
  send_chord "$S13C" "c" "c"
  send_text "$S13C" "replacement"
  tmux_cmd send-keys -t "$S13C" Escape
  sleep "$KEY_DELAY"
  lem_capture "$S13C" | grep -qE '^[[:space:][:digit:]]*replacement[[:space:]]*$' && double_change_ok=1
fi
if boot_with_file "$S13Y" "$SCRATCH" 'first known line' "13-doubled-operators"; then
  send_chord "$S13Y" "y" "y" "p"
  if [ "$(lem_capture "$S13Y" | grep -c 'first known line')" = 2 ]; then
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
  lem_capture "$S14C" | grep -qE '^[[:space:][:digit:]]*gamma[[:space:]]*$' && count_ok=1
fi
if boot_with_file "$S14R" "$SNIPEFIX" 'alpha beta gamma' "14-count-repeat"; then
  send_chord "$S14R" "d" "w" "."
  lem_capture "$S14R" | grep -qE '^[[:space:][:digit:]]*gamma[[:space:]]*$' && repeat_ok=1
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
  lem_capture "$S15R" | grep -qE '^[[:space:][:digit:]]*ab xx ab yy Xab[[:space:]]*$' && snipe_repeat_ok=1
fi
if boot_with_file "$S15O" "$SNIPEFIX" 'alpha beta gamma' "15-snipe-parity"; then
  send_chord "$S15O" "d" "z" "b" "e"
  lem_capture "$S15O" | grep -qE '^[[:space:][:digit:]]*ta gamma[[:space:]]*$' && snipe_operator_ok=1
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
  sleep "$KEY_DELAY"
  if lem_capture "$S16" | grep -qE '^[[:space:][:digit:]]*omega[[:space:]]*$' && \
     lem_capture "$S16" | grep -qE 'NORMAL'; then
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
  if echo "$fill_screen" | grep -q 'alpha beta gamma' && \
     echo "$fill_screen" | grep -q 'omega' && \
     ! echo "$fill_screen" | grep -qE 'alpha.*omega'; then
    pass "17-fill-paragraph" "SPC y w wrapped the paragraph"
  else
    fail "17-fill-paragraph" "SPC y w did not wrap the paragraph" "$S17"
  fi
fi

# ===========================================================================
# Check 18: SPC m I creates a valid Org ID property drawer at the current
#   heading.
# ===========================================================================
S18="lem-yath-it18-$id"
if boot_with_file "$S18" "$ORGFIX" '\* Heading' "18-org-id"; then
  send_chord "$S18" "Space" "m" "I"
  sleep 0.6
  tmux_cmd send-keys -t "$S18" "j"
  sleep "$KEY_DELAY"
  org_screen="$(lem_capture "$S18")"
  if echo "$org_screen" | grep -q ':PROPERTIES:' && \
     echo "$org_screen" | grep -qiE ':ID: [0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' && \
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
  sleep "$KEY_DELAY"
  auto_fill_screen="$(lem_capture "$S19")"
  if echo "$auto_fill_screen" | grep -q 'alpha beta gamma' && \
     echo "$auto_fill_screen" | grep -q 'tail' && \
     ! echo "$auto_fill_screen" | grep -qE 'alpha.*tail'; then
    pass "19-auto-fill-toggle" "SPC y a enabled functional auto fill"
  else
    fail "19-auto-fill-toggle" "SPC y a did not wrap inserted text" "$S19"
  fi
fi

# ===========================================================================
# Check 20: C-n/C-p retain ordinary line movement instead of Lem's vi yank-pop
#   overrides.
# ===========================================================================
S20="lem-yath-it20-$id"
if boot_with_file "$S20" "$SCRATCH" 'first known line' "20-control-line-motion"; then
  tmux_cmd send-keys -t "$S20" "C-n"
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$S20" "i"
  send_text "$S20" "X"
  tmux_cmd send-keys -t "$S20" Escape
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$S20" "C-p"
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$S20" "i"
  send_text "$S20" "Y"
  tmux_cmd send-keys -t "$S20" Escape
  sleep "$KEY_DELAY"
  control_screen="$(lem_capture "$S20")"
  if echo "$control_screen" | grep -q 'Yfirst known line' && \
     echo "$control_screen" | grep -q 'Xsecond known line'; then
    pass "20-control-line-motion" "C-n/C-p moved between logical lines"
  else
    fail "20-control-line-motion" "C-n/C-p did not retain line movement" "$S20"
  fi
fi

# ===========================================================================
# Check 21: Repeated SPC v expands from the word at point to its nearest
#   enclosing delimiter. Visual S then exposes the exact selected range.
# ===========================================================================
S21="lem-yath-it21-$id"
if boot_with_file "$S21" "$EXPANDFIX" 'one two.*alpha beta.*three' "21-expand-region"; then
  send_chord "$S21" "s" "a" "l"
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
  y_line_screen="$(lem_capture "$S22")"
  if [ "$(echo "$y_line_screen" | grep -c 'first known line')" = 2 ]; then
    pass "22-Y-linewise" "Y yanked the whole line from a mid-line cursor"
  else
    fail "22-Y-linewise" "Y behaved like y$ instead of yy" "$S22"
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo
echo "================ SUMMARY ================"
order=(01-boot-normal 02-insert-roundtrip 03-leader-compile 04-gc-operator \
       05-snipe 06-find-file 07-mx-prescient 08-native-delete \
       09-native-change 10-evil-surround 11-visual-leader \
       12-visual-operators 13-doubled-operators 14-count-repeat \
       15-snipe-parity 16-insert-C-u 17-fill-paragraph 18-org-id \
       19-auto-fill-toggle 20-control-line-motion 21-expand-region \
       22-Y-linewise)
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
