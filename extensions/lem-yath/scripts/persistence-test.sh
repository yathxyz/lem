#!/usr/bin/env bash
# Real-ncurses regressions for safe auto-revert and persisted editor state.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-persistence-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-persistence.XXXXXX")"
case "$root" in
  "" | /)
    echo "Refusing unsafe persistence test directory: $root" >&2
    exit 1
    ;;
esac

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export XDG_STATE_HOME="$root/state-home"
export XDG_DATA_HOME="$root/data-home"
export WORKDIR="$root/work"
export LEM_HOME="$root/lem-home/"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_PERSISTENCE_STATE_FILE="$root/state/persistence.sexp"
default_state_file="$LEM_YATH_PERSISTENCE_STATE_FILE"
export LEM_YATH_PERSISTENCE_TEST_ROOT="$root/fixture/"
export LEM_YATH_PERSISTENCE_TEST_REPORT="$root/report"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
  "$WORKDIR" \
  "$LEM_HOME" "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")" \
  "$LEM_YATH_PERSISTENCE_TEST_ROOT/auto" \
  "$LEM_YATH_PERSISTENCE_TEST_ROOT/notify-extra" \
  "$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-auto" \
  "$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-place" \
  "$LEM_YATH_PERSISTENCE_TEST_ROOT/concurrent"
chmod 700 "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
: >"$LEM_YATH_PERSISTENCE_TEST_REPORT"

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
    */lem-yath-persistence.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe persistence cleanup path: %s\n' "$root" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-34s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-34s %s\n' "$1" "$2"
  if [ -n "${3:-}" ]; then
    printf '%s\n' '--- screen ---'
    lem_capture "$3" 2>/dev/null || true
  fi
}

report_count() {
  grep -cE "$1" "$LEM_YATH_PERSISTENCE_TEST_REPORT" 2>/dev/null || true
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

fixture="$(lem-yath_lisp_string "$here/scripts/persistence-fixture.lisp")"

start_phase() {
  local session=$1 phase=$2 before
  shift 2
  before=$(report_count "^READY phase=$phase$")
  export LEM_YATH_PERSISTENCE_TEST_PHASE="$phase"
  tmux_cmd set-environment -g LEM_YATH_PERSISTENCE_TEST_PHASE "$phase" \
    2>/dev/null || true
  tmux_cmd set-environment -g LEM_YATH_PERSISTENCE_STATE_FILE \
    "$LEM_YATH_PERSISTENCE_STATE_FILE" 2>/dev/null || true
  sessions+=("$session")
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$@" || return 1
  wait_report_count "^READY phase=$phase$" "$((before + 1))" "$BOOT_TIMEOUT"
}

invoke_mx() {
  local session=$1 command=$2 report_pattern=$3 before
  before=$(report_count "$report_pattern")
  send_keys "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  send_literal "$session" "$command"
  send_keys "$session" Enter
  wait_report_count "$report_pattern" "$((before + 1))" "$WAIT_TIMEOUT"
}

open_mx_prompt() {
  local session=$1 command=$2 prompt=$3
  send_keys "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  send_literal "$session" "$command"
  send_keys "$session" Enter
  lem_wait_for "$session" "$prompt" "$WAIT_TIMEOUT" >/dev/null
}

accept_named_prompt() {
  local session=$1 value=$2 before
  before=$(report_count '^PROMPT-ACCEPT ')
  open_mx_prompt "$session" lem-yath-test-persistence-named-prompt \
    'Persistence prompt:' || return 1
  send_literal "$session" "$value"
  send_keys "$session" Enter
  wait_report_count '^PROMPT-ACCEPT ' "$((before + 1))" "$WAIT_TIMEOUT"
}

press_and_wait() {
  local session=$1 key=$2 pattern=$3 before
  before=$(report_count "$pattern")
  lem_keys "$session" "$key"
  wait_report_count "$pattern" "$((before + 1))" "$WAIT_TIMEOUT"
}

wait_for_exit() {
  local session=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    if ! tmux_cmd has-session -t "$session" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

last_line() {
  grep -E "$1" "$LEM_YATH_PERSISTENCE_TEST_REPORT" | tail -n 1
}

same_file_time() {
  [ "$(stat -c %y "$1")" = "$(stat -c %y "$2")" ]
}

wait_for_file_contents() {
  local pathname=$1 expected=$2 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    if [ -f "$pathname" ] && cmp -s "$pathname" "$expected"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

main_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/auto/main.txt"
delete_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/auto/delete.txt"
background_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/auto/background.txt"
custom_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/auto/custom.txt"
notify_extra_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/notify-extra/extra.txt"
main_stamp="$root/main.timestamp"
delete_stamp="$root/delete.timestamp"
background_stamp="$root/background.timestamp"

printf 'CLEAN-ONE\nsteady-line\n' >"$main_file"
printf 'DELETE-ONE\n' >"$delete_file"
printf 'BACKGROUND-ONE\n' >"$background_file"
printf 'CUSTOM-DISK-ONE\n' >"$custom_file"
printf 'NOTIFY-EXTRA\n' >"$notify_extra_file"
touch -r "$main_file" "$main_stamp"
touch -r "$delete_file" "$delete_stamp"
touch -r "$background_file" "$background_stamp"

auto_session="lem-yath-persistence-auto-$id"
if start_phase "$auto_session" auto "$main_file" &&
   lem_wait_for "$auto_session" 'CLEAN-ONE' "$BOOT_TIMEOUT" >/dev/null; then
  pass auto-boot 'the isolated file buffer reached normal mode'
else
  fail auto-boot 'the auto-revert fixture did not initialize' "$auto_session"
fi

if press_and_wait "$auto_session" F9 '^HOOK ' &&
   grep -Eq \
     '^HOOK dangerous=0 safe=1 timer=yes api=yes notify=yes paths=[2-9][0-9]* directories=[1-9][0-9]* threads=1$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass hook-idempotence \
    'two reloads left one safe hook, timer, and notification service'
else
  fail hook-idempotence \
    'hook, timer, notification ownership, or public API contract diverged' \
    "$auto_session"
fi

# The fixture moved the fallback interval to one minute.  A clean current
# buffer appearing promptly without a key event therefore proves inotify
# delivery rather than either the timer or pre-command fallback.
printf 'CLEAN-IDLE\nsteady-line\n' >"$main_file"
touch -r "$main_stamp" "$main_file"
if lem_wait_for "$auto_session" 'CLEAN-IDLE' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass notify-no-input \
    'a clean external rewrite appeared promptly without polling or a keypress'
else
  fail notify-no-input 'the notification service did not refresh an idle buffer' \
    "$auto_session"
fi

# A same-length write with the exact original timestamp must still be noticed.
send_keys "$auto_session" 2 G 2 l
printf 'CLEAN-TWO\nsteady-line\n' >"$main_file"
touch -r "$main_stamp" "$main_file"
if ! same_file_time "$main_stamp" "$main_file"; then
  fail same-mtime-fixture 'the test could not preserve the original timestamp'
elif lem_wait_for "$auto_session" 'CLEAN-TWO' "$WAIT_TIMEOUT" >/dev/null &&
     press_and_wait "$auto_session" F5 '^BUFFER phase=auto ';
then
  clean_state=$(last_line '^BUFFER phase=auto ')
  if [[ "$clean_state" == *'label=current file=main.txt text=CLEAN-TWO\nsteady-line\n modified=no '* &&
        "$clean_state" == *' line=2 column=2 '* ]]; then
    pass clean-same-mtime \
      'notification loaded a same-mtime rewrite and preserved line/column'
  else
    fail clean-same-mtime "unexpected clean state: $clean_state" "$auto_session"
  fi
else
  fail clean-same-mtime 'the clean-state recorder did not run' "$auto_session"
fi

# Record exact dirty state, mutate disk, then compare every recorded field.
send_keys "$auto_session" i
send_literal "$auto_session" 'LOCAL-'
send_keys "$auto_session" Escape
if press_and_wait "$auto_session" F5 '^BUFFER phase=auto ';
then
  dirty_before=$(last_line '^BUFFER phase=auto ')
else
  dirty_before=''
fi
printf 'DISK-THR3\nsteady-line\n' >"$main_file"
touch -r "$main_stamp" "$main_file"
if press_and_wait "$auto_session" F6 '^BUFFER phase=auto ';
then
  dirty_after=$(last_line '^BUFFER phase=auto ')
  dirty_before_payload=${dirty_before#* text=}
  dirty_after_payload=${dirty_after#* text=}
  if [ -n "$dirty_before" ] &&
     [ "$dirty_before_payload" = "$dirty_after_payload" ] &&
     [[ "$dirty_after" == *' modified=yes '* ]] &&
     printf 'DISK-THR3\nsteady-line\n' | cmp -s - "$main_file"; then
    pass dirty-no-loss 'external change preserved exact local bytes, point, and modified state'
  else
    fail dirty-no-loss \
      "before=[$dirty_before] after=[$dirty_after]" "$auto_session"
  fi
else
  fail dirty-no-loss 'the dirty-state checker did not complete' "$auto_session"
fi

# Refusing a stale save must preserve both sides exactly; accepting it must
# write the intended local buffer and refresh the tracked file baseline.
if press_and_wait "$auto_session" F1 '^SAVE-STATE ';
then
  stale_save_before=$(last_line '^SAVE-STATE ')
else
  stale_save_before=''
fi
send_keys "$auto_session" C-x C-s
if lem_wait_for "$auto_session" \
     'changed on disk; overwrite it with this buffer' "$WAIT_TIMEOUT" \
     >/dev/null; then
  send_keys "$auto_session" n
  if press_and_wait "$auto_session" F1 '^SAVE-STATE ';
  then
    stale_save_no=$(last_line '^SAVE-STATE ')
    if [ "$stale_save_no" = "$stale_save_before" ] &&
       [[ "$stale_save_no" == *'modified=yes baseline=no' ]] &&
       printf 'DISK-THR3\nsteady-line\n' | cmp -s - "$main_file"; then
      pass stale-save-no 'answering no preserved exact disk and dirty-buffer state'
    else
      fail stale-save-no \
        "before=[$stale_save_before] after=[$stale_save_no]" "$auto_session"
    fi
  else
    fail stale-save-no 'the post-refusal state probe did not run' "$auto_session"
  fi
else
  fail stale-save-no 'saving a stale dirty buffer did not ask for confirmation' \
    "$auto_session"
fi

send_keys "$auto_session" C-x C-s
if lem_wait_for "$auto_session" \
     'changed on disk; overwrite it with this buffer' "$WAIT_TIMEOUT" \
     >/dev/null; then
  send_keys "$auto_session" y
  if press_and_wait "$auto_session" F1 '^SAVE-STATE ';
  then
    stale_save_yes=$(last_line '^SAVE-STATE ')
    if [ "$stale_save_yes" = \
         'SAVE-STATE text=CLEAN-TWO\nstLOCAL-eady-line\n modified=no baseline=yes' ] &&
       printf 'CLEAN-TWO\nstLOCAL-eady-line\n' | cmp -s - "$main_file"; then
      pass stale-save-yes 'answering yes wrote local text and refreshed the baseline'
    else
      fail stale-save-yes "unexpected accepted-save state: $stale_save_yes" \
        "$auto_session"
    fi
  else
    fail stale-save-yes 'the post-save baseline probe did not run' "$auto_session"
  fi
else
  fail stale-save-yes 'the accepted stale save did not prompt' "$auto_session"
fi

if invoke_mx "$auto_session" lem-yath-test-persistence-open-delete \
     '^OPEN label=delete ' &&
   lem_wait_for "$auto_session" 'DELETE-ONE' "$WAIT_TIMEOUT" >/dev/null; then
  rm -f "$delete_file"
  if press_and_wait "$auto_session" F5 '^BUFFER phase=auto ';
  then
    missing_state=$(last_line '^BUFFER phase=auto ')
    if [[ "$missing_state" == *'file=delete.txt text=DELETE-ONE\n modified=no '* &&
          "$missing_state" == *' exists=no' ]]; then
      pass delete-preserves-buffer 'unlinking a clean file did not erase its live buffer'
    else
      fail delete-preserves-buffer "unexpected missing state: $missing_state" "$auto_session"
    fi
  else
    fail delete-preserves-buffer 'the missing-file checker did not run' "$auto_session"
  fi

  printf 'DELETE-TWO\n' >"$delete_file"
  touch -r "$delete_stamp" "$delete_file"
  if lem_wait_for "$auto_session" 'DELETE-TWO' "$WAIT_TIMEOUT" >/dev/null &&
     press_and_wait "$auto_session" F5 '^BUFFER phase=auto ';
  then
    recreated_state=$(last_line '^BUFFER phase=auto ')
    if [[ "$recreated_state" == *'file=delete.txt text=DELETE-TWO\n modified=no '* &&
          "$recreated_state" == *' exists=yes' ]]; then
      pass recreate-reloads \
        'directory notification reloaded recreation despite the original timestamp'
    else
      fail recreate-reloads "unexpected recreated state: $recreated_state" "$auto_session"
    fi
  else
    fail recreate-reloads 'the recreated-file checker did not run' "$auto_session"
  fi
else
  fail delete-open 'could not open the deletion fixture' "$auto_session"
fi

printf 'BACKGROUND-TWO\n' >"$background_file"
touch -r "$background_stamp" "$background_file"
if press_and_wait "$auto_session" F7 '^GLOBAL ' &&
   grep -q '^GLOBAL text=BACKGROUND-TWO\\n modified=no exists=yes$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass global-noncurrent 'forced global scan refreshed a non-current clean buffer'
else
  fail global-noncurrent 'the background buffer remained stale' "$auto_session"
fi

if invoke_mx "$auto_session" lem-yath-test-persistence-notify-lifecycle \
     '^NOTIFY-LIFECYCLE ' &&
   grep -q \
     '^NOTIFY-LIFECYCLE path-add=1 directory-add=1 open-live=1 open-watched=yes paths-restored=yes directories-restored=yes after-live=1 after-watched=no before-live=1$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass notify-lifecycle \
    'opening and killing a buffer added then released its distinct directory watch'
else
  fail notify-lifecycle \
    'notification buffer ownership or kernel-directory teardown diverged' \
    "$auto_session"
fi

if invoke_mx "$auto_session" lem-yath-test-persistence-use-polling \
     '^POLLING ' &&
   grep -q '^POLLING paths=0 directories=0 live=0 threads=0 timer=yes$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  printf 'DELETE-THREE\n' >"$delete_file"
  touch -r "$delete_stamp" "$delete_file"
  if lem_wait_for "$auto_session" 'DELETE-THREE' "$WAIT_TIMEOUT" >/dev/null; then
    pass polling-fallback \
      'stopping notifications released resources and the timer still refreshed clean files'
  else
    fail polling-fallback \
      'the clean buffer did not refresh after notification shutdown' \
      "$auto_session"
  fi
else
  fail polling-fallback \
    'notification shutdown did not expose a clean zero-resource polling state' \
    "$auto_session"
fi

if invoke_mx "$auto_session" lem-yath-test-persistence-setup-custom-dirty \
     '^CUSTOM-SETUP ';
then
  printf 'CUSTOM-DISK-TWO\n' >"$custom_file"
  if press_and_wait "$auto_session" F8 '^CUSTOM ';
  then
    custom_state=$(last_line '^CUSTOM ')
    if [ "$custom_state" = \
      'CUSTOM count=0 modified=yes text=CUSTOM-DISK-ONE\nLOCAL-CUSTOM\n' ]; then
      pass dirty-custom-revert 'dirty custom/LSP-style revert callback was never invoked'
    else
      fail dirty-custom-revert "unexpected custom state: $custom_state" "$auto_session"
    fi
  else
    fail dirty-custom-revert 'the custom-revert checker did not run' "$auto_session"
  fi

  send_keys "$auto_session" Escape Escape M-x
  if lem_wait_for "$auto_session" 'Command:' "$WAIT_TIMEOUT" >/dev/null; then
    send_literal "$auto_session" revert-buffer
    send_keys "$auto_session" Enter
    if lem_wait_for "$auto_session" 'Discard unsaved changes' "$WAIT_TIMEOUT" \
         >/dev/null; then
      send_keys "$auto_session" n
      if press_and_wait "$auto_session" F8 '^CUSTOM ';
      then
        manual_custom_state=$(last_line '^CUSTOM ')
        if [ "$manual_custom_state" = \
          'CUSTOM count=0 modified=yes text=CUSTOM-DISK-ONE\nLOCAL-CUSTOM\n' ]; then
          pass manual-custom-revert-no \
            'manual revert refusal preserved dirty custom/LSP buffer state'
        else
          fail manual-custom-revert-no \
            "unexpected manual-refusal state: $manual_custom_state" \
            "$auto_session"
        fi
      else
        fail manual-custom-revert-no 'manual-refusal state probe did not run' \
          "$auto_session"
      fi
    else
      fail manual-custom-revert-no 'manual dirty revert did not ask to discard' \
        "$auto_session"
    fi
  else
    fail manual-custom-revert-no 'could not invoke manual revert' "$auto_session"
  fi
else
  fail dirty-custom-revert 'the custom dirty buffer setup failed' "$auto_session"
fi
lem_stop "$auto_session"

# Ordinary editing must not write the visited file or create backup/auto-save
# sidecars, even after crossing upstream's 256-key checkpoint and idle delay.
autosave_dir="$LEM_YATH_PERSISTENCE_TEST_ROOT/write-policy"
autosave_file="$autosave_dir/autosave.txt"
autosave_expected="$root/autosave.expected"
mkdir -p "$autosave_dir"
printf 'ORIGINAL-DISK\n' >"$autosave_file"
cp "$autosave_file" "$autosave_expected"
autosave_session="lem-yath-persistence-autosave-$id"
if start_phase "$autosave_session" autosave "$autosave_file" &&
   lem_wait_for "$autosave_session" 'ORIGINAL-DISK' "$BOOT_TIMEOUT" \
     >/dev/null; then
  typing_payload=$(printf 'x%.0s' {1..300})
  send_keys "$autosave_session" G A
  send_literal "$autosave_session" "$typing_payload"
  send_keys "$autosave_session" Escape
  sleep 6
  if press_and_wait "$autosave_session" F2 '^WRITE-POLICY ';
  then
    write_policy=$(last_line '^WRITE-POLICY ')
    sidecars=$(find "$autosave_dir" -mindepth 1 -maxdepth 1 \
      ! -name 'autosave.txt' -print)
    checkpoints=$(find "$XDG_DATA_HOME" -type f -print)
    if [ "$write_policy" = \
         'WRITE-POLICY auto-save=no input-hook=0 timer=no backups=no checkpoint=no checkpoint-hook=0 checkpoint-timer=no modified=yes' ] &&
       cmp -s "$autosave_file" "$autosave_expected" &&
       [ -z "$sidecars" ] && [ -z "$checkpoints" ]; then
      pass no-implicit-writes \
        '300 typed keys plus idle wait changed no disk bytes or sidecars'
    else
      fail no-implicit-writes \
        "policy=[$write_policy] sidecars=[$sidecars] checkpoints=[$checkpoints]" \
        "$autosave_session"
    fi
  else
    fail no-implicit-writes 'the write-policy probe did not run' "$autosave_session"
  fi
else
  fail no-implicit-writes 'the write-policy process did not initialize' \
    "$autosave_session"
fi
lem_stop "$autosave_session"

# Save As must never replace an existing, unvisited target without consent.
save_as_dir="$LEM_YATH_PERSISTENCE_TEST_ROOT/save-as"
save_as_source="$save_as_dir/source.txt"
save_as_target="$save_as_dir/target.txt"
save_as_source_expected="$root/save-as-source.expected"
save_as_target_expected="$root/save-as-target.expected"
mkdir -p "$save_as_dir"
printf 'SOURCE-DISK\n' >"$save_as_source"
printf 'TARGET-ORIGINAL\n' >"$save_as_target"
cp "$save_as_source" "$save_as_source_expected"
cp "$save_as_target" "$save_as_target_expected"
save_as_session="lem-yath-persistence-save-as-$id"
if start_phase "$save_as_session" save-as "$save_as_source" &&
   lem_wait_for "$save_as_session" 'SOURCE-DISK' "$BOOT_TIMEOUT" >/dev/null; then
  send_keys "$save_as_session" G A
  send_literal "$save_as_session" '-LOCAL'
  send_keys "$save_as_session" Escape
  if open_mx_prompt "$save_as_session" \
       lem-yath-test-persistence-write-existing-target \
       'target\.txt.*overwrite'; then
    send_keys "$save_as_session" n
    if press_and_wait "$save_as_session" F4 '^SAVE-AS ';
    then
      save_as_no=$(last_line '^SAVE-AS ')
      if [ "$save_as_no" = \
           'SAVE-AS name=source.txt file=source.txt text=SOURCE-DISK-LOCAL\n modified=yes' ] &&
         cmp -s "$save_as_source" "$save_as_source_expected" &&
         cmp -s "$save_as_target" "$save_as_target_expected"; then
        pass save-as-no \
          'refusal retained source identity and changed neither disk file'
      else
        fail save-as-no "unexpected refusal state: $save_as_no" "$save_as_session"
      fi
    else
      fail save-as-no 'the post-refusal Save As probe did not run' "$save_as_session"
    fi
  else
    fail save-as-no 'existing unvisited target did not require confirmation' \
      "$save_as_session"
  fi

  if open_mx_prompt "$save_as_session" \
       lem-yath-test-persistence-write-existing-target \
       'target\.txt.*overwrite'; then
    send_keys "$save_as_session" y
    if press_and_wait "$save_as_session" F4 '^SAVE-AS ';
    then
      save_as_yes=$(last_line '^SAVE-AS ')
      if [ "$save_as_yes" = \
           'SAVE-AS name=target.txt file=target.txt text=SOURCE-DISK-LOCAL\n modified=no' ] &&
         printf 'SOURCE-DISK-LOCAL\n' | cmp -s - "$save_as_target" &&
         cmp -s "$save_as_source" "$save_as_source_expected"; then
        pass save-as-yes \
          'acceptance replaced the target and migrated buffer identity once'
      else
        fail save-as-yes "unexpected accepted state: $save_as_yes" \
          "$save_as_session"
      fi
    else
      fail save-as-yes 'the accepted Save As probe did not run' "$save_as_session"
    fi
  else
    fail save-as-yes 'second Save As did not request confirmation' "$save_as_session"
  fi
else
  fail save-as-boot 'the Save As source did not initialize' "$save_as_session"
fi
lem_stop "$save_as_session"

# A genuinely new visited path has a known :missing baseline.  Its first save
# must not be mistaken for a stale-file conflict.
new_first_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/new-first.txt"
new_first_expected="$root/new-first.expected"
rm -f -- "$new_first_file"
printf 'NEW-FIRST\n' >"$new_first_expected"
new_first_session="lem-yath-persistence-new-first-$id"
if start_phase "$new_first_session" new-first "$new_first_file" &&
   lem_wait_for "$new_first_session" 'new-first\.txt' "$BOOT_TIMEOUT" \
     >/dev/null; then
  send_keys "$new_first_session" i
  send_literal "$new_first_session" NEW-FIRST
  send_keys "$new_first_session" Enter Escape C-x C-s
  if wait_for_file_contents "$new_first_file" "$new_first_expected" &&
     press_and_wait "$new_first_session" F1 '^SAVE-STATE ';
  then
    new_first_state=$(last_line '^SAVE-STATE ')
    if [ "$new_first_state" = \
         'SAVE-STATE text=NEW-FIRST\n modified=no baseline=yes' ]; then
      pass genuine-new-first-save \
        'first save of a nonexistent visited path completed without a false prompt'
    else
      fail genuine-new-first-save \
        "unexpected first-save state: $new_first_state" "$new_first_session"
    fi
  else
    fail genuine-new-first-save \
      'first save of a genuinely new file prompted, wedged, or wrote wrong bytes' \
      "$new_first_session"
  fi
else
  fail genuine-new-first-save 'the new-file buffer did not initialize' \
    "$new_first_session"
fi
lem_stop "$new_first_session"

# A file that disappears after being visited remains a stale-save conflict.
deleted_guard_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/deleted-guard.txt"
printf 'DELETED-GUARD\n' >"$deleted_guard_file"
deleted_guard_session="lem-yath-persistence-deleted-guard-$id"
if start_phase "$deleted_guard_session" deleted-save "$deleted_guard_file" &&
   lem_wait_for "$deleted_guard_session" 'DELETED-GUARD' "$BOOT_TIMEOUT" \
     >/dev/null; then
  send_keys "$deleted_guard_session" G A
  send_literal "$deleted_guard_session" -LOCAL
  send_keys "$deleted_guard_session" Escape
  rm -f -- "$deleted_guard_file"
  send_keys "$deleted_guard_session" C-x C-s
  if lem_wait_for "$deleted_guard_session" \
       'changed on disk; overwrite it with this buffer' "$WAIT_TIMEOUT" \
       >/dev/null; then
    send_keys "$deleted_guard_session" n
    if press_and_wait "$deleted_guard_session" F5 \
         '^BUFFER phase=deleted-save ';
    then
      deleted_guard_state=$(last_line '^BUFFER phase=deleted-save ')
      if [[ "$deleted_guard_state" == \
            *'file=deleted-guard.txt text=DELETED-GUARD-LOCAL\n modified=yes '* ]] &&
         [[ "$deleted_guard_state" == *' exists=no' ]] &&
         [ ! -e "$deleted_guard_file" ]; then
        pass deleted-visited-save-guard \
          'refusing a stale save kept deleted disk state and exact dirty buffer bytes'
      else
        fail deleted-visited-save-guard \
          "unexpected deleted-file refusal: $deleted_guard_state" \
          "$deleted_guard_session"
      fi
    else
      fail deleted-visited-save-guard \
        'the deleted-file refusal state probe did not run' \
        "$deleted_guard_session"
    fi
  else
    fail deleted-visited-save-guard \
      'saving a dirty buffer whose visited file disappeared was not guarded' \
      "$deleted_guard_session"
  fi
else
  fail deleted-visited-save-guard 'the deleted-file fixture did not initialize' \
    "$deleted_guard_session"
fi
lem_stop "$deleted_guard_session"

# Simulate a Save As race: the target is absent during write-file's initial
# probe, then appears in a higher-priority before-save hook.  Refusal must
# restore the original filename-less buffer identity and directory.
save_as_race_dir="$LEM_YATH_PERSISTENCE_TEST_ROOT/save-as-race"
save_as_race_target="$save_as_race_dir/target.txt"
save_as_race_expected="$root/save-as-race.expected"
mkdir -p "$save_as_race_dir"
rm -f -- "$save_as_race_target"
printf 'RACE-TARGET\n' >"$save_as_race_expected"
save_as_race_session="lem-yath-persistence-save-as-race-$id"
if start_phase "$save_as_race_session" save-as-race &&
   invoke_mx "$save_as_race_session" \
     lem-yath-test-persistence-setup-save-as-race '^RACE-SETUP ';
then
  if open_mx_prompt "$save_as_race_session" \
       lem-yath-test-persistence-write-save-as-race \
       'targets an existing or unverifiable file; overwrite it';
  then
    send_keys "$save_as_race_session" n
    if invoke_mx "$save_as_race_session" \
         lem-yath-test-persistence-record-save-as-race '^RACE-STATE ';
    then
      save_as_race_state=$(last_line '^RACE-STATE ')
      if [ "$save_as_race_state" = \
           'RACE-STATE name=*persistence-save-as-race* file=none directory-restored=yes text=RACE-LOCAL\n modified=yes' ] &&
         cmp -s "$save_as_race_target" "$save_as_race_expected"; then
        pass filename-less-save-as-race \
          'refusal restored name, nil filename, directory, bytes, and modified state'
      else
        fail filename-less-save-as-race \
          "unexpected Save As race refusal: $save_as_race_state" \
          "$save_as_race_session"
      fi
    else
      fail filename-less-save-as-race \
        'the filename-less identity probe did not run after refusal' \
        "$save_as_race_session"
    fi
  else
    fail filename-less-save-as-race \
      'the late-created Save As target did not require confirmation' \
      "$save_as_race_session"
  fi
else
  fail filename-less-save-as-race \
    'the filename-less Save As race fixture did not initialize' \
    "$save_as_race_session"
fi
lem_stop "$save_as_race_session"

# `quit-active-window' only deletes with a universal prefix.  Refusing its
# modified-buffer confirmation must keep the active buffer and disk bytes.
quit_guard_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/quit-guard.txt"
quit_guard_expected="$root/quit-guard.expected"
printf 'QUIT-GUARD\n' >"$quit_guard_file"
cp "$quit_guard_file" "$quit_guard_expected"
quit_guard_session="lem-yath-persistence-quit-guard-$id"
if start_phase "$quit_guard_session" quit-guard "$quit_guard_file" &&
   lem_wait_for "$quit_guard_session" 'QUIT-GUARD' "$BOOT_TIMEOUT" >/dev/null;
then
  send_keys "$quit_guard_session" G A
  send_literal "$quit_guard_session" -LOCAL
  send_keys "$quit_guard_session" Escape
  if open_mx_prompt "$quit_guard_session" \
       lem-yath-test-persistence-quit-active-window-with-kill \
       'Buffer quit-guard\.txt is modified; kill anyway';
  then
    send_keys "$quit_guard_session" n
    if press_and_wait "$quit_guard_session" F5 '^BUFFER phase=quit-guard ';
    then
      quit_guard_state=$(last_line '^BUFFER phase=quit-guard ')
      if [[ "$quit_guard_state" == \
            *'file=quit-guard.txt text=QUIT-GUARD-LOCAL\n modified=yes '* ]] &&
         cmp -s "$quit_guard_file" "$quit_guard_expected"; then
        pass quit-window-prefix-guard \
          'prefixed quit refusal retained the exact modified buffer and disk bytes'
      else
        fail quit-window-prefix-guard \
          "unexpected prefixed-quit refusal: $quit_guard_state" \
          "$quit_guard_session"
      fi
    else
      fail quit-window-prefix-guard \
        'the modified buffer disappeared after prefixed quit refusal' \
        "$quit_guard_session"
    fi
  else
    fail quit-window-prefix-guard \
      'prefixed quit-window did not ask before deleting a modified buffer' \
      "$quit_guard_session"
  fi
else
  fail quit-window-prefix-guard 'the quit-window fixture did not initialize' \
    "$quit_guard_session"
fi
lem_stop "$quit_guard_session"

# Explicit save checks must hash beyond the background-revert digest limit.
large_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/large-stale.txt"
large_expected="$root/large-stale.expected"
large_stamp="$root/large-stale.timestamp"
large_payload_size=$((17 * 1024 * 1024))
# The safety contract depends on total bytes, not one pathological 17 MiB
# logical line.  Short lines keep ncurses prompt redraws out of this digest
# regression while retaining an ASCII file comfortably above the 16 MiB cap.
LC_ALL=C head -c "$large_payload_size" /dev/zero | tr '\0' A | \
  fold -w 4095 >"$large_file"
LC_ALL=C head -c "$large_payload_size" /dev/zero | tr '\0' B | \
  fold -w 4095 >"$large_expected"
large_size=$(wc -c <"$large_file")
touch -r "$large_file" "$large_stamp"
large_session="lem-yath-persistence-large-$id"
if start_phase "$large_session" large "$large_file" &&
   lem_wait_for "$large_session" 'AAAA' "$BOOT_TIMEOUT" >/dev/null; then
  send_keys "$large_session" g g r
  send_literal "$large_session" L
  if invoke_mx "$large_session" \
       lem-yath-test-persistence-prepare-large-baseline '^LARGE-PREPARED ';
  then
    cp "$large_expected" "$large_file"
    touch -r "$large_stamp" "$large_file"
    if invoke_mx "$large_session" \
         lem-yath-test-persistence-normalize-large-metadata \
         '^LARGE-NORMALIZED ';
    then
      send_keys "$large_session" C-x C-s
      if lem_wait_for "$large_session" \
           'changed on disk; overwrite it with this buffer' "$WAIT_TIMEOUT" \
           >/dev/null; then
        send_keys "$large_session" n
        if invoke_mx "$large_session" \
             lem-yath-test-persistence-record-large-state '^LARGE-STATE ';
        then
          large_state=$(last_line '^LARGE-STATE ')
          if [ "$large_state" = \
               "LARGE-STATE length=$large_size first=L last=A modified=yes" ] &&
             cmp -s "$large_file" "$large_expected" &&
             same_file_time "$large_file" "$large_stamp"; then
            pass large-stale-save \
              '>16 MiB equal-size/equal-mtime rewrite was detected and refused'
          else
            fail large-stale-save "unexpected large state: $large_state" \
              "$large_session"
          fi
        else
          fail large-stale-save 'the large-buffer refusal probe did not run' \
            "$large_session"
        fi
      else
        fail large-stale-save 'large stale save did not request confirmation' \
          "$large_session"
      fi
    else
      fail large-stale-save 'could not normalize the metadata fixture' \
        "$large_session"
    fi
  else
    fail large-stale-save 'could not prepare the large-file baseline' \
      "$large_session"
  fi
else
  fail large-stale-save 'the large-file process did not initialize' "$large_session"
fi
lem_stop "$large_session"

# ---------------------------------------------------------------------------
# Fresh-process save-place, prompt, literal/regexp search, and kill-ring state.

rm -f "$LEM_YATH_PERSISTENCE_STATE_FILE" \
  "$LEM_YATH_PERSISTENCE_STATE_FILE.lock"
place_file="$LEM_YATH_PERSISTENCE_TEST_ROOT/state-roundtrip.txt"
printf '%s\n' \
  'header' \
  'literal-old' \
  'literal-new' \
  'rx-11' \
  'rx-22' \
  'KILL-OLDER' \
  'KILL-NEWER' \
  'save-place-target-abcdef' \
  'tail' >"$place_file"

writer_session="lem-yath-persistence-writer-$id"
if start_phase "$writer_session" writer "$place_file" &&
   lem_wait_for "$writer_session" 'save-place-target-abcdef' "$BOOT_TIMEOUT" \
     >/dev/null; then
  pass state-writer-boot 'fresh writer opened the round-trip fixture'
else
  fail state-writer-boot 'the persistence writer did not initialize' "$writer_session"
fi

if accept_named_prompt "$writer_session" 'older prompt' &&
   accept_named_prompt "$writer_session" 'newer prompt'; then
  pass prompt-writer 'two named prompt values were accepted through the TUI'
else
  fail prompt-writer 'named prompt input did not complete' "$writer_session"
fi

send_keys "$writer_session" Escape Escape g g C-s
if lem_wait_for "$writer_session" 'ISearch' "$WAIT_TIMEOUT" >/dev/null; then
  send_literal "$writer_session" literal-old
  send_keys "$writer_session" Enter C-s
  send_literal "$writer_session" literal-new
  send_keys "$writer_session" Enter C-M-s
  send_literal "$writer_session" 'rx-1[0-9]'
  send_keys "$writer_session" Enter C-M-s
  send_literal "$writer_session" 'rx-2[0-9]'
  send_keys "$writer_session" Enter
  pass search-writer 'literal and regexp searches completed through real isearch'
else
  fail search-writer 'configured C-s did not enter isearch' "$writer_session"
fi

send_keys "$writer_session" Escape 6 G y y 7 G y y 8 G 0 4 l
if press_and_wait "$writer_session" F5 '^BUFFER phase=writer ';
then
  writer_place=$(last_line '^BUFFER phase=writer ')
  if [[ "$writer_place" == *'line=8 column=4 '* ]]; then
    pass place-writer 'writer point reached the intended line and column'
  else
    fail place-writer "unexpected writer point: $writer_place" "$writer_session"
  fi
fi

if press_and_wait "$writer_session" F10 '^STATE ';
then
  writer_state=$(last_line '^STATE ')
  if [[ "$writer_state" == *'prompts=older prompt|newer prompt '* &&
        "$writer_state" == *'literal=literal-new|literal-old '* &&
        "$writer_state" == *'regexp=rx-2[0-9]|rx-1[0-9] '* &&
        "$writer_state" == *'kills=KILL-NEWER\n[vi-line]|KILL-OLDER\n[vi-line]'* ]]; then
    pass state-writer-memory 'writer held ordered prompt/search/linewise kill state'
  else
    fail state-writer-memory "unexpected writer state: $writer_state" "$writer_session"
  fi
else
  fail state-writer-memory 'the writer state probe did not run' "$writer_session"
fi

if wait_for_exit "$writer_session" &&
   [ -s "$LEM_YATH_PERSISTENCE_STATE_FILE" ] &&
   grep -Fqx 'EXIT-KILL live=KILL-NEWER\n[vi-line]|KILL-OLDER\n[vi-line]|[]' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT" &&
   grep -Fqx 'EXIT-KILL disk=KILL-NEWER\n[vi-line]|KILL-OLDER\n[vi-line]|[]' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass clean-exit-flush 'clean editor exit wrote the shared persistence state'
else
  fail clean-exit-flush 'direct clean exit did not persist state' "$writer_session"
fi

reader_session="lem-yath-persistence-reader-$id"
if start_phase "$reader_session" reader "$place_file" &&
   lem_wait_for "$reader_session" 'save-place-target-abcdef' "$BOOT_TIMEOUT" \
     >/dev/null; then
  pass state-reader-boot 'fresh reader loaded the shared state file'
else
  fail state-reader-boot 'the persistence reader did not initialize' "$reader_session"
fi

if press_and_wait "$reader_session" F5 '^BUFFER phase=reader ';
then
  reader_place=$(last_line '^BUFFER phase=reader ')
  if [[ "$reader_place" == *'line=8 column=4 '* ]]; then
    pass place-roundtrip 'fresh process restored the saved line and column'
  else
    fail place-roundtrip "unexpected restored point: $reader_place" "$reader_session"
  fi
else
  fail place-roundtrip 'the restored-place probe did not run' "$reader_session"
fi

# Assert and consume the restored linewise head before unrelated prompt/search
# editing can legitimately add newer kill-ring entries.
if press_and_wait "$reader_session" F10 '^STATE ';
then
  reader_state=$(last_line '^STATE ')
  if [[ "$reader_state" == *'kills=KILL-NEWER\n[vi-line]|KILL-OLDER\n[vi-line]'* ]]; then
    pass kill-ring-roundtrip 'fresh process restored kill order and :vi-line metadata'
  else
    fail kill-ring-roundtrip "unexpected kill state: $reader_state" "$reader_session"
  fi
fi

send_keys "$reader_session" 9 G p
if press_and_wait "$reader_session" F5 '^BUFFER phase=reader ';
then
  paste_state=$(last_line '^BUFFER phase=reader ')
  if [[ "$paste_state" == *'tail\nKILL-NEWER\n'* &&
        "$paste_state" == *' modified=yes '* ]]; then
    pass linewise-paste 'restored kill metadata drove a real linewise Vi paste'
  else
    fail linewise-paste "unexpected paste state: $paste_state" "$reader_session"
  fi
else
  fail linewise-paste 'the post-paste buffer probe did not run' "$reader_session"
fi
send_keys "$reader_session" u

if open_mx_prompt "$reader_session" lem-yath-test-persistence-named-prompt \
     'Persistence prompt:';
then
  prompt_before=$(report_count '^PROMPT-INPUT ')
  send_keys "$reader_session" M-p F4 M-p F4
  if wait_report_count '^PROMPT-INPUT ' "$((prompt_before + 2))"; then
    prompt_values=$(grep '^PROMPT-INPUT ' "$LEM_YATH_PERSISTENCE_TEST_REPORT" |
      tail -n 2)
    if [ "$prompt_values" = $'PROMPT-INPUT value=newer prompt\nPROMPT-INPUT value=older prompt' ]; then
      pass prompt-roundtrip 'M-p restored named prompt history newest to oldest'
    else
      fail prompt-roundtrip "unexpected prompt history: $prompt_values" "$reader_session"
    fi
  else
    fail prompt-roundtrip 'prompt history probes did not run' "$reader_session"
  fi
  send_keys "$reader_session" Escape Escape
else
  fail prompt-roundtrip 'fresh named prompt did not open' "$reader_session"
fi

search_before=$(report_count '^SEARCH-INPUT ')
send_keys "$reader_session" Escape g g C-s
if lem_wait_for "$reader_session" 'ISearch' "$WAIT_TIMEOUT" >/dev/null; then
  send_keys "$reader_session" M-p F3 M-p F3 Escape C-M-s M-p F3 M-p F3
  if wait_report_count '^SEARCH-INPUT ' "$((search_before + 4))"; then
    search_values=$(grep '^SEARCH-INPUT ' "$LEM_YATH_PERSISTENCE_TEST_REPORT" |
      tail -n 4)
    expected_search=$'SEARCH-INPUT kind=literal value=literal-new\nSEARCH-INPUT kind=literal value=literal-old\nSEARCH-INPUT kind=regexp value=rx-2[0-9]\nSEARCH-INPUT kind=regexp value=rx-1[0-9]'
    if [ "$search_values" = "$expected_search" ]; then
      pass search-roundtrip 'literal and regexp rings remained distinct and ordered'
    else
      fail search-roundtrip "unexpected search rings: $search_values" "$reader_session"
    fi
  else
    fail search-roundtrip 'search history probes did not run' "$reader_session"
  fi
  send_keys "$reader_session" Escape
else
  fail search-roundtrip 'fresh literal isearch did not open' "$reader_session"
fi
lem_stop "$reader_session"

printf 'short\nend' >"$place_file"
clamp_session="lem-yath-persistence-clamp-$id"
if start_phase "$clamp_session" clamp "$place_file" &&
   lem_wait_for "$clamp_session" 'short' "$BOOT_TIMEOUT" >/dev/null &&
   press_and_wait "$clamp_session" F5 '^BUFFER phase=clamp ';
then
  clamp_state=$(last_line '^BUFFER phase=clamp ')
  if [[ "$clamp_state" == *'at-end=yes '* ]]; then
    pass place-clamp 'obsolete saved position clamped safely to the new EOF'
  else
    fail place-clamp "saved position did not clamp: $clamp_state" "$clamp_session"
  fi
else
  fail place-clamp 'the shortened-file process did not initialize' "$clamp_session"
fi
lem_stop "$clamp_session"

# ---------------------------------------------------------------------------
# Malformed/read-eval state safety.

good_state="$root/good-persistence.sexp"
cp "$LEM_YATH_PERSISTENCE_STATE_FILE" "$good_state"
read_eval_sentinel="$root/read-eval-executed"
printf '#.(progn (with-open-file (s #P"%s" :direction :output :if-does-not-exist :create) (write-string "unsafe" s)) (list :version 1))\n' \
  "$read_eval_sentinel" >"$LEM_YATH_PERSISTENCE_STATE_FILE"

malformed_session="lem-yath-persistence-malformed-$id"
if start_phase "$malformed_session" malformed &&
   lem_wait_for "$malformed_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" \
     >/dev/null; then
  if [ ! -e "$read_eval_sentinel" ]; then
    pass malformed-read-eval 'state reader rejected #. without executing its payload'
  else
    fail malformed-read-eval 'state reader executed a read-time payload' "$malformed_session"
  fi
else
  fail malformed-read-eval 'malformed state prevented editor startup' "$malformed_session"
fi
lem_stop "$malformed_session"

dispatch_expected="$root/dispatch-allocation.expected"
printf '#1000000(0)\n' >"$LEM_YATH_PERSISTENCE_STATE_FILE"
cp "$LEM_YATH_PERSISTENCE_STATE_FILE" "$dispatch_expected"
dispatch_session="lem-yath-persistence-dispatch-$id"
if start_phase "$dispatch_session" dispatch-allocation &&
   lem_wait_for "$dispatch_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" \
     >/dev/null &&
   press_and_wait "$dispatch_session" F10 '^STATE ';
then
  dispatch_state=$(last_line '^STATE ')
  if [[ "$dispatch_state" == \
        *'prompts= literal= regexp= places=0 kill-count=0 kills=' ]] &&
     cmp -s "$LEM_YATH_PERSISTENCE_STATE_FILE" "$dispatch_expected"; then
    pass dispatch-allocation-rejected \
      '#1000000 dispatch syntax was rejected before reader allocation'
  else
    fail dispatch-allocation-rejected \
      "dispatch input was read or mutated: $dispatch_state" "$dispatch_session"
  fi
else
  fail dispatch-allocation-rejected \
    '#1000000 dispatch input allocated, wedged, or prevented normal commands' \
    "$dispatch_session"
fi
lem_stop "$dispatch_session"

printf '(:version 1 :places ((42 "bad")) :kill-ring ((7 (:vi-line))) :literal-searches (3) :regexp-searches dotted :prompt-histories ((bad)))\n' \
  >"$LEM_YATH_PERSISTENCE_STATE_FILE"
invalid_session="lem-yath-persistence-invalid-$id"
if start_phase "$invalid_session" invalid &&
   lem_wait_for "$invalid_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" \
     >/dev/null &&
   press_and_wait "$invalid_session" F10 '^STATE ';
then
  invalid_state=$(last_line '^STATE ')
  if [[ "$invalid_state" == *'prompts= literal= regexp= places=0 kill-count=0 kills=' ]]; then
    pass malformed-schema 'type-invalid state normalized to bounded empty state'
  else
    fail malformed-schema "invalid entries survived: $invalid_state" "$invalid_session"
  fi
else
  fail malformed-schema 'type-invalid state prevented normal startup' "$invalid_session"
fi
lem_stop "$invalid_session"

# ---------------------------------------------------------------------------
# Two stale processes must merge rather than overwrite each other's state.

rm -f "$LEM_YATH_PERSISTENCE_STATE_FILE" \
  "$LEM_YATH_PERSISTENCE_STATE_FILE.lock"
concurrent_a="$LEM_YATH_PERSISTENCE_TEST_ROOT/concurrent/a.txt"
concurrent_b="$LEM_YATH_PERSISTENCE_TEST_ROOT/concurrent/b.txt"
printf 'aaaa\nbbbb\ncccc\ndddd\n' >"$concurrent_a"
printf '1111\n2222\n3333\n4444\n' >"$concurrent_b"

session_a="lem-yath-persistence-concurrent-a-$id"
session_b="lem-yath-persistence-concurrent-b-$id"
if start_phase "$session_a" concurrent-a "$concurrent_a" &&
   start_phase "$session_b" concurrent-b "$concurrent_b" &&
   lem_wait_for "$session_a" 'cccc' "$BOOT_TIMEOUT" >/dev/null &&
   lem_wait_for "$session_b" '4444' "$BOOT_TIMEOUT" >/dev/null; then
  pass concurrent-boot 'two processes loaded the same initially empty state'
else
  fail concurrent-boot 'concurrent writers did not both initialize' "$session_a"
fi

send_keys "$session_a" 3 G l
send_keys "$session_b" 4 G 2 l
if press_and_wait "$session_a" F12 '^CONCURRENT-WRITE phase=concurrent-a ' &&
   press_and_wait "$session_b" F12 '^CONCURRENT-WRITE phase=concurrent-b ';
then
  pass concurrent-writes 'both stale snapshots flushed distinct state'
else
  fail concurrent-writes 'one stale writer did not flush' "$session_b"
fi
lem_stop "$session_a"
lem_stop "$session_b"

verify_session="lem-yath-persistence-concurrent-verify-$id"
if start_phase "$verify_session" concurrent-verify &&
   press_and_wait "$verify_session" F12 '^CONCURRENT-VERIFY ';
then
  concurrent_state=$(last_line '^CONCURRENT-VERIFY ')
  if [[ "$concurrent_state" == *'a=12 b=18 '* &&
        "$concurrent_state" == *'concurrent-a'* &&
        "$concurrent_state" == *'concurrent-b'* &&
        "$concurrent_state" == *'kill-count=2 '* &&
        "$concurrent_state" == *'concurrent-a[vi-line]'* &&
        "$concurrent_state" == *'concurrent-b[]'* ]]; then
    pass stale-snapshot-union 'fresh process saw both places, prompts, and kill entries'
  else
    fail stale-snapshot-union "merged state diverged: $concurrent_state" "$verify_session"
  fi
else
  fail stale-snapshot-union 'fresh union verifier did not complete' "$verify_session"
fi
lem_stop "$verify_session"

# ---------------------------------------------------------------------------
# A stale process must not resurrect entries intentionally cleared elsewhere.

rm -f "$LEM_YATH_PERSISTENCE_STATE_FILE" \
  "$LEM_YATH_PERSISTENCE_STATE_FILE.lock"
printf 'old\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/concurrent/old-place.txt"
printf 'new\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/concurrent/new-place.txt"

clear_seed="lem-yath-persistence-clear-seed-$id"
if start_phase "$clear_seed" clear-seed &&
   press_and_wait "$clear_seed" F12 '^CLEAR-SEED '; then
  pass clear-seed 'seeded every shared place and history category'
else
  fail clear-seed 'could not seed the shared persistence state' "$clear_seed"
fi
lem_stop "$clear_seed"

clear_stale="lem-yath-persistence-clear-stale-$id"
clear_writer="lem-yath-persistence-clear-writer-$id"
if start_phase "$clear_stale" clear-stale &&
   start_phase "$clear_writer" clear-writer; then
  pass clear-concurrent-boot 'two processes loaded the same seeded baseline'
else
  fail clear-concurrent-boot 'clear concurrency processes did not initialize' \
    "$clear_stale"
fi

if press_and_wait "$clear_writer" F12 '^CLEAR-WRITER ' &&
   press_and_wait "$clear_stale" F12 '^CLEAR-STALE '; then
  pass clear-concurrent-writes 'clear committed before the stale process added new state'
else
  fail clear-concurrent-writes 'clear/stale writes did not both flush' "$clear_stale"
fi
lem_stop "$clear_writer"
lem_stop "$clear_stale"

clear_verify="lem-yath-persistence-clear-verify-$id"
if start_phase "$clear_verify" clear-verify &&
   press_and_wait "$clear_verify" F12 '^CLEAR-VERIFY '; then
  clear_state=$(last_line '^CLEAR-VERIFY ')
  if [[ "$clear_state" == *'old-place=no new-place=yes '* &&
        "$clear_state" == *'prompts=new-prompt '* &&
        "$clear_state" == *'literal=new-literal '* &&
        "$clear_state" == *'regexp=new-regexp '* &&
        "$clear_state" == *'kills=new-kill[]'* &&
        "$clear_state" != *'old-prompt'* &&
        "$clear_state" != *'old-literal'* &&
        "$clear_state" != *'old-regexp'* &&
        "$clear_state" != *'old-kill'* ]]; then
    pass clear-no-resurrection 'fresh process saw new additions but no cleared entries'
  else
    fail clear-no-resurrection "cleared state was resurrected: $clear_state" \
      "$clear_verify"
  fi
else
  fail clear-no-resurrection 'fresh clear verifier did not complete' "$clear_verify"
fi
lem_stop "$clear_verify"

# ---------------------------------------------------------------------------
# Save Place stores Dired's selected filename, not a fragile rendered offset.

export LEM_YATH_PERSISTENCE_STATE_FILE="$root/directory-place/persistence.sexp"
rm -rf -- "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
mkdir -m 700 -p "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
printf 'FIRST\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-place/first.txt"
printf 'SELECTED\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-place/selected.txt"
printf 'THIRD\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-place/third.txt"

directory_writer="lem-yath-persistence-directory-writer-$id"
if start_phase "$directory_writer" directory-writer &&
   invoke_mx "$directory_writer" \
     lem-yath-test-persistence-directory-write '^DIRECTORY-WRITE ' &&
   grep -q '^DIRECTORY-WRITE selected=selected\.txt identity=path$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass directory-place-write \
    'directory selection persisted by exact entry identity'
else
  fail directory-place-write \
    'the selected directory row was not stored as a pathname' "$directory_writer"
fi
lem_stop "$directory_writer"

directory_reader="lem-yath-persistence-directory-reader-$id"
if start_phase "$directory_reader" directory-reader &&
   invoke_mx "$directory_reader" \
     lem-yath-test-persistence-directory-read '^DIRECTORY-READ ' &&
   grep -q '^DIRECTORY-READ selected=selected\.txt restored=yes$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass directory-place-roundtrip \
    'fresh process restored the selected directory entry on first visit'
else
  fail directory-place-roundtrip \
    'fresh directory visit did not restore the selected entry' "$directory_reader"
fi
lem_stop "$directory_reader"

# ---------------------------------------------------------------------------
# Global auto-revert refreshes Dired-style buffers without losing live state.

export LEM_YATH_PERSISTENCE_STATE_FILE="$root/directory-auto/persistence.sexp"
rm -rf -- "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
mkdir -m 700 -p "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
printf 'MARKED\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-auto/marked.txt"
printf 'SELECTED\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-auto/selected.txt"

directory_auto="lem-yath-persistence-directory-auto-$id"
if start_phase "$directory_auto" directory-auto &&
   invoke_mx "$directory_auto" \
     lem-yath-test-persistence-directory-auto-setup \
     '^DIRECTORY-AUTO-SETUP ' &&
   grep -q \
     '^DIRECTORY-AUTO-SETUP selected=selected\.txt column=5 marked=yes modified=yes adapter=yes$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass directory-auto-setup \
    'the directory adapter tracked a selected row and a live mark'
else
  fail directory-auto-setup \
    'the Dired-style auto-revert adapter did not initialize' "$directory_auto"
fi

# Create immediately: stock SB-POSIX exposes only whole-second directory mtimes,
# so this also exercises the direct-entry-name fallback. Capture-pane only
# observes output and cannot trigger the pre-command scanner.
printf 'ADDED\n' >"$LEM_YATH_PERSISTENCE_TEST_ROOT/directory-auto/added.txt"
if lem_wait_for "$directory_auto" 'added\.txt' "$((WAIT_TIMEOUT + 5))" \
     >/dev/null; then
  pass directory-periodic-no-input \
    'an external create appeared in the idle directory buffer'
else
  fail directory-periodic-no-input \
    'the idle directory listing did not observe an external create' \
    "$directory_auto"
fi

if invoke_mx "$directory_auto" \
     lem-yath-test-persistence-directory-auto-report '^DIRECTORY-AUTO ' &&
   grep -q \
     '^DIRECTORY-AUTO selected=selected\.txt column=5 marked=yes added=yes modified=no$' \
     "$LEM_YATH_PERSISTENCE_TEST_REPORT"; then
  pass directory-refresh-state \
    'refresh preserved exact selection, column, and surviving marks'
else
  fail directory-refresh-state \
    'directory refresh lost Dired-style live state' "$directory_auto"
fi
lem_stop "$directory_auto"

# ---------------------------------------------------------------------------
# Prompt allowlisting, live caps, kill-ring physical MRU, and file security.

export LEM_YATH_PERSISTENCE_STATE_FILE="$root/prompt-security/persistence.sexp"
rm -rf -- "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
mkdir -m 700 -p "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
prompt_security_session="lem-yath-persistence-prompt-security-$id"
if start_phase "$prompt_security_session" prompt-security &&
   invoke_mx "$prompt_security_session" \
     lem-yath-test-persistence-prompt-security '^PROMPT-SECURITY ';
then
  prompt_security=$(last_line '^PROMPT-SECURITY ')
  if [ "$prompt_security" = \
       'PROMPT-SECURITY live=100 snapshot=100 safe-head=cap-104 unknown=no pg=no conninfo=no' ]; then
    pass prompt-security-write \
      'live safe history capped at 100 while unknown and SQL histories stayed out'
  else
    fail prompt-security-write "unexpected prompt policy: $prompt_security" \
      "$prompt_security_session"
  fi
else
  fail prompt-security-write 'the prompt security seed did not complete' \
    "$prompt_security_session"
fi
lem_stop "$prompt_security_session"

prompt_security_verify="lem-yath-persistence-prompt-security-verify-$id"
if start_phase "$prompt_security_verify" prompt-security-verify &&
   invoke_mx "$prompt_security_verify" \
     lem-yath-test-persistence-prompt-security '^PROMPT-SECURITY ';
then
  prompt_security_fresh=$(last_line '^PROMPT-SECURITY ')
  if [ "$prompt_security_fresh" = \
       'PROMPT-SECURITY live=100 snapshot=100 safe-head=cap-104 unknown=no pg=no conninfo=no' ]; then
    pass prompt-security-roundtrip \
      'fresh process restored only the reviewed bounded safe history'
  else
    fail prompt-security-roundtrip \
      "unexpected fresh prompt policy: $prompt_security_fresh" \
      "$prompt_security_verify"
  fi
else
  fail prompt-security-roundtrip 'the prompt security verifier did not complete' \
    "$prompt_security_verify"
fi
lem_stop "$prompt_security_verify"

export LEM_YATH_PERSISTENCE_STATE_FILE="$root/kill-semantics/persistence.sexp"
rm -rf -- "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
mkdir -m 700 -p "$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")"
kill_semantics_session="lem-yath-persistence-kill-semantics-$id"
if start_phase "$kill_semantics_session" kill-semantics &&
   invoke_mx "$kill_semantics_session" \
     lem-yath-test-persistence-kill-semantics '^KILL-SEMANTICS ';
then
  kill_semantics=$(last_line '^KILL-SEMANTICS ')
  if [ "$kill_semantics" = \
       'KILL-SEMANTICS distinct=yes physical=yes count=3 offset=0 head-line=yes' ]; then
    pass kill-ring-semantics \
      'option-distinct duplicates, physical MRU, and offset reset are exact'
  else
    fail kill-ring-semantics "unexpected ring semantics: $kill_semantics" \
      "$kill_semantics_session"
  fi
else
  fail kill-ring-semantics 'the kill-ring semantic probe did not complete' \
    "$kill_semantics_session"
fi
lem_stop "$kill_semantics_session"

kill_semantics_verify="lem-yath-persistence-kill-semantics-verify-$id"
if start_phase "$kill_semantics_verify" kill-semantics-verify &&
   invoke_mx "$kill_semantics_verify" \
     lem-yath-test-persistence-kill-semantics '^KILL-VERIFY ';
then
  kill_verify=$(last_line '^KILL-VERIFY ')
  if [ "$kill_verify" = \
       'KILL-VERIFY count=3 entries=same[vi-line]|same[]|older[]' ]; then
    pass kill-ring-option-roundtrip \
      'charwise and linewise copies of identical text both survived'
  else
    fail kill-ring-option-roundtrip "unexpected persisted ring: $kill_verify" \
      "$kill_semantics_verify"
  fi
else
  fail kill-ring-option-roundtrip 'the kill-ring verifier did not complete' \
    "$kill_semantics_verify"
fi
lem_stop "$kill_semantics_verify"

export LEM_YATH_PERSISTENCE_STATE_FILE="$root/mode-state/private/persistence.sexp"
rm -rf -- "$root/mode-state"
mode_session="lem-yath-persistence-modes-$id"
if start_phase "$mode_session" modes &&
   press_and_wait "$mode_session" F11 '^FLUSH ';
then
  mode_dir=$(dirname "$LEM_YATH_PERSISTENCE_STATE_FILE")
  mode_temp=$(find "$mode_dir" -maxdepth 1 \
    -name 'persistence.sexp.tmp.*' -print -quit)
  if [ "$(stat -c %a "$mode_dir")" = 700 ] &&
     [ "$(stat -c %a "$LEM_YATH_PERSISTENCE_STATE_FILE")" = 600 ] &&
     [ "$(stat -c %a "$LEM_YATH_PERSISTENCE_STATE_FILE.lock")" = 600 ] &&
     [ -z "$mode_temp" ]; then
    pass persistence-file-modes \
      'state directory is 0700, files are 0600, and no temp residue remains'
  else
    fail persistence-file-modes \
      "dir=$(stat -c %a "$mode_dir" 2>/dev/null) state=$(stat -c %a "$LEM_YATH_PERSISTENCE_STATE_FILE" 2>/dev/null) lock=$(stat -c %a "$LEM_YATH_PERSISTENCE_STATE_FILE.lock" 2>/dev/null) temp=[$mode_temp]" \
      "$mode_session"
  fi
else
  fail persistence-file-modes 'the private-state flush did not complete' \
    "$mode_session"
fi
lem_stop "$mode_session"

# A path whose parent is a regular file forces both directory creation and
# lock acquisition to fail.  Startup, ordinary commands, and exit must remain
# responsive and must never spin on the failed persistence operation.
failure_parent="$root/persistence-parent-is-a-file"
printf 'not a directory\n' >"$failure_parent"
export LEM_YATH_PERSISTENCE_STATE_FILE="$failure_parent/persistence.sexp"
failure_session="lem-yath-persistence-failure-$id"
if start_phase "$failure_session" failure &&
   lem_wait_for "$failure_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" \
     >/dev/null; then
  if press_and_wait "$failure_session" F5 '^BUFFER phase=failure ';
  then
    pass persistence-failure-command \
      'state/lock failure did not wedge an ordinary editor command'
  else
    fail persistence-failure-command 'ordinary command wedged after load failure' \
      "$failure_session"
  fi
  if press_and_wait "$failure_session" F10 '^STATE ' &&
     wait_for_exit "$failure_session"; then
    pass persistence-failure-exit \
      'clean exit completed despite an unwritable state and lock path'
  else
    fail persistence-failure-exit 'persistence failure wedged clean exit' \
      "$failure_session"
  fi
else
  fail persistence-failure-command 'state/lock failure prevented normal startup' \
    "$failure_session"
  fail persistence-failure-exit 'state/lock failure prevented an exit probe' \
    "$failure_session"
fi
lem_stop "$failure_session"
export LEM_YATH_PERSISTENCE_STATE_FILE="$default_state_file"

printf '\n--- persistence report ---\n'
sed -n '1,260p' "$LEM_YATH_PERSISTENCE_TEST_REPORT"
printf '%s\n' '--------------------------'

if [ "$failed" = 0 ]; then
  echo 'PERSISTENCE TEST PASSED'
  exit 0
else
  echo 'PERSISTENCE TEST FAILED'
  exit 1
fi
