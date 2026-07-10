#!/usr/bin/env bash
# Regression test: multi-token orderless filtering must survive Space in the
# prompt completion popup (lem-yath-completion-space overrides Lem's stock
# insert-space-and-cancel binding). "roam" must list the roam commands; adding
# " fi" must narrow to lem-yath-roam-find with the popup still open.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-$$}"
s="lem-yath-orderless-$id"
lem_start_lem-yath "$s"
sleep 5
lem_keys "$s" M-x
sleep 1
lem_keys "$s" roam
lem_wait_for "$s" "lem-yath-roam-find" 10 || { echo "FAIL: popup never showed roam candidates"; lem_stop "$s"; exit 1; }
lem_keys "$s" Space
sleep 0.5
lem_keys "$s" fi
sleep 1.5
screen=$(lem_capture "$s")
lem_stop "$s"
if echo "$screen" | grep -q "Command: roam fi" && echo "$screen" | grep -q "lem-yath-roam-find"; then
  echo "ORDERLESS TEST PASSED"
else
  echo "ORDERLESS TEST FAILED (popup closed at the space, or candidate gone); screen was:"
  echo "$screen"
  exit 1
fi
