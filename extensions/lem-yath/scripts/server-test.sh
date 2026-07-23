#!/usr/bin/env bash
# Real-ncurses coverage for the reusable Lem server and lemclient workflow.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-server-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-server.XXXXXX")"
session="lem-yath-server-$id"
origin="$root/origin.txt"
first="$root/first file;safe.txt"
second="$root/second.txt"
nowait="$root/nowait.txt"
abort="$root/abort.txt"
focus_file="$root/focus.txt"

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_SERVER_SOCKET="$root/runtime/server.sock"
export LEM_YATH_SERVER_PANE_FILE="$root/runtime/server.pane"
export LEM_YATH_SERVER_REPORT="$root/report"
export LEM_YATH_SERVER_ABORT_FILE="$abort"

LEM_CLIENT="${LEM_CLIENT:-$(dirname "$LEM_BIN")/lemclient}"
client_pid=
tmux_attach_pid=
attach_fd_open=0

cleanup() {
  if [[ -n ${client_pid:-} ]] && kill -0 "$client_pid" 2>/dev/null; then
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  if [[ -n ${tmux_attach_pid:-} ]] && kill -0 "$tmux_attach_pid" 2>/dev/null; then
    kill "$tmux_attach_pid" 2>/dev/null || true
    wait "$tmux_attach_pid" 2>/dev/null || true
  fi
  if ((attach_fd_open)); then
    exec 9>&-
    attach_fd_open=0
  fi
  if declare -F lem_stop >/dev/null; then
    lem_stop "$session" || true
  fi
  case "${root:-}" in
    */lem-yath-server.*)
      [[ -d $root ]] && rm -rf -- "$root"
      ;;
    *)
      printf 'Refusing unsafe server-test cleanup path: %s\n' \
        "${root:-<unset>}" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

mkdir -p "$HOME" "$XDG_CACHE_HOME"
: >"$LEM_YATH_SERVER_REPORT"
printf 'ORIGIN\n' >"$origin"
printf 'alpha\nbravo\ncharlie\n' >"$first"
printf 'second\n' >"$second"
printf 'nowait-one\nnowait-two\n' >"$nowait"
printf 'abort-original\n' >"$abort"
printf 'focus-target\n' >"$focus_file"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
KEY_DELAY="${KEY_DELAY:-0.18}"

pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }

die() {
  printf 'FAIL  %-26s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,240p' "$LEM_YATH_SERVER_REPORT" >&2 || true
  printf '\n--- client output ---\n' >&2
  for client_file in client.out client.err client.status; do
    printf '%s:\n' "$client_file" >&2
    sed -n '1,80p' "$root/$client_file" 2>/dev/null >&2 || true
  done
  exit 1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_SERVER_REPORT" 2>/dev/null || true
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
  sleep "$KEY_DELAY"
}

send_literal() {
  tmux_cmd send-keys -t "$session" -l "$1"
  sleep "$KEY_DELAY"
}

record_state() {
  local before
  before=$(report_count '^STATE ')
  send_key F12
  wait_report_count '^STATE ' "$((before + 1))"
}

last_state() {
  grep '^STATE ' "$LEM_YATH_SERVER_REPORT" | tail -n 1
}

start_client() {
  rm -f "$root/client.out" "$root/client.err" "$root/client.status"
  (
    trap - EXIT INT TERM
    set +e
    "$LEM_CLIENT" "$@" >"$root/client.out" 2>"$root/client.err"
    printf '%d\n' "$?" >"$root/client.status"
  ) &
  client_pid=$!
}

wait_client() {
  local timeout=${1:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    [[ -s $root/client.status ]] && return 0
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

assert_client_status() {
  local expected=$1 label=$2
  wait_client || die "$label" 'lemclient did not return'
  wait "$client_pid" || true
  client_pid=
  [[ $(<"$root/client.status") == "$expected" ]] ||
    die "$label" "lemclient returned $(<"$root/client.status"), expected $expected"
}

fixture="$(lem-yath_lisp_string "$here/scripts/server-fixture.lisp")"
form="(load #P$fixture)"
tmux_cmd kill-session -t "$session" 2>/dev/null || true
printf -v command '%q ' env \
  "LEM_YATH_SERVER_SOCKET=$LEM_YATH_SERVER_SOCKET" \
  "LEM_YATH_SERVER_PANE_FILE=$LEM_YATH_SERVER_PANE_FILE" \
  "LEM_YATH_SERVER_REPORT=$LEM_YATH_SERVER_REPORT" \
  "LEM_YATH_SERVER_ABORT_FILE=$LEM_YATH_SERVER_ABORT_FILE" \
  "$LEM_BIN" --eval "$form" "$origin"
tmux_cmd new-session -d -s "$session" -x 160 -y 50 "$command"

if ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT" ||
   ! lem_wait_for "$session" 'ORIGIN' "$BOOT_TIMEOUT" >/dev/null; then
  die boot 'configured Lem did not reach the origin buffer'
fi
for _ in $(seq 1 $((BOOT_TIMEOUT * 4))); do
  [[ -S $LEM_YATH_SERVER_SOCKET && -f $LEM_YATH_SERVER_PANE_FILE ]] && break
  sleep 0.25
done
[[ -S $LEM_YATH_SERVER_SOCKET && -f $LEM_YATH_SERVER_PANE_FILE ]] ||
  die boot 'server socket or pane metadata did not appear'

send_key F7
wait_report_count '^SUMMARY STATIC PASS failures=0$' 1 ||
  die static-contracts 'server maps, hooks, or editor environment differ'
[[ $(stat -c '%a' "$root/runtime") == 700 ]] ||
  die private-metadata 'runtime directory is not mode 0700'
[[ $(stat -c '%a' "$LEM_YATH_SERVER_SOCKET") == 600 ]] ||
  die private-metadata 'server socket is not mode 0600'
[[ $(stat -c '%a' "$LEM_YATH_SERVER_PANE_FILE") == 600 ]] ||
  die private-metadata 'pane file is not mode 0600'
mapfile -t pane_metadata <"$LEM_YATH_SERVER_PANE_FILE"
[[ ${#pane_metadata[@]} == 2 && -n ${pane_metadata[0]} &&
   ${pane_metadata[1]} =~ ^%[0-9]+$ ]] ||
  die private-metadata 'pane metadata does not contain a tmux pane ID'
pass static-contracts 'server maps, hooks, and editor variables initialize once'
pass private-metadata 'socket directory and metadata are owner-private'

bad_response=$(printf 'BAD\0' | socat - "UNIX-CONNECT:$LEM_YATH_SERVER_SOCKET" || true)
grep -q '^ERROR Unsupported server protocol$' <<<"$bad_response" ||
  die malformed-request 'invalid protocol did not receive a bounded error'
[[ -S $LEM_YATH_SERVER_SOCKET ]] ||
  die malformed-request 'invalid protocol stopped the server'
pass malformed-request 'invalid clients are rejected without stopping the server'

start_client --no-focus +2:3 "$first" "$second"
lem_wait_for "$session" 'bravo' "$WAIT_TIMEOUT" >/dev/null ||
  die multi-file-wait 'the first requested file was not displayed'
[[ ! -s $root/client.status ]] ||
  die multi-file-wait 'blocking client returned before the first edit'
record_state || die multi-file-wait 'first request state was not recordable'
grep -Fq 'file=first file;safe.txt line=2 column=3 mode=yes requests=1' \
  <<<"$(last_state)" ||
  die multi-file-wait "unexpected first location: $(last_state)"
send_key i
send_literal X
send_key Escape
send_key Z
send_key Z
lem_wait_for "$session" '^second$' "$WAIT_TIMEOUT" >/dev/null ||
  die multi-file-wait 'finishing the first file did not advance to the second'
record_state || die multi-file-wait 'second request state was not recordable'
grep -Fq 'file=second.txt line=1 column=0 mode=yes requests=1' \
  <<<"$(last_state)" ||
  die multi-file-wait "unexpected second location: $(last_state)"
[[ ! -s $root/client.status ]] ||
  die multi-file-wait \
    "client returned $(<"$root/client.status") before every requested file finished"
send_key A
send_literal 'TWO'
send_key Escape
send_key Z
send_key Z
assert_client_status 0 multi-file-wait
grep -q '^braXvo$' "$first" ||
  die multi-file-wait 'first edit was not saved at the requested column'
grep -q '^secondTWO$' "$second" ||
  die multi-file-wait 'second edit was not saved'
lem_wait_for "$session" 'ORIGIN' "$WAIT_TIMEOUT" >/dev/null ||
  die multi-file-wait 'completed request did not return to its origin buffer'
pass multi-file-wait 'one client blocks across positioned multi-file edits and saves'

set +e
"$LEM_CLIENT" --no-focus --no-wait +2:1 "$nowait" \
  >"$root/nowait.out" 2>"$root/nowait.err"
nowait_status=$?
set -e
[[ $nowait_status == 0 ]] || die no-wait "client returned $nowait_status"
lem_wait_for "$session" 'nowait-two' "$WAIT_TIMEOUT" >/dev/null ||
  die no-wait 'no-wait file was not displayed'
record_state || die no-wait 'no-wait state was not recordable'
grep -Fq 'file=nowait.txt line=2 column=1 mode=no requests=0' \
  <<<"$(last_state)" || die no-wait "unexpected state: $(last_state)"
pass no-wait 'nonblocking opens return immediately without edit-session state'

start_client --no-focus "$abort"
lem_wait_for "$session" 'abort-original' "$WAIT_TIMEOUT" >/dev/null ||
  die abort 'abort target was not displayed'
send_key A
send_literal 'DISCARD'
send_key Escape
send_key Z
send_key Q
assert_client_status 1 abort
lem_wait_for "$session" 'nowait-two' "$WAIT_TIMEOUT" >/dev/null ||
  die abort 'aborting did not restore the request origin buffer'
state_before=$(report_count '^STATE ')
send_key F11
wait_report_count '^STATE ' "$((state_before + 1))" ||
  die abort 'retained abort buffer state was not recordable'
grep -Fq 'file=abort.txt line=1' <<<"$(last_state)" ||
  die abort 'aborting did not retain the edited buffer for recovery'
grep -Fq 'mode=no requests=0 modified=yes' <<<"$(last_state)" ||
  die abort "abort state differed: $(last_state)"
[[ $(<"$abort") == abort-original ]] ||
  die abort 'aborting persisted the discarded edit'
send_key u
record_state || die abort 'cleaned abort state was not recordable'
grep -Fq 'modified=no' <<<"$(last_state)" ||
  die abort 'undo did not clean the intentionally retained aborted edit'
pass abort 'ZQ reports failure, preserves disk, and leaves the unsaved buffer recoverable'

start_client --no-focus
attached=0
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  record_state || die pane-attach 'zero-file request state was not recordable'
  if grep -Fq 'file=abort.txt' <<<"$(last_state)" &&
     grep -Fq 'mode=yes requests=1' <<<"$(last_state)"; then
    attached=1
    break
  fi
  sleep 0.25
done
[[ $attached == 1 ]] ||
  die pane-attach "zero-file client did not attach: $(last_state)"
grep -Fq 'file=abort.txt' <<<"$(last_state)" ||
  die pane-attach 'zero-file client changed the current buffer'
[[ ! -s $root/client.status ]] ||
  die pane-attach 'zero-file client did not wait for pane editing'
send_key C-x
send_key '#'
assert_client_status 0 pane-attach
pass pane-attach 'lemclient with no files attaches to and waits on the current pane'

mapfile -t pane_metadata <"$LEM_YATH_SERVER_PANE_FILE"
lem_pane=${pane_metadata[1]}
origin_pane=$(tmux_cmd new-window -d -P -F '#{pane_id}' \
  -t "$session" -n client-shell 'bash --noprofile --norc')
attach_fifo="$root/tmux-attach.fifo"
mkfifo "$attach_fifo"
exec 9<>"$attach_fifo"
attach_fd_open=1
printf -v attach_command '%q ' "$TMUX_BIN" -L "$TMUX_SOCKET" \
  attach-session -t "$session"
script -q -c "$attach_command" /dev/null \
  <"$attach_fifo" >"$root/tmux-client.out" 2>"$root/tmux-client.err" &
tmux_attach_pid=$!
attached_client=
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  attached_client=$(tmux_cmd list-clients -F '#{client_name}' | head -n 1 || true)
  [[ -n $attached_client ]] && break
  sleep 0.25
done
[[ -n $attached_client ]] || die focus-handoff 'tmux client did not attach'
tmux_cmd switch-client -c "$attached_client" -t "$origin_pane"
focus_status="$root/focus.status"
printf -v focus_command '%q ' env \
  "LEM_YATH_SERVER_SOCKET=$LEM_YATH_SERVER_SOCKET" \
  "LEM_YATH_SERVER_PANE_FILE=$LEM_YATH_SERVER_PANE_FILE" \
  "$LEM_CLIENT" "$focus_file"
printf -v status_command '; echo $? > %q' "$focus_status"
tmux_cmd send-keys -t "$origin_pane" -l "$focus_command$status_command"
tmux_cmd send-keys -t "$origin_pane" Enter
focused=0
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  client_pane=$(tmux_cmd display-message -p -c "$attached_client" '#{pane_id}')
  if [[ $client_pane == "$lem_pane" ]] &&
     tmux_cmd capture-pane -p -t "$lem_pane" | grep -q 'focus-target'; then
    focused=1
    break
  fi
  sleep 0.25
done
[[ $focused == 1 ]] ||
  die focus-handoff 'lemclient did not focus the published Lem pane'
tmux_cmd send-keys -t "$lem_pane" Z Z
restored=0
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  client_pane=$(tmux_cmd display-message -p -c "$attached_client" '#{pane_id}')
  if [[ -s $focus_status && $(<"$focus_status") == 0 &&
        $client_pane == "$origin_pane" ]]; then
    restored=1
    break
  fi
  sleep 0.25
done
[[ $restored == 1 ]] ||
  die focus-handoff 'lemclient did not restore its originating pane'
kill "$tmux_attach_pid" 2>/dev/null || true
wait "$tmux_attach_pid" 2>/dev/null || true
tmux_attach_pid=
exec 9>&-
attach_fd_open=0
tmux_cmd kill-window -t "$origin_pane"
pass focus-handoff 'attached tmux client focuses Lem and returns to its origin pane'

set +e
"$LEM_CLIENT" --no-focus +9 >"$root/dangling.out" 2>"$root/dangling.err"
dangling_status=$?
set -e
if [[ $dangling_status != 2 ]] ||
   ! grep -q 'must precede a file' "$root/dangling.err"; then
  die cli-validation 'dangling location was not rejected before connection'
fi
pass cli-validation 'invalid location-only invocation fails clearly'

send_key C-x
send_key C-c
closed=0
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  if ! tmux_cmd has-session -t "$session" 2>/dev/null; then
    closed=1
    break
  fi
  sleep 0.25
done
[[ $closed == 1 ]] || die shutdown 'C-x C-c did not close the editor'
[[ ! -e $LEM_YATH_SERVER_SOCKET && ! -e $LEM_YATH_SERVER_PANE_FILE ]] ||
  die shutdown 'clean editor exit left server metadata behind'
pass shutdown 'clean editor exit closes clients and removes owned metadata'

failure_runtime="$root/failure-runtime"
failure_socket="$failure_runtime/server.sock"
failure_pane="$failure_runtime/server.pane"
protected="$root/protected.txt"
mkdir -m 700 "$failure_runtime"
printf 'protected\n' >"$protected"
ln -s "$protected" "$failure_pane"
printf -v command '%q ' env \
  "LEM_YATH_SERVER_SOCKET=$failure_socket" \
  "LEM_YATH_SERVER_PANE_FILE=$failure_pane" \
  "LEM_YATH_SERVER_REPORT=$LEM_YATH_SERVER_REPORT" \
  "LEM_YATH_SERVER_ABORT_FILE=$LEM_YATH_SERVER_ABORT_FILE" \
  'GIT_EDITOR=preserved-git' 'VISUAL=preserved-visual' \
  'EDITOR=preserved-editor' \
  "$LEM_BIN" --eval "$form" "$origin"
ready_before=$(report_count '^READY$')
tmux_cmd new-session -d -s "$session" -x 160 -y 50 "$command"
wait_report_count '^READY$' "$((ready_before + 1))" "$BOOT_TIMEOUT" ||
  die failed-start 'editor did not survive rejected pane metadata'
send_key F6
wait_report_count '^FAILED-START ' 1 ||
  die failed-start 'failed-start state was not recordable'
grep -Fq \
  'FAILED-START running=no socket=no git=preserved-git visual=preserved-visual editor=preserved-editor' \
  "$LEM_YATH_SERVER_REPORT" ||
  die failed-start 'failed startup changed listener state or editor variables'
[[ ! -e $failure_socket ]] ||
  die failed-start 'partial startup left a stale socket'
[[ -L $failure_pane && $(<"$protected") == protected ]] ||
  die failed-start 'startup followed or removed untrusted pane metadata'
send_key C-x
send_key C-c
for _ in $(seq 1 $((WAIT_TIMEOUT * 4))); do
  ! tmux_cmd has-session -t "$session" 2>/dev/null && break
  sleep 0.25
done
! tmux_cmd has-session -t "$session" 2>/dev/null ||
  die failed-start 'editor with rejected server metadata did not exit cleanly'
pass failed-start 'partial startup cleans its socket and preserves prior editor variables'

printf 'server test passed\n'
