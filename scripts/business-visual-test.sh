#!/usr/bin/env bash
# Real-ncurses coverage for the host-gated business document presentation.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-business-visual-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-business-visual.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_BUSINESS_VISUAL_REPORT="$root/report"
export LEM_TUI_WIDTH=160
export LEM_TUI_HEIGHT=30
mkdir -p "$HOME" "$XDG_CACHE_HOME"

document="$root/business.org"
printf '%s\n' 'BUSINESS-BEGIN' '* Calm document' >"$document"
: >"$LEM_YATH_BUSINESS_VISUAL_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-business-visual-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_BUSINESS_VISUAL_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

leading_column() {
  lem_capture "$session" |
    awk '/BUSINESS-BEGIN/ { match($0, /[^ ]/); print RSTART - 1; exit }'
}

wait_column() {
  local expected=$1 index=0 actual
  while ((index < 40)); do
    actual=$(leading_column)
    if [[ $actual == "$expected" ]]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/business-visual-fixture.lisp")"
lem_start "$session" "$document" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  pass boot "configured Lem loaded the business visual fixture"
else
  fail boot "fixture did not become ready"
fi

if wait_report '^HOST default=yes actual=[^ ]+ matched=(yes|no) auto=(yes|no) consistent=yes$' &&
   wait_report '^STATE label=baseline host=[^ ]+ theme=modus-vivendi-tinted global=no doc=no center=no wrap=no target=100 fill=73 jump=yes .*normal=box insert=bar emacs=box replace=underline fg=#ffffff bg=#0d0e1c region=#555a66 geometry=160:0:0:160$' &&
   wait_column 0; then
  pass host-gate "automatic activation exactly followed the workwin host gate"
else
  fail host-gate "automatic activation diverged from the configured host policy"
fi

lem_keys "$session" F5
if wait_report '^STATE label=enabled host=[^ ]+ theme=business-operandi global=yes doc=yes center=yes wrap=yes target=88 fill=88 jump=no compact=yes vi=yes normal=box insert=bar emacs=bar replace=underline fg=#1f2933 bg=#fbfbfa region=#cfe0f5 geometry=160:36:36:88$' &&
   wait_column 36; then
  pass presentation "manual enable applied the light 88-column document page"
else
  fail presentation "theme, modeline, cursor, or rendered document geometry diverged"
fi

if wait_report '^PREDICATES org=yes markdown=yes epub=yes notmuch=yes feed=yes devdocs=yes text=yes pdf=no search=no lisp=no$'; then
  pass mode-boundary "document modes were included without styling code, lists, or PDFs"
else
  fail mode-boundary "business document mode classification was too broad or incomplete"
fi

if wait_report '^PREEXIST during=yes center=yes target=77 wrap=yes$'; then
  pass local-restoration "a pre-existing centered view survived document-profile removal"
else
  fail local-restoration "buffer-local centered state was overwritten"
fi

lem_keys "$session" F6
if wait_report '^STATE label=reload .*theme=business-operandi global=yes doc=yes center=yes wrap=yes target=88 fill=88 jump=no .*geometry=160:36:36:88$'; then
  pass reload "live source reload retained the active profile without duplicate state"
else
  fail reload "live reload lost business presentation state"
fi

lem_keys "$session" F7
if wait_report '^STATE label=code .*global=yes doc=no center=no wrap=no target=100 fill=73 jump=no .*geometry=160:3:0:157$' &&
   wait_report '^STATE label=org-return .*global=yes doc=yes center=yes wrap=yes target=88 fill=88 jump=no .*geometry=160:36:36:88$'; then
  pass mode-transition "major-mode changes removed and reapplied presentation state"
else
  fail mode-transition "document presentation leaked into code or failed to return"
fi

lem_keys "$session" F8
if wait_report '^RESTORE modeline=yes default-hosts=yes$' &&
   wait_report '^STATE label=disabled host=[^ ]+ theme=modus-vivendi-tinted global=no doc=no center=no wrap=no target=100 fill=73 jump=yes compact=no vi=yes normal=box insert=bar emacs=box replace=underline fg=#ffffff bg=#0d0e1c region=#555a66 geometry=160:0:0:160$' &&
   wait_column 0; then
  pass disable-restore "toggle-off restored theme, modeline, cursors, pulse, and buffer state"
else
  fail disable-restore "profile teardown left global or buffer-local state behind"
fi

if ((failed)); then
  printf '\n'
  cat "$LEM_YATH_BUSINESS_VISUAL_REPORT"
  printf 'BUSINESS VISUAL TEST FAILED\n'
  exit 1
fi

printf '\n'
cat "$LEM_YATH_BUSINESS_VISUAL_REPORT"
printf 'BUSINESS VISUAL TEST PASSED\n'
