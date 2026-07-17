#!/usr/bin/env bash
# Two-round OpenAI-compatible tool-call stream for the hermetic AI-009 gate.
set -euo pipefail

: "${LEM_YATH_LLM_TOOLS_LOG:?}"
count_file="$LEM_YATH_LLM_TOOLS_LOG/curl.count"
count=0
if [[ -f "$count_file" ]]; then
  IFS= read -r count <"$count_file"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
printf '%s\0' "$@" >"$LEM_YATH_LLM_TOOLS_LOG/curl.$count.argv"
while IFS= read -r line; do
  printf '%s\n' "$line"
done >"$LEM_YATH_LLM_TOOLS_LOG/curl.$count.config"

case "$count" in
  1)
    printf '%s\n' \
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_root","type":"function","function":{"name":"project_","arguments":"{"}},{"index":1,"id":"call_list","type":"function","function":{"name":"list_project_","arguments":"{\"glob\":\"*.li"}},{"index":2,"id":"call_search","type":"function","function":{"name":"search_","arguments":"{\"pattern\":\"TOOL_"}},{"index":3,"id":"call_read","type":"function","function":{"name":"read_project_","arguments":"{\"path\":\"target.lisp\",\"start_line\":1,"}},{"index":4,"id":"call_symbol","type":"function","function":{"name":"read_emacs_","arguments":"{\"name\":\"LEM-YATH::LLM-"}}]}}]}' \
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"root","arguments":"}"}},{"index":1,"function":{"name":"files","arguments":"sp\"}"}},{"index":2,"function":{"name":"project","arguments":"SENTINEL\",\"glob\":\"*.lisp\"}"}},{"index":3,"function":{"name":"file","arguments":"\"end_line\":2}"}},{"index":4,"function":{"name":"symbol","arguments":"REQUEST-BODY\"}"}}]},"finish_reason":"tool_calls"}]}' \
      'data: [DONE]'
    ;;
  2)
    printf '%s\n' \
      'data: {"choices":[{"delta":{"content":"Agentic tools "}}]}' \
      'data: {"choices":[{"delta":{"content":"complete"},"finish_reason":"stop"}]}' \
      'data: [DONE]'
    ;;
  *)
    printf 'unexpected tool-loop curl round: %s\n' "$count" >&2
    exit 64
    ;;
esac
