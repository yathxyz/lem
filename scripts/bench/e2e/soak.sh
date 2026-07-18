#!/usr/bin/env bash
# soak.sh -- T3 soak run + leak detector (SPEC-PERF PF-8).
#
# A scripted, key-driven editing loop against the REAL ncurses ./lem binary in
# the sandboxed private-socket tmux (reusing driver.sh -- Constraint 7 stays
# structural: unique socket, mktemp sandbox, cleanup kills only its own).  It
# cycles key analogs of the T2 (PF-5) workload actions -- open the 10 MB file,
# page, isearch key sequences, edits + undo, scrolling -- for LEM_SOAK_SECONDS
# (default 1800), then exits the editor cleanly so the metrics dump fires.
#
# Two independent memory signals feed the detector:
#   * external RSS -- sampled from /proc/<pane_pid>/status every
#     SOAK_SAMPLE_INTERVAL (10 s) into a CSV, so the analysis does NOT depend on
#     any in-image state (SPEC-PERF PF-8).
#   * in-image dynamic-usage -- the metrics heap ring (idle-timer sampled); the
#     active bursts are separated by an idle REST (SOAK_REST_SECONDS, default 12,
#     > the 10 s metrics sample period) so the idle timer actually fires and the
#     dump carries dynamic-usage samples across the run.
#
# analyze-soak.mjs fits both second halves and flags a leak only when BOTH
# exceed the threshold.  soak.sh's own exit code IS the detector verdict
# (0 clean, 1 leak suspect, 2 insufficient data) -- that is what the self-test
# asserts.  When wired into run-t3.sh (LEM_T3_SOAK=1) the verdict is reported
# loudly but treated as a TREND, not a hard gate (consistent with T3: only the
# in-image keystroke/startup budgets ever hard-fail).
#
# Runs standalone or is sourced by run-t3.sh (which owns the sandbox); call
# e2e_soak_run.

LEM_SOAK_SECONDS="${LEM_SOAK_SECONDS:-1800}"
SOAK_REST_SECONDS="${SOAK_REST_SECONDS:-12}"
SOAK_SAMPLE_INTERVAL="${SOAK_SAMPLE_INTERVAL:-10}"
SOAK_THRESHOLD_MB_MIN="${SOAK_THRESHOLD_MB_MIN:-1}"
SOAK_PACE="${SOAK_PACE:-0.02}"
SOAK_INJECT_LEAK="${SOAK_INJECT_LEAK:-0}"
# The injected leak is deliberately LARGE and fast (4 MiB retained per second of
# idle => hundreds of MB over a short self-test).  It only affects the LEAK arm
# (SOAK_INJECT_LEAK=1); the clean arm is unaffected.  A big leak is required
# because on a short run the external RSS second-half slope is warm-up /
# munmap-dominated noise (measured band ~+-20 MB/min): a small leak's retained
# growth hides under it, so a small injection moves the GC-noise-free DU floor
# but NOT the RSS slope, and the "RSS AND DU" gate would (correctly, per its own
# rule) not fire.  A large leak clears the RSS noise unambiguously, proving the
# detector end to end.  A real editor leak on the 30-min soak is caught by the
# far more sensitive DU-floor signal (the RSS AND is the conservative
# corroboration PF-8 asks for).
SOAK_LEAK_BYTES="${SOAK_LEAK_BYTES:-4194304}"  # 4 MiB retained per idle tick ...
SOAK_LEAK_MS="${SOAK_LEAK_MS:-1000}"           # ... every 1 s of idle
SOAK_TAG="${SOAK_TAG:-soak-$(date +%Y%m%d%H%M%S)}"

E2E_READY_MARKER="E2E_READY_MARKER"
SOAK_SAMPLER_PID=""

# Where durable artifacts (CSV, copied dump, analysis) land -- OUTSIDE the
# sandbox, which cleanup deletes.  bench/results/ is gitignored.  Resolved in
# e2e_soak_run (after driver.sh has set E2E_REPO_ROOT); overridable via env.
SOAK_OUT_DIR="${SOAK_OUT_DIR:-}"

# Build the --eval form: (optionally) install a leak timer, then draw the ready
# marker at point in the freshly-opened file buffer (matching keystroke.sh's
# file scenarios).  The leak is a PURE TEST-SIDE injection -- NO source changes.
#
# It is an IDLE timer, not a regular one, on purpose: a regular timer firing
# every second keeps the editor from ever being idle for the metrics heap
# idle-timer's 10 s period, starving the very dynamic-usage samples the detector
# reads (measured: 2 samples over a 200 s run).  An idle timer fires DURING the
# idle rests alongside the metrics sampler (idle timers are serviced without
# leaving the idle loop), so the leak grows and the heap ring still samples it.
_soak_eval_form() {
  local marker="(lem:insert-string (lem:current-point) \"$E2E_READY_MARKER\")"
  if [ "$SOAK_INJECT_LEAK" = "1" ]; then
    printf '%s' "(progn (defparameter cl-user::*soak-leak* nil) (lem:start-timer (lem:make-idle-timer (lambda () (push (make-array $SOAK_LEAK_BYTES :element-type (quote (unsigned-byte 8)) :initial-element 1) cl-user::*soak-leak*))) $SOAK_LEAK_MS :repeat t) $marker)"
  else
    printf '%s' "(progn $marker)"
  fi
}

# --- external RSS sampler ---------------------------------------------------
# Sample VmRSS of the editor's pane process every SOAK_SAMPLE_INTERVAL seconds
# into CSV `t_seconds,rss_bytes'.  Runs as a detached subshell; PID kept so the
# main flow and the cleanup trap can stop it.
_soak_start_sampler() {
  local session="$1" csv="$2" pid
  pid="$(tmux -L "$LEM_SOCK" list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)"
  if [ -z "$pid" ]; then
    echo "soak: could not resolve pane pid for RSS sampling" >&2
    return 1
  fi
  printf 't_seconds,rss_bytes\n' > "$csv"
  (
    start="$(date +%s)"
    while kill -0 "$pid" 2>/dev/null; do
      now="$(date +%s)"; el=$(( now - start ))
      rss="$(awk '/^VmRSS:/{print $2*1024}' "/proc/$pid/status" 2>/dev/null || true)"
      [ -n "$rss" ] && printf '%s,%s\n' "$el" "$rss" >> "$csv"
      sleep "$SOAK_SAMPLE_INTERVAL"
    done
  ) &
  SOAK_SAMPLER_PID=$!
}

_soak_stop_sampler() {
  if [ -n "$SOAK_SAMPLER_PID" ]; then
    kill "$SOAK_SAMPLER_PID" 2>/dev/null || true
    wait "$SOAK_SAMPLER_PID" 2>/dev/null || true
    SOAK_SAMPLER_PID=""
  fi
}

# --- key-driven workload actions --------------------------------------------
_soak_key_n() {   # session key n
  local s="$1" k="$2" n="$3" i
  for i in $(seq 1 "$n"); do lem_keys "$s" "$k"; sleep "$SOAK_PACE"; done
}

# One active burst = key analogs of the PF-5 workload actions.
_soak_active_burst() {
  local s="$1"
  # page (big-file workload): next-page / previous-page
  _soak_key_n "$s" C-v 5
  _soak_key_n "$s" M-v 5
  # scroll (scroll workload): line down / up
  _soak_key_n "$s" Down 15
  _soak_key_n "$s" Up 10
  # isearch (isearch workload): open, type a common needle, step, abort
  lem_keys "$s" C-s; sleep "$SOAK_PACE"
  lem_type "$s" "the"; sleep 0.1
  lem_keys "$s" C-s; sleep "$SOAK_PACE"
  lem_keys "$s" C-s; sleep "$SOAK_PACE"
  lem_keys "$s" C-g; sleep "$SOAK_PACE"       # isearch-abort: back to origin
  # edits + undo (undo-storm workload): insert, delete, undo, redo
  lem_type "$s" "soak edit "; sleep "$SOAK_PACE"
  _soak_key_n "$s" Backspace 10
  lem_keys "$s" M-x; sleep 0.1; lem_type "$s" "undo"; sleep 0.1; lem_keys "$s" Enter; sleep 0.1
  lem_keys "$s" M-x; sleep 0.1; lem_type "$s" "redo"; sleep 0.1; lem_keys "$s" Enter; sleep 0.1
  # defensive: bail out of any lingering minibuffer prompt before the rest.
  lem_keys "$s" C-g; sleep "$SOAK_PACE"
}

# --- main -------------------------------------------------------------------
# e2e_soak_run: drive the soak, analyze, return the detector verdict code.
e2e_soak_run() {
  local session="soak"
  [ -n "$SOAK_OUT_DIR" ] || SOAK_OUT_DIR="$E2E_REPO_ROOT/bench/results"
  mkdir -p "$SOAK_OUT_DIR"
  local csv="$SOAK_OUT_DIR/${SOAK_TAG}.csv"
  local dump_copy="$SOAK_OUT_DIR/${SOAK_TAG}-metrics.json"
  local analysis="$SOAK_OUT_DIR/${SOAK_TAG}-analysis.txt"

  echo "== soak: ${LEM_SOAK_SECONDS}s, rest=${SOAK_REST_SECONDS}s, sample=${SOAK_SAMPLE_INTERVAL}s, inject-leak=${SOAK_INJECT_LEAK} ==" >&2

  # Reuse keystroke.sh's corpus generator for the 10 MB mixed-10m file.
  e2e_gen_corpora || return 2

  lem_start "$session" "$(_soak_eval_form)" "$E2E_BIGFILE"
  if ! lem_wait_for "$session" "$E2E_READY_MARKER" 30; then
    echo "soak: readiness sentinel never appeared" >&2
    lem_capture "$session" | head -12 >&2
    lem_stop "$session" || true
    return 2
  fi

  _soak_start_sampler "$session" "$csv" || { lem_stop "$session" || true; return 2; }

  local start deadline now i=0
  start="$(date +%s)"
  deadline=$(( start + LEM_SOAK_SECONDS ))
  while now="$(date +%s)"; [ "$now" -lt "$deadline" ]; do
    i=$(( i + 1 ))
    _soak_active_burst "$session"
    printf '    burst %d done, elapsed %ds / %ds\n' "$i" "$(( $(date +%s) - start ))" "$LEM_SOAK_SECONDS" >&2
    # Idle rest so the in-image heap idle-timer fires (> 10 s sample period),
    # but never overshoot the deadline by a whole rest.
    now="$(date +%s)"
    if [ "$now" -lt "$deadline" ]; then sleep "$SOAK_REST_SECONDS"; fi
  done

  _soak_stop_sampler

  if ! lem_stop "$session" 20; then
    echo "soak: editor did not exit cleanly -- no metrics dump" >&2
    return 2
  fi

  local json
  json="$(lem_metrics_json)"
  if [ -z "$json" ] || [ ! -s "$json" ]; then
    echo "soak: no metrics dump found under $LEM_HOME" >&2
    return 2
  fi
  cp "$json" "$dump_copy"

  echo "== analyzing soak (csv=$csv dump=$dump_copy) ==" >&2
  # No pipe: run to a file so the exit code is node's directly (a piped
  # `| tee' would mask it), then echo the report to stderr.
  local rc=0
  node "$E2E_DRIVER_DIR/analyze-soak.mjs" \
       --csv "$csv" --dump "$dump_copy" \
       --threshold-mb-min "$SOAK_THRESHOLD_MB_MIN" > "$analysis" 2>&1 || rc=$?
  cat "$analysis" >&2
  echo "    artifacts: $csv | $dump_copy | $analysis" >&2
  SOAK_ANALYSIS_FILE="$analysis"
  return "$rc"
}

# --- standalone entry -------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=./driver.sh
  source "$_here/driver.sh"
  # shellcheck source=./common.sh
  source "$_here/common.sh"
  # shellcheck source=./keystroke.sh   (for e2e_gen_corpora / E2E_BIGFILE)
  source "$_here/keystroke.sh"
  lem_e2e_init
  trap '_soak_stop_sampler; lem_e2e_cleanup' EXIT INT TERM
  rc=0
  e2e_soak_run || rc=$?
  exit "$rc"
fi
