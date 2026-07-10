#!/usr/bin/env bash
# Boot Lem with the lem-yath config inside tmux and assert a clean load.
# Safe to run concurrently: session/report names are unique per invocation.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-$$}"
session="lem-yath-boot-$id"
tmp="${TMPDIR:-/tmp}"
report="$tmp/lem-yath-boot-report-$id"
rm -f "$report"

lem_start_lem-yath_eval "$session" \
  "(uiop:symbol-call :lem-yath :write-boot-report $(lem-yath_lisp_string "$report"))" \
  --log-filename "$tmp/lem-yath-lem-$id.log"

ok=0
for _ in $(seq 1 120); do
  [ -f "$report" ] && { ok=1; break; }
  sleep 0.5
done

screen="$(lem_capture "$session" 2>/dev/null || true)"
lem_stop "$session"

if [ "$ok" != 1 ]; then
  echo "FAIL: boot report never appeared; last screen:"
  echo "$screen"
  exit 1
fi

echo "--- boot report ---"
cat "$report"
echo "-------------------"

fail=0
grep -q '^boot-error: none$' "$report" || { echo "FAIL: boot error"; fail=1; }
grep -q '^boot-ok: T$' "$report" || { echo "FAIL: boot-ok not T"; fail=1; }
grep -qi '^vi-mode: T$' "$report" || { echo "FAIL: vi-mode inactive"; fail=1; }
grep -q '^leader: Space$' "$report" || { echo "FAIL: leader not Space"; fail=1; }
grep -q 'rust-spec: (rust-analyzer)' "$report" || { echo "FAIL: rust spec"; fail=1; }
grep -q 'commands: t t t t t t' "$report" || { echo "FAIL: missing commands"; fail=1; }

if [ "$fail" = 0 ]; then echo "BOOT TEST PASSED"; else echo "BOOT TEST FAILED"; exit 1; fi
