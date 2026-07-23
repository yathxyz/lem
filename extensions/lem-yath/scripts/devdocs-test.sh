#!/usr/bin/env bash
# Real-TUI acceptance for the keybound DevDocs install/lookup/view workflow.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-devdocs-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-devdocs.XXXXXX")"
session="lem-yath-devdocs-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_DEVDOCS_REPORT="$root/report"
export LEM_YATH_DEVDOCS_CURL_LOG="$root/curl.jsonl"
export LEM_YATH_DEVDOCS_OPEN_LOG="$root/open.jsonl"
fakebin="$root/fake bin;safe"
export LEM_YATH_DEVDOCS_FAKE_BIN="$fakebin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$fakebin"
: >"$LEM_YATH_DEVDOCS_REPORT"
: >"$LEM_YATH_DEVDOCS_CURL_LOG"
: >"$LEM_YATH_DEVDOCS_OPEN_LOG"
cp "$here/scripts/fake-devdocs-curl.py" "$fakebin/curl"
cp "$here/scripts/fake-devdocs-xdg-open.py" "$fakebin/xdg-open"
python=$(command -v python3)
sed -i "1c#!$python" "$fakebin/curl" "$fakebin/xdg-open"
chmod +x "$fakebin/curl" "$fakebin/xdg-open"
ln -s "$(command -v timeout)" "$fakebin/timeout"
export PATH="$fakebin:$PATH"

source_file="$root/source file;safe.txt"
printf 'DevDocs source remains exact\n' >"$source_file"

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,140p' "$LEM_YATH_DEVDOCS_REPORT" 2>/dev/null || true
  sed -n '1,180p' "$LEM_YATH_DEVDOCS_CURL_LOG" 2>/dev/null || true
  sed -n '1,80p' "$LEM_YATH_DEVDOCS_OPEN_LOG" 2>/dev/null || true
}

report_count() { grep -c "^$1" "$LEM_YATH_DEVDOCS_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 80)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_DEVDOCS_REPORT" | tail -n 1; }
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
submit_prompt() {
  local prompt=$1 text=$2
  lem_wait_for "$session" "$prompt" 20 >/dev/null
  tmux_cmd send-keys -t "$session" -l -- "$text"
  lem_keys "$session" Enter
}
start_lookup() {
  lem_keys "$session" Space h d
  submit_prompt 'DevDocs docset:' "$1"
}
choose_entry() {
  submit_prompt 'DevDocs entry:' "$1"
}

fixture="$(lem-yath_lisp_string "$here/scripts/devdocs-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if wait_report READY 0 && lem_wait_for "$session" NORMAL 60 >/dev/null &&
   grep -Fqx -- "EXEC curl=$fakebin/curl xdg-open=$fakebin/xdg-open" \
     "$LEM_YATH_DEVDOCS_REPORT"; then
  pass boot 'configured Lem loaded isolated DevDocs HTTP and browser tools'
else
  fail boot 'configured Lem did not resolve the fake tools after Direnv'
fi
if ((failed)); then exit 1; fi

lem_keys "$session" F5
submit_prompt 'Install docset slug:' custom
if wait_lines "$LEM_YATH_DEVDOCS_CURL_LOG" 1; then sleep 0.5; fi
if invoke_report &&
   [[ $(latest STATE) == 'STATE mode=other slug=none path=none generation=0 installed=yes read-only=no keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass install 'install fetched, validated, cached, and registered the custom index'
else
  fail install 'install accepted no validated session cache or damaged source state'
fi
if ((failed)); then exit 1; fi

start_lookup custom
choose_entry Custom.Entry
if lem_wait_for "$session" 'Decoded & text.' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=viewer slug=custom path=guide/custom#entry generation=2 installed=yes read-only=yes keys=yes body=yes hidden=yes source-live=yes source-exact=yes' ]]; then
  pass lookup 'physical SPC h d focused a sanitized read-only documentation pane'
else
  fail lookup 'key dispatch, cached prompts, rendering, focus, or Vi keys diverged'
fi
if ((failed)); then exit 1; fi

before_open=$(wc -l <"$LEM_YATH_DEVDOCS_OPEN_LOG")
lem_keys "$session" b
if wait_lines "$LEM_YATH_DEVDOCS_OPEN_LOG" "$((before_open + 1))" &&
   python3 - "$LEM_YATH_DEVDOCS_OPEN_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert calls[-1] == ["https://devdocs.io/custom/guide/custom#entry"]
PY
then
  pass browser 'b passed the exact fragment-bearing DevDocs URL as one argv'
else
  fail browser 'browser fallback URL or argv shape diverged'
fi

lem_keys "$session" q
sleep 0.4
if invoke_report &&
   [[ $(latest STATE) == 'STATE mode=other slug=none path=none generation=0 installed=yes read-only=no keys=yes body=no hidden=no source-live=yes source-exact=yes' ]]; then
  pass quit 'q returned to the unchanged source buffer'
else
  fail quit 'viewer q did not restore source focus and contents'
fi

custom_indexes=$(grep -Fc 'documents.devdocs.io/custom/index.json' "$LEM_YATH_DEVDOCS_CURL_LOG")
if [ "$custom_indexes" -eq 1 ]; then
  pass cache 'lookup reused the installed session index without another request'
else
  fail cache "custom index was requested $custom_indexes times"
fi

start_lookup slow
sleep 0.2
start_lookup rust
choose_entry Vec::new
if lem_wait_for "$session" 'Rust decoded & body.' 20 >/dev/null; then sleep 3; fi
if ! lem_capture "$session" | grep -Fq 'DevDocs entry:' && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=viewer slug=rust path=std/vec/struct.Vec#method.new generation=4 installed=yes read-only=yes keys=yes body=yes hidden=yes source-live=yes source-exact=yes' ]]; then
  pass stale-index 'a late older index could not open a stale entry prompt'
else
  fail stale-index 'out-of-order index completion displaced the latest lookup'
fi

lem_keys "$session" q
sleep 0.4
start_lookup slowpage
choose_entry Slow.Page
sleep 0.2
start_lookup rust
choose_entry Vec::with_capacity
if lem_wait_for "$session" 'Rust decoded & body.' 20 >/dev/null; then sleep 3; fi
if ! lem_capture "$session" | grep -Fq 'Stale slow page.' && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=viewer slug=rust path=std/vec/struct.Vec#method.with_capacity generation=6 installed=yes read-only=yes keys=yes body=yes hidden=yes source-live=yes source-exact=yes' ]]; then
  pass stale-page 'a late older page could not overwrite the latest viewer'
else
  fail stale-page 'out-of-order page completion replaced newer documentation'
fi

lem_keys "$session" q
sleep 0.4
before_broken=$(wc -l <"$LEM_YATH_DEVDOCS_CURL_LOG")
start_lookup 'broken;touch PWNED'
if wait_lines "$LEM_YATH_DEVDOCS_CURL_LOG" "$((before_broken + 1))"; then sleep 0.5; fi
if invoke_report && [[ $(latest STATE) == *'mode=other '*'source-exact=yes' ]]; then
  pass failure 'a failed index left the source active without opening a prompt'
else
  fail failure 'failed index handling changed the source or opened a viewer'
fi

if python3 - "$LEM_YATH_DEVDOCS_CURL_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert calls
for argv in calls:
    assert len(argv) == 4
    assert argv[:3] == ["-fsSL", "--max-time", "5"]
    assert argv[-1].startswith("https://documents.devdocs.io/")
assert any("broken;touch PWNED" in argv[-1] for argv in calls)
PY
then
  pass argv 'every bounded HTTP request remained an inert direct argv vector'
else
  fail argv 'curl timeout, URL, or direct-argv boundary diverged'
fi

if [ ! -e "$root/PWNED" ] && [ ! -e "$PWD/PWNED" ]; then
  pass inert 'metacharacter paths, docsets, and URLs remained inert'
else
  fail inert 'test metacharacters escaped an argv boundary'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
