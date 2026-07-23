#!/usr/bin/env bash
# Real-ncurses coverage for Winner-style frame-local window-layout history.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-window-history-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-window-history.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_WINDOW_HISTORY_REPORT="$root/report"
export LEM_TUI_WIDTH=120
export LEM_TUI_HEIGHT=30
mkdir -p "$HOME" "$XDG_CACHE_HOME"

source_file="$root/WINNER-A.txt"
for line in $(seq 1 24); do
  printf 'A line %02d\n' "$line"
done >"$source_file"
: >"$LEM_YATH_WINDOW_HISTORY_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-window-history-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-28s %s\n' "$1" "$2"
  tail -20 "$LEM_YATH_WINDOW_HISTORY_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

state_count() {
  grep -c '^STATE ' "$LEM_YATH_WINDOW_HISTORY_REPORT" 2>/dev/null || true
}

wait_state() {
  local previous=$1 timeout=${2:-15} index=0 count
  while ((index < timeout * 4)); do
    count=$(state_count)
    if ((count > previous)); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

report_state() {
  local previous
  previous=$(state_count)
  lem_keys "$session" F5
  wait_state "$previous"
}

latest_state() {
  grep '^STATE ' "$LEM_YATH_WINDOW_HISTORY_REPORT" | tail -1
}

fixture="$(lem-yath_lisp_string "$here/scripts/window-history-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   lem_wait_for "$session" 'A line 01' 60 >/dev/null &&
   grep -q '^READY$' "$LEM_YATH_WINDOW_HISTORY_REPORT"; then
  pass boot "configured Lem loaded the window-history fixture"
else
  fail boot "fixture did not become ready"
fi

if report_state &&
   [[ $(latest_state) == *'tree=WINNER-A.txt selected=WINNER-A.txt windows=1'* ]] &&
   [[ $(latest_state) == *'hook=1 left=LEM-YATH-WINDOW-LAYOUT-UNDO right=LEM-YATH-WINDOW-LAYOUT-REDO'* ]]; then
  pass startup-contract "one hook and the pinned Winner bindings are active"
else
  fail startup-contract "startup layout or bindings diverged"
fi

lem_keys "$session" C-x 3
lem_keys "$session" C-x o
lem_keys "$session" F6
lem_keys "$session" C-x 2
lem_keys "$session" C-x o
lem_keys "$session" F7
if report_state &&
   [[ $(latest_state) == *'tree=H(WINNER-A.txt,V(WINNER-B,WINNER-C)) selected=WINNER-C windows=3'* ]]; then
  pass nested-layout "horizontal and vertical splits retained distinct buffers"
else
  fail nested-layout "nested split topology or buffer identity was lost"
fi

lem_keys "$session" C-x 1
if report_state &&
   [[ $(latest_state) == *'tree=WINNER-C selected=WINNER-C windows=1'* ]]; then
  pass collapse "C-x 1 produced the expected one-window layout"
else
  fail collapse "the collapse baseline is not deterministic"
fi

lem_keys "$session" C-c Left
if report_state &&
   [[ $(latest_state) == *'tree=H(WINNER-A.txt,V(WINNER-B,WINNER-C)) selected=WINNER-C windows=3'* ]] &&
   [[ $(latest_state) == *'redo=1'* ]]; then
  pass undo-layout "C-c Left restored topology, buffers, selection, and a redo route"
else
  fail undo-layout "Winner undo did not restore the previous configuration"
fi

lem_keys "$session" C-c Left
if report_state &&
   [[ $(latest_state) == *'tree=H(WINNER-A.txt,V(WINNER-B,WINNER-B)) selected=WINNER-B windows=3'* ]] &&
   [[ $(latest_state) == *'redo=2'* ]]; then
  pass repeated-undo "successive undo crossed a buffer-switch configuration"
else
  fail repeated-undo "the second layout undo did not traverse history"
fi

lem_keys "$session" C-c Right
if report_state &&
   [[ $(latest_state) == *'tree=H(WINNER-A.txt,V(WINNER-B,WINNER-C)) selected=WINNER-C windows=3'* ]]; then
  pass redo-layout "C-c Right restored the newer three-window configuration"
else
  fail redo-layout "layout redo lost topology or buffer identity"
fi

lem_keys "$session" C-c Right
if report_state &&
   [[ $(latest_state) == *'tree=WINNER-C selected=WINNER-C windows=1'* ]] &&
   [[ $(latest_state) == *'redo=0'* ]]; then
  pass repeated-redo "successive redo returned to the collapsed tip"
else
  fail repeated-redo "the redo route did not reach its original tip"
fi

lem_keys "$session" F8
lem_keys "$session" C-c Left
if report_state &&
   [[ $(latest_state) == *'tree=H(WINNER-A.txt,V(WINNER-B,WINNER-C)) selected=WINNER-C windows=3'* ]] &&
   [[ $(latest_state) == *'WINNER-C:241:171'* ]]; then
  pass live-point "restoration kept the live point and marker-tracked view start"
else
  fail live-point "Winner restoration rewound point or lost its recorded view"
fi

lem_keys "$session" C-c Right
lem_keys "$session" C-u 30 C-x 3
pre_resize_ok=0
if report_state &&
   [[ $(latest_state) == *'geometry=WINNER-C:0:0:30:30,WINNER-C:31:0:89:30'* ]]; then
  pre_resize_ok=1
fi
lem_keys "$session" C-x 1
report_state >/dev/null || true
tmux_cmd resize-window -t "$session" -x 160 -y 30
sleep 0.5
lem_keys "$session" C-c Left
if ((pre_resize_ok)) && report_state &&
   [[ $(latest_state) == *'tree=H(WINNER-C,WINNER-C) selected=WINNER-C windows=2'* ]] &&
   [[ $(latest_state) == *'geometry=WINNER-C:0:0:40:30,WINNER-C:41:0:119:30'* ]]; then
  pass proportional-resize "saved split proportion adapted to the resized terminal"
else
  fail proportional-resize "restoration reused stale absolute geometry"
fi

lem_keys "$session" C-x 1
lem_keys "$session" C-x 3
lem_keys "$session" C-x 3
lem_keys "$session" C-c Left
if report_state &&
   [[ $(latest_state) == *'tree=WINNER-C selected=WINNER-C windows=1'* ]]; then
  pass repeated-command "consecutive identical splits coalesced into one Winner step"
else
  fail repeated-command "repeated split commands created separate undo steps"
fi

lem_keys "$session" F10
if report_state &&
   [[ $(latest_state) == *'hook=1 left=LEM-YATH-WINDOW-LAYOUT-UNDO right=LEM-YATH-WINDOW-LAYOUT-REDO'* ]]; then
  pass reload "source reload preserved exactly one hook and both bindings"
else
  fail reload "window-history reload duplicated or lost configuration"
fi

lem_keys "$session" F9
lem_keys "$session" F6
lem_keys "$session" F7
lem_keys "$session" F6
lem_keys "$session" F7
if report_state && [[ $(latest_state) == *'undo=3 redo=0'* ]]; then
  pass bounded-history "the configured history limit pruned older layouts exactly"
else
  fail bounded-history "the frame history exceeded or underfilled its bound"
fi

lem_keys "$session" C-x t 2
if report_state &&
   [[ $(latest_state) == *'windows=1'* ]] &&
   [[ $(latest_state) == *'undo=0 redo=0'* ]]; then
  lem_keys "$session" C-x 3
  lem_keys "$session" C-c Left
  if report_state && [[ $(latest_state) == *'windows=1'* ]]; then
    lem_keys "$session" C-x t p
    if report_state &&
       [[ $(latest_state) == *'tree=WINNER-C selected=WINNER-C windows=1'* ]] &&
       [[ $(latest_state) == *'undo=3 redo=0'* ]]; then
      pass frame-local "tab frames retained independent layout histories"
    else
      fail frame-local "returning to the original tab lost its history"
    fi
  else
    fail frame-local "the new tab could not undo its own split"
  fi
else
  fail frame-local "the new tab inherited another frame's history"
fi

if ((failed)); then
  printf '\nWINDOW HISTORY TEST FAILED\n'
  exit 1
fi

printf '\nWINDOW HISTORY TEST PASSED\n'
