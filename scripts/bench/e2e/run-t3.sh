#!/usr/bin/env bash
# run-t3.sh -- T3 end-to-end tier orchestrator (SPEC-PERF PF-7).
#
# Invoked by scripts/run-bench.sh for tier t3 (and runnable directly).  Builds
# ONE sandbox + private tmux socket, runs the startup and keystroke scenarios,
# writes a PF-3-schema result JSON into bench/results/ (gitignored), prints a
# budget-vs-actual table, and exits nonzero ONLY on a hard-budget violation or a
# harness failure -- NEVER on the wall-clock trends (SPEC-PERF PF-7: only the
# in-image PF-2-derived numbers hard-fail).
#
# T3 keeps NO committed baseline (there is no band gate for a noisy wall tier):
# its trend history lives in the bench/README.md ledger, so `--rebaseline t3' is
# not applicable and run-bench.sh short-circuits it.
#
# Config passed through the environment by run-bench.sh (with standalone
# fallbacks): LEM_BENCH_RESULTS_DIR, LEM_BENCH_FP_SLUG, LEM_BENCH_TIMESTAMP,
# LEM_BENCH_FINGERPRINT.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./driver.sh
source "$HERE/driver.sh"
# shellcheck source=./common.sh
source "$HERE/common.sh"
# shellcheck source=./startup.sh
source "$HERE/startup.sh"
# shellcheck source=./keystroke.sh
source "$HERE/keystroke.sh"

RESULTS_DIR="${LEM_BENCH_RESULTS_DIR:-$E2E_REPO_ROOT/bench/results}"
FP_SLUG="${LEM_BENCH_FP_SLUG:-standalone}"
TIMESTAMP="${LEM_BENCH_TIMESTAMP:-$(date +%Y%m%d%H%M%S)}"
FINGERPRINT="${LEM_BENCH_FINGERPRINT:-$(hostname)}"
COMMIT="$(git -C "$E2E_REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

lem_e2e_init
E2E_KV="$LEM_E2E_ROOT/results.kv"
: > "$E2E_KV"

HARNESS_RC=0
e2e_startup_run   || HARNESS_RC=1
e2e_keystroke_run || HARNESS_RC=1

mkdir -p "$RESULTS_DIR"
RESULT_JSON="$RESULTS_DIR/${FP_SLUG}-t3-${TIMESTAMP}.json"

# ENTRY lines -> PF-3-schema JSON.
node -e '
  const fs = require("fs");
  const [kv, out, fp, commit, ts] = process.argv.slice(1);
  const entries = [];
  for (const line of fs.readFileSync(kv, "utf8").split("\n")) {
    const f = line.split("\t");
    if (f[0] !== "ENTRY") continue;
    entries.push({
      name: f[1], unit: f[2],
      min: Number(f[3]), median: Number(f[4]), p90: Number(f[5]),
      "consed-per-op": 0, n: Number(f[6]),
    });
  }
  const doc = { fingerprint: fp, tier: "t3", commit, timestamp: ts, entries };
  fs.writeFileSync(out, JSON.stringify(doc, null, 2) + "\n");
' "$E2E_KV" "$RESULT_JSON" "$FINGERPRINT" "$COMMIT" "$TIMESTAMP"
echo "Results written: $RESULT_JSON"

# Budget-vs-actual table from BUDGET lines.
echo
printf '%s\n' "======================================================================"
printf '%-34s %10s %10s  %s\n' "budget check" "actual ms" "limit ms" "verdict"
printf '%s\n' "----------------------------------------------------------------------"
BUDGET_FAIL=0
while IFS=$'\t' read -r tag name actual limit verdict; do
  [ "$tag" = "BUDGET" ] || continue
  printf '%-34s %10s %10s  %s\n' "$name" "$actual" "$limit" "$verdict"
  [ "$verdict" = "FAIL" ] && BUDGET_FAIL=1
done < "$E2E_KV"
printf '%s\n' "======================================================================"
echo "(wall-clock numbers are TREND-only and never gate; hard fails are the"
echo " in-image PF-2 keystroke p95 budgets and the warm-startup budget above.)"

if [ "$HARNESS_RC" -ne 0 ]; then
  echo "T3: HARNESS FAILURE"
  exit 1
fi
if [ "$BUDGET_FAIL" -ne 0 ]; then
  echo "T3: BUDGET VIOLATION"
  exit 1
fi
echo "T3: OK (all budgets within limits)"
exit 0
