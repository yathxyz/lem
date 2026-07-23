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
export LEM_YATH_DAILY_WORKFLOWS_SLOW_FIND="$root/slow-find"
export LEM_YATH_DAILY_WORKFLOWS_FIND_STARTED="$root/find-started"
export LEM_YATH_DAILY_WORKFLOWS_FIND_TERMINATED="$root/find-terminated"
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

wait_for_file() {
  local path=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    [ -e "$path" ] && return 0
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
  wait_report_count "$report_pattern" "$((count_before + 1))" "$WAIT_TIMEOUT"
}

check_find_marks() {
  local session=$1 label=$2 expected=$3 before actual
  before=$(report_count '^FIND-MARKS ')
  lem_keys "$session" F2
  if wait_report_count '^FIND-MARKS ' "$((before + 1))"; then
    actual=$(grep '^FIND-MARKS ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = "$expected" ]; then
      pass "$label" "$actual"
    else
      fail "$label" "unexpected mark state: $actual" "$session"
    fi
  else
    fail "$label" "the mark-state probe did not run" "$session"
  fi
}

line_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/line-eof.txt"
visual_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/visual.txt"
visual_block_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/visual-block.txt"
visual_line_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/visual-line-eof.txt"
lisp_file="$LEM_YATH_DAILY_WORKFLOWS_ROOT/editing/guard.lisp"
grep_root="$LEM_YATH_DAILY_WORKFLOWS_ROOT/grep"
grep_source="$grep_root/source.txt"
grep_alpha="$grep_root/alpha.txt"
grep_beta="$grep_root/nested/beta.txt"
find_root="$LEM_YATH_DAILY_WORKFLOWS_ROOT/find-name"
find_source="$find_root/source.txt"
find_sentinel="$find_root/INJECTED"
find_ops_root="$LEM_YATH_DAILY_WORKFLOWS_ROOT/find-name-ops"
find_copy_target="$LEM_YATH_DAILY_WORKFLOWS_ROOT/find-name-copy-target"
printf 'first\nomega' > "$line_file"
printf 'prefix TOKEN suffix\n' > "$visual_file"
printf 'aa11zz\nbb22yy\ncc33xx\n' > "$visual_block_file"
printf 'first\nomega' > "$visual_line_file"
printf '(a b c)\n' > "$lisp_file"
mkdir -p "$grep_root/nested"
printf 'grep source anchor\n' > "$grep_source"
printf 'daily grep needle lower\n' > "$grep_alpha"
printf 'DAILY GREP NEEDLE UPPER\n' > "$grep_beta"
printf 'ignored grep needle\n' > "$grep_root/ignored.txt"
printf 'ignored.txt\n' > "$grep_root/.ignore"
mkdir -p "$find_root/nested" "$find_root/named-dir.match" \
  "$find_ops_root/copy-tree.op" "$find_ops_root/tree.op" "$find_copy_target"
printf 'FIND OPEN TARGET\n' > "$find_root/00-[.match"
printf 'nested match\n' > "$find_root/nested/later.match"
printf 'semicolon match\n' > "$find_root/semi;colon.match"
printf 'space match\n' > "$find_root/space target.match"
printf 'literal star match\n' > "$find_root/literal*.match"
printf 'literal question match\n' > "$find_root/literal?.match"
newline_match=$'line\nbreak.match'
printf 'newline match\n' > "$find_root/$newline_match"
printf 'find source\n' > "$find_source"
printf 'hostile copy one\n' > "$find_ops_root/alpha;one.op"
printf 'hostile copy two\n' > "$find_ops_root/beta space.op"
printf 'rename target\n' > "$find_ops_root/move.op"
printf 'delete target\n' > "$find_ops_root/delete.op"
printf 'recursive copy child\n' > "$find_ops_root/copy-tree.op/child.txt"
printf 'recursive child\n' > "$find_ops_root/tree.op/child.txt"
printf '%s\n' \
  "#!$(command -v python3)" \
  'import os' \
  'import signal' \
  'from pathlib import Path' \
  'Path(os.environ["LEM_YATH_DAILY_WORKFLOWS_FIND_STARTED"]).touch()' \
  'def terminate(_signum, _frame):' \
  '    Path(os.environ["LEM_YATH_DAILY_WORKFLOWS_FIND_TERMINATED"]).touch()' \
  '    raise SystemExit(143)' \
  'signal.signal(signal.SIGTERM, terminate)' \
  'while True:' \
  '    signal.pause()' \
  > "$LEM_YATH_DAILY_WORKFLOWS_SLOW_FIND"
chmod +x "$LEM_YATH_DAILY_WORKFLOWS_SLOW_FIND"

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

# Evil Visual Block does not activate Emacs rectangle-mark-mode, so the pinned
# duplicate-dwim duplicates the active cursor line and retains the block.
block_session="lem-yath-daily-visual-block-$id"
if start_fixture_session "$block_session" editing "$visual_block_file" &&
   lem_wait_for "$block_session" 'aa11zz' "$BOOT_TIMEOUT" >/dev/null; then
  visual_before_count=$(report_count '^VISUAL label=visual-before ')
  send_chord "$block_session" C-v j j l l F5
  if wait_report_count '^VISUAL label=visual-before ' "$((visual_before_count + 1))"; then
    before_state=$(grep '^VISUAL label=visual-before ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    before_state=${before_state#* active=}
    visual_after_count=$(report_count '^VISUAL label=visual-after ')
    send_chord "$block_session" 2 M-j F6
    if wait_report_count '^VISUAL label=visual-after ' "$((visual_after_count + 1))"; then
      after_state=$(grep '^VISUAL label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      after_state=${after_state#* active=}
      actual=$(grep '^BUFFER label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      if [ "$before_state" = "$after_state" ] &&
         [[ "$after_state" == yes\ type=block\ * ]] &&
         [ "$actual" = 'BUFFER label=visual-after text=aa11zz\nbb22yy\ncc33xx\ncc33xx\ncc33xx\n' ]; then
        pass duplicate-visual-block-count "2 M-j duplicated the active cursor line and retained the block"
      else
        fail duplicate-visual-block-count "before=[$before_state] after=[$after_state] text=[$actual]" "$block_session"
      fi
    else
      fail duplicate-visual-block-after "the post-M-j block probe did not run" "$block_session"
    fi
  else
    fail duplicate-visual-block-before "the Visual Block probe did not run" "$block_session"
  fi
  buffer_after_count=$(report_count '^BUFFER label=line-after-duplicate ')
  send_chord "$block_session" Escape u F7
  if wait_report_count '^BUFFER label=line-after-duplicate ' "$((buffer_after_count + 1))"; then
    actual=$(grep '^BUFFER label=line-after-duplicate ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'BUFFER label=line-after-duplicate text=aa11zz\nbb22yy\ncc33xx\n' ]; then
      pass duplicate-visual-block-undo "one undo removed both counted copies"
    else
      fail duplicate-visual-block-undo "unexpected undo result: $actual" "$block_session"
    fi
  else
    fail duplicate-visual-block-undo "the block undo probe did not run" "$block_session"
  fi
else
  fail duplicate-visual-block-boot "could not open the Visual Block fixture" "$block_session"
fi
lem_stop "$block_session"

# With the active corner above the mark, duplicate-dwim copies the top cursor
# line; the lower mark follows its original text as Emacs markers do.
block_reverse_session="lem-yath-daily-visual-block-reverse-$id"
if start_fixture_session "$block_reverse_session" editing "$visual_block_file" &&
   lem_wait_for "$block_reverse_session" 'cc33xx' "$BOOT_TIMEOUT" >/dev/null; then
  visual_before_count=$(report_count '^VISUAL label=visual-before ')
  send_chord "$block_reverse_session" G 0 C-v k k l l F5
  if wait_report_count '^VISUAL label=visual-before ' "$((visual_before_count + 1))"; then
    before_state=$(grep '^VISUAL label=visual-before ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    before_state=${before_state#* active=}
    visual_after_count=$(report_count '^VISUAL label=visual-after ')
    send_chord "$block_reverse_session" M-j F6
    if wait_report_count '^VISUAL label=visual-after ' "$((visual_after_count + 1))"; then
      after_state=$(grep '^VISUAL label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      after_state=${after_state#* active=}
      actual=$(grep '^BUFFER label=visual-after ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      before_point=${before_state#* point=}
      before_point=${before_point%% *}
      after_point=${after_state#* point=}
      after_point=${after_point%% *}
      before_start=${before_state#* start=}
      before_start=${before_start%% *}
      after_start=${after_state#* start=}
      after_start=${after_start%% *}
      if [[ "$before_state" == yes\ type=block\ * ]] &&
         [[ "$after_state" == yes\ type=block\ * ]] &&
         [ "$before_point" = "$after_point" ] &&
         [ "$after_start" -eq "$((before_start + 7))" ] &&
         [ "$actual" = 'BUFFER label=visual-after text=aa11zz\naa11zz\nbb22yy\ncc33xx\n' ]; then
        pass duplicate-visual-block-reverse "reverse block duplicated its cursor line and moved the later mark"
      else
        fail duplicate-visual-block-reverse "before=[$before_state] after=[$after_state] text=[$actual]" "$block_reverse_session"
      fi
    else
      fail duplicate-visual-block-reverse "the reverse block post-M-j probe did not run" "$block_reverse_session"
    fi
  else
    fail duplicate-visual-block-reverse "the reverse Visual Block probe did not run" "$block_reverse_session"
  fi
else
  fail duplicate-visual-block-reverse-boot "could not open the reverse Visual Block fixture" "$block_reverse_session"
fi
lem_stop "$block_reverse_session"

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
  if [ "$mru_populate" = 'MRU phase=populate limit=300 count=300 first=recent-042.txt target-count=1 late-index=299 oldest-present=no' ]; then
    pass recent-mru-populate "305 opens capped at 300 and a reopen moved one entry to front"
  else
    fail recent-mru-populate "unexpected in-process MRU: $mru_populate" "$populate_session"
  fi
else
  fail recent-mru-populate "recent-file population did not complete" "$populate_session"
fi
lem_stop "$populate_session"
sleep 0.5

chmod 640 "$LEM_YATH_DAILY_WORKFLOWS_ROOT/recent/recent-042.txt"
touch -d '2020-01-02 03:04:05 UTC' \
  "$LEM_YATH_DAILY_WORKFLOWS_ROOT/recent/recent-042.txt"

recent_session="lem-yath-daily-recent-$id"
if start_fixture_session "$recent_session" verify &&
   lem_wait_for "$recent_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" >/dev/null; then
  mru_verify=$(grep '^MRU phase=verify ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
  if [ "$mru_verify" = 'MRU phase=verify limit=300 count=300 first=recent-042.txt target-count=1 late-index=299 oldest-present=no' ] &&
     [ -s "$LEM_HOME/history/files" ]; then
    pass recent-mru-persistence "a fresh Lem process loaded the same deduplicated 300-entry MRU"
  else
    fail recent-mru-persistence "unexpected persisted MRU: $mru_verify" "$recent_session"
  fi

  send_chord "$recent_session" M-g r
  if lem_wait_for "$recent_session" 'File:' "$WAIT_TIMEOUT" >/dev/null &&
     lem_wait_for "$recent_session" 'recent-042\.txt' "$WAIT_TIMEOUT" >/dev/null; then
    pass recent-binding "M-g r opened the recent-file completion prompt"
    screen=$(lem_capture "$recent_session")
    if grep -Eq 'recent-042\.txt.*-rw-r-----.*18.*2020 Jan 02' \
         <<<"$screen"; then
      pass recent-annotations \
        'M-g r showed permissions, size, and deterministic mtime'
    else
      fail recent-annotations \
        'the recent-file candidate metadata was missing or misresolved' \
        "$recent_session"
    fi
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

    # The provider is globally capped at 100 prepared items, but it must filter
    # the complete 300-entry MRU before that cap on every query. Entry 299 is
    # therefore absent initially and must remain selectable after narrowing.
    send_chord "$recent_session" M-g r
    if lem_wait_for "$recent_session" 'File:' "$WAIT_TIMEOUT" >/dev/null; then
      initial_recent_screen=$(lem_capture "$recent_session")
      tmux_cmd send-keys -t "$recent_session" -l 'recent-005'
      if ! grep -q 'recent-005\.txt' <<<"$initial_recent_screen" &&
         lem_wait_for "$recent_session" 'recent-005\.txt' "$WAIT_TIMEOUT" >/dev/null; then
        lem_keys "$recent_session" Enter
        if lem_wait_for "$recent_session" 'recent fixture 005' "$WAIT_TIMEOUT" >/dev/null; then
          current_before=$(report_count '^CURRENT ')
          lem_keys "$recent_session" F10
          if wait_report_count '^CURRENT ' "$((current_before + 1))" &&
             grep -q '^CURRENT .*file=recent-005\.txt text=recent fixture 005\\n$' \
               "$LEM_YATH_DAILY_WORKFLOWS_REPORT"; then
            pass recent-beyond-cap \
              'narrowing selected the MRU entry at unfiltered index 299'
          else
            fail recent-beyond-cap \
              'the narrowed late candidate opened the wrong file' "$recent_session"
          fi
        else
          fail recent-beyond-cap \
            'Return did not open the narrowed late candidate' "$recent_session"
        fi
      else
        fail recent-beyond-cap \
          'the complete MRU was not filtered before the 100-item cap' \
          "$recent_session"
        lem_keys "$recent_session" Escape
      fi
    else
      fail recent-beyond-cap 'the second recent-file prompt did not open' \
        "$recent_session"
    fi

    if invoke_test_command "$recent_session" lem-yath-test-add-control-recent \
         '^CONTROL-RECENT READY '; then
      if lem_wait_for "$recent_session" 'File:' "$WAIT_TIMEOUT" >/dev/null; then
        tmux_cmd send-keys -t "$recent_session" -l 'control'
      fi
      if lem_wait_for "$recent_session" 'control\\nname\.txt' \
           "$WAIT_TIMEOUT" >/dev/null; then
        control_screen=$(lem_capture "$recent_session")
        if grep -Fq 'control\nname.txt' <<<"$control_screen"; then
          lem_keys "$recent_session" Enter
          if lem_wait_for "$recent_session" 'CONTROL RECENT TARGET' \
               "$WAIT_TIMEOUT" >/dev/null; then
            pass recent-control-path \
              'escaped one-row label opened the untouched newline pathname'
          else
            fail recent-control-path \
              'escaped label did not map back to the raw pathname' \
              "$recent_session"
          fi
        else
          fail recent-control-path \
            'control pathname was not rendered as an escaped one-row label' \
            "$recent_session"
        fi
      else
        fail recent-control-path \
          'newline-containing recent path corrupted or vanished from the prompt' \
          "$recent_session"
        lem_keys "$recent_session" Escape
      fi
    else
      fail recent-control-path \
        'could not add the newline-containing recent path' "$recent_session"
    fi
  else
    fail recent-binding "M-g r did not expose the recent-file prompt and target" "$recent_session"
    lem_keys "$recent_session" Escape
  fi

  # The modal list-buffers chooser enters its name filter through the effective
  # Evil-Collection s n prefix; one Return commits the filter and the next
  # visits the focused buffer.
  if invoke_test_command "$recent_session" lem-yath-test-setup-buffer-list '^BUFFER-LIST READY '; then
    send_chord "$recent_session" C-x C-b
    if lem_wait_for "$recent_session" \
         'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' \
         "$WAIT_TIMEOUT" >/dev/null; then
      screen=$(lem_capture "$recent_session")
      if grep -q 'daily-alpha-buffer\.txt' <<<"$screen" &&
         grep -q 'daily-zz-target-buffer\.txt' <<<"$screen"; then
        pass buffer-list-columns "C-x C-b displayed Buffer and File columns"
      else
        fail buffer-list-columns "the expected file-backed rows were absent" "$recent_session"
      fi
      send_chord "$recent_session" s n
      tmux_cmd send-keys -t "$recent_session" -l zz-target
      sleep 0.6
      screen=$(lem_capture "$recent_session")
      if grep -q 'daily-zz-target-buffer\.txt' <<<"$screen" &&
         ! grep -q 'daily-alpha-buffer\.txt' <<<"$screen"; then
        pass buffer-list-filter "a distinctive filename query isolated the matching buffer"
      else
        fail buffer-list-filter "the filter did not isolate zz-target" "$recent_session"
      fi
      lem_keys "$recent_session" Enter Enter
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

  start_ops_search() {
    local pattern=$1 expected=$2
    send_chord "$find_session" M-s f
    lem_wait_for "$find_session" 'ind name in directory:' "$WAIT_TIMEOUT" >/dev/null || return 1
    lem_keys "$find_session" F1
    lem_wait_for "$find_session" 'Name pattern:' "$WAIT_TIMEOUT" >/dev/null || return 1
    send_chord "$find_session" C-a C-k
    tmux_cmd send-keys -t "$find_session" -l "$pattern"
    lem_keys "$find_session" Enter
    lem_wait_for "$find_session" "Status:[[:space:]]+$expected" "$WAIT_TIMEOUT" >/dev/null || return 1
    sleep "$KEY_DELAY"
  }
  if ! start_fixture_session "$find_session" editing "$find_source" ||
     ! lem_wait_for "$find_session" 'find source' "$BOOT_TIMEOUT" >/dev/null; then
    fail find-name-boot "could not open the find-name source buffer" "$find_session"
    return
  fi

  if invoke_test_command "$find_session" lem-yath-test-find-name-buffer-guards '^FIND-GUARDS '; then
    actual=$(grep '^FIND-GUARDS ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'FIND-GUARDS collision-rejected=yes collision-intact=yes stale-start-rejected=yes stale-intact=yes root-copy-rejected=yes' ]; then
      pass find-name-buffer-guards "unowned buffers and mode-changed async targets stayed untouched"
    else
      fail find-name-buffer-guards "unexpected ownership guard result: $actual" "$find_session"
    fi
  else
    fail find-name-buffer-guards "the ownership regression probe did not run" "$find_session"
  fi

  send_chord "$find_session" M-s f
  if ! lem_wait_for "$find_session" 'ind name in directory:' "$WAIT_TIMEOUT" >/dev/null; then
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

  tmux_cmd resize-window -t "$find_session" -x 100 -y 30
  sleep "$KEY_DELAY"
  if invoke_test_command "$find_session" lem-yath-test-record-find-name-display '^FIND-DISPLAY '; then
    actual=$(grep '^FIND-DISPLAY ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'FIND-DISPLAY width=100 file-cells=100 file-tail=....17 file-size=....17 file-buffer=.../00-[.match directory-cells=100 directory-tail=.....0 directory-size=.....0 directory-buffer=.../named-dir.match modified=no' ] &&
       lem_capture "$find_session" | grep -Eq '00-\[\.match +17$'; then
      pass find-name-dirvish-size "Dirvish file sizes align at the right edge without entering buffer text"
    else
      fail find-name-dirvish-size "unexpected 100-column size rendering: $actual" "$find_session"
    fi
  else
    fail find-name-dirvish-size "could not inspect the rendered file-size attribute" "$find_session"
  fi

  tmux_cmd resize-window -t "$find_session" -x 64 -y 30
  sleep "$KEY_DELAY"
  if invoke_test_command "$find_session" lem-yath-test-record-find-name-display '^FIND-DISPLAY '; then
    actual=$(grep '^FIND-DISPLAY ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'FIND-DISPLAY width=64 file-cells=64 file-tail=....17 file-size=....17 file-buffer=.../00-[.match directory-cells=64 directory-tail=.....0 directory-size=.....0 directory-buffer=.../named-dir.match modified=no' ]; then
      pass find-name-dirvish-resize "right-edge file and directory metadata followed the resized window"
    else
      fail find-name-dirvish-resize "unexpected 64-column size rendering: $actual" "$find_session"
    fi
  else
    fail find-name-dirvish-resize "could not inspect size alignment after resize" "$find_session"
  fi
  tmux_cmd resize-window -t "$find_session" -x 100 -y 30
  sleep "$KEY_DELAY"

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

  check_find_marks "$find_session" find-name-marks-initial \
    'FIND-MARKS count=0 current=00-[.match marked='
  send_chord "$find_session" m m
  check_find_marks "$find_session" find-name-mark-advance \
    'FIND-MARKS count=2 current=literal*.match marked=00-[.match,line\nbreak.match'
  screen=$(lem_capture "$find_session")
  if grep -Fq '* ./00-[.match' <<<"$screen" &&
     grep -Fq '* ./line\nbreak.match' <<<"$screen" &&
     grep -Fq '  ./literal*.match' <<<"$screen"; then
    pass find-name-mark-render "marked and unmarked rows have distinct Dired prefixes"
  else
    fail find-name-mark-render "the visible mark prefixes do not match the mark set" "$find_session"
  fi

  printf 'refresh-only match\n' > "$find_root/refresh-only.match"
  lem_keys "$find_session" g
  if lem_wait_for "$find_session" 'Status:[[:space:]]+9 matches' "$WAIT_TIMEOUT" >/dev/null; then
    check_find_marks "$find_session" find-name-mark-refresh \
      'FIND-MARKS count=2 current=00-[.match marked=00-[.match,line\nbreak.match'
  else
    fail find-name-mark-refresh "g did not complete the refreshed search" "$find_session"
  fi
  rm -f "$find_root/refresh-only.match"
  lem_keys "$find_session" g
  if ! lem_wait_for "$find_session" 'Status:[[:space:]]+8 matches' "$WAIT_TIMEOUT" >/dev/null; then
    fail find-name-mark-refresh-prune "g did not remove the vanished result" "$find_session"
  fi

  lem_keys "$find_session" U
  check_find_marks "$find_session" find-name-unmark-all \
    'FIND-MARKS count=0 current=00-[.match marked='
  lem_keys "$find_session" t
  check_find_marks "$find_session" find-name-toggle-all \
    'FIND-MARKS count=8 current=00-[.match marked=00-[.match,line\nbreak.match,literal*.match,literal?.match,named-dir.match,later.match,semi;colon.match,space target.match'
  lem_keys "$find_session" u
  check_find_marks "$find_session" find-name-unmark-advance \
    'FIND-MARKS count=7 current=line\nbreak.match marked=line\nbreak.match,literal*.match,literal?.match,named-dir.match,later.match,semi;colon.match,space target.match'
  lem_keys "$find_session" t
  check_find_marks "$find_session" find-name-toggle-inverse \
    'FIND-MARKS count=1 current=line\nbreak.match marked=00-[.match'
  printf 'refresh-only match\n' > "$find_root/refresh-only.match"
  lem_keys "$find_session" g
  if lem_wait_for "$find_session" 'Status:[[:space:]]+9 matches' "$WAIT_TIMEOUT" >/dev/null; then
    check_find_marks "$find_session" find-name-final-mark-refresh \
      'FIND-MARKS count=1 current=00-[.match marked=00-[.match'
  else
    fail find-name-final-mark-refresh "the marked refresh did not finish" "$find_session"
  fi
  rm -f "$find_root/refresh-only.match"

  lem_keys "$find_session" Enter
  if lem_wait_for "$find_session" 'FIND OPEN TARGET' "$WAIT_TIMEOUT" >/dev/null; then
    pass find-name-return "Vi Return opened the exact property-backed result"
  else
    fail find-name-return "Return did not open the literal unmatched-bracket filename" "$find_session"
    return
  fi

  lem_keys "$find_session" F4
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
    fail find-name-revisit "the persistent *Find* buffer could not be revisited" "$find_session"
    lem_keys "$find_session" Escape
    sleep "$KEY_DELAY"
  fi

  # A shell-looking wildcard is one argv element. It must neither execute the
  # embedded command nor prevent the empty result buffer from being useful.
  send_chord "$find_session" M-s f
  if ! lem_wait_for "$find_session" 'ind name in directory:' "$WAIT_TIMEOUT" >/dev/null; then
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
    check_find_marks "$find_session" find-name-fresh-search-clears-marks \
      'FIND-MARKS count=0 current=none marked='
  else
    fail find-name-argv-safety "the pattern executed or empty results were not rendered" "$find_session"
  fi

  if invoke_test_command "$find_session" lem-yath-test-use-slow-find '^FIND-SLOW READY$'; then
    send_chord "$find_session" M-s f
    if lem_wait_for "$find_session" 'ind name in directory:' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" F4
    fi
    if lem_wait_for "$find_session" 'Name pattern:' "$WAIT_TIMEOUT" >/dev/null; then
      send_chord "$find_session" C-a C-k
      tmux_cmd send-keys -t "$find_session" -l '*.slow'
      lem_keys "$find_session" Enter
    fi
    if lem_wait_for "$find_session" 'Status:[[:space:]]+searching' "$WAIT_TIMEOUT" >/dev/null &&
       wait_for_file "$LEM_YATH_DAILY_WORKFLOWS_FIND_STARTED" "$WAIT_TIMEOUT"; then
      send_chord "$find_session" C-c C-k
      if lem_wait_for "$find_session" 'Status:[[:space:]]+cancelled' "$WAIT_TIMEOUT" >/dev/null &&
         wait_for_file "$LEM_YATH_DAILY_WORKFLOWS_FIND_TERMINATED" "$WAIT_TIMEOUT"; then
        pass find-name-cancel "C-c C-k terminated only the active find and retained cancelled results"
      else
        fail find-name-cancel "the active find process was not cancelled cleanly" "$find_session"
      fi
    else
      fail find-name-cancel-start "the controlled long-running find did not start" "$find_session"
    fi
  else
    fail find-name-cancel-setup "could not select the controlled find executable" "$find_session"
  fi

  # A new process is used for the operation checks because the cancellation
  # probe deliberately replaces the find executable in this one.
  lem_stop "$find_session"
  find_session="lem-yath-daily-find-ops-$id"
  if ! start_fixture_session "$find_session" editing "$find_source" ||
     ! lem_wait_for "$find_session" 'find source' "$BOOT_TIMEOUT" >/dev/null; then
    fail find-name-operations-boot "could not open the file-operation fixture" "$find_session"
    return
  fi

  if start_ops_search '*.op' '6 matches'; then
    send_chord "$find_session" Escape m m
    if invoke_test_command "$find_session" lem-yath-test-find-name-bindings '^FIND-BINDINGS '; then
      actual=$(grep '^FIND-BINDINGS ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      if [ "$actual" = 'FIND-BINDINGS C=LEM-YATH-FIND-NAME-COPY R=LEM-YATH-FIND-NAME-RENAME D=LEM-YATH-FIND-NAME-DELETE m=LEM-YATH-FIND-NAME-MARK' ]; then
        pass find-name-normal-bindings "Dired commands override conflicting Vi Normal keys only in *Find*"
      else
        fail find-name-normal-bindings "unexpected Vi Normal bindings: $actual" "$find_session"
      fi
    else
      fail find-name-normal-bindings "could not inspect the active *Find* keymaps" "$find_session"
    fi
    lem_keys "$find_session" C
    if lem_wait_for "$find_session" 'opy to:' "$WAIT_TIMEOUT" >/dev/null; then
      pass find-name-copy-prompt "C opened Lem's file-completion destination prompt"
    else
      fail find-name-copy-prompt "C did not open the copy destination prompt" "$find_session"
    fi
    if invoke_test_command "$find_session" lem-yath-test-find-name-copy-to-target '^FIND-COPY-COMMAND done$' &&
       lem_wait_for "$find_session" 'Status:[[:space:]]+6 matches' "$WAIT_TIMEOUT" >/dev/null &&
       cmp -s "$find_ops_root/alpha;one.op" "$find_copy_target/alpha;one.op" &&
       cmp -s "$find_ops_root/beta space.op" "$find_copy_target/beta space.op"; then
      pass find-name-copy "C copied the marked hostile pathnames into an existing directory"
    else
      fail find-name-copy "marked copy did not preserve both exact pathnames" "$find_session"
    fi

    lem_keys "$find_session" U
    printf 'collision sentinel\n' > "$find_copy_target/alpha;one.op"
    lem_keys "$find_session" m
    send_chord "$find_session" Escape Escape M-x
    tmux_cmd send-keys -t "$find_session" -l 'lem-yath-test-find-name-copy-to-target'
    lem_keys "$find_session" Enter
    if lem_wait_for "$find_session" 'Overwrite .*alpha;one\.op' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" n
    fi
    sleep 0.5
    if [ "$(cat "$find_copy_target/alpha;one.op")" = 'collision sentinel' ]; then
      pass find-name-copy-refusal "declining the collision prompt left the destination untouched"
    else
      fail find-name-copy-refusal "copy overwrote a destination after refusal" "$find_session"
    fi
  else
    fail find-name-operations-search "could not produce the operation fixture results" "$find_session"
  fi

  if start_ops_search 'copy-tree.op' '1 match'; then
    before=$(report_count '^FIND-COPY-COMMAND done$')
    send_chord "$find_session" Escape Escape M-x
    tmux_cmd send-keys -t "$find_session" -l 'lem-yath-test-find-name-copy-to-target'
    lem_keys "$find_session" Enter
    if lem_wait_for "$find_session" 'Recursively copy directory' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" n
    fi
    wait_report_count '^FIND-COPY-COMMAND done$' "$((before + 1))" || true
    if [ ! -e "$find_copy_target/copy-tree.op" ]; then
      pass find-name-copy-directory-refusal "declining recursive copy left the destination absent"
    else
      fail find-name-copy-directory-refusal "recursive copy ran after refusal" "$find_session"
    fi

    before=$(report_count '^FIND-COPY-COMMAND done$')
    send_chord "$find_session" Escape Escape M-x
    tmux_cmd send-keys -t "$find_session" -l 'lem-yath-test-find-name-copy-to-target'
    lem_keys "$find_session" Enter
    if lem_wait_for "$find_session" 'Recursively copy directory' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" y
    fi
    if wait_report_count '^FIND-COPY-COMMAND done$' "$((before + 1))" &&
       [ "$(cat "$find_copy_target/copy-tree.op/child.txt")" = 'recursive copy child' ]; then
      pass find-name-copy-directory "directory copy required explicit top-level confirmation"
    else
      fail find-name-copy-directory "confirmed recursive copy did not preserve the directory" "$find_session"
    fi
  else
    fail find-name-copy-directory-search "could not isolate the recursive-copy fixture" "$find_session"
  fi

  if start_ops_search 'move.op' '1 match'; then
    lem_keys "$find_session" R
    if lem_wait_for "$find_session" 'ename to:' "$WAIT_TIMEOUT" >/dev/null; then
      pass find-name-rename-prompt "R opened Lem's file-completion destination prompt"
    else
      fail find-name-rename-prompt "R did not open the rename destination prompt" "$find_session"
    fi
    if invoke_test_command "$find_session" lem-yath-test-find-name-rename-to-target '^FIND-RENAME-COMMAND done$' &&
       lem_wait_for "$find_session" 'Status:[[:space:]]+0 matches' "$WAIT_TIMEOUT" >/dev/null &&
       [ ! -e "$find_ops_root/move.op" ] &&
       [ "$(cat "$find_ops_root/renamed.op")" = 'rename target' ]; then
      pass find-name-rename "R renamed the current unmarked result and refreshed the search"
    else
      fail find-name-rename "current-row rename did not move the exact source" "$find_session"
    fi
  else
    fail find-name-rename-search "could not isolate the rename fixture" "$find_session"
  fi

  if start_ops_search 'delete.op' '1 match'; then
    lem_keys "$find_session" D
    if lem_wait_for "$find_session" 'Delete 1 selected entry' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" y
    fi
    if lem_wait_for "$find_session" 'Status:[[:space:]]+0 matches' "$WAIT_TIMEOUT" >/dev/null &&
       [ ! -e "$find_ops_root/delete.op" ]; then
      pass find-name-delete "D confirmed and deleted the current ordinary file"
    else
      fail find-name-delete "confirmed ordinary deletion did not refresh cleanly" "$find_session"
    fi
  else
    fail find-name-delete-search "could not isolate the delete fixture" "$find_session"
  fi

  if start_ops_search 'tree.op' '1 match'; then
    lem_keys "$find_session" D
    if lem_wait_for "$find_session" 'Delete 1 selected entry' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" y
    fi
    if lem_wait_for "$find_session" 'Recursively delete directory' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" n
    fi
    sleep 0.5
    if [ -f "$find_ops_root/tree.op/child.txt" ]; then
      pass find-name-delete-directory-refusal "declining recursive deletion retained the complete directory"
    else
      fail find-name-delete-directory-refusal "recursive refusal removed directory contents" "$find_session"
    fi

    lem_keys "$find_session" D
    if lem_wait_for "$find_session" 'Delete 1 selected entry' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" y
    fi
    if lem_wait_for "$find_session" 'Recursively delete directory' "$WAIT_TIMEOUT" >/dev/null; then
      lem_keys "$find_session" y
    fi
    if lem_wait_for "$find_session" 'Status:[[:space:]]+0 matches' "$WAIT_TIMEOUT" >/dev/null &&
       [ ! -e "$find_ops_root/tree.op" ]; then
      pass find-name-delete-directory "D required both confirmations before recursive deletion"
    else
      fail find-name-delete-directory "confirmed recursive deletion did not remove the directory" "$find_session"
    fi
  else
    fail find-name-delete-directory-search "could not isolate the directory fixture" "$find_session"
  fi

  lem_stop "$find_session"
}

test_grep() {
  local grep_session="lem-yath-daily-grep-$id" before actual screen
  local grep_selected_current=""
  if ! start_fixture_session "$grep_session" editing "$grep_source" ||
     ! lem_wait_for "$grep_session" 'grep source anchor' "$BOOT_TIMEOUT" >/dev/null; then
    fail grep-boot "could not open the configured grep fixture" "$grep_session"
    return
  fi

  send_chord "$grep_session" M-s g
  if lem_wait_for "$grep_session" 'rg -nS --no-heading' "$WAIT_TIMEOUT" >/dev/null; then
    screen=$(lem_capture "$grep_session")
    if grep -Fq 'rg -nS --no-heading ' <<<"$screen"; then
      pass grep-default-command "M-s g offered the exact configured ripgrep command"
    else
      fail grep-default-command "the grep prompt did not retain its trailing input position" "$grep_session"
    fi
  else
    fail grep-default-command "M-s g retained the stale upstream git-grep prompt" "$grep_session"
  fi
  tmux_cmd send-keys -t "$grep_session" -l -- needle
  lem_keys "$grep_session" Enter
  if lem_wait_for "$grep_session" 'Directory:' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$grep_session" F2
  else
    fail grep-directory-prompt "grep did not request its search directory" "$grep_session"
  fi

  if lem_wait_for "$grep_session" 'DAILY GREP NEEDLE UPPER' "$WAIT_TIMEOUT" >/dev/null; then
    before=$(report_count '^GREP ')
    lem_keys "$grep_session" F8
    if wait_report_count '^GREP ' "$((before + 1))"; then
      actual=$(grep '^GREP ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
      if [ "$actual" = 'GREP mode=yes readonly=yes records=2 active=no alpha=yes beta=yes ignored=no query=yes directory=yes' ]; then
        pass grep-results "smart-case results were scoped, recorded, and read-only"
      else
        fail grep-results "unexpected configured grep state: $actual" "$grep_session"
      fi
    else
      fail grep-results "the grep result-state probe did not run" "$grep_session"
    fi
  else
    fail grep-results "global grep did not render both smart-case matches" "$grep_session"
  fi

  send_chord "$grep_session" i
  lem_keys "$grep_session" F2
  send_chord "$grep_session" i
  tmux_cmd send-keys -t "$grep_session" -l -- X
  before=$(report_count '^GREP ')
  lem_keys "$grep_session" F8
  if wait_report_count '^GREP ' "$((before + 1))"; then
    actual=$(grep '^GREP ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [[ "$actual" == \
          'GREP mode=yes readonly=no records=2 active=yes alpha=no beta=yes ignored=no query=yes directory=yes' ||
          "$actual" == \
          'GREP mode=yes readonly=no records=2 active=yes alpha=yes beta=no ignored=no query=yes directory=yes' ]] &&
       [ "$(cat "$grep_alpha")" = 'daily grep needle lower' ] &&
       [ "$(cat "$grep_beta")" = 'DAILY GREP NEEDLE UPPER' ]; then
      pass grep-staged-edit "i staged a result-row edit without touching its source"
    else
      fail grep-staged-edit "global grep bypassed staged editing: $actual" "$grep_session"
    fi
  else
    fail grep-staged-edit "the staged grep-state probe did not run" "$grep_session"
  fi

  send_chord "$grep_session" Escape
  send_chord "$grep_session" C-c C-k
  before=$(report_count '^GREP ')
  lem_keys "$grep_session" F8
  if wait_report_count '^GREP ' "$((before + 1))"; then
    actual=$(grep '^GREP ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = 'GREP mode=yes readonly=yes records=2 active=no alpha=yes beta=yes ignored=no query=yes directory=yes' ] &&
       [ "$(cat "$grep_alpha")" = 'daily grep needle lower' ]; then
      pass grep-staged-abort "C-c C-k restored the result and retained the exact source"
    else
      fail grep-staged-abort "aborting did not restore the global grep transaction: $actual" "$grep_session"
    fi
  else
    fail grep-staged-abort "the post-abort grep-state probe did not run" "$grep_session"
  fi

  send_chord "$grep_session" C-n Enter
  if lem_wait_for "$grep_session" 'daily grep needle lower|DAILY GREP NEEDLE UPPER' "$WAIT_TIMEOUT" >/dev/null; then
    before=$(report_count '^CURRENT ')
    lem_keys "$grep_session" F10
    if wait_report_count '^CURRENT ' "$((before + 1))"; then
      grep_selected_current=$(grep '^CURRENT ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    else
      grep_selected_current=
    fi
    if [[ "$grep_selected_current" == \
          'CURRENT name=alpha.txt file=alpha.txt text=daily grep needle lower\n' ||
          "$grep_selected_current" == \
          'CURRENT name=beta.txt file=beta.txt text=DAILY GREP NEEDLE UPPER\n' ]]; then
      pass grep-navigation "C-n and Return visited the other exact source match"
    else
      fail grep-navigation "result navigation did not select a matching source" "$grep_session"
    fi
  else
    fail grep-navigation "C-n and Return did not visit a matching source" "$grep_session"
  fi

  send_chord "$grep_session" M-s g
  if lem_wait_for "$grep_session" 'rg -nS --no-heading needle' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$grep_session" C-g
  fi
  before=$(report_count '^CURRENT ')
  lem_keys "$grep_session" F10
  if wait_report_count '^CURRENT ' "$((before + 1))"; then
    actual=$(grep '^CURRENT ' "$LEM_YATH_DAILY_WORKFLOWS_REPORT" | tail -1)
    if [ "$actual" = "$grep_selected_current" ]; then
      pass grep-cancel "C-g cancelled the command prompt without changing buffers"
    else
      fail grep-cancel "prompt cancellation changed the selected source" "$grep_session"
    fi
  else
    fail grep-cancel "the post-cancellation source probe did not run" "$grep_session"
  fi

  send_chord "$grep_session" M-s g
  if lem_wait_for "$grep_session" 'rg -nS --no-heading needle' "$WAIT_TIMEOUT" >/dev/null; then
    send_chord "$grep_session" C-a C-k
    tmux_cmd send-keys -t "$grep_session" -l -- 'rg -nS --no-heading absent-value'
    lem_keys "$grep_session" Enter
  fi
  if lem_wait_for "$grep_session" 'Directory:' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$grep_session" F2
  fi
  if lem_wait_for "$grep_session" 'No match' "$WAIT_TIMEOUT" >/dev/null; then
    pass grep-no-match "an empty ripgrep result reported No match without a parser failure"
  else
    fail grep-no-match "empty output did not reach the intended No match path" "$grep_session"
  fi

  send_chord "$grep_session" M-s g
  if lem_wait_for "$grep_session" 'rg -nS --no-heading absent-value' "$WAIT_TIMEOUT" >/dev/null; then
    send_chord "$grep_session" C-a C-k
    tmux_cmd send-keys -t "$grep_session" -l -- "rg -nS --no-heading '['"
    lem_keys "$grep_session" Enter
  fi
  if lem_wait_for "$grep_session" 'Directory:' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$grep_session" F2
  fi
  if lem_wait_for "$grep_session" 'regex parse error|unclosed character class' "$WAIT_TIMEOUT" >/dev/null; then
    pass grep-invalid-regexp "ripgrep regexp errors remained visible and recoverable"
  else
    fail grep-invalid-regexp "an invalid regexp did not report ripgrep's error" "$grep_session"
  fi

  lem_stop "$grep_session"
}

test_find_name
test_grep

echo
cat "$LEM_YATH_DAILY_WORKFLOWS_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "DAILY WORKFLOWS TEST PASSED"
  exit 0
else
  echo "DAILY WORKFLOWS TEST FAILED"
  exit 1
fi
