#!/usr/bin/env bash
# Real-TUI acceptance for the configured Miniflux/Fever reading workflow.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-elfeed-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-elfeed.XXXXXX")"
session="lem-yath-elfeed-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_ELFEED_REPORT="$root/report"
export LEM_YATH_ELFEED_CURL_LOG="$root/curl.jsonl"
export LEM_YATH_ELFEED_OPEN_LOG="$root/open.jsonl"
export LEM_YATH_ELFEED_STATE="$root/state.json"
fakebin="$root/fake bin;safe"
export LEM_YATH_ELFEED_FAKE_BIN="$fakebin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$fakebin"
: >"$LEM_YATH_ELFEED_REPORT"
: >"$LEM_YATH_ELFEED_CURL_LOG"
: >"$LEM_YATH_ELFEED_OPEN_LOG"
printf '{"unread_requests": 0}\n' >"$LEM_YATH_ELFEED_STATE"
cp "$here/scripts/fake-elfeed-curl.py" "$fakebin/curl"
cp "$here/scripts/fake-elfeed-xdg-open.py" "$fakebin/xdg-open"
python=$(command -v python3)
sed -i "1c#!$python" "$fakebin/curl" "$fakebin/xdg-open"
chmod +x "$fakebin/curl" "$fakebin/xdg-open"
ln -s "$(command -v timeout)" "$fakebin/timeout"
export PATH="$fakebin:$PATH"

password='secret;touch-PWNED'
printf 'machine rss.wg login yanni password %s\n' "$password" >"$HOME/.authinfo"
chmod 600 "$HOME/.authinfo"
source_file="$root/source file;safe.txt"
printf 'Elfeed source remains exact\n' >"$source_file"

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_ELFEED_REPORT" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_ELFEED_CURL_LOG" 2>/dev/null || true
  sed -n '1,80p' "$LEM_YATH_ELFEED_OPEN_LOG" 2>/dev/null || true
}

report_count() { grep -c "^$1" "$LEM_YATH_ELFEED_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 80)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_ELFEED_REPORT" | tail -n 1; }
invoke_report() {
  local before
  before=$(report_count STATE)
  lem_keys "$session" F4
  wait_report STATE "$before"
}
wait_lines() {
  local path=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(wc -l <"$path")" -ge "$expected" ]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/elfeed-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if wait_report READY 0 && lem_wait_for "$session" NORMAL 60 >/dev/null &&
   grep -Fqx -- "EXEC curl=$fakebin/curl xdg-open=$fakebin/xdg-open" \
     "$LEM_YATH_ELFEED_REPORT"; then
  pass boot 'configured Lem loaded the fixture with isolated HTTP and browser tools'
else
  fail boot 'configured Lem did not resolve both fake tools after Direnv'
fi
if ((failed)); then exit 1; fi

lem_keys "$session" F3
if lem_wait_for "$session" 'First item' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list row=101 entry=none generation=1 read-only=yes keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass list 'the command focused a read-only Fever list with Vi-priority keys'
else
  fail list 'initial fetch, focus, row mapping, or key precedence diverged'
fi
if ((failed)); then exit 1; fi

lem_keys "$session" j
sleep 0.3
lem_keys "$session" g
if lem_wait_for "$session" 'Second item refreshed' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list row=102 entry=none generation=2 read-only=yes keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass refresh 'g refreshed asynchronously while preserving the selected entry'
else
  fail refresh 'refresh did not retain the selected Fever item'
fi

lem_keys "$session" Enter
if lem_wait_for "$session" 'Second body & decoded.' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=entry row=none entry=102 generation=0 read-only=yes keys=yes body=yes hidden=yes source-live=yes source-exact=yes' ]]; then
  pass read 'Return focused decoded article text while dropping script and style bodies'
else
  fail read 'article rendering, focus, or HTML sanitization diverged'
fi

before_open=$(wc -l <"$LEM_YATH_ELFEED_OPEN_LOG")
lem_keys "$session" b
if wait_lines "$LEM_YATH_ELFEED_OPEN_LOG" "$((before_open + 1))"; then
  lem_keys "$session" A
fi
if wait_lines "$LEM_YATH_ELFEED_OPEN_LOG" "$((before_open + 2))" &&
   python3 - "$LEM_YATH_ELFEED_OPEN_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
url = "https://example.invalid/102?x=1&safe=touch%20PWNED"
assert calls[-2:] == [[url], ["https://archive.is/newest/" + url]]
PY
then
  pass links 'b and A passed one exact URL argv to the browser and archive.is'
else
  fail links 'browser or configured archive.is URL handling diverged'
fi

lem_keys "$session" q
sleep 0.4
if invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list row=102 entry=none generation=2 read-only=yes keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass return 'q restored focus to the selected feed-list row'
else
  fail return 'entry quit did not return to the prior list state'
fi

lem_keys "$session" g
sleep 0.2
lem_keys "$session" g
if lem_wait_for "$session" 'Newest generation item' 20 >/dev/null; then
  sleep 3
fi
if ! lem_capture "$session" | grep -Fq 'Stale generation item' && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list row=301 entry=none generation=4 read-only=yes keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass stale 'a late older refresh could not overwrite the latest generation'
else
  fail stale 'out-of-order asynchronous results replaced newer feed data'
fi

lem_keys "$session" g
if lem_wait_for "$session" 'No unread feed items.' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list row=none entry=none generation=5 read-only=yes keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass empty 'a successful empty unread response rendered an explicit empty state'
else
  fail empty 'empty unread state was not rendered distinctly'
fi

lem_keys "$session" g
if lem_wait_for "$session" 'Feed refresh failed.' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list row=none entry=none generation=6 read-only=yes keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass failure 'a failed Fever request rendered a distinct bounded failure state'
else
  fail failure 'server failure was confused with an empty unread response'
fi

if python3 - "$LEM_YATH_ELFEED_CURL_LOG" "$password" <<'PY'
import hashlib, json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
api_key = hashlib.md5(("yanni:" + sys.argv[2]).encode()).hexdigest()
assert calls
for call in calls:
    argv = call["argv"]
    assert len(argv) == 6
    assert argv[4] == "api_key@-"
    assert argv[-1].startswith("http://rss.wg:8070/fever/?api&")
    assert call["stdin"] == api_key
    assert api_key not in argv
    assert sys.argv[2] not in "\n".join(argv)
PY
then
  pass credential 'the derived Fever key stayed on bounded curl stdin, outside argv'
else
  fail credential 'credential or direct-argv HTTP boundary diverged'
fi

if [ ! -e "$root/PWNED" ] && [ ! -e "$PWD/PWNED" ]; then
  pass argv 'metacharacter credentials, paths, and URLs remained inert'
else
  fail argv 'test metacharacters escaped an argv boundary'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
