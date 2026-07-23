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
export LEM_YATH_SERVER_SOCKET="$root/server/server.sock"
export LEM_YATH_SERVER_PANE_FILE="$root/server/server.sock.pane"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_TERMINAL_PROMPT=0
export GIT_PAGER=cat
export GIT_ALLOW_PROTOCOL=file
export JJ_CONFIG="$root/jj-config.toml"
export JJ_PAGER=cat
export NO_COLOR=1
# The wrapper-path assertion starts Lem from an intentionally empty PATH.
# Host direnv bookkeeping would otherwise restore an unrelated parent PATH.
unset DIRENV_DIFF DIRENV_DIR DIRENV_FILE DIRENV_WATCHES
export LEM_YATH_VCS_REPORT="$root/report"
export LEM_YATH_VCS_PROMPT_INPUT="$root/prompt-input"
export LEM_YATH_VCS_COLOCATED_ROOT="$root/repos/colocated repo;safe/"
export LEM_YATH_VCS_GIT_MAIN="$root/repos/git main;safe/"
export LEM_YATH_VCS_GIT_ROOT="$root/repos/git worktree;safe/"
export LEM_YATH_VCS_CODE_FILE="${LEM_YATH_VCS_GIT_ROOT}nested/deeper/history.lisp"
export LEM_YATH_VCS_MARKDOWN_FILE="${LEM_YATH_VCS_GIT_ROOT}nested/docs/notes.md"
export LEM_YATH_VCS_UNTRACKED_FILE="${LEM_YATH_VCS_GIT_ROOT}nested/deeper/retired.lisp"
export LEM_YATH_VCS_PORCELAIN_ROOT="$root/repos/porcelain worktree;safe/"
export LEM_YATH_VCS_PORCELAIN_FILE="${LEM_YATH_VCS_PORCELAIN_ROOT}porcelain.txt"
export LEM_YATH_VCS_PORCELAIN_REMOTE="$root/repos/porcelain-remote.git"
export LEM_YATH_VCS_PORCELAIN_PEER="$root/repos/porcelain-peer"
export LEM_YATH_VCS_FETCH_REMOTE="$root/repos/fetch remote;safe.git"
export LEM_YATH_VCS_PUSH_REMOTE="$root/repos/push-target.git"
export LEM_YATH_VCS_MANAGED_REMOTE="$root/repos/managed remote;safe.git"
export LEM_YATH_VCS_WORKTREE_CHECKOUT="$root/repos/wt checkout;safe"
export LEM_YATH_VCS_WORKTREE_CREATED="$root/repos/wt created;safe"
export LEM_YATH_VCS_WORKTREE_MOVE_CONTAINER="$root/repos/wt container;safe"
export LEM_YATH_VCS_WORKTREE_MOVED="${LEM_YATH_VCS_WORKTREE_MOVE_CONTAINER}/wt created;safe"
export LEM_YATH_VCS_WORKTREE_LOCKED="$root/repos/wt locked;safe"
export LEM_YATH_VCS_WORKTREE_STALE="$root/repos/wt stale;safe"
export LEM_YATH_VCS_SUBMODULE_REMOTE="$root/repos/submodule remote;safe.git"
export LEM_YATH_VCS_SUBMODULE_SEED="$root/repos/submodule seed;safe"
export LEM_YATH_VCS_SUBMODULE_PATH="modules/module path;safe"
export LEM_YATH_VCS_SUBMODULE_NAME="module-safe"
export LEM_YATH_VCS_SUBTREE_REMOTE="$root/repos/subtree remote;safe.git"
export LEM_YATH_VCS_SUBTREE_SEED="$root/repos/subtree seed;safe"
export LEM_YATH_VCS_SUBTREE_PUSH="$root/repos/subtree push;safe.git"
export LEM_YATH_VCS_SUBTREE_PREFIX="vendor/module path;safe"
export LEM_YATH_VCS_SUBTREE_COMMIT_PREFIX="vendor/commit path;safe"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" "$LEM_HOME" \
  "$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper" \
  "$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper/raw directory;sentinel" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/deeper" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/deeper/raw directory;sentinel" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/docs" \
  "$LEM_YATH_VCS_PORCELAIN_ROOT/raw directory;sentinel"
: >"$LEM_YATH_VCS_REPORT"
: >"$LEM_YATH_VCS_PROMPT_INPUT"
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
printf '* TODO tracked implementation task\nordinary line\n' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/deeper/todos.org"
printf 'FIXME(owner): tracked documentation task\n' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/docs/fixmes.txt"
printf 'nested/deeper/ignored-todo.txt\n' \
  >"$LEM_YATH_VCS_GIT_MAIN/.gitignore"
printf '%s\n' \
  '[submodule "todo-fixture"]' \
  '  path = nested/vendor/module' \
  '  url = ../unused-module.git' \
  >"$LEM_YATH_VCS_GIT_MAIN/.gitmodules"
printf '%s\n' \
  'HOLD: held' 'NEXT: next' 'THEM: them' 'PROG: progress' 'OKAY: okay' \
  'DONT: avoid' 'FAIL: failed' 'MAYBE: maybe' 'KLUDGE: kludge' \
  'HACK: hack' 'TEMP: temporary' 'WIP: work' 'DEBUG: debug' 'XXXX*: literal' \
  'NOTE: ignored' 'DONE: ignored' 'TODO missing required colon' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/docs/keywords.txt"
"$git_bin" -C "$LEM_YATH_VCS_GIT_MAIN" add -- \
  .gitignore .gitmodules \
  nested/deeper/history-old.lisp nested/deeper/retired.lisp \
  nested/deeper/todos.org nested/docs/fixmes.txt nested/docs/keywords.txt \
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
printf 'TODO: untracked scanner item\n' \
  >"$LEM_YATH_VCS_GIT_ROOT/nested/deeper/untracked-todo.txt"
printf 'TODO: ignored scanner item\n' \
  >"$LEM_YATH_VCS_GIT_ROOT/nested/deeper/ignored-todo.txt"
mkdir -p "$LEM_YATH_VCS_GIT_ROOT/nested/vendor/module"
printf 'TODO: submodule scanner item\n' \
  >"$LEM_YATH_VCS_GIT_ROOT/nested/vendor/module/todos.txt"

# A separate repository exercises Legit's mutating Magit-like porcelain
# without changing the gutter and Timemachine history fixtures above.
if ! "$git_bin" init --bare -q "$LEM_YATH_VCS_PORCELAIN_REMOTE" ||
   ! "$git_bin" init --bare -q "$LEM_YATH_VCS_PUSH_REMOTE" ||
   ! git_init "$LEM_YATH_VCS_PORCELAIN_ROOT"; then
  echo "Could not initialize the porcelain Git fixtures" >&2
  rm -rf -- "$root"
  exit 1
fi
{
  for line in $(seq 1 40); do
    printf 'porcelain-line-%02d\n' "$line"
  done
} >"$LEM_YATH_VCS_PORCELAIN_FILE"
printf 'tracked auxiliary file\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
  porcelain.txt auxiliary.txt
if ! git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" porcelain-initial \
     '2001-01-04T00:00:00+0000' ||
   ! "$git_bin" clone --bare -q "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     "$LEM_YATH_VCS_MANAGED_REMOTE" ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" remote add origin \
     "$LEM_YATH_VCS_PORCELAIN_REMOTE" ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" remote add push-target \
     "$LEM_YATH_VCS_PUSH_REMOTE" ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" remote add -- \
     -push-option "$LEM_YATH_VCS_PUSH_REMOTE" ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -qu origin main ||
   ! "$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" symbolic-ref \
     HEAD refs/heads/main ||
   ! "$git_bin" clone -q "$LEM_YATH_VCS_PORCELAIN_REMOTE" \
     "$LEM_YATH_VCS_PORCELAIN_PEER"; then
  echo "Could not create the porcelain remote topology" >&2
  rm -rf -- "$root"
  exit 1
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" config \
  user.name 'Lem Yath Peer Test'
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" config \
  user.email 'lem-yath-peer@example.invalid'

# A separate local remote exercises the complete submodule lifecycle without
# requiring network or credential state.  GIT_ALLOW_PROTOCOL is scoped to this
# disposable test HOME and permits only the local file transport.
if ! "$git_bin" init --bare -q "$LEM_YATH_VCS_SUBMODULE_REMOTE" ||
   ! mkdir -p "$LEM_YATH_VCS_SUBMODULE_SEED" ||
   ! git_init "$LEM_YATH_VCS_SUBMODULE_SEED"; then
  echo "Could not initialize the submodule fixture" >&2
  rm -rf -- "$root"
  exit 1
fi
printf 'submodule version one\n' >"$LEM_YATH_VCS_SUBMODULE_SEED/module.txt"
"$git_bin" -C "$LEM_YATH_VCS_SUBMODULE_SEED" add -- module.txt
if ! git_commit "$LEM_YATH_VCS_SUBMODULE_SEED" submodule-v1 \
     '2001-01-05T00:00:00+0000' ||
   ! "$git_bin" -C "$LEM_YATH_VCS_SUBMODULE_SEED" remote add origin \
     "$LEM_YATH_VCS_SUBMODULE_REMOTE" ||
   ! "$git_bin" -C "$LEM_YATH_VCS_SUBMODULE_SEED" push -qu origin main ||
   ! "$git_bin" --git-dir="$LEM_YATH_VCS_SUBMODULE_REMOTE" symbolic-ref \
     HEAD refs/heads/main; then
  echo "Could not create the submodule remote topology" >&2
  rm -rf -- "$root"
  exit 1
fi

if ! "$git_bin" init --bare -q "$LEM_YATH_VCS_SUBTREE_REMOTE" ||
   ! "$git_bin" init --bare -q "$LEM_YATH_VCS_SUBTREE_PUSH" ||
   ! mkdir -p "$LEM_YATH_VCS_SUBTREE_SEED" ||
   ! git_init "$LEM_YATH_VCS_SUBTREE_SEED"; then
  echo "Could not initialize the subtree fixture" >&2
  rm -rf -- "$root"
  exit 1
fi
printf 'subtree version one\n' >"$LEM_YATH_VCS_SUBTREE_SEED/module.txt"
"$git_bin" -C "$LEM_YATH_VCS_SUBTREE_SEED" add -- module.txt
if ! git_commit "$LEM_YATH_VCS_SUBTREE_SEED" subtree-v1 \
     '2001-01-09T00:00:00+0000' ||
   ! "$git_bin" -C "$LEM_YATH_VCS_SUBTREE_SEED" remote add origin \
     "$LEM_YATH_VCS_SUBTREE_REMOTE" ||
   ! "$git_bin" -C "$LEM_YATH_VCS_SUBTREE_SEED" push -qu origin main ||
   ! "$git_bin" --git-dir="$LEM_YATH_VCS_SUBTREE_REMOTE" symbolic-ref \
     HEAD refs/heads/main; then
  echo "Could not create the subtree remote topology" >&2
  rm -rf -- "$root"
  exit 1
fi
sed -i '2s/.*/porcelain-line-02 changed-first-hunk/' \
  "$LEM_YATH_VCS_PORCELAIN_FILE"
sed -i '5s/.*/porcelain-line-05 changed-nearby-hunk/' \
  "$LEM_YATH_VCS_PORCELAIN_FILE"
sed -i '35s/.*/porcelain-line-35 changed-second-hunk/' \
  "$LEM_YATH_VCS_PORCELAIN_FILE"
printf 'porcelain untracked file\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/untracked.txt"

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

wait_until() {
  local timeout=$1 index=0
  shift
  while ((index < timeout * 4)); do
    if "$@"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

porcelain_first_hunk_only() {
  local diff
  diff=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    diff --cached --unified=0 -- porcelain.txt) || return 1
  grep -q 'changed-first-hunk' <<<"$diff" &&
    grep -q 'changed-nearby-hunk' <<<"$diff" &&
    ! grep -q 'changed-second-hunk' <<<"$diff"
}

porcelain_first_region_only() {
  local diff
  diff=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    diff --cached --unified=0 -- porcelain.txt) || return 1
  grep -q 'changed-first-hunk' <<<"$diff" &&
    ! grep -q 'changed-nearby-hunk' <<<"$diff" &&
    ! grep -q 'changed-second-hunk' <<<"$diff"
}

porcelain_first_region_unstaged() {
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --quiet -- porcelain.txt
}

porcelain_region_partially_unstaged() {
  local staged unstaged
  staged=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    diff --cached --unified=0 -- porcelain.txt) || return 1
  unstaged=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    diff --unified=0 -- porcelain.txt) || return 1
  ! grep -q 'changed-first-hunk' <<<"$staged" &&
    grep -q 'changed-nearby-hunk' <<<"$staged" &&
    ! grep -q 'changed-second-hunk' <<<"$staged" &&
    grep -q 'changed-first-hunk' <<<"$unstaged" &&
    grep -q 'changed-second-hunk' <<<"$unstaged"
}

porcelain_all_hunks_staged() {
  local diff
  diff=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    diff --cached --unified=0 -- porcelain.txt) || return 1
  grep -q 'changed-first-hunk' <<<"$diff" &&
    grep -q 'changed-nearby-hunk' <<<"$diff" &&
    grep -q 'changed-second-hunk' <<<"$diff" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --quiet -- porcelain.txt
}

porcelain_index_empty() {
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_all_staged() {
  local names
  names=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    diff --cached --name-only) || return 1
  [ "$names" = $'porcelain.txt\nuntracked.txt' ]
}

porcelain_subject_is() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    log -1 --format=%s 2>/dev/null)" = "$1" ]
}

porcelain_remote_matches_head() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" = \
    "$("$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
      rev-parse refs/heads/main)" ]
}

porcelain_fetch_complete() {
  [ "$fetch_original_head" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$fetch_topic_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse refs/remotes/origin/fetch-topic)" ] &&
    [ "$fetch_tag_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse refs/tags/fetch-tag)" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/remotes/origin/stale &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_elsewhere_fetched() {
  [ "$fetch_original_head" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$fetch_elsewhere_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse FETCH_HEAD)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_managed_remote_added() {
  [ "$LEM_YATH_VCS_MANAGED_REMOTE" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      remote get-url managed-safe 2>/dev/null)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/remotes/managed-safe/main
}

porcelain_managed_remote_configured() {
  [ "$LEM_YATH_VCS_MANAGED_REMOTE" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get remote.managed-safe.url)" ] &&
    [ '+refs/heads/main:refs/remotes/managed-safe/main' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        config --get-all remote.managed-safe.fetch)" ] &&
    [ "$LEM_YATH_VCS_PUSH_REMOTE" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        config --get remote.managed-safe.pushurl)" ] &&
    [ 'refs/heads/main:refs/heads/managed-main' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        config --get remote.managed-safe.push)" ] &&
    [ --tags = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get remote.managed-safe.tagOpt)" ] &&
    [ always = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get remote.managed-safe.followRemoteHEAD)" ]
}

porcelain_managed_remote_renamed() {
  ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" remote get-url \
    managed-safe >/dev/null 2>&1 &&
    [ "$LEM_YATH_VCS_MANAGED_REMOTE" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        remote get-url managed-renamed)" ] &&
    [ managed-renamed = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get remote.pushDefault)" ] &&
    [ managed-renamed = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.main.pushRemote)" ] &&
    [ --tags = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get remote.managed-renamed.tagOpt)" ]
}

porcelain_managed_remote_pruned() {
  ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show-ref --verify --quiet refs/remotes/managed-renamed/stale
}

porcelain_managed_refspec_pruned() {
  [ '+refs/heads/main:refs/remotes/managed-renamed/main' = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get-all remote.managed-renamed.fetch)" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/remotes/managed-renamed/absent
}

porcelain_managed_remote_removed() {
  ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" remote get-url \
    managed-renamed >/dev/null 2>&1 &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get remote.pushDefault >/dev/null 2>&1 &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.main.pushRemote >/dev/null 2>&1
}

porcelain_branch_is() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    branch --show-current)" = "$1" ]
}

porcelain_stashed() {
  [ -n "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash list)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet
}

porcelain_stash_restored() {
  [ -z "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash list)" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet
}

porcelain_stash_count_is() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash list | wc -l)" \
    -eq "$1" ]
}

porcelain_stash_all_saved() {
  porcelain_stash_count_is 1 &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/stash-untracked.txt" ] &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/stash-ignored.txt" ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-list --parents -n 1 refs/stash | wc -w)" -eq 4 ]
}

porcelain_stash_all_restored() {
  porcelain_stash_count_is 0 &&
    grep -q '^stash-both-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/stash-untracked.txt")" = \
      stash-untracked ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/stash-ignored.txt")" = \
      stash-ignored ]
}

porcelain_stash_index_saved() {
  porcelain_stash_count_is 1 &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet &&
    ! grep -q '^stash-index-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    grep -q '^stash-unstaged-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
}

porcelain_stash_index_restored() {
  porcelain_stash_count_is 0 &&
    grep -q '^stash-index-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    grep -q '^stash-unstaged-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt" &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- auxiliary.txt
}

porcelain_stash_worktree_saved() {
  porcelain_stash_count_is 1 &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- auxiliary.txt &&
    grep -q '^stash-index-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    ! grep -q '^stash-unstaged-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --quiet -- porcelain.txt
}

porcelain_stash_worktree_restored() {
  porcelain_stash_count_is 0 &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- auxiliary.txt &&
    grep -q '^stash-unstaged-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
}

porcelain_stash_snapshot_preserved() {
  porcelain_stash_count_is 1 &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- auxiliary.txt &&
    grep -q '^stash-index-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    grep -q '^stash-unstaged-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
}

porcelain_stash_wip_saved() {
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse --verify refs/wip/index/refs/heads/main >/dev/null 2>&1 &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-parse --verify refs/wip/wtree/refs/heads/main >/dev/null 2>&1 &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-parse refs/wip/index/refs/heads/main^{tree})" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" write-tree)" ] &&
    grep -q '^stash-index-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    grep -q '^stash-unstaged-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
}

porcelain_stash_applied() {
  porcelain_stash_count_is 1 &&
    grep -q '^stash-inspect-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
}

porcelain_stash_tracked_saved() {
  porcelain_stash_count_is 1 &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_stash_patch_created() {
  [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/0001-lem-stash-inspect.patch" ] &&
    grep -q '^+stash-inspect-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/0001-lem-stash-inspect.patch" &&
    porcelain_stash_count_is 1
}

porcelain_stash_branch_complete() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    branch --show-current)" = stash-branch-base ] &&
    porcelain_stash_count_is 0 &&
    grep -q '^stash-inspect-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
}

porcelain_stash_branch_here_complete() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    branch --show-current)" = stash-branch-here ] &&
    porcelain_stash_count_is 1 &&
    grep -q '^stash-here-probe$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
}

porcelain_peer_pulled() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" rev-parse HEAD)" ] &&
    grep -q 'peer-pull-probe' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
}

porcelain_rebase_todo_ready() {
  local todo="$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge/git-rebase-todo"
  [ -f "$todo" ] &&
    [ "$(grep -c '^pick ' "$todo")" -eq 2 ] &&
    grep -q 'porcelain commit from Lem' "$todo" &&
    grep -q 'porcelain-peer' "$todo"
}

porcelain_rebase_todo_reword_fixup() {
  local todo="$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge/git-rebase-todo"
  [ -f "$todo" ] &&
    [ "$(sed -n '1s/^reword .*/reword/p' "$todo")" = reword ] &&
    [ "$(sed -n '2s/^fixup .*/fixup/p' "$todo")" = fixup ]
}

porcelain_rebase_complete() {
  [ ! -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-list --count HEAD)" -eq 2 ] &&
    porcelain_subject_is 'porcelain commit reworded in Lem' &&
    grep -q 'peer-pull-probe' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_repeat_rebase_todo_ready() {
  local todo="$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge/git-rebase-todo"
  [ -f "$todo" ] &&
    [ "$(grep -c '^pick ' "$todo")" -eq 1 ] &&
    grep -q 'porcelain commit reworded in Lem' "$todo"
}

porcelain_repeat_rebase_todo_reword() {
  local todo="$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge/git-rebase-todo"
  [ -f "$todo" ] &&
    [ "$(sed -n '1s/^reword .*/reword/p' "$todo")" = reword ]
}

porcelain_repeat_rebase_complete() {
  [ ! -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-list --count HEAD)" -eq 2 ] &&
    porcelain_subject_is 'porcelain commit reworded twice in Lem' &&
    grep -q 'peer-pull-probe' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_edit_rebase_todo_ready() {
  local todo="$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge/git-rebase-todo"
  [ -f "$todo" ] &&
    [ "$(grep -c '^pick ' "$todo")" -eq 1 ] &&
    grep -q 'porcelain commit reworded twice in Lem' "$todo"
}

porcelain_edit_rebase_todo_marked() {
  local todo="$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge/git-rebase-todo"
  [ -f "$todo" ] &&
    [ "$(sed -n '1s/^edit .*/edit/p' "$todo")" = edit ]
}

porcelain_edit_rebase_stopped() {
  [ -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge/stopped-sha" ] &&
    porcelain_subject_is 'porcelain commit reworded twice in Lem' &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_edit_amend_staged() {
  local diff
  diff=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    diff --cached -- porcelain.txt) || return 1
  grep -q 'edit-stop-amendment' <<<"$diff" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet
}

porcelain_edit_amend_aborted() {
  [ -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    porcelain_subject_is 'porcelain commit reworded twice in Lem' &&
    porcelain_edit_amend_staged
}

porcelain_edit_amended() {
  [ -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    porcelain_subject_is 'porcelain commit edited in Lem' &&
    grep -q 'edit-stop-amendment' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_edit_rebase_complete() {
  [ ! -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-list --count HEAD)" -eq 2 ] &&
    porcelain_subject_is 'porcelain commit edited in Lem' &&
    grep -q 'edit-stop-amendment' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt" &&
    grep -q 'peer-pull-probe' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_cherry_active() {
  local metadata
  metadata=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse --git-path CHERRY_PICK_HEAD) || return 1
  case "$metadata" in
    /*) [ -f "$metadata" ] ;;
    *) [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/$metadata" ] ;;
  esac
}

porcelain_cherry_conflicted() {
  porcelain_cherry_active &&
    [ "$porcelain_conflict_head" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ -n "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      ls-files -u -- "$1")" ]
}

porcelain_cherry_clean() {
  ! porcelain_cherry_active &&
    [ -z "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" ls-files -u)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_cherry_success() {
  porcelain_subject_is 'cherry-success-source' &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-success.txt")" = \
      'picked successfully' ] &&
    porcelain_cherry_clean
}

porcelain_cherry_region_picked() {
  [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-region.txt")" = \
    $'region one\nregion two' ] &&
    [ 'cherry-region-one' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        log -1 --format=%s HEAD~1)" ] &&
    [ 'cherry-region-two' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        log -1 --format=%s HEAD)" ] &&
    [ "$cherry_main_head" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD~2)" ] &&
    porcelain_cherry_clean
}

porcelain_cherry_region_reverted() {
  [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-region.txt" ] &&
    [ 4 -eq "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-list --count "$cherry_main_head..HEAD")" ] &&
    [ 'Revert "cherry-region-two"' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        log -1 --format=%s HEAD~1)" ] &&
    [ 'Revert "cherry-region-one"' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        log -1 --format=%s HEAD)" ] &&
    porcelain_cherry_clean
}

porcelain_cherry_applied() {
  [ "$cherry_success_head" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-apply.txt")" = \
      'applied without commit' ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- cherry-apply.txt &&
    ! porcelain_cherry_active
}

porcelain_cherry_continued() {
  porcelain_subject_is 'cherry-continue-source' &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-continue.txt")" = \
      'continue resolved' ] &&
    porcelain_cherry_clean
}

porcelain_cherry_aborted() {
  [ "$porcelain_conflict_head" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-abort.txt")" = \
      'main abort value' ] &&
    porcelain_cherry_clean
}

porcelain_cherry_skipped() {
  [ "$porcelain_conflict_head" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-skip.txt")" = \
      'main skip value' ] &&
    porcelain_cherry_clean
}

porcelain_cherry_current_is() {
  [ "$1" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch --show-current)" ]
}

porcelain_cherry_spinout_complete() {
  porcelain_cherry_current_is "$cherry_move_main_branch" &&
    [ "$cherry_spinout_parent" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse \
        "$cherry_move_main_branch")" ] &&
    [ "$cherry_spinout_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse \
        cherry-spinout-destination)" ] &&
    porcelain_cherry_clean
}

porcelain_cherry_spinoff_complete() {
  porcelain_cherry_current_is cherry-spinoff-destination &&
    [ "$cherry_spinoff_parent" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse \
        "$cherry_move_main_branch")" ] &&
    [ "$cherry_spinoff_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse \
        cherry-spinoff-destination)" ] &&
    porcelain_cherry_clean
}

porcelain_cherry_donate_complete() {
  porcelain_cherry_current_is "$cherry_move_main_branch" &&
    [ "$cherry_donate_parent" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse \
        "$cherry_move_main_branch")" ] &&
    [ "$cherry_donate_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse \
        cherry-donate-destination)" ] &&
    porcelain_cherry_clean
}

porcelain_cherry_harvest_complete() {
  local source_tip
  source_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse cherry-harvest-source) || return 1
  porcelain_cherry_current_is "$cherry_move_main_branch" &&
    [ "$cherry_harvest_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse \
        "$cherry_move_main_branch")" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" merge-base \
      --is-ancestor "$cherry_harvest_hash" cherry-harvest-source &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" show \
      "$source_tip:cherry-harvest-retained.txt")" = 'retained on source' ] &&
    porcelain_cherry_clean
}

porcelain_cherry_squash_complete() {
  [ "$cherry_harvest_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-squash.txt")" = \
      'squashed into index' ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- cherry-squash.txt
}

porcelain_cherry_edit_complete() {
  local body
  body=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" log -1 --format=%B) ||
    return 1
  porcelain_cherry_current_is "$cherry_move_main_branch" &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" log -1 --format=%s)" = \
      'cherry message edited in Lem' ] &&
    printf '%s\n' "$body" | grep -Fq \
      "(cherry picked from commit $cherry_edit_hash)" &&
    printf '%s\n' "$body" | grep -Fq \
      'Signed-off-by: Lem Yath Test <lem-yath-test@example.invalid>' &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-edit.txt")" = \
      'edited cherry content' ] &&
    porcelain_cherry_clean
}

porcelain_cherry_mainline_complete() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" log -1 --format=%s)" = \
    'cherry-merge-source' ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-merge-side.txt")" = \
      'merge second-parent content' ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-list \
      --parents -n 1 HEAD | awk '{print NF}')" -eq 2 ] &&
    porcelain_cherry_clean
}

enter_cherry_revision() {
  local session=$1 revision=$2
  local index
  for index in $(seq 1 48); do
    lem_keys "$session" BSpace
  done
  tmux_cmd send-keys -t "$session" -l -- "$revision"
  send_keys "$session" Enter
}

prepare_porcelain_cherry_fixture() {
  local target_branch baseline
  target_branch=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    branch --show-current) || return 1
  [ -n "$target_branch" ] || return 1

  printf 'base continue value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-continue.txt"
  printf 'base abort value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-abort.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-continue.txt cherry-abort.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-baseline \
    '2001-01-06T00:00:00+0000' || return 1
  baseline=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    test-cherry-continue "$baseline" || return 1
  printf 'source continue value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-continue.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-continue.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-continue-source \
    '2001-01-07T00:00:00+0000' || return 1
  cherry_continue_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    test-cherry-abort "$baseline" || return 1
  printf 'source abort value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-abort.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-abort.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-abort-source \
    '2001-01-08T00:00:00+0000' || return 1
  cherry_abort_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    test-cherry-skip "$baseline" || return 1
  printf 'source skip value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-skip.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-skip.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-skip-source \
    '2001-01-09T00:00:00+0000' || return 1
  cherry_skip_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$target_branch" || return 1
  printf 'main continue value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-continue.txt"
  printf 'main abort value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-abort.txt"
  printf 'main skip value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-skip.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-continue.txt cherry-abort.txt cherry-skip.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-conflict-main \
    '2001-01-10T00:00:00+0000' || return 1
  cherry_main_head=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    test-cherry-success "$cherry_main_head" || return 1
  printf 'picked successfully\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-success.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-success.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-success-source \
    '2001-01-11T00:00:00+0000' || return 1
  cherry_success_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$target_branch" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    test-cherry-apply "$cherry_main_head" || return 1
  printf 'applied without commit\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-apply.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-apply.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-apply-source \
    '2001-01-12T00:00:00+0000' || return 1
  cherry_apply_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$target_branch" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    test-cherry-region "$cherry_main_head" || return 1
  printf 'region one\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-region.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-region.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-region-one \
    '2001-01-12T01:00:00+0000' || return 1
  cherry_region_one_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  printf 'region two\n' \
    >>"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-region.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-region.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-region-two \
    '2001-01-12T02:00:00+0000' || return 1
  cherry_region_two_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$target_branch" || return 1
  [ "$cherry_main_head" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    porcelain_cherry_clean
}

prepare_porcelain_cherry_move_fixture() {
  local baseline
  cherry_move_main_branch=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    branch --show-current) || return 1
  [ -n "$cherry_move_main_branch" ] || return 1
  baseline=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) ||
    return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    cherry-harvest-source "$baseline" || return 1
  printf 'harvested content\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-harvest.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-harvest.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-harvest-selected \
    '2001-01-13T00:00:00+0000' || return 1
  cherry_harvest_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  printf 'retained on source\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-harvest-retained.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-harvest-retained.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-harvest-retained \
    '2001-01-14T00:00:00+0000' || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$cherry_move_main_branch" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    cherry-squash-source "$baseline" || return 1
  printf 'squashed into index\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-squash.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-squash.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-squash-source \
    '2001-01-15T00:00:00+0000' || return 1
  cherry_squash_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$cherry_move_main_branch" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    cherry-edit-source "$baseline" || return 1
  printf 'edited cherry content\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-edit.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-edit.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-edit-source \
    '2001-01-16T00:00:00+0000' || return 1
  cherry_edit_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$cherry_move_main_branch" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    cherry-merge-source "$baseline" || return 1
  printf 'merge first-parent content\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-merge-first.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-merge-first.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-merge-first \
    '2001-01-17T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -qc \
    cherry-merge-side "$baseline" || return 1
  printf 'merge second-parent content\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-merge-side.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-merge-side.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-merge-side \
    '2001-01-18T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    cherry-merge-source || return 1
  GIT_AUTHOR_DATE='2001-01-19T00:00:00+0000' \
  GIT_COMMITTER_DATE='2001-01-19T00:00:00+0000' \
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" merge -q --no-ff \
      -m cherry-merge-source cherry-merge-side || return 1
  cherry_merge_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q \
    "$cherry_move_main_branch" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    cherry-donate-destination "$baseline" || return 1
  cherry_donate_parent=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  printf 'donated content\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-donate.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-donate.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-donate-source \
    '2001-01-20T00:00:00+0000' || return 1
  cherry_donate_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  cherry_spinoff_parent=$cherry_donate_hash
  printf 'spin-off content\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-spinoff.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-spinoff.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-spinoff-source \
    '2001-01-21T00:00:00+0000' || return 1
  cherry_spinoff_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  cherry_spinout_parent=$cherry_spinoff_hash
  printf 'spin-out content\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-spinout.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    cherry-spinout.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" cherry-spinout-source \
    '2001-01-22T00:00:00+0000' || return 1
  cherry_spinout_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  porcelain_cherry_clean
}

porcelain_bisect_active() {
  local metadata
  metadata=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse --git-path BISECT_LOG) || return 1
  case "$metadata" in
    /*) [ -f "$metadata" ] ;;
    *) [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/$metadata" ] ;;
  esac
}

porcelain_bisect_no_checkout() {
  local metadata
  porcelain_bisect_active || return 1
  metadata=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse --git-path BISECT_HEAD) || return 1
  case "$metadata" in
    /*) [ -f "$metadata" ] ;;
    *) [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/$metadata" ] ;;
  esac
}

porcelain_bisect_reset() {
  ! porcelain_bisect_active &&
    [ "$bisect_bad_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_bisect_first_bad() {
  porcelain_bisect_active &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" bisect log |
      grep -Fq "# first bad commit: [$bisect_first_bad_hash]"
}

porcelain_bisect_log_has() {
  porcelain_bisect_active &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" bisect log |
      grep -Fq "git bisect $1"
}

prepare_porcelain_bisect_fixture() {
  local index timestamp
  porcelain_cherry_clean || return 1
  printf 'healthy state\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/bisect-probe.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- bisect-probe.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" bisect-good-0 \
    '2001-02-01T00:00:00+0000' || return 1
  bisect_good_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  for index in 1 2 3 4 5 6 7 8; do
    if [ "$index" -eq 4 ]; then
      printf 'BUG introduced here\n' \
        >>"$LEM_YATH_VCS_PORCELAIN_ROOT/bisect-probe.txt"
    else
      printf 'revision %s\n' "$index" \
        >>"$LEM_YATH_VCS_PORCELAIN_ROOT/bisect-probe.txt"
    fi
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- bisect-probe.txt ||
      return 1
    timestamp=$(printf '2001-02-%02dT00:00:00+0000' "$((index + 1))")
    git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" "bisect-step-$index" \
      "$timestamp" || return 1
    if [ "$index" -eq 4 ]; then
      bisect_first_bad_hash=$("$git_bin" \
        -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1
    fi
  done
  bisect_bad_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  porcelain_cherry_clean
}

porcelain_reset_clean_at() {
  [ "$1" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_reset_mixed() {
  [ "$reset_base_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-mode.txt")" = \
      'reset mode step' ]
}

porcelain_reset_soft() {
  [ "$reset_base_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-mode.txt")" = \
      'reset mode step' ]
}

porcelain_reset_keep() {
  local names
  names=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --name-only) ||
    return 1
  [ "$reset_base_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$names" = reset-keep.txt ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-mode.txt")" = \
      'reset mode base' ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-keep.txt")" = \
      'uncommitted keep value' ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_reset_index_only() {
  local names
  names=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --name-only) ||
    return 1
  porcelain_reset_clean_at "$reset_step_hash" && return 1
  [ "$reset_step_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$names" = reset-index.txt ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-index.txt")" = \
      'staged index value' ]
}

porcelain_reset_worktree_only() {
  [ "$reset_step_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-worktree.txt")" = \
      'reset worktree base' ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show :reset-worktree.txt)" = 'staged worktree value' ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- reset-worktree.txt &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --quiet -- reset-worktree.txt
}

porcelain_reset_file_only() {
  [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset dir;safe/target file.txt")" = \
    'reset target step' ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-other.txt")" = \
      'other remains dirty' ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --quiet -- 'reset dir;safe/target file.txt' &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --quiet -- reset-other.txt
}

porcelain_reset_other_branch() {
  local reflog
  reflog=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    reflog show -1 --format=%gs reset-moving 2>/dev/null) || return 1
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
       rev-parse reset-moving)" = "$reset_step_hash" ] &&
    [ "$reflog" = "reset: moving to $reset_step_hash" ] &&
    porcelain_reset_clean_at "$reset_step_hash"
}

prepare_porcelain_reset_fixture() {
  porcelain_reset_clean_at "$bisect_bad_hash" || return 1
  reset_current_branch=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    branch --show-current) || return 1
  [ -n "$reset_current_branch" ] || return 1
  mkdir -p "$LEM_YATH_VCS_PORCELAIN_ROOT/reset dir;safe"
  printf 'reset mode base\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-mode.txt"
  printf 'reset keep base\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-keep.txt"
  printf 'reset index base\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-index.txt"
  printf 'reset worktree base\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-worktree.txt"
  printf 'reset target base\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset dir;safe/target file.txt"
  printf 'reset other base\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-other.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    reset-mode.txt reset-keep.txt reset-index.txt reset-worktree.txt \
    'reset dir;safe/target file.txt' reset-other.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" reset-base \
    '2001-03-01T00:00:00+0000' || return 1
  reset_base_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  printf 'reset mode step\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-mode.txt"
  printf 'reset target step\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset dir;safe/target file.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    reset-mode.txt 'reset dir;safe/target file.txt' || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" reset-step \
    '2001-03-02T00:00:00+0000' || return 1
  reset_step_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    reset-moving "$reset_base_hash" || return 1
  porcelain_reset_clean_at "$reset_step_hash"
}

porcelain_merge_metadata_absent() {
  [ ! -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/MERGE_HEAD" ]
}

porcelain_merge_clean_at_main() {
  [ "$merge_main_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    porcelain_merge_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_merge_plain_complete() {
  [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
       rev-list --parents -1 HEAD | awk '{print NF}')" = 3 ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-plain.txt")" = \
      'plain branch value' ] &&
    porcelain_merge_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_merge_squashed() {
  porcelain_merge_metadata_absent &&
    [ "$merge_main_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-squash.txt")" = \
      'squash branch value' ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- merge-squash.txt &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --quiet -- merge-squash.txt
}

porcelain_merge_no_commit() {
  [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/MERGE_HEAD" ] &&
    [ "$merge_main_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-nocommit.txt")" = \
      'no commit branch value' ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- merge-nocommit.txt
}

porcelain_merge_conflicted() {
  [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/MERGE_HEAD" ] &&
    [ -n "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      ls-files --unmerged -- merge-conflict.txt)" ]
}

porcelain_merge_subject_is() {
  [ "$1" = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    log -1 --format=%s)" ]
}

porcelain_merge_absorbed() {
  porcelain_branch_is "$reset_current_branch" &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/heads/merge-absorb &&
    [ "$merge_absorb_hash" = \
      "$("$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
        rev-parse refs/heads/merge-absorb)" ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
       log -1 --format=%s)" = "Merge branch 'merge-absorb' [#42]" ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
       rev-list --parents -1 HEAD | awk '{print NF}')" = 3 ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-absorb.txt")" = \
      'absorb local updated value' ] &&
    porcelain_merge_metadata_absent
}

porcelain_merge_lease_refused() {
  [ "$merge_absorb_target_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/heads/merge-lease-fail &&
    [ "$merge_lease_remote_hash" = \
      "$("$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
        rev-parse refs/heads/merge-lease-fail)" ] &&
    porcelain_merge_metadata_absent
}

porcelain_merge_dissolved() {
  porcelain_branch_is "$reset_current_branch" &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/heads/merge-dissolve &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-dissolve.txt")" = \
      'dissolve branch value' ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
       rev-list --parents -1 HEAD | awk '{print NF}')" = 3 ] &&
    porcelain_merge_metadata_absent
}

create_porcelain_merge_branch() {
  local branch=$1 filename=$2 content=$3 timestamp=$4
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    "$branch" "$reset_step_hash" || return 1
  printf '%s\n' "$content" \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/$filename"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- "$filename" ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" "$branch" "$timestamp"
}

prepare_porcelain_merge_fixture() {
  rm -f -- "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-untracked.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
    "$reset_step_hash" || return 1
  printf 'merge main value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    merge-conflict.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" merge-main \
    '2001-04-01T00:00:00+0000' || return 1
  merge_main_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  create_porcelain_merge_branch merge-plain merge-plain.txt \
    'plain branch value' '2001-04-02T00:00:00+0000' || return 1
  create_porcelain_merge_branch merge-nocommit merge-nocommit.txt \
    'no commit branch value' '2001-04-03T00:00:00+0000' || return 1
  create_porcelain_merge_branch merge-edit merge-edit.txt \
    'edit branch value' '2001-04-04T00:00:00+0000' || return 1
  create_porcelain_merge_branch merge-squash merge-squash.txt \
    'squash branch value' '2001-04-05T00:00:00+0000' || return 1
  create_porcelain_merge_branch merge-preview merge-preview.txt \
    'preview branch value' '2001-04-06T00:00:00+0000' || return 1
  create_porcelain_merge_branch merge-conflict merge-conflict.txt \
    'merge side value' '2001-04-07T00:00:00+0000' || return 1
  create_porcelain_merge_branch merge-absorb merge-absorb.txt \
    'absorb remote value' '2001-04-08T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    merge-absorb:merge-absorb || return 1
  printf 'absorb local updated value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-absorb.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    merge-absorb.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" merge-absorb-local \
    '2001-04-09T00:00:00+0000' || return 1
  merge_absorb_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.merge-absorb.pushRemote origin || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.merge-absorb.pullRequest 42 || return 1

  create_porcelain_merge_branch merge-dissolve merge-dissolve.txt \
    'dissolve branch value' '2001-04-10T00:00:00+0000' || return 1

  create_porcelain_merge_branch merge-lease-fail merge-lease.txt \
    'lease original value' '2001-04-11T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    merge-lease-fail:merge-lease-fail || return 1
  merge_lease_tracking_hash=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse refs/remotes/origin/merge-lease-fail) || return 1
  printf 'lease local divergent value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-lease.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    merge-lease.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" merge-lease-local \
    '2001-04-12T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.merge-lease-fail.pushRemote origin || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" fetch -q origin || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" checkout -q -B \
    merge-lease-fail origin/merge-lease-fail || return 1
  printf 'lease remote advanced value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_PEER/merge-lease.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- \
    merge-lease.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" merge-lease-remote \
    '2001-04-13T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -q origin \
    merge-lease-fail || return 1
  merge_lease_remote_hash=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_PEER" rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q \
    "$reset_current_branch" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
    "$merge_main_hash" || return 1
  porcelain_merge_clean_at_main
}

porcelain_revert_metadata_absent() {
  [ ! -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/REVERT_HEAD" ] &&
    [ ! -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/sequencer/todo" ]
}

porcelain_revert_conflicted() {
  [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/REVERT_HEAD" ] &&
    [ -n "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      ls-files --unmerged -- merge-conflict.txt)" ]
}

porcelain_revert_noedit_complete() {
  porcelain_branch_is revert-noedit &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-noedit.txt" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" log -1 --format=%B |
      grep -q '^Signed-off-by: Lem Yath Test <lem-yath-test@example.invalid>$' &&
    porcelain_revert_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_revert_subject_is() {
  [ "$1" = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    log -1 --format=%s)" ]
}

porcelain_revert_no_commit_complete() {
  [ "$revert_nocommit_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-nocommit.txt" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      diff --cached --quiet -- revert-nocommit.txt &&
    [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/REVERT_HEAD" ] &&
    [ ! -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/sequencer/todo" ]
}

porcelain_revert_multi_complete() {
  [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-multi-a.txt" ] &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-multi-b.txt" ] &&
    [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
       rev-list --count "$merge_main_hash..HEAD")" = 4 ] &&
    porcelain_revert_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_revert_merge_complete() {
  [ -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-merge-main.txt" ] &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-merge-side.txt" ] &&
    porcelain_revert_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_revert_abort_complete() {
  [ "$revert_conflict_tip" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt")" = \
      'revert later value' ] &&
    porcelain_revert_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_revert_continue_complete() {
  porcelain_revert_subject_is 'Revert "revert-conflict-target"' &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt")" = \
      'merge main value' ] &&
    porcelain_revert_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_revert_skip_complete() {
  [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt")" = \
      'skip later value' ] &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-skip.txt" ] &&
    porcelain_revert_metadata_absent &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_branch_current_is() {
  [ "$1" = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    symbolic-ref --quiet --short HEAD 2>/dev/null)" ]
}

porcelain_branch_remote_checkout_complete() {
  porcelain_branch_current_is remote-topic &&
    [ "$branch_remote_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "origin/remote-topic" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        for-each-ref --format='%(upstream:short)' refs/heads/remote-topic)" ] &&
    [ origin = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.remote-topic.pushRemote)" ]
}

porcelain_branch_created_complete() {
  porcelain_branch_current_is branch-created &&
    [ "$merge_main_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ]
}

porcelain_branch_no_checkout_complete() {
  porcelain_branch_current_is branch-created &&
    [ "$merge_main_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse refs/heads/branch-no-checkout)" ]
}

porcelain_branch_orphan_complete() {
  porcelain_branch_current_is branch-orphan &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-parse --verify HEAD >/dev/null 2>&1 &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_branch_renamed_complete() {
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show-ref --verify --quiet refs/heads/branch-renamed &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/heads/branch-no-checkout
}

porcelain_branch_remote_renamed_complete() {
  [ "$merge_main_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-parse refs/heads/branch-remote-renamed 2>/dev/null)" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/heads/branch-remote-rename &&
    porcelain_origin_branch_is branch-remote-renamed "$branch_remote_hash" &&
    ! "$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
      show-ref --verify --quiet refs/heads/branch-remote-rename &&
    [ origin = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.branch-remote-renamed.pushRemote)" ]
}

porcelain_branch_shelved_complete() {
  ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show-ref --verify --quiet refs/heads/branch-shelve &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet "refs/shelved/$branch_shelved_name" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      reflog exists "refs/shelved/$branch_shelved_name" &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      reflog exists refs/heads/branch-shelve &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.branch-shelve.pushRemote >/dev/null 2>&1
}

porcelain_branch_unshelved_complete() {
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show-ref --verify --quiet refs/heads/branch-shelve &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet "refs/shelved/$branch_shelved_name" &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      reflog exists refs/heads/branch-shelve &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      reflog exists "refs/shelved/$branch_shelved_name"
}

porcelain_branch_remote_deleted_complete() {
  ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show-ref --verify --quiet refs/remotes/origin/remote-delete &&
    ! "$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
      show-ref --verify --quiet refs/heads/remote-delete
}

porcelain_branch_remote_local_only_complete() {
  ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show-ref --verify --quiet refs/remotes/origin/remote-keep &&
    porcelain_origin_branch_is remote-keep "$branch_remote_hash"
}

porcelain_branch_default_updated_complete() {
  porcelain_branch_current_is primary-next &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      show-ref --verify --quiet refs/heads/main &&
    [ origin/primary-next = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" symbolic-ref \
        --quiet --short refs/remotes/origin/HEAD)" ] &&
    [ origin/primary-next = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        for-each-ref --format='%(upstream:short)' \
        refs/heads/default-follower)" ]
}

porcelain_branch_config_complete() {
  [ 'configured branch description' = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.branch-renamed.description)" ] &&
    [ 'origin/remote-topic' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        for-each-ref --format='%(upstream:short)' \
        refs/heads/branch-renamed)" ] &&
    [ true = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.branch-renamed.rebase)" ] &&
    [ origin = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.branch-renamed.pushRemote)" ] &&
    [ true = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get pull.rebase)" ] &&
    [ origin = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get remote.pushDefault)" ] &&
    [ always = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.autoSetupMerge)" ] &&
    [ remote = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.autoSetupRebase)" ]
}

porcelain_branch_reset_complete() {
  [ "$branch_remote_hash" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-parse refs/heads/branch-renamed)" ] &&
    porcelain_branch_current_is branch-created
}

porcelain_branch_absent() {
  ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show-ref --verify --quiet "refs/heads/$1"
}

porcelain_branch_spinoff_complete() {
  porcelain_branch_current_is branch-spun-off &&
    [ "$branch_spinoff_tip" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$merge_main_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse refs/heads/branch-spinoff-source)" ] &&
    [ 'origin/spin-base' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        for-each-ref --format='%(upstream:short)' \
        refs/heads/branch-spun-off)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_branch_spinoff_region_complete() {
  porcelain_branch_current_is branch-spun-off-region &&
    [ "$branch_spinoff_region_tip" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$branch_spinoff_region_keep" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse refs/heads/branch-spinoff-region-source)" ] &&
    [ 'origin/spin-base' = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        for-each-ref --format='%(upstream:short)' \
        refs/heads/branch-spun-off-region)" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_branch_spinout_complete() {
  porcelain_branch_current_is branch-spinout-source &&
    [ "$merge_main_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$branch_spinout_tip" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse refs/heads/branch-spun-out)" ] &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/branch-spinout.txt" ] &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet
}

porcelain_branch_dirty_spinout_complete() {
  porcelain_branch_current_is branch-dirty-spin &&
    [ "$branch_dirty_tip" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ "$merge_main_hash" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        rev-parse refs/heads/branch-dirty-source)" ] &&
    grep -q '^dirty worktree survives$' \
      "$LEM_YATH_VCS_PORCELAIN_ROOT/branch-dirty.txt" &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet -- \
      branch-dirty.txt
}

prepare_porcelain_branch_fixture() {
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q main || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
    "$merge_main_hash" || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/heads/branch-checkout "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/heads/branch-delete-merged "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/heads/branch-current-delete "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/heads/branch-shelve "$merge_main_hash" || return 1
  branch_shelved_name="$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    show -s --format=%cs branch-shelve)-branch-shelve" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.branch-shelve.pushRemote origin || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/heads/branch-remote-rename "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/heads/default-follower "$merge_main_hash" || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    branch-remote-build "$merge_main_hash" || return 1
  printf 'remote branch value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-remote.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- branch-remote.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-remote \
    '2001-06-01T00:00:00+0000' || return 1
  branch_remote_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    HEAD:refs/heads/remote-topic || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/remotes/origin/remote-topic "$branch_remote_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    "$branch_remote_hash":refs/heads/branch-remote-rename || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/remotes/origin/branch-remote-rename "$branch_remote_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.branch-remote-rename.pushRemote origin || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    "$branch_remote_hash":refs/heads/remote-delete \
    "$branch_remote_hash":refs/heads/remote-keep || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/remotes/origin/remote-delete "$branch_remote_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/remotes/origin/remote-keep "$branch_remote_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/main default-follower >/dev/null || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" symbolic-ref \
    refs/remotes/origin/HEAD refs/remotes/origin/main || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q main || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -D \
    branch-remote-build >/dev/null || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    branch-delete-unmerged "$merge_main_hash" || return 1
  printf 'unmerged branch value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-unmerged.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- branch-unmerged.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-unmerged \
    '2001-06-02T00:00:00+0000' || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    "$merge_main_hash":refs/heads/spin-base || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/remotes/origin/spin-base "$merge_main_hash" || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    branch-spinoff-source "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/spin-base branch-spinoff-source >/dev/null ||
    return 1
  printf 'spin off one\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-spinoff-a.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    branch-spinoff-a.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-spinoff-a \
    '2001-06-03T00:00:00+0000' || return 1
  printf 'spin off two\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-spinoff-b.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    branch-spinoff-b.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-spinoff-b \
    '2001-06-04T00:00:00+0000' || return 1
  branch_spinoff_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    branch-spinoff-region-source "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/spin-base \
    branch-spinoff-region-source >/dev/null || return 1
  printf 'region keep\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-spinoff-region.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    branch-spinoff-region.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-spinoff-region-keep \
    '2001-06-03T01:00:00+0000' || return 1
  branch_spinoff_region_keep=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1
  printf 'region move one\n' \
    >>"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-spinoff-region.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    branch-spinoff-region.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-spinoff-region-one \
    '2001-06-03T02:00:00+0000' || return 1
  printf 'region move two\n' \
    >>"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-spinoff-region.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    branch-spinoff-region.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-spinoff-region-two \
    '2001-06-03T03:00:00+0000' || return 1
  branch_spinoff_region_tip=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    branch-spinout-source "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/spin-base branch-spinout-source >/dev/null ||
    return 1
  printf 'spin out value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-spinout.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    branch-spinout.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-spinout \
    '2001-06-05T00:00:00+0000' || return 1
  branch_spinout_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    branch-dirty-source "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/spin-base branch-dirty-source >/dev/null ||
    return 1
  printf 'committed dirty source\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-dirty.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- branch-dirty.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" branch-dirty \
    '2001-06-06T00:00:00+0000' || return 1
  branch_dirty_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q main || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
    "$merge_main_hash" || return 1
  porcelain_branch_current_is main
}

porcelain_origin_ref_is() {
  [ "$2" = "$("$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
    rev-parse "$1" 2>/dev/null)" ]
}

porcelain_origin_branch_is() {
  porcelain_origin_ref_is "refs/heads/$1" "$2"
}

porcelain_push_target_ref_is() {
  [ "$2" = "$("$git_bin" --git-dir="$LEM_YATH_VCS_PUSH_REMOTE" \
    rev-parse "$1" 2>/dev/null)" ]
}

porcelain_push_remote_complete() {
  porcelain_origin_branch_is push-current "$push_current_tip"
}

porcelain_push_upstream_complete() {
  porcelain_origin_branch_is push-upstream "$push_upstream_tip"
}

porcelain_push_elsewhere_complete() {
  porcelain_origin_branch_is push-elsewhere "$push_current_tip" &&
    [ origin/push-elsewhere = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        for-each-ref --format='%(upstream:short)' \
        refs/heads/push-current)" ] &&
    [ "$push_current_tip" = \
      "$("$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
        rev-parse refs/tags/push-follow-tag^{} 2>/dev/null)" ]
}

porcelain_push_dry_run_complete() {
  ! "$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" \
    show-ref --verify --quiet refs/heads/push-dry-run
}

porcelain_push_other_complete() {
  porcelain_push_target_ref_is refs/heads/push-other-target "$push_other_tip"
}

porcelain_push_refspecs_complete() {
  porcelain_origin_ref_is refs/heads/push-explicit "$push_other_tip" &&
    porcelain_origin_ref_is refs/tags/push-explicit-tag \
      "$push_one_tag_object"
}

porcelain_push_matching_complete() {
  porcelain_push_target_ref_is refs/heads/push-match "$push_match_tip"
}

porcelain_push_one_tag_complete() {
  porcelain_origin_ref_is refs/tags/push-one "$push_one_tag_object"
}

porcelain_push_all_tags_complete() {
  porcelain_origin_ref_is refs/tags/push-all-extra \
    "$push_all_tag_object"
}

porcelain_push_notes_complete() {
  porcelain_origin_ref_is refs/notes/review "$push_notes_tip"
}

porcelain_push_force_with_lease_complete() {
  porcelain_origin_branch_is push-force "$push_force_tip"
}

porcelain_push_settled() {
  local predicate=$1
  wait_legit "$porcelain_session" porcelain &&
    wait_until "$WAIT_TIMEOUT" "$predicate"
}

pull_upstream_tip=
pull_pushremote_tip=
pull_elsewhere_tip=
pull_rebase_remote_tip=
pull_rebase_old_local_tip=
pull_refusal_remote_tip=
pull_refusal_local_tip=
pull_conflict_local_tip=

porcelain_pull_clean() {
  [ -z "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" status --porcelain)" ] &&
    [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/MERGE_HEAD" ] &&
    [ ! -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    [ ! -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-apply" ]
}

porcelain_pull_head_is() {
  local branch=$1 expected=$2
  [ "$branch" = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    symbolic-ref --quiet --short HEAD 2>/dev/null)" ] &&
    [ "$expected" = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      rev-parse HEAD 2>/dev/null)" ] &&
    porcelain_pull_clean
}

porcelain_pull_upstream_complete() {
  porcelain_pull_head_is pull-upstream "$pull_upstream_tip" &&
    [ origin/pull-upstream = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        for-each-ref --format='%(upstream:short)' refs/heads/pull-upstream)" ]
}

porcelain_pull_pushremote_complete() {
  porcelain_pull_head_is pull-pushremote "$pull_pushremote_tip" &&
    [ origin = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      config --get branch.pull-pushremote.pushRemote)" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --get \
      branch.pull-pushremote.merge >/dev/null 2>&1
}

porcelain_pull_elsewhere_complete() {
  porcelain_pull_head_is pull-elsewhere "$pull_elsewhere_tip"
}

porcelain_pull_rebase_configured() {
  [ true = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    config --get branch.pull-rebase.rebase 2>/dev/null)" ]
}

porcelain_pull_rebase_complete() {
  local head parent subject
  head=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) ||
    return 1
  parent=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD^) ||
    return 1
  subject=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    log -1 --format=%s) || return 1
  [ pull-rebase = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    symbolic-ref --quiet --short HEAD 2>/dev/null)" ] &&
    [ "$parent" = "$pull_rebase_remote_tip" ] &&
    [ "$subject" = pull-rebase-local ] &&
    [ "$head" != "$pull_rebase_old_local_tip" ] &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" merge-base \
      --is-ancestor "$pull_rebase_old_local_tip" HEAD &&
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" merge-base \
      --is-ancestor "$pull_rebase_remote_tip" HEAD &&
    [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/pull-rebase-local.txt" ] &&
    [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/pull-rebase-remote.txt" ] &&
    porcelain_pull_clean
}

porcelain_pull_ff_refused() {
  porcelain_pull_head_is pull-refusal "$pull_refusal_local_tip" &&
    ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" merge-base \
      --is-ancestor "$pull_refusal_remote_tip" HEAD
}

porcelain_pull_conflicted() {
  [ pull-conflict = "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    symbolic-ref --quiet --short HEAD 2>/dev/null)" ] &&
    [ "$pull_conflict_local_tip" = \
      "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/MERGE_HEAD" ] &&
    [ -n "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
      ls-files -u -- pull-conflict.txt)" ] &&
    [ ! -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-merge" ] &&
    [ ! -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/rebase-apply" ]
}

porcelain_pull_conflict_aborted() {
  porcelain_pull_head_is pull-conflict "$pull_conflict_local_tip" &&
    [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/pull-conflict.txt")" = \
      'pull conflict local' ]
}

prepare_porcelain_pull_fixture() {
  local base=$merge_main_hash

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -f main ||
    return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard "$base" ||
    return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" fetch -q origin || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" checkout -q -B \
    pull-upstream "$base" || return 1
  printf 'pull upstream remote\n' \
    >"$LEM_YATH_VCS_PORCELAIN_PEER/pull-upstream.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- pull-upstream.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" pull-upstream-remote \
    '2001-06-20T00:00:00+0000' || return 1
  pull_upstream_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -qf origin \
    HEAD:refs/heads/pull-upstream || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" checkout -q -B \
    pull-pushremote "$base" || return 1
  printf 'pull push remote\n' \
    >"$LEM_YATH_VCS_PORCELAIN_PEER/pull-pushremote.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- \
    pull-pushremote.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" pull-pushremote-remote \
    '2001-06-21T00:00:00+0000' || return 1
  pull_pushremote_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -qf origin \
    HEAD:refs/heads/pull-pushremote || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" checkout -q -B \
    pull-rebase "$base" || return 1
  printf 'pull rebase remote\n' \
    >"$LEM_YATH_VCS_PORCELAIN_PEER/pull-rebase-remote.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- \
    pull-rebase-remote.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" pull-rebase-remote \
    '2001-06-22T00:00:00+0000' || return 1
  pull_rebase_remote_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -qf origin \
    HEAD:refs/heads/pull-rebase || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" checkout -q -B \
    pull-refusal "$base" || return 1
  printf 'pull refusal remote\n' \
    >"$LEM_YATH_VCS_PORCELAIN_PEER/pull-refusal-remote.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- \
    pull-refusal-remote.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" pull-refusal-remote \
    '2001-06-23T00:00:00+0000' || return 1
  pull_refusal_remote_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -qf origin \
    HEAD:refs/heads/pull-refusal || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" checkout -q -B \
    pull-conflict "$base" || return 1
  printf 'pull conflict remote\n' \
    >"$LEM_YATH_VCS_PORCELAIN_PEER/pull-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- \
    pull-conflict.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" pull-conflict-remote \
    '2001-06-24T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -qf origin \
    HEAD:refs/heads/pull-conflict || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -B \
    pull-elsewhere-build "$base" || return 1
  printf 'pull elsewhere remote\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/pull-elsewhere.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    pull-elsewhere.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" pull-elsewhere-remote \
    '2001-06-24T00:00:00+0000' || return 1
  pull_elsewhere_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -qf -- \
    -push-option HEAD:refs/heads/pull-elsewhere-source || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -f main ||
    return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -D \
    pull-elsewhere-build >/dev/null || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" fetch -q origin || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -f \
    pull-upstream "$base" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/pull-upstream pull-upstream >/dev/null || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -f \
    pull-pushremote "$base" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.pull-pushremote.pushRemote origin || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -f \
    pull-elsewhere "$base" || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -B \
    pull-rebase "$base" || return 1
  printf 'pull rebase local\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/pull-rebase-local.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    pull-rebase-local.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" pull-rebase-local \
    '2001-06-25T00:00:00+0000' || return 1
  pull_rebase_old_local_tip=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/pull-rebase pull-rebase >/dev/null || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -B \
    pull-refusal "$base" || return 1
  printf 'pull refusal local\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/pull-refusal-local.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    pull-refusal-local.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" pull-refusal-local \
    '2001-06-26T00:00:00+0000' || return 1
  pull_refusal_local_tip=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/pull-refusal pull-refusal >/dev/null || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -B \
    pull-conflict "$base" || return 1
  printf 'pull conflict local\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/pull-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    pull-conflict.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" pull-conflict-local \
    '2001-06-27T00:00:00+0000' || return 1
  pull_conflict_local_tip=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/pull-conflict pull-conflict >/dev/null || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.pull-conflict.rebase false || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q \
    pull-pushremote || return 1
  porcelain_pull_clean
}

prepare_porcelain_push_fixture() {
  local tree
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -f main ||
    return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
    "$merge_main_hash" || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    push-current "$merge_main_hash" || return 1
  printf 'push current value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/push-current.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- push-current.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" push-current \
    '2001-06-10T00:00:00+0000' || return 1
  push_current_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
    branch.push-current.pushRemote origin || return 1
  if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --get \
       branch.push-current.merge >/dev/null 2>&1; then
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch --unset-upstream \
      push-current >/dev/null || return 1
  fi
  GIT_COMMITTER_DATE='2001-06-10T01:00:00+0000' \
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" tag -a push-one \
      -m push-one "$push_current_tip" || return 1
  GIT_COMMITTER_DATE='2001-06-10T02:00:00+0000' \
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" tag -a push-follow-tag \
      -m push-follow "$push_current_tip" || return 1
  push_one_tag_object=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse refs/tags/push-one) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    push-upstream "$merge_main_hash" || return 1
  printf 'push upstream value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/push-upstream.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- push-upstream.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" push-upstream \
    '2001-06-11T00:00:00+0000' || return 1
  push_upstream_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    "$merge_main_hash":refs/heads/push-upstream || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/remotes/origin/push-upstream "$merge_main_hash" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
    --set-upstream-to=origin/push-upstream push-upstream >/dev/null ||
    return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    push-other-source "$merge_main_hash" || return 1
  printf 'push other value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/push-other.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- push-other.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" push-other \
    '2001-06-12T00:00:00+0000' || return 1
  push_other_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  GIT_COMMITTER_DATE='2001-06-12T01:00:00+0000' \
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" tag -a push-all-extra \
      -m push-all "$push_other_tip" || return 1
  push_all_tag_object=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse refs/tags/push-all-extra) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    push-match "$merge_main_hash" || return 1
  printf 'push matching value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/push-match.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- push-match.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" push-match \
    '2001-06-13T00:00:00+0000' || return 1
  push_match_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  # Origin deliberately contains divergent branches for rejection coverage.
  # Seed the clean auxiliary remote so matching tests only matching semantics.
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q push-target \
    "$merge_main_hash":refs/heads/push-match || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    push-force "$merge_main_hash" || return 1
  printf 'push force local value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/push-force.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- push-force.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" push-force-local \
    '2001-06-14T00:00:00+0000' || return 1
  push_force_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  tree=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse "$merge_main_hash^{tree}") || return 1
  push_force_remote_tip=$(printf 'push force remote\n' | \
    GIT_AUTHOR_DATE='2001-06-14T01:00:00+0000' \
    GIT_COMMITTER_DATE='2001-06-14T01:00:00+0000' \
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" commit-tree \
      "$tree" -p "$merge_main_hash") || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/lem-yath-test/push-force-remote "$push_force_remote_tip" || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
    refs/lem-yath-test/push-force-remote:refs/heads/push-force || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref -d \
    refs/lem-yath-test/push-force-remote || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
    refs/remotes/origin/push-force "$push_force_remote_tip" || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" notes --ref=review add -f \
    -m 'push review note' "$merge_main_hash" || return 1
  push_notes_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse refs/notes/review) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q push-current ||
    return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --quiet || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" diff --cached --quiet ||
    return 1
  porcelain_branch_current_is push-current
}

prepare_porcelain_revert_fixture() {
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q main || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
    "$merge_main_hash" || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-noedit "$merge_main_hash" || return 1
  printf 'revert no-edit value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-noedit.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- revert-noedit.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-noedit \
    '2001-05-01T00:00:00+0000' || return 1
  revert_noedit_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-edit "$merge_main_hash" || return 1
  printf 'revert edit value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-edit.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- revert-edit.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-edit \
    '2001-05-02T00:00:00+0000' || return 1
  revert_edit_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-nocommit "$merge_main_hash" || return 1
  printf 'revert no-commit value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-nocommit.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- revert-nocommit.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-nocommit \
    '2001-05-03T00:00:00+0000' || return 1
  revert_nocommit_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-multi "$merge_main_hash" || return 1
  printf 'revert multi a\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-multi-a.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- revert-multi-a.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-multi-a \
    '2001-05-04T00:00:00+0000' || return 1
  revert_multi_a_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  printf 'revert multi b\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-multi-b.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- revert-multi-b.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-multi-b \
    '2001-05-05T00:00:00+0000' || return 1
  revert_multi_b_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-merge-side "$merge_main_hash" || return 1
  printf 'revert merge side\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-merge-side.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    revert-merge-side.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-merge-side \
    '2001-05-06T00:00:00+0000' || return 1
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-merge "$merge_main_hash" || return 1
  printf 'revert merge main\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-merge-main.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    revert-merge-main.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-merge-main \
    '2001-05-07T00:00:00+0000' || return 1
  GIT_AUTHOR_DATE='2001-05-08T00:00:00+0000' \
    GIT_COMMITTER_DATE='2001-05-08T00:00:00+0000' \
    "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" merge -q --no-ff \
      -m revert-merge-commit revert-merge-side || return 1
  revert_merge_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-conflict "$merge_main_hash" || return 1
  printf 'revert target value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    merge-conflict.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-conflict-target \
    '2001-05-09T00:00:00+0000' || return 1
  revert_conflict_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1
  printf 'revert later value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    merge-conflict.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-conflict-later \
    '2001-05-10T00:00:00+0000' || return 1
  revert_conflict_tip=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
    rev-parse HEAD) || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -b \
    revert-skip "$merge_main_hash" || return 1
  printf 'skip target value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    merge-conflict.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-skip-conflict \
    '2001-05-11T00:00:00+0000' || return 1
  revert_skip_conflict_hash=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1
  printf 'revert skip value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/revert-skip.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- revert-skip.txt ||
    return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-skip-clean \
    '2001-05-12T00:00:00+0000' || return 1
  revert_skip_clean_hash=$("$git_bin" \
    -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD) || return 1
  printf 'skip later value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- \
    merge-conflict.txt || return 1
  git_commit "$LEM_YATH_VCS_PORCELAIN_ROOT" revert-skip-later \
    '2001-05-13T00:00:00+0000' || return 1

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q revert-noedit
}

enter_prompt_value() {
  local session=$1 value=$2 index
  for index in $(seq 1 80); do
    lem_keys "$session" BSpace
  done
  tmux_cmd send-keys -t "$session" -l -- "$value"
  send_keys "$session" Enter
}

enter_completion_prompt_value() {
  local session=$1 value=$2 prompt=$3 index
  for index in $(seq 1 80); do
    lem_keys "$session" BSpace
  done
  tmux_cmd send-keys -t "$session" -l -- "$value"
  sleep 0.5
  send_keys "$session" Enter
  sleep 0.25
  if lem_wait_for "$session" "$prompt" 1 >/dev/null 2>&1; then
    send_keys "$session" Enter
  fi
}

enter_atomic_prompt_value() {
  local session=$1 value=$2
  # Avoid racing literal input against queued editing keys.  The fixture's F12
  # command loads the exact value into Lem's kill ring, so one yank replaces
  # the prompt atomically even when the value contains spaces or metacharacters.
  printf '%s' "$value" >"$LEM_YATH_VCS_PROMPT_INPUT"
  send_keys "$session" C-a C-k F12 C-y
  sleep 0.5
  send_keys "$session" Enter
  sleep 0.25
}

submit_atomic_prompt_value() {
  local session=$1 value=$2
  # A completion popup consumes the first Return and leaves the prompt active.
  # Submit through one fixture command so a later Return cannot escape into the
  # synchronous VCS action after the prompt has already closed.
  printf '%s' "$value" >"$LEM_YATH_VCS_PROMPT_INPUT"
  send_keys "$session" F4
  sleep 0.25
}

enter_atomic_completion_prompt_value() {
  local session=$1 value=$2 prompt=$3
  # Clear with two settled editing events before sending the literal value.
  # A second Enter accepts arbitrary input when completion first leaves the
  # prompt active rather than choosing a displayed candidate.
  send_keys "$session" C-a C-k
  sleep 0.5
  tmux_cmd send-keys -t "$session" -l -- "$value"
  sleep 0.5
  send_keys "$session" Enter
  sleep 0.25
  if lem_wait_for "$session" "$prompt" 1 >/dev/null 2>&1; then
    send_keys "$session" Enter
  fi
}

enter_path_prompt_value() {
  local session=$1 value=$2 prompt=$3
  # Directory completion can rewrite its buffer while a burst of Backspace
  # and literal key events is still queued.  Load the exact value into Lem's
  # kill ring, then exercise the editor's ordinary prompt yank path atomically.
  printf '%s' "$value" >"$LEM_YATH_VCS_PROMPT_INPUT"
  send_keys "$session" C-a C-k
  send_keys "$session" F12
  send_keys "$session" C-y
  sleep 0.5
  send_keys "$session" Enter
  sleep 0.25
  if lem_wait_for "$session" "$prompt" 1 >/dev/null 2>&1; then
    send_keys "$session" Enter
  fi
}

enter_completion_prompt_value_until() {
  local session=$1 value=$2 next_prompt=$3 index
  for index in $(seq 1 80); do
    lem_keys "$session" BSpace
  done
  tmux_cmd send-keys -t "$session" -l -- "$value"
  sleep 0.5
  for index in 1 2 3; do
    send_keys "$session" Enter
    if lem_wait_for "$session" "$next_prompt" 2 >/dev/null 2>&1; then
      return 0
    fi
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

if [[ ${LEM_YATH_VCS_CHERRY_REGION_ONLY:-0} != 1 ]]; then
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
   grep -q '^RELOAD same=yes find=1 post=1 save=1 change=1 kill=1 global=0 source=1 directory=0 root-marker=1 todo-hook=1 bisect-hook=1 bisect=yes fetch=yes pull=yes log=yes reset=yes merge=yes revert=yes branch=yes worktree=yes push=yes stash=yes remote=yes submodule=yes subtree=yes smart=yes git=yes jj=yes time=yes jj-refresh=yes jj-quit=yes older=yes newer=yes nth=yes fuzzy=yes short=yes full=yes blame=yes blame-quit=yes p=yes n=yes t=yes quit=yes$' \
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
legit_state=$(latest_report '^LEGIT phase=git ')
if [[ "$legit_state" == *'todos=yes todo-count=yes todo-properties=yes todo-hook=1 todo-bottom=yes '* ]]; then
  pass legit-todo-section 'Legit rendered the configured Magit-Todos keywords with actions'
else
  fail legit-todo-section "unexpected Legit TODO state: $legit_state" \
    "$git_session"
fi

todo_preview_before=$(report_count '^TODO-PREVIEW ')
send_keys "$git_session" C-c t
if wait_report_count '^TODO-PREVIEW ' "$((todo_preview_before + 1))" &&
   [[ $(latest_report '^TODO-PREVIEW ') == \
      'TODO-PREVIEW row=yes move=yes visit=yes file=todos.org line=1 text=yes' ]]; then
  pass legit-todo-preview 'a TODO row resolves to its exact tracked source line'
else
  fail legit-todo-preview 'TODO row preview metadata did not resolve exactly' \
    "$git_session"
fi

todo_list_before=$(report_count '^TODO-LIST ')
send_keys "$git_session" C-c P Enter C-c Q
if wait_report_count '^TODO-LIST ' "$((todo_list_before + 1))" &&
   [[ $(latest_report '^TODO-LIST ') == \
      'TODO-LIST active=yes root=yes top=yes hidden=no grouped=no large=no title=yes latest=no' ]]; then
  pass legit-todo-dedicated-list \
    'Return on the TODO heading opened the expanded dedicated list'
else
  fail legit-todo-dedicated-list \
    'the TODO heading did not open the dedicated 10x-threshold list' \
    "$git_session"
fi

send_keys "$git_session" g C-c Q
if wait_report_count '^TODO-LIST ' "$((todo_list_before + 2))" &&
   [[ $(latest_report '^TODO-LIST ') == \
      'TODO-LIST active=yes root=yes top=yes hidden=no grouped=no large=no title=yes latest=no' ]]; then
  pass legit-todo-dedicated-refresh 'g refreshed the dedicated TODO list in place'
else
  fail legit-todo-dedicated-refresh \
    'g left or corrupted the dedicated TODO list' "$git_session"
fi

send_keys "$git_session" q C-c Q
if wait_report_count '^TODO-LIST ' "$((todo_list_before + 3))" &&
   [[ $(latest_report '^TODO-LIST ') == \
      'TODO-LIST active=yes root=no top=no hidden=no grouped=no large=no title=no latest=yes' ]]; then
  pass legit-todo-dedicated-quit \
    'q returned from the TODO list to ordinary Git status for the same repository'
else
  fail legit-todo-dedicated-quit \
    'q retained dedicated-list state or did not restore Git status' "$git_session"
fi

todo_sections_before=$(report_count '^TODO-SECTIONS ')
send_keys "$git_session" C-c T
if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 1))" &&
   [[ $(latest_report '^TODO-SECTIONS ') == *\
'top=yes top-hidden=yes grouped=no keyword-hidden=no path-hidden=no row-hidden=yes branch=no '* ]]; then
  pass legit-todo-auto-collapse 'the 17-item TODO section initially collapsed above the exact limit of 10'
else
  fail legit-todo-auto-collapse 'the initial TODO section visibility was wrong' \
    "$git_session"
fi

send_keys "$git_session" C-c P Tab C-c T
if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 2))" &&
   [[ $(latest_report '^TODO-SECTIONS ') == *\
'top=yes top-hidden=no grouped=no keyword-hidden=no path-hidden=no row-hidden=no branch=no '* ]]; then
  pass legit-todo-tab-expand 'Tab expanded the TODO heading and exposed its actionable rows'
else
  fail legit-todo-tab-expand 'Tab did not expand the TODO heading physically' \
    "$git_session"
fi

send_keys "$git_session" g
wait_legit "$git_session" git || true
send_keys "$git_session" C-c T
if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 3))" &&
   [[ $(latest_report '^TODO-SECTIONS ') == *\
'top=yes top-hidden=no grouped=no keyword-hidden=no path-hidden=no row-hidden=no branch=no '* ]]; then
  pass legit-todo-refresh-visibility 'refresh preserved the explicitly expanded section'
else
  fail legit-todo-refresh-visibility 'refresh lost the TODO section visibility cache' \
    "$git_session"
fi

printf '%s\n' \
  'TODO: grouped extra one' 'TODO: grouped extra two' \
  'TODO: grouped extra three' 'TODO: grouped extra four' \
  >>"$LEM_YATH_VCS_GIT_ROOT/nested/docs/keywords.txt"
send_keys "$git_session" g
wait_legit "$git_session" git || true
send_keys "$git_session" C-c T
if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 4))" &&
   [[ $(latest_report '^TODO-SECTIONS ') == *\
'top=yes top-hidden=no grouped=yes keyword-hidden=yes path-hidden=yes row-hidden=yes branch=yes '* ]]; then
  pass legit-todo-auto-group '21 items grouped by keyword then filename with depth-sensitive collapse'
else
  fail legit-todo-auto-group 'the 21-item grouping hierarchy or visibility was wrong' \
    "$git_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_GIT_ROOT" restore -- nested/docs/keywords.txt
printf 'TODO: branch-only\n' \
  >>"$LEM_YATH_VCS_GIT_ROOT/nested/docs/keywords.txt"
send_keys "$git_session" g
wait_legit "$git_session" git || true
send_keys "$git_session" C-c T
if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 5))" &&
   [[ $(latest_report '^TODO-SECTIONS ') == *\
'branch=yes branch-hidden=no branch-row=yes branch-row-hidden=no policy=branch base=automatic' ]]; then
  pass legit-todo-branch-diff 'the non-main branch list showed only added-line TODOs against main'
else
  fail legit-todo-branch-diff 'the branch-diff TODO section was absent or folded incorrectly' \
    "$git_session"
fi

send_keys "$git_session" C-c P B
if lem_wait_for "$git_session" 'Refname:' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$git_session" -l -- main
  send_keys "$git_session" Enter
  wait_legit "$git_session" git || true
  send_keys "$git_session" C-c T
  if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 6))" &&
     [[ $(latest_report '^TODO-SECTIONS ') == *\
'branch=yes branch-hidden=no branch-row=yes branch-row-hidden=no policy=branch base=main' ]]; then
    pass legit-todo-branch-base 'B selected and retained a validated branch comparison ref'
  else
    fail legit-todo-branch-base 'B did not apply the selected TODO comparison ref' \
      "$git_session"
  fi
else
  fail legit-todo-branch-base 'B did not open the TODO ref prompt' \
    "$git_session"
fi

send_keys "$git_session" C-c P B
if lem_wait_for "$git_session" 'Refname:' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$git_session" -l -- --missing-ref
  send_keys "$git_session" Enter
  if lem_wait_for "$git_session" 'Not a commit ref: --missing-ref' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$git_session" C-c T
    if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 7))" &&
       [[ $(latest_report '^TODO-SECTIONS ') == *\
'policy=branch base=main' ]]; then
      pass legit-todo-branch-base-invalid \
        'B rejected an option-shaped invalid ref without changing the baseline'
    else
      fail legit-todo-branch-base-invalid \
        'an invalid B ref changed the retained TODO baseline' "$git_session"
    fi
  else
    fail legit-todo-branch-base-invalid \
      'B did not reject an option-shaped invalid ref' "$git_session"
  fi
else
  fail legit-todo-branch-base-invalid \
    'B did not reopen the TODO ref prompt' "$git_session"
fi

send_keys "$git_session" C-c P B
if lem_wait_for "$git_session" 'Refname:' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$git_session" C-g C-c T
  if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 8))" &&
     [[ $(latest_report '^TODO-SECTIONS ') == *\
'policy=branch base=main' ]]; then
    pass legit-todo-branch-base-cancel \
      'cancelling B retained the previous TODO comparison ref'
  else
    fail legit-todo-branch-base-cancel \
      'cancelling B changed the retained TODO baseline' "$git_session"
  fi
else
  fail legit-todo-branch-base-cancel \
    'B did not open the TODO ref prompt for cancellation' "$git_session"
fi

send_keys "$git_session" C-c P b
wait_legit "$git_session" git || true
send_keys "$git_session" C-c T
if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 9))" &&
   [[ $(latest_report '^TODO-SECTIONS ') == *\
'branch=no branch-hidden=no branch-row=yes branch-row-hidden=no policy=nil base=main' ]]; then
  pass legit-todo-branch-toggle-off 'b hid branch TODOs from a TODO section'
else
  fail legit-todo-branch-toggle-off 'b did not disable branch TODO presentation' \
    "$git_session"
fi

send_keys "$git_session" C-c P b
wait_legit "$git_session" git || true
send_keys "$git_session" C-c T
if wait_report_count '^TODO-SECTIONS ' "$((todo_sections_before + 10))" &&
   [[ $(latest_report '^TODO-SECTIONS ') == *\
'branch=yes branch-hidden=no branch-row=yes branch-row-hidden=no policy=t base=main' ]]; then
  pass legit-todo-branch-toggle-on 'a second b forced branch TODOs back on'
else
  fail legit-todo-branch-toggle-on 'b did not re-enable branch TODO presentation' \
    "$git_session"
fi

dedicated_extra=0
while ((dedicated_extra < 183)); do
  printf 'TODO: dedicated list threshold %03d\n' "$dedicated_extra"
  dedicated_extra=$((dedicated_extra + 1))
done >>"$LEM_YATH_VCS_GIT_ROOT/nested/docs/keywords.txt"
todo_list_large_before=$(report_count '^TODO-LIST ')
send_keys "$git_session" g C-c P Enter C-c Q
if wait_report_count '^TODO-LIST ' "$((todo_list_large_before + 1))" &&
   [[ $(latest_report '^TODO-LIST ') == \
      'TODO-LIST active=yes root=yes top=yes hidden=yes grouped=yes large=yes title=yes latest=no' ]]; then
  pass legit-todo-dedicated-thresholds \
    'the dedicated list retained 201 items and applied its exact 100/200 thresholds'
else
  fail legit-todo-dedicated-thresholds \
    'the dedicated list truncated before or missed its tenfold thresholds' \
    "$git_session"
fi
send_keys "$git_session" q C-c Q
if wait_report_count '^TODO-LIST ' "$((todo_list_large_before + 2))" &&
   [[ $(latest_report '^TODO-LIST ') == \
      'TODO-LIST active=yes root=no top=no hidden=no grouped=yes large=no title=no latest=yes' ]]; then
  pass legit-todo-dedicated-large-quit \
    'q restored ordinary capped status after the large dedicated list'
else
  fail legit-todo-dedicated-large-quit \
    'q did not restore ordinary status after the large dedicated list' \
    "$git_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_GIT_ROOT" restore -- nested/docs/keywords.txt
send_keys "$git_session" g
wait_legit "$git_session" git || true

status_position_before=$(report_count '^STATUS-CONTEXT ')
send_keys "$git_session" C-c O
wait_report_count '^STATUS-CONTEXT ' "$((status_position_before + 1))" || true
status_position_count=$((status_position_before + 1))
if [[ $(latest_report '^STATUS-CONTEXT ') == \
      'STATUS-CONTEXT focus=no todo=no' ]]; then
  send_keys "$git_session" C-x o C-c O
  status_position_count=$((status_position_count + 1))
  wait_report_count '^STATUS-CONTEXT ' "$status_position_count" || true
fi
send_keys "$git_session" g g C-c O
status_position_count=$((status_position_count + 1))
if wait_report_count '^STATUS-CONTEXT ' "$status_position_count" &&
   [[ $(latest_report '^STATUS-CONTEXT ') == \
      'STATUS-CONTEXT focus=yes todo=no' ]]; then
  send_keys "$git_session" b
fi
if lem_wait_for "$git_session" '\[Branch\]' "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-todo-branch-delegation \
    'b retained the ordinary branch dispatch outside TODO sections'
  send_keys "$git_session" q
else
  fail legit-todo-branch-delegation \
    'b did not delegate to branch dispatch outside TODO sections' "$git_session"
fi

send_keys "$git_session" C-c O
status_position_count=$((status_position_count + 1))
if wait_report_count '^STATUS-CONTEXT ' "$status_position_count" &&
   [[ $(latest_report '^STATUS-CONTEXT ') == \
      'STATUS-CONTEXT focus=yes todo=no' ]]; then
  send_keys "$git_session" B
fi
if lem_wait_for "$git_session" '\[Bisect\]' "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-todo-bisect-delegation \
    'B retained the ordinary bisect dispatch outside TODO sections'
  send_keys "$git_session" q
else
  fail legit-todo-bisect-delegation \
    'B did not delegate to bisect dispatch outside TODO sections' "$git_session"
fi
send_keys "$git_session" q F6

if [[ ${LEM_YATH_VCS_SMOKE_ONLY:-0} == 1 ]]; then
  printf '\n'
  if ((failed)); then
    printf 'VCS SMOKE TEST FAILED\n'
    exit 1
  fi
  printf 'VCS SMOKE TEST PASSED\n'
  exit 0
fi

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

# Magit's default file dispatch is C-c M-g, then b.  Make a real unsaved edit
# first: the blame must consume the live Lem buffer through --contents -, keep
# ordinary j/k available, and return through a real commit child lifecycle.
lem_keys "$git_session" i
tmux_cmd send-keys -t "$git_session" -l -- ';; UNSAVED-BLAME- '
# The first Escape dismisses any completion popup; the second is the actual
# Evil insert-to-normal transition when completion was visible.  Keep a real
# event boundary between them and verify the state before exercising Magit.
send_keys "$git_session" Escape Escape
lem_wait_for "$git_session" 'NORMAL' "$WAIT_TIMEOUT" >/dev/null ||
  fail git-blame-normal-state 'the unsaved edit did not leave Insert state' \
    "$git_session"
send_keys "$git_session" C-c M-g b
if lem_wait_for "$git_session" 'Blame:' "$WAIT_TIMEOUT" >/dev/null &&
   lem_wait_for "$git_session" 'UNSAVED-BLAME-' "$WAIT_TIMEOUT" >/dev/null &&
   press_report "$git_session" F5 '^BLAME ' &&
   [[ $(latest_report '^BLAME ') == \
      'BLAME kind=blame blame=1 commit=0 zero=yes external=yes live=yes origin=yes origin-point=yes read-only=yes copied=no show=no source=no' ]]; then
  pass git-blame-live-buffer 'C-c M-g b blamed the real unsaved Lem contents at point'
else
  fail git-blame-live-buffer 'file dispatch did not produce live-buffer blame' \
    "$git_session"
fi

send_keys "$git_session" g j
if press_report "$git_session" F5 '^BLAME ' &&
   [[ $(latest_report '^BLAME ') == \
      'BLAME kind=blame blame=1 commit=0 zero=no external=no live=yes origin=yes origin-point=yes read-only=yes copied=no show=no source=no' ]]; then
  pass git-blame-next-chunk 'g j moved from the unsaved chunk to committed history'
else
  fail git-blame-next-chunk 'g j did not select the next distinct blame chunk' \
    "$git_session"
fi

send_keys "$git_session" M-w
if press_report "$git_session" F5 '^BLAME ' &&
   [[ $(latest_report '^BLAME ') == \
      'BLAME kind=blame blame=1 commit=0 zero=no external=no live=yes origin=yes origin-point=yes read-only=yes copied=yes show=no source=no' ]]; then
  pass git-blame-copy 'M-w copied the selected chunk full hash'
else
  fail git-blame-copy 'M-w did not copy the current blame hash' "$git_session"
fi

send_keys "$git_session" Enter
if lem_wait_for "$git_session" 'commit ' "$WAIT_TIMEOUT" >/dev/null &&
   press_report "$git_session" F5 '^BLAME ' &&
   [[ $(latest_report '^BLAME ') == \
      'BLAME kind=commit blame=1 commit=1 zero=no external=no live=no origin=yes origin-point=yes read-only=yes copied=yes show=yes source=no' ]]; then
  pass git-blame-show-commit 'RET opened the exact committed chunk in a read-only child'
else
  fail git-blame-show-commit 'RET did not open the selected blame commit' \
    "$git_session"
fi

send_keys "$git_session" q g k
if press_report "$git_session" F5 '^BLAME ' &&
   [[ $(latest_report '^BLAME ') == \
      'BLAME kind=blame blame=1 commit=0 zero=yes external=yes live=yes origin=yes origin-point=yes read-only=yes copied=no show=no source=no' ]]; then
  pass git-blame-previous-chunk 'q and g k returned from the commit to the prior unsaved chunk'
else
  fail git-blame-previous-chunk 'commit return or previous-chunk navigation failed' \
    "$git_session"
fi

send_keys "$git_session" q
if press_report "$git_session" F5 '^BLAME ' &&
   [[ $(latest_report '^BLAME ') == \
      'BLAME kind=source blame=0 commit=0 zero=no external=no live=yes origin=no origin-point=no read-only=no copied=no show=no source=yes' ]]; then
  pass git-blame-quit 'q restored the live modified source and removed blame children'
else
  fail git-blame-quit 'q did not restore the exact live source lifecycle' \
    "$git_session"
fi

send_keys "$git_session" u F6
sleep 1
if press_report "$git_session" F7 '^SOURCE ' &&
   [[ $(latest_report '^SOURCE ') == \
      'SOURCE current=yes live=yes text=yes point=yes mode=yes modified=yes filename=yes timemachine-live=0' ]]; then
  pass git-blame-source-undo 'undo restored the pre-blame source baseline'
else
  fail git-blame-source-undo 'source state did not survive blame and undo exactly' \
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

extra_before=$(report_count '^TIMEMACHINE-EXTRA ')
send_keys "$git_session" g t y C-c h
if wait_report_count '^TIMEMACHINE-EXTRA ' "$((extra_before + 1))" &&
   [[ $(latest_report '^TIMEMACHINE-EXTRA ') == \
      'TIMEMACHINE-EXTRA history=yes blame=no parent=no short=yes full=no read-only=yes author=no date=no content=yes blame-live=0' ]]; then
  pass timemachine-copy-short 'gty copied the pinned 12-character revision hash'
else
  fail timemachine-copy-short 'gty did not copy the displayed abbreviated hash' \
    "$git_session"
fi

extra_before=$(report_count '^TIMEMACHINE-EXTRA ')
send_keys "$git_session" g t Y C-c h
if wait_report_count '^TIMEMACHINE-EXTRA ' "$((extra_before + 1))" &&
   [[ $(latest_report '^TIMEMACHINE-EXTRA ') == \
      'TIMEMACHINE-EXTRA history=yes blame=no parent=no short=no full=yes read-only=yes author=no date=no content=yes blame-live=0' ]]; then
  pass timemachine-copy-full 'gtY copied the complete displayed revision hash'
else
  fail timemachine-copy-full 'gtY did not copy the displayed full hash' \
    "$git_session"
fi

send_keys "$git_session" g t b
if lem_wait_for "$git_session" 'Lem Yath Test' "$WAIT_TIMEOUT" >/dev/null; then
  extra_before=$(report_count '^TIMEMACHINE-EXTRA ')
  send_keys "$git_session" C-c h
  if wait_report_count '^TIMEMACHINE-EXTRA ' "$((extra_before + 1))" &&
     [[ $(latest_report '^TIMEMACHINE-EXTRA ') == \
        'TIMEMACHINE-EXTRA history=no blame=yes parent=yes short=no full=yes read-only=yes author=yes date=yes content=yes blame-live=1' ]]; then
    pass timemachine-blame 'gtb opened revision-specific read-only blame'
  else
    fail timemachine-blame 'the blame view lost its revision, parent, or content' \
      "$git_session"
  fi
else
  fail timemachine-blame 'gtb did not render the selected revision blame' \
    "$git_session"
fi

extra_before=$(report_count '^TIMEMACHINE-EXTRA ')
send_keys "$git_session" q C-c h
if wait_report_count '^TIMEMACHINE-EXTRA ' "$((extra_before + 1))" &&
   [[ $(latest_report '^TIMEMACHINE-EXTRA ') == \
      'TIMEMACHINE-EXTRA history=yes blame=no parent=no short=no full=yes read-only=yes author=no date=no content=yes blame-live=0' ]]; then
  pass timemachine-blame-quit 'blame q restored the unchanged history view and cleaned up'
else
  fail timemachine-blame-quit 'blame q did not restore and clean the history view' \
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
lem_stop "$git_session"
fi

porcelain_session="lem-yath-vcs-porcelain-$id"
if start_phase porcelain "$LEM_YATH_VCS_PORCELAIN_FILE" \
  "$porcelain_session"; then
  pass porcelain-boot 'configured wrapper opened the isolated porcelain repository'
else
  fail porcelain-boot 'porcelain fixture did not become ready' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" Space g g
if wait_legit "$porcelain_session" porcelain; then
  pass porcelain-status 'Legit opened the real mutating Git fixture'
else
  fail porcelain-status 'Legit did not open the porcelain fixture' \
    "$porcelain_session"
fi

if [[ ${LEM_YATH_VCS_CHERRY_REGION_ONLY:-0} == 1 ]]; then
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard HEAD
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" clean -q -fdx
  send_keys "$porcelain_session" Escape Space g G
  wait_legit "$porcelain_session" porcelain || true
else
send_keys "$porcelain_session" l
if lem_wait_for "$porcelain_session" 'HEAD reflog' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass legit-log-popup 'l opened the complete visible log argument/action popup'
else
  fail legit-log-popup 'l did not open the configured log popup' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" - n
send_keys "$porcelain_session" - n
if lem_wait_for "$porcelain_session" 'Limit number of commits:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" 1
fi
send_keys "$porcelain_session" - g
send_keys "$porcelain_session" - c
send_keys "$porcelain_session" - h
send_keys "$porcelain_session" - p
send_keys "$porcelain_session" - s
send_keys "$porcelain_session" l
if lem_wait_for "$porcelain_session" 'porcelain-initial' "$WAIT_TIMEOUT" \
     >/dev/null &&
   lem_wait_for "$porcelain_session" 'Author: Lem Yath Test' "$WAIT_TIMEOUT" \
     >/dev/null &&
   lem_wait_for "$porcelain_session" 'tracked auxiliary file' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass legit-log-current \
    'l l rendered the bounded decorated graph with headers, patch, stat, and preview'
else
  fail legit-log-current 'the configured current log did not render its options' \
    "$porcelain_session"
fi

log_actions_visible=1
send_keys "$porcelain_session" A
lem_wait_for "$porcelain_session" '\[Apply\]' \
  "$WAIT_TIMEOUT" >/dev/null || log_actions_visible=0
send_keys "$porcelain_session" q
log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=yes\ status=no\ state=yes\ hash=yes\ line=*porcelain-initial*\ offset=0 ]]; then
  pass legit-log-action-cancel \
    'canceling a log action retained the configured log and commit anchor'
else
  fail legit-log-action-cancel \
    'canceling a log action lost its log state or selected commit' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" b
lem_wait_for "$porcelain_session" '\[Branch\]' \
  "$WAIT_TIMEOUT" >/dev/null || log_actions_visible=0
send_keys "$porcelain_session" q
send_keys "$porcelain_session" f
lem_wait_for "$porcelain_session" '\[Fetch\]' \
  "$WAIT_TIMEOUT" >/dev/null || log_actions_visible=0
send_keys "$porcelain_session" q
send_keys "$porcelain_session" F
lem_wait_for "$porcelain_session" '\[Pull\]' \
  "$WAIT_TIMEOUT" >/dev/null || log_actions_visible=0
send_keys "$porcelain_session" q
send_keys "$porcelain_session" B
lem_wait_for "$porcelain_session" '\[Bisect\]' \
  "$WAIT_TIMEOUT" >/dev/null || log_actions_visible=0
send_keys "$porcelain_session" q
if ((log_actions_visible)); then
  pass legit-log-actions \
    'log A/b/f/F/B opened the inherited Magit actions instead of pagination'
else
  fail legit-log-actions \
    'a log action key was still shadowed by custom pagination' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" c a
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" C-c C-k
fi
if lem_wait_for "$porcelain_session" 'Abort amend?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=yes\ status=no\ state=yes\ hash=yes\ line=*porcelain-initial*\ offset=0 ]]; then
  pass legit-log-amend-abort \
    'log c a abort returned to the configured log and retained its commit anchor'
else
  fail legit-log-amend-abort \
    'log c a abort dropped to status or lost its configured log anchor' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" q c a
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" C-c C-k
fi
if lem_wait_for "$porcelain_session" 'Abort amend?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=no\ status=yes\ state=no\ hash=*\ offset=-1 ]]; then
  pass legit-log-message-origin-isolated \
    'a later status c a stayed in status instead of inheriting a stale log origin'
else
  fail legit-log-message-origin-isolated \
    'the aborted log editor leaked its origin into an unrelated status amend' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" l r
if lem_wait_for "$porcelain_session" 'Reflog main' "$WAIT_TIMEOUT" \
     >/dev/null &&
   lem_wait_for "$porcelain_session" 'porcelain-initial' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass legit-log-reflog 'l r rendered the bounded current-branch reflog'
else
  fail legit-log-reflog 'the current reflog action did not render' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" q l s
if lem_wait_for "$porcelain_session" 'Shortlog' "$WAIT_TIMEOUT" \
     >/dev/null; then
  send_keys "$porcelain_session" r
fi
if lem_wait_for "$porcelain_session" 'Shortlog range:' "$WAIT_TIMEOUT" \
     >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" HEAD 'Shortlog range:'
fi
if lem_wait_for "$porcelain_session" 'Lem Yath Test' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass legit-shortlog-range 'l s r summarized the validated revision range'
else
  fail legit-shortlog-range 'the visible shortlog range action did not render' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" q
if wait_legit "$porcelain_session" porcelain; then
  pass legit-log-quit 'q returned from log-family views to live Legit status'
else
  fail legit-log-quit 'log-family q did not restore Legit status' \
    "$porcelain_session"
fi

region_before=$(report_count '^PORCELAIN-REGION ')
region_staged=0
send_keys "$porcelain_session" C-c w
if wait_report_count '^PORCELAIN-REGION ' "$((region_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-REGION ') == \
      'PORCELAIN-REGION staged=no line=yes mode=yes focused=yes' ]]; then
  send_keys "$porcelain_session" V j s
  if wait_until "$WAIT_TIMEOUT" porcelain_first_region_only; then
    pass legit-stage-region \
      'Visual-line s staged one replacement without its nearby hunk change'
    region_staged=1
  else
    fail legit-stage-region \
      'Visual-line s did not stage exactly the selected replacement' \
      "$porcelain_session"
  fi
else
  fail legit-stage-region \
    'could not focus the first replacement in the real unstaged diff' \
    "$porcelain_session"
fi

region_before=$(report_count '^PORCELAIN-REGION ')
if [ "$region_staged" = 1 ]; then
  send_keys "$porcelain_session" C-c W
fi
if [ "$region_staged" = 1 ] &&
   wait_report_count '^PORCELAIN-REGION ' "$((region_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-REGION ') == \
      'PORCELAIN-REGION staged=yes line=yes mode=yes focused=yes' ]]; then
  send_keys "$porcelain_session" V j u
fi
if [ "$region_staged" = 1 ] &&
   wait_until "$WAIT_TIMEOUT" porcelain_first_region_unstaged; then
  pass legit-unstage-region \
    'Visual-line u returned the selected replacement to the worktree'
else
  fail legit-unstage-region \
    'Visual-line u did not empty the index while retaining worktree changes' \
    "$porcelain_session"
fi

position_before=$(report_count '^PORCELAIN-POSITION ')
hunk_staged=0
send_keys "$porcelain_session" C-c d
if wait_report_count '^PORCELAIN-POSITION ' "$((position_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-POSITION ') == \
      'PORCELAIN-POSITION file=porcelain.txt row=yes diff=yes mode=yes focused=yes' ]]; then
  lem_keys "$porcelain_session" s
  if wait_until "$WAIT_TIMEOUT" porcelain_first_hunk_only; then
    pass legit-stage-hunk \
      'normal-state s retained whole-hunk staging beside region staging'
    hunk_staged=1
  else
    fail legit-stage-hunk 'diff-mode s did not stage exactly the selected hunk' \
      "$porcelain_session"
  fi
else
  fail legit-stage-hunk 'could not focus the first real Legit diff hunk' \
    "$porcelain_session"
fi

region_before=$(report_count '^PORCELAIN-REGION ')
region_unstaged=0
if [ "$hunk_staged" = 1 ]; then
  send_keys "$porcelain_session" C-c W
fi
if [ "$hunk_staged" = 1 ] &&
   wait_report_count '^PORCELAIN-REGION ' "$((region_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-REGION ') == \
      'PORCELAIN-REGION staged=yes line=yes mode=yes focused=yes' ]]; then
  send_keys "$porcelain_session" V j u
  if wait_until "$WAIT_TIMEOUT" porcelain_region_partially_unstaged; then
    pass legit-unstage-region-partial \
      'Visual-line u removed one replacement from a staged multi-change hunk'
    region_unstaged=1
  else
    fail legit-unstage-region-partial \
      'Visual-line u disturbed the wrong staged or unstaged lines' \
      "$porcelain_session"
  fi
else
  fail legit-unstage-region-partial \
    'could not focus the replacement in the real staged diff' \
    "$porcelain_session"
fi

position_before=$(report_count '^PORCELAIN-POSITION ')
if [ "$region_unstaged" = 1 ]; then
  send_keys "$porcelain_session" C-c e
fi
if [ "$region_unstaged" = 1 ] &&
   wait_report_count '^PORCELAIN-POSITION ' "$((position_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-POSITION ') == \
      'PORCELAIN-POSITION file=porcelain.txt row=yes diff=yes mode=yes focused=yes' ]]; then
  lem_keys "$porcelain_session" u
fi
if [ "$region_unstaged" = 1 ] &&
   wait_until "$WAIT_TIMEOUT" porcelain_index_empty; then
  pass legit-unstage-hunk \
    'normal-state u retained whole-hunk unstaging after a partial unstage'
else
  fail legit-unstage-hunk 'could not unstage the remaining cached hunk' \
    "$porcelain_session"
fi

region_before=$(report_count '^PORCELAIN-REGION ')
multi_hunk_staged=0
send_keys "$porcelain_session" C-c w
if wait_report_count '^PORCELAIN-REGION ' "$((region_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-REGION ') == \
      'PORCELAIN-REGION staged=no line=yes mode=yes focused=yes' ]]; then
  send_keys "$porcelain_session" V G s
  if wait_until "$WAIT_TIMEOUT" porcelain_all_hunks_staged; then
    pass legit-stage-region-multi \
      'one Visual selection staged changed lines across separated hunks'
    multi_hunk_staged=1
  else
    fail legit-stage-region-multi \
      'the spanning Visual selection did not assemble both hunks safely' \
      "$porcelain_session"
  fi
else
  fail legit-stage-region-multi \
    'could not focus the spanning unstaged selection' \
    "$porcelain_session"
fi

region_before=$(report_count '^PORCELAIN-REGION ')
if [ "$multi_hunk_staged" = 1 ]; then
  send_keys "$porcelain_session" C-c W
fi
if [ "$multi_hunk_staged" = 1 ] &&
   wait_report_count '^PORCELAIN-REGION ' "$((region_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-REGION ') == \
      'PORCELAIN-REGION staged=yes line=yes mode=yes focused=yes' ]]; then
  send_keys "$porcelain_session" V G u
fi
if [ "$multi_hunk_staged" = 1 ] &&
   wait_until "$WAIT_TIMEOUT" porcelain_first_region_unstaged; then
  pass legit-unstage-region-multi \
    'one Visual selection unstaged changed lines across separated hunks'
else
  fail legit-unstage-region-multi \
    'the spanning Visual unstage did not restore the clean index' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" C-c m s C-c a s
if wait_until "$WAIT_TIMEOUT" porcelain_all_staged; then
  pass legit-stage-files 'status-pane s staged tracked and untracked files'
else
  fail legit-stage-files 'status-pane staging did not produce the expected index' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" l l
if lem_wait_for "$porcelain_session" 'porcelain-initial' \
     "$WAIT_TIMEOUT" >/dev/null; then
  lem_keys "$porcelain_session" c c
fi
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  lem_keys "$porcelain_session" i
  tmux_cmd send-keys -t "$porcelain_session" -l -- \
    'porcelain commit from Lem'
  send_keys "$porcelain_session" Escape C-c C-c
  if wait_until "$WAIT_TIMEOUT" porcelain_subject_is \
       'porcelain commit from Lem'; then
    pass legit-commit \
      'log c c and C-c C-c created the staged commit from Vi state'
  else
    fail legit-commit 'the commit buffer did not create the expected commit' \
      "$porcelain_session"
  fi
else
  fail legit-commit "c c did not open Legit's commit-message buffer" \
    "$porcelain_session"
fi

log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=yes\ status=no\ state=yes\ hash=yes\ line=*porcelain-initial*\ offset=0 ]]; then
  pass legit-commit-log-refresh \
    'confirming log c c refreshed the log and retained its original commit anchor'
else
  fail legit-commit-log-refresh \
    'confirming log c c dropped to status or lost its original commit anchor' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" q
send_keys "$porcelain_session" p p
if lem_wait_for "$porcelain_session" 'Set push remote and push main there:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin \
    'Set push remote and push main there:'
fi
if lem_wait_for "$porcelain_session" \
     'Set origin as push remote and push main there' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_remote_matches_head; then
  pass legit-push \
    'Evil Collection p p configured and pushed the current branch to origin'
else
  fail legit-push 'p p did not configure and update the bare remote' \
    "$porcelain_session"
fi

fetch_original_head=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
  rev-parse HEAD)
if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" pull -q --ff-only &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" switch -qc fetch-topic &&
   printf 'fetch-only branch\n' \
     >"$LEM_YATH_VCS_PORCELAIN_PEER/fetch-topic.txt" &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- fetch-topic.txt &&
   git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" fetch-topic \
     '2001-01-04T12:00:00+0000' &&
   fetch_topic_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" \
     rev-parse HEAD) &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -qu origin fetch-topic &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" switch -qc tag-only &&
   printf 'tag-only history\n' \
     >"$LEM_YATH_VCS_PORCELAIN_PEER/tag-only.txt" &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- tag-only.txt &&
   git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" tag-only \
     '2001-01-04T13:00:00+0000' &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" tag fetch-tag &&
   fetch_tag_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" \
     rev-parse HEAD) &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -q origin fetch-tag &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" switch -q main &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
     refs/remotes/origin/stale "$fetch_original_head"; then
  send_keys "$porcelain_session" f
  if lem_wait_for "$porcelain_session" 'Fetch' "$WAIT_TIMEOUT" >/dev/null; then
    tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
    send_keys "$porcelain_session" p
    tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
    send_keys "$porcelain_session" t
    tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
    send_keys "$porcelain_session" F
    send_keys "$porcelain_session" u
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_fetch_complete; then
    pass legit-fetch \
      'f toggles prune/tags/force and fetches the current upstream without moving HEAD'
  else
    fail legit-fetch \
      'the upstream fetch lost options, refs, cleanliness, or the original HEAD' \
      "$porcelain_session"
  fi
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --unset-all \
    branch.main.pushRemote
  send_keys "$porcelain_session" f p
  if lem_wait_for "$porcelain_session" 'Set push remote and fetch' \
       "$WAIT_TIMEOUT" >/dev/null; then
    tmux_cmd send-keys -t "$porcelain_session" -l -- origin
    send_keys "$porcelain_session" Enter
  fi
  if lem_wait_for "$porcelain_session" 'Fetched from origin' \
       "$WAIT_TIMEOUT" >/dev/null &&
     [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
       config --get branch.main.pushRemote)" = origin ]; then
    pass legit-fetch-pushremote \
      'f p configured the missing branch push remote and fetched it'
  else
    fail legit-fetch-pushremote \
      'f p did not preserve Magit missing-push-remote configuration behavior' \
      "$porcelain_session"
  fi
  if "$git_bin" init --bare -q "$LEM_YATH_VCS_FETCH_REMOTE" &&
     "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" switch -qc \
       elsewhere-source main &&
     printf 'elsewhere-only history\n' \
       >"$LEM_YATH_VCS_PORCELAIN_PEER/elsewhere.txt" &&
     "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- elsewhere.txt &&
     git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" elsewhere-source \
       '2001-01-04T14:00:00+0000' &&
     fetch_elsewhere_hash=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" \
       rev-parse HEAD) &&
     "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -q \
       "$LEM_YATH_VCS_FETCH_REMOTE" HEAD:main &&
     "$git_bin" --git-dir="$LEM_YATH_VCS_FETCH_REMOTE" symbolic-ref \
       HEAD refs/heads/main &&
     "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" switch -q main; then
    send_keys "$porcelain_session" f e
    if lem_wait_for "$porcelain_session" 'Fetch remote:' \
         "$WAIT_TIMEOUT" >/dev/null; then
      tmux_cmd send-keys -t "$porcelain_session" -l -- \
        "$LEM_YATH_VCS_FETCH_REMOTE"
      send_keys "$porcelain_session" Enter
    fi
    if wait_until "$WAIT_TIMEOUT" porcelain_elsewhere_fetched; then
      pass legit-fetch-elsewhere \
        'f e fetched a direct-argv path containing a space and semicolon'
    else
      fail legit-fetch-elsewhere \
        'f e rejected or misparsed a valid metacharacter-bearing Git path' \
        "$porcelain_session"
    fi
  else
    fail legit-fetch-elsewhere \
      'could not prepare the metacharacter-bearing fetch remote' \
      "$porcelain_session"
  fi

  send_keys "$porcelain_session" f C
  if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" d
  fi
  if lem_wait_for "$porcelain_session" \
       'Description for main \(blank unsets\):' \
       "$WAIT_TIMEOUT" >/dev/null; then
    enter_atomic_prompt_value "$porcelain_session" \
      'configured through fetch'
  fi
  if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" q
  fi
  if lem_wait_for "$porcelain_session" '\[Fetch\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" q
  fi
  if [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --get \
       branch.main.description)" = 'configured through fetch' ]; then
    pass legit-fetch-configure \
      'f C configured the current branch and returned to the fetch popup'
  else
    fail legit-fetch-configure \
      'f C did not route directly through current-branch configuration' \
      "$porcelain_session"
  fi
else
  fail legit-fetch 'could not prepare the independent fetch refs' \
    "$porcelain_session"
fi

# Remote lifecycle: add with the default fetch argument, edit all six visible
# variables through the nested configure map, migrate push variables on rename,
# prune tracking refs/refspecs, and remove without leaving stale configuration.
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
  remote.pushDefault origin
send_keys "$porcelain_session" M
if lem_wait_for "$porcelain_session" 'Remote' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Remote name:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" managed-safe
fi
if lem_wait_for "$porcelain_session" 'Remote URL:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$LEM_YATH_VCS_MANAGED_REMOTE"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_managed_remote_added; then
  pass legit-remote-add \
    'M a fetched a metacharacter-bearing local remote without moving repository state'
else
  fail legit-remote-add 'M a did not add and fetch the selected remote' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" C-c f
send_keys "$porcelain_session" M C
if lem_wait_for "$porcelain_session" 'Configure remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" managed-safe \
    'Configure remote:'
fi
if lem_wait_for "$porcelain_session" 'Configure remote' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" u
fi
if lem_wait_for "$porcelain_session" 'Fetch URL for managed-safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$LEM_YATH_VCS_MANAGED_REMOTE"
fi
send_keys "$porcelain_session" U
if lem_wait_for "$porcelain_session" 'Fetch refspec for managed-safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" \
    '+refs/heads/main:refs/remotes/managed-safe/main'
fi
send_keys "$porcelain_session" s
if lem_wait_for "$porcelain_session" 'Push URL for managed-safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$LEM_YATH_VCS_PUSH_REMOTE"
fi
send_keys "$porcelain_session" S
if lem_wait_for "$porcelain_session" 'Push refspec for managed-safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" \
    'refs/heads/main:refs/heads/managed-main'
fi
send_keys "$porcelain_session" O
if lem_wait_for "$porcelain_session" 'Tag option for managed-safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" --tags
fi
send_keys "$porcelain_session" h
if lem_wait_for "$porcelain_session" 'Follow remote HEAD for managed-safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" always
fi
send_keys "$porcelain_session" q q
if wait_until "$WAIT_TIMEOUT" porcelain_managed_remote_configured; then
  pass legit-remote-configure \
    'M C edited URL, fetch, push URL, push, tag, and follow-HEAD variables'
else
  fail legit-remote-configure \
    'the nested remote configuration surface lost a visible variable' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
  remote.pushDefault managed-safe
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
  branch.main.pushRemote managed-safe
send_keys "$porcelain_session" C-c f
send_keys "$porcelain_session" M r
if lem_wait_for "$porcelain_session" 'Rename remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" managed-safe \
    'Rename remote:'
fi
if lem_wait_for "$porcelain_session" 'Rename managed-safe to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" managed-renamed
fi
if wait_until "$WAIT_TIMEOUT" porcelain_managed_remote_renamed; then
  pass legit-remote-rename \
    'M r retained remote configuration and migrated repository/branch push targets'
else
  fail legit-remote-rename 'M r left a stale name or push variable' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --unset-all \
  remote.managed-renamed.fetch
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --add \
  remote.managed-renamed.fetch \
  '+refs/heads/*:refs/remotes/managed-renamed/*'
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
  refs/remotes/managed-renamed/stale HEAD
send_keys "$porcelain_session" C-c f
send_keys "$porcelain_session" M p
if lem_wait_for "$porcelain_session" 'Prune stale branches of remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" managed-renamed \
    'Prune stale branches of remote:'
fi
if lem_wait_for "$porcelain_session" \
     'Prune stale branches of managed-renamed?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_managed_remote_pruned; then
  pass legit-remote-prune 'M p removed only a stale remote-tracking branch'
else
  fail legit-remote-prune 'M p retained the stale remote-tracking ref' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --unset-all \
  remote.managed-renamed.fetch
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --add \
  remote.managed-renamed.fetch \
  '+refs/heads/main:refs/remotes/managed-renamed/main'
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --add \
  remote.managed-renamed.fetch \
  '+refs/heads/absent:refs/remotes/managed-renamed/absent'
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
  refs/remotes/managed-renamed/absent HEAD
send_keys "$porcelain_session" C-c f
send_keys "$porcelain_session" M P
if lem_wait_for "$porcelain_session" 'Prune refspecs of remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" managed-renamed \
    'Prune refspecs of remote:'
fi
if lem_wait_for "$porcelain_session" \
     'Prune 1 stale refspec for managed-renamed?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_managed_refspec_pruned; then
  pass legit-remote-prune-refspec \
    'M P removed one stale fetch mapping and its exact tracking ref'
else
  fail legit-remote-prune-refspec \
    'M P crossed the valid/stale fetch-refspec boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" C-c f
send_keys "$porcelain_session" M k
if lem_wait_for "$porcelain_session" 'Remove remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" managed-renamed \
    'Remove remote:'
fi
if lem_wait_for "$porcelain_session" 'Remove remote managed-renamed?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_managed_remote_removed; then
  pass legit-remote-remove \
    'M k removed the remote and cleared stale repository/branch push targets'
else
  fail legit-remote-remove 'M k left remote or push configuration behind' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" b c
if lem_wait_for "$porcelain_session" \
     'Create and checkout branch starting at:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" main \
    'Create and checkout branch starting at:'
  if lem_wait_for "$porcelain_session" \
       'Name for create and checkout branch:' \
       "$WAIT_TIMEOUT" >/dev/null; then
    enter_prompt_value "$porcelain_session" vcs-feature
  fi
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_is vcs-feature; then
  pass legit-branch-create 'b c created and checked out a branch from main'
else
  fail legit-branch-create 'b c did not create the requested branch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" b b
if lem_wait_for "$porcelain_session" 'Checkout branch or revision:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" main \
    'Checkout branch or revision:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_is main; then
  pass legit-branch-checkout 'b b checked out the selected existing branch'
else
  fail legit-branch-checkout 'b b did not return to main' "$porcelain_session"
fi

printf 'stash-ignored.txt\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/.git/info/exclude"
printf 'stash-both-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
printf 'stash-untracked\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/stash-untracked.txt"
printf 'stash-ignored\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/stash-ignored.txt"
send_keys "$porcelain_session" g z - a z
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-stash-all
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_all_saved; then
  pass legit-stash-both-all \
    'z - a z stashed tracked, untracked, and ignored state with three parents'
else
  fail legit-stash-both-all \
    'z - a z did not preserve the complete stash topology and clean boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z p
if lem_wait_for "$porcelain_session" 'Pop stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_all_restored; then
  pass legit-stash-pop-all \
    'z p restored tracked, untracked, and ignored state and removed the stash'
else
  fail legit-stash-pop-all 'z p did not restore the complete selected stash' \
    "$porcelain_session"
fi

rm -f "$LEM_YATH_VCS_PORCELAIN_ROOT/stash-untracked.txt" \
  "$LEM_YATH_VCS_PORCELAIN_ROOT/stash-ignored.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q HEAD -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear

printf 'stash-index-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- auxiliary.txt
printf 'stash-unstaged-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
send_keys "$porcelain_session" g z i
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-stash-index
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_index_saved; then
  pass legit-stash-index \
    'z i removed only staged content while retaining an unrelated unstaged file'
else
  fail legit-stash-index 'z i crossed the staged/worktree state boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z p
if lem_wait_for "$porcelain_session" 'Pop stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_index_restored; then
  pass legit-stash-index-pop \
    'z p restored the index-only stash to the index without losing unstaged state'
else
  fail legit-stash-index-pop 'the index-only stash did not invert cleanly' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q HEAD -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear

printf 'stash-index-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- auxiliary.txt
printf 'stash-unstaged-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
send_keys "$porcelain_session" g z w
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-stash-worktree
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_worktree_saved; then
  pass legit-stash-worktree \
    'z w removed only unstaged content while preserving the exact index'
else
  fail legit-stash-worktree 'z w crossed the worktree/index state boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z p
if lem_wait_for "$porcelain_session" 'Pop stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_worktree_restored; then
  pass legit-stash-worktree-pop \
    'z p restored the worktree-only stash without changing the staged file'
else
  fail legit-stash-worktree-pop 'the worktree-only stash did not invert cleanly' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q HEAD -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear

printf 'stash-index-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- auxiliary.txt
printf 'stash-unstaged-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
send_keys "$porcelain_session" g z x
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-stash-keep-index
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_worktree_saved; then
  pass legit-stash-keep-index \
    'z x stashed both layers while retaining the exact staged index'
else
  fail legit-stash-keep-index 'z x did not preserve the index boundary' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q HEAD -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- \
  auxiliary.txt porcelain.txt

printf 'stash-index-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- auxiliary.txt
printf 'stash-unstaged-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/porcelain.txt"
send_keys "$porcelain_session" g z Z
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-snapshot-both
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_snapshot_preserved; then
  pass legit-stash-snapshot \
    'z Z recorded both layers without changing either live state'
else
  fail legit-stash-snapshot 'z Z mutated the live index or worktree' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z k
if lem_wait_for "$porcelain_session" 'Drop stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if lem_wait_for "$porcelain_session" 'Drop stash@{0}?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  lem_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_count_is 0; then
  pass legit-stash-drop 'z k selected, confirmed, and dropped the snapshot'
else
  fail legit-stash-drop 'z k did not remove the selected snapshot' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z I
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-snapshot-index
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_snapshot_preserved; then
  pass legit-stash-snapshot-index \
    'z I recorded the index without mutating live staged or unstaged content'
else
  fail legit-stash-snapshot-index 'z I changed live repository state' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear

send_keys "$porcelain_session" z W
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-snapshot-worktree
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_snapshot_preserved; then
  pass legit-stash-snapshot-worktree \
    'z W recorded the worktree without mutating live staged or unstaged content'
else
  fail legit-stash-snapshot-worktree 'z W changed live repository state' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear

send_keys "$porcelain_session" z r
if wait_until "$WAIT_TIMEOUT" porcelain_stash_wip_saved; then
  pass legit-stash-wip \
    'z r updated branch-scoped index/worktree WIP refs without cleaning live state'
else
  fail legit-stash-wip 'z r did not preserve exact WIP ref and live-state boundaries' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q HEAD -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- \
  auxiliary.txt porcelain.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear

printf 'stash-inspect-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
send_keys "$porcelain_session" g z z
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-stash-inspect
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_tracked_saved; then
  pass legit-stash-inspect-fixture \
    'prepared one selected stash for apply, inspect, patch, and branch actions'
else
  fail legit-stash-inspect-fixture \
    'could not prepare the inspect/transform stash' "$porcelain_session"
fi

send_keys "$porcelain_session" z a
if lem_wait_for "$porcelain_session" 'Apply stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_applied; then
  pass legit-stash-apply \
    'z a restored the selected stash while retaining its reflog entry'
else
  fail legit-stash-apply 'z a did not preserve apply-versus-pop semantics' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- auxiliary.txt

send_keys "$porcelain_session" g z v
if lem_wait_for "$porcelain_session" 'Show stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if lem_wait_for "$porcelain_session" 'stash-inspect-probe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-stash-show "z v rendered the selected stash patch in Legit's diff pane"
else
  fail legit-stash-show 'z v did not render the selected stash patch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z f
if lem_wait_for "$porcelain_session" 'Create patch from stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_patch_created; then
  pass legit-stash-format-patch \
    'z f created Magit-named patch content without dropping the stash'
else
  fail legit-stash-format-patch 'z f did not write the selected stash patch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z l
if lem_wait_for "$porcelain_session" 'lem-stash-inspect' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-stash-list 'z l displayed the bounded stash reflog entry'
else
  fail legit-stash-list 'z l did not display the stash list' \
    "$porcelain_session"
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- ' '
sleep 0.2

send_keys "$porcelain_session" z b
if lem_wait_for "$porcelain_session" 'Branch from stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if lem_wait_for "$porcelain_session" 'New branch name:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" stash-branch-base
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_branch_complete; then
  pass legit-stash-branch \
    'z b created at the stash base, applied cleanly, and dropped the stash'
else
  fail legit-stash-branch 'z b did not preserve stash-base branch semantics' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- auxiliary.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q main
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -D stash-branch-base \
  >/dev/null
rm -f "$LEM_YATH_VCS_PORCELAIN_ROOT/0001-lem-stash-inspect.patch"

printf 'stash-here-probe\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
send_keys "$porcelain_session" g z z
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-stash-here
  send_keys "$porcelain_session" Enter
fi
if ! wait_until "$WAIT_TIMEOUT" porcelain_stash_tracked_saved; then
  fail legit-stash-branch-here-fixture \
    'could not prepare the branch-here stash' "$porcelain_session"
fi
send_keys "$porcelain_session" z B
if lem_wait_for "$porcelain_session" 'Branch from stash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Enter
fi
if lem_wait_for "$porcelain_session" 'New branch name:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" stash-branch-here
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_branch_here_complete; then
  pass legit-stash-branch-here \
    'z B branched at current HEAD, applied the stash, and retained its reflog entry'
else
  fail legit-stash-branch-here \
    'z B did not preserve branch-here or retained-stash semantics' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- auxiliary.txt
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" switch -q main
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -D stash-branch-here \
  >/dev/null
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" stash clear
send_keys "$porcelain_session" g
if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" pull -q --ff-only &&
   printf 'peer-pull-probe\n' \
     >>"$LEM_YATH_VCS_PORCELAIN_PEER/auxiliary.txt" &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- auxiliary.txt &&
   git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" porcelain-peer \
     '2001-01-05T00:00:00+0000' &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -q; then
  send_keys "$porcelain_session" F p
  if lem_wait_for "$porcelain_session" \
       'Set push remote and pull main from there:' \
       "$WAIT_TIMEOUT" >/dev/null; then
    enter_completion_prompt_value "$porcelain_session" origin \
      'Set push remote and pull main from there:'
  fi
  if lem_wait_for "$porcelain_session" \
       'Set origin as push remote and pull main from there' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" y
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_peer_pulled; then
    pass legit-pull \
      'F p configured the missing push remote and fast-forwarded from origin'
  else
    fail legit-pull 'F p did not integrate the peer commit' \
      "$porcelain_session"
  fi
else
  fail legit-pull 'could not prepare the independent peer commit' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g
commit_before=$(report_count '^PORCELAIN-COMMIT ')
send_keys "$porcelain_session" C-c r
if wait_report_count '^PORCELAIN-COMMIT ' "$((commit_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-COMMIT ') == \
      'PORCELAIN-COMMIT row=yes hash=yes rebase=yes subject=yes' ]]; then
  pass legit-rebase-position 'the real status row exposed its commit hash and r i command'
else
  fail legit-rebase-position 'could not select the older commit in Legit status' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" r i
rebase_before=$(report_count '^REBASE ')
if wait_until "$WAIT_TIMEOUT" porcelain_rebase_todo_ready; then
  send_keys "$porcelain_session" C-c v
fi
if wait_report_count '^REBASE ' "$((rebase_before + 1))" &&
   [[ $(latest_report '^REBASE ') == \
      'REBASE mode=yes file=yes first=yes second=yes point=yes fixup=yes edit=yes commit=yes amend=yes diff=yes legacy-free=yes continue=yes abort=yes modified=no' ]]; then
  pass legit-rebase-open 'r i opened the two-commit todo in the native rebase mode'
else
  fail legit-rebase-open 'interactive rebase did not expose the expected todo mode' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" r f
if wait_until "$WAIT_TIMEOUT" porcelain_rebase_todo_reword_fixup; then
  pass legit-rebase-actions \
    'r and f saved the first todo as reword and the second as fixup'
else
  fail legit-rebase-actions 'the rebase-mode actions did not update the real todo file' \
    "$porcelain_session"
fi

reword_before=$(report_count '^REWORD ')
send_keys "$porcelain_session" C-c C-c
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" C-c v
fi
if wait_report_count '^REWORD ' "$((reword_before + 1))" &&
   [[ $(latest_report '^REWORD ') == \
      'REWORD mode=yes file=yes server=yes subject=yes continue=yes abort=yes' ]]; then
  pass legit-rebase-reword-open 'Git opened the reword message through the blocking Lem client'
else
  fail legit-rebase-reword-open 'reword did not open a server-owned Legit message buffer' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g g d d i
tmux_cmd send-keys -t "$porcelain_session" -l -- \
  'porcelain commit reworded in Lem'
send_keys "$porcelain_session" Escape C-c C-c
if wait_until "$WAIT_TIMEOUT" porcelain_rebase_complete; then
  pass legit-rebase-continue \
    'the client-saved reword and fixup completed with clean retained content'
else
  fail legit-rebase-continue \
    'the client-backed reword/fixup did not produce the expected clean history' \
    "$porcelain_session"
fi

commit_before=$(report_count '^PORCELAIN-COMMIT ')
send_keys "$porcelain_session" Escape Space g G
if wait_legit "$porcelain_session" porcelain; then
  send_keys "$porcelain_session" C-c r
fi
if wait_report_count '^PORCELAIN-COMMIT ' "$((commit_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-COMMIT ') == \
      'PORCELAIN-COMMIT row=yes hash=yes rebase=yes subject=yes' ]]; then
  pass legit-repeat-rebase-position \
    'the rewritten commit was immediately selectable for another rebase'
else
  fail legit-repeat-rebase-position \
    'the rewritten commit could not be selected in a refreshed Legit status' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" r i
rebase_before=$(report_count '^REBASE ')
if wait_until "$WAIT_TIMEOUT" porcelain_repeat_rebase_todo_ready; then
  send_keys "$porcelain_session" C-c v
fi
if wait_report_count '^REBASE ' "$((rebase_before + 1))" &&
   [[ $(latest_report '^REBASE ') == \
      'REBASE mode=yes file=yes first=yes second=no point=yes fixup=yes edit=yes commit=yes amend=yes diff=yes legacy-free=yes continue=yes abort=yes modified=no' ]]; then
  pass legit-repeat-rebase-open \
    'an immediate second r i opened a fresh one-commit todo'
else
  fail legit-repeat-rebase-open \
    'the immediate second interactive rebase did not open a fresh todo' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" r
if wait_until "$WAIT_TIMEOUT" porcelain_repeat_rebase_todo_reword; then
  pass legit-repeat-rebase-action 'the fresh todo accepted a second reword action'
else
  fail legit-repeat-rebase-action \
    'the fresh todo did not persist the second reword action' \
    "$porcelain_session"
fi

reword_before=$(report_count '^REWORD ')
send_keys "$porcelain_session" C-c C-c
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" C-c v
fi
if wait_report_count '^REWORD ' "$((reword_before + 1))" &&
   [[ $(latest_report '^REWORD ') == \
      'REWORD mode=yes file=yes server=yes subject=yes continue=yes abort=yes' ]]; then
  pass legit-repeat-reword-open \
    'the second Git editor callback reused the blocking Lem client safely'
else
  fail legit-repeat-reword-open \
    'the second Git editor callback did not produce a usable message buffer' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g g d d i
tmux_cmd send-keys -t "$porcelain_session" -l -- \
  'porcelain commit reworded twice in Lem'
send_keys "$porcelain_session" Escape C-c C-c
if wait_until "$WAIT_TIMEOUT" porcelain_repeat_rebase_complete; then
  pass legit-repeat-rebase-continue \
    'two consecutive client-backed rewords completed with clean history'
else
  fail legit-repeat-rebase-continue \
    'the second client-backed reword did not complete cleanly' \
    "$porcelain_session"
fi

commit_before=$(report_count '^PORCELAIN-COMMIT ')
send_keys "$porcelain_session" Escape Space g G
if wait_legit "$porcelain_session" porcelain; then
  send_keys "$porcelain_session" C-c r
fi
if wait_report_count '^PORCELAIN-COMMIT ' "$((commit_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-COMMIT ') == \
      'PORCELAIN-COMMIT row=yes hash=yes rebase=yes subject=yes' ]]; then
  pass legit-edit-rebase-position \
    'the twice-rewritten commit remained selectable for an edit stop'
else
  fail legit-edit-rebase-position \
    'the twice-rewritten commit could not start the edit-stop workflow' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" r i
if wait_until "$WAIT_TIMEOUT" porcelain_edit_rebase_todo_ready; then
  send_keys "$porcelain_session" e
fi
if wait_until "$WAIT_TIMEOUT" porcelain_edit_rebase_todo_marked; then
  pass legit-edit-rebase-action 'e persisted a real edit action in the todo'
else
  fail legit-edit-rebase-action \
    'the rebase todo did not persist the edit action' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" C-c C-c
if wait_until "$WAIT_TIMEOUT" porcelain_edit_rebase_stopped; then
  pass legit-edit-rebase-stop \
    'Git stopped at the selected commit with a clean amend baseline'
else
  fail legit-edit-rebase-stop \
    'the interactive rebase did not reach a clean edit stop' \
    "$porcelain_session"
fi

printf 'edit-stop-amendment\n' >>"$LEM_YATH_VCS_PORCELAIN_FILE"
position_before=$(report_count '^PORCELAIN-POSITION ')
send_keys "$porcelain_session" Escape Space g G
if wait_legit "$porcelain_session" porcelain; then
  send_keys "$porcelain_session" C-c m
fi
if wait_report_count '^PORCELAIN-POSITION ' "$((position_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-POSITION ') == \
      'PORCELAIN-POSITION file=porcelain.txt row=yes diff=yes mode=yes focused=no' ]]; then
  send_keys "$porcelain_session" s
fi
if wait_until "$WAIT_TIMEOUT" porcelain_edit_amend_staged; then
  pass legit-edit-rebase-stage \
    'Legit staged the edit-stop change before amending'
else
  fail legit-edit-rebase-stage \
    'the edit-stop change was not staged through Legit status' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" c a
amend_before=$(report_count '^AMEND ')
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" C-c v
fi
if wait_report_count '^AMEND ' "$((amend_before + 1))" &&
   [[ $(latest_report '^AMEND ') == \
      'AMEND mode=yes file=no name=yes action=yes subject=yes clean=yes continue=yes abort=yes commit=yes amend=yes diff=yes legacy-free=yes' ]]; then
  pass legit-edit-rebase-amend-open \
    'c a opened a prefilled transient amend message in Legit commit mode'
else
  fail legit-edit-rebase-amend-open \
    'the amend action did not open the expected safe transient buffer' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" C-c C-k
if lem_wait_for "$porcelain_session" 'Abort amend?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_edit_amend_aborted; then
  pass legit-edit-rebase-amend-abort \
    'aborting the amend preserved the staged edit-stop change'
else
  fail legit-edit-rebase-amend-abort \
    'amend abort changed the commit, index, or rebase state' \
    "$porcelain_session"
fi

amend_before=$(report_count '^AMEND ')
send_keys "$porcelain_session" c a
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" C-c v
fi
if wait_report_count '^AMEND ' "$((amend_before + 1))" &&
   [[ $(latest_report '^AMEND ') == \
      'AMEND mode=yes file=no name=yes action=yes subject=yes clean=yes continue=yes abort=yes commit=yes amend=yes diff=yes legacy-free=yes' ]]; then
  pass legit-edit-rebase-amend-reopen \
    'c a reopened a fresh prefilled amend buffer after abort'
else
  fail legit-edit-rebase-amend-reopen \
    'the aborted amend buffer leaked or did not return focus to status' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g g d d i
tmux_cmd send-keys -t "$porcelain_session" -l -- \
  'porcelain commit edited in Lem'
send_keys "$porcelain_session" Escape C-c C-c
if wait_until "$WAIT_TIMEOUT" porcelain_edit_amended; then
  pass legit-edit-rebase-amend \
    'the staged content and edited subject amended HEAD cleanly'
else
  fail legit-edit-rebase-amend \
    'the transient amend did not update HEAD and clean the index' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" r c
if wait_until "$WAIT_TIMEOUT" porcelain_edit_rebase_complete; then
  pass legit-edit-rebase-continue \
    'r c completed the edit-stop rebase with amended content and message'
else
  fail legit-edit-rebase-continue \
    'the amended edit stop did not continue to a clean final history' \
    "$porcelain_session"
fi
fi

if prepare_porcelain_cherry_fixture; then
  pass legit-cherry-fixture \
    'prepared clean, no-commit, and three conflicting source refs'
else
  fail legit-cherry-fixture \
    'could not prepare the isolated cherry-pick histories' \
    "$porcelain_session"
  lem_stop "$porcelain_session"
  printf '\n'
  cat "$LEM_YATH_VCS_REPORT" 2>/dev/null || true
  echo 'VCS TEST FAILED'
  exit 1
fi

send_keys "$porcelain_session" Escape Space g G
if wait_legit "$porcelain_session" porcelain; then
  cherry_before=$(report_count '^CHERRY ')
  send_keys "$porcelain_session" C-c y
else
  cherry_before=$(report_count '^CHERRY ')
fi
if wait_report_count '^CHERRY ' "$((cherry_before + 1))" &&
   [[ $(latest_report '^CHERRY ') == \
      'CHERRY active=no dispatch=yes initial=yes active-map=yes options=yes candidate=yes' ]]; then
  pass legit-cherry-dispatch \
    'A exposes the complete Magit argument/action maps and all-ref completion'
else
  fail legit-cherry-dispatch \
    'the dispatch, diff bindings, or all-ref candidates were incomplete' \
    "$porcelain_session"
fi

cherry_region_prompted=0
cherry_region_editors=0
send_keys "$porcelain_session" l o
if lem_wait_for "$porcelain_session" 'Log revision\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" test-cherry-region \
    'cherry-region-two'
fi
if lem_wait_for "$porcelain_session" 'cherry-region-two' \
     "$WAIT_TIMEOUT" >/dev/null; then
  # Select from the older row back toward the newer row.  This proves that
  # commit collection is independent of Visual selection direction.
  send_keys "$porcelain_session" j V k A
fi
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - e
  send_keys "$porcelain_session" A
fi
if lem_wait_for "$porcelain_session" 'Cherry-pick:' 2 >/dev/null 2>&1; then
  cherry_region_prompted=1
  enter_cherry_revision "$porcelain_session" \
    "$cherry_region_one_hash,$cherry_region_two_hash"
fi
if lem_wait_for "$porcelain_session" 'cherry-region-one' \
     "$WAIT_TIMEOUT" >/dev/null &&
   lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  cherry_region_editors=$((cherry_region_editors + 1))
  send_keys "$porcelain_session" C-c C-c
fi
if lem_wait_for "$porcelain_session" 'cherry-region-two' \
     "$WAIT_TIMEOUT" >/dev/null &&
   lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  cherry_region_editors=$((cherry_region_editors + 1))
  send_keys "$porcelain_session" C-c C-c
fi
if ((cherry_region_prompted == 0 && cherry_region_editors == 2)) &&
   wait_until "$WAIT_TIMEOUT" porcelain_cherry_region_picked; then
  pass legit-cherry-visual-region \
    'reversed Visual A -e A edited dependent commits oldest-first without prompting'
else
  fail legit-cherry-visual-region \
    'Visual A -e A prompted, lost selection order, or failed editor handoff' \
    "$porcelain_session"
fi

log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=yes\ status=no\ state=yes\ hash=yes\ line=*cherry-region-two*\ offset=0 ]]; then
  pass legit-cherry-log-refresh \
    'a successful Visual cherry-pick refreshed its log and retained the selected commit'
else
  fail legit-cherry-log-refresh \
    'a successful Visual cherry-pick dropped to status or lost its commit anchor' \
    "$porcelain_session"
fi

if [[ ${LEM_YATH_VCS_CHERRY_REGION_ONLY:-0} == 1 ]]; then
  lem_stop "$porcelain_session"
  printf '\n'
  cat "$LEM_YATH_VCS_REPORT" 2>/dev/null || true
  if ((failed)); then
    echo 'VCS CHERRY REGION TEST FAILED'
    exit 1
  fi
  echo 'VCS CHERRY REGION TEST PASSED'
  exit 0
fi

cherry_region_prompted=0
send_keys "$porcelain_session" q l l
if lem_wait_for "$porcelain_session" 'cherry-region-two' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" j V k _
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - E _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' 2 \
     >/dev/null 2>&1; then
  cherry_region_prompted=1
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_region_two_hash,$cherry_region_one_hash" 'Revert commit\(s\):'
fi
if ((cherry_region_prompted == 0)) &&
   wait_until "$WAIT_TIMEOUT" porcelain_cherry_region_reverted; then
  pass legit-revert-visual-region \
    'reversed Visual _ reverted dependent commits newest-first without prompting'
else
  fail legit-revert-visual-region \
    'Visual _ prompted, lost selection direction, or reverted commits out of order' \
    "$porcelain_session"
fi

log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=yes\ status=no\ state=yes\ hash=yes\ line=*cherry-region-two*\ offset=0 ]]; then
  pass legit-revert-log-refresh \
    'a successful Visual revert refreshed its log and retained the selected commit'
else
  fail legit-revert-log-refresh \
    'a successful Visual revert dropped to status or lost its commit anchor' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$cherry_main_head"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" clean -fq -- \
  cherry-region.txt
send_keys "$porcelain_session" q g

send_keys "$porcelain_session" A A
if lem_wait_for "$porcelain_session" 'Cherry-pick:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_cherry_revision "$porcelain_session" "$cherry_success_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_success; then
  pass legit-cherry-pick \
    'A A selected an all-ref commit and applied it with Magit-compatible --ff'
else
  fail legit-cherry-pick \
    'A A did not produce the expected clean picked commit' \
    "$porcelain_session"
fi
cherry_success_head=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
  rev-parse HEAD)

send_keys "$porcelain_session" A a
if lem_wait_for "$porcelain_session" 'Apply changes from commit:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_cherry_revision "$porcelain_session" "$cherry_apply_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_applied; then
  pass legit-cherry-apply \
    'A a applied the selected commit to the index without moving HEAD'
else
  fail legit-cherry-apply \
    'A a did not preserve HEAD with the selected change staged' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard HEAD
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" clean -fq -- cherry-apply.txt
send_keys "$porcelain_session" g

porcelain_conflict_head=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
  rev-parse HEAD)
send_keys "$porcelain_session" A A
if lem_wait_for "$porcelain_session" 'Cherry-pick:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_cherry_revision "$porcelain_session" "$cherry_continue_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_conflicted \
     cherry-continue.txt; then
  pass legit-cherry-conflict \
    'A A retained a real unmerged index and CHERRY_PICK_HEAD on conflict'
else
  fail legit-cherry-conflict \
    'the conflicting pick did not enter Git sequencer state' \
    "$porcelain_session"
fi

cherry_before=$(report_count '^CHERRY ')
send_keys "$porcelain_session" C-c y
if wait_report_count '^CHERRY ' "$((cherry_before + 1))" &&
   [[ $(latest_report '^CHERRY ') == \
      'CHERRY active=yes dispatch=yes initial=yes active-map=yes options=yes candidate=yes' ]]; then
  pass legit-cherry-in-progress \
    'the dispatch detected the active cherry-pick and changed action semantics'
else
  fail legit-cherry-in-progress \
    'the active cherry-pick was not reflected by the dispatch state' \
    "$porcelain_session"
fi

printf 'continue resolved\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/cherry-continue.txt"
position_before=$(report_count '^PORCELAIN-POSITION ')
send_keys "$porcelain_session" g C-c Y
if wait_report_count '^PORCELAIN-POSITION ' "$((position_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-POSITION ') == \
      'PORCELAIN-POSITION file=cherry-continue.txt row=yes diff=yes mode=yes focused=no' ]]; then
  send_keys "$porcelain_session" s
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_active &&
   [ -z "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     ls-files -u -- cherry-continue.txt)" ] &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     diff --quiet -- cherry-continue.txt &&
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     diff --cached --quiet -- cherry-continue.txt; then
  pass legit-cherry-resolve-stage \
    'Legit displayed the unmerged row and staged its resolved file'
else
  fail legit-cherry-resolve-stage \
    'the unmerged row was hidden or could not stage its resolution' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" A A
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_continued; then
  pass legit-cherry-continue \
    'A A continued the resolved pick without opening a nested editor'
else
  fail legit-cherry-continue \
    'the resolved pick did not complete with its original commit subject' \
    "$porcelain_session"
fi

porcelain_conflict_head=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
  rev-parse HEAD)
send_keys "$porcelain_session" A A
if lem_wait_for "$porcelain_session" 'Cherry-pick:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_cherry_revision "$porcelain_session" "$cherry_abort_hash"
fi
wait_until "$WAIT_TIMEOUT" porcelain_cherry_conflicted \
  cherry-abort.txt || true
send_keys "$porcelain_session" A a
if lem_wait_for "$porcelain_session" 'Abort cherry-pick?' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_aborted; then
  pass legit-cherry-abort \
    'in-progress A a aborted and restored the exact pre-pick tree and HEAD'
else
  fail legit-cherry-abort \
    'A a did not cleanly restore the pre-pick state' \
    "$porcelain_session"
fi

porcelain_conflict_head=$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
  rev-parse HEAD)
send_keys "$porcelain_session" A A
if lem_wait_for "$porcelain_session" 'Cherry-pick:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_cherry_revision "$porcelain_session" "$cherry_skip_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_conflicted \
     cherry-skip.txt; then
  position_before=$(report_count '^PORCELAIN-POSITION ')
  send_keys "$porcelain_session" g C-c Y
  if wait_report_count '^PORCELAIN-POSITION ' "$((position_before + 1))" &&
     [[ $(latest_report '^PORCELAIN-POSITION ') == \
        PORCELAIN-POSITION\ file=cherry-skip.txt\ row=yes\ * ]]; then
    pass legit-cherry-add-add-row \
      'Legit rendered the add/add conflict despite its U-free AA status'
  else
    fail legit-cherry-add-add-row \
      'the add/add conflict was absent from Legit status' \
      "$porcelain_session"
  fi
  send_keys "$porcelain_session" A s
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_skipped; then
  pass legit-cherry-skip \
    'in-progress A s skipped the conflicting commit and cleaned the sequencer'
else
  fail legit-cherry-skip \
    'A s did not retain HEAD and clean the conflicting pick' \
    "$porcelain_session"
fi

if prepare_porcelain_cherry_move_fixture; then
  pass legit-cherry-move-fixture \
    'prepared source, destination, interior, squash, and editable cherry histories'
else
  fail legit-cherry-move-fixture \
    'could not prepare the cherry-pick histories' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" g

send_keys "$porcelain_session" A n
if lem_wait_for "$porcelain_session" 'Move cherry:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_spinout_hash" 'Move cherry:'
fi
if lem_wait_for "$porcelain_session" 'Spin out to new branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" cherry-spinout-destination
fi
if lem_wait_for "$porcelain_session" 'Starting point for new branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$cherry_spinout_parent"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_spinout_complete; then
  pass legit-cherry-spinout \
    'A n moved the tip to a new branch, reset the source, and stayed on source'
else
  fail legit-cherry-spinout \
    'spinout lost its destination, source reset, checkout, or clean boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" A s
if lem_wait_for "$porcelain_session" 'Move cherry:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_spinoff_hash" 'Move cherry:'
fi
if lem_wait_for "$porcelain_session" 'Spin off to new branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" cherry-spinoff-destination
fi
if lem_wait_for "$porcelain_session" 'Starting point for new branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$cherry_spinoff_parent"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_spinoff_complete; then
  pass legit-cherry-spinoff \
    'A s moved the tip, reset the source, and checked out the new branch'
else
  fail legit-cherry-spinoff \
    'spinoff lost its destination, source reset, checkout, or clean boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" b l
if lem_wait_for "$porcelain_session" 'Checkout local branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_move_main_branch" 'Checkout local branch:'
fi
if ! wait_until "$WAIT_TIMEOUT" porcelain_cherry_current_is \
     "$cherry_move_main_branch"; then
  fail legit-cherry-return-source \
    'could not return from the spun-off branch to the source' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" A d
if lem_wait_for "$porcelain_session" 'Donate cherry:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_donate_hash" 'Donate cherry:'
fi
if lem_wait_for "$porcelain_session" 'Move cherry to branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    cherry-donate-destination 'Move cherry to branch:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_donate_complete; then
  pass legit-cherry-donate \
    'A d moved the tip to an existing branch and stayed on the reset source'
else
  fail legit-cherry-donate \
    'donate lost its destination, source reset, checkout, or clean boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" A h
if lem_wait_for "$porcelain_session" 'Harvest cherry:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_harvest_hash" 'Harvest cherry:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_harvest_complete; then
  pass legit-cherry-harvest \
    'A h picked here, rebased an interior source commit away, and returned'
else
  fail legit-cherry-harvest \
    'harvest lost its picked commit, retained descendant, or checkout state' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" A m
if lem_wait_for "$porcelain_session" 'Squash:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" "$cherry_squash_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_squash_complete &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-cherry-squash \
    'A m applied a selected ref through git merge --squash without moving HEAD'
else
  fail legit-cherry-squash \
    'squash did not preserve HEAD with the selected tree staged' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard HEAD
send_keys "$porcelain_session" C-c f g

send_keys "$porcelain_session" A
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" = s
fi
if lem_wait_for "$porcelain_session" 'Cherry-pick strategy:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" ort \
    'Cherry-pick strategy:'
fi
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - x
fi
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - e
fi
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" + s
fi
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" A
fi
if lem_wait_for "$porcelain_session" 'Cherry-pick:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_edit_hash" 'Cherry-pick:'
fi
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" g g d d i
  tmux_cmd send-keys -t "$porcelain_session" -l -- \
    'cherry message edited in Lem'
  send_keys "$porcelain_session" Enter Enter Escape C-c C-c
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_edit_complete; then
  pass legit-cherry-edit-arguments \
    'A =s -x -e +s A edited natively with strategy, reference, and signoff'
else
  fail legit-cherry-edit-arguments \
    'editable cherry-pick lost its message trailers, content, or clean state' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" A
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - m
fi
if lem_wait_for "$porcelain_session" 'Mainline parent:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" 1
fi
if lem_wait_for "$porcelain_session" '\[Apply\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" A
fi
if lem_wait_for "$porcelain_session" 'Cherry-pick:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$cherry_merge_hash" 'Cherry-pick:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_cherry_mainline_complete; then
  pass legit-cherry-mainline \
    'A -m A replayed a real merge relative to parent one as a linear commit'
else
  fail legit-cherry-mainline \
    'mainline replay lost its selected-parent tree or clean linear boundary' \
    "$porcelain_session"
fi

if prepare_porcelain_bisect_fixture; then
  pass legit-bisect-fixture \
    'prepared a clean nine-commit history with one known first-bad commit'
else
  fail legit-bisect-fixture \
    'could not prepare the isolated linear bisect history' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" Escape Space g G
wait_legit "$porcelain_session" porcelain ||
  fail legit-bisect-focus 'could not refocus Legit after fixture creation' \
    "$porcelain_session"
send_keys "$porcelain_session" F4
if wait_report_count '^BISECT ' 1 &&
   [[ $(latest_report '^BISECT ') == \
      'BISECT active=no status=yes diff=yes initial=yes actions=yes section=no terms=none no-checkout=no first-parent=no first-bad=no hook=1' ]]; then
  pass legit-bisect-dispatch \
    'B exposes the complete initial and in-progress Magit action maps'
else
  fail legit-bisect-dispatch \
    'the bisect binding, popup arguments, actions, or hook were incomplete' \
    "$porcelain_session"
fi

# Exercise Magit's initial transient arguments before starting: --no-checkout,
# --first-parent, and custom old/new terms all remain live until the B action.
send_keys "$porcelain_session" B
if lem_wait_for "$porcelain_session" 'Bisect' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" n
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" p
  tmux_cmd send-keys -t "$porcelain_session" -l -- '='
  send_keys "$porcelain_session" o
fi
if lem_wait_for "$porcelain_session" 'Old/good term' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" old
  tmux_cmd send-keys -t "$porcelain_session" -l -- '='
  send_keys "$porcelain_session" n
fi
if lem_wait_for "$porcelain_session" 'New/bad term' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" new
  send_keys "$porcelain_session" B
fi
if lem_wait_for "$porcelain_session" 'Start bisect with bad revision' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$bisect_bad_hash"
fi
if lem_wait_for "$porcelain_session" 'Good revision' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$bisect_good_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_bisect_no_checkout; then
  bisect_before=$(report_count '^BISECT ')
  send_keys "$porcelain_session" F4
else
  bisect_before=$(report_count '^BISECT ')
fi
if wait_report_count '^BISECT ' "$((bisect_before + 1))" &&
   [[ $(latest_report '^BISECT ') == \
      'BISECT active=yes status=yes diff=yes initial=yes actions=yes section=yes terms=old/new no-checkout=yes first-parent=yes first-bad=no hook=1' ]]; then
  pass legit-bisect-start \
    'B B started with no-checkout, first-parent, custom terms, and a live status section'
else
  fail legit-bisect-start \
    'the configured start arguments or active status rendering were lost' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" B g
if wait_until "$WAIT_TIMEOUT" porcelain_bisect_log_has old; then
  pass legit-bisect-good 'B g marked the no-checkout candidate with the old term'
else
  fail legit-bisect-good 'B g did not advance the custom-term bisect' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" B k
if wait_until "$WAIT_TIMEOUT" porcelain_bisect_log_has skip; then
  pass legit-bisect-skip 'B k skipped the current candidate and advanced'
else
  fail legit-bisect-skip 'B k did not record a skipped bisect candidate' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" B m
if lem_wait_for "$porcelain_session" 'Mark current revision as' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if wait_until "$WAIT_TIMEOUT" porcelain_bisect_log_has new; then
  pass legit-bisect-mark 'B m n marked the candidate using the visible new term'
else
  fail legit-bisect-mark 'B m did not expose or apply custom terms' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" B r
if lem_wait_for "$porcelain_session" 'Reset bisect' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_bisect_reset; then
  pass legit-bisect-reset \
    'B r confirmed, removed metadata, and restored the exact original HEAD'
else
  fail legit-bisect-reset 'B r did not cleanly restore the pre-bisect state' \
    "$porcelain_session"
fi

# The inactive s action combines start with `git bisect run`.  Use only shell
# builtins so the check proves the wrapper need not inherit host utilities.
send_keys "$porcelain_session" B s
if lem_wait_for "$porcelain_session" 'Start bisect with bad revision' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$bisect_bad_hash"
fi
if lem_wait_for "$porcelain_session" 'Good revision' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$bisect_good_hash"
fi
if lem_wait_for "$porcelain_session" 'Bisect shell command' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- \
    'while IFS= read -r line; do [ "$line" = "BUG introduced here" ] && exit 1; done < bisect-probe.txt; exit 0'
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_bisect_first_bad; then
  bisect_before=$(report_count '^BISECT ')
  send_keys "$porcelain_session" F4
else
  bisect_before=$(report_count '^BISECT ')
fi
if wait_report_count '^BISECT ' "$((bisect_before + 1))" &&
   [[ $(latest_report '^BISECT ') == \
      'BISECT active=yes status=yes diff=yes initial=yes actions=yes section=yes terms=good/bad no-checkout=no first-parent=no first-bad=yes hook=1' ]]; then
  pass legit-bisect-run \
    'B s ran the explicit shell predicate and found the exact first bad commit'
else
  fail legit-bisect-run \
    'scripted bisect did not converge or render its first-bad result' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" B r
if lem_wait_for "$porcelain_session" 'Reset bisect' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_bisect_reset; then
  pass legit-bisect-run-reset \
    'the completed scripted bisect remained resettable through B r'
else
  fail legit-bisect-run-reset \
    'completed scripted bisect metadata or HEAD survived reset' \
    "$porcelain_session"
fi

if prepare_porcelain_reset_fixture; then
  pass legit-reset-fixture \
    'prepared isolated base/step revisions, a movable branch, and metacharacter paths'
else
  fail legit-reset-fixture \
    'could not prepare the isolated reset history' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" Escape Space g G
wait_legit "$porcelain_session" porcelain ||
  fail legit-reset-focus 'could not refocus Legit after reset fixture creation' \
    "$porcelain_session"

send_keys "$porcelain_session" O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Mixed reset:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_base_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_mixed; then
  pass legit-reset-mixed \
    'O m moved HEAD and the index while preserving the step worktree'
else
  fail legit-reset-mixed \
    'mixed reset did not preserve its exact HEAD/index/worktree boundary' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" h
fi
if lem_wait_for "$porcelain_session" 'Hard reset:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_step_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_clean_at "$reset_step_hash"; then
  pass legit-reset-hard \
    'O h restored HEAD, index, and worktree to the selected step'
else
  fail legit-reset-hard \
    'hard reset left HEAD, index, or worktree at the wrong revision' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" s
fi
if lem_wait_for "$porcelain_session" 'Soft reset:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_base_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_soft; then
  pass legit-reset-soft \
    'O s moved only HEAD and retained the step index and worktree'
else
  fail legit-reset-soft \
    'soft reset changed or lost the retained index/worktree state' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" h
fi
if lem_wait_for "$porcelain_session" 'Hard reset:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_step_hash"
fi
wait_until "$WAIT_TIMEOUT" porcelain_reset_clean_at "$reset_step_hash" ||
  fail legit-reset-soft-cleanup \
    'could not restore the clean step after soft reset' "$porcelain_session"

printf 'uncommitted keep value\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-keep.txt"
send_keys "$porcelain_session" g O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" k
fi
if lem_wait_for "$porcelain_session" 'Keep reset:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_base_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_keep; then
  pass legit-reset-keep \
    'O k moved HEAD/index while retaining an unrelated dirty tracked file'
else
  fail legit-reset-keep \
    'keep reset lost the dirty file or retained the wrong committed tree' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$reset_step_hash"
send_keys "$porcelain_session" g

printf 'staged index value\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-index.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- reset-index.txt
send_keys "$porcelain_session" g O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" i
fi
if lem_wait_for "$porcelain_session" 'Reset index to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_step_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_index_only; then
  pass legit-reset-index \
    'O i reset only the index and retained the edited worktree file'
else
  fail legit-reset-index \
    'index-only reset moved HEAD or discarded the worktree edit' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$reset_step_hash"
send_keys "$porcelain_session" g

printf 'staged worktree value\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-worktree.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- reset-worktree.txt
printf 'unstaged worktree value\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-worktree.txt"
send_keys "$porcelain_session" g O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" w
fi
if lem_wait_for "$porcelain_session" 'Reset worktree to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_step_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_worktree_only; then
  pass legit-reset-worktree \
    'O w used a temporary index and changed only worktree contents'
else
  fail legit-reset-worktree \
    'worktree-only reset changed HEAD/index or retained the wrong file content' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$reset_step_hash"
send_keys "$porcelain_session" g

printf 'selected path dirty\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset dir;safe/target file.txt"
printf 'other remains dirty\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-other.txt"
send_keys "$porcelain_session" g O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" f
fi
if lem_wait_for "$porcelain_session" 'Checkout from revision:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_step_hash"
fi
if lem_wait_for "$porcelain_session" 'Checkout file:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  # Select the unique path through the real completion view, then submit the
  # resulting exact prompt value.  Completion Return and prompt Return are
  # deliberately separate Lem commands.
  enter_completion_prompt_value "$porcelain_session" target 'Checkout file:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_file_only; then
  pass legit-reset-file \
    'O f restored one exact space/semicolon path and left another dirty file alone'
else
  fail legit-reset-file \
    'file checkout broadened its path scope or mishandled direct argv' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$reset_step_hash"
send_keys "$porcelain_session" g

send_keys "$porcelain_session" O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" b
fi
if lem_wait_for "$porcelain_session" 'Reset branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" moving 'Reset branch:'
fi
if lem_wait_for "$porcelain_session" 'Reset reset-moving to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_step_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_other_branch; then
  pass legit-reset-branch-other \
    'O b moved a non-current branch through update-ref without touching HEAD'
else
  fail legit-reset-branch-other \
    'non-current branch reset changed HEAD or lost its reset reflog action' \
    "$porcelain_session"
fi

printf 'current branch dirty\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-mode.txt"
send_keys "$porcelain_session" g O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" b
fi
if lem_wait_for "$porcelain_session" 'Reset branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$reset_current_branch" 'Reset branch:'
fi
if lem_wait_for "$porcelain_session" "Reset $reset_current_branch to:" \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_base_hash"
fi
if lem_wait_for "$porcelain_session" 'Uncommitted changes will be lost' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if [ "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" = \
     "$reset_step_hash" ] &&
   [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-mode.txt")" = \
     'current branch dirty' ]; then
  pass legit-reset-branch-decline \
    'O b respected refusal of the current-branch destructive reset'
else
  fail legit-reset-branch-decline \
    'declining the loss warning still changed HEAD or the dirty file' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" b
fi
if lem_wait_for "$porcelain_session" 'Reset branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$reset_current_branch" 'Reset branch:'
fi
if lem_wait_for "$porcelain_session" "Reset $reset_current_branch to:" \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_base_hash"
fi
if lem_wait_for "$porcelain_session" 'Uncommitted changes will be lost' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_clean_at "$reset_base_hash"; then
  pass legit-reset-branch-current \
    'O b confirmed and hard-reset the current dirty branch to its target'
else
  fail legit-reset-branch-current \
    'confirmed current-branch reset did not cleanly reach the selected target' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$reset_step_hash"
printf 'untracked survives reset\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-untracked.txt"
send_keys "$porcelain_session" g O
if lem_wait_for "$porcelain_session" 'Reset' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" b
fi
if lem_wait_for "$porcelain_session" 'Reset branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$reset_current_branch" 'Reset branch:'
fi
if lem_wait_for "$porcelain_session" "Reset $reset_current_branch to:" \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$reset_base_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_reset_clean_at "$reset_base_hash" &&
   [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-untracked.txt")" = \
     'untracked survives reset' ]; then
  pass legit-reset-branch-untracked \
    'current branch reset ignored and preserved an untracked-only change'
else
  fail legit-reset-branch-untracked \
    'untracked-only state prompted, blocked, or was removed by branch reset' \
    "$porcelain_session"
fi

if prepare_porcelain_merge_fixture; then
  pass legit-merge-fixture \
    'prepared divergent plain, edit, squash, preview, and conflict branches'
else
  fail legit-merge-fixture 'could not prepare the isolated merge history' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" g

printf 'dirty merge guard\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/reset-keep.txt"
send_keys "$porcelain_session" g m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Merge:' "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    merge-plain 'Merge:'
fi
if lem_wait_for "$porcelain_session" 'Merging with dirty worktree is risky' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if [ "$merge_main_hash" = \
     "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
   [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/reset-keep.txt")" = \
     'dirty merge guard' ]; then
  pass legit-merge-dirty-decline \
    'm m preserved HEAD and tracked worktree state when risk was declined'
else
  fail legit-merge-dirty-decline \
    'declining the dirty-worktree warning still changed repository state' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -- \
  reset-keep.txt
send_keys "$porcelain_session" g

send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - n
fi
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" + s
fi
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Merge:' "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    merge-plain 'Merge:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_plain_complete &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" log -1 --format=%B |
     grep -q '^Signed-off-by: Lem Yath Test <lem-yath-test@example.invalid>$'; then
  pass legit-merge-plain \
    'm m merged with persistent no-ff/signoff options and a two-parent commit'
else
  fail legit-merge-plain \
    'plain merge lost its branch, parent, cleanliness, or option semantics' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
send_keys "$porcelain_session" g

send_keys "$porcelain_session" l l m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" p
fi
if lem_wait_for "$porcelain_session" 'Preview merge:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    merge-preview 'Preview merge:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_clean_at_main &&
   lem_wait_for "$porcelain_session" 'merge-preview.txt' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-merge-preview \
    'log m p retained its prospective preview without changing repository state'
else
  fail legit-merge-preview \
    'a log-origin merge preview was overwritten, mutated state, or omitted its change' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" s
fi
if lem_wait_for "$porcelain_session" 'Squash:' "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" merge-squash
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_squashed &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-merge-squash \
    'm s staged the selected tree without moving HEAD or creating MERGE_HEAD'
else
  fail legit-merge-squash \
    'squash merge moved HEAD, created merge metadata, or lost staged content' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
send_keys "$porcelain_session" C-c f g

send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if lem_wait_for "$porcelain_session" 'Merge without committing:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" merge-nocommit
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_no_commit &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-merge-nocommit \
    'm n retained HEAD and prepared an explicit in-progress merge'
else
  fail legit-merge-nocommit \
    'no-commit merge failed to preserve the expected merge boundary' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" 'abort merge' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Abort merge' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_clean_at_main; then
  pass legit-merge-abort \
    'in-progress m a restored the exact pre-merge HEAD, index, and worktree'
else
  fail legit-merge-abort \
    'merge abort retained metadata or changed the pre-merge state' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g l l m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" e
fi
if lem_wait_for "$porcelain_session" 'Merge without committing:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" merge-edit
fi
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" g g d d i
  tmux_cmd send-keys -t "$porcelain_session" -l -- \
    'merge message edited in Lem'
  send_keys "$porcelain_session" Escape C-c C-c
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_subject_is \
     'merge message edited in Lem'; then
  pass legit-merge-edit \
    'log m e opened the prefilled Legit message buffer and committed its edit'
else
  fail legit-merge-edit \
    'merge edit did not create the user-edited merge commit' \
    "$porcelain_session"
fi
log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=yes\ status=no\ state=yes\ hash=yes\ line=*merge-main*\ offset=0 ]]; then
  pass legit-merge-edit-log-refresh \
    'confirming the merge message returned to the originating log and commit'
else
  fail legit-merge-edit-log-refresh \
    'confirming the merge message dropped to status or lost its log anchor' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" q
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
send_keys "$porcelain_session" g

send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Merge:' "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" merge-conflict
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_conflicted &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-merge-conflict \
    'm m retained a real unmerged index and MERGE_HEAD on conflict'
else
  fail legit-merge-conflict \
    'conflicting merge did not remain available for resolution' \
    "$porcelain_session"
fi
printf 'resolved merge value\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- merge-conflict.txt
send_keys "$porcelain_session" g m
if lem_wait_for "$porcelain_session" 'commit merge' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" g g d d i
  tmux_cmd send-keys -t "$porcelain_session" -l -- \
    'resolved merge committed in Lem'
  send_keys "$porcelain_session" Escape C-c C-c
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_subject_is \
     'resolved merge committed in Lem' &&
   [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt")" = \
     'resolved merge value' ]; then
  pass legit-merge-continue \
    'in-progress m m committed the resolved merge through the native buffer'
else
  fail legit-merge-continue \
    'resolved merge did not commit with the edited message and content' \
    "$porcelain_session"
fi

if prepare_porcelain_revert_fixture; then
  pass legit-revert-fixture \
    'prepared clean, merge, multi-commit, and conflicting revert histories'
else
  fail legit-revert-fixture 'could not prepare the isolated revert histories' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - E
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" + s
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$revert_noedit_hash" 'Revert commit\(s\):'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_noedit_complete; then
  pass legit-revert-noedit \
    '_ _ created a signed-off reverse commit without opening an editor'
else
  fail legit-revert-noedit \
    'non-editing revert lost its commit, signoff, tree, or clean boundary' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q revert-edit
send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    "$revert_edit_hash" 'Revert commit\(s\):'
fi
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" g g d d i
  tmux_cmd send-keys -t "$porcelain_session" -l -- \
    'revert message edited in Lem'
  send_keys "$porcelain_session" Enter Enter
  send_keys "$porcelain_session" Escape C-c C-c
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_subject_is \
     'revert message edited in Lem' &&
   [ ! -e "$LEM_YATH_VCS_PORCELAIN_ROOT/revert-edit.txt" ]; then
  pass legit-revert-edit \
    'default _ _ opened and committed a prefilled native message buffer'
else
  fail legit-revert-edit \
    'editable revert did not commit the edited message and reverse tree' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q revert-nocommit
send_keys "$porcelain_session" g -
if lem_wait_for "$porcelain_session" 'Revert changes from:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" "$revert_nocommit_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_no_commit_complete &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-revert-no-commit \
    'direct - staged the inverse tree without moving HEAD and retained abort state'
else
  fail legit-revert-no-commit \
    'no-commit revert moved HEAD or lost its staged active boundary' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$revert_nocommit_hash"

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q revert-multi
send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - E
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" \
    "$revert_multi_b_hash,$revert_multi_a_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_multi_complete &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-revert-multiple \
    'comma-separated _ _ reverted two commits in the requested order'
else
  fail legit-revert-multiple \
    'multi-commit revert lost ordering, commit count, or exact trees' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q revert-merge
send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - m
fi
if lem_wait_for "$porcelain_session" 'Mainline parent:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" 1
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - E
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" "$revert_merge_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_merge_complete &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-revert-mainline \
    '_ -m reverted a merge relative to parent one and retained mainline content'
else
  fail legit-revert-mainline \
    'merge revert ignored or misapplied its selected mainline parent' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q revert-conflict
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$revert_conflict_tip"
send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - E
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" "$revert_conflict_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_conflicted &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-revert-conflict \
    'a conflicting _ _ retained REVERT_HEAD and the unmerged index'
else
  fail legit-revert-conflict \
    'conflicting revert did not retain recoverable sequencer state' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" 'abort revert' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Really abort revert' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_abort_complete; then
  pass legit-revert-abort \
    'active _ a restored the exact pre-revert HEAD, index, and worktree'
else
  fail legit-revert-abort \
    'revert abort did not restore the exact conflict baseline' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" "$revert_conflict_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_conflicted &&
   wait_legit "$porcelain_session" porcelain; then
  printf 'merge main value\n' \
    >"$LEM_YATH_VCS_PORCELAIN_ROOT/merge-conflict.txt"
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -- merge-conflict.txt
  send_keys "$porcelain_session" g _
fi
if lem_wait_for "$porcelain_session" 'continue revert' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_continue_complete; then
  pass legit-revert-continue \
    'active _ _ committed a physically resolved revert with Git prepared text'
else
  fail legit-revert-continue \
    'resolved revert did not continue with the prepared sequencer message' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q revert-skip
send_keys "$porcelain_session" g _
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" - E
fi
if lem_wait_for "$porcelain_session" '\[Revert\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" _
fi
if lem_wait_for "$porcelain_session" 'Revert commit\(s\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" \
    "$revert_skip_conflict_hash,$revert_skip_clean_hash"
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_conflicted &&
   wait_legit "$porcelain_session" porcelain; then
  send_keys "$porcelain_session" g _
fi
if lem_wait_for "$porcelain_session" 'skip commit' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" s
fi
if wait_until "$WAIT_TIMEOUT" porcelain_revert_skip_complete; then
  pass legit-revert-skip \
    'active _ s skipped the conflict and reverted the remaining clean commit'
else
  fail legit-revert-skip \
    'revert skip lost the current tree or failed to continue the sequence' \
    "$porcelain_session"
fi

if prepare_porcelain_branch_fixture; then
  pass legit-branch-fixture \
    'prepared local, remote, unmerged, current, and spin branch histories'
else
  fail legit-branch-fixture 'could not prepare isolated branch histories' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" b
fi
if lem_wait_for "$porcelain_session" 'Checkout branch or revision:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-checkout \
    'Checkout branch or revision:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_current_is branch-checkout; then
  pass legit-branch-checkout 'b b checked out the selected branch/revision'
else
  fail legit-branch-checkout 'branch/revision checkout did not move HEAD' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" l
fi
if lem_wait_for "$porcelain_session" 'Checkout local branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin/remote-topic \
    'Checkout local branch:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_remote_checkout_complete; then
  pass legit-branch-remote-checkout \
    'b l created a local tracking branch and configured its push remote'
else
  fail legit-branch-remote-checkout \
    'remote checkout lost its hash, upstream, local name, or push remote' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" c
fi
if lem_wait_for "$porcelain_session" \
     'Create and checkout branch starting at:' "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" "$merge_main_hash" \
    'Create and checkout branch starting at:'
fi
if lem_wait_for "$porcelain_session" \
     'Name for create and checkout branch:' "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-created
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_created_complete; then
  pass legit-branch-create-checkout \
    'b c used Magit upstream-first prompting and checked out the new branch'
else
  fail legit-branch-create-checkout \
    'create-and-checkout lost its selected start point or branch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if lem_wait_for "$porcelain_session" 'Create branch starting at:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" "$merge_main_hash" \
    'Create branch starting at:'
fi
if lem_wait_for "$porcelain_session" 'Name for create branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-no-checkout
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_no_checkout_complete; then
  pass legit-branch-create \
    'b n created the selected branch without moving HEAD'
else
  fail legit-branch-create \
    'create-without-checkout moved HEAD or used the wrong start point' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" o
fi
if lem_wait_for "$porcelain_session" \
     'Create and checkout orphan branch starting at:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" "$merge_main_hash" \
    'Create and checkout orphan branch starting at:'
fi
if lem_wait_for "$porcelain_session" \
     'Name for create and checkout orphan branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-orphan
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_orphan_complete; then
  pass legit-branch-orphan \
    'b o created an unborn orphan HEAD with the selected staged tree'
else
  fail legit-branch-orphan \
    'orphan checkout retained a parent or lost its staged starting tree' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -f branch-created
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
send_keys "$porcelain_session" g

send_keys "$porcelain_session" b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Rename branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-no-checkout \
    'Rename branch:'
fi
if lem_wait_for "$porcelain_session" \
     "Rename branch 'branch-no-checkout' to:" \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-renamed
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_renamed_complete; then
  pass legit-branch-rename 'b m renamed the selected non-current branch'
else
  fail legit-branch-rename 'branch rename retained the old ref or lost the new ref' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Rename branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-remote-rename \
    'Rename branch:'
fi
if lem_wait_for "$porcelain_session" \
     "Rename branch 'branch-remote-rename' to:" \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-remote-renamed
fi
if lem_wait_for "$porcelain_session" \
     'Also rename branch-remote-rename to branch-remote-renamed on origin' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_remote_renamed_complete; then
  pass legit-branch-rename-remote \
    'b m preserved the divergent remote commit while renaming its push target'
else
  fail legit-branch-rename-remote \
    'remote-aware rename lost local config, rewrote the remote tip, or retained an old ref' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" h
fi
if lem_wait_for "$porcelain_session" 'Shelve branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-shelve \
    'Shelve branch:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_shelved_complete; then
  pass legit-branch-shelve \
    'b h moved the branch, reflog, and pushRemote boundary under refs/shelved'
else
  fail legit-branch-shelve \
    'shelving retained the local ref/config or lost the dated ref/reflog' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" H
fi
if lem_wait_for "$porcelain_session" 'Unshelve branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" "$branch_shelved_name" \
    'Unshelve branch:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_unshelved_complete; then
  pass legit-branch-unshelve \
    'b H restored the date-stripped branch and reflog without reviving pushRemote'
else
  fail legit-branch-unshelve \
    'unshelving retained the shelf or lost the restored branch/reflog' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" x
fi
if lem_wait_for "$porcelain_session" 'Delete branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" remote-delete \
    'Deleting local refs/remotes/origin/remote-delete'
fi
if lem_wait_for "$porcelain_session" \
     'Deleting local refs/remotes/origin/remote-delete; also delete on origin' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_remote_deleted_complete; then
  pass legit-branch-delete-remote \
    'b x deleted the selected tracking ref and its confirmed remote branch'
else
  fail legit-branch-delete-remote \
    'confirmed remote deletion retained a local or remote ref' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" x
fi
if lem_wait_for "$porcelain_session" 'Delete branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" remote-keep \
    'Deleting local refs/remotes/origin/remote-keep'
fi
if lem_wait_for "$porcelain_session" \
     'Deleting local refs/remotes/origin/remote-keep; also delete on origin' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_remote_local_only_complete; then
  pass legit-branch-delete-tracking-only \
    'declining b x removed only the stale local tracking ref'
else
  fail legit-branch-delete-tracking-only \
    'tracking-only deletion retained the local ref or removed the remote branch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" C
fi
if lem_wait_for "$porcelain_session" 'Configure branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" branch-renamed
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" d
fi
if lem_wait_for "$porcelain_session" \
     'Description for branch-renamed' "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" 'configured branch description'
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" u
fi
if lem_wait_for "$porcelain_session" 'Upstream for branch-renamed:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" origin/remote-topic
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" r
fi
if lem_wait_for "$porcelain_session" 'Rebase when pulling branch-renamed:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" true
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" p
fi
if lem_wait_for "$porcelain_session" 'Push remote for branch-renamed:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" origin
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" R
fi
if lem_wait_for "$porcelain_session" 'Repository pull.rebase:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" true
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" P
fi
if lem_wait_for "$porcelain_session" 'Repository push default:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" origin
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a m
fi
if lem_wait_for "$porcelain_session" 'Automatic upstream setup:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" always
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a r
fi
if lem_wait_for "$porcelain_session" 'Automatic rebase setup:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" remote
fi
if lem_wait_for "$porcelain_session" '\[Configure branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" q
fi
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" q
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_config_complete &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-branch-configure \
    'b C persisted branch and repository configuration through the live popup'
else
  fail legit-branch-configure \
    'branch configuration lost description, upstream, rebase, or remote values' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" X
fi
if lem_wait_for "$porcelain_session" 'Reset branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-renamed \
    'Reset branch:'
fi
if lem_wait_for "$porcelain_session" 'Reset branch-renamed to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" "$branch_remote_hash" \
    'Reset branch-renamed to:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_reset_complete; then
  pass legit-branch-reset \
    'Evil-remapped b X reset a non-current branch without moving HEAD'
else
  fail legit-branch-reset 'branch reset changed HEAD or used the wrong target' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" x
fi
if lem_wait_for "$porcelain_session" 'Delete branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-delete-merged \
    'Delete branch:'
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_absent branch-delete-merged; then
  pass legit-branch-delete-merged \
    'Evil-remapped b x deleted a branch already merged into HEAD'
else
  fail legit-branch-delete-merged 'safe branch deletion retained its ref' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" x
fi
if lem_wait_for "$porcelain_session" 'Delete branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-delete-unmerged \
    'Delete branch:'
fi
if lem_wait_for "$porcelain_session" 'Force delete' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     show-ref --verify --quiet refs/heads/branch-delete-unmerged; then
  pass legit-branch-delete-decline \
    'b x retained an unmerged branch when force deletion was declined'
else
  fail legit-branch-delete-decline \
    'declining unmerged deletion still removed the branch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" x
fi
if lem_wait_for "$porcelain_session" 'Delete branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" branch-delete-unmerged \
    'Delete branch:'
fi
if lem_wait_for "$porcelain_session" 'Force delete' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_absent branch-delete-unmerged; then
  pass legit-branch-delete-force \
    'b x force-deleted the unmerged branch only after confirmation'
else
  fail legit-branch-delete-force 'confirmed unmerged deletion retained the ref' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q \
  branch-current-delete
send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" x
fi
if lem_wait_for "$porcelain_session" 'Delete branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" branch-current-delete
fi
if lem_wait_for "$porcelain_session" 'switch before deleting:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" branch-created
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_current_is branch-created &&
   porcelain_branch_absent branch-current-delete &&
   wait_legit "$porcelain_session" porcelain; then
  pass legit-branch-delete-current \
    'b x switched away before deleting the current branch'
else
  fail legit-branch-delete-current \
    'current-branch deletion lost its selected safe checkout boundary' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q \
  branch-spinoff-region-source
branch_region_prompted=0
send_keys "$porcelain_session" g l l
if lem_wait_for "$porcelain_session" 'branch-spinoff-region-two' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" j V k b
fi
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" s
fi
if lem_wait_for "$porcelain_session" 'Spin off branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  branch_region_prompted=1
  enter_prompt_value "$porcelain_session" branch-spun-off-region
fi
if ((branch_region_prompted == 1)) &&
   wait_until "$WAIT_TIMEOUT" porcelain_branch_spinoff_region_complete; then
  pass legit-branch-spinoff-visual-region \
    'reversed Visual b s moved only the two selected commits and retained their parent'
else
  fail legit-branch-spinoff-visual-region \
    'Visual b s lost its oldest selected boundary or reset the entire unpushed range' \
    "$porcelain_session"
fi

log_action_before=$(report_count '^LOG-ACTION ')
send_keys "$porcelain_session" C-c L
if wait_report_count '^LOG-ACTION ' "$((log_action_before + 1))" &&
   [[ $(latest_report '^LOG-ACTION ') == \
      LOG-ACTION\ log=yes\ status=no\ state=yes\ hash=yes\ line=*branch-spinoff-region-keep*\ offset=0 ]]; then
  pass legit-branch-spinoff-log-refresh \
    'Visual branch spin-off refreshed its source log and fell back when the commit moved'
else
  fail legit-branch-spinoff-log-refresh \
    'Visual branch spin-off dropped to status or missed the vanished-commit fallback' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" q

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q \
  branch-spinoff-source
send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" s
fi
if lem_wait_for "$porcelain_session" 'Spin off branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-spun-off
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_spinoff_complete; then
  pass legit-branch-spinoff \
    'b s moved unpushed commits to a new checked-out tracking branch'
else
  fail legit-branch-spinoff \
    'spin-off lost commits, upstream, source reset, or checkout state' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q \
  branch-spinout-source
send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" S
fi
if lem_wait_for "$porcelain_session" 'Spin out branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-spun-out
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_spinout_complete; then
  pass legit-branch-spinout \
    'b S retained the source checkout while moving its unpushed commits'
else
  fail legit-branch-spinout \
    'spin-out lost its source checkout, new tip, reset, or clean tree' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q \
  branch-dirty-source
printf 'dirty worktree survives\n' \
  >>"$LEM_YATH_VCS_PORCELAIN_ROOT/branch-dirty.txt"
send_keys "$porcelain_session" g b
if lem_wait_for "$porcelain_session" '\[Branch\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" S
fi
if lem_wait_for "$porcelain_session" 'Spin out branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" branch-dirty-spin
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_dirty_spinout_complete; then
  pass legit-branch-spinout-dirty \
    'dirty b S followed Magit by checking out the new branch and retaining edits'
else
  fail legit-branch-spinout-dirty \
    'dirty spin-out lost the worktree, source reset, new tip, or checkout' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -f main
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"

if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
     "$merge_main_hash":refs/heads/primary-next &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
     refs/remotes/origin/primary-next "$merge_main_hash" &&
   "$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" symbolic-ref \
     HEAD refs/heads/primary-next; then
  send_keys "$porcelain_session" g b
  if lem_wait_for "$porcelain_session" '\[Branch\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" B
  fi
  if lem_wait_for "$porcelain_session" \
       'Default changed from main to primary-next on origin' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" y
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_branch_default_updated_complete; then
    pass legit-branch-update-default \
      'b B refreshed origin/HEAD, renamed the local default, and migrated upstreams'
  else
    fail legit-branch-update-default \
      'default migration lost the local rename, remote HEAD, or follower upstream' \
      "$porcelain_session"
  fi
else
  fail legit-branch-update-default-fixture \
    'could not move the disposable remote default branch' \
    "$porcelain_session"
fi

if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     show-ref --verify --quiet refs/heads/primary-next &&
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     show-ref --verify --quiet refs/heads/main; then
  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -m \
    primary-next main
fi
if ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -f main ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
     --set-upstream-to=origin/main main >/dev/null ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch \
     --set-upstream-to=origin/main default-follower >/dev/null ||
   ! "$git_bin" --git-dir="$LEM_YATH_VCS_PORCELAIN_REMOTE" symbolic-ref \
     HEAD refs/heads/main ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" remote set-head \
     origin main ||
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" push -q origin \
     --delete primary-next; then
  fail legit-branch-update-default-restore \
    'could not restore main after the isolated default-migration check' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref -d \
  refs/remotes/origin/primary-next
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"

pull_fixture_ready=0
if prepare_porcelain_pull_fixture; then
  pass legit-pull-fixture \
    'prepared push-remote, upstream, elsewhere, rebase, refusal, and conflict histories'
  pull_fixture_ready=1
else
  fail legit-pull-fixture 'could not prepare isolated pull histories' \
    "$porcelain_session"
fi

if [ "$pull_fixture_ready" = 1 ]; then
  send_keys "$porcelain_session" g F
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" p
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_pushremote_complete; then
    pass legit-pull-pushremote \
      'F p fast-forwarded from the configured push remote without creating an upstream'
  else
    fail legit-pull-pushremote \
      'F p lost the push-remote destination, branch boundary, or clean state' \
      "$porcelain_session"
  fi

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q pull-upstream
  send_keys "$porcelain_session" g F
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" u
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_upstream_complete; then
    pass legit-pull-upstream \
      'F u fast-forwarded from the exact configured upstream'
  else
    fail legit-pull-upstream \
      'F u did not retain the upstream, expected tip, and clean state' \
      "$porcelain_session"
  fi

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q pull-elsewhere
  send_keys "$porcelain_session" g F
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" e
  fi
  if lem_wait_for "$porcelain_session" 'Pull from remote branch:' \
       "$WAIT_TIMEOUT" >/dev/null; then
    enter_completion_prompt_value "$porcelain_session" \
      -push-option/pull-elsewhere-source 'Pull from remote branch:'
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_elsewhere_complete; then
    pass legit-pull-elsewhere \
      'F e pulled an explicit option-like configured remote through the argv boundary'
  else
    fail legit-pull-elsewhere \
      'F e lost the explicit remote branch, option boundary, or clean state' \
      "$porcelain_session"
  fi
  if ! wait_legit "$porcelain_session" porcelain; then
    fail legit-pull-elsewhere-ui \
      'the elsewhere pull did not finish its synchronous status refresh' \
      "$porcelain_session"
  fi

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q pull-rebase
  send_keys "$porcelain_session" g F
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" r
  fi
  if lem_wait_for "$porcelain_session" 'Rebase when pulling pull-rebase:' \
       "$WAIT_TIMEOUT" >/dev/null; then
    enter_completion_prompt_value "$porcelain_session" true \
      'Rebase when pulling pull-rebase:'
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_rebase_configured; then
    pass legit-pull-configure-rebase \
      'F r persisted the current branch pull-rebase variable'
  else
    fail legit-pull-configure-rebase \
      'F r did not preserve the pinned branch configuration action' \
      "$porcelain_session"
  fi
  # The old popup can remain painted while the completion result is still
  # being consumed.  Wait for the configuration side effect above before
  # looking for the re-rendered popup, and cancel with Escape so a delayed key
  # cannot quit the underlying Legit status buffer.
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" Escape
  fi
  if ! wait_legit "$porcelain_session" porcelain; then
    fail legit-pull-configure-rebase-ui \
      'the pull configuration action did not return to an interactive Legit status' \
      "$porcelain_session"
  fi

  send_keys "$porcelain_session" F
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
    send_keys "$porcelain_session" r u
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_rebase_complete; then
    pass legit-pull-rebase \
      'F -r u rebased the local commit onto the fetched upstream tip'
  else
    fail legit-pull-rebase \
      'the rebase pull lost topology, either side content, or sequencer cleanup' \
      "$porcelain_session"
  fi

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q pull-refusal
  send_keys "$porcelain_session" g F
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
    send_keys "$porcelain_session" f u
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_ff_refused; then
    pass legit-pull-ff-only-refusal \
      'F -f u refused divergent history without moving HEAD or retaining operation state'
  else
    fail legit-pull-ff-only-refusal \
      'fast-forward-only pull mutated divergent history or retained Git state' \
      "$porcelain_session"
  fi
  # Ordinary pull failures use Legit's bounded error popup.  Dismiss it before
  # proving that a subsequent pull starts from an interactive status pane.
  if lem_wait_for "$porcelain_session" 'Press Space to continue' 2 \
       >/dev/null 2>&1; then
    send_keys "$porcelain_session" Space
  fi
  if ! wait_legit "$porcelain_session" porcelain; then
    fail legit-pull-ff-only-refusal-ui \
      'the refusal did not return to an interactive Legit status' \
      "$porcelain_session"
  fi

  "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q pull-conflict
  send_keys "$porcelain_session" g F
  if lem_wait_for "$porcelain_session" '\[Pull\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" u
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_conflicted &&
     wait_legit "$porcelain_session" porcelain &&
     porcelain_pull_conflicted; then
    pass legit-pull-conflict \
      'F u retained the exact local HEAD, unmerged index, and MERGE_HEAD on conflict'
  else
    fail legit-pull-conflict \
      'a conflicting pull lost its local HEAD or recoverable merge state' \
      "$porcelain_session"
  fi
  send_keys "$porcelain_session" m
  if lem_wait_for "$porcelain_session" 'abort merge' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" a
  fi
  if lem_wait_for "$porcelain_session" 'Abort merge' \
       "$WAIT_TIMEOUT" >/dev/null; then
    send_keys "$porcelain_session" y
  fi
  if wait_until "$WAIT_TIMEOUT" porcelain_pull_conflict_aborted; then
    pass legit-pull-conflict-abort \
      'the ordinary merge abort restored the exact pre-pull HEAD, index, and worktree'
  else
    fail legit-pull-conflict-abort \
      'aborting a conflicting pull did not restore the pre-pull repository' \
      "$porcelain_session"
  fi
fi

if prepare_porcelain_push_fixture; then
  pass legit-push-fixture \
    'prepared push-remote, upstream, tag, notes, matching, and divergent refs'
else
  fail legit-push-fixture 'could not prepare isolated push histories' \
    "$porcelain_session"
fi

# Push is a network/process-heavy boundary and follows several deliberately
# retained interactive Git editor sessions.  Start it in a fresh installed
# Lem process so failures cannot be confused with stale editor callbacks from
# the preceding rebase, cherry-pick, merge, and branch lifecycle tests.
lem_stop "$porcelain_session"
porcelain_session="lem-yath-vcs-push-$id"
if start_phase porcelain "$LEM_YATH_VCS_PORCELAIN_FILE" \
  "$porcelain_session"; then
  pass porcelain-push-restart \
    'restarted the installed wrapper at the isolated push boundary'
else
  fail porcelain-push-restart \
    'the isolated push editor did not become ready' "$porcelain_session"
fi
send_keys "$porcelain_session" Space g G
if wait_legit "$porcelain_session" porcelain; then
  pass legit-push-status 'the fresh editor opened push-current in Legit'
else
  fail legit-push-status 'the fresh push status did not become interactive' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" p
fi
if porcelain_push_settled porcelain_push_remote_complete; then
  pass legit-push-remote \
    'Evil Collection p p pushed the current branch to its push remote'
else
  fail legit-push-remote 'p p did not update the configured remote branch' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q push-upstream
send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" u
fi
if porcelain_push_settled porcelain_push_upstream_complete; then
  pass legit-push-upstream 'p u pushed the current branch to its upstream'
else
  fail legit-push-upstream 'p u did not update the configured upstream' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q push-current
printf '#!/bin/sh\nexit 1\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/.git/hooks/pre-push"
chmod +x "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/hooks/pre-push"
send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" h
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" u
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" t e
fi
if lem_wait_for "$porcelain_session" 'Push push-current to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin/push-elsewhere \
    'Push push-current to:'
fi
rm -f -- "$LEM_YATH_VCS_PORCELAIN_ROOT/.git/hooks/pre-push"
if porcelain_push_settled porcelain_push_elsewhere_complete; then
  pass legit-push-elsewhere \
    'p -h -u -t e bypassed the hook, set upstream, and followed its tag'
else
  fail legit-push-elsewhere \
    'elsewhere push lost its ref, upstream, no-verify, or follow-tags effect' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" n o
fi
if lem_wait_for "$porcelain_session" 'Push source branch or commit:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" push-other-source \
    'Push push-other-source to:'
fi
if lem_wait_for "$porcelain_session" 'Push push-other-source to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin/push-dry-run \
    'Push push-other-source to:'
fi
push_dry_run_finished=0
if wait_legit "$porcelain_session" porcelain; then
  push_dry_run_finished=1
fi
if [ "$push_dry_run_finished" = 1 ] &&
   porcelain_push_dry_run_complete; then
  pass legit-push-dry-run \
    'p -n o refreshed after a dry run without creating the remote branch'
else
  fail legit-push-dry-run \
    'dry-run push did not finish responsively or mutated the bare remote' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" o
fi
if lem_wait_for "$porcelain_session" 'Push source branch or commit:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" push-other-source \
    'Push push-other-source to:'
fi
if lem_wait_for "$porcelain_session" 'Push push-other-source to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    -push-option/push-other-target \
    'Push push-other-source to:'
fi
if porcelain_push_settled porcelain_push_other_complete; then
  pass legit-push-other \
    'p o pushed an arbitrary source through an option-like remote safely'
else
  fail legit-push-other 'arbitrary-source push did not create its target ref' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" r
fi
if lem_wait_for "$porcelain_session" 'Push to remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" origin \
    'Push refspecs \(comma separated\):'
fi
if lem_wait_for "$porcelain_session" 'Push refspecs \(comma separated\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" \
    'push-other-source:refs/heads/push-explicit,refs/tags/push-one:refs/tags/push-explicit-tag'
fi
if porcelain_push_settled porcelain_push_refspecs_complete; then
  pass legit-push-refspecs \
    'p r pushed two comma-separated direct-argv refspecs exactly'
else
  fail legit-push-refspecs 'explicit refspec push lost a branch or tag ref' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Push matching branches to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  submit_atomic_prompt_value "$porcelain_session" push-target
fi
if porcelain_push_settled porcelain_push_matching_complete; then
  pass legit-push-matching 'p m updated branches present on both sides'
else
  fail legit-push-matching 'matching push did not update its shared branch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" T
fi
if lem_wait_for "$porcelain_session" 'Push tag:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" push-one \
    'Push push-one to remote:'
fi
if lem_wait_for "$porcelain_session" 'Push push-one to remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin \
    'Push push-one to remote:'
fi
if porcelain_push_settled porcelain_push_one_tag_complete; then
  pass legit-push-tag 'p T pushed exactly the selected annotated tag'
else
  fail legit-push-tag 'selected-tag push did not preserve the tag object' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" t
fi
if lem_wait_for "$porcelain_session" 'Push all tags to remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin \
    'Push all tags to remote:'
fi
if porcelain_push_settled porcelain_push_all_tags_complete; then
  pass legit-push-tags 'p t pushed the complete local tag namespace'
else
  fail legit-push-tags 'all-tags push omitted the additional tag' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if lem_wait_for "$porcelain_session" 'Push notes ref:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" refs/notes/review \
    'Push refs/notes/review to remote:'
fi
if lem_wait_for "$porcelain_session" 'Push refs/notes/review to remote:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin \
    'Push refs/notes/review to remote:'
fi
if porcelain_push_settled porcelain_push_notes_complete; then
  pass legit-push-notes 'p n pushed the selected notes ref without a shell'
else
  fail legit-push-notes 'notes push did not preserve the selected notes ref' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q push-force
send_keys "$porcelain_session" g p
if lem_wait_for "$porcelain_session" '\[Push\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" f e
fi
if lem_wait_for "$porcelain_session" 'Push push-force to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" origin/push-force \
    'Push push-force to:'
fi
if porcelain_push_settled porcelain_push_force_with_lease_complete; then
  pass legit-push-force-with-lease \
    'p -f e replaced a divergent remote only under the observed lease'
else
  fail legit-push-force-with-lease \
    'force-with-lease did not replace the exact observed remote tip' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q main
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
send_keys "$porcelain_session" g

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
send_keys "$porcelain_session" g m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" d
fi
if lem_wait_for "$porcelain_session" 'Merge main into:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    merge-dissolve 'Merge main into:'
fi
if lem_wait_for "$porcelain_session" 'Do you really want to merge main branch main' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if porcelain_merge_clean_at_main &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     show-ref --verify --quiet refs/heads/main; then
  pass legit-merge-main-protection \
    'm d refused to dissolve the configured main branch when declined'
else
  fail legit-merge-main-protection \
    'declining main-branch dissolution still changed or removed main' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Absorb branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    merge-absorb 'Absorb branch:'
fi
if lem_wait_for "$porcelain_session" \
     'Absorb merge-absorb into main and delete merge-absorb after success' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if lem_wait_for "$porcelain_session" \
     'Force-push merge-absorb to origin/merge-absorb with lease' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_absorbed; then
  pass legit-merge-absorb \
    'm a lease-pushed, merged with PR context, and deleted only the local source'
else
  fail legit-merge-absorb \
    'absorb lost its lease update, merge, message, or deletion boundary' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q merge-dissolve
send_keys "$porcelain_session" g m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" d
fi
if lem_wait_for "$porcelain_session" 'Merge merge-dissolve into:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" main \
    'Merge merge-dissolve into:'
fi
if lem_wait_for "$porcelain_session" \
     'Dissolve merge-dissolve into main and delete merge-dissolve after success' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_dissolved; then
  pass legit-merge-dissolve \
    'm d switched targets, merged the former branch, and deleted it after success'
else
  fail legit-merge-dissolve \
    'dissolve lost its checkout, merge, content, or deletion boundary' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
send_keys "$porcelain_session" g m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Absorb branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    merge-conflict 'Absorb branch:'
fi
if lem_wait_for "$porcelain_session" \
     'Absorb merge-conflict into main and delete merge-conflict after success' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_conflicted &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     show-ref --verify --quiet refs/heads/merge-conflict; then
  pass legit-merge-absorb-conflict \
    'a conflicting absorb retained MERGE_HEAD, the unmerged index, and source branch'
else
  fail legit-merge-absorb-conflict \
    'a conflicting absorb deleted its source or lost recoverable merge state' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" 'abort merge' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Abort merge' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_clean_at_main; then
  pass legit-merge-absorb-abort \
    'the ordinary active-merge abort restored a failed absorb exactly'
else
  fail legit-merge-absorb-abort \
    'aborting a failed absorb did not restore the target branch' \
    "$porcelain_session"
fi

merge_absorb_target_hash=$("$git_bin" \
  -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)
# Default-branch migration intentionally fetches all refs.  Re-establish the
# recorded stale observation at the exact lease test boundary.
if ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" update-ref \
     refs/remotes/origin/merge-lease-fail "$merge_lease_tracking_hash"; then
  fail legit-merge-lease-fixture \
    'could not restore the deliberately stale remote-tracking observation' \
    "$porcelain_session"
fi
send_keys "$porcelain_session" g m
if lem_wait_for "$porcelain_session" '\[Merge\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Absorb branch:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    merge-lease-fail 'Absorb branch:'
fi
if lem_wait_for "$porcelain_session" \
     'Absorb merge-lease-fail into main and delete merge-lease-fail after success' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if lem_wait_for "$porcelain_session" \
     'Force-push merge-lease-fail to origin/merge-lease-fail with lease' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_merge_lease_refused; then
  pass legit-merge-lease-refusal \
    'a stale force-with-lease stopped absorb before merge or deletion'
else
  fail legit-merge-lease-refusal \
    'a rejected lease still merged, deleted, or overwrote the remote branch' \
    "$porcelain_session"
fi

# The worktree dispatch is deliberately isolated in its own module.  The
# expected stale-lease failure above leaves Legit's process error popup active,
# while create, move, visit, and current-worktree deletion replace the status
# root by design.  Start a fresh installed editor at this boundary so neither
# state can consume the first `Z` dispatch event.
lem_stop "$porcelain_session"
porcelain_session="lem-yath-vcs-worktree-$id"
if start_phase porcelain "$LEM_YATH_VCS_PORCELAIN_FILE" \
  "$porcelain_session"; then
  pass porcelain-worktree-restart \
    'restarted the installed wrapper at the isolated worktree boundary'
else
  fail porcelain-worktree-restart \
    'the isolated worktree editor did not become ready' "$porcelain_session"
fi
send_keys "$porcelain_session" Space g G
if wait_legit "$porcelain_session" porcelain; then
  pass legit-worktree-status \
    'the fresh editor opened the primary repository in Legit'
else
  fail legit-worktree-status \
    'the fresh worktree status did not become interactive' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" checkout -q -f main
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" reset -q --hard \
  "$merge_main_hash"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" branch -f \
  worktree-checkout "$merge_main_hash"

send_keys "$porcelain_session" l l
if ! lem_wait_for "$porcelain_session" 'Current log' \
     "$WAIT_TIMEOUT" >/dev/null; then
  fail legit-worktree-log-origin \
    'could not open the current log before the root-changing worktree action' \
    "$porcelain_session"
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" b
fi
if lem_wait_for "$porcelain_session" 'In new worktree; checkout:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value_until "$porcelain_session" \
    worktree-checkout 'Checkout worktree-checkout in new worktree:'
fi
if lem_wait_for "$porcelain_session" \
     'Checkout worktree-checkout in new worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_path_prompt_value "$porcelain_session" \
    "$LEM_YATH_VCS_WORKTREE_CHECKOUT" \
    'Checkout worktree-checkout in new worktree:'
fi
if wait_until "$WAIT_TIMEOUT" test -f \
     "$LEM_YATH_VCS_WORKTREE_CHECKOUT/.git" &&
   [ "$("$git_bin" -C "$LEM_YATH_VCS_WORKTREE_CHECKOUT" \
       branch --show-current)" = worktree-checkout ] &&
   lem_wait_for "$porcelain_session" 'Branch: worktree-checkout' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-worktree-checkout \
    'log Z b created, registered, visited, and displayed a metacharacter path'
else
  fail legit-worktree-checkout \
    'log Z b did not preserve the selected root-changing worktree visit' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" g
fi
if lem_wait_for "$porcelain_session" 'Show status for worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    porcelain 'Show status for worktree:'
fi
if lem_wait_for "$porcelain_session" 'Branch: main' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-worktree-visit \
    'Z g replaced the active status with the selected primary worktree'
else
  fail legit-worktree-visit \
    'Z g did not visit and display the primary worktree' "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" c
fi
if lem_wait_for "$porcelain_session" \
     'Create branch and worktree starting at:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" "$merge_main_hash" \
    'Create branch and worktree starting at:'
fi
if lem_wait_for "$porcelain_session" \
     'Name for create branch and worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" worktree-created
fi
if lem_wait_for "$porcelain_session" \
     'Checkout worktree-created in new worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_path_prompt_value "$porcelain_session" \
    "$LEM_YATH_VCS_WORKTREE_CREATED" \
    'Checkout worktree-created in new worktree:'
fi
if wait_until "$WAIT_TIMEOUT" test -f \
     "$LEM_YATH_VCS_WORKTREE_CREATED/.git" &&
   [ "$("$git_bin" -C "$LEM_YATH_VCS_WORKTREE_CREATED" \
       branch --show-current)" = worktree-created ] &&
   lem_wait_for "$porcelain_session" 'Branch: worktree-created' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-worktree-create \
    'Z c created the branch and worktree at the selected start point'
else
  fail legit-worktree-create \
    'Z c lost the new branch, selected revision, path, or active status' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" m
fi
if lem_wait_for "$porcelain_session" 'Move worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    created 'Move worktree:'
fi
if lem_wait_for "$porcelain_session" 'Move worktree to:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  printf '%s' "$LEM_YATH_VCS_WORKTREE_MOVE_CONTAINER" \
    >"$LEM_YATH_VCS_PROMPT_INPUT"
  send_keys "$porcelain_session" C-a C-k F12 C-y
  # Keep completion empty while the long metacharacter path is inserted, then
  # create the destination before Git observes it so move-to-container is real.
  mkdir -p "$LEM_YATH_VCS_WORKTREE_MOVE_CONTAINER"
  send_keys "$porcelain_session" Enter
  sleep 0.25
  if lem_wait_for "$porcelain_session" 'Move worktree to:' 1 \
       >/dev/null 2>&1; then
    send_keys "$porcelain_session" Enter
  fi
fi
if wait_until "$WAIT_TIMEOUT" test -f \
     "$LEM_YATH_VCS_WORKTREE_MOVED/.git" &&
   [ ! -e "$LEM_YATH_VCS_WORKTREE_CREATED" ] &&
   [ "$("$git_bin" -C "$LEM_YATH_VCS_WORKTREE_MOVED" \
       branch --show-current)" = worktree-created ] &&
   lem_wait_for "$porcelain_session" 'Branch: worktree-created' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-worktree-move \
    'Z m nested into an existing container and followed the resulting status root'
else
  fail legit-worktree-move \
    'Z m did not preserve registration, branch, path, and active status' \
    "$porcelain_session"
fi

printf 'uncommitted worktree edge\n' \
  >"$LEM_YATH_VCS_WORKTREE_MOVED/untracked edge;safe.txt"
tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" k
fi
if lem_wait_for "$porcelain_session" 'Delete worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    container 'Delete worktree:'
fi
if lem_wait_for "$porcelain_session" 'despite uncommitted changes' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" n
fi
if [ -f "$LEM_YATH_VCS_WORKTREE_MOVED/untracked edge;safe.txt" ] &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" worktree list \
     --porcelain | grep -Fqx \
       "worktree $LEM_YATH_VCS_WORKTREE_MOVED"; then
  pass legit-worktree-dirty-decline \
    'Z k retained a dirty current worktree when deletion was declined'
else
  fail legit-worktree-dirty-decline \
    'declining dirty worktree deletion still removed content or registration' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" k
fi
if lem_wait_for "$porcelain_session" 'Delete worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    container 'Delete worktree:'
fi
if lem_wait_for "$porcelain_session" 'despite uncommitted changes' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" test ! -e \
     "$LEM_YATH_VCS_WORKTREE_MOVED" &&
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" worktree list \
      --porcelain | grep -Fqx \
        "worktree $LEM_YATH_VCS_WORKTREE_MOVED" &&
   lem_wait_for "$porcelain_session" 'Branch: main' \
     "$WAIT_TIMEOUT" >/dev/null; then
  pass legit-worktree-dirty-force \
    'Z k force-removed dirty content only after confirmation and returned home'
else
  fail legit-worktree-dirty-force \
    'confirmed dirty deletion failed to remove or return to the primary status' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" worktree add -q \
  -b worktree-locked "$LEM_YATH_VCS_WORKTREE_LOCKED" "$merge_main_hash"
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" worktree lock \
  --reason lem-yath-test "$LEM_YATH_VCS_WORKTREE_LOCKED"
tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" k
fi
if lem_wait_for "$porcelain_session" 'Delete worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    locked 'Delete worktree:'
fi
if lem_wait_for "$porcelain_session" 'Unlock the selected worktree' \
     "$WAIT_TIMEOUT" >/dev/null &&
   [ -f "$LEM_YATH_VCS_WORKTREE_LOCKED/.git" ]; then
  pass legit-worktree-locked \
    'Z k refused a locked worktree before presenting a destructive prompt'
else
  fail legit-worktree-locked \
    'locked-worktree deletion was not rejected safely' "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" worktree add -q \
  -b worktree-stale "$LEM_YATH_VCS_WORKTREE_STALE" "$merge_main_hash"
rm -rf -- "$LEM_YATH_VCS_WORKTREE_STALE"
tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" k
fi
if lem_wait_for "$porcelain_session" 'Delete worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    stale 'Delete worktree:'
fi
if wait_until "$WAIT_TIMEOUT" sh -c \
     "! '$git_bin' -C '$LEM_YATH_VCS_PORCELAIN_ROOT' worktree list --porcelain | grep -Fqx 'worktree $LEM_YATH_VCS_WORKTREE_STALE'"; then
  pass legit-worktree-stale \
    'Z k pruned missing worktree metadata without a destructive prompt'
else
  fail legit-worktree-stale \
    'missing worktree metadata remained registered after prune' \
    "$porcelain_session"
fi

# The primary is never offered by move/delete.  Remove the remaining clean
# checkout through the dispatch, then clean the locked edge fixture directly.
tmux_cmd send-keys -t "$porcelain_session" -l -- 'Z'
if lem_wait_for "$porcelain_session" '\[Worktree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" k
fi
if lem_wait_for "$porcelain_session" 'Delete worktree:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" \
    checkout 'Delete worktree:'
fi
if lem_wait_for "$porcelain_session" \
     "Delete worktree $LEM_YATH_VCS_WORKTREE_CHECKOUT" \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" test ! -e \
     "$LEM_YATH_VCS_WORKTREE_CHECKOUT" &&
   [ -d "$LEM_YATH_VCS_PORCELAIN_ROOT/.git" ]; then
  pass legit-worktree-clean-delete \
    'Z k confirmed clean linked-worktree deletion while preserving primary Git'
else
  fail legit-worktree-clean-delete \
    'clean linked deletion failed or affected the primary worktree' \
    "$porcelain_session"
fi
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" worktree unlock \
  "$LEM_YATH_VCS_WORKTREE_LOCKED" || true
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" worktree remove --force \
  "$LEM_YATH_VCS_WORKTREE_LOCKED" || true

# Exercise Evil Collection's apostrophe submodule dispatch after all workflows
# which require a pristine superproject index.  This covers each normally
# visible lifecycle action against a real local bare remote.
tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" a
fi
if lem_wait_for "$porcelain_session" 'Submodule URL:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBMODULE_REMOTE"
fi
if lem_wait_for "$porcelain_session" 'Submodule path:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBMODULE_PATH"
fi
if lem_wait_for "$porcelain_session" 'Submodule name:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBMODULE_NAME"
fi
if wait_until "$WAIT_TIMEOUT" test -f \
     "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH/module.txt" &&
   [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --file \
        .gitmodules --get "submodule.$LEM_YATH_VCS_SUBMODULE_NAME.path")" = \
     "$LEM_YATH_VCS_SUBMODULE_PATH" ] &&
   [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" ls-files -s -- \
        "$LEM_YATH_VCS_SUBMODULE_PATH" | awk '{print $1}')" = 160000 ]; then
  pass legit-submodule-add \
    "' a added the named metacharacter-path module and staged its gitlink"
else
  fail legit-submodule-add \
    'submodule add lost its name, direct-argv path, population, or index state' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" l
fi
if lem_wait_for "$porcelain_session" 'Populated submodules:' \
     "$WAIT_TIMEOUT" >/dev/null &&
   lem_wait_for "$porcelain_session" 'modules/module path;safe.*main' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" Space
  pass legit-submodule-list \
    "' l rendered a bounded populated-module pane with branch and hash"
else
  fail legit-submodule-list \
    'the submodule list did not render the populated module textually' \
    "$porcelain_session"
fi

# Record the added gitlink before testing ordinary (non-force) deinit.  A newly
# staged gitlink is intentionally protected by Git as an uncommitted module
# change, which is a different boundary from a clean populated submodule.
if ! GIT_AUTHOR_DATE='2001-01-08T00:00:00+0000' \
     GIT_COMMITTER_DATE='2001-01-08T00:00:00+0000' \
     "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" commit -qm \
       'Record submodule fixture' -- .gitmodules \
       "$LEM_YATH_VCS_SUBMODULE_PATH"; then
  fail legit-submodule-record \
    'could not record the clean submodule baseline before deinit' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" d
fi
if lem_wait_for "$porcelain_session" 'Unpopulate submodule:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" module \
    'Unpopulate submodule:'
fi
if lem_wait_for "$porcelain_session" 'Unpopulate submodule modules/module path;safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" test ! -e \
     "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH/.git" &&
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --get \
     "submodule.$LEM_YATH_VCS_SUBMODULE_NAME.url" >/dev/null 2>&1; then
  pass legit-submodule-unpopulate \
    "' d confirmed deinitialization without deleting the preserved module Gitdir"
else
  fail legit-submodule-unpopulate \
    'submodule deinitialization retained a worktree or registration unexpectedly' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" r
fi
if lem_wait_for "$porcelain_session" 'Register submodule:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" module \
    'Register submodule:'
fi
if wait_until "$WAIT_TIMEOUT" "$git_bin" \
     -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config --get \
     "submodule.$LEM_YATH_VCS_SUBMODULE_NAME.url" >/dev/null 2>&1; then
  pass legit-submodule-register "' r restored local submodule registration"
else
  fail legit-submodule-register \
    'submodule init did not restore the declared local URL' "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" r p
fi
if lem_wait_for "$porcelain_session" 'Populate submodule:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" module \
    'Populate submodule:'
fi
submodule_v1_hash=$($git_bin -C "$LEM_YATH_VCS_SUBMODULE_SEED" rev-parse HEAD)
if wait_until "$WAIT_TIMEOUT" test -e \
     "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH/.git" &&
   [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH" \
        rev-parse HEAD)" = "$submodule_v1_hash" ]; then
  pass legit-submodule-populate \
    "' -r p populated the recorded revision through the recursive path"
else
  fail legit-submodule-populate \
    'submodule population did not restore the exact recorded revision' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" config \
  "submodule.$LEM_YATH_VCS_SUBMODULE_NAME.url" /deliberately/wrong
tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" s
fi
if lem_wait_for "$porcelain_session" 'Synchronize submodule:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" module \
    'Synchronize submodule:'
fi
if wait_until "$WAIT_TIMEOUT" sh -c \
     "[ \"\$('$git_bin' -C '$LEM_YATH_VCS_PORCELAIN_ROOT' config --get 'submodule.$LEM_YATH_VCS_SUBMODULE_NAME.url')\" = '$LEM_YATH_VCS_SUBMODULE_REMOTE' ]"; then
  pass legit-submodule-sync "' s synchronized the local URL from .gitmodules"
else
  fail legit-submodule-sync \
    'submodule sync did not replace the deliberately stale local URL' \
    "$porcelain_session"
fi

printf 'submodule version two\n' >"$LEM_YATH_VCS_SUBMODULE_SEED/module.txt"
"$git_bin" -C "$LEM_YATH_VCS_SUBMODULE_SEED" add -- module.txt
git_commit "$LEM_YATH_VCS_SUBMODULE_SEED" submodule-v2 \
  '2001-01-06T00:00:00+0000'
"$git_bin" -C "$LEM_YATH_VCS_SUBMODULE_SEED" push -qu origin main
submodule_v2_hash=$($git_bin -C "$LEM_YATH_VCS_SUBMODULE_SEED" rev-parse HEAD)
tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" U u
fi
if lem_wait_for "$porcelain_session" 'Update submodule:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" module \
    'Update submodule:'
fi
if wait_until "$WAIT_TIMEOUT" sh -c \
     "[ \"\$('$git_bin' -C '$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH' rev-parse HEAD)\" = '$submodule_v2_hash' ]"; then
  pass legit-submodule-update \
    "' -U u advanced the worktree to the configured upstream tip"
else
  fail legit-submodule-update \
    'remote-tip submodule update did not reach the pushed revision' \
    "$porcelain_session"
fi

printf 'submodule version three\n' >"$LEM_YATH_VCS_SUBMODULE_SEED/module.txt"
"$git_bin" -C "$LEM_YATH_VCS_SUBMODULE_SEED" add -- module.txt
git_commit "$LEM_YATH_VCS_SUBMODULE_SEED" submodule-v3 \
  '2001-01-07T00:00:00+0000'
"$git_bin" -C "$LEM_YATH_VCS_SUBMODULE_SEED" push -qu origin main
submodule_v3_hash=$($git_bin -C "$LEM_YATH_VCS_SUBMODULE_SEED" rev-parse HEAD)
tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" f
fi
if wait_until "$WAIT_TIMEOUT" sh -c \
     "[ \"\$('$git_bin' -C '$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH' rev-parse origin/main)\" = '$submodule_v3_hash' ] && [ \"\$('$git_bin' -C '$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH' rev-parse HEAD)\" = '$submodule_v2_hash' ]"; then
  pass legit-submodule-fetch \
    "' f fetched the new module ref without checking it out"
else
  fail legit-submodule-fetch \
    'recursive fetch lost either the fetched-ref or worktree boundary' \
    "$porcelain_session"
fi

printf 'dirty module content\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH/module.txt"
printf 'untracked module backup\n' \
  >"$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH/untracked.txt"
tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" k
fi
if lem_wait_for "$porcelain_session" 'Remove submodule:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" module \
    'Remove submodule:'
fi
if lem_wait_for "$porcelain_session" 'is dirty; enable -f' \
     "$WAIT_TIMEOUT" >/dev/null &&
   [ -f "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH/module.txt" ]; then
  pass legit-submodule-remove-refusal \
    "' k refused dirty removal without the force argument"
else
  fail legit-submodule-remove-refusal \
    'dirty submodule removal was not rejected before mutation' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- "'"
if lem_wait_for "$porcelain_session" '\[Submodule\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" f k
fi
if lem_wait_for "$porcelain_session" 'Remove submodule:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_completion_prompt_value "$porcelain_session" module \
    'Remove submodule:'
fi
if lem_wait_for "$porcelain_session" 'Remove submodule modules/module path;safe' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
if lem_wait_for "$porcelain_session" 'Stash dirty content and force removal' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" y
fi
submodule_gitdir="$LEM_YATH_VCS_PORCELAIN_ROOT/.git/modules/$LEM_YATH_VCS_SUBMODULE_NAME"
if wait_until "$WAIT_TIMEOUT" test ! -e \
     "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBMODULE_PATH" &&
   [ -d "$submodule_gitdir" ] &&
   "$git_bin" --git-dir="$submodule_gitdir" show-ref --verify --quiet \
     refs/stash &&
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" ls-files --error-unmatch \
     -- "$LEM_YATH_VCS_SUBMODULE_PATH" >/dev/null 2>&1; then
  pass legit-submodule-remove \
    "' -f k stashed dirty content, removed the gitlink, and preserved its Gitdir"
else
  fail legit-submodule-remove \
    'forced removal lost its stash/Gitdir or retained the gitlink/worktree' \
    "$porcelain_session"
fi

# The subtree commands require a clean index.  Record the preceding submodule
# removal, then exercise every pinned import/export action against local bare
# repositories whose paths contain both spaces and shell metacharacters.
if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" add -u &&
   GIT_AUTHOR_DATE='2001-01-10T00:00:00+0000' \
   GIT_COMMITTER_DATE='2001-01-10T00:00:00+0000' \
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" commit -qm \
     'Record submodule removal'; then
  pass legit-subtree-clean-baseline \
    'recorded a clean baseline for subtree lifecycle coverage'
else
  fail legit-subtree-clean-baseline \
    'could not record the subtree lifecycle baseline' "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- '"'
if lem_wait_for "$porcelain_session" '\[Subtree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" i
fi
if lem_wait_for "$porcelain_session" '\[Subtree import\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" P
fi
if lem_wait_for "$porcelain_session" 'Prefix:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBTREE_PREFIX"
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" 'Message \(blank unsets\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" 'Import subtree; safe'
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" s a
if lem_wait_for "$porcelain_session" 'From repository:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_completion_prompt_value "$porcelain_session" \
    "$LEM_YATH_VCS_SUBTREE_REMOTE" 'From repository:'
fi
if lem_wait_for "$porcelain_session" 'Ref:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_completion_prompt_value "$porcelain_session" main 'Ref:'
fi
if wait_until "$WAIT_TIMEOUT" test -f \
     "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBTREE_PREFIX/module.txt" &&
   [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBTREE_PREFIX/module.txt")" = \
     'subtree version one' ] &&
   [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" log -1 --format=%s)" = \
     'Import subtree; safe' ]; then
  pass legit-subtree-add \
    '" i -P -m -s a imported a squashed metacharacter-path subtree'
else
  fail legit-subtree-add \
    'subtree add lost its direct-argv path, source ref, content, or message' \
    "$porcelain_session"
fi

printf 'subtree version two\n' >"$LEM_YATH_VCS_SUBTREE_SEED/module.txt"
"$git_bin" -C "$LEM_YATH_VCS_SUBTREE_SEED" add -- module.txt
git_commit "$LEM_YATH_VCS_SUBTREE_SEED" subtree-v2 \
  '2001-01-11T00:00:00+0000'
"$git_bin" -C "$LEM_YATH_VCS_SUBTREE_SEED" push -qu origin main
subtree_v2_hash=$($git_bin -C "$LEM_YATH_VCS_SUBTREE_SEED" rev-parse HEAD)

tmux_cmd send-keys -t "$porcelain_session" -l -- '"'
if lem_wait_for "$porcelain_session" '\[Subtree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" i
fi
if lem_wait_for "$porcelain_session" '\[Subtree import\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" P
fi
if lem_wait_for "$porcelain_session" 'Prefix:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBTREE_PREFIX"
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" 'Message \(blank unsets\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" 'Pull subtree; safe'
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" s f
if lem_wait_for "$porcelain_session" 'From repository:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_completion_prompt_value "$porcelain_session" \
    "$LEM_YATH_VCS_SUBTREE_REMOTE" 'From repository:'
fi
if lem_wait_for "$porcelain_session" 'Ref:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_completion_prompt_value "$porcelain_session" main 'Ref:'
fi
if wait_until "$WAIT_TIMEOUT" sh -c \
     "[ \"\$(cat '$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBTREE_PREFIX/module.txt')\" = 'subtree version two' ]" &&
   [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" log -1 --format=%s)" = \
     'Pull subtree; safe' ]; then
  pass legit-subtree-pull \
    '" i -P -m -s f pulled the advanced remote subtree revision'
else
  fail legit-subtree-pull \
    'subtree pull did not advance content with the configured message' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" fetch -q \
  "$LEM_YATH_VCS_SUBTREE_REMOTE" \
  main:refs/remotes/subtree-fixture/main
tmux_cmd send-keys -t "$porcelain_session" -l -- '"'
if lem_wait_for "$porcelain_session" '\[Subtree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" i
fi
if lem_wait_for "$porcelain_session" '\[Subtree import\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" P
fi
if lem_wait_for "$porcelain_session" 'Prefix:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBTREE_COMMIT_PREFIX"
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" 'Message \(blank unsets\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" 'Add commit subtree; safe'
fi
send_keys "$porcelain_session" c
if lem_wait_for "$porcelain_session" 'Commit:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$subtree_v2_hash"
fi
if wait_until "$WAIT_TIMEOUT" test -f \
     "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBTREE_COMMIT_PREFIX/module.txt" &&
   [ "$(cat "$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBTREE_COMMIT_PREFIX/module.txt")" = \
     'subtree version two' ]; then
  pass legit-subtree-add-commit \
    '" i -P -m c imported an already fetched commit without squash'
else
  fail legit-subtree-add-commit \
    'subtree add-commit did not resolve and import the selected commit' \
    "$porcelain_session"
fi

printf 'subtree version three\n' >"$LEM_YATH_VCS_SUBTREE_SEED/module.txt"
"$git_bin" -C "$LEM_YATH_VCS_SUBTREE_SEED" add -- module.txt
git_commit "$LEM_YATH_VCS_SUBTREE_SEED" subtree-v3 \
  '2001-01-12T00:00:00+0000'
"$git_bin" -C "$LEM_YATH_VCS_SUBTREE_SEED" push -qu origin main
subtree_v3_hash=$($git_bin -C "$LEM_YATH_VCS_SUBTREE_SEED" rev-parse HEAD)
"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" fetch -q \
  "$LEM_YATH_VCS_SUBTREE_REMOTE" \
  main:refs/remotes/subtree-fixture/main

tmux_cmd send-keys -t "$porcelain_session" -l -- '"'
if lem_wait_for "$porcelain_session" '\[Subtree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" i
fi
if lem_wait_for "$porcelain_session" '\[Subtree import\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" P
fi
if lem_wait_for "$porcelain_session" 'Prefix:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBTREE_COMMIT_PREFIX"
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" 'Message \(blank unsets\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" 'Merge subtree; safe'
fi
send_keys "$porcelain_session" m
if lem_wait_for "$porcelain_session" 'Commit:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$subtree_v3_hash"
fi
if wait_until "$WAIT_TIMEOUT" sh -c \
     "[ \"\$(cat '$LEM_YATH_VCS_PORCELAIN_ROOT/$LEM_YATH_VCS_SUBTREE_COMMIT_PREFIX/module.txt')\" = 'subtree version three' ]"; then
  pass legit-subtree-merge \
    '" i -P -m m merged a resolved commit without squash'
else
  fail legit-subtree-merge \
    'subtree merge did not advance the existing prefix to the selected commit' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- '"'
if lem_wait_for "$porcelain_session" '\[Subtree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" e
fi
if lem_wait_for "$porcelain_session" '\[Subtree export\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" P
fi
if lem_wait_for "$porcelain_session" 'Prefix:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBTREE_COMMIT_PREFIX"
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" a
if lem_wait_for "$porcelain_session" 'Annotate \(blank unsets\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" '[export] '
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" b
if lem_wait_for "$porcelain_session" 'Branch \(blank unsets\):' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" subtree/export-safe
fi
tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
send_keys "$porcelain_session" j s
if lem_wait_for "$porcelain_session" 'Commit:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" HEAD
fi
if wait_until "$WAIT_TIMEOUT" "$git_bin" \
     -C "$LEM_YATH_VCS_PORCELAIN_ROOT" show-ref --verify --quiet \
     refs/heads/subtree/export-safe &&
   [ "$($git_bin -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
        show subtree/export-safe:module.txt)" = 'subtree version three' ] &&
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" \
     cat-file -e subtree/export-safe:porcelain.txt 2>/dev/null; then
  pass legit-subtree-split \
    '" e -P -a -b -j s split, annotated, branched, and rejoined subtree history'
else
  fail legit-subtree-split \
    'subtree split lost its branch, root-only tree, or rejoin mutation' \
    "$porcelain_session"
fi

tmux_cmd send-keys -t "$porcelain_session" -l -- '"'
if lem_wait_for "$porcelain_session" '\[Subtree\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$porcelain_session" e
fi
if lem_wait_for "$porcelain_session" '\[Subtree export\]' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- '-'
  send_keys "$porcelain_session" P
fi
if lem_wait_for "$porcelain_session" 'Prefix:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_prompt_value "$porcelain_session" "$LEM_YATH_VCS_SUBTREE_PREFIX"
fi
send_keys "$porcelain_session" p
if lem_wait_for "$porcelain_session" 'To repository:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_completion_prompt_value "$porcelain_session" \
    "$LEM_YATH_VCS_SUBTREE_PUSH" 'To repository:'
fi
if lem_wait_for "$porcelain_session" 'To reference:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  enter_atomic_completion_prompt_value "$porcelain_session" \
    export-safe 'To reference:'
fi
if wait_until "$WAIT_TIMEOUT" "$git_bin" \
     --git-dir="$LEM_YATH_VCS_SUBTREE_PUSH" show-ref --verify --quiet \
     refs/heads/export-safe &&
   [ "$($git_bin --git-dir="$LEM_YATH_VCS_SUBTREE_PUSH" \
        show refs/heads/export-safe:module.txt)" = 'subtree version two' ] &&
   ! "$git_bin" --git-dir="$LEM_YATH_VCS_SUBTREE_PUSH" \
     cat-file -e refs/heads/export-safe:porcelain.txt 2>/dev/null; then
  pass legit-subtree-push \
    '" e -P p pushed an extracted root-only history to a metacharacter path'
else
  fail legit-subtree-push \
    'subtree push did not create the exact exported tree and destination ref' \
    "$porcelain_session"
fi
lem_stop "$porcelain_session"

printf '\n'
cat "$LEM_YATH_VCS_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo 'VCS TEST PASSED'
  exit 0
else
  echo 'VCS TEST FAILED'
  exit 1
fi
