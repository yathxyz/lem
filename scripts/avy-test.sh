#!/usr/bin/env bash
# Real-ncurses parity coverage for the configured Evil/Avy leader motions.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-avy-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-avy.XXXXXX")"
sessions=()

cleanup() {
  local session
  if declare -F lem_stop >/dev/null; then
    for session in "${sessions[@]:-}"; do
      [ -n "$session" ] && lem_stop "$session" || true
    done
  fi
  case "${root:-}" in
    */lem-yath-avy.*) [ -d "$root" ] && rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe Avy cleanup path: %s\n' "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_AVY_REPORT="$root/report"
export LEM_YATH_AVY_SOURCE="$here/lem-yath/src/avy.lisp"
export LEM_TUI_WIDTH="${LEM_TUI_WIDTH:-100}"
export LEM_TUI_HEIGHT="${LEM_TUI_HEIGHT:-30}"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$root/fixtures"
: >"$LEM_YATH_AVY_REPORT"

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
KEY_DELAY="${KEY_DELAY:-0.16}"

failed=0
declare -A started

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }

fail() {
  local name=$1 detail=$2 session=${3:-}
  failed=1
  printf 'FAIL  %-28s %s\n' "$name" "$detail" >&2
  if [ -n "$session" ]; then
    printf '\n--- screen (%s) ---\n' "$session" >&2
    lem_capture "$session" >&2 || true
    printf '\n--- attributes ---\n' >&2
    tmux_cmd capture-pane -t "$session" -p -e 2>/dev/null \
      | sed -n '1,18p' | sed -n l >&2 || true
  fi
  printf '\n--- report ---\n' >&2
  tail -80 "$LEM_YATH_AVY_REPORT" >&2 || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_AVY_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/avy-fixture.lisp")"

start_session() {
  local session=$1 file=$2 sentinel=$3 ready_before
  ready_before=$(report_count '^READY$')
  sessions+=("$session")
  if ! lem_start_lem-yath_eval "$session" "(load #P$fixture_lisp)" "$file"; then
    fail boot "failed to launch configured Lem" ""
    return 1
  fi
  started["$session"]=1
  tmux_cmd set-option -t "$session" remain-on-exit on
  if ! wait_report_count '^READY$' "$((ready_before + 1))" "$BOOT_TIMEOUT" ||
     ! lem_wait_for "$session" "$sentinel" "$BOOT_TIMEOUT" >/dev/null ||
     ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null; then
    fail boot "configured Lem did not become ready" "$session"
    return 1
  fi
  sleep 0.35
  lem_keys "$session" Escape
  sleep 0.35
  send_keys "$session" g g 0
}

stop_session() {
  local session=$1 dead status
  [ "${started[$session]:-0}" = 1 ] || return 0
  if tmux_cmd has-session -t "$session" 2>/dev/null; then
    dead=$(tmux_cmd display-message -p -t "$session" '#{pane_dead}')
    status=$(tmux_cmd display-message -p -t "$session" '#{pane_dead_status}')
    if [ "$dead" = 1 ]; then
      fail child-exit "Lem exited with status ${status:-unknown}" "$session"
    fi
  else
    fail child-exit "tmux session disappeared before teardown" ""
  fi
  lem_stop "$session" || true
  started["$session"]=0
}

send_keys() {
  local session=$1 key
  shift
  for key in "$@"; do
    if [ "${#key}" = 1 ]; then
      tmux_cmd send-keys -t "$session" -l "$key"
    else
      lem_keys "$session" "$key"
    fi
    sleep "$KEY_DELAY"
  done
}

record_state() {
  local session=$1 before
  before=$(report_count '^STATE ')
  lem_keys "$session" F12
  wait_report_count '^STATE ' "$((before + 1))"
}

last_state() { grep '^STATE ' "$LEM_YATH_AVY_REPORT" | tail -1; }
last_active() { grep '^ACTIVE ' "$LEM_YATH_AVY_REPORT" | tail -1; }

assert_state() {
  local name=$1 expected=$2 session=$3 state
  state=$(last_state)
  if grep -qE "$expected" <<<"$state"; then
    pass "$name" "$state"
  else
    fail "$name" "state did not match /$expected/: $state" "$session"
  fi
}

assert_last_active() {
  local name=$1 expected=$2 session=$3 active
  active=$(last_active)
  if grep -qE "$expected" <<<"$active"; then
    pass "$name" "$active"
  else
    fail "$name" "active labels did not match /$expected/: $active" "$session"
  fi
}

body_attributes() {
  tmux_cmd capture-pane -t "$1" -p -e | sed -n '1,24p'
}

attribute_count() {
  (LC_ALL=C grep -aoE '48;5;94m' || true) | wc -l | tr -d ' '
}

wait_attribute_count() {
  local session=$1 minimum=$2 timeout=${3:-$WAIT_TIMEOUT} index=0 count=0
  while ((index < timeout * 10)); do
    count=$(attribute_count <<<"$(body_attributes "$session")")
    if ((count >= minimum)); then
      printf '%s\n' "$count"
      return 0
    fi
    sleep 0.1
    index=$((index + 1))
  done
  printf '%s\n' "$count"
  return 1
}

wait_no_avy_attributes() {
  local session=$1 timeout=${2:-$WAIT_TIMEOUT} index=0 count=0
  while ((index < timeout * 10)); do
    count=$(attribute_count <<<"$(body_attributes "$session")")
    if ((count == 0)); then
      return 0
    fi
    sleep 0.1
    index=$((index + 1))
  done
  return 1
}

multi_file="$root/fixtures/multi.txt"
symbol_file="$root/fixtures/symbols.lisp"
line_file="$root/fixtures/lines.txt"
wrap_file="$root/fixtures/wrap.txt"
actions_file="$root/fixtures/actions.txt"

for number in $(seq 1 12); do
  printf 'x-target-%02d alpha beta\n' "$number"
done >"$multi_file"

printf 'axle xray Xeno | xlast\none-two -- | -end\n' >"$symbol_file"

for number in $(seq 1 15); do
  if [ "$number" = 7 ]; then
    printf 'line %02d sole-v\n' "$number"
  else
    printf 'line %02d alpha\n' "$number"
  fi
done >"$line_file"

{
  printf 'x\t'
  head -c 140 /dev/zero | tr '\0' w
  printf '\tx-end\nx-hidden\nx-visible\n'
} >"$wrap_file"

printf 'ORIGIN|\nalpha qone tail\nbeta qtwo tail\n' >"$actions_file"

# Static contracts, exact 12 -> 4 label narrowing, composited ncurses output,
# jump history, cancellation, resize cleanup, reload, and read-only invariants.
primary="lem-yath-avy-primary-$id"
if start_session "$primary" "$multi_file" 'x-target-01'; then
  static_before=$(report_count '^STATIC ')
  lem_keys "$primary" F11
  if wait_report_count '^STATIC ' "$((static_before + 1))" &&
     tail -1 "$LEM_YATH_AVY_REPORT" \
       | grep -qE '^STATIC bindings=yes motions=yes tree=yes dispatch=yes defaults=yes attribute=yes failures=0$'; then
    pass static-contracts "bindings, motion types, tree, defaults, and face agree"
  else
    fail static-contracts "static contracts diverged" "$primary"
  fi

  reload_before=$(report_count '^RELOAD ')
  lem_keys "$primary" F10
  wait_report_count '^RELOAD ' "$((reload_before + 1))" || true
  lem_keys "$primary" F10
  if wait_report_count '^RELOAD ' "$((reload_before + 2))" &&
     [ "$(grep -c '^RELOAD bindings=yes motions=yes labels=0 buffers=0$' "$LEM_YATH_AVY_REPORT")" -ge 2 ] &&
     ! grep -q '^RELOAD ERROR' "$LEM_YATH_AVY_REPORT"; then
    pass reload-idempotence "two live source reloads retained clean bindings"
  else
    fail reload-idempotence "reload lost bindings or retained labels" "$primary"
  fi

  snapshot_before=$(report_count '^SNAPSHOT ')
  lem_keys "$primary" F9
  wait_report_count '^SNAPSHOT ' "$((snapshot_before + 1))" ||
    fail snapshot "source snapshot was not recorded" "$primary"

  active_before=$(report_count '^ACTIVE ')
  send_keys "$primary" ' ' a x
  labels=$(wait_attribute_count "$primary" 12 || true)
  screen=$(lem_capture "$primary")
  if ((labels >= 12)) &&
     grep -qE '^a-target-01 alpha beta$' <<<"$screen" &&
     grep -qE '^latarget-09 alpha beta$' <<<"$screen" &&
     grep -qE '^lstarget-10 alpha beta$' <<<"$screen" &&
     ! grep -q 'lem-yath-avy-goto-char' <<<"$screen"; then
    pass label-rendering "12 bold lead labels replace target cells without Which-Key leakage"
  else
    fail label-rendering "initial labels were not composited at exact target cells" "$primary"
  fi

  send_keys "$primary" l
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  if wait_attribute_count "$primary" 4 >/dev/null &&
     lem_capture "$primary" | grep -qE '^a-target-09 alpha beta$' &&
     lem_capture "$primary" | grep -qE '^s-target-10 alpha beta$'; then
    assert_last_active multikey-tree \
      'key=l labels=12 buffers=1 frame-floats=12 map=a@1@multi.txt@[^,]+,s@24@multi.txt@[^,]+,d@47@multi.txt@[^,]+,f@70@multi.txt@[^,]+,g@93@multi.txt@[^,]+,h@116@multi.txt@[^,]+,j@139@multi.txt@[^,]+,k@162@multi.txt@[^,]+,la@185@multi.txt@[^,]+,ls@208@multi.txt@[^,]+,ld@231@multi.txt@[^,]+,lf@254@multi.txt@' \
      "$primary"
  else
    fail narrowed-rendering "four suffix labels were not redrawn after l" "$primary"
  fi

  send_keys "$primary" s
  wait_report_count '^ACTIVE ' "$((active_before + 2))" || true
  assert_last_active narrowed-tree \
    'key=s labels=4 buffers=1 frame-floats=4 map=a@185@multi.txt@[^,]+,s@208@multi.txt@[^,]+,d@231@multi.txt@[^,]+,f@254@multi.txt@' \
    "$primary"

  compare_before=$(report_count '^INVARIANTS ')
  lem_keys "$primary" F8
  if wait_report_count '^INVARIANTS ' "$((compare_before + 1))" &&
     grep '^INVARIANTS ' "$LEM_YATH_AVY_REPORT" | tail -1 \
       | grep -q '^INVARIANTS same=yes changes=0 labels=0 buffers=0$'; then
    pass source-invariants "text, undo, overlays, modified tick, and hooks stayed unchanged"
  else
    fail source-invariants "display labels mutated source state" "$primary"
  fi
  record_state "$primary" || fail record "state recorder timed out" "$primary"
  assert_state char-jump \
    'point=208 line=10 column=0 char=x .*state=NORMAL active=no labels=0 label-buffers=0 frame-floats=0' \
    "$primary"

  send_keys "$primary" C-o
  record_state "$primary" || fail record "state recorder timed out" "$primary"
  assert_state jumplist-return 'point=1 line=1 column=0 char=x ' "$primary"

  send_keys "$primary" g g 0
  active_before=$(report_count '^ACTIVE ')
  send_keys "$primary" ' ' a x
  wait_attribute_count "$primary" 12 >/dev/null || true
  send_keys "$primary" z
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  wait_attribute_count "$primary" 12 >/dev/null || true
  send_keys "$primary" Escape
  wait_report_count '^ACTIVE ' "$((active_before + 2))" || true
  if wait_no_avy_attributes "$primary"; then
    assert_last_active invalid-and-cancel \
      'key=Escape labels=12 buffers=1 frame-floats=[0-9]+' "$primary"
  else
    fail invalid-and-cancel "Escape left visible Avy labels" "$primary"
  fi

  send_keys "$primary" g g 0
  resize_active_before=$(report_count '^ACTIVE ')
  send_keys "$primary" ' ' a x
  wait_attribute_count "$primary" 12 >/dev/null || true
  tmux_cmd resize-window -t "$primary" -x 110 -y 30
  # The resize hook only marks the session stale.  The next input aborts after
  # Lem has completed its whole layout update, avoiding a partial frame resize.
  send_keys "$primary" Escape
  wait_report_count '^ACTIVE ' "$((resize_active_before + 1))" || true
  if wait_no_avy_attributes "$primary"; then
    assert_last_active resize-stale-path \
      'key=Escape labels=12 .*stale=yes$' "$primary"
    record_state "$primary" || fail record "state recorder timed out" "$primary"
    assert_state resize-cleanup \
      'active=no labels=0 label-buffers=0 frame-floats=0' "$primary"
  else
    send_keys "$primary" Escape
    fail resize-cleanup "terminal resize did not abort stale absolute labels" "$primary"
  fi
  tmux_cmd resize-window -t "$primary" -x "$LEM_TUI_WIDTH" -y "$LEM_TUI_HEIGHT"

  read_only_before=$(report_count '^READ-ONLY ')
  lem_keys "$primary" F3
  wait_report_count '^READ-ONLY ' "$((read_only_before + 1))" || true
  send_keys "$primary" g g 0
  snapshot_before=$(report_count '^SNAPSHOT ')
  lem_keys "$primary" F9
  wait_report_count '^SNAPSHOT ' "$((snapshot_before + 1))" || true
  send_keys "$primary" ' ' a x
  wait_attribute_count "$primary" 12 >/dev/null || true
  send_keys "$primary" s
  compare_before=$(report_count '^INVARIANTS ')
  lem_keys "$primary" F8
  wait_report_count '^INVARIANTS ' "$((compare_before + 1))" || true
  record_state "$primary" || fail record "state recorder timed out" "$primary"
  if grep '^INVARIANTS ' "$LEM_YATH_AVY_REPORT" | tail -1 \
       | grep -q '^INVARIANTS same=yes changes=0 labels=0 buffers=0$'; then
    assert_state read-only-jump \
      'line=2 column=0 char=x .*active=no labels=0 label-buffers=0 frame-floats=0 .*read-only=yes' \
      "$primary"
  else
    fail read-only-jump "read-only source invariants changed" "$primary"
  fi
fi
stop_session "$primary"

# Character labels are closest-first and case-folded; symbol labels use Lisp
# syntax boundaries, while printable punctuation deliberately bypasses them.
symbols="lem-yath-avy-symbols-$id"
if start_session "$symbols" "$symbol_file" 'axle xray Xeno'; then
  snapshot_before=$(report_count '^SNAPSHOT ')
  lem_keys "$symbols" F9
  wait_report_count '^SNAPSHOT ' "$((snapshot_before + 1))" || true

  marker_before=$(report_count '^MARKER ')
  lem_keys "$symbols" F7
  wait_report_count '^MARKER ' "$((marker_before + 1))" || true
  active_before=$(report_count '^ACTIVE ')
  send_keys "$symbols" ' ' a x
  wait_attribute_count "$symbols" 4 >/dev/null || true
  send_keys "$symbols" a
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  assert_last_active char-order \
    'key=a labels=4 .*map=a@[0-9]+@symbols.lisp@[^,]+,s@[0-9]+@symbols.lisp@[^,]+,d@[0-9]+@symbols.lisp@[^,]+,f@[0-9]+@symbols.lisp@' \
    "$symbols"
  record_state "$symbols" || fail record "state recorder timed out" "$symbols"
  assert_state closest-casefold 'line=1 column=17 char=x ' "$symbols"

  lem_keys "$symbols" F7
  wait_report_count '^MARKER ' "$((marker_before + 2))" || true
  active_before=$(report_count '^ACTIVE ')
  send_keys "$symbols" ' ' s x
  wait_attribute_count "$symbols" 3 >/dev/null || true
  send_keys "$symbols" s
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  assert_last_active symbol-boundaries \
    'key=s labels=3 .*map=a@[0-9]+@symbols.lisp@[^,]+,s@[0-9]+@symbols.lisp@[^,]+,d@[0-9]+@symbols.lisp@' \
    "$symbols"
  record_state "$symbols" || fail record "state recorder timed out" "$symbols"
  assert_state symbol-jump 'line=1 column=10 char=X ' "$symbols"

  last_marker_before=$(report_count '^LAST-MARKER ')
  lem_keys "$symbols" F2
  wait_report_count '^LAST-MARKER ' "$((last_marker_before + 1))" || true
  active_before=$(report_count '^ACTIVE ')
  send_keys "$symbols" ' ' s -
  wait_attribute_count "$symbols" 4 >/dev/null || true
  send_keys "$symbols" d
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  record_state "$symbols" || fail record "state recorder timed out" "$symbols"
  assert_state punctuation-symbol 'line=2 column=9 char=- ' "$symbols"

  compare_before=$(report_count '^INVARIANTS ')
  lem_keys "$symbols" F8
  if wait_report_count '^INVARIANTS ' "$((compare_before + 1))" &&
     grep '^INVARIANTS ' "$LEM_YATH_AVY_REPORT" | tail -1 \
       | grep -q '^INVARIANTS same=yes changes=0 labels=0 buffers=0$'; then
    pass symbol-invariants "character and symbol jumps did not mutate Lisp source"
  else
    fail symbol-invariants "symbol selection changed source state" "$symbols"
  fi
fi
stop_session "$symbols"

# Line selection supports numeric fallback; zero candidates return in place and
# one candidate jumps without rendering a label tree.
lines="lem-yath-avy-lines-$id"
if start_session "$lines" "$line_file" 'line 01 alpha'; then
  active_before=$(report_count '^ACTIVE ')
  send_keys "$lines" ' ' l
  wait_attribute_count "$lines" 15 >/dev/null || true
  send_keys "$lines" 1
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  if lem_wait_for "$lines" 'Goto line:' "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$lines" 2 Enter
    record_state "$lines" || fail record "state recorder timed out" "$lines"
    assert_state numeric-line-fallback \
      'line=12 column=0 char=l .*state=NORMAL active=no' "$lines"
  else
    send_keys "$lines" Escape
    fail numeric-line-fallback "numeric selector did not open Goto line" "$lines"
  fi

  send_keys "$lines" g g 0 ' ' l
  wait_attribute_count "$lines" 15 >/dev/null || true
  send_keys "$lines" 1 BSpace 5 Enter
  record_state "$lines" || fail record "state recorder timed out" "$lines"
  assert_state numeric-line-editing \
    'line=5 column=0 char=l .*state=NORMAL active=no labels=0' "$lines"

  send_keys "$lines" g g 0 ' ' l
  wait_attribute_count "$lines" 15 >/dev/null || true
  send_keys "$lines" 1 C-g
  record_state "$lines" || fail record "state recorder timed out" "$lines"
  assert_state numeric-line-cancel \
    'line=1 column=0 char=l .*state=NORMAL active=no labels=0' "$lines"

  send_keys "$lines" g g 0
  send_keys "$lines" ' ' a v
  record_state "$lines" || fail record "state recorder timed out" "$lines"
  assert_state single-autojump \
    'line=7 column=13 char=v .*active=no labels=0 label-buffers=0 frame-floats=0' \
    "$lines"

  send_keys "$lines" g g 0
  send_keys "$lines" ' ' a z
  record_state "$lines" || fail record "state recorder timed out" "$lines"
  assert_state zero-candidates \
    'line=1 column=0 char=l .*active=no labels=0 label-buffers=0 frame-floats=0' \
    "$lines"

  send_keys "$lines" ' ' a C-g
  record_state "$lines" || fail record "state recorder timed out" "$lines"
  assert_state target-cancel \
    'line=1 column=0 char=l .*active=no labels=0 label-buffers=0 frame-floats=0' \
    "$lines"

  send_keys "$lines" 5 ' ' l
  record_state "$lines" || fail record "state recorder timed out" "$lines"
  assert_state counted-line-direct \
    'line=5 column=0 char=l .*state=NORMAL active=no labels=0' "$lines"
fi
stop_session "$lines"

# Stock Avy dispatch keys restart the full selector, then act on the selected
# expression while preserving the original window/point where appropriate.
actions="lem-yath-avy-actions-$id"
if start_session "$actions" "$actions_file" 'ORIGIN|'; then
  marker_before=$(report_count '^MARKER ')
  lem_keys "$actions" F7
  wait_report_count '^MARKER ' "$((marker_before + 1))" || true

  send_keys "$actions" ' ' a q '?'
  if lem_wait_for "$actions" \
       'x: kill-move.*X: kill-stay.*i: ispell.*z: zap-to-ch' \
       "$WAIT_TIMEOUT" >/dev/null; then
    pass dispatch-help "stock action keys are shown without leaving selection"
  else
    fail dispatch-help "dispatch help was not shown" "$actions"
  fi
  send_keys "$actions" n s
  record_state "$actions" || fail record "copy action state timed out" "$actions"
  assert_state dispatch-copy \
    'point=7 .*mark=no:-1 kill=qtwo .*text=ORIGIN\|\\nalpha qone tail\\nbeta qtwo tail\\n' \
    "$actions"

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q y s
  record_state "$actions" || fail record "yank action state timed out" "$actions"
  assert_state dispatch-yank \
    'kill=qtwo .*text=ORIGINqtwo\|\\nalpha qone tail\\nbeta qtwo tail\\n' \
    "$actions"
  send_keys "$actions" u

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q Y s
  record_state "$actions" || fail record "yank-line action state timed out" "$actions"
  assert_state dispatch-yank-line \
    'kill=qtwo tail .*text=ORIGINqtwo tail\|\\nalpha qone tail\\nbeta qtwo tail\\n' \
    "$actions"
  send_keys "$actions" u

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q x s
  record_state "$actions" || fail record "kill-move action state timed out" "$actions"
  assert_state dispatch-kill-move \
    'line=3 column=5 char=  .*kill=qtwo .*text=ORIGIN\|\\nalpha qone tail\\nbeta  tail\\n' \
    "$actions"
  send_keys "$actions" u

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q X s
  record_state "$actions" || fail record "kill-stay action state timed out" "$actions"
  assert_state dispatch-kill-stay \
    'point=7 .*kill=qtwo .*text=ORIGIN\|\\nalpha qone tail\\nbeta tail\\n' \
    "$actions"
  send_keys "$actions" u

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q t s
  record_state "$actions" || fail record "teleport action state timed out" "$actions"
  assert_state dispatch-teleport \
    'kill=qtwo .*text=ORIGINqtwo\|\\nalpha qone tail\\nbeta tail\\n' \
    "$actions"
  send_keys "$actions" u

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q m s
  record_state "$actions" || fail record "mark action state timed out" "$actions"
  assert_state dispatch-mark \
    'line=3 column=9 char=  .*mark=yes:[0-9]+ .*text=ORIGIN\|\\nalpha qone tail\\nbeta qtwo tail\\n' \
    "$actions"
  send_keys "$actions" Escape

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q i s
  if lem_wait_for "$actions" 'spell correction is unavailable' "$WAIT_TIMEOUT" \
       >/dev/null; then
    pass dispatch-ispell-unavailable \
      "stock key reports the missing configured spell backend"
  else
    fail dispatch-ispell-unavailable "missing backend was not explicit" "$actions"
  fi
  record_state "$actions" || fail record "ispell action state timed out" "$actions"
  assert_state dispatch-ispell-invariants \
    'point=7 .*text=ORIGIN\|\\nalpha qone tail\\nbeta qtwo tail\\n' \
    "$actions"

  lem_keys "$actions" F7
  send_keys "$actions" ' ' a q z s
  record_state "$actions" || fail record "zap action state timed out" "$actions"
  assert_state dispatch-zap \
    'kill=\|\\nalpha qone tail\\nbeta  .*text=ORIGINqtwo tail\\n' \
    "$actions"
fi
stop_session "$actions"

# Normal state sees all text windows; Evil visual state remains current-window
# only.  The two windows deliberately show the same source to make counts exact.
scope="lem-yath-avy-scope-$id"
if start_session "$scope" "$multi_file" 'x-target-01'; then
  split_before=$(report_count '^SPLIT ')
  lem_keys "$scope" F6
  wait_report_count '^SPLIT ' "$((split_before + 1))" || true

  active_before=$(report_count '^ACTIVE ')
  send_keys "$scope" ' ' a x
  wait_attribute_count "$scope" 24 >/dev/null || true
  send_keys "$scope" f
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  assert_last_active normal-all-windows \
    'key=f labels=24 buffers=1 frame-floats=24' "$scope"
  record_state "$scope" || fail record "state recorder timed out" "$scope"
  assert_state cross-window-selection \
    'line=2 column=0 char=x .*window=1 state=NORMAL active=no labels=0' "$scope"

  send_keys "$scope" C-w h
  record_state "$scope" || fail record "state recorder timed out" "$scope"
  assert_state return-left-window \
    'line=1 column=0 char=x .*window=0 state=NORMAL active=no labels=0' "$scope"

  prefixed_before=$(report_count '^ACTIVE ')
  send_keys "$scope" 4 ' ' a x
  wait_attribute_count "$scope" 12 >/dev/null || true
  send_keys "$scope" Escape
  wait_report_count '^ACTIVE ' "$((prefixed_before + 1))" || true
  assert_last_active prefixed-normal-current-window \
    'key=Escape labels=12 buffers=1 frame-floats=12' "$scope"

  sleep 0.35
  visual_before=$(report_count '^ACTIVE ')
  send_keys "$scope" v ' ' a x
  wait_attribute_count "$scope" 12 >/dev/null || true
  send_keys "$scope" Escape
  wait_report_count '^ACTIVE ' "$((visual_before + 1))" || true
  assert_last_active visual-current-window \
    'key=Escape labels=12 buffers=1 frame-floats=12' "$scope"
  sleep 0.35
  send_keys "$scope" Escape
  if wait_no_avy_attributes "$scope"; then
    pass scope-cleanup "both all-window and visual selectors removed every label"
  else
    fail scope-cleanup "scope cancellation retained labels" "$scope"
  fi

  side_before=$(report_count '^SIDE ')
  lem_keys "$scope" F1
  wait_report_count '^SIDE ' "$((side_before + 1))" || true
  active_before=$(report_count '^ACTIVE ')
  send_keys "$scope" ' ' a x
  wait_attribute_count "$scope" 36 >/dev/null || true
  send_keys "$scope" Escape
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  assert_last_active normal-includes-side-window \
    'key=Escape labels=36 buffers=1 frame-floats=37' "$scope"
  if wait_no_avy_attributes "$scope" && record_state "$scope"; then
    assert_state side-window-cleanup \
      'active=no labels=0 label-buffers=0 frame-floats=1 left-side=live-source' \
      "$scope"
  else
    fail side-window-cleanup \
      "Avy cancellation did not preserve only the live side window" "$scope"
  fi
fi
stop_session "$scope"

# Wrapped row starts and a tabbed continuation use Lem's real display geometry;
# the hidden-line predicate must remove the middle logical line from candidates.
display="lem-yath-avy-display-$id"
if start_session "$display" "$wrap_file" 'x-hidden'; then
  wrap_before=$(report_count '^WRAP ')
  lem_keys "$display" F5
  wait_report_count '^WRAP ' "$((wrap_before + 1))" || true

  active_before=$(report_count '^ACTIVE ')
  send_keys "$display" ' ' a x
  wait_attribute_count "$display" 4 >/dev/null || true
  wrapped_screen=$(lem_capture "$display")
  if grep -q 's-end' <<<"$wrapped_screen" && ! grep -q 'x-end' <<<"$wrapped_screen"; then
    pass wrapped-tab-geometry "label replaced x after a tab on a wrapped continuation"
  else
    fail wrapped-tab-geometry "wrapped tab label was displaced from x-end" "$display"
  fi
  send_keys "$display" Escape
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true

  active_before=$(report_count '^ACTIVE ')
  send_keys "$display" ' ' l
  if wait_attribute_count "$display" 4 >/dev/null; then
    send_keys "$display" Escape
    wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
    assert_last_active wrapped-line-rows \
      'key=Escape labels=[4-9][0-9]* buffers=1 frame-floats=[4-9][0-9]*' "$display"
  else
    send_keys "$display" Escape
    fail wrapped-line-rows "logical line was not split into visible row targets" "$display"
  fi

  hidden_before=$(report_count '^HIDDEN ')
  lem_keys "$display" F4
  wait_report_count '^HIDDEN ' "$((hidden_before + 1))" || true
  active_before=$(report_count '^ACTIVE ')
  send_keys "$display" ' ' a x
  wait_attribute_count "$display" 3 >/dev/null || true
  send_keys "$display" Escape
  wait_report_count '^ACTIVE ' "$((active_before + 1))" || true
  assert_last_active hidden-line-filter \
    'key=Escape labels=3 buffers=1 frame-floats=3' "$display"
fi
stop_session "$display"

if [ "$failed" -ne 0 ]; then
  printf 'Avy parity test failed.\n' >&2
  exit 1
fi

printf 'All Avy parity tests passed.\n'
