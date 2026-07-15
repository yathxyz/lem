#!/usr/bin/env bash
# Real-TUI acceptance for the configured Notmuch read/fetch workflow.
set -euo pipefail

# Lem/tmux key decoding requires a UTF-8 locale in the Nix sandbox.
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-notmuch-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-notmuch.XXXXXX")"
session="lem-yath-notmuch-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_NOTMUCH_REPORT="$root/report"
export LEM_YATH_NOTMUCH_LOG="$root/notmuch-argv.jsonl"
export LEM_YATH_NOTMUCH_STATE="$root/state.json"
export LEM_YATH_MBSYNC_LOG="$root/mbsync-argv"
export LEM_YATH_NOTMUCH_OPEN_LOG="$root/xdg-open.jsonl"
fakebin="$root/fake bin;safe"
export LEM_YATH_NOTMUCH_FAKE_BIN="$fakebin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$fakebin"
: >"$LEM_YATH_NOTMUCH_REPORT"
: >"$LEM_YATH_NOTMUCH_LOG"
: >"$LEM_YATH_MBSYNC_LOG"
: >"$LEM_YATH_NOTMUCH_OPEN_LOG"
printf '{"searches": 0, "news": 0}\n' >"$LEM_YATH_NOTMUCH_STATE"
cp "$here/scripts/fake-notmuch.py" "$fakebin/notmuch"
cp "$here/scripts/fake-mbsync.sh" "$fakebin/mbsync"
cp "$here/scripts/fake-notmuch-xdg-open.py" "$fakebin/xdg-open"
python=$(command -v python3)
shell=$(command -v bash)
sed -i "1c#!$python" "$fakebin/notmuch" "$fakebin/xdg-open"
sed -i "1c#!$shell" "$fakebin/mbsync"
chmod +x "$fakebin/notmuch" "$fakebin/mbsync" "$fakebin/xdg-open"
export PATH="$fakebin:$PATH"

source_file="$root/source file;safe.txt"
printf 'Notmuch source remains exact\n' >"$source_file"

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_NOTMUCH_REPORT" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_NOTMUCH_LOG" 2>/dev/null || true
  sed -n '1,40p' "$LEM_YATH_NOTMUCH_STATE" 2>/dev/null || true
}

report_count() { grep -c "^$1" "$LEM_YATH_NOTMUCH_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 80)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_NOTMUCH_REPORT" | tail -n 1; }
invoke_report() {
  local before
  before=$(report_count STATE)
  lem_keys "$session" F1
  wait_report STATE "$before"
}
wait_log_count() {
  local path=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(wc -l <"$path")" -ge "$expected" ]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/notmuch-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if wait_report READY 0 && lem_wait_for "$session" NORMAL 60 >/dev/null &&
   grep -Fqx -- "EXEC notmuch=$fakebin/notmuch xdg-open=$fakebin/xdg-open" \
     "$LEM_YATH_NOTMUCH_REPORT"; then
  pass boot 'configured Lem loaded the fixture and resolved the fake notmuch'
else
  fail boot 'configured Lem did not load the fixture with the fake notmuch'
fi

lem_keys "$session" F3
if lem_wait_for "$session" 'First thread' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list query=yes row=thread:alpha thread=none message=none read-only=yes keys=yes body=no html-hidden=no source-live=yes source-exact=yes' ]]; then
  pass search 'the query opened and focused a read-only newest-first list'
else
  fail search 'search rendering, focus, row identity, or keymaps diverged'
fi

lem_keys "$session" j
sleep 0.4
lem_keys "$session" Enter
if lem_wait_for "$session" 'Primary plain body' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=show query=no row=none thread=thread:beta message=payment+safe;touch PWNED@example.invalid read-only=yes keys=yes body=yes html-hidden=yes source-live=yes source-exact=yes' ]]; then
  pass read 'j and Return opened both plain-text messages without HTML'
else
  fail read 'thread navigation, nested message parsing, or show focus failed'
fi

lem_keys "$session" C-c s e
if wait_log_count "$LEM_YATH_NOTMUCH_OPEN_LOG" 1; then
  lem_keys "$session" G
fi
if invoke_report && [[ $(latest STATE) == *'message=reply/second?value@example.invalid '* ]]; then
  lem_keys "$session" C-c s e
fi
if wait_log_count "$LEM_YATH_NOTMUCH_OPEN_LOG" 2 &&
   python3 - "$LEM_YATH_NOTMUCH_OPEN_LOG" <<'PY'
import json, sys, urllib.parse
calls = [json.loads(line) for line in open(sys.argv[1])]
base = "https://backup.ecolink.ie/payment-emails/by-message-id?id="
ids = [
    "payment+safe;touch PWNED@example.invalid",
    "reply/second?value@example.invalid",
]
assert calls == [[base + urllib.parse.quote(value, safe="")] for value in ids]
PY
then
  pass payment-email 'C-c s e opened the current message in Salta with exact URL encoding'
else
  fail payment-email 'message-at-point tracking, mode binding, URL encoding, or browser argv diverged'
fi

before_show=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" g
if wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_show + 1))" &&
   invoke_report && [[ $(latest STATE) == *'mode=show '*'thread=thread:beta '* ]]; then
  pass show-refresh 'g refreshed the current thread in place'
else
  fail show-refresh 'show refresh did not retain the thread view'
fi

lem_keys "$session" q
sleep 0.5
lem_keys "$session" g
if lem_wait_for "$session" 'Second thread refreshed' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list query=yes row=thread:beta thread=none message=none read-only=yes keys=yes body=no html-hidden=no source-live=yes source-exact=yes' ]]; then
  pass list-refresh 'q returned and g refreshed while preserving the selected thread'
else
  fail list-refresh 'list return, refresh, or row preservation failed'
fi

lem_keys "$session" F4
if lem_wait_for "$session" 'No threads for query: tag:empty' 20 >/dev/null &&
   invoke_report && [[ $(latest STATE) == *'mode=list query=no row=none '* ]]; then
  pass empty 'a successful empty JSON array rendered an empty result list'
else
  fail empty 'empty search was confused with process failure'
fi

lem_keys "$session" F3
before_notmuch=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
if lem_wait_for "$session" 'First thread' 20 >/dev/null; then
  lem_keys "$session" F5
fi
if wait_log_count "$LEM_YATH_MBSYNC_LOG" 1 &&
   wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_notmuch + 1))" &&
   grep -Fxq -- '-a' "$LEM_YATH_MBSYNC_LOG" &&
   python3 - "$LEM_YATH_NOTMUCH_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert ["new"] in calls
queries = [call[-1] for call in calls if call and call[0] == "search"]
assert 'tag:inbox and subject:"safe;touch PWNED"' in queries
assert all(isinstance(call, list) and all(isinstance(arg, str) for arg in call) for call in calls)
PY
then
  pass fetch 'mbsync -a completed before notmuch new through the fake tools'
else
  fail fetch 'fetch/index sequencing or direct query argv failed'
fi

if [ ! -e "$root/PWNED" ] && [ ! -e "$PWD/PWNED" ]; then
  pass argv 'metacharacter query remained one inert notmuch argv value'
else
  fail argv 'query text escaped the direct argv boundary'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
