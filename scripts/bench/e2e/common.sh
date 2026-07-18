#!/usr/bin/env bash
# common.sh -- shared result-emission + stats helpers for the T3 e2e harness
# (SPEC-PERF PF-7).  Sourced by startup.sh and keystroke.sh (which are sourced,
# in turn, by run-t3.sh).  Keeps the tmux primitives in driver.sh separate from
# the bench bookkeeping here.
#
# Results are accumulated as tab-separated lines in the file named by $E2E_KV:
#
#   ENTRY  <name> <unit> <min> <median> <p90> <n>   -> a PF-3 result entry (JSON)
#   BUDGET <name> <actual_ms> <limit_ms> <PASS|FAIL> -> a hard budget check
#   TREND  <name> <unit> <value>                     -> informational only
#
# run-t3.sh renders ENTRY lines into the PF-3-schema JSON, prints the BUDGET
# table, and exits nonzero iff any BUDGET is FAIL (or a harness step failed).
# TREND lines (wall numbers) NEVER gate -- SPEC-PERF PF-7: only the in-image
# PF-2-derived percentiles hard-fail.

# min/median/p90/p95 of the whitespace-separated numbers on stdin, echoed as
# "min median p90 p95" (nearest-rank, matching the lisp drivers' sorted-stat).
e2e_stats() {
  node -e '
    const nums = require("fs").readFileSync(0, "utf8").trim().split(/\s+/)
      .filter(s => s.length).map(Number).filter(x => !Number.isNaN(x)).sort((a,b)=>a-b);
    if (nums.length === 0) { process.stdout.write("0 0 0 0\n"); process.exit(0); }
    const pct = f => { const i = Math.min(nums.length-1, Math.max(0, Math.ceil(f*nums.length)-1)); return nums[i]; };
    process.stdout.write([nums[0], pct(0.5), pct(0.9), pct(0.95)].map(x=>x.toFixed(3)).join(" ")+"\n");
  '
}

# us -> ms with three decimals.
e2e_us_to_ms() {
  node -e 'process.stdout.write((Number(process.argv[1])/1000).toFixed(3)+"\n")' "$1"
}

e2e_entry() {
  # name unit min median p90 n
  printf 'ENTRY\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$E2E_KV"
}

e2e_trend() {
  # name unit value
  printf 'TREND\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$E2E_KV"
}

# name actual_ms limit_ms -- records and prints a hard budget check.
e2e_budget() {
  local name="$1" actual="$2" limit="$3" verdict
  if node -e 'process.exit(Number(process.argv[1]) < Number(process.argv[2]) ? 0 : 1)' "$actual" "$limit"; then
    verdict="PASS"
  else
    verdict="FAIL"
  fi
  printf 'BUDGET\t%s\t%s\t%s\t%s\n' "$name" "$actual" "$limit" "$verdict" >> "$E2E_KV"
  printf '    budget %-28s %8s ms  (< %s ms)  %s\n' "$name" "$actual" "$limit" "$verdict" >&2
}
