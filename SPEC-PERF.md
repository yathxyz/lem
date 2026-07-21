# Lem Performance Observatory — End-to-End Optimization Spec

**Baseline:** `yathxyz/lem` main @ `305c3ddb` (2026-07-18), i.e. after SPEC-VK landed in
full (12 certified books, four one-source kernel swaps live).
**Scope policy:** bare Lem only — everything in this spec lives in this repository and
measures the unconfigured ncurses build. The `lem-yath` configuration repo keeps its
own behavior harness and is out of scope here.
**API policy (hard constraint):** unchanged from SPEC-VK — `lem-core` / `lem` exported
symbols and behavior stay frozen. Optimizations happen beneath the API; instrumentation
is purely additive.

## Goal

Build a **measurement-first optimization framework**: know, with numbers, how the
editor performs end-to-end — from tty byte to painted cell, in real daily-driver
sessions and in reproducible synthetic workloads — and then run a gated optimization
loop where every change is (a) motivated by measured data, (b) provably
behavior-preserving via the existing conformance suites and proofs, and (c) committed
with before/after numbers in a ledger.

Four measurement tiers, cheapest-to-run first:

- **T0 — field telemetry (always on):** the daily-driven image records what real
  sessions actually spend time on. This is the ground truth that ranks hotspots;
  synthetic tiers exist to reproduce and regress what T0 reveals.
- **T1 — micro benchmarks (in-image):** per-primitive µs/op and bytes-consed/op.
- **T2 — macro session replay (headless, deterministic):** scripted realistic
  workloads against the recording fake-interface; tight thresholds; per-workload
  sb-sprof profiles.
- **T3 — end-to-end (real ncurses under tmux):** startup, keystroke-to-paint
  latency, soak memory. Noisy by nature; tracked as trends, not hard gates.

**What "optimized" means here.** A change counts as an optimization only if it improves
a target metric beyond the recorded noise band *and* regresses no other gated metric
beyond its noise band *and* leaves every rove suite and ACL2 book green. Synthetic wins
that do not eventually move T0 field histograms are recorded as such in the ledger —
the field data is the arbiter, not the benchmark.

## Non-goals

- Measuring or optimizing SDL2/webview frontends, or any configured (`lem-yath`) image.
- Perf gating on shared CI runners. Baselines are per-machine; the bench gate is a
  local pre-commit discipline exactly like `run-proofs.sh`.
- Networked/telemetry-phone-home anything. T0 data is local files only.
- Micro-optimizing verified kernel books speculatively. Kernel code may be optimized
  when data demands it, but the one-source rule holds: the changed book must recertify
  and the conformance suites must stay green.
- Startup-time heroics that trade away image robustness (e.g. dumping fragile
  save-lisp-and-die tricks) — startup is measured and tracked, optimized only with
  boring means.

## Constraints

1. **Measure before touching.** No optimization item may be opened without a T0 or T2
   measurement identifying the hotspot and a stated hypothesis. "This looks slow" is
   not a work item.
2. **Behavior-preservation is checkable, not asserted.** Every optimization runs the
   full gates: `scripts/run-tests.sh` (all suites incl. kernel conformance PBT),
   `scripts/run-proofs.sh` if anything under `verified/` changed, and the editor
   builds (`make ncurses`). The kernel conformance suites are the fence that makes
   aggressive optimization safe.
3. **Never commit slower.** `scripts/run-bench.sh` compares against the committed
   baseline; a gated-tier regression beyond the noise band blocks commit like a red
   test. Deliberate trade-offs (e.g. memory for speed) are permitted only with a
   ledger entry stating the trade.
4. **Instrumentation must not be the perturbation.** T0 sampling is allocation-free on
   the hot path (preallocated ring buffers / bucket counters), with a measured
   overhead budget: < 1 µs and 0 bytes consed per recorded event. The overhead is
   itself benchmarked (T1) before T0 ships.
5. **Baselines are honest.** Results carry a machine fingerprint (hostname + CPU model
   + core count); comparisons only ever run against a matching fingerprint. Median of
   ≥ 5 in-process repetitions, `gc :full` before each timed section, first repetition
   discarded as warmup; report min/median/p90.
6. Spec documents (SPEC.md, SPEC-VK.md, SPEC-PERF.md) are requirements, not scratch
   space — implementers do not edit them to match what was built; deviations are
   recorded in `bench/README.md` (the perf ledger, mirroring `verified/README.md`).
7. **The user's running Lem instances are never touched.** All T3 runs use fresh,
   uniquely-named tmux sockets/sessions and kill only what they created.

---

## Milestone P0 — Measurement substrate

### PF-1: T0 telemetry core (`src/metrics.lisp`)

Additive module, compiled into every build (no feature flag — it is always on, per
decision; the off-switch is an editor variable defaulting to on).

- **Latency histograms:** log2-bucketed counters (1 µs … 16 s, ~24 buckets, fixed
  vectors) for: input-event → redisplay-complete (the keystroke-to-paint proxy),
  per-command-dispatch duration keyed by command name (bounded table, overflow bucket),
  and redisplay pass duration.
- **GC log:** via `sb-ext:*after-gc-hooks*` — per-GC pause estimate
  (`sb-ext:*gc-run-time*` delta), generation, bytes freed; ring buffer of the last
  4096 GCs plus a pause histogram.
- **Heap/RSS samples:** every N seconds (idle-timer), `sb-kernel:dynamic-usage` and
  `VmRSS` from `/proc/self/status`; ring buffer sized for ~24 h at the sample rate.
- **Dump:** JSON to `(lem-home)/metrics/<start-timestamp>.json` on `exit-lem` and on
  demand via a `metrics-dump` command; `metrics-report` renders a human summary
  (p50/p95/p99 latencies, worst commands, GC pause distribution, heap trend) in a
  buffer.

**Done when:** the daily-driver build records and dumps; a T1 benchmark shows the
per-event overhead within the Constraint-4 budget; unit tests cover histogram math and
dump/restore round-trip.

### PF-2: Pipeline timestamps

Five timestamps threaded through the input→paint pipeline, so end-to-end latency
decomposes into attributable stages:

| Stage | Point in code |
|-------|---------------|
| t₀ input arrives | frontend input thread: tty byte(s) read (ncurses), key RPC received (lem-server/webview), or SDL key event dequeued (sdl2) |
| t₁ event enqueued | `send-event` into the editor queue |
| t₂ event dequeued | main loop picks it up |
| t₃ command done | command dispatch returns |
| t₄ redisplay done | `update-display` returns |

Recorded per-event into T0 histograms (queue-wait = t₂−t₁, command = t₃−t₂,
redisplay = t₄−t₃). Timestamps use a monotonic clock; the carrying mechanism must not
change any `lem-core` API (attach to the event object or a thread-local; frontends
that never pass a t₀ are simply unaffected).

**Done when:** `metrics-report` shows the stage decomposition for a live session;
conformance: total ≈ sum of stages within measurement error on a scripted run.

### PF-3: Bench runner, result schema, baselines

- `scripts/run-bench.sh [t1|t2|t3|all]` — builds/loads what it needs, runs the tier,
  writes `bench/results/<fingerprint>-<tier>-<timestamp>.json`, compares against
  `bench/baselines/<fingerprint>-<tier>.json`, prints a delta table, exits nonzero on
  gated regression (T1/T2 only).
- Result schema: `{fingerprint, tier, commit, timestamp, entries: [{name, unit,
  min, median, p90, consed-per-op, n}]}`. One schema for all tiers.
- Noise bands measured empirically per entry (run the suite 5× at baseline creation;
  band = max observed spread, floor 5%); stored in the baseline file. Regression =
  median worse than baseline median by more than the band.
- `scripts/run-bench.sh --rebaseline <tier>` regenerates after an accepted change;
  rebaselining requires a ledger entry (Constraint 6).

**Done when:** a synthetic regression (sleep injected into a bench entry) is caught
with nonzero exit; rebaseline flow works; `bench/README.md` exists with the ledger
format.

---

## Milestone P1 — T1 micro suite

### PF-4: `scripts/bench/` micro benchmarks

Grow `scripts/bench-edit.lisp` (kept, moved to `scripts/bench/edit.lisp`) into a
suite, each file self-contained, each entry reporting µs/op **and** bytes-consed/op:

| Entry | What it measures |
|-------|------------------|
| edit | insert/delete/newline, normal + 200 KB line, points registered (existing) |
| width | `string-width` over ASCII / CJK / emoji / mixed corpora (kernel-backed path) |
| search | forward/backward search, regex and literal, large buffer |
| syntax | syntax-scan over a large Lisp file (tmlanguage path) |
| redisplay | full redisplay compute of a 200×50 frame via the recording fake-interface, plain + long-line + many-overlay buffers |
| points | marker relocation with 10/100/1000 registered points per edit |
| telemetry | PF-1 record path (proves Constraint-4 budget, permanently) |

All entries run in the `:release` edit-engine mode by default; the edit entry
additionally runs `:paranoid` so the paranoid tax is a tracked number (this is the
datum for the soak decision on when to drop `LEM_PARANOID=1`).

**Done when:** `scripts/run-bench.sh t1` is green against a fresh baseline; each entry
is deterministic (fixed seeds, fixed corpora committed under `bench/corpora/`).

---

## Milestone P2 — T2 macro session replay

### PF-5: Deterministic workload scripts

Headless image + recording fake-interface (from VK-12), fixed 200×50 frame, fixed
seeds. Each workload is a scripted editing session measuring wall time, bytes consed,
GC count + pause total (from PF-1 counters), and frames rendered:

| Workload | Session |
|----------|---------|
| big-file | open committed 10 MB file, page through end-to-end, jump top/bottom |
| isearch | incremental search with common/rare/absent needles over the big file |
| undo-storm | 5k mixed edits, full undo, full redo |
| overlay-heavy | editing with thousands of overlays/points registered |
| long-line | 200 KB single line: cursor motion, edits, wrap on/off |
| lisp-edit | open large `.lisp` file, syntax scan, indent-heavy editing, paredit-style structural edits |
| scroll | sustained line-scroll and page-scroll throughput over styled text |

Corpora are committed (or generated deterministically by a committed script) under
`bench/corpora/`. Workloads use only frozen public API + existing internals — a
workload is also an API-stability canary.

**Done when:** `scripts/run-bench.sh t2` runs all workloads reproducibly (spread
within the noise floor across 5 consecutive runs) and gates against baseline.

### PF-6: Profiler integration

`scripts/run-bench.sh t2 --profile <workload>` runs the workload under `sb-sprof`
(reusing the `src/commands/sprof.lisp` infrastructure where sensible) and writes a
flat + graph report to `bench/profiles/`. Every optimization item (P5) attaches the
before-profile that motivated it.

**Done when:** a profile of `big-file` clearly attributes ≥ 90% of samples to named
frames (i.e. the image is built with enough debug info for useful profiles).

---

## Milestone P3 — T3 end-to-end harness

### PF-7: Startup and keystroke-to-paint (`scripts/bench/e2e/`)

A repo-local tmux driver (self-contained; pattern borrowed from lem-yath's
`tui-driver.sh` but no dependency on that repo): fresh socket per run, 200×50 pane,
Constraint 7 enforced structurally.

- **Startup:** time from `exec` of `./lem` to editor-ready (ready = a sentinel drawn
  via `--eval` appearing in `capture-pane`); cold (first run) and warm (repeat)
  recorded separately.
- **Keystroke-to-paint:** the driver sends single keys and polls `capture-pane` at
  high frequency for the resulting change; wall numbers are coarse (~5–10 ms
  resolution) and recorded as trends. The *precise* number comes from cross-checking
  PF-2: the same session's metrics dump decomposes t₀…t₄, and the driver asserts the
  in-image p95 for the scripted keys is within budget. Scenarios: plain insert in a
  small buffer, insert into the 10 MB file, insert into the 200 KB line, scroll held
  down.
- **Budgets (initial, revisable with ledger entry):** in-image keystroke p95 < 10 ms
  on plain buffers, < 30 ms on pathological buffers; startup < 2 s warm.

**Done when:** `scripts/run-bench.sh t3` produces the trend file and prints
budget-vs-actual; budget violations warn loudly but only the in-image (PF-2-derived)
numbers ever hard-fail.

### PF-8: Soak and leak detection

Scripted 30-minute editing loop (cycling the PF-5 workload actions against the real
binary in tmux), sampling RSS and `dynamic-usage` every 10 s via the metrics
idle-timer. Post-processing flags monotonic heap growth (linear fit over the second
half of the run above a threshold) as a leak suspect.

**Done when:** one full soak run is recorded and analyzed in the ledger; the leak
detector catches a deliberately-injected leak (test of the detector itself).

---

## Milestone P4 — Grounding report

### PF-9: First baseline ledger + hotspot ranking

With P0–P3 landed: run everything, and daily-drive the instrumented build for at
least a week. Then write the first **grounding report** in `bench/README.md`:

- Full T1/T2/T3 baseline tables for the primary machine fingerprint.
- T0 field summary: real-session latency percentiles, stage decomposition, worst
  commands, GC pause profile, paranoid-mode tax as actually experienced.
- sb-sprof hotspot ranking from the T2 workloads, reconciled against T0 (a hotspot
  that only exists synthetically is marked as such).
- The ranked optimization backlog: OPT-1, OPT-2, … each with the measurement that
  motivates it and a hypothesis.

**Done when:** the report exists and the backlog is ranked by measured impact, not
intuition. This milestone is the point of the whole spec — P5 must not start early.

---

## Milestone P5 — The optimization loop (ongoing)

### PF-10: Loop protocol

Each backlog item OPT-n proceeds:

1. **Evidence:** the motivating T0/T2 measurement + profile, restated in the item.
2. **Hypothesis:** what change, why it should help, expected magnitude.
3. **Change:** beneath the frozen API. If it touches `verified/`, books recertify
   (one-source rule); if it touches shell code pinned by conformance suites, those
   suites are the proof of behavior-preservation.
4. **Gates:** `run-tests.sh` + (if applicable) `run-proofs.sh` + `run-bench.sh t1 t2`
   green vs. baseline, target metric improved beyond its noise band.
5. **Review:** adversarial review (the SPEC-VK workflow pattern) with explicit
   attention to behavior drift and to benchmark-overfitting.
6. **Ledger + commit:** one commit per OPT item, before/after numbers in
   `bench/README.md`, rebaseline.
7. Periodically (per few OPT items): a fresh T0 field dump confirms the win is felt
   in real sessions; if not, the ledger says so.

**Done when:** the protocol is exercised end-to-end on OPT-1. The backlog itself is
open-ended; the spec is satisfied once the framework and protocol are proven live,
not when some arbitrary number of optimizations has landed.

---

## Sequencing

P0 → P1 → P2 → P3 → P4 → P5. P1–P3 have no interdependencies beyond P0 and may be
reordered if convenient, but P4 (grounding report) requires all tiers plus ≥ 1 week of
T0 field data, and P5 requires P4. The paranoid→release soak decision (from SPEC-VK)
becomes data-driven at P4 via the measured paranoid tax and field latency histograms.

## Standing risks

- **Observer effect:** T0 instrumentation on the hot path. Mitigated by Constraint 4
  (budgeted, permanently benchmarked by the T1 `telemetry` entry).
- **Noise → false gates:** timer/GC jitter causing flaky bench failures. Mitigated by
  empirical per-entry noise bands, median-of-k, and keeping T3 wall numbers ungated.
- **Goodhart:** optimizing benchmarks instead of the editor. Mitigated by T0-as-arbiter
  (PF-10 step 7) and reviewer attention in PF-10 step 5.
- **Baseline rot:** hardware/OS/SBCL upgrades invalidate baselines. Fingerprints
  detect the hardware part; SBCL version is recorded in results; rebaseline with a
  ledger entry when the platform moves.
- **Histogram lies:** log2 buckets and p99-from-buckets have bounded but real error;
  acceptable for ranking, noted in `metrics-report` output.
- **tmux timing resolution** (~5–10 ms) makes T3 wall numbers coarse forever; the
  design accepts this and anchors precision on PF-2 in-image timestamps instead.
