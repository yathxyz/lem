#!/usr/bin/env bash
# Real-ncurses parity coverage for the configured evil-snipe behavior.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-snipe-$$}"
sessions=()
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-snipe.XXXXXX")"

cleanup() {
  local session
  if declare -F lem_stop >/dev/null; then
    for session in "${sessions[@]:-}"; do
      [ -n "$session" ] && lem_stop "$session" || true
    done
  fi
  case "${root:-}" in
    */lem-yath-snipe.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe snipe-test cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_SNIPE_REPORT="$root/report"
export LEM_YATH_SNIPE_SOURCE="$here/lem-yath/src/vi.lisp"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$root/fixtures"
: >"$LEM_YATH_SNIPE_REPORT"

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
KEY_DELAY="${KEY_DELAY:-0.20}"

validate_timeout() {
  local name=$1 value=$2
  if [[ ! $value =~ ^[1-9][0-9]{0,2}$ ]] || ((10#$value > 600)); then
    printf '%s must be an integer from 1 through 600, got: %s\n' \
      "$name" "$value" >&2
    exit 2
  fi
}

validate_timeout BOOT_TIMEOUT "$BOOT_TIMEOUT"
validate_timeout WAIT_TIMEOUT "$WAIT_TIMEOUT"
if [[ ! $KEY_DELAY =~ ^(0\.[0-9]{1,3}|[1-9][0-9]{0,2}(\.[0-9]{1,3})?)$ ]]; then
  printf 'KEY_DELAY must be a positive decimal below 1000, got: %s\n' \
    "$KEY_DELAY" >&2
  exit 2
fi

failed=0
declare -A started

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  if [ -n "${3:-}" ]; then
    printf '\n--- screen (%s) ---\n' "$3" >&2
    lem_capture "$3" >&2 || true
    printf '\n--- attributes ---\n' >&2
    tmux_cmd capture-pane -t "$3" -p -e 2>/dev/null \
      | sed -n '1,12p' | sed -n l >&2 || true
  fi
  printf '\n--- report ---\n' >&2
  tail -80 "$LEM_YATH_SNIPE_REPORT" >&2 || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_SNIPE_REPORT" 2>/dev/null || true
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

fixture="$(lem-yath_lisp_string "$here/scripts/snipe-fixture.lisp")"

start_session() {
  local session=$1 file=$2 sentinel=$3 ready_before
  ready_before=$(report_count '^READY$')
  sessions+=("$session")
  if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$file"; then
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
  sleep 0.4
  lem_keys "$session" Escape
  sleep 0.35
  send_keys "$session" g g 0 z t
}

stop_session() {
  local session=$1 dead status
  [ "${started[$session]:-0}" = 1 ] || return 0
  if ! tmux_cmd has-session -t "$session" 2>/dev/null; then
    fail child-exit "tmux session disappeared before teardown" ""
    return 0
  fi
  dead=$(tmux_cmd display-message -p -t "$session" '#{pane_dead}')
  status=$(tmux_cmd display-message -p -t "$session" '#{pane_dead_status}')
  if [ "$dead" = 1 ]; then
    fail child-exit "Lem exited before teardown with status ${status:-unknown}" "$session"
  fi
  lem_stop "$session" || true
}

send_keys() {
  local session=$1 key
  shift
  for key in "$@"; do
    if [ "$key" = ';' ]; then
      # tmux parses a literal semicolon as a command separator even with -l.
      tmux_cmd send-keys -t "$session" -H 3b
    elif [ "${#key}" = 1 ]; then
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

last_state() {
  grep '^STATE ' "$LEM_YATH_SNIPE_REPORT" | tail -1
}

assert_state() {
  local name=$1 expected=$2 session=$3 state
  state=$(last_state)
  if grep -qE "$expected" <<<"$state"; then
    pass "$name" "$state"
  else
    fail "$name" "state did not match /$expected/: $state" "$session"
  fi
}

body_attributes() {
  tmux_cmd capture-pane -t "$1" -p -e | sed -n '2,12p'
}

attribute_count() {
  local colors=$1
  (LC_ALL=C grep -aoE "(${colors})m" || true) \
    | wc -l | tr -d ' '
}

wait_attribute_count() {
  local session=$1 colors=$2 minimum=$3 timeout=${4:-$WAIT_TIMEOUT}
  local index=0 count
  while ((index < timeout * 10)); do
    count=$(attribute_count "$colors" <<<"$(body_attributes "$session")")
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

wait_no_snipe_attributes() {
  local session=$1 timeout=${2:-$WAIT_TIMEOUT} index=0 count
  while ((index < timeout * 10)); do
    count=$(attribute_count '46|106|47|107|48;5;110|48;5;251' \
      <<<"$(body_attributes "$session")")
    if ((count == 0)); then
      return 0
    fi
    sleep 0.1
    index=$((index + 1))
  done
  return 1
}

motion_file="$root/fixtures/motions.txt"
case_file="$root/fixtures/case-cross-line.txt"
operator_file="$root/fixtures/operators.txt"
highlight_file="$root/fixtures/highlights.txt"
offscreen_file="$root/fixtures/offscreen.txt"
whitespace_file="$root/fixtures/whitespace.txt"
backward_overlap_file="$root/fixtures/backward-overlap.txt"
eof_file="$root/fixtures/eof.txt"
failed_repeat_file="$root/fixtures/failed-repeat.txt"
x_transient_file="$root/fixtures/x-transient.txt"
operator_count_file="$root/fixtures/operator-count.txt"
return_type_file="$root/fixtures/return-type.txt"
cancel_file="$root/fixtures/cancel.txt"
jumplist_file="$root/fixtures/jumplist.txt"
nested_operator_file="$root/fixtures/nested-operator.txt"

printf 'a1x a2x a3x\n' >"$motion_file"
printf 'aX q\nax q\nay\n' >"$case_file"
printf 'alpha beta gamma\n' >"$operator_file"
printf 'ax ay ax az ax aw ax\n' >"$highlight_file"
head -c 12000 /dev/zero | tr '\0' a >"$offscreen_file"
printf '\n' >>"$offscreen_file"
printf 'target-x\n' >>"$offscreen_file"
printf '    return 0;  -  \n' >"$whitespace_file"
printf 'aaaa\n' >"$backward_overlap_file"
printf %s 'aa xx zz' >"$eof_file"
printf 'ax ay ax\n' >"$failed_repeat_file"
printf '00 aa 11 aa 22 aa 33 aa\n' >"$x_transient_file"
printf '00 aa 11 aa 22 aa 33 aa 44 aa\n' >"$operator_count_file"
printf 'alpha beta bravo\n' >"$return_type_file"
printf 'alpha beta gamma\n' >"$cancel_file"
printf 'origin\nzz one\nzz two\n' >"$jumplist_file"
printf 'axx beta gamma\n' >"$nested_operator_file"

# Static contracts and two consecutive source reloads prove keymap and hook
# replacement is idempotent in the same running editor.
static_session="lem-yath-snipe-static-$id"
if start_session "$static_session" "$motion_file" 'a1x a2x a3x'; then
  static_before=$(report_count '^STATIC ')
  lem_keys "$static_session" F11
  if wait_report_count '^STATIC ' "$((static_before + 1))" &&
     tail -1 "$LEM_YATH_SNIPE_REPORT" \
       | grep -qE '^STATIC bindings=yes types=yes lifecycle=yes attributes=yes failures=0$'; then
    pass static-contracts "all override bindings, motion types, hooks, and faces agree"
  else
    fail static-contracts "static contracts diverged" "$static_session"
  fi

  reload_before=$(report_count '^RELOAD ')
  reload_success_before=$(report_count '^RELOAD bindings=yes lifecycle=yes pre=1 post=0 old=0 overlays=0 deleted=yes$')
  lem_keys "$static_session" F10
  wait_report_count '^RELOAD ' "$((reload_before + 1))" || true
  lem_keys "$static_session" F10
  if wait_report_count '^RELOAD ' "$((reload_before + 2))" &&
     wait_report_count \
       '^RELOAD bindings=yes lifecycle=yes pre=1 post=0 old=0 overlays=0 deleted=yes$' \
       "$((reload_success_before + 2))" &&
     ! grep -q '^RELOAD ERROR' "$LEM_YATH_SNIPE_REPORT" &&
     tail -1 "$LEM_YATH_SNIPE_REPORT" \
       | grep -qE '^RELOAD bindings=yes lifecycle=yes pre=1 post=0 old=0 overlays=0 deleted=yes$'; then
    pass reload-idempotence "two live reloads retained one cleanup hook of each kind"
  else
    fail reload-idempotence "reload duplicated state or lost bindings" "$static_session"
  fi
fi
stop_session "$static_session"

# Counts are part of the stored search.  ; repeats its direction after an
# unrelated command and , reverses that stored direction.
repeat_session="lem-yath-snipe-repeat-$id"
if start_session "$repeat_session" "$motion_file" 'a1x a2x a3x'; then
  send_keys "$repeat_session" 2 f x
  record_state "$repeat_session"
  assert_state count-find \
    'line=1 column=6 char=x .*target=x direction=FORWARD inclusive=yes count=2 family=F armed=F vi=.*NORMAL overlays=0$' \
    "$repeat_session"

  send_keys "$repeat_session" h ';'
  record_state "$repeat_session"
  assert_state persistent-semicolon \
    'line=1 column=10 char=x .*target=x direction=FORWARD inclusive=yes count=2 family=F armed=F vi=.*NORMAL overlays=0$' \
    "$repeat_session"

  send_keys "$repeat_session" ','
  record_state "$repeat_session"
  assert_state reverse-comma \
    'line=1 column=2 char=x .*target=x direction=FORWARD inclusive=yes count=2 family=F armed=F vi=.*NORMAL overlays=0$' \
    "$repeat_session"
fi
stop_session "$repeat_session"

# Exclusive t/T motion endpoints skip the adjacent old match on repeat.  A
# backward-origin immediate F uses lowercase/uppercase transient direction,
# not the letter's absolute direction.
till_session="lem-yath-snipe-till-$id"
if start_session "$till_session" "$motion_file" 'a1x a2x a3x'; then
  send_keys "$till_session" t x
  record_state "$till_session"
  assert_state till-forward \
    'line=1 column=1 char=1 .*target=x direction=FORWARD inclusive=no count=1 family=T armed=T vi=.*NORMAL overlays=0$' \
    "$till_session"

  send_keys "$till_session" ';'
  record_state "$till_session"
  assert_state till-repeat-skips-match \
    'line=1 column=5 char=2 .*target=x direction=FORWARD inclusive=no count=1 family=T armed=T vi=.*NORMAL overlays=0$' \
    "$till_session"

  send_keys "$till_session" ','
  record_state "$till_session"
  assert_state till-reverse \
    'line=1 column=3 char=[[:space:]] .*target=x direction=FORWARD inclusive=no count=1 family=T armed=T vi=.*NORMAL overlays=0$' \
    "$till_session"

  send_keys "$till_session" 0 2 f x h F a F
  record_state "$till_session"
  assert_state backward-immediate-pair \
    'line=1 column=8 char=a .*target=a direction=BACKWARD inclusive=yes count=1 family=F armed=F vi=.*NORMAL overlays=0$' \
    "$till_session"
fi
stop_session "$till_session"

# One-character override searches are case-sensitive and can cross a logical
# line while remaining within the visible viewport.
case_session="lem-yath-snipe-case-$id"
if start_session "$case_session" "$case_file" 'aX q'; then
  send_keys "$case_session" f x
  record_state "$case_session"
  assert_state case-and-cross-line \
    'line=2 column=1 char=x .*target=x direction=FORWARD inclusive=yes count=1 family=F armed=F vi=.*NORMAL overlays=0$' \
    "$case_session"
fi
stop_session "$case_session"

# Initial visible scope must not auto-scroll to a target outside the current
# viewport, but the failed target remains available to ;/, like evil-snipe.
scope_session="lem-yath-snipe-scope-$id"
if start_session "$scope_session" "$offscreen_file" 'aaaa'; then
  wrap_before=$(report_count '^WRAP ')
  lem_keys "$scope_session" F8
  wait_report_count '^WRAP enabled=yes line=1 column=0$' \
    "$((wrap_before + 1))" || fail visible-clipping "line wrap setup failed" "$scope_session"
  send_keys "$scope_session" f x
  record_state "$scope_session"
  assert_state visible-clipping \
    'line=1 column=0 char=a .*target=x direction=FORWARD inclusive=yes count=1 family=F armed=none vi=.*NORMAL overlays=0$' \
    "$scope_session"
fi
stop_session "$scope_session"

# The active evil-snipe default collapses leading indentation for both the
# one-character override and a two-space snipe target.
whitespace_session="lem-yath-snipe-whitespace-$id"
if start_session "$whitespace_session" "$whitespace_file" 'return 0'; then
  send_keys "$whitespace_session" f Space
  record_state "$whitespace_session"
  assert_state whitespace-find \
    'line=1 column=3 char=[[:space:]] .*target=[[:space:]] direction=FORWARD inclusive=yes count=1 family=F armed=F vi=.*NORMAL overlays=0$' \
    "$whitespace_session"

  send_keys "$whitespace_session" g g 0 s Space Space
  record_state "$whitespace_session"
  assert_state whitespace-two-character \
    'line=1 column=2 char=[[:space:]] .*target=[[:space:]]{2} direction=FORWARD inclusive=yes count=1 family=S armed=S vi=.*NORMAL overlays=0$' \
    "$whitespace_session"
fi
stop_session "$whitespace_session"

# Backward search must choose the nearest overlapping occurrence rather than
# reversing a list of forward non-overlapping matches.  Forward targets ending
# exactly at buffer-end must also work without a final newline.
edge_session="lem-yath-snipe-edge-$id"
if start_session "$edge_session" "$backward_overlap_file" 'aaaa'; then
  send_keys "$edge_session" '$' S a a
  record_state "$edge_session"
  assert_state backward-overlap \
    'line=1 column=1 char=a .*target=aa direction=BACKWARD inclusive=yes count=1 family=S armed=S' \
    "$edge_session"
fi
stop_session "$edge_session"

eof_session="lem-yath-snipe-eof-$id"
if start_session "$eof_session" "$eof_file" 'aa xx zz'; then
  send_keys "$eof_session" s z z
  record_state "$eof_session"
  assert_state target-at-eof \
    'line=1 column=6 char=z text=aa xx zz target=zz direction=FORWARD inclusive=yes count=1 family=S armed=S' \
    "$eof_session"
fi
stop_session "$eof_session"

# An unsuccessful repeat keeps the transient pair armed, so its uppercase key
# can recover in the opposite direction without collecting a new target.
failed_repeat_session="lem-yath-snipe-failed-repeat-$id"
if start_session "$failed_repeat_session" "$failed_repeat_file" 'ax ay ax'; then
  send_keys "$failed_repeat_session" f x ';' ';' F
  record_state "$failed_repeat_session"
  assert_state failed-repeat-recovery \
    'line=1 column=1 char=x .*target=x direction=FORWARD inclusive=yes count=1 family=F armed=F' \
    "$failed_repeat_session"
fi
stop_session "$failed_repeat_session"

# F12 records the family at input time but remains an unrelated command.  It
# must consume the old transient, so the following f collects a new target.
record_consumes_session="lem-yath-snipe-record-consumes-$id"
if start_session "$record_consumes_session" "$motion_file" 'a1x a2x a3x'; then
  send_keys "$record_consumes_session" f x
  record_state "$record_consumes_session"
  assert_state record-observes-transient \
    'line=1 column=2 char=x .*target=x direction=FORWARD inclusive=yes count=1 family=F armed=F' \
    "$record_consumes_session"

  send_keys "$record_consumes_session" f a
  record_state "$record_consumes_session"
  assert_state record-consumes-transient \
    'line=1 column=4 char=a .*target=a direction=FORWARD inclusive=yes count=1 family=F armed=F' \
    "$record_consumes_session"
fi
stop_session "$record_consumes_session"

# A numeric prefix is the next command and therefore exits evil-snipe's
# one-command transient map.  The following f starts a new counted target.
counted_transient_session="lem-yath-snipe-counted-transient-$id"
if start_session "$counted_transient_session" "$motion_file" 'a1x a2x a3x'; then
  send_keys "$counted_transient_session" f x 2 f a
  record_state "$counted_transient_session"
  assert_state counted-transient-exit \
    'line=1 column=8 char=a .*target=a direction=FORWARD inclusive=yes count=2 family=F armed=F' \
    "$counted_transient_session"
fi
stop_session "$counted_transient_session"

# An armed transient must be removed before d reads a nested f motion;
# otherwise that motion can accidentally repeat the previous target.
nested_operator_session="lem-yath-snipe-nested-operator-$id"
if start_session "$nested_operator_session" "$nested_operator_file" \
     'axx beta gamma'; then
  send_keys "$nested_operator_session" f x d f b
  record_state "$nested_operator_session"
  assert_state armed-family-before-d-f \
    'column=1 .*text=aeta gamma\\n .*target=b direction=FORWARD inclusive=yes count=1 family=F armed=none' \
    "$nested_operator_session"
fi
stop_session "$nested_operator_session"

# The same collision can affect exclusive t/T motions.  A fresh d t must read
# its own target instead of repeating the t b search that armed the map.
nested_t_operator_session="lem-yath-snipe-nested-t-operator-$id"
if start_session "$nested_t_operator_session" "$operator_file" \
     'alpha beta gamma'; then
  send_keys "$nested_t_operator_session" t b d t g
  record_state "$nested_t_operator_session"
  assert_state armed-family-before-d-t \
    'column=5 .*text=alphagamma\\n .*target=g direction=FORWARD inclusive=no count=1 family=T armed=none' \
    "$nested_t_operator_session"
fi
stop_session "$nested_t_operator_session"

# Operator-only x/X searches do not arm normal-state keys immediately.  A
# later successful ; does, after which x repeats instead of deleting a byte.
x_transient_session="lem-yath-snipe-x-transient-$id"
if start_session "$x_transient_session" "$x_transient_file" \
     '00 aa 11 aa 22 aa 33 aa'; then
  send_keys "$x_transient_session" d x a a ';' x
  record_state "$x_transient_session"
  assert_state x-transient-after-semicolon \
    'line=1 column=11 char=[[:space:]] text=aa 11 aa 22 aa 33 aa\\n .*target=aa direction=FORWARD inclusive=no count=1 family=X armed=X' \
    "$x_transient_session"
fi
stop_session "$x_transient_session"

x_nested_operator_session="lem-yath-snipe-x-nested-operator-$id"
if start_session "$x_nested_operator_session" "$x_transient_file" \
     '00 aa 11 aa 22 aa 33 aa'; then
  send_keys "$x_nested_operator_session" d x a a ';' x d x 3 3
  record_state "$x_nested_operator_session"
  assert_state armed-family-before-d-x \
    'column=11 .*text=aa 11 aa 2233 aa\\n .*target=33 direction=FORWARD inclusive=no count=1 family=X armed=none' \
    "$x_nested_operator_session"
fi
stop_session "$x_nested_operator_session"

# Counts belong to the stored motion and Lem's dot replay must reproduce both
# the operator count and the two target keystrokes.
operator_count_session="lem-yath-snipe-operator-count-$id"
if start_session "$operator_count_session" "$operator_count_file" \
     '00 aa 11 aa 22 aa 33 aa 44 aa'; then
  send_keys "$operator_count_session" 2 d z a a
  record_state "$operator_count_session"
  assert_state operator-count \
    'column=0 .*text=[[:space:]]22 aa 33 aa 44 aa\\n .*target=aa direction=FORWARD inclusive=yes count=2 family=S armed=none' \
    "$operator_count_session"

  send_keys "$operator_count_session" '.'
  record_state "$operator_count_session"
  assert_state operator-dot-repeat \
    'column=0 .*text=[[:space:]]44 aa\\n .*target=aa direction=FORWARD inclusive=yes count=2 family=S armed=none' \
    "$operator_count_session"
fi
stop_session "$operator_count_session"

# Return inside a different operator alias reuses the stored search's dynamic
# exclusive type.  The target b therefore survives dz<Return>.
return_type_session="lem-yath-snipe-return-type-$id"
if start_session "$return_type_session" "$return_type_file" \
     'alpha beta bravo'; then
  send_keys "$return_type_session" t b d z Enter
  record_state "$return_type_session"
  assert_state return-dynamic-motion-type \
    'column=5 .*text=alphabravo\\n .*target=b direction=FORWARD inclusive=no count=1 family=T armed=none' \
    "$return_type_session"
fi
stop_session "$return_type_session"

# Abort paths must unwind operator state, preserve bytes, remove incremental
# faces, and leave no transient family behind.
cancel_operator_session="lem-yath-snipe-cancel-operator-$id"
if start_session "$cancel_operator_session" "$cancel_file" \
     'alpha beta gamma'; then
  send_keys "$cancel_operator_session" d z a C-g
  if ! lem_wait_for "$cancel_operator_session" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null ||
     ! wait_no_snipe_attributes "$cancel_operator_session"; then
    fail operator-c-g-cancel 'C-g left operator state or incremental faces active' \
      "$cancel_operator_session"
  fi
  record_state "$cancel_operator_session"
  assert_state operator-c-g-cancel \
    'line=1 column=0 char=a text=alpha beta gamma\\n target=none .*armed=none vi=.*NORMAL overlays=0$' \
    "$cancel_operator_session"

  send_keys "$cancel_operator_session" d z a BSpace
  record_state "$cancel_operator_session"
  assert_state operator-backspace-cancel \
    'line=1 column=0 char=a text=alpha beta gamma\\n target=none .*armed=none vi=.*NORMAL overlays=0$' \
    "$cancel_operator_session"
fi
stop_session "$cancel_operator_session"

# Initial snipes are jumps; ; repeats are not.  After crossing two lines, C-o
# must return to the initial origin rather than the intermediate repeat target.
jumplist_session="lem-yath-snipe-jumplist-$id"
if start_session "$jumplist_session" "$jumplist_file" 'origin'; then
  send_keys "$jumplist_session" s z z ';' C-o
  record_state "$jumplist_session"
  assert_state initial-only-jumplist \
    'line=1 column=0 char=o .*target=zz direction=FORWARD inclusive=yes count=1 family=S armed=none' \
    "$jumplist_session"
fi
stop_session "$jumplist_session"

# Operator aliases: z/Z include the full two-character match, x/X exclude it;
# overridden f/t retain their corresponding inclusive/exclusive range shape.
forward_operator_session="lem-yath-snipe-op-forward-$id"
if start_session "$forward_operator_session" "$operator_file" 'alpha beta gamma'; then
  send_keys "$forward_operator_session" d z b e
  record_state "$forward_operator_session"
  assert_state operator-z-inclusive \
    'column=0 .*text=ta gamma\\n .*target=be direction=FORWARD inclusive=yes' \
    "$forward_operator_session"

  send_keys "$forward_operator_session" u d x b e
  record_state "$forward_operator_session"
  assert_state operator-x-exclusive \
    'column=0 .*text=beta gamma\\n .*target=be direction=FORWARD inclusive=no' \
    "$forward_operator_session"

  send_keys "$forward_operator_session" u d f b
  record_state "$forward_operator_session"
  assert_state operator-f-inclusive \
    'column=0 .*text=eta gamma\\n .*target=b direction=FORWARD inclusive=yes' \
    "$forward_operator_session"

  send_keys "$forward_operator_session" u d t b
  record_state "$forward_operator_session"
  assert_state operator-t-exclusive \
    'column=0 .*text=beta gamma\\n .*target=b direction=FORWARD inclusive=no' \
    "$forward_operator_session"
fi
stop_session "$forward_operator_session"

backward_operator_session="lem-yath-snipe-op-backward-$id"
if start_session "$backward_operator_session" "$operator_file" 'alpha beta gamma'; then
  send_keys "$backward_operator_session" '$' d Z b e
  record_state "$backward_operator_session"
  assert_state operator-Z-inclusive \
    'column=5 .*text=alpha \\n .*target=be direction=BACKWARD inclusive=yes' \
    "$backward_operator_session"

  send_keys "$backward_operator_session" u '$' d X b e
  record_state "$backward_operator_session"
  assert_state operator-X-exclusive \
    'column=7 .*text=alpha be\\n .*target=be direction=BACKWARD inclusive=no' \
    "$backward_operator_session"
fi
stop_session "$backward_operator_session"

# Incremental prefix candidates are rendered before the blocking second key.
# Final selected/secondary faces persist until the next command, while Escape
# and an unrelated motion remove every snipe background from the text rows.
highlight_session="lem-yath-snipe-highlight-$id"
if start_session "$highlight_session" "$highlight_file" 'ax ay ax az'; then
  send_keys "$highlight_session" s a
  if lem_wait_for "$highlight_session" '1>' "$WAIT_TIMEOUT" >/dev/null &&
     staged_matches=$(wait_attribute_count "$highlight_session" \
       '47|107|48;5;251' 4); then
    pass incremental-highlight "first character exposed $staged_matches visible candidates"
  else
    fail incremental-highlight "prefix candidates were not rendered before read-key" \
      "$highlight_session"
  fi

  send_keys "$highlight_session" Escape
  record_state "$highlight_session"
  if wait_no_snipe_attributes "$highlight_session" &&
     grep -qE 'line=1 column=0 .*target=none .*armed=none vi=.*NORMAL overlays=0$' <<<"$(last_state)"; then
    pass cancel-cleanup "Escape restored the origin and removed incremental overlays"
  else
    fail cancel-cleanup "Escape left movement, search state, or attributes behind" \
      "$highlight_session"
  fi

  send_keys "$highlight_session" s a x
  selected_count=0
  secondary_count=0
  if selected_count=$(wait_attribute_count "$highlight_session" \
       '46|106|48;5;110' 1) &&
     secondary_count=$(wait_attribute_count "$highlight_session" \
       '47|107|48;5;251' 2); then
    pass final-highlight "selected and later matches use distinct visible faces"
  else
    fail final-highlight \
      "expected selected and secondary faces, got $selected_count/$secondary_count" \
      "$highlight_session"
  fi

  send_keys "$highlight_session" ';'
  repeat_selected=0
  repeat_secondary=0
  if repeat_selected=$(wait_attribute_count "$highlight_session" \
       '46|106|48;5;110' 1) &&
     repeat_secondary=$(wait_attribute_count "$highlight_session" \
       '47|107|48;5;251' 3); then
    pass whole-visible-repeat "repeat highlighted matches on both sides of point"
  else
    fail whole-visible-repeat \
      "whole-visible repeat exposed only $repeat_selected/$repeat_secondary faces" \
      "$highlight_session"
  fi

  send_keys "$highlight_session" h
  if wait_no_snipe_attributes "$highlight_session"; then
    pass next-command-cleanup "the next unrelated command removed final overlays"
  else
    fail next-command-cleanup "final match overlays survived an unrelated motion" \
      "$highlight_session"
  fi
fi
stop_session "$highlight_session"

if ((failed == 0)); then
  printf '\nALL EVIL-SNIPE PARITY CHECKS PASSED\n'
  exit 0
fi

printf '\nEVIL-SNIPE PARITY CHECKS FAILED\n' >&2
exit 1
