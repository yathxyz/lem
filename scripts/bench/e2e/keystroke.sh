#!/usr/bin/env bash
# keystroke.sh -- T3 keystroke-to-paint scenarios (SPEC-PERF PF-7).
#
# Four scenarios per PF-7:
#   (a) plain      inserts into a small scratch buffer            budget p95 < 10ms
#   (b) bigfile    inserts into the 10 MB mixed-10m corpus file   budget p95 < 30ms
#   (c) longline   inserts into a 16 KB single line               budget p95 < 30ms
#   (d) scroll     next-line held down through the 10 MB file     budget p95 < 30ms
#
# The 16 KB single line is DEVIATED from PF-7's "200 KB line": a single text
# object >= ~24 000 chars stack-overflows redisplay (the P2 cliff -- see
# bench/README.md); 16 KB keeps a ~30% margin below it, matching the T2
# long-line workload's cap.
#
# Each scenario drives N>=100 keys ONE AT A TIME with a small inter-key sleep,
# because redisplay coalesces while the input queue is non-empty (interp.lisp:
# `(when (= 0 (event-queue-length)) ... (redraw-display))'): paced keys make
# each keystroke paint, so the keystroke (t4-t1) histogram gets ~one sample per
# key.  It then verifies the screen actually changed, exits cleanly so the
# metrics dump fires, and parses the dump for the PF-2 stage percentiles.
#
# The pipeline-wrapping proof (and the loud-FAIL condition PF-7 asks for) is the
# queue-wait sample count: every event the ncurses frontend wraps records one
# queue-wait sample on dequeue, so queue-wait_count >= N proves the wrapping is
# intact -- if it were broken the count would be ~0.  The wall-side numbers
# (single key -> poll capture until it changes, 20x) are TREND only.
#
# Runs standalone or is sourced by run-t3.sh (which owns the sandbox + $E2E_KV).

E2E_KEYS="${E2E_KEYS:-120}"           # keys driven per scenario (>= 100)
E2E_PACE="${E2E_PACE:-0.025}"         # inter-key sleep (s) so each key paints
E2E_WALL_SAMPLES="${E2E_WALL_SAMPLES:-20}"
E2E_BUDGET_PLAIN_MS="${E2E_BUDGET_PLAIN_MS:-10}"
E2E_BUDGET_PATH_MS="${E2E_BUDGET_PATH_MS:-30}"

E2E_READY_MARKER="E2E_READY_MARKER"
# For scratch (plain) scenario: fresh writable buffer + marker.
E2E_PLAIN_EVAL='(let ((b (lem:make-buffer "*e2e*"))) (lem:switch-to-buffer b) (lem:insert-string (lem:buffer-point b) "'"$E2E_READY_MARKER"'"))'
# For file scenarios: apply-args opens the file first, then this eval inserts a
# marker at point (top of the opened buffer) so readiness is detectable.
E2E_FILE_EVAL='(lem:insert-string (lem:current-point) "'"$E2E_READY_MARKER"'")'

# Generate the corpora this script needs INTO THE SANDBOX (reusing the committed
# deterministic generator), and derive the 16 KB single line.
e2e_gen_corpora() {
  E2E_CORPORA_DIR="$LEM_E2E_ROOT/corpora/"
  mkdir -p "$E2E_CORPORA_DIR"
  echo "== generating corpora into the sandbox ==" >&2
  LEM_BENCH_CORPUS_DIR="$E2E_CORPORA_DIR" \
    sbcl --noinform --no-sysinit --no-userinit --non-interactive \
      --load "$E2E_REPO_ROOT/.qlot/setup.lisp" \
      --load "$E2E_REPO_ROOT/bench/corpora/generate.lisp" \
      --eval '(progn (bench-ensure-corpus "mixed-10m") (bench-ensure-corpus "long-line-200k") (uiop:quit))' \
      >&2
  E2E_BIGFILE="$E2E_CORPORA_DIR/mixed-10m.txt"
  E2E_LONGLINE="$E2E_CORPORA_DIR/line-16k.txt"
  head -c 16384 "$E2E_CORPORA_DIR/long-line-200k.txt" > "$E2E_LONGLINE"
  [ -s "$E2E_BIGFILE" ] || { echo "corpus gen failed: $E2E_BIGFILE" >&2; return 1; }
  [ -s "$E2E_LONGLINE" ] || { echo "corpus gen failed: $E2E_LONGLINE" >&2; return 1; }
}

# Drive N keys, one at a time, paced.  $2=mode (literal|named), $3=key.
_e2e_drive() {
  local session="$1" mode="$2" key="$3" i
  for i in $(seq 1 "$E2E_KEYS"); do
    if [ "$mode" = "literal" ]; then
      lem_type "$session" "$key"
    else
      lem_keys "$session" "$key"
    fi
    sleep "$E2E_PACE"
  done
}

# Coarse wall keystroke-to-paint: baseline capture, send ONE key, poll capture
# until it differs, record elapsed ms.  Repeated E2E_WALL_SAMPLES times.  Echoes
# the ms samples (space separated).  TREND only -- never gates.
_e2e_wall_trend() {
  local session="$1" mode="$2" key="$3"
  local i base t0 now cur ms samples=()
  for i in $(seq 1 "$E2E_WALL_SAMPLES"); do
    base="$(lem_capture "$session")"
    t0="$(date +%s.%N)"
    if [ "$mode" = "literal" ]; then lem_type "$session" "$key"; else lem_keys "$session" "$key"; fi
    # poll up to ~1s for a paint
    while :; do
      cur="$(lem_capture "$session")"
      if [ "$cur" != "$base" ]; then break; fi
      now="$(date +%s.%N)"
      if node -e 'process.exit((Number(process.argv[2])-Number(process.argv[1]))>1?0:1)' "$t0" "$now"; then
        break   # gave up after 1s; record it anyway (coarse trend)
      fi
      sleep 0.005
    done
    now="$(date +%s.%N)"
    ms="$(node -e 'process.stdout.write(((Number(process.argv[2])-Number(process.argv[1]))*1000).toFixed(3))' "$t0" "$now")"
    samples+=("$ms")
  done
  printf '%s ' "${samples[@]}"
}

# Emit the in-image p50/p95 ENTRY lines for one pipeline stage (us -> ms).
_e2e_emit_stage() {
  local scn="$1" stage="$2" count="$3" p50_us="$4" p95_us="$5"
  local p50_ms p95_ms
  p50_ms="$(e2e_us_to_ms "$p50_us")"
  p95_ms="$(e2e_us_to_ms "$p95_us")"
  e2e_entry "$stage/$scn/p50-in-image" "ms" "$p50_ms" "$p50_ms" "$p50_ms" "$count"
  e2e_entry "$stage/$scn/p95-in-image" "ms" "$p95_ms" "$p95_ms" "$p95_ms" "$count"
}

# One full scenario.
#   $1 scn name  $2 budget_ms  $3 key-mode(literal|named)  $4 key
#   $5.. lem args: the eval form then optional file
_e2e_scenario() {
  local scn="$1" budget_ms="$2" mode="$3" key="$4"; shift 4
  local session="ks-$scn"
  echo "== keystroke scenario: $scn (drive ${E2E_KEYS} keys, mode=$mode key='$key') ==" >&2
  lem_start "$session" "$@"
  if ! lem_wait_for "$session" "$E2E_READY_MARKER" 20; then
    echo "$scn: readiness sentinel never appeared" >&2
    lem_capture "$session" | head -12 >&2
    lem_stop "$session" || true
    return 1
  fi
  local before after
  before="$(lem_capture "$session")"
  _e2e_drive "$session" "$mode" "$key"
  sleep 0.3
  after="$(lem_capture "$session")"
  if [ "$before" = "$after" ]; then
    echo "$scn: screen did NOT change after ${E2E_KEYS} keys (harness broken)" >&2
    lem_stop "$session" || true
    return 1
  fi
  echo "    screen changed: yes" >&2

  # Wall trend (coarse, TREND only) before exiting.
  local wall stats wmin wmed wp90 wp95
  wall="$(_e2e_wall_trend "$session" "$mode" "$key")"
  stats="$(printf '%s\n' $wall | e2e_stats)"
  read -r wmin wmed wp90 wp95 <<<"$stats"

  if ! lem_stop "$session"; then
    echo "$scn: editor did not exit cleanly -- no metrics dump" >&2
    return 1
  fi

  # Parse the just-written dump.
  local json
  json="$(lem_metrics_json)"
  if [ -z "$json" ] || [ ! -s "$json" ]; then
    echo "$scn: no metrics dump found under $LEM_HOME" >&2
    return 1
  fi
  local kv
  kv="$(node "$E2E_DRIVER_DIR/parse-metrics.js" "$json")"
  # shellcheck disable=SC2046
  eval "$kv"

  echo "    in-image: keystroke n=$keystroke_count p50=${keystroke_p50_us}us p95=${keystroke_p95_us}us | queue-wait n=$queuewait_count | command n=$command_count" >&2

  # Pipeline-wrapping proof (PF-7 loud FAIL): every wrapped event records a
  # queue-wait sample on dequeue, so its count must reach N.
  if node -e 'process.exit(Number(process.argv[1]) >= Number(process.argv[2]) ? 0 : 1)' \
        "$queuewait_count" "$E2E_KEYS"; then :; else
    echo "$scn: queue-wait sample count $queuewait_count < $E2E_KEYS -- ncurses pipeline wrapping is BROKEN" >&2
    return 1
  fi
  # Keystroke (end-to-end) needs enough paints for a meaningful p95.
  local floor=$(( E2E_KEYS / 2 ))
  if node -e 'process.exit(Number(process.argv[1]) >= Number(process.argv[2]) ? 0 : 1)' \
        "$keystroke_count" "$floor"; then :; else
    echo "$scn: keystroke paint count $keystroke_count < $floor (excessive coalescing / broken redisplay charging)" >&2
    return 1
  fi

  # ENTRY lines: in-image p50/p95 for each stage + sample count + wall trend.
  _e2e_emit_stage "$scn" "keystroke"  "$keystroke_count" "$keystroke_p50_us" "$keystroke_p95_us"
  _e2e_emit_stage "$scn" "queue-wait" "$queuewait_count" "$queuewait_p50_us" "$queuewait_p95_us"
  _e2e_emit_stage "$scn" "command"    "$command_count"   "$command_p50_us"   "$command_p95_us"
  _e2e_emit_stage "$scn" "redisplay"  "$redisplay_count" "$redisplay_p50_us" "$redisplay_p95_us"
  e2e_entry "keystroke/$scn/samples" "count" "$keystroke_count" "$keystroke_count" "$keystroke_count" "$keystroke_count"
  e2e_entry "keystroke/$scn/wall-p50" "ms" "$wmin" "$wmed" "$wp90" "$E2E_WALL_SAMPLES"
  e2e_entry "keystroke/$scn/wall-p95" "ms" "$wp95" "$wp95" "$wp95" "$E2E_WALL_SAMPLES"
  e2e_trend "keystroke/$scn/wall-p50" "ms" "$wmed"
  e2e_trend "keystroke/$scn/wall-p95" "ms" "$wp95"

  # Hard budget: in-image keystroke p95.
  local p95_ms
  p95_ms="$(e2e_us_to_ms "$keystroke_p95_us")"
  e2e_budget "keystroke/$scn/p95-in-image" "$p95_ms" "$budget_ms"
}

e2e_keystroke_run() {
  e2e_gen_corpora || return 1
  _e2e_scenario plain    "$E2E_BUDGET_PLAIN_MS" literal "a"    "$E2E_PLAIN_EVAL" || return 1
  _e2e_scenario bigfile  "$E2E_BUDGET_PATH_MS"  literal "a"    "$E2E_FILE_EVAL" "$E2E_BIGFILE" || return 1
  _e2e_scenario longline "$E2E_BUDGET_PATH_MS"  literal "a"    "$E2E_FILE_EVAL" "$E2E_LONGLINE" || return 1
  _e2e_scenario scroll   "$E2E_BUDGET_PATH_MS"  named   "Down" "$E2E_FILE_EVAL" "$E2E_BIGFILE" || return 1
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
  e2e_keystroke_run
  echo "--- results ---"
  cat "$E2E_KV"
  if grep -q $'\tFAIL$' "$E2E_KV"; then exit 1; fi
fi
