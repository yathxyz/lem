#!/usr/bin/env bash
# Real-ncurses acceptance coverage for the configured direnv lifecycle.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-direnv-$$}"
if ! root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-direnv.XXXXXX")"; then
  echo "Could not create the direnv test directory." >&2
  exit 1
fi
case "$root" in
  "" | /)
    echo "Refusing unsafe direnv test directory: $root" >&2
    exit 1
    ;;
esac

session="lem-yath-direnv-$id"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export XDG_CONFIG_HOME="$root/config"
export XDG_DATA_HOME="$root/data"
export WORKDIR="$root/work"
export LEM_HOME="$root/lem-home/"
export LEM_YATH_SOURCE="${LEM_YATH_SOURCE:-$here/lem-yath}"
export LEM_YATH_DIRENV_REPORT="$root/report"
export LEM_YATH_DIRENV_EVENTS="$root/direnv-events"
export LEM_YATH_DIRENV_WRAPPER_MODE_FILE="$root/wrapper-mode"
export LEM_YATH_DIRENV_BLOCKED_EXECUTED="$root/blocked-executed"
export LEM_YATH_DIRENV_INJECTION_SENTINEL="$root/injected-by-shell"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" \
  "$WORKDIR" "$LEM_HOME" "$root/wrapper-bin"
: >"$LEM_YATH_DIRENV_REPORT"
: >"$LEM_YATH_DIRENV_EVENTS"
printf '%s\n' normal >"$LEM_YATH_DIRENV_WRAPPER_MODE_FILE"

source "$here/scripts/tui-driver.sh"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-direnv.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe direnv-test cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

failed=0
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"

pass() { printf 'PASS  %-31s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-31s %s\n' "$1" "$2" >&2
}

dump_failure_context() {
  printf '%s\n' '--- Lem screen ---' >&2
  lem_capture "$session" >&2 || true
  printf '%s\n' '--- fixture report ---' >&2
  sed -n '1,260p' "$LEM_YATH_DIRENV_REPORT" >&2 || true
  printf '%s\n' '--- direnv wrapper events ---' >&2
  sed -n '1,160p' "$LEM_YATH_DIRENV_EVENTS" >&2 || true
}

die() {
  fail "$1" "$2"
  dump_failure_context
  exit 1
}

for program in bash direnv timeout; do
  if ! command -v "$program" >/dev/null 2>&1; then
    printf 'FAIL  %-31s %s\n' prerequisites \
      "$program is required by direnv-test.sh" >&2
    exit 1
  fi
done

bash_program="$(command -v bash)"
real_direnv="$(command -v direnv)"
export LEM_YATH_REAL_DIRENV="$real_direnv"

# The first directory deliberately contains spaces and shell metacharacters.
# A direct argv + process-directory implementation treats every byte as a
# pathname; an interpolated shell command could create the isolated sentinel.
export LEM_YATH_DIRENV_A_DIR="$root/project A \$(touch \"\$LEM_YATH_DIRENV_INJECTION_SENTINEL\")"
export LEM_YATH_DIRENV_NESTED_DIR="$LEM_YATH_DIRENV_A_DIR/nested environment"
export LEM_YATH_DIRENV_B_DIR="$root/project B"
export LEM_YATH_DIRENV_BACKGROUND_DIR="$root/background project"
export LEM_YATH_DIRENV_THROW_DIR="$root/throw project"
export LEM_YATH_DIRENV_OUTSIDE_DIR="$root/outside"
export LEM_YATH_DIRENV_BLOCKED_DIR="$root/blocked project"
export LEM_YATH_DIRENV_TIMEOUT_DIR="$root/timeout project"
export LEM_YATH_DIRENV_MALFORMED_DIR="$root/malformed project"

export LEM_YATH_DIRENV_A_FILE="$LEM_YATH_DIRENV_A_DIR/initial.py"
export LEM_YATH_DIRENV_A_SIBLING="$LEM_YATH_DIRENV_A_DIR/sibling.txt"
export LEM_YATH_DIRENV_NESTED_FILE="$LEM_YATH_DIRENV_NESTED_DIR/nested.txt"
export LEM_YATH_DIRENV_B_FILE="$LEM_YATH_DIRENV_B_DIR/b.txt"
export LEM_YATH_DIRENV_BACKGROUND_FILE="$LEM_YATH_DIRENV_BACKGROUND_DIR/background.txt"
export LEM_YATH_DIRENV_THROW_FILE="$LEM_YATH_DIRENV_THROW_DIR/throw.direnvthrow"
export LEM_YATH_DIRENV_OUTSIDE_FILE="$LEM_YATH_DIRENV_OUTSIDE_DIR/outside.txt"
export LEM_YATH_DIRENV_BLOCKED_FILE="$LEM_YATH_DIRENV_BLOCKED_DIR/blocked.txt"
export LEM_YATH_DIRENV_TIMEOUT_FILE="$LEM_YATH_DIRENV_TIMEOUT_DIR/timeout.txt"
export LEM_YATH_DIRENV_MALFORMED_FILE="$LEM_YATH_DIRENV_MALFORMED_DIR/malformed.txt"

mkdir -p "$LEM_YATH_DIRENV_A_DIR/bin" \
  "$LEM_YATH_DIRENV_NESTED_DIR/bin" \
  "$LEM_YATH_DIRENV_B_DIR/bin" \
  "$LEM_YATH_DIRENV_BACKGROUND_DIR/bin" \
  "$LEM_YATH_DIRENV_THROW_DIR/bin" \
  "$LEM_YATH_DIRENV_OUTSIDE_DIR" \
  "$LEM_YATH_DIRENV_BLOCKED_DIR/bin" \
  "$LEM_YATH_DIRENV_TIMEOUT_DIR/bin" \
  "$LEM_YATH_DIRENV_MALFORMED_DIR/bin"

printf 'print("initial")\n' >"$LEM_YATH_DIRENV_A_FILE"
printf 'sibling\n' >"$LEM_YATH_DIRENV_A_SIBLING"
printf 'nested\n' >"$LEM_YATH_DIRENV_NESTED_FILE"
printf 'project b\n' >"$LEM_YATH_DIRENV_B_FILE"
printf 'background\n' >"$LEM_YATH_DIRENV_BACKGROUND_FILE"
printf 'throw\n' >"$LEM_YATH_DIRENV_THROW_FILE"
printf 'outside\n' >"$LEM_YATH_DIRENV_OUTSIDE_FILE"
printf 'blocked\n' >"$LEM_YATH_DIRENV_BLOCKED_FILE"
printf 'timeout\n' >"$LEM_YATH_DIRENV_TIMEOUT_FILE"
printf 'malformed\n' >"$LEM_YATH_DIRENV_MALFORMED_FILE"

write_tool() {
  local directory=$1 value=$2
  {
    printf '#!%s\n' "$bash_program"
    printf 'printf "%%s\\n" %q\n' "$value"
  } >"$directory/bin/direnv-project-tool"
  chmod +x "$directory/bin/direnv-project-tool"
}

write_tool "$LEM_YATH_DIRENV_A_DIR" A
write_tool "$LEM_YATH_DIRENV_NESTED_DIR" NESTED
write_tool "$LEM_YATH_DIRENV_B_DIR" B
write_tool "$LEM_YATH_DIRENV_BACKGROUND_DIR" BACKGROUND
write_tool "$LEM_YATH_DIRENV_THROW_DIR" THROW
write_tool "$LEM_YATH_DIRENV_BLOCKED_DIR" BLOCKED
write_tool "$LEM_YATH_DIRENV_TIMEOUT_DIR" TIMEOUT
write_tool "$LEM_YATH_DIRENV_MALFORMED_DIR" MALFORMED

printf '%s\n' \
  'export LEM_YATH_DIRENV_CASE=A' \
  'export LEM_YATH_DIRENV_BASE=A' \
  'unset LEM_YATH_DIRENV_DROP' \
  'unset LEM_YATH_DIRENV_NESTED' \
  'unset LEM_YATH_DIRENV_BLOCKED' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_A_DIR/.envrc"

printf '%s\n' \
  'export LEM_YATH_DIRENV_CASE=NESTED' \
  'export LEM_YATH_DIRENV_BASE=NESTED' \
  'export LEM_YATH_DIRENV_DROP=NESTED-DROP' \
  'export LEM_YATH_DIRENV_NESTED=yes' \
  'unset LEM_YATH_DIRENV_BLOCKED' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_NESTED_DIR/.envrc"

printf '%s\n' \
  'export LEM_YATH_DIRENV_CASE=B' \
  'export LEM_YATH_DIRENV_BASE=B' \
  'export LEM_YATH_DIRENV_DROP=B-DROP' \
  'unset LEM_YATH_DIRENV_NESTED' \
  'unset LEM_YATH_DIRENV_BLOCKED' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_B_DIR/.envrc"

printf '%s\n' \
  'export LEM_YATH_DIRENV_CASE=BACKGROUND' \
  'export LEM_YATH_DIRENV_BASE=BACKGROUND' \
  'export LEM_YATH_DIRENV_DROP=BACKGROUND-DROP' \
  'unset LEM_YATH_DIRENV_NESTED' \
  'unset LEM_YATH_DIRENV_BLOCKED' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_BACKGROUND_DIR/.envrc"

printf '%s\n' \
  'export LEM_YATH_DIRENV_CASE=THROW' \
  'export LEM_YATH_DIRENV_BASE=THROW' \
  'export LEM_YATH_DIRENV_DROP=THROW-DROP' \
  'unset LEM_YATH_DIRENV_NESTED' \
  'unset LEM_YATH_DIRENV_BLOCKED' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_THROW_DIR/.envrc"

printf '%s\n' BLOCKED >"$LEM_YATH_DIRENV_BLOCKED_DIR/value"
printf '%s\n' \
  'watch_file "$PWD/value"' \
  'touch "$LEM_YATH_DIRENV_BLOCKED_EXECUTED"' \
  'export LEM_YATH_DIRENV_CASE="$(cat "$PWD/value")"' \
  'export LEM_YATH_DIRENV_BASE=BLOCKED' \
  'unset LEM_YATH_DIRENV_DROP' \
  'unset LEM_YATH_DIRENV_NESTED' \
  'export LEM_YATH_DIRENV_BLOCKED=yes' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_BLOCKED_DIR/.envrc"

printf '%s\n' \
  'export LEM_YATH_DIRENV_CASE=TIMEOUT' \
  'export LEM_YATH_DIRENV_BASE=TIMEOUT' \
  'export LEM_YATH_DIRENV_DROP=TIMEOUT-DROP' \
  'unset LEM_YATH_DIRENV_NESTED' \
  'unset LEM_YATH_DIRENV_BLOCKED' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_TIMEOUT_DIR/.envrc"

printf '%s\n' \
  'export LEM_YATH_DIRENV_CASE=MALFORMED' \
  'export LEM_YATH_DIRENV_BASE=MALFORMED' \
  'export LEM_YATH_DIRENV_DROP=MALFORMED-DROP' \
  'unset LEM_YATH_DIRENV_NESTED' \
  'unset LEM_YATH_DIRENV_BLOCKED' \
  'PATH_add "$PWD/bin"' \
  >"$LEM_YATH_DIRENV_MALFORMED_DIR/.envrc"

# Child observations use a direct absolute program and therefore prove that
# the process environment, not merely Lisp's getenv lookup, was updated.
export LEM_YATH_DIRENV_CHILD="$root/record-child-environment"
{
  printf '#!%s\n' "$bash_program"
  printf '%s\n' \
    'printf "%s/%s/%s\n" "${LEM_YATH_DIRENV_CASE:-unset}" "${LEM_YATH_DIRENV_BASE:-unset}" "${LEM_YATH_DIRENV_DROP:-unset}"'
} >"$LEM_YATH_DIRENV_CHILD"
chmod +x "$LEM_YATH_DIRENV_CHILD"

# Wrap the real binary only to count/directly inspect invocations and to make
# one later export return malformed JSON.  Every normal call execs the real
# flake-pinned direnv with its original argv.
direnv_wrapper="$root/wrapper-bin/direnv"
{
  printf '#!%s\n' "$bash_program"
  printf '%s\n' \
    'set -uo pipefail' \
    '{' \
    '  printf "CALL cwd=%s argc=%d argv=" "$PWD" "$#"' \
    '  separator=' \
    '  for argument in "$@"; do' \
    '    printf "%s%s" "$separator" "$argument"' \
    '    separator="|"' \
    '  done' \
    '  printf "\n"' \
    '} >>"$LEM_YATH_DIRENV_EVENTS"' \
    'mode=$(sed -n "1p" "$LEM_YATH_DIRENV_WRAPPER_MODE_FILE" 2>/dev/null || true)' \
    'if [ "$mode" = malformed ] && [ "${1:-}" = export ] && [ "${2:-}" = json ]; then' \
    '  printf "{\"LEM_YATH_DIRENV_CASE\":"' \
    '  exit 0' \
    'fi' \
    'if [ "$mode" = slow ] && [ "${1:-}" = export ] && [ "${2:-}" = json ]; then' \
    '  sleep 5' \
    'fi' \
    'exec "$LEM_YATH_REAL_DIRENV" "$@"'
} >"$direnv_wrapper"
chmod +x "$direnv_wrapper"

# Baseline values must be restored whenever no envrc applies.
# The invoking Codex/dev shell may itself be inside direnv.  Its transition
# state describes a different process baseline and must not leak into this
# hermetic editor process; retain the runner PATH itself as the new baseline.
for variable in ${!DIRENV_@}; do
  unset "$variable"
done
export LEM_YATH_DIRENV_BASE=baseline
export LEM_YATH_DIRENV_DROP=baseline-drop
unset LEM_YATH_DIRENV_CASE LEM_YATH_DIRENV_NESTED LEM_YATH_DIRENV_BLOCKED || true

allow_directory() {
  (cd "$1" && "$real_direnv" allow >/dev/null 2>&1)
}

for directory in "$LEM_YATH_DIRENV_A_DIR" \
                 "$LEM_YATH_DIRENV_NESTED_DIR" \
                 "$LEM_YATH_DIRENV_B_DIR" \
                 "$LEM_YATH_DIRENV_BACKGROUND_DIR" \
                 "$LEM_YATH_DIRENV_THROW_DIR" \
                 "$LEM_YATH_DIRENV_TIMEOUT_DIR" \
                 "$LEM_YATH_DIRENV_MALFORMED_DIR"; do
  if ! allow_directory "$directory"; then
    printf 'FAIL  %-31s %s\n' prerequisites \
      "could not authorize fixture envrc in $directory" >&2
    exit 1
  fi
done

export PATH="$root/wrapper-bin:$PATH"

report_count() {
  grep -cE "$1" "$LEM_YATH_DIRENV_REPORT" 2>/dev/null || true
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

export_count() {
  grep -c ' argc=2 argv=export|json$' "$LEM_YATH_DIRENV_EVENTS" 2>/dev/null || true
}

run_mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.45
  lem_keys "$session" Enter
  sleep 0.35
}

run_and_wait() {
  local command=$1 pattern=$2 before
  before=$(report_count "$pattern")
  run_mx "$command" &&
    wait_report_count "$pattern" "$((before + 1))"
}

state_line() {
  grep "^STATE label=$1 " "$LEM_YATH_DIRENV_REPORT" 2>/dev/null | tail -1
}

assert_state() {
  local name=$1 label=$2 line expected
  shift 2
  line=$(state_line "$label")
  if [ -z "$line" ]; then
    fail "$name" "no state was recorded for $label"
    return
  fi
  for expected in "$@"; do
    if [[ "$line" != *"$expected"* ]]; then
      fail "$name" "expected [$expected] in [$line]"
      return
    fi
  done
  pass "$name" "$line"
}

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/direnv-fixture.lisp")"
config_lisp="$(lem-yath_lisp_string "$LEM_YATH_SOURCE/init.lisp")"
printf '(load #P%s)\n(load #P%s)\n' "$config_lisp" "$fixture_lisp" \
  >"$LEM_HOME/init.lisp"

lem_start "$session" "$LEM_YATH_DIRENV_A_FILE"
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^FIXTURE READY$' 1 "$BOOT_TIMEOUT" ||
   ! wait_report_count '^STATE label=mode-initial ' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not reach the initial Python mode hook'
fi
pass boot 'real ncurses Lem opened the command-line Python file'

assert_state pre-mode-direnv mode-initial \
  'file=yes' 'mode=PYTHON-MODE' 'relevant=A' 'active=A' \
  'case=A' 'base=A' 'drop=unset' 'tool=A' 'child=A/A/unset' \
  'status=0' 'error=none'

if run_and_wait lem-yath-test-direnv-static '^STATIC '; then
  static=$(grep '^STATIC ' "$LEM_YATH_DIRENV_REPORT" | tail -1)
  hooks=$(grep '^HOOKS label=initial ' "$LEM_YATH_DIRENV_REPORT" | tail -1)
  if [[ "$static" == *'update-command=yes allow-command=yes relevant=yes maybe=yes update-directory=yes active-var=yes program=yes timeout=yes empty-export=yes mode-hooks=1'* ]] &&
     [[ "$hooks" == 'HOOKS label=initial find=0 switch=1 post=1' ]]; then
    pass api-and-hooks 'the around method owns file opens and selected-buffer hooks are unique'
  else
    fail api-and-hooks "static=[$static] hooks=[$hooks]"
  fi
else
  fail api-and-hooks 'the static production probe did not run'
fi

if grep -Fq "CALL cwd=$LEM_YATH_DIRENV_A_DIR argc=2 argv=export|json" \
     "$LEM_YATH_DIRENV_EVENTS" &&
   [ ! -e "$LEM_YATH_DIRENV_INJECTION_SENTINEL" ]; then
  pass argv-and-directory-safety \
    'the weird directory reached real direnv without shell evaluation'
else
  fail argv-and-directory-safety 'direnv argv/cwd was altered or shell text executed'
fi

# Ordinary commands, a sibling file, and module reloads in one directory must
# reuse the exact-directory cache and leave one copy of every hook.
before=$(export_count)
if run_and_wait lem-yath-test-direnv-open-a-sibling \
     '^STATE label=a-sibling ';
then
  assert_state same-directory-state a-sibling \
    'relevant=A' 'active=A' 'case=A' 'tool=A' 'child=A/A/unset'
else
  fail same-directory-state 'could not open the sibling file'
fi
lem_keys "$session" j
lem_keys "$session" k
sleep 0.35
after=$(export_count)
if [ "$after" -eq "$before" ]; then
  pass same-directory-cache 'sibling switches and ordinary commands did not rerun direnv'
else
  fail same-directory-cache "export count changed from $before to $after"
fi

if ! run_and_wait lem-yath-test-direnv-use-custom-preferences \
       '^PREFERENCES label=custom '; then
  fail reload-preferences 'could not set nondefault reload preferences'
fi
before=$(export_count)
if run_and_wait lem-yath-test-direnv-reload '^HOOKS label=reload ';
then
  hooks=$(grep '^HOOKS label=reload ' "$LEM_YATH_DIRENV_REPORT" | tail -1)
  preferences=$(grep '^PREFERENCES label=reload ' \
    "$LEM_YATH_DIRENV_REPORT" | tail -1)
  if [ "$hooks" = 'HOOKS label=reload find=0 switch=1 post=1' ] &&
     [ "$preferences" = \
       'PREFERENCES label=reload timeout=17 summary=no paths=no' ] &&
     [ "$(export_count)" -eq "$before" ]; then
    pass reload-idempotence \
      'two source reloads preserved hooks, cache, timeout, and summary preferences'
  else
    fail reload-idempotence \
      "hooks=[$hooks] preferences=[$preferences] exports=$before->$(export_count)"
  fi
else
  fail reload-idempotence 'the production reload probe did not complete'
fi
if ! run_and_wait lem-yath-test-direnv-restore-preferences \
       '^PREFERENCES label=restored '; then
  fail reload-preferences 'could not restore production preference defaults'
fi

if run_and_wait lem-yath-test-direnv-open-nested '^STATE label=nested ';
then
  assert_state nested-envrc nested \
    'relevant=NESTED' 'active=NESTED' 'case=NESTED' 'base=NESTED' \
    'drop=NESTED-DROP' 'nested=yes' 'tool=NESTED' \
    'child=NESTED/NESTED/NESTED-DROP'
else
  fail nested-envrc 'could not enter the nested envrc'
fi

if run_and_wait lem-yath-test-direnv-switch-project-b '^STATE label=b ';
then
  assert_state project-transition b \
    'relevant=B' 'active=B' 'case=B' 'base=B' 'drop=B-DROP' \
    'nested=unset' 'tool=B' 'child=B/B/B-DROP'
else
  fail project-transition 'could not enter project B'
fi

before=$(export_count)
if run_and_wait lem-yath-test-direnv-background-find \
     '^STATE label=background-retained ';
then
  background=$(grep '^BACKGROUND ' "$LEM_YATH_DIRENV_REPORT" | tail -1)
  assert_state background-find-retains-selection background-retained \
    'file=yes' 'relevant=B' 'active=B' 'case=B' 'base=B' 'drop=B-DROP' \
    'tool=B' 'child=B/B/B-DROP' 'status=0' 'error=none'
  if [ "$background" = \
       'BACKGROUND created=yes selected=no file=yes' ] &&
     [ "$(export_count)" -eq "$before" ]; then
    pass background-find-no-retarget \
      'an unselected find-file-buffer neither switched nor exported an environment'
  else
    fail background-find-no-retarget \
      "background=[$background] exports=$before->$(export_count)"
  fi
else
  fail background-find-retains-selection 'the background file probe did not run'
fi

before=$(export_count)
if run_and_wait lem-yath-test-direnv-throwing-open \
     '^STATE label=throw-restored ';
then
  throw_hook=$(grep '^THROW-HOOK ' "$LEM_YATH_DIRENV_REPORT" | tail -1)
  throw_result=$(grep '^THROW caught=' "$LEM_YATH_DIRENV_REPORT" | tail -1)
  assert_state throwing-hook-restores throw-restored \
    'file=yes' 'relevant=B' 'active=B' 'case=B' 'base=B' 'drop=B-DROP' \
    'tool=B' 'child=B/B/B-DROP' 'status=0' 'error=none'
  if [ "$throw_hook" = \
       'THROW-HOOK case=THROW base=THROW tool=THROW child=THROW/THROW/THROW-DROP' ] &&
     [ "$throw_result" = 'THROW caught=yes' ] &&
     [ "$(export_count)" -eq "$((before + 1))" ]; then
    pass throwing-hook-provisional \
      'the target mode hook saw its env and unwind-protect restored project B'
  else
    fail throwing-hook-provisional \
      "hook=[$throw_hook] result=[$throw_result] exports=$before->$(export_count)"
  fi
else
  fail throwing-hook-restores 'the throwing execute-find-file probe did not run'
fi

if run_and_wait lem-yath-test-direnv-open-directory '^STATE label=directory-a ';
then
  assert_state directory-buffer directory-a \
    'file=no' 'mode=DIRECTORY-MODE' 'relevant=A' 'active=A' \
    'case=A' 'tool=A' 'child=A/A/unset'
else
  fail directory-buffer 'the real directory-mode buffer did not open'
fi

if run_and_wait lem-yath-test-direnv-open-listener '^STATE label=listener-b ';
then
  assert_state listener-buffer listener-b \
    'file=no' 'listener=yes' 'relevant=B' 'active=B' \
    'case=B' 'tool=B' 'child=B/B/B-DROP'
else
  fail listener-buffer 'the listener-mode buffer did not open'
fi

if run_and_wait lem-yath-test-direnv-retarget-listener '^RETARGET listener=NESTED$' &&
   run_and_wait lem-yath-test-direnv-record-retargeted \
     '^STATE label=listener-retargeted ';
then
  assert_state post-command-retarget listener-retargeted \
    'file=no' 'listener=yes' 'relevant=NESTED' 'active=NESTED' \
    'case=NESTED' 'tool=NESTED' 'child=NESTED/NESTED/NESTED-DROP'
else
  fail post-command-retarget 'post-command did not observe the listener directory change'
fi

if run_and_wait lem-yath-test-direnv-open-scratch \
     '^STATE label=scratch-retained ';
then
  assert_state ineligible-scratch scratch-retained \
    'file=no' 'listener=no' 'relevant=none' 'active=NESTED' \
    'case=NESTED' 'tool=NESTED' 'child=NESTED/NESTED/NESTED-DROP'
else
  fail ineligible-scratch 'the ineligible scratch probe did not run'
fi

if run_and_wait lem-yath-test-direnv-open-process-buffer \
     '^STATE label=process-a ';
then
  assert_state marked-process-buffer process-a \
    'file=no' 'mode=FUNDAMENTAL-MODE' 'listener=no' 'process=yes' \
    'relevant=A' 'active=A' 'case=A' 'base=A' 'drop=unset' \
    'tool=A' 'child=A/A/unset'
else
  fail marked-process-buffer 'the marked non-file process buffer did not open'
fi

if run_and_wait lem-yath-test-direnv-open-outside '^STATE label=outside ';
then
  assert_state outside-restores-baseline outside \
    'relevant=OUTSIDE' 'active=OUTSIDE' 'case=unset' 'base=baseline' \
    'drop=baseline-drop' 'nested=unset' 'tool=none' \
    'child=unset/baseline/baseline-drop'
else
  fail outside-restores-baseline 'could not leave all envrc trees'
fi

# A blocked envrc may cause real direnv to return nonzero with a valid JSON
# unload.  The previous project must be unloaded, but the blocked file itself
# must never execute or be authorized implicitly.
allow_before=$(grep -c ' argv=allow$' "$LEM_YATH_DIRENV_EVENTS" 2>/dev/null || true)
if run_and_wait lem-yath-test-direnv-open-blocked '^STATE label=blocked ';
then
  assert_state blocked-envrc blocked \
    'relevant=BLOCKED' 'active=BLOCKED' 'case=unset' 'base=baseline' \
    'drop=baseline-drop' 'blocked=unset' 'tool=none' \
    'child=unset/baseline/baseline-drop' 'status=1' 'error=status'
  allow_after=$(grep -c ' argv=allow$' "$LEM_YATH_DIRENV_EVENTS" 2>/dev/null || true)
  if [ ! -e "$LEM_YATH_DIRENV_BLOCKED_EXECUTED" ] &&
     [ "$allow_after" -eq "$allow_before" ]; then
    pass blocked-not-auto-allowed 'the unauthorized envrc was neither run nor allowed'
  else
    fail blocked-not-auto-allowed 'the unauthorized envrc ran or direnv allow was invoked'
  fi
else
  fail blocked-envrc 'the blocked envrc probe did not complete'
fi

if run_mx direnv-allow &&
   run_and_wait lem-yath-test-direnv-record-allowed \
     '^STATE label=blocked-allowed ';
then
  assert_state explicit-allow blocked-allowed \
    'relevant=BLOCKED' 'active=BLOCKED' 'case=BLOCKED' 'base=BLOCKED' \
    'drop=unset' 'blocked=yes' 'tool=BLOCKED' 'child=BLOCKED/BLOCKED/unset' \
    'status=0' 'error=none'
  if [ -e "$LEM_YATH_DIRENV_BLOCKED_EXECUTED" ] &&
     grep -q ' argv=allow$' "$LEM_YATH_DIRENV_EVENTS"; then
    pass explicit-allow-executed 'only the explicit command authorized and loaded the envrc'
  else
    fail explicit-allow-executed 'explicit allow did not authorize and execute the envrc'
  fi
else
  fail explicit-allow 'direnv-allow or its state probe failed'
fi

printf '%s\n' BLOCKED2 >"$LEM_YATH_DIRENV_BLOCKED_DIR/value"
before=$(export_count)
if run_mx direnv-update-environment &&
   run_and_wait lem-yath-test-direnv-record-updated \
     '^STATE label=blocked-updated ';
then
  assert_state manual-update blocked-updated \
    'relevant=BLOCKED' 'active=BLOCKED' 'case=BLOCKED2' 'base=BLOCKED' \
    'blocked=yes' 'tool=BLOCKED' 'child=BLOCKED2/BLOCKED/unset'
  if [ "$(export_count)" -eq "$((before + 1))" ]; then
    pass manual-update-forces 'manual update bypassed the same-directory cache exactly once'
  else
    fail manual-update-forces "unexpected export count $before->$(export_count)"
  fi
else
  fail manual-update 'the forced same-directory refresh failed'
fi

# A timed-out export must retain a nontrivial prior environment and cache the
# failed directory instead of blocking every subsequent command with retries.
if run_and_wait lem-yath-test-direnv-switch-project-b '^STATE label=b ';
then
  assert_state failure-baseline-b b \
    'relevant=B' 'active=B' 'case=B' 'base=B' 'drop=B-DROP' \
    'tool=B' 'child=B/B/B-DROP' 'status=0' 'error=none'
else
  fail failure-baseline-b 'could not establish project B before failure cases'
fi

if ! run_and_wait lem-yath-test-direnv-use-short-timeout \
       '^TIMEOUT seconds=1$'; then
  fail timeout-setup 'could not install the isolated one-second timeout'
fi
printf '%s\n' slow >"$LEM_YATH_DIRENV_WRAPPER_MODE_FILE"
before=$(export_count)
if run_and_wait lem-yath-test-direnv-open-timeout \
     '^STATE label=timeout-failed ';
then
  assert_state timeout-preserves-environment timeout-failed \
    'relevant=TIMEOUT' 'active=TIMEOUT' 'case=B' 'base=B' 'drop=B-DROP' \
    'tool=B' 'child=B/B/B-DROP' 'status=124' 'error=timeout'
else
  fail timeout-preserves-environment 'the slow export did not return after its timeout'
fi
after_timeout=$(export_count)
if run_and_wait lem-yath-test-direnv-record-timeout \
     '^STATE label=timeout-retained ';
then
  assert_state timeout-retained timeout-retained \
    'relevant=TIMEOUT' 'active=TIMEOUT' 'case=B' 'base=B' 'drop=B-DROP' \
    'tool=B' 'child=B/B/B-DROP' 'status=124' 'error=timeout'
  if [ "$after_timeout" -eq "$((before + 1))" ] &&
     [ "$(export_count)" -eq "$after_timeout" ]; then
    pass timeout-cache 'post-command hooks did not retry the failed directory'
  else
    fail timeout-cache \
      "unexpected export counts before=$before failure=$after_timeout final=$(export_count)"
  fi
else
  fail timeout-retained 'the post-timeout state probe did not run'
fi

printf '%s\n' normal >"$LEM_YATH_DIRENV_WRAPPER_MODE_FILE"
if ! run_and_wait lem-yath-test-direnv-restore-timeout \
       '^TIMEOUT seconds=300$'; then
  fail timeout-restore 'could not restore the production timeout'
fi

# Re-enter B, then prove malformed successful output is parsed and validated
# before any environment variable changes.  Retaining B makes a reset-to-
# baseline implementation fail this assertion.
if ! run_and_wait lem-yath-test-direnv-switch-project-b '^STATE label=b '; then
  fail malformed-setup 'could not re-enter project B before malformed output'
fi
printf '%s\n' malformed >"$LEM_YATH_DIRENV_WRAPPER_MODE_FILE"
before=$(export_count)
if run_and_wait lem-yath-test-direnv-open-malformed \
     '^STATE label=malformed-failed ' &&
   run_and_wait lem-yath-test-direnv-record-malformed \
     '^STATE label=malformed-retained ';
then
  assert_state malformed-atomic malformed-retained \
    'relevant=MALFORMED' 'active=MALFORMED' 'case=B' 'base=B' \
    'drop=B-DROP' 'nested=unset' 'blocked=unset' 'tool=B' \
    'child=B/B/B-DROP' 'status=0' 'error=malformed'
  after_malformed=$(export_count)
  if [ "$after_malformed" -eq "$((before + 1))" ]; then
    pass malformed-cache 'the failed directory was not retried by later hooks'
  else
    fail malformed-cache "unexpected export count $before->$after_malformed"
  fi
else
  fail malformed-atomic 'malformed output did not return control with a state probe'
fi

printf '%s\n' normal >"$LEM_YATH_DIRENV_WRAPPER_MODE_FILE"
if run_mx direnv-update-environment &&
   run_and_wait lem-yath-test-direnv-record-recovered \
     '^STATE label=malformed-recovered ';
then
  assert_state malformed-recovery malformed-recovered \
    'relevant=MALFORMED' 'active=MALFORMED' 'case=MALFORMED' \
    'base=MALFORMED' 'drop=MALFORMED-DROP' 'tool=MALFORMED' \
    'child=MALFORMED/MALFORMED/MALFORMED-DROP' 'status=0' 'error=none'
else
  fail malformed-recovery 'manual recovery after malformed output failed'
fi

if ((failed)); then
  dump_failure_context
  printf '%s\n' 'DIRENV TEST FAILED' >&2
  exit 1
fi

printf '%s\n' 'DIRENV TEST PASSED'
