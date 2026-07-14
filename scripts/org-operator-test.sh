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
       'STATIC normal=yes operator=yes visual=yes stock=yes snipe=yes safe=yes commands=yes' \
       "$LEM_YATH_ORG_OPERATOR_REPORT"; then
    pass static-routing \
      "normal d/x/X, visual defaults, text objects, and operator Snipe coexist"
  else
    fail static-routing "effective Org routing contract differed" "$CASE_SESSION"
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
if start_case daE "$WORKDIR/source-outer.org" 'begin_src text'; then
  if operate_and_record daE "$CASE_SESSION" d a E; then
    assert_state daE daE "$CASE_SESSION" \
      'text=AFTER\n bytes=' 'register=#+begin_src text\nsource body\n#+end_src\n' \
      'register-type=char' 'state=normal selection=none'
  fi
  stop_case "$CASE_SESSION"
fi

if start_case diE "$WORKDIR/source-inner.org" 'begin_src text'; then
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
      'text=* H\n:MY-DRAWER:\n:ID: value\n:END:\nKEEP\n* S\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  if operate_and_record hyphen-drawer "$CASE_SESSION" d a E; then
    assert_state hyphen-drawer-aE hyphen-drawer "$CASE_SESSION" \
      'text=* H\n:MY-DRAWER:\n:ID: value\n:END:\nKEEP\n* S\n bytes=' \
      'register= register-type=none' 'modified=no'
  fi
  if operate_and_record hyphen-drawer "$CASE_SESSION" d a r; then
    assert_state hyphen-drawer-ar hyphen-drawer "$CASE_SESSION" \
      'text=* H\n:MY-DRAWER:\n:ID: value\n:END:\nKEEP\n* S\n bytes=' \
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
