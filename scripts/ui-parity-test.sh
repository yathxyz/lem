#!/usr/bin/env bash
# Real-ncurses coverage for delayed leader help and programming-only numbers.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

id="${LEM_YATH_CHECK_ID:-ui-parity-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-ui-parity.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_UI_PARITY_REPORT="$root/report"
export LEM_YATH_UI_CODE_FILE="$root/code.lisp"
export LEM_YATH_UI_PROSE_FILE="$root/notes.md"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
printf '(defun answer ()\n  42)\n' >"$LEM_YATH_UI_CODE_FILE"
printf '# Notes\n\nplain prose\n' >"$LEM_YATH_UI_PROSE_FILE"
: >"$LEM_YATH_UI_PARITY_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-ui-parity-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_UI_PARITY_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

run_mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.3
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.4
  lem_keys "$session" Enter
  sleep 0.2
  lem_keys "$session" Enter
  sleep 0.4
}

screen_has_leader() {
  lem_capture "$session" | grep -qE '\[Leader([^]]*)?\]'
}

fixture="$(lem-yath_lisp_string "$here/scripts/ui-parity-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$LEM_YATH_UI_CODE_FILE"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  pass boot "configured Lem loaded the UI fixture"
else
  fail boot "fixture did not become ready"
fi

if run_mx lem-yath-test-ui-static-checks &&
   wait_report '^SUMMARY STATIC PASS failures=0$'; then
  pass static-contracts "leader maps, scoped delay, and expected bindings are configured"
else
  fail static-contracts "leader help static contracts failed"
fi

if run_mx lem-yath-test-ui-rebuild-leader &&
   wait_report '^REBUILD changed=yes timer-before=yes timer-after=no stale-callback-safe=yes window-before=yes window-after=no shown-replaced=yes normal-prefixes=1 visual-prefixes=1 cache-normal=yes cache-visual=yes bindings=yes help=yes$'; then
  pass leader-rebuild "reload replaces one shared tree and clears stale UI/cache state"
else
  fail leader-rebuild "leader rebuild lifecycle contracts failed"
fi

if run_mx lem-yath-test-ui-code-state &&
   wait_report '^STATE label=code file=code\.lisp programming=yes line-mode=yes fixture-mode=yes git-mode=yes line-numbers=yes relative=2 number-width=3 gutter=G 2 gutter-width=4 '; then
  pass code-line-numbers "the composed gutter renders a relative distance in code"
else
  fail code-line-numbers "programming gutter did not expose relative line numbers"
fi

if run_mx lem-yath-test-ui-production-gutters &&
   wait_report '^STATE label=production-gutters file=code\.lisp programming=yes line-mode=yes fixture-mode=no git-mode=yes line-numbers=yes relative=2 number-width=3 gutter=2 gutter-width=4 '; then
  pass production-gutters "real Git and relative-number columns compose"
else
  fail production-gutters "production Git gutter was absent or swallowed"
fi

if run_mx lem-yath-test-ui-reordered-code-state &&
   wait_report '^STATE label=code-reordered file=code\.lisp programming=yes line-mode=yes fixture-mode=yes git-mode=yes line-numbers=yes relative=2 number-width=3 gutter=G 2 gutter-width=4 '; then
  pass reordered-gutters "line-number re-enable preserved a lower-priority gutter"
else
  fail reordered-gutters "gutter composition depended on global-mode order"
fi

if run_mx lem-yath-test-ui-prose-state &&
   wait_report '^STATE label=prose file=notes\.md programming=no line-mode=yes fixture-mode=yes git-mode=yes line-numbers=no relative=none number-width=0 gutter=fixture-gutter gutter-width=14 '; then
  pass prose-line-numbers "Markdown omits numbers without swallowing another gutter"
else
  fail prose-line-numbers "prose numbering or composite-gutter isolation failed"
fi

if run_mx lem-yath-test-ui-unsaved-code-state &&
   wait_report '^STATE label=unsaved-code file=none programming=yes line-mode=yes fixture-mode=yes git-mode=yes line-numbers=yes relative=2 number-width=3 gutter=G 2 gutter-width=4 '; then
  pass unsaved-line-numbers "unsaved programming buffers also receive relative numbers"
else
  fail unsaved-line-numbers "fileless programming buffer lacked relative numbers"
fi

run_mx lem-yath-test-ui-code-state || true

lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" F12
sleep 0.2
if lem_capture "$session" | grep -q '\[Fixture unrelated\]'; then
  fail unrelated-transient "an unrelated transient ignored its upstream delay"
else
  unrelated_shown=0
  for _ in {1..8}; do
    sleep 0.1
    if lem_capture "$session" | grep -q '\[Fixture unrelated\]'; then
      unrelated_shown=1
      break
    fi
  done
  if ((unrelated_shown)); then
    pass unrelated-transient "an unrelated transient retained the upstream 500ms delay"
  else
    fail unrelated-transient "unrelated transient did not appear on its own schedule"
  fi
fi
lem_keys "$session" Escape
sleep 0.4

lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" Space
sleep 0.7
if screen_has_leader; then
  fail delayed-leader "leader popup appeared before its configured delay"
else
  leader_shown=0
  for _ in {1..8}; do
    sleep 0.1
    if lem_capture "$session" | grep -q '\[Leader\]'; then
      leader_shown=1
      break
    fi
  done
  if ((leader_shown)); then
    pass delayed-leader "leader help stayed hidden for 700ms and appeared near one second"
  else
    fail delayed-leader "leader popup missed its one-second window"
  fi
fi

lem_keys "$session" p
sleep 0.2
if lem_capture "$session" | grep -q '\[Leader p: project\]' &&
   lem_capture "$session" | grep -q 'find project file' &&
   lem_capture "$session" | grep -q 'document symbols'; then
  pass nested-leader "project continuations replaced the root menu immediately"
else
  fail nested-leader "project continuation menu was missing or undescribed"
fi

lem_keys "$session" Escape
sleep 1.2
if screen_has_leader; then
  fail leader-cancel "Escape left or resurrected the continuation popup"
else
  pass leader-cancel "Escape closed the popup with no delayed resurrection"
fi

lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" Space
sleep 0.08
lem_keys "$session" z
if wait_report '^FAST count=1 popup=no$' 10; then
  sleep 1.2
  if screen_has_leader; then
    fail fast-leader "a completed fast chord left a delayed popup behind"
  else
    pass fast-leader "a fast leader command canceled pending help"
  fi
else
  fail fast-leader "fast leader chord did not execute cleanly"
fi

lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" v
if lem_wait_for "$session" 'VISUAL' 3 >/dev/null; then
  lem_keys "$session" Space
  if lem_wait_for "$session" '\[Leader\]' 2 >/dev/null; then
    pass visual-leader "the shared leader popup also appears in visual state"
  else
    fail visual-leader "visual-state leader did not show continuations"
  fi
else
  fail visual-leader "could not enter visual state"
fi

lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" Escape

if ((failed)); then
  printf '\n'
  cat "$LEM_YATH_UI_PARITY_REPORT"
  printf 'UI PARITY TEST FAILED\n'
  exit 1
fi

printf '\n'
cat "$LEM_YATH_UI_PARITY_REPORT"
printf 'UI PARITY TEST PASSED\n'
