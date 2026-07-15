#!/usr/bin/env bash
# Real-TUI, credential-free acceptance for the read-only OpenRouter tool loop.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-tools-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-tools.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_TOOLS_REPORT="$root/report"
export LEM_YATH_LLM_TOOLS_LOG="$root/log"
export LEM_YATH_LLM_TOOLS_PROJECT="$root/project"
export LEM_YATH_LLM_TOOLS_CURL="$root/bin/curl"
export OPENROUTER_API_KEY='test-key-not-a-credential'
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-tools-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-tools.*)
      [[ -d "$root" ]] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe LLM tools cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_YATH_LLM_TOOLS_LOG" \
  "$root/bin" "$LEM_YATH_LLM_TOOLS_PROJECT" "$root/outside"
: >"$LEM_YATH_LLM_TOOLS_REPORT"
cp "$here/scripts/llm-tools-fake-curl.sh" "$LEM_YATH_LLM_TOOLS_CURL"
chmod +x "$LEM_YATH_LLM_TOOLS_CURL"

git -C "$LEM_YATH_LLM_TOOLS_PROJECT" init -q
printf '%s\n' '(defparameter *tool-sentinel* "TOOL_SENTINEL")' \
  '(defun fixture-target () *tool-sentinel*)' \
  >"$LEM_YATH_LLM_TOOLS_PROJECT/target.lisp"
printf '%s\n' 'ordinary notes' >"$LEM_YATH_LLM_TOOLS_PROJECT/notes.txt"
for index in $(seq 1 305); do
  printf 'line-%03d\n' "$index"
done >"$LEM_YATH_LLM_TOOLS_PROJECT/long.txt"
printf 'binary\0payload' >"$LEM_YATH_LLM_TOOLS_PROJECT/binary.dat"
printf '%s\n' 'OUTSIDE_SECRET' >"$root/outside/secret.txt"
ln -s target.lisp "$LEM_YATH_LLM_TOOLS_PROJECT/inside-link.lisp"
ln -s "$root/outside/secret.txt" "$LEM_YATH_LLM_TOOLS_PROJECT/escape.txt"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_LLM_TOOLS_REPORT" >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_TOOLS_REPORT" 2>/dev/null || true
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

wait_state() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    lem_keys "$session" F12
    sleep 0.25
    if grep -qE "$pattern" "$LEM_YATH_LLM_TOOLS_REPORT"; then return 0; fi
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/llm-tools-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)"; then
  die boot 'could not start the isolated tmux/Lem process'
fi
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the tool fixture'
fi
pass boot 'configured Lem loaded the isolated tool fixture'

lem_keys "$session" F2
if ! wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  die static-contracts 'tool schema, executor, or security contract failed'
fi
pass static-contracts 'all five tools and path/content limits passed'

lem_keys "$session" F3
if ! wait_state '^STATE active=no final=yes root=yes list=yes search=yes read=yes symbol=yes protocol-error=no$'; then
  die agentic-loop 'fragmented calls, tool execution, or final stream failed'
fi
pass agentic-loop 'five fragmented calls completed through a second HTTP round'

if [[ $(<"$LEM_YATH_LLM_TOOLS_LOG/curl.count") != 2 ]]; then
  die round-boundary 'expected exactly two OpenRouter HTTP requests'
fi

python3 - "$LEM_YATH_LLM_TOOLS_LOG/curl.1.argv" \
  "$LEM_YATH_LLM_TOOLS_LOG/curl.2.argv" \
  "$LEM_YATH_LLM_TOOLS_PROJECT" <<'PY'
import json
import pathlib
import sys

def body(path):
    args = pathlib.Path(path).read_bytes().split(b"\0")[:-1]
    args = [value.decode() for value in args]
    assert args[:4] == ["-sN", "https://openrouter.ai/api/v1/chat/completions",
                       "-H", "Content-Type: application/json"]
    assert args[4:6] == ["-H", "Authorization: Bearer test-key-not-a-credential"]
    assert args[6] == "-d"
    return json.loads(args[7])

first = body(sys.argv[1])
second = body(sys.argv[2])
root = str(pathlib.Path(sys.argv[3]).resolve()) + "/"
names = [tool["function"]["name"] for tool in first["tools"]]
assert names == ["project_root", "list_project_files", "search_project",
                 "read_project_file", "read_emacs_symbol"]
assert first["model"] == "openrouter/auto"
assert first["max_tokens"] == 4000 and first["temperature"] == 0.2
assert first["messages"][1] == {
    "role": "user",
    "content": "Inspect this project with the available tools.",
}
assert len(second["messages"]) == 8
assistant = second["messages"][2]
assert assistant["role"] == "assistant" and assistant["content"] is None
calls = assistant["tool_calls"]
assert [call["id"] for call in calls] == [
    "call_root", "call_list", "call_search", "call_read", "call_symbol"
]
assert [json.loads(call["function"]["arguments"]) for call in calls] == [
    {}, {"glob": "*.lisp"},
    {"pattern": "TOOL_SENTINEL", "glob": "*.lisp"},
    {"path": "target.lisp", "start_line": 1, "end_line": 2},
    {"name": "LEM-YATH::LLM-REQUEST-BODY"},
]
results = second["messages"][3:]
assert [message["role"] for message in results] == ["tool"] * 5
assert [message["tool_call_id"] for message in results] == [call["id"] for call in calls]
assert results[0]["content"] == root
assert "target.lisp" in results[1]["content"]
assert "TOOL_SENTINEL" in results[2]["content"]
assert "Showing lines 1-2" in results[3]["content"]
assert "Function: LEM-YATH::LLM-REQUEST-BODY" in results[4]["content"]
assert [tool["function"]["name"] for tool in second["tools"]] == names
PY
pass request-transcript 'schemas and exact assistant/tool follow-up messages passed'

printf 'All LLM tool-loop tests passed.\n'
