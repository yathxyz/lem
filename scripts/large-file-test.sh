#!/usr/bin/env bash
# Real-ncurses coverage for the configured large-file confirmation boundary.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-large-file-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-large-file.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_LARGE_FILE_REPORT="$root/report"
export LEM_YATH_SOURCE="${LEM_YATH_SOURCE:-$here/lem-yath}"
export LEM_YATH_LARGE_FILE_ABORT="$WORKDIR/abort.el"
export LEM_YATH_LARGE_FILE_TEMPORARY="$WORKDIR/temporary.el"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
: >"$LEM_YATH_LARGE_FILE_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-large-file-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-25s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-25s %s\n' "$1" "$2"
  sed -n '1,220p' "$LEM_YATH_LARGE_FILE_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

make_ascii_file() {
  local count=$1 path=$2
  printf '%*s' "$count" '' >"$path"
}

make_ascii_file 64 "$WORKDIR/exact.el"
make_ascii_file 65 "$WORKDIR/normal.el"
make_ascii_file 65 "$LEM_YATH_LARGE_FILE_ABORT"
make_ascii_file 65 "$LEM_YATH_LARGE_FILE_TEMPORARY"
printf 'A\r\n\377' >"$WORKDIR/literal.el"
printf '%*s' 61 '' >>"$WORKDIR/literal.el"
cp "$WORKDIR/literal.el" "$WORKDIR/literal.original"

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_LARGE_FILE_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

state_count() {
  grep -c '^STATE ' "$LEM_YATH_LARGE_FILE_REPORT" 2>/dev/null || true
}

report_after() {
  local before=$1 pattern=$2 index=0
  lem_keys "$session" F2
  while ((index < 60)); do
    if (( $(state_count) > before )) &&
       tail -n 1 "$LEM_YATH_LARGE_FILE_REPORT" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

begin_find_file() {
  local path=$1
  lem_keys "$session" Escape Escape M-x
  sleep 0.2
  tmux_cmd send-keys -t "$session" -l 'find-file'
  lem_keys "$session" Enter
  sleep 0.2
  tmux_cmd send-keys -t "$session" -l "$path"
  lem_keys "$session" Enter
}

open_without_confirmation() {
  local path=$1 name=${1##*/}
  begin_find_file "$path"
  lem_wait_for "$session" "$name" 15 >/dev/null
}

fixture="$(lem-yath_lisp_string "$here/scripts/large-file-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"

if lem_wait_for "$session" 'LARGE FILE ORIGIN' 60 >/dev/null &&
   lem_wait_for "$session" 'NORMAL' 10 >/dev/null &&
   wait_report '^READY threshold=52428800 hook=1$' 60; then
  pass boot 'configured Lem loaded the 50 MiB policy once'
else
  fail boot 'large-file fixture did not become ready with the configured policy'
fi

lem_keys "$session" F3
if wait_report '^THRESHOLD value=64$' 10; then
  pass test-threshold 'the isolated interaction threshold was reduced to 64 bytes'
else
  fail test-threshold 'could not configure the bounded interaction fixture'
fi

lem_keys "$session" F4
if wait_report '^RELOAD threshold=64 hook=1$' 15; then
  pass reload 'source reload preserved the user threshold and one pre-read hook'
else
  fail reload 'source reload reset the threshold or duplicated the hook'
fi

open_without_confirmation "$WORKDIR/exact.el"
before=$(state_count)
if report_after "$before" 'name=exact\.el mode=ELISP-MODE literal=no chars=64 .*threshold=64$'; then
  pass exact-threshold 'a file exactly at the threshold opened without a prompt'
else
  fail exact-threshold 'the configured threshold was not strictly greater-than'
fi

begin_find_file "$LEM_YATH_LARGE_FILE_ABORT"
if lem_wait_for "$session" 'File abort\.el is large \(65\), really open\?' 15 >/dev/null; then
  pass pre-read-prompt 'the warning appeared before the oversized file was read'
else
  fail pre-read-prompt 'the oversized file did not present the configured warning'
fi
lem_keys "$session" n
sleep 0.4
lem_keys "$session" F5
if wait_report '^ABORT current=exact\.el visited=no$' 10; then
  pass abort 'n left the origin selected and allocated no visited buffer'
else
  fail abort 'aborting created or selected an oversized-file buffer'
fi

begin_find_file "$WORKDIR/normal.el"
if lem_wait_for "$session" 'File normal\.el is large \(65\), really open\?' 15 >/dev/null; then
  lem_keys "$session" y
else
  fail normal-open 'the normal-open choice was not offered'
fi
lem_wait_for "$session" 'normal\.el' 15 >/dev/null || true
before=$(state_count)
if report_after "$before" 'name=normal\.el mode=ELISP-MODE literal=no chars=65 .*paredit=yes threshold=64$'; then
  pass normal-open 'y used ordinary decoding and file-mode hooks'
else
  fail normal-open 'the normal choice did not retain the ordinary Elisp lifecycle'
fi

begin_find_file "$WORKDIR/literal.el"
if lem_wait_for "$session" 'File literal\.el is large \(65\), really open\?' 15 >/dev/null; then
  lem_keys "$session" l
else
  fail literal-open 'the literal-open choice was not offered'
fi
lem_wait_for "$session" 'literal\.el' 15 >/dev/null || true
before=$(state_count)
if report_after "$before" 'name=literal\.el mode=FUNDAMENTAL-MODE literal=yes chars=65 modified=no readonly=no encoding=LATIN-1 eol=LF tree=no lsp=no lint=no paredit=no threshold=64$'; then
  pass literal-open 'l used byte-preserving Fundamental mode without file hooks'
else
  fail literal-open 'literal mode decoded, normalized, or activated ordinary hooks'
fi

lem_keys "$session" i
tmux_cmd send-keys -t "$session" -l 'Z'
lem_keys "$session" Escape Escape C-x C-s
sleep 0.6
before=$(state_count)
if report_after "$before" 'name=literal\.el mode=FUNDAMENTAL-MODE literal=yes chars=66 modified=no .*encoding=LATIN-1 eol=LF .*threshold=64$' &&
   test "$(head -c 1 "$WORKDIR/literal.el")" = Z &&
   tail -c +2 "$WORKDIR/literal.el" | cmp -s - "$WORKDIR/literal.original"; then
  pass literal-save 'literal save retained mode and round-tripped every original byte'
else
  fail literal-save 'literal save changed mode or failed the byte round-trip'
fi

printf '\376' >>"$WORKDIR/literal.el"
lem_keys "$session" F7
sleep 0.6
before=$(state_count)
if report_after "$before" 'name=literal\.el mode=FUNDAMENTAL-MODE literal=yes chars=67 modified=no .*encoding=LATIN-1 eol=LF .*threshold=64$' &&
   test "$(tail -c 1 "$WORKDIR/literal.el" | od -An -tu1 | tr -d ' ')" = 254; then
  pass literal-revert 'external revert retained literal decoding and the new byte'
else
  fail literal-revert 'external revert decoded normally or changed literal state'
fi

lem_keys "$session" F6
if wait_report '^TEMPORARY opened=yes chars=65 literal=no$' 10; then
  pass temporary-policy 'temporary implementation reads bypassed interactive prompting'
else
  fail temporary-policy 'a temporary read blocked or inherited literal state'
fi

if ((failed)); then
  exit 1
fi

printf '\n%s\n' 'LARGE FILE TEST PASSED'
