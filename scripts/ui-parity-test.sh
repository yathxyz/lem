#!/usr/bin/env bash
# Real-ncurses coverage for the display baseline, delayed leader help, and
# programming-only numbers.
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
export LEM_YATH_UI_WRAP_FILE="$root/wrap.txt"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
printf '((((((rainbow))))))\n(defun answer (value)\n  (list :answer value "string")) ; comment\n' >"$LEM_YATH_UI_CODE_FILE"
printf '# Notes\n\nplain prose\n' >"$LEM_YATH_UI_PROSE_FILE"
{
  printf 'WRAP-BEGIN-'
  head -c 600 /dev/zero | tr '\0' x
  printf '%s\n' '-TAIL-SENTINEL'
  printf '%s\n' 'SECOND-LINE'
} >"$LEM_YATH_UI_WRAP_FILE"
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
lem_start "$session" "$LEM_YATH_UI_CODE_FILE" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  tmux_cmd resize-window -t "$session" -x 100 -y 30
  pass boot "configured Lem loaded the UI fixture"
else
  fail boot "fixture did not become ready"
fi

if run_mx lem-yath-test-ui-static-checks &&
   wait_report '^SUMMARY STATIC PASS failures=0$'; then
  pass static-contracts "display defaults, tab lifecycle, and leader behavior are configured"
else
  fail static-contracts "display or leader static contracts failed"
fi

if run_mx lem-yath-test-ui-theme-state &&
   wait_report '^THEME name=modus-vivendi-tinted foreground=#ffffff background=#0d0e1c region=#ffffff/#555a66 modeline=#ffffff/#484d67 inactive=#969696/#292d48 warning=#d0bc00/none string=#2fafff/none comment=#ef8386/none keyword=#79a8ff/none constant=#b6a0ff/none function=#f78fe7/none variable=#4ae2f0/none type=#11c777/none builtin=#feacd0/none line=#989898/#1d2235 active-line=#ffffff/#4a4f69 paren=#ffffff/#4f7f9f$' &&
   wait_report '^RAINBOW attributes=PAREN-COLOR-1,PAREN-COLOR-2,PAREN-COLOR-3,PAREN-COLOR-4,PAREN-COLOR-5,PAREN-COLOR-6 colors=#ffffff/none,#ff66ff/none,#00eff0/none,#ff6b55/none,#efef00/none,#b6a0ff/none$' &&
   wait_report '^SHOW-PAREN enabled=yes timer=yes overlays=2 colors=#ffffff/#4f7f9f,#ffffff/#4f7f9f$'; then
  pass theme "Modus semantic faces, six Common Lisp depths, and pair highlighting are active"
else
  fail theme "theme attributes or rainbow delimiter properties differed"
fi

escape=$(printf '\033')
rendered_colors=$(
  tmux_cmd capture-pane -t "$session" -p -e 2>/dev/null |
    LC_ALL=C grep -aoE "${escape}\\[(3[0-7]|9[0-7]|38[:;]5[:;][0-9]+)m" |
    sort -u | wc -l | tr -d ' '
)
if ((rendered_colors >= 5)); then
  pass theme-render "ncurses emitted $rendered_colors distinct foreground classes"
else
  fail theme-render "ncurses exposed only $rendered_colors foreground classes"
fi

if run_mx lem-yath-test-ui-reload-display &&
   wait_report '^DISPLAY-RELOAD theme=modus-vivendi-tinted wrap=no highlight=no frame=no rainbow-hooks=1$'; then
  pass display-reload "theme and UI reload preserve one idempotent baseline"
else
  fail display-reload "display reload changed state or duplicated hooks"
fi

lem_keys "$session" C-x t 2
sleep 0.5
if run_mx lem-yath-test-ui-frame-state &&
   wait_report '^FRAME enabled=yes count=2$' &&
   lem_capture "$session" | sed -n '1p' | grep -q '0:' &&
   lem_capture "$session" | sed -n '1p' | grep -q '1:'; then
  pass on-demand-tab "C-x t 2 enabled tabs and created a second frame"
else
  fail on-demand-tab "C-x t 2 did not lazily enable the tab UI"
fi

if run_mx lem-yath-test-ui-reload-active-tabs &&
   wait_report '^TAB-RELOAD enabled=yes count=2$'; then
  pass tab-reload "configuration reload preserved user-created tabs"
else
  fail tab-reload "configuration reload destroyed active tabs"
fi

run_mx toggle-frame-multiplexer || true
sleep 0.3
if run_mx lem-yath-test-ui-frame-state &&
   wait_report '^FRAME enabled=no count=0$' &&
   ! lem_capture "$session" | sed -n '1p' | grep -qE '0:|1:'; then
  pass hide-tabs "disabling tabs restored the header-free baseline"
else
  fail hide-tabs "frame multiplexer did not return to its startup state"
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

# A fresh ordinary buffer inherits the truncated startup default.  This suite
# checks rendering only; screen-line modal semantics live in screen-line-test.sh.
run_mx lem-yath-test-ui-wrap-state || true
sleep 0.3
if wait_report '^WRAP label=state enabled=no line=1 column=0 ' &&
   ! lem_capture "$session" | grep -q 'TAIL-SENTINEL' &&
   lem_capture "$session" | sed -n '1p' | grep -q 'WRAP-BEGIN' &&
   ! lem_capture "$session" | sed -n '1p' | grep -qE '0: .*wrap'; then
  pass truncated-startup "long lines clip to one row with no tab header"
else
  fail truncated-startup "startup wrapped, exposed the tail, or retained a tab header"
fi

run_mx toggle-line-wrap || true
run_mx lem-yath-test-ui-wrap-state || true
sleep 0.3
if [[ $(grep '^WRAP label=state ' "$LEM_YATH_UI_PARITY_REPORT" | tail -1) == *'enabled=yes'* ]] &&
   lem_capture "$session" | grep -q 'TAIL-SENTINEL'; then
  pass wrapped-display "the existing wrap toggle rendered the long-line tail"
else
  fail wrapped-display "the wrap toggle did not expose the long-line tail"
fi

run_mx toggle-line-wrap || true
run_mx lem-yath-test-ui-wrap-state || true
sleep 0.3
if [[ $(grep '^WRAP label=state ' "$LEM_YATH_UI_PARITY_REPORT" | tail -1) == *'enabled=no'* ]] &&
   ! lem_capture "$session" | grep -q 'TAIL-SENTINEL'; then
  pass truncated-restore "toggling wrapping off restored clipped rendering"
else
  fail truncated-restore "toggle-off did not restore truncated rendering"
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
   lem_capture "$session" | grep -q 'workspace symbols'; then
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
