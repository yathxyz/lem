#!/usr/bin/env bash
# Real-TUI, credential-free acceptance for OpenRouter and native agent CLIs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-backend-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-backend.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_BACKEND_REPORT="$root/report"
export LEM_YATH_LLM_FAKE_LOG="$root/log"
export LEM_YATH_LLM_FAKE_BIN="$root/bin/"
export LEM_YATH_LLM_CLAUDE_PROJECT_ROOT="$root/project"
export LEM_YATH_CLAUDE_PROJECTS_DIR="$root/claude-projects"
export OPENROUTER_API_KEY='test-key-not-a-credential'
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-backend-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-backend.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe LLM backend cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_YATH_LLM_FAKE_LOG" \
  "$LEM_YATH_LLM_FAKE_BIN" "$LEM_YATH_LLM_CLAUDE_PROJECT_ROOT" \
  "$LEM_YATH_CLAUDE_PROJECTS_DIR" "$HOME/.claude"
git -C "$LEM_YATH_LLM_CLAUDE_PROJECT_ROOT" init -q
git -C "$HOME" init -q
printf '%s\n' '{"mcpServers":{}}' \
  >"$LEM_YATH_LLM_CLAUDE_PROJECT_ROOT/.mcp.json"
chmod 600 "$LEM_YATH_LLM_CLAUDE_PROJECT_ROOT/.mcp.json"
printf '%s\n' '{"mcpServers":{"home":{}}}' >"$HOME/.claude/.mcp.json"
chmod 600 "$HOME/.claude/.mcp.json"
ln -s .mcp.json "$HOME/.claude/symlink-mcp.json"
encoded_project=$(printf '%s' "$LEM_YATH_LLM_CLAUDE_PROJECT_ROOT" | tr '/.' '--')
claude_project_dir="$LEM_YATH_CLAUDE_PROJECTS_DIR/$encoded_project"
mkdir -p "$claude_project_dir"
chmod 700 "$LEM_YATH_CLAUDE_PROJECTS_DIR" "$claude_project_dir"
printf '%s\n' \
  '{"type":"user","uuid":"claude-user-before"}' \
  '{"type":"assistant","uuid":"claude-message-boundary"}' \
  '{"type":"user","uuid":"claude-user-after"}' \
  >"$claude_project_dir/claude-session-1.jsonl"
printf '%s\n' \
  "{\"version\":1,\"entries\":[{\"sessionId\":\"claude-session-1\",\"fullPath\":\"$claude_project_dir/claude-session-1.jsonl\",\"firstPrompt\":\"Original session\",\"summary\":\"Original session\",\"modified\":\"2026-07-18T00:00:00Z\"}],\"unknown\":{\"keep\":true}}" \
  >"$claude_project_dir/sessions-index.json"
chmod 600 "$claude_project_dir/claude-session-1.jsonl" \
  "$claude_project_dir/sessions-index.json"
: >"$LEM_YATH_LLM_BACKEND_REPORT"
bash_bin=$(command -v bash)
for executable in curl claude codex grok; do
  cp "$here/scripts/llm-fake-backend.sh" "$LEM_YATH_LLM_FAKE_BIN$executable"
  sed -i "1c#!$bash_bin" "$LEM_YATH_LLM_FAKE_BIN$executable"
  chmod +x "$LEM_YATH_LLM_FAKE_BIN$executable"
done

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() {
  printf 'PASS  %-30s %s\n' "$1" "$2"
}

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_LLM_BACKEND_REPORT" >&2 || true
  printf '\n--- fake argv files ---\n' >&2
  find "$LEM_YATH_LLM_FAKE_LOG" -maxdepth 1 -type f -printf '%f\n' \
    2>/dev/null | sort >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_BACKEND_REPORT" 2>/dev/null || true
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

wait_state() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    lem_keys "$session" F12
    sleep 0.25
    if grep -qE "$pattern" "$LEM_YATH_LLM_BACKEND_REPORT"; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

send_key() {
  lem_keys "$session" "$1"
  sleep 0.15
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l -- "$1"
  sleep 0.15
}

assert_argv() {
  local label=$1 file=$2
  shift 2
  local -a actual=() expected=("$@")
  if [ ! -f "$file" ]; then
    die "$label" "missing argv capture $file"
  fi
  mapfile -d '' -t actual <"$file"
  if (( ${#actual[@]} != ${#expected[@]} )); then
    die "$label" "argv length ${#actual[@]} != ${#expected[@]}"
  fi
  local index
  for index in "${!expected[@]}"; do
    if [[ "${actual[$index]}" != "${expected[$index]}" ]]; then
      die "$label" "argv[$index] differed"
    fi
  done
  pass "$label" 'native argv matched exactly'
}

fixture="$(lem-yath_lisp_string "$here/scripts/llm-backend-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)"; then
  die boot 'could not start the isolated tmux/Lem process'
fi
if ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the backend fixture'
fi
pass boot 'configured Lem loaded the isolated backend fixture'

send_key F2
if ! wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  die static-contracts 'command, session validation, or parser contract failed'
fi
pass static-contracts 'native argv and bounded parser contracts passed'

send_key F3
if ! wait_state '^STATE active=no openrouter=yes '; then
  die openrouter-stream 'SSE chunks did not reach the live output buffer'
fi
pass openrouter-stream 'fake SSE chunks streamed through the editor queue'

send_key F4
if ! wait_state 'active=no .*claude1=yes .*thinking=yes tool=yes tool-result=yes .*claude-id=claude-session-1 .*claude-boundary=yes'; then
  die claude-first 'Claude text, activity, or session metadata was missing'
fi
send_key F4
if ! wait_state 'active=no .*claude2=yes .*claude-id=claude-session-1'; then
  die claude-resume 'Claude resume request did not complete'
fi
pass claude-stream 'Claude events rendered and the second request resumed'

send_key F9
if ! wait_report_count '^NEW claude=none$' 1; then
  die claude-new-session 'new-session command did not clear Claude metadata'
fi
send_key F4
if ! wait_state 'active=no .*claude3=yes .*claude-id=claude-session-1'; then
  die claude-fresh 'Claude did not start fresh after clearing the session'
fi
pass claude-new-session 'explicit new conversation suppressed resume argv'

send_key F8
if ! wait_state '^STATE active=yes '; then
  die request-active 'slow fake request was not registered as active'
fi
send_key F5
sleep 0.4
if [ -e "$LEM_YATH_LLM_FAKE_LOG/codex.count" ]; then
  die duplicate-guard 'a second backend launched while one request was active'
fi
send_key F7
if ! wait_state 'active=no .*aborted=yes '; then
  die request-abort 'active process was not terminated and finalized'
fi
pass request-lifecycle 'duplicate launch was rejected and abort finalized safely'

send_key F5
if ! wait_state 'active=no .*codex1=yes .*command=yes file=yes .*codex-id=codex-thread-1'; then
  die codex-first 'Codex response, activity, or thread metadata was missing'
fi
send_key F5
if ! wait_state 'active=no .*codex2=yes .*codex-id=codex-thread-1'; then
  die codex-resume 'Codex resume request did not complete'
fi
pass codex-stream 'Codex activity rendered and the second request resumed'

send_key F6
if ! wait_state 'active=no .*grok1=yes .*grok-id=grok-session-1'; then
  die grok-first 'Grok text or session metadata was missing'
fi
send_key F6
if ! wait_state 'active=no .*grok2=yes .*grok-id=grok-session-1'; then
  die grok-resume 'Grok resume request did not complete'
fi
pass grok-stream 'Grok events rendered and the second request resumed'

send_key F10
send_key C-c
send_key C-f
if ! wait_state 'claude-branch=[0-9A-Fa-f-]{36} .*selected-backend=CLAUDE-CODE'; then
  die claude-fork 'C-c C-f did not select a newly forked Claude session'
fi

python3 - "$claude_project_dir" <<'PY'
import json
import pathlib
import re
import stat
import sys

directory = pathlib.Path(sys.argv[1])
index = json.loads((directory / "sessions-index.json").read_text())
assert index["unknown"] == {"keep": True}
assert len(index["entries"]) == 2
fork = index["entries"][-1]
session_id = fork["sessionId"]
assert re.fullmatch(
    r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
    session_id,
    re.IGNORECASE,
)
assert fork["messageCount"] == 2
path = pathlib.Path(fork["fullPath"])
assert path.parent == directory and path.name == f"{session_id}.jsonl"
records = [json.loads(line) for line in path.read_text().splitlines()]
assert [record.get("uuid") for record in records[:2]] == [
    "claude-user-before", "claude-message-boundary"
]
assert records[2] == {
    "type": "last-prompt", "sessionId": session_id, "lastPrompt": "fork"
}
assert stat.S_IMODE(path.stat().st_mode) == 0o600
assert stat.S_IMODE((directory / "sessions-index.json").stat().st_mode) == 0o600
assert (directory / "claude-session-1.jsonl").read_text().splitlines()[-1] == \
    '{"type":"user","uuid":"claude-user-after"}'
PY
pass claude-fork 'physical C-c C-f created one bounded registered JSONL fork'

send_key C-c
send_key C-b
if ! lem_wait_for "$session" 'Session:' "$WAIT_TIMEOUT" >/dev/null; then
  die claude-session-picker 'C-c C-b did not open the session picker'
fi
send_literal 'Original session'
send_key Enter
if ! wait_state 'claude-branch=claude-session-1 .*selected-backend=CLAUDE-CODE'; then
  die claude-session-picker 'the selected original Claude session was not restored'
fi
pass claude-session-picker 'physical C-c C-b restored a registered project session'

fork_count_before=$(find "$claude_project_dir" -maxdepth 1 -name '*.jsonl' -type f | wc -l)
printf '{malformed\n' >"$claude_project_dir/sessions-index.json"
chmod 600 "$claude_project_dir/sessions-index.json"
send_key F10
send_key C-c
send_key C-f
sleep 0.5
fork_count_after=$(find "$claude_project_dir" -maxdepth 1 -name '*.jsonl' -type f | wc -l)
if [ "$fork_count_after" -ne "$fork_count_before" ]; then
  die claude-fork-rollback 'a malformed index left an unregistered fork file'
fi
if ! wait_state 'claude-branch=claude-session-1'; then
  die claude-fork-rollback 'failed fork changed the active Claude session'
fi
pass claude-fork-rollback 'index failure removed its fork file and retained session ownership'

system='Short, direct answers. Skip extra context unless it changes correctness.'
composed_prefix=$'System instructions:\nShort, direct answers. Skip extra context unless it changes correctness.\n\nUser message:\n'
claude_tools=(
  --allowedTools Bash --allowedTools Read --allowedTools Edit
  --allowedTools Write --allowedTools Glob --allowedTools Grep
  --allowedTools WebFetch --allowedTools WebSearch --allowedTools Agent
)
claude_mcp=(--mcp-config "$LEM_YATH_LLM_CLAUDE_PROJECT_ROOT/.mcp.json")

assert_argv claude-first-argv "$LEM_YATH_LLM_FAKE_LOG/claude.1.argv" \
  -p 'claude prompt' --output-format stream-json --verbose \
  "${claude_tools[@]}" --append-system-prompt "$system" "${claude_mcp[@]}"
assert_argv claude-resume-argv "$LEM_YATH_LLM_FAKE_LOG/claude.2.argv" \
  -p 'claude prompt' --output-format stream-json --verbose \
  --resume claude-session-1 "${claude_tools[@]}" \
  --append-system-prompt "$system" "${claude_mcp[@]}"
assert_argv claude-fresh-argv "$LEM_YATH_LLM_FAKE_LOG/claude.3.argv" \
  -p 'claude prompt' --output-format stream-json --verbose \
  "${claude_tools[@]}" --append-system-prompt "$system" "${claude_mcp[@]}"
assert_argv claude-aborted-argv "$LEM_YATH_LLM_FAKE_LOG/claude.4.argv" \
  -p 'abort prompt' --output-format stream-json --verbose \
  --resume claude-session-1 "${claude_tools[@]}" \
  --append-system-prompt "$system" "${claude_mcp[@]}"

for cwd_file in "$LEM_YATH_LLM_FAKE_LOG"/claude.{1,2,3,4}.cwd; do
  if [ "$(<"$cwd_file")" != "$LEM_YATH_LLM_CLAUDE_PROJECT_ROOT" ]; then
    die claude-project-cwd 'Claude did not inherit the originating Git root'
  fi
done
pass claude-project-cwd 'all Claude requests ran at the originating Git root'

assert_argv codex-first-argv "$LEM_YATH_LLM_FAKE_LOG/codex.1.argv" \
  exec --json -s read-only "${composed_prefix}codex prompt"
assert_argv codex-resume-argv "$LEM_YATH_LLM_FAKE_LOG/codex.2.argv" \
  exec resume codex-thread-1 --json -s read-only \
  "${composed_prefix}codex prompt"

grok_tail=(--output-format streaming-json -m grok-build --sandbox read-only \
  --permission-mode dontAsk --disable-web-search --no-subagents --no-plan)
assert_argv grok-first-argv "$LEM_YATH_LLM_FAKE_LOG/grok.1.argv" \
  -p "${composed_prefix}grok prompt" "${grok_tail[@]}"
assert_argv grok-resume-argv "$LEM_YATH_LLM_FAKE_LOG/grok.2.argv" \
  -p "${composed_prefix}grok prompt" --output-format streaming-json \
  -r grok-session-1 -m grok-build --sandbox read-only \
  --permission-mode dontAsk --disable-web-search --no-subagents --no-plan

python3 - "$LEM_YATH_LLM_FAKE_LOG/curl.1.argv" \
  "$LEM_YATH_LLM_FAKE_LOG/curl.1.config" <<'PY'
import json
import pathlib
import re
import sys

args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
args = [value.decode() for value in args]
assert args == ["--silent", "--show-error", "--fail-with-body", "--no-buffer",
                "--max-time", "300", "--config", "-"]
joined = "\0".join(args)
assert "test-key-not-a-credential" not in joined
assert "openrouter prompt" not in joined

config = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert 'url = "https://openrouter.ai/api/v1/chat/completions"' in config
assert "Authorization: Bearer test-key-not-a-credential" in config
encoded_body = re.search(r'data-binary = (".*")', config).group(1)
body = json.loads(json.loads(encoded_body))
assert body["model"] == "openrouter/auto" and body["stream"] is True
assert body["temperature"] == 0.2 and body["max_tokens"] == 800
assert body["messages"] == [
    {"role": "system", "content": "Short, direct answers. Skip extra context unless it changes correctness."},
    {"role": "user", "content": "openrouter prompt"},
]
PY
pass openrouter-request 'exact request stayed on curl stdin and off argv'

printf 'All LLM backend tests passed.\n'
