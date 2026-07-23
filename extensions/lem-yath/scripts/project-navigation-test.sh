#!/usr/bin/env bash
# Real-ncurses coverage for persistent, project-aware navigation workflows.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-project-navigation-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-project-navigation.XXXXXX")"
case "$root" in
  "" | /)
    echo "Refusing unsafe project-navigation test directory: $root" >&2
    exit 1
    ;;
esac

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_HOME="$root/lem-home/"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_PROJECT_NAVIGATION_REPORT="$root/report"
export LEM_YATH_PROJECT_NAVIGATION_ALPHA="$root/projects/alpha/"
export LEM_YATH_PROJECT_NAVIGATION_ALPHA_ALIAS="$root/projects/alpha-alias/"
export LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING="$root/projects/alpha-sibling/"
export LEM_YATH_PROJECT_NAVIGATION_BETA="$root/projects/beta/"
export LEM_YATH_PROJECT_NAVIGATION_GAMMA="$root/projects/gamma/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT="$root/projects/submodule-dot/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE="$root/projects/submodule-outside/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET="$root/projects/submodule-outside-target/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE="$root/projects/submodule-cycle/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD="$root/projects/submodule-cycle/child/"
export LEM_YATH_PROJECT_NAVIGATION_REQUEST_STATE="$root/request-state/"
export LEM_YATH_PROJECT_NAVIGATION_REQUEST_HELPER="$root/request-helper.sh"
export LEM_YATH_PROJECT_NAVIGATION_PREVIEW_FIXTURES="$root/preview-fixtures/"
submodule_child="$root/submodule-child"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" "$LEM_HOME" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/build" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/ignored-dir" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING/build" \
  "$LEM_YATH_PROJECT_NAVIGATION_BETA" \
  "$LEM_YATH_PROJECT_NAVIGATION_GAMMA" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  "$LEM_YATH_PROJECT_NAVIGATION_REQUEST_STATE" \
  "$LEM_YATH_PROJECT_NAVIGATION_PREVIEW_FIXTURES" \
  "$submodule_child/nested"
: >"$LEM_YATH_PROJECT_NAVIGATION_REPORT"

printf 'ignored-target.txt\nignored-dir/\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/.gitignore"
printf 'ALPHA MAIN PROJECT\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/alpha-main.txt"
printf 'TRACKED PROJECT TARGET\nSHARED_GREP ALPHA\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/tracked-target.txt"
printf 'DELETE_GREP FIRST\nKEEP ONE\nDELETE_GREP MIDDLE\nKEEP TWO\nDELETE_GREP FINAL' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/delete-target.txt"
printf 'UNTRACKED PROJECT TARGET\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/untracked-target.txt"
printf 'RECENT PROJECT PREVIEW\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/recent-preview.txt"
printf 'DEEP RECENT PROJECT TARGET\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/deep-recent-target.txt"
printf 'SHARED_GREP TRACKED BUILD\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/build/kept.txt"
printf 'SHARED_GREP IGNORED\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/ignored-target.txt"
printf 'SHARED_GREP IGNORED TREE\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/ignored-dir/secret.txt"
printf 'SIBLING PROJECT FILE\nSHARED_GREP SIBLING\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING/sibling-only.txt"
printf 'BETA MAIN PROJECT\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_BETA/beta-main.txt"
printf 'GAMMA TARGET PROJECT\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_GAMMA/gamma-target.txt"
printf 'SUBMODULE CHILD TARGET\n' \
  >"$submodule_child/nested/child-file.txt"
printf 'OUTSIDE SUBMODULE TARGET\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET/outside.txt"
printf 'CYCLE CHILD TARGET\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD/child.txt"
printf 'line one\r\nline two\r' \
  >"$LEM_YATH_PROJECT_NAVIGATION_PREVIEW_FIXTURES/small.txt"
head -c 1048577 </dev/zero | tr '\0' x \
  >"$LEM_YATH_PROJECT_NAVIGATION_PREVIEW_FIXTURES/large.txt"
printf 'binary\0preview\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_PREVIEW_FIXTURES/binary.bin"
mkfifo "$LEM_YATH_PROJECT_NAVIGATION_PREVIEW_FIXTURES/fifo"
ln -s alpha "$root/projects/alpha-alias"
ln -s ../../beta/beta-main.txt \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/lexical-out.txt"

printf '%s\n' \
  '[submodule "dot"]' \
  '  path = .' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT/.gitmodules"
printf '%s\n' \
  '[submodule "escape"]' \
  '  path = escape' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE/.gitmodules"
ln -s "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE/escape"
printf '%s\n' \
  '[submodule "child"]' \
  '  path = child' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE/.gitmodules"
printf '%s\n' \
  '[submodule "back"]' \
  '  path = back' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD/.gitmodules"
ln -s .. "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD/back"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  'label=$1' \
  'state=$2' \
  ': >"$state/$label-started"' \
  'deadline=$((SECONDS + 30))' \
  'while [ ! -e "$state/$label-release" ]; do' \
  '  if ((SECONDS >= deadline)); then exit 97; fi' \
  '  sleep 0.02' \
  'done' \
  'printf "%s.txt\\0" "request-$label"' \
  >"$LEM_YATH_PROJECT_NAVIGATION_REQUEST_HELPER"
chmod +x "$LEM_YATH_PROJECT_NAVIGATION_REQUEST_HELPER"

for project in \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING" \
  "$LEM_YATH_PROJECT_NAVIGATION_BETA" \
  "$LEM_YATH_PROJECT_NAVIGATION_GAMMA" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD"; do
  git -C "$project" init -q
done
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  config user.name 'Lem Yath Test'
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  config user.email 'lem-yath-test@example.invalid'
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" add \
  .gitmodules back child.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  commit -qm 'Add cyclic child fixture'
git -c advice.addEmbeddedRepo=false \
  -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE" add \
  .gitmodules child
git -C "$LEM_YATH_PROJECT_NAVIGATION_ALPHA" add \
  .gitignore alpha-main.txt build/kept.txt src/delete-target.txt \
  src/tracked-target.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING" add sibling-only.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_BETA" add beta-main.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_GAMMA" add gamma-target.txt
git -C "$submodule_child" init -q
git -C "$submodule_child" config user.name 'Lem Yath Test'
git -C "$submodule_child" config user.email 'lem-yath-test@example.invalid'
git -C "$submodule_child" add nested/child-file.txt
git -C "$submodule_child" commit -qm 'Add child fixture'
git -c protocol.file.allow=always \
  -C "$LEM_YATH_PROJECT_NAVIGATION_ALPHA" \
  submodule add -q "$submodule_child" vendor/child

chmod 640 "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/tracked-target.txt"
touch -d '2020-01-02 03:04:05 UTC' \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/tracked-target.txt"

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
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
  grep -cE "$1" "$LEM_YATH_PROJECT_NAVIGATION_REPORT" 2>/dev/null || true
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

latest_report() {
  grep -E "$1" "$LEM_YATH_PROJECT_NAVIGATION_REPORT" 2>/dev/null |
    tail -n 1
}

leave_grep_insert() {
  local session=$1 before state
  before=$(report_count '^GREP-ESCAPE ')
  lem_keys "$session" Escape
  sleep 0.25
  lem_keys "$session" F12
  wait_report_count '^GREP-ESCAPE ' "$((before + 1))" || return 1
  state=$(latest_report '^GREP-ESCAPE ')
  [[ "$state" == 'GREP-ESCAPE normal=yes '* ]]
}

send_chord() {
  local session=$1
  shift
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

send_ex_write() {
  local session=$1
  tmux_cmd send-keys -t "$session" -l ':'
  sleep "$KEY_DELAY"
  tmux_cmd send-keys -t "$session" -l 'w'
  sleep "$KEY_DELAY"
  lem_keys "$session" Enter
  sleep "$KEY_DELAY"
}

fixture="$(lem-yath_lisp_string "$here/scripts/project-navigation-fixture.lisp")"

start_phase() {
  local session=$1 phase=$2 ready_before
  shift 2
  ready_before=$(report_count "^READY phase=$phase$")
  export LEM_YATH_PROJECT_NAVIGATION_PHASE="$phase"
  tmux_cmd set-environment -g LEM_YATH_PROJECT_NAVIGATION_PHASE "$phase" \
    2>/dev/null || true
  sessions+=("$session")
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$@"
  wait_report_count "^READY phase=$phase$" "$((ready_before + 1))" \
    "$BOOT_TIMEOUT"
}

invoke_mx() {
  local session=$1 command=$2 report_pattern=$3 before
  before=$(report_count "$report_pattern")
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  lem_keys "$session" Enter
  wait_report_count "$report_pattern" "$((before + 1))"
}

submit_completion_prompt() {
  local session=$1 prompt_pattern=$2 index=0
  lem_keys "$session" Enter
  sleep 0.3
  while ((index < 8)); do
    if ! lem_capture "$session" | grep -qE "$prompt_pattern"; then
      return 0
    fi
    sleep 0.1
    index=$((index + 1))
  done
  return 1
}

open_project_picker() {
  local session=$1
  lem_keys "$session" Escape
  sleep 0.2
  send_chord "$session" Space Space
  lem_wait_for "$session" 'Switch to:' "$WAIT_TIMEOUT" >/dev/null
}

narrow_project_picker() {
  local session=$1 key=$2
  tmux_cmd send-keys -t "$session" -l "$key"
  sleep 0.2
  lem_keys "$session" Space
  sleep 0.4
}

capture_picker_state() {
  local session=$1 before
  before=$(report_count '^PICKER-STATE ')
  lem_keys "$session" F10
  if wait_report_count '^PICKER-STATE ' "$((before + 1))"; then
    grep '^PICKER-STATE ' "$LEM_YATH_PROJECT_NAVIGATION_REPORT" | tail -1
  fi
}

wait_screen_absent() {
  local session=$1 pattern=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if ! lem_capture "$session" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

reset_picker_origin() {
  invoke_mx "$1" lem-yath-test-project-navigation-reset-picker-origin \
    '^PICKER-ORIGIN '
}

register_session="lem-yath-project-register-$id"
if start_phase "$register_session" register \
     "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/alpha-main.txt" &&
   lem_wait_for "$register_session" 'ALPHA MAIN PROJECT' "$BOOT_TIMEOUT" \
     >/dev/null; then
  pass register-boot 'clean-profile Lem opened the current Alpha project'
else
  fail register-boot 'registration phase did not initialize' "$register_session"
fi

if invoke_mx "$register_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=register sample=1 ' &&
   grep -q '^HISTORY phase=register sample=1 roots=alpha count=1 alpha=1 beta=0 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass current-project-registration \
    'opening one current-project file registered and persisted Alpha'
else
  fail current-project-registration \
    'clean-profile Alpha registration diverged' "$register_session"
fi

if invoke_mx "$register_session" \
     lem-yath-test-project-navigation-open-beta '^OPEN label=beta ' &&
   lem_wait_for "$register_session" 'BETA MAIN PROJECT' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass second-project-registration 'a real file visit registered Beta'
else
  fail second-project-registration 'Beta did not open through the real hook' \
    "$register_session"
fi

if invoke_mx "$register_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=register sample=2 ' &&
   grep -q '^HISTORY phase=register sample=2 roots=beta,alpha count=2 alpha=1 beta=1 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-mru-order 'Beta moved ahead of Alpha without duplication'
else
  fail project-mru-order 'in-process project MRU order diverged' \
    "$register_session"
fi

lem_stop "$register_session"
sleep 0.5

verify_session="lem-yath-project-verify-$id"
if start_phase "$verify_session" verify &&
   lem_wait_for "$verify_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" \
     >/dev/null; then
  pass verify-boot 'fresh Lem process loaded the shared hermetic profile'
else
  fail verify-boot 'verification phase did not initialize' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=verify sample=1 ' &&
   grep -q '^HISTORY phase=verify sample=1 roots=beta,alpha count=2 alpha=1 beta=1 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-mru-persistence \
    'a fresh process restored the persisted Beta,Alpha MRU'
else
  fail project-mru-persistence 'fresh-process project history diverged' \
    "$verify_session"
fi

# Both editors load the same Beta,Alpha baseline before either writes.  Every
# later operation must transact against the latest disk state rather than its
# stale in-memory vector.
concurrent_session="lem-yath-project-concurrent-$id"
if start_phase "$concurrent_session" concurrent &&
   lem_wait_for "$concurrent_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" \
     >/dev/null &&
   invoke_mx "$concurrent_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=concurrent sample=1 ' &&
   grep -q '^HISTORY phase=concurrent sample=1 roots=beta,alpha count=2 alpha=1 beta=1 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-concurrent-baseline \
    'two live Lem processes loaded the same persisted MRU baseline'
else
  fail project-concurrent-baseline \
    'the second live process did not load the shared baseline' \
    "$concurrent_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-remember-gamma \
     '^HISTORY-ACTION phase=verify action=remember-gamma ' &&
   invoke_mx "$concurrent_session" \
     lem-yath-test-project-navigation-core-remember-alpha \
     '^HISTORY-ACTION phase=concurrent action=core-remember-alpha ' &&
   grep -q '^HISTORY-ACTION phase=verify action=remember-gamma roots=gamma,beta,alpha alpha=1 beta=1 gamma=1$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
   grep -q '^HISTORY-ACTION phase=concurrent action=core-remember-alpha roots=alpha,gamma,beta alpha=1 beta=1 gamma=1$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-concurrent-additions \
    'a stale stock writer preserved the other process addition and updated MRU'
else
  fail project-concurrent-additions \
    'serialized project additions lost an entry or MRU order' \
    "$concurrent_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-core-forget-beta \
     '^HISTORY-ACTION phase=verify action=core-forget-beta ' &&
   invoke_mx "$concurrent_session" \
     lem-yath-test-project-navigation-remember-gamma \
     '^HISTORY-ACTION phase=concurrent action=remember-gamma ' &&
   grep -q '^HISTORY-ACTION phase=verify action=core-forget-beta roots=alpha,gamma alpha=1 beta=0 gamma=1$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
   grep -q '^HISTORY-ACTION phase=concurrent action=remember-gamma roots=gamma,alpha alpha=1 beta=0 gamma=1$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-concurrent-removal \
    'a later stale writer retained another process intentional removal'
else
  fail project-concurrent-removal \
    'a stale writer resurrected a deliberately removed project' \
    "$concurrent_session"
fi

# Restore the baseline so the remainder of the established interaction gate
# keeps testing the same candidate and picker state as before.
if invoke_mx "$concurrent_session" \
     lem-yath-test-project-navigation-core-remember-beta \
     '^HISTORY-ACTION phase=concurrent action=core-remember-beta ' &&
   invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-core-forget-gamma \
     '^HISTORY-ACTION phase=verify action=core-forget-gamma ' &&
   grep -q '^HISTORY-ACTION phase=verify action=core-forget-gamma roots=beta,alpha alpha=1 beta=1 gamma=0$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-concurrent-restore \
    'the shared history returned to the established Beta,Alpha fixture'
else
  fail project-concurrent-restore \
    'the concurrency fixture did not restore its baseline' "$verify_session"
fi
lem_stop "$concurrent_session"

lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" C-x p u
if lem_wait_for "$verify_session" 'Project:' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$verify_session" -l \
    "$LEM_YATH_PROJECT_NAVIGATION_BETA"
  sleep 0.3
fi
if submit_completion_prompt "$verify_session" 'Project:' &&
   invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=verify sample=2 ' &&
   grep -q '^HISTORY phase=verify sample=2 roots=alpha count=1 alpha=1 beta=0 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-unsave-binding \
    'physical C-x p u removed the selected project through the safe stock command'
else
  fail project-unsave-binding \
    'physical C-x p u did not remove exactly the selected project' \
    "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-core-remember-beta \
     '^HISTORY-ACTION phase=verify action=core-remember-beta ' &&
   grep -q '^HISTORY-ACTION phase=verify action=core-remember-beta roots=beta,alpha alpha=1 beta=1 gamma=0$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-unsave-restore \
    'the stock transactional helper restored the established fixture'
else
  fail project-unsave-restore \
    'the stock helper did not restore Beta without disturbing Alpha' \
    "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-history-parser '^HISTORY-PARSER ' &&
   grep -q '^HISTORY-PARSER nil=yes strings=yes displaced=yes dispatch=yes mismatch=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-history-parser \
    'the bounded reader accepts pinned legacy forms and rejects dispatch syntax'
else
  fail project-history-parser \
    'the bounded project-history grammar accepted or rejected the wrong form' \
    "$verify_session"
fi

history_file="$LEM_HOME/history/projects"
history_lock="$history_file.lock"
history_artifacts=$(find "$LEM_HOME/history" -maxdepth 1 -type f \
  -name 'projects.*' ! -name 'projects.lock' -print -quit)
if [ "$(stat -c %a "$history_file" 2>/dev/null)" = 600 ] &&
   [ "$(stat -c %a "$history_lock" 2>/dev/null)" = 600 ] &&
   [ ! -L "$history_file" ] && [ -z "$history_artifacts" ]; then
  pass project-history-storage \
    'state and lock are private regular exact-path files with no temp residue'
else
  fail project-history-storage \
    'project history permissions, type, exact path, or cleanup diverged'
fi

history_good="$root/project-history-good"
history_victim="$root/project-history-victim"
cp -p "$history_file" "$history_good"
printf 'victim-sentinel\n' >"$history_victim"
rm -f "$history_file"
ln -s "$history_victim" "$history_file"
if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-history-refusal \
     '^HISTORY-REFUSAL rejected=yes$' &&
   [ -L "$history_file" ] &&
   grep -qx 'victim-sentinel' "$history_victim"; then
  pass project-history-symlink-refusal \
    'a symlinked history was rejected without touching its target'
else
  fail project-history-symlink-refusal \
    'a symlinked history was followed, replaced, or accepted' "$verify_session"
fi
rm -f "$history_file"
cp -p "$history_good" "$history_file"

printf '#.(error "unsafe")\n' >"$history_file"
chmod 600 "$history_file"
if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-history-refusal \
     '^HISTORY-REFUSAL rejected=yes$' &&
   grep -qx '#.(error "unsafe")' "$history_file"; then
  pass project-history-malformed-refusal \
    'malformed dispatch syntax was rejected without replacing the file'
else
  fail project-history-malformed-refusal \
    'malformed project history was evaluated, accepted, or overwritten' \
    "$verify_session"
fi
cp -p "$history_good" "$history_file"

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-static-checks '^STATIC ' &&
   grep -q '^STATIC normal=yes visual=yes pf=yes pg=yes pp=yes space=yes leader-tree=yes emacs-dispatch=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
   grep -q '^REGEXP escaped-alternation=yes raw-alternation=yes leading-close-class=yes escaped-close-class=yes negated-close-class=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-leader-bindings \
    'leader maps and project-dispatch keys match Emacs; regexp conversion is exact'
else
  fail project-leader-bindings 'project leader bindings diverged' \
    "$verify_session"
fi

request_race_before=$(report_count '^REQUEST-RACE ')
lem_keys "$verify_session" Escape
sleep 0.2
lem_keys "$verify_session" F9
if wait_report_count '^REQUEST-RACE ' "$((request_race_before + 1))" 45 &&
   grep -q '^REQUEST-RACE a-cancelled=yes b-live=yes a-launch=no b-owned=yes a-published=no b-published=yes propagated=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-request-cancellation \
    'cancellation is request-local and stale work cannot launch or publish'
else
  fail project-request-cancellation \
    'overlapping project request ownership diverged' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-setup-buffers '^SETUP ' &&
   lem_wait_for "$verify_session" 'ALPHA MAIN PROJECT' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass buffer-setup 'file and non-file sibling fixtures were created'
else
  fail buffer-setup 'project buffer fixture setup failed' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-record-candidates '^CANDIDATES ' &&
   grep -q '^CANDIDATES root=alpha tracked=yes untracked=yes ignored=no ignored-tree=no git-internal=no sibling=no relative=yes unique=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass git-project-candidates \
    'Git candidates include tracked and untracked files but no ignored escape'
else
  fail git-project-candidates 'Git project candidate contract diverged' \
    "$verify_session"
fi

if grep -q '^SUBMODULE file=yes gitlink=no merged-root=alpha$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass git-submodule-parity \
    'initialized child files merge into Alpha without exposing the gitlink'
else
  fail git-submodule-parity \
    'Git submodule candidates or merged root diverged' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-submodule-safety \
     '^SUBMODULE-SAFETY ' &&
   grep -q '^SUBMODULE-SAFETY dot=yes outside=yes cycle=yes visited-once=yes bounded=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass git-submodule-safety \
    'malformed, escaping, and cyclic submodule roots are bounded and unique'
else
  fail git-submodule-safety \
    'submodule containment or cycle handling diverged' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-record-buffers '^BUFFERS ' &&
   grep -q '^BUFFERS root=alpha alpha-file=yes alpha-nonfile=yes sibling-file=no sibling-nonfile=no fileless=yes exact=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-buffer-membership \
    'buffer-directory includes non-files and exactly excludes alpha-sibling'
else
  fail project-buffer-membership 'project buffer containment diverged' \
    "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" Space p f
if lem_wait_for "$verify_session" 'Project file( \(current\))?:' "$WAIT_TIMEOUT" >/dev/null &&
   lem_wait_for "$verify_session" 'src/tracked-target\.txt' "$WAIT_TIMEOUT" \
     >/dev/null &&
   lem_wait_for "$verify_session" 'src/untracked-target\.txt' "$WAIT_TIMEOUT" \
     >/dev/null; then
  file_screen=$(lem_capture "$verify_session")
  if ! grep -Fq 'ignored-target.txt' <<<"$file_screen" &&
     ! grep -Fq 'ignored-dir/secret.txt' <<<"$file_screen" &&
     ! grep -Fq '.git/' <<<"$file_screen"; then
    pass spc-p-f-candidates \
      'SPC p f exposed tracked and untracked Git candidates only'
  else
    fail spc-p-f-candidates 'SPC p f exposed an ignored or internal path' \
      "$verify_session"
  fi
  if grep -Eq 'src/tracked-target\.txt.*-rw-r-----.*41.*2020 Jan 02' \
       <<<"$file_screen"; then
    pass project-file-annotations \
      'SPC p f retained relative labels and added resolved file metadata'
  else
    fail project-file-annotations \
      'project file metadata was missing or used the wrong root' \
      "$verify_session"
  fi
  tmux_cmd send-keys -t "$verify_session" -l 'untracked-target'
  sleep 0.4
  submit_completion_prompt "$verify_session" 'Project file( \(current\))?:'
  if lem_wait_for "$verify_session" 'UNTRACKED PROJECT TARGET' \
       "$WAIT_TIMEOUT" >/dev/null; then
    before=$(report_count '^CURRENT label=spc-p-f ')
    lem_keys "$verify_session" F6
    if wait_report_count '^CURRENT label=spc-p-f ' "$((before + 1))" &&
       grep -q '^CURRENT label=spc-p-f root=alpha name=untracked-target\.txt file=src/untracked-target\.txt directory=src/$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-f-selection \
        'SPC p f resolved Alpha from a non-file buffer and opened its file'
    else
      fail spc-p-f-selection 'SPC p f opened the wrong file identity' \
        "$verify_session"
    fi
  else
    fail spc-p-f-selection 'SPC p f did not open the untracked target' \
      "$verify_session"
  fi
else
  fail spc-p-f-binding 'SPC p f did not expose both expected candidates' \
    "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" Space p g
if lem_wait_for "$verify_session" 'Project regexp:' "$WAIT_TIMEOUT" \
     >/dev/null; then
  tmux_cmd send-keys -t "$verify_session" -l 'SHARED_GREP'
  lem_keys "$verify_session" Enter
  if lem_wait_for "$verify_session" 'SHARED_GREP ALPHA' "$WAIT_TIMEOUT" \
       >/dev/null; then
    grep_screen=$(lem_capture "$verify_session")
    if ! grep -Fq 'SHARED_GREP SIBLING' <<<"$grep_screen" &&
       ! grep -Fq 'SHARED_GREP IGNORED' <<<"$grep_screen"; then
      pass spc-p-g-results \
        'SPC p g stayed inside Alpha and honored ignored paths'
    else
      fail spc-p-g-results 'project grep leaked a sibling or ignored result' \
        "$verify_session"
    fi
    before=$(report_count '^GREP ')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP ' "$((before + 1))" &&
       grep -q '^GREP alpha=yes tracked-build=yes sibling=no ignored=no matches=2 readonly=yes active=no enter=yes finish=yes delete=yes unmark=yes unmark-all=yes abort=yes exit=yes ex=yes ex-count=1$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-buffer \
        'project grep opens read-only with the pinned staged-edit bindings'
    else
      fail spc-p-g-buffer 'the project grep result buffer diverged' \
        "$verify_session"
    fi

    send_chord "$verify_session" i
    sleep 0.2
    before=$(report_count '^GREP ')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP ' "$((before + 1))" &&
       grep -q '^GREP .* readonly=no active=yes ' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-stage-entry \
        'Evil-Collection i entered a writable isolated wgrep-style stage'
    else
      fail spc-p-g-stage-entry \
        'normal-state i did not enter staged project-grep editing' \
        "$verify_session"
    fi

    lem_keys "$verify_session" F2
    send_chord "$verify_session" i
    tmux_cmd send-keys -t "$verify_session" -l 'STAGED_'
    sleep 0.4
    before=$(report_count '^GREP-MULTILINE ')
    lem_keys "$verify_session" F4
    if wait_report_count '^GREP-MULTILINE ' "$((before + 1))" &&
       grep -qx 'GREP-MULTILINE blocked=yes unchanged=yes active=yes' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-stage-multiline \
        'pasted multiline text was refused before it could split a staged row'
    else
      fail spc-p-g-stage-multiline \
        'a pasted multiline staged grep edit was not refused atomically' \
        "$verify_session"
    fi
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" &&
       grep -q '^GREP-WRITEBACK result=yes source=no modified=no disk=no .* active=yes readonly=no status=CHANGED$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-stage-isolation \
        'editing changed only the staged result and highlighted it as pending'
    else
      fail spc-p-g-stage-isolation \
        'a staged edit leaked into the source or lost its pending state' \
        "$verify_session"
    fi

    if leave_grep_insert "$verify_session" &&
       [[ "$(latest_report '^GREP-ESCAPE ')" =~ ^GREP-ESCAPE\ normal=yes\ state=.*\ result=yes$ ]]; then
      pass spc-p-g-escape \
        'Escape left Vi Insert state without dismissing staged grep results'
    else
      fail spc-p-g-escape \
        'Escape did not preserve the staged grep UI in Vi Normal state' \
        "$verify_session"
    fi
    send_ex_write "$verify_session"
    sleep 0.4
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" &&
       grep -q '^GREP-WRITEBACK result=yes source=yes modified=yes disk=no .* active=no readonly=yes status=DONE$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-stage-apply \
        'Evil-Collection :w applied the staged row without saving it'
    else
      fail spc-p-g-stage-apply \
        ':w did not apply and close the staged transaction safely' \
        "$verify_session"
    fi

    lem_keys "$verify_session" C-x o
    sleep 0.3
    send_ex_write "$verify_session"
    lem_keys "$verify_session" C-x o
    sleep 0.2
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" &&
       grep -q '^GREP-WRITEBACK result=yes source=yes modified=no disk=yes .* active=no readonly=yes status=DONE$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-writeback-save \
        'native :w fallback saved the source edit to disk'
    else
      fail spc-p-g-writeback-save \
        'the source save did not persist the grep edit cleanly' \
        "$verify_session"
    fi

    send_chord "$verify_session" i
    send_chord "$verify_session" Z Z
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" &&
       grep -q '^GREP-WRITEBACK result=yes source=yes modified=no disk=yes .* active=no readonly=yes status=DONE$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-stage-zz-empty \
        'Evil-Collection ZZ closed an unchanged staged transaction'
    else
      fail spc-p-g-stage-zz-empty \
        'ZZ did not close an unchanged staged transaction safely' \
        "$verify_session"
    fi

    send_chord "$verify_session" i
    lem_keys "$verify_session" F2
    send_chord "$verify_session" i
    tmux_cmd send-keys -t "$verify_session" -l 'ABORT_'
    sleep 0.3
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" || true
    if ! leave_grep_insert "$verify_session"; then
      fail spc-p-g-stage-abort-state \
        'could not leave Insert state before the ZQ abort' \
        "$verify_session"
    fi
    send_chord "$verify_session" Z Q
    sleep 0.3
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" &&
       grep -q '^GREP-WRITEBACK result=yes source=yes modified=no disk=yes abort-result=no abort-source=no .* active=no readonly=yes status=NONE$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-stage-abort \
        'Evil-Collection ZQ restored the result without touching the source'
    else
      fail spc-p-g-stage-abort \
        'aborting did not restore the staged result exactly' \
        "$verify_session"
    fi

    send_chord "$verify_session" i
    lem_keys "$verify_session" F2
    send_chord "$verify_session" i
    tmux_cmd send-keys -t "$verify_session" -l 'EXIT_'
    sleep 0.3
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" || true
    if ! leave_grep_insert "$verify_session"; then
      fail spc-p-g-stage-exit-state \
        'could not leave Insert state before normal Escape exit' \
        "$verify_session"
    fi
    lem_keys "$verify_session" Escape
    if lem_wait_for "$verify_session" \
         'Project grep modified; apply changes.*\[y/n\]' \
         "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$verify_session" n
      sleep 0.3
      before=$(report_count '^GREP-WRITEBACK result=')
      lem_keys "$verify_session" F8
      if wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" &&
         grep -q '^GREP-WRITEBACK result=yes source=yes modified=no disk=yes abort-result=no abort-source=no exit-result=no exit-source=no .* active=no readonly=yes status=NONE$' \
           "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
        pass spc-p-g-stage-exit \
          'normal Escape prompted and n discarded only the staged result edit'
      else
        fail spc-p-g-stage-exit \
          'normal Escape cancellation did not restore the staged result' \
          "$verify_session"
      fi
    else
      fail spc-p-g-stage-exit \
        'normal Escape did not open the pinned apply-or-discard prompt' \
        "$verify_session"
    fi

    send_chord "$verify_session" i
    lem_keys "$verify_session" F2
    send_chord "$verify_session" i
    tmux_cmd send-keys -t "$verify_session" -l 'STALE_'
    sleep 0.3
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" || true
    if ! leave_grep_insert "$verify_session"; then
      fail spc-p-g-stage-stale-state \
        'could not leave Insert state before the stale-source apply' \
        "$verify_session"
    fi
    before=$(report_count '^GREP-STALE ')
    lem_keys "$verify_session" F3
    wait_report_count '^GREP-STALE ' "$((before + 1))" || true
    send_chord "$verify_session" Z Z
    sleep 0.3
    before=$(report_count '^GREP-WRITEBACK result=')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP-WRITEBACK result=' "$((before + 1))" &&
       grep -q '^GREP-WRITEBACK result=no source=no modified=yes disk=yes abort-result=no abort-source=no exit-result=no exit-source=no stale-result=yes external-source=yes active=no readonly=yes status=REJECT$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-stage-stale \
        'apply rejected a source line changed after grep without overwriting it'
    else
      fail spc-p-g-stage-stale \
        'stale-source protection lost either the source or staged edit' \
        "$verify_session"
    fi

    send_chord "$verify_session" j k
    if lem_wait_for "$verify_session" 'Source changed after grep' \
         "$WAIT_TIMEOUT" >/dev/null; then
      pass spc-p-g-stage-stale-echo \
        'revisiting a rejected row echoed its exact failure reason'
    else
      fail spc-p-g-stage-stale-echo \
        'the rejected row did not explain itself when revisited' \
        "$verify_session"
    fi

  else
    fail spc-p-g-results 'SPC p g produced no Alpha match' "$verify_session"
  fi
else
  fail spc-p-g-binding 'SPC p g did not open the regexp prompt' \
    "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.4
lem_keys "$verify_session" Escape
sleep 0.2

send_chord "$verify_session" Space p g
if lem_wait_for "$verify_session" 'Project regexp:' "$WAIT_TIMEOUT" \
     >/dev/null; then
  lem_keys "$verify_session" C-a C-k
  tmux_cmd send-keys -t "$verify_session" -l 'DELETE_GREP'
  lem_keys "$verify_session" Enter
  if lem_wait_for "$verify_session" 'DELETE_GREP FIRST' "$WAIT_TIMEOUT" \
       >/dev/null; then
    send_chord "$verify_session" i
    send_chord "$verify_session" C-c C-d
    send_chord "$verify_session" u
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=0 ignored=0 pending=0 blank=0 active=yes readonly=no source=original disk=original modified=no$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-undo \
        'undo restored a whole-row deletion mark and its separate intent'
    else
      fail spc-p-g-delete-undo \
        'undo left stale deletion intent or result text' "$verify_session"
    fi

    send_chord "$verify_session" C-c C-d
    send_chord "$verify_session" C-c C-k
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=0 ignored=0 pending=0 blank=0 active=no readonly=yes source=original disk=original modified=no$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-abort \
        'abort restored a marked deletion without touching its source'
    else
      fail spc-p-g-delete-abort \
        'abort retained deletion intent or changed the source' "$verify_session"
    fi

    send_chord "$verify_session" i
    send_chord "$verify_session" C-c C-d
    send_chord "$verify_session" j
    send_chord "$verify_session" C-c C-d
    send_chord "$verify_session" j
    send_chord "$verify_session" C-c C-d
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=3 ignored=0 pending=3 blank=3 active=yes readonly=no source=original disk=original modified=no$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-stage \
        'C-c C-d marked first, middle, and unterminated final rows in isolation'
    else
      fail spc-p-g-delete-stage \
        'whole-row deletion did not retain three isolated marks' "$verify_session"
    fi

    send_chord "$verify_session" k k
    send_chord "$verify_session" V j
    send_chord "$verify_session" C-c C-r
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=1 ignored=2 pending=1 blank=3 active=yes readonly=no source=original disk=original modified=no$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-unmark-region \
        'C-c C-r unmarked only changed rows intersecting the Visual region'
    else
      fail spc-p-g-delete-unmark-region \
        'regional unmarking changed text, source state, or the wrong intents' \
        "$verify_session"
    fi

    send_chord "$verify_session" C-c C-u
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=0 ignored=3 pending=0 blank=3 active=yes readonly=no source=original disk=original modified=no$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-unmark-all \
        'C-c C-u removed every remaining apply intent without restoring text'
    else
      fail spc-p-g-delete-unmark-all \
        'whole-buffer unmarking restored text or retained apply intent' \
        "$verify_session"
    fi

    send_chord "$verify_session" C-c C-e
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=0 ignored=0 pending=0 blank=3 active=no readonly=yes source=original disk=original modified=no$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-unmark-accept \
        'applying only unmarked rows retained display text as the next baseline'
    else
      fail spc-p-g-delete-unmark-accept \
        'accepting unmarked rows rearmed them or changed their source' \
        "$verify_session"
    fi

    send_chord "$verify_session" i
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=0 ignored=0 pending=0 blank=3 active=yes readonly=no source=original disk=original modified=no$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-unmark-reenter \
        'a later stage kept accepted display-only rows inactive'
    else
      fail spc-p-g-delete-unmark-reenter \
        'a later stage confused the result baseline with the source snapshot' \
        "$verify_session"
    fi

    send_chord "$verify_session" k
    send_chord "$verify_session" C-c C-d
    send_chord "$verify_session" j
    send_chord "$verify_session" C-c C-d
    send_chord "$verify_session" j
    send_chord "$verify_session" C-c C-d

    send_chord "$verify_session" C-c C-e
    before=$(report_count '^GREP-DELETE ')
    lem_keys "$verify_session" F1
    if wait_report_count '^GREP-DELETE ' "$((before + 1))" &&
       grep -q '^GREP-DELETE records=3 marked=0 ignored=0 pending=0 blank=3 active=no readonly=yes source=remaining disk=original modified=yes$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-delete-apply \
        'apply removed complete source lines bottom-up without saving the file'
    else
      fail spc-p-g-delete-apply \
        'whole-row apply lost line boundaries, ordering, or the save boundary' \
        "$verify_session"
    fi
  else
    fail spc-p-g-delete-results \
      'the dedicated deletion grep returned no first row' "$verify_session"
  fi
else
  fail spc-p-g-delete-binding \
    'the deletion scenario could not open project grep' "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.4
lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" Space p p
if lem_wait_for "$verify_session" 'Project( \(current\))?:' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$verify_session" -l 'choose'
  if lem_wait_for "$verify_session" 'choose a dir' "$WAIT_TIMEOUT" \
       >/dev/null; then
    submit_completion_prompt "$verify_session" 'Project( \(current\))?:'
    if lem_wait_for "$verify_session" 'Project directory.*:' "$WAIT_TIMEOUT" \
         >/dev/null; then
      lem_keys "$verify_session" F4
      if lem_wait_for "$verify_session" 'Project command' "$WAIT_TIMEOUT" \
           >/dev/null &&
         lem_wait_for "$verify_session" 'find file' "$WAIT_TIMEOUT" \
           >/dev/null &&
         lem_wait_for "$verify_session" 'find regexp' "$WAIT_TIMEOUT" \
           >/dev/null; then
        pass spc-p-p-dispatch \
          'SPC p p accepted an arbitrary directory and showed its dispatch'
        lem_keys "$verify_session" f
        if lem_wait_for "$verify_session" 'Project file( \(current\))?:' "$WAIT_TIMEOUT" \
             >/dev/null; then
          tmux_cmd send-keys -t "$verify_session" -l 'gamma-target'
          sleep 0.3
          submit_completion_prompt "$verify_session" 'Project file( \(current\))?:'
          if lem_wait_for "$verify_session" 'GAMMA TARGET PROJECT' \
               "$WAIT_TIMEOUT" >/dev/null; then
            before=$(report_count '^CURRENT label=spc-p-p ')
            lem_keys "$verify_session" F7
            if wait_report_count '^CURRENT label=spc-p-p ' \
                 "$((before + 1))" &&
               grep -q '^CURRENT label=spc-p-p root=gamma name=gamma-target\.txt file=gamma-target\.txt directory=\.$' \
                 "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
               grep -q '^SWITCH dispatch=find-file gamma-known=yes mru-first=gamma$' \
                 "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
              pass spc-p-p-selection \
                'the dispatch ran find-file against Gamma and promoted its MRU'
            else
              fail spc-p-p-selection \
                'project switch dispatch retained the wrong project root' \
                "$verify_session"
            fi
          else
            fail spc-p-p-selection \
              'Gamma dispatch did not open gamma-target.txt' "$verify_session"
          fi
        else
          fail spc-p-p-find 'dispatch f did not open a project-file prompt' \
            "$verify_session"
        fi
      else
        fail spc-p-p-dispatch 'project switch dispatch was absent or incomplete' \
          "$verify_session"
      fi
    else
      fail spc-p-p-directory 'arbitrary-directory choice did not prompt' \
        "$verify_session"
    fi
  else
    fail spc-p-p-choice 'project picker omitted its arbitrary-directory row' \
      "$verify_session"
  fi
else
  fail spc-p-p-binding 'SPC p p did not open the project picker' \
    "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-setup-picker '^PICKER-SETUP ' &&
   grep -q '^PICKER-SETUP duplicate=yes recent=yes lexical=yes alias-buffer=yes hooks=0$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-picker-setup \
    'Consult-style buffer, recent-file, root, and lexical alias fixtures loaded'
else
  fail project-picker-setup 'project picker fixture setup diverged' \
    "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-bounded-preview '^PICKER-BOUNDED ' &&
   grep -q '^PICKER-BOUNDED small=yes large=yes binary=yes fifo=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-picker-bounded-preview \
    'one bounded reader normalizes text and rejects large, binary, and FIFO inputs'
else
  fail project-picker-bounded-preview 'bounded preview input handling diverged' \
    "$verify_session"
fi

if open_project_picker "$verify_session" &&
   lem_wait_for "$verify_session" 'PROJECT BUFFER' "$WAIT_TIMEOUT" \
     >/dev/null; then
  picker_screen=$(lem_capture "$verify_session")
  buffer_group_line=$(grep -n -m1 'Project Buffer' <<<"$picker_screen" | cut -d: -f1)
  file_group_line=$(grep -n -m1 'Project File' <<<"$picker_screen" | cut -d: -f1)
  root_group_line=$(grep -n -m1 'Project Root' <<<"$picker_screen" | cut -d: -f1)
  if [[ -n "$buffer_group_line" && -n "$file_group_line" &&
        -n "$root_group_line" ]] &&
     ((buffer_group_line < file_group_line && file_group_line < root_group_line)); then
    buffer_group_rows=$(sed -n "$((buffer_group_line + 1)),$((file_group_line - 1))p" \
      <<<"$picker_screen")
    file_group_rows=$(sed -n "$((file_group_line + 1)),$((root_group_line - 1))p" \
      <<<"$picker_screen")
    if grep -Fq 'alpha-main.txt' <<<"$buffer_group_rows" &&
       grep -Fq '*alpha-build*' <<<"$buffer_group_rows" &&
       grep -Fq 'src/recent-preview.txt' <<<"$buffer_group_rows" &&
       grep -Fq 'src/recent-preview.txt' <<<"$file_group_rows" &&
       grep -Fq 'src/lexical-out.txt' <<<"$file_group_rows" &&
       ! grep -Fq 'sibling-only.txt' <<<"$picker_screen" &&
       ! grep -Fq '*sibling-build*' <<<"$picker_screen" &&
       ! grep -Fq '*alias-build*' <<<"$picker_screen" &&
       ! grep -Fq 'alpha-alias' <<<"$picker_screen"; then
      pass project-picker-sources \
        'fixed groups preserve duplicate identities and lexical project membership'
    else
      fail project-picker-sources 'candidate source membership diverged' \
        "$verify_session"
    fi
  else
    fail project-picker-sources 'initial group order diverged' "$verify_session"
  fi
  picker_state=$(capture_picker_state "$verify_session")
  if grep -q 'prompt=yes .*group="Project Buffer" .*source=duplicate .*hooks=0 kill-hooks=0 history-same=yes .*mru-same=yes' \
       <<<"$picker_state"; then
    pass project-picker-immediate-preview \
      'the first buffer row previews without MRU, find-file, or kill-hook effects'
  else
    fail project-picker-immediate-preview \
      "unexpected initial picker state: $picker_state" "$verify_session"
  fi
else
  fail project-picker-binding 'SPC SPC did not open the grouped picker' \
    "$verify_session"
fi

lem_keys "$verify_session" 'M-}'
if lem_wait_for "$verify_session" 'PROJECT PREVIEW' "$WAIT_TIMEOUT" \
     >/dev/null; then
  picker_screen=$(lem_capture "$verify_session")
  first_group=$(grep -E 'Project (Buffer|File|Root)' <<<"$picker_screen" | head -1)
  picker_state=$(capture_picker_state "$verify_session")
  if grep -Fq 'Project File' <<<"$first_group" &&
     grep -q 'prompt=yes .*group="Project File" .*source=temporary temp=yes temp-listed=no .*hooks=0 kill-hooks=0 history-same=yes' \
       <<<"$picker_state"; then
    pass project-picker-next-group \
      'M-} rotated Project File first and previewed it in an unlisted buffer'
  else
    fail project-picker-next-group \
      "group rotation or file preview diverged: $picker_state" "$verify_session"
  fi
else
  fail project-picker-next-group 'M-} did not focus Project File' \
    "$verify_session"
fi

lem_keys "$verify_session" 'M-{'
sleep 0.4
picker_state=$(capture_picker_state "$verify_session")
if grep -q 'prompt=yes .*group="Project Buffer" .*source=duplicate .*preview-deleted=yes .*kill-hooks=0' \
     <<<"$picker_state"; then
  pass project-picker-previous-group \
    'M-{ restored Project Buffer and deleted the prior temporary preview'
else
  fail project-picker-previous-group \
    "previous-group cleanup diverged: $picker_state" "$verify_session"
fi
lem_keys "$verify_session" C-g
sleep 0.3
picker_state=$(capture_picker_state "$verify_session")
if grep -q 'prompt=no .*source=origin .*preview-deleted=yes .*kill-hooks=0 history-same=yes exact=yes .*mru-same=yes point=7 view=1 horizontal=4$' \
     <<<"$picker_state"; then
  pass project-picker-abort-rollback \
    'abort restored the exact origin and deleted every sampled preview'
else
  fail project-picker-abort-rollback \
    "abort rollback diverged: $picker_state" "$verify_session"
fi

if reset_picker_origin "$verify_session" &&
   open_project_picker "$verify_session"; then
  narrow_project_picker "$verify_session" f
  if lem_wait_for "$verify_session" 'Switch to: \[Project File\]' \
       "$WAIT_TIMEOUT" >/dev/null; then
    picker_screen=$(lem_capture "$verify_session")
    if grep -Fq 'Project File' <<<"$picker_screen" &&
       ! grep -Fq 'Project Buffer' <<<"$picker_screen" &&
       ! grep -Fq 'Project Root' <<<"$picker_screen"; then
      pass project-picker-narrow-prefix \
        'f Space visibly narrowed to the Project File source only'
    else
      fail project-picker-narrow-prefix 'file narrowing retained another group' \
        "$verify_session"
    fi
  else
    fail project-picker-narrow-prefix 'file narrowing omitted its prompt indicator' \
      "$verify_session"
  fi
  edit_before=$(report_count '^PICKER-EDIT ')
  lem_keys "$verify_session" F11
  if ! wait_report_count '^PICKER-EDIT ' "$((edit_before + 1))"; then
    fail project-picker-origin-edit 'could not edit the hidden origin during preview' \
      "$verify_session"
  fi
  tmux_cmd send-keys -t "$verify_session" -l 'qqq-no-project-picker-match'
  sleep 0.5
  picker_state=$(capture_picker_state "$verify_session")
  if grep -Fq 'prompt=yes input="qqq-no-project-picker-match" focus="none" group="none"' \
       <<<"$picker_state" &&
     grep -q 'source=origin .*hooks=0 kill-hooks=0 history-same=yes exact=yes .*point=13 view=1 horizontal=4$' \
       <<<"$picker_state"; then
    pass project-picker-no-match-rollback \
      'zero results retain the query and restore durable origin markers'
  else
    fail project-picker-no-match-rollback \
      "zero-result rollback diverged: $picker_state" "$verify_session"
  fi
  calls_before_space=$(sed -n 's/.* calls=\([0-9][0-9]*\) .*/\1/p' \
    <<<"$picker_state")
  lem_keys "$verify_session" Space
  sleep 0.4
  space_state=$(capture_picker_state "$verify_session")
  calls_after_space=$(sed -n 's/.* calls=\([0-9][0-9]*\) .*/\1/p' \
    <<<"$space_state")
  if [[ -n "$calls_before_space" && -n "$calls_after_space" ]] &&
     ((calls_after_space > calls_before_space)) &&
     grep -Fq 'prompt=yes input="qqq-no-project-picker-match " focus="none" group="none"' \
       <<<"$space_state"; then
    pass project-picker-space-reopen \
      'Space after zero results invoked the provider again and retained the prompt'
  else
    fail project-picker-space-reopen \
      "Space did not reopen zero-result completion: $space_state" "$verify_session"
  fi
  lem_keys "$verify_session" C-g
  sleep 0.3
  picker_state=$(capture_picker_state "$verify_session")
  if grep -q 'prompt=no .*source=origin .*hooks=0 kill-hooks=0 history-same=yes exact=yes .*point=13 view=1 horizontal=4$' \
       <<<"$picker_state"; then
    pass project-picker-no-match-abort \
      'aborting from a zero-result query preserved exact restored state'
  else
    fail project-picker-no-match-abort \
      "zero-result abort diverged: $picker_state" "$verify_session"
  fi
else
  fail project-picker-no-match-setup 'could not open the narrowed no-match scenario' \
    "$verify_session"
fi

if reset_picker_origin "$verify_session" &&
   open_project_picker "$verify_session"; then
  narrow_project_picker "$verify_session" f
  tmux_cmd send-keys -t "$verify_session" -l 'recent-previewx'
  sleep 0.4
  no_match_state=$(capture_picker_state "$verify_session")
  lem_keys "$verify_session" BSpace
  if grep -q 'focus="none" group="none" .*source=origin' \
       <<<"$no_match_state" &&
     lem_wait_for "$verify_session" 'PROJECT PREVIEW' "$WAIT_TIMEOUT" \
       >/dev/null; then
    picker_state=$(capture_picker_state "$verify_session")
    if grep -q 'prompt=yes input="recent-preview" focus="src/recent-preview.txt" group="Project File" .*source=temporary' \
         <<<"$picker_state"; then
      pass project-picker-backspace-recovery \
        'Backspace from zero results reopened and previewed the matching file row'
    else
      fail project-picker-backspace-recovery \
        "matching completion did not recover: $picker_state" "$verify_session"
    fi
  else
    fail project-picker-backspace-recovery \
      "zero-result setup or Backspace recovery failed: $no_match_state" \
      "$verify_session"
  fi
  lem_keys "$verify_session" C-g
else
  fail project-picker-backspace-setup 'could not open the Backspace recovery scenario' \
    "$verify_session"
fi

if reset_picker_origin "$verify_session" &&
   open_project_picker "$verify_session"; then
  narrow_project_picker "$verify_session" f
  lem_keys "$verify_session" BSpace
  sleep 0.4
  picker_screen=$(lem_capture "$verify_session")
  if grep -q 'Switch to:' <<<"$picker_screen" &&
     ! grep -q 'Switch to: \[' <<<"$picker_screen" &&
     grep -Fq 'Project Buffer' <<<"$picker_screen" &&
     grep -Fq 'Project File' <<<"$picker_screen" &&
     grep -Fq 'Project Root' <<<"$picker_screen"; then
    pass project-picker-widen \
      'Backspace on an empty narrow restored the base prompt and every source'
  else
    fail project-picker-widen 'empty Backspace did not widen the picker' \
      "$verify_session"
  fi
  lem_keys "$verify_session" C-g
else
  fail project-picker-widen-setup 'could not open the widening scenario' \
    "$verify_session"
fi

if reset_picker_origin "$verify_session" &&
   open_project_picker "$verify_session"; then
  narrow_project_picker "$verify_session" b
  picker_screen=$(lem_capture "$verify_session")
  if grep -q 'Switch to: \[Project Buffer\]' <<<"$picker_screen" &&
     grep -Fq 'Project Buffer' <<<"$picker_screen" &&
     ! grep -Fq 'Project File' <<<"$picker_screen" &&
     ! grep -Fq 'Project Root' <<<"$picker_screen"; then
    tmux_cmd send-keys -t "$verify_session" -l 'src/recent-preview.txt'
    sleep 0.4
    preview_state=$(capture_picker_state "$verify_session")
    lem_keys "$verify_session" Enter
    sleep 0.4
    picker_state=$(capture_picker_state "$verify_session")
    if grep -q 'prompt=yes .*group="Project Buffer" .*source=duplicate' \
         <<<"$preview_state" &&
       grep -q 'prompt=no .*source=duplicate .*hooks=0 kill-hooks=0 .*pulse=yes pulse-source=duplicate' \
         <<<"$picker_state"; then
      pass project-picker-buffer-identity \
        'b Space accepted the exact buffer and applied destination feedback'
    else
      fail project-picker-buffer-identity \
        "buffer identity or prompt closure diverged: $preview_state / $picker_state" \
        "$verify_session"
    fi
  else
    fail project-picker-buffer-prefix 'b Space did not isolate Project Buffer' \
      "$verify_session"
    lem_keys "$verify_session" C-g
  fi
else
  fail project-picker-buffer-setup 'could not open the buffer identity scenario' \
    "$verify_session"
fi

if reset_picker_origin "$verify_session" &&
   open_project_picker "$verify_session"; then
  narrow_project_picker "$verify_session" f
  narrow_state=$(capture_picker_state "$verify_session")
  reads_before_query=$(sed -n 's/.* reads=\([0-9][0-9]*\) .*/\1/p' \
    <<<"$narrow_state")
  tmux_cmd send-keys -t "$verify_session" -l 'src/recent-preview.txt'
  sleep 0.4
  preview_state=$(capture_picker_state "$verify_session")
  reads_after_query=$(sed -n 's/.* reads=\([0-9][0-9]*\) .*/\1/p' \
    <<<"$preview_state")
  if [[ -n "$reads_before_query" && -n "$reads_after_query" ]] &&
     ((reads_after_query == reads_before_query)); then
    pass project-picker-preview-dedup \
      'refreshing an unchanged focused file did not reread it'
  else
    fail project-picker-preview-dedup \
      "unchanged focus reread the file: $narrow_state / $preview_state" \
      "$verify_session"
  fi
  lem_keys "$verify_session" Enter
  sleep 0.4
  picker_state=$(capture_picker_state "$verify_session")
  if grep -q 'prompt=yes .*group="Project File" .*source=temporary temp=yes temp-listed=no .*hooks=0 kill-hooks=0 history-same=yes' \
       <<<"$preview_state" &&
     grep -q 'prompt=no .*source=normal-file temp=no .*preview-deleted=yes hooks=1 kill-hooks=0 .*pulse=yes pulse-source=normal-file' \
       <<<"$picker_state"; then
    pass project-picker-file-identity \
      'the temporary preview became a normal file with destination feedback'
  else
    fail project-picker-file-identity \
      "file preview/action identity diverged: $preview_state / $picker_state" \
      "$verify_session"
  fi
else
  fail project-picker-file-setup 'could not open the file identity scenario' \
    "$verify_session"
fi

if reset_picker_origin "$verify_session" &&
   open_project_picker "$verify_session"; then
  narrow_project_picker "$verify_session" r
  picker_screen=$(lem_capture "$verify_session")
  if grep -q 'Switch to: \[Project Root\]' <<<"$picker_screen" &&
     grep -Fq 'Project Root' <<<"$picker_screen" &&
     ! grep -Fq 'Project Buffer' <<<"$picker_screen" &&
     ! grep -Fq 'Project File' <<<"$picker_screen"; then
    tmux_cmd send-keys -t "$verify_session" -l 'beta'
    sleep 0.4
    preview_state=$(capture_picker_state "$verify_session")
    lem_keys "$verify_session" Enter
    if grep -q 'prompt=yes .*group="Project Root" .*source=origin .*hooks=1 kill-hooks=0 .*exact=yes' \
         <<<"$preview_state" &&
       lem_wait_for "$verify_session" 'Find File:.*projects/beta/' \
         "$WAIT_TIMEOUT" >/dev/null; then
      tmux_cmd send-keys -t "$verify_session" -l 'beta-main.txt'
      sleep 0.3
      lem_keys "$verify_session" Enter
      sleep 0.4
      before=$(report_count '^CURRENT label=spc-p-f ')
      lem_keys "$verify_session" F6
      picker_state=$(capture_picker_state "$verify_session")
      if wait_report_count '^CURRENT label=spc-p-f ' "$((before + 1))" &&
         grep -q '^CURRENT label=spc-p-f root=beta name=beta-main\.txt file=beta-main\.txt directory=\.$' \
           "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
         grep -q 'prompt=no .*hooks=2 kill-hooks=0 .*pulse=yes pulse-source=other' \
           <<<"$picker_state"; then
        pass project-picker-root-action \
          'r Space completed its rooted Find File action before destination feedback'
      else
        fail project-picker-root-action \
          "root action opened the wrong identity: $picker_state" "$verify_session"
      fi
    else
      fail project-picker-root-action 'root row previewed or skipped nested Find File' \
        "$verify_session"
    fi
  else
    fail project-picker-root-prefix 'r Space did not isolate Project Root' \
      "$verify_session"
    lem_keys "$verify_session" C-g
  fi
else
  fail project-picker-root-setup 'could not open the root action scenario' \
    "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-seed-many-recent '^PICKER-MANY ' &&
   grep -q '^PICKER-MANY history-index=130 candidate-index=130 beyond-hundred=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
   open_project_picker "$verify_session"; then
  narrow_project_picker "$verify_session" f
  picker_screen=$(lem_capture "$verify_session")
  if ! grep -Fq 'deep-recent-target.txt' <<<"$picker_screen"; then
    tmux_cmd send-keys -t "$verify_session" -l 'deep-recent-target'
    if lem_wait_for "$verify_session" 'RECENT PROJECT TARGET' \
         "$WAIT_TIMEOUT" >/dev/null; then
      preview_state=$(capture_picker_state "$verify_session")
      lem_keys "$verify_session" Enter
      sleep 0.4
      before=$(report_count '^CURRENT label=spc-p-f ')
      lem_keys "$verify_session" F6
      picker_state=$(capture_picker_state "$verify_session")
      if wait_report_count '^CURRENT label=spc-p-f ' "$((before + 1))" &&
         grep -q '^CURRENT label=spc-p-f root=alpha name=deep-recent-target\.txt file=src/deep-recent-target\.txt directory=src/$' \
           "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
         grep -q 'prompt=yes .*source=temporary temp=yes temp-listed=no .*hooks=2 kill-hooks=0 history-same=yes' \
           <<<"$preview_state" &&
         grep -q 'prompt=no .*preview-deleted=yes hooks=3 kill-hooks=0' \
           <<<"$picker_state"; then
        pass project-picker-beyond-limit \
          'querying searched and accepted a candidate beyond the first hundred provider rows'
      else
        fail project-picker-beyond-limit \
          "beyond-hundred action or cleanup diverged: $preview_state / $picker_state" \
          "$verify_session"
      fi
    else
      fail project-picker-beyond-limit 'deep query did not preview its hidden row' \
        "$verify_session"
    fi
  else
    fail project-picker-beyond-limit 'the 130th provider row was initially visible' \
      "$verify_session"
    lem_keys "$verify_session" C-g
  fi
else
  fail project-picker-many-setup 'could not seed the beyond-hundred provider case' \
    "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-preview-read-error '^PICKER-PREVIEW-ERROR ' &&
   grep -q '^PICKER-PREVIEW-ERROR result=nil slot=nil remaining=no listed=no kill-hooks=0$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-picker-preview-error-cleanup \
    'a failed preview read left no preview buffer and ran no kill hooks'
else
  fail project-picker-preview-error-cleanup \
    'failed preview-read cleanup leaked state or ran hooks' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-finish-picker '^PICKER-FINISH ' &&
   grep -q '^PICKER-FINISH hooks=3 kill-hooks=0$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-picker-isolation \
    'only three accepted files ran find hooks; sampled previews ran no kill hooks'
else
  fail project-picker-isolation 'picker hook isolation or fixture cleanup diverged' \
    "$verify_session"
fi

printf '\n'
cat "$LEM_YATH_PROJECT_NAVIGATION_REPORT" 2>/dev/null || true
if ((failed)); then
  echo 'PROJECT NAVIGATION TEST FAILED'
  exit 1
fi

echo 'PROJECT NAVIGATION TEST PASSED'
