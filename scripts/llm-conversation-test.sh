#!/usr/bin/env bash
# Real-ncurses coverage for the Org-backed, buffer-local gptel-style workflow.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-conversation-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-conversation.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_LLM_CONVERSATION_REPORT="$root/report"
export LEM_YATH_LLM_CONVERSATION_SLEEP="$(command -v sleep)"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-llm-conversation-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-llm-conversation.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe LLM-conversation cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME"
: >"$LEM_YATH_LLM_CONVERSATION_REPORT"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() {
  printf 'PASS  %-28s %s\n' "$1" "$2"
}

die() {
  printf 'FAIL  %-28s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,240p' "$LEM_YATH_LLM_CONVERSATION_REPORT" >&2 || true
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LLM_CONVERSATION_REPORT" 2>/dev/null || true
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

send_key() {
  lem_keys "$session" "$1"
  sleep 0.15
}

send_conversation() {
  send_key C-c
  send_key Enter
}

hex_text() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
}

fixture="$(lem-yath_lisp_string "$here/scripts/llm-conversation-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)"; then
  die boot 'could not start the isolated tmux/Lem process'
fi
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the conversation fixture'
fi
pass boot 'configured Lem loaded the isolated conversation fixture'

send_key F3
if ! wait_report_count \
  '^PASS STATIC buffer=\*scratch\* org=yes conversation=yes key=LEM-YATH-LLM-SEND shared=no$' 1; then
  die startup-mode 'startup scratch, mode, or C-c Return binding differed'
fi
pass startup-mode 'startup is an Org LLM conversation with C-c Return'

send_key F8
if ! wait_report_count '^SETUP-TYPED ' 1; then
  die typed-conversation 'could not prepare the typed conversation scenario'
fi
send_conversation
if ! wait_report_count '^SEND label=typed ' 1; then
  die typed-conversation 'C-c Return did not send the current typed user turn'
fi
if ! grep -qE '^MESSAGES count=3 roles=user,assistant,user$' \
  "$LEM_YATH_LLM_CONVERSATION_REPORT"; then
  die typed-conversation 'user and assistant turns were not reconstructed separately'
fi
typed_first=$(hex_text 'Earlier **question**.')
typed_assistant=$(hex_text 'Earlier answer.')
typed_current=$'Current [link](https://example.com) and **bold**.\n\n```sh\nprintf \'ok\\n\'\n```\nOutput:\n```text\nok\n```'
typed_current_hex=$(hex_text "$typed_current")
if ! grep -qE \
  "^MESSAGE index=0 role=user content-hex=$typed_first$" \
  "$LEM_YATH_LLM_CONVERSATION_REPORT" ||
   ! grep -qE \
  "^MESSAGE index=1 role=assistant content-hex=$typed_assistant$" \
  "$LEM_YATH_LLM_CONVERSATION_REPORT" ||
   ! grep -qE \
  "^MESSAGE index=2 role=user content-hex=$typed_current_hex$" \
  "$LEM_YATH_LLM_CONVERSATION_REPORT" ||
   ! grep -qE \
  "^SEND label=typed buffer=\\*scratch\\* prompt-hex=$typed_current_hex$" \
  "$LEM_YATH_LLM_CONVERSATION_REPORT"; then
  die typed-conversation 'typed contents or bounded Org-to-Markdown prompt differed'
fi
if ! wait_report_count '^DONE label=typed$' 1; then
  die typed-conversation 'the typed response did not finish before buffer reuse'
fi
pass typed-conversation 'typed roles and Org-to-Markdown prompt reached the backend intact'

send_key F9
if ! wait_report_count '^SETUP-REGION mark=yes$' 1; then
  die org-region 'could not prepare the active Org region scenario'
fi
send_conversation
region_expected=$(hex_text '**selected**')
if ! wait_report_count \
  "^SEND label=region buffer=\\*scratch\\* prompt-hex=$region_expected$" 1; then
  die org-region 'the active Org region was not rendered without conversation history'
fi
if ! wait_report_count '^DONE label=region$' 1; then
  die org-region 'the active Org region response did not finish before buffer reuse'
fi
pass org-region 'active Org region rendered independently as Markdown'

send_key F2
if ! wait_report_count '^SETUP label=origin ' 1; then
  die origin-setup 'could not prepare the origin-marker scenario'
fi
send_key i
if ! lem_wait_for "$session" 'INSERT' "$WAIT_TIMEOUT" >/dev/null; then
  die origin-send 'Lem did not enter Vi insert state'
fi
send_conversation
if ! wait_report_count '^FIRST label=origin$' 1; then
  die origin-send 'C-c Return did not stream the first local chunk'
fi
send_key F4
if ! wait_report_count '^EDIT label=origin active=yes$' 1; then
  die tracked-marker 'the interleaved user edit did not occur during the request'
fi
if ! wait_report_count '^DONE label=origin$' 1; then
  die tracked-marker 'the local response did not finish after the user edit'
fi
send_key F12
origin_expected=$(hex_text $'PREFIX\nhello\n\nalpha beta\n\n* _TAIL')
if ! grep -qE \
  "^STATE current=\\*scratch\\* prompt-hex=68656C6C6F scratch-hex=$origin_expected shared-hex= scratch-active=no shared-active=no assistant-role=ASSISTANT user-role=USER$" \
  "$LEM_YATH_LLM_CONVERSATION_REPORT"; then
  die tracked-marker 'response placement, roles, prompt, or buffer isolation differed'
fi
pass tracked-marker 'streaming stayed at the send marker across an interleaved edit'

send_key F5
if ! wait_report_count '^SETUP label=abort ' 1; then
  die local-abort 'could not prepare the abort scenario'
fi
send_conversation
if ! wait_report_count '^FIRST label=abort$' 1; then
  die local-abort 'the slow local response did not begin'
fi
send_key Escape
send_key Space
send_key g
send_key a
abort_expected=$(hex_text $'abort\n\npartial\n[request aborted]\n\n* _TAIL')
abort_ok=0
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  send_key F12
  if grep -qE \
    "^STATE current=\\*scratch\\* prompt-hex=61626F7274 scratch-hex=$abort_expected shared-hex= scratch-active=no shared-active=no " \
    "$LEM_YATH_LLM_CONVERSATION_REPORT"; then
    abort_ok=1
    break
  fi
  sleep 0.1
done
if [ "$abort_ok" -ne 1 ]; then
  die local-abort 'abort did not finalize and release the local request'
fi
pass local-abort 'SPC g a finalized the originating conversation safely'

send_key F6
if ! wait_report_count '^SETUP label=readonly .*read-only=yes$' 1; then
  die read-only-fallback 'could not prepare the read-only scenario'
fi
send_conversation
if ! wait_report_count '^DONE label=shared$' 1; then
  die read-only-fallback 'the read-only request did not use the shared fallback'
fi
send_key F12
scratch_expected=$(hex_text 'readonly')
shared_expected=$(hex_text $'\n## User (conversation-test)\n\nreadonly\n\n## Assistant\n\nfallback\n')
if ! grep -qE \
  "^STATE current=\\*scratch\\* prompt-hex=726561646F6E6C79 scratch-hex=$scratch_expected shared-hex=$shared_expected scratch-active=no shared-active=no " \
  "$LEM_YATH_LLM_CONVERSATION_REPORT"; then
  die read-only-fallback 'source or shared transcript content differed'
fi
pass read-only-fallback 'read-only conversation fell back without changing its source'

send_key F7
if ! wait_report_count '^SETUP label=kill ' 1; then
  die buffer-kill 'could not prepare the killed-conversation scenario'
fi
send_conversation
if ! wait_report_count '^FIRST label=kill$' 1; then
  die buffer-kill 'the process-backed local response did not begin'
fi
send_key Escape
send_key Space
send_key b
send_key k
if ! lem_wait_for "$session" 'kill anyway' "$WAIT_TIMEOUT" >/dev/null; then
  die buffer-kill 'SPC b k did not request confirmation for modified scratch'
fi
send_key y
kill_ok=0
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  send_key F11
  if grep -qE \
    '^KILL buffer=deleted active=no aborted=yes insertion=none process=nil saved-process=dead shared-active=no hook=1$' \
    "$LEM_YATH_LLM_CONVERSATION_REPORT"; then
    kill_ok=1
    break
  fi
  sleep 0.1
done
if [ "$kill_ok" -ne 1 ]; then
  die buffer-kill 'buffer deletion did not release the request and child process'
fi
pass buffer-kill 'SPC b k released request ownership and terminated its process'

printf 'All LLM conversation tests passed.\n'
