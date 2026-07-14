#!/usr/bin/env bash
# Real-ncurses coverage for pinned Dirvish presentation in directory-mode.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-dirvish-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-dirvish.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_DIRVISH_REPORT="$root/report"
export LEM_YATH_DIRVISH_ROOT="$root/files"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$LEM_YATH_DIRVISH_ROOT/child"
printf 'one\n' >"$LEM_YATH_DIRVISH_ROOT/child/one"
printf 'two\n' >"$LEM_YATH_DIRVISH_ROOT/child/two"
printf 'three\n' >"$LEM_YATH_DIRVISH_ROOT/child/three"
head -c 1536 /dev/zero >"$LEM_YATH_DIRVISH_ROOT/size.bin"
printf 'DIRVISH VISIT\n' >"$LEM_YATH_DIRVISH_ROOT/open.txt"
: >"$LEM_YATH_DIRVISH_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-dirvish-$id"
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
  sed -n '1,160p' "$LEM_YATH_DIRVISH_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_DIRVISH_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/dirvish-fixture.lisp")"
lem_start "$session" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  tmux_cmd resize-window -t "$session" -x 100 -y 24
  pass boot 'configured Lem opened a real directory-mode buffer'
else
  fail boot 'directory fixture did not become ready'
fi

if wait_report '^STATIC mode=DIRECTORY-MODE inserters=1 exact=yes bytes=..1\.5k count=.....3$'; then
  pass pinned-defaults 'hidden details and six-cell format match pinned Dirvish defaults'
else
  fail pinned-defaults 'configured inserters or exact size formatting differed'
fi

lem_keys "$session" F2
if wait_report '^DISPLAY width=100 file-cells=100 file-tail=..1\.5k file-size=..1\.5k file-source=..size\.bin directory-cells=100 directory-tail=.....3 directory-size=.....3 directory-source=..child/ modified=no readonly=yes$'; then
  pass display-100 'names stay compact while size and child count align at column 100'
else
  fail display-100 '100-column logical display or source text differed'
fi

screen="$(lem_capture "$session")"
if [[ "$screen" == *'size.bin'*'1.5k'* ]] &&
   [[ "$screen" == *'child/'* ]]; then
  pass ncurses-render 'real terminal rows contain compact names and right-edge metadata'
else
  fail ncurses-render 'Dirvish metadata did not reach the terminal screen'
fi

tmux_cmd resize-window -t "$session" -x 64 -y 24
sleep 0.5
lem_keys "$session" F2
if wait_report '^DISPLAY width=64 file-cells=64 file-tail=..1\.5k file-size=..1\.5k file-source=..size\.bin directory-cells=64 directory-tail=.....3 directory-size=.....3 directory-source=..child/ modified=no readonly=yes$'; then
  pass resize 'metadata followed the narrower window without entering source text'
else
  fail resize '64-column alignment or source invariants differed'
fi

lem_keys "$session" F3
if wait_report '^VISIT file=open\.txt text=DIRVISH VISIT$'; then
  pass visit 'the compact property-backed row opened the exact file'
else
  fail visit 'presentation changes broke directory row identity'
fi

lem_keys "$session" F4
if wait_report '^RELOAD inserters=1 exact=yes transformer=yes$'; then
  pass reload 'two source reloads retained one inserter and the composite transformer'
else
  fail reload 'reload duplicated or displaced presentation state'
fi

if ((failed)); then
  exit 1
fi

printf '\n%s\n' 'DIRVISH TEST PASSED'
