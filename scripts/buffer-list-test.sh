#!/usr/bin/env bash
# Real-ncurses coverage for the configured Ibuffer saved filter groups.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-buffer-list-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-buffer-list.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_BUFFER_LIST_REPORT="$root/report"
export LEM_YATH_BUFFER_LIST_TARGET="$root/buffer-list-zz-target.txt"
export LEM_YATH_BUFFER_LIST_SAVE_TARGET="$root/buffer-list-save-target.txt"
export LEM_TUI_WIDTH=180
export LEM_TUI_HEIGHT=36
mkdir -p "$HOME" "$XDG_CACHE_HOME"

source_file="$root/buffer-list-source.txt"
printf 'BUFFER LIST SOURCE\n' >"$source_file"
printf 'BUFFER LIST SELECTED TARGET\n' >"$LEM_YATH_BUFFER_LIST_TARGET"
printf 'SAVE ORIGINAL\n' >"$LEM_YATH_BUFFER_LIST_SAVE_TARGET"
: >"$LEM_YATH_BUFFER_LIST_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-buffer-list-$id"
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
  tail -20 "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

report_count() {
  grep -c '^STATE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true
}

report_state() {
  local before attempts=0
  before=$(report_count)
  lem_keys "$session" F5
  while ((attempts < 40)); do
    if (( $(report_count) > before )); then return 0; fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

latest_state() {
  grep '^STATE ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
}

fixture="$(lem-yath_lisp_string "$here/scripts/buffer-list-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'BUFFER LIST SOURCE' 60 >/dev/null &&
   grep -q '^READY$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
  pass boot "configured Lem loaded the grouped-buffer fixture"
else
  fail boot "the fixture did not become ready"
fi

expected_classify='classify=org,tramp,emacs,ediff,dired,terminal,help,org,Default'
expected_order='order=org,tramp,emacs,ediff,dired,terminal,help,Default'
if report_state &&
   [[ $(latest_state) == *"$expected_classify"* ]] &&
   [[ $(latest_state) == *"$expected_order"* ]]; then
  pass group-semantics "all seven groups use configured first-match order"
else
  fail group-semantics "classification or group order diverged"
fi

if [[ $(latest_state) == *'subset=org,Default'* ]] &&
   [[ $(latest_state) == *'binding=LEM-YATH-LIST-BUFFERS definitions=7'* ]]; then
  pass hidden-empty-binding "empty groups are omitted and C-x C-b owns the grouped command"
else
  fail hidden-empty-binding "empty-group or binding behavior diverged"
fi

lem_keys "$session" C-x C-b
if lem_wait_for "$session" 'Buffer[[:space:]]+File' 15 >/dev/null; then
  screen=$(lem_capture "$session")
  missing=0
  for group in org tramp emacs ediff dired terminal help Default; do
    if ! grep -Fq "[ ${group} ]" <<<"$screen"; then
      missing=1
    fi
  done
  if ((missing == 0)) &&
     grep -q 'buffer-list-zz-target\.txt' <<<"$screen" &&
     grep -Fq 'buffer-list-control\nname' <<<"$screen" &&
     grep -q '\*Org Src directory-first-match\*' <<<"$screen"; then
    pass grouped-ui "the chooser displays distinct Ibuffer headings and escaped rows"
  else
    fail grouped-ui "the grouped chooser omitted headings or fixture rows"
  fi
else
  fail grouped-ui "C-x C-b did not open the grouped multi-column chooser"
fi

# Heading rows are presentation/control rows, never buffer-operation targets.
lem_keys "$session" C-k
lem_keys "$session" C-s
lem_keys "$session" Space
sleep 0.3
screen=$(lem_capture "$session")
if grep -Fq '[ org ]' <<<"$screen" &&
   grep -q '\*Org Src buffer-list\*' <<<"$screen" &&
   ! grep -Eq 'x[[:space:]]+\[ org \]' <<<"$screen"; then
  pass heading-safety "kill, save, and mark cannot target a group heading"
else
  fail heading-safety "a buffer action mutated or marked a group heading"
fi
lem_keys "$session" BTab

# The first row is the first nonempty group heading.  Return follows Ibuffer:
# hide its rows, retain an ellipsis heading, and expand it again in place.
lem_keys "$session" Enter
sleep 0.4
screen=$(lem_capture "$session")
if grep -Fq '[ org ... ]' <<<"$screen" &&
   ! grep -q '\*Org Src buffer-list\*' <<<"$screen" &&
   grep -Fq '[ tramp ]' <<<"$screen"; then
  pass grouped-collapse "Return collapsed only the focused Ibuffer group"
else
  fail grouped-collapse "the focused heading did not collapse safely"
fi

lem_keys "$session" Enter
sleep 0.4
screen=$(lem_capture "$session")
if grep -Fq '[ org ]' <<<"$screen" &&
   grep -q '\*Org Src buffer-list\*' <<<"$screen" &&
   ! grep -Fq '[ org ... ]' <<<"$screen"; then
  pass grouped-expand "Return restored the collapsed group in place"
else
  fail grouped-expand "the focused heading did not expand safely"
fi

tmux_cmd send-keys -t "$session" -l 'zz-target'
sleep 0.6
screen=$(lem_capture "$session")
if grep -q 'buffer-list-zz-target\.txt' <<<"$screen" &&
   [[ $(grep -c 'buffer-list-source\.txt' <<<"$screen") -eq 1 ]] &&
   ! grep -Eq '\[ (org|Default) (\.\.\. )?\]' <<<"$screen"; then
  pass grouped-filter "live filtering presents matching buffers without heading traps"
else
  fail grouped-filter "filtering retained headings or unrelated rows"
fi

lem_keys "$session" Enter
if lem_wait_for "$session" 'BUFFER LIST SELECTED TARGET' 15 >/dev/null; then
  before=$(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F6
  attempts=0
  while ((attempts < 40)) &&
        (( $(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) <= before )); do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if grep -q '^CURRENT name=buffer-list-zz-target\.txt file=buffer-list-zz-target\.txt group=Default text=BUFFER LIST SELECTED TARGET\\n$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
    pass grouped-select "Return opens the exact focused buffer"
  else
    fail grouped-select "the selected buffer identity was not preserved"
  fi
else
  fail grouped-select "Return did not open the filtered target"
fi

lem_keys "$session" F10
if report_state &&
   [[ $(latest_state) == *"$expected_classify"* ]] &&
   [[ $(latest_state) == *"$expected_order"* ]] &&
   [[ $(latest_state) == *'binding=LEM-YATH-LIST-BUFFERS definitions=7'* ]]; then
  pass reload "source reload preserves definitions, grouping, and binding"
else
  fail reload "reload changed the effective grouped-buffer contract"
fi

lem_keys "$session" C-x C-b
tmux_cmd send-keys -t "$session" -l 'save-target'
if lem_wait_for "$session" 'buffer-list-save-target\.txt' 15 >/dev/null; then
  lem_keys "$session" Space
  lem_keys "$session" C-s
  sleep 0.5
  if cmp -s "$LEM_YATH_BUFFER_LIST_SAVE_TARGET" <(printf 'SAVE ORIGINAL\nSAVE LOCAL\n'); then
    pass marked-save "Space plus C-s saved the marked grouped entry"
  else
    fail marked-save "the marked file buffer was not saved exactly"
    od -An -tx1 "$LEM_YATH_BUFFER_LIST_SAVE_TARGET" 2>/dev/null || true
  fi
else
  fail marked-save "the save fixture did not survive grouped filtering"
fi
lem_keys "$session" Enter
lem_wait_for "$session" 'SAVE LOCAL' 15 >/dev/null ||
  fail marked-save-select "Return did not close the chooser on the saved buffer"

lem_keys "$session" C-x C-b
tmux_cmd send-keys -t "$session" -l 'kill-target'
if lem_wait_for "$session" 'buffer-list-kill-target-a' 15 >/dev/null &&
   lem_wait_for "$session" 'buffer-list-kill-target-b' 15 >/dev/null; then
  lem_keys "$session" Space
  lem_keys "$session" Space
  lem_keys "$session" C-k
  sleep 0.5
  before=$(grep -c '^LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F7
  attempts=0
  while ((attempts < 40)) &&
        (( $(grep -c '^LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) <= before )); do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if grep -q '^LIFECYCLE save-modified=no kill-a=dead kill-b=dead$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
    pass marked-kill "Space plus C-k removed both marked entries and the stale filter snapshot"
  else
    fail marked-kill "marked entry deletion did not cleanly update the chooser snapshot"
  fi
else
  fail marked-kill "the kill fixtures did not survive grouped filtering"
fi

if ((failed)); then
  printf '\nBUFFER LIST TEST FAILED\n'
  exit 1
fi

printf '\nBUFFER LIST TEST PASSED\n'
