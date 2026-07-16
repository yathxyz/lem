#!/usr/bin/env bash
# Real-TUI acceptance for the host-gated external Org nodes projector.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-org-nodes-sync-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-nodes-sync.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_ORG_NODES_REPORT="$root/report"
export LEM_YATH_ORG_NODES_LOG="$root/log"
export LEM_YATH_ORG_NODES_ELIGIBLE="$WORKDIR/eligible ;\$meta.org"
export LEM_YATH_ORG_NODES_CONFLICT="$WORKDIR/note.sync-conflict-peer.org"
export LEM_YATH_ORG_NODES_OUTSIDE="$root/outside/outside.org"
export LEM_YATH_ORG_NODES_FAILURE="$WORKDIR/failure.org"
export LEM_YATH_ORG_NODES_MANUAL="$WORKDIR/readlist.org"
export LEM_YATH_ORG_NODES_ESCAPE="$WORKDIR/escape.org"
export LEM_YATH_ORG_NODES_COMMAND="$root/bin/nodes-org-sync"
source "$here/scripts/tui-driver.sh"
export LEM_YATH_SOURCE

session="lem-yath-org-nodes-sync-$id"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-org-nodes-sync.*) [[ -d "$root" ]] && rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe nodes-sync cleanup path: %s\n' "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$WORKDIR" "$XDG_CACHE_HOME" "$root/bin" \
  "$LEM_YATH_ORG_NODES_LOG" "$root/outside"
: >"$LEM_YATH_ORG_NODES_REPORT"

bash_bin=$(command -v bash)
printf '%s\n' \
  "#!$bash_bin" \
  'set -euo pipefail' \
  ': "${LEM_YATH_ORG_NODES_LOG:?}"' \
  'count_file="$LEM_YATH_ORG_NODES_LOG/count"' \
  'count=0' \
  'if [[ -f "$count_file" ]]; then IFS= read -r count <"$count_file"; fi' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" >"$count_file"' \
  'printf "%s\0" "$@" >"$LEM_YATH_ORG_NODES_LOG/$count.argv"' \
  'if [[ "$*" == *failure.org* ]]; then' \
  '  printf "fixture database failure\n" >&2' \
  '  exit 7' \
  'fi' \
  >"$LEM_YATH_ORG_NODES_COMMAND"
chmod +x "$LEM_YATH_ORG_NODES_COMMAND"
export PATH="$root/bin:$PATH"

write_actionable() {
  local path=$1
  printf '%s\n' \
    '* TODO Task' \
    'Task body.' \
    '* Scheduled' \
    'SCHEDULED: <2026-07-16 Thu>' \
    '* Deadline' \
    'DEADLINE: <2026-07-17 Fri>' \
    '* Reading :reading:' \
    '* Plain' \
    '* Source owner' \
    '#+begin_src text' \
    'SCHEDULED: <2026-07-18 Sat>' \
    '#+end_src' \
    >"$path"
}

write_actionable "$LEM_YATH_ORG_NODES_ELIGIBLE"
write_actionable "$LEM_YATH_ORG_NODES_CONFLICT"
write_actionable "$LEM_YATH_ORG_NODES_OUTSIDE"
write_actionable "$LEM_YATH_ORG_NODES_FAILURE"
printf '%s\n' '* TODO Manual task' '* Manual plain' \
  >"$LEM_YATH_ORG_NODES_MANUAL"
ln -s "$LEM_YATH_ORG_NODES_OUTSIDE" "$LEM_YATH_ORG_NODES_ESCAPE"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
die() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  printf '\n--- screen ---\n' >&2
  lem_capture "$session" >&2 || true
  printf '\n--- report ---\n' >&2
  sed -n '1,260p' "$LEM_YATH_ORG_NODES_REPORT" >&2 || true
  exit 1
}

report_count() { grep -cE "$1" "$LEM_YATH_ORG_NODES_REPORT" 2>/dev/null || true; }
wait_report() {
  local pattern=$1 expected=${2:-1} index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    if (( $(report_count "$pattern") >= expected )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
wait_fake_count() {
  local expected=$1 index=0
  while ((index < WAIT_TIMEOUT * 4)); do
    if [[ -f "$LEM_YATH_ORG_NODES_LOG/count" ]] &&
       (( $(<"$LEM_YATH_ORG_NODES_LOG/count") >= expected )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
send_key() { lem_keys "$session" "$1"; sleep 0.2; }
save_current() { lem_keys "$session" C-x C-s; sleep 0.3; }

fixture="$(lem-yath_lisp_string "$here/scripts/org-nodes-sync-fixture.lisp")"
if ! lem_start_lem-yath_eval "$session" "(load #P$fixture)" \
  "$LEM_YATH_ORG_NODES_ELIGIBLE"; then
  die boot 'could not start isolated Lem'
fi
if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report '^READY$'; then
  die boot 'configured Lem did not load the fixture'
fi
pass boot 'configured Lem loaded the isolated nodes-sync fixture'

send_key F2
if ! wait_report '^STATIC enabled=yes host=[^ ]+ eligible=yes command=yes denied=yes before=1 after=1 mode-hook=1 auto=no$'; then
  die static-contracts 'host policy or reload-safe hooks differed'
fi
pass static-contracts 'host policy and reload-safe local hooks passed'

send_key F3
save_current
if ! wait_fake_count 1; then die default-sync 'eligible save did not launch'; fi
sleep 0.4
send_key F5
if ! wait_report '^STATUS .* state=succeeded task=no scheduled=no deadline=no reading=no plain=no source=no modified=no$'; then
  die default-sync 'default save changed IDs or did not finish cleanly'
fi
pass default-sync 'physical save synced without automatic IDs'

send_key F4
save_current
if ! wait_fake_count 2; then die auto-id 'opt-in save did not launch'; fi
sleep 0.4
send_key F5
if ! wait_report '^STATUS .* state=succeeded task=yes scheduled=yes deadline=yes reading=yes plain=no source=no modified=no$'; then
  die auto-id 'actionable ID selection differed'
fi
pass auto-id 'opt-in save added IDs only to actionable headings'

send_key F9
if ! wait_report '^MANUAL count=1 task=yes plain=no modified=yes$'; then
  die manual-id 'manual default-off ID command differed'
fi
pass manual-id 'manual command works while automatic IDs remain off'

send_key F6
save_current
sleep 0.6
[[ $(<"$LEM_YATH_ORG_NODES_LOG/count") == 2 ]] ||
  die conflict-refusal 'Syncthing conflict file launched the projector'
send_key F7
save_current
sleep 0.6
[[ $(<"$LEM_YATH_ORG_NODES_LOG/count") == 2 ]] ||
  die outside-refusal 'outside file launched the projector'
send_key F10
save_current
sleep 0.6
[[ $(<"$LEM_YATH_ORG_NODES_LOG/count") == 2 ]] ||
  die symlink-refusal 'symlink escape launched the projector'
pass refusal-policy 'conflict, outside-root, and symlink escapes were inert'

send_key F8
save_current
if ! wait_fake_count 3; then die failure-report 'failure fixture did not launch'; fi
sleep 0.5
send_key F5
if ! wait_report '^STATUS file=failure.org state=failed .* modified=no$' ||
   ! lem_capture "$session" | grep -q 'failure.org'; then
  die failure-report 'failure state or active source buffer was lost'
fi
pass failure-report 'async failure retained the source and exposed status'

python3 - "$LEM_YATH_ORG_NODES_LOG/1.argv" \
  "$LEM_YATH_ORG_NODES_LOG/2.argv" "$LEM_YATH_ORG_NODES_LOG/3.argv" \
  "$LEM_YATH_ORG_NODES_ELIGIBLE" "$LEM_YATH_ORG_NODES_FAILURE" <<'PY'
import pathlib
import sys

def argv(path):
    return [part.decode() for part in pathlib.Path(path).read_bytes().split(b"\0")[:-1]]

eligible = str(pathlib.Path(sys.argv[4]).resolve())
failure = str(pathlib.Path(sys.argv[5]).resolve())
assert argv(sys.argv[1]) == ["--quiet", "--file", eligible]
assert argv(sys.argv[2]) == ["--quiet", "--file", eligible]
assert argv(sys.argv[3]) == ["--quiet", "--file", failure]
PY
pass argv-boundary 'all launches used exact direct argv and canonical paths'

printf 'All Org nodes-sync tests passed.\n'
