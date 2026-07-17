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
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
    log --no-graph -r @ \
    --template 'description.first_line()'
}

current_change_id() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
    log --no-graph -r @ \
    --template change_id
}

wait_current_change_id() {
  local expected=$1 index=0
  while ((index < 80)); do
    if [ "$(current_change_id)" = "$expected" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_current_change_not() {
  local previous=$1 index=0
  while ((index < 80)); do
    if [ "$(current_change_id)" != "$previous" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

visible_description() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
    log --no-graph -r 'all()' \
    --template 'description.first_line() ++ "\n"' | grep -Fxq -- "$1"
}

revision_count_by_description() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
    log --no-graph -r 'all()' \
    --template 'description.first_line() ++ "\n"' |
    grep -Fxc -- "$1" || true
}

wait_revision_count() {
  local description=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(revision_count_by_description "$description")" -eq "$expected" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

full_description() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy log --no-graph \
    -r "$1" --template description
}

revision_present() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy log --no-graph \
    -r "$1" --template change_id >/dev/null 2>&1
}

revision_has_file() {
  local revision=$1 path=$2
  local listed
  while IFS= read -r listed; do
    if [[ "$listed" == "$path" || "$listed" == */"$path" ]]; then
      return 0
    fi
  done < <(
    "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
      file list -r "$revision"
  )
  return 1
}

wait_revision_has_file() {
  local revision=$1 path=$2 index=0
  while ((index < 80)); do
    if revision_has_file "$revision" "$path"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_revision_lacks_file() {
  local revision=$1 path=$2 index=0
  while ((index < 80)); do
    if ! revision_has_file "$revision" "$path"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

current_operation_id() {
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
    op log --no-graph -n 1 \
    --template id
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
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy log --no-graph \
    -r "($1)-" --template change_id
}

revision_with_description_parent() {
  local wanted_description=$1 wanted_parent=$2 excluded_revision=$3
  local revision description
  while IFS=$'\t' read -r revision description; do
    if [ "$revision" != "$excluded_revision" ] &&
       [ "$description" = "$wanted_description" ] &&
       [ "$(revision_parent "$revision")" = "$wanted_parent" ]; then
      printf '%s\n' "$revision"
      return 0
    fi
  done < <(
    "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
      log --no-graph -r 'all()' \
      --template 'change_id ++ "\t" ++ description.first_line() ++ "\n"'
  )
  return 1
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
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" --ignore-working-copy \
    bookmark list --quiet "$1" \
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

split_report_count() {
  grep -c '^SPLIT ' "$LEM_YATH_JJ_PORCELAIN_REPORT" 2>/dev/null || true
}

invoke_split_report() {
  local before
  before=$(split_report_count)
  lem_keys "$session" F2
  local index=0
  while ((index < 80)); do
    if (( $(split_report_count) > before )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

latest_split_report() {
  grep '^SPLIT ' "$LEM_YATH_JJ_PORCELAIN_REPORT" | tail -n 1
}

restore_report_count() {
  grep -c '^RESTORE ' "$LEM_YATH_JJ_PORCELAIN_REPORT" 2>/dev/null || true
}

invoke_restore_report() {
  local before
  before=$(restore_report_count)
  lem_keys "$session" F4
  local index=0
  while ((index < 80)); do
    if (( $(restore_report_count) > before )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

latest_restore_report() {
  grep '^RESTORE ' "$LEM_YATH_JJ_PORCELAIN_REPORT" | tail -n 1
}

message_report_count() {
  grep -c '^MESSAGE ' "$LEM_YATH_JJ_PORCELAIN_REPORT" 2>/dev/null || true
}

invoke_message_report() {
  local before
  before=$(message_report_count)
  lem_keys "$session" F3
  local index=0
  while ((index < 80)); do
    if (( $(message_report_count) > before )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

latest_message_report() {
  grep '^MESSAGE ' "$LEM_YATH_JJ_PORCELAIN_REPORT" | tail -n 1
}

replace_prompt_text() {
  local text=$1
  lem_keys "$session" C-a C-k
  tmux_cmd send-keys -t "$session" -l "$text"
  lem_keys "$session" Enter
}

replace_message_text() {
  local text=$1
  lem_keys "$session" g g d G i
  tmux_cmd send-keys -t "$session" -l "$text"
  sleep 0.25
  lem_keys "$session" Escape
  sleep 0.25
  lem_wait_for "$session" 'NORMAL' 10 >/dev/null
}

finish_message_edit() {
  lem_keys "$session" C-c
  sleep 0.5
  lem_keys "$session" C-c
  sleep 0.75
  if lem_capture "$session" | grep -q 'JJ-Message'; then
    # Some tmux/TTY runs coalesce repeated identical control events and leave
    # the already-entered C-c prefix pending. Send only that missing suffix.
    lem_keys "$session" C-c
    sleep 0.5
  fi
}

abort_message_edit() {
  lem_keys "$session" C-c
  lem_wait_for "$session" 'C-c-' 10 >/dev/null
  sleep 0.5
  lem_keys "$session" C-k
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
if lem_wait_for "$session" 'o/O/I/A new' 10 >/dev/null; then
  pass help '? exposed the focused porcelain command surface'
else
  fail help 'the porcelain help summary was not visible'
fi

initial_working_copy_id=$(current_change_id)
lem_keys "$session" '['
if invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=base\nbody_line '* ]]; then
  pass goto-parent '[ selected the sole visible parent row'
else
  fail goto-parent '[ did not select the working copy parent'
fi
lem_keys "$session" ']'
if invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=current '* ]]; then
  pass goto-child '] selected the sole visible child row'
else
  fail goto-child '] did not return to the working copy child'
fi
lem_keys "$session" '[' '[' '['
if lem_wait_for "$session" 'No parent revisions are visible' 10 >/dev/null &&
   [ "$(current_change_id)" = "$initial_working_copy_id" ] &&
   invoke_report && [[ $(latest_report) == *'kind=log row=yes description= rows=3 '* ]]; then
  pass parent-refusal '[ refused the root row without moving or mutating'
else
  fail parent-refusal 'root-parent refusal changed point or repository state'
fi
lem_keys "$session" '.'
if invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass goto-working-copy '. selected the current working-copy row'
else
  fail goto-working-copy '. did not restore the @ row'
fi

# A temporary non-working-copy sibling makes ] exercise Majutsu's exact-choice
# path rather than silently choosing one of several visible children.
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new --no-edit \
  "$base_change_id" --message 'navigation sibling' >/dev/null
navigation_sibling_id=$(
  revision_with_description_parent \
    'navigation sibling' "$base_change_id" "$initial_working_copy_id"
)
navigation_sibling_short=$(
  "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log --no-graph \
    -r "$navigation_sibling_id" --template 'change_id.shortest(12)'
)
lem_keys "$session" g r '[' ']'
if lem_wait_for "$session" 'Go to child:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l "$navigation_sibling_short"
  lem_keys "$session" Enter
fi
if invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=navigation_sibling '* ]]; then
  pass goto-child-choice '] prompted for and selected one of multiple children'
else
  fail goto-child-choice 'multiple-child selection was absent or chose the wrong row'
fi
lem_keys "$session" '.'
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" undo >/dev/null
lem_keys "$session" g r
if wait_revision_absent "$navigation_sibling_id" && invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=current rows=3 '* ]]; then
  pass navigation-cleanup 'the temporary branch was removed and @ stayed selected'
else
  fail navigation-cleanup 'temporary relationship fixture cleanup diverged'
fi

# Log-local O/I/A are immediate Majutsu workflows. Each graph rewrite is
# verified through real jj and then undone before the longstanding suite runs.
lem_keys "$session" O
new_child_id=$initial_working_copy_id
if wait_current_change_not "$initial_working_copy_id"; then
  new_child_id=$(current_change_id)
fi
if [ "$new_child_id" != "$initial_working_copy_id" ] &&
   [ "$(revision_parent "$new_child_id")" = "$initial_working_copy_id" ] &&
   invoke_report && [[ $(latest_report) == *'kind=log row=yes description= '* ]]; then
  pass new-dwim 'O created and selected a child of the selected row'
else
  fail new-dwim 'O did not create the expected child graph'
fi
lem_keys "$session" u '.'
if wait_current_change_id "$initial_working_copy_id" &&
   wait_revision_absent "$new_child_id"; then
  pass new-dwim-undo 'u restored the graph after O'
else
  fail new-dwim-undo 'O was not cleanly undoable'
fi

lem_keys "$session" I
new_before_id=$initial_working_copy_id
if wait_current_change_not "$initial_working_copy_id"; then
  new_before_id=$(current_change_id)
fi
if [ "$new_before_id" != "$initial_working_copy_id" ] &&
   [ "$(revision_parent "$new_before_id")" = "$base_change_id" ] &&
   [ "$(revision_parent "$initial_working_copy_id")" = "$new_before_id" ] &&
   invoke_report && [[ $(latest_report) == *'kind=log row=yes description= '* ]]; then
  pass new-before 'I inserted and selected a change before the selected row'
else
  fail new-before 'I did not create the expected before graph'
fi
lem_keys "$session" u '.'
if wait_current_change_id "$initial_working_copy_id" &&
   wait_revision_absent "$new_before_id" &&
   [ "$(revision_parent "$initial_working_copy_id")" = "$base_change_id" ]; then
  pass new-before-undo 'u restored the graph after I'
else
  fail new-before-undo 'I was not cleanly undoable'
fi

lem_keys "$session" '[' A
new_after_id=$initial_working_copy_id
if wait_current_change_not "$initial_working_copy_id"; then
  new_after_id=$(current_change_id)
fi
if [ "$new_after_id" != "$initial_working_copy_id" ] &&
   [ "$(revision_parent "$new_after_id")" = "$base_change_id" ] &&
   [ "$(revision_parent "$initial_working_copy_id")" = "$new_after_id" ] &&
   invoke_report && [[ $(latest_report) == *'kind=log row=yes description= '* ]]; then
  pass new-after 'A inserted and selected a change after the selected row'
else
  fail new-after 'A did not create the expected after graph'
fi
lem_keys "$session" u '.'
if wait_current_change_id "$initial_working_copy_id" &&
   wait_revision_absent "$new_after_id" &&
   [ "$(revision_parent "$initial_working_copy_id")" = "$base_change_id" ]; then
  pass new-after-undo 'u restored the graph after A'
else
  fail new-after-undo 'A was not cleanly undoable'
fi

# Revert operates on a content-bearing historical source with a live descendant
# so the gate distinguishes destination modes by graph and file state.
revert_baseline_operation=$(current_operation_id)
printf 'content introduced by the revert source\n' \
  >"${LEM_YATH_JJ_PORCELAIN_ROOT}revert.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  --message 'revert descendant' >/dev/null
revert_source_id=$initial_working_copy_id
revert_descendant_id=$(current_change_id)
revert_description='Revert "current"'
lem_keys "$session" g r

lem_keys "$session" _
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" q
fi
if [ "$(revision_count_by_description "$revert_description")" -eq 0 ] &&
   invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass revert-cancel '_ q closed the revert popup without mutation'
else
  fail revert-cancel 'revert cancellation changed history or the selected row'
fi

lem_keys "$session" _
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" _
fi
if wait_revision_count "$revert_description" 1; then
  default_revert_id=$(
    revision_with_description_parent \
      "$revert_description" "$revert_source_id" '' || true
  )
else
  default_revert_id=
fi
if [ -n "$default_revert_id" ] &&
   wait_revision_parent "$revert_descendant_id" "$default_revert_id" &&
   ! revision_has_file "$revert_descendant_id" revert.txt &&
   invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass revert-default '_ _ inserted the reverse after the selected source and retained its row'
else
  fail revert-default 'default revert placement, content, or point restoration diverged'
fi
lem_keys "$session" u
if wait_revision_count "$revert_description" 0 &&
   wait_revision_parent "$revert_descendant_id" "$revert_source_id" &&
   revision_has_file "$revert_descendant_id" revert.txt; then
  pass revert-default-undo 'u restored the graph and content after the default revert'
else
  fail revert-default-undo 'default revert was not cleanly undoable'
fi

lem_keys "$session" _
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" o
fi
if lem_wait_for "$session" 'Revert onto:' 10 >/dev/null; then
  replace_prompt_text "$base_change_id"
fi
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" _
fi
if wait_revision_count "$revert_description" 1; then
  onto_revert_id=$(
    revision_with_description_parent \
      "$revert_description" "$base_change_id" '' || true
  )
else
  onto_revert_id=
fi
if [ -n "$onto_revert_id" ] &&
   wait_revision_parent "$revert_descendant_id" "$revert_source_id" &&
   revision_has_file "$revert_descendant_id" revert.txt; then
  pass revert-onto '_ o placed a prompted reversal on the destination branch'
else
  fail revert-onto 'onto placement rewrote the wrong branch or content'
fi
lem_keys "$session" u
if ! wait_revision_count "$revert_description" 0; then
  fail revert-onto-undo 'onto revert was not cleanly undoable'
fi

lem_keys "$session" _
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" b
fi
if lem_wait_for "$session" 'Insert revert before:' 10 >/dev/null; then
  replace_prompt_text "$revert_descendant_id"
fi
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" _
fi
if wait_revision_count "$revert_description" 1; then
  before_revert_id=$(
    revision_with_description_parent \
      "$revert_description" "$revert_source_id" '' || true
  )
else
  before_revert_id=
fi
if [ -n "$before_revert_id" ] &&
   wait_revision_parent "$revert_descendant_id" "$before_revert_id" &&
   ! revision_has_file "$revert_descendant_id" revert.txt; then
  pass revert-before '_ b inserted the reversal before the prompted descendant'
else
  fail revert-before 'insert-before placement or reversed content diverged'
fi
lem_keys "$session" u
if ! wait_revision_count "$revert_description" 0; then
  fail revert-before-undo 'insert-before revert was not cleanly undoable'
fi

lem_keys "$session" _
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" r
fi
if lem_wait_for "$session" 'Revert revisions:' 10 >/dev/null; then
  replace_prompt_text 'definitely-no-such-revision'
fi
if lem_wait_for "$session" 'JJ Revert' 10 >/dev/null; then
  lem_keys "$session" _
fi
if lem_wait_for "$session" 'jj revert failed' 10 >/dev/null &&
   [ "$(revision_count_by_description "$revert_description")" -eq 0 ] &&
   wait_revision_parent "$revert_descendant_id" "$revert_source_id"; then
  pass revert-refusal 'an invalid source surfaced jj failure without mutation'
else
  fail revert-refusal 'invalid-source revert changed the repository or hid failure'
fi

"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" op restore \
  "$revert_baseline_operation" >/dev/null
lem_keys "$session" g r
if wait_current_change_id "$initial_working_copy_id" &&
   wait_revision_absent "$revert_descendant_id" &&
   [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}revert.txt" ] &&
   invoke_report && [[ $(latest_report) == *'description=current rows=3 '* ]]; then
  pass revert-cleanup 'operation restore removed the isolated revert fixture'
else
  fail revert-cleanup 'revert fixture cleanup did not restore the baseline graph'
fi

# Restore uses two independent working-copy paths so the gate can distinguish
# full, fileset-scoped, source, destination, and changes-in operation modes.
restore_baseline_operation=$(current_operation_id)
printf 'restore one\n' >"${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt"
printf 'restore two\n' >"${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt"
printf 'partial restore line\n' \
  >>"${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt"
lem_keys "$session" g r

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" q
fi
if [ -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ] &&
   invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass restore-cancel 'R q closed the restore popup without mutation'
else
  fail restore-cancel 'restore cancellation changed content or the selected row'
fi

# Majutsu's -i route stays inside Lem. The selector builds the complement
# patch expected by jj's private interactive diff tool, so unselected changes
# survive while the selected hunk or changed line is restored.
lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" i
fi
if lem_wait_for "$session" 'Jujutsu restore selection:' 10 >/dev/null &&
   invoke_restore_report &&
   [[ $(latest_restore_report) == \
     'RESTORE kind=restore-selection hunks=3 selected=0 partial=0 row=yes keys=yes' ]]; then
  pass restore-partial-open 'R - i opened the native three-hunk restore selector'
else
  fail restore-partial-open 'interactive restore parsing, mode, or keymap diverged'
fi
lem_keys "$session" q
if lem_wait_for "$session" 'History' 10 >/dev/null &&
   [ -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ] &&
   grep -Fxq 'partial restore line' \
     "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt" &&
   invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass restore-partial-cancel 'q preserved every change and restored the initiating row'
else
  fail restore-partial-cancel 'selector cancellation mutated content or lost its row'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'Restore fileset or path' 10 >/dev/null; then
  replace_prompt_text 'restore-one.txt'
fi
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" i
fi
if lem_wait_for "$session" 'Jujutsu restore selection:' 10 >/dev/null &&
   invoke_restore_report &&
   [[ $(latest_restore_report) == \
     'RESTORE kind=restore-selection hunks=1 selected=0 partial=0 row=yes keys=yes' ]]; then
  pass restore-partial-fileset 'R -- then -i froze the configured one-path range'
else
  fail restore-partial-fileset 'interactive restore ignored or swallowed its fileset state'
fi
lem_keys "$session" q
lem_wait_for "$session" 'History' 10 >/dev/null || true

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" i
fi
if lem_wait_for "$session" 'Jujutsu restore selection:' 10 >/dev/null; then
  lem_keys "$session" r
fi
if lem_wait_for "$session" 'Select at least one Jujutsu restore hunk' 10 >/dev/null &&
   invoke_restore_report &&
   [[ $(latest_restore_report) == *'hunks=3 selected=0 partial=0 '* ]]; then
  pass restore-partial-empty 'r refused an empty native restore selection'
else
  fail restore-partial-empty 'empty interactive restore did not fail closed'
fi
lem_keys "$session" q

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" i
fi
if lem_wait_for "$session" 'Jujutsu restore selection:' 10 >/dev/null; then
  lem_keys "$session" /
  tmux_cmd send-keys -t "$session" -l '^restore-one.txt$'
  lem_keys "$session" Enter j F
fi
if invoke_restore_report &&
   [[ $(latest_restore_report) == *'hunks=3 selected=1 partial=0 '* ]]; then
  pass restore-partial-file-select 'F selected the exact file represented at point'
else
  fail restore-partial-file-select 'file selection changed the wrong restore hunks'
fi
lem_keys "$session" C H
if invoke_restore_report &&
   [[ $(latest_restore_report) == *'hunks=3 selected=1 partial=0 '* ]]; then
  pass restore-partial-hunk-select 'C then H retained one complete restore hunk'
else
  fail restore-partial-hunk-select 'clear or whole-hunk restore selection diverged'
fi
lem_keys "$session" C /
tmux_cmd send-keys -t "$session" -l '^[+]restore one$'
lem_keys "$session" Enter V
lem_wait_for "$session" 'V-LINE' 10 >/dev/null || true
lem_keys "$session" R
if lem_wait_for "$session" \
     'Select the whole hunk or file when restoring an added or deleted file' \
     10 >/dev/null &&
   invoke_restore_report &&
   [[ $(latest_restore_report) == *'selected=0 partial=0 '* ]]; then
  pass restore-partial-added-refusal 'R rejected unsafe line selection in an added file'
else
  fail restore-partial-added-refusal 'added-file line selection did not fail closed'
fi
lem_keys "$session" Escape
lem_wait_for "$session" 'NORMAL' 10 >/dev/null || true
lem_keys "$session" q
lem_wait_for "$session" 'History' 10 >/dev/null || true

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" i
fi
if lem_wait_for "$session" 'Jujutsu restore selection:' 10 >/dev/null; then
  lem_keys "$session" /
  tmux_cmd send-keys -t "$session" -l '^[+]partial restore line$'
  lem_keys "$session" Enter V
  lem_wait_for "$session" 'V-LINE' 10 >/dev/null || true
  lem_keys "$session" R
fi
if invoke_restore_report &&
   [[ $(latest_restore_report) == *'hunks=3 selected=1 partial=1 '* ]]; then
  pass restore-partial-region-select 'R retained one changed-line restore selection'
else
  fail restore-partial-region-select 'changed-line restore selection was not represented exactly'
fi
lem_keys "$session" r
lem_wait_for "$session" 'Jujutsu partial restore completed' 10 >/dev/null || true
if [ "$(cat "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt")" = \
     'tracked through every Jujutsu operation' ] &&
   [ -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ] &&
   invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass restore-partial-region 'R/r restored only the selected line and preserved its complement'
else
  fail restore-partial-region 'partial restore changed unselected content or lost its row'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if grep -Fxq 'partial restore line' \
     "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt" &&
   wait_revision_has_file "$initial_working_copy_id" restore-one.txt &&
   wait_revision_has_file "$initial_working_copy_id" restore-two.txt; then
  pass restore-partial-undo 'u restored the exact pre-operation working copy'
else
  fail restore-partial-undo 'interactive restore was not cleanly undoable'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" i
fi
if lem_wait_for "$session" 'Jujutsu restore selection:' 10 >/dev/null; then
  lem_keys "$session" F5
fi
if invoke_restore_report &&
   [[ $(latest_restore_report) == *'hunks=3 selected=3 partial=0 '* ]]; then
  pass restore-partial-select-all 'the private-tool edge model covered the complete restore range'
else
  fail restore-partial-select-all 'whole-range interactive selection diverged'
fi
lem_keys "$session" r
lem_wait_for "$session" 'Jujutsu partial restore completed' 10 >/dev/null || true
if [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ] &&
   [ "$(cat "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt")" = \
     'tracked through every Jujutsu operation' ] &&
   invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass restore-partial-empty-complement 'the private tool restored an all-selected range'
else
  fail restore-partial-empty-complement 'the empty complement did not produce a full restore'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if grep -Fxq 'partial restore line' \
     "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt" &&
   wait_revision_has_file "$initial_working_copy_id" restore-one.txt &&
   wait_revision_has_file "$initial_working_copy_id" restore-two.txt; then
  pass restore-partial-empty-complement-undo 'u restored the all-selected operation exactly'
else
  fail restore-partial-empty-complement-undo 'all-selected interactive restore was not undoable'
fi

# Keep the established restore matrix independent of the tracked-line fixture;
# it expects only the two added paths below. Refresh forces jj to snapshot this
# external cleanup before the next editor-driven operation.
sed -i '/^partial restore line$/d' \
  "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt"
lem_keys "$session" g r
invoke_report >/dev/null || true
if [ "$(cat "${LEM_YATH_JJ_PORCELAIN_ROOT}working copy.txt")" = \
     'tracked through every Jujutsu operation' ]; then
  pass restore-partial-isolation 'the partial-line fixture left the legacy restore baseline intact'
else
  fail restore-partial-isolation 'the tracked-line fixture leaked into later restore cases'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ] &&
   invoke_report && [[ $(latest_report) == *'description=current '* ]]; then
  pass restore-default 'R r restored the working copy from its parent and retained the row'
else
  fail restore-default 'argument-free restore did not discard both working-copy changes'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if wait_revision_has_file "$initial_working_copy_id" restore-one.txt &&
   wait_revision_has_file "$initial_working_copy_id" restore-two.txt; then
  pass restore-default-undo 'u restored both discarded working-copy paths'
else
  fail restore-default-undo 'default restore was not cleanly undoable'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'Restore fileset or path' 10 >/dev/null; then
  replace_prompt_text 'restore-one.txt'
fi
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ]; then
  pass restore-fileset 'R -- limited default restore to the prompted path'
else
  fail restore-fileset 'fileset restore changed the wrong working-copy paths'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if ! wait_revision_has_file "$initial_working_copy_id" restore-one.txt ||
   ! wait_revision_has_file "$initial_working_copy_id" restore-two.txt; then
  fail restore-fileset-undo 'fileset restore was not cleanly undoable'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" f
fi
if lem_wait_for "$session" 'Restore from revision or revset' 10 >/dev/null; then
  replace_prompt_text "$base_change_id"
fi
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ]; then
  pass restore-explicit-from 'R - f restored @ from an arbitrary prompted revision'
else
  fail restore-explicit-from 'explicit source revset did not restore the working copy'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if ! wait_revision_has_file "$initial_working_copy_id" restore-one.txt ||
   ! wait_revision_has_file "$initial_working_copy_id" restore-two.txt; then
  fail restore-explicit-from-undo 'explicit-source restore was not cleanly undoable'
fi

lem_keys "$session" '['
lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" t -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'Restore fileset or path' 10 >/dev/null; then
  replace_prompt_text 'restore-one.txt'
fi
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if revision_has_file "$base_change_id" restore-one.txt &&
   revision_has_file "$initial_working_copy_id" restore-one.txt &&
   invoke_report && [[ $(latest_report) == *'description=base\nbody_line '* ]]; then
  pass restore-selected-into 'R t restored one path from @ into the selected historical row'
else
  fail restore-selected-into 'selected-row destination or point restoration diverged'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if ! wait_revision_lacks_file "$base_change_id" restore-one.txt; then
  fail restore-selected-into-undo 'historical destination restore was not cleanly undoable'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" c x r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if revision_has_file "$base_change_id" 'working copy.txt' &&
   revision_has_file "$initial_working_copy_id" 'working copy.txt' &&
   ! revision_has_file "$initial_working_copy_id" restore-one.txt &&
   ! revision_has_file "$initial_working_copy_id" restore-two.txt; then
  pass restore-clear 'x cleared changes-in so execution used the working-copy default'
else
  fail restore-clear 'clear left a historical changes-in selection active'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if ! wait_revision_has_file "$initial_working_copy_id" restore-one.txt ||
   ! wait_revision_has_file "$initial_working_copy_id" restore-two.txt; then
  fail restore-clear-undo 'cleared-selection restore was not cleanly undoable'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" c r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if ! revision_has_file "$base_change_id" 'working copy.txt' &&
   ! revision_has_file "$initial_working_copy_id" 'working copy.txt' &&
   invoke_report && [[ $(latest_report) == *'description=base\nbody_line '* ]]; then
  pass restore-changes-in 'R c removed the selected historical change and retained its row'
else
  fail restore-changes-in 'selected changes-in restore changed the wrong history'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if ! wait_revision_has_file "$base_change_id" 'working copy.txt' ||
   ! wait_revision_has_file "$initial_working_copy_id" 'working copy.txt'; then
  fail restore-changes-in-undo 'historical changes-in restore was not cleanly undoable'
fi

lem_keys "$session" '.' R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" c
fi
if lem_wait_for "$session" 'Restore changes in revision or revset' 10 >/dev/null; then
  replace_prompt_text 'definitely-no-such-restore-revision'
fi
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" r
fi
if lem_wait_for "$session" 'jj restore failed' 10 >/dev/null &&
   revision_has_file "$initial_working_copy_id" restore-one.txt &&
   revision_has_file "$initial_working_copy_id" restore-two.txt; then
  pass restore-refusal 'an invalid changes-in revset surfaced failure without mutation'
else
  fail restore-refusal 'invalid restore input changed history or hid failure'
fi

printf 'preserve through descendant restore\n' \
  >"${LEM_YATH_JJ_PORCELAIN_ROOT}restore-descendant.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  --message 'restore descendant child' >/dev/null
restore_source_id=$initial_working_copy_id
restore_child_id=$(current_change_id)
lem_keys "$session" g r

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" c r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if ! revision_has_file "$restore_source_id" restore-descendant.txt &&
   ! revision_has_file "$restore_child_id" restore-descendant.txt; then
  pass restore-descendants-default 'ordinary changes-in restore preserved descendant diffs'
else
  fail restore-descendants-default 'ordinary restore unexpectedly preserved descendant content'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if ! wait_revision_has_file "$restore_child_id" restore-descendant.txt; then
  fail restore-descendants-default-undo 'ordinary descendant restore was not undoable'
fi

lem_keys "$session" R
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" c -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" d
fi
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" -
fi
if lem_wait_for "$session" 'JJ Restore options' 10 >/dev/null; then
  lem_keys "$session" I
fi
if lem_wait_for "$session" 'JJ Restore' 10 >/dev/null; then
  lem_keys "$session" r
fi
lem_wait_for "$session" 'Jujutsu restore completed' 10 >/dev/null || true
if ! revision_has_file "$restore_source_id" restore-descendant.txt &&
   revision_has_file "$restore_child_id" restore-descendant.txt; then
  pass restore-descendants 'R - d preserved descendant content while restoring its ancestor'
else
  fail restore-descendants 'restore-descendants did not preserve the child snapshot'
fi
lem_keys "$session" u
invoke_report >/dev/null || true
if ! wait_revision_has_file "$restore_child_id" restore-descendant.txt; then
  fail restore-descendants-undo 'descendant-preserving restore was not undoable'
fi

"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" op restore \
  "$restore_baseline_operation" >/dev/null
lem_keys "$session" g r
invoke_report >/dev/null || true
if wait_current_change_id "$initial_working_copy_id" &&
   wait_revision_absent "$restore_child_id" &&
   [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-one.txt" ] &&
   [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-two.txt" ] &&
   [ ! -e "${LEM_YATH_JJ_PORCELAIN_ROOT}restore-descendant.txt" ] &&
   [[ $(latest_report) == *'description=current rows=3 '* ]]; then
  pass restore-cleanup 'operation restore removed the isolated restore fixture'
else
  fail restore-cleanup 'restore fixture cleanup did not recover the baseline graph'
fi

lem_keys "$session" c
if lem_wait_for "$session" 'Edit the message' 10 >/dev/null &&
   invoke_message_report &&
   [[ $(latest_message_report) == \
     MESSAGE\ action=describe\ revision=*' root=yes mode=yes keys=yes origin=yes row=yes modified=no content=current' ]]; then
  pass describe-open 'c opened the selected row in the multiline message editor'
else
  fail describe-open 'describe editor metadata, initial text, or local keys diverged'
fi

lem_keys "$session" A
tmux_cmd send-keys -t "$session" -l ' cancelled'
sleep 0.25
lem_keys "$session" Escape
sleep 0.25
lem_wait_for "$session" 'NORMAL' 10 >/dev/null || true
abort_message_edit
if wait_description current && invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=current '* ]]; then
  pass describe-abort 'C-c C-k discarded the edited description and restored its row'
else
  fail describe-abort 'describe cancellation mutated the revision or lost its row'
fi

lem_keys "$session" c
if lem_wait_for "$session" 'Edit the message' 10 >/dev/null; then
  replace_message_text 'described in Lem'
  finish_message_edit
fi
if wait_description 'described in Lem' && invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=described_in_Lem '* ]]; then
  pass describe 'C-c C-c submitted the editor text and retained its row'
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
if lem_wait_for "$session" 'Edit the message' 10 >/dev/null &&
   invoke_message_report &&
   [[ $(latest_message_report) == *'action=describe '*'content=base\nbody_line' ]]; then
  lem_keys "$session" A
  tmux_cmd send-keys -t "$session" -l $'\nthird line'
  sleep 0.25
  lem_keys "$session" Escape
  sleep 0.25
  lem_wait_for "$session" 'NORMAL' 10 >/dev/null || true
  finish_message_edit
fi
if [ "$(full_description "$base_change_id")" = \
     $'base\nbody line\nthird line' ] &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=base\nbody_line\nthird_line '* ]]; then
  pass multiline-describe 'c preserved and submitted the complete multiline description'
else
  fail multiline-describe 'multiline prefill, direct argv submission, or row restoration failed'
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

duplicate_baseline=$(revision_count_by_description 'rebase source')
lem_keys "$session" y
if lem_wait_for "$session" 'JJ Duplicate' 10 >/dev/null; then
  lem_keys "$session" q
fi
if [ "$(revision_count_by_description 'rebase source')" -eq "$duplicate_baseline" ] &&
   ! lem_capture "$session" | grep -q 'JJ Duplicate' &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=rebase_source '* ]]; then
  pass duplicate-popup-cancel 'y q closed the duplicate popup without mutation'
else
  fail duplicate-popup-cancel 'duplicate cancellation changed history, point, or popup state'
fi

lem_keys "$session" y
if lem_wait_for "$session" 'JJ Duplicate' 10 >/dev/null; then
  lem_keys "$session" y
fi
if wait_revision_count 'rebase source' $((duplicate_baseline + 1)); then
  popup_parent_duplicate=$(
    revision_with_description_parent \
      'rebase source' "$rebase_destination_id" "$rebase_source_id" || true
  )
else
  popup_parent_duplicate=
fi
if [ -n "$popup_parent_duplicate" ] &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=rebase_source '* ]]; then
  pass duplicate-popup-default 'y y duplicated onto the existing parent and retained the source row'
else
  fail duplicate-popup-default 'the popup default lost its placement or selected row'
fi
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" undo >/dev/null
lem_keys "$session" g r
if ! wait_revision_count 'rebase source' "$duplicate_baseline"; then
  fail duplicate-popup-default-undo 'the popup-default fixture did not undo cleanly'
fi

lem_keys "$session" Y
if wait_revision_count 'rebase source' $((duplicate_baseline + 1)); then
  parent_duplicate=$(
    revision_with_description_parent \
      'rebase source' "$rebase_destination_id" "$rebase_source_id" || true
  )
else
  parent_duplicate=
fi
if [ -n "$parent_duplicate" ] &&
   "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
     -r "$parent_duplicate" 'root:rebase-source.txt' |
       grep -Fxq 'source content' &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=rebase_source '* ]]; then
  pass duplicate-dwim 'Y duplicated the selected change onto its parent and retained its row'
else
  fail duplicate-dwim 'immediate duplication lost content, placement, or selected row'
fi

lem_keys "$session" y
if lem_wait_for "$session" 'JJ Duplicate' 10 >/dev/null; then
  lem_keys "$session" o
fi
if lem_wait_for "$session" 'Duplicate destination revision or revset:' 10 >/dev/null; then
  replace_prompt_text "$base_change_id"
fi
if wait_revision_count 'rebase source' $((duplicate_baseline + 2)); then
  onto_duplicate=$(
    revision_with_description_parent \
      'rebase source' "$base_change_id" "$rebase_source_id" || true
  )
else
  onto_duplicate=
fi
if [ -n "$onto_duplicate" ] &&
   "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
     -r "$onto_duplicate" 'root:rebase-source.txt' |
       grep -Fxq 'source content'; then
  pass duplicate-onto 'y o duplicated the selected change onto the prompted destination'
else
  fail duplicate-onto 'onto placement did not retain the duplicated content or parent'
fi
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" undo >/dev/null
lem_keys "$session" g r
if ! wait_revision_count 'rebase source' $((duplicate_baseline + 1)); then
  fail duplicate-onto-undo 'the onto placement fixture did not undo cleanly'
fi

lem_keys "$session" y
if lem_wait_for "$session" 'JJ Duplicate' 10 >/dev/null; then
  lem_keys "$session" a
fi
if lem_wait_for "$session" 'Duplicate insert-after revision or revset:' 10 >/dev/null; then
  replace_prompt_text "$base_change_id"
fi
if wait_revision_count 'rebase source' $((duplicate_baseline + 2)); then
  after_duplicate=$(
    revision_with_description_parent \
      'rebase source' "$base_change_id" "$rebase_source_id" || true
  )
else
  after_duplicate=
fi
if [ -n "$after_duplicate" ] &&
   wait_revision_parent "$rebase_destination_id" "$after_duplicate"; then
  pass duplicate-after 'y a inserted the duplicate after the prompted destination'
else
  fail duplicate-after 'insert-after placement did not reparent the destination children'
fi
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" undo >/dev/null
lem_keys "$session" g r
if ! wait_revision_count 'rebase source' $((duplicate_baseline + 1)) ||
   ! wait_revision_parent "$rebase_destination_id" "$base_change_id"; then
  fail duplicate-after-undo 'the insert-after fixture did not undo cleanly'
fi

lem_keys "$session" y
if lem_wait_for "$session" 'JJ Duplicate' 10 >/dev/null; then
  lem_keys "$session" b
fi
if lem_wait_for "$session" 'Duplicate insert-before revision or revset:' 10 >/dev/null; then
  replace_prompt_text "$rebase_destination_id"
fi
if wait_revision_count 'rebase source' $((duplicate_baseline + 2)); then
  before_duplicate=$(
    revision_with_description_parent \
      'rebase source' "$base_change_id" "$rebase_source_id" || true
  )
else
  before_duplicate=
fi
if [ -n "$before_duplicate" ] &&
   wait_revision_parent "$rebase_destination_id" "$before_duplicate"; then
  pass duplicate-before 'y b inserted the duplicate before the prompted destination'
else
  fail duplicate-before 'insert-before placement did not reparent the destination'
fi
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" undo >/dev/null
lem_keys "$session" g r
if ! wait_revision_count 'rebase source' $((duplicate_baseline + 1)) ||
   ! wait_revision_parent "$rebase_destination_id" "$base_change_id"; then
  fail duplicate-before-undo 'the insert-before fixture did not undo cleanly'
fi

lem_keys "$session" y
if lem_wait_for "$session" 'JJ Duplicate' 10 >/dev/null; then
  lem_keys "$session" o
fi
if lem_wait_for "$session" 'Duplicate destination revision or revset:' 10 >/dev/null; then
  replace_prompt_text 'definitely-no-such-revision'
fi
if lem_wait_for "$session" 'jj duplicate failed' 10 >/dev/null &&
   [ "$(revision_count_by_description 'rebase source')" -eq \
     $((duplicate_baseline + 1)) ] &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=rebase_source '* ]]; then
  pass duplicate-refusal 'an invalid destination surfaced jj failure without mutation'
else
  fail duplicate-refusal 'invalid duplicate placement mutated history or lost the source row'
fi

# Build a content-bearing two-hunk revision so split selection can prove that
# one replacement moves into a new parent while the other remains behind.
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  "$rebase_source_id" --message 'split base' >/dev/null
: >"${LEM_YATH_JJ_PORCELAIN_ROOT}split.txt"
for line in {1..30}; do
  printf 'line %d\n' "$line" >>"${LEM_YATH_JJ_PORCELAIN_ROOT}split.txt"
done
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" status >/dev/null
split_base_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @ --template change_id)
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  "$split_base_id" --message 'split source' >/dev/null
sed -i '2s/.*/first changed by split/' \
  "${LEM_YATH_JJ_PORCELAIN_ROOT}split.txt"
sed -i '25s/.*/second remains behind/' \
  "${LEM_YATH_JJ_PORCELAIN_ROOT}split.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" status >/dev/null
split_source_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @ --template change_id)

lem_keys "$session" g r
selected_split_source=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if invoke_report &&
     [[ $(latest_report) == *'kind=log row=yes description=split_source '* ]]; then
    selected_split_source=1
    break
  fi
  lem_keys "$session" C-k
done
if ((selected_split_source)); then
  pass split-row 'the row map selected the two-hunk split source'
else
  fail split-row 'the split source was not reachable through revision navigation'
fi

lem_keys "$session" S
if lem_wait_for "$session" 'Jujutsu split:' 10 >/dev/null &&
   invoke_split_report &&
   [[ $(latest_split_report) == \
     'SPLIT kind=split hunks=2 selected=0 partial=0 row=yes keys=yes placement=parent parallel=no' ]]; then
  pass split-open 'S opened a two-hunk Majutsu-style selection view'
else
  fail split-open 'split view, hunk parsing, or local keymap diverged'
fi
lem_keys "$session" q
if lem_wait_for "$session" 'History' 10 >/dev/null &&
   [ "$(revision_parent "$split_source_id")" = "$split_base_id" ] &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=split_source '* ]]; then
  pass split-cancel 'q restored the exact source row without mutation'
else
  fail split-cancel 'split cancellation changed history or lost the source row'
fi

lem_keys "$session" S
if lem_wait_for "$session" 'Jujutsu split:' 10 >/dev/null; then
  lem_keys "$session" s
fi
if lem_wait_for "$session" 'Select at least one Jujutsu hunk' 10 >/dev/null &&
   invoke_split_report &&
   [[ $(latest_split_report) == *'kind=split hunks=2 selected=0 '* ]]; then
  pass split-empty-selection 's refused execution without a patch selection'
else
  fail split-empty-selection 'an empty split selection did not fail closed'
fi
lem_keys "$session" q

lem_keys "$session" S
if lem_wait_for "$session" 'Jujutsu split:' 10 >/dev/null; then
  lem_keys "$session" p
fi
if invoke_split_report && [[ $(latest_split_report) == *'parallel=yes' ]]; then
  pass split-parallel-toggle 'p exposed the parallel split layout'
else
  fail split-parallel-toggle 'parallel split state did not toggle'
fi
lem_keys "$session" p o
if lem_wait_for "$session" 'Split destination revision or revset:' 10 >/dev/null; then
  replace_prompt_text "$split_base_id"
fi
if invoke_split_report &&
   [[ $(latest_split_report) == *'placement=destination parallel=no' ]]; then
  pass split-placement 'o retained the prompted split destination'
else
  fail split-placement 'split destination state was not retained'
fi
lem_keys "$session" c
if ! invoke_split_report ||
   [[ $(latest_split_report) != *'placement=parent parallel=no' ]]; then
  fail split-placement-reset 'c did not restore existing-parent placement'
fi

lem_keys "$session" F
if invoke_split_report &&
   [[ $(latest_split_report) == *'hunks=2 selected=2 partial=0 '* ]]; then
  pass split-file-select 'F selected both hunks in the current file'
else
  fail split-file-select 'file-level split selection did not cover both hunks'
fi
lem_keys "$session" C H
if invoke_split_report &&
   [[ $(latest_split_report) == *'hunks=2 selected=1 partial=0 '* ]]; then
  pass split-hunk-select 'C then H retained only the current hunk'
else
  fail split-hunk-select 'clear or whole-hunk selection state diverged'
fi
lem_keys "$session" C

# Select the removed+added replacement lines through a physical Visual-Line
# region. This exercises Majutsu's fine-grained R path, not just whole hunks.
lem_keys "$session" /
tmux_cmd send-keys -t "$session" -l '^-line 2$'
lem_keys "$session" Enter V 2 j R
if invoke_split_report &&
   [[ $(latest_split_report) == *'hunks=2 selected=1 partial=1 '* ]]; then
  pass split-region-select 'R converted a visual replacement into a partial hunk patch'
else
  fail split-region-select 'visual changed-line selection was not retained as a partial hunk'
fi

lem_keys "$session" s
if lem_wait_for "$session" 'Selected change description' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'selected split'
  lem_keys "$session" Enter
fi
if wait_revision_count 'selected split' 1; then
  selected_split_id=$split_source_id
  remaining_split_id=$(
    revision_with_description_parent \
      'split source' "$selected_split_id" 'none' || true
  )
else
  selected_split_id=
  remaining_split_id=
fi
if [ -n "$selected_split_id" ] && [ -n "$remaining_split_id" ] &&
   [ "$(revision_parent "$selected_split_id")" = "$split_base_id" ] &&
   [ "$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
       -r "$selected_split_id" 'root:split.txt' | sed -n '2p')" = \
     'first changed by split' ] &&
   [ "$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
       -r "$selected_split_id" 'root:split.txt' | sed -n '25p')" = \
     'line 25' ] &&
   [ "$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
       -r "$remaining_split_id" 'root:split.txt' | sed -n '25p')" = \
     'second remains behind' ] &&
   "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" diff --git \
     -r "$remaining_split_id" | grep -Fq 'second remains behind' &&
   ! "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" diff --git \
     -r "$remaining_split_id" | grep -Fq 'first changed by split' &&
   lem_wait_for "$session" 'History' 10 >/dev/null &&
   invoke_report &&
   [[ $(latest_report) == *'kind=log row=yes description=selected_split '* ]]; then
  pass split 'S/R/s moved only the selected replacement and restored its change-ID row'
else
  fail split 'partial patch content, graph shape, description, or restoration diverged'
fi

"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" new \
  "$remaining_split_id" --message 'empty split source' >/dev/null
empty_split_id=$("$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" log \
  --no-graph -r @ --template change_id)
lem_keys "$session" g r
selected_empty_split=0
for _ in 1 2 3 4 5 6; do
  if invoke_report &&
     [[ $(latest_report) == *'kind=log row=yes description=empty_split_source '* ]]; then
    selected_empty_split=1
    break
  fi
  lem_keys "$session" C-k
done
if ((selected_empty_split)); then
  lem_keys "$session" S
fi
if lem_wait_for "$session" 'Cannot split an empty Jujutsu revision' 10 >/dev/null &&
   revision_present "$empty_split_id" &&
   [ "$(revision_parent "$empty_split_id")" = "$remaining_split_id" ]; then
  pass split-refusal 'S rejected an empty revision without mutation'
else
  fail split-refusal 'empty-revision split did not fail closed'
fi

# Majutsu's C action commits @ regardless of the selected historical row. Give
# the current working copy a description and content, then cover both editor
# cancellation and the successful multiline commit/new-child transition.
printf 'content committed through Lem\n' \
  >"${LEM_YATH_JJ_PORCELAIN_ROOT}commit.txt"
"$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" describe @ \
  --message 'draft commit' >/dev/null
commit_source_id=$(current_change_id)
lem_keys "$session" g r C
if lem_wait_for "$session" 'Edit the message' 10 >/dev/null &&
   invoke_message_report &&
   [[ $(latest_message_report) == \
     'MESSAGE action=commit revision=@ root=yes mode=yes keys=yes origin=yes row=yes modified=no content=draft_commit' ]]; then
  pass commit-open 'C opened @ with its existing description and message-local keys'
else
  fail commit-open 'commit editor metadata, prefill, or origin state diverged'
fi
lem_keys "$session" A
tmux_cmd send-keys -t "$session" -l ' cancelled'
sleep 0.25
lem_keys "$session" Escape
sleep 0.25
lem_wait_for "$session" 'NORMAL' 10 >/dev/null || true
abort_message_edit
if [ "$(current_change_id)" = "$commit_source_id" ] &&
   [ "$(full_description "$commit_source_id")" = 'draft commit' ] &&
   invoke_report && [[ $(latest_report) == *'kind=log row=yes '* ]]; then
  pass commit-abort 'C-c C-k discarded the commit edit without changing @'
else
  fail commit-abort 'commit cancellation mutated @ or lost the history row'
fi

lem_keys "$session" C
if lem_wait_for "$session" 'Edit the message' 10 >/dev/null; then
  replace_message_text $'committed in Lem\nbody line'
  finish_message_edit
fi
commit_child_id=$(current_change_id)
if [ "$commit_child_id" != "$commit_source_id" ] &&
   [ "$(revision_parent "$commit_child_id")" = "$commit_source_id" ] &&
   [ "$(full_description "$commit_source_id")" = \
     $'committed in Lem\nbody line' ] &&
   "$jj_bin" -R "$LEM_YATH_JJ_PORCELAIN_ROOT" file show \
     -r "$commit_source_id" 'root:commit.txt' |
       grep -Fxq 'content committed through Lem' &&
   [ "$(current_description)" = '' ] &&
   invoke_report && [[ $(latest_report) == *'kind=log row=yes '* ]]; then
  pass commit 'C-c C-c committed the multiline message and selected the new @ row'
else
  fail commit 'commit message, content, graph transition, or new-row restoration diverged'
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
