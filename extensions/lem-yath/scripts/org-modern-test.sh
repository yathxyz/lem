#!/usr/bin/env bash
# Real-ncurses coverage for the active org-modern display-only projection.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-modern-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-modern.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_ORG_MODERN_REPORT="$root/report"
export LEM_TUI_WIDTH=150
export LEM_TUI_HEIGHT=40
mkdir -p "$HOME" "$XDG_CACHE_HOME"

fixture="$root/modern.org"
original="$root/original.org"
printf '%s\n' \
  '#+title: Modern fixture' \
  '' \
  '* TODO [#A] Parent :work:focus:' \
  'Body <2026-07-16 Thu> and <<target>> plus <<<radio>>>.' \
  '** NEXT Child' \
  'Child body.' \
  '- [ ] open' \
  '+ [X] done' \
  '  * [-] partial' \
  '| name | value |' \
  '|------+-------|' \
  '| one  | two   |' \
  '---------' \
  '#+begin_src text' \
  '- [ ] source decoy <2026-01-01 Thu>' \
  '| source | table |' \
  '#+end_src' \
  '#+filetags: :alpha:beta:' \
  >"$fixture"
cp "$fixture" "$original"
: >"$LEM_YATH_ORG_MODERN_REPORT"

session="lem-yath-org-modern-$id"
failed=0
cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  tail -80 "$LEM_YATH_ORG_MODERN_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern="$1" attempts=0
  while ((attempts < 120)); do
    grep -qE "$pattern" "$LEM_YATH_ORG_MODERN_REPORT" && return 0
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-modern-fixture.lisp")"
lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"

if wait_report '^READY$' && lem_wait_for "$session" 'Modern fixture' 60 >/dev/null; then
  pass boot "configured Org buffer loaded with org-modern enabled"
else
  fail boot "the org-modern fixture did not become ready"
fi

if grep -q '^MODE org=yes modern=yes transformer=yes hook=1 glyphs-one-cell=yes widths=1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1$' \
     "$LEM_YATH_ORG_MODERN_REPORT"; then
  pass mode-glyphs "the active hook and every replacement glyph preserve one cell"
else
  fail mode-glyphs "mode activation, transformer ownership, or glyph width diverged"
fi

baseline_ok=1
for expected in \
  'LINE label=keyword display=..title:.Modern.fixture' \
  'LINE label=heading display=▿.TODO...A..Parent..work.focus.' \
  'LINE label=child display=.▽.NEXT.Child' \
  'LINE label=inline display=Body..2026-07-16.Thu..and.↪.target...plus.⛯..radio....' \
  'LINE label=list-open display=–..□..open' \
  'LINE label=list-done display=◦..☑..done' \
  'LINE label=list-partial display=..∙..⊟..partial' \
  'LINE label=table display=│.name.│.value.│' \
  'LINE label=table-rule display=│──────┼───────│' \
  'LINE label=rule display=─────────' \
  'LINE label=block-begin display=▏.......src.text' \
  'LINE label=block-body-list display=-.[.].source.decoy.<2026-01-01.Thu>' \
  'LINE label=block-body-table display=|.source.|.table.|' \
  'LINE label=block-end display=▏.....src' \
  'LINE label=filetags display=..filetags:..alpha.beta.'; do
  if ! grep -Fq "$expected" "$LEM_YATH_ORG_MODERN_REPORT"; then
    baseline_ok=0
  fi
done
if ((baseline_ok)) &&
   ! grep '^LINE ' "$LEM_YATH_ORG_MODERN_REPORT" | grep -q 'same=no' &&
   grep -q '^LINE label=heading .* reverse=yes$' "$LEM_YATH_ORG_MODERN_REPORT" &&
   grep -q '^SOURCE modified=no bytes=same$' "$LEM_YATH_ORG_MODERN_REPORT"; then
  pass projection "headings, labels, lists, tables, blocks, and keywords render safely"
else
  fail projection "one or more pinned org-modern projections diverged"
fi

screen="$(lem_capture "$session")"
# A startup direnv notification can temporarily cover the parent row.  The
# child heading remains visible and exercises the same ncurses projection.
if grep -Fq '▽ NEXT Child' <<<"$screen" &&
   grep -Fq '–  □  open' <<<"$screen" &&
   grep -Fq '│ name │ value │' <<<"$screen" &&
   grep -Fq -- '- [ ] source decoy <2026-01-01 Thu>' <<<"$screen"; then
  pass ncurses "the real terminal shows decoration while source-block decoys stay literal"
else
  fail ncurses "the terminal presentation did not match the logical projection"
fi

lem_keys "$session" F2
if wait_report '^FOLD folds=1 next-hidden=yes modified=no bytes=same$' &&
   grep -q '^LINE label=folded display=▶\.TODO' "$LEM_YATH_ORG_MODERN_REPORT" &&
   lem_wait_for "$session" 'Parent.*\[\.\.\.\]' 15 >/dev/null; then
  pass folding "the heading indicator follows the real Org fold state"
else
  fail folding "folding did not update the display-only heading indicator"
fi

lem_keys "$session" F3
if wait_report '^TOGGLE enabled=yes modified=no bytes=same$' &&
   grep -q '^LINE label=disabled display=\*\.TODO' "$LEM_YATH_ORG_MODERN_REPORT" &&
   grep -q '^LINE label=reenabled display=▿\.TODO' "$LEM_YATH_ORG_MODERN_REPORT"; then
  pass toggle "M-x-compatible minor-mode state restores raw and modern rows"
else
  fail toggle "the buffer-local org-modern toggle changed text or failed to redraw"
fi

lem_keys "$session" F4
if wait_report '^CURSOR column=3 index=3 source-cells=10 display-cells=10 display=–\.\.□\.\.open modified=no$'; then
  pass cursor "cell-stable substitutions preserve the source cursor index"
else
  fail cursor "the transformed list row shifted cursor geometry"
fi

lem_keys "$session" F5
if wait_report '^RELOAD hook=1 transformer=yes enabled=yes modified=no bytes=same$' &&
   grep -q '^LINE label=reloaded display=▿\.TODO' "$LEM_YATH_ORG_MODERN_REPORT"; then
  pass reload "source reload retains one hook and the composed transformer"
else
  fail reload "reload duplicated ownership or disabled the projection"
fi

if cmp -s "$fixture" "$original"; then
  pass disk "rendering, folding, toggling, and reload leave disk bytes unchanged"
else
  fail disk "a display-only operation changed the Org file"
fi

if ((failed)); then
  printf '\nORG MODERN TEST FAILED\n'
  exit 1
fi

printf '\nORG MODERN TEST PASSED\n'
