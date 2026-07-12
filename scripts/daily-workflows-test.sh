#!/usr/bin/env bash
# Real-TUI acceptance tests for high-frequency editing and navigation workflows.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-daily-workflows-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-daily-workflows.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_HOME="$root/lem-home/"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_DAILY_WORKFLOWS_ROOT="$root/fixture"
export LEM_YATH_DAILY_WORKFLOWS_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR" "$LEM_HOME" "$XDG_CACHE_HOME" \
  "$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing"
: > "$LEM_YATH_DAILY_WORKFLOWS_REPORT"

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
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}
report_count() {
  local pattern=$1
  grep -cE "$pattern" "$LEM_YATH_DAILY_WORKFLOWS_REPORT" 2>/dev/null || true
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

send_chord() {
  local session=$1
  shift
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

fixture="$(lem-yath_lisp_string "$here/scripts/daily-workflows-fixture.lisp")"

start_fixture_session() {
  local session=$1 phase=$2 ready_before
  shift 2
  ready_before=$(report_count "^READY $phase$")
  export LEM_YATH_DAILY_WORKFLOWS_PHASE="$phase"
  # A live tmux server retains its launch environment between sessions.
  tmux_cmd set-environment -g LEM_YATH_DAILY_WORKFLOWS_PHASE "$phase" 2>/dev/null || true
  sessions+=("$session")
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$@"
  wait_report_count "^READY $phase$" "$((ready_before + 1))" "$BOOT_TIMEOUT"
}

invoke_test_command() {
  local session=$1 command=$2 report_pattern=$3 count_before
  count_before=$(report_count "$report_pattern")
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  lem_keys "$session" Enter
  sleep 0.2
  lem_keys "$session" Enter
  wait_report_count "$report_pattern" "$((count_before + 1))" "$WAIT_TIMEOUT"
}

line_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/line-eof.txt"
visual_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/visual.txt"
visual_line_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/visual-line-eof.txt"
lisp_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/guard.lisp"
find_root="$LEM_YATH_DAILY_WORKFLOWS_ROOT/find-name"
find_source="$find_root/source.txt"
find_sentinel="$find_root/INJECTED"
printf 'first\nomega' > "$line_file"
printf 'prefix TOKEN suffix\n' > "$visual_file"
printf 'first\nomega' > "$visual_line_file"
printf '(a b c)\n' > "$lisp_file"
mkdir -p "$find_root/nested" "$find_root/named-dir.match"
printf 'FIND OPEN TARGET\n' > "$find_root/00-[.match"
printf 'nested match\n' > "$find_root/nested/later.match"
printf 'semicolon match\n' > "$find_root/semi;colon.match"
printf 'space match\n' > "$find_root/space target.match"
printf 'literal star match\n' > "$find_root/literal*.match"
printf 'literal question match\n' > "$find_root/literal?.match"
newline_match=$'line\nbreak.match'
printf 'newline match\n' > "$find_root/$newline_match"
printf 'find source\n' > "$find_source"

# M-j duplicates the last line even when the source file has no final newline,
# and the entire insertion is one undo unit.
line_session="lem-yath-daily-line-$id"
if start_fixture_session "$line_session" editing "$line_file" &&
   lem_wait_for "$line_session" 'omega' "$BOOT_TIMEOUT" >/dev/null; then
  point_before_count=$(report_count '^POINT label=line-before-duplicate ')
  send_chord "$line_session" G '$' F3
  wait_report_count '^POINT label=line-before-duplicate ' "$((point_before_count + 1))" || true
  point_before=$(grep '^POINT label=line-before-duplicate ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
  point_before=${point_before##*point=}
  lem_keys "$line_session" M-j
  sleep 0.3
  before=$(report_count '^BUFFER label=line-after-duplicate ')
  lem_keys "$line_session" F7
  if wait_report_count '^BUFFER label=line-after-duplicate ' "$((before + 1))"; then
    actual=$(grep '^BUFFER label=line-after-duplicate ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'BUFFER label=line-after-duplicate text=first\nomega\nomega\n' ]; then
      pass duplicate-line-eof "M-j matched Emacs by terminating the source and copy at EOF"
    else
      fail duplicate-line-eof "unexpected buffer snapshot: $actual" "$line_session"
    fi
    if wait_report_count '^POINT label=line-after-duplicate ' 1; then
      point_after=$(grep '^POINT label=line-after-duplicate ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      point_after=${point_after##*point=}
      if [ -n "$point_before" ] && [ "$point_before" = "$point_after" ]; then
        pass duplicate-line-point "M-j preserved a cursor exactly at unterminated EOF"
      else
        fail duplicate-line-point "point moved from $point_before to $point_after" "$line_session"
      fi
    else
      fail duplicate-line-point "the post-duplicate point probe did not run" "$line_session"
    fi
  else
    fail duplicate-line-eof "the post-duplicate snapshot command did not run" "$line_session"
  fi

  before=$(report_count '^BUFFER label=line-after-undo ')
  lem_keys "$line_session" u
  sleep 0.3
  lem_keys "$line_session" F8
  if wait_report_count '^BUFFER label=line-after-undo ' "$((before + 1))"; then
    actual=$(grep '^BUFFER label=line-after-undo ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'BUFFER label=line-after-undo text=first\nomega' ]; then
      pass duplicate-one-undo "one normal-state undo restored the exact no-newline file"
    else
      fail duplicate-one-undo "one undo left: $actual" "$line_session"
    fi
  else
    fail duplicate-one-undo "the post-undo snapshot command did not run" "$line_session"
  fi
else
  fail duplicate-line-boot "could not open the EOF fixture" "$line_session"
fi
lem_stop "$line_session"

# With a visual character region, M-j duplicates only the selection while
# retaining the original visual bounds and cursor position.
visual_session="lem-yath-daily-visual-$id"
if start_fixture_session "$visual_session" editing "$visual_file" &&
   lem_wait_for "$visual_session" 'prefix TOKEN suffix' "$BOOT_TIMEOUT" >/dev/null; then
  send_chord "$visual_session" w v e F5
  if wait_report_count '^VISUAL label=visual-before ' 1; then
    lem_keys "$visual_session" M-j
    sleep 0.3
    lem_keys "$visual_session" F6
    if wait_report_count '^VISUAL label=visual-after ' 1; then
      before_state=$(grep '^VISUAL label=visual-before ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      after_state=$(grep '^VISUAL label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      before_state=${before_state#* active=}
      after_state=${after_state#* active=}
      if [ "$before_state" = "$after_state" ] && [[ "$after_state" == yes\ * ]]; then
        pass duplicate-visual-state "the original visual range and point stayed active"
      else
        fail duplicate-visual-state "before=[$before_state] after=[$after_state]" "$visual_session"
      fi
      actual=$(grep '^BUFFER label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      if [ "$actual" = 'BUFFER label=visual-after text=prefix TOKENTOKEN suffix\n' ]; then
        pass duplicate-visual-text "M-j duplicated only the selected characters"
      else
        fail duplicate-visual-text "unexpected visual duplicate: $actual" "$visual_session"
      fi
    else
      fail duplicate-visual-after "the post-M-j visual probe did not run" "$visual_session"
    fi
  else
    fail duplicate-visual-before "the visual selection probe did not run" "$visual_session"
  fi
else
  fail duplicate-visual-boot "could not open the visual fixture" "$visual_session"
fi
lem_stop "$visual_session"

# Reverse Visual character orientation must survive the insertion as well.
reverse_session="lem-yath-daily-visual-reverse-$id"
if start_fixture_session "$reverse_session" editing "$visual_file" &&
   lem_wait_for "$reverse_session" 'prefix TOKEN suffix' "$BOOT_TIMEOUT" >/dev/null; then
  visual_before_count=$(report_count '^VISUAL label=visual-before ')
  send_chord "$reverse_session" w e v b F5
  if wait_report_count '^VISUAL label=visual-before ' "$((visual_before_count + 1))"; then
    before_state=$(grep '^VISUAL label=visual-before ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    before_state=${before_state#* active=}
    visual_after_count=$(report_count '^VISUAL label=visual-after ')
    lem_keys "$reverse_session" M-j
    sleep 0.3
    lem_keys "$reverse_session" F6
    if wait_report_count '^VISUAL label=visual-after ' "$((visual_after_count + 1))"; then
      after_state=$(grep '^VISUAL label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      after_state=${after_state#* active=}
      actual=$(grep '^BUFFER label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      if [ "$before_state" = "$after_state" ] &&
         [[ "$after_state" == yes\ type=char\ * ]] &&
         [ "$actual" = 'BUFFER label=visual-after text=prefix TOKENTOKEN suffix\n' ]; then
        pass duplicate-visual-reverse "reverse VISUAL orientation, point, bounds, and text were preserved"
      else
        fail duplicate-visual-reverse "before=[$before_state] after=[$after_state] text=[$actual]" "$reverse_session"
      fi
    else
      fail duplicate-visual-reverse "the reverse post-M-j probe did not run" "$reverse_session"
    fi
  else
    fail duplicate-visual-reverse "the reverse visual selection probe did not run" "$reverse_session"
  fi
else
  fail duplicate-visual-reverse-boot "could not open the reverse visual fixture" "$reverse_session"
fi
lem_stop "$reverse_session"

# Vi V-LINE on an unterminated final line follows Emacs' newline behavior and
# retains its linewise subtype and exact selection.
visual_line_session="lem-yath-daily-visual-line-$id"
if start_fixture_session "$visual_line_session" editing "$visual_line_file" &&
   lem_wait_for "$visual_line_session" 'omega' "$BOOT_TIMEOUT" >/dev/null; then
  visual_before_count=$(report_count '^VISUAL label=visual-before ')
  send_chord "$visual_line_session" G V F5
  if wait_report_count '^VISUAL label=visual-before ' "$((visual_before_count + 1))"; then
    before_state=$(grep '^VISUAL label=visual-before ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    before_state=${before_state#* active=}
    visual_after_count=$(report_count '^VISUAL label=visual-after ')
    lem_keys "$visual_line_session" M-j
    sleep 0.3
    lem_keys "$visual_line_session" F6
    if wait_report_count '^VISUAL label=visual-after ' "$((visual_after_count + 1))"; then
      after_state=$(grep '^VISUAL label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      after_state=${after_state#* active=}
      actual=$(grep '^BUFFER label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      before_end=${before_state##* end=}
      after_end=${after_state##* end=}
      before_anchor=${before_state% end=*}
      after_anchor=${after_state% end=*}
      if [ "$before_anchor" = "$after_anchor" ] &&
         [ "$after_end" -eq "$((before_end + 1))" ] &&
         [[ "$after_state" == yes\ type=line\ * ]] &&
         [ "$actual" = 'BUFFER label=visual-after text=first\nomega\nomega\n' ]; then
        pass duplicate-visual-line-eof "V-LINE anchor stayed fixed while the new source terminator joined its range"
      else
        fail duplicate-visual-line-eof "before=[$before_state] after=[$after_state] text=[$actual]" "$visual_line_session"
      fi
    else
      fail duplicate-visual-line-eof "the V-LINE post-M-j probe did not run" "$visual_line_session"
    fi
  else
    fail duplicate-visual-line-eof "the V-LINE selection probe did not run" "$visual_line_session"
  fi
else
  fail duplicate-visual-line-eof-boot "could not open the V-LINE fixture" "$visual_line_session"
fi
lem_stop "$visual_line_session"

# Paredit's local M-j must retain structural precedence over global duplicate.
guard_session="lem-yath-daily-guard-$id"
if start_fixture_session "$guard_session" editing "$lisp_file" &&
   lem_wait_for "$guard_session" '\(a b c\)' "$BOOT_TIMEOUT" >/dev/null; then
  send_chord "$guard_session" w w M-j F9
  if wait_report_count '^BUFFER label=structural-guard ' 1; then
    actual=$(grep '^BUFFER label=structural-guard ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'BUFFER label=structural-guard text=(a c b)\n' ]; then
      pass paredit-m-j-guard "Paredit structurally dragged b instead of duplicating text"
    else
      fail paredit-m-j-guard "M-j produced: $actual" "$guard_session"
    fi
  else
    fail paredit-m-j-guard "the structural snapshot command did not run" "$guard_session"
  fi
else
  fail paredit-m-j-boot "could not open the Lisp fixture" "$guard_session"
fi
lem_stop "$guard_session"

# An already-oversized on-disk history must be normalized before any new file
# opens, rewritten in newest-preserving order, and reloaded identically.
mkdir -p "$LEM_HOME/history"
{
  printf '('
  for index in $(seq 0 304); do
    printf ' "%s/preseed/preseed-%03d.txt"' \
      "$LEM_YATH_DAILY_WORKFLOWS_ROOT" "$index"
  done
  printf ')\n'
} > "$LEM_HOME/history/files"

preseed_session="lem-yath-daily-preseed-$id"
if start_fixture_session "$preseed_session" preseed; then
  mru_preseed=$(grep '^MRU-PRESEED phase=preseed ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
  if [ "$mru_preseed" = 'MRU-PRESEED phase=preseed limit=300 count=300 index=300 first=preseed-304.txt retained-oldest=preseed-005.txt oldest-present=no memory-order=yes disk-order=yes' ]; then
    pass recent-mru-preseed "startup trimmed an oversized history to its newest 300 entries"
  else
    fail recent-mru-preseed "unexpected trimmed MRU: $mru_preseed" "$preseed_session"
  fi
else
  fail recent-mru-preseed "the oversized-history process did not initialize" "$preseed_session"
fi
lem_stop "$preseed_session"
sleep 0.5

preseed_verify_session="lem-yath-daily-preseed-verify-$id"
if start_fixture_session "$preseed_verify_session" preseed-verify; then
  mru_preseed_verify=$(grep '^MRU-PRESEED phase=preseed-verify ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
  if [ "$mru_preseed_verify" = 'MRU-PRESEED phase=preseed-verify limit=300 count=300 index=300 first=preseed-304.txt retained-oldest=preseed-005.txt oldest-present=no memory-order=yes disk-order=yes' ]; then
    pass recent-mru-preseed-persist "a fresh process reloaded the persisted 300-entry trim"
  else
    fail recent-mru-preseed-persist "unexpected persisted trim: $mru_preseed_verify" "$preseed_verify_session"
  fi
else
  fail recent-mru-preseed-persist "the trimmed-history reload did not initialize" "$preseed_verify_session"
fi
lem_stop "$preseed_verify_session"
rm -f "$LEM_HOME/history/files"
sleep 0.5

# Populate more than the intended cap through the real find-file hook. Then
# start a second Lem process against the same HOME to prove persistence.
populate_session="lem-yath-daily-populate-$id"
if start_fixture_session "$populate_session" populate; then
  mru_populate=$(grep '^MRU phase=populate ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
  if [ "$mru_populate" = 'MRU phase=populate limit=300 count=300 first=recent-042.txt target-count=1 oldest-present=no' ]; then
    pass recent-mru-populate "305 opens capped at 300 and a reopen moved one entry to front"
  else
    fail recent-mru-populate "unexpected in-process MRU: $mru_populate" "$populate_session"
  fi
else
  fail recent-mru-populate "recent-file population did not complete" "$populate_session"
fi
lem_stop "$populate_session"
sleep 0.5

recent_session="lem-yath-daily-recent-$id"
if start_fixture_session "$recent_session" verify &&
   lem_wait_for "$recent_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" >/dev/null; then
  mru_verify=$(grep '^MRU phase=verify ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
  if [ "$mru_verify" = 'MRU phase=verify limit=300 count=300 first=recent-042.txt target-count=1 oldest-present=no' ] &&
     [ -s "$LEM_HOME/history/files" ]; then
    pass recent-mru-persistence "a fresh Lem process loaded the same deduplicated 300-entry MRU"
  else
    fail recent-mru-persistence "unexpected persisted MRU: $mru_verify" "$recent_session"
  fi

  send_chord "$recent_session" M-g r
  if lem_wait_for "$recent_session" 'File:' "$WAIT_TIMEOUT" >/dev/null &&
     lem_wait_for "$recent_session" 'recent-042\.txt' "$WAIT_TIMEOUT" >/dev/null; then
    pass recent-binding "M-g r opened the recent-file completion prompt"
    lem_keys "$recent_session" Enter
    sleep 0.3
    lem_keys "$recent_session" Enter
    if lem_wait_for "$recent_session" 'RECENT TARGET 042' "$WAIT_TIMEOUT" >/dev/null; then
      current_before=$(report_count '^CURRENT ')
      lem_keys "$recent_session" F10
      if wait_report_count '^CURRENT ' "$((current_before + 1))" &&
         grep -q '^CURRENT .*file=recent-042\.txt text=RECENT TARGET 042\\n$' "$LEM_YATH_DAILY_WORKFLOWS_REPORT"; then
        pass recent-open "Return opened the most-recent file in the editor"
      else
        fail recent-open "the opened recent buffer did not match the MRU head" "$recent_session"
      fi
    else
      fail recent-open "the focused recent candidate did not open" "$recent_session"
    fi
  else
    fail recent-binding "M-g r did not expose the recent-file prompt and target" "$recent_session"
    lem_keys "$recent_session" Escape
  fi

  # Existing list-buffers remains a multi-column, live-filtered chooser whose
  # Return action switches to the focused buffer.
  if invoke_test_command "$recent_session" lem-yath-test-setup-buffer-list '^BUFFER-LIST READY '; then
    send_chord "$recent_session" C-x C-b
    if lem_wait_for "$recent_session" 'Buffer[[:space:]]+File' "$WAIT_TIMEOUT" >/dev/null; then
      screen=$(lem_capture "$recent_session")
      if grep -q 'daily-alpha-buffer\.txt' <<<"$screen" &&
         grep -q 'daily-zz-target-buffer\.txt' <<<"$screen"; then
        pass buffer-list-columns "C-x C-b displayed Buffer and File columns"
      else
        fail buffer-list-columns "the expected file-backed rows were absent" "$recent_session"
      fi
      tmux_cmd send-keys -t "$recent_session" -l zz-target
      sleep 0.6
      screen=$(lem_capture "$recent_session")
      if grep -q 'daily-zz-target-buffer\.txt' <<<"$screen" &&
         ! grep -q 'daily-alpha-buffer\.txt' <<<"$screen"; then
        pass buffer-list-filter "a distinctive filename query isolated the matching buffer"
      else
        fail buffer-list-filter "the filter did not isolate zz-target" "$recent_session"
      fi
      lem_keys "$recent_session" Enter
      if lem_wait_for "$recent_session" 'DAILY BETA BUFFER TARGET' "$WAIT_TIMEOUT" >/dev/null; then
        current_before=$(report_count '^CURRENT ')
        lem_keys "$recent_session" F10
        if wait_report_count '^CURRENT ' "$((current_before + 1))" &&
           grep -q '^CURRENT .*file=daily-zz-target-buffer\.txt text=DAILY BETA BUFFER TARGET\\n$' "$LEM_YATH_DAILY_WORKFLOWS_REPORT"; then
          pass buffer-list-return "Return switched to the filtered file buffer"
        else
          fail buffer-list-return "the selected buffer identity was not recorded" "$recent_session"
        fi
      else
        fail buffer-list-return "Return did not switch to the beta buffer" "$recent_session"
      fi
    else
      fail buffer-list-columns "C-x C-b did not open the multi-column chooser" "$recent_session"
    fi
  else
    fail buffer-list-setup "could not create the list-buffers fixtures" "$recent_session"
  fi
else
  fail recent-mru-verify-boot "the persistence-check process did not initialize" "$recent_session"
fi

test_find_name() {
  local find_session="lem-yath-daily-find-$id" screen before actual
  if ! start_fixture_session "$find_session" editing "$find_source" ||
     ! lem_wait_for "$find_session" 'find source' "$BOOT_TIMEOUT" >/dev/null; then
    fail find-name-boot "could not open the find-name source buffer" "$find_session"
    return
  fi

  if invoke_test_command "$find_session" lem-yath-test-find-name-buffer-guards '^FIND-GUARDS '; then
    actual=$(grep '^FIND-GUARDS ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'FIND-GUARDS collision-rejected=yes collision-intact=yes stale-start-rejected=yes stale-intact=yes' ]; then
      pass find-name-buffer-guards "unowned buffers and mode-changed async targets stayed untouched"
    else
      fail find-name-buffer-guards "unexpected ownership guard result: $actual" "$find_session"
    fi
  else
    fail find-name-buffer-guards "the ownership regression probe did not run" "$find_session"
  fi

  send_chord "$find_session" M-s f
  if ! lem_wait_for "$find_session" 'Find name in directory:' "$WAIT_TIMEOUT" >/dev/null; then
    fail find-name-directory-prompt "M-s f did not prompt for a directory" "$find_session"
    return
  fi
  lem_keys "$find_session" F4
  if ! lem_wait_for "$find_session" 'Name pattern:' "$WAIT_TIMEOUT" >/dev/null; then
    fail find-name-pattern-prompt "M-s f did not prompt for a name wildcard" "$find_session"
    return
  fi
  send_chord "$find_session" C-a C-k
  tmux_cmd send-keys -t "$find_session" -l '*.match'
  lem_keys "$find_session" Enter

  if lem_wait_for "$find_session" 'Status:[[:space:]]+8 matches' "$WAIT_TIMEOUT" >/dev/null; then
    pass find-name-search "M-s f produced all eight file/directory matches"
  else
    fail find-name-search "the asynchronous find results did not arrive" "$find_session"
    return
  fi

  screen=$(lem_capture "$find_session")
  if grep -Fq '00-[.match' <<<"$screen" &&
     grep -Fq 'named-dir.match' <<<"$screen" &&
     grep -Fq 'semi;colon.match' <<<"$screen" &&
     grep -Fq 'space target.match' <<<"$screen" &&
     grep -Fq 'line\nbreak.match' <<<"$screen" &&
     grep -Fq 'literal*.match' <<<"$screen" &&
     grep -Fq 'literal?.match' <<<"$screen" &&
     ! grep -Fq 'source.txt' <<<"$screen"; then
    pass find-name-render "literal *, ?, [, spaces, semicolons, and newlines rendered safely"
  else
    fail find-name-render "the persistent result buffer rendered the wrong rows" "$find_session"
  fi

  before=$(report_count '^FIND-CURRENT ')
  lem_keys "$find_session" F11
  if wait_report_count '^FIND-CURRENT ' "$((before + 1))"; then
    actual=$(grep '^FIND-CURRENT ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'FIND-CURRENT name=*Find* readonly=yes path=00-[.match' ]; then
      pass find-name-mode "the persistent result buffer is read-only and focused on the sorted first row"
    else
      fail find-name-mode "unexpected find buffer state: $actual" "$find_session"
    fi
  else
    fail find-name-mode "could not inspect the find result buffer" "$find_session"
  fi

  lem_keys "$find_session" Enter
  if lem_wait_for "$find_session" 'FIND OPEN TARGET' "$WAIT_TIMEOUT" >/dev/null; then
    pass find-name-return "Vi Return opened the exact property-backed result"
  else
    fail find-name-return "Return did not open the literal unmatched-bracket filename" "$find_session"
    return
  fi

  send_chord "$find_session" C-x C-b
  if lem_wait_for "$find_session" 'Buffer[[:space:]]+File' "$WAIT_TIMEOUT" >/dev/null; then
    tmux_cmd send-keys -t "$find_session" -l '*Find*'
    sleep 0.5
    lem_keys "$find_session" Enter
  fi
  if lem_wait_for "$find_session" 'Find name results' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$find_session" q
    if lem_wait_for "$find_session" 'FIND OPEN TARGET' "$WAIT_TIMEOUT" >/dev/null; then
      before=$(report_count '^FIND-PERSIST ')
      lem_keys "$find_session" F12
      if wait_report_count '^FIND-PERSIST ' "$((before + 1))" &&
         grep -Fq 'FIND-PERSIST exists=yes readonly=yes current=00-\[.match' "$LEM_YATH_DAILY_WORKFLOWS_REPORT"; then
        pass find-name-persistence "q returned to the file while *Find* remained available"
      else
        fail find-name-persistence "q discarded or mutated the persistent result buffer" "$find_session"
      fi
    else
      fail find-name-quit "q did not return from *Find* to the opened file" "$find_session"
    fi
  else
    fail find-name-revisit "C-x C-b could not revisit the persistent *Find* buffer" "$find_session"
  fi

  # A shell-looking wildcard is one argv element. It must neither execute the
  # embedded command nor prevent the empty result buffer from being useful.
  send_chord "$find_session" M-s f
  if ! lem_wait_for "$find_session" 'Find name in directory:' "$WAIT_TIMEOUT" >/dev/null; then
    fail find-name-safety-directory "the second search did not prompt for a directory" "$find_session"
    return
  fi
  lem_keys "$find_session" F4
  if ! lem_wait_for "$find_session" 'Name pattern:' "$WAIT_TIMEOUT" >/dev/null; then
    fail find-name-safety-pattern "the second search did not prompt for a wildcard" "$find_session"
    return
  fi
  send_chord "$find_session" C-a C-k
  tmux_cmd send-keys -t "$find_session" -l '*.match;touch INJECTED'
  lem_keys "$find_session" Enter
  if lem_wait_for "$find_session" '\(no matches\)' "$WAIT_TIMEOUT" >/dev/null &&
     [ ! -e "$find_sentinel" ]; then
    pass find-name-argv-safety "shell syntax stayed inert and empty results remained visible"
  else
    fail find-name-argv-safety "the pattern executed or empty results were not rendered" "$find_session"
  fi

  lem_stop "$find_session"
}
test_find_name

echo
cat "$LEM_YATH_DAILY_WORKFLOWS_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "DAILY WORKFLOWS TEST PASSED"
  exit 0
else
  echo "DAILY WORKFLOWS TEST FAILED"
  exit 1
fi
