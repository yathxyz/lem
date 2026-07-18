#!/usr/bin/env bash
# soak-self-test.sh -- leak-detector self-test (SPEC-PERF PF-8 done-when:
# "the leak detector catches a deliberately-injected leak").
#
# Runs the SAME short soak twice against the real ./lem binary:
#   * LEAK arm  (SOAK_INJECT_LEAK=1): an idle timer -- injected purely via
#     --eval, NO source changes -- pushes a byte array onto a global list every
#     idle tick (soak.sh defaults: 4 MiB every 1 s of idle).  Deliberately large
#     so it clears the short-run RSS noise and exercises the full "RSS AND DU"
#     gate; the DU floor is the sensitive signal.  The detector MUST flag it
#     (soak.sh exit 1 = LEAK SUSPECT).
#   * CLEAN arm (SOAK_INJECT_LEAK=0): the identical workload with no injection.
#     The detector MUST NOT flag it (soak.sh exit 0 = CLEAN).
#
# Each arm is a standalone soak.sh subprocess: its own private tmux socket and
# mktemp sandbox (Constraint 7), torn down by its own trap.  Both arms must
# reach a definitive verdict (exit 2 = INSUFFICIENT DATA fails the self-test --
# it means the run was too short to sample; lengthen LEM_SOAK_SECONDS).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Short by design; long enough to accumulate second-half samples on both signals
# (~10 s external RSS cadence; in-image dynamic-usage sampled during the idle
# rests).  Overridable for debugging.
export LEM_SOAK_SECONDS="${LEM_SOAK_SECONDS:-200}"
export SOAK_REST_SECONDS="${SOAK_REST_SECONDS:-12}"
export SOAK_THRESHOLD_MB_MIN="${SOAK_THRESHOLD_MB_MIN:-1}"

pass=0
fail=0
_check() {  # description expected actual
  if [ "$2" = "$3" ]; then
    printf 'PASS  %-40s (exit %s)\n' "$1" "$3"
    pass=$(( pass + 1 ))
  else
    printf 'FAIL  %-40s (expected exit %s, got %s)\n' "$1" "$2" "$3"
    fail=$(( fail + 1 ))
  fi
}

echo "== leak-detector self-test: soak ${LEM_SOAK_SECONDS}s x2 arms =="

echo "-- arm 1/2: INJECTED LEAK (expect LEAK SUSPECT, exit 1) --"
leak_rc=0
SOAK_INJECT_LEAK=1 SOAK_TAG="soak-selftest-leak" "$HERE/soak.sh" || leak_rc=$?
_check "injected-leak arm flags LEAK SUSPECT" 1 "$leak_rc"

echo
echo "-- arm 2/2: CLEAN (expect CLEAN, exit 0) --"
clean_rc=0
SOAK_INJECT_LEAK=0 SOAK_TAG="soak-selftest-clean" "$HERE/soak.sh" || clean_rc=$?
_check "clean arm does NOT flag" 0 "$clean_rc"

echo
echo "== self-test summary: ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
