# Lem Performance Ledger

This is the perf ledger for SPEC-PERF — the analogue of `verified/README.md` for
the verified kernel. It records baselines, rebaselines, and every optimization
(OPT-n) with before/after numbers. The field data (T0) is the arbiter; synthetic
wins that do not move the T0 histograms are recorded as such.

## Layout

```
bench/
├── README.md      # this ledger
├── baselines/     # committed, per-machine baselines (<fingerprint>-<tier>.json)
├── results/       # gitignored: per-run result JSON
├── profiles/      # gitignored: sb-sprof flat/graph reports (PF-6)
└── corpora/       # committed fixed corpora / deterministic generators (PF-4/5)
```

## Running

```bash
scripts/run-bench.sh t1                 # measure + gate against baseline
scripts/run-bench.sh --rebaseline t1    # regenerate the baseline (needs a ledger entry)
scripts/run-bench.sh t2 --profile <workload>  # sb-sprof one T2 workload (PF-6)
scripts/bench/self-test.sh              # prove the gate catches a regression
scripts/run-bench.sh t3                 # T3 end-to-end (startup + keystroke); fast, no soak
LEM_T3_SOAK=1 scripts/run-bench.sh t3   # ...plus the optional 30-min soak + leak check (PF-8)
scripts/bench/e2e/soak-self-test.sh     # prove the leak detector catches an injected leak (PF-8)
```

Baselines are per-machine. Every result carries a fingerprint (hostname + CPU
model + core count) and comparisons only run against a matching fingerprint
(Constraint 5). Measurement is median of five in-process repetitions with a full
GC before each timed section and the first repetition discarded (Constraint 5).
A gated-tier regression beyond the per-entry noise band blocks commit like a red
test (Constraint 3).

## Result schema (`lem-bench`, one schema for all tiers)

```json
{
  "fingerprint": "host | cpu model | Nc",
  "tier": "t1",
  "commit": "<git rev>",
  "timestamp": "YYYYMMDDHHMMSS",
  "entries": [
    {"name": "telemetry", "unit": "us/op",
     "min": 0.0, "median": 0.0, "p90": 0.0,
     "consed-per-op": 0, "n": 50000000}
  ]
}
```

Baseline files additionally carry a per-entry `"band"` (noise band as a
fraction; measured as the spread of medians over five suite runs at baseline
creation, floored at 5%). Regression = current median worse than baseline median
by more than the band — **except for budget-gated entries** (see Deviations),
whose gate is a hard budget rather than the band comparison.

## T1 suite structure (PF-4)

`scripts/bench/run-t1.lisp` is the tier **harness** only: measurement
primitives, a multi-entry registry, the noise-band gate, and the JSON schema.
Entries live one per file next to it and register via `register-bench-entry`;
the driver discovers and loads every sibling `*.lisp` that is not a `run-*.lisp`
driver. Corpora come from `bench/corpora/generate.lisp` (below).

- `telemetry.lisp` — the PF-1 record path (budget-gated canary).
- `edit.lisp` — edit latency (was `scripts/bench-edit.lisp`, now deleted; see
  Deviations).
- `points.lisp` — marker relocation vs. registered-point count.
- `width.lisp` — `string-width` over ASCII / CJK / emoji / mixed corpora.
- `search.lisp` — forward/backward, literal/regexp search over the large buffer.
- `syntax.lisp` — tmlanguage syntax scan over `lisp-500k` (real lisp-mode grammar).
- `redisplay.lisp` — full redisplay compute of a 200×50 frame through the
  recording fake-interface (plain / long-line / many-overlay).

Each entry rebuilds a fresh fixture per timed section (`:setup`), sizes its own
iteration count for a ≥ 10 ms window, and reports µs/op **and** bytes-consed/op.

## Corpora (`bench/corpora/`)

`generate.lisp` (committed) produces every corpus deterministically (fixed
SplitMix64 seeds, fixed inputs) into `bench/corpora/cache/` (gitignored) at
bench time — the blobs are **not** committed. Regeneration is byte-identical.

| Corpus | Content |
|--------|---------|
| `lisp-500k` | ~500 KB syntactically-valid Common Lisp — a deterministic concatenation of whole repo source files, **read at the pinned commit `5cd018a9` via `git show` (not the working tree)** so the corpus does not drift when P5 optimizes those files (see Deviations) |
| `unicode-mixed` | ~100 KB of mixed ASCII / CJK / emoji / combining-mark text |
| `long-line-200k` | one 200 000-char line (the PI-1 corpus the edit/points benches stress) |
| `mixed-10m` | ~10 MB realistic multi-line prose+code mix, mixed line lengths, some unicode (the T2 big-file workload corpus, PF-5) |

`lisp-500k` and `unicode-mixed` are the corpora for the width/syntax entries;
`mixed-10m` (P2) is the big-file workload corpus. All four are regenerated (and
thus validated) on every bench run. The bench image loads `:lem/core` only, so
`generate.lisp` reproduces SplitMix64 locally rather than depending on
`tests/pbt/harness.lisp`. The `lisp-500k` cache filename carries the pin commit
(`lisp-500k-5cd018a9.lisp`), so bumping the pin invalidates the cache
automatically.

## T1 entries

| Entry | What it measures | Gate |
|-------|------------------|------|
| telemetry | PF-1 record path (`histogram-record`, inline hot-path primitive) | **Budget-gated:** < 1 µs/op and 0 bytes consed/op (Constraint 4, permanent). Exempt from the median-band regression gate — see Deviations. |
| edit/`{normal,longline}`/`{insert-delete,newline}`/`{release,paranoid}` | edit latency: a keystroke round-trip (insert+delete) and a split+join, on a 2000×60 buffer and the 200 KB line, in both edit-engine modes | median-band |
| points/`{10,100,1000}` | marker relocation with N registered points on the edited line | median-band |
| width/`{ascii,cjk,emoji,mixed}` | `lem:string-width` (kernel-backed) over a 4000-char class string (ascii/cjk/emoji) or the `unicode-mixed` corpus | median-band |
| search/`{forward,backward}`-`{literal,regexp}` | frozen `search-*` over the `lisp-500k` buffer, absent needle (full sweep) | median-band |
| syntax/lisp-500k | `syntax-scan-region` over `lisp-500k` with the real lisp-mode tmlanguage grammar | median-band |
| redisplay/`{plain,long-line,many-overlay}` | force full redisplay compute of a 200×50 frame through the recording fake-interface | median-band |

**Paranoid tax** (`:paranoid` median ÷ `:release` median, from the current
baseline) — the SPEC-VK soak-decision datum: normal buffer ~1.2×
(insert-delete 27.3/22.8, newline 28.5/23.6); 200 KB line ~13–16×
(insert-delete 17000/1067, newline 15000/1167). Consistent with the VK-4
acceptance table (the certified region `wf-buffer` walks the line's codepoints
per edit, so the tax scales with line length).

All seven PF-4 entry families now exist (telemetry, edit, points, width, search,
syntax, redisplay); Milestone P1 is complete.

### P1 baseline numbers (ex44 / i5-13500 / 20c, commit `07253058`)

Committed baseline medians (`bench/baselines/ex44-…-t1.json`). Every entry
reports µs/op **and** bytes-consed/op over `n` ops per timed section; band 20%
for all (budget-gated for `telemetry`, see Deviations).

| Entry | median µs/op | consed B/op | n |
|-------|-------------:|------------:|--:|
| `edit/normal/insert-delete/release` | 22.8 | 3015 | 2500 |
| `edit/normal/newline/release` | 23.6 | 3134 | 2500 |
| `edit/longline/insert-delete/release` | 1066.7 | 3269421 | 30 |
| `edit/longline/newline/release` | 1166.7 | 3702513 | 30 |
| `edit/normal/insert-delete/paranoid` | 27.3 | 5732 | 1500 |
| `edit/normal/newline/paranoid` | 28.5 | 5996 | 2000 |
| `edit/longline/insert-delete/paranoid` | 17000.0 | 9671824 | 2 |
| `edit/longline/newline/paranoid` | 15000.0 | 10104608 | 2 |
| `points/10` | 24.0 | 5046 | 2500 |
| `points/100` | 40.0 | 30228 | 1200 |
| `points/1000` | 204.0 | 289406 | 250 |
| `width/ascii` | 122.2 | 0 | 180 |
| `width/cjk` | 105.6 | 0 | 180 |
| `width/emoji` | 111.1 | 0 | 180 |
| `width/mixed` | 1666.7 | 0 | 12 |
| `search/forward-literal` | 11500.0 | 7684096 | 2 |
| `search/backward-literal` | 13000.0 | 8929280 | 2 |
| `search/forward-regexp` | 7666.7 | 0 | 3 |
| `search/backward-regexp` | 8000.0 | 0 | 3 |
| `syntax/lisp-500k` | 116000.0 | 16416768 | 1 |
| `redisplay/plain` | 457.1 | 112347 | 35 |
| `redisplay/long-line` | 7000.0 | 2071200 | 4 |
| `redisplay/many-overlay` | 4750.0 | 1736704 | 4 |
| `telemetry` | 0.00102 | 0 | 50000000 |

## T2 suite structure (PF-5)

`scripts/bench/run-t2.lisp` is the T2 **harness**: the 200×50 recording
fake-interface, a self-registering workload registry, the median-of-three
measurement, the JSON schema, and the 20% noise-band gate. It reuses the P1
harness *patterns* (registry, `sorted-stat`, the PF-3 schema, interleaving, the
band floor) adapted to whole-session workloads. Workloads live one-per-file
under `scripts/bench/t2/` (a subdirectory, so the T1 driver's sibling-`*.lisp`
discovery never loads them) and register via `register-t2-workload`.

Each workload is a scripted editing session driven through **frozen public API**
(an API-stability canary): commands (`next-page`, `scroll-down`, `find-file-
buffer`, `move-to-*`, `insert-character`, …) against a genuine current 200×50
window, forcing a full redisplay per rendered step via `redraw-display :force
t`. Per workload we report **wall ms** (gated, min/median/p90), **bytes
consed**, **GC count**, **GC pause total (ms)**, and **frames rendered** (the
recording interface's `update-display` `:after` frame counter).

| Workload | Session |
|----------|---------|
| big-file | open the 10 MB `mixed-10m` corpus via `find-file-buffer`, page through end-to-end (`next-page` until `end-of-buffer`), jump bottom/top |
| isearch | 10 MB `mixed-10m` buffer, incremental search with common (`"the"`, ~34.7k hits), rare (`"attribute cache"`, ~213 hits), and absent needles — per-keystroke highlight via the real `lem/isearch::isearch-update-buffer`, then match stepping via `search-forward` (see Deviations for the headless-isearch note) |
| undo-storm | seeded buffer, 5000 mixed edits (`insert`/`delete`/`newline` at moving positions, one undo group each), full `buffer-undo` to start, full `buffer-redo`; a correctness canary (undo/redo round-trips losslessly) is asserted once in setup, outside every timed window |
| overlay-heavy | `lisp-500k` buffer with 2000 registered overlays (single- and multi-line via `make-overlay`), 500 net-zero edits interleaved with the overlay boundaries, full redisplay every 10 edits |
| long-line | 16 KB single line: `character-offset` cursor sweeps, beginning/end-of-line, net-zero edits at 8 positions, wrap-off and wrap-on render passes (×2) |
| lisp-edit | syntax-scanned `lisp-500k` (lem-lisp-syntax syntax table + lem-lisp-mode tmlanguage), `forward-sexp`/`backward-sexp` motion sweeps, `newline-and-indent` at nesting points (lem-core `calc-indent-default`) with per-edit region re-scan |
| scroll | syntax-scanned `lisp-500k` buffer (real lisp-mode tmlanguage), sustained line-scroll (`scroll-down` ×1500) then page-scroll (`next-page` ×150) over styled text |

**Measurement (per the task spec):** median of **three** full executions per
workload per suite run, `gc :full` before each, **one** warm-up pass discarded,
timed passes **interleaved** round-robin across workloads (a transient lands on
≤ 1 rep per workload). Unlike T1, T2 does **not** suppress GC in the timed
window — GC count and pause total are reported session metrics. The rebaseline
folds five suite runs; the band is the spread of the five suite medians, floored
at 20% (as T1 — see Deviations).

### P2 T2 baseline numbers (ex44 / i5-13500 / 20c, commit `5cd018a9`)

Committed baseline medians (`bench/baselines/ex44-…-t2.json`); wall unit is
ms/workload, band 20% for all. `consed`, `gc`, and `frames` are the per-workload
medians; `frames` is deterministic (identical every run). The seven-workload
table below supersedes the initial three-workload baseline (see the ledger
rebaseline row that added `isearch`, `undo-storm`, `overlay-heavy`, `lisp-edit`;
the pre-existing three shift slightly under seven-way interleaving).

| Workload | median ms | consed B | GC count | GC pause ms | frames |
|----------|----------:|---------:|---------:|------------:|-------:|
| `big-file` | 4234 | 718 801 280 | 4 | ~33 | 4976 |
| `isearch` | 2201 | 437 387 136 | 3 | ~41 | 496 |
| `scroll` | 1075 | 322 662 272 | 2 | ~7 | 1652 |
| `overlay-heavy` | 520 | 175 174 144 | 1 | ~0 | 51 |
| `long-line` | 488 | 121 617 184 | 1 | ~0 | 172 |
| `lisp-edit` | 299 | 36 621 696 | 1 | ~0 | 72 |
| `undo-storm` | 266 | 24 322 688 | 1 | ~0 | 4 |

(Absolute ms track machine load at baseline creation; the gate compares against
the committed median within the 20% band on a matching fingerprint, so a
per-machine rebaseline is the honest reset when the platform or its steady-state
load moves — Constraint 5.)

## T2 profiler (PF-6)

```bash
scripts/run-bench.sh t2 --profile <workload>
```

Runs ONE named workload under `sb-sprof` (`:cpu` mode) instead of
measuring/gating, writes a flat + call-graph report to
`bench/profiles/<workload>-<timestamp>.txt` (gitignored), and prints the top-15
flat frames to stdout. The sample interval is 1000 Hz and the workload is
replayed until ≥ 2.5 s of wall time has elapsed, so even the shortest workload
clears the PF-6 ≥ 1000-sample bar with margin (a fast workload just replays more
times). Every P5 optimization item (OPT-n) attaches the before-profile that
motivated it (PF-6 / PF-10).

**PF-6 done-when (profile attributes ≥ 90 % of samples to named frames).**
Verified on `big-file`: 4153 samples, only **0.6 % "elsewhere"** (foreign /
unattributed) — i.e. **> 99 %** of samples land in named Lisp frames, so the
`:lem/core` image ships enough debug info for useful profiles with **no**
bench-image debug-policy change needed. The `big-file` hotspots are the
`string-width` kernel path (`ACL2::K-CHAR-WIDTH`, `icon-code-p`, `wide-index`,
`ACL2::K-SUM`, …) driving full-frame redisplay over the 10 MB buffer — recorded
here as the first data point for the P4 hotspot ranking, not acted on (P5 must
not start before the P4 grounding report).

## T3 suite structure (PF-7)

`scripts/bench/e2e/` is the end-to-end tmux harness — the real ncurses `./lem`
binary driven from outside, no in-image bench code (the frozen API is exercised
exactly as a user's terminal would). Files:

- `driver.sh` — sourceable tmux driver. **Constraint 7 is structural:** every
  run uses a UNIQUE PRIVATE socket (`tmux -L lem-e2e-$$-$RANDOM$RANDOM`), never
  the default server; the editor runs with `HOME`/`XDG_*`/`LEM_HOME` redirected
  into an `mktemp` sandbox so it reads/writes nothing of the user's real config;
  the cleanup trap (EXIT/INT/TERM) kills only that private-socket server, removes
  only its own socket file, and deletes only its own sandbox. Primitives:
  `lem_start` (launch `./lem` in a 200×50 pane via a generated `printf %q`
  launcher, so the `--eval` form's parens/quotes never fight tmux), `lem_keys`,
  `lem_type`, `lem_capture`, `lem_wait_for`, `lem_stop`, `lem_metrics_json`.
- `common.sh` — result emission (`ENTRY`/`BUDGET`/`TREND` TSV lines) + stats.
- `startup.sh` — startup-to-ready: time from `exec` to a `--eval`-drawn sentinel
  in `capture-pane`. Cold = first run of the batch; warm = median of 5.
- `keystroke.sh` — the four PF-7 scenarios (below), corpora generated into the
  sandbox by reusing `bench/corpora/generate.lisp`.
- `parse-metrics.js` — extracts the PF-2 stage percentiles from the exit dump
  (node; jq is unavailable). Reads the per-stage histograms directly and merges
  the per-command histograms with the same log2 upper-edge estimator
  `histogram-percentile` uses.
- `run-t3.sh` — orchestrator invoked by `scripts/run-bench.sh t3`: one sandbox,
  runs startup + keystroke, writes the PF-3-schema JSON to `bench/results/`
  (gitignored), prints the budget table, exits nonzero ONLY on a hard-budget
  violation or a harness failure.

| Scenario | Session | Hard budget |
|----------|---------|-------------|
| plain | 120 paced inserts into a fresh scratch buffer | in-image keystroke p95 < 10 ms |
| bigfile | 120 paced inserts into the 10 MB `mixed-10m` corpus file | < 30 ms |
| longline | 120 paced inserts into a **16 KB** single line | < 30 ms |
| scroll | 120 paced `next-line` (Down) through the 10 MB file | < 30 ms |

Keys are driven **one at a time** (~25 ms apart), because redisplay coalesces
while the input queue is non-empty (`interp.lisp`: `(when (= 0
(event-queue-length)) (redraw-display))`) — pacing makes each keystroke paint,
so the keystroke (t₄−t₁) histogram gets ~one sample per key. Each scenario
verifies the screen actually changed, exits cleanly (`C-x C-c`, then `y` for a
file-backed modified buffer) so the metrics dump fires, and cross-checks the
PF-2 dump. The **pipeline-wrapping proof** (the loud-FAIL condition PF-7 asks
for) is the **queue-wait sample count**: every event the ncurses frontend wraps
records one queue-wait sample on dequeue, so `queue-wait_count >= N` proves the
wrapping is intact (a broken wrap reads ~0). Wall numbers (single key → poll
`capture-pane` until it changes, 20×) are TREND-only and never gate.

**T3 keeps NO committed baseline** — a noisy wall tier has no band gate, so
`--rebaseline t3` is not applicable (`run-bench.sh` short-circuits it) and the
only hard gates are the in-image PF-2 keystroke p95 budgets and the warm-startup
budget. T3's trend history is the ledger rows below.

## T3 soak + leak detection (PF-8)

An optional soak stage lives beside the keystroke harness and drives the SAME
real ncurses `./lem` binary in the SAME sandboxed private-socket tmux
(Constraint 7 stays structural). Off by default so the standard `t3` stays fast;
`LEM_T3_SOAK=1 scripts/run-bench.sh t3` appends it, and it also runs standalone.

- `soak.sh` — a key-driven editing loop for `LEM_SOAK_SECONDS` (default 1800),
  cycling key analogs of the PF-5 workload actions against the opened 10 MB
  `mixed-10m` file: page (`C-v`/`M-v`), scroll (`Down`/`Up`), isearch a common
  needle and abort, insert + `Backspace` + `M-x undo`/`redo`. Each active burst
  is followed by an **idle rest** (`SOAK_REST_SECONDS`, default 12 s > the 10 s
  metrics sample period) so the in-image heap idle-timer actually fires and the
  exit dump carries `dynamic-usage` samples across the run. Two independent
  memory signals are captured: **external RSS** (sampled from
  `/proc/<pane_pid>/status` every 10 s into a `t_seconds,rss_bytes` CSV, with no
  dependence on in-image state) and **in-image `dynamic-usage`** (the metrics
  heap ring). On completion the editor exits cleanly so the metrics dump fires;
  the CSV, a copy of the dump, and the analysis text are preserved under
  `bench/results/` (gitignored).
- `analyze-soak.mjs` — the detector (node; jq unavailable). Reads the CSV + dump
  and flags a leak only when **BOTH** signals grow past a threshold (default
  1 MB/min):
  - **`dynamic-usage` growth = the FLOOR trend.** Raw `dynamic-usage` sawtooths
    ±hundreds of MB with the GC cycle, so its least-squares fit is meaningless;
    the RETAINED memory is the lower envelope (the post-GC troughs). We take the
    MINIMUM of the first half vs the second half (a reading can never fall below
    the live set, so the min is a safe, never-spuriously-low floor estimate) and
    report the floor's growth rate. This is the sensitive, GC-noise-free
    discriminator: measured flat (~305 MB, ~0.1 MB/min) across a clean editing
    soak, and rising under a leak.
  - **RSS growth = a robust median-of-halves rate.** SBCL munmaps memory back to
    the OS after full GCs, so RSS sawtooths downward and a least-squares slope
    over a short window is dominated by whichever munmap lands in it (measured: a
    clean run's second-half LS slope swung to −47 MB/min). The median of the
    second half minus the median of the first half, over their time separation,
    cannot be flipped by those outliers.
  - **Verdict:** `LEAK SUSPECT` (exit 1) iff RSS-rate AND DU-floor-rate both
    exceed the threshold; `CLEAN` (exit 0) otherwise; `INSUFFICIENT DATA`
    (exit 2) if either signal has < 4 points per half. `GC pause p99` is also
    reported from the dump.
- `soak-self-test.sh` — the PF-8 done-when ("catches a deliberately-injected
  leak"). Runs the short soak (default 200 s) twice: a LEAK arm whose `--eval`
  installs a repeating **idle** timer that pushes a 4 MiB array onto a global
  list every second of idle (a pure test-side injection — NO source changes),
  and a CLEAN arm with no injection. Asserts the LEAK arm flags (exit 1) and the
  CLEAN arm does not (exit 0).

The soak verdict is a **trend, not a gate**: like all T3 wall/soak numbers only
the in-image keystroke/startup budgets ever hard-fail, so a genuine leak suspect
on the real soak is recorded as a P4 backlog candidate (below), not a red
commit. `soak.sh`'s own exit code IS the verdict (that is what the self-test
asserts); the `run-t3.sh` wiring reports it loudly but never flips the tier's
exit.

## Ledger

Format: one row per baseline creation / rebaseline / OPT-n. Include the
fingerprint, the commit, the reason, and — for optimizations — before/after
numbers and the motivating T0/T2 measurement (Constraint 1).

### Rebaselines

| Date | Fingerprint | Tier | Commit | Reason |
|------|-------------|------|--------|--------|
| 2026-07-18 | ex44 / i5-13500 / 20c | t1 | (PF-3) | Initial baseline: `telemetry` entry established with the bench runner. No optimization — this is the substrate landing (SPEC-PERF PF-3). |
| 2026-07-18 | ex44 / i5-13500 / 20c | t1 | (P0 review fixes r1) | Rebaseline after widening the telemetry timed window from 1e6 to 5e7 ops (honest ~0.0008 µs/op trend instead of a bimodal 0.001/0.002 quantization artifact) and making the entry budget-gated. No behavior/optimization change to Lem — measurement substrate only. New band is informational for this entry. |
| 2026-07-18 | ex44 / i5-13500 / 20c | t1 | (PF-4) | Initial baseline for the PF-4 micro suite: `edit` (12 entries) and `points` (3 entries) added to the multi-entry registry, plus the `bench/corpora/` generators. No optimization — new measurement entries only. Gate-stability validated by 11 consecutive PASS runs on a machine under concurrent load (load avg ~4.6). See Deviations for the measurement-hygiene choices (net-zero ops, GC suppression, interleaving, median-of-nine, 20% band floor). |
| 2026-07-18 | ex44 / i5-13500 / 20c | t1 | (PF-4) | Rebaseline completing Milestone P1: added the `width` (4), `search` (4), `syntax` (1), and `redisplay` (3) entry files to the registry (12 new entries). No optimization — new measurement entries only. Each is deterministic (fixed corpora / fixed-content strings) and sizes its iteration count for a ≥ 10 ms window; validated by 5 consecutive PASS runs. See Deviations for the redisplay long-line size cap (a stack-exhaustion finding), the headless syntax-grammar load, the absent-needle search sweep, and the persistent recording interface. |
| 2026-07-18 | ex44 / i5-13500 / 20c | t1 | (PF-5, corpus pin) | **No t1 rebaseline needed.** Pinning `lisp-500k` to commit `5cd018a9` via `git show` (was: working-tree `read-file-string`) is byte-for-byte identical at this commit — the six source files are unchanged between the working tree and the pin — verified by regenerating both ways and comparing (`cmp` IDENTICAL). The `syntax/lisp-500k` t1 entry reads the same bytes, so its baseline is untouched; the committed t1 baseline stands. Recorded here per Constraint 6. |
| 2026-07-18 | ex44 / i5-13500 / 20c | t2 | (PF-5) | **Initial T2 baseline** (Milestone P2): the `run-t2.lisp` macro-session harness + three workloads (`big-file`, `scroll`, `long-line`), the `mixed-10m` corpus generator, and the `lisp-500k` corpus pin. No optimization — new measurement tier only. Validated by 5 consecutive PASS gate runs; all three bands settle at the 20% floor after interleaving. See Deviations for the long-line 16 KB render cap (a tighter restatement of the P1 stack-exhaustion finding), the additive T2 metric fields, the interleaving/long-line sizing hygiene, and the `mixed-10m` corpus. |
| 2026-07-18 | ex44 / i5-13500 / 20c | t2 | (PF-5, +4 workloads) | **T2 rebaseline** completing the PF-5 workload set: added `isearch`, `undo-storm`, `overlay-heavy`, and `lisp-edit` (one file each under `scripts/bench/t2/`), so all seven PF-5 workloads now exist. No optimization — new measurement workloads only; each drives frozen public API + existing internals (an API-stability canary). The pre-existing `big-file`/`scroll`/`long-line` medians shift down slightly (4745→4234, 1272→1075, 610→488) because the interleaved suite is now seven-way, not three-way — the honest per-machine reset (Constraint 5), not a regression. Rebaseline folds five suite runs; all bands settle at the 20% floor. Validated by 5 consecutive PASS gate runs. See Deviations for the headless-isearch driving choice, the undo-storm canary-in-setup + trailing-undo replay, the overlay-heavy net-zero edits, and the lisp-edit `calc-indent-default` + undo-restore choices. |

### T3 trend history (PF-7)

T3 has no committed baseline; each run's headline numbers are recorded here as a
trend row (Constraint 5: matching fingerprint only). Wall numbers are coarse
(~5–10 ms tmux resolution) and never gate; the in-image columns are the
PF-2-derived hard budgets.

| Date | Fingerprint | Commit | Startup warm (ms) | plain p95 | bigfile p95 | longline p95 | scroll p95 | Notes |
|------|-------------|--------|-------------------|-----------|-------------|--------------|------------|-------|
| 2026-07-18 | ex44 / i5-13500 / 20c | 8fbbb171 | **190** (cold 190) | **1.0** (wall 6.2) | **1.0** (wall 6.3) | **16.4** (wall 40.7) | **2.0** (wall 6.7) | First T3 baseline row (Milestone P3, PF-7). All budgets PASS: warm startup 190 ms ≪ 2 s; plain keystroke p95 1.0 ms < 10 ms; bigfile/scroll 1–2 ms and longline 16.4 ms all < 30 ms. In-image ms are log2-bucket p95 estimates (us upper-edge / 1000); "wall" = coarse `capture-pane` trend p50. `longline` is the pathological one both in-image (p50 8.2 ms, redisplay-dominated: the certified `k-sum`/`k-obj-width` non-tail width fold over the 16 KB line) and wall (~41 ms) — corroborating signals. queue-wait sample count 142–143 ≥ 120 per scenario (pipeline wrapping proven). No optimization — new measurement tier only. |

### T3 soak history (PF-8)

Soak is trend-only (no committed baseline; matching fingerprint only). Each full
soak records RSS start/end + median-of-halves rate, the `dynamic-usage` floor
trend, GC pause p99, and the verdict. Artifacts (CSV, dump copy, analysis) are
under `bench/results/` (gitignored).

| Date | Fingerprint | Commit | Duration | RSS start→end (med rate) | DU floor rate | GC pause p99 | Verdict | Notes |
|------|-------------|--------|----------|--------------------------|---------------|--------------|---------|-------|
| 2026-07-18 | ex44 / i5-13500 / 20c | fd0e83a6 | 30 min (1800 s) | 659→692 MB med-of-halves, **2.20 MB/min** (raw first/last 411→777 MB; 181 samples) | 305→345 MB, **2.61 MB/min** (130 samples) | 131.1 ms (348 GCs) | **LEAK SUSPECT** | First full soak (Milestone P3, PF-8), against the real ncurses `./lem` at `fd0e83a6`, cycling key analogs of the seven PF-5 workload actions over the 10 MB `mixed-10m` file with 12 s idle rests. **Trend-only, NOT a commit gate** (PF-8, like all T3 wall/soak numbers — only the in-image keystroke/startup budgets ever hard-fail). Both signals clear the 1 MB/min threshold so the detector flags: recorded here as a **P4 backlog candidate** (leak triage — P5/optimization must wait for the P4 grounding report, so it is NOT investigated or fixed here). The DU floor (retained-memory lower envelope) rising ~40 MB over 30 min is the sensitive signal; RSS corroborates. To triage at P4: heap still reaching steady working set over the run vs. genuine per-burst retention. The detector *itself* is validated by `soak-self-test.sh` (200 s ×2 arms): CLEAN arm → CLEAN (exit 0, DU floor 0.02 MB/min, RSS −33 MB/min munmap dip correctly not flagged), injected-leak arm → LEAK SUSPECT (exit 1, DU floor 26.25 MB/min) — so PF-8's done-when (one full soak recorded + analyzed **and** the detector catches a deliberately-injected leak) is satisfied. Artifacts (CSV, dump copy, analysis) under `bench/results/` (gitignored); sandbox + private tmux socket torn down by the harness trap. |

### Optimizations (OPT-n)

_None yet. P5 must not start before the P4 grounding report (SPEC-PERF)._

| Item | Date | Evidence (T0/T2 + profile) | Change | Before → After | Notes |
|------|------|----------------------------|--------|----------------|-------|
| —    | —    | —                          | —      | —              | —     |

## P4 grounding report (PRELIMINARY — synthetic only)

This is the PF-9 grounding report: the point of SPEC-PERF, the artifact that ranks
the optimization backlog by measured data rather than intuition. It is written
**PRELIMINARY** — from synthetic tiers (T1/T2/T3 + one soak) and sb-sprof profiles
only. **The T0 field summary that PF-9 also requires is PENDING** (see the deviation
and user instructions in the "T0 field section" below). Per Constraint 6 the field
data is the arbiter, so **the backlog here is provisional and P5 stays gated** until
the field week lands and the ranking is reconciled and finalized.

### 1. Baseline pointer + performance portrait

The full baseline tables are already in this ledger, above — this report does not
duplicate them:

- **T1 micro** — *P1 baseline numbers* table (fp ex44 / i5-13500 / 20c, commit
  `07253058`).
- **T2 macro** — *P2 T2 baseline numbers* table (committed baseline JSON at commit
  `e073c6b2`; the section header's `5cd018a9` is the corpus-pin commit — the baseline
  file itself records `e073c6b2`, which is the provenance used throughout this report).
- **T3 end-to-end** — *T3 trend history* table (commit `8fbbb171`).
- **Soak** — *T3 soak history* table (commit `fd0e83a6`).

**Portrait (as measured).** The unconfigured ncurses build starts fast — warm startup
**190 ms**, an order of magnitude under the 2 s budget — and is comfortably interactive
for ordinary editing: in-image keystroke-to-paint p95 is **1.0 ms** on a plain buffer,
**1.0 ms** inserting into the 10 MB file, **2.0 ms** scrolling it, all far under budget.
The one pathological keystroke is **long-line: p95 16.4 ms** (still < 30 ms budget),
redisplay-dominated by the certified non-tail width fold over a 16 KB single line.
Macro throughput is dominated by full-frame redisplay over large buffers: the big-file
page-through (10 MB, 4976 frames) runs **4234 ms** and conses **719 MB** (4 GCs,
~33 ms pause total); isearch **2201 ms** / 437 MB / 3 GCs (~41 ms); scroll **1075 ms**;
the edit-bound workloads are cheap (overlay-heavy 520 ms, long-line 488 ms, lisp-edit
299 ms, undo-storm 266 ms, each ≤ 1 GC). GC behavior is benign per-session but the
**30-min soak flagged LEAK SUSPECT** — `dynamic-usage` floor rising **+2.61 MB/min**,
RSS **+2.20 MB/min**, **GC pause p99 131 ms** (artifacts
`bench/results/soak-20260718223850.*`) — the one open stability question. The
`:paranoid` edit-engine tax is **~1.2× on normal buffers** but **~13–16× on a 200 KB
line** (the certified `wf-buffer` re-walks the line per edit); this is the datum for
the paranoid→release soak decision (see NOTE below). Micro-level, `string-width` over
mixed unicode (1667 µs) and syntax-scan of 500 KB Lisp (116 ms) are the heaviest T1
primitives — both feeding the redisplay hotspot the profiles confirm.

### 2. Cross-workload sb-sprof hotspot ranking

Fresh 2026-07-19 sb-sprof `:cpu` profiles of all seven T2 workloads (per-workload
sample counts — big-file **3804**, isearch **4095**, scroll **2841**, overlay-heavy
**2636**, long-line **2629**, lisp-edit **2518**, undo-storm **2663** — every one
clears the PF-6 ≥ 1000-sample bar). Cross-workload weight =
Σ_workload (frame self% × that workload's committed t2 wall-ms share); shares: big-file
46.6%, isearch 24.2%, scroll 11.8%, overlay-heavy 5.7%, long-line 5.4%, lisp-edit 3.3%,
undo-storm 2.9% (total 9083 wall-ms). `weighted` reads as "≈ % of total editor CPU
attributable to this frame across a wall-representative session mix" — a ranking metric,
not an exact time budget. **Full per-workload top-10 tables and the class methodology
are versioned in `bench/profiles-summary.md`; raw flat+graph reports are
`bench/profiles/*-20260719*.txt` (gitignored).**

Class: **kernel** = verified ACL2 `K-*` books (optimizable only under the one-source
recertify rule); **shell** = imperative `lem`/`lem-core` code; **runtime** =
SBCL/PCL/foreign/unattributed.

| # | frame | weighted | class | dominates (self%) | field relevance |
|--:|---|--:|---|---|---|
| 1 | `ACL2::K-CHAR-WIDTH` | 12.14 | kernel | big-file 14.5, long-line 13.2, scroll 12.5, isearch 12.4 | **field-plausible**, weight inflated by big-file/scroll paging |
| 2 | `ICON:ICON-CODE-P` | 7.88 | shell | big-file 13.1, scroll 10.4, long-line 10.0 | **field-plausible** (per-codepoint width shim) |
| 3 | `STRING-WIDTH-UTILS:WIDE-INDEX` | 7.27 | shell | isearch 10.8, big-file 8.8 | **field-plausible** (width shim) |
| 4 | `(LAMBDA .ARG0. :IN BRAID.LISP)` PCL dispatch | 5.72 | runtime | overlay-heavy 48.7, undo-storm 22.8, lisp-edit 15.8 | **field-relevant to edit latency**, weight *understated* by wall mix |
| 5 | `ACL2::K-CONTROL-CODE-P` | 4.47 | kernel | ~5 across the 4 redisplay workloads | field-plausible (width path) |
| 6 | `ACL2::K-ZERO-CODE-P` | 4.04 | kernel | big-file 4.9, isearch 4.2 | field-plausible (width path) |
| 7 | `ACL2::K-AMBIGUOUS-CODE-P` | 3.68 | kernel | scroll 5.2, long-line 5.0 | field-plausible (width path) |
| 8 | `SB-IMPL::GETHASH/EQL-HASH/FLAT` | 3.47 | runtime | big-file 4.2 | field-plausible (width memo lookups) |
| 9 | `Unknown fn 45469` | 3.30 | runtime | isearch 12.9 only | **synthetic/unattributed — flag, do not optimize** |
| 10 | `ACL2::K-SUM` (non-tail width fold) | 3.25 | kernel | long-line 7.5, scroll 5.0 | **field-plausible + correctness-linked** (same frame as the crash cliff) |
| 11 | `SB-KERNEL:TWO-ARG->=` | 3.02 | runtime | ~3 across redisplay workloads | field-plausible (width predicates' fixnum compares) |
| 12 | `STRING-WIDTH-UTILS:STRING-WIDTH` | 2.75 | shell | long-line 5.2, scroll 5.1 | field-plausible (width shim entry) |
| 13 | `SB-KERNEL:TWO-ARG-<=` | 2.48 | runtime | long-line 3.0, isearch 2.7 | field-plausible (width path arithmetic) |
| 14 | `ACL2::K-WIDE-CODE-P` | 2.06 | kernel | long-line 3.2, scroll 2.7 | field-plausible (width path) |
| 15 | `LENGTH` | 1.76 | runtime | **undo-storm 32.4** | **synthetic-prominent** — 5k-edit storm; must reconcile vs real undo/redo frequency (T0) |

(Rank 16–25 continue in `bench/profiles-summary.md`: `NATP`, `GENERIC-+`, `RANGE<=`,
`%DATA-VECTOR-AND-INDEX`, `SB-SPROF::UNAVAILABLE-FRAMES` [profiler self-overhead, not an
editor hotspot], `SEARCH`, `TEXT-OBJECT-CHAR-WIDTHS`, `DATA-VECTOR-REF`,
`GETHASH/EQL-HASH`, `K-NAT`.)

**Two actionable clusters, and why the synthetic mix must be reconciled against T0.**
(a) **The string-width redisplay path** — ranks 1,2,3,5,6,7,8,10,11,12,13,14 plus 16/22/24
— sums to **~55–60% of weighted cross-workload CPU**, split ~half verified kernel (`K-*`
per-codepoint predicates + the `K-SUM` fold) and ~half the `lem/common/character` shim
(`icon-code-p`, `wide-index`, `string-width`, `text-object-char-widths`). It dominates
*every* redisplay-bound workload, so it is not a big-file artifact — but its cross-workload
*weight* is inflated by big-file+scroll paging (58% of the synthetic mix is bulk-scrolling
large buffers, which a typical editing session does far less of than the mix implies). Real
weight is field-pending. (b) **PCL generic-function dispatch** on hot buffer/point/overlay
generics — the single frame #4, with *zero* kernel component — dominates the edit-bound
workloads (overlay-heavy/undo-storm/lisp-edit) and is *understated* by the wall-weighted
mix because those workloads have small wall shares; it is exactly the cost a user feels as
edit latency. **Class split of aggregated weight is near-even thirds** (kernel 32.86 /
runtime 32.44 / shell 32.35), but read through these two clusters, not as three independent
thirds. Frames explicitly marked synthetic (`Unknown fn 45469`, `UNAVAILABLE-FRAMES`) and
synthetic-prominent (`LENGTH` in undo-storm) are **not** carried into the backlog on
synthetic evidence alone.

### 3. T0 field section — PENDING

**PENDING — DEVIATION (Constraint 6 / SPEC-PERF PF-9).** PF-9 requires the grounding
report to include a **T0 field summary** (real-session latency percentiles, stage
decomposition, worst commands, GC pause profile, paranoid tax as actually experienced)
and to **reconcile the sb-sprof ranking against T0** — with ≥ 1 week of field data
(Sequencing: "P4 … requires all tiers plus ≥ 1 week of T0 field data"). At the time of
writing that field data does not yet exist, so this report is issued PRELIMINARY on
synthetic data only, with the field summary explicitly deferred and the backlog marked
provisional. This deviation is recorded here per Constraint 6 rather than by weakening
the spec.

**User instructions to produce the T0 summary and finalize the report:**

1. **Daily-drive the instrumented build.** `make ncurses`, then use `./lem` as your
   normal editor for **at least a week**. T0 telemetry is always-on (no flag; the
   editor variable defaults on), Constraint-4 budgeted, so daily use costs nothing
   measurable.
2. **Dumps land automatically.** On every clean exit (`exit-lem` / `C-x C-c`) the
   session writes `(lem-home)/metrics/<session-start-timestamp>.json`. You can also
   dump on demand mid-session with **`M-x metrics-dump`**, and read a live human
   summary any time with **`M-x metrics-report`** (renders p50/p95/p99 latencies, the
   t₀…t₄ stage decomposition, worst commands, GC pause distribution, and heap trend
   into a `*metrics*` buffer). Keep the accumulated dump JSONs — do not delete
   `(lem-home)/metrics/`.
3. **After the week, produce the T0 summary and reconcile.** Aggregate the dumped
   JSONs into: real-session keystroke/command/redisplay percentiles, the stage
   decomposition, the worst commands by dispatch time, the GC pause profile, and the
   paranoid tax as actually experienced. Then **reconcile this synthetic ranking
   against it** — specifically test (i) whether the width path's real weight matches
   its 55–60% synthetic share or is inflated by big-file paging that real sessions do
   less of; (ii) whether PCL edit-path dispatch (understated here) ranks higher on
   real edit-command frequency; (iii) whether `undo-storm`'s `LENGTH` prominence
   survives real `undo`/`redo` frequency at all.
4. **Finalize.** Replace this section with the field summary, re-rank the OPT backlog
   by real impact × confidence, drop the "PRELIMINARY" marker, and only then open P5.

### 4. Ranked optimization backlog (PROVISIONAL — OPT-1 … OPT-6)

Ranked by **measured impact × confidence**, with **correctness outranking pure
throughput** (priority order: Correctness first). Every item cites its motivating
artifact; all remain provisional pending the T0 reconciliation in §3.

**OPT-1 — Long-line redisplay stack-overflow cliff (correctness-grade).**
- *Measurement:* a single text object ≳ **24 000 chars** overflows the default SBCL
  control stack during redisplay — deterministic (recursion depth = line length),
  confirmed by three independent harness findings: the P1 `redisplay/long-line`
  deviation (crash between 50 k and 100 k chars), the P2 `long-line` deviation (renders
  at 23 000, crashes at 24 000 with wrap-on + cursor-at-end), and the T3 `longline`
  scenario cap. The shipping `./lem` binary uses the same default stack, so **this is
  a real editor crash**, not a bench artifact. The same frame shows as raw CPU: `K-SUM`
  #10 (long-line 7.5% / scroll 5.0% self).
- *Root cause:* `verified/layout.lisp` `k-obj-width` → `K-SUM`, a **non-tail** left
  fold over the object's full per-character width list.
- *Hypothesis:* rewrite `K-SUM`/`k-obj-width` as a tail-recursive accumulator (or a
  bounded iterative width sum) in the certified book. Lifts the cap entirely *and*
  removes the non-tail fold from the hot width path (a bonus CPU win on long lines).
  Expected magnitude: eliminates the crash class; small-to-moderate CPU improvement on
  long-line/scroll.
- *Risk / verification:* touches `verified/` → **one-source recertify** (`run-proofs.sh`)
  and the kernel conformance PBT (`run-tests.sh`) are the behavior-preservation proof;
  re-enable a > 24 000-char render in the T1/T2/T3 long-line harnesses once the cap
  lifts.

**OPT-2 — String-width redisplay path (largest CPU share).**
- *Measurement:* ~**55–60% of weighted cross-workload CPU** (§2, table ranks
  1/2/3/5/6/7/8/10/11/12/13/14); `K-CHAR-WIDTH` #1 (weighted 12.14), `ICON-CODE-P` #2
  (7.88), `WIDE-INDEX` #3 (7.27). Dominates big-file (self 14.5/13.1/8.8),
  isearch, scroll, long-line. Provenance: `bench/profiles-summary.md`,
  `bench/profiles/big-file-20260719102057.txt` et al.
- *Hypothesis:* the redisplay recomputes per-codepoint widths for text objects on every
  full frame; cache width at the shim layer (`lem/common/character` —
  `text-object-char-widths` / `string-width`, keyed per unchanged line/object) so
  unchanged lines skip the kernel per-codepoint walk entirely. A gethash memo already
  rides along the path (`GETHASH/EQL-HASH/FLAT` #8), suggesting the per-char cache
  exists but the per-object/per-line result does not. Caching at the **shell shim**
  avoids recertifying the kernel. Expected magnitude: large — could remove a substantial
  fraction of redisplay CPU on all four redisplay-bound workloads (and, via less consing,
  fewer GCs — see OPT-4).
- *Risk / verification:* shell-level change under the frozen API; behavior-preservation =
  T1 `width/*` + `redisplay/*` entries, T2 redisplay workloads, and the rove suites,
  all green with the target profile share reduced. If any kernel `K-*` book is touched,
  one-source recertify applies. **Reconcile the 55–60% weight against T0 first** — it is
  inflated by big-file paging.

**OPT-3 — PCL generic-dispatch on hot buffer/point/overlay generics (edit latency).**
- *Measurement:* frame #4 `(LAMBDA .ARG0. :IN BRAID.LISP)` — the PCL discriminating
  closure — is **48.7% self in overlay-heavy, 22.8% in undo-storm, 15.8% in lisp-edit**,
  with *zero* kernel component (`bench/profiles/overlay-heavy-20260719102135.txt`). The
  hot generics are the buffer/point/overlay protocol (`point<=`, `same-line-p`,
  `character-offset`, overlay predicates — visible as the next frames in those profiles).
- *Hypothesis:* seal/devirtualize the hottest buffer/point protocol generics (e.g.
  `declaim inline` fast paths or sealed dispatch) so megamorphic edit-path calls stop
  paying full cache-closure dispatch. Expected magnitude: large on **edit latency** —
  the cost a user actually feels typing/undoing — even though the wall-weighted mix
  understates it (these workloads have small wall shares).
- *Risk / verification:* shell change beneath the frozen `lem-core` API; the buffer/
  point/overlay rove suites + T2 edit workloads (overlay-heavy/undo-storm/lisp-edit) are
  the behavior-preservation fence. **Must be corroborated by T0 real edit-command
  frequency** before it is committed (its synthetic prominence rests on edit-storm
  workloads).

**OPT-4 — GC pause p99 / redisplay consing.**
- *Measurement:* soak **GC pause p99 131 ms** (`bench/results/soak-20260718223850.*`,
  T3 soak history row); big-file conses **719 MB** and isearch **437 MB** per workload
  (T2 baseline), driving the 3–4 GCs those sessions incur. A 131 ms pause is a felt
  hitch in an interactive session.
- *Hypothesis:* the dominant consing is in the redisplay width path (OPT-2) and the
  literal-search `points-to-string`-per-line allocation; cutting per-frame allocation
  (chiefly via OPT-2's width cache) reduces GC frequency and pause tail. Expected
  magnitude: p99 pause and GC count down proportional to the consing removed. Largely
  **downstream of OPT-2** — sequence after it and re-measure.
- *Risk / verification:* T2 `gc-count`/`gc-pause-ms` per-workload metrics + a re-run
  soak; no API change.

**OPT-5 — Soak leak suspect (daily-driver stability; TRIAGE first).**
- *Measurement:* the 30-min soak verdict **LEAK SUSPECT** — `dynamic-usage` floor
  **+2.61 MB/min**, RSS **+2.20 MB/min** over the run (both above the 1 MB/min
  threshold), `bench/results/soak-20260718223850.*` (T3 soak history, commit
  `fd0e83a6`). Trend-only, never a commit gate — recorded as a P4 candidate.
- *Hypothesis:* **triage, not yet a fix** — determine whether the heap is still reaching
  its steady working set over 30 min (benign) or genuinely retaining per-burst (leak).
  Candidate sources to inspect: overlay/point retention, unbounded undo history, or a
  ring buffer that is not actually bounded. Expected magnitude: unknown until triaged;
  potentially high (long-session stability is the whole daily-driver point).
- *Risk / verification:* re-run soak + the leak detector (`analyze-soak.mjs`); **low
  confidence in root cause** is exactly why it ranks below the CPU items and why the
  **T0 field week is the arbiter** — a real week-long session either shows the retention
  or shows the heap settling.

**OPT-6 — Long-line keystroke latency (derived; verification item).**
- *Measurement:* T3 `longline` keystroke **p95 16.4 ms** (in-image, redisplay-dominated;
  T3 trend history, commit `8fbbb171`) — the one keystroke scenario near its budget.
- *Hypothesis:* **fully downstream of OPT-1 + OPT-2** (the `K-SUM` fold and the width
  path over the 16 KB line are its entire cost). No independent change; listed so the
  finalized report *verifies* that OPT-1/OPT-2 actually drop this measured p95 toward
  single-digit ms in a real session, per PF-10 step 7.
- *Risk / verification:* T3 `longline` p95 re-measured after OPT-1/OPT-2; no new surface.

**NOTE (not an OPT item) — paranoid→release soak decision.** The `:paranoid` edit-engine
tax is measured at **~1.2× on normal buffers** and **~13–16× on a 200 KB line** (T1
edit entries, `verified/README.md` VK-4 acceptance table). Whether to drop
`LEM_PARANOID=1` for daily driving is **the user's call**, not an optimization item — and
SPEC-PERF makes it data-driven at P4 via this tax *and* the field latency histograms.
Since the field histograms are PENDING (§3), the decision waits on the field week too.

### 5. P5 protocol readiness

PF-10 runs each backlog item OPT-n through a fixed loop: **(1) evidence** — the
motivating T0/T2 measurement + before-profile restated in the item (the profiles under
`bench/profiles/` and `bench/profiles-summary.md` are already attached above);
**(2) hypothesis** — change + expected magnitude; **(3) change** beneath the frozen API,
recertifying any touched `verified/` book under the one-source rule (OPT-1 is the one
kernel item) and leaning on the conformance suites where shell code is touched;
**(4) gates** — `run-tests.sh` + (if `verified/` changed) `run-proofs.sh` + `run-bench.sh
t1 t2` green vs. baseline, with the target metric improved beyond its noise band and no
other gated metric regressed; **(5) adversarial review** for behavior drift and
benchmark-overfitting; **(6) ledger + one commit per item + rebaseline**; **(7) periodic
T0 re-dump** confirming the win is felt in real sessions. The framework for all seven
steps is live (P0–P3 landed). **What is NOT ready is the backlog itself:** it is
provisional until the ≥ 1-week T0 field data (§3) reconciles this synthetic ranking and
the report is finalized. **P5 must not start before that finalization** (Sequencing:
"P5 requires P4"; PF-9 done-when: "the backlog is ranked by measured impact … P5 must
not start early").

## Deviations from SPEC-PERF.md

SPEC-PERF item 6 requires deviations to be recorded here rather than by editing
the spec.

- **The `telemetry` entry is budget-gated, not band-gated** (P0 review fixes,
  round 1). SPEC-PERF PF-3 describes a single mechanism — "Regression = median
  worse than baseline median by more than the band" — for every gated entry.
  The `telemetry` entry measures `histogram-record`, which costs ~0.8 ns/op:
  an order of magnitude below `get-internal-real-time` resolution (1 µs) and
  well below the between-process CPU-frequency variance a real pre-commit
  machine exhibits (a busy machine intermittently reads +50% for a whole
  process invocation, which no in-process repetition or window length removes).
  A median-vs-band gate on such an entry is therefore non-reproducible: it
  reports intermittent false regressions on an unchanged tree, which would
  block legitimate commits (undercutting Constraint 3). We resolve this by
  gating `telemetry` on the permanent Constraint-4 hard budget (< 1 µs/op AND 0
  bytes consed/op) instead — deterministic, and the meaningful invariant for a
  telemetry hot-path primitive. Its median/band are still recorded and printed
  (verdict `TREND`) for trend visibility. Any real regression this path could
  suffer either conses (caught by the 0-consed budget) or adds latency toward/
  past the 1 µs budget. All µs-scale entries added in PF-4+ keep the normal
  band gate, where between-process variance is small relative to the signal and
  the mechanism is sound. Implemented via `+budget-gated-entries+` in
  `scripts/bench/run-t1.lisp`.

- **`scripts/bench-edit.lisp` moved into the suite** (PF-4). SPEC-PERF PF-4
  says the VK-4 edit bench is "kept, moved to `scripts/bench/edit.lisp`"; the
  old top-level script is deleted and its scenarios are now driver entries.

- **Edit ops are net-zero round-trips, not one-directional insert/delete**
  (PF-4). The VK-4 script measured `insert-char`, `delete-char`, and
  `newline split+join` as separate one-directional runs. A one-directional
  insert (or delete) grows (shrinks) the edited line, so its per-op cost
  **depends on the iteration count** — and under `:paranoid` the certified
  `wf-buffer` re-walks the whole growing line every edit, making the entry
  O(n²) in the iteration count. That is impossible to size for both a ≥ 10 ms
  window and a stable, count-independent number. The suite instead measures
  net-zero round-trips — `insert-delete` (insert a char then delete it) and
  `newline` (split then join) — which keep the line length (and every
  registered point) invariant, so the number is iteration-count-independent and
  gate-stable while still covering insert, delete, split, and join cost. The
  separate one-directional numbers remain available as the VK-4 acceptance
  table in `verified/README.md`.

- **Measurement hygiene to make the µs-scale entries gate-stable** (PF-4). The
  consing-heavy edit/points entries are sensitive to GC-pause and scheduling
  jitter; three additive measures (none of which change any measured Lem code)
  make the median gate reproducible:
  1. **GC suppression in the timed window** — `bytes-consed-between-gcs` is
     raised to 1 GiB and every section starts with a full GC, so no GC fires
     inside a timed window (the heaviest section conses ~65 MB). GC-pause
     jitter — seen doubling a 25 ms window — is removed from the wall figure;
     allocation is still reported as consed-per-op and GC cost lives in T0/T3.
  2. **Interleaving** — `run-suite` runs the reps round-robin across entries
     (not all of one entry back-to-back), so each entry's nine reps span the
     whole ~10 s suite and a sub-second load transient lands on at most one rep
     per entry instead of an entire entry's window.
  3. **Median of nine** (Constraint 5 mandates ≥ 5) rejects a transient
     covering one or two reps.

- **Band floor raised 5% → 20%** (PF-4). SPEC-PERF PF-3 floors the noise band
  at 5%. Two effects push real variance higher: the five band-measuring suite
  runs execute in one process (shared CPU-frequency/thermal state, so they
  underestimate the cross-process variance the gate — a fresh process — sees),
  and the pre-commit machine is a shared workstation running concurrent
  CPU-heavy work (the developer's own editor sessions, other agents). After the
  hygiene measures above, the residual cross-process swing on the consing-heavy
  `:paranoid` entries is ~15–17%. A 20% floor covers it and stays far below the
  > 1.5× (50%) hot-path regression SPEC-VK VK-4 treats as a blocker, so the
  gate remains meaningful. A quiet, CPU-pinned machine would justify a tighter
  floor via its own per-machine rebaseline (Constraint 5). Implemented as
  `+bench-band-floor+` in `scripts/bench/run-t1.lisp`.

- **The self-test scopes itself to `telemetry`** (PF-4). `scripts/bench/
  self-test.sh` sets `LEM_BENCH_ONLY=telemetry` (a new driver filter): the gate
  mechanism it proves is the budget gate, whose canary is the telemetry entry,
  and scoping keeps the self-test fast and independent of the slower,
  load-sensitive µs entries.

- **The `redisplay/long-line` buffer is 50 KB, not 200 KB** (PF-4), and this is
  a *finding*, not just a sizing choice. PF-4 names a "200 KB long-line" buffer
  (the same corpus the edit/points entries stress). Redisplaying a single text
  object of ≳ 100 000 characters **exhausts the default control stack**: the
  certified clip/wrap path (`src/display/physical-line.lisp` →
  `verified/layout.lisp` `k-clip` / `k-wrap-row`) computes an object's total
  width with `k-obj-width` → `k-sum`, a **non-tail** left fold over the object's
  entire per-character width list, so its recursion depth equals the line
  length. Empirically on this build (default SBCL control stack) a plain single
  line renders fine at 50 000 chars and stack-overflows by 100 000 — and the
  built `lem` binary uses the same default stack (its `save-lisp-and-die` sets
  no larger one), so this is the real editor's limit, not a bench artifact. No
  production display-level long-line cap exists (unlike syntax scanning's
  `long-line-scan-threshold`), and no existing test renders a line this long, so
  the limitation was latent. The redisplay entry therefore uses a 50 KB single
  line (first 50 000 chars of the `long-line-200k` corpus, wrap off) — well below
  the boundary, gate-stable, and still exercising the single-huge-object clip
  path that dominates the cost. The 200 KB single-object redisplay is **not**
  benchmarked (it would crash the suite); it is recorded here as an
  OPT-candidate for P4/P5: making `k-sum`/`k-obj-width` (or the object-width
  path feeding the layout kernel) non-recursive would lift the cap. Measuring
  under an artificially enlarged stack was rejected — it would report a number
  the shipping editor cannot actually achieve.

- **`syntax` loads `extensions/lisp-mode/grammar.lisp` directly, not the whole
  `lem-lisp-mode` system** (PF-4). PF-4 wants the "tmlanguage path" over a large
  Lisp file in a lisp-mode buffer. The real grammar
  (`lem-lisp-mode/grammar:make-tmlanguage-lisp`) lives in a file that depends
  only on `lem/core` + cl-ppcre, both already in the bench image; loading it
  directly gives the *actual* lisp-mode tmlanguage (dozens of match/region
  patterns) without dragging in `lem-lisp-mode`'s heavy transitive deps
  (usocket / micros / lsp), which the `:lem/core`-only bench image does not
  otherwise pull. This is the headless-scan setup `tests/long-line-scan.lisp`
  uses, but against the real grammar rather than a synthetic one. (Loading it
  prints one benign `redefining GET-FEATURES` warning — the grammar file defines
  a default method the bench never overrides.)

- **`search` sweeps an ABSENT needle over the whole buffer** (PF-4). Searching
  for a needle that occurs would stop at a corpus-content-dependent line, making
  the number fragile to any corpus change. An absent needle forces the frozen
  `search-*` to visit every line (the deterministic worst case) and, on failure,
  `search-step` restores the point to its origin, so the op is net-zero and the
  buffer/point state is invariant across repetitions — gate-stable, and a
  faithful measure of the per-line scan cost that dominates a miss (and the tail
  of a hit). Note the regexp entries cons 0 B/op while the literal entries cons
  megabytes: the regexp path scans over `line-string` (the stored line, no copy)
  whereas the literal path builds a fresh `points-to-string` per line.

- **`width` ascii/cjk/emoji strings are fixed-content, not corpus files** (PF-4).
  `string-width` is a pure function, so a deterministic 4000-char string cycling
  a fixed codepoint pool (no RNG, no committed blob) is a byte-identical input
  every run — the same determinism guarantee as a committed corpus, with less
  git weight. The `mixed` class does use the committed `unicode-mixed` corpus
  (the realistic all-branches string). The op accumulates the returned widths so
  the width call cannot be elided as dead code.

- **`redisplay` installs a persistent recording interface at load time** (PF-4).
  The recording fake-interface is normally entered via the dynamically-scoped
  `with-recording-interface`, but the driver calls each entry's `:setup` and
  `:op` in separate, unscoped calls, so a dynamic scope cannot span them. The
  entry instead sets `lem-core::*implementation*` to a
  `recording-fake-interface` once at load and calls `setup-first-frame` (exactly
  what `invoke-frontend` does for a real frontend). This is process-global, but
  harmless: no other T1 entry touches the implementation. `redraw-buffer` is
  called with force=t so every op is a full recompute (not a display-cache hit),
  which is the frame-from-scratch cost the entry means to measure.

### Milestone P2 (T2 macro session replay)

- **`lisp-500k` is pinned to commit `5cd018a9`, read via `git show`** (PF-5, a
  P1 review-finding fix). The corpus was built from the *working-tree* contents
  of six repo source files — so it would silently drift under the very P5
  optimizations that will edit those files, invalidating the syntax/scroll
  baselines mid-flight. It is now read from the git object store at the fixed
  pin (`git show 5cd018a9:<path>`), which is independent of the working tree and
  the index by construction, so two regenerations are always identical *and*
  unaffected by any working-tree edit (git semantics; verified additionally by
  wiping the cache and diffing two fresh generations — IDENTICAL). The pin is
  baked into the cache filename (`lisp-500k-5cd018a9.lisp`), so a pin bump
  invalidates the cache automatically. At this commit the pinned bytes equal the
  old working-tree build (the six files are unchanged), so the committed **t1
  baseline is unaffected** (verified `cmp` IDENTICAL; no t1 rebaseline).

- **`mixed-10m` corpus added** (PF-5). A committed deterministic generator (fixed
  SplitMix64 seed) produces a ~10 MB document: prose paragraphs, lisp-ish code
  blocks, blank lines, mixed line lengths, and ~2.5% of words carrying a
  non-ASCII glyph (accented Latin / Greek / math arrows / CJK), tracked to the
  byte target as UTF-8. Cached like the others (gitignored), regenerated
  byte-identically on demand. It is the `big-file` workload's corpus.

- **The `long-line` workload is a 16 KB single line, not 80 KB** (PF-5), and the
  render cap is **tighter than the P1 redisplay entry's 50 KB** — a sharper
  restatement of the same stack-exhaustion finding. The task text names an 80 KB
  line "for any step that renders", but rendering a single text object of that
  length exhausts the default control stack: the certified clip/wrap layout path
  (`verified/layout.lisp` `k-obj-width` → `k-sum`) is a **non-tail** fold whose
  recursion depth equals the line length. Measured on this build driving the
  **full command path** (`redraw-display` with wrap **on** and the cursor at
  end-of-line — the deepest case): **23 000 chars render fine, 24 000
  stack-overflow** (deterministic, since depth = length). That boundary is lower
  than the P1 `redisplay/long-line` entry's 50 KB because that entry calls
  `redraw-buffer` directly with the cursor at column 0 and wrap off, a shallower
  path; the T2 workload exercises the real editing path (redraw-display +
  wrap-on + cursor-at-end), which recurses deeper. "Workloads must NOT crash" is
  paramount over the specific 80 KB figure, so **16 KB** is used for a ~30%
  margin below the 24 000-char cliff. The kernel is **not** fixed here (out of
  P2 scope); the ≥ ~24 000-char single-object redisplay stays the OPT-candidate
  the P1 ledger already records.

- **The T2 result schema extends the PF-3 entry with three additive fields**
  (PF-5). PF-3 defines one entry shape — `{name, unit, min, median, p90,
  consed-per-op, n}` — for all tiers. T2 keeps it (the gated metric is **wall
  ms**: `unit` = `"ms/workload"`, `min/median/p90` = wall time, `consed-per-op`
  = bytes consed per workload, `n` = 1) and adds `gc-count`, `gc-pause-ms`, and
  `frames` alongside, since PF-5 mandates reporting GC count + pause total and
  frames rendered. These extra fields are additive metadata (like the baseline
  `band`); the gate reads only wall-ms. GC count is captured with a transient
  `*after-gc-hooks*` counter; pause total from the `sb-ext:*gc-run-time*` delta
  (internal-time-units = microseconds on SBCL, so `/1000` → ms); frames from the
  recording interface's `update-display` `:after` counter.

- **T2 measurement differs from T1: median-of-three, no GC suppression** (PF-5).
  Per the P2 task: median of **three** full workload executions per suite run
  (T1 uses nine), `gc :full` before each, one warm-up pass discarded. Crucially
  T2 does **not** raise `bytes-consed-between-gcs` to suppress GC (T1 does, to
  isolate wall time) — GC count and pause total are *reported metrics* of the
  realistic session, so natural GC behaviour is measured. Two hygiene measures
  keep the median-of-three gate stable: (1) **interleaving** the three timed
  passes round-robin across workloads (as T1), so a transient hits ≤ 1 rep per
  workload rather than clustering on two of a single workload's consecutive
  reps; (2) **sizing `long-line` to a ~450 ms window** (finer sweep stride, more
  edit points, the session repeated twice). A single long-line pass runs ~75 ms,
  small enough that one GC or scheduling hiccup is a > 20% swing that median-of-
  three cannot reject — an observed intermittent gate failure; the wider window
  makes noise proportionally small and the entry gates stably at the 20% band.

- **T2 rebaseline folds five suite runs; band floor 20%** (PF-5). Mirroring T1:
  the band is the spread of the five suite medians as a fraction of the
  aggregate median, floored at 20% (the same shared-workstation reasoning as the
  T1 `+bench-band-floor+` deviation above). No budget-gated workloads exist in
  T2 (the T1 telemetry-budget special case does not apply). Absolute T2 ms track
  the machine's steady-state load at baseline creation; the gate is median-vs-
  band on a matching fingerprint, so a per-machine rebaseline is the honest reset
  when the platform moves (Constraint 5).

- **`isearch` drives the real incremental-search engine per keystroke, not the
  interactive command loop** (PF-5). The P2 task allows this fallback explicitly:
  the interactive isearch loop (`lem/isearch:isearch-forward` → `isearch-start`
  installs a minor mode and then `read-key`s each keystroke, with a floating
  popup message) cannot run headlessly without a real input loop feeding key
  events. So the workload drives the *real* isearch engine at per-keystroke
  granularity rather than reimplementing it: for each prefix of the needle it
  calls the real `lem/isearch::isearch-update-buffer` (the exact visible-region
  search + highlight-overlay function `isearch-update-display` calls), then
  forces a redisplay; match stepping is the `isearch-next` path — the frozen
  `lem:search-forward` advancing the cursor match by match, scrolling the view
  (`window-see`) and re-highlighting per step. Only the minor-mode entry,
  `read-key`, and the popup message (input-loop / frontend-interactive, not
  search work) are not driven. Needles and hit counts are deterministic
  properties of the pinned `mixed-10m` generator: `"the"` (~34.7k hits, dense —
  match stepping capped at 250), `"attribute cache"` (~213 hits, sparse — long
  scans between hits), an absent needle (one full-buffer scan, no match). The
  buffer is a private `make-buffer` copy of the corpus, **not** `find-file-buffer`
  (which would return the *same* buffer object the `big-file` workload opens, so
  the two would collide).

- **`undo-storm` asserts its correctness canary in setup; RUN adds a trailing
  undo for replay** (PF-5). The task requires asserting "final buffer text equals
  post-edit text … outside the timed window". `t2-measure-once` times the whole
  RUN thunk, so the assert cannot live in RUN. It is therefore done once in
  `setup` (which is untimed and re-runs on every bench invocation): setup runs
  the exact 5k-edit sequence, records the post-edit text, does a full undo (→
  base) then full redo (→ post-edit), and asserts the redo result is
  byte-identical to the recorded post-edit text — proving undo/redo round-trips
  losslessly. For replayability the base text is seeded with undo **disabled**
  (so the seed is never on the undo stack; "start" = the seeded base), and RUN is
  net-zero: 5k edits → full undo (→ base) → full redo (→ post-edit) → a **final
  full undo** (→ base), ending exactly where it began so all three timed reps +
  the warm-up replay identically. The trailing undo is the only addition beyond
  the spec's "edits, undo, redo" session and exists solely for replay hygiene;
  it roughly doubles the undo work in the timed window, which is representative
  (undo/redo is what the workload measures) and deterministic. One undo group is
  recorded per edit (a `buffer-undo-boundary` after each), so the full undo/redo
  replays exactly 5k groups.

- **`overlay-heavy` edits are net-zero and the 2000 overlays persist across
  reps** (PF-5). The 2000 overlays (`make-overlay`, single- and multi-line,
  spread over the first 2000 lines of `lisp-500k`) are built once in setup and
  never deleted, so every rep runs with the full overlay set registered. The 500
  edits are net-zero (insert a char, delete it) — the same hygiene the T1
  edit/points entries and the T2 long-line workload use — so the text, and
  therefore every overlay point (which returns to its original position), is
  invariant and every execution renders the identical frame sequence. The edits
  sweep the same line band the overlays occupy and the view follows the cursor,
  so each of the 50 forced frames (one per 10 edits, per the task) has real
  overlays in the visible region to gather and paint; the per-edit cost is the
  relocation of the 4000 registered overlay points that lie after the edit.

- **`lisp-edit` uses lem-core's `calc-indent-default`, and undoes its edits to
  restore** (PF-5). The task calls for "lem-core's syntax/indent machinery"; the
  lisp-specific `calc-indent` lives in `lem-lisp-syntax`, whose load pulls
  micros/usocket, which the `:lem/core` bench image deliberately does not carry.
  So `newline-and-indent` indents via the default `calc-indent-function`
  (`calc-indent-default`, copies the previous line's indentation) — genuine
  lem-core indent machinery, no heavy deps. Structural motion uses the real
  lem-lisp-syntax **syntax table** (`extensions/lisp-syntax/syntax-table.lisp`,
  loaded directly — it depends only on `:lem`, unlike the rest of that system) so
  `forward-sexp`/`backward-sexp` (`form-offset`/`scan-lists`) match parens
  correctly; highlight attributes come from the lem-lisp-mode tmlanguage grammar
  (the same direct-load trick `scroll` and the T1 `syntax` entry use). `backward-sexp`
  is ~100× costlier per call than `forward-sexp` over dense real Lisp (its
  negative-count `form-offset` re-scans backward), so it dominates the sweep and
  the step count is sized for a bounded, gate-stable window, not raw motion
  volume. For replayability the corpus is inserted with undo **disabled** then
  undo enabled; the sexp sweeps are read-only and the `newline-and-indent` edits
  are undone at the end of RUN by draining the undo stack (which stops at the
  corpus base, since the corpus insert was not recorded), and each edit re-scans
  only the few lines it touched (`syntax-scan-region`), never the whole 500 KB
  buffer (a full re-scan per edit would be ~116 ms × the edit count).

### Milestone P3 (T3 end-to-end harness)

- **The keystroke `longline` scenario is a 16 KB single line, not PF-7's
  "200 KB line"** (PF-7). This is the same stack-exhaustion cliff the P1
  `redisplay/long-line` entry and the P2 `long-line` workload already record: a
  single text object ≳ 24 000 chars overflows the default control stack in the
  certified clip/wrap layout path (`verified/layout.lisp` `k-obj-width` →
  `k-sum`, a non-tail width fold whose recursion depth equals the line length).
  16 KB keeps the ~30% margin below the ~24 000-char cliff that the T2 long-line
  workload uses, so the scenario exercises the genuine long-line redisplay cost
  (its p50 is 8 ms, redisplay-dominated) without crashing the driven editor. The
  kernel is not fixed here (out of P3 scope); the ≥ ~24 000-char single-object
  redisplay remains the OPT-candidate the P1/P2 ledger already records.

- **Keys are driven ONE AT A TIME (~25 ms apart), not in fast bursts** (PF-7).
  PF-7 says "small sleep between bursts so the editor keeps up". The editor
  coalesces redisplay while input is pending (`interp.lisp`: redisplay only when
  `(= 0 (event-queue-length))`), which is the *correct* editor behaviour and the
  real keystroke-to-paint story — but a 20-key burst then paints once, so the
  end-to-end keystroke (t₄−t₁) histogram records ~1 sample per burst, not per
  key (measured: a 20-key burst → 4 keystroke samples). Pacing one key per
  ~25 ms lets the queue drain and each key paint, yielding ~one keystroke sample
  per key (measured: 120 keys → ~135 samples incl. the 20 wall-trend keys). This
  changes nothing about the editor; it is how a human types, and it is what makes
  the p95 a per-keystroke number.

- **The pipeline-wrapping proof is the queue-wait sample count, not the
  keystroke count** (PF-7). PF-7 asks the harness to FAIL loudly if "sample count
  … < ~N — the pipeline wrapping is broken". The definitive wrapping signal is
  `queue-wait_count`: `send-input-event` (ncurses) wraps every key in a
  `pipeline-event`, and `receive-event` records exactly one queue-wait sample per
  wrapped event on dequeue — so `queue-wait_count >= N` proves the wrap end to
  end (a broken wrap reads ~0), independent of redisplay coalescing. The harness
  hard-FAILs on `queue-wait_count < N` and additionally requires the keystroke
  paint count ≥ N/2 (a meaningful-p95 floor). The keystroke count alone would be
  the wrong gate: coalescing legitimately lowers it below N.

- **`LEM_HOME` is exported WITH a trailing slash** (PF-7, a bring-up finding).
  `(lem-home)` feeds `LEM_HOME` straight into `(merge-pathnames "metrics/"
  (lem-home))`; a value without a trailing slash parses as a *file* pathname
  whose final component `merge-pathnames` then strips, landing the metrics dump
  in the *parent* of the intended `lem-home` (observed: `$ROOT/metrics/` instead
  of `$ROOT/lem-home/metrics/`). The sandbox exports `LEM_HOME=$ROOT/lem-home/`
  so the dump lands where the harness reads it. This is a harness-side sandbox
  detail, not a Lem change (the frozen API is untouched).

- **"Cold" startup is the first run of the batch, not a dropped-page-cache cold
  start** (PF-7). PF-7 wants cold (first run) and warm (repeat) recorded
  separately. A true cold-cache start needs `echo 3 >
  /proc/sys/vm/drop_caches` (root); the harness records the first launch of the
  batch as "cold" and the median of the next 5 as "warm". On the daily-driver
  machine the ~415 MB image is already in the page cache from the build, so cold
  and warm read nearly identical (both ~190 ms) — honest for a warm working set,
  and the warm budget (< 2 s) is what PF-7 hard-gates.

- **In-image p95 is a log2-bucket estimate** (PF-7, a standing histogram
  caveat). The gated keystroke p95 comes from the T0 log2 histogram, so it is the
  upper edge of the crossing bucket (a power-of-two microsecond value): e.g. a
  true p95 of 9 ms reports as 16 384 µs (16.4 ms), and 20 ms reports as 32 768 µs
  (32.8 ms). This is the bounded error `metrics-report` already flags and is
  acceptable for a budget check (it never *under*-reports); the coarse wall
  trend is recorded alongside as an independent corroborating signal (and for
  `longline` the two agree: in-image p95 16.4 ms, wall p95 ~41 ms — both the
  clear pathological outlier). Budgets are "initial, revisable with a ledger
  entry" per PF-7; the current five all pass with margin.

- **T3 has no committed baseline; `run-bench.sh --rebaseline t3` is a
  documented no-op** (PF-7). Unlike T1/T2, a noisy wall tier has no meaningful
  band gate, so there is no `bench/baselines/*-t3.json`. `run-bench.sh` prints a
  short "not applicable" notice for `--rebaseline t3` and suppresses the generic
  "Rebaselined" epilogue when no gated tier was actually rebaselined. T3's trend
  history lives in the ledger's *T3 trend history* table above (Constraint 6:
  trends recorded in the ledger, not a committed baseline file).

- **The soak "`dynamic-usage` growth" signal is the FLOOR (post-GC trough)
  trend, not a raw least-squares fit** (PF-8). PF-8 says "flags monotonic heap
  growth (linear fit over the second half ... RSS and `dynamic-usage`)". Measured
  reality on this editor: idle-timer `dynamic-usage` sawtooths ±hundreds of MB
  per GC cycle (a clean editing soak swings ~305↔530 MB), so a least-squares fit
  over raw samples catches whichever GC phase the ~10 s sampling lands on and
  false-flags a flat run. The retained memory is the lower envelope, so the
  detector compares the MINIMUM of the first half vs the second half (a
  `dynamic-usage` reading can never be below the live set, so the min is a safe
  floor estimate that never spuriously undershoots) and flags on the floor's
  growth rate. This is the honest reading of "monotonic heap growth" for a
  generational collector; measured ~0.1 MB/min on a clean soak, cleanly rising
  under an injected leak.

- **The soak "RSS growth" signal is a robust median-of-halves rate, not a
  least-squares slope** (PF-8). SBCL munmaps memory back to the OS after full
  GCs, so external RSS sawtooths downward; a least-squares slope over the second
  half is dominated by whichever munmap falls in it (measured: a clean run's
  second-half LS slope swung to −47 MB/min while total RSS was flat). The
  detector uses `median(2nd half) − median(1st half)` over their time
  separation, which those outlier dips cannot flip.

- **On a SHORT run, RSS alone cannot discriminate a leak; the DU floor is the
  discriminator and RSS is the required corroboration** (PF-8). Warm-up arena
  growth (~250 MB as the 10 MB file loads and the heap reaches working size)
  dominates RSS on a short run and is present with or without a leak, so RSS's
  short-run growth does not separate the two. The verdict therefore ANDs the
  sensitive, GC-noise-free DU-floor rate with the RSS rate: a clean run is
  vetoed by its flat DU floor regardless of RSS noise, and a leak must move
  BOTH. Consequently the leak-detector self-test injects a deliberately LARGE
  leak (4 MiB per idle second, hundreds of MB) so it clears the RSS noise
  unambiguously and exercises the full "RSS AND DU" gate — the magnitude proves
  the mechanism; the far more sensitive DU floor is what catches a small real
  leak on the 30-min soak.

- **The injected self-test leak is an IDLE timer, not a regular timer** (PF-8).
  A regular timer firing every second keeps the editor from ever being idle for
  the metrics heap idle-timer's 10 s period, starving the very `dynamic-usage`
  samples the detector reads (measured: 2 samples over a 200 s run). An idle
  timer is serviced during the idle rests alongside the metrics sampler (idle
  timers fire without leaving the idle loop), so the leak grows AND the heap
  ring still samples it.

- **The soak verdict is a trend, never a commit gate** (PF-8, consistent with
  PF-7). The optional `LEM_T3_SOAK=1` stage reports the verdict loudly but never
  flips `run-t3.sh`'s exit; only the in-image keystroke/startup budgets hard-fail
  in T3. A genuine leak suspect on the real soak is recorded as a P4 backlog
  candidate (with its data), not fixed here and not a red commit — PF-8's
  done-when is "one full soak recorded and analyzed" plus "the detector catches
  an injected leak", both satisfied without gating on the noisy wall tier.

- **The soak's `longline`-class pathology is avoided; the soak edits the 10 MB
  file, not a >24 000-char single line** (PF-8, inheriting the P1/P2/P3 cliff).
  The soak workload never constructs a single line past the ~24 000-char
  redisplay stack-exhaustion cliff (it edits within the `mixed-10m` corpus and
  inserts short strings), so the 30-min run cannot hit the known crash.
