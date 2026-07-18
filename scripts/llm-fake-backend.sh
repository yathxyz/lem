#!/usr/bin/env bash
# Credential-free fake for the LLM runtime acceptance test.  The test copies
# this file under curl/claude/codex/grok names in an isolated PATH.
set -euo pipefail

: "${LEM_YATH_LLM_FAKE_LOG:?}"
backend=${0##*/}
count_file="$LEM_YATH_LLM_FAKE_LOG/$backend.count"
count=0
if [ -f "$count_file" ]; then
  IFS= read -r count <"$count_file"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
printf '%s\0' "$@" >"$LEM_YATH_LLM_FAKE_LOG/$backend.$count.argv"
pwd >"$LEM_YATH_LLM_FAKE_LOG/$backend.$count.cwd"

case "$backend" in
  curl)
    cat >"$LEM_YATH_LLM_FAKE_LOG/curl.$count.config"
    printf '%s\n' \
      'data: {"choices":[{"delta":{"content":"Open"}}]}' \
      'data: {"choices":[{"delta":{"content":"Router"}}]}' \
      'data: [DONE]'
    ;;
  claude)
    if [[ " $* " == *" abort prompt "* ]]; then
      exec sleep 30
    fi
    session_id=claude-session-1
    resume_next=0
    for argument in "$@"; do
      if (( resume_next )); then
        session_id=$argument
        resume_next=0
      elif [[ $argument == --resume ]]; then
        resume_next=1
      fi
    done
    printf '%s\n' \
      '{"type":"not-valid"' \
      "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"checked context\"},{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"safe.lisp\",\"detail\":\"one\\ntwo\\nthree\\nfour\\nfive\\nsix\\nseven\\neight\\nnine\"}},{\"type\":\"text\",\"text\":\"Claude answer $count\"}]}}" \
      '{"type":"user","message":{"content":[{"type":"tool_result","content":"read ok","is_error":false}]}}' \
      "{\"type\":\"result\",\"session_id\":\"$session_id\",\"uuid\":\"claude-message-boundary\",\"is_error\":false}"
    ;;
  codex)
    printf '%s\n' \
      '{"type":"thread.started","thread_id":"codex-thread-1"}' \
      '{"type":"item.completed","item":{"type":"command_execution","command":"pwd","status":"completed","exit_code":0,"aggregated_output":"/safe/project"}}' \
      '{"type":"item.completed","item":{"type":"file_change","changes":[{"kind":"update","path":"safe.lisp"}]}}' \
      "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Codex answer $count\"}}"
    ;;
  grok)
    printf '%s\n' \
      '{"type":"text","data":"Grok "}' \
      "{\"type\":\"text\",\"data\":\"answer $count\"}" \
      '{"type":"end","sessionId":"grok-session-1","stopReason":"end_turn"}'
    ;;
  *)
    printf 'Unexpected fake backend name: %s\n' "$backend" >&2
    exit 64
    ;;
esac
