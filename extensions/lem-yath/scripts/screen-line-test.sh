#!/usr/bin/env bash
# Evil visual-line parity through the real configured ncurses editor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LEM_TUI_WIDTH=40
export LEM_TUI_HEIGHT=24
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-screen-line-$$}"
fixture="$here/scripts/screen-line-fixture.lisp"
KEY_DELAY="${KEY_DELAY:-0.18}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-40}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-12}"
SESSIONS=()
FAILED=0
COMPLETED_CASES=0
CASE_INDEX=0

cleanup() {
  local session
  for session in "${SESSIONS[@]:-}"; do
    [ -n "$session" ] && tmux_cmd kill-session -t "$session" 2>/dev/null
  done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }
fail() {
  FAILED=1
  printf 'FAIL  %-28s %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then
    printf '%s\n' "----- screen ($3) -----"
    lem_capture "$3" 2>/dev/null || true
    printf '%s\n' '------------------------'
  fi
}

keys() {
  local session="$1" key
  shift
  for key in "$@"; do
    tmux_cmd send-keys -t "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

report_count() {
  local prefix="$1"
  grep -c "^${prefix}" "$CASE_REPORT" 2>/dev/null || true
}

wait_report() {
  local prefix="$1" previous="${2:-0}" i=0 count
  while ((i < WAIT_TIMEOUT * 10)); do
    count=$(report_count "$prefix")
    if ((count > previous)); then
      grep "^${prefix}" "$CASE_REPORT" | tail -1
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf 'Timed out waiting for %s in %s\n' "$prefix" "$CASE_REPORT" >&2
  return 1
}

field() {
  local line="$1" name="$2"
  sed -n "s/.* ${name}=\\([^ ]*\\).*/\\1/p" <<<"$line"
}

expect_eq() {
  local actual="$1" expected="$2" description="$3"
  if [ "$actual" != "$expected" ]; then
    CASE_OK=0
    printf '  expected %s=%s, got %s\n' "$description" "$expected" "$actual" >&2
  fi
}

expect_contains() {
  local actual="$1" expected="$2" description="$3"
  if [[ "$actual" != *"$expected"* ]]; then
    CASE_OK=0
    printf '  expected %s to contain %s, got %s\n' \
      "$description" "$expected" "$actual" >&2
  fi
}

expect_matches() {
  local actual="$1" pattern="$2" description="$3"
  if ! grep -qE "$pattern" <<<"$actual"; then
    CASE_OK=0
    printf '  expected %s to match /%s/\n' "$description" "$pattern" >&2
  fi
}

finish_case() {
  local name="$1" message="$2"
  if [ "$CASE_OK" = 1 ]; then
    pass "$name" "$message"
  else
    fail "$name" "$message" "$CASE_SESSION"
  fi
  COMPLETED_CASES=$((COMPLETED_CASES + 1))
  if (( ${SCREEN_LINE_STOP_AFTER:-0} > 0 &&
        COMPLETED_CASES >= SCREEN_LINE_STOP_AFTER )); then
    exit "$FAILED"
  fi
}

start_case() {
  local label="$1" wrap="$2" extension="${3:-txt}"
  local start_at="${SCREEN_LINE_START_AT:-1}"
  local scratch="/tmp/lem-yath-screen-line-${label}-${id}.${extension}"
  local fixture_string before
  CASE_INDEX=$((CASE_INDEX + 1))
  if ((CASE_INDEX < start_at)); then
    return 1
  fi
  CASE_SESSION="lem-screen-${label}-${id}"
  CASE_REPORT="/tmp/lem-yath-screen-line-${label}-${id}.report"
  : >"$CASE_REPORT"
  printf 'screen-line boot marker\n' >"$scratch"
  export LEM_YATH_SCREEN_LINE_REPORT="$CASE_REPORT"
  if tmux_cmd list-sessions >/dev/null 2>&1; then
    tmux_cmd set-environment -g LEM_YATH_SCREEN_LINE_REPORT "$CASE_REPORT"
  fi
  fixture_string=$(lem-yath_lisp_string "$fixture")
  SESSIONS+=("$CASE_SESSION")
  lem_start "$CASE_SESSION" "$scratch" --eval "(load #P$fixture_string)"
  if ! lem_wait_for "$CASE_SESSION" 'screen-line boot marker' "$BOOT_TIMEOUT" >/dev/null; then
    fail "$label-boot" "configured editor did not open" "$CASE_SESSION"
    return 1
  fi
  if ! wait_report READY 0 >/dev/null; then
    fail "$label-fixture" "fixture did not load" "$CASE_SESSION"
    return 1
  fi
  before=$(report_count PREP)
  keys "$CASE_SESSION" F1
  PREP=$(wait_report PREP "$before") || return 1
  ROW=$(field "$PREP" row)
  SECOND=$(field "$PREP" second)
  THIRD=$(field "$PREP" third)
  FOURTH=$(field "$PREP" fourth)
  LOGICAL2=$(field "$PREP" logical2)
  BASELINE=$(field "$PREP" baseline)
  if [ "$wrap" = yes ]; then
    keys "$CASE_SESSION" Space y v
  fi
  return 0
}

setup_key() {
  local key="$1" before
  before=$(report_count SETUP)
  keys "$CASE_SESSION" "$key"
  wait_report SETUP "$before" >/dev/null
}

reset_unwrapped_case() {
  local before
  before=$(report_count PREP)
  keys "$CASE_SESSION" F1
  PREP=$(wait_report PREP "$before")
  ROW=$(field "$PREP" row)
  SECOND=$(field "$PREP" second)
  THIRD=$(field "$PREP" third)
  FOURTH=$(field "$PREP" fourth)
  LOGICAL2=$(field "$PREP" logical2)
  BASELINE=$(field "$PREP" baseline)
}

reset_wrapped_case() {
  reset_unwrapped_case
  keys "$CASE_SESSION" Space y v
}

record_state() {
  local before
  before=$(report_count STATE)
  keys "$CASE_SESSION" F5
  STATE=$(wait_report STATE "$before")
}

# 01: Policy is installed once and the real leader toggle remains reversible.
if start_case policy no; then
  CASE_OK=1
  before=$(report_count STATIC)
  keys "$CASE_SESSION" F6
  STATIC=$(wait_report STATIC "$before")
  expect_contains "$STATIC" 'respect=yes' policy
  expect_contains "$STATIC" 'wordwrap=yes' word-boundary-policy
  expect_contains "$STATIC" 'j=LEM-YATH-NEXT-LINE' j-binding
  expect_contains "$STATIC" 'gj=LEM-YATH-NEXT-G-LINE' gj-binding
  expect_contains "$STATIC" 'visual=LEM-YATH-VISUAL-LINE' V-binding
  expect_eq "$(field "$PREP" exact)" yes exact-eol-column
  expect_eq "$(field "$PREP" overflow)" no overflow-column
  record_state
  expect_eq "$(field "$STATE" wrap)" no initial-wrap
  keys "$CASE_SESSION" Space y v
  record_state
  expect_eq "$(field "$STATE" wrap)" yes enabled-wrap
  keys "$CASE_SESSION" Space y v
  record_state
  expect_eq "$(field "$STATE" wrap)" no restored-wrap
  finish_case 01-policy-toggle "buffer-local screen-line policy and SPC y v are exact"
fi

# 02: j/k use displayed rows, gj/gk use logical lines, and goals do not leak.
if start_case vertical yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" j
  record_state
  expect_eq "$(field "$STATE" point)" "$((THIRD + 5))" j-point
  keys "$CASE_SESSION" k
  record_state
  expect_eq "$(field "$STATE" point)" "$((SECOND + 5))" k-point
  setup_key F2
  keys "$CASE_SESSION" 2 j
  record_state
  expect_eq "$(field "$STATE" point)" "$((FOURTH + 5))" counted-j
  setup_key F2
  keys "$CASE_SESSION" g j
  record_state
  expect_eq "$(field "$STATE" line)" 2 gj-logical-line
  expect_eq "$(field "$STATE" point)" "$((LOGICAL2 + 11))" gj-short-tail
  setup_key F2
  keys "$CASE_SESSION" j g j g k
  record_state
  expect_eq "$(field "$STATE" point)" "$((THIRD + 5))" family-goal-reset
  finish_case 02-vertical-goals "j/k, gj/gk, counts, short tails, and goal-family resets work"
fi

# 03: screen/logical beginnings, ends, counts, I, and A match Evil.
if start_case horizontal yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" 0
  record_state
  expect_eq "$(field "$STATE" point)" "$SECOND" screen-zero
  setup_key F2
  keys "$CASE_SESSION" g 0
  record_state
  expect_eq "$(field "$STATE" point)" 1 logical-g-zero
  setup_key F2
  keys "$CASE_SESSION" '$'
  record_state
  expect_eq "$(field "$STATE" point)" "$((THIRD - 1))" screen-end
  setup_key F2
  keys "$CASE_SESSION" g '$'
  record_state
  expect_eq "$(field "$STATE" point)" "$((LOGICAL2 - 2))" logical-end
  setup_key F2
  keys "$CASE_SESSION" 2 '$'
  record_state
  expect_eq "$(field "$STATE" point)" "$((FOURTH - 1))" counted-screen-end
  setup_key F2
  keys "$CASE_SESSION" I
  tmux_cmd send-keys -t "$CASE_SESSION" -l X
  keys "$CASE_SESSION" Escape
  record_state
  expect_eq "$(field "$STATE" point)" "$SECOND" I-point
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE + 1))" I-length
  finish_case 03-horizontal-insert "0/g0, $/g$, 2$, and I use displayed-row geometry"
fi

if start_case append yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" A
  tmux_cmd send-keys -t "$CASE_SESSION" -l X
  keys "$CASE_SESSION" Escape
  record_state
  expect_eq "$(field "$STATE" point)" "$THIRD" A-point
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE + 1))" A-length
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" 2 j A
  tmux_cmd send-keys -t "$CASE_SESSION" -l X
  keys "$CASE_SESSION" Escape
  record_state
  expect_eq "$(field "$STATE" point)" "$((LOGICAL2 - 1))" A-final-row-point
  expect_eq "$(field "$STATE" line)" 1 A-final-row-line
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE + 1))" A-final-row-length
  before=$(report_count EMPTY)
  keys "$CASE_SESSION" F12
  EMPTY=$(wait_report EMPTY "$before")
  EMPTY_BASE=$(field "$EMPTY" baseline)
  keys "$CASE_SESSION" A
  tmux_cmd send-keys -t "$CASE_SESSION" -l X
  keys "$CASE_SESSION" Escape
  record_state
  expect_eq "$(field "$STATE" line)" 2 A-empty-line
  expect_eq "$(field "$STATE" buflen)" "$((EMPTY_BASE + 1))" A-empty-length
  expect_contains "$(field "$STATE" text)" 'first\nX\nthird\n' A-empty-text
  finish_case 04-append "A respects middle, final, and empty displayed-row ends"
fi

# 05: ordinary screen motions remain characterwise for d/y/c.
if start_case charops yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" d j
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - ROW))" dj-length
  expect_eq "$(field "$STATE" regtype)" char dj-register
  expect_eq "$(field "$STATE" reglen)" "$ROW" dj-register-length
  expect_eq "$(field "$STATE" unnamed)" - dj-small-register
  expect_eq "$(field "$STATE" onetype)" char dj-one-register
  expect_eq "$(field "$STATE" onelen)" "$ROW" dj-one-length
  finish_case 05-dj "dj deletes one exclusive displayed-row distance characterwise"
fi

if start_case yankmotion yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" y j
  record_state
  expect_eq "$(field "$STATE" buflen)" "$BASELINE" yj-buffer
  expect_eq "$(field "$STATE" regtype)" char yj-register
  expect_eq "$(field "$STATE" reglen)" "$ROW" yj-register-length
  expect_eq "$(field "$STATE" unnamed)" 0 yj-zero-register
  finish_case 06-yj "yj is a non-mutating characterwise screen motion"
fi

if start_case change-motion yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" c j Escape
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - ROW))" cj-length
  expect_eq "$(field "$STATE" regtype)" char cj-register
  expect_eq "$(field "$STATE" state)" NORMAL cj-state
  expect_eq "$(field "$STATE" onetype)" char cj-one-register
  expect_eq "$(field "$STATE" onelen)" "$ROW" cj-one-length
  finish_case 07-cj "cj changes the exclusive screen range without adding a logical line"
fi

# 08: inverse g-j remains a logical linewise operator while wrapping is on.
if start_case logicalop yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" d g j
  record_state
  expect_eq "$(field "$STATE" buflen)" 6 dgj-buffer
  expect_eq "$(field "$STATE" regtype)" line dgj-register
  finish_case 08-dgj "dgj keeps logical linewise semantics under visual wrapping"
fi

# 09: doubled operators and Y use whole screen rows with native line registers.
if start_case doubled yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" d d
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - ROW))" dd-length
  expect_eq "$(field "$STATE" regtype)" line dd-register
  expect_eq "$(field "$STATE" reglen)" "$((ROW + 1))" dd-register-length
  expect_eq "$(field "$STATE" unnamed)" 1 dd-numbered-register
  expect_eq "$(field "$STATE" dashtype)" char dd-dash-register
  expect_eq "$(field "$STATE" dashlen)" "$ROW" dd-dash-length
  expect_eq "$(field "$STATE" onetype)" line dd-one-register
  expect_eq "$(field "$STATE" onelen)" "$((ROW + 1))" dd-one-length
  before=$(report_count EMPTYEOF)
  keys "$CASE_SESSION" F10
  wait_report EMPTYEOF "$before" >/dev/null
  keys "$CASE_SESSION" d d
  record_state
  expect_eq "$(field "$STATE" buflen)" 0 empty-dd-buffer
  expect_eq "$(field "$STATE" regtype)" line empty-dd-register
  expect_eq "$(field "$STATE" reglen)" 1 empty-dd-register-length
  expect_eq "$(field "$STATE" dashtype)" char empty-dd-dash-register
  expect_eq "$(field "$STATE" dashlen)" 0 empty-dd-dash-length
  expect_eq "$(field "$STATE" onetype)" line empty-dd-one-register
  expect_eq "$(field "$STATE" onelen)" 1 empty-dd-one-length
  finish_case 09-dd "dd removes one screen row and stores newline-normalized line text"
fi

if start_case counted-double yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" 2 d d
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - 2 * ROW))" 2dd-length
  expect_eq "$(field "$STATE" regtype)" line 2dd-register
  expect_eq "$(field "$STATE" reglen)" "$((2 * ROW + 1))" 2dd-register-length
  expect_eq "$(field "$STATE" dashtype)" char 2dd-dash-register
  expect_eq "$(field "$STATE" dashlen)" "$((2 * ROW))" 2dd-dash-length
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" d 2 d
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - 2 * ROW))" d2d-length
  expect_eq "$(field "$STATE" regtype)" line d2d-register
  expect_eq "$(field "$STATE" reglen)" "$((2 * ROW + 1))" d2d-register-length
  expect_eq "$(field "$STATE" dashtype)" char d2d-dash-register
  expect_eq "$(field "$STATE" dashlen)" "$((2 * ROW))" d2d-dash-length
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" y 2 y
  record_state
  expect_eq "$(field "$STATE" buflen)" "$BASELINE" y2y-buffer
  expect_eq "$(field "$STATE" regtype)" line y2y-register
  expect_eq "$(field "$STATE" reglen)" "$((2 * ROW + 1))" y2y-register-length
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" c 2 c Escape
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - 2 * ROW))" c2c-length
  expect_eq "$(field "$STATE" regtype)" line c2c-register
  expect_eq "$(field "$STATE" state)" NORMAL c2c-state
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" d 0
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - 5))" d0-length
  expect_eq "$(field "$STATE" regtype)" char d0-register
  expect_eq "$(field "$STATE" reglen)" 5 d0-register-length
  finish_case 10-counted-dd "first- and second-position counts span exact screen rows"
fi

if start_case yy yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" y y
  record_state
  expect_eq "$(field "$STATE" buflen)" "$BASELINE" yy-buffer
  expect_eq "$(field "$STATE" regtype)" line yy-register
  expect_eq "$(field "$STATE" reglen)" "$((ROW + 1))" yy-register-length
  expect_eq "$(field "$STATE" unnamed)" 0 yy-zero-register
  finish_case 11-yy "yy yanks one screen row as newline-normalized line text"
fi

if start_case cc yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" c c Escape
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - ROW))" cc-length
  expect_eq "$(field "$STATE" regtype)" line cc-register
  expect_eq "$(field "$STATE" state)" NORMAL cc-state
  before=$(report_count EMPTYEOF)
  keys "$CASE_SESSION" F10
  wait_report EMPTYEOF "$before" >/dev/null
  keys "$CASE_SESSION" c c
  record_state
  expect_eq "$(field "$STATE" buflen)" 0 empty-cc-buffer
  expect_eq "$(field "$STATE" state)" INSERT empty-cc-state
  expect_eq "$(field "$STATE" unnamed)" 1 empty-cc-numbered-register
  expect_eq "$(field "$STATE" regtype)" line empty-cc-register
  expect_eq "$(field "$STATE" reglen)" 1 empty-cc-register-length
  expect_eq "$(field "$STATE" dashtype)" char empty-cc-dash-register
  expect_eq "$(field "$STATE" dashlen)" 0 empty-cc-dash-length
  expect_eq "$(field "$STATE" onetype)" line empty-cc-one-register
  expect_eq "$(field "$STATE" onelen)" 1 empty-cc-one-length
  finish_case 12-cc "cc changes one screen row without creating an empty logical line"
fi

if start_case big-yank yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" Y
  record_state
  expect_eq "$(field "$STATE" buflen)" "$BASELINE" Y-buffer
  expect_eq "$(field "$STATE" regtype)" line Y-register
  expect_eq "$(field "$STATE" reglen)" "$((ROW + 1))" Y-register-length
  finish_case 13-Y "Y uses the current complete screen row"
fi

# 14: D/C stop at the row edge and remain characterwise.
if start_case endops yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" D
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - ROW + 5))" D-length
  expect_eq "$(field "$STATE" regtype)" char D-register
  expect_eq "$(field "$STATE" reglen)" "$((ROW - 5))" D-register-length
  expect_eq "$(field "$STATE" onetype)" char D-one-register
  expect_eq "$(field "$STATE" onelen)" "$((ROW - 5))" D-one-length
  finish_case 14-D "D deletes through the displayed-row end characterwise"
fi

if start_case change-end yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" C Escape
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - ROW + 5))" C-length
  expect_eq "$(field "$STATE" regtype)" char C-register
  expect_eq "$(field "$STATE" onetype)" char C-one-register
  expect_eq "$(field "$STATE" onelen)" "$((ROW - 5))" C-one-length
  keys "$CASE_SESSION" Escape
  before=$(report_count EMPTY)
  keys "$CASE_SESSION" F12
  EMPTY=$(wait_report EMPTY "$before")
  EMPTY_BASE=$(field "$EMPTY" baseline)
  keys "$CASE_SESSION" C
  tmux_cmd send-keys -t "$CASE_SESSION" -l X
  record_state
  expect_eq "$(field "$STATE" buflen)" "$EMPTY_BASE" empty-C-buffer
  expect_eq "$(field "$STATE" state)" INSERT empty-C-state
  expect_eq "$(field "$STATE" line)" 2 empty-C-line
  expect_eq "$(field "$STATE" unnamed)" 1 empty-C-numbered-register
  expect_eq "$(field "$STATE" regtype)" char empty-C-register
  expect_eq "$(field "$STATE" reglen)" 1 empty-C-register-length
  expect_eq "$(field "$STATE" dashlen)" "$((ROW - 5))" empty-C-no-small-delete
  expect_contains "$(field "$STATE" text)" 'first\nXthird\n' empty-C-text
  keys "$CASE_SESSION" Escape
  reset_wrapped_case
  setup_key F11
  keys "$CASE_SESSION" c 0
  record_state
  expect_eq "$(field "$STATE" buflen)" "$BASELINE" bol-c0-buffer
  expect_eq "$(field "$STATE" state)" INSERT bol-c0-state
  expect_eq "$(field "$STATE" unnamed)" - bol-c0-small-register
  expect_eq "$(field "$STATE" regtype)" char bol-c0-register
  expect_eq "$(field "$STATE" reglen)" 0 bol-c0-register-length
  expect_eq "$(field "$STATE" dashtype)" char bol-c0-dash-register
  expect_eq "$(field "$STATE" dashlen)" 0 bol-c0-dash-length
  expect_eq "$(field "$STATE" onetype)" char bol-c0-one-register
  expect_eq "$(field "$STATE" onelen)" 0 bol-c0-one-length
  finish_case 15-C "C and c0 enter Insert even on empty ranges"
fi

# 16: V owns a distinct screen-line range in both directions.
if start_case visual yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" V
  record_state
  expect_eq "$(field "$STATE" visual)" screen-line V-type
  expect_eq "$(field "$STATE" range)" "${SECOND}:${THIRD}" V-range
  keys "$CASE_SESSION" j
  record_state
  expect_eq "$(field "$STATE" range)" "${SECOND}:${FOURTH}" Vj-range
  setup_key F2
  keys "$CASE_SESSION" V k
  record_state
  expect_eq "$(field "$STATE" range)" "1:${THIRD}" Vk-range
  finish_case 16-visual-range "V, Vj, and Vk select exact complete displayed rows"
fi

if start_case visual-yank yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" V y
  record_state
  expect_eq "$(field "$STATE" visual)" none Vy-exit
  expect_eq "$(field "$STATE" regtype)" line Vy-register
  expect_eq "$(field "$STATE" reglen)" "$((ROW + 1))" Vy-register-length
  setup_key F2
  keys "$CASE_SESSION" v j
  record_state
  expect_eq "$(field "$STATE" visual)" char vj-type
  finish_case 17-visual-operators "V-y is linewise while ordinary v-j remains characterwise"
fi

# 18: disabling wrapping restores logical j/dd/V and exclusive gj.
if start_case truncated no; then
  CASE_OK=1
  setup_key F3
  keys "$CASE_SESSION" d j
  record_state
  expect_eq "$(field "$STATE" buflen)" 6 truncated-dj-buffer
  expect_eq "$(field "$STATE" regtype)" line truncated-dj-register
  finish_case 18-truncated-dj "without wrapping dj is logical and linewise"
fi

if start_case truncated-gj no; then
  CASE_OK=1
  setup_key F3
  keys "$CASE_SESSION" d g j
  record_state
  expect_eq "$(field "$STATE" regtype)" char truncated-dgj-register
  keys "$CASE_SESSION" u
  setup_key F3
  keys "$CASE_SESSION" V
  record_state
  expect_eq "$(field "$STATE" visual)" line truncated-V-type
  expect_eq "$(field "$STATE" range)" "1:${LOGICAL2}" truncated-V-range
  finish_case 19-truncated-inverse "without wrapping dgj stays exclusive and V stays logical-line"
fi

# 20: landing at logical BOL promotes a counted screen motion exactly like Evil.
if start_case promotion yes; then
  CASE_OK=1
  setup_key F4
  keys "$CASE_SESSION" d 4 j
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - 3 * ROW - 8))" promoted-length
  expect_eq "$(field "$STATE" regtype)" line promoted-register
  finish_case 20-exclusive-promotion "screen motion landing at BOL promotes the preceding logical line"
fi

# 21: line register paste, undo, and redo retain screen-row semantics.
if start_case paste yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" y y p
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE + ROW + 1))" paste-length
  expect_eq "$(field "$STATE" regtype)" line paste-register
  finish_case 21-paste "p inserts a screen-line yank as a new logical line"
fi

if start_case undo yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" d d u
  record_state
  expect_eq "$(field "$STATE" buflen)" "$BASELINE" undo-length
  keys "$CASE_SESSION" C-r
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - ROW))" redo-length
  finish_case 22-undo-redo "one u restores and one C-r reapplies the screen-row edit"
fi

# 23: display columns honor CJK width and tab-width=4 without invalid landings.
if start_case widths no; then
  CASE_OK=1
  before=$(report_count WIDTHS)
  keys "$CASE_SESSION" F7
  WIDTHS=$(wait_report WIDTHS "$before")
  WIDTH_SECOND=$(field "$WIDTHS" second)
  WIDTH_THIRD=$(field "$WIDTHS" third)
  setup_key F8
  keys "$CASE_SESSION" j
  record_state
  expect_eq "$(field "$STATE" point)" "$WIDTH_SECOND" cjk-point
  expect_eq "$(field "$STATE" vcol)" 0 cjk-column
  setup_key F8
  keys "$CASE_SESSION" j k
  record_state
  expect_eq "$(field "$STATE" point)" 2 cjk-roundtrip
  setup_key F9
  keys "$CASE_SESSION" j
  record_state
  expect_eq "$(field "$STATE" point)" "$((WIDTH_THIRD + 2))" tab-point
  expect_eq "$(field "$STATE" vcol)" 2 tab-column
  finish_case 23-widths "CJK cells and tab-width=4 preserve valid display columns"
fi

# 24: Lispyville keeps unmatched delimiters and its current char-register quirk.
if start_case structural no lisp; then
  CASE_OK=1
  before=$(report_count STRUCT)
  keys "$CASE_SESSION" F10
  STRUCT=$(wait_report STRUCT "$before")
  STRUCT_ROW=$(field "$STRUCT" row)
  STRUCT_BASE=$(field "$STRUCT" baseline)
  setup_key F11
  keys "$CASE_SESSION" d d
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((STRUCT_BASE - STRUCT_ROW + 1))" structural-length
  expect_eq "$(field "$STATE" regtype)" char structural-register
  expect_contains "$(field "$STATE" text)" '(' structural-opener
  finish_case 24-structural "wrapped Lisp dd is delimiter-safe and preserves Lispyville register behavior"
fi

# 25: excessive counts clamp to BOF/EOF instead of aborting the operator.
if start_case boundaries yes; then
  CASE_OK=1
  setup_key F2
  keys "$CASE_SESSION" d 9 9 9 j
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((SECOND + 4))" excessive-forward
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" d 9 9 9 k
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((BASELINE - SECOND - 4))" excessive-backward
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" d 9 9 9 '$'
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((SECOND + 4))" excessive-end
  reset_wrapped_case
  setup_key F2
  keys "$CASE_SESSION" 9 9 9 d d
  record_state
  expect_eq "$(field "$STATE" buflen)" "$((SECOND - 1))" excessive-screen-dd
  reset_unwrapped_case
  setup_key F3
  keys "$CASE_SESSION" 9 9 9 d d
  record_state
  expect_eq "$(field "$STATE" buflen)" 0 excessive-logical-dd
  finish_case 25-boundaries "excessive screen/logical counts clamp at BOF and EOF"
fi

# 26: disabling wrapping retains Evil's empty logical-line register semantics.
if start_case logical-empty no; then
  CASE_OK=1
  before=$(report_count EMPTYEOF)
  keys "$CASE_SESSION" F10
  wait_report EMPTYEOF "$before" >/dev/null
  keys "$CASE_SESSION" Space y v y y
  record_state
  expect_eq "$(field "$STATE" wrap)" no empty-logical-yy-wrap
  expect_eq "$(field "$STATE" buflen)" 0 empty-logical-yy-buffer
  expect_eq "$(field "$STATE" unnamed)" 0 empty-logical-yy-zero
  expect_eq "$(field "$STATE" regtype)" line empty-logical-yy-register
  expect_eq "$(field "$STATE" reglen)" 1 empty-logical-yy-length
  before=$(report_count EMPTYEOF)
  keys "$CASE_SESSION" F10
  wait_report EMPTYEOF "$before" >/dev/null
  keys "$CASE_SESSION" Space y v d d
  record_state
  expect_eq "$(field "$STATE" wrap)" no empty-logical-dd-wrap
  expect_eq "$(field "$STATE" buflen)" 0 empty-logical-dd-buffer
  expect_eq "$(field "$STATE" unnamed)" 1 empty-logical-dd-one
  expect_eq "$(field "$STATE" regtype)" line empty-logical-dd-register
  expect_eq "$(field "$STATE" reglen)" 1 empty-logical-dd-length
  expect_eq "$(field "$STATE" dashtype)" char empty-logical-dd-dash
  expect_eq "$(field "$STATE" dashlen)" 0 empty-logical-dd-dash-length
  before=$(report_count EMPTYEOF)
  keys "$CASE_SESSION" F10
  wait_report EMPTYEOF "$before" >/dev/null
  keys "$CASE_SESSION" Space y v c c
  tmux_cmd send-keys -t "$CASE_SESSION" -l X
  record_state
  expect_eq "$(field "$STATE" wrap)" no empty-logical-cc-wrap
  expect_eq "$(field "$STATE" buflen)" 2 empty-logical-cc-buffer
  expect_eq "$(field "$STATE" state)" INSERT empty-logical-cc-state
  expect_eq "$(field "$STATE" regtype)" line empty-logical-cc-register
  expect_eq "$(field "$STATE" reglen)" 1 empty-logical-cc-length
  expect_eq "$(field "$STATE" dashtype)" char empty-logical-cc-dash
  expect_eq "$(field "$STATE" dashlen)" 0 empty-logical-cc-dash-length
  expect_contains "$(field "$STATE" text)" 'X\n' empty-logical-cc-text
  before=$(report_count EMPTYEOF)
  keys "$CASE_SESSION" F10
  wait_report EMPTYEOF "$before" >/dev/null
  keys "$CASE_SESSION" Space y v i
  tmux_cmd send-keys -t "$CASE_SESSION" -l abc
  keys "$CASE_SESSION" Escape c c
  tmux_cmd send-keys -t "$CASE_SESSION" -l X
  record_state
  expect_eq "$(field "$STATE" wrap)" no unterminated-cc-wrap
  expect_eq "$(field "$STATE" buflen)" 2 unterminated-cc-buffer
  expect_eq "$(field "$STATE" state)" INSERT unterminated-cc-state
  expect_eq "$(field "$STATE" regtype)" line unterminated-cc-register
  expect_eq "$(field "$STATE" reglen)" 4 unterminated-cc-register-length
  expect_eq "$(field "$STATE" text)" 'X\n' unterminated-cc-text
  finish_case 26-logical-empty "wrap-off empty and unterminated yy/dd/cc retain Evil line semantics"
fi

# 27: prose wraps before a whole word, with navigation matching the drawing.
if start_case word-boundary no word; then
  CASE_OK=1
  before=$(report_count WORD)
  keys "$CASE_SESSION" F12
  WORD=$(wait_report WORD "$before")
  WORD_BOUNDARY=$(field "$WORD" boundary)
  WORD_HARD=$(field "$WORD" hard)
  WORD_PREFIX=$(field "$WORD" prefix)
  WORD_SPACES=$(( $(field "$WORD" row) - WORD_PREFIX ))
  printf -v WORD_EDGE_PATTERN 'a{%d} {%d}\\\\$' \
    "$WORD_PREFIX" "$WORD_SPACES"
  SCREEN=$(lem_capture "$CASE_SESSION")
  expect_contains "$SCREEN" 'bbbbbbbbbbbb' rendered-whole-word
  expect_matches "$SCREEN" "$WORD_EDGE_PATTERN" continuation-marker-at-edge
  keys "$CASE_SESSION" j
  record_state
  expect_eq "$(field "$STATE" point)" "$WORD_BOUNDARY" word-navigation-boundary
  expect_eq "$(field "$STATE" vcol)" 0 word-navigation-column
  if [ "$WORD_BOUNDARY" = "$WORD_HARD" ]; then
    CASE_OK=0
    printf '  expected word boundary %s to differ from hard boundary %s\n' \
      "$WORD_BOUNDARY" "$WORD_HARD" >&2
  fi
  keys "$CASE_SESSION" k
  record_state
  expect_eq "$(field "$STATE" point)" 1 word-navigation-roundtrip
  finish_case 27-word-boundary "renderer and screen motions share the Emacs-style prose boundary"
fi

if [ "$FAILED" = 0 ]; then
  printf '\nSCREEN LINE TEST PASSED\n'
else
  printf '\nSCREEN LINE TEST FAILED\n' >&2
fi
exit "$FAILED"
