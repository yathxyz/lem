#!/usr/bin/env bash
# Real-ncurses coverage for display-only programming indentation guides.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-indent-guides-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-indent-guides.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_INDENT_GUIDES_REPORT="$root/report"
export LEM_YATH_INDENT_GUIDES_CODE="$root/code.py"
export LEM_YATH_INDENT_GUIDES_PROSE="$root/notes.md"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
cp "$here/scripts/indent-guides-code.py" "$LEM_YATH_INDENT_GUIDES_CODE"
cp "$here/scripts/indent-guides-prose.md" "$LEM_YATH_INDENT_GUIDES_PROSE"
chmod u+w "$LEM_YATH_INDENT_GUIDES_CODE" "$LEM_YATH_INDENT_GUIDES_PROSE"
: >"$LEM_YATH_INDENT_GUIDES_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-indent-guides-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-26s %s\n' "$1" "$2"
  printf '%s\n' '--- report ---'
  sed -n '1,240p' "$LEM_YATH_INDENT_GUIDES_REPORT" 2>/dev/null || true
  printf '%s\n' '--- screen ---'
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_INDENT_GUIDES_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/indent-guides-fixture.lisp")"
lem_start "$session" "$LEM_YATH_INDENT_GUIDES_CODE" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  tmux_cmd resize-window -t "$session" -x 100 -y 24
  pass boot 'configured Lem loaded the Python fixture'
else
  fail boot 'fixture did not become ready'
fi

if wait_report '^LINE label=level-one number=2 text=....if.ready:$' &&
   wait_report '^LINE label=level-two number=3 text=....│...for.item.in.items:$' &&
   wait_report '^LINE label=level-three number=4 text=....│...│...print\(item\)$'; then
  pass nested-levels 'mode spacing produced guides only for enclosing indentation levels'
else
  fail nested-levels 'space-indented logical lines did not receive the expected guides'
fi

if wait_report '^LINE label=blank-context number=5 text=....│...│...$'; then
  pass blank-context 'a blank line inherited the deepest adjacent indentation context'
else
  fail blank-context 'blank-line guide synthesis differed'
fi

if wait_report '^LINE label=tab-expanded number=7 text=....│...print\("tabs"\)$'; then
  pass tab-expansion 'leading tabs used visual columns and the configured tab width'
else
  fail tab-expansion 'tab indentation was not rendered at visual guide columns'
fi

if wait_report '^LINE label=string-limited number=10 text=....│.......deeply.indented.text$'; then
  pass string-scope 'multiline strings retain only the opening-context guide depth'
else
  fail string-scope 'guides descended through a multiline string body'
fi

if wait_report '^CODE programming=yes enabled=yes modified=no bytes-same=yes transformer=yes$'; then
  pass nonmutation 'rendering preserved buffer bytes, clean state, and the configured transformer'
else
  fail nonmutation 'guide rendering mutated source state or was not active'
fi

sleep 0.5
if lem_capture "$session" | grep -q '│'; then
  pass ncurses-render 'the terminal screen contains real vertical guide glyphs'
else
  fail ncurses-render 'logical guide glyphs did not reach the ncurses screen'
fi

lem_keys "$session" F3
wait_report '^PROSE programming=no enabled=yes modified=no$' || true
lem_keys "$session" Escape
sleep 0.4
prose_row=$(lem_capture "$session" | grep 'prose indentation stays ordinary' || true)
if wait_report '^LINE label=prose number=3 text=........prose.indentation.stays.ordinary$' &&
   wait_report '^PROSE programming=no enabled=yes modified=no$' &&
   [[ -n "$prose_row" && "$prose_row" != *'│'* ]]; then
  pass prose-scope 'Markdown indentation and terminal rendering stayed untouched'
else
  fail prose-scope 'guides leaked into the non-programming buffer'
fi

lem_keys "$session" F4
if wait_report '^LINE label=disabled number=4 text=............print\(item\)$' &&
   wait_report '^LINE label=reenabled number=4 text=....│...│...print\(item\)$' &&
   wait_report '^TOGGLE enabled=yes modified=no bytes-same=yes$'; then
  pass local-toggle 'the buffer-local toggle disabled and restored display only'
else
  fail local-toggle 'toggle state, rendered text, or source bytes differed'
fi

lem_keys "$session" F5
if wait_report '^LINE label=reloaded number=4 text=....│...│...print\(item\)$' &&
   wait_report '^RELOAD transformer=yes enabled=yes$'; then
  pass reload 'two source reloads retained one deterministic transformer'
else
  fail reload 'source reload changed guide behavior or activation'
fi

lem_keys "$session" F2
if wait_report '^SCREEN code line=4 column=0 modified=no$' &&
   lem_capture "$session" | grep -q '│'; then
  pass screen-return 'returning to code restored guides without moving point or dirtying text'
else
  fail screen-return 'code screen state did not restore cleanly'
fi

lem_keys "$session" F6
if wait_report '^BLANK-CURSOR line=5 column=0 text=....│...│... cursor=0 eol=no modified=no$' &&
   lem_capture "$session" | grep -q '│'; then
  pass blank-cursor 'virtual blank-line guides kept the real cursor at column zero'
else
  fail blank-cursor 'blank-line guide synthesis displaced or hid the cursor'
fi

if ((failed)); then
  exit 1
fi

printf '\nINDENT GUIDES TEST PASSED\n'
