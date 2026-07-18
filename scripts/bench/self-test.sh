#!/usr/bin/env bash
# SPEC-PERF PF-3 self-test: proves the gate catches a regression.
#
# Establishes a clean baseline in a throwaway directory (so the committed
# baseline is never touched), confirms a clean run passes, then injects a
# synthetic slowdown (LEM_BENCH_INJECT_SLEEP_US) and asserts the run exits
# nonzero.  Runs entirely off the committed working tree.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lem-bench-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export BENCH_BASELINES_DIR="$TMP/baselines"
export BENCH_RESULTS_DIR="$TMP/results"

echo "[self-test] 1/3 establishing clean baseline in $TMP ..."
if ! scripts/run-bench.sh --rebaseline t1; then
  echo "[self-test] FAIL: clean rebaseline errored" >&2
  exit 1
fi

echo "[self-test] 2/3 clean run must pass green ..."
if ! scripts/run-bench.sh t1; then
  echo "[self-test] FAIL: clean run regressed against its own baseline" >&2
  exit 1
fi

echo "[self-test] 3/3 injected regression (LEM_BENCH_INJECT_SLEEP_US=50) must fail ..."
if LEM_BENCH_INJECT_SLEEP_US=50 scripts/run-bench.sh t1; then
  echo "[self-test] FAIL: injected regression was NOT caught (exit 0)" >&2
  exit 1
fi

echo "[self-test] PASS: injected regression caught with nonzero exit."
exit 0
