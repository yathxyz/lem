#!/usr/bin/env bash
# Real-ncurses coverage for the display baseline, global delayed prefix help,
# and programming-only numbers.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

id="${LEM_YATH_CHECK_ID:-ui-parity-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-ui-parity.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_UI_PARITY_REPORT="$root/report"
export LEM_YATH_UI_CODE_FILE="$root/code.lisp"
export LEM_YATH_UI_PROGRAMMING_FILE="$root/rainbow.py"
export LEM_YATH_UI_RAINBOW_ERROR_FILE="$root/rainbow-errors.py"
export LEM_YATH_UI_PROSE_FILE="$root/notes.md"
export LEM_YATH_UI_WRAP_FILE="$root/wrap.txt"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
printf '(((((((((rainbow)))))))))\n(defun answer (value)\n  (list :answer value "string")) ; comment\n' >"$LEM_YATH_UI_CODE_FILE"
printf '%s\n' 'value = ({["ignored ( [ { } ] )"]})  # ignored ({[]})' \
  >"$LEM_YATH_UI_PROGRAMMING_FILE"
printf '%s\n' 'mismatch = ([)]' 'unmatched = )(' 'escaped = \(' \
  >"$LEM_YATH_UI_RAINBOW_ERROR_FILE"
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
  local command=$1 first index
  lem_keys "$session" Escape
  sleep 0.3
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  first=${command:0:1}
  tmux_cmd send-keys -t "$session" -l "$first"
  lem_wait_for "$session" "Command: ${first}" 5 >/dev/null || return 1
  for ((index = 1; index < ${#command}; index++)); do
    tmux_cmd send-keys -t "$session" -l "${command:index:1}"
    sleep 0.05
  done
  sleep 0.2
  lem_keys "$session" Enter
  sleep 0.4
}

screen_has_leader() {
  lem_capture "$session" | grep -q 'lem-yath-avy-goto-char'
}

screen_has_dynamic_prefix() {
  lem_capture "$session" | grep -q 'ui-prefix-local'
}

screen_has_c_x_prefix() {
  lem_capture "$session" | grep -q 'C-f find-file'
}

screen_has_page_one() {
  lem_capture "$session" | grep -q 'a ui-page-dispatch'
}

screen_has_page_two() {
  lem_capture "$session" | grep -q 'x ui-page-dispatch'
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
   wait_report '^RAINBOW attributes=PAREN-COLOR-1,PAREN-COLOR-2,PAREN-COLOR-3,PAREN-COLOR-4,PAREN-COLOR-5,PAREN-COLOR-6,RAINBOW-DELIMITER-COLOR-7,RAINBOW-DELIMITER-COLOR-8,RAINBOW-DELIMITER-COLOR-9 colors=#ffffff/none,#ff66ff/none,#00eff0/none,#ff6b55/none,#efef00/none,#b6a0ff/none,#44df44/none,#79a8ff/none,#f78fe7/none$' &&
   wait_report '^SHOW-PAREN enabled=yes timer=yes overlays=2 colors=#ffffff/#4f7f9f,#ffffff/#4f7f9f$'; then
  pass theme "Modus semantic faces, nine delimiter depths, and pair highlighting are active"
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

if run_mx lem-yath-test-ui-programming-rainbow &&
   wait_report '^PROGRAM-RAINBOW mode=PYTHON-MODE programming=yes attributes=PAREN-COLOR-1,PAREN-COLOR-2,PAREN-COLOR-3,SYNTAX-STRING-ATTRIBUTE,SYNTAX-STRING-ATTRIBUTE,SYNTAX-STRING-ATTRIBUTE,SYNTAX-STRING-ATTRIBUTE,SYNTAX-STRING-ATTRIBUTE,SYNTAX-STRING-ATTRIBUTE,PAREN-COLOR-3,PAREN-COLOR-2,PAREN-COLOR-1,SYNTAX-COMMENT-ATTRIBUTE,SYNTAX-COMMENT-ATTRIBUTE,SYNTAX-COMMENT-ATTRIBUTE,SYNTAX-COMMENT-ATTRIBUTE,SYNTAX-COMMENT-ATTRIBUTE,SYNTAX-COMMENT-ATTRIBUTE$'; then
  pass programming-rainbow "mixed delimiters use syntax depth while strings and comments remain untouched"
else
  fail programming-rainbow "non-Lisp delimiter colors or syntax exclusions differed"
fi

if run_mx lem-yath-test-ui-rainbow-errors &&
   wait_report '^RAINBOW-ERRORS attributes=PAREN-COLOR-1,PAREN-COLOR-2,RAINBOW-DELIMITER-MISMATCHED-ATTRIBUTE,PAREN-COLOR-1,RAINBOW-DELIMITER-UNMATCHED-ATTRIBUTE,RAINBOW-DELIMITER-UNMATCHED-ATTRIBUTE,NIL colors=#ffffff/none,#ff66ff/none,#ffffff/#7a6100,#ffffff/none,#ffffff/#9d1f1f,#ffffff/#9d1f1f,none/none$'; then
  pass rainbow-errors "mismatched, unmatched, negative-depth, and escaped delimiters match Emacs"
else
  fail rainbow-errors "error delimiter classification or Modus colors differed"
fi

if run_mx lem-yath-test-ui-reload-display &&
   wait_report '^DISPLAY-RELOAD theme=modus-vivendi-tinted wrap=no highlight=no frame=no rainbow-hooks=1 upstream-hooks=0$'; then
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
  pass leader-rebuild "reload replaces one shared raw tree and clears stale UI/cache state"
else
  fail leader-rebuild "leader rebuild lifecycle contracts failed"
fi

if run_mx lem-yath-test-ui-reload-prefix-help &&
   wait_report '^PREFIX-RELOAD pending-clean=yes stale-safe=yes visible-clean=yes mode=yes delay=321 limit=19 docs=yes input-bindings=1 cleanup-hooks=1$'; then
  pass prefix-help-reload "direct reload cancels pending/visible help and preserves preferences"
else
  fail prefix-help-reload "prefix-help reload lifecycle contracts failed"
fi

if run_mx lem-yath-test-ui-code-state &&
   wait_report '^STATE label=code file=code\.lisp programming=yes line-mode=yes fixture-mode=yes git-mode=yes line-numbers=yes relative=2 number-width=3 gutter=G 2 gutter-width=4 '; then
  pass code-line-numbers "the composed gutter renders a relative distance in code"
else
  fail code-line-numbers "programming gutter did not expose relative line numbers"
fi

if run_mx lem-yath-test-ui-production-gutters &&
   wait_report '^STATE label=production-gutters file=code\.lisp programming=yes line-mode=yes fixture-mode=no git-mode=yes line-numbers=yes relative=2 number-width=3 gutter=2 gutter-width=3 '; then
  pass production-gutters "an unchanged code buffer renders only its relative-number column"
else
  fail production-gutters "an empty Git gutter added width or swallowed relative numbers"
fi

if run_mx lem-yath-test-ui-reordered-code-state &&
   wait_report '^STATE label=code-reordered file=code\.lisp programming=yes line-mode=yes fixture-mode=yes git-mode=yes line-numbers=yes relative=2 number-width=3 gutter=G 2 gutter-width=4 '; then
  pass reordered-gutters "line-number re-enable preserved a lower-priority gutter"
else
  fail reordered-gutters "gutter composition depended on global-mode order"
fi

if run_mx lem-yath-test-ui-prose-state &&
   wait_report '^STATE label=prose file=notes\.md programming=no line-mode=yes fixture-mode=yes git-mode=no line-numbers=no relative=none number-width=0 gutter=fixture-gutter gutter-width=14 '; then
  pass prose-line-numbers "Markdown omits code-only gutters without swallowing another gutter"
else
  fail prose-line-numbers "prose gutter scope or composite-gutter isolation failed"
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

lem_keys "$session" p
sleep 0.2
if lem_capture "$session" | grep -q '\[Fixture unrelated nested\]' &&
   lem_capture "$session" | grep -q 'nested leaf'; then
  pass unrelated-nested "native transient nesting still refreshes immediately"
else
  fail unrelated-nested "global Which-Key delay leaked into a native transient"
fi
lem_keys "$session" Escape
sleep 0.4

# A dynamically created local/global shared prefix must merge both maps, keep
# one shadow winner, sort by key, and use the ordinary one-second idle delay.
lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" F9
sleep 0.7
if screen_has_dynamic_prefix; then
  fail dynamic-prefix-delay "dynamic prefix help appeared before one second"
else
  dynamic_shown=0
  for _ in {1..8}; do
    sleep 0.1
    if screen_has_dynamic_prefix; then
      dynamic_shown=1
      break
    fi
  done
  dynamic_screen=$(lem_capture "$session")
  local_line=$(printf '%s\n' "$dynamic_screen" | grep -n 'ui-prefix-local' | head -1 | cut -d: -f1)
  global_line=$(printf '%s\n' "$dynamic_screen" | grep -n 'ui-prefix-global' | head -1 | cut -d: -f1)
  shadow_line=$(printf '%s\n' "$dynamic_screen" | grep -n 'ui-prefix-shadow-local' | head -1 | cut -d: -f1)
  if ((dynamic_shown)) &&
     [[ -n "$local_line" && -n "$global_line" && -n "$shadow_line" ]] &&
     ((local_line < global_line && global_line < shadow_line)) &&
     ! printf '%s\n' "$dynamic_screen" | grep -q 'ui-prefix-shadow-global'; then
    pass dynamic-prefix-merge "late mode/global maps merged, sorted, and honored local shadowing"
  else
    fail dynamic-prefix-merge "dynamic shared prefix contents or precedence were wrong"
  fi
fi

lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" F9
sleep 0.08
lem_keys "$session" a
if wait_report '^PREFIX-DISPATCH local count=1 popup=no$' 10; then
  sleep 1.2
  if screen_has_dynamic_prefix; then
    fail dynamic-fast-dispatch "completed dynamic prefix resurrected delayed help"
  else
    pass dynamic-fast-dispatch "displayed continuation dispatched and canceled its timer"
  fi
else
  fail dynamic-fast-dispatch "displayed local continuation did not dispatch"
fi

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" F9
sleep 0.08
lem_keys "$session" b
if wait_report '^PREFIX-DISPATCH global$' 10; then
  pass dynamic-global-dispatch "merged global continuation dispatched through the live keymaps"
else
  fail dynamic-global-dispatch "merged global continuation did not dispatch"
fi

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" F9
sleep 0.08
lem_keys "$session" d
if wait_report '^PREFIX-DISPATCH shadow-local$' 10 &&
   ! grep -q '^PREFIX-DISPATCH shadow-global$' "$LEM_YATH_UI_PARITY_REPORT"; then
  pass dynamic-shadow-dispatch "the displayed local shadow winner was the dispatched command"
else
  fail dynamic-shadow-dispatch "displayed shadowing and actual dispatch diverged"
fi

# The pinned Which-Key C-h map pages width-bounded snapshots while leaving
# dispatch in the live prefix.  A 45x24 terminal makes F8 exactly two pages.
tmux_cmd resize-window -t "$session" -x 45 -y 24
lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" F8
sleep 0.7
if screen_has_page_one; then
  fail which-key-page-delay "the first page appeared before the configured delay"
elif lem_wait_for "$session" 'a ui-page-dispatch' 2 >/dev/null; then
  page_one=$(lem_capture "$session")
  if printf '%s\n' "$page_one" | grep -q 'l ui-page-dispatch' &&
     ! printf '%s\n' "$page_one" | grep -q 'm ui-page-dispatch'; then
    pass which-key-page-one "the narrow popup showed only the first width-bounded page"
  else
    fail which-key-page-one "the first page overflowed or omitted its final entry"
  fi
else
  fail which-key-page-delay "the first page did not appear after one second"
fi

lem_keys "$session" C-h n
sleep 0.4
page_two=$(lem_capture "$session")
if printf '%s\n' "$page_two" | grep -q 'm ui-page-dispatch' &&
   printf '%s\n' "$page_two" | grep -q 'x ui-page-dispatch' &&
   ! printf '%s\n' "$page_two" | grep -q 'a ui-page-dispatch'; then
  pass which-key-page-next "C-h n moved to page two without horizontal scrolling"
else
  fail which-key-page-next "C-h n did not replace page one with page two"
fi

lem_keys "$session" C-h p
sleep 0.4
if screen_has_page_one && ! screen_has_page_two; then
  pass which-key-page-previous "C-h p returned to page one"
else
  fail which-key-page-previous "C-h p did not restore page one"
fi

lem_keys "$session" C-h p
sleep 0.4
if screen_has_page_two && ! screen_has_page_one; then
  pass which-key-page-cycle "previous-page cycles from the first page to the last"
else
  fail which-key-page-cycle "previous-page did not wrap at the first page"
fi

lem_keys "$session" x
if wait_report '^PAGE-DISPATCH arg=1 popup=no$' 10; then
  pass which-key-page-dispatch "a continuation on the displayed page dispatched through the live map"
else
  fail which-key-page-dispatch "paging changed or blocked live continuation dispatch"
fi

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" F8
sleep 1.2
lem_keys "$session" C-h 3 x
if wait_report '^PAGE-DISPATCH arg=3 popup=no$' 10; then
  pass which-key-digit-argument "C-h digit replayed the prefix with Lem's universal argument"
else
  fail which-key-digit-argument "the dispatcher lost the digit or replayed the wrong prefix"
fi

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" F8
sleep 1.2
lem_keys "$session" C-h d
sleep 0.4
if lem_capture "$session" | grep -q 'Handle a'; then
  pass which-key-docstrings "C-h d added the command's first docstring line"
else
  fail which-key-docstrings "C-h d did not rebuild descriptions from command documentation"
fi
lem_keys "$session" C-h d
sleep 0.4
if ! lem_capture "$session" | grep -q 'Handle a'; then
  pass which-key-docstrings-restore "a second C-h d restored command-name descriptions"
else
  fail which-key-docstrings-restore "docstring display did not toggle back off"
fi

lem_keys "$session" C-h h
sleep 0.4
if lem_capture "$session" | grep -q 'F8 bindings' &&
   lem_capture "$session" | grep -q 'ui-page-dispatch'; then
  pass which-key-standard-help "C-h h opened focused live prefix bindings"
else
  fail which-key-standard-help "the standard-help branch omitted the active prefix"
fi
lem_keys "$session" q
sleep 0.3

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" F8
sleep 0.1
lem_keys "$session" C-h
sleep 0.4
if lem_capture "$session" | grep -q 'F8 bindings'; then
  pass which-key-early-help "C-h before the popup used standard prefix help"
else
  fail which-key-early-help "pre-popup C-h incorrectly entered the paging reader"
fi
lem_keys "$session" q
sleep 0.3

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" F8
sleep 1.2
lem_keys "$session" C-h a
sleep 0.4
if ! screen_has_page_one && ! screen_has_page_two; then
  pass which-key-abort "C-h a aborted the incomplete prefix and removed its page"
else
  fail which-key-abort "the abort branch left the prefix popup active"
fi

# Undoing from a nested prefix replays its parent and starts a fresh idle
# interval, matching Which-Key's key-sequence reload rather than faking a page.
tmux_cmd resize-window -t "$session" -x 100 -y 30
lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" C-x
sleep 1.2
lem_keys "$session" t
sleep 1.2
lem_keys "$session" C-h u
sleep 0.7
if screen_has_c_x_prefix; then
  fail which-key-undo-delay "nested undo redisplayed its parent too early"
elif lem_wait_for "$session" 'C-f find-file' 2 >/dev/null; then
  pass which-key-undo-prefix "C-h u replayed the parent prefix with a fresh delay"
else
  fail which-key-undo-prefix "nested undo did not restore the live parent prefix"
fi
lem_keys "$session" Escape
sleep 0.3

# Built-in global and Vi-state prefixes must participate too.
lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" C-x
sleep 0.7
if screen_has_c_x_prefix; then
  fail global-prefix-delay "C-x help appeared before one second"
else
  if lem_wait_for "$session" 'C-f find-file' 2 >/dev/null; then
    pass global-prefix "the built-in C-x map received delayed raw-command guidance"
  else
    fail global-prefix "the built-in C-x map remained silent"
  fi
fi

lem_keys "$session" t
sleep 0.7
if screen_has_c_x_prefix ||
   lem_capture "$session" | grep -q 'lem-yath-frame-create'; then
  fail nested-global-delay "nested C-x t reused or replaced the popup too early"
else
  if lem_wait_for "$session" 'lem-yath-frame-create' 2 >/dev/null; then
    pass nested-global-delay "nested C-x t hid the old page and waited a fresh second"
  else
    fail nested-global-delay "nested C-x t guidance missed its second idle window"
  fi
fi
lem_keys "$session" Escape
sleep 1.2
if screen_has_c_x_prefix ||
   lem_capture "$session" | grep -q 'lem-yath-frame-create'; then
  fail global-prefix-cancel "Escape left or resurrected global prefix help"
else
  pass global-prefix-cancel "Escape canceled global prefix help without resurrection"
fi

lem_keys "$session" Escape
sleep 0.3
lem_keys "$session" g
if lem_wait_for "$session" 'lem-yath-next-g-line' 2 >/dev/null; then
  pass vi-prefix "the active normal-state g map received delayed guidance"
else
  fail vi-prefix "the active Vi-state prefix remained silent"
fi
lem_keys "$session" Escape
sleep 0.4

# Insert-state C-c shares a prefix across the Vi state and Lisp mode.  Both
# valid layers must be described, with the state-local i binding winning.
tmux_cmd resize-window -t "$session" -x 180 -y 30
lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" i
sleep 0.2
lem_keys "$session" C-c
sleep 0.7
if lem_capture "$session" | grep -q 'lem-yath-llm-send'; then
  fail insert-shared-prefix "insert C-c help appeared before one second"
else
  if lem_wait_for "$session" 'lem-yath-llm-send' 2 >/dev/null &&
     lem_capture "$session" | grep -q 'lisp-eval-at-point'; then
    pass insert-shared-prefix "insert C-c merged the state-local and Lisp-mode continuations"
  else
    fail insert-shared-prefix "insert C-c omitted an active keymap layer"
  fi
fi
lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" Escape
sleep 0.3
tmux_cmd resize-window -t "$session" -x 100 -y 30

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
    if screen_has_leader; then
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
sleep 0.7
if screen_has_leader ||
   lem_capture "$session" | grep -q 'lem-yath-project-find-file'; then
  fail nested-leader "nested leader help appeared before its fresh idle delay"
else
  if lem_wait_for "$session" 'lem-yath-project-find-file' 2 >/dev/null &&
     lem_capture "$session" | grep -q 'lem-yath-workspace-symbol'; then
    pass nested-leader "leader nesting uses raw commands after a fresh one-second wait"
  else
    fail nested-leader "project continuation help was missing or mislabeled"
  fi
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
sleep 0.3
lem_keys "$session" F6
if wait_report '^VI-STATE current=VISUAL buffer=VISUAL$' 3; then
  lem_keys "$session" Space
  if lem_wait_for "$session" 'lem-yath-avy-goto-char' 2 >/dev/null; then
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
