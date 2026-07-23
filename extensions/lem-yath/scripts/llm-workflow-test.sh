#!/usr/bin/env bash
# Real-TUI acceptance for named LLM presets and external web handoff.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-llm-workflow-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-llm-workflow.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
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
  "$root/project" "$WORKDIR/roam"
chmod 700 "$root/private"
: >"$LEM_YATH_LLM_WORKFLOW_REPORT"
printf 'initial context\n' >"$source_file"
printf '%s\n' \
  "((emacs-lisp-mode ." \
  "  ((eval . (local-set-key (kbd \"C-c i\") #'consult-outline))" \
  "   (outline-regexp . \";;;\")" \
  "   (lexical-binding . t)" \
  "   (eval . (defun vile-config/add-elisp-to-gptel-context nil" \
  "             (interactive)" \
  "             (mapcar #'gptel-add-file" \
  "                     (list" \
  "                      (expand-file-name \"./early-init.el\" user-emacs-directory)" \
  "                      (expand-file-name \"./init.el\" user-emacs-directory)" \
  "                      (expand-file-name \"./lisp/\" user-emacs-directory))))))))" \
  >"$root/project/.dir-locals.el"
mkdir -p "$root/project/lisp/.hidden"
printf 'EARLY-CONTEXT-SENTINEL\n' >"$root/project/early-init.el"
printf 'INIT-CONTEXT-SENTINEL\n' >"$root/project/init.el"
printf 'LISP-A-CONTEXT-SENTINEL\n' >"$root/project/lisp/init-a.el"
printf 'LISP-B-CONTEXT-SENTINEL\n' >"$root/project/lisp/init-b.el"
printf 'HIDDEN-CONTEXT-SENTINEL\n' >"$root/project/lisp/.hidden/hidden.el"
printf '\0binary\n' >"$root/project/lisp/binary.bin"
printf 'lisp/ignored-secret.el\n' >"$root/project/.gitignore"
printf 'IGNORED-CONTEXT-SENTINEL\n' >"$root/project/lisp/ignored-secret.el"
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
default_preset=quick-lookup

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

run_mx() {
  local command=$1
  send_key C-g
  send_key Escape
  send_key M-x
  if ! lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null; then
    return 1
  fi
  send_literal "$command"
  send_key Enter
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

send_key Space
send_key g
send_key L
if ! lem_wait_for "$session" 'temperature: 0.2' "$WAIT_TIMEOUT" >/dev/null; then
  die direct-full-menu 'SPC g L did not open the full settings menu'
fi
send_key t
if ! lem_wait_for "$session" 'use tools: on' "$WAIT_TIMEOUT" >/dev/null; then
  die full-tools 'the full menu did not toggle supported tools and reopen'
fi
send_key T
if ! lem_wait_for "$session" 'blank for API default' "$WAIT_TIMEOUT" >/dev/null; then
  die temperature-prompt 'the full menu did not open its temperature prompt'
fi
send_key BSpace
send_key BSpace
send_key BSpace
send_literal '1.25'
send_key Enter
if ! lem_wait_for "$session" 'temperature: 1.25' "$WAIT_TIMEOUT" >/dev/null; then
  die temperature-setting 'the validated temperature did not update the live menu'
fi
send_key c
if ! lem_wait_for "$session" 'Response tokens' "$WAIT_TIMEOUT" >/dev/null; then
  die token-prompt 'the full menu did not open its response-token prompt'
fi
send_key BSpace
send_key BSpace
send_key BSpace
send_literal '2048'
send_key Enter
if ! lem_wait_for "$session" 'response tokens: 2048' "$WAIT_TIMEOUT" >/dev/null; then
  die token-setting 'the validated token cap did not update the live menu'
fi
send_key x
if ! lem_wait_for "$session" 'request tracing: on' "$WAIT_TIMEOUT" >/dev/null; then
  die trace-on 'the full menu did not enable request tracing and reopen'
fi
send_key x
if ! lem_wait_for "$session" 'request tracing: off' "$WAIT_TIMEOUT" >/dev/null; then
  die trace-off 'the full menu did not disable request tracing and reopen'
fi
send_key q
send_key F12
if ! wait_report_count 'STATE current=custom backend=OPENROUTER model=openrouter/auto .*temperature=1.25 max=2048 tools=yes ' 1; then
  die full-menu-state 'full-menu controls did not update live request settings'
fi
pass direct-full-menu 'SPC g L changed supported live request settings'

send_key Space
send_key g
send_key L
send_literal '-'
if ! lem_wait_for "$session" 'add configured Emacs Lisp tree' "$WAIT_TIMEOUT" >/dev/null; then
  die context-submenu 'full-menu - did not open the gptel-style context actions'
fi
send_key e
if ! lem_wait_for "$session" 'context sources: 4' "$WAIT_TIMEOUT" >/dev/null; then
  die emacs-context-helper 'the audited Emacs helper did not add exactly four text files'
fi
send_key I
if ! lem_wait_for "$session" 'EARLY-CONTEXT-SENTINEL' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'LISP-B-CONTEXT-SENTINEL' "$WAIT_TIMEOUT" >/dev/null; then
  die context-inspect 'the context inspector did not render attached live files'
fi
send_key Space
send_key b
send_key k
send_key Space
send_key g
send_key L
send_literal '-'
send_key d
if ! lem_wait_for "$session" 'context sources: 0' "$WAIT_TIMEOUT" >/dev/null; then
  die context-clear 'full-menu -d did not clear buffer-local request context'
fi
send_key q
pass request-context 'physical -e, inspect, and -d context workflow passed'

send_key Space
send_key g
send_key l
if ! lem_wait_for "$session" 'open full LLM menu' "$WAIT_TIMEOUT" >/dev/null; then
  die compact-menu 'SPC g l did not retain the configured compact menu'
fi
send_key m
if ! lem_wait_for "$session" 'response tokens: 2048' "$WAIT_TIMEOUT" >/dev/null; then
  die compact-to-full 'compact m did not open the full LLM menu'
fi
send_key t
if ! lem_wait_for "$session" 'use tools: off' "$WAIT_TIMEOUT" >/dev/null; then
  die full-tools-off 'the full menu did not toggle tools back off'
fi
send_key q
pass compact-to-full 'compact m followed the configured Emacs route to full settings'

send_key F9
if ! wait_report_count '^ROUTING ready$' 1; then
  die response-routing-setup 'the response-routing fixture was not prepared'
fi
send_key Space
send_key g
send_key L
send_key k
if ! lem_wait_for "$session" 'Response to: kill-ring' "$WAIT_TIMEOUT" >/dev/null; then
  die kill-ring-destination 'the full menu did not retain the one-shot kill-ring target'
fi
send_key Enter
send_key F10
if ! wait_report_count '^ROUTING dispatches=1 prompt=ROUTING-PROMPT .*kill=ROUTED-RESPONSE-SENTINEL .* hidden=no$' 1; then
  die kill-ring-response 'the response was not copied exactly or its private sink leaked'
fi
pass kill-ring-response 'physical k then Return copied one response and cleaned its sink'

send_key F9
wait_report_count '^ROUTING ready$' 2 ||
  die echo-routing-setup 'the echo routing fixture was not reset'
send_key Space
send_key g
send_key L
send_key e
send_key Enter
if ! lem_wait_for "$session" 'response: ROUTED-RESPONSE-SENTINEL' "$WAIT_TIMEOUT" >/dev/null; then
  die echo-response 'the echo-area destination did not display the completed response'
fi
send_key F10
if ! wait_report_count '^ROUTING dispatches=1 prompt=ROUTING-PROMPT .* hidden=no$' 2; then
  die echo-response-cleanup 'the echo response did not complete exactly once and clean its sink'
fi
pass echo-response 'physical e then Return displayed one response without a transcript'

send_key F9
wait_report_count '^ROUTING ready$' 3 ||
  die buffer-routing-setup 'the buffer routing fixture was not reset'
send_key Space
send_key g
send_key L
send_key b
if ! lem_wait_for "$session" 'Output to buffer:' "$WAIT_TIMEOUT" >/dev/null; then
  die buffer-destination-prompt 'the gptel-style b destination did not prompt for a buffer'
fi
send_literal '*llm-route-target*'
send_key Enter
if ! lem_wait_for "$session" 'Response to: buffer \*llm-route-target\*' "$WAIT_TIMEOUT" >/dev/null; then
  die buffer-destination 'the selected response buffer was not retained by the menu'
fi
send_key Enter
if ! lem_wait_for "$session" 'LEFTROUTED-RESPONSE-SENTINELRIGHT' "$WAIT_TIMEOUT" >/dev/null; then
  die buffer-response 'the response was not inserted at the target buffer point'
fi
send_key F10
if ! wait_report_count '^ROUTING dispatches=1 prompt=ROUTING-PROMPT .*target=LEFTROUTED-RESPONSE-SENTINELRIGHT .*hidden=no$' 1; then
  die buffer-response-contract 'buffer routing changed source text, placement, or ownership'
fi
pass buffer-response 'physical b inserted at the exact point in another buffer'

send_key F9
wait_report_count '^ROUTING ready$' 4 ||
  die session-routing-setup 'the LLM-session routing fixture was not reset'
send_key Space
send_key g
send_key L
send_key g
if ! lem_wait_for "$session" 'Existing or new LLM session:' "$WAIT_TIMEOUT" >/dev/null; then
  die session-destination-prompt 'the gptel-style g destination did not prompt for a session'
fi
send_literal '*llm-route-session*'
send_key Enter
if ! lem_wait_for "$session" 'Response to: LLM session \*llm-route-session\*' "$WAIT_TIMEOUT" >/dev/null; then
  die session-destination 'the selected LLM session was not retained by the menu'
fi
send_key Enter
if ! lem_wait_for "$session" 'ROUTED-RESPONSE-SENTINEL' "$WAIT_TIMEOUT" >/dev/null; then
  die session-response 'the routed LLM session did not receive the response'
fi
send_key F10
if ! wait_report_count '^ROUTING dispatches=1 prompt=ROUTING-PROMPT roles= kill=.*session-mode=yes session=\* ROUTING-PROMPT|+ROUTED-RESPONSE-SENTINEL|+\*  hidden=no$' 1; then
  die session-response-contract 'the routed exchange changed source context or was not a reusable typed conversation'
fi
pass session-response 'physical g created a reusable Org LLM conversation'

send_key F4
if ! wait_report_count '^ROUTING followup-ready$' 1; then
  die session-followup-setup 'the existing-session follow-up was not prepared'
fi
send_key C-c
send_key Enter
send_key F10
if ! wait_report_count '^ROUTING dispatches=2 prompt=ROUTING-FOLLOWUP roles=user,assistant,user .*session-mode=yes session=\* ROUTING-PROMPT|+ROUTED-RESPONSE-SENTINEL|+\* ROUTING-FOLLOWUP|+ROUTED-RESPONSE-SENTINEL|+\*  hidden=no$' 1; then
  die session-followup-contract 'the existing session did not reconstruct and extend all typed turns'
fi
pass session-followup 'C-c Return continued the routed session with typed history and no stray prompt'

send_key F9
wait_report_count '^ROUTING ready$' 5 ||
  die preview-setup 'the request-preview fixture was not reset'
send_key Space
send_key g
send_key L
send_key J
if ! lem_wait_for "$session" '"dry_run": true' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" '"backend": "lem-yath-routing-test"' "$WAIT_TIMEOUT" >/dev/null; then
  die request-preview 'J did not open a normalized JSON request preview'
fi
send_key F11
if ! wait_report_count '^PREVIEW mode=yes readonly=yes dry=yes backend=lem-yath-routing-test prompt=ROUTING-PROMPT dispatches=0$' 1 ||
   ! wait_report_count '^PREVIEW secrets=absent$' 1; then
  die request-preview-contract 'preview mutated, dispatched, or omitted the effective prompt'
fi
send_key q
pass request-preview 'physical J opened a read-only credential-free dry run without dispatch'

if ! run_mx lem-yath-test-llm-workflow-rewrite-setup ||
   ! wait_report_count '^REWRITE ready$' 1; then
  die rewrite-setup 'the staged rewrite fixture was not prepared'
fi
send_key v
send_key '$'
send_key Space
send_key g
send_key L
if ! lem_wait_for "$session" 'rewrite selected region' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-menu 'the full gptel-style menu did not expose Visual rewrite'
fi
send_key r
if ! lem_wait_for "$session" 'Rewrite instruction:' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-prompt 'r did not prompt for the required change'
fi
send_literal 'make better'
send_key Enter
if ! lem_wait_for "$session" 'Proposed replacement' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'REWRITTEN' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-preview 'the first replacement was not staged in the preview buffer'
fi
if ! run_mx lem-yath-test-llm-workflow-rewrite-record ||
   ! wait_report_count '^REWRITE source=OLD pending=1 response=REWRITTEN preview=yes focus=preview dispatches=1 prompt=OLD|+What is the required change.*make better system=rewrite forward=no hidden=no ' 1; then
  die rewrite-contract 'the staged rewrite changed source, leaked state, or used the wrong directive'
fi
send_key D
if ! lem_wait_for "$session" '^--- current:' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" '^-OLD' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" '^[+]REWRITTEN' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-diff 'D did not open the bounded unified replacement diff'
fi
send_key q
send_key r
if ! lem_wait_for "$session" 'Rewrite instruction:' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-iterate-prompt 'r did not prompt to iterate on the staged proposal'
fi
send_literal 'make stronger'
send_key Enter
if ! lem_wait_for "$session" 'ITERATED' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-iterate 'the second request did not replace the staged proposal'
fi
if ! run_mx lem-yath-test-llm-workflow-rewrite-record ||
   ! wait_report_count '^REWRITE source=OLD pending=1 response=ITERATED preview=yes focus=preview dispatches=2 .*system=rewrite forward=no hidden=no ' 1; then
  die rewrite-iterate-contract 'iteration did not preserve source and replace only the proposal'
fi
send_key A
if ! lem_wait_for "$session" 'ITERATED' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-accept 'A did not replace the tracked source region'
fi
if ! run_mx lem-yath-test-llm-workflow-rewrite-record ||
   ! wait_report_count '^REWRITE source=ITERATED pending=0 response=none preview=no focus=source dispatches=2 .*forward=no hidden=no ' 1; then
  die rewrite-accept-contract 'acceptance did not clear all staged state'
fi
send_key u
if ! run_mx lem-yath-test-llm-workflow-rewrite-record ||
   ! wait_report_count '^REWRITE source=OLD pending=0 response=none preview=no focus=source dispatches=2 ' 1; then
  die rewrite-undo 'accepted replacement was not one Normal-state undo step'
fi
pass rewrite-accept 'Visual menu staged, diffed, iterated, accepted, and undid one replacement'

if ! run_mx lem-yath-test-llm-workflow-rewrite-setup ||
   ! wait_report_count '^REWRITE ready$' 2; then
  die rewrite-reject-setup 'the rejection fixture was not prepared'
fi
send_key v
send_key '$'
send_key Space
send_key g
send_key L
send_key r
if ! lem_wait_for "$session" 'Rewrite instruction:' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-reject-prompt 'the rejection rewrite did not prompt'
fi
send_literal 'discard this'
send_key Enter
if ! lem_wait_for "$session" 'REWRITTEN' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-reject-preview 'the rejection proposal was not staged'
fi
send_key K
if ! run_mx lem-yath-test-llm-workflow-rewrite-record ||
   ! wait_report_count '^REWRITE source=OLD pending=0 response=none preview=no focus=source dispatches=1 .*forward=no hidden=no ' 1; then
  die rewrite-reject 'K changed source text or retained staged resources'
fi
pass rewrite-reject 'K discarded the proposal without changing source text'

if ! run_mx lem-yath-test-llm-workflow-rewrite-setup ||
   ! wait_report_count '^REWRITE ready$' 3; then
  die rewrite-merge-setup 'the merge-conflict fixture was not prepared'
fi
send_key v
send_key '$'
send_key Space
send_key g
send_key L
send_key r
if ! lem_wait_for "$session" 'Rewrite instruction:' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-merge-prompt 'the merge rewrite did not prompt'
fi
send_literal 'merge this'
send_key Enter
if ! lem_wait_for "$session" 'REWRITTEN' "$WAIT_TIMEOUT" >/dev/null; then
  die rewrite-merge-preview 'the merge proposal was not staged'
fi
send_key M
if ! run_mx lem-yath-test-llm-workflow-rewrite-record ||
   ! wait_report_count '^REWRITE source=<<<<<<< original|OLD|=======|REWRITTEN|>>>>>>> lem-yath-rewrite-test| pending=0 response=none preview=no focus=source dispatches=1 .*forward=no hidden=no ' 1; then
  die rewrite-merge 'M did not insert and finalize the explicit merge conflict'
fi
send_key u
if ! run_mx lem-yath-test-llm-workflow-rewrite-record ||
   ! wait_report_count '^REWRITE source=OLD pending=0 response=none preview=no focus=source dispatches=1 ' 2; then
  die rewrite-merge-undo 'the merge conflict was not one Normal-state undo step'
fi
pass rewrite-merge 'M inserted an undoable explicit merge conflict'

if ! run_mx lem-yath-test-llm-workflow-variant-setup ||
   ! wait_report_count '^VARIANT ready$' 1; then
  die variant-setup 'the response-variant conversation was not prepared'
fi
send_key Space
send_key g
send_key L
if ! lem_wait_for "$session" 'Tweak response' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'regenerate' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-menu 'the full menu did not detect the assistant response at point'
fi
send_key M-Enter
if ! lem_wait_for "$session" 'VARIANT-TWO' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-regenerate 'M-Return did not regenerate the assistant span'
fi
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-TWO history=VARIANT-ONE dispatches=1 prompt=QUESTION roles=user contents=QUESTION settings=LEM-YATH-VARIANT-TEST,variant-model,variant system,0.55,321,NIL active=no visual=no selection=none$' 1; then
  die variant-regenerate-contract 'regeneration changed settings, transcript, history, or request ownership'
fi
send_key u
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-ONE history= dispatches=1 prompt=QUESTION roles=user contents=QUESTION settings=LEM-YATH-VARIANT-TEST,variant-model,variant system,0.55,321,NIL active=no visual=no selection=none$' 1; then
  die variant-regenerate-undo 'undo did not revive the original response semantics'
fi
send_key C-r
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-TWO history=VARIANT-ONE dispatches=1 .*active=no visual=no selection=none$' 2; then
  die variant-regenerate-redo 'redo did not revive the regenerated response semantics'
fi
send_key Space
send_key g
send_key L
if ! lem_wait_for "$session" 'previous variant' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-history-menu 'the regenerated response did not expose variant navigation'
fi
send_key P
if ! lem_wait_for "$session" 'VARIANT-ONE' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-previous 'P did not rotate to the previous response'
fi
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-ONE history=VARIANT-TWO dispatches=1 .*active=no visual=no selection=none$' 1; then
  die variant-previous-contract 'P did not rotate response text and history atomically'
fi
send_key Space
send_key g
send_key L
send_key N
if ! lem_wait_for "$session" 'VARIANT-TWO' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-next 'N did not rotate forward to the regenerated response'
fi
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-TWO history=VARIANT-ONE dispatches=1 .*active=no visual=no selection=none$' 3; then
  die variant-next-contract 'N did not restore response text and history atomically'
fi
send_key u
if ! lem_wait_for "$session" 'VARIANT-ONE' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-undo 'one Normal-state undo did not revert the variant rotation'
fi
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-ONE history=VARIANT-TWO dispatches=1 .*active=no visual=no selection=none$' 2; then
  die variant-undo-contract 'variant text and metadata were not one undo group'
fi
send_key C-r
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-TWO history=VARIANT-ONE dispatches=1 .*active=no visual=no selection=none$' 4; then
  die variant-redo-contract 'redo did not revive the regenerated text and metadata'
fi
send_key Space
send_key g
send_key L
send_key E
if ! lem_wait_for "$session" 'current-response$' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'VARIANT-TWO$' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'VARIANT-ONE$' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-diff 'E did not show the current and previous response variants'
fi
send_key q
send_key Space
send_key g
send_key L
send_key Space
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-TWO history=VARIANT-ONE dispatches=1 .*active=no visual=yes selection=VARIANT-TWO$' 1; then
  die variant-mark 'Space did not select exactly the assistant response span'
fi
pass response-variants 'M-Return, P, N, E, and Space passed through the real full menu'

if ! run_mx lem-yath-test-llm-workflow-variant-cli-setup ||
   ! wait_report_count '^VARIANT cli-ready$' 1; then
  die variant-cli-setup 'the native CLI refusal fixture was not prepared'
fi
send_key Space
send_key g
send_key L
send_key M-Enter
if ! lem_wait_for "$session" 'cannot safely regenerate in place' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-cli-refusal 'native resumable history was not refused explicitly'
fi
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-ONE history= dispatches=0 prompt=none roles= contents= settings= active=no visual=no selection=none$' 1; then
  die variant-cli-contract 'refused native CLI regeneration mutated the answer or dispatched a request'
fi
pass response-variant-safety 'one undo is exact and native resumable histories fail closed'

if ! run_mx lem-yath-test-llm-workflow-variant-fail-setup ||
   ! wait_report_count '^VARIANT fail-ready$' 1; then
  die variant-fail-setup 'the no-launch regeneration fixture was not prepared'
fi
send_key Space
send_key g
send_key L
send_key M-Enter
if ! lem_wait_for "$session" 'original response restored' "$WAIT_TIMEOUT" >/dev/null ||
   ! lem_wait_for "$session" 'VARIANT-ONE' "$WAIT_TIMEOUT" >/dev/null; then
  die variant-fail-restore 'a backend that did not launch lost the original response'
fi
send_key F1
if ! wait_report_count '^VARIANT response=VARIANT-ONE history= dispatches=1 prompt=QUESTION roles=user contents=QUESTION settings=LEM-YATH-VARIANT-FAIL-TEST,variant-model,variant system,0.55,321,NIL active=no visual=no selection=none$' 1; then
  die variant-fail-contract 'failed regeneration changed text, metadata, or request ownership'
fi
pass response-variant-launch-failure 'no-launch regeneration restored the exact original answer'

send_key F7
if ! wait_report_count '^CAPTURE ready$' 1; then
  die capture-setup 'the daily LLM capture fixture was not prepared'
fi
send_key M-x
if ! lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null; then
  die capture-command 'M-x did not open for the configured capture command'
fi
send_literal 'yath/llm-capture'
send_key Enter
if ! lem_wait_for "$session" 'Type in your prompt:' "$WAIT_TIMEOUT" >/dev/null; then
  die capture-prompt 'the exact configured capture command did not prompt'
fi
send_literal 'Daily capture prompt'
send_key Enter
if ! lem_wait_for "$session" 'CAPTURE-RESPONSE-SENTINEL' "$WAIT_TIMEOUT" >/dev/null; then
  die capture-response 'the captured response did not stream into the daily note'
fi
send_key F8
if ! wait_report_count '^CAPTURE PASS ' 1; then
  die capture-contract 'daily topic metadata or inline response placement differed'
fi
if ! grep -R -q '^\* Daily capture prompt :llm:$' "$WORKDIR/roam" ||
   ! grep -R -q '^CAPTURE-RESPONSE-SENTINEL$' "$WORKDIR/roam"; then
  die capture-save 'the verified daily capture was not saved to the roam tree'
fi
pass daily-llm-capture 'exact M-x command saved one tagged inline exchange'

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
if ! wait_report_count 'STATE current=fixture-preset backend=CODEX model=fixture-model system=fixture system temperature=0.7 max=1234 tools=no saved=yes file-mode=600 dir-mode=700 ' 1; then
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
for _ in $(seq 1 "${#default_preset}"); do
  send_key BSpace
done
send_literal 'fixture-preset'
send_key Enter
sleep 0.5
send_key F12
if ! wait_report_count 'STATE current=fixture-preset backend=CODEX model=fixture-model system=fixture system temperature=0.7 max=1234 tools=no saved=yes ' 1; then
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
