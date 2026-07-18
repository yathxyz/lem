#!/usr/bin/env bash
# Evil-Org text-object parity through the configured real ncurses editor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-org-operator-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-operator.XXXXXX")"

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_ORG_OPERATOR_REPORT="$root/report"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
: >"$LEM_YATH_ORG_OPERATOR_REPORT"

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
KEY_DELAY="${KEY_DELAY:-0.18}"
CASE_PREFIX="${LEM_YATH_ORG_OPERATOR_CASE_PREFIX:-}"

fixture_lisp="$(lem-yath_lisp_string \
  "$here/scripts/org-operator-fixture.lisp")"

sessions=()
declare -A started
failed=0

cleanup() {
  local session
  if declare -F lem_stop >/dev/null; then
    for session in "${sessions[@]:-}"; do
      [ -n "$session" ] && lem_stop "$session" || true
    done
  fi
  case "${root:-}" in
    */lem-yath-org-operator.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe Org operator cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-28s %s\n' "$1" "$2" >&2
  if [ -n "${3:-}" ]; then
    printf '\n--- screen (%s) ---\n' "$3" >&2
    lem_capture "$3" >&2 || true
  fi
  printf '\n--- report ---\n' >&2
  tail -80 "$LEM_YATH_ORG_OPERATOR_REPORT" >&2 || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_ORG_OPERATOR_REPORT" 2>/dev/null || true
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

start_case() {
  local phase=$1 file=$2 sentinel=$3
  local session="lem-org-operator-${phase}-${id}" ready_before
  if [ -n "$CASE_PREFIX" ] && [ "$phase" != "$CASE_PREFIX" ] &&
     [[ "$phase" != "$CASE_PREFIX"-* ]]; then
    return 1
  fi
  ready_before=$(report_count "^READY phase=${phase}$")
  export LEM_YATH_ORG_OPERATOR_PHASE="$phase"
  sessions+=("$session")
  if ! lem_start_lem-yath_eval "$session" "(load #P$fixture_lisp)" "$file"; then
    fail "$phase" "failed to launch configured Lem" ""
    return 1
  fi
  started["$session"]=1
  tmux_cmd set-option -t "$session" remain-on-exit on
  if ! wait_report_count "^READY phase=${phase}$" \
       "$((ready_before + 1))" "$BOOT_TIMEOUT" ||
     ! lem_wait_for "$session" "$sentinel" "$BOOT_TIMEOUT" >/dev/null ||
     ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null; then
    fail "$phase" "configured Lem did not become ready" "$session"
    return 1
  fi
  sleep 0.35
  send_keys "$session" Escape g g 0
  CASE_SESSION="$session"
}

stop_case() {
  local session=$1 dead status
  [ "${started[$session]:-0}" = 1 ] || return 0
  if tmux_cmd has-session -t "$session" 2>/dev/null; then
    dead=$(tmux_cmd display-message -p -t "$session" '#{pane_dead}')
    status=$(tmux_cmd display-message -p -t "$session" '#{pane_dead_status}')
    if [ "$dead" = 1 ]; then
      fail child-exit "Lem exited with status ${status:-unknown}" "$session"
    fi
  fi
  lem_stop "$session" || true
  started["$session"]=0
}

record_state() {
  local phase=$1 session=$2 before
  before=$(report_count "^STATE phase=${phase} ")
  lem_keys "$session" F12
  wait_report_count "^STATE phase=${phase} " "$((before + 1))"
}

last_state() {
  local phase=$1
  grep "^STATE phase=${phase} " "$LEM_YATH_ORG_OPERATOR_REPORT" | tail -1
}

assert_state() {
  local name=$1 phase=$2 session=$3 state needle missing=""
  shift 3
  state=$(last_state "$phase")
  if [ -z "$state" ]; then
    fail "$name" "no F12 state report was recorded" "$session"
    return
  fi
  for needle in "$@"; do
    if [[ "$state" != *"$needle"* ]]; then
      missing="${missing}${missing:+, }${needle}"
    fi
  done
  if [ -z "$missing" ]; then
    pass "$name" "$state"
  else
    fail "$name" "missing [$missing] in: $state" "$session"
  fi
}

operate_and_record() {
  local phase=$1 session=$2
  shift 2
  send_keys "$session" "$@"
  if ! lem_wait_for "$session" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null; then
    fail "$phase" "operator did not return to NORMAL" "$session"
    return 1
  fi
  sleep 0.25
  if ! record_state "$phase" "$session"; then
    fail "$phase" "F12 state report timed out" "$session"
    return 1
  fi
}

assert_unsafe_context() {
  local phase=$1 session=$2 expected_text=$3
  if operate_and_record "$phase" "$session" d a r; then
    assert_state "${phase}-ar" "$phase" "$session" \
      "$expected_text" 'state=normal selection=none' \
      'register= register-type=none' 'small= small-type=none' \
      'modified=no'
  fi
  if operate_and_record "$phase" "$session" d a E; then
    assert_state "${phase}-aE" "$phase" "$session" \
      "$expected_text" 'state=normal selection=none' \
      'register= register-type=none' 'small= small-type=none' \
      'modified=no'
  fi
}

write_fixtures() {
  printf '%s\n' '~code~ tail' >"$WORKDIR/inline-outer.org"
  printf '%s\n' '~code~ tail' >"$WORKDIR/inline-inner.org"
  printf '%s' $'- parent\n  - child' >"$WORKDIR/list-eof.org"
  printf '%s\n' \
    '#+begin_src text' \
    'source body' \
    '#+end_src' \
    'AFTER' >"$WORKDIR/source-outer.org"
  printf '%s\n' \
    '#+begin_src text' \
    'source body' \
    '#+end_src' \
    'AFTER' >"$WORKDIR/source-inner.org"
  printf '%s\n' \
    '- parent' \
    '  - child' \
    '- sibling' >"$WORKDIR/list-outer.org"
  printf '%s\n' \
    '- parent' \
    '  - child' \
    '- sibling' >"$WORKDIR/list-inner.org"
  printf '%s\n' \
    '* Parent' \
    'Parent body' \
    '** Child' \
    'Child body' \
    '* Sibling' >"$WORKDIR/subtree-outer.org"
  printf '%s\n' \
    '* Parent' \
    'Parent body' \
    '** Child' \
    'Child body' \
    '* Sibling' >"$WORKDIR/subtree-inner.org"
  printf '%s\n' \
    '* Parent' \
    '** Child' \
    '*** Grandchild' \
    'Grand body' \
    '** Child sibling' \
    '* Top sibling' >"$WORKDIR/count.org"
  printf '%s\n' '~code~ tail' >"$WORKDIR/visual-object.org"
  printf '%s\n' \
    '* Parent' \
    'Parent body' \
    '** Child' \
    'Child body' \
    '* Sibling' >"$WORKDIR/visual-subtree.org"
  printf '%s\n' 'plain text without an Org object' >"$WORKDIR/abort.org"
  printf '%s\n' 'alpha beta' >"$WORKDIR/daw.org"
  printf '%s\n' 'alpha beta' >"$WORKDIR/surround-add.org"
  printf '%s\n' '"alpha" beta' >"$WORKDIR/surround-delete.org"
  printf '%s\n' '"alpha" beta' >"$WORKDIR/surround-change.org"
  printf '%s\n' 'alpha beta gamma' >"$WORKDIR/snipe.org"
  printf '%s\n' '* Static routing' >"$WORKDIR/static.org"
  printf '%s\n' \
    'Preamble paragraph.' \
    '#+title: Element navigation' \
    'After title.' \
    '* Root' \
    'SCHEDULED: <2026-07-14 Tue>' \
    ':PROPERTIES:' \
    ':ID: root-id' \
    ':END:' \
    'Intro paragraph.' \
    'continued intro.' \
    '- item one' \
    '  continuation one' \
    '  - nested child' \
    '- item two' \
    '' \
    '| a | b |' \
    '| c | d |' \
    '#+TBLFM: $1=1' \
    '' \
    '#+begin_quote' \
    'Quote paragraph.' \
    '- quote item' \
    '#+end_quote' \
    '' \
    '#+begin_src text' \
    'source body' \
    '#+end_src' \
    '** Child' \
    'Child body.' \
    '*** Grand' \
    'Grand body.' \
    '** Child sibling' \
    'Sibling body.' \
    '* Other' \
    'Other body.' >"$WORKDIR/navigation-elements.org"
  printf '%s\n' \
    '* Empty' \
    '* Parent' \
    '** Child' \
    '* Drawer' \
    ':PROPERTIES:' \
    ':END:' \
    'Drawer tail.' \
    '* Quote' \
    '#+begin_quote' \
    '#+end_quote' \
    'Quote tail.' >"$WORKDIR/navigation-empty-elements.org"
  printf '%s\n' 'One.  Two!  Three?' 'Four.' '' 'Five.  Six.' \
    >"$WORKDIR/navigation-sentence.org"
  printf '%s\n' \
    'Wrapped first line' \
    'continues without ending. Next single-space sentence?' \
    'After terminal.' '' \
    'Indented paragraph' \
    '  continues here!' >"$WORKDIR/navigation-sentence-wrapped.org"
  printf '%s\n' '| aa | bb | cc |' '| dd | ee | ff |' \
    >"$WORKDIR/navigation-table.org"
  printf '%s\n' \
    '* Heading' \
    'Paragraph text.' \
    '- item one' \
    '- item two' \
    '| aa | bb |' \
    '| cc | dd |' \
    '#+name: sample' \
    'Next paragraph.' \
    '** Child' \
    'Child body.' >"$WORKDIR/navigation-structure.org"
  printf '%s\n' \
    '* Heading' \
    'First paragraph line.' \
    'continued here.' \
    '' \
    '- item one' \
    '- item two' \
    '' \
    ':PROPERTIES:' \
    ':ID: value' \
    ':END:' \
    '' \
    '#+begin_src text' \
    'block one' \
    '' \
    'block two' \
    '#+end_src' >"$WORKDIR/navigation-separated.org"
  printf '%s\n' \
    '- first item' \
    '  continuation text' \
    '- second item' \
    '' \
    '- parent' \
    '  - child' \
    '- sibling' >"$WORKDIR/navigation-complex-list.org"
  printf '%s\n' \
    '| a | b |' \
    '| c | d |' \
    '#+TBLFM: $1=1' \
    'AFTER' >"$WORKDIR/navigation-formula-table.org"
  printf '%s\n' \
    'CLOCK: [2026-07-14 Tue 09:00]--[2026-07-14 Tue 10:00] =>  1:00' \
    'CLOCK: [2026-07-14 Tue 11:00]--[2026-07-14 Tue 12:00] =>  1:00' \
    'AFTER' >"$WORKDIR/navigation-clocks.org"
  printf '%s\n' '1. one' '2. two' '3. three' \
    >"$WORKDIR/delete-ordered.org"
  printf '%s\n' '1. one' '5. [@5] five' '6. six' \
    >"$WORKDIR/delete-ordered-counter.org"
  printf '%s\n' '1. top' '   1. child' '2. second' '3. third' \
    >"$WORKDIR/delete-ordered-nested.org"
  printf '%s\n' '1. one' '   continuation' '2. two' \
    >"$WORKDIR/delete-ordered-unsafe.org"
  printf '%s\n' '* TODO Alpha beta :work:' \
    >"$WORKDIR/delete-heading-tag.org"
  printf '%s\n' '| abc | de |' >"$WORKDIR/delete-table.org"
  printf '%s\n' '| abc | de |' >"$WORKDIR/delete-table-backward.org"
  printf '%s\n' '| abc | de |' >"$WORKDIR/delete-table-count.org"
  printf '%s\n' '| abc | de |' >"$WORKDIR/delete-table-visual.org"
  printf '%s\n' '* H1' 'body' '* H2' 'body2' '** Child' \
    >"$WORKDIR/shift-heading.org"
  printf '%s\n' '* H1' 'body' >"$WORKDIR/shift-heading-abort.org"
  printf '%s\n' '- one' '- two' '  - child' '- three' \
    >"$WORKDIR/shift-list.org"
  printf '%s\n' '1. one' '2. two' '3. three' \
    >"$WORKDIR/shift-ordered.org"
  printf '%s\n' '- one' '  continuation' '- two' \
    >"$WORKDIR/shift-list-top.org"
  printf '%s\n' '| a | b | c |' '| d | e | f |' \
    >"$WORKDIR/shift-table.org"
  printf '%s\n' '| a | b |' '| c | d |' '#+TBLFM: $1=1' \
    >"$WORKDIR/shift-table-formula.org"
  printf '%s\n' 'alpha' 'beta' 'gamma' >"$WORKDIR/shift-prose.org"
  printf '%s\n' '* A' '** A child' '* B' '* C' \
    >"$WORKDIR/visual-meta-headings.org"
  printf '%s\n' '** A' '*** A child' '** B' '* C' \
    >"$WORKDIR/visual-meta-headings-promote.org"
  printf '%s\n' '* A' '** A child' '* B' '* C' \
    >"$WORKDIR/visual-meta-heading-move.org"
  printf '%s\n' '- zero' '- one' '- two' '- three' \
    >"$WORKDIR/visual-meta-list.org"
  printf '%s\n' '- zero' '  - one' '  - two' '- three' \
    >"$WORKDIR/visual-meta-list-outdent.org"
  printf '%s\n' \
    '- zero' \
    '- one' \
    '  continuation' \
    '  - child' \
    '- two' >"$WORKDIR/visual-meta-list-tree.org"
  printf '%s\n' \
    '- zero' \
    '  - one' \
    '    continuation' \
    '    - child' \
    '- two' >"$WORKDIR/visual-meta-list-tree-outdent.org"
  printf '%s\n' 'zero' 'one' 'two' 'three' 'four' \
    >"$WORKDIR/visual-meta-lines.org"
  printf '%s\n' '| a | b |' '| c | d |' 'AFTER' \
    >"$WORKDIR/visual-meta-table.org"
  printf '%s\n' '* A' '** A child' '* B' '* C' '* D' \
    >"$WORKDIR/visual-shift-meta-heading.org"
  printf '%s\n' 'zero' 'one' 'two' 'three' \
    >"$WORKDIR/visual-shift-meta-lines.org"
  printf '%s\n' \
    'CLOCK: [2026-07-14 Tue 09:00]--[2026-07-14 Tue 10:00] =>  1:00' \
    >"$WORKDIR/visual-shift-meta-clock-up.org"
  printf '%s\n' \
    'CLOCK: [2026-07-14 Tue 09:00]--[2026-07-14 Tue 10:00] =>  1:00' \
    >"$WORKDIR/visual-shift-meta-clock-down.org"
  printf '%s\n' \
    '[[file:target.org][described link]] tail' \
    >"$WORKDIR/link-outer.org"
  printf '%s\n' \
    '[[file:target.org][described link]] tail' \
    >"$WORKDIR/link-inner.org"
  printf '%s\n' '[[file:x][https://example.com]] tail' \
    >"$WORKDIR/link-url-description.org"
  printf '%s\n' 'https://example.com tail' >"$WORKDIR/plain-link.org"
  printf '%s\n' 'https://example.com/foo_bar tail' \
    >"$WORKDIR/plain-link-underscore.org"
  printf '%s\n' '[[https://x/foo_bar][desc]] tail' \
    >"$WORKDIR/link-target-underscore.org"
  printf '%s\n' '[[https://x][foo_bar]] tail' \
    >"$WORKDIR/link-description-subscript.org"
  printf '%s\n' '~https://example.com/foo_bar~ tail' \
    >"$WORKDIR/opaque-plain-link-code.org"
  printf '%s\n' '=[[https://x/foo_bar][desc]]= tail' \
    >"$WORKDIR/opaque-bracket-link-verbatim.org"
  printf '%s\n' '~a *b*~ tail' >"$WORKDIR/opaque-code.org"
  printf '%s\n' '~\alpha~ tail' >"$WORKDIR/opaque-entity.org"
  printf '%s\n' '| alpha | beta |' >"$WORKDIR/table-cell.org"
  printf '%s\n' '| alpha \| literal | beta |' \
    >"$WORKDIR/ambiguous-table-cell.org"
  printf '%s\n' '| first |' '| second |' 'AFTER' \
    >"$WORKDIR/table-context.org"
  printf '%s\n' '| a |' '| b |' '#+TBLFM: $1=1' 'AFTER' \
    >"$WORKDIR/table-formula-element.org"
  printf '%s\n' '| a |' '| b |' '#+TBLFM: $1=1' 'AFTER' \
    >"$WORKDIR/table-formula-greater.org"
  printf '%s\n' \
    'First paragraph line' \
    'second paragraph line' \
    '' \
    'AFTER' >"$WORKDIR/paragraph-element.org"
  printf '%s\n' \
    'Fallback paragraph' \
    '' \
    'AFTER' >"$WORKDIR/paragraph-object.org"
  printf '%s\n' '* Empty' '* Sibling' >"$WORKDIR/empty-subtree.org"
  printf '%s\n' \
    '1. ordered item' \
    '2. ordered next' >"$WORKDIR/unsafe-ordered.org"
  printf '%s\n' \
    $'-\ttabbed item' \
    '- safe-looking sibling' >"$WORKDIR/unsafe-tabbed.org"
  printf '%s\n' \
    '- item' \
    '  continuation body' \
    '- next' >"$WORKDIR/unsafe-continuation.org"
  printf '%s\n' \
    '#+begin_src text' \
    'body without end' >"$WORKDIR/unsafe-unclosed.org"
  printf '%s\n' ':END:' ':ID: orphan' 'KEEP' \
    >"$WORKDIR/unsafe-orphan-property.org"
  printf '%s\n' 'plain unsafe text' >"$WORKDIR/visual-abort.org"
  printf '%s\n' '~one~ ~two~ tail' >"$WORKDIR/count-object.org"
  printf '%s\n' 'P1' '' 'P2' '' 'AFTER' \
    >"$WORKDIR/count-element.org"
  printf '%s\n' '~one~ [fn:note] ~two~' \
    >"$WORKDIR/count-object-barrier.org"
  printf '%s\n' 'P1' '' ':ID: orphan' '' 'P2' \
    >"$WORKDIR/count-element-barrier.org"
  printf '%s\n' '- parent' '  - child' '- sibling' \
    >"$WORKDIR/list-context.org"
  printf '%s\n' '- ' '- KEEP' >"$WORKDIR/empty-list-leaf.org"
  printf '%s\n' '- ' '  - child' '- KEEP' \
    >"$WORKDIR/empty-list-parent.org"
  printf '%s\n' 'prefix [fn:note] suffix' \
    >"$WORKDIR/unsupported-inline.org"
  printf '%s\n' 'prefix [cite:@key] suffix' \
    >"$WORKDIR/unsupported-citation.org"
  printf '%s\n' 'prefix \alpha suffix' \
    >"$WORKDIR/unsupported-entity.org"
  printf '%s\n' '*prefix [cite:@key] suffix*' \
    >"$WORKDIR/unsupported-nested.org"
  printf '%s\n' '* H' ':ID: *orphan*' 'KEEP' '* S' \
    >"$WORKDIR/orphan-under-heading.org"
  printf '%s\n' '* H' ':MY-DRAWER:' ':ID: value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/hyphen-drawer.org"
  printf '%s\n' '* H' ':MY-DRAWER:' ':ID: value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/drawer-element.org"
  printf '%s\n' '* H' ':MY-DRAWER:' ':ID: value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/drawer-greater.org"
  printf '%s\n' '* H' ':MY-DRAWER:' ':ID: value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/drawer-inner-greater.org"
  printf '%s\n' '* H' ':PROPERTIES:' ':ID: value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/property-drawer-element.org"
  printf '%s\n' '* H' ':PROPERTIES:' ':ID: value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/property-drawer-greater.org"
  printf '%s\n' '* H' ':MY-DRAWER:' ':ID: value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/drawer-subtree.org"
  printf '%s\n' \
    '* H' \
    ':LOGBOOK:' \
    'CLOCK: [2026-07-14 Tue 09:00]--[2026-07-14 Tue 10:00] =>  1:00' \
    ':END:' \
    'KEEP' \
    '* S' >"$WORKDIR/drawer-clock-element.org"
  printf '%s\n' \
    '* H' \
    ':LOGBOOK:' \
    'CLOCK: [2026-07-14 Tue 09:00]--[2026-07-14 Tue 10:00] =>  1:00' \
    ':END:' \
    'KEEP' \
    '* S' >"$WORKDIR/drawer-clock-object.org"
  printf '%s\n' '* H' ':NOTES:' 'note ~code~ tail' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/drawer-inline-object.org"
  printf '%s\n' '* H' ':PROPERTIES:' ':NOTE: *bold* value' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/property-drawer-object.org"
  printf '%s\n' '* H' ':LOGBOOK:' ':END:' 'KEEP' '* S' \
    >"$WORKDIR/empty-drawer.org"
  printf '%s\n' '* H' ':LOGBOOK:' 'CLOCK: [2026-07-14 Tue 09:00]' 'KEEP' \
    '* S' >"$WORKDIR/unclosed-drawer.org"
  printf '%s\n' \
    '#+begin_src text' \
    'before' \
    '#+begin_src text' \
    'inner' \
    '#+end_src' \
    'after' \
    '#+end_src' \
    'KEEP' >"$WORKDIR/nested-block.org"
  printf '%s\n' \
    '#+begin_src text' \
    'before' \
    '#+end_quote' \
    'after' \
    '#+end_src' \
    'KEEP' >"$WORKDIR/mismatched-end.org"
  printf '%s\n' '#+begin_quote' 'quoted body' '#+end_quote' 'AFTER' \
    >"$WORKDIR/quote-outer.org"
  printf '%s\n' '#+begin_quote' 'quoted body' '#+end_quote' 'AFTER' \
    >"$WORKDIR/quote-inner.org"
  printf '%s\n' '| a | b |' '|---+---|' '| c | d |' \
    >"$WORKDIR/table-hline.org"
  printf '%s\n' '- one' '- two' '' 'AFTER' \
    >"$WORKDIR/list-postblank.org"
  printf '%s\n' '| a |' '| b |' '' 'AFTER' \
    >"$WORKDIR/table-postblank.org"
  printf '%s\n' 'Paragraph' '' 'AFTER' \
    >"$WORKDIR/paragraph-postblank.org"
  printf '%s\n' '~code~ tail' >"$WORKDIR/reverse-visual.org"
  printf '%s\n' '- parent' '  - child' '- sibling' \
    >"$WORKDIR/repeated-visual-list.org"
  printf '%s\n' '<2026-07-12 Sun> tail' >"$WORKDIR/timestamp.org"
  printf '%s\n' '* Parent' 'Body' '* Sibling' \
    >"$WORKDIR/heading-element.org"
  printf '%s\n' 'P1' '' '* H' 'body' >"$WORKDIR/count-heading.org"
}

write_fixtures

# Effective state maps: local Org text objects must coexist with native Vi.
if start_case static "$WORKDIR/static.org" 'Static routing'; then
  if record_state static "$CASE_SESSION" &&
     grep -Fxq \
       'STATIC normal=yes operator=yes visual=yes stock=yes snipe=yes safe=yes commands=yes motions=yes' \
       "$LEM_YATH_ORG_OPERATOR_REPORT"; then
    pass static-routing \
      "normal d/x/X/< />, doubled shifts, visual defaults, text objects, and operator Snipe coexist"
  else
    fail static-routing "effective Org routing contract differed" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

# Evil-Org's gh/gl/gk/gj/gH maps follow GNU Org's element tree rather than
# merely visiting headings.  These cases cover every supported greater-element
# family and retain exact Normal-state endpoints under literal keys.
if start_case element-forward "$WORKDIR/navigation-elements.org" \
     'Preamble paragraph'; then
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-preamble element-forward "$CASE_SESSION" \
      'line=2 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 3 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-headline element-forward "$CASE_SESSION" \
      'line=34 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 6 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-property element-forward "$CASE_SESSION" \
      'line=9 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 10 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-list element-forward "$CASE_SESSION" \
      'line=16 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 12 j 4 l
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-nested-item element-forward "$CASE_SESSION" \
      'line=14 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 15 j 2 l
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-table-row element-forward "$CASE_SESSION" \
      'line=17 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 17 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-formula element-forward "$CASE_SESSION" \
      'line=20 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 19 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-quote element-forward "$CASE_SESSION" \
      'line=25 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 20 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-quote-body element-forward "$CASE_SESSION" \
      'line=22 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 24 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-source element-forward "$CASE_SESSION" \
      'line=28 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 27 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-child element-forward "$CASE_SESSION" \
      'line=32 column=0' 'state=normal selection=none' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 28 j 0
  if operate_and_record element-forward "$CASE_SESSION" g j; then
    assert_state element-forward-child-body element-forward "$CASE_SESSION" \
      'line=30 column=0' 'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case element-backward "$WORKDIR/navigation-elements.org" \
     'Preamble paragraph'; then
  send_keys "$CASE_SESSION" 8 j 5 l
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-mid-paragraph element-backward \
      "$CASE_SESSION" 'line=9 column=0' 'modified=no'
  fi
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-drawer element-backward "$CASE_SESSION" \
      'line=6 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 13 j 0
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-item element-backward "$CASE_SESSION" \
      'line=11 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 15 j 0
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-table element-backward "$CASE_SESSION" \
      'line=11 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 19 j 0
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-quote element-backward "$CASE_SESSION" \
      'line=16 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 29 j 0
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-grand element-backward "$CASE_SESSION" \
      'line=28 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 31 j 0
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-sibling element-backward "$CASE_SESSION" \
      'line=28 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 33 j 0
  if operate_and_record element-backward "$CASE_SESSION" g k; then
    assert_state element-backward-root element-backward "$CASE_SESSION" \
      'line=4 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case element-up-down-top "$WORKDIR/navigation-elements.org" \
     'Preamble paragraph'; then
  send_keys "$CASE_SESSION" 8 j 5 l
  if operate_and_record element-up-down-top "$CASE_SESSION" g h; then
    assert_state element-up-paragraph element-up-down-top "$CASE_SESSION" \
      'line=4 column=0' 'modified=no'
  fi
  if operate_and_record element-up-down-top "$CASE_SESSION" g l; then
    assert_state element-down-heading element-up-down-top "$CASE_SESSION" \
      'line=5 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 10 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g l; then
    assert_state element-down-list element-up-down-top "$CASE_SESSION" \
      'line=11 column=1' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 15 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g l; then
    assert_state element-down-table element-up-down-top "$CASE_SESSION" \
      'line=16 column=1' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 19 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g l; then
    assert_state element-down-quote element-up-down-top "$CASE_SESSION" \
      'line=21 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 25 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g l; then
    assert_state element-down-source-noop element-up-down-top \
      "$CASE_SESSION" 'line=26 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 10 j 3 l
  if operate_and_record element-up-down-top "$CASE_SESSION" g h; then
    assert_state element-up-item element-up-down-top "$CASE_SESSION" \
      'line=11 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 12 j 4 l
  if operate_and_record element-up-down-top "$CASE_SESSION" g h; then
    assert_state element-up-nested-item element-up-down-top "$CASE_SESSION" \
      'line=13 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 16 j 2 l
  if operate_and_record element-up-down-top "$CASE_SESSION" g h; then
    assert_state element-up-table-row element-up-down-top "$CASE_SESSION" \
      'line=16 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 20 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g h; then
    assert_state element-up-quote-body element-up-down-top "$CASE_SESSION" \
      'line=20 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 25 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g h; then
    assert_state element-up-source element-up-down-top "$CASE_SESSION" \
      'line=4 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 29 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g h; then
    assert_state element-up-grand element-up-down-top "$CASE_SESSION" \
      'line=28 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 30 j 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g H; then
    assert_state element-top element-up-down-top "$CASE_SESSION" \
      'line=4 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 0
  if operate_and_record element-up-down-top "$CASE_SESSION" g H; then
    assert_state element-top-preamble-noop element-up-down-top \
      "$CASE_SESSION" 'line=1 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case element-count "$WORKDIR/navigation-elements.org" \
     'Preamble paragraph'; then
  if operate_and_record element-count "$CASE_SESSION" 2 g j; then
    assert_state element-forward-count element-count "$CASE_SESSION" \
      'line=3 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 31 j 0
  if operate_and_record element-count "$CASE_SESSION" 2 g k; then
    assert_state element-backward-count element-count "$CASE_SESSION" \
      'line=4 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 30 j 0
  if operate_and_record element-count "$CASE_SESSION" 2 g h; then
    assert_state element-up-count element-count "$CASE_SESSION" \
      'line=28 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case element-delete "$WORKDIR/navigation-elements.org" \
     'Preamble paragraph'; then
  send_keys "$CASE_SESSION" 3 j 0
  if operate_and_record element-delete "$CASE_SESSION" d g j; then
    assert_state element-delete-subtree element-delete "$CASE_SESSION" \
      'text=Preamble paragraph.\n#+title: Element navigation\nAfter title.\n* Other\nOther body.\n bytes=' \
      'register=* Root\nSCHEDULED: <2026-07-14 Tue>\n' \
      'Sibling body.\n register-type=line' \
      'state=normal selection=none' 'modified=yes'
    send_keys "$CASE_SESSION" u
    if record_state element-delete "$CASE_SESSION"; then
      assert_state element-delete-undo element-delete "$CASE_SESSION" \
        'text=Preamble paragraph.\n#+title: Element navigation\nAfter title.\n* Root\n' \
        '* Other\nOther body.\n bytes=' 'modified=no'
    fi
  fi
  stop_case "$CASE_SESSION"
fi

if start_case element-visual "$WORKDIR/navigation-elements.org" \
     'Preamble paragraph'; then
  send_keys "$CASE_SESSION" 3 j 0 v g j
  if lem_wait_for "$CASE_SESSION" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state element-visual "$CASE_SESSION"; then
    assert_state element-visual-subtree element-visual "$CASE_SESSION" \
      'state=visual-char selection=char' \
      'selected=* Root\nSCHEDULED: <2026-07-14 Tue>\n' \
      'Sibling body.\n*' 'line=34 column=0' 'modified=no'
  else
    fail element-visual-subtree \
      "Visual element motion did not settle or report" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case element-malformed "$WORKDIR/unsafe-unclosed.org" \
     'body without end'; then
  if operate_and_record element-malformed "$CASE_SESSION" g j; then
    assert_state element-malformed-forward element-malformed "$CASE_SESSION" \
      'text=#+begin_src text\nbody without end\n bytes=' \
      'point=1 line=1 column=0' 'state=normal selection=none' \
      'register= register-type=none' 'modified=no'
  fi
  if operate_and_record element-malformed "$CASE_SESSION" d g j; then
    assert_state element-malformed-operator element-malformed "$CASE_SESSION" \
      'text=#+begin_src text\nbody without end\n bytes=' \
      'point=1 line=1 column=0' 'state=normal selection=none' \
      'register= register-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case element-empty "$WORKDIR/navigation-empty-elements.org" \
     'Empty'; then
  if operate_and_record element-empty "$CASE_SESSION" g l; then
    assert_state element-empty-headline element-empty "$CASE_SESSION" \
      'point=1 line=1 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g j 0
  if operate_and_record element-empty "$CASE_SESSION" g l; then
    assert_state element-heading-child element-empty "$CASE_SESSION" \
      'line=3 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 4 j 0
  if operate_and_record element-empty "$CASE_SESSION" g l; then
    assert_state element-empty-drawer element-empty "$CASE_SESSION" \
      'line=5 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" g g 8 j 0
  if operate_and_record element-empty "$CASE_SESSION" g l; then
    assert_state element-empty-quote element-empty "$CASE_SESSION" \
      'line=9 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Evil-Org's always-active sentence motions use Emacs double-space sentence
# boundaries, while table rows dispatch to Org field boundaries with the
# complete count.  These assertions are literal-key TUI checks.
if start_case navigation-sentence-forward \
     "$WORKDIR/navigation-sentence.org" 'One.*Two'; then
  if operate_and_record navigation-sentence-forward "$CASE_SESSION" ')'; then
    assert_state navigation-sentence-forward navigation-sentence-forward \
      "$CASE_SESSION" 'point=7 line=1 column=6' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-sentence-count \
     "$WORKDIR/navigation-sentence.org" 'One.*Two'; then
  if operate_and_record navigation-sentence-count "$CASE_SESSION" 2 ')'; then
    assert_state navigation-sentence-count navigation-sentence-count \
      "$CASE_SESSION" 'point=13 line=1 column=12' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-sentence-backward \
     "$WORKDIR/navigation-sentence.org" 'One.*Two'; then
  send_keys "$CASE_SESSION" 12 l
  if operate_and_record navigation-sentence-backward "$CASE_SESSION" '('; then
    assert_state navigation-sentence-backward navigation-sentence-backward \
      "$CASE_SESSION" 'point=7 line=1 column=6' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-sentence-wrapped-forward \
     "$WORKDIR/navigation-sentence-wrapped.org" 'Wrapped first'; then
  if operate_and_record navigation-sentence-wrapped-forward \
       "$CASE_SESSION" ')'; then
    assert_state navigation-sentence-wrapped-forward \
      navigation-sentence-wrapped-forward "$CASE_SESSION" \
      'line=3 column=0' 'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-sentence-wrapped-backward \
     "$WORKDIR/navigation-sentence-wrapped.org" 'After terminal'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record navigation-sentence-wrapped-backward \
       "$CASE_SESSION" '('; then
    assert_state navigation-sentence-wrapped-backward \
      navigation-sentence-wrapped-backward "$CASE_SESSION" \
      'line=1 column=0' 'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-table-forward \
     "$WORKDIR/navigation-table.org" 'aa.*bb'; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record navigation-table-forward "$CASE_SESSION" 2 ')'; then
    assert_state navigation-table-forward navigation-table-forward \
      "$CASE_SESSION" 'line=1 column=9' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-table-backward \
     "$WORKDIR/navigation-table.org" 'aa.*bb'; then
  send_keys "$CASE_SESSION" j 7 l
  if operate_and_record navigation-table-backward "$CASE_SESSION" 2 '('; then
    assert_state navigation-table-backward navigation-table-backward \
      "$CASE_SESSION" 'line=2 column=2' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# GNU Org paragraph motions traverse adjacent structural units.  Affiliated
# keywords and their prose form one unit, as do single-line lists and tables.
if start_case navigation-structure-forward \
     "$WORKDIR/navigation-structure.org" 'Heading'; then
  if operate_and_record navigation-structure-forward "$CASE_SESSION" '}'; then
    assert_state navigation-heading-forward navigation-structure-forward \
      "$CASE_SESSION" 'line=2 column=0' 'modified=no'
  fi
  if operate_and_record navigation-structure-forward "$CASE_SESSION" '}'; then
    assert_state navigation-prose-forward navigation-structure-forward \
      "$CASE_SESSION" 'line=3 column=0' 'modified=no'
  fi
  if operate_and_record navigation-structure-forward "$CASE_SESSION" '}'; then
    assert_state navigation-list-forward navigation-structure-forward \
      "$CASE_SESSION" 'line=5 column=0' 'modified=no'
  fi
  if operate_and_record navigation-structure-forward "$CASE_SESSION" '}'; then
    assert_state navigation-table-forward-paragraph \
      navigation-structure-forward "$CASE_SESSION" \
      'line=7 column=0' 'modified=no'
  fi
  if operate_and_record navigation-structure-forward "$CASE_SESSION" '}'; then
    assert_state navigation-keyword-forward navigation-structure-forward \
      "$CASE_SESSION" 'line=9 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-structure-backward \
     "$WORKDIR/navigation-structure.org" 'Child body'; then
  send_keys "$CASE_SESSION" 8 j
  if operate_and_record navigation-structure-backward "$CASE_SESSION" '{'; then
    assert_state navigation-child-backward navigation-structure-backward \
      "$CASE_SESSION" 'line=7 column=0' 'modified=no'
  fi
  if operate_and_record navigation-structure-backward "$CASE_SESSION" '{'; then
    assert_state navigation-keyword-backward navigation-structure-backward \
      "$CASE_SESSION" 'line=5 column=0' 'modified=no'
  fi
  if operate_and_record navigation-structure-backward "$CASE_SESSION" '{'; then
    assert_state navigation-table-backward-paragraph \
      navigation-structure-backward "$CASE_SESSION" \
      'line=3 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-separated-count \
     "$WORKDIR/navigation-separated.org" 'First paragraph'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record navigation-separated-count "$CASE_SESSION" 2 '}'; then
    assert_state navigation-separated-count navigation-separated-count \
      "$CASE_SESSION" 'line=7 column=0' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-drawer-forward \
     "$WORKDIR/navigation-separated.org" 'ID: value'; then
  send_keys "$CASE_SESSION" 8 j
  if operate_and_record navigation-drawer-forward "$CASE_SESSION" '}'; then
    assert_state navigation-drawer-forward navigation-drawer-forward \
      "$CASE_SESSION" 'line=10 column=0' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-block-forward \
     "$WORKDIR/navigation-separated.org" 'block one'; then
  send_keys "$CASE_SESSION" 12 j
  if operate_and_record navigation-block-forward "$CASE_SESSION" '}'; then
    assert_state navigation-block-forward navigation-block-forward \
      "$CASE_SESSION" 'line=14 column=0' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-block-backward \
     "$WORKDIR/navigation-separated.org" 'block two'; then
  send_keys "$CASE_SESSION" 14 j
  if operate_and_record navigation-block-backward "$CASE_SESSION" '{'; then
    assert_state navigation-block-backward navigation-block-backward \
      "$CASE_SESSION" 'line=14 column=0' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-complex-list-forward \
     "$WORKDIR/navigation-complex-list.org" 'first item'; then
  if operate_and_record navigation-complex-list-forward \
       "$CASE_SESSION" '}'; then
    assert_state navigation-complex-list-first \
      navigation-complex-list-forward "$CASE_SESSION" \
      'line=3 column=0' 'modified=no'
  fi
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record navigation-complex-list-forward \
       "$CASE_SESSION" '}'; then
    assert_state navigation-complex-list-parent \
      navigation-complex-list-forward "$CASE_SESSION" \
      'line=6 column=0' 'modified=no'
  fi
  if operate_and_record navigation-complex-list-forward \
       "$CASE_SESSION" '}'; then
    assert_state navigation-complex-list-child \
      navigation-complex-list-forward "$CASE_SESSION" \
      'line=7 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-complex-list-continuation \
     "$WORKDIR/navigation-complex-list.org" 'continuation text'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record navigation-complex-list-continuation \
       "$CASE_SESSION" '}'; then
    assert_state navigation-complex-list-continuation \
      navigation-complex-list-continuation "$CASE_SESSION" \
      'line=3 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-complex-list-backward \
     "$WORKDIR/navigation-complex-list.org" 'second item'; then
  send_keys "$CASE_SESSION" 2 j 2 l
  if operate_and_record navigation-complex-list-backward \
       "$CASE_SESSION" '{'; then
    assert_state navigation-complex-list-backward \
      navigation-complex-list-backward "$CASE_SESSION" \
      'line=3 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-formula-forward \
     "$WORKDIR/navigation-formula-table.org" 'a.*b'; then
  if operate_and_record navigation-formula-forward "$CASE_SESSION" '}'; then
    assert_state navigation-formula-forward navigation-formula-forward \
      "$CASE_SESSION" 'line=4 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-formula-backward \
     "$WORKDIR/navigation-formula-table.org" 'AFTER'; then
  send_keys "$CASE_SESSION" 3 j
  if operate_and_record navigation-formula-backward "$CASE_SESSION" '{'; then
    assert_state navigation-formula-backward navigation-formula-backward \
      "$CASE_SESSION" 'line=1 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-clocks-forward \
     "$WORKDIR/navigation-clocks.org" '09:00'; then
  if operate_and_record navigation-clocks-forward "$CASE_SESSION" '}'; then
    assert_state navigation-clocks-forward navigation-clocks-forward \
      "$CASE_SESSION" 'line=3 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-clocks-backward \
     "$WORKDIR/navigation-clocks.org" 'AFTER'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record navigation-clocks-backward "$CASE_SESSION" '{'; then
    assert_state navigation-clocks-backward navigation-clocks-backward \
      "$CASE_SESSION" 'line=1 column=0' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Exclusive motion shape must survive both operator-pending and Visual state.
if start_case navigation-delete-sentence \
     "$WORKDIR/navigation-sentence.org" 'One.*Two'; then
  if operate_and_record navigation-delete-sentence "$CASE_SESSION" d ')'; then
    assert_state navigation-delete-sentence navigation-delete-sentence \
      "$CASE_SESSION" 'text=Two!  Three?\nFour.\n\nFive.  Six.\n bytes=' \
      'register=One.   register-type=char' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state navigation-delete-sentence "$CASE_SESSION"
    assert_state navigation-delete-sentence-undo navigation-delete-sentence \
      "$CASE_SESSION" \
      'text=One.  Two!  Three?\nFour.\n\nFive.  Six.\n bytes=' \
      'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-delete-paragraph \
     "$WORKDIR/navigation-structure.org" 'Heading'; then
  if operate_and_record navigation-delete-paragraph "$CASE_SESSION" d '}'; then
    assert_state navigation-delete-paragraph navigation-delete-paragraph \
      "$CASE_SESSION" 'text=Paragraph text.\n- item one\n' \
      'register=* Heading\n register-type=line' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-delete-paragraph-midline \
     "$WORKDIR/navigation-structure.org" 'Heading'; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record navigation-delete-paragraph-midline \
       "$CASE_SESSION" d '}'; then
    assert_state navigation-delete-paragraph-midline \
      navigation-delete-paragraph-midline "$CASE_SESSION" \
      'text=* \nParagraph text.\n- item one\n' \
      'register=Heading register-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-visual-sentence \
     "$WORKDIR/navigation-sentence.org" 'One.*Two'; then
  send_keys "$CASE_SESSION" v ')'
  if lem_wait_for "$CASE_SESSION" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state navigation-visual-sentence "$CASE_SESSION"; then
    assert_state navigation-visual-sentence navigation-visual-sentence \
      "$CASE_SESSION" 'state=visual-char selection=char' \
      'selected=One.  T' 'modified=no'
  else
    fail navigation-visual-sentence \
      "Visual sentence motion did not settle or report" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case navigation-visual-paragraph \
     "$WORKDIR/navigation-structure.org" 'Heading'; then
  send_keys "$CASE_SESSION" v '}'
  if lem_wait_for "$CASE_SESSION" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state navigation-visual-paragraph "$CASE_SESSION"; then
    assert_state navigation-visual-paragraph navigation-visual-paragraph \
      "$CASE_SESSION" 'state=visual-char selection=char' \
      'selected=* Heading\nP' 'modified=no'
  else
    fail navigation-visual-paragraph \
      "Visual paragraph motion did not settle or report" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

# The pinned base map makes < and > true range operators.  They dispatch by
# Org context while retaining ordinary Evil ranges, counts, Visual exit, and
# one-step undo.
if start_case shift-heading "$WORKDIR/shift-heading.org" 'H1'; then
  if operate_and_record shift-heading "$CASE_SESSION" '>' 2 j; then
    assert_state shift-heading shift-heading "$CASE_SESSION" \
      'text=** H1\nbody\n** H2\nbody2\n** Child\n bytes=' \
      'state=normal selection=none' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state shift-heading "$CASE_SESSION"
    assert_state shift-heading-undo shift-heading "$CASE_SESSION" \
      'text=* H1\nbody\n* H2\nbody2\n** Child\n bytes=' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-heading-left "$WORKDIR/shift-heading.org" 'Child'; then
  send_keys "$CASE_SESSION" 4 j
  if operate_and_record shift-heading-left "$CASE_SESSION" '<' '<'; then
    assert_state shift-heading-left shift-heading-left "$CASE_SESSION" \
      'text=* H1\nbody\n* H2\nbody2\n* Child\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-heading-abort \
     "$WORKDIR/shift-heading-abort.org" 'H1'; then
  if operate_and_record shift-heading-abort "$CASE_SESSION" '<' '<'; then
    assert_state shift-heading-abort shift-heading-abort "$CASE_SESSION" \
      'text=* H1\nbody\n bytes=' 'modified=no' \
      'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-list-single "$WORKDIR/shift-list.org" 'two'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record shift-list-single "$CASE_SESSION" '>' '>'; then
    assert_state shift-list-single shift-list-single "$CASE_SESSION" \
      'text=- one\n  - two\n  - child\n- three\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-list-range "$WORKDIR/shift-list.org" 'two'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record shift-list-range "$CASE_SESSION" '>' j; then
    assert_state shift-list-range shift-list-range "$CASE_SESSION" \
      'text=- one\n  - two\n    - child\n- three\n bytes=' 'modified=yes'
    if operate_and_record shift-list-range "$CASE_SESSION" '<' j; then
      assert_state shift-list-range-left shift-list-range "$CASE_SESSION" \
        'text=- one\n- two\n  - child\n- three\n bytes=' 'modified=yes'
    fi
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-ordered "$WORKDIR/shift-ordered.org" '2\. two'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record shift-ordered "$CASE_SESSION" '>' '>'; then
    assert_state shift-ordered shift-ordered "$CASE_SESSION" \
      'text=1. one\n   1. two\n2. three\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-list-top "$WORKDIR/shift-list-top.org" 'one'; then
  if operate_and_record shift-list-top "$CASE_SESSION" '>' '>'; then
    assert_state shift-list-top shift-list-top "$CASE_SESSION" \
      'text= - one\n   continuation\n - two\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-table-column "$WORKDIR/shift-table.org" ' a '; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record shift-table-column "$CASE_SESSION" '>' l; then
    assert_state shift-table-column shift-table-column "$CASE_SESSION" \
      'text=| b | a | c |\n| e | d | f |\n bytes=' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state shift-table-column "$CASE_SESSION"
    assert_state shift-table-column-undo shift-table-column "$CASE_SESSION" \
      'text=| a | b | c |\n| d | e | f |\n bytes=' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-table-column-motion-count \
     "$WORKDIR/shift-table.org" ' a '; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record shift-table-column-motion-count \
       "$CASE_SESSION" '>' 2 l; then
    assert_state shift-table-column-motion-count \
      shift-table-column-motion-count "$CASE_SESSION" \
      'text=| b | a | c |\n| e | d | f |\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-table-column-operator-count \
     "$WORKDIR/shift-table.org" ' a '; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record shift-table-column-operator-count \
       "$CASE_SESSION" 2 '>' l; then
    assert_state shift-table-column-operator-count \
      shift-table-column-operator-count "$CASE_SESSION" \
      'text=| b | a | c |\n| e | d | f |\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-table-column-left "$WORKDIR/shift-table.org" ' a '; then
  send_keys "$CASE_SESSION" 6 l
  if operate_and_record shift-table-column-left "$CASE_SESSION" '<' l; then
    assert_state shift-table-column-left shift-table-column-left \
      "$CASE_SESSION" \
      'text=| b | a | c |\n| e | d | f |\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-table-column-wide-visual \
     "$WORKDIR/shift-table.org" ' a '; then
  send_keys "$CASE_SESSION" 2 l v 8 l
  if operate_and_record shift-table-column-wide-visual \
       "$CASE_SESSION" '>'; then
    assert_state shift-table-column-wide-visual \
      shift-table-column-wide-visual "$CASE_SESSION" \
      'text=| b | c | a |\n| e | f | d |\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-table-lines "$WORKDIR/shift-table.org" ' a '; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record shift-table-lines "$CASE_SESSION" '>' '>'; then
    assert_state shift-table-lines shift-table-lines "$CASE_SESSION" \
      'text=    | a | b | c |\n    | d | e | f |\n bytes=' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-table-formula \
     "$WORKDIR/shift-table-formula.org" ' a '; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record shift-table-formula "$CASE_SESSION" '>' l; then
    assert_state shift-table-formula shift-table-formula "$CASE_SESSION" \
      'text=| b | a |\n| d | c |\n#+TBLFM: $2=1\n bytes=' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state shift-table-formula "$CASE_SESSION"
    assert_state shift-table-formula-undo shift-table-formula "$CASE_SESSION" \
      'text=| a | b |\n| c | d |\n#+TBLFM: $1=1\n bytes=' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-prose "$WORKDIR/shift-prose.org" 'alpha'; then
  if operate_and_record shift-prose "$CASE_SESSION" 2 '>' '>'; then
    assert_state shift-prose shift-prose "$CASE_SESSION" \
      'text=    alpha\n    beta\ngamma\n bytes=' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state shift-prose "$CASE_SESSION"
    assert_state shift-prose-undo shift-prose "$CASE_SESSION" \
      'text=alpha\nbeta\ngamma\n bytes=' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case shift-heading-visual "$WORKDIR/shift-heading.org" 'H1'; then
  send_keys "$CASE_SESSION" V 2 j
  if operate_and_record shift-heading-visual "$CASE_SESSION" '>'; then
    assert_state shift-heading-visual shift-heading-visual "$CASE_SESSION" \
      'text=** H1\nbody\n** H2\nbody2\n** Child\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

# Evil-Org exposes GNU Org's Meta commands directly in Visual state.  The
# unshifted commands keep the selection live and operate on its structural
# region; shifted commands use the expanded moving endpoint and leave Visual
# state after a successful edit.
if start_case visual-meta-heading-level \
     "$WORKDIR/visual-meta-headings.org" 'A child'; then
  send_keys "$CASE_SESSION" V 2 j M-l
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-heading-level "$CASE_SESSION"; then
    assert_state visual-meta-heading-level visual-meta-heading-level \
      "$CASE_SESSION" \
      'text=** A\n*** A child\n** B\n* C\n bytes=' \
      'state=visual-line selection=line' \
      'selected=** A\n*** A child\n** B\n' 'modified=yes'
    send_keys "$CASE_SESSION" Escape u
    if record_state visual-meta-heading-level "$CASE_SESSION"; then
      assert_state visual-meta-heading-level-undo \
        visual-meta-heading-level "$CASE_SESSION" \
        'text=* A\n** A child\n* B\n* C\n bytes=' \
        'state=normal selection=none' 'modified=no'
    fi
  else
    fail visual-meta-heading-level \
      "Visual heading demotion did not retain and report its range" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-heading-promote-reverse \
     "$WORKDIR/visual-meta-headings-promote.org" 'A child'; then
  send_keys "$CASE_SESSION" 2 j V 2 k M-h
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-heading-promote-reverse "$CASE_SESSION"; then
    assert_state visual-meta-heading-promote-reverse \
      visual-meta-heading-promote-reverse "$CASE_SESSION" \
      'text=* A\n** A child\n* B\n* C\n bytes=' \
      'state=visual-line selection=line' \
      'selected=* A\n** A child\n* B\n' 'modified=yes'
  else
    fail visual-meta-heading-promote-reverse \
      "reverse Visual heading promotion did not settle" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-heading-move \
     "$WORKDIR/visual-meta-heading-move.org" 'A child'; then
  send_keys "$CASE_SESSION" V j M-j
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-heading-move "$CASE_SESSION"; then
    assert_state visual-meta-heading-move visual-meta-heading-move \
      "$CASE_SESSION" \
      'text=* B\n* A\n** A child\n* C\n bytes=' \
      'state=visual-line selection=line' \
      'selected=* A\n** A child\n' 'modified=yes'
  else
    fail visual-meta-heading-move \
      "selected subtree movement did not settle" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-list-indent \
     "$WORKDIR/visual-meta-list.org" 'zero'; then
  send_keys "$CASE_SESSION" j V j M-l
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-list-indent "$CASE_SESSION"; then
    assert_state visual-meta-list-indent visual-meta-list-indent \
      "$CASE_SESSION" \
      'text=- zero\n  - one\n  - two\n- three\n bytes=' \
      'state=visual-line selection=line' \
      'selected=  - one\n  - two\n' 'modified=yes'
  else
    fail visual-meta-list-indent \
      "Visual list indentation did not settle" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-list-outdent-reverse \
     "$WORKDIR/visual-meta-list-outdent.org" 'zero'; then
  send_keys "$CASE_SESSION" 2 j V k M-h
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-list-outdent-reverse "$CASE_SESSION"; then
    assert_state visual-meta-list-outdent-reverse \
      visual-meta-list-outdent-reverse "$CASE_SESSION" \
      'text=- zero\n- one\n- two\n- three\n bytes=' \
      'state=visual-line selection=line' \
      'selected=- one\n- two\n' 'modified=yes'
  else
    fail visual-meta-list-outdent-reverse \
      "reverse Visual list outdent did not settle" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-lines-down \
     "$WORKDIR/visual-meta-lines.org" 'zero'; then
  send_keys "$CASE_SESSION" j V j M-j
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-lines-down "$CASE_SESSION"; then
    assert_state visual-meta-lines-down visual-meta-lines-down \
      "$CASE_SESSION" \
      'text=zero\nthree\none\ntwo\nfour\n bytes=' \
      'state=visual-line selection=line' \
      'selected=one\ntwo\n' 'modified=yes'
  else
    fail visual-meta-lines-down \
      "Visual line-region movement did not settle" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-lines-up-block \
     "$WORKDIR/visual-meta-lines.org" 'zero'; then
  send_keys "$CASE_SESSION" 2 j C-v k M-k
  if lem_wait_for "$CASE_SESSION" 'V-BLOCK' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-lines-up-block "$CASE_SESSION"; then
    assert_state visual-meta-lines-up-block visual-meta-lines-up-block \
      "$CASE_SESSION" \
      'text=one\ntwo\nzero\nthree\nfour\n bytes=' \
      'state=visual-block selection=block' 'modified=yes'
  else
    fail visual-meta-lines-up-block \
      "Visual Block line-region movement did not settle" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-table-reverse \
     "$WORKDIR/visual-meta-table.org" 'AFTER'; then
  send_keys "$CASE_SESSION" j V k M-l
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-table-reverse "$CASE_SESSION"; then
    assert_state visual-meta-table-reverse visual-meta-table-reverse \
      "$CASE_SESSION" \
      'text=| b | a |\n| d | c |\nAFTER\n bytes=' \
      'state=visual-line selection=line' 'modified=yes'
  else
    fail visual-meta-table-reverse \
      "reverse Visual table context did not move its column" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-list \
     "$WORKDIR/visual-meta-list-tree.org" 'continuation'; then
  send_keys "$CASE_SESSION" j V 2 j M-L
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-list "$CASE_SESSION"; then
    assert_state visual-shift-meta-list visual-shift-meta-list \
      "$CASE_SESSION" \
      'text=- zero\n  - one\n    continuation\n    - child\n- two\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  else
    fail visual-shift-meta-list \
      "shifted Visual list-tree edit did not exit Visual state" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-list-left \
     "$WORKDIR/visual-meta-list-tree-outdent.org" 'continuation'; then
  send_keys "$CASE_SESSION" j V 2 j M-H
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-list-left "$CASE_SESSION"; then
    assert_state visual-shift-meta-list-left visual-shift-meta-list-left \
      "$CASE_SESSION" \
      'text=- zero\n- one\n  continuation\n  - child\n- two\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  else
    fail visual-shift-meta-list-left \
      "shifted Visual list-tree outdent did not exit Visual state" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-heading-context \
     "$WORKDIR/visual-shift-meta-heading.org" 'A child'; then
  send_keys "$CASE_SESSION" V 2 j M-L
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-heading-context "$CASE_SESSION"; then
    assert_state visual-shift-meta-heading-context \
      visual-shift-meta-heading-context "$CASE_SESSION" \
      'text=* A\n** A child\n* B\n** C\n* D\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  else
    fail visual-shift-meta-heading-context \
      "shifted heading command did not use the expanded endpoint" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-line-context \
     "$WORKDIR/visual-shift-meta-lines.org" 'zero'; then
  send_keys "$CASE_SESSION" j V j M-K
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-line-context "$CASE_SESSION"; then
    assert_state visual-shift-meta-line-context \
      visual-shift-meta-line-context "$CASE_SESSION" \
      'text=zero\none\nthree\ntwo\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  else
    fail visual-shift-meta-line-context \
      "shifted line command did not use the expanded endpoint" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-line-down-context \
     "$WORKDIR/visual-meta-lines.org" 'zero'; then
  send_keys "$CASE_SESSION" j V j M-J
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-line-down-context "$CASE_SESSION"; then
    assert_state visual-shift-meta-line-down-context \
      visual-shift-meta-line-down-context "$CASE_SESSION" \
      'text=zero\none\ntwo\nfour\nthree\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  else
    fail visual-shift-meta-line-down-context \
      "shifted downward line command did not use the expanded endpoint" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-clock-up \
     "$WORKDIR/visual-shift-meta-clock-up.org" 'CLOCK:'; then
  send_keys "$CASE_SESSION" v 2 6 l M-K
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-clock-up "$CASE_SESSION"; then
    assert_state visual-shift-meta-clock-up \
      visual-shift-meta-clock-up "$CASE_SESSION" \
      'text=CLOCK: [2026-07-14 Tue 09:05]--[2026-07-14 Tue 10:00] =>  0:55\n bytes=' \
      'state=normal selection=none' 'modified=yes'
    send_keys "$CASE_SESSION" u
    if record_state visual-shift-meta-clock-up "$CASE_SESSION"; then
      assert_state visual-shift-meta-clock-up-undo \
        visual-shift-meta-clock-up "$CASE_SESSION" \
        'text=CLOCK: [2026-07-14 Tue 09:00]--[2026-07-14 Tue 10:00] =>  1:00\n bytes=' \
        'state=normal selection=none' 'modified=no'
    else
      fail visual-shift-meta-clock-up-undo \
        "Visual CLOCK adjustment did not undo" "$CASE_SESSION"
    fi
  else
    record_state visual-shift-meta-clock-up "$CASE_SESSION" || true
    fail visual-shift-meta-clock-up \
      "forward Visual CLOCK adjustment did not exit Visual state" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-clock-down \
     "$WORKDIR/visual-shift-meta-clock-down.org" 'CLOCK:'; then
  send_keys "$CASE_SESSION" 5 0 l v 2 4 h M-J
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-clock-down "$CASE_SESSION"; then
    assert_state visual-shift-meta-clock-down \
      visual-shift-meta-clock-down "$CASE_SESSION" \
      'text=CLOCK: [2026-07-14 Tue 08:55]--[2026-07-14 Tue 10:00] =>  1:05\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  else
    record_state visual-shift-meta-clock-down "$CASE_SESSION" || true
    fail visual-shift-meta-clock-down \
      "reverse Visual CLOCK adjustment did not exit Visual state" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-shift-meta-table-reverse \
     "$WORKDIR/visual-meta-table.org" 'AFTER'; then
  send_keys "$CASE_SESSION" j V k M-K
  if lem_wait_for "$CASE_SESSION" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-shift-meta-table-reverse "$CASE_SESSION"; then
    assert_state visual-shift-meta-table-reverse \
      visual-shift-meta-table-reverse "$CASE_SESSION" \
      'text=| c | d |\nAFTER\n bytes=' \
      'state=normal selection=none' 'modified=yes'
  else
    fail visual-shift-meta-table-reverse \
      "reverse shifted Visual table context did not delete its row" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-meta-level-guard \
     "$WORKDIR/visual-meta-headings.org" 'A child'; then
  send_keys "$CASE_SESSION" V 2 j M-h
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-meta-level-guard "$CASE_SESSION"; then
    assert_state visual-meta-level-guard visual-meta-level-guard \
      "$CASE_SESSION" 'text=* A\n** A child\n* B\n* C\n bytes=' \
      'state=visual-line selection=line' \
      'selected=* A\n** A child\n* B\n' 'modified=no'
  else
    fail visual-meta-level-guard \
      "unsafe region promotion did not preserve Visual state" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

# Evil-Org's destructive base map repairs ordinary numbered lists and tags,
# preserves a single deleted table cell's width, and leaves counted/Visual
# table deletion on ordinary Evil semantics.
if start_case delete-ordered "$WORKDIR/delete-ordered.org" '1\. one'; then
  if operate_and_record delete-ordered "$CASE_SESSION" d d; then
    assert_state delete-ordered delete-ordered "$CASE_SESSION" \
      'text=1. two\n2. three\n bytes=' \
      'register=1. one\n register-type=line' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state delete-ordered "$CASE_SESSION"
    assert_state delete-ordered-undo delete-ordered "$CASE_SESSION" \
      'text=1. one\n2. two\n3. three\n bytes=' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-ordered-counter \
     "$WORKDIR/delete-ordered-counter.org" '1\. one'; then
  if operate_and_record delete-ordered-counter "$CASE_SESSION" d d; then
    assert_state delete-ordered-counter delete-ordered-counter \
      "$CASE_SESSION" 'text=5. [@5] five\n6. six\n bytes=' \
      'register=1. one\n register-type=line' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-ordered-nested \
     "$WORKDIR/delete-ordered-nested.org" '1\. top'; then
  if operate_and_record delete-ordered-nested "$CASE_SESSION" 2 d d; then
    assert_state delete-ordered-nested delete-ordered-nested \
      "$CASE_SESSION" 'text=1. second\n2. third\n bytes=' \
      'register=1. top\n   1. child\n register-type=line' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-ordered-unsafe \
     "$WORKDIR/delete-ordered-unsafe.org" '1\. one'; then
  if operate_and_record delete-ordered-unsafe "$CASE_SESSION" d d; then
    assert_state delete-ordered-unsafe delete-ordered-unsafe \
      "$CASE_SESSION" \
      'text=1. one\n   continuation\n2. two\n bytes=' \
      'register= register-type=none' 'small= small-type=none' \
      'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-heading-tag \
     "$WORKDIR/delete-heading-tag.org" 'Alpha beta'; then
  send_keys "$CASE_SESSION" 2 w
  if operate_and_record delete-heading-tag "$CASE_SESSION" d a w; then
    assert_state delete-heading-tag delete-heading-tag "$CASE_SESSION" \
      'text=* TODO beta' ':work:\n bytes=78 ' \
      'register=Alpha  register-type=char' \
      'small=Alpha  small-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-table "$WORKDIR/delete-table.org" 'abc'; then
  send_keys "$CASE_SESSION" 3 l
  if operate_and_record delete-table "$CASE_SESSION" x; then
    assert_state delete-table delete-table "$CASE_SESSION" \
      'text=| ac  | de |\n bytes=' 'register=b register-type=char' \
      'small=b small-type=char' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state delete-table "$CASE_SESSION"
    assert_state delete-table-undo delete-table "$CASE_SESSION" \
      'text=| abc | de |\n bytes=' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-table-backward \
     "$WORKDIR/delete-table-backward.org" 'abc'; then
  send_keys "$CASE_SESSION" 4 l
  if operate_and_record delete-table-backward "$CASE_SESSION" X; then
    assert_state delete-table-backward delete-table-backward \
      "$CASE_SESSION" 'text=| ac  | de |\n bytes=' \
      'register=b register-type=char' 'small=b small-type=char'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-table-count "$WORKDIR/delete-table-count.org" 'abc'; then
  send_keys "$CASE_SESSION" 3 l
  if operate_and_record delete-table-count "$CASE_SESSION" 2 x; then
    assert_state delete-table-count delete-table-count "$CASE_SESSION" \
      'text=| a | de |\n bytes=' 'register=bc register-type=char' \
      'small=bc small-type=char'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case delete-table-visual "$WORKDIR/delete-table-visual.org" 'abc'; then
  send_keys "$CASE_SESSION" 3 l v l
  if operate_and_record delete-table-visual "$CASE_SESSION" x; then
    assert_state delete-table-visual delete-table-visual "$CASE_SESSION" \
      'text=| a | de |\n bytes=' 'register=bc register-type=char' \
      'small=bc small-type=char' 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

# Inline code objects: outer includes markup/post-blank; inner keeps delimiters.
if start_case dae "$WORKDIR/inline-outer.org" 'code.*tail'; then
  if operate_and_record dae "$CASE_SESSION" d a e; then
    assert_state dae dae "$CASE_SESSION" \
      'text=tail\n bytes=' 'state=normal selection=none' \
      'register=~code~  register-type=char' \
      'small=~code~  small-type=char' 'modified=yes'
    send_keys "$CASE_SESSION" u
    record_state dae "$CASE_SESSION"
    assert_state dae-undo dae "$CASE_SESSION" 'text=~code~ tail\n bytes='
  fi
  stop_case "$CASE_SESSION"
fi

if start_case die "$WORKDIR/inline-inner.org" 'code.*tail'; then
  if operate_and_record die "$CASE_SESSION" d i e; then
    assert_state die die "$CASE_SESSION" \
      'text=~~ tail\n bytes=' 'register=code register-type=char' \
      'small=code small-type=char' 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

# Org object post-blank belongs to the inline object even when point is on
# that horizontal whitespace.
if start_case postblank "$WORKDIR/inline-outer.org" 'code.*tail'; then
  send_keys "$CASE_SESSION" 6 l
  if operate_and_record postblank "$CASE_SESSION" d a e; then
    assert_state postblank-object postblank "$CASE_SESSION" \
      'text=tail\n bytes=' 'register=~code~  register-type=char' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

# Source block element objects: outer removes the block; inner removes its body.
if start_case daE "$WORKDIR/source-outer.org" 'source body'; then
  if operate_and_record daE "$CASE_SESSION" d a E; then
    assert_state daE daE "$CASE_SESSION" \
      'text=AFTER\n bytes=' 'register=#+begin_src text\nsource body\n#+end_src\n' \
      'register-type=char' 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case diE "$WORKDIR/source-inner.org" 'source body'; then
  if operate_and_record diE "$CASE_SESSION" d i E; then
    assert_state diE diE "$CASE_SESSION" \
      'text=#+begin_src text\n#+end_src\nAFTER\n bytes=' \
      'register=source body\n register-type=char' \
      'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

# Recursive list items: ar is linewise; ir is the charwise item contents.
if start_case dar "$WORKDIR/list-outer.org" 'parent'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record dar "$CASE_SESSION" d a r; then
    assert_state dar dar "$CASE_SESSION" \
      'text=- sibling\n bytes=' \
      'register=- parent\n  - child\n register-type=line' \
      'state=normal selection=none'
    send_keys "$CASE_SESSION" u
    record_state dar "$CASE_SESSION"
    assert_state dar-undo dar "$CASE_SESSION" \
      'text=- parent\n  - child\n- sibling\n bytes='
  fi
  stop_case "$CASE_SESSION"
fi

if start_case yir "$WORKDIR/list-inner.org" 'parent'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record yir "$CASE_SESSION" y i r; then
    assert_state yir yir "$CASE_SESSION" \
      'text=- parent\n  - child\n- sibling\n bytes=' \
      'register=parent\n  - child\n register-type=char' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Unterminated EOF is still a valid boundary for a safe list item tree.
if start_case yir-eof "$WORKDIR/list-eof.org" 'parent'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record yir-eof "$CASE_SESSION" y i r; then
    assert_state yir-eof yir-eof "$CASE_SESSION" \
      'text=- parent\n  - child bytes=' \
      'register=parent\n  - child register-type=char' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Outer counts retain Evil-Org's original-point anchor while advancing to the
# second object/element.
if start_case count-object "$WORKDIR/count-object.org" 'one.*two'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record count-object "$CASE_SESSION" 2 y a e; then
    assert_state count-object-anchor count-object "$CASE_SESSION" \
      'text=~one~ ~two~ tail\n bytes=' \
      'register=one~ ~two~  register-type=char' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case count-element "$WORKDIR/count-element.org" 'P1'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record count-element "$CASE_SESSION" 2 y a E; then
    assert_state count-element-anchor count-element "$CASE_SESSION" \
      'text=P1\n\nP2\n\nAFTER\n bytes=' \
      'register=1\n\nP2\n\n register-type=char' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case count-heading "$WORKDIR/count-heading.org" 'P1'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record count-heading "$CASE_SESSION" 2 y a E; then
    assert_state count-heading-element count-heading "$CASE_SESSION" \
      'register=1\n\n* H\nbody\n register-type=char' 'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 l
  if operate_and_record count-heading "$CASE_SESSION" 2 y a e; then
    assert_state count-heading-object count-heading "$CASE_SESSION" \
      'register=1\n\n* H\nbody\n register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case count-object-barrier "$WORKDIR/count-object-barrier.org" \
     'fn:note'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record count-object-barrier "$CASE_SESSION" 2 y a e; then
    assert_state count-object-barrier-abort count-object-barrier \
      "$CASE_SESSION" 'text=~one~ [fn:note] ~two~\n bytes=' \
      'register= register-type=none' 'small= small-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case count-element-barrier "$WORKDIR/count-element-barrier.org" \
     'ID: orphan'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record count-element-barrier "$CASE_SESSION" 2 y a E; then
    assert_state count-element-barrier-abort count-element-barrier \
      "$CASE_SESSION" 'text=P1\n\n:ID: orphan\n\nP2\n bytes=' \
      'register= register-type=none' 'small= small-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Org distinguishes absolute BOL (plain-list), the item prefix, and item text
# (paragraph).  Exercise all three rather than inferring context from a line.
if start_case list-context "$WORKDIR/list-context.org" 'parent'; then
  if operate_and_record list-context "$CASE_SESSION" y a r; then
    assert_state list-bol-ar list-context "$CASE_SESSION" \
      'register=- parent\n  - child\n- sibling\n register-type=line'
  fi
  send_keys "$CASE_SESSION" Escape g g 0
  if operate_and_record list-context "$CASE_SESSION" y a E; then
    assert_state list-bol-aE list-context "$CASE_SESSION" \
      'register=- parent\n  - child\n- sibling\n register-type=char'
  fi
  send_keys "$CASE_SESSION" Escape g g 0
  if operate_and_record list-context "$CASE_SESSION" y i r; then
    assert_state list-bol-ir list-context "$CASE_SESSION" \
      'register=- parent\n  - child\n- sibling\n register-type=char'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 2 l
  if operate_and_record list-context "$CASE_SESSION" y a E; then
    assert_state list-text-aE list-context "$CASE_SESSION" \
      'register=parent\n register-type=char'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 2 l
  if operate_and_record list-context "$CASE_SESSION" y a r; then
    assert_state list-text-ar list-context "$CASE_SESSION" \
      'register=- parent\n  - child\n register-type=line'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 2 j 0
  if operate_and_record list-context "$CASE_SESSION" y a E; then
    assert_state list-later-bol-aE list-context "$CASE_SESSION" \
      'register=- sibling\n register-type=char'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 2 j 0
  if operate_and_record list-context "$CASE_SESSION" y a r; then
    assert_state list-later-bol-ar list-context "$CASE_SESSION" \
      'register=- sibling\n register-type=line'
  fi
  stop_case "$CASE_SESSION"
fi

# Empty item contents must never consume the structural newline.  A leaf
# aborts; an empty parent begins its inner range at the child item.
if start_case empty-list-leaf "$WORKDIR/empty-list-leaf.org" 'KEEP'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record empty-list-leaf "$CASE_SESSION" d i r; then
    assert_state empty-list-leaf-ir empty-list-leaf "$CASE_SESSION" \
      'text=- \n- KEEP\n bytes=' 'register= register-type=none' \
      'small= small-type=none' 'modified=no'
  fi
  if operate_and_record empty-list-leaf "$CASE_SESSION" d i E; then
    assert_state empty-list-leaf-iE empty-list-leaf "$CASE_SESSION" \
      'text=- \n- KEEP\n bytes=' 'register= register-type=none' \
      'small= small-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case empty-list-parent "$WORKDIR/empty-list-parent.org" 'child'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record empty-list-parent "$CASE_SESSION" y i r; then
    assert_state empty-list-parent-inner empty-list-parent "$CASE_SESSION" \
      'text=- \n  - child\n- KEEP\n bytes=' \
      'register=  - child\n register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case heading-element "$WORKDIR/heading-element.org" 'Parent'; then
  if operate_and_record heading-element "$CASE_SESSION" y a E; then
    assert_state heading-element-outer heading-element "$CASE_SESSION" \
      'register=* Parent\nBody\n register-type=char' 'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0
  if operate_and_record heading-element "$CASE_SESSION" y i E; then
    assert_state heading-element-inner heading-element "$CASE_SESSION" \
      'register=Body\n register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Subtrees: aR is a linewise whole subtree; iR preserves its heading.
if start_case yaR "$WORKDIR/subtree-outer.org" 'Parent'; then
  if operate_and_record yaR "$CASE_SESSION" y a R; then
    assert_state yaR yaR "$CASE_SESSION" \
      'text=* Parent\nParent body\n** Child\nChild body\n* Sibling\n bytes=' \
      'register=* Parent\nParent body\n** Child\nChild body\n register-type=line' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case diR "$WORKDIR/subtree-inner.org" 'Parent'; then
  if operate_and_record diR "$CASE_SESSION" d i R; then
    assert_state diR diR "$CASE_SESSION" \
      'text=* Parent\n* Sibling\n bytes=' \
      'register=Parent body\n** Child\nChild body\n register-type=line' \
      'state=normal selection=none'
    send_keys "$CASE_SESSION" u
    record_state diR "$CASE_SESSION"
    assert_state diR-undo diR "$CASE_SESSION" \
      'text=* Parent\nParent body\n** Child\nChild body\n* Sibling\n bytes='
  fi
  stop_case "$CASE_SESSION"
fi

# From Grandchild, count 3 climbs two parents and yanks Parent's subtree.
if start_case count-climb "$WORKDIR/count.org" 'Grandchild'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record count-climb "$CASE_SESSION" 3 y a R; then
    assert_state count-climb count-climb "$CASE_SESSION" \
      'register=* Parent\n** Child\n*** Grandchild\nGrand body\n** Child sibling\n register-type=line' \
      'text=* Parent\n** Child\n*** Grandchild\nGrand body\n** Child sibling\n* Top sibling\n bytes=' \
      'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Visual objects must preserve their intended characterwise/linewise shape.
if start_case visual-ae "$WORKDIR/visual-object.org" 'code.*tail'; then
  send_keys "$CASE_SESSION" v a e
  if lem_wait_for "$CASE_SESSION" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-ae "$CASE_SESSION"; then
    assert_state visual-ae visual-ae "$CASE_SESSION" \
      'state=visual-char selection=char selected=~code~ ' \
      'text=~code~ tail\n bytes=' 'modified=no'
  else
    fail visual-ae "visual object did not settle or report" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case visual-aR "$WORKDIR/visual-subtree.org" 'Parent'; then
  send_keys "$CASE_SESSION" v a R
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state visual-aR "$CASE_SESSION"; then
    assert_state visual-aR visual-aR "$CASE_SESSION" \
      'state=visual-line selection=line' \
      'selected=* Parent\nParent body\n** Child\nChild body\n' \
      'text=* Parent\nParent body\n** Child\nChild body\n* Sibling\n bytes=' \
      'modified=no'
  else
    fail visual-aR "linewise visual subtree did not settle or report" \
      "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case reverse-visual "$WORKDIR/reverse-visual.org" 'code.*tail'; then
  send_keys "$CASE_SESSION" 4 l v 3 h a e
  if lem_wait_for "$CASE_SESSION" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null &&
     record_state reverse-visual "$CASE_SESSION"; then
    assert_state reverse-visual-ae reverse-visual "$CASE_SESSION" \
      'state=visual-char selection=char selected=~code~ ' \
      'text=~code~ tail\n bytes=' 'modified=no'
  else
    fail reverse-visual-ae \
      "reverse Visual object did not settle or report" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

if start_case repeated-var "$WORKDIR/repeated-visual-list.org" 'parent'; then
  send_keys "$CASE_SESSION" 2 l v a r
  if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
     record_state repeated-var "$CASE_SESSION"; then
    assert_state repeated-var-item repeated-var "$CASE_SESSION" \
      'state=visual-line selection=line' \
      'selected=- parent\n  - child\n' 'modified=no'
    send_keys "$CASE_SESSION" a r
    if lem_wait_for "$CASE_SESSION" 'V-LINE' "$WAIT_TIMEOUT" >/dev/null &&
       record_state repeated-var "$CASE_SESSION"; then
      assert_state repeated-var-list repeated-var "$CASE_SESSION" \
        'state=visual-line selection=line' \
        'selected=- parent\n  - child\n- sibling\n' 'modified=no'
    else
      fail repeated-var-list \
        "second Visual ar did not settle or report" "$CASE_SESSION"
    fi
  else
    fail repeated-var-item \
      "first Visual ar did not settle or report" "$CASE_SESSION"
  fi
  stop_case "$CASE_SESSION"
fi

# Described bracket links expose distinct outer and description-only ranges.
if start_case link-dae "$WORKDIR/link-outer.org" 'described link.*tail'; then
  if operate_and_record link-dae "$CASE_SESSION" d a e; then
    assert_state link-dae link-dae "$CASE_SESSION" \
      'text=tail\n bytes=' \
      'register=[[file:target.org][described link]]  register-type=char' \
      'small=[[file:target.org][described link]]  small-type=char' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case link-die "$WORKDIR/link-inner.org" 'described link.*tail'; then
  if operate_and_record link-die "$CASE_SESSION" d i e; then
    assert_state link-die link-die "$CASE_SESSION" \
      'text=[[file:target.org][]] tail\n bytes=' \
      'register=described link register-type=char' \
      'small=described link small-type=char' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case link-url-description "$WORKDIR/link-url-description.org" \
     'example.com.*tail'; then
  send_keys "$CASE_SESSION" 12 l
  if operate_and_record link-url-description "$CASE_SESSION" y a e; then
    assert_state link-url-description-outer link-url-description \
      "$CASE_SESSION" \
      'register=[[file:x][https://example.com]]  register-type=char' \
      'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 12 l
  if operate_and_record link-url-description "$CASE_SESSION" y i e; then
    assert_state link-url-description-inner link-url-description \
      "$CASE_SESSION" \
      'register=https://example.com register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case plain-link "$WORKDIR/plain-link.org" 'example.com.*tail'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record plain-link "$CASE_SESSION" y a e; then
    assert_state plain-link-outer plain-link "$CASE_SESSION" \
      'register=https://example.com  register-type=char' 'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 l
  if operate_and_record plain-link "$CASE_SESSION" y i e; then
    assert_state plain-link-inner plain-link "$CASE_SESSION" \
      'register=https://example.com register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case plain-link-underscore "$WORKDIR/plain-link-underscore.org" \
     'foo_bar.*tail'; then
  send_keys "$CASE_SESSION" 25 l
  if operate_and_record plain-link-underscore "$CASE_SESSION" y a e; then
    assert_state plain-link-underscore-opaque plain-link-underscore \
      "$CASE_SESSION" \
      'register=https://example.com/foo_bar  register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case link-target-underscore "$WORKDIR/link-target-underscore.org" \
     'foo_bar.*desc'; then
  send_keys "$CASE_SESSION" 17 l
  if operate_and_record link-target-underscore "$CASE_SESSION" y a e; then
    assert_state link-target-underscore-opaque link-target-underscore \
      "$CASE_SESSION" \
      'register=[[https://x/foo_bar][desc]]  register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case link-description-subscript \
     "$WORKDIR/link-description-subscript.org" 'foo_bar.*tail'; then
  send_keys "$CASE_SESSION" 18 l
  if operate_and_record link-description-subscript "$CASE_SESSION" d a e; then
    assert_state link-description-subscript-abort link-description-subscript \
      "$CASE_SESSION" 'text=[[https://x][foo_bar]] tail\n bytes=' \
      'register= register-type=none' 'small= small-type=none' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case opaque-plain-link-code \
     "$WORKDIR/opaque-plain-link-code.org" 'foo_bar.*tail'; then
  send_keys "$CASE_SESSION" 24 l
  if operate_and_record opaque-plain-link-code "$CASE_SESSION" y a e; then
    assert_state opaque-plain-link-code-outer opaque-plain-link-code \
      "$CASE_SESSION" \
      'register=~https://example.com/foo_bar~  register-type=char' \
      'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case opaque-bracket-link-verbatim \
     "$WORKDIR/opaque-bracket-link-verbatim.org" 'foo_bar.*desc'; then
  send_keys "$CASE_SESSION" 16 l
  if operate_and_record opaque-bracket-link-verbatim \
       "$CASE_SESSION" y a e; then
    assert_state opaque-bracket-link-verbatim-outer \
      opaque-bracket-link-verbatim "$CASE_SESSION" \
      'register==[[https://x/foo_bar][desc]]=  register-type=char' \
      'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case opaque-code "$WORKDIR/opaque-code.org" 'a.*b.*tail'; then
  send_keys "$CASE_SESSION" 4 l
  if operate_and_record opaque-code "$CASE_SESSION" y a e; then
    assert_state opaque-code-outer opaque-code "$CASE_SESSION" \
      'register=~a *b*~  register-type=char' 'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 4 l
  if operate_and_record opaque-code "$CASE_SESSION" y i e; then
    assert_state opaque-code-inner opaque-code "$CASE_SESSION" \
      'register=a *b* register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case opaque-entity "$WORKDIR/opaque-entity.org" 'alpha.*tail'; then
  send_keys "$CASE_SESSION" 3 l
  if operate_and_record opaque-entity "$CASE_SESSION" y a e; then
    assert_state opaque-entity-literal opaque-entity "$CASE_SESSION" \
      'register=~\\alpha~  register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case timestamp "$WORKDIR/timestamp.org" '2026-07-12'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record timestamp "$CASE_SESSION" y a e; then
    assert_state timestamp-outer timestamp "$CASE_SESSION" \
      'register=<2026-07-12 Sun>  register-type=char' 'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 l
  if operate_and_record timestamp "$CASE_SESSION" y i e; then
    assert_state timestamp-inner timestamp "$CASE_SESSION" \
      'register=<2026-07-12 Sun> register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# A table cell's outer object starts after its left pipe and includes its
# right pipe; the inner object is the trimmed cell value.
if start_case table-context "$WORKDIR/table-context.org" 'first'; then
  if operate_and_record table-context "$CASE_SESSION" y a E; then
    assert_state table-first-bol-aE table-context "$CASE_SESSION" \
      'register=| first |\n| second |\n register-type=char' 'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0
  if operate_and_record table-context "$CASE_SESSION" y a e; then
    assert_state table-first-bol-ae table-context "$CASE_SESSION" \
      'register=| first |\n| second |\n register-type=char' 'modified=no'
  fi
  send_keys "$CASE_SESSION" Escape g g 0 j 0
  if operate_and_record table-context "$CASE_SESSION" y a E; then
    assert_state table-later-bol-aE table-context "$CASE_SESSION" \
      'register=| second |\n register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case table-formula-element "$WORKDIR/table-formula-element.org" \
     'TBLFM'; then
  if operate_and_record table-formula-element "$CASE_SESSION" d a E; then
    assert_state table-formula-element-outer table-formula-element \
      "$CASE_SESSION" 'text=AFTER\n bytes=' \
      'register=| a |\n| b |\n#+TBLFM: $1=1\n register-type=char' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case table-formula-greater "$WORKDIR/table-formula-greater.org" \
     'TBLFM'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record table-formula-greater "$CASE_SESSION" d a r; then
    assert_state table-formula-greater-outer table-formula-greater \
      "$CASE_SESSION" 'text=AFTER\n bytes=' \
      'register=| a |\n| b |\n#+TBLFM: $1=1\n register-type=line' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case table-cell "$WORKDIR/table-cell.org" 'alpha.*beta'; then
  send_keys "$CASE_SESSION" l
  if operate_and_record table-cell "$CASE_SESSION" y a e; then
    assert_state table-cell-outer table-cell "$CASE_SESSION" \
      'text=| alpha | beta |\n bytes=' 'point=2 line=1 column=1' \
      'register= alpha | register-type=char' \
      'state=normal selection=none' 'modified=no'
    if operate_and_record table-cell "$CASE_SESSION" y i e; then
      assert_state table-cell-inner table-cell "$CASE_SESSION" \
        'text=| alpha | beta |\n bytes=' 'point=3 line=1 column=2' \
        'register=alpha register-type=char' \
        'state=normal selection=none' 'modified=no'
    fi
  fi
  stop_case "$CASE_SESSION"
fi

if start_case ambiguous-table-cell "$WORKDIR/ambiguous-table-cell.org" \
     'literal.*beta'; then
  send_keys "$CASE_SESSION" 2 l
  if operate_and_record ambiguous-table-cell "$CASE_SESSION" d a e; then
    assert_state ambiguous-table-cell-abort ambiguous-table-cell \
      "$CASE_SESSION" 'text=| alpha \\| literal | beta |\n bytes=' \
      'register= register-type=none' 'small= small-type=none' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case table-hline "$WORKDIR/table-hline.org" 'a.*b'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record table-hline "$CASE_SESSION" d i E; then
    assert_state table-hline-inner table-hline "$CASE_SESSION" \
      'text=| a | b |\n\n| c | d |\n bytes=' \
      'register=|---+---| register-type=char' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

# Plain prose is an element, and ae deliberately falls back to that element
# when no narrower inline object covers point.
if start_case paragraph-aE "$WORKDIR/paragraph-element.org" \
     'First paragraph line'; then
  if operate_and_record paragraph-aE "$CASE_SESSION" d a E; then
    assert_state paragraph-aE paragraph-aE "$CASE_SESSION" \
      'text=AFTER\n bytes=' \
      'register=First paragraph line\nsecond paragraph line\n\n register-type=char' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case paragraph-ae "$WORKDIR/paragraph-object.org" \
     'Fallback paragraph'; then
  if operate_and_record paragraph-ae "$CASE_SESSION" d a e; then
    assert_state paragraph-ae-fallback paragraph-ae "$CASE_SESSION" \
      'text=AFTER\n bytes=' \
      'register=Fallback paragraph\n\n register-type=char' \
      'state=normal selection=none' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

# Post-blank belongs to the preceding element.  Greater list/table objects
# must not fall through from that blank to the entire section.
if start_case paragraph-postblank "$WORKDIR/paragraph-postblank.org" \
     'Paragraph'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record paragraph-postblank "$CASE_SESSION" y a E; then
    assert_state paragraph-postblank-owner paragraph-postblank "$CASE_SESSION" \
      'register=Paragraph\n\n register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case list-postblank "$WORKDIR/list-postblank.org" 'one'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record list-postblank "$CASE_SESSION" y a r; then
    assert_state list-postblank-owner list-postblank "$CASE_SESSION" \
      'register=- one\n- two\n\n register-type=line' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case table-postblank "$WORKDIR/table-postblank.org" '| a |'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record table-postblank "$CASE_SESSION" y a r; then
    assert_state table-postblank-owner table-postblank "$CASE_SESSION" \
      'register=| a |\n| b |\n\n register-type=line' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# An empty subtree has no valid inner line range.
if start_case empty-iR "$WORKDIR/empty-subtree.org" 'Empty'; then
  if operate_and_record empty-iR "$CASE_SESSION" d i R; then
    assert_state empty-iR-abort empty-iR "$CASE_SESSION" \
      'text=* Empty\n* Sibling\n bytes=' \
      'state=normal selection=none' 'register= register-type=none' \
      'small= small-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# Unsafe list ownership and malformed blocks must not fall through to a
# paragraph or section for either aE or ar.
if start_case unsupported-inline "$WORKDIR/unsupported-inline.org" \
     'fn:note'; then
  send_keys "$CASE_SESSION" 8 l
  if operate_and_record unsupported-inline "$CASE_SESSION" d a e; then
    assert_state unsupported-inline-ae unsupported-inline "$CASE_SESSION" \
      'text=prefix [fn:note] suffix\n bytes=' \
      'register= register-type=none' 'small= small-type=none' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case unsupported-citation "$WORKDIR/unsupported-citation.org" \
     'cite:@key'; then
  send_keys "$CASE_SESSION" 14 l
  if operate_and_record unsupported-citation "$CASE_SESSION" d a e; then
    assert_state unsupported-citation-ae unsupported-citation "$CASE_SESSION" \
      'text=prefix [cite:@key] suffix\n bytes=' \
      'register= register-type=none' 'small= small-type=none' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case unsupported-entity "$WORKDIR/unsupported-entity.org" \
     'alpha.*suffix'; then
  send_keys "$CASE_SESSION" 9 l
  if operate_and_record unsupported-entity "$CASE_SESSION" d a e; then
    assert_state unsupported-entity-ae unsupported-entity "$CASE_SESSION" \
      'text=prefix \\alpha suffix\n bytes=' \
      'register= register-type=none' 'small= small-type=none' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case unsupported-nested "$WORKDIR/unsupported-nested.org" \
     'cite:@key'; then
  send_keys "$CASE_SESSION" 15 l
  if operate_and_record unsupported-nested "$CASE_SESSION" d a e; then
    assert_state unsupported-nested-ae unsupported-nested "$CASE_SESSION" \
      'text=*prefix [cite:@key] suffix*\n bytes=' \
      'register= register-type=none' 'small= small-type=none' \
      'state=normal selection=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case orphan-heading "$WORKDIR/orphan-under-heading.org" 'orphan'; then
  send_keys "$CASE_SESSION" j 6 l
  if operate_and_record orphan-heading "$CASE_SESSION" d a e; then
    assert_state orphan-heading-ae orphan-heading "$CASE_SESSION" \
      'text=* H\n:ID: *orphan*\nKEEP\n* S\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  if operate_and_record orphan-heading "$CASE_SESSION" d a r; then
    assert_state orphan-heading-ar orphan-heading "$CASE_SESSION" \
      'text=* H\n:ID: *orphan*\nKEEP\n* S\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  if operate_and_record orphan-heading "$CASE_SESSION" d a R; then
    assert_state orphan-heading-aR orphan-heading "$CASE_SESSION" \
      'text=* H\n:ID: *orphan*\nKEEP\n* S\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case hyphen-drawer "$WORKDIR/hyphen-drawer.org" 'MY-DRAWER'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record hyphen-drawer "$CASE_SESSION" d a e; then
    assert_state hyphen-drawer-ae hyphen-drawer "$CASE_SESSION" \
      'text=* H\n:MY-DRAWER:\n:END:\nKEEP\n* S\n bytes=' \
      'register=:ID: value\n register-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case drawer-element "$WORKDIR/drawer-element.org" 'MY-DRAWER'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record drawer-element "$CASE_SESSION" d a E; then
    assert_state drawer-element-aE drawer-element "$CASE_SESSION" \
      'text=* H\n:MY-DRAWER:\n:END:\nKEEP\n* S\n bytes=' \
      'register=:ID: value\n register-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case drawer-greater "$WORKDIR/drawer-greater.org" 'MY-DRAWER'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record drawer-greater "$CASE_SESSION" d a r; then
    assert_state drawer-greater-ar drawer-greater "$CASE_SESSION" \
      'text=* H\nKEEP\n* S\n bytes=' \
      'register=:MY-DRAWER:\n:ID: value\n:END:\n register-type=line' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case drawer-inner-greater \
     "$WORKDIR/drawer-inner-greater.org" 'MY-DRAWER'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record drawer-inner-greater "$CASE_SESSION" d i r; then
    assert_state drawer-inner-greater-ir drawer-inner-greater \
      "$CASE_SESSION" \
      'text=* H\n:MY-DRAWER:\n:END:\nKEEP\n* S\n bytes=' \
      'register=:ID: value\n register-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case property-drawer-element \
     "$WORKDIR/property-drawer-element.org" 'PROPERTIES'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record property-drawer-element "$CASE_SESSION" d a E; then
    assert_state property-drawer-element-aE property-drawer-element \
      "$CASE_SESSION" \
      'text=* H\n:PROPERTIES:\n:END:\nKEEP\n* S\n bytes=' \
      'register=:ID: value\n register-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case property-drawer-greater \
     "$WORKDIR/property-drawer-greater.org" 'PROPERTIES'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record property-drawer-greater "$CASE_SESSION" d a r; then
    assert_state property-drawer-greater-ar property-drawer-greater \
      "$CASE_SESSION" \
      'text=* H\nKEEP\n* S\n bytes=' \
      'register=:PROPERTIES:\n:ID: value\n:END:\n register-type=line' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case drawer-subtree "$WORKDIR/drawer-subtree.org" 'MY-DRAWER'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record drawer-subtree "$CASE_SESSION" d a R; then
    assert_state drawer-subtree-aR drawer-subtree "$CASE_SESSION" \
      'text=* S\n bytes=' \
      'register=* H\n:MY-DRAWER:\n:ID: value\n:END:\nKEEP\n register-type=line' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case drawer-clock-element \
     "$WORKDIR/drawer-clock-element.org" 'CLOCK:'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record drawer-clock-element "$CASE_SESSION" d a E; then
    assert_state drawer-clock-element-aE drawer-clock-element \
      "$CASE_SESSION" \
      'text=* H\n:LOGBOOK:\n:END:\nKEEP\n* S\n bytes=' \
      'register=CLOCK: [2026-07-14 Tue 09:00]--[2026-07-14 Tue 10:00] =>  1:00\n register-type=char' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case drawer-clock-object \
     "$WORKDIR/drawer-clock-object.org" 'CLOCK:'; then
  send_keys "$CASE_SESSION" 2 j 1 0 l
  if operate_and_record drawer-clock-object "$CASE_SESSION" d a e; then
    assert_state drawer-clock-object-ae drawer-clock-object \
      "$CASE_SESSION" \
      'text=* H\n:LOGBOOK:\nCLOCK: --[2026-07-14 Tue 10:00] =>  1:00\n:END:\nKEEP\n* S\n bytes=' \
      'register=[2026-07-14 Tue 09:00] register-type=char' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case drawer-inline-object \
     "$WORKDIR/drawer-inline-object.org" 'code'; then
  send_keys "$CASE_SESSION" 2 j 7 l
  if operate_and_record drawer-inline-object "$CASE_SESSION" d a e; then
    assert_state drawer-inline-object-ae drawer-inline-object \
      "$CASE_SESSION" \
      'text=* H\n:NOTES:\nnote tail\n:END:\nKEEP\n* S\n bytes=' \
      'register=~code~  register-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case property-drawer-object \
     "$WORKDIR/property-drawer-object.org" 'bold'; then
  send_keys "$CASE_SESSION" 2 j 9 l
  if operate_and_record property-drawer-object "$CASE_SESSION" d a e; then
    assert_state property-drawer-object-ae property-drawer-object \
      "$CASE_SESSION" \
      'text=* H\n:PROPERTIES:\n:END:\nKEEP\n* S\n bytes=' \
      'register=:NOTE: *bold* value\n register-type=char' 'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case empty-drawer "$WORKDIR/empty-drawer.org" 'LOGBOOK'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record empty-drawer "$CASE_SESSION" d i r; then
    assert_state empty-drawer-ir empty-drawer "$CASE_SESSION" \
      'text=* H\n:LOGBOOK:\n:END:\nKEEP\n* S\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case unclosed-drawer "$WORKDIR/unclosed-drawer.org" 'CLOCK:'; then
  send_keys "$CASE_SESSION" 2 j
  if operate_and_record unclosed-drawer "$CASE_SESSION" d a r; then
    assert_state unclosed-drawer-ar unclosed-drawer "$CASE_SESSION" \
      'text=* H\n:LOGBOOK:\nCLOCK: [2026-07-14 Tue 09:00]\nKEEP\n* S\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case nested-inner "$WORKDIR/nested-block.org" 'inner'; then
  send_keys "$CASE_SESSION" 3 j
  if operate_and_record nested-inner "$CASE_SESSION" d a e; then
    assert_state nested-inner-ae nested-inner "$CASE_SESSION" \
      'text=#+begin_src text\nbefore\n#+begin_src text\ninner\n#+end_src\nafter\n#+end_src\nKEEP\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case nested-tail "$WORKDIR/nested-block.org" 'after'; then
  send_keys "$CASE_SESSION" 5 j
  if operate_and_record nested-tail "$CASE_SESSION" d a E; then
    assert_state nested-tail-aE nested-tail "$CASE_SESSION" \
      'text=#+begin_src text\nbefore\n#+begin_src text\ninner\n#+end_src\nafter\n#+end_src\nKEEP\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  if operate_and_record nested-tail "$CASE_SESSION" d a r; then
    assert_state nested-tail-ar nested-tail "$CASE_SESSION" \
      'text=#+begin_src text\nbefore\n#+begin_src text\ninner\n#+end_src\nafter\n#+end_src\nKEEP\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case mismatched-end "$WORKDIR/mismatched-end.org" 'before'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record mismatched-end "$CASE_SESSION" d a E; then
    assert_state mismatched-end-literal mismatched-end "$CASE_SESSION" \
      'text=KEEP\n bytes=' \
      'register=#+begin_src text\nbefore\n#+end_quote\nafter\n#+end_src\n register-type=char' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case quote-outer "$WORKDIR/quote-outer.org" 'quoted body'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record quote-outer "$CASE_SESSION" d a r; then
    assert_state quote-outer-greater quote-outer "$CASE_SESSION" \
      'text=AFTER\n bytes=' \
      'register=#+begin_quote\nquoted body\n#+end_quote\n register-type=line' \
      'modified=yes'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case quote-inner "$WORKDIR/quote-inner.org" 'quoted body'; then
  send_keys "$CASE_SESSION" j
  if operate_and_record quote-inner "$CASE_SESSION" y i r; then
    assert_state quote-inner-greater quote-inner "$CASE_SESSION" \
      'text=#+begin_quote\nquoted body\n#+end_quote\nAFTER\n bytes=' \
      'register=quoted body\n register-type=char' 'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case unsafe-ordered "$WORKDIR/unsafe-ordered.org" 'ordered item'; then
  assert_unsafe_context unsafe-ordered "$CASE_SESSION" \
    'text=1. ordered item\n2. ordered next\n bytes='
  stop_case "$CASE_SESSION"
fi

if start_case unsafe-tabbed "$WORKDIR/unsafe-tabbed.org" 'tabbed item'; then
  assert_unsafe_context unsafe-tabbed "$CASE_SESSION" \
    'text=-\ttabbed item\n- safe-looking sibling\n bytes='
  stop_case "$CASE_SESSION"
fi

if start_case unsafe-continuation "$WORKDIR/unsafe-continuation.org" \
     'continuation body'; then
  send_keys "$CASE_SESSION" j
  assert_unsafe_context unsafe-continuation "$CASE_SESSION" \
    'text=- item\n  continuation body\n- next\n bytes='
  stop_case "$CASE_SESSION"
fi

if start_case unsafe-unclosed "$WORKDIR/unsafe-unclosed.org" \
     'body without end'; then
  assert_unsafe_context unsafe-unclosed "$CASE_SESSION" \
    'text=#+begin_src text\nbody without end\n bytes='
  stop_case "$CASE_SESSION"
fi

if start_case unsafe-orphan "$WORKDIR/unsafe-orphan-property.org" \
     'ID: orphan'; then
  assert_unsafe_context unsafe-orphan "$CASE_SESSION" \
    'text=:END:\n:ID: orphan\nKEEP\n bytes='
  stop_case "$CASE_SESSION"
fi

# Abort from an existing charwise selection must preserve its exact shape,
# endpoints, bytes, and previously populated unnamed register.
if start_case visual-abort "$WORKDIR/visual-abort.org" 'plain unsafe text'; then
  if operate_and_record visual-abort "$CASE_SESSION" y i w; then
    send_keys "$CASE_SESSION" v l l
    if lem_wait_for "$CASE_SESSION" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null &&
       record_state visual-abort "$CASE_SESSION"; then
      visual_before=$(last_state visual-abort)
      assert_state visual-abort-before visual-abort "$CASE_SESSION" \
        'text=plain unsafe text\n bytes=' \
        'state=visual-char selection=char selected=pla' \
        'register=plain register-type=char' 'modified=no'
      send_keys "$CASE_SESSION" a R
      if lem_wait_for "$CASE_SESSION" 'VISUAL' "$WAIT_TIMEOUT" >/dev/null &&
         record_state visual-abort "$CASE_SESSION"; then
        visual_after=$(last_state visual-abort)
        if [ "$visual_after" = "$visual_before" ]; then
          pass visual-abort-preserves \
            "selection, shape, bytes, point, and register stayed identical"
        else
          fail visual-abort-preserves \
            "before/after F12 states differed" "$CASE_SESSION"
        fi
      else
        fail visual-abort-preserves \
          "abort did not retain VISUAL state or report" "$CASE_SESSION"
      fi
    else
      fail visual-abort-before \
        "seed selection did not enter VISUAL state or report" "$CASE_SESSION"
    fi
  fi
  stop_case "$CASE_SESSION"
fi

# A subtree object before the first heading aborts and preserves clean state.
if start_case abort "$WORKDIR/abort.org" 'plain text'; then
  if operate_and_record abort "$CASE_SESSION" d a R; then
    assert_state abort-no-mutation abort "$CASE_SESSION" \
      'text=plain text without an Org object\n bytes=' \
      'state=normal selection=none' 'register= register-type=none' \
      'modified=no'
  fi
  stop_case "$CASE_SESSION"
fi

# The local a/i prefixes must retain stock word objects and evil-surround.
if start_case daw "$WORKDIR/daw.org" 'alpha beta'; then
  if operate_and_record daw "$CASE_SESSION" d a w; then
    assert_state daw-compatibility daw "$CASE_SESSION" \
      'text=beta\n bytes=' 'register=alpha  register-type=char' \
      'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case surround-add "$WORKDIR/surround-add.org" 'alpha beta'; then
  if operate_and_record surround-add "$CASE_SESSION" y s i w '"'; then
    assert_state surround-add surround-add "$CASE_SESSION" \
      'text="alpha" beta\n bytes=' 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case surround-delete "$WORKDIR/surround-delete.org" 'alpha.*beta'; then
  if operate_and_record surround-delete "$CASE_SESSION" l d s '"'; then
    assert_state surround-delete surround-delete "$CASE_SESSION" \
      'text=alpha beta\n bytes=' 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case surround-change "$WORKDIR/surround-change.org" 'alpha.*beta'; then
  if operate_and_record surround-change "$CASE_SESSION" l c s '"' "'"; then
    assert_state surround-change surround-change "$CASE_SESSION" \
      "text='alpha' beta\\n bytes=" 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

# The Org operator map must leave evil-snipe's exclusive x alias reachable.
if start_case snipe-x "$WORKDIR/snipe.org" 'alpha beta gamma'; then
  if operate_and_record snipe-x "$CASE_SESSION" d x b e; then
    assert_state snipe-x-compatibility snipe-x "$CASE_SESSION" \
      'text=beta gamma\n bytes=' 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'All Evil-Org operator TUI tests passed.\n'
