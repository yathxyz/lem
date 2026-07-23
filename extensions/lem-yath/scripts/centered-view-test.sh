#!/usr/bin/env bash
# Real-ncurses coverage for the configured buffer-local centered document view.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-centered-view-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-centered-view.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_CENTERED_VIEW_REPORT="$root/report"
export LEM_TUI_WIDTH=160
export LEM_TUI_HEIGHT=30
mkdir -p "$HOME" "$XDG_CACHE_HOME"

document="$root/centered.txt"
{
  printf '%s\n' 'CENTER-BEGIN'
  printf 'WRAP-BEGIN-'
  head -c 115 /dev/zero | tr '\0' x
  printf '%s\n' '-WRAP-TAIL'
  printf '%s\n' 'CENTER-END'
} >"$document"
: >"$LEM_YATH_CENTERED_VIEW_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-centered-view-$id"
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
    if grep -qE "$pattern" "$LEM_YATH_CENTERED_VIEW_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_new_center() {
  local previous=$1 timeout=${2:-15} index=0 count
  while ((index < timeout * 4)); do
    count=$(grep -c '^CENTER ' "$LEM_YATH_CENTERED_VIEW_REPORT" 2>/dev/null || true)
    if ((count > previous)); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

latest_center() {
  grep '^CENTER ' "$LEM_YATH_CENTERED_VIEW_REPORT" | tail -1
}

leading_column() {
  local marker=$1
  lem_capture "$session" |
    awk -v marker="$marker" 'index($0, marker) { match($0, /[^ ]/); print RSTART - 1; exit }'
}

wait_column() {
  local marker=$1 expected=$2 index=0 actual
  while ((index < 40)); do
    actual=$(leading_column "$marker")
    if [[ $actual == "$expected" ]]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

geometry_valid() {
  local line=$1 expected_windows=$2 geometry entry width left right body count=0
  geometry=${line##* geometry=}
  IFS=',' read -r -a entries <<<"$geometry"
  [[ ${#entries[@]} -eq $expected_windows ]] || return 1
  for entry in "${entries[@]}"; do
    IFS=':' read -r width left right body <<<"$entry"
    [[ -n $body ]] || return 1
    ((left == right)) || return 1
    ((body == width - left - right)) || return 1
    if ((width > 100)); then
      ((left == (width - 100) / 2)) || return 1
    else
      ((left == 0)) || return 1
    fi
    count=$((count + 1))
  done
  ((count == expected_windows))
}

fixture="$(lem-yath_lisp_string "$here/scripts/centered-view-fixture.lisp")"
lem_start "$session" "$document" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  pass boot "configured Lem loaded the centered-view fixture"
else
  fail boot "fixture did not become ready"
fi

lem_keys "$session" F5
if wait_report '^CENTER label=state active=no wrap=no target=100 windows=1 geometry=160:0:0:160$' &&
   wait_column CENTER-BEGIN 0; then
  pass disabled-baseline "ordinary text starts at column zero without wrapping"
else
  fail disabled-baseline "centered state leaked into a fresh text buffer"
fi

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" Space y c
sleep 0.5
lem_keys "$session" F5
if wait_report '^CENTER label=state active=yes wrap=yes target=100 windows=1 geometry=160:30:30:100$' &&
   wait_column CENTER-BEGIN 30 &&
   wait_column WRAP-TAIL 30; then
  pass leader-toggle "SPC y c centered text and wrapped continuation rows at width 100"
else
  fail leader-toggle "the real leader chord did not produce balanced rendered margins"
fi

tmux_cmd resize-window -t "$session" -x 120 -y 30
if wait_column CENTER-BEGIN 10; then
  lem_keys "$session" F5
  if wait_report '^CENTER label=state active=yes wrap=yes target=100 windows=1 geometry=120:10:10:100$'; then
    pass resize "SIGWINCH recomputed balanced margins without retoggling"
  else
    fail resize "rendered resize and recorded body geometry diverged"
  fi
else
  fail resize "the centered column did not follow the resized window"
fi

before=$(grep -c '^CENTER ' "$LEM_YATH_CENTERED_VIEW_REPORT" || true)
lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" Space y v
sleep 0.4
lem_keys "$session" F5
if wait_new_center "$before" &&
   [[ $(latest_center) == *'active=yes wrap=no target=100 windows=1 geometry=120:10:10:100' ]]; then
  lem_keys "$session" j '$'
  if wait_column WRAP-TAIL 10; then
    lem_keys "$session" 0
    sleep 0.4
    if ! lem_capture "$session" | grep -q 'WRAP-TAIL'; then
      pass horizontal-scroll "centered margins bound clipping and cursor-driven scrolling"
    else
      fail horizontal-scroll "returning to column zero retained stale horizontal content"
    fi
  else
    fail horizontal-scroll "line-end motion did not reveal the clipped tail inside the body"
  fi
else
  fail horizontal-scroll "SPC y v could not disable wrapping inside centered view"
fi

lem_keys "$session" Escape
sleep 0.2
lem_keys "$session" Space y v
if wait_column WRAP-TAIL 10; then
  pass wrap-restore "the visual-line chord restored centered continuation rows"
else
  fail wrap-restore "reenabling wrapping did not restore centered continuation rows"
fi

lem_keys "$session" F6
if wait_report '^CENTER label=width-80 active=yes wrap=yes target=80 windows=1 geometry=120:20:20:80$' &&
   wait_column CENTER-BEGIN 20; then
  pass configurable-width "changing the configured target immediately changed layout"
else
  fail configurable-width "the target width was not live or balanced"
fi

lem_keys "$session" F8
if wait_report '^CENTER label=reload active=yes wrap=yes target=80 windows=1 geometry=120:20:20:80$'; then
  pass reload "source reload preserved the active mode and configured width"
else
  fail reload "reload reset state or duplicated an incompatible mode class"
fi

lem_keys "$session" F7
wait_report '^CENTER label=width-100 active=yes wrap=yes target=100 windows=1 geometry=120:10:10:100$' ||
  fail width-restore "the fixture could not restore the production target"

if wait_report '^CENTER label=split active=yes wrap=yes target=100 windows=2 geometry=120:10:10:100,120:10:10:100$'; then
  split_line=$(latest_center)
  if geometry_valid "$split_line" 2; then
    pass split-windows "each split derived its own balanced content geometry"
  else
    fail split-windows "split body arithmetic did not match its recorded margins"
  fi
else
  fail split-windows "two independent windows did not retain centered geometry"
fi

lem_keys "$session" F5
wait_report '^CENTER label=unsplit active=yes wrap=yes target=100 windows=1 geometry=120:10:10:100$' ||
  fail split-restore "the fixture could not restore the single centered window"

tmux_cmd resize-window -t "$session" -x 90 -y 30
if wait_column CENTER-BEGIN 0; then
  lem_keys "$session" F5
  if wait_report '^CENTER label=state active=yes wrap=yes target=100 windows=1 geometry=90:0:0:90$'; then
    pass narrow-window "windows narrower than the target retain their full body"
  else
    fail narrow-window "narrow body geometry was not clamped at zero margins"
  fi
else
  fail narrow-window "narrow text retained stale padding"
fi

lem_keys "$session" Space y c
sleep 0.5
lem_keys "$session" F5
if wait_report '^CENTER label=state active=no wrap=yes target=100 windows=1 geometry=90:0:0:90$' &&
   wait_column CENTER-BEGIN 0; then
  pass disable-restore "toggle-off removed only margins and retained Emacs-style wrapping"
else
  fail disable-restore "toggle-off left stale geometry or reverted wrapping"
fi

if ((failed)); then
  printf '\n'
  cat "$LEM_YATH_CENTERED_VIEW_REPORT"
  printf 'CENTERED VIEW TEST FAILED\n'
  exit 1
fi

printf '\n'
cat "$LEM_YATH_CENTERED_VIEW_REPORT"
printf 'CENTERED VIEW TEST PASSED\n'
