#!/usr/bin/env bash
# startup.sh -- T3 startup-to-ready measurement (SPEC-PERF PF-7).
#
# Times from the `exec' of ./lem to the editor being ready, where "ready" is a
# distinctive sentinel drawn by an --eval marker insertion appearing in
# capture-pane.  Cold = the first run of the batch; warm = the median of the
# next 5.  Asserts warm < 2s (hard budget, PF-7).
#
# Runs standalone (sources driver.sh + common.sh, builds its own sandbox) or is
# sourced by run-t3.sh (which sets up the sandbox and $E2E_KV, then calls
# e2e_startup_run).

E2E_STARTUP_WARM_RUNS="${E2E_STARTUP_WARM_RUNS:-5}"
E2E_BUDGET_STARTUP_MS="${E2E_BUDGET_STARTUP_MS:-2000}"

E2E_READY_MARKER="E2E_READY_MARKER"
# Insert the ready sentinel into a fresh (writable) buffer -- NOT the read-only
# *dashboard* splash, which an insert would error into.
E2E_STARTUP_EVAL='(let ((b (lem:make-buffer "*e2e*"))) (lem:switch-to-buffer b) (lem:insert-string (lem:buffer-point b) "'"$E2E_READY_MARKER"'"))'

# Elapsed milliseconds between two `date +%s.%N' stamps.
_e2e_ms_between() {
  node -e 'process.stdout.write(((Number(process.argv[2])-Number(process.argv[1]))*1000).toFixed(3)+"\n")' "$1" "$2"
}

# One timed startup: launch, wait for the sentinel, stop.  Echoes elapsed ms.
_e2e_startup_once() {
  local session="$1"
  local t0 t1
  t0="$(date +%s.%N)"
  lem_start "$session" "$E2E_STARTUP_EVAL"
  if ! lem_wait_for "$session" "$E2E_READY_MARKER" 20; then
    echo "startup: sentinel never appeared for $session" >&2
    lem_capture "$session" | head -12 >&2
    lem_stop "$session" || true
    return 1
  fi
  t1="$(date +%s.%N)"
  if ! lem_stop "$session"; then
    echo "startup: $session did not exit cleanly" >&2
    return 1
  fi
  _e2e_ms_between "$t0" "$t1"
}

e2e_startup_run() {
  echo "== startup: cold + ${E2E_STARTUP_WARM_RUNS} warm ==" >&2
  local cold warm=() ms i
  cold="$(_e2e_startup_once startup-cold)" || return 1
  printf '    cold                     %8s ms\n' "$cold" >&2
  for i in $(seq 1 "$E2E_STARTUP_WARM_RUNS"); do
    ms="$(_e2e_startup_once "startup-warm-$i")" || return 1
    warm+=("$ms")
    printf '    warm[%d]                  %8s ms\n' "$i" "$ms" >&2
  done
  local stats warm_min warm_med warm_p90
  stats="$(printf '%s\n' "${warm[@]}" | e2e_stats)"
  read -r warm_min warm_med warm_p90 _ <<<"$stats"

  e2e_entry "startup/cold" "ms" "$cold" "$cold" "$cold" 1
  e2e_entry "startup/warm" "ms" "$warm_min" "$warm_med" "$warm_p90" "$E2E_STARTUP_WARM_RUNS"
  e2e_budget "startup/warm" "$warm_med" "$E2E_BUDGET_STARTUP_MS"
}

# --- standalone entry -------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=./driver.sh
  source "$_here/driver.sh"
  # shellcheck source=./common.sh
  source "$_here/common.sh"
  lem_e2e_init
  E2E_KV="$(mktemp "${TMPDIR:-/tmp}/lem-e2e-kv.XXXXXX")"
  trap 'rm -f "$E2E_KV"; lem_e2e_cleanup' EXIT INT TERM
  e2e_startup_run
  echo "--- results ---"
  cat "$E2E_KV"
  # Standalone exit code reflects the budget verdicts.
  if grep -q $'\tFAIL$' "$E2E_KV"; then exit 1; fi
fi
