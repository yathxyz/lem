#!/usr/bin/env bash
# SPEC-PERF PF-3 -- performance bench runner.
#
# Usage:
#   scripts/run-bench.sh [--rebaseline] <t1|t2|t3|all> ...
#
# Builds/loads what the tier needs, runs it, writes a result JSON under
# bench/results/, compares against the committed baseline in bench/baselines/,
# prints a delta table, and exits nonzero on a gated regression (T1/T2 are
# gated; T3 wall numbers are trend-only).  `--rebaseline` regenerates the
# baseline for the given tier(s) instead of comparing -- do this only after an
# accepted change and record the rationale in bench/README.md (Constraint 6).
#
# Baselines are per-machine: every result carries a fingerprint (hostname + CPU
# model + core count) and comparisons only run against a matching fingerprint
# (Constraint 5).
#
# Directory overrides (used by the self-test so it never clobbers the committed
# baseline): BENCH_RESULTS_DIR, BENCH_BASELINES_DIR.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

usage() {
  echo "usage: scripts/run-bench.sh [--rebaseline] <t1|t2|t3|all> ..." >&2
}

REBASELINE=0
TIERS=()
for arg in "$@"; do
  case "$arg" in
    --rebaseline) REBASELINE=1 ;;
    -h|--help)    usage; exit 0 ;;
    t1|t2|t3)     TIERS+=("$arg") ;;
    all)          TIERS+=("t1") ;;   # only T1 exists at milestone P0
    *) echo "unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done
if [ "${#TIERS[@]}" -eq 0 ]; then usage; exit 2; fi

# --- fingerprint (hostname + CPU model + core count) ------------------------
FP_HOST="$(hostname)"
FP_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//')"
[ -n "$FP_CPU" ] || FP_CPU="unknown-cpu"
FP_CORES="$(nproc 2>/dev/null || echo 0)"
FINGERPRINT="${FP_HOST} | ${FP_CPU} | ${FP_CORES}c"
FP_SLUG="$(printf '%s-%s-%sc' "$FP_HOST" "$FP_CPU" "$FP_CORES" \
           | tr -c 'A-Za-z0-9._-' '-' | tr -s '-' | sed 's/^-//;s/-$//')"

RESULTS_DIR="${BENCH_RESULTS_DIR:-$ROOT/bench/results}"
BASELINES_DIR="${BENCH_BASELINES_DIR:-$ROOT/bench/baselines}"
mkdir -p "$RESULTS_DIR" "$BASELINES_DIR"

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
MODE="measure"; [ "$REBASELINE" -eq 1 ] && MODE="rebaseline"

rc=0
for tier in "${TIERS[@]}"; do
  DRIVER="$ROOT/scripts/bench/run-$tier.lisp"
  if [ ! -f "$DRIVER" ]; then
    echo "== tier $tier: no driver ($DRIVER) yet, skipping ==" >&2
    continue
  fi
  echo "== bench tier=$tier mode=$MODE fingerprint=[$FINGERPRINT] =="
  LEM_BENCH_MODE="$MODE" \
  LEM_BENCH_TIER="$tier" \
  LEM_BENCH_FINGERPRINT="$FINGERPRINT" \
  LEM_BENCH_FP_SLUG="$FP_SLUG" \
  LEM_BENCH_TIMESTAMP="$TIMESTAMP" \
  LEM_BENCH_RESULTS_DIR="$RESULTS_DIR" \
  LEM_BENCH_BASELINES_DIR="$BASELINES_DIR" \
  sbcl --dynamic-space-size 4GiB --noinform --no-sysinit --no-userinit \
       --non-interactive \
       --load .qlot/setup.lisp \
       --eval "(ql:quickload :lem/core :silent t)" \
       --load "$DRIVER"
  tier_rc=$?
  [ "$tier_rc" -ne 0 ] && rc="$tier_rc"
done

if [ "$REBASELINE" -eq 1 ]; then
  echo
  echo "Rebaselined. Constraint 6: record the rebaseline rationale as a ledger"
  echo "entry in bench/README.md before committing the new baseline."
fi
exit "$rc"
