#!/usr/bin/env bash
# Real-ncurses acceptance coverage for the Embark-style action framework.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

id="${LEM_YATH_CHECK_ID:-actions-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-actions.XXXXXX")"
session="lem-yath-actions-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-actions.*)
      [ -d "$root" ] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe actions-test cleanup path: %s\n' "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_ACTIONS_ROOT="$root/fixture/"
export LEM_YATH_ACTIONS_REPORT="$root/report"
export LEM_YATH_ACTIONS_LAUNCH_REPORT="$root/launch-report"
export LEM_YATH_ACTIONS_SOURCE="$root/fixture/actions-source.txt"
export LEM_YATH_ACTIONS_BUFFER="$root/fixture/buffer-action.txt"
export LEM_YATH_ACTIONS_FAKE_BIN="$root/bin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$LEM_YATH_ACTIONS_ROOT/relative" "$LEM_YATH_ACTIONS_ROOT/find" \
  "$root/bin"
: >"$LEM_YATH_ACTIONS_REPORT"
: >"$LEM_YATH_ACTIONS_LAUNCH_REPORT"

printf '%s\n' \
  'prefix REGION_TARGET suffix' \
  'https://example.invalid/action?q=lem' \
  './relative/target.txt' \
  'fixture_identifier ' \
  'aa BLOCK one' \
  'x' \
  'cc BLOCK three' \
  '' >"$LEM_YATH_ACTIONS_SOURCE"
printf 'RELATIVE FILE ACTION TARGET\n' \
  >"$LEM_YATH_ACTIONS_ROOT/relative/target.txt"
printf 'FIND NAME ACTION TARGET\n' \
  >"$LEM_YATH_ACTIONS_ROOT/find/result.hit"
printf 'PEEK ACTION TARGET\n' \
  >"$LEM_YATH_ACTIONS_ROOT/peek-target.txt"
printf 'DELETED FILE ACTION TARGET\n' \
  >"$LEM_YATH_ACTIONS_ROOT/deleted-target.txt"
printf '.' >"$LEM_YATH_ACTIONS_BUFFER"

shell=$(command -v bash)
printf '%s\n' \
  "#!$shell" \
  'set -eu' \
  ': "${LEM_YATH_ACTIONS_LAUNCH_REPORT:?}"' \
  'printf "argc=%s arg=%s\\n" "$#" "$1" >>"$LEM_YATH_ACTIONS_LAUNCH_REPORT"' \
  >"$root/bin/xdg-open"
chmod +x "$root/bin/xdg-open"
export PATH="$root/bin:$PATH"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"

pass() {
  printf 'PASS  %-32s %s\n' "$1" "$2"
}

die() {
  printf 'FAIL  %-32s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  if [ -f "$LEM_YATH_ACTIONS_REPORT" ]; then
    sed -n '1,260p' "$LEM_YATH_ACTIONS_REPORT" >&2
  fi
  printf '\n--- launch report ---\n' >&2
  if [ -f "$LEM_YATH_ACTIONS_LAUNCH_REPORT" ]; then
    sed -n '1,80p' "$LEM_YATH_ACTIONS_LAUNCH_REPORT" >&2
  fi
  exit 1
}

report_count() {
  local pattern=$1
  grep -cE "$pattern" "$LEM_YATH_ACTIONS_REPORT" 2>/dev/null || true
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

launch_count() {
  local pattern=$1
  grep -cE "$pattern" "$LEM_YATH_ACTIONS_LAUNCH_REPORT" 2>/dev/null || true
}

wait_launch_count() {
  local pattern=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(launch_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_screen() {
  local pattern=$1 timeout=${2:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if lem_capture "$session" | grep -qiE "$pattern"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

send_keys() {
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep 0.12
  done
}

source_buffer() {
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" F7
  sleep 0.25
}

goto_source_line() {
  local line=$1
  source_buffer
  send_keys "$line" G 0
}

open_actions() {
  send_keys Space e a
}

record_state() {
  local before
  before=$(report_count '^STATE ')
  lem_keys "$session" F5
  wait_report_count '^STATE ' "$((before + 1))"
}

fixture="$(lem-yath_lisp_string "$here/scripts/actions-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)" \
  "$LEM_YATH_ACTIONS_SOURCE"; then
  die boot 'could not start the isolated tmux/Lem process'
fi

if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  die boot 'configured Lem did not load the actions fixture'
fi
pass boot 'configured Lem loaded the real-ncurses fixture'

lem_keys "$session" F6
if ! wait_report_count '^SUMMARY STATIC PASS failures=0 ' 1; then
  die static-contracts 'leader, completion, whitelist, or registry contract failed'
fi
pass static-contracts 'normal/visual leader and completion-local bindings are exact'
if ! grep -Fq "XDG path=$root/bin/xdg-open" "$LEM_YATH_ACTIONS_REPORT"; then
  die launcher-resolution 'the fixture xdg-open did not win executable resolution'
fi
pass launcher-resolution 'external actions resolve the isolated fixture launcher'

goto_source_line 2
open_actions
if ! wait_screen 'open URL' || ! wait_screen 'copy URL'; then
  die transient-labels 'URL action labels were not rendered'
fi
pass transient-labels 'the target-specific transient rendered its key labels'

lem_keys "$session" q
sleep 0.4
if lem_capture "$session" | grep -qiE 'open URL|copy URL'; then
  die transient-cancel 'q left the action transient visible'
fi
pass transient-cancel 'q canceled immediately without changing the target'

goto_source_line 2
open_actions
if ! wait_screen '\[1/3\][[:space:]]+URL:' || ! wait_screen 'open URL'; then
  die target-cycle 'the highest-priority URL target did not open first'
fi
open_actions
if ! wait_screen '\[2/3\][[:space:]]+Identifier:' ||
   ! wait_screen 'find definitions' ||
   lem_capture "$session" | grep -qiE 'open URL'; then
  die target-cycle 'repeating SPC e a did not advance to the identifier target'
fi
open_actions
if ! wait_screen '\[3/3\][[:space:]]+Buffer:' || ! wait_screen 'save buffer' ||
   lem_capture "$session" | grep -qiE 'find definitions'; then
  die target-cycle 'the second cycle did not advance to the buffer target'
fi
open_actions
if ! wait_screen '\[1/3\][[:space:]]+URL:' || ! wait_screen 'open URL' ||
   lem_capture "$session" | grep -qiE 'save buffer'; then
  die target-cycle 'the target cycle did not wrap to the URL'
fi
lem_keys "$session" q
pass target-cycle 'repeated SPC e a cycled URL, identifier, buffer, then wrapped'

goto_source_line 2
open_actions
open_actions
if ! wait_screen 'copy identifier'; then
  die target-cycle-dispatch 'the cycled identifier menu did not remain actionable'
fi
before=$(report_count '^STATE ')
lem_keys "$session" w
sleep 0.25
lem_keys "$session" F5
if ! wait_report_count '^STATE ' "$((before + 1))" ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^STATE .*kill=https ';
then
  die target-cycle-dispatch 'w acted on the wrong target after cycling'
fi
pass target-cycle-dispatch 'an action used the cycled target rather than the first target'

goto_source_line 2
before=$(report_count '^STATE ')
lem_keys "$session" Space e a w
sleep 0.35
lem_keys "$session" F5
if ! wait_report_count '^STATE ' "$((before + 1))" ||
   ! grep -qE '^STATE .*kill=https://example\.invalid/action\?q=lem ' \
     "$LEM_YATH_ACTIONS_REPORT"; then
  die fast-dispatch 'the uninterrupted leader/action chord did not copy the URL'
fi
if [ -s "$LEM_YATH_ACTIONS_LAUNCH_REPORT" ]; then
  die url-copy-safety 'copying a URL invoked the external launcher'
fi
pass fast-dispatch 'SPC e a w dispatched before any delayed leader help'
pass url-copy-safety 'URL copy populated the kill ring without launching anything'

goto_source_line 2
open_actions
lem_keys "$session" Enter
if ! wait_launch_count \
  '^argc=1 arg=https://example\.invalid/action\?q=lem$' 1; then
  die url-external 'Return did not pass the exact URL as one launcher argument'
fi
pass url-external 'Return opened the exact URL through one argv element'

source_buffer
send_keys g g w v e
open_actions
if ! wait_screen 'copy region' || lem_capture "$session" | grep -qi 'find definitions'; then
  die visual-forward-priority 'the forward region did not outrank identifier actions'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^STATE .*kill=REGION_TARGET text=prefix REGION_TARGET suffix\\n'; then
  die visual-forward-copy 'forward visual copy changed text or copied the wrong target'
fi
if ! cmp -s "$LEM_YATH_ACTIONS_SOURCE" \
  <(printf '%s\n' 'prefix REGION_TARGET suffix' \
    'https://example.invalid/action?q=lem' './relative/target.txt' \
    'fixture_identifier ' 'aa BLOCK one' 'x' \
    'cc BLOCK three' ''); then
  die visual-forward-copy 'forward visual action mutated the file'
fi
pass visual-forward-priority 'forward visual region outranked the identifier target'
pass visual-forward-copy 'forward visual copy preserved the source byte-for-byte'

source_buffer
send_keys g g w e v b
open_actions
if ! wait_screen 'copy region'; then
  die visual-reverse-priority 'the reverse selection was not detected as a region'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^STATE .*kill=REGION_TARGET text=prefix REGION_TARGET suffix\\n'; then
  die visual-reverse-copy 'reverse visual copy changed text or copied the wrong target'
fi
pass visual-reverse-priority 'reverse visual orientation retained region priority'
pass visual-reverse-copy 'reverse visual copy preserved the source byte-for-byte'

goto_source_line 5
send_keys 3 l C-v 2 j 4 l
open_actions
if ! wait_screen 'copy region' || lem_capture "$session" | grep -qi 'find definitions'; then
  die visual-block-priority 'the forward Visual Block did not become a region target'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^STATE .*visual=block .*kill=BLOCK one\\nx\\ncc BLOCK text='; then
  die visual-block-copy 'the forward block did not copy the linear Embark region'
fi
pass visual-block-priority 'Visual Block outranked point-local targets as an active region'
pass visual-block-copy 'forward Visual Block copied the exact Evil-expanded linear region'

goto_source_line 7
send_keys 7 l C-v 2 k 4 h
open_actions
if ! wait_screen 'copy region'; then
  die visual-block-reverse 'the reverse Visual Block did not become a region target'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^STATE .*visual=block .*kill=BLOCK one\\nx\\ncc BLOCK text='; then
  die visual-block-reverse 'the reverse block changed the expanded region text or state'
fi
pass visual-block-reverse 'reverse Visual Block retained the same exact region target and state'

goto_source_line 3
open_actions
if ! wait_screen 'visit file' || ! wait_screen 'copy path'; then
  die relative-file-menu 'the existing relative path was not classified as a file'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -Fq \
     "kill=$LEM_YATH_ACTIONS_ROOT"'relative/target.txt '; then
  die relative-file-copy 'copy path did not resolve the relative target'
fi
pass relative-file-copy 'relative file copy used the resolved existing pathname'

goto_source_line 3
open_actions
lem_keys "$session" Enter
if ! wait_screen 'RELATIVE FILE ACTION TARGET'; then
  die relative-file-visit 'Return did not visit the existing relative file'
fi
pass relative-file-visit 'Return visited the exact existing relative target'

goto_source_line 3
open_actions
lem_keys "$session" x
if ! wait_launch_count \
  "^argc=1 arg=$LEM_YATH_ACTIONS_ROOT"'relative/target\.txt$' 1; then
  die file-external 'x did not pass the resolved file as one launcher argument'
fi
pass file-external 'x opened the resolved file through one argv element'

goto_source_line 4
open_actions
if ! wait_screen 'find definitions' || ! wait_screen 'find references'; then
  die identifier-menu 'identifier actions were not offered by local handlers'
fi
lem_keys "$session" d
if ! wait_report_count \
  '^HANDLER kind=definition symbol=fixture_identifier ' 1; then
  die identifier-definition 'd did not invoke the deterministic definition handler'
fi
pass identifier-definition 'd delegated to the buffer-local definition handler'

goto_source_line 4
open_actions
lem_keys "$session" r
if ! wait_report_count \
  '^HANDLER kind=references symbol=fixture_identifier ' 1; then
  die identifier-references 'r did not invoke the deterministic reference handler'
fi
pass identifier-references 'r delegated to the buffer-local reference handler'

before=$(report_count '^HANDLER kind=definition symbol=fixture_identifier ')
goto_source_line 4
lem_keys "$session" '$'
open_actions
if ! wait_screen 'find definitions'; then
  die identifier-boundary 'trailing whitespace did not retain the identifier target'
fi
lem_keys "$session" d
if ! wait_report_count '^HANDLER kind=definition symbol=fixture_identifier ' \
  "$((before + 1))"; then
  die identifier-boundary 'definition handler received a point outside the identifier'
fi
pass identifier-boundary 'identifier actions use an in-symbol point at a whitespace boundary'

source_buffer
lem_keys "$session" F8
if ! wait_report_count '^NATIVE ready=yes$' 1; then
  die native-context-setup 'fixture context menu was not installed'
fi
open_actions
if ! wait_screen 'mode context menu'; then
  die native-context-menu 'the generic action transient omitted native delegation'
fi
lem_keys "$session" m
if ! wait_screen 'Native fixture action'; then
  die native-context-menu 'm did not open the native buffer context menu'
fi
lem_keys "$session" Enter
if ! wait_report_count '^NATIVE selected=yes$' 1; then
  die native-context-menu 'native context-menu callback did not run'
fi
pass native-context-menu 'm delegated through Lem’s native buffer context menu'

source_buffer
lem_keys "$session" F10
if ! wait_screen 'Action completion:'; then
  die completion-boot 'fixture prompt did not open'
fi
if ! wait_screen 'ACTION-CANDIDATE'; then
  die completion-popup 'prompt completion did not focus the fixture candidate'
fi
before=$(report_count '^PROMPT ')
lem_keys "$session" F9
if ! wait_report_count '^PROMPT ' "$((before + 1))" ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^PROMPT live=yes completion=yes focus=ACTION-CANDIDATE input= kill=.* accept=0$'; then
  die completion-popup 'the pre-action focus or prompt input was not deterministic'
fi
lem_keys "$session" F4
if ! wait_report_count '^DIRECT reset=completion-diagnostic-sentinel$' 1 ||
   ! grep -qE \
     '^DIRECT target=yes generation=[0-9]+ presented=[0-9]+ current=yes result=INVOKED kill=accepted-action-candidate accept=0$' \
     "$LEM_YATH_ACTIONS_REPORT"; then
  die completion-direct 'the production completion target or copy action failed directly'
fi
send_keys C-c a
if ! wait_screen 'copy completion'; then
  die completion-action-menu 'C-c a did not open the completion-only actions'
fi
lem_keys "$session" w
sleep 0.25
before=$(report_count '^PROMPT ')
lem_keys "$session" F9
if ! wait_report_count '^PROMPT ' "$((before + 1))" ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^PROMPT live=yes completion=yes focus=ACTION-CANDIDATE input= kill=accepted-action-candidate accept=0$'; then
  die completion-copy 'copy accepted, closed, or changed the prompt candidate'
fi
pass completion-copy 'C-c a w copied focus while leaving the prompt usable and unaccepted'

send_keys C-c a
if ! wait_screen 'accept completion'; then
  die completion-accept 'C-c a did not offer acceptance for the live candidate'
fi
lem_keys "$session" Enter
if ! wait_report_count '^COMPLETION accept=1 label=ACTION-CANDIDATE ' 1; then
  die completion-accept 'C-c a Return did not accept the captured candidate once'
fi
lem_keys "$session" Enter
if ! wait_report_count \
  '^COMPLETION result=accepted-action-candidate accept=1$' 1; then
  die completion-accept 'the prompt result or exactly-once count was wrong'
fi
if grep -q '^COMPLETION accept=2 ' "$LEM_YATH_ACTIONS_REPORT"; then
  die completion-accept 'candidate acceptance ran more than once'
fi
pass completion-accept 'C-c a Return accepted the captured candidate exactly once'

source_buffer
lem_keys "$session" F11
if ! wait_screen 'Status:[[:space:]]+1 match'; then
  die find-name-result 'the real asynchronous find-name result did not arrive'
fi
open_actions
if ! wait_screen 'visit file' || ! wait_screen 'copy path'; then
  die find-name-result 'the property-backed row was not a file action target'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -Fq \
     "kill=$LEM_YATH_ACTIONS_ROOT"'find/result.hit '; then
  die find-name-copy 'find-name row copy lost its exact property-backed path'
fi
pass find-name-copy 'a real find-name row copied its exact result pathname'

open_actions
lem_keys "$session" Enter
if ! wait_screen 'FIND NAME ACTION TARGET'; then
  die find-name-visit 'Return did not visit the real find-name result'
fi
pass find-name-visit 'Return visited the real property-backed find-name result'

source_buffer
lem_keys "$session" F12
if ! wait_screen 'PEEK ACTION TARGET'; then
  die peek-result 'fixture peek-source collector did not display'
fi
open_actions
if ! wait_screen 'visit location' || ! wait_screen 'copy line'; then
  die peek-result 'peek row was not classified as a location target'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     'kill=.*PEEK ACTION TARGET'; then
  die peek-copy 'peek result copy did not preserve its rendered line'
fi
pass peek-copy 'peek-source result copied its rendered location line'

open_actions
lem_keys "$session" Enter
sleep 0.35
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^STATE buffer=peek-target\.txt file=peek-target\.txt visual=none .*text=PEEK ACTION TARGET\\n$'; then
  die peek-visit 'Return did not visit the peek result source'
fi
pass peek-visit 'Return visited the location returned by peek-source'

lem_keys "$session" F3
if ! wait_screen '^\.[[:space:]]*$'; then
  die buffer-action-setup 'the dedicated file-backed buffer did not open'
fi
send_keys A
tmux_cmd send-keys -t "$session" -l '!'
send_keys Escape
open_actions
if ! wait_screen 'save buffer' || ! wait_screen 'revert buffer' ||
   ! wait_screen 'kill buffer' || ! wait_screen 'copy buffer'; then
  die buffer-action-menu 'the live file-backed buffer actions were incomplete'
fi
lem_keys "$session" w
sleep 0.25
if ! record_state ||
   ! tail -n 1 "$LEM_YATH_ACTIONS_REPORT" | grep -qE \
     '^STATE buffer=buffer-action\.txt .*kill=buffer-action\.txt .*text=\.!$'; then
  die buffer-copy 'w did not copy the exact buffer name without changing content'
fi
pass buffer-copy 'w copied the exact live buffer name'

open_actions
lem_keys "$session" s
sleep 0.35
if [ "$(cat "$LEM_YATH_ACTIONS_BUFFER")" != '.!' ]; then
  die buffer-save 's did not persist the modified target buffer'
fi
pass buffer-save 's persisted the target buffer through the action menu'

printf 'REVERTED!' >"$LEM_YATH_ACTIONS_BUFFER"
open_actions
lem_keys "$session" r
if ! wait_screen 'REVERTED!'; then
  die buffer-revert 'r did not replace the clean buffer with its changed file'
fi
before=$(report_count '^BUFFER live=')
lem_keys "$session" F2
if ! wait_report_count '^BUFFER live=yes modified=no text=REVERTED!$' \
     "$((before + 1))"; then
  die buffer-revert 'the reverted target state was not clean and exact'
fi
pass buffer-revert 'r reloaded the externally changed file into a clean buffer'

open_actions
if ! wait_screen 'Identifier:'; then
  die buffer-kill 'the identifier target did not precede the buffer after revert'
fi
open_actions
if ! wait_screen 'Buffer: buffer-action\.txt'; then
  die buffer-kill 'repeating SPC e a did not select the buffer target'
fi
killed_before=$(report_count '^BUFFER killed=yes name=buffer-action\.txt$')
lem_keys "$session" k
if ! wait_report_count '^BUFFER killed=yes name=buffer-action\.txt$' \
     "$((killed_before + 1))"; then
  die buffer-kill 'k did not kill the selected clean target buffer'
fi
before=$(report_count '^BUFFER live=no$')
lem_keys "$session" F2
if ! wait_report_count '^BUFFER live=no$' "$((before + 1))"; then
  die buffer-kill 'the killed target remained in the live buffer list'
fi
pass buffer-kill 'k killed the selected buffer and released its live target'

source_buffer
before=$(report_count '^STALE origin-gone=')
lem_keys "$session" S-F6
if ! wait_report_count '^STALE origin-gone=yes .*responsive=yes$' \
  "$((before + 1))"; then
  die stale-origin 'dispatch against a deleted origin escaped or switched buffers'
fi
pass stale-origin 'a deleted origin was rejected without destabilizing the editor'

before=$(report_count '^STALE file-gone=')
lem_keys "$session" S-F7
if ! wait_report_count '^STALE file-gone=yes .*responsive=yes$' \
  "$((before + 1))"; then
  die deleted-file 'dispatch against a deleted file destabilized the editor'
fi
pass deleted-file 'a vanished file target failed safely in its live origin'

before=$(report_count '^RELOAD ')
lem_keys "$session" S-F8
if ! wait_report_count '^RELOAD ' "$((before + 1))" "$BOOT_TIMEOUT"; then
  die reload-idempotence 'reloading actions did not complete'
fi
reload_line=$(grep '^RELOAD ' "$LEM_YATH_ACTIONS_REPORT" | tail -n 1)
if ! grep -qE \
  '^RELOAD providers-before=([0-9]+) providers-after=\1 actions-before=([0-9]+) actions-after=\2 normal=yes visual=yes completion=yes$' \
  <<<"$reload_line"; then
  die reload-idempotence "registry or key counts changed: $reload_line"
fi
pass reload-idempotence 'reload retained one registry population and each exact binding'

printf '\n'
sed -n '1,300p' "$LEM_YATH_ACTIONS_REPORT"
printf 'ACTIONS TEST PASSED\n'
