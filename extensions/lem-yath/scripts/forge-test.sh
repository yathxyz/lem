#!/usr/bin/env bash
# Real-TUI acceptance for GitHub Forge parity, using a stateful fake gh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-forge-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-forge.XXXXXX")"
session="lem-yath-forge-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_FORGE_ROOT="$root/repository forge;safe/"
export LEM_YATH_FORGE_REPORT="$root/report"
export LEM_YATH_FORGE_FAKE_STATE="$root/state.json"
export LEM_YATH_FORGE_FAKE_LOG="$root/gh-argv.jsonl"
export LEM_YATH_FORGE_FAKE_GH="$root/fake gh;safe"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_YATH_FORGE_ROOT"
: >"$LEM_YATH_FORGE_REPORT"
: >"$LEM_YATH_FORGE_FAKE_LOG"
cp "$here/scripts/fake-gh.py" "$LEM_YATH_FORGE_FAKE_GH"
python="$(command -v python3)"
sed -i "1c#!$python" "$LEM_YATH_FORGE_FAKE_GH"
chmod +x "$LEM_YATH_FORGE_FAKE_GH"

cat >"$LEM_YATH_FORGE_FAKE_STATE" <<'JSON'
{
  "pullreqs": [
    {
      "number": 7,
      "title": "First pull request",
      "body": "PR body from fake GitHub",
      "author": {"login": "alice"},
      "state": "OPEN",
      "url": "https://github.com/yath/test/pull/7",
      "updatedAt": "2026-07-15T19:00:00Z",
      "isDraft": false,
      "headRefName": "feature-one",
      "baseRefName": "main",
      "comments": []
    },
    {
      "number": 9,
      "title": "Second pull request",
      "body": "Second PR body",
      "author": {"login": "bob"},
      "state": "OPEN",
      "url": "https://github.com/yath/test/pull/9",
      "updatedAt": "2026-07-15T19:30:00Z",
      "isDraft": true,
      "headRefName": "feature-two",
      "baseRefName": "main",
      "comments": []
    }
  ],
  "issues": [
    {
      "number": 12,
      "title": "Tracked issue",
      "body": "Issue body from fake GitHub",
      "author": {"login": "carol"},
      "state": "OPEN",
      "url": "https://github.com/yath/test/issues/12",
      "updatedAt": "2026-07-15T18:00:00Z",
      "comments": []
    }
  ]
}
JSON

git -C "$LEM_YATH_FORGE_ROOT" init -q
git -C "$LEM_YATH_FORGE_ROOT" remote add origin 'git@github.com:yath/test.git'
printf 'Forge source remains live\n' >"${LEM_YATH_FORGE_ROOT}source file.txt"

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_FORGE_REPORT" 2>/dev/null || true
}

report_count() { grep -c "^$1" "$LEM_YATH_FORGE_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 80)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_FORGE_REPORT" | tail -n 1; }
invoke_report() {
  local before
  before=$(report_count STATE)
  lem_keys "$session" F1
  wait_report STATE "$before"
}
state_value() {
  python3 - "$LEM_YATH_FORGE_FAKE_STATE" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
try:
    value = eval(sys.argv[2], {"data": data})
except (IndexError, KeyError):
    value = ""
print(value)
PY
}
wait_state() {
  local expression=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(state_value "$expression")" = "$expected" ]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/forge-fixture.lisp")"
lem_start "$session" "${LEM_YATH_FORGE_ROOT}source file.txt" \
  --eval "(load #P$fixture)"

if wait_report READY 0 2>/dev/null && lem_wait_for "$session" NORMAL 60 >/dev/null; then
  pass boot 'configured Lem opened the isolated repository'
else
  fail boot 'configured Lem failed to reach Normal state'
fi

lem_keys "$session" F3
if
   lem_wait_for "$session" 'GitHub Forge: yath/test' 30 >/dev/null &&
   invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list view=all topic=pullreq-7 state=open action=none cache=yes read-only=yes keys=yes source-live=yes' ]]; then
  pass list 'the registered Forge command fetched and selected the first PR'
else
  fail list 'Forge list, remote parsing, selection, or keymap state diverged'
fi

lem_keys "$session" C-j
sleep 0.5
lem_keys "$session" Enter
if lem_wait_for "$session" 'Second PR body' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=topic view=none topic=pullreq-9 state=open action=none cache=yes read-only=yes keys=yes source-live=yes' ]]; then
  pass inspect 'C-j and Return opened the selected PR details'
else
  fail inspect 'row navigation or topic inspection failed'
fi

lem_keys "$session" r
if lem_wait_for "$session" 'Comment on PR #9' 10 >/dev/null && invoke_report &&
   [[ $(latest STATE) == *'mode=compose '*'action=comment '* ]]; then
  lem_keys "$session" i
  sleep 0.25
  tmux_cmd send-keys -t "$session" -l 'Comment from Lem'
  sleep 0.25
  lem_keys "$session" Enter
  sleep 0.25
  tmux_cmd send-keys -t "$session" -l 'second line; safe'
  sleep 0.25
  lem_keys "$session" Escape
  sleep 0.25
  lem_keys "$session" C-c
  sleep 0.25
  lem_keys "$session" C-c
fi
if wait_state 'data["pullreqs"][1]["comments"][0]["body"]' $'Comment from Lem\nsecond line; safe'; then
  pass comment 'multiline comment composition reached gh as one argv value'
else
  fail comment 'comment composition or direct argv transport failed'
fi

# The topic buffer survives composition; close is confirmed and reopen is not.
lem_keys "$session" s
if lem_wait_for "$session" 'Close PR #9' 10 >/dev/null; then lem_keys "$session" y; fi
if wait_state 'data["pullreqs"][1]["state"]' CLOSED; then
  pass close 's required confirmation and closed the pull request'
else
  fail close 'confirmed close did not reach the fake backend'
fi
lem_keys "$session" s
if wait_state 'data["pullreqs"][1]["state"]' OPEN; then
  pass reopen 's reopened the retained closed topic'
else
  fail reopen 'reopen did not reach the fake backend'
fi

lem_keys "$session" F3
if lem_wait_for "$session" 'GitHub Forge:' 20 >/dev/null; then
  lem_keys "$session" c
  sleep 0.25
  lem_keys "$session" i
fi
if lem_wait_for "$session" '^Title:' 10 >/dev/null; then
  lem_keys "$session" i
  tmux_cmd send-keys -t "$session" -l 'Created from Lem; safe'
  sleep 0.25
  lem_keys "$session" Escape
  sleep 0.25
  lem_keys "$session" j
  sleep 0.25
  lem_keys "$session" j
  sleep 0.25
  lem_keys "$session" i
  sleep 0.25
  tmux_cmd send-keys -t "$session" -l 'Multiline issue body'
  sleep 0.25
  lem_keys "$session" Enter
  sleep 0.25
  tmux_cmd send-keys -t "$session" -l 'with second line'
  sleep 0.25
  lem_keys "$session" Escape
  sleep 0.25
  lem_keys "$session" C-c
  sleep 0.25
  lem_keys "$session" C-c
fi
if wait_state 'data["issues"][-1]["title"]' 'Created from Lem; safe' &&
   wait_state 'data["issues"][-1]["body"]' $'Multiline issue body\nwith second line'; then
  pass create 'c i submitted an editor-composed multiline issue'
else
  fail create 'issue title/body composition failed'
fi

before_gh=$(wc -l <"$LEM_YATH_FORGE_FAKE_LOG")
before_status=$(report_count STATUS)
lem_keys "$session" F2
if wait_report STATUS "$before_status" &&
   [[ $(latest STATUS) == 'STATUS cached=yes topic=yes preview=yes hook=1' ]] &&
   [ "$(wc -l <"$LEM_YATH_FORGE_FAKE_LOG")" -eq "$before_gh" ]; then
  pass status 'Legit rendered cached topics with previews and no network call'
else
  fail status 'Legit section cache, preview, hook idempotence, or I/O boundary failed'
fi

if python3 - "$LEM_YATH_FORGE_FAKE_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert calls
assert all(isinstance(call, list) and all(isinstance(arg, str) for arg in call) for call in calls)
assert all("GH_TOKEN" not in arg and "github_pat" not in arg for call in calls for arg in call)
assert any("Comment from Lem\nsecond line; safe" in call for call in calls)
assert any("Created from Lem; safe" in call for call in calls)
PY
then
  pass argv 'all backend operations used direct token-free argv vectors'
else
  fail argv 'backend argv logging exposed malformed or credential-bearing calls'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
