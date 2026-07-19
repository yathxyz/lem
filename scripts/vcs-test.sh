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
export JJ_CONFIG="$root/jj-config.toml"
export JJ_PAGER=cat
export NO_COLOR=1
# The wrapper-path assertion starts Lem from an intentionally empty PATH.
# Host direnv bookkeeping would otherwise restore an unrelated parent PATH.
unset DIRENV_DIFF DIRENV_DIR DIRENV_FILE DIRENV_WATCHES
export LEM_YATH_VCS_REPORT="$root/report"
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

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" "$LEM_HOME" \
  "$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper" \
  "$LEM_YATH_VCS_COLOCATED_ROOT/nested/deeper/raw directory;sentinel" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/deeper" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/deeper/raw directory;sentinel" \
  "$LEM_YATH_VCS_GIT_MAIN/nested/docs" \
  "$LEM_YATH_VCS_PORCELAIN_ROOT/raw directory;sentinel"
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
printf 'TODO tracked implementation task\nordinary line\n' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/deeper/todos.txt"
printf 'FIXME tracked documentation task\n' \
  >"$LEM_YATH_VCS_GIT_MAIN/nested/docs/fixmes.txt"
"$git_bin" -C "$LEM_YATH_VCS_GIT_MAIN" add -- \
  nested/deeper/history-old.lisp nested/deeper/retired.lisp \
  nested/deeper/todos.txt nested/docs/fixmes.txt nested/docs/notes.md
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

# A separate repository exercises Legit's mutating Magit-like porcelain
# without changing the gutter and Timemachine history fixtures above.
if ! "$git_bin" init --bare -q "$LEM_YATH_VCS_PORCELAIN_REMOTE" ||
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
   ! "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" remote add origin \
     "$LEM_YATH_VCS_PORCELAIN_REMOTE" ||
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
sed -i '2s/.*/porcelain-line-02 changed-first-hunk/' \
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
    ! grep -q 'changed-second-hunk' <<<"$diff"
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
  [ "$cherry_main_head" = \
    "$("$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" rev-parse HEAD)" ] &&
    porcelain_cherry_clean
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
   grep -q '^RELOAD same=yes find=1 post=1 save=1 change=1 kill=1 global=0 source=1 directory=0 root-marker=1 todo-hook=1 smart=yes git=yes jj=yes time=yes jj-refresh=yes jj-quit=yes older=yes newer=yes nth=yes fuzzy=yes short=yes full=yes blame=yes blame-quit=yes p=yes n=yes t=yes quit=yes$' \
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
if [[ "$legit_state" == *'todos=yes todo-count=yes todo-properties=yes todo-hook=1 '* ]]; then
  pass legit-todo-section 'Legit rendered two tracked TODO/FIXME rows with actions'
else
  fail legit-todo-section "unexpected Legit TODO state: $legit_state" \
    "$git_session"
fi

todo_preview_before=$(report_count '^TODO-PREVIEW ')
send_keys "$git_session" C-c t
if wait_report_count '^TODO-PREVIEW ' "$((todo_preview_before + 1))" &&
   [[ $(latest_report '^TODO-PREVIEW ') == \
      'TODO-PREVIEW row=yes move=yes visit=yes file=todos.txt line=1 text=yes' ]]; then
  pass legit-todo-preview 'a TODO row resolves to its exact tracked source line'
else
  fail legit-todo-preview 'TODO row preview metadata did not resolve exactly' \
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

position_before=$(report_count '^PORCELAIN-POSITION ')
hunk_staged=0
send_keys "$porcelain_session" C-c d
if wait_report_count '^PORCELAIN-POSITION ' "$((position_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-POSITION ') == \
      'PORCELAIN-POSITION file=porcelain.txt row=yes diff=yes mode=yes focused=yes' ]]; then
  lem_keys "$porcelain_session" s
  if wait_until "$WAIT_TIMEOUT" porcelain_first_hunk_only; then
    pass legit-stage-hunk 's in a Vi-normal Legit diff staged only the selected hunk'
    hunk_staged=1
  else
    fail legit-stage-hunk 'diff-mode s did not stage exactly the selected hunk' \
      "$porcelain_session"
  fi
else
  fail legit-stage-hunk 'could not focus the first real Legit diff hunk' \
    "$porcelain_session"
fi

position_before=$(report_count '^PORCELAIN-POSITION ')
if [ "$hunk_staged" = 1 ]; then
  send_keys "$porcelain_session" C-c e
fi
if [ "$hunk_staged" = 1 ] &&
   wait_report_count '^PORCELAIN-POSITION ' "$((position_before + 1))" &&
   [[ $(latest_report '^PORCELAIN-POSITION ') == \
      'PORCELAIN-POSITION file=porcelain.txt row=yes diff=yes mode=yes focused=yes' ]]; then
  lem_keys "$porcelain_session" u
fi
if [ "$hunk_staged" = 1 ] &&
   wait_until "$WAIT_TIMEOUT" porcelain_index_empty; then
  pass legit-unstage-hunk 'u in a staged Vi-normal diff unstaged the selected hunk'
else
  fail legit-unstage-hunk 'could not focus and unstage the selected cached hunk' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" C-c m s C-c a s
if wait_until "$WAIT_TIMEOUT" porcelain_all_staged; then
  pass legit-stage-files 'status-pane s staged tracked and untracked files'
else
  fail legit-stage-files 'status-pane staging did not produce the expected index' \
    "$porcelain_session"
fi

lem_keys "$porcelain_session" c c
if lem_wait_for "$porcelain_session" 'Please enter the commit message' \
     "$WAIT_TIMEOUT" >/dev/null; then
  lem_keys "$porcelain_session" i
  tmux_cmd send-keys -t "$porcelain_session" -l -- \
    'porcelain commit from Lem'
  send_keys "$porcelain_session" Escape C-c C-c
  if wait_until "$WAIT_TIMEOUT" porcelain_subject_is \
       'porcelain commit from Lem'; then
    pass legit-commit 'c c and C-c C-c created the staged commit from Vi state'
  else
    fail legit-commit 'the commit buffer did not create the expected commit' \
      "$porcelain_session"
  fi
else
  fail legit-commit "c c did not open Legit's commit-message buffer" \
    "$porcelain_session"
fi

send_keys "$porcelain_session" P p
if wait_until "$WAIT_TIMEOUT" porcelain_remote_matches_head; then
  pass legit-push 'P p pushed the current tracked branch to origin'
else
  fail legit-push 'P p did not update the bare remote' "$porcelain_session"
fi

send_keys "$porcelain_session" b c
if lem_wait_for "$porcelain_session" 'New branch name:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- vcs-feature
  send_keys "$porcelain_session" Enter
  if lem_wait_for "$porcelain_session" 'Base branch:' \
       "$WAIT_TIMEOUT" >/dev/null; then
    tmux_cmd send-keys -t "$porcelain_session" -l -- main
    send_keys "$porcelain_session" Enter
  fi
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_is vcs-feature; then
  pass legit-branch-create 'b c created and checked out a branch from main'
else
  fail legit-branch-create 'b c did not create the requested branch' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" b b
if lem_wait_for "$porcelain_session" 'Branch:' "$WAIT_TIMEOUT" >/dev/null; then
  for _ in $(seq 1 11); do
    lem_keys "$porcelain_session" BSpace
  done
  tmux_cmd send-keys -t "$porcelain_session" -l -- main
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_branch_is main; then
  pass legit-branch-checkout 'b b checked out the selected existing branch'
else
  fail legit-branch-checkout 'b b did not return to main' "$porcelain_session"
fi

printf 'stash-probe\n' >>"$LEM_YATH_VCS_PORCELAIN_ROOT/auxiliary.txt"
send_keys "$porcelain_session" g z z
if lem_wait_for "$porcelain_session" 'Stash message:' \
     "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$porcelain_session" -l -- lem-stash
  send_keys "$porcelain_session" Enter
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stashed; then
  pass legit-stash-push 'z z stashed tracked worktree changes with a message'
else
  fail legit-stash-push 'z z did not create a clean stash' \
    "$porcelain_session"
fi

send_keys "$porcelain_session" z p
if lem_wait_for "$porcelain_session" 'Pop the latest stash' \
     "$WAIT_TIMEOUT" >/dev/null; then
  lem_keys "$porcelain_session" y
fi
if wait_until "$WAIT_TIMEOUT" porcelain_stash_restored; then
  pass legit-stash-pop 'z p restored and removed the latest stash'
else
  fail legit-stash-pop 'z p did not restore the latest stash' \
    "$porcelain_session"
fi

"$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_ROOT" restore -- auxiliary.txt
send_keys "$porcelain_session" g
if "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" pull -q --ff-only &&
   printf 'peer-pull-probe\n' \
     >>"$LEM_YATH_VCS_PORCELAIN_PEER/auxiliary.txt" &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" add -- auxiliary.txt &&
   git_commit "$LEM_YATH_VCS_PORCELAIN_PEER" porcelain-peer \
     '2001-01-05T00:00:00+0000' &&
   "$git_bin" -C "$LEM_YATH_VCS_PORCELAIN_PEER" push -q; then
  send_keys "$porcelain_session" F p
  if wait_until "$WAIT_TIMEOUT" porcelain_peer_pulled; then
    pass legit-pull 'F p fast-forwarded to a real peer commit from origin'
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
      'CHERRY active=no pick=yes apply=yes skip=yes diff=yes candidate=yes' ]]; then
  pass legit-cherry-dispatch \
    'A exposes Magit pick/apply/skip bindings and all-ref completion'
else
  fail legit-cherry-dispatch \
    'the dispatch, diff bindings, or all-ref candidates were incomplete' \
    "$porcelain_session"
fi

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
      'CHERRY active=yes pick=yes apply=yes skip=yes diff=yes candidate=yes' ]]; then
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
