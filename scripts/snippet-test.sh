#!/usr/bin/env bash
# Real-ncurses regressions for Yasnippet-style expansion sessions.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-snippet-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-snippet.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_SNIPPET_TEST_REPORT="$root/report"
fixture_snippet_root="$root/snippets"
incoming_snippet_dirs="${LEM_YATH_SNIPPET_DIRS:-}"
if [ -n "$incoming_snippet_dirs" ]; then
  export LEM_YATH_SNIPPET_DIRS="$fixture_snippet_root:$incoming_snippet_dirs"
else
  export LEM_YATH_SNIPPET_DIRS="$fixture_snippet_root"
fi
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$fixture_snippet_root/org-mode" \
  "$fixture_snippet_root/fundamental-mode" \
  "$fixture_snippet_root/lisp-mode" \
  "$fixture_snippet_root/prog-mode"
: >"$LEM_YATH_SNIPPET_TEST_REPORT"

write_snippet() { # write_snippet <path> <name> <key> <body-line>...
  local path=$1 name=$2 key=$3
  shift 3
  {
    printf '%s\n' '# -*- mode: snippet -*-'
    printf '# name: %s\n' "$name"
    printf '# key: %s\n' "$key"
    printf '%s\n' '# --'
    printf '%s\n' "$@"
  } >"$path"
}

# This is the exact private snippet configured in Emacs.
write_snippet "$fixture_snippet_root/org-mode/srcblock.snpt" \
  'src block' 'jjs ' \
  '#+BEGIN_SRC ${1:language}' \
  '$0' \
  '#+END_SRC'

# Portable, data-only snippets cover the session grammar independently of
# the private corpus and never require evaluating embedded Emacs Lisp.
write_snippet "$fixture_snippet_root/fundamental-mode/backtrack" \
  'backtrack fields' 'back' '${1:first}-${2:second}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/mirror" \
  'mirror field' 'mir' '${1:value}:$1:$0'
write_snippet "$fixture_snippet_root/fundamental-mode/repeated" \
  'repeated field ownership' 'repedge' '${1:a}-${1:b}-$1-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/nested" \
  'nested fields' 'nest' '${1:outer ${2:inner}}|$2|$0'
write_snippet "$fixture_snippet_root/fundamental-mode/escaped" \
  'escaped braces' 'brace' '${1:\{\}}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/completion-trigger" \
  'completion trigger' 'cmp' 'SNIPPET-WON-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/active-popup" \
  'active popup' 'pop' '${1:value}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/escape" \
  'escape retention' 'esc' '${1:value}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/undo" \
  'undo expansion' 'und' '${1:value}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/zero-default" \
  'zero default replacement' 'zerobody' '${1:lang}-${0:content}'
write_snippet "$fixture_snippet_root/fundamental-mode/middle-insert" \
  'middle default insertion' 'midins' '${1:value}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/middle-backspace" \
  'middle default backspace' 'midbs' '${1:value}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/pair-backspace" \
  'paired backspace mirror' 'pairbs' '${1:()}:$1-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/mode-change" \
  'mode change cleanup' 'mchg' '${1:value}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/manual-picker" \
  'manual picker' 'pick-never-typed' '${1:chosen}-$0'
write_snippet "$fixture_snippet_root/fundamental-mode/dynamic-date" \
  'safe dynamic date' 'dyn-date' 'DATE=`(format-time-string "%Y-%m-%d")`:$0'
write_snippet "$fixture_snippet_root/fundamental-mode/dynamic-file" \
  'safe dynamic file name' 'dyn-file' \
  'CLASS=${1:`(file-name-base (or (buffer-file-name) (buffer-name)))`}:$0'
write_snippet "$fixture_snippet_root/fundamental-mode/unsafe-form" \
  'unsafe dynamic form' 'unsafe' '`(shell-command "touch /tmp/never")`$0'
write_snippet "$fixture_snippet_root/fundamental-mode/transform" \
  'safe field transform' 'xform' \
  '${1:Heading}' \
  '${1:$(make-string (string-width yas-text) ?\=)}' \
  '$0'
write_snippet "$fixture_snippet_root/lisp-mode/after-mode-change" \
  'after mode change' 'aftermode' '${1:ready}-$0'

{
  printf '%s\n' '# -*- mode: snippet -*-'
  printf '%s\n' '# name: non-shell condition'
  printf '%s\n' '# key: onlyprog'
  printf '%s\n' "# condition: (not (member major-mode '(sh-mode bash-ts-mode)))"
  printf '%s\n' '# --'
  printf '%s\n' 'CONDITION-ALLOWED-$0'
} >"$fixture_snippet_root/prog-mode/conditional"

# Exercise both safe indentation directives together.  `$>' first asks the
# active mode to indent the marker line; fixed indentation then prefixes the
# nonzero trigger column while retaining the resulting relative layout.
{
  printf '%s\n' '# -*- mode: snippet -*-'
  printf '%s\n' '# name: fixed marker indentation'
  printf '%s\n' '# key: fixmark'
  printf '%s\n' "# expand-env: ((yas-indent-line 'fixed))"
  printf '%s\n' '# --'
  printf '%s\n' 'alpha'
  printf '%s\n' '  $>beta ${1:value}'
  printf '%s\n' '$0'
} >"$fixture_snippet_root/fundamental-mode/fixed-marker"
write_snippet "$fixture_snippet_root/lisp-mode/paredit" \
  'paredit field' 'par' '(${1:value})$0'

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
session="lem-yath-snippet-$id"
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

report_count() {
  grep -cE "$1" "$LEM_YATH_SNIPPET_TEST_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_SNIPPET_TEST_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
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

hex_of() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
}

run_mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.25
  lem_keys "$session" Escape
  sleep 0.25
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  lem_keys "$session" Enter
  sleep 0.4
}

enter_insert() {
  if ! lem_capture "$session" | grep -q 'INSERT'; then
    lem_keys "$session" i
    lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null
  fi
}

enter_insert_after() {
  if ! lem_capture "$session" | grep -q 'INSERT'; then
    # Vi's normal-state cursor rests on the final trigger character.  `a'
    # enters insert state after it, leaving point at the trigger boundary.
    lem_keys "$session" a
    lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null
  fi
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l "$1"
  sleep 0.12
}

record_state() {
  local label=$1 before
  before=$(report_count "^STATE label=$label ")
  lem_keys "$session" F12
  wait_report_count "^STATE label=$label " "$((before + 1))"
}

last_state() {
  grep "^STATE label=$1 " "$LEM_YATH_SNIPPET_TEST_REPORT" | tail -1
}

assert_state() { # name label text expected-fragment...
  local name=$1 label=$2 expected_text=$3 line expected_hex fragment
  shift 3
  line=$(last_state "$label")
  expected_hex=$(hex_of "$expected_text")
  if [[ "$line" != *"text-hex=$expected_hex "* ]]; then
    fail "$name" "wrong text state: $line"
    return
  fi
  for fragment in "$@"; do
    if [[ "$line" != *"$fragment"* ]]; then
      fail "$name" "missing '$fragment' in: $line"
      return
    fi
  done
  pass "$name" "$label produced the expected text and editor state"
}

fixture="$(lem-yath_lisp_string "$here/scripts/snippet-fixture.lisp")"
scratch="$root/private.org"
: >"$scratch"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$scratch"
if lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null &&
   wait_report '^ANCESTRY-SUMMARY ok=' "$BOOT_TIMEOUT"; then
  if grep -q '^ANCESTRY-SUMMARY ok=yes$' "$LEM_YATH_SNIPPET_TEST_REPORT" &&
     grep -q \
       '^CORPUS total=2387 supported=2318 unsupported=69 safe-backquote=62 safe-condition=6$' \
       "$LEM_YATH_SNIPPET_TEST_REPORT" &&
     grep -q '^DYNAMIC-ORACLE ok=yes ' "$LEM_YATH_SNIPPET_TEST_REPORT" &&
     wait_report \
       '^READY roots=([2-9]|[1-9][0-9]+) ancestry=yes$' "$BOOT_TIMEOUT"; then
    pass boot \
      "fixture roots, exact ancestry, and pinned corpus counts matched"
  else
    fail boot "one or more snippet ancestry vectors differed"
    sed -n '/^ANCESTRY /p;/^ANCESTRY-SUMMARY /p;/^CORPUS/p;/^DYNAMIC-ORACLE/p' \
      "$LEM_YATH_SNIPPET_TEST_REPORT" 2>/dev/null || true
    exit 1
  fi
else
  fail boot "Lem did not load the snippet fixture"
fi

# The private `jjs' snippet uses the .org filename alias despite Lem's plain
# major mode.  Typing replaces the pristine default, then Tab reaches $0.
if run_mx lem-yath-test-snippet-private-setup && enter_insert; then
  send_literal jjs
  lem_keys "$session" Tab
  send_literal common-lisp
  if record_state private-org; then
    assert_state private-default private-org \
      $'#+BEGIN_SRC common-lisp\n\n#+END_SRC\n' \
      'active=yes' 'field=1' 'completion=no' 'vi=insert'
  else
    fail private-default "state probe did not run"
  fi
  lem_keys "$session" Tab
  if record_state private-org; then
    line=$(last_state private-org)
    if [[ "$line" == *'point=25 '* &&
          "$line" == *'active=no '* &&
          "$line" == *'field=none '* &&
          "$line" == *'completion=no '* ]]; then
      pass private-final-field 'Tab moved to the $0 position on the blank body line'
    else
      fail private-final-field "unexpected final position: $line"
    fi
  else
    fail private-final-field "state probe did not run"
  fi
else
  fail private-setup "could not prepare the private .org scenario"
fi

# Trusted file snippets translate the pinned corpus's bounded dynamic forms at
# expansion time.  Date and filename values remain ordinary literal text while
# preserving the surrounding field session.
if run_mx lem-yath-test-snippet-dynamic-date-setup && enter_insert; then
  send_literal dyn-date
  lem_keys "$session" Tab
  if record_state dynamic-date; then
    assert_state safe-dynamic-date dynamic-date $'DATE=2031-02-09:\n' \
      'active=no' 'field=none' 'completion=no'
  else
    fail safe-dynamic-date "dynamic date state probe did not run"
  fi
else
  fail safe-dynamic-date "could not prepare dynamic date expansion"
fi

if run_mx lem-yath-test-snippet-dynamic-file-setup && enter_insert; then
  send_literal dyn-file
  lem_keys "$session" Tab
  if record_state dynamic-file; then
    assert_state safe-dynamic-filename dynamic-file $'CLASS=widget-card:\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail safe-dynamic-filename "dynamic filename state probe did not run"
  fi
else
  fail safe-dynamic-filename "could not prepare dynamic filename expansion"
fi

# An unrecognized form is never read or invoked.  Tab reports it as unavailable
# and retains the trigger exactly, proving the fail-closed boundary physically.
if run_mx lem-yath-test-snippet-unsafe-setup && enter_insert; then
  send_literal unsafe
  lem_keys "$session" Tab
  if record_state unsafe; then
    assert_state unsafe-form-fail-closed unsafe unsafe \
      'active=no' 'field=none' 'completion=no'
  else
    fail unsafe-form-fail-closed "unsafe form state probe did not run"
  fi
else
  fail unsafe-form-fail-closed "could not prepare unsafe-form scenario"
fi

# A pure field transform is a dependency-aware mirror: editing the heading
# recomputes its display-width underline without making the mirror navigable.
if run_mx lem-yath-test-snippet-transform-setup && enter_insert; then
  send_literal xform
  lem_keys "$session" Tab
  send_literal Title
  if record_state transform; then
    assert_state safe-field-transform transform $'Title\n=====\n\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail safe-field-transform "transform state probe did not run"
  fi
else
  fail safe-field-transform "could not prepare field-transform scenario"
fi

# The common prog-mode condition is evaluated from Lem's actual major mode:
# it expands in C and is absent in a shell buffer.
if run_mx lem-yath-test-snippet-condition-true-setup && enter_insert; then
  send_literal onlyprog
  lem_keys "$session" Tab
  if record_state condition-true; then
    assert_state safe-condition-true condition-true \
      $'CONDITION-ALLOWED-\n' 'active=no' 'field=none'
  else
    fail safe-condition-true "true-condition state probe did not run"
  fi
else
  fail safe-condition-true "could not prepare true-condition scenario"
fi

if run_mx lem-yath-test-snippet-condition-false-setup && enter_insert; then
  send_literal onlyprog
  lem_keys "$session" Tab
  if record_state condition-false; then
    assert_state safe-condition-false condition-false \
      '            onlyprog' \
      'active=no' 'field=none'
  else
    fail safe-condition-false "false-condition state probe did not run"
  fi
else
  fail safe-condition-false "could not prepare false-condition scenario"
fi

# The manual selector exposes the same portable templates without requiring a
# trigger.  Prescient narrows by the human-readable name, then the chosen
# template starts the ordinary editable field session at point.
if run_mx lem-yath-test-snippet-selector-setup &&
   run_mx lem-yath-insert-snippet &&
   lem_wait_for "$session" 'Snippet:' "$WAIT_TIMEOUT" >/dev/null; then
  send_literal 'manual picker'
  if lem_wait_for "$session" 'manual picker' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Enter
    sleep 0.4
    enter_insert
    send_literal picked
    if record_state selector; then
      assert_state manual-snippet-selector selector $'picked-\n' \
        'active=yes' 'field=1' 'completion=no'
    else
      fail manual-snippet-selector "selector state probe did not run"
    fi
  else
    fail manual-snippet-selector "manual picker candidate was not visible"
  fi
else
  fail manual-snippet-selector "M-x selector did not open"
fi

# Backward traversal uses the terminal's real back-tab key (reported to Lem as
# Shift-Tab), returning from field 2 to field 1 without changing either value.
if run_mx lem-yath-test-snippet-backtrack-setup && enter_insert; then
  send_literal back
  lem_keys "$session" Tab
  send_literal one
  lem_keys "$session" Tab
  send_literal two
  lem_keys "$session" BTab
  if record_state backtrack; then
    assert_state shift-tab-backtrack backtrack $'one-two-\n' \
      'active=yes' 'field=1' 'completion=no' 'vi=insert'
  else
    fail shift-tab-backtrack "state probe did not run"
  fi
else
  fail backtrack-setup "could not prepare field traversal"
fi

if run_mx lem-yath-test-snippet-mirror-setup && enter_insert; then
  send_literal mir
  lem_keys "$session" Tab
  send_literal sync
  if record_state mirror; then
    assert_state live-mirrors mirror $'sync:sync:\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail live-mirrors "state probe did not run"
  fi
else
  fail mirror-setup "could not prepare mirror expansion"
fi

# Yas parses all braced occurrences before attaching simple mirrors.  For a
# repeated number this makes the later braced field the first navigation stop
# and the owner of `$1'; the earlier braced field follows it.
if run_mx lem-yath-test-snippet-repeated-setup && enter_insert; then
  send_literal repedge
  lem_keys "$session" Tab
  if record_state repeated; then
    assert_state repeated-later-first repeated $'a-b-b-\n' \
      'point=3 ' 'active=yes' 'field=1' 'completion=no'
  else
    fail repeated-later-first "initial repeated-field probe did not run"
  fi
  send_literal X
  if record_state repeated; then
    assert_state repeated-mirror-owner repeated $'a-X-X-\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail repeated-mirror-owner "mirror-owner probe did not run"
  fi
  lem_keys "$session" Tab
  if record_state repeated; then
    assert_state repeated-earlier-second repeated $'a-X-X-\n' \
      'point=1 ' 'active=yes' 'field=1' 'completion=no'
  else
    fail repeated-earlier-second "forward repeated-field probe did not run"
  fi
  send_literal Y
  lem_keys "$session" BTab
  if record_state repeated; then
    assert_state repeated-reverse-navigation repeated $'Y-X-X-\n' \
      'point=3 ' 'active=yes' 'field=1' 'completion=no'
  else
    fail repeated-reverse-navigation "reverse repeated-field probe did not run"
  fi
else
  fail repeated-setup "could not prepare repeated-field traversal"
fi

if run_mx lem-yath-test-snippet-nested-setup && enter_insert; then
  send_literal nest
  lem_keys "$session" Tab
  lem_keys "$session" Tab
  send_literal core
  if record_state nested; then
    assert_state nested-placeholders nested $'outer core|core|\n' \
      'active=yes' 'field=2' 'completion=no'
  else
    fail nested-placeholders "state probe did not run"
  fi
else
  fail nested-setup "could not prepare nested expansion"
fi

# Replacing a parent placeholder disables its nested child and clears every
# mirror derived from that child rather than leaving stale default text.
if run_mx lem-yath-test-snippet-nested-setup && enter_insert; then
  send_literal nest
  lem_keys "$session" Tab
  send_literal X
  if record_state nested; then
    assert_state nested-parent-replacement nested $'X||\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail nested-parent-replacement "state probe did not run"
  fi
else
  fail nested-parent-setup "could not prepare parent replacement"
fi

# Escaped delimiters inside a default are literal data, not parser syntax.
if run_mx lem-yath-test-snippet-escaped-setup && enter_insert; then
  send_literal brace
  lem_keys "$session" Tab
  if record_state escaped; then
    assert_state escaped-default escaped $'{}-\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail escaped-default "initial escaped-default probe did not run"
  fi
  send_literal ok
  if record_state escaped; then
    assert_state escaped-replacement escaped $'ok-\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail escaped-replacement "replacement probe did not run"
  fi
else
  fail escaped-setup "could not prepare escaped-delimiter expansion"
fi

# `${0:...}' is an editable final field, unlike the simple `$0' exit marker.
# One Tab enters it; the first edit replaces its default and commits the
# session without requiring another Tab.
if run_mx lem-yath-test-snippet-zero-default-setup && enter_insert; then
  send_literal zerobody
  lem_keys "$session" Tab
  lem_keys "$session" Tab
  send_literal body
  if record_state zero-default; then
    assert_state zero-default-auto-exit zero-default $'lang-body\n' \
      'active=no' 'field=none' 'completion=no' 'vi=insert'
  else
    fail zero-default-auto-exit "final-field replacement probe did not run"
  fi
else
  fail zero-default-setup "could not prepare editable zero-field replacement"
fi

# Editing from the middle of an untouched default is an ordinary insertion;
# only insertion at the field start performs Yas's replace-default behavior.
if run_mx lem-yath-test-snippet-middle-insert-setup && enter_insert; then
  send_literal midins
  lem_keys "$session" Tab
  lem_keys "$session" Right Right
  send_literal X
  if record_state middle-insert; then
    assert_state middle-default-insert middle-insert $'vaXlue-\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail middle-default-insert "middle-insertion probe did not run"
  fi
else
  fail middle-insert-setup "could not prepare middle-default insertion"
fi

# Backspace away from the field start deletes one preceding character rather
# than clearing the entire pristine default.
if run_mx lem-yath-test-snippet-middle-backspace-setup && enter_insert; then
  send_literal midbs
  lem_keys "$session" Tab
  lem_keys "$session" Right Right Right
  lem_keys "$session" BSpace
  if record_state middle-backspace; then
    assert_state middle-default-backspace middle-backspace $'vaue-\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail middle-default-backspace "middle-Backspace probe did not run"
  fi
else
  fail middle-backspace-setup "could not prepare middle-default Backspace"
fi

# Backspace between adjacent delimiters flows through the snippet wrapper and
# updates every mirror from the one preflighted pair-deletion command.
if run_mx lem-yath-test-snippet-pair-backspace-setup && enter_insert; then
  send_literal pairbs
  lem_keys "$session" Tab
  lem_keys "$session" Right
  lem_keys "$session" BSpace
  if record_state pair-backspace; then
    assert_state paired-backspace-mirror pair-backspace $':-\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail paired-backspace-mirror "paired snippet Backspace probe did not run"
  fi
else
  fail pair-backspace-setup "could not prepare paired snippet Backspace"
fi

# A major-mode transition invalidates the old field overlays and buffer-local
# hooks.  Global activation must cleanly end that session, restore the minor
# mode, and allow a new Lisp snippet to install working edit hooks.
if run_mx lem-yath-test-snippet-mode-change-setup && enter_insert; then
  send_literal mchg
  lem_keys "$session" Tab
  lem_keys "$session" F6
  if record_state mode-change; then
    assert_state mode-change-cleanup mode-change $'value-\n' \
      'active=no' 'field=none' 'snippet-mode=yes' \
      'before-hook=no' 'after-hook=no'
  else
    fail mode-change-cleanup "post-mode-change probe did not run"
  fi
  enter_insert
  lem_keys "$session" End
  send_literal aftermode
  lem_keys "$session" Tab
  send_literal again
  if record_state mode-change; then
    assert_state mode-change-reenable mode-change $'value-again-\n\n' \
      'active=yes' 'field=1' 'snippet-mode=yes' \
      'before-hook=yes' 'after-hook=yes'
  else
    fail mode-change-reenable "post-mode-change expansion probe did not run"
  fi
else
  fail mode-change-setup "could not prepare active mode transition"
fi

# Nonzero-column fixed indentation composes with `$>': marker indentation is
# applied first, then every nonblank continuation receives the trigger column.
if run_mx lem-yath-test-snippet-fixed-indent-setup && enter_insert_after; then
  lem_keys "$session" Tab
  if record_state fixed-indent; then
    assert_state fixed-marker-indentation fixed-indent \
      $'pre alpha\n    beta value\n\n' \
      'active=yes' 'field=1' 'completion=no'
  else
    fail fixed-marker-indentation "fixed-indentation probe did not run"
  fi
else
  fail fixed-indent-setup "could not prepare nonzero-column fixed indentation"
fi

# With no trigger and no popup, the minor mode must delegate to the original
# fundamental-mode behavior, which is insertion of a literal tab.
if run_mx lem-yath-test-snippet-fallback-setup && enter_insert; then
  send_literal none
  lem_keys "$session" Tab
  if record_state fallback; then
    assert_state no-trigger-fallback fallback $'none\t' \
      'active=no' 'field=none' 'completion=no'
  else
    fail no-trigger-fallback "state probe did not run"
  fi
else
  fail fallback-setup "could not prepare Tab fallback"
fi

# An ordinary completion popup remains authoritative over an expandable word.
if run_mx lem-yath-test-snippet-ordinary-popup-setup && enter_insert; then
  send_literal cmp
  lem_keys "$session" F6
  if lem_wait_for "$session" 'CMP-FIRST' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Tab
    if record_state ordinary-popup; then
      assert_state popup-before-trigger ordinary-popup cmp \
        'active=no' 'completion=yes' 'focus=CMP-SECOND' 'vi=insert'
    else
      fail popup-before-trigger "state probe did not run"
    fi
  else
    fail popup-before-trigger-setup "ordinary completion popup did not open"
  fi
else
  fail popup-before-trigger-setup "could not prepare ordinary popup precedence"
fi

# Once a snippet field is active, Tab advances that field and dismisses an
# incidental popup rather than navigating its candidates.
if run_mx lem-yath-test-snippet-active-popup-setup && enter_insert; then
  send_literal pop
  lem_keys "$session" Tab
  lem_keys "$session" F6
  if lem_wait_for "$session" 'CMP-FIRST' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Tab
    if record_state active-popup; then
      assert_state active-field-before-popup active-popup $'value-\n' \
        'active=no' 'field=none' 'completion=no' 'focus=none'
    else
      fail active-field-before-popup "state probe did not run"
    fi
  else
    fail active-field-before-popup "popup did not open inside the active field"
  fi
else
  fail active-popup-setup "could not prepare active-field popup precedence"
fi

# Leaving Vi insert state does not discard the field session.  Re-entering
# insert state lets the same Tab key complete traversal.
if run_mx lem-yath-test-snippet-escape-setup && enter_insert; then
  send_literal esc
  lem_keys "$session" Tab
  send_literal hold
  lem_keys "$session" Escape
  sleep 0.3
  if record_state escape; then
    assert_state escape-retains-session escape $'hold-\n' \
      'active=yes' 'field=1' 'completion=no' 'vi=normal'
  else
    fail escape-retains-session "normal-state probe did not run"
  fi
  enter_insert
  lem_keys "$session" Tab
  if record_state escape; then
    assert_state escape-resume escape $'hold-\n' \
      'active=no' 'field=none' 'completion=no' 'vi=insert'
  else
    fail escape-resume "resumed-state probe did not run"
  fi
else
  fail escape-setup "could not prepare Escape retention"
fi

# The template itself is inserted structurally, and editing a pristine field
# still goes through Paredit: `(' pairs, and the typed closer skips its mate.
if run_mx lem-yath-test-snippet-paredit-setup && enter_insert; then
  send_literal par
  lem_keys "$session" Tab
  send_literal '('
  send_literal x
  send_literal ')'
  if record_state paredit; then
    assert_state paredit-field-edit paredit $'((x))\n' \
      'active=yes' 'field=1' 'completion=no' 'paredit=yes'
  else
    fail paredit-field-edit "state probe did not run"
  fi
else
  fail paredit-setup "could not prepare the Lisp snippet"
fi

# Expansion is one undo unit.  Restoring the pre-expansion trigger must also
# remove every live field marker so no stale session captures a later Tab.
if run_mx lem-yath-test-snippet-undo-setup && enter_insert_after; then
  lem_keys "$session" Tab
  if record_state undo; then
    assert_state undo-expanded undo $'value-\n' 'active=yes' 'field=1'
  else
    fail undo-expanded "expanded-state probe did not run"
  fi
  lem_keys "$session" Escape
  sleep 0.3
  lem_keys "$session" u
  if record_state undo; then
    assert_state undo-session-cleanup undo und \
      'active=no' 'field=none' 'completion=no' 'vi=normal'
  else
    fail undo-session-cleanup "post-undo probe did not run"
  fi
else
  fail undo-setup "could not prepare expansion undo"
fi

# Consume a real file from the flake-pinned yasnippet-snippets checkout in a
# second real editor opened directly on .py.  The fixture root deliberately
# contains no Python `def' definition, so this can only pass when the non-flake
# input remains discoverable after prepending it.
lem_stop "$session"
session="lem-yath-snippet-community-$id"
python_scratch="$root/community.py"
: >"$python_scratch"
ready_before=$(report_count '^READY roots=')
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$python_scratch"
if lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null &&
   lem_wait_for "$session" 'Python' "$BOOT_TIMEOUT" >/dev/null &&
   wait_report_count \
     '^READY roots=([2-9]|[1-9][0-9]+) ancestry=yes$' \
     "$((ready_before + 1))" "$BOOT_TIMEOUT"; then
  pass community-python-boot "real .py buffer opened with pinned roots"
  if run_mx lem-yath-test-snippet-python-setup && enter_insert; then
    send_literal def
    lem_keys "$session" Tab
    if record_state community-python; then
      assert_state community-python-load community-python \
        $'def methodname(self, arg):\n    pass\n' \
        'active=yes' 'field=1' 'completion=no' 'vi=insert'
    else
      fail community-python-load "initial community-snippet probe did not run"
    fi
    send_literal compute
    if record_state community-python; then
      assert_state community-python-replace community-python \
        $'def compute(self, arg):\n    pass\n' \
        'active=yes' 'field=1' 'completion=no' 'vi=insert'
    else
      fail community-python-replace "replacement probe did not run"
    fi
  else
    fail community-python-setup "could not prepare pinned Python expansion"
  fi
else
  fail community-python-boot "real .py fixture did not reach Python normal state"
fi

echo
sed -n '1,240p' "$LEM_YATH_SNIPPET_TEST_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "SNIPPET TEST PASSED"
  exit 0
else
  echo "SNIPPET TEST FAILED"
  exit 1
fi
