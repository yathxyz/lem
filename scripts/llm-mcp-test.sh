#!/usr/bin/env bash
# Real-TUI, credential-free acceptance for fetch/GitHub stdio MCP clients.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-mcp-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-mcp.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_MCP_REPORT="$root/report"
export LEM_YATH_LLM_MCP_PROJECT="$root/project"
export LEM_YATH_LLM_MCP_CURL="$root/bin/curl"
export LEM_YATH_MCP_FETCH_PROGRAM="$root/bin/fetch-server"
export LEM_YATH_MCP_DOCKER_PROGRAM="$root/bin/docker"
export OPENROUTER_API_KEY='test-openrouter-key'
export GITHUB_PERSONAL_ACCESS_TOKEN='fixture-github-token'
export UNRELATED_SECRET='must-not-reach-mcp'
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-mcp-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-mcp.*) [[ -d "$root" ]] && rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe MCP cleanup path: %s\n' "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME/mcp-test-log" "$XDG_CACHE_HOME" "$root/bin" \
  "$LEM_YATH_LLM_MCP_PROJECT"
: >"$LEM_YATH_LLM_MCP_REPORT"
cp "$here/scripts/llm-mcp-fake-server.py" "$LEM_YATH_MCP_FETCH_PROGRAM"
cp "$here/scripts/llm-mcp-fake-server.py" "$LEM_YATH_MCP_DOCKER_PROGRAM"
cp "$here/scripts/llm-mcp-fake-curl.sh" "$LEM_YATH_LLM_MCP_CURL"
python="$(command -v python3)"
bash_program="$(command -v bash)"
sed -i "1s|.*|#!$python|" "$LEM_YATH_MCP_FETCH_PROGRAM" \
  "$LEM_YATH_MCP_DOCKER_PROGRAM"
sed -i "1s|.*|#!$bash_program|" "$LEM_YATH_LLM_MCP_CURL"
chmod +x "$LEM_YATH_MCP_FETCH_PROGRAM" "$LEM_YATH_MCP_DOCKER_PROGRAM" \
  "$LEM_YATH_LLM_MCP_CURL"

git -C "$LEM_YATH_LLM_MCP_PROJECT" init -q
printf '%s\n' '(defun mcp-source () :readonly)' \
  >"$LEM_YATH_LLM_MCP_PROJECT/source.lisp"

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_LLM_MCP_REPORT" >&2 || true
  exit 1
}
report_count() { grep -cE "$1" "$LEM_YATH_LLM_MCP_REPORT" 2>/dev/null || true; }
wait_report() {
  local pattern=$1 timeout=${2:-30} index=0
  while ((index < timeout * 4)); do
    grep -qE "$pattern" "$LEM_YATH_LLM_MCP_REPORT" && return 0
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/llm-mcp-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)" ||
   ! lem_wait_for "$session" NORMAL 60 >/dev/null ||
   ! wait_report '^READY$' 60; then
  die boot 'configured Lem did not load the MCP fixture'
fi
pass boot 'configured Lem loaded the isolated MCP fixture'

lem_keys "$session" F2
if ! wait_report '^SUMMARY STATIC PASS failures=0$' 30; then
  die protocol 'MCP lifecycle, security boundary, or cancellation failed'
fi
pass protocol 'two server lifecycles, pagination, calls, and cancellation passed'

python3 - "$HOME/mcp-test-log/fetch.startup.json" \
  "$HOME/mcp-test-log/github.startup.json" \
  "$HOME/mcp-test-log/fetch.requests.jsonl" \
  "$HOME/mcp-test-log/github.requests.jsonl" <<'PY'
import json
import pathlib
import sys

fetch = json.loads(pathlib.Path(sys.argv[1]).read_text())
github = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert "OPENROUTER_API_KEY" not in fetch["environment"]
assert "GITHUB_PERSONAL_ACCESS_TOKEN" not in fetch["environment"]
assert "UNRELATED_SECRET" not in fetch["environment"]
assert github["github_token"] == "fixture-github-token"
assert github["toolsets"] == "context,repos,issues,pull_requests,users"
assert github["read_only"] == "1"
assert "fixture-github-token" not in github["argv"]
assert "UNRELATED_SECRET" not in github["environment"]
assert github["argv"] == [
    "run", "-i", "--rm",
    "-e", "GITHUB_PERSONAL_ACCESS_TOKEN",
    "-e", "GITHUB_TOOLSETS",
    "-e", "GITHUB_READ_ONLY",
    "ghcr.io/github/github-mcp-server",
]

for path, version in [(sys.argv[3], "2025-11-25"), (sys.argv[4], "2025-11-25")]:
    messages = [json.loads(line) for line in pathlib.Path(path).read_text().splitlines()]
    initialize = next(m for m in messages if m.get("method") == "initialize")
    assert initialize["params"]["protocolVersion"] == version
    assert initialize["params"]["capabilities"] == {}
    assert any(m.get("method") == "notifications/initialized" for m in messages)
    assert any(isinstance(m.get("id"), str)
               and m["id"].endswith("-ping") and m.get("result") == {}
               for m in messages)
PY
pass process-boundary 'stdio framing, ping, fixed argv, and credential confinement passed'

lem_keys "$session" F3
for _ in $(seq 1 120); do
  lem_keys "$session" F12
  if grep -qE '^STATE active=no final=yes tool=yes protocol-error=no$' \
      "$LEM_YATH_LLM_MCP_REPORT"; then
    break
  fi
  sleep 0.25
done
if ! grep -qE '^STATE active=no final=yes tool=yes protocol-error=no$' \
    "$LEM_YATH_LLM_MCP_REPORT"; then
  die agent-loop 'OpenRouter did not complete the MCP tool round'
fi
pass agent-loop 'namespaced fetch tool completed through a second model round'

python3 - "$HOME/mcp-test-log/curl.1.argv" \
  "$HOME/mcp-test-log/curl.2.argv" <<'PY'
import json
import pathlib
import sys

def body(path):
    args = pathlib.Path(path).read_bytes().split(b"\0")[:-1]
    args = [item.decode() for item in args]
    return json.loads(args[args.index("-d") + 1])

first, second = map(body, sys.argv[1:])
names = [tool["function"]["name"] for tool in first["tools"]]
assert names[:5] == ["project_root", "list_project_files", "search_project",
                     "read_project_file", "read_emacs_symbol"]
assert names[5:] == ["mcp__fetch__fetch", "mcp__fetch__fetch_dheaders"]
assert len(second["messages"]) == 4
assert second["messages"][2]["tool_calls"][0]["function"]["name"] == \
       "mcp__fetch__fetch"
tool = second["messages"][3]
assert tool["role"] == "tool" and tool["tool_call_id"] == "mcp_call"
assert "FETCH-FIRST" in tool["content"] and "FETCH-SECOND" in tool["content"]
assert "https://example.invalid/agent" in tool["content"]
PY
pass transcript 'exact tool schemas and assistant/tool follow-up transcript passed'

printf 'All MCP client tests passed.\n'
