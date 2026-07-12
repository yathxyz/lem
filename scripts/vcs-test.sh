#!/usr/bin/env bash
# Real-TUI VCS acceptance: jj/Git dispatch, scoped gutters, and time travel.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-vcs-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-vcs.XXXXXX")"
case "$root" in
  "" | /)
    echo "Refusing unsafe VCS test directory: $root" >&2
    exit 1
    ;;
esac

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_HOME="$root/lem-home/"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_PAGER=cat
export JJ_CONFIG="$root/jj-config.toml"
export JJ_PAGER=cat
export NO_COLOR=1
export LEM_YATH_VCS_REPORT="$root/report"
export LEM_YATH_VCS_COLOCATED_ROOT="$root/repos/colocated repo;safe/"
export LEM_YATH_VCS_GIT_MAIN="$root/repos/git main;safe/"
export LEM_YATH_VCS_GIT_ROOT="$root/repos/git worktree;safe/"
export LEM_YATH_VCS_CODE_FILE="${LEM_YATH_VCS_GIT_ROOT}nested/deeper/history.lisp"
export LEM_YATH_VCS_MARKDOWN_FILE="${LEM_YATH_VCS_GIT_ROOT}nested/docs/notes.md"
export LEM_YATH_VCS_UNTRACKED_FILE="${LEM_YATH_VCS_GIT_ROOT}nested/deeper/retired.lisp"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" "$LEM_HOME" \
  "$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper" \
  "$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper/raw directory;sentinel" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/deeper" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/deeper/raw directory;sentinel" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/docs"
: >"$LEM_YATH_VCS_REPORT"
printf '%s\n' \
  'user.name = "Lem Yath Test"' \
  'user.email = "lem-yath-test@example.invalid"' \
  >"$JJ_CONFIG"

git_bin="$(command -v git 2>/dev/null || true)"
jj_bin="$(command -v jj 2>/dev/null || true)"
if [ -z "$git_bin" ] || [ ! -x "$git_bin" ]; then
  echo "VCS test requires git on the test runner PATH" >&2
  rm -rf -- "$root"
  exit 1
fi
if [ -z "$jj_bin" ] || [ ! -x "$jj_bin" ]; then
  echo "VCS test requires jj on the test runner PATH" >&2
  rm -rf -- "$root"
  exit 1
fi

git_init() {
  "$git_bin" -C "$1" init -q -b main &&
    "$git_bin" -C "$1" config user.name 'Lem Yath Test' &&
    "$git_bin" -C "$1" config user.email 'lem-yath-test@example.invalid'
}

git_commit() {
  local directory=$1 message=$2 timestamp=$3
  GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_DATE="$timestamp" \
    "$git_bin" -C "$directory" commit -qm "$message"
}

if ! git_init "$LEM_YATH_VCS_COLOCATED_ROOT"; then
  echo "Could not initialize the colocated Git fixture" >&2
  rm -rf -- "$root"
  exit 1
fi
printf '(defparameter vcs-colocated t)\n' \
  >"$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper/colocated.lisp"
"$git_bin" -C "$LEM_YATH_VCS_COLOCATED_ROOT" add -- \
  nested/deeper/colocated.lisp
if ! git_commit "$LEM_YATH_VCS_COLOCATED_ROOT" vcs-colocated \
  '2001-01-01T00:00:00+0000'; then
  echo "Could not commit the colocated fixture" >&2
  rm -rf -- "$root"
  exit 1
fi
if ! "$jj_bin" git init --colocate "$LEM_YATH_VCS_COLOCATED_ROOT" >/dev/null; then
  echo "Could not initialize the colocated jj fixture" >&2
  rm -rf -- "$root"
  exit 1
fi

if ! git_init "$LEM_YATH_VCS_GIT_MAIN"; then
  echo "Could not initialize the Git worktree's main repository" >&2
  rm -rf -- "$root"
  exit 1
fi
printf '%s\n' \
  '(defparameter vcs-history :old)' \
  '(defparameter vcs-change :old)' \
  '(defparameter vcs-old-extra :shifts-anchor)' \
  '(defparameter vcs-three 3)' \
  '(defparameter vcs-four 4)' \
  '(defparameter vcs-five 5)' \
  '(defparameter vcs-gone t)' \
  '(defparameter vcs-seven 7)' \
  '(defparameter vcs-eight 8)' \
  '(defparameter vcs-nine 9)' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/deeper/history-old.lisp"
printf '(defparameter vcs-retired :historical)\n' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/deeper/retired.lisp"
printf '# VCS notes\n\nold prose\n' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/docs/notes.md"
"$git_bin" -C "$LEM_YATH_VCS_GIT_MAIN" add -- \
  nested/deeper/history-old.lisp nested/deeper/retired.lisp \
  nested/docs/notes.md
if ! git_commit "$LEM_YATH_VCS_GIT_MAIN" vcs-old \
  '2001-01-02T00:00:00+0000'; then
  echo "Could not create the older history fixture" >&2
  rm -rf -- "$root"
  exit 1
fi
export LEM_YATH_VCS_OLD_HASH
LEM_YATH_VCS_OLD_HASH="$($git_bin -C "$LEM_YATH_VCS_GIT_MAIN" rev-parse HEAD)"

"$git_bin" -C "$LEM_YATH_VCS_GIT_MAIN" mv -- \
  nested/deeper/history-old.lisp nested/deeper/history.lisp
printf '%s\n' \
  '(defparameter vcs-history :new)' \
  '(defparameter vcs-change :old)' \
  '(defparameter vcs-three 3)' \
  '(defparameter vcs-four 4)' \
  '(defparameter vcs-five 5)' \
  '(defparameter vcs-gone t)' \
  '(defparameter vcs-seven 7)' \
  '(defparameter vcs-eight 8)' \
  '(defparameter vcs-nine 9)' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/deeper/history.lisp"
"$git_bin" -C "$LEM_YATH_VCS_GIT_MAIN" add -- \
  nested/deeper/history.lisp
"$git_bin" -C "$LEM_YATH_VCS_GIT_MAIN" rm -q -- \
  nested/deeper/retired.lisp
if ! git_commit "$LEM_YATH_VCS_GIT_MAIN" vcs-new \
  '2001-01-03T00:00:00+0000'; then
  echo "Could not create the newer history fixture" >&2
  rm -rf -- "$root"
  exit 1
fi
if ! "$git_bin" -C "$LEM_YATH_VCS_GIT_MAIN" worktree add -q \
  -b vcs-runtime-test "$LEM_YATH_VCS_GIT_ROOT" HEAD; then
  echo "Could not create the linked-worktree fixture" >&2
  rm -rf -- "$root"
  exit 1
fi
mkdir -p "$LEM_YATH_VCS_GIT_ROOT/nested/deeper/raw directory;sentinel"

# Three separated worktree hunks produce real modified, deleted, and added
# gutter records while leaving the two committed history revisions intact.
printf '%s\n' \
  '(defparameter vcs-history :new)' \
  '(defparameter vcs-change :new)' \
  '(defparameter vcs-three 3)' \
  '(defparameter vcs-four 4)' \
  '(defparameter vcs-five 5)' \
  '(defparameter vcs-seven 7)' \
  '(defparameter vcs-eight 8)' \
  '(defparameter vcs-nine 9)' \
  '(defparameter vcs-added t)' \
  >"$LEM_YATH_VCS_CODE_FILE"
printf '# VCS notes\n\nchanged prose\n' >"$LEM_YATH_VCS_MARKDOWN_FILE"
# Recreate a formerly tracked path without adding it to the index.  It still
# has log history, which distinguishes the required tracked-file gate from a
# merely nonempty-history check.
printf '(defparameter vcs-retired :recreated-untracked)\n' \
  >"$LEM_YATH_VCS_UNTRACKED_FILE"

if [ ! -d "$LEM_YATH_VCS_COLOCATED_ROOT/.git" ] ||
   [ ! -d "$LEM_YATH_VCS_COLOCATED_ROOT/.jj" ] ||
   [ ! -f "$LEM_YATH_VCS_GIT_ROOT/.git" ] ||
   [ -e "$LEM_YATH_VCS_GIT_ROOT/.jj" ]; then
  echo "VCS repository fixture topology is wrong" >&2
  rm -rf -- "$root"
  exit 1
fi
"$git_bin" -C "$LEM_YATH_VCS_GIT_ROOT" diff --quiet -- \
  nested/deeper/history.lisp
code_diff_status=$?
"$git_bin" -C "$LEM_YATH_VCS_GIT_ROOT" diff --quiet -- \
  nested/docs/notes.md
markdown_diff_status=$?
if [ "$code_diff_status" -ne 1 ] || [ "$markdown_diff_status" -ne 1 ]; then
  echo "VCS worktree fixtures are missing changes or git diff failed" >&2
  rm -rf -- "$root"
  exit 1
fi
if "$git_bin" -C "$LEM_YATH_VCS_GIT_ROOT" ls-files --error-unmatch -- \
     nested/deeper/retired.lisp >/dev/null 2>&1 ||
   [ -z "$("$git_bin" -C "$LEM_YATH_VCS_GIT_ROOT" log --format=%H -- \
     nested/deeper/retired.lisp)" ]; then
  echo "Recreated-path fixture is tracked or has no history" >&2
  rm -rf -- "$root"
  exit 1
fi

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"
KEY_DELAY="${KEY_DELAY:-0.25}"
failed=0
sessions=()

cleanup() {
  local session
  for session in "${sessions[@]:-}"; do
    [ -n "$session" ] && lem_stop "$session"
  done
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-31s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-31s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_VCS_REPORT" 2>/dev/null || true
}

latest_report() {
  grep -E "$1" "$LEM_YATH_VCS_REPORT" 2>/dev/null | tail -n 1
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

send_keys() {
  local session=$1 key
  shift
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

press_report() {
  local session=$1 key=$2 pattern=$3 before
  before=$(report_count "$pattern")
  lem_keys "$session" "$key"
  wait_report_count "$pattern" "$((before + 1))"
}

wait_jj_dispatch() {
  local session=$1 phase=$2 index=0 before latest
  while ((index < WAIT_TIMEOUT * 2)); do
    before=$(report_count "^DISPATCH phase=$phase ")
    lem_keys "$session" F3
    wait_report_count "^DISPATCH phase=$phase " "$((before + 1))" 3 || true
    latest=$(grep "^DISPATCH phase=$phase " "$LEM_YATH_VCS_REPORT" | tail -n 1)
    if [[ "$latest" == DISPATCH\ phase="$phase"\ kind=jj\ * ]] &&
       [[ "$latest" == *'content=yes '* ]] &&
       [[ "$latest" == *'programming=no utility-gutter=none '* ]] &&
       [[ "$latest" == *'raw-exact=yes raw-sentinel=yes '* ]]; then
      return 0
    fi
    sleep 0.5
    index=$((index + 1))
  done
  return 1
}

wait_legit() {
  local session=$1 phase=$2 index=0 before latest
  while ((index < WAIT_TIMEOUT * 2)); do
    before=$(report_count "^LEGIT phase=$phase ")
    lem_keys "$session" F4
    wait_report_count "^LEGIT phase=$phase " "$((before + 1))" 3 || true
    latest=$(grep "^LEGIT phase=$phase " "$LEM_YATH_VCS_REPORT" | tail -n 1)
    if [[ "$latest" == LEGIT\ phase="$phase"\ active=yes\ source-live=yes\ raw-exact=yes\ raw-sentinel=yes\ * ]]; then
      return 0
    fi
    sleep 0.5
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/vcs-fixture.lisp")"

start_phase() {
  local phase=$1 file=$2 session=$3 ready_before original_path tmux_path
  ready_before=$(report_count "^READY phase=$phase ")
  export LEM_YATH_VCS_PHASE="$phase"
  export LEM_YATH_VCS_SENTINEL_DIRECTORY
  LEM_YATH_VCS_SENTINEL_DIRECTORY="$(dirname "$file")/raw directory;sentinel/"
  sessions+=("$session")

  # Launch the installed wrapper with an empty inherited PATH.  Git and jj can
  # therefore be discovered by the fixture only when the wrapper itself ships
  # them.  Keep an absolute tmux path so the harness can still start the pane.
  tmux_path="$(command -v tmux)"
  original_path=$PATH
  TMUX_BIN=$tmux_path
  PATH="$root/empty-path"
  lem_start "$session" "$file" --eval "(load #P$fixture)"
  local start_status=$?
  PATH=$original_path
  if [ "$start_status" -ne 0 ]; then
    return "$start_status"
  fi
  wait_report_count "^READY phase=$phase " "$((ready_before + 1))" "$BOOT_TIMEOUT" &&
    lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null
}

colocated_session="lem-yath-vcs-colocated-$id"
if start_phase colocated \
  "$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper/colocated.lisp" \
  "$colocated_session"; then
  pass colocated-boot 'configured wrapper opened the colocated repository'
else
  fail colocated-boot 'colocated fixture did not become ready' "$colocated_session"
fi

if press_report "$colocated_session" F1 '^SUMMARY STATIC ' &&
   grep -q '^SUMMARY STATIC PASS failures=0$' "$LEM_YATH_VCS_REPORT" &&
   grep -q '^EXECUTABLES git=yes jj=yes git-store=yes jj-store=yes$' \
     "$LEM_YATH_VCS_REPORT"; then
  pass wrapper-bindings 'the installed wrapper supplies pinned git/jj and all VCS keys'
else
  fail wrapper-bindings 'wrapper executables or normal/visual bindings failed' \
    "$colocated_session"
fi

if press_report "$colocated_session" F9 '^ROOTS phase=colocated ' &&
   [[ $(latest_report '^ROOTS phase=colocated ') == \
      'ROOTS phase=colocated jj=yes git=yes history-git=yes expected=yes raw-exact=yes raw-sentinel=yes' ]]; then
  pass colocated-roots 'the real repository is simultaneously a jj and Git root'
else
  fail colocated-roots 'colocated root detection disagreed with the fixture' \
    "$colocated_session"
fi

send_keys "$colocated_session" Space g g
if wait_jj_dispatch "$colocated_session" colocated; then
  pass smart-jj-dispatch 'SPC g g preferred the real jj status/log view'
else
  fail smart-jj-dispatch 'smart dispatch did not produce jj status/log output' \
    "$colocated_session"
fi

printf 'jj refresh probe\n' \
  >"$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper/jj-refresh-probe.txt"
send_keys "$colocated_session" g r
if press_report "$colocated_session" F3 '^DISPATCH phase=colocated ' &&
   [[ $(latest_report '^DISPATCH phase=colocated ') == \
      *'kind=jj jj-view=yes legit=no content=yes exit=no programming=no utility-gutter=none refresh-probe=yes raw-exact=yes raw-sentinel=yes '* ]]; then
  pass jj-refresh-key 'g r refreshed the live jj view with new repository state'
else
  fail jj-refresh-key 'the configured g r key did not refresh jj status' \
    "$colocated_session"
fi

send_keys "$colocated_session" q
if press_report "$colocated_session" F7 '^SOURCE ' &&
   [[ $(latest_report '^SOURCE ') == \
      'SOURCE current=yes live=yes text=yes point=yes mode=yes modified=yes filename=yes timemachine-live=0' ]]; then
  pass jj-quit-key 'q returned from the jj view to its source buffer'
else
  fail jj-quit-key 'q did not return from the jj view to its source' \
    "$colocated_session"
fi

send_keys "$colocated_session" Space g J
if wait_jj_dispatch "$colocated_session" colocated; then
  pass forced-jj-dispatch 'SPC g J forced jj in the colocated repository'
else
  fail forced-jj-dispatch 'the forced jj binding did not open real output' \
    "$colocated_session"
fi

send_keys "$colocated_session" q
if press_report "$colocated_session" F7 '^SOURCE ' &&
   [[ $(latest_report '^SOURCE ') == \
      'SOURCE current=yes live=yes text=yes point=yes mode=yes modified=yes filename=yes timemachine-live=0' ]]; then
  pass forced-jj-quit 'q returned from the forced jj view without fixture recovery'
else
  fail forced-jj-quit 'forced jj required out-of-band source recovery' \
    "$colocated_session"
fi

send_keys "$colocated_session" Space g G
if wait_legit "$colocated_session" colocated; then
  pass forced-git-dispatch 'SPC g G forced Legit despite the colocated jj root'
else
  fail forced-git-dispatch 'the forced Git binding did not open Legit' \
    "$colocated_session"
fi
send_keys "$colocated_session" q F6

if press_report "$colocated_session" F8 '^RELOAD ' 60 &&
   grep -q '^RELOAD same=yes find=1 post=1 save=1 change=1 kill=1 global=0 source=1 directory=0 root-marker=1 smart=yes git=yes jj=yes time=yes jj-refresh=yes jj-quit=yes older=yes newer=yes nth=yes fuzzy=yes p=yes n=yes t=yes quit=yes$' \
     "$LEM_YATH_VCS_REPORT"; then
  pass reload-idempotence 'two VCS reloads preserved one mode, hooks, inserter, and keymaps'
else
  fail reload-idempotence 'VCS reload duplicated or replaced runtime state' \
    "$colocated_session"
fi
lem_stop "$colocated_session"

git_session="lem-yath-vcs-git-$id"
if start_phase git "$LEM_YATH_VCS_CODE_FILE" "$git_session"; then
  pass git-boot 'configured wrapper opened the Git-only repository'
else
  fail git-boot 'Git-only fixture did not become ready' "$git_session"
fi

if press_report "$git_session" F9 '^ROOTS phase=git ' &&
   [[ $(latest_report '^ROOTS phase=git ') == \
      'ROOTS phase=git jj=no git=yes history-git=yes expected=yes raw-exact=yes raw-sentinel=yes' ]]; then
  pass git-only-roots 'the second repository has Git without a jj root'
else
  fail git-only-roots 'Git-only root detection was wrong' "$git_session"
fi

send_keys "$git_session" Space g g
if wait_legit "$git_session" git; then
  pass smart-git-dispatch 'SPC g g selected Legit in a Git-only repository'
else
  fail smart-git-dispatch 'smart dispatch did not open Legit for Git-only' \
    "$git_session"
fi
send_keys "$git_session" q F6

if press_report "$git_session" F2 '^GUTTER ' &&
   grep -q '^GUTTER code-programming=yes code-mode=yes added=yes modified=yes deleted=yes initial=yes timer=yes transition-off=yes transition-clean=yes restored=yes markdown-programming=no markdown-mode=no markdown=none markdown-composed=none markdown-state=no utility-programming=no utility-mode=no utility=none utility-composed=none utility-state=no debounce-line=4 debounce-clean=yes markers=' \
     "$LEM_YATH_VCS_REPORT"; then
  screen=$(lem_capture "$git_session")
  if grep -qE '~.*vcs-change' <<<"$screen" &&
     grep -qE '_.*vcs-five' <<<"$screen" &&
     grep -qE '\+.*vcs-added' <<<"$screen"; then
    pass scoped-gutter 'real +/~/_ markers render only for the programming file'
  else
    fail scoped-gutter 'the fixture saw markers but ncurses did not render all rows' \
      "$git_session"
  fi
else
  fail scoped-gutter 'real diff markers leaked into prose/utility or were incomplete' \
    "$git_session"
fi

# Make a real normal/insert-mode edit on a previously clean tracked line, then
# leave Lem idle beyond the 300ms production debounce.  The only path that can
# install the new line-4 marker and clear the timer is the callback itself.
lem_keys "$git_session" i
tmux_cmd send-keys -t "$git_session" -l -- X
lem_keys "$git_session" Escape
sleep 1
if press_report "$git_session" F12 '^DEBOUNCE phase=git ' &&
   [[ $(latest_report '^DEBOUNCE phase=git ') == \
      'DEBOUNCE phase=git timer=no target=yes type=modified marker=~ changed=yes baseline=no source-text=no modified=yes' ]]; then
  pass gutter-debounce 'a real idle edit ran the callback, cleared its timer, and refreshed markers'
else
  fail gutter-debounce 'the real idle edit did not complete its debounced refresh' \
    "$git_session"
fi

lem_keys "$git_session" u
sleep 1
if press_report "$git_session" F12 '^DEBOUNCE phase=git ' &&
   [[ $(latest_report '^DEBOUNCE phase=git ') == \
      'DEBOUNCE phase=git timer=no target=no type=none marker=none changed=no baseline=yes source-text=yes modified=no' ]]; then
  pass gutter-debounce-undo 'undo restored source text and the baseline gutter through the same callback'
else
  fail gutter-debounce-undo 'undo did not restore the source and gutter baseline' \
    "$git_session"
fi

if press_report "$git_session" F10 '^INVOKE ' &&
   grep -q '^INVOKE source=yes other=yes point=7:8$' "$LEM_YATH_VCS_REPORT"; then
  pass timemachine-invocation 'a shifted anchor and unrelated prior buffer were prepared'
else
  fail timemachine-invocation 'the nontrivial source baseline was not established' \
    "$git_session"
fi

send_keys "$git_session" Space g t
if press_report "$git_session" F5 '^TIMEMACHINE ' &&
   grep -q '^TIMEMACHINE active=yes index=0 count=2 old=no new=yes .*read-only=yes .*minor=yes .*anchor=yes$' \
     "$LEM_YATH_VCS_REPORT"; then
  pass timemachine-newest 'SPC g t opened the renamed newest file at the source anchor'
else
  fail timemachine-newest 'time machine did not open newest at the translated anchor' \
    "$git_session"
fi

if press_report "$git_session" F11 '^DETOUR ' &&
   grep -q '^DETOUR timemachine=yes other=yes source-current=no$' \
     "$LEM_YATH_VCS_REPORT"; then
  pass timemachine-detour 'a normal buffer now outranks the stored invoker in recency'
else
  fail timemachine-detour 'could not create a non-source predecessor for q' \
    "$git_session"
fi

send_keys "$git_session" C-k
if press_report "$git_session" F5 '^TIMEMACHINE ' &&
   grep -q '^TIMEMACHINE active=yes index=1 count=2 old=yes new=no .*old-hash=yes .*read-only=yes .*minor=yes .*anchor=yes$' \
     "$LEM_YATH_VCS_REPORT"; then
  pass timemachine-older 'C-k followed the rename to older content and its shifted anchor'
else
  fail timemachine-older 'C-k did not render the pre-rename revision' "$git_session"
fi

send_keys "$git_session" C-j
if press_report "$git_session" F5 '^TIMEMACHINE ' &&
   [[ $(grep '^TIMEMACHINE active=yes ' "$LEM_YATH_VCS_REPORT" | tail -n 1) == \
      *'index=0 count=2 old=no new=yes '* ]] &&
   [[ $(grep '^TIMEMACHINE active=yes ' "$LEM_YATH_VCS_REPORT" | tail -n 1) == \
      *'anchor=yes' ]]; then
  pass timemachine-newer 'C-j returned to the newer translated content'
else
  fail timemachine-newer 'C-j did not return to the newer revision' "$git_session"
fi

send_keys "$git_session" g t g
if lem_wait_for "$git_session" 'Enter revision number:' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$git_session" -l -- 1
  send_keys "$git_session" Enter
  if press_report "$git_session" F5 '^TIMEMACHINE ' &&
     [[ $(grep '^TIMEMACHINE active=yes ' "$LEM_YATH_VCS_REPORT" | tail -n 1) == \
        *'index=1 count=2 old=yes new=no '* ]] &&
     [[ $(grep '^TIMEMACHINE active=yes ' "$LEM_YATH_VCS_REPORT" | tail -n 1) == \
        *'old-hash=yes '* ]]; then
    pass timemachine-nth 'gtg revision 1 selected the oldest full-hash revision'
  else
    fail timemachine-nth 'oldest-based numeric selection chose the wrong revision' \
      "$git_session"
  fi
else
  fail timemachine-nth 'gtg did not open the numeric revision prompt' \
    "$git_session"
fi

send_keys "$git_session" C-j g t t
if lem_wait_for "$git_session" 'Commit message:' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$git_session" -l -- vcs-old
  sleep 0.5
  send_keys "$git_session" Enter
  active_before=$(report_count '^TIMEMACHINE active=yes ')
  lem_keys "$git_session" F5
  if wait_report_count '^TIMEMACHINE active=yes ' "$((active_before + 1))" &&
     [[ $(grep '^TIMEMACHINE active=yes ' "$LEM_YATH_VCS_REPORT" | tail -n 1) == \
        *'index=1 count=2 old=yes new=no '* ]] &&
     [[ $(grep '^TIMEMACHINE active=yes ' "$LEM_YATH_VCS_REPORT" | tail -n 1) == \
        *'old-hash=yes '* ]]; then
    pass timemachine-fuzzy 'gtt selected the older revision by commit subject'
  else
    fail timemachine-fuzzy 'subject completion selected the wrong revision' \
      "$git_session"
  fi
else
  fail timemachine-fuzzy 'gtt did not open the commit-message completion prompt' \
    "$git_session"
fi

send_keys "$git_session" q
if press_report "$git_session" F7 '^SOURCE ' &&
   grep -q '^SOURCE current=yes live=yes text=yes point=yes mode=yes modified=yes filename=yes timemachine-live=0$' \
     "$LEM_YATH_VCS_REPORT"; then
  pass timemachine-quit 'q restored the exact source buffer and removed history views'
else
  fail timemachine-quit 'q changed source state or leaked a history buffer' \
    "$git_session"
fi

untracked_before=$(report_count '^UNTRACKED ')
send_keys "$git_session" C-c u
if wait_report_count '^UNTRACKED ' "$((untracked_before + 1))" &&
   [[ $(latest_report '^UNTRACKED ') == \
      'UNTRACKED current=yes file=yes tracked=no history=yes timemachine-live=0' ]]; then
  pass untracked-history-fixture 'the recreated path is untracked despite retained history'
else
  fail untracked-history-fixture 'the recreated-path precondition was not visible in Lem' \
    "$git_session"
fi

send_keys "$git_session" Space g t
if lem_wait_for "$git_session" 'File is not tracked by Git' "$WAIT_TIMEOUT" \
     >/dev/null; then
  untracked_before=$(report_count '^UNTRACKED ')
  send_keys "$git_session" C-c u
  if wait_report_count '^UNTRACKED ' "$((untracked_before + 1))" &&
     [[ $(latest_report '^UNTRACKED ') == \
        'UNTRACKED current=yes file=yes tracked=no history=yes timemachine-live=0' ]]; then
    pass timemachine-untracked 'SPC g t rejected untracked current state before opening history'
  else
    fail timemachine-untracked 'the rejection message appeared but a history view leaked' \
      "$git_session"
  fi
else
  fail timemachine-untracked 'SPC g t did not report the exact untracked-file rejection' \
    "$git_session"
fi

printf '\n'
cat "$LEM_YATH_VCS_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo 'VCS TEST PASSED'
  exit 0
else
  echo 'VCS TEST FAILED'
  exit 1
fi
