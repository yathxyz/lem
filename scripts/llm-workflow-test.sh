#!/usr/bin/env bash
# Real-TUI acceptance for named LLM presets and external web handoff.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-workflow-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-workflow.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_WORKFLOW_REPORT="$root/report"
export LEM_YATH_LLM_WORKFLOW_BROWSER="$root/bin/brave"
export LEM_YATH_LLM_WORKFLOW_BROWSER_LOG="$root/browser"
export LEM_YATH_LLM_PRESET_FILE="$root/private/llm-presets.json"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-workflow-$id"
source_file="$root/project/context.txt"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-workflow.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe LLM workflow cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$root/bin" "$root/private" \
  "$root/project"
chmod 700 "$root/private"
: >"$LEM_YATH_LLM_WORKFLOW_REPORT"
printf 'initial context\n' >"$source_file"
git -C "$root/project" init -q

bash_bin=$(command -v bash)
printf '%s\n' \
  "#!$bash_bin" \
  'set -euo pipefail' \
  ': "${LEM_YATH_LLM_WORKFLOW_BROWSER_LOG:?}"' \
  'count_file="$LEM_YATH_LLM_WORKFLOW_BROWSER_LOG.count"' \
  'count=0' \
  'if [ -f "$count_file" ]; then IFS= read -r count <"$count_file"; fi' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" >"$count_file"' \
  'printf "%s\0" "$@" >"$LEM_YATH_LLM_WORKFLOW_BROWSER_LOG.$count.argv"' \
  >"$LEM_YATH_LLM_WORKFLOW_BROWSER"
chmod +x "$LEM_YATH_LLM_WORKFLOW_BROWSER"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_LLM_WORKFLOW_REPORT" >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_WORKFLOW_REPORT" 2>/dev/null || true
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

send_key() {
  lem_keys "$session" "$1"
  sleep 0.15
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l -- "$1"
  sleep 0.15
}

wait_browser_count() {
  local expected=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    if [ -f "$LEM_YATH_LLM_WORKFLOW_BROWSER_LOG.count" ] &&
       [ "$(<"$LEM_YATH_LLM_WORKFLOW_BROWSER_LOG.count")" -ge "$expected" ]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

start_fixture() {
  local fixture
  fixture="$(lem-yath_lisp_string "$here/scripts/llm-workflow-fixture.lisp")"
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$source_file"
  lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null
  wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"
}

if ! start_fixture; then die boot 'could not start the first Lem phase'; fi
pass boot 'configured Lem loaded the preset/handoff fixture'

send_key F2
if ! wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  die static-contracts 'menu, preset, request, or truncation contracts failed'
fi
pass static-contracts 'menu, quick preset, and bounded context contracts passed'

send_key F3
if ! wait_report_count '^SETTINGS ready$' 1; then
  die preset-setup 'fixture settings were not applied'
fi
send_key Space
send_key g
send_key l
if ! lem_wait_for "$session" 'save preset' "$WAIT_TIMEOUT" >/dev/null; then
  die preset-menu 'SPC g l did not render the preset/handoff menu'
fi
send_key s
if ! lem_wait_for "$session" 'Save LLM preset:' "$WAIT_TIMEOUT" >/dev/null; then
  die preset-save-prompt 'menu save did not open the name prompt'
fi
send_key Enter
sleep 0.5
send_key F12
if ! wait_report_count 'STATE current=fixture-preset backend=CODEX model=fixture-model system=fixture system temperature=0.7 max=1234 saved=yes file-mode=600 dir-mode=700 ' 1; then
  die preset-save 'preset state or private file permissions differed'
fi
pass preset-save 'physical menu saved a private named preset'

lem_stop "$session"
: >"$LEM_YATH_LLM_WORKFLOW_REPORT"
if ! start_fixture; then die restart 'could not start the fresh Lem phase'; fi
pass restart 'fresh Lem process loaded against the same private preset file'

send_key Space
send_key g
send_key l
send_key l
if ! lem_wait_for "$session" 'LLM preset:' "$WAIT_TIMEOUT" >/dev/null; then
  die preset-load-prompt 'menu load did not open preset completion'
fi
send_key C-a
send_key C-k
send_literal 'fixture-preset'
send_key Enter
sleep 0.5
send_key F12
if ! wait_report_count 'STATE current=fixture-preset backend=CODEX model=fixture-model system=fixture system temperature=0.7 max=1234 saved=yes ' 1; then
  die preset-load 'fresh process did not restore every saved setting'
fi
pass preset-load 'fresh process loaded backend, model, system, and limits'

send_key F5
if ! wait_report_count '^REGION ready$' 1; then die region-setup 'setup failed'; fi
send_key Escape
send_key 0
send_key w
send_key v
send_key e
send_key Space
send_key g
send_key l
if ! lem_wait_for "$session" 'open in Claude' "$WAIT_TIMEOUT" >/dev/null; then
  die handoff-menu 'visual-state leader did not render handoff actions'
fi
send_key c
if ! wait_browser_count 1; then
  die claude-handoff 'fake browser was not launched'
fi
pass claude-handoff 'visual-state menu launched Claude through argv'

send_key F6
if ! wait_report_count '^LONG ready$' 1; then die long-setup 'setup failed'; fi
send_key Escape
send_key Space
send_key g
send_key l
send_key w
if ! wait_browser_count 2; then
  die chatgpt-handoff 'fake browser was not launched for search mode'
fi
send_key F12
if ! wait_report_count 'kill-length=13000 kill-truncated=yes$' 1; then
  die chatgpt-copy 'bounded handoff prompt was not copied to the kill ring'
fi
pass chatgpt-handoff 'search handoff copied and launched bounded context'

python3 - "$LEM_YATH_LLM_WORKFLOW_BROWSER_LOG.1.argv" \
  "$LEM_YATH_LLM_WORKFLOW_BROWSER_LOG.2.argv" "$source_file" <<'PY'
import pathlib
import sys
import urllib.parse

def argv(path):
    return [value.decode() for value in pathlib.Path(path).read_bytes().split(b"\0")[:-1]]

claude = argv(sys.argv[1])
chatgpt = argv(sys.argv[2])
source = pathlib.Path(sys.argv[3])
assert claude[0] == "--new-window" and len(claude) == 2
claude_url = urllib.parse.urlparse(claude[1])
assert (claude_url.scheme, claude_url.netloc, claude_url.path) == (
    "https", "claude.ai", "/new")
claude_prompt = urllib.parse.parse_qs(claude_url.query)["q"][0]
assert "HANDOFFREGION" in claude_prompt
assert "prefix" not in claude_prompt and "suffix" not in claude_prompt
assert "Buffer: context.txt" in claude_prompt
assert f"File: {source}" in claude_prompt
assert f"Project: {source.parent}/" in claude_prompt

assert chatgpt[0] == "--new-window" and len(chatgpt) == 2
chatgpt_url = urllib.parse.urlparse(chatgpt[1])
params = urllib.parse.parse_qs(chatgpt_url.query)
assert (chatgpt_url.scheme, chatgpt_url.netloc, chatgpt_url.path) == (
    "https", "chatgpt.com", "/")
assert params["temporary-chat"] == ["true"] and params["hints"] == ["search"]
prompt = params["q"][0]
assert len(prompt) == 13000 and prompt.startswith("[Truncated by Lem")
assert prompt.endswith("x" * 100)
PY
pass handoff-urls 'decoded URLs contain exact region/project and search parameters'

printf 'All LLM workflow tests passed.\n'
