#!/usr/bin/env bash
set -euo pipefail

printf '%s\0' "$@" >>"$LEM_YATH_LLM_OAUTH_LOG/grok.argv"
case "${1:-}" in
  version)
    printf 'grok 0.1.211\n'
    ;;
  models)
    count_file="$LEM_YATH_LLM_OAUTH_LOG/grok-refresh.count"
    count=0
    if [[ -f "$count_file" ]]; then count="$(<"$count_file")"; fi
    count=$((count + 1))
    printf '%s' "$count" >"$count_file"
    printf '%s\n' '{"https://auth.x.ai::device":{"key":"grok-refreshed-secret","user_id":"grok-user-1","expires_at":"2999-01-01T00:00:00Z"}}' >"$LEM_YATH_GROK_AUTH_FILE"
    chmod 600 "$LEM_YATH_GROK_AUTH_FILE"
    printf 'grok-build\n'
    ;;
  *)
    printf 'unexpected grok command\n' >&2
    exit 2
    ;;
esac
