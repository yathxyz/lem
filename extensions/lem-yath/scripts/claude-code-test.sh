#!/usr/bin/env bash
# Credential-free real-TUI acceptance for the integrated Claude Code buffer.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-claude-code-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-claude-code.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_CLAUDE_CODE_REPORT="$root/report"
export LEM_YATH_CLAUDE_CODE_FAKE="$root/bin/ccr"
export LEM_YATH_CLAUDE_CODE_LOG="$root/claude"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-claude-code-$id"
source_file="$root/project/context.txt"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-claude-code.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe Claude Code cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$root/bin" "$root/project"
: >"$LEM_YATH_CLAUDE_CODE_REPORT"
printf 'Claude project context\n' >"$source_file"
git -C "$root/project" init -q
bash_bin=$(command -v bash)

printf '%s\n' \
  "#!$bash_bin" \
  'set -euo pipefail' \
  ': "${LEM_YATH_CLAUDE_CODE_LOG:?}"' \
  'count_file="$LEM_YATH_CLAUDE_CODE_LOG.count"' \
  'count=0' \
  'if [ -f "$count_file" ]; then IFS= read -r count <"$count_file"; fi' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" >"$count_file"' \
  'printf "%s\0" "$PWD" "$@" >"$LEM_YATH_CLAUDE_CODE_LOG.$count.argv"' \
  'if [ "$count" -eq 1 ]; then' \
  '  printf %s '\''{"type":"assistant","session_id":"ide-session-1","message":{"content":[{"type":"text","text":"FIRST'\''' \
  '  sleep 0.15' \
  '  printf "%s\n" '\''-CLAUDE-REPLY"},{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"context.txt"}}]}}'\''' \
  '  printf "%s\n" '\''{"type":"result","session_id":"ide-session-1"}'\''' \
  'else' \
  '  printf "%s\n%s\n" '\''{"type":"assistant","session_id":"ide-session-2","message":{"content":[{"type":"text","text":"SECOND-CLAUDE-REPLY"}]}}'\'' '\''{"type":"result","session_id":"ide-session-2"}'\''' \
  'fi' \
  >"$LEM_YATH_CLAUDE_CODE_FAKE"
chmod +x "$LEM_YATH_CLAUDE_CODE_FAKE"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,200p' "$LEM_YATH_CLAUDE_CODE_REPORT" >&2 || true
  exit 1
}

report_has() {
  grep -Eq "$1" "$LEM_YATH_CLAUDE_CODE_REPORT" 2>/dev/null
}

wait_report() {
  local pattern=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    if report_has "$pattern"; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_state() {
  local pattern=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    lem_keys "$session" F12
    sleep 0.25
    if report_has "$pattern"; then return 0; fi
    index=$((index + 1))
  done
  return 1
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l -- "$1"
  sleep 0.15
}

fixture="$(lem-yath_lisp_string "$here/scripts/claude-code-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$source_file"; then
  die boot 'could not start configured Lem'
fi
lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null || \
  die boot 'configured Lem did not reach normal state'
wait_report '^READY$' || die boot 'fixture did not load'
pass boot 'configured Lem loaded the Claude Code fixture'

lem_keys "$session" F2
if ! wait_report '^STATIC binding=LEM-YATH-CLAUDE-CODE resolved=.*/ccr suffix=code$'; then
  die static-contracts 'normal binding or direct ccr argv resolution differed'
fi
pass static-contracts 'C-c c resolves the configured direct ccr argv'

lem_keys "$session" C-c c
if ! lem_wait_for "$session" 'Claude Code' "$WAIT_TIMEOUT" >/dev/null; then
  die open-session 'physical normal-state C-c c did not open the interactive buffer'
fi
pass open-session 'physical C-c c opened the integrated query/output UI'
sleep 0.5

send_literal 'first IDE prompt'
lem_keys "$session" Enter
if ! lem_wait_for "$session" 'FIRST-CLAUDE-REPLY' "$WAIT_TIMEOUT" >/dev/null; then
  die fragmented-stream 'fragmented JSONL assistant output was not rendered'
fi
pass fragmented-stream 'fragmented assistant and coalesced result events rendered'

send_literal 'second IDE prompt'
lem_keys "$session" Enter
if ! lem_wait_for "$session" 'SECOND-CLAUDE-REPLY' "$WAIT_TIMEOUT" >/dev/null; then
  die resumed-stream 'second prompt did not render through the resumed session'
fi
if ! wait_state '^STATE session=ide-session-2 directory=.*/project/ command=.*/ccr\|code events=4 types=assistant,result,assistant,result first=yes second=yes tool=yes$'; then
  die session-state 'session, project directory, activity rendering, or resume state differed'
fi
pass session-state 'project context and rendered activity survived session resume'

python3 - "$LEM_YATH_CLAUDE_CODE_LOG.1.argv" \
  "$LEM_YATH_CLAUDE_CODE_LOG.2.argv" "$root/project" <<'PY'
import pathlib
import sys

def fields(path):
    return [part.decode() for part in pathlib.Path(path).read_bytes().split(b"\0")[:-1]]

first = fields(sys.argv[1])
second = fields(sys.argv[2])
project = str(pathlib.Path(sys.argv[3]))
allowed = (
    "mcp__lem__buffer_list,mcp__lem__buffer_get_content,"
    "mcp__lem__buffer_info,mcp__lem__editor_get_screen,"
    "mcp__lem__openDiff,mcp__lem__checkDiff"
)
prompt = (
    "Use the connected Lem MCP tools to inspect the live editor. "
    "Do not mutate files directly. Present proposed whole-buffer "
    "changes with openDiff, wait for the user's decision, and check "
    "it with checkDiff before continuing."
)
config = first[8]
assert pathlib.Path(config).is_file()
assert first == [
    project,
    "code", "--output-format", "stream-json", "--verbose", "--print",
    "first IDE prompt", "--mcp-config", config,
    "--allowedTools", allowed, "--disallowedTools", "Edit,Write,NotebookEdit",
    "--append-system-prompt", prompt,
    "--permission-mode", "acceptEdits",
]
assert second == [
    project,
    "code", "--output-format", "stream-json", "--verbose", "--print",
    "second IDE prompt", "--mcp-config", config,
    "--allowedTools", allowed, "--disallowedTools", "Edit,Write,NotebookEdit",
    "--append-system-prompt", prompt,
    "--permission-mode", "acceptEdits", "--resume", "ide-session-1",
]
PY
pass native-argv 'both launches used the private MCP config, allowlist, project cwd, and resume ID'

printf 'All Claude Code integration tests passed.\n'
