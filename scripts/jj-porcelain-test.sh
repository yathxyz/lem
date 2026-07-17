#!/usr/bin/env bash
# Real-TUI acceptance for the focused Majutsu-compatible jj porcelain.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-jj-porcelain-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-jj-porcelain.XXXXXX")"
session="lem-yath-jj-porcelain-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export JJ_CONFIG="$root/jj-config.toml"
export JJ_PAGER=cat
export NO_COLOR=1
export LEM_YATH_JJ_PORCELAIN_REPORT="$root/report"
export LEM_YATH_JJ_PORCELAIN_ROOT="$root/repository jj;safe/"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$LEM_YATH_JJ_PORCELAIN_ROOT"
: >"$LEM_YATH_JJ_PORCELAIN_REPORT"
printf '%s\n' \
  'user.name = "Lem Yath Test"' \
  'user.email = "lem-yath-test@example.invalid"' \
  >"$JJ_CONFIG"

jj_bin="$(command -v jj 2>/dev/null || true)"
if [ -z "$jj_bin" ] || [ ! -x "$jj_bin" ]; then
  echo 'jj porcelain test requires jj on PATH' >&2
  exit 1
fi

"$jj_bin" git init "$LEM_YATH_JJ_PORCELAIN_ROOT" >/dev/null
printf 'tracked through every Jujutsu operation\n' \
  >"${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" describe \
  --message $'base\nbody line' >/dev/null
base_change_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @ --template change_id)
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  --message current >/dev/null

current_description() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log --no-graph -r @ \
    --template 'description.first_line()'
}

visible_description() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log --no-graph -r 'all()' \
    --template 'description.first_line() ++ "\n"' | grep -Fxq -- "$1"
}

full_description() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log --no-graph \
    -r "$1" --template description
}

revision_present() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log --no-graph \
    -r "$1" --template change_id >/dev/null 2>&1
}

wait_revision_absent() {
  local revision=$1 index=0
  while ((index < 80)); do
    if ! revision_present "$revision"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

revision_parent() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log --no-graph \
    -r "($1)-" --template change_id
}

wait_revision_parent() {
  local revision=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(revision_parent "$revision")" = "$expected" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

bookmark_target() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" bookmark list --quiet "$1" \
    --template 'normal_target.change_id()'
}

wait_bookmark_target() {
  local name=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(bookmark_target "$name")" = "$expected" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_bookmark_absent() {
  local name=$1 index=0
  while ((index < 80)); do
    if [ -z "$(bookmark_target "$name")" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

open_bookmark_action() {
  local action=$1
  lem_keys "$session" b
  if lem_wait_for "$session" 'JJ Bookmarks' 10 >/dev/null; then
    lem_keys "$session" "$action"
    return 0
  fi
  return 1
}

wait_description() {
  local expected=$1 index=0
  while ((index < 80)); do
    if [ "$(current_description)" = "$expected" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

report_count() {
  grep -c '^STATE ' "$LEM_YATH_JJ_PORCELAIN_REPORT" 2>/dev/null || true
}

invoke_report() {
  local before
  before=$(report_count)
  lem_keys "$session" F1
  local index=0
  while ((index < 80)); do
    if (( $(report_count) > before )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

latest_report() {
  grep '^STATE ' "$LEM_YATH_JJ_PORCELAIN_REPORT" | tail -n 1
}

replace_prompt_text() {
  local text=$1
  lem_keys "$session" C-a C-k
  tmux_cmd send-keys -t "$session" -l "$text"
  lem_keys "$session" Enter
}

failed=0
pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-26s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_JJ_PORCELAIN_REPORT" 2>/dev/null || true
}

fixture="$(lem-yath_lisp_string "$here/scripts/jj-porcelain-fixture.lisp")"
lem_start "$session" \
  "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt" \
  --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null; then
  pass boot 'configured Lem opened the jj fixture'
else
  fail boot 'configured Lem did not reach Normal state'
fi

lem_keys "$session" Space g J
if lem_wait_for "$session" 'History' 30 >/dev/null; then
  pass open 'SPC g J opened the row-aware jj history'
else
  fail open 'the jj history porcelain did not render'
fi

lem_keys "$session" C-j
if invoke_report &&
   [[ $(latest_report) == \
     'STATE kind=log row=yes description=current rows=3 root=yes read-only=yes mode=yes keys=yes source=no source-live=yes' ]]; then
  pass navigation 'C-j selected @ and all Majutsu-compatible keys are active'
else
  fail navigation 'revision metadata, navigation, or keymap state diverged'
fi

lem_keys "$session" '?'
if lem_wait_for "$session" 'c describe' 10 >/dev/null; then
  pass help '? exposed the focused porcelain command surface'
else
  fail help 'the porcelain help summary was not visible'
fi

lem_keys "$session" c
if lem_wait_for "$session" 'Description:' 10 >/dev/null; then
  replace_prompt_text 'described in Lem'
fi
if wait_description 'described in Lem' && invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=described_in_Lem '* ]]; then
  pass describe 'c changed the selected description and retained its row'
else
  fail describe 'description mutation or point restoration failed'
fi

lem_keys "$session" o
if lem_wait_for "$session" 'New change description' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'created in Lem'
  lem_keys "$session" Enter
fi
if wait_description 'created in Lem' && visible_description 'described in Lem'; then
  pass new 'o created and checked out a child of the selected change'
else
  fail new 'new-change creation did not preserve the selected parent'
fi

lem_keys "$session" u
if wait_description 'described in Lem' &&
   ! visible_description 'created in Lem'; then
  pass undo 'u reversed the new-change operation'
else
  fail undo 'Jujutsu operation undo did not restore the parent'
fi

lem_keys "$session" C-r
if wait_description 'created in Lem' && visible_description 'created in Lem'; then
  pass redo 'C-r restored the undone operation'
else
  fail redo 'Jujutsu operation redo did not restore the child'
fi

# Refresh preserves the old parent row; C-k reaches the newly restored child.
lem_keys "$session" C-k
if invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=created_in_Lem '* ]]; then
  pass previous-row 'C-k moved to the preceding revision row'
else
  fail previous-row 'C-k did not select the restored child revision'
fi

child_change_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @ --template change_id)
destination_change_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @- --template change_id)
printf 'moved into the parent by Lem squash\n' \
  >>"${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" status >/dev/null

lem_keys "$session" s
if lem_wait_for "$session" 'JJ Squash' 10 >/dev/null; then
  lem_keys "$session" q
fi
if revision_present "$child_change_id" &&
   [ "$(current_description)" = 'created in Lem' ] &&
   ! lem_capture "$session" | grep -q 'JJ Squash'; then
  pass squash-cancel 'q closed the squash popup without changing the repository'
else
  fail squash-cancel 'squash cancellation changed state or left its popup active'
fi

lem_keys "$session" s
if lem_wait_for "$session" 'JJ Squash' 10 >/dev/null; then
  lem_keys "$session" s
fi
if wait_revision_absent "$child_change_id" &&
   [ "$(full_description "$destination_change_id")" = \
     $'described in Lem\n\ncreated in Lem' ] &&
   "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
     -r "$destination_change_id" 'root:working copy.txt' |
       grep -Fxq 'moved into the parent by Lem squash' &&
   invoke_report &&
   [[ $(latest_report) == \
     *'kind=log row=yes description=described_in_Lem\n\ncreated_in_Lem '* ]]; then
  pass squash 's s combined both messages, moved the whole change, and selected its parent'
else
  fail squash 'default whole-change squash, message combination, or parent restoration failed'
fi

# Normalize the destination description so the existing show/describe checks
# remain independent of the multiline squash assertion above.
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" describe \
  "$destination_change_id" --message 'described in Lem' >/dev/null
lem_keys "$session" g r
if ! invoke_report ||
   [[ $(latest_report) != *'kind=log row=yes description=described_in_Lem '* ]]; then
  fail squash-followup 'the normalized squash destination did not refresh in place'
fi

# Recreate the child so the independent confirmed-abandon path remains covered.
lem_keys "$session" o
if lem_wait_for "$session" 'New change description' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'created in Lem'
  lem_keys "$session" Enter
fi
if ! wait_description 'created in Lem'; then
  fail squash-followup 'the squash destination could not create a new child'
fi
lem_keys "$session" C-k
if ! invoke_report ||
   [[ $(latest_report) != *'kind=log row=yes description=created_in_Lem '* ]]; then
  fail squash-followup 'the recreated child row could not be selected'
fi

lem_keys "$session" x
if lem_wait_for "$session" 'Abandon Jujutsu revision' 10 >/dev/null; then
  lem_keys "$session" y
fi
if wait_description '' &&
   ! visible_description 'created in Lem' &&
   visible_description 'described in Lem'; then
  pass abandon 'x confirmed the child removal and jj created a fresh empty @'
else
  fail abandon 'confirmed abandon did not remove the selected child'
fi

# Abandon resets the view because the selected ID disappeared.  The first row
# is jj's fresh empty @ and the second is the retained described parent.
lem_keys "$session" C-j C-j d
if lem_wait_for "$session" 'Commit ID:' 20 >/dev/null && invoke_report &&
   [[ $(latest_report) == \
     'STATE kind=show row=no description=described_in_Lem rows=0 root=yes read-only=yes mode=yes keys=yes source=no source-live=yes' ]]; then
  pass show 'd opened the selected change in a read-only jj show view'
else
  fail show 'change browsing did not open the selected revision'
fi

lem_keys "$session" q
if invoke_report && [[ $(latest_report) == *'STATE kind=log '* ]]; then
  pass show-quit 'q returned from the change view to the history'
else
  fail show-quit 'q did not restore the history buffer'
fi

# The history point is still on the described parent; C-j selects its base.
lem_keys "$session" C-j
if invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=base\nbody_line '* ]]; then
  lem_keys "$session" c
fi
if lem_wait_for "$session" 'multiline description' 10 >/dev/null &&
   [ "$(full_description "$base_change_id")" = $'base\nbody line' ]; then
  pass multiline-refusal 'c preserved an existing multiline description'
else
  fail multiline-refusal 'the single-line prompt did not fail closed'
fi

lem_keys "$session" e
if wait_description base; then
  pass edit 'e moved the working copy to the selected historical change'
else
  fail edit 'the row-aware edit command selected the wrong revision'
fi

root_change_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r 'root()' --template change_id)
lem_keys "$session" C-j s
if lem_wait_for "$session" 'no parent to squash into' 10 >/dev/null &&
   revision_present "$root_change_id"; then
  pass squash-refusal 's rejected the root revision before opening the popup'
else
  fail squash-refusal 'root squash did not fail closed'
fi

# Build sibling source/destination changes below the multiline base, then
# select the source physically through the row map for rebase coverage.
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  "$base_change_id" --message 'rebase destination' >/dev/null
printf 'destination content\n' \
  >"${LEM_YATH_JJ_PORCELAIN_ROOT}rebase-destination.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" status >/dev/null
rebase_destination_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @ --template change_id)
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  "$base_change_id" --message 'rebase source' >/dev/null
printf 'source content\n' \
  >"${LEM_YATH_JJ_PORCELAIN_ROOT}rebase-source.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" status >/dev/null
rebase_source_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @ --template change_id)

lem_keys "$session" g r
selected_rebase_source=0
for _ in 1 2 3 4 5 6 7 8; do
  if invoke_report &&
     [[ $(latest_report) == *'kind=log row=yes description=rebase_source '* ]]; then
    selected_rebase_source=1
    break
  fi
  lem_keys "$session" C-k
done
if ((selected_rebase_source)); then
  pass rebase-row 'the row map selected the content-bearing rebase source'
else
  fail rebase-row 'the rebase source was not reachable through revision navigation'
fi

lem_keys "$session" r
if lem_wait_for "$session" 'JJ Rebase' 10 >/dev/null; then
  lem_keys "$session" q
fi
if [ "$(revision_parent "$rebase_source_id")" = "$base_change_id" ] &&
   ! lem_capture "$session" | grep -q 'JJ Rebase'; then
  pass rebase-popup-cancel 'q closed the rebase popup without moving the source'
else
  fail rebase-popup-cancel 'rebase popup cancellation changed history or stayed active'
fi

lem_keys "$session" r
if lem_wait_for "$session" 'JJ Rebase' 10 >/dev/null; then
  lem_keys "$session" s
fi
if lem_wait_for "$session" 'Rebase destination revision or revset:' 10 >/dev/null; then
  replace_prompt_text "$rebase_destination_id"
fi
if lem_wait_for "$session" 'Rebase Jujutsu revision' 10 >/dev/null; then
  lem_keys "$session" n
fi
if [ "$(revision_parent "$rebase_source_id")" = "$base_change_id" ]; then
  pass rebase-confirm-cancel 'n refused the prepared rebase without mutation'
else
  fail rebase-confirm-cancel 'confirmation cancellation moved the source revision'
fi

lem_keys "$session" r
if lem_wait_for "$session" 'JJ Rebase' 10 >/dev/null; then
  lem_keys "$session" s
fi
if lem_wait_for "$session" 'Rebase destination revision or revset:' 10 >/dev/null; then
  replace_prompt_text "$rebase_destination_id"
fi
if lem_wait_for "$session" 'Rebase Jujutsu revision' 10 >/dev/null; then
  lem_keys "$session" y
fi
if wait_revision_parent "$rebase_source_id" "$rebase_destination_id" &&
   "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
     -r "$rebase_source_id" 'root:rebase-source.txt' |
       grep -Fxq 'source content' &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=rebase_source '* ]]; then
  pass rebase 'r s moved the selected subtree and retained its content and row'
else
  fail rebase 'selected-subtree rebase or row restoration failed'
fi

lem_keys "$session" r
if lem_wait_for "$session" 'JJ Rebase' 10 >/dev/null; then
  lem_keys "$session" r
fi
if lem_wait_for "$session" 'Rebase destination revision or revset:' 10 >/dev/null; then
  replace_prompt_text "$rebase_source_id"
fi
if lem_wait_for "$session" 'Rebase Jujutsu revision' 10 >/dev/null; then
  lem_keys "$session" y
fi
if lem_wait_for "$session" 'jj rebase failed' 10 >/dev/null &&
   [ "$(revision_parent "$rebase_source_id")" = "$rebase_destination_id" ]; then
  pass rebase-refusal 'an invalid self-destination surfaced jj failure without mutation'
else
  fail rebase-refusal 'invalid rebase did not fail closed'
fi

lem_keys "$session" b
if lem_wait_for "$session" 'JJ Bookmarks' 10 >/dev/null; then
  lem_keys "$session" q
fi
if [ -z "$(bookmark_target topic-lem)" ] &&
   ! lem_capture "$session" | grep -q 'JJ Bookmarks'; then
  pass bookmark-popup-cancel 'b q closed the bookmark popup without mutation'
else
  fail bookmark-popup-cancel 'bookmark cancellation changed state or stayed active'
fi

if open_bookmark_action c &&
   lem_wait_for "$session" 'Create bookmark:' 10 >/dev/null; then
  replace_prompt_text 'topic-lem'
fi
if wait_bookmark_target topic-lem "$rebase_source_id" &&
   lem_wait_for "$session" '\[topic-lem\].*rebase source' 10 >/dev/null; then
  pass bookmark-create 'b c created a bookmark and rendered its row label'
else
  fail bookmark-create 'bookmark creation, target, or inline label failed'
fi

if open_bookmark_action l &&
   lem_wait_for "$session" 'Jujutsu bookmarks:' 10 >/dev/null &&
   lem_wait_for "$session" 'topic-lem:' 10 >/dev/null; then
  pass bookmark-list 'b l opened the focused local bookmark list'
else
  fail bookmark-list 'the local bookmark list did not render'
fi
lem_keys "$session" q
if lem_wait_for "$session" 'History' 10 >/dev/null; then
  pass bookmark-list-quit 'q restored the history from the bookmark list'
else
  fail bookmark-list-quit 'bookmark list quit did not restore history'
fi

if open_bookmark_action r &&
   lem_wait_for "$session" 'Rename bookmark:' 10 >/dev/null; then
  replace_prompt_text 'topic-lem'
fi
if lem_wait_for "$session" 'New bookmark name:' 10 >/dev/null; then
  replace_prompt_text 'topic-renamed'
fi
if wait_bookmark_absent topic-lem &&
   wait_bookmark_target topic-renamed "$rebase_source_id"; then
  pass bookmark-rename 'b r renamed the selected local bookmark'
else
  fail bookmark-rename 'bookmark rename did not preserve its target'
fi

lem_keys "$session" C-j
if invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=rebase_destination '* ]]; then
  if open_bookmark_action M &&
     lem_wait_for "$session" 'Move bookmark:' 10 >/dev/null; then
    replace_prompt_text 'topic-renamed'
  fi
else
  fail bookmark-move-row 'the rebase destination row was not selected'
fi
if wait_bookmark_target topic-renamed "$rebase_destination_id"; then
  pass bookmark-move 'b M moved the bookmark backwards to the selected parent'
else
  fail bookmark-move 'allow-backwards bookmark move failed'
fi

lem_keys "$session" C-k
if invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=rebase_source '* ]]; then
  if open_bookmark_action s &&
     lem_wait_for "$session" 'Set bookmark:' 10 >/dev/null; then
    replace_prompt_text 'topic-renamed'
  fi
else
  fail bookmark-set-row 'the rebase source row was not restored'
fi
if wait_bookmark_target topic-renamed "$rebase_source_id"; then
  pass bookmark-set 'b s set the bookmark forward to the selected source'
else
  fail bookmark-set 'bookmark set did not target the selected revision'
fi

if open_bookmark_action d &&
   lem_wait_for "$session" 'Delete bookmark:' 10 >/dev/null; then
  replace_prompt_text 'topic-renamed'
fi
if lem_wait_for "$session" 'Delete Jujutsu bookmark' 10 >/dev/null; then
  lem_keys "$session" n
fi
if wait_bookmark_target topic-renamed "$rebase_source_id"; then
  pass bookmark-delete-cancel 'n cancelled bookmark deletion without mutation'
else
  fail bookmark-delete-cancel 'cancelled deletion removed or moved the bookmark'
fi

if open_bookmark_action c &&
   lem_wait_for "$session" 'Create bookmark:' 10 >/dev/null; then
  replace_prompt_text 'forget-me'
fi
if ! wait_bookmark_target forget-me "$rebase_source_id"; then
  fail bookmark-forget-setup 'the forget fixture bookmark was not created'
fi
if open_bookmark_action f &&
   lem_wait_for "$session" 'Forget bookmark:' 10 >/dev/null; then
  replace_prompt_text 'forget-me'
fi
if lem_wait_for "$session" 'Forget Jujutsu bookmark' 10 >/dev/null; then
  lem_keys "$session" y
fi
if wait_bookmark_absent forget-me; then
  pass bookmark-forget 'b f forgot the local bookmark after confirmation'
else
  fail bookmark-forget 'confirmed bookmark forget left the bookmark present'
fi

if open_bookmark_action d &&
   lem_wait_for "$session" 'Delete bookmark:' 10 >/dev/null; then
  replace_prompt_text 'topic-renamed'
fi
if lem_wait_for "$session" 'Delete Jujutsu bookmark' 10 >/dev/null; then
  lem_keys "$session" y
fi
if wait_bookmark_absent topic-renamed; then
  pass bookmark-delete 'b d deleted the bookmark after confirmation'
else
  fail bookmark-delete 'confirmed bookmark deletion left the bookmark present'
fi

lem_keys "$session" q
if invoke_report &&
   [[ $(latest_report) == \
     'STATE kind=none row=no description=none rows=0 root=no read-only=no mode=no keys=yes source=yes source-live=yes' ]]; then
  pass quit 'q returned to the original live source buffer'
else
  fail quit 'the porcelain did not restore its source buffer'
fi

if ((failed)); then
  exit 1
fi
printf 'SUMMARY PASS failures=0\n'
