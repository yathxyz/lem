#!/usr/bin/env bash
# Real-ncurses coverage for automatic, merge-safe bookmark persistence.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-bookmark-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-bookmark.XXXXXX")"
case "$root" in
  "" | /)
    echo "Refusing unsafe bookmark test directory: $root" >&2
    exit 1
    ;;
esac

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export XDG_STATE_HOME="$root/state-home"
export LEM_HOME="$root/lem-home/"
export LEM_YATH_PERSISTENCE_STATE_FILE="$root/state/persistence.sexp"
export LEM_YATH_BOOKMARK_TEST_REPORT="$root/report"
export LEM_YATH_BOOKMARKS_SOURCE="$here/lem-yath/src/bookmarks.lisp"
export LEM_YATH_PERSISTENCE_SOURCE="$here/lem-yath/src/persistence.lisp"
export LEM_YATH_BOOKMARK_TEST_PHASE=unknown

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$LEM_HOME" \
  "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")" "$root/files"
chmod 700 "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
: >"$LEM_YATH_BOOKMARK_TEST_REPORT"
printf 'alpha-1\nalpha-2\nalpha-3\nalpha-4\n' >"$root/files/a.txt"
printf 'beta-1\nbeta-2\nbeta-3\n' >"$root/files/b.txt"

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
KEY_DELAY="${KEY_DELAY:-0.18}"
failed=0
sessions=()

cleanup() {
  local session
  for session in "${sessions[@]:-}"; do
    [ -n "$session" ] && lem_stop "$session"
  done
  case "$root" in
    */lem-yath-bookmark.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe bookmark cleanup path: %s\n' "$root" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then
    printf '%s\n' '--- screen ---'
    lem_capture "$3" 2>/dev/null || true
  fi
}

report_count() {
  grep -cE "$1" "$LEM_YATH_BOOKMARK_TEST_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

send_keys() {
  local session=$1
  shift
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

send_literal() {
  tmux_cmd send-keys -t "$1" -l -- "$2"
  sleep "$KEY_DELAY"
}

fixture="$(lem-yath_lisp_string "$here/scripts/bookmark-fixture.lisp")"

start_phase() {
  local session=$1 phase=$2
  shift 2
  local before
  before=$(report_count "^READY phase=$phase$")
  export LEM_YATH_BOOKMARK_TEST_PHASE="$phase"
  tmux_cmd set-environment -g LEM_YATH_BOOKMARK_TEST_PHASE "$phase" \
    2>/dev/null || true
  sessions+=("$session")
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$@" || return 1
  wait_report_count "^READY phase=$phase$" "$((before + 1))" "$BOOT_TIMEOUT"
}

press_and_wait() {
  local session=$1 key=$2 pattern=$3 before
  before=$(report_count "$pattern")
  lem_keys "$session" "$key"
  wait_report_count "$pattern" "$((before + 1))" "$WAIT_TIMEOUT"
}

invoke_mx() {
  local session=$1 command=$2
  send_keys "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  send_literal "$session" "$command"
  send_keys "$session" Enter
}

wait_for_exit() {
  local session=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    if ! tmux_cmd has-session -t "$session" 2>/dev/null; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

set_bookmark() {
  local session=$1 name=$2
  send_keys "$session" Escape Space b m
  lem_wait_for "$session" 'Boorkmark name:' "$WAIT_TIMEOUT" >/dev/null || return 1
  send_keys "$session" F4
  send_literal "$session" "$name"
  send_keys "$session" Enter
}

open_bookmark_prompt() {
  local session=$1 name=$2
  invoke_mx "$session" bookmark-jump || return 1
  lem_wait_for "$session" 'Jump to bookmark:' "$WAIT_TIMEOUT" >/dev/null || return 1
  send_literal "$session" "$name"
  sleep 0.4
  lem_capture "$session" | grep -qE 'Jump to bookmark:'
}

jump_bookmark() {
  local session=$1 name=$2
  send_keys "$session" Escape Space Enter
  lem_wait_for "$session" 'Jump to bookmark:' "$WAIT_TIMEOUT" >/dev/null || return 1
  send_literal "$session" "$name"
  send_keys "$session" Enter
}

writer="lem-yath-bookmark-writer-$id"
if start_phase "$writer" writer "$root/files/a.txt" &&
   lem_wait_for "$writer" 'alpha-3' "$BOOT_TIMEOUT" >/dev/null; then
  send_keys "$writer" Escape 3 G 2 l
  if set_bookmark "$writer" seed &&
     press_and_wait "$writer" F5 '^BOOKMARKS phase=writer '; then
    writer_state=$(grep '^BOOKMARKS phase=writer ' \
      "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
    if [[ "$writer_state" == *'entries=seed@a.txt@19 '* &&
          "$writer_state" == *'line=3 column=2 position=19' ]]; then
      pass keybinding-set 'SPC b m recorded the current file and point'
    else
      fail keybinding-set "unexpected writer state: $writer_state" "$writer"
    fi
  else
    fail keybinding-set 'SPC b m did not create a bookmark' "$writer"
  fi

  if open_bookmark_prompt "$writer" see; then
    screen=$(lem_capture "$writer")
    if grep -Eq \
         'seed[[:space:]]+file.*a\.txt.*L3:C2.*alpha-3' <<<"$screen"; then
      pass bookmark-annotations \
        'SPC RET shows type, path, exact line/column, and nearby context'
    else
      fail bookmark-annotations \
        'the bookmark row lacked Marginalia-style context' "$writer"
    fi
    send_keys "$writer" C-g
  else
    fail bookmark-annotations 'could not open the bookmark prompt' "$writer"
  fi

  if open_bookmark_prompt "$writer" alpha-3; then
    screen=$(lem_capture "$writer")
    if ! grep -Eq '^[[:space:]]*seed[[:space:]]' <<<"$screen"; then
      pass bookmark-metadata-display-only \
        'bookmark context did not participate in candidate matching'
    else
      fail bookmark-metadata-display-only \
        'bookmark context leaked into filtering' "$writer"
    fi
    send_keys "$writer" C-g
  else
    fail bookmark-metadata-display-only \
      'could not query the bookmark prompt by annotation text' "$writer"
  fi

  send_keys "$writer" F9
  if open_bookmark_prompt "$writer" missing; then
    screen=$(lem_capture "$writer")
    if grep -Eq \
         'missing-target[[:space:]]+missing.*missing\.txt.*@7' <<<"$screen"; then
      pass bookmark-stale-metadata \
        'a stale target degrades to bounded missing-file metadata'
    else
      fail bookmark-stale-metadata \
        'a missing bookmark target broke or lost its safe annotation' "$writer"
    fi
    send_keys "$writer" C-g
  else
    fail bookmark-stale-metadata \
      'a missing bookmark target broke the prompt' "$writer"
  fi
  send_keys "$writer" F10
else
  fail writer-boot 'the bookmark writer did not initialize' "$writer"
fi

if invoke_mx "$writer" exit-lem && wait_for_exit "$writer" &&
   [ -s "$LEM_YATH_PERSISTENCE_STATE_FILE" ]; then
  pass clean-exit-save 'normal editor exit atomically wrote bookmark state'
else
  fail clean-exit-save 'normal editor exit did not persist bookmarks' "$writer"
fi

session_a="lem-yath-bookmark-a-$id"
session_b="lem-yath-bookmark-b-$id"
if start_phase "$session_a" concurrent-a "$root/files/a.txt" &&
   start_phase "$session_b" concurrent-b "$root/files/b.txt"; then
  pass concurrent-boot 'two processes restored the same bookmark baseline'
else
  fail concurrent-boot 'concurrent bookmark processes did not initialize' "$session_a"
fi

if jump_bookmark "$session_a" seed &&
   press_and_wait "$session_a" F5 '^BOOKMARKS phase=concurrent-a '; then
  jump_state=$(grep '^BOOKMARKS phase=concurrent-a ' \
    "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
  if [[ "$jump_state" == *'file=a.txt line=3 column=2 position=19' ]]; then
    pass fresh-process-jump 'SPC RET restored and jumped to the saved point'
  else
    fail fresh-process-jump "unexpected jump state: $jump_state" "$session_a"
  fi
else
  fail fresh-process-jump 'fresh process could not jump to seed' "$session_a"
fi

send_keys "$session_a" Escape 4 G l
if press_and_wait "$session_a" F6 '^BOOKMARKS phase=concurrent-a label=writer-a ' &&
   press_and_wait "$session_b" F7 '^BOOKMARKS phase=concurrent-b label=writer-b '; then
  pass concurrent-writes 'stale processes flushed update/delete/add changes'
else
  fail concurrent-writes 'one stale bookmark writer did not flush' "$session_b"
fi
lem_stop "$session_a"
lem_stop "$session_b"

verify="lem-yath-bookmark-verify-$id"
if start_phase "$verify" verify "$root/files/b.txt" &&
   press_and_wait "$verify" F5 '^BOOKMARKS phase=verify '; then
  verify_state=$(grep '^BOOKMARKS phase=verify ' \
    "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
  if [[ "$verify_state" == *'entries=only-a@a.txt@28|only-b@b.txt@1 '* &&
        "$verify_state" != *'seed@'* ]]; then
    pass three-way-merge 'fresh process saw both additions and the local deletion'
  else
    fail three-way-merge "unexpected merged state: $verify_state" "$verify"
  fi
else
  fail three-way-merge 'merged bookmark verifier did not initialize' "$verify"
fi

if jump_bookmark "$verify" only-a &&
   press_and_wait "$verify" F5 '^BOOKMARKS phase=verify '; then
  only_a_state=$(grep '^BOOKMARKS phase=verify ' \
    "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
  if [[ "$only_a_state" == *'file=a.txt line=4 column=3 position=28' ]]; then
    pass merged-jump-a 'merged bookmark A retained its file and point'
  else
    fail merged-jump-a "unexpected only-a jump: $only_a_state" "$verify"
  fi
else
  fail merged-jump-a 'could not jump to merged bookmark A' "$verify"
fi

if jump_bookmark "$verify" only-b &&
   press_and_wait "$verify" F5 '^BOOKMARKS phase=verify '; then
  only_b_state=$(grep '^BOOKMARKS phase=verify ' \
    "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
  if [[ "$only_b_state" == *'file=b.txt line=1 column=0 position=1' ]]; then
    pass merged-jump-b 'merged bookmark B retained its file and point'
  else
    fail merged-jump-b "unexpected only-b jump: $only_b_state" "$verify"
  fi
else
  fail merged-jump-b 'could not jump to merged bookmark B' "$verify"
fi

if press_and_wait "$verify" F8 '^RELOAD '; then
  reload_state=$(grep '^RELOAD ' "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
  if [[ "$reload_state" == *'exit-hooks=1 baseline=stable'* &&
        "$reload_state" == *'only-a@a.txt@28'* &&
        "$reload_state" == *'only-b@b.txt@1'* ]]; then
    pass reload-idempotence 'two source reloads preserved state and one exit hook'
  else
    fail reload-idempotence "unexpected reload state: $reload_state" "$verify"
  fi
else
  fail reload-idempotence 'reload probe did not complete' "$verify"
fi
lem_stop "$verify"

printf '(:version 1 :bookmarks (("valid" "/tmp/valid-a.txt" 2) ("" "/tmp/empty.txt" 1) ("bad-position" "/tmp/bad.txt" 0) ("bad-file" 7 1) ("valid" "/tmp/other.txt" 5)) :places () :kill-ring () :literal-searches () :regexp-searches () :prompt-histories ())\n' \
  >"$LEM_YATH_PERSISTENCE_STATE_FILE"
schema="lem-yath-bookmark-schema-$id"
if start_phase "$schema" schema &&
   press_and_wait "$schema" F5 '^BOOKMARKS phase=schema '; then
  schema_state=$(grep '^BOOKMARKS phase=schema ' \
    "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
  if [[ "$schema_state" == *'entries=valid@valid-a.txt@2 '* ]]; then
    pass schema-validation 'invalid and duplicate bookmark triples were rejected'
  else
    fail schema-validation "unexpected normalized state: $schema_state" "$schema"
  fi
else
  fail schema-validation 'invalid bookmark schema prevented normal commands' "$schema"
fi
lem_stop "$schema"

sentinel="$root/read-eval-executed"
printf '#.(progn (with-open-file (s #P"%s" :direction :output :if-does-not-exist :create) (write-string "unsafe" s)) nil)\n' \
  "$sentinel" >"$LEM_YATH_PERSISTENCE_STATE_FILE"
malformed="lem-yath-bookmark-malformed-$id"
if start_phase "$malformed" malformed &&
   press_and_wait "$malformed" F5 '^BOOKMARKS phase=malformed '; then
  malformed_state=$(grep '^BOOKMARKS phase=malformed ' \
    "$LEM_YATH_BOOKMARK_TEST_REPORT" | tail -n 1)
  if [ ! -e "$sentinel" ] && [[ "$malformed_state" == *'entries= file='* ]]; then
    pass malformed-safety 'unsafe reader syntax was ignored without execution'
  else
    fail malformed-safety "malformed state was accepted: $malformed_state" "$malformed"
  fi
else
  fail malformed-safety 'malformed state prevented normal editor commands' "$malformed"
fi
lem_stop "$malformed"

printf '\n--- bookmark report ---\n'
cat "$LEM_YATH_BOOKMARK_TEST_REPORT"
exit "$failed"
