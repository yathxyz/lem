#!/usr/bin/env bash
# Real-ncurses acceptance coverage for Emacs-style asynchronous compilation.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-compilation-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-compilation.quote's.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_COMPILATION_ROOT="$root/work"
export LEM_YATH_COMPILATION_REPORT="$root/report"
source_root="${LEM_YATH_SOURCE:-$here/lem-yath}"
export LEM_YATH_COMPILATION_SOURCE="$source_root/src/compilation.lisp"
export LEM_YATH_COMPILATION_GUARDIAN_PATH_REPORT="$root/guardian-path"
export LEM_YATH_COMPILATION_SENTINEL="captured from * origin = value"
export LEM_YATH_COMPILATION_BASH_ENV="$root/bash env"
export LEM_YATH_COMPILATION_SHADOW_PATH="$root/shadow-bin"
export LEM_YATH_COMPILATION_PYTHONPATH="$root/python poison"
processors=$(nproc)
export LEM_YATH_EXPECTED_MAKE_COMMAND="make -k -j$(((2 * processors + 2) / 3)) "
export LEM_TUI_WIDTH=150
export LEM_TUI_HEIGHT=42
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_YATH_COMPILATION_ROOT"
: >"$LEM_YATH_COMPILATION_REPORT"
: >"$LEM_YATH_COMPILATION_ROOT/events"

source "$here/scripts/tui-driver.sh"

session="lem-yath-compilation-$id"
origin="$LEM_YATH_COMPILATION_ROOT/origin.txt"
main_c="$LEM_YATH_COMPILATION_ROOT/main.c"
fake="$here/scripts/fake-compiler.py"
report="$LEM_YATH_COMPILATION_REPORT"
events="$LEM_YATH_COMPILATION_ROOT/events"
export LEM_YATH_COMPILATION_EVENTS="$events"
compiler_python=$(command -v python3)
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"
KEY_DELAY="${KEY_DELAY:-0.16}"

printf '%s\n' one two three four five six seven eight >"$origin"
printf '%s\n' \
  'int one;' 'int two;' 'int three;' 'int four;' \
  'int five;' 'int six;' 'int seven;' 'int eight;' >"$main_c"
printf '%s\n' 'fn one() {}' 'fn two() {}' 'fn three() {}' 'fn four() {}' \
  >"$LEM_YATH_COMPILATION_ROOT/secondary.rs"
printf '%s\n' 'package main' 'func one() {}' 'func two() {}' 'func four() {}' \
  >"$LEM_YATH_COMPILATION_ROOT/worker.go"
printf '%s\n' one two three four five six seven eight \
  >"$LEM_YATH_COMPILATION_ROOT/test_sample.py"
printf '%s\n' one two three four five six seven eight \
  >"$LEM_YATH_COMPILATION_ROOT/default.nix"
printf 'all:\n\t@printf '\''DEFAULT-MAKE-RAN\\n'\''\n' \
  >"$LEM_YATH_COMPILATION_ROOT/Makefile"
printf '%s\n' \
  'if [ ! -e "$LEM_YATH_COMPILATION_ROOT/silent-startup.request" ]; then' \
  "  printf 'INNER-BASH-ENV\\n' >&2" \
  'fi' \
  'printf '\''bash-env shellopts=%s\n'\'' "$SHELLOPTS" >> "$LEM_YATH_COMPILATION_EVENTS"' \
  'if [ -e "$LEM_YATH_COMPILATION_ROOT/startup-stop.request" ]; then' \
  '  printf '\''startup-stop target=%s command=%s\n'\'' "$PPID" "$$" >> "$LEM_YATH_COMPILATION_EVENTS"' \
  '  kill -STOP "$PPID"' \
  'fi' \
  >"$LEM_YATH_COMPILATION_BASH_ENV"
mkdir -p "$LEM_YATH_COMPILATION_SHADOW_PATH"
for shadow_name in bash python3 nproc; do
  printf '%s\n' \
    '#!/bin/sh' \
    "printf 'shadow-$shadow_name\\n' >> \"\$LEM_YATH_COMPILATION_EVENTS\"" \
    'exit 99' \
    >"$LEM_YATH_COMPILATION_SHADOW_PATH/$shadow_name"
  chmod +x "$LEM_YATH_COMPILATION_SHADOW_PATH/$shadow_name"
done
mkdir -p "$LEM_YATH_COMPILATION_PYTHONPATH"
printf '%s\n' \
  'import os' \
  'import sys' \
  'from pathlib import Path' \
  '' \
  '_directory = Path(__file__).resolve().parent' \
  '_program = os.path.basename(sys.argv[0])' \
  'if _program == "compilation-guardian.py":' \
  '    (_directory / "guardian-poisoned").write_text("loaded\n", encoding="utf-8")' \
  '    os._exit(97)' \
  'if _program == "fake-compiler.py":' \
  '    (_directory / "inner-loaded").write_text("loaded\n", encoding="utf-8")' \
  >"$LEM_YATH_COMPILATION_PYTHONPATH/sitecustomize.py"

private_guardian_pid() {
  local pid=$1 cwd expected_cwd executable guardian_path argv0 argv1 argv2
  local -a argv=()
  [ -r "/proc/$pid/cmdline" ] || return 1
  cwd=$(readlink -- "/proc/$pid/cwd" 2>/dev/null) || return 1
  expected_cwd=$(readlink -f -- "$LEM_YATH_COMPILATION_ROOT" 2>/dev/null) ||
    return 1
  [ "$cwd" = "$expected_cwd" ] || return 1
  while IFS= read -r -d '' argument; do
    argv+=("$argument")
  done <"/proc/$pid/cmdline"
  [ "${#argv[@]}" -eq 3 ] || return 1
  argv0=${argv[0]}
  argv1=${argv[1]}
  argv2=${argv[2]}
  [ -r "$LEM_YATH_COMPILATION_GUARDIAN_PATH_REPORT" ] || return 1
  guardian_path=$(<"$LEM_YATH_COMPILATION_GUARDIAN_PATH_REPORT")
  [ "$argv1" = "$guardian_path" ] || return 1
  [ "${argv2##*/}" = bash ] || return 1
  executable=$(readlink -- "/proc/$pid/exe" 2>/dev/null) || return 1
  [ "$(readlink -f -- "$argv0" 2>/dev/null)" = "$executable" ]
}

fixture_pid_owned() {
  local pid=$1 cwd expected_cwd cmdline
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
  [ -r "/proc/$pid/cmdline" ] || return 1
  cwd=$(readlink -- "/proc/$pid/cwd" 2>/dev/null) || return 1
  expected_cwd=$(readlink -f -- "$LEM_YATH_COMPILATION_ROOT" 2>/dev/null) ||
    return 1
  [ "$cwd" = "$expected_cwd" ] || return 1
  cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
  [[ "$cmdline" == *"$LEM_YATH_COMPILATION_ROOT"* ]] ||
    private_guardian_pid "$pid"
}

cleanup_test_processes() {
  local pid
  [ -f "$events" ] || return 0
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if [ "$pid" -gt 1 ] && [ -e "/proc/$pid/stat" ] &&
       fixture_pid_owned "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done < <(awk '
    {
      for (field_index = 1; field_index <= NF; field_index++) {
        if ($field_index ~ /^(pid|pgid|guardian|target|command|[^[:space:]]*-(child|target|command))=[0-9]+$/) {
          sub(/^[^=]+=/, "", $field_index)
          print $field_index
        }
      }
    }
  ' "$events" | sort -un)
}

cleanup() {
  lem_stop "$session" || true
  cleanup_test_processes
  case "${root:-}" in
    */lem-yath-compilation.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe compilation cleanup path: %s\n' \
         "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-28s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- fixture report ---\n' >&2
  sed -n '1,320p' "$report" >&2 || true
  printf '\n--- compiler events ---\n' >&2
  sed -n '1,320p' "$events" >&2 || true
  exit 1
}

send_chord() {
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l "$1"
}

wait_file() {
  local path=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    [ -e "$path" ] && return 0
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_report() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    grep -qE "$pattern" "$report" 2>/dev/null && return 0
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

record_until() {
  local key=$1 pattern=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    lem_keys "$session" "$key"
    sleep 0.12
    grep -qE "$pattern" "$report" 2>/dev/null && return 0
    sleep 0.13
    index=$((index + 1))
  done
  return 1
}

state_count() { grep -c '^STATE ' "$report" 2>/dev/null || true; }
latest_state() { grep '^STATE ' "$report" | tail -1; }

record_state() {
  local before
  before=$(state_count)
  lem_keys "$session" F12
  for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
    (( $(state_count) > before )) && return 0
    sleep 0.25
  done
  return 1
}

compiler_command() {
  printf '%q %q %q %q' \
    "$compiler_python" "$fake" "$1" "$LEM_YATH_COMPILATION_ROOT"
}

enter_compile_command() {
  local command=$1
  send_chord Space c c
  # A long per-buffer command horizontally scrolls the prompt label out of
  # view, but the ncurses completion border remains an unambiguous prompt.
  lem_wait_for "$session" '╭' "$WAIT_TIMEOUT" >/dev/null || return 1
  send_chord C-a C-k
  send_literal "$command"
  sleep "$KEY_DELAY"
  lem_keys "$session" Enter
}

event_pid() {
  local mode=$1 field=${2:-pid}
  grep "start mode=$mode " "$events" | tail -1 |
    sed -nE "s/.*[[:space:]]$field=([0-9]+).*/\\1/p"
}

event_field() {
  local prefix=$1 field=$2
  sed -nE \
    "s/^$prefix .*${field}=([0-9]+).*/\\1/p" "$events" | tail -1
}

child_pid() {
  local label=$1
  sed -nE "s/^$label=([0-9]+)$/\\1/p" "$events" | tail -1
}

pid_running() {
  local pid=$1 state
  [ -r "/proc/$pid/stat" ] || return 1
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  [[ "$state" != Z && "$state" != X && -n "$state" ]]
}

# Brokers and anchored group leaders are explicitly reaped and must disappear.
# A deeper descendant can instead remain briefly as a non-running zombie after
# reparenting, so its assertion is intentionally separate.
pid_gone() {
  local pid=$1
  [ ! -e "/proc/$pid/stat" ]
}

pid_terminated() {
  local pid=$1 state
  [ -r "/proc/$pid/stat" ] || return 0
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  [[ "$state" == Z || "$state" == X ]]
}

wait_pid_gone() {
  local pid=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    pid_gone "$pid" && return 0
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

all_recorded_brokers_gone() {
  local pid
  while read -r pid; do
    [ -n "$pid" ] || continue
    pid_gone "$pid" || return 1
  done < <(sed -nE 's/.* guardian=([0-9]+).*/\1/p' "$events" | sort -un)
}

wait_pid_terminated() {
  local pid=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    pid_terminated "$pid" && return 0
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_distinct_descendant_terminated() {
  local anchor=$1 descendant=$2
  [ "$anchor" = "$descendant" ] || wait_pid_terminated "$descendant"
}

kill_fixture_pid() {
  local pid=$1
  fixture_pid_owned "$pid" || return 1
  kill -KILL "$pid"
}

fixture="$(lem-yath_lisp_string "$here/scripts/compilation-fixture.lisp")"
if ! lem_start "$session" "$origin" --eval "(load #P$fixture)"; then
  die boot 'could not start the isolated configured Lem process'
fi
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'one' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report '^READY$' "$BOOT_TIMEOUT"; then
  die boot 'configured Lem or the compilation fixture did not become ready'
fi
pass boot 'configured Lem opened the origin buffer in an isolated tmux socket'

lem_keys "$session" F5
if ! wait_report '^STATIC PASS .*bindings=T make=yes pinned=T drain=T .*parsed=7$'; then
  die static-contract 'default command/runtime, parser coverage, or configured bindings diverged'
fi
if grep -Fq 'sb-posix:killpg' "$LEM_YATH_COMPILATION_SOURCE"; then
  die static-contract 'Lem retained a cached numeric process-group signaling path'
fi
pass static-contract 'defaults, parsers, Evil keys, and guardian-only group signaling resolve'

lem_keys "$session" F2
if ! wait_report '^NOREADER child=absent stream=closed process=nil pid=nil control=nil reader=nil state=test-no-reader$'; then
  die no-reader-cleanup 'launch cleanup without a reader did not close, reap, and clear its direct child'
fi
pass no-reader-cleanup 'the no-reader launch path closed streams, reaped its child, and cleared ownership'

# Accept the untouched initial command once through the installed wrapper.
send_chord Space c c
lem_wait_for "$session" '╭' "$WAIT_TIMEOUT" >/dev/null ||
  die default-command 'SPC c c did not open the default compilation prompt'
lem_keys "$session" Enter
# The top-level Bash must source BASH_ENV.  Make may source it again when its
# recipe shell is Bash, so require presence rather than a platform-specific count.
if ! lem_wait_for "$session" 'INNER-BASH-ENV' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'DEFAULT-MAKE-RAN' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'Compilation finished' "$WAIT_TIMEOUT" >/dev/null ||
   [ "$(grep -c '^bash-env shellopts=.*errexit' "$events")" -lt 1 ] ||
   grep -q '^shadow-' "$events"; then
  die default-command 'the isolated guardian did not preserve the hostile captured environment for the executable Make command'
fi
pass default-command 'the untouched Make default ran with the hostile environment confined to its inner shell'
lem_keys "$session" q
sleep "$KEY_DELAY"

# An ordered EXIT followed by an empty output poll is a valid drain boundary.
# Suppress the startup marker and run a command with no process output so this
# cannot accidentally take the positive-underfull path.
silent_startup_marker="$LEM_YATH_COMPILATION_ROOT/silent-startup.request"
silent_done="$LEM_YATH_COMPILATION_ROOT/silent.done"
: >"$silent_startup_marker"
rm -f "$silent_done"
printf -v silent_command ': > %q' "$silent_done"
enter_compile_command "$silent_command" ||
  die silent-drain 'could not start the silent compilation fixture'
wait_file "$silent_done" ||
  die silent-drain 'the silent command did not execute'
if ! record_until F12 '^STATE buffer=\*compilation\* .*session=FINISHED readonly=T undo=off drain-positive-underfull=0$' 3; then
  die silent-drain 'an empty post-EXIT output poll did not release and reap the broker'
fi
rm -f "$silent_startup_marker"
pass silent-drain 'an empty underfull post-EXIT poll completed and reaped a silent command'
lem_keys "$session" q
sleep "$KEY_DELAY"

# Python normally starts with SIGPIPE ignored.  The gated Bash must instead
# inherit the ordinary shell disposition so a closed pipeline terminates its
# writer with 128 + SIGPIPE rather than leaving it to report EPIPE.
sigpipe_done="$LEM_YATH_COMPILATION_ROOT/sigpipe.done"
rm -f "$sigpipe_done"
printf -v sigpipe_command \
  'yes | head -n 1 >/dev/null; [ "${PIPESTATUS[0]}" -eq 141 ] && : > %q' \
  "$sigpipe_done"
enter_compile_command "$sigpipe_command" ||
  die sigpipe 'could not start the inherited-signal fixture'
if ! wait_file "$sigpipe_done" ||
   ! lem_wait_for "$session" 'Compilation finished' "$WAIT_TIMEOUT" >/dev/null; then
  die sigpipe 'the command shell did not restore default SIGPIPE behavior'
fi
pass sigpipe 'the command shell restored default SIGPIPE behavior before exec'
lem_keys "$session" q
sleep "$KEY_DELAY"

# Make the origin buffer dirty through genuine Vi input before invoking SPC c c.
send_chord Escape j A
send_literal ' SAVED-BY-COMPILE'
send_chord Escape
primary_command=$(compiler_command primary)
if ! enter_compile_command "$primary_command"; then
  die compile-prompt 'SPC c c did not accept the replacement command'
fi
if ! lem_wait_for "$session" 'Save file .*origin\.txt.*\[y/n/!/\./q/d\]' "$WAIT_TIMEOUT" >/dev/null; then
  die save-query 'modified buffers did not trigger the configured save-some-buffers prompt'
fi
lem_keys "$session" d
if ! lem_wait_for "$session" 'SAVED-BY-COMPILE' "$WAIT_TIMEOUT" >/dev/null; then
  die save-diff 'the d action did not display the live unified diff'
fi
lem_keys "$session" y
if ! lem_wait_for "$session" 'LIVE-BEFORE-GATE run=1' "$WAIT_TIMEOUT" >/dev/null ||
   ! wait_file "$LEM_YATH_COMPILATION_ROOT/primary.ready"; then
  die live-output 'the background command did not stream before process exit'
fi
if ! grep -q '^two SAVED-BY-COMPILE$' "$origin"; then
  die save-diff 'answering y after viewing the diff did not save the origin file'
fi
primary_anchor=$(event_pid primary pgid)
primary_guardian=$(event_pid primary guardian)
primary_pid=$(event_pid primary)
if [ -z "$primary_anchor" ] || [ -z "$primary_guardian" ] ||
   [ -z "$primary_pid" ] || ! pid_running "$primary_anchor" ||
   ! pid_running "$primary_guardian" || ! pid_running "$primary_pid"; then
  die live-output 'the live marker appeared only after the process was already gone'
fi
guardian_cmdline=$(tr '\0' '\n' <"/proc/$primary_guardian/cmdline")
guardian_environment=$(tr '\0' '\n' <"/proc/$primary_guardian/environ" |
  LC_ALL=C sort)
expected_guardian_environment=$(printf '%s\n' \
  'HOME=/' \
  'LC_ALL=C' \
  'PATH=' \
  'PYTHONNOUSERSITE=1' \
  'PYTHONDONTWRITEBYTECODE=1' |
  LC_ALL=C sort)
if ! private_guardian_pid "$primary_guardian" ||
   grep -Fq "$LEM_YATH_COMPILATION_ROOT" <<<"$guardian_cmdline" ||
   grep -Fq "$LEM_YATH_COMPILATION_SENTINEL" <<<"$guardian_cmdline" ||
   [ "$guardian_environment" != "$expected_guardian_environment" ] ||
   [ -e "$LEM_YATH_COMPILATION_PYTHONPATH/guardian-poisoned" ] ||
   [ ! -e "$LEM_YATH_COMPILATION_PYTHONPATH/inner-loaded" ] ||
   ! grep -q '^command-transport-memfd=absent$' "$events" ||
   ! grep -Fq "sentinel=$LEM_YATH_COMPILATION_SENTINEL option-name=captured-option-name" "$events"; then
  die private-frame 'guardian argv/environment/descriptor isolation or inner captured Python environment diverged'
fi
pass save-and-live 'd saved, output streamed, and the guardian environment and command transport stayed isolated'

touch "$LEM_YATH_COMPILATION_ROOT/primary.release"
if ! wait_file "$LEM_YATH_COMPILATION_ROOT/utf8.ready" ||
   ! lem_wait_for "$session" 'UTF8-SPLIT-' "$WAIT_TIMEOUT" >/dev/null; then
  die utf8-split 'a valid split UTF-8 prefix did not stream while its tail was retained'
fi
if lem_capture "$session" | grep -q 'Compilation reader failed'; then
  die utf8-split 'a valid incomplete UTF-8 prefix was rejected before its tail arrived'
fi
touch "$LEM_YATH_COMPILATION_ROOT/utf8.release"
if ! lem_wait_for "$session" 'UTF8-SPLIT-λ' "$WAIT_TIMEOUT" >/dev/null; then
  die utf8-split 'a valid split UTF-8 character was not decoded after completion'
fi
if ! wait_file "$LEM_YATH_COMPILATION_ROOT/ansi.ready" ||
   ! record_until F10 '^ANSI tail=[1-9][0-9]* escape=no marker=no styled=no diagnostics=0 state=RUNNING$'; then
  die ansi-split 'a split CSI sequence was not retained invisibly across reads'
fi
touch "$LEM_YATH_COMPILATION_ROOT/ansi.release"
if ! lem_wait_for "$session" 'ANSI-SPLIT' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'Compilation finished' "$WAIT_TIMEOUT" >/dev/null ||
   ! record_until F10 '^ANSI tail=0 escape=no marker=yes styled=yes diagnostics=6 state=FINISHED$'; then
  die ansi-complete 'ANSI state, diagnostic parsing, or terminal status was incorrect'
fi
pass ansi-and-parser 'split 256-colour SGR was styled and stripped; six source formats parsed'

# Evil Collection log navigation stays in the log; Return and M-g visit source.
send_chord g j
record_state || die navigation 'could not record first g j state'
navigation_state=$(latest_state)
[[ $navigation_state == *'buffer=*compilation*'*' diag=0 '* &&
   $navigation_state == *'readonly=T undo=off '* ]] ||
  die navigation "first g j did not select diagnostic 0 in a protected log: $navigation_state"
send_chord g j
record_state || die navigation 'could not record second g j state'
[[ $(latest_state) == *' diag=1 '* ]] ||
  die navigation "second g j did not select diagnostic 1: $(latest_state)"
send_chord ']' ']'
record_state || die navigation 'could not record ]] state'
[[ $(latest_state) == *' diag=2 '* ]] ||
  die navigation "]] did not skip to the next source file: $(latest_state)"
send_chord '[' '['
record_state || die navigation 'could not record [[ state'
[[ $(latest_state) == *' diag=1 '* ]] ||
  die navigation "[[ did not return to the previous source file: $(latest_state)"
send_chord g k
record_state || die navigation 'could not record g k state'
[[ $(latest_state) == *' diag=0 '* ]] ||
  die navigation "g k did not return to diagnostic 0: $(latest_state)"
lem_keys "$session" Enter
sleep "$KEY_DELAY"
record_state || die navigation 'could not record Return visit'
[[ $(latest_state) == *'buffer=main.c '*'line=2 column=2 '* ]] ||
  die navigation "Return did not visit the exact first source location: $(latest_state)"
send_chord M-g n
record_state || die navigation 'could not record M-g n visit'
[[ $(latest_state) == *'buffer=main.c '*'line=4 column=1 '* ]] ||
  die navigation "M-g n did not visit the next compilation source: $(latest_state)"
send_chord M-g p
record_state || die navigation 'could not record M-g p visit'
[[ $(latest_state) == *'buffer=main.c '*'line=2 column=2 '* ]] ||
  die navigation "M-g p did not return to the previous source: $(latest_state)"
lem_keys "$session" F6
sleep "$KEY_DELAY"
lem_keys "$session" F11
wait_report '^PROVIDER seeded=DIAGNOSTIC$' ||
  die navigation 'fixture could not seed the lint diagnostic provider before go'
send_chord g o
lem_keys "$session" F11
if ! wait_report '^CONTRACT provider=COMPILATION readonly=T mutation=blocked unchanged=yes undo=off$'; then
  die navigation 'go did not select compilation or the result buffer allowed mutation/undo'
fi
record_state || die navigation 'could not record go display behavior'
[[ $(latest_state) == *'buffer=*compilation*'* ]] ||
  die navigation "go selected the source instead of retaining the log: $(latest_state)"

# If the remembered source window is gone, go must create a distinct source
# window.  Merely switching the sole log window and restoring its focus object
# would leave the compilation buffer undisplayed.
lem_keys "$session" F1
if ! wait_report '^WINDOW-PREP current=\*compilation\* windows=1 compilation=1 origin-deleted=yes$'; then
  die navigation-fallback 'fixture could not leave one compilation window after deleting the source window'
fi
send_chord g o
lem_keys "$session" F3
if ! wait_report '^WINDOWS current=\*compilation\* windows=2 compilation=1 source=1 distinct=yes$'; then
  die navigation-fallback 'go did not preserve the log while opening source in a distinct fallback window'
fi
record_state || die navigation-fallback 'could not inspect the retained compilation window'
[[ $(latest_state) == *'buffer=*compilation*'*'readonly=T'* ]] ||
  die navigation-fallback "go did not retain focus on the read-only compilation log: $(latest_state)"
pass navigation 'gj/gk, [[/]], RET, go (including deleted-source fallback), and M-g match compile-mode'

# gr must reuse the exact command, directory, and captured environment.
send_chord g r
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  grep -q '^primary-count=2$' "$events" && break
  sleep 0.25
done
if ! grep -q '^primary-count=2$' "$events" ||
   ! lem_wait_for "$session" 'LIVE-BEFORE-GATE run=2' "$WAIT_TIMEOUT" >/dev/null ||
   [ "$(grep -c '^start mode=primary ' "$events")" -ne 2 ] ||
   [ "$(grep -F -c " cwd=$LEM_YATH_COMPILATION_ROOT sentinel=$LEM_YATH_COMPILATION_SENTINEL option-name=captured-option-name" "$events")" -ne 2 ]; then
  die recompile 'gr did not reuse the exact command, working directory, and environment'
fi
lem_wait_for "$session" 'Compilation finished' "$WAIT_TIMEOUT" >/dev/null ||
  die recompile 'the second compilation did not terminate normally'
pass recompile 'gr reran without prompting and preserved command context exactly'

# A normally exiting leader must be reaped without waiting for EOF from a
# daemon-like descendant that retained the inherited stdout descriptor.
rm -f "$LEM_YATH_COMPILATION_ROOT/background.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
background_command=$(compiler_command background)
enter_compile_command "$background_command" ||
  die background-stdout 'could not start the inherited-stdout fixture through SPC c c'
wait_file "$LEM_YATH_COMPILATION_ROOT/background.ready" ||
  die background-stdout 'background descendant did not inherit stdout before its leader exited'
background_anchor=$(event_pid background pgid)
background_parent=$(event_pid background)
background_child=$(child_pid background-child)
if [ -z "$background_anchor" ] || [ -z "$background_parent" ] ||
   [ -z "$background_child" ] ||
   ! lem_wait_for "$session" 'BACKGROUND-LEADER-FINISHED' 3 >/dev/null ||
   ! lem_wait_for "$session" 'Compilation finished' 3 >/dev/null; then
  die background-stdout 'terminal status waited for EOF from the still-running descendant'
fi
if ! wait_pid_gone "$background_anchor" ||
   ! wait_distinct_descendant_terminated "$background_anchor" "$background_parent" ||
   ! pid_running "$background_child"; then
  die background-stdout 'the anchor was not reaped, its compiler remained live, or its stdout holder stopped'
fi
record_state || die background-stdout 'could not inspect the normally completed background session'
[[ $(latest_state) == *'session=FINISHED readonly=T undo=off '* ]] ||
  die background-stdout "background-holder completion did not reach a read-only finished state: $(latest_state)"
if ! kill_fixture_pid "$background_child" ||
   ! wait_pid_terminated "$background_child"; then
  die background-stdout 'could not terminate the separately tracked stdout-holding descendant'
fi
pass background-stdout 'command status and anchor reap were prompt while the separately tracked descendant retained stdout'

# A continuously writing out-of-group descendant must not prevent the first
# positive but underfull post-exit read from establishing a drained boundary.
rm -f "$LEM_YATH_COMPILATION_ROOT/slow-background.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
slow_background_command=$(compiler_command slow-background)
enter_compile_command "$slow_background_command" ||
  die slow-background 'could not start the slow escaped-writer fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/slow-background.ready" ||
  die slow-background 'slow escaped writer did not become ready'
slow_background_anchor=$(event_pid slow-background pgid)
slow_background_parent=$(event_pid slow-background)
slow_background_child=$(child_pid slow-child)
if [ -z "$slow_background_anchor" ] ||
   [ -z "$slow_background_parent" ] ||
   [ -z "$slow_background_child" ] ||
   ! lem_wait_for "$session" 'SLOW-BACKGROUND-LEADER-FINISHED' 3 >/dev/null ||
   ! lem_wait_for "$session" 'Compilation finished' 3 >/dev/null ||
   ! wait_pid_gone "$slow_background_anchor" ||
   ! wait_distinct_descendant_terminated \
       "$slow_background_anchor" "$slow_background_parent" ||
   ! wait_pid_terminated "$slow_background_child" ||
   ! grep -q '^slow-child-broken-pipe$' "$events"; then
  die slow-background 'continuous escaped output prevented prompt status, reap, or stream closure'
fi
record_state ||
  die slow-background 'could not inspect the live reader drain observation'
slow_background_state=$(latest_state)
if [[ ! "$slow_background_state" =~ drain-positive-underfull=[1-9][0-9]* ]]; then
  die slow-background "the live reader never invoked the positive-underfull drain predicate: $slow_background_state"
fi
pass slow-background 'the live reader observed a positive underfull burst and closed the escaped writer'

# A partial UTF-8 code point must fail promptly rather than making a character
# stream wait for the inherited descriptor to close.
rm -f "$LEM_YATH_COMPILATION_ROOT/partial.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
partial_command=$(compiler_command partial)
enter_compile_command "$partial_command" ||
  die partial-utf8 'could not start the partial UTF-8 fixture through SPC c c'
wait_file "$LEM_YATH_COMPILATION_ROOT/partial.ready" ||
  die partial-utf8 'partial UTF-8 fixture did not leave its stdout holder ready'
partial_anchor=$(event_pid partial pgid)
partial_parent=$(event_pid partial)
partial_child=$(child_pid partial-child)
if [ -z "$partial_anchor" ] || [ -z "$partial_parent" ] ||
   [ -z "$partial_child" ] ||
   ! lem_wait_for "$session" 'PARTIAL-UTF8-BEFORE' 3 >/dev/null ||
   ! lem_wait_for "$session" 'Compilation reader failed' 3 >/dev/null; then
  die partial-utf8 'an incomplete code point waited for EOF from the live descendant'
fi
if ! wait_pid_gone "$partial_anchor" ||
   ! wait_distinct_descendant_terminated "$partial_anchor" "$partial_parent" ||
   ! pid_running "$partial_child"; then
  die partial-utf8 'the anchor was not reaped promptly or its stdout holder stopped'
fi
record_state || die partial-utf8 'could not inspect the failed partial UTF-8 session'
[[ $(latest_state) == *'session=FAILED readonly=T undo=off '* ]] ||
  die partial-utf8 "partial UTF-8 did not produce a read-only failed session: $(latest_state)"
if ! kill_fixture_pid "$partial_child" ||
   ! wait_pid_terminated "$partial_child"; then
  die partial-utf8 'could not terminate the separately tracked UTF-8 stdout holder'
fi
pass partial-utf8 'strict binary decoding failed promptly without waiting for inherited stdout EOF'

# If a command kills only the guardian, its separate watchdog must terminate
# the still-live anchored command group before control EOF reports failure.
rm -f "$LEM_YATH_COMPILATION_ROOT/kill-guardian.ready" \
  "$LEM_YATH_COMPILATION_ROOT/kill-guardian.release"
lem_keys "$session" F7
sleep "$KEY_DELAY"
kill_guardian_command=$(compiler_command kill-guardian)
enter_compile_command "$kill_guardian_command" ||
  die guardian-death 'could not start the guardian-death fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/kill-guardian.ready" ||
  die guardian-death 'guardian-death fixture did not become ready'
kill_guardian_pid=$(event_pid kill-guardian guardian)
kill_guardian_anchor=$(event_pid kill-guardian pgid)
kill_guardian_child=$(event_pid kill-guardian)
[ -n "$kill_guardian_pid" ] && [ -n "$kill_guardian_anchor" ] &&
  [ -n "$kill_guardian_child" ] ||
  die guardian-death 'guardian-death fixture did not report group identities'
touch "$LEM_YATH_COMPILATION_ROOT/kill-guardian.release"
if ! lem_wait_for "$session" 'Compilation reader failed' 3 >/dev/null ||
   ! wait_pid_gone "$kill_guardian_pid" ||
   ! wait_pid_gone "$kill_guardian_anchor" ||
   ! wait_distinct_descendant_terminated \
       "$kill_guardian_anchor" "$kill_guardian_child"; then
  die guardian-death 'watchdog did not clean the anchored group after guardian death'
fi
record_state || die guardian-death 'could not inspect state after guardian death'
[[ $(latest_state) == *'session=FAILED readonly=T undo=off '* ]] ||
  die guardian-death "guardian death did not produce a read-only failed session: $(latest_state)"
pass guardian-death 'guardian-only death failed closed and its separate watchdog killed the anchored group'

# BASH_ENV runs before the anonymous command script.  Stop its immediate
# parent at that boundary: STARTED must already be queued so Lem can process
# F12 and C-c C-k even though the anchor can no longer report child status.
startup_stop_marker="$LEM_YATH_COMPILATION_ROOT/startup-stop.request"
rm -f "$LEM_YATH_COMPILATION_ROOT/startup-gate.ready"
: >"$startup_stop_marker"
lem_keys "$session" F7
sleep "$KEY_DELAY"
startup_gate_command=$(compiler_command startup-gate)
enter_compile_command "$startup_gate_command" ||
  die startup-gate 'could not start the BASH_ENV startup-gate fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/startup-gate.ready" ||
  die startup-gate 'the command body did not run after BASH_ENV stopped its parent'
startup_gate_guardian=$(event_pid startup-gate guardian)
startup_gate_anchor=$(event_pid startup-gate pgid)
startup_gate_child=$(event_pid startup-gate)
startup_stop_target=$(event_field startup-stop target)
startup_stop_command=$(event_field startup-stop command)
startup_stop_line=$(sed -n '/^startup-stop /=' "$events" | tail -1)
startup_start_line=$(sed -n '/^start mode=startup-gate /=' "$events" | tail -1)
startup_body_line=$(sed -n '/^startup-gate-body$/=' "$events" | tail -1)
if [ -z "$startup_gate_guardian" ] || [ -z "$startup_gate_anchor" ] ||
   [ -z "$startup_gate_child" ] || [ -z "$startup_stop_target" ] ||
   [ -z "$startup_stop_command" ] || [ -z "$startup_stop_line" ] ||
   [ -z "$startup_start_line" ] || [ -z "$startup_body_line" ] ||
   [ "$startup_stop_target" != "$startup_gate_anchor" ] ||
   (( startup_stop_line >= startup_start_line )) ||
   (( startup_start_line >= startup_body_line )); then
  die startup-gate 'startup stop did not precede the command script under the reported anchor'
fi
startup_anchor_state=$(awk '{print $3}' \
  "/proc/$startup_gate_anchor/stat" 2>/dev/null || true)
startup_guardian_state=$(awk '{print $3}' \
  "/proc/$startup_gate_guardian/stat" 2>/dev/null || true)
if [ "$startup_anchor_state" != T ] ||
   [ -z "$startup_guardian_state" ] || [ "$startup_guardian_state" = T ] ||
   ! pid_running "$startup_gate_child" ||
   ! pid_running "$startup_stop_command"; then
  die startup-gate 'BASH_ENV did not stop only the command-side parent'
fi
record_state ||
  die startup-gate 'Lem remained blocked in START instead of accepting F12'
startup_gate_state=$(latest_state)
if [[ "$startup_gate_state" != *'buffer=*compilation*'*'session=RUNNING'* ]]; then
  die startup-gate "the first queued command did not observe a running compilation: $startup_gate_state"
fi
rm -f "$startup_stop_marker"
[ ! -e "$startup_stop_marker" ] ||
  die startup-gate 'could not remove the one-shot startup marker'
lem_keys "$session" C-c C-k
if ! lem_wait_for "$session" 'Compilation interrupted' "$WAIT_TIMEOUT" >/dev/null ||
   ! wait_pid_gone "$startup_gate_guardian" ||
   ! wait_pid_gone "$startup_gate_anchor" ||
   ! wait_pid_gone "$startup_stop_target" ||
   ! wait_pid_terminated "$startup_gate_child" ||
   ! wait_pid_terminated "$startup_stop_command"; then
  die startup-gate 'startup-stopped anchor blocked escalation or complete reap'
fi
pass startup-gate 'STARTED returned before hostile BASH_ENV stopped the anchor; interrupt reaped all identities'

# SIGSTOP cannot be caught.  Stopping the entire command group must leave the
# guardian/control broker responsive enough to apply bounded SIGKILL.
rm -f "$LEM_YATH_COMPILATION_ROOT/stop-group.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
stop_group_command=$(compiler_command stop-group)
enter_compile_command "$stop_group_command" ||
  die stopped-group 'could not start the stopped-group fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/stop-group.ready" ||
  die stopped-group 'stopped-group fixture did not become ready'
stop_group_guardian=$(event_pid stop-group guardian)
stop_group_anchor=$(event_pid stop-group pgid)
stop_group_child=$(event_pid stop-group)
for _ in $(seq 1 100); do
  anchor_state=$(awk '{print $3}' "/proc/$stop_group_anchor/stat" 2>/dev/null || true)
  child_state=$(awk '{print $3}' "/proc/$stop_group_child/stat" 2>/dev/null || true)
  [ "$anchor_state" = T ] && [ "$child_state" = T ] && break
  sleep 0.01
done
stop_group_guardian_state=$(awk '{print $3}' \
  "/proc/$stop_group_guardian/stat" 2>/dev/null || true)
if [ "${anchor_state:-}" != T ] || [ "${child_state:-}" != T ] ||
   [ -z "$stop_group_guardian_state" ] ||
   [ "$stop_group_guardian_state" = T ]; then
  die stopped-group 'the fixture did not stop only the anchored command group'
fi
lem_keys "$session" C-c C-k
if ! lem_wait_for "$session" 'Compilation interrupted' "$WAIT_TIMEOUT" >/dev/null ||
   ! wait_pid_gone "$stop_group_guardian" ||
   ! wait_pid_gone "$stop_group_anchor" ||
   ! wait_pid_terminated "$stop_group_child"; then
  die stopped-group 'unblockable group stop prevented guardian escalation or reap'
fi
pass stopped-group 'out-of-group control escalated SIGSTOPped commands without deadlock'

# A command can target its immediate parent without knowing the command-group
# leader.  That parent may be Bash or the in-group anchor, but it must never be
# the private broker that receives Lem's bounded escalation request.
rm -f "$LEM_YATH_COMPILATION_ROOT/stop-parent.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
stop_parent_command=$(compiler_command stop-parent)
enter_compile_command "$stop_parent_command" ||
  die stopped-parent 'could not start the stopped-parent fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/stop-parent.ready" ||
  die stopped-parent 'stopped-parent fixture did not become ready'
stop_parent_guardian=$(event_pid stop-parent guardian)
stop_parent_anchor=$(event_pid stop-parent pgid)
stop_parent_child=$(event_pid stop-parent)
stop_parent_target=$(child_pid stop-parent-target)
if [ -z "$stop_parent_guardian" ] || [ -z "$stop_parent_anchor" ] ||
   [ -z "$stop_parent_child" ] || [ -z "$stop_parent_target" ] ||
   [ "$stop_parent_target" = "$stop_parent_guardian" ]; then
  die stopped-parent 'the fixture did not identify a private broker and distinct immediate parent'
fi
for _ in $(seq 1 100); do
  stop_parent_state=$(awk '{print $3}' "/proc/$stop_parent_target/stat" \
    2>/dev/null || true)
  [ "$stop_parent_state" = T ] && break
  sleep 0.01
done
stop_parent_guardian_state=$(awk '{print $3}' \
  "/proc/$stop_parent_guardian/stat" 2>/dev/null || true)
if [ "${stop_parent_state:-}" != T ] ||
   [ -z "$stop_parent_guardian_state" ] ||
   [ "$stop_parent_guardian_state" = T ]; then
  die stopped-parent 'the command did not stop only its immediate in-group parent'
fi
lem_keys "$session" C-c C-k
if ! lem_wait_for "$session" 'Compilation interrupted' "$WAIT_TIMEOUT" >/dev/null ||
   ! wait_pid_gone "$stop_parent_guardian" ||
   ! wait_pid_gone "$stop_parent_anchor" ||
   ! wait_pid_terminated "$stop_parent_child" ||
   ! wait_pid_terminated "$stop_parent_target"; then
  die stopped-parent 'a stopped immediate parent blocked broker escalation or reap'
fi
pass stopped-parent 'stopping Bash/anchor left the private broker responsive through bounded reap'

# The inner Bash must not inherit the SIGINT ignore disposition that Bash
# assigns to an asynchronous command when job control is disabled.  This
# fixture tests SIGINT without installing a handler, so it must exit well
# before the three-second guardian escalation deadline.
rm -f "$LEM_YATH_COMPILATION_ROOT/default-interrupt.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
default_interrupt_command=$(compiler_command default-interrupt)
enter_compile_command "$default_interrupt_command" ||
  die default-interrupt 'could not start the default-disposition interrupt fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/default-interrupt.ready" ||
  die default-interrupt 'default-disposition fixture did not become ready'
default_interrupt_anchor=$(event_pid default-interrupt pgid)
default_interrupt_child=$(event_pid default-interrupt)
if [ -z "$default_interrupt_anchor" ] ||
   [ -z "$default_interrupt_child" ] ||
   ! grep -q '^default-interrupt-disposition=active$' "$events"; then
  die default-interrupt 'the command inherited an ignored SIGINT disposition'
fi
lem_keys "$session" C-c C-k
for _ in $(seq 1 100); do
  pid_terminated "$default_interrupt_child" && break
  sleep 0.01
done
if ! pid_terminated "$default_interrupt_child"; then
  die default-interrupt 'the ordinary command survived until guardian escalation'
fi
sleep 0.2
if ! pid_running "$default_interrupt_anchor"; then
  die default-interrupt 'the anchor did not reserve the PGID during grace'
fi
if ! lem_wait_for "$session" 'Compilation interrupted' "$WAIT_TIMEOUT" >/dev/null ||
   ! wait_pid_gone "$default_interrupt_anchor"; then
  die default-interrupt 'default-disposition interrupt did not finish and reap its anchor'
fi
pass default-interrupt 'ordinary commands receive SIGINT while the anchor safely reserves its PGID'

# Even when every command member honors SIGINT, the anchor must remain the
# live group leader until escalation, reserving the PGID against reuse.
rm -f "$LEM_YATH_COMPILATION_ROOT/leader-only.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
leader_only_command=$(compiler_command leader-only)
enter_compile_command "$leader_only_command" ||
  die interrupt-ownership 'could not start the leader-only interrupt fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/leader-only.ready" ||
  die interrupt-ownership 'leader-only interrupt fixture did not become ready'
leader_only_anchor=$(event_pid leader-only pgid)
leader_only_child=$(event_pid leader-only)
[ -n "$leader_only_anchor" ] && [ -n "$leader_only_child" ] ||
  die interrupt-ownership 'leader-only fixture did not report anchor and child identities'
lem_keys "$session" C-c C-k
for _ in $(seq 1 100); do
  grep -q '^leader-only-sigint ' "$events" && break
  sleep 0.01
done
if ! grep -q '^leader-only-sigint ' "$events" ||
   ! wait_pid_terminated "$leader_only_child"; then
  die interrupt-ownership 'the command child did not honor the group SIGINT'
fi
sleep 0.2
if ! pid_running "$leader_only_anchor"; then
  die interrupt-ownership 'the anchor released its PGID during the grace period'
fi
if ! lem_wait_for "$session" 'Compilation interrupted' "$WAIT_TIMEOUT" >/dev/null ||
   ! wait_pid_gone "$leader_only_anchor"; then
  die interrupt-ownership 'anchor escalation did not reach a terminal state'
fi
pass interrupt-ownership 'a live anchor reserved the PGID after its command child exited'

# C-c C-k signals the whole group and escalates for an uncooperative child.
lem_keys "$session" F7
sleep "$KEY_DELAY"
interrupt_command=$(compiler_command interrupt)
enter_compile_command "$interrupt_command" ||
  die interrupt 'could not start the interrupt fixture through SPC c c'
wait_file "$LEM_YATH_COMPILATION_ROOT/interrupt.ready" ||
  die interrupt 'interrupt fixture did not report both group members ready'
interrupt_broker=$(event_pid interrupt guardian)
interrupt_anchor=$(event_pid interrupt pgid)
interrupt_parent=$(event_pid interrupt)
interrupt_child=$(child_pid interrupt-child)
lem_keys "$session" C-c C-k
for _ in $(seq 1 50); do
  grep -q '^interrupt-parent-sigint ' "$events" && break
  sleep 0.01
done
if ! grep -q '^interrupt-parent-sigint ' "$events"; then
  die interrupt 'the compiler child did not receive SIGINT'
fi
sleep 0.2
if ! pid_running "$interrupt_broker" || ! pid_running "$interrupt_anchor" ||
   ! pid_running "$interrupt_child"; then
  die interrupt 'the broker, anchor, or resistant child vanished during the grace period'
fi
if ! lem_wait_for "$session" 'Compilation interrupted' "$WAIT_TIMEOUT" >/dev/null; then
  die interrupt 'C-c C-k did not produce an interrupted terminal state'
fi
if ! grep -q '^interrupt-parent-sigint ' "$events" ||
   ! grep -q '^interrupt-child-sigint ' "$events" ||
   ! wait_pid_gone "$interrupt_broker" ||
   ! wait_pid_gone "$interrupt_anchor" ||
   ! wait_distinct_descendant_terminated "$interrupt_anchor" "$interrupt_parent" ||
   ! wait_pid_terminated "$interrupt_child"; then
  die interrupt 'SIGINT/escalation did not reap the broker and anchor or terminate their descendants'
fi
pass interrupt 'C-c C-k honored SIGINT grace, reaped its broker and anchor, and terminated its descendant'

# Real replacement plus an explicitly late callback proves stale ownership guards.
rm -f "$LEM_YATH_COMPILATION_ROOT/old.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
old_command=$(compiler_command old)
enter_compile_command "$old_command" ||
  die replacement 'could not start the old long-running compilation'
wait_file "$LEM_YATH_COMPILATION_ROOT/old.ready" ||
  die replacement 'old compilation did not become ready'
old_broker=$(event_pid old guardian)
old_anchor=$(event_pid old pgid)
old_parent=$(event_pid old)
old_child=$(child_pid old-child)
lem_keys "$session" F8
wait_report '^CAPTURE state=RUNNING$' ||
  die replacement 'fixture did not capture the old session identity'
lem_keys "$session" F7
sleep "$KEY_DELAY"
fresh_command=$(compiler_command fresh)
enter_compile_command "$fresh_command" ||
  die replacement 'could not enter the fresh replacement command'
if ! lem_wait_for "$session" 'A compilation process is running; kill it' "$WAIT_TIMEOUT" >/dev/null; then
  die replacement 'running-process replacement did not require confirmation'
fi
lem_keys "$session" y
if ! lem_wait_for "$session" 'FRESH-ONLY' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'Compilation finished' "$WAIT_TIMEOUT" >/dev/null ||
   ! wait_pid_gone "$old_broker" ||
   ! wait_pid_gone "$old_anchor" ||
   ! wait_distinct_descendant_terminated "$old_anchor" "$old_parent" ||
   ! wait_pid_terminated "$old_child"; then
  die replacement 'confirmed replacement did not reap the old broker and anchor, terminate its descendant, and retain fresh output'
fi
lem_keys "$session" F9
if ! wait_report '^STALE active-state=FINISHED fresh=yes injected=no old-status=no$'; then
  die stale-events 'a queued callback from the replaced session altered the reused buffer'
fi
pass replacement 'confirmed replacement killed its tree and rejected late old-session events'

lem_keys "$session" F4
if ! wait_report '^RELOAD command=yes leader=LEM-YATH-COMPILE next=LEM-YATH-NEXT-ERROR kill-hook=1 exit-hook=1$'; then
  die reload 'loading compilation.lisp twice lost commands, bindings, or hook uniqueness'
fi
pass reload 'two source reloads are cleanup-safe and idempotent'

# Killing the compilation buffer must synchronously join even when an escaped
# descendant continuously writes to the inherited output descriptor.
rm -f "$LEM_YATH_COMPILATION_ROOT/escaped-running.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
escaped_running_command=$(compiler_command escaped-running)
enter_compile_command "$escaped_running_command" ||
  die buffer-kill 'could not start the buffer-kill process fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/escaped-running.ready" ||
  die buffer-kill 'buffer-kill fixture did not become ready'
kill_broker=$(event_pid escaped-running guardian)
kill_anchor=$(event_pid escaped-running pgid)
kill_parent=$(event_pid escaped-running)
kill_child=$(child_pid escaped-child)
capture_before=$(grep -c '^CAPTURE ' "$report" || true)
lem_keys "$session" F8
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  (( $(grep -c '^CAPTURE ' "$report" || true) > capture_before )) && break
  sleep 0.25
done
if (( $(grep -c '^CAPTURE ' "$report" || true) <= capture_before )); then
  die buffer-kill 'fixture did not retain the live session handles before deletion'
fi
send_chord Space b k
# This is deliberately the next queued fixture command.  It can run only
# after the buffer-delete hook (including its synchronous reader join) returns.
lem_keys "$session" F2
if ! wait_report '^CLEANUP old=yes active=none process=nil saved-process=dead pid=nil control=nil reader=nil saved-reader=dead state=BUFFER-KILLED buffer=deleted$'; then
  die buffer-kill 'the command immediately after deletion observed incomplete synchronous teardown'
fi
if ! wait_pid_gone "$kill_broker" ||
   ! wait_pid_gone "$kill_anchor" ||
   ! wait_distinct_descendant_terminated "$kill_anchor" "$kill_parent" ||
   ! wait_pid_terminated "$kill_child" ||
   ! grep -q '^escaped-child-broken-pipe$' "$events"; then
  die buffer-kill 'SPC b k did not join, reap, or close the escaped writer promptly'
fi
pass buffer-kill 'the very next command saw joined teardown despite continuous escaped output'

# Reload while a process owns the buffer, not merely after it has finished.
rm -f "$LEM_YATH_COMPILATION_ROOT/old.ready"
enter_compile_command "$old_command" ||
  die active-reload 'could not start the active-reload process fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/old.ready" ||
  die active-reload 'active-reload fixture did not become ready'
reload_broker=$(event_pid old guardian)
reload_anchor=$(event_pid old pgid)
reload_parent=$(event_pid old)
reload_child=$(child_pid old-child)
reload_before=$(grep -c '^RELOAD ' "$report" || true)
lem_keys "$session" F4
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  (( $(grep -c '^RELOAD ' "$report" || true) > reload_before )) && break
  sleep 0.25
done
if (( $(grep -c '^RELOAD ' "$report" || true) <= reload_before )) ||
   ! wait_pid_gone "$reload_broker" ||
   ! wait_pid_gone "$reload_anchor" ||
   ! wait_distinct_descendant_terminated "$reload_anchor" "$reload_parent" ||
   ! wait_pid_terminated "$reload_child"; then
  die active-reload 'source reload did not reap its anchor and terminate its descendant'
fi
pass active-reload 'source reload reaped its anchor and terminated its descendant before replacing closures'

# The editor-exit hook is exercised last because the real ncurses process ends.
rm -f "$LEM_YATH_COMPILATION_ROOT/old.ready"
lem_keys "$session" F7
sleep "$KEY_DELAY"
enter_compile_command "$old_command" ||
  die editor-exit 'could not start the editor-exit process fixture'
wait_file "$LEM_YATH_COMPILATION_ROOT/old.ready" ||
  die editor-exit 'editor-exit fixture did not become ready'
exit_broker=$(event_pid old guardian)
exit_anchor=$(event_pid old pgid)
exit_parent=$(event_pid old)
exit_child=$(child_pid old-child)
send_chord C-x C-c
session_closed=0
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  if ! tmux_cmd has-session -t "$session" 2>/dev/null; then
    session_closed=1
    break
  fi
  sleep 0.25
done
if [ "$session_closed" -ne 1 ] ||
   ! wait_pid_gone "$exit_broker" ||
   ! wait_pid_gone "$exit_anchor" ||
   ! wait_distinct_descendant_terminated "$exit_anchor" "$exit_parent" ||
   ! wait_pid_terminated "$exit_child" ||
   ! all_recorded_brokers_gone; then
  die editor-exit 'C-x C-c did not close Lem, reap every broker and anchor, and terminate the descendant'
fi
pass editor-exit 'C-x C-c reaped its anchor and left no running compilation descendants'

printf 'All compilation tests passed.\n'
