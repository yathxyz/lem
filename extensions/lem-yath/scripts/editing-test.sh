#!/usr/bin/env bash
# Hermetic real-Lem regression tests for touched-line whitespace cleanup.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-editing-$$}"
session="lem-yath-editing-$id"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-editing.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_EDITING_TEST_ROOT="$root/fixtures"
export LEM_YATH_EDITING_REPORT="$root/report"
mkdir -p "$HOME" "$WORKDIR" "$LEM_YATH_EDITING_TEST_ROOT"

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

test_file="$(lem-yath_lisp_string "$here/scripts/editing-test.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$test_file)"
for _ in $(seq 1 240); do
  if [ -f "$LEM_YATH_EDITING_REPORT" ] &&
     grep -q '^SUMMARY ' "$LEM_YATH_EDITING_REPORT"; then
    break
  fi
  sleep 0.25
done

if [ ! -f "$LEM_YATH_EDITING_REPORT" ]; then
  echo "EDITING TEST FAILED: Lem produced no report"
  lem_capture "$session" 2>/dev/null || true
  exit 1
fi

cat "$LEM_YATH_EDITING_REPORT"
grep -q '^SUMMARY PASS ' "$LEM_YATH_EDITING_REPORT"
