#!/usr/bin/env bash
set -euo pipefail

log="$HOME/mcp-test-log"
mkdir -p "$log"
count=0
[[ -f "$log/curl.count" ]] && count=$(<"$log/curl.count")
count=$((count + 1))
printf '%s' "$count" >"$log/curl.count"
printf '%s\0' "$@" >"$log/curl.$count.argv"
while IFS= read -r line; do
  printf '%s\n' "$line"
done >"$log/curl.$count.config"

if ((count == 1)); then
  printf '%s\n' \
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"mcp_call","type":"function","function":{"name":"mcp__fetch__","arguments":"{\"url\":"}}]},"finish_reason":null}]}' \
    'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"fetch","arguments":"\"https://example.invalid/agent\"}"}}]},"finish_reason":"tool_calls"}]}' \
    'data: [DONE]'
else
  printf '%s\n' \
    'data: {"choices":[{"delta":{"content":"MCP agent complete"},"finish_reason":"stop"}]}' \
    'data: [DONE]'
fi
