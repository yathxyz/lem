#!/usr/bin/env bash
# Real-ncurses coverage for the configured global-so-long-mode policy.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-so-long-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-so-long.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_SO_LONG_REPORT="$root/report"
export LEM_YATH_SOURCE="${LEM_YATH_SOURCE:-$here/lem-yath}"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
: >"$LEM_YATH_SO_LONG_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-so-long-$id"
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
  sed -n '1,240p' "$LEM_YATH_SO_LONG_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

make_ascii_file() {
  local count=$1 path=$2
  printf '%*s' "$count" '' | tr ' ' x >"$path"
  printf '\n' >>"$path"
}

make_utf8_file() {
  local count=$1 path=$2 index
  : >"$path"
  for ((index = 0; index < count; index++)); do
    printf 'é' >>"$path"
  done
  printf '\n' >>"$path"
}

make_ascii_file 10000 "$WORKDIR/threshold.el"
make_ascii_file 10001 "$WORKDIR/excessive.el"
make_ascii_file 10001 "$WORKDIR/plain.txt"
make_ascii_file 10001 "$WORKDIR/document.org"
make_ascii_file 10001 "$WORKDIR/unknown.payload"
make_ascii_file 10001 "$WORKDIR/disabled.el"
make_ascii_file 10001 "$WORKDIR/save-safe.el"
make_utf8_file 5001 "$WORKDIR/multibyte.el"

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_SO_LONG_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

state_count() {
  grep -c '^STATE ' "$LEM_YATH_SO_LONG_REPORT" 2>/dev/null || true
}

report_after() {
  local before=$1 pattern=$2 index=0
  lem_keys "$session" F2
  while ((index < 60)); do
    if (( $(state_count) > before )) &&
       tail -n 1 "$LEM_YATH_SO_LONG_REPORT" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

open_file() {
  local path=$1 name=${1##*/}
  lem_keys "$session" Escape Escape M-x
  sleep 0.2
  tmux_cmd send-keys -t "$session" -l 'find-file'
  lem_keys "$session" Enter
  sleep 0.2
  tmux_cmd send-keys -t "$session" -l "$path"
  lem_keys "$session" Enter
  lem_wait_for "$session" "$name" 20 >/dev/null
}

run_mx() {
  lem_keys "$session" Escape Escape M-x
  sleep 0.2
  tmux_cmd send-keys -t "$session" -l "$1"
  lem_keys "$session" Enter
  sleep 0.4
}

fixture="$(lem-yath_lisp_string "$here/scripts/so-long-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)"

if lem_wait_for "$session" 'SO LONG ORIGIN' 60 >/dev/null &&
   lem_wait_for "$session" 'NORMAL' 10 >/dev/null &&
   wait_report '^READY$' 60; then
  pass boot 'configured Lem loaded the test origin in Normal state'
else
  fail boot 'So Long fixture did not become ready'
fi

lem_keys "$session" F3
if wait_report '^HOOKS find-guard=1 find-core=0 save-guard=1 save-core=0$' 10; then
  pass reload 'reinstalling mode-selection and save guards remained idempotent'
else
  fail reload 'guard replacement was absent, duplicated, or left core hooks active'
fi

open_file "$WORKDIR/threshold.el"
before=$(state_count)
if report_after "$before" 'mode=ELISP-MODE .*readonly=no wrap=no modified=no active=no .*chars=10001 .*paredit=yes global=yes$'; then
  pass exact-threshold 'a 10,000-byte line retained the selected Lisp mode'
else
  fail exact-threshold 'the strict greater-than threshold differed'
fi

lem_keys "$session" F4
open_file "$WORKDIR/excessive.el"
before=$(state_count)
if report_after "$before" 'mode=LEM-YATH-SO-LONG-MODE .*highlight=no readonly=yes wrap=yes modified=no active=yes original=ELISP-MODE chars=10002 tree=no lsp=no gutter=no dap=no lint=no paredit=no global=yes$'; then
  pass excessive-mode 'a 10,001-byte Lisp line bypassed expensive mode features'
else
  fail excessive-mode 'the excessive programming file did not enter the safe mode'
fi

lem_keys "$session" i
tmux_cmd send-keys -t "$session" -l 'Z'
lem_keys "$session" Escape Escape
sleep 0.3
before=$(state_count)
if report_after "$before" 'mode=LEM-YATH-SO-LONG-MODE .*readonly=yes .*modified=no active=yes .*chars=10002 '; then
  pass read-only 'ordinary insertion could not mutate the protected buffer'
else
  fail read-only 'the protected buffer changed or left its safe mode'
fi

lem_keys "$session" C-c C-c
before=$(state_count)
if report_after "$before" 'mode=ELISP-MODE .*highlight=yes readonly=no wrap=no modified=no active=no .*chars=10002 .*paredit=yes global=yes$'; then
  pass revert 'C-c C-c restored the original Lisp mode and presentation'
else
  fail revert 'the advertised revert did not restore the original mode'
fi
lem_keys "$session" F5

open_file "$WORKDIR/unknown.payload"
before=$(state_count)
if report_after "$before" 'mode=LEM-YATH-SO-LONG-MODE .*active=yes original=FUNDAMENTAL-MODE chars=10002 .*global=yes$'; then
  pass fundamental-target 'an unassociated file retained GNU So Long fundamental targeting'
else
  fail fundamental-target 'the fundamental-mode target boundary differed'
fi

open_file "$WORKDIR/plain.txt"
before=$(state_count)
if report_after "$before" 'mode=FUNDAMENTAL-MODE .*readonly=no .*active=no .*chars=10002 .*global=yes$'; then
  pass text-boundary 'a plain-text document was not treated as Emacs Fundamental mode'
else
  fail text-boundary 'the .txt semantic mode boundary differed'
fi

open_file "$WORKDIR/document.org"
before=$(state_count)
if report_after "$before" 'mode=ORG-MODE .*active=no .*chars=10002 .*global=yes$'; then
  pass org-boundary 'Org remained outside the default So Long target modes'
else
  fail org-boundary 'the document-mode boundary incorrectly mitigated Org'
fi

open_file "$WORKDIR/multibyte.el"
before=$(state_count)
if report_after "$before" 'mode=LEM-YATH-SO-LONG-MODE .*active=yes original=ELISP-MODE chars=5002 .*global=yes$'; then
  pass byte-threshold '5,001 two-byte UTF-8 characters exceeded the byte threshold'
else
  fail byte-threshold 'line length was not measured with GNU So Long byte semantics'
fi

run_mx global-so-long-mode
open_file "$WORKDIR/disabled.el"
before=$(state_count)
if report_after "$before" 'mode=ELISP-MODE .*active=no .*chars=10002 .*global=no$'; then
  pass global-toggle 'disabling the global mode affected subsequently visited files'
else
  fail global-toggle 'the global toggle did not delegate ordinary mode selection'
fi
lem_keys "$session" F6
if wait_report '^RELOAD global=no find-guard=1 find-core=0 save-guard=1 save-core=0$' 15; then
  pass source-reload 'source reload preserved the user toggle and single hook ownership'
else
  fail source-reload 'source reload reset the toggle or duplicated mode-selection hooks'
fi
run_mx global-so-long-mode

open_file "$WORKDIR/save-safe.el"
run_mx toggle-read-only
lem_keys "$session" i
tmux_cmd send-keys -t "$session" -l 'Z'
lem_keys "$session" Escape Escape
sleep 0.3
lem_keys "$session" C-x C-s
sleep 0.5
before=$(state_count)
if report_after "$before" 'mode=LEM-YATH-SO-LONG-MODE .*modified=no active=yes original=ELISP-MODE chars=10003 .*global=yes$' &&
   test "$(wc -c <"$WORKDIR/save-safe.el")" -eq 10003; then
  pass save-boundary 'a forced save retained the safe mode and wrote only the user edit'
else
  fail save-boundary 'before-save mode refresh escaped mitigation or altered the file'
fi

if ((failed)); then
  exit 1
fi

printf '\n%s\n' 'SO LONG TEST PASSED'
