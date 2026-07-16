#!/usr/bin/env bash
# Real-ncurses coverage for configured org-download clipboard and yank commands.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-download-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-download.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export XDG_SESSION_TYPE=wayland
export LEM_YATH_ORG_DOWNLOAD_REPORT="$root/report"
export LEM_YATH_ORG_DOWNLOAD_EXEC_LOG="$root/exec.jsonl"
fakebin="$root/bin"
export LEM_YATH_ORG_DOWNLOAD_TEST_BIN="$fakebin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR/notes" "$fakebin"

python="$(command -v python3)"
for program in curl wl-paste xclip; do
  cp "$here/scripts/org-download-fake.py" "$fakebin/$program"
  sed -i "1c#!$python" "$fakebin/$program"
  chmod +x "$fakebin/$program"
done
export PATH="$fakebin:$PATH"

fixture="$WORKDIR/notes/download.org"
printf '%s\n' \
  '#+TITLE: Download fixture' \
  '' \
  '* Clipboard' \
  'Clipboard insertion point' \
  '' \
  '* Yank' \
  'Yank insertion point' \
  >"$fixture"

local_source="$root/local source.png"
printf '\211PNG\r\n\032\nlocal-fixture' >"$local_source"
export LEM_YATH_ORG_DOWNLOAD_URL='https://images.example/image%20name.PNG?token=secret;$(touch nope)'
encoded_local="${local_source// /%20}"
export LEM_YATH_ORG_DOWNLOAD_FILE_URL="file://$encoded_local"
: >"$LEM_YATH_ORG_DOWNLOAD_REPORT"
: >"$LEM_YATH_ORG_DOWNLOAD_EXEC_LOG"

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-download-fixture.lisp")"
session="lem-yath-org-download-$id"
failed=0

cleanup() {
  lem_stop "$session" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-25s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-25s %s\n' "$1" "$2"
  tail -80 "$LEM_YATH_ORG_DOWNLOAD_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

mx() {
  local command="$1"
  local index
  tmux_cmd send-keys -t "$session" Escape Escape
  sleep 0.5
  wait_screen_absent 'Command:' 5 || return 1
  tmux_cmd send-keys -t "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  for ((index = 0; index < ${#command}; index++)); do
    tmux_cmd send-keys -t "$session" -l -- "${command:index:1}"
    sleep 0.03
  done
  lem_wait_for "$session" "Command: ${command}" 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" Enter
  wait_screen_absent 'Command:' 10 || return 1
  sleep 0.25
}

wait_screen_absent() {
  local pattern="$1" timeout="${2:-10}" attempts=0
  while ((attempts < timeout * 4)); do
    if ! lem_capture "$session" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_count() {
  grep -c '^STATE ' "$LEM_YATH_ORG_DOWNLOAD_REPORT" 2>/dev/null || true
}

report_state() {
  local before after attempts=0
  before="$(report_count)"
  lem_keys "$session" F4
  while ((attempts < 80)); do
    after="$(report_count)"
    if ((after > before)); then
      grep '^STATE ' "$LEM_YATH_ORG_DOWNLOAD_REPORT" | tail -1
      return 0
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  return 1
}

state_text() {
  printf '%s' "${1#* text=}"
}

media_files() {
  find "$WORKDIR/media" -maxdepth 1 -type f ! -name '.lem-yath-download.*' -printf '%f\n' 2>/dev/null | sort
}

curl_count() {
  grep -c '"program": "curl"' "$LEM_YATH_ORG_DOWNLOAD_EXEC_LOG" 2>/dev/null || true
}

lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"
if lem_wait_for "$session" 'Download fixture' 60 >/dev/null &&
   grep -q '^READY$' "$LEM_YATH_ORG_DOWNLOAD_REPORT"; then
  pass boot 'configured Org buffer and fixture loaded'
else
  fail boot 'Org download fixture did not become ready'
  exit 1
fi
lem_keys "$session" Escape
mx lem-yath-test-org-download-commands || true
sleep 0.5
if grep -q '^COMMANDS yank=yes clipboard=yes$' "$LEM_YATH_ORG_DOWNLOAD_REPORT"; then
  pass commands 'both exact Emacs command names are registered'
else
  fail commands 'one or both configured M-x commands are absent'
  exit 1
fi

# URL yank: physical M-x, URL kept off argv, timestamped relative link, and one undo.
lem_keys "$session" F2 F5
yank_file='2026-07-16_12-34-56_image name.png'
if mx org-download-yank &&
   lem_wait_for "$session" 'Downloaded Org image to' 15 >/dev/null; then
  yank_state="$(report_state || true)"
  if [[ "$yank_state" == *'#+DOWNLOADED: https://images.example/image%20name.PNG?token=secret;$(touch nope) @ 2026-07-16 12:34:56'* ]] &&
     [[ "$yank_state" == *'[[file:../media/2026-07-16_12-34-56_image name.png]]'* ]] &&
     [[ "$(media_files)" == "$yank_file" ]] &&
     [ "$(stat -c %a "$WORKDIR/media/$yank_file")" = 644 ]; then
    pass yank 'URL image, annotation, relative link, timestamp, and mode match'
  else
    fail yank "URL yank diverged: $yank_state files=$(media_files)"
  fi
else
  fail yank 'physical org-download-yank did not complete'
  exit 1
fi

if python3 - "$LEM_YATH_ORG_DOWNLOAD_EXEC_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
curl = next(row for row in rows if row["program"] == "curl")
assert not any("images.example" in arg or "secret" in arg for arg in curl["argv"])
assert 'url = "https://images.example/image%20name.PNG?token=secret;$(touch nope)"' in curl["config"]
assert curl["argv"][-4:] == ["--proto", "=http,https", "--proto-redir", "=http,https"]
PY
then
  pass transport 'URL and metacharacters stayed inert on curl stdin config'
else
  fail transport 'curl argv/config boundary diverged'
fi

sleep 0.5
lem_keys "$session" u
sleep 0.5
yank_undo="$(report_state || true)"
if [[ "$yank_undo" != *'#+DOWNLOADED:'* ]] &&
   [ -f "$WORKDIR/media/$yank_file" ]; then
  pass yank-undo 'one Normal undo removed the annotation/link but kept the image'
else
  fail yank-undo "URL insertion was not one undo unit: $yank_undo"
  exit 1
fi

# Wayland clipboard: exact backend, generated ID, and link share one undo unit.
lem_keys "$session" F3
clipboard_file='2026-07-16_12-34-56_screenshot.png'
if mx org-download-clipboard &&
   lem_wait_for "$session" 'Captured Org clipboard image to' 15 >/dev/null; then
  clipboard_state="$(report_state || true)"
  if [[ "$clipboard_state" == *':PROPERTIES:'* ]] &&
     [[ "$clipboard_state" == *':ID: '* ]] &&
     [[ "$clipboard_state" == *'#+DOWNLOADED: screenshot @ 2026-07-16 12:34:56'* ]] &&
     [[ "$clipboard_state" == *'[[file:../media/2026-07-16_12-34-56_screenshot.png]]'* ]] &&
     [ -f "$WORKDIR/media/$clipboard_file" ] &&
     python3 - "$LEM_YATH_ORG_DOWNLOAD_EXEC_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
row = next(row for row in rows if row["program"] == "wl-paste")
assert row["argv"] == ["--type", "image/png"]
PY
  then
    pass clipboard-wayland 'wl-paste capture created an ID, annotation, and relative link'
  else
    fail clipboard-wayland "Wayland clipboard capture diverged: $clipboard_state"
  fi
else
  fail clipboard-wayland 'physical clipboard command did not complete'
fi

sleep 0.5
lem_keys "$session" u
sleep 0.5
clipboard_undo="$(report_state || true)"
if [[ "$clipboard_undo" != *':ID: '* ]] &&
   [[ "$clipboard_undo" != *'#+DOWNLOADED: screenshot'* ]] &&
   [ -f "$WORKDIR/media/$clipboard_file" ]; then
  pass clipboard-undo 'one undo removed both the generated ID and image link'
else
  fail clipboard-undo "clipboard edit escaped its one undo unit: $clipboard_undo"
fi

# X11 fallback is selected from the live environment and uses direct argv.
lem_keys "$session" F8 F3
if mx org-download-clipboard &&
   lem_wait_for "$session" 'Captured Org clipboard image to' 15 >/dev/null; then
  xclip_file='2026-07-16_12-34-57_screenshot.png'
  if [ -f "$WORKDIR/media/$xclip_file" ] &&
     python3 - "$LEM_YATH_ORG_DOWNLOAD_EXEC_LOG" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
expected = ["-selection", "clipboard", "-target", "image/png", "-out"]
actual = [row["argv"] for row in rows if row["program"] == "xclip"]
assert expected in actual, {"actual": actual, "expected": expected}
PY
  then
    pass clipboard-x11 'xclip fallback used the configured direct argument vector'
  else
    fail clipboard-x11 'X11 clipboard backend or target file diverged'
  fi
else
  fail clipboard-x11 'X11 clipboard capture did not complete'
fi

# Local file URLs do not invoke curl and retain decoded basenames.
lem_keys "$session" F2 F7
curl_before="$(curl_count)"
if mx org-download-yank &&
   lem_wait_for "$session" 'Downloaded Org image to' 15 >/dev/null; then
  local_file='2026-07-16_12-34-58_local source.png'
  curl_after="$(curl_count)"
  if [ -f "$WORKDIR/media/$local_file" ] && [ "$curl_after" = "$curl_before" ]; then
    pass file-url 'percent-decoded local file URL copied without a network process'
  else
    fail file-url 'local file URL path, name, or transport diverged'
  fi
else
  fail file-url 'local file URL did not complete'
fi

# Invalid payload, oversize output, invalid kill text, and read-only state fail cleanly.
baseline_state="$(report_state || true)"
baseline_text="$(state_text "$baseline_state")"
baseline_files="$(media_files)"
lem_keys "$session" F2 F6
mx org-download-yank || true
if lem_wait_for "$session" 'recognized image or PDF' 15 >/dev/null; then
  bad_state="$(report_state || true)"
  if [ "$(state_text "$bad_state")" = "$baseline_text" ] &&
     [ "$(media_files)" = "$baseline_files" ] &&
     ! find "$WORKDIR/media" -maxdepth 1 -name '.lem-yath-download.*' | grep -q .; then
    pass invalid-image 'non-image output left neither text, target, nor temporary file'
  else
    fail invalid-image 'non-image output escaped transactional cleanup'
  fi
else
  fail invalid-image 'non-image output was not rejected visibly'
fi

lem_keys "$session" F9
mx org-download-yank || true
if lem_wait_for "$session" 'exceeds the 1 KiB limit' 15 >/dev/null &&
   [ "$(media_files)" = "$baseline_files" ]; then
  pass size-bound 'oversize clipboard/network output was terminated and removed'
else
  fail size-bound 'oversize output was not rejected cleanly'
fi

lem_keys "$session" F10
curl_before="$(curl_count)"
mx org-download-yank || true
if lem_wait_for "$session" 'Unsupported Org download URL scheme' 15 >/dev/null; then
  curl_after="$(curl_count)"
  if [ "$curl_after" = "$curl_before" ]; then
    pass invalid-url 'non-URL kill text failed before launching a process'
  else
    fail invalid-url 'invalid kill text launched curl'
  fi
else
  fail invalid-url 'invalid kill text was not rejected'
fi

lem_keys "$session" C-c z r F5
curl_before="$(curl_count)"
mx org-download-yank || true
if lem_wait_for "$session" 'Org buffer is read-only' 15 >/dev/null; then
  curl_after="$(curl_count)"
  if [ "$curl_after" = "$curl_before" ]; then
    pass read-only 'read-only refusal occurred before network or filesystem work'
  else
    fail read-only 'read-only buffer still launched a transfer'
  fi
else
  fail read-only 'read-only buffer was not refused visibly'
fi
lem_keys "$session" C-c z w

if ((failed)); then
  printf '\nORG DOWNLOAD TEST FAILED\n'
  exit 1
fi

printf '\nORG DOWNLOAD TEST PASSED\n'
