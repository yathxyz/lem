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

### Bug fixes (out-of-band correctness, NOT P5 optimization entries)

| Item | Date | Fingerprint | Evidence | Change | Before → After | Notes |
|------|------|-------------|----------|--------|----------------|-------|
| OPT-1 crash fix (commit `86291785`) | 2026-07-19 | ex44 / i5-13500 / 20c | P1/P2/P3 deviations (the ~24k redisplay cliff); mapping probe at the pre-fix HEAD: `redraw-buffer` of a single line overflows at **50 651** chars (wrap off) / **50 653** (wrap on), backtrace ~99% `ACL2::K-SUM` frames; `redraw-display` full command path crashed at **24 000** (P2 measurement) | `verified/layout.lisp`: `k-sum`, `k-firstn`, `k-clip-chars` — the three render-path recursions with depth = line length — converted to ACL2 `mbe` with tail-recursive accumulator `:exec` twins (`k-sum-acc`, `k-firstn-acc`, `k-clip-chars-acc`), proved equal to the unchanged `:logic` recursions at guard verification; shim learned `mbe` (expands to `:exec`, matching ACL2's guard-verified execution) + `verify-guards` (no-op) — see `verified/README.md`. All 12 books recertified; no theorem statement changed | crash at ≥ 24k chars (editor CRASH, deterministic) → **500k-char single line renders clean** in every config (wrap on/off × cursor start/mid/end); 300k pinned by the new rove suite `tests/pbt/long-line-render.lisp` (kernel-oracle content equality + exec-twin = naive-recursion PBT) | **Bug fix, not an optimization** — P5 remains gated on the T0 field week. T1/T2/T3 long-line workload sizes and budgets unchanged (16 KB / 50 KB caps kept for baseline comparability; see the updated deviation notes). t1/t2 gates PASS vs the committed baselines after the fix (no entry outside band) |

### Optimizations (OPT-n)

_None yet. P5 must not start before the P4 grounding report (SPEC-PERF). (The
OPT-1 crash was fixed out-of-band as a correctness bug fix — see the Bug fixes
table above — not as the start of the P5 loop.)_

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

**OPT-1 — Long-line redisplay stack-overflow cliff (correctness-grade). — ✅ FIXED
2026-07-19 (out-of-band bug fix; see the *Bug fixes* ledger table).**
- *Measurement (historical):* a single text object ≳ **24 000 chars** overflowed the
  default SBCL control stack during redisplay — deterministic (recursion depth = line
  length), confirmed by three independent harness findings: the P1 `redisplay/long-line`
  deviation (crash between 50 k and 100 k chars), the P2 `long-line` deviation (renders
  at 23 000, crashes at 24 000 with wrap-on + cursor-at-end), and the T3 `longline`
  scenario cap. The shipping `./lem` binary uses the same default stack, so **this was
  a real editor crash**, not a bench artifact. The same frame shows as raw CPU: `K-SUM`
  #10 (long-line 7.5% / scroll 5.0% self).
- *Root cause (as mapped by the fix's probe):* three `verified/layout.lisp` recursions
  with depth = line length on the render path — `k-obj-width` → `K-SUM` (every width
  measurement; the frame filling ~99% of the overflow backtrace), `K-FIRSTN` (explode
  halving, wrap path), `K-CLIP-CHARS` (per-char clip scan, horizontal-scroll path).
- *Fix:* the three folds are now ACL2 `mbe` definitions — unchanged `:logic` recursion
  (every theorem re-certifies), tail-recursive accumulator `:exec` twins proved equal
  at guard verification and executed in-image via the shim's `mbe` reinterpretation.
  Before → after: crash at ≥ 24k (command path) / 50 650 (`redraw-buffer`) → clean at
  500k in every wrap/cursor config; 300k pinned by `tests/pbt/long-line-render.lisp`.
- *Verification (done):* full 12-book recertification (`run-proofs.sh`), full rove suite
  incl. layout-conformance + screen-projection + the new long-line pin
  (`run-tests.sh`), t1 + t2 PASS vs the committed baselines, `make ncurses`. Bench
  long-line sizes/budgets deliberately unchanged (perf-motivated now, not
  crash-motivated — resizing awaits OPT-2/OPT-6 and the T0-reconciled report). The
  residual *CPU* cost of the width path stays tracked by OPT-2/OPT-6.

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
  **UPDATE 2026-07-19: the crash is FIXED** (OPT-1 bug fix — mbe tail-recursive
  layout folds; see the *Bug fixes* ledger table and
  `tests/pbt/long-line-render.lisp`, which pins a 300k-char render). The 50 KB
  entry size is **kept** for baseline comparability — a perf/rebaseline
  decision pending OPT-2/OPT-6, no longer a crash cap.

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
  **UPDATE 2026-07-19: the cliff is FIXED** (OPT-1 bug fix, *Bug fixes* ledger
  table; 300k-char render pinned by `tests/pbt/long-line-render.lisp`). The
  16 KB workload size and its committed baseline are **kept** — comparability,
  not a crash cap; resizing awaits OPT-2/OPT-6.

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
  **UPDATE 2026-07-19: the cliff is FIXED** (OPT-1 bug fix, *Bug fixes* ledger
  table). The 16 KB scenario is **kept** so the longline p95 trend rows stay
  comparable; resizing is a perf decision for OPT-2/OPT-6, no longer a crash
  cap.

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
  **UPDATE 2026-07-19: the cliff is FIXED** (OPT-1 bug fix, *Bug fixes* ledger
  table); the soak workload is unchanged (it was shaped around realism, and the
  avoidance note is now historical rather than load-bearing).

## 2026-09-19: typing latency audit

Compared worktree changes with `377d94cf3` on Nova (Ryzen 9 9950X3D),
Nix 2.34.8 and SBCL 2.5.10, using the locked Nix shell and Qlot dependencies.
No installed editor profile or running editor was changed.

Three avoidable costs were fixed:

- Each insertion/deletion scanned the whole buffer twice just to detect a
  content change. The mutation scope now compares the source line length and
  line count, preserving detection on exceptional exits and ignoring empty edits.
- Edits calculated an absolute undo position even with undo disabled or during
  replay. Skipping unused positions removes quadratic line-by-line file loading.
- The daemon SDL client slept 10 ms between polls. It now waits for input and
  explicit screen/error notifications, coalescing pending messages. Rendering
  skips cell backgrounds already painted by the initial clear, after resolving
  inverse video and cursor colors.

### Measurements

| Workload | Before | After |
| --- | ---: | ---: |
| Load 10,000 lines (500 KB), median | 2,129 ms | 49 ms |
| Insert/delete pair, undo enabled, boundaries after each edit, buffer start | 0.300 ms | 0.005 ms |
| Same pair, buffer end | 0.600 ms | 0.315 ms |
| SDL socket-to-presentation, styled 100×40 Unicode screen, median | 8 ms | 2 ms |
| SDL socket-to-presentation, p95 | 12 ms | 2.001 ms |

The edit benchmark discards one warmup, then takes the median of three runs;
edit samples contain 200 pairs. SDL uses 120 updates after the initial frame,
a private socket peer, the real graphical event loop, and SDL's dummy video
backend/software renderer. Times end after `SDL_RenderPresent` returns; these
are not physical keyboard-to-monitor measurements. Scheduling outliers remain
(the final SDL run's maximum was 27 ms). Before/after rendered pixel dumps were
identical, including colored backgrounds, inverse video, underlining, and Unicode:
SHA-256 `0be3e7682a118983994adc6e6bdb43ab23a0ed9f4dc4a6809b9bae5fb37c165e`.

Reproduce after `nix develop`, `qlot install`, and
`./scripts/prepare-dependencies.sh`:

```sh
sbcl --dynamic-space-size 4GiB --noinform --no-sysinit --no-userinit --non-interactive \
  --load .qlot/setup.lisp --load scripts/bench/e2e/edit-latency.lisp
SDL_VIDEODRIVER=dummy sbcl --noinform --no-sysinit --no-userinit --non-interactive \
  --load .qlot/setup.lisp --load scripts/bench/e2e/sdl-presentation.lisp
```

For A/B runs, export `LEM_EDIT_SOURCE` or `LEM_SDL_SOURCE` pointing to the old
`buffer-insert.lisp` or `sdl-client.lisp` extracted with `git show`. Optional
`LEM_SDL_PIXELS` writes the second rendered frame as raw ARGB8888 pixels for
comparison. Internal package access in these harnesses deliberately exercises
and instruments the production client and edit implementation.

### Validation and remaining findings

- Cold test loading exposed a search-order bug for package-inferred dependencies
  (`rove/main`, `jsonrpc/main`); the runner now preserves that resolver's priority.
  The T2 Lisp fixture also called `find-symbol` on packages before loading them;
  its package-existence guards were corrected.
- Graphical-client tests pass, including FIFO batching, wakeups on reader errors,
  queue overflow reporting, and reader cancellation. Core edit-generation tests
  and the baseline/paranoid/conformance edit-engine fuzz suites pass.
- `nix build .#checks.x86_64-linux.native-client-display` passes with the final
  core and SDL changes. Its 15 runtime checks cover shared terminal/SDL editing,
  Vi and prompt ownership, Unicode paste, resizing, crashes, and disconnects.
  The Xvfb screenshot was also inspected; this does not establish physical
  display latency or update the installed profile.
- The full core run passes 69 of 75 suites. The same six suites fail with the
  original edit implementation: kernel-undo-conformance, layout-conformance,
  redisplay-cache, MCP integration, emergency-save, and display-cache. This is
  not a clean full-suite result; those failures need separate investigation.
- Six T2 workloads completed with bounded diagnostic setup/execution: big-file,
  isearch, Lisp editing, long lines, overlays, and scrolling. Their respective
  medians were 3,322 / 1,815 / 327 / 303 / 349 / 790 ms per workload. No matching
  Nova baseline was available; no existing baseline was replaced.
- Absolute positions for retained undo edits still walk preceding lines, so
  typing near the end of a large file remains slower. Undo also validates tree
  structure and copies/simulates complete buffer contents; its integrity checks
  were preserved. The 5,000-edit undo-storm workload exceeded a 30-second
  per-execution diagnostic limit inside `validate-undo-tree` during undo;
  no complete result or passing full T2 suite is claimed.
- This audit covers the shared edit path and native client presentation. The
  user's precise frontend/configuration and physical input-to-display latency
  have not been established.

### Follow-up: cached absolute positions

On `main`, absolute position queries now reuse a nearby line's start offset.
An insertion/deletion on that line preserves its prefix, so repeated typing
does not traverse the preceding lines again. Buffer edit ticks and a low-level
line generation invalidate other anchors, including renderer writes through
`set-line-string` that bypass normal edit bookkeeping. The line generation is
conservative across buffers; edits in another buffer can cause a fresh scan.

The same 10,000-line benchmark measured 51 ms to load and 0.005 / 0.010 ms
per insert/delete pair at the start/end respectively (previous end: 0.315 ms).
These tiny samples have millisecond timer granularity; the useful result is
the removal of repeated whole-prefix traversal, not sub-microsecond precision.

Independent text traversal checks every tracked point after generated edits,
undo and redo. Explicit tests cover undo-disabled edits, inhibited undo,
erase/reinsert, and raw renderer replacements of different lengths. They pass,
as do all 15 native-client runtime checks. The full core suite still has the
same six previously recorded failures; no additional suite failed.

### Follow-up: exact undo text verification

Undo's exact text comparison now compares each line with the corresponding
string slice and explicitly verifies intervening newlines. It still checks
the complete text and length, including replay-hook mutations, without moving
a temporary point once per character. No undo integrity check was removed.

`scripts/bench/e2e/undo-text.lisp` measures 20 comparisons and 20 undo/redo
pairs on a 10,000-line (500 KB) buffer per trial, with one warmup and three
measured trials. On the same machine, median exact comparison dropped from
26.400 to 0.200 ms; a complete undo/redo pair dropped from 111.051 to 5.450 ms.
Each trial asserts the final buffer text. Additional tests reject shorter,
longer, and equal-length changed strings, including altered newline boundaries,
empty lines and Unicode. The full core suite has the same six known failures.

### Follow-up: retained undo route allocation

The validator now sizes its temporary visited-node table from the owned tree.
After full validation, ordinary one-edge undo/redo routes avoid constructing
complete ancestor lists and hash tables. General branch navigation still uses
the existing route finder. A corruption regression confirms that even a bad
parent link outside that one-edge route is rejected before changing text.

A diagnostic using the T2 generator's 5,000 mixed edits, followed by full undo
and redo with exact text assertions, was sampled with SBCL's CPU profiler at
2 ms intervals. Undo/redo took 5.075 / 5.014 seconds before these two changes
and 2.735 / 2.767 seconds after; allocation fell from 13.88 / 13.96 GB to
1.50 / 1.54 GB. These are individual profiled executions, not a benchmark band.
The final profile attributes about 79% of inclusive sampled time to full tree
validation. That remains linear in retained history per move; removing it
would require a different validation design, not simply bypassing checks.

All 83 real-terminal Vundo checks and all 15 native-client display checks pass
with the final core changes. The full core run retains the same six known
failures. No installed editor or mutable Nix profile was changed.

### Follow-up: complete T2 replay and fixture correction

The unmodified replay fixture retained another 5,000 undo nodes after each
sample: returning to the base text does not discard retained branches. Its
three undo-storm samples took 21.7 / 29.1 / 36.0 seconds, so they did not measure
an identical starting state. The workload now clears its private buffer's
history at the beginning of each run, including that reset in the timed work.
This is a benchmark correction, not an editor speedup; older undo-storm results
must not be compared as if the fixture had stayed unchanged.

The corrected full T2 run completed setup canaries, one warmup, and all three
interleaved measured runs. Final medians on Nova:

| Workload | Median ms/workload |
| --- | ---: |
| big-file | 3,422 |
| isearch | 1,879 |
| lisp-edit | 294 |
| long-line | 316 |
| overlay-heavy | 361 |
| scroll | 832 |
| undo-storm | 8,601 |

Undo-storm's measured range is now 8,595–8,633 ms. Results are recorded in
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t2-20260919112521.json`.
The runner exits 2 because no matching Nova baseline exists, after writing
all results; this is a completed measurement, not a passing regression gate.
No committed baseline was replaced.

Vundo validation also exposed missing native-agent certificate configuration
in the Nix test environment. Checks now receive the launcher's curl and CA
bundle settings. The fixture reports the original configuration error, and
the shell driver exits after a boot failure instead of cascading through tests.

### Follow-up: sparse syntax checkpoints and cache correctness

The Lisp-editing CPU profile attributed about 54% of sampled time to syntax
parsing requested by backward form movement. Descending queries before the
earliest cached position repeatedly reparsed the entire buffer prefix. Parsing
now records a checkpoint every 64 lines, so later queries can resume nearby.

Differential tests also reproduced an existing cache bug in the original
parser: a query inside a multi-character delimiter or escape could cache a
state that could not resume at that position. For example, querying between
`|` and `#` in a block-comment closer could leave the next query inside the
comment after it had ended. Only resumable positions are now cached; line
comments retain their valid constant state through the rest of the line.

Matched filtered T2 Lisp-editing runs measured 280 ms with the original parser
and 147 ms with safe checkpoints (72 frames in each workload). Allocation was
439 MB and 421 MB respectively. These workloads include structural movement,
indentation, scanning, rendering and undo; they are not single-keystroke times.
The original parser was loaded from `d3d50ec7e` for the otherwise identical A/B
run. No baseline band was regenerated.

Fresh parses agree with cached results through multiline strings, escaped
quotes, nested comments, Unicode, edits before/after checkpoints, and undo.
All 21 real-terminal structural-editing checks and 15 native-client checks
pass. The full core suite retains its same six previously recorded failures.

The final complete T2 run also finished all seven workloads. Medians in the
same table order above were 3,413 / 1,863 / 152 / 310 / 360 / 829 / 8,505 ms.
Its result file is
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t2-20260919113615.json`.
The exit-2 missing-baseline qualification still applies.

### Follow-up: display-cache correctness

Differential redraw tests reproduced stale equal-width gutter labels: the
horizontal-scroll fingerprint omitted the gutter's contents. It now hashes
the gutter text and attributes, allowing equal newly constructed gutter
records to keep cache hits while changed labels invalidate them.

Image drawing-object comparison also compared each field with itself, hiding
changed images or dimensions. It now compares the two objects. Images are no
longer merged: the old merge discarded the second adjacent image, even when
the images differed. Regression tests cover identity, dimensions and adjacency.

Three existing test fixtures were stale: fingerprint callers omitted the new
right-margin argument, and the layout mock lacked the required character-width
method. Updating those fixtures brings the full core suite to 72 of 75 passing
suites. The remaining failures are kernel-undo-conformance, MCP integration
and emergency-save. All 15 native-client display checks pass after these fixes.
Image tests exercise comparison and reduction, not physical image rendering.

The first T3 terminal run measured input-enqueue-to-core-paint p95 at 1.024 ms
for a small buffer, 2.048 ms for a 10 MB file and scrolling, and 16.384 ms for a
16 KB single line. These are histogram bucket values, not physical monitor
latencies. Warm startup was 2,142.646 ms, exceeding its 2,000 ms budget, so the
overall run failed its gate. Results are in
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919114354.json`.

### Follow-up: packaged startup and SBCL's library directory

Tracing startup found over one million `readlink` calls. In the saved Nix
executable, `(sb-int:sbcl-homedir-pathname)` returned `#P"./"`; ASDF's wrapping
source registry consequently scanned the launch directory recursively. In
this checkout that includes `.direnv/flake-inputs` and the Nixpkgs source tree.
The cost depends on the directory from which the editor is launched.

Nix executable wrappers now set `SBCL_HOME` to the matching SBCL installation.
This corrects the implementation-library location without disabling the user's
ASDF source registry. The base wrapper also covers webview; terminal, SDL,
daemon-client and recovery executable wrappers receive the same setting.

A rebuilt terminal executable measured 288.677 ms median warm startup (five
runs), versus 2,142.646 ms before the fix in this checkout. All four keystroke
p95 buckets remained unchanged, and the complete T3 run passed every budget:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919115118.json`.
All 15 native-client display checks also passed with the rebuilt launchers.
These measurements use isolated configuration and do not imply a change to
the installed user profile. The syscall trace was diagnostic only; its large
instrumentation overhead is excluded from the reported comparison.

Two more baseline failures were outdated fixtures. Emergency checkpoint tests
now enable checkpoint mode and verify that disabling it prevents legacy
checkpoint writes. The MCP CRUD test now checks that deletion refuses unsaved
changes and preserves the text, then checks deletion of a clean buffer. The
full core suite now passes 74 of 75 suites. The remaining
`kernel-undo-conformance` failure predates this performance work; the certified
linear undo model and current production undo behavior still need reconciliation.

### Follow-up: inline the small verified width functions

A T2 long-line CPU profile attributed about 40% of samples inclusively to
`string-width`, with substantial per-character call and generic-arithmetic
overhead. The Common Lisp shim now requests inlining for `natp` and the four
small width/control helpers. Callers' existing character/fixnum declarations
can specialize their arithmetic. The certified definitions are unchanged;
the large Unicode decision trees stay out of line.

The kernel's ASDF system now tracks the source files read indirectly by its
loader. A fresh-image check confirmed that touching `verified/width.lisp`
recompiled the cached `string-width-utils` caller. Kernel books still use their
existing load-once behavior within an already-running image.

Matched filtered T2 long-line runs measured 316 ms before and 215 ms after a
fresh source build, with 172 frames in both workloads. Allocation remained
about 172 MB. The standard T3 long-line p95 stayed in the same 16.384 ms
histogram bucket, so this is a replay CPU improvement, not a demonstrated
improvement in that end-to-end p95 metric. All standard T3 budgets passed:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919115533.json`.

All 12 ACL2 books certified successfully with ACL2 8.6 and the required
community books built from the flake's pinned Nixpkgs. All 15 native-client
checks passed, and the full core suite retained only the previously recorded
undo-model conformance failure. No proof definition or safety setting changed.

A separate 200,000-byte single-line experiment used the T3 scenario driver
with the full `long-line-200k.txt` corpus, 120 keys paced 100 ms apart, and 20
wall-clock trend samples. Its input-to-core-paint p95 was 131.072 ms (138
recorded paints), exceeding the 30 ms budget. This larger workload is not
comparable to the standard 16 KB trend. A separate instrumented run collected
12,469 CPU samples, about 98% inclusively in `redraw-display`: multiple redraws
occur through command reading, hooks, timers and the command loop. Text
insertion itself accounted for less than 1%. Redundant rendering remains an
open performance target; histogram command time includes some of those redraws.

The complete interleaved T2 run after inlining finished with medians of 2,691 /
1,487 / 148 / 231 / 340 / 657 / 8,479 ms for big-file / isearch / lisp-edit /
long-line / overlay-heavy / scroll / undo-storm respectively. Results are in
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t2-20260919115930.json`.
As before, the runner exited 2 after writing all results because the matching
Nova baseline is absent; no committed baseline or gate was changed.

### Open investigation: transient redraws and viewport restoration

The 200 KB profile identified two full redraws during ordinary input from
`hide-transient`, even when no transient menu exists: one through keymap
activation and one through the post-command hook. An experimental conditional
redraw reduced the standard T3 16 KB long-line p95 bucket from 16.384 to
4.096 ms, but **the experiment was reverted**. Vundo's direct-window-delete
and related rollback cases then restored the text and point but changed the
saved viewport (one reproduction changed its absolute view position from
404 to 428). Retaining redraws for an active bottom pane, or for the core's
frame-redisplay flag, did not resolve the failures. The original redraw
behavior passed the Vundo checks in a matched build.

The experimental result file
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919120641.json`
does not describe retained code and must not be used as a speedup claim for
the current branch. The layout/viewport dependency needs to be resolved before
this optimization can be reconsidered. At that checkpoint, main retained the
validated width inlining and unconditional transient redraw behavior.


### Resolving the transient redraw dependency (2026-09-19)

Tracing the original failure identified an independent bottom-pane lifecycle
bug. Direct `delete-window` removed a bottom pane without clearing its frame
owner or restoring the reserved height. Vundo cleared the owner in its deletion
hook, but the main window stayed at height 47 instead of 50. Its restored view
position 404 then moved to 428 when Vi adjusted scrolling to the stale height.
Core now clears the bottom-pane owner and balances windows before deletion
hooks run. `delete-bottomside-window` delegates to that common path, and no
longer clears a replacement pane created by a deletion hook. Vundo no longer
needs to detach the owner itself. New core regression cases failed before this
fix and pass afterward, including replacement-pane ownership.

With layout restoration explicit, `hide-transient` now redraws only when it
had visible popup/mode state to remove. It still cancels pending delayed menus
and performs ownership/mode cleanup on every call. This removes two full
redraws per ordinary command, from keymap activation and post-command handling.
Recording-frontend tests cover absent menus, closing visible menus, repeated
hiding, delayed timer cancellation, and active mode state without a popup.

The Vundo prior-bottom-pane fixture now snapshots the source point/view after
installing that pane, immediately before opening Vundo. Its old assertion used
a snapshot from before the layout change: opening a five-row pane can
legitimately scroll the source to keep its cursor visible. The test still
requires exact entry-point/view restoration and exact restoration of the
borrowed pane's buffer, height, point, view, cursor visibility and horizontal
scroll. All 83 Vundo checks and all 15 native client/display checks pass in the
rebuilt runtime (`/tmp/lem-layout-validated.log`). The core suite remains 74/75,
with only the previously documented kernel-undo model mismatch; transient unit
tests pass. No verified kernel definition changed in this step.

Standard T3 passed all budgets, with warm startup 287.058 ms and input-to-core-
paint p95 buckets of 1.024 / 2.048 / 8.192 / 1.024 ms for plain / big-file /
16 KB long-line / scroll. The preceding retained width-inlining build's
long-line bucket was 16.384 ms. The new result is
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919121846.json`.

The separate 200 KB stress scenario (120 keys at 100 ms intervals, plus 20 wall
trend samples) improved from 131.072 to 32.768 ms at p95, with 140 recorded
paints. Command p95 fell to 1.024 ms; redisplay p95 remains 32.768 ms. This still
fails the 30 ms budget. Results: `/tmp/lem-layout-200k.log` and
`/tmp/lem-layout-200k.kv`. These are quantized internal timing buckets, not
physical keyboard-to-monitor latency. The cost of one full long-line redraw
remains an open optimization target. No installed editor/profile was changed.


### Printable ASCII width fast path (2026-09-19)

After removing idle transient redraws, a new 200 KB typing profile collected
7,405 samples. `text-object-char-widths` accounted for 30.5% inclusive time;
Unicode width classification still ran for every printable ASCII character.
The verified `k-char-width` now handles codes 32-126 before those table walks,
while preserving two-cell advances for dynamically registered ASCII icons.
`printable-ascii-width-classification` proves the range is outside all three
Unicode tables and the control range; `k-char-width-ascii-fast-path-equivalence`
proves equality to the complete original branch order. The fast path lives in
the certified source, not in a separate unchecked shell implementation.

All 12 books certified (`/tmp/lem-ascii-proofs.log`), including both new
obligations. The core suite is still 74/75 with the known undo-model mismatch;
new tests cover every printable ASCII code at multiple columns and both
ambiguous-width settings, registered ASCII icons, `wide-index` behavior,
and the adjacent control codes. All 15 native display checks passed in the
rebuilt runtime (`/tmp/lem-ascii-native.log`).

Matched filtered T2 long-line runs improved from 219.001 to 172.000 ms, with
result files ending `t2-20260919122355.json` and `t2-20260919122603.json`.
The short T1 windows were too sensitive to timer granularity: an apparent
emoji regression was one clock tick. A longer matched probe used five timed
repetitions after a discarded warm-up, 5,000 width calls per 4,000-character
ASCII/CJK/emoji string and 500 per mixed corpus. Medians in microseconds per
call were ASCII 51.6 -> 30.2, CJK 44.8 -> 45.2, emoji 49.4 -> 49.8, and mixed
848.006 -> 730.006 (`/tmp/lem-width-long-before.csv` and
`/tmp/lem-width-long-after.csv`). CJK and emoji differences were below 1%, unlike the short run's apparent
regression.

The committed T1 width entries now use 2,000/80 iterations instead of 180/12
so their timed windows stay above 10 ms after these improvements. This changes
measurement duration, not workload text or units; no baseline was regenerated.
The longer standard T1 medians were 29.000 / 43.501 / 46.001 / 700.000 us for
ASCII / CJK / emoji / mixed, recorded in
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t1-20260919122914.json`.

Standard T3 again passed every budget: warm startup 287.083 ms; plain / big-file
/ 16 KB long-line / scroll p95 buckets 1.024 / 1.024 / 8.192 / 1.024 ms, in
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919122803.json`.
The separate 200 KB stress p95 remains in the 32.768 ms bucket and still misses
the 30 ms budget (`/tmp/lem-ascii-200k.log`, `/tmp/lem-ascii-200k.kv`). Thus this
step reduces measured rendering work but does not demonstrate a further
input-to-paint p95 bucket improvement. Repeated width scans and construction
of full-line kernel lists remain targets; installed profiles are unchanged.

The final full T2 replay completed all workloads and canaries. Medians were 2,192.015 / 1,213.007 / 139.001 / 186.001 / 339.001 / 571.004 / 8,350.052 ms
for big-file / isearch / lisp-edit / long-line / overlay-heavy / scroll / undo-storm respectively.
Results: `bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t2-20260919122921.json`.
T1/T2 still exit 2 after writing results because no matching Nova baseline is
committed; this is not a passing regression gate. No baseline or budget changed.

### Single-pass character widths and bounded word-wrap scans (2026-09-19)

The display adapter now collects character-width deltas and their total in one
pass, reusing the resulting list for pixel scaling or the non-cell-aligned
fallback. Matched filtered T2 long-line medians improved from 174.001 to
167.001 ms (results ending `t2-20260919123114.json` and
`t2-20260919123231.json`). Explicit cases cover tabs, combining marks, CJK,
ambiguous widths, pixel scaling, zero widths and newline resets.

The word-wrap adapter previously reconstructed the entire remaining logical
line for each physical row. It now materializes only through the first
character exceeding the row width, which preserves the hard-boundary lookup.
It still checks all object metadata, including unsupported objects beyond the
prefix, and leaves the full drawing records intact. Random differential tests
compare full-string and prefix boundary results; direct cases cover bounded
allocation, combining marks, fitting runs and unsupported trailing objects.
No verified kernel definition changed.

The fork configures horizontal truncation by default and word-boundary wrapping
when wrapping is enabled. The original T3 used bare Lem's ordinary wrapping.
Two additional 16 KB scenarios now exercise the configured display settings;
they do not load the entire user profile. The separate configured screen-line
check does, and all 27 checks pass. All 15 native display checks also pass;
the core suite remains 74/75 with only the documented pre-existing undo-model
mismatch (`/tmp/lem-word-prefix-check.log`, `/tmp/lem-word-prefix-tests.log`).

Matched 200 KB word-wrap stress runs improved from a 262.144 to a 32.768 ms
input-to-core-paint p95 bucket. Each sent 120 keys at 100 ms intervals plus
20 wall-trend samples; recorded paints increased from 133 to 140 because the
old path coalesced some updates. This still misses the 30 ms budget. Logs and
metrics are `/tmp/lem-word-wrap-200k-before.{log,kv}` and
`/tmp/lem-word-wrap-200k-after.{log,kv}`. These are quantized internal timings,
not physical keyboard-to-monitor latency. The matched 16 KB word-wrap p95
improved from 16.384 to 4.096 ms.

Expanded standard T3 passes all budgets: warm startup 286.134 ms; plain /
big-file / long-line / scroll / truncate / word-wrap p95 buckets are
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms. Results:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919123821.json`.
The final full T2 completed all workloads and canaries, with medians of
1,955.006 / 1,165.003 / 132.000 / 166.000 / 326.000 / 508.000 / 8,335.026 ms
for big-file / isearch / lisp-edit / long-line / overlay-heavy / scroll /
undo-storm. Results:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t2-20260919123941.json`.
T2 still exits 2 because the Nova baseline is absent, not because a workload
failed; this is not a passing regression gate. No baseline, budget or installed
editor/profile changed.

### Constant-time split eligibility (2026-09-19)

A fresh 200 KB ordinary-wrap profile collected 4,002 CPU samples; `acl2::len`
accounted for 11.2% self time (`/tmp/lem-current-wrap-profile.txt`). Before
halving an overflowing text run, `k-wrap-row` counted the complete code list
just to test whether it contained at least two characters. It now checks the
first two cons cells. The separate length calculation needed to choose the
halving point remains unchanged.

The local theorem `two-conses-iff-length-exceeds-one` proves the condition
equivalent, including improper lists and atoms. A local positive-length lemma
supplies the arithmetic fact needed by the existing termination argument.
The layout book certified independently (`/tmp/lem-split-layout-proof.log`);
the final all-book pass certified the other 11 and skipped that current layout
certificate, with zero failures (`/tmp/lem-split-final-proofs.log`). Existing
content, width, blocking and termination obligations remain intact.

An isolated comparison loads the previous `k-wrap-row` under a distinct name
and compares it with the new function in the same SBCL process. Both produce
identical 50-row output for a 200,000-character ASCII run at width 200. After
10 warm-up frames per function, five alternating before/after windows of 100
frames each measured medians of 6.890 -> 5.930 ms/frame, about 14% less kernel
wrapping time. Ranges were 6.790-6.980 and 5.840-6.040 ms respectively;
allocation stayed at approximately 14.92 MB/frame. This isolates wrapping,
not the full input-to-paint pipeline (`/tmp/lem-split-probe.{lisp,log}`).

The core suite remains 74/75 with the existing undo-model mismatch. All 15
native display and 27 configured screen-line checks pass
(`/tmp/lem-split-tests.log`, `/tmp/lem-split-check.log`). The checked runtime
contains the final executable definition; the later positive-length lemma is
proof-only. No installed editor or profile changed.

Matched filtered T2 long-line medians improved from 166.000 to 156.001 ms
(results ending `t2-20260919124350.json` and `t2-20260919124944.json`). T2
still exits 2 because no matching Nova baseline is committed; no baseline or
budget changed. Standard T3 passes all six typing scenarios: warm startup
285.594 ms; plain / big-file / long-line / scroll / truncate / word-wrap p95
buckets remain 1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms. Results:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919124951.json`.

The 200 KB word-wrap stress comparison at the harness's default 25 ms key
spacing recorded the same 65.536 ms input-to-core-paint p95 bucket before and
after, both while validation ran and after it finished. The latter runs
recorded 130/133 paints (`/tmp/lem-split-idle-200k-{before,after}.{log,kv}`).
That cadence is faster than the 100 ms spacing used by the previous stress
investigation, so those buckets cannot establish a regression against its
32.768 ms result. Scenario logs now print key spacing alongside key count.

A subsequent matched pair explicitly set `E2E_PACE=0.1`: both builds recorded
140 paints and the same 32.768 ms p95 bucket
(`/tmp/lem-split-paced-200k-{before,after}.{sh,log,kv}`). Thus the lower kernel
and T2 costs do not demonstrate a further typing p95 bucket improvement. The
200 KB stress still misses the 30 ms target; remaining full-line scans and
list construction remain optimization targets.

### Inline live icon classification (2026-09-19)

The recent 200 KB display profile attributed 10.1% inclusive CPU samples to
`icon-code-p`, which is called by width and drawing-type classification for
every character. This small function is now declared inline so callers can
specialize its hash lookup and avoid an out-of-line call. The registry is
still read on every lookup; no cache or fixed icon-range assumption was added.
Public registration and dynamically bound registries retain their behavior.

Matched filtered T1 medians in microseconds per string-width call improved
from 30.500 / 45.501 / 48.500 / 737.500 to
24.500 / 40.001 / 44.000 / 662.525 for ASCII / CJK / emoji / mixed text.
All entries still allocate zero bytes. These are the existing longer T1
windows, with five measured repetitions after warm-up, in results ending
`t1-20260919125327.json` and `t1-20260919125354.json`.
Matched filtered T2 long-line medians improved from 155.000 to 146.001 ms,
in results ending `t2-20260919125335.json` and `t2-20260919125403.json`.
T1/T2 still exit 2 because the matching Nova baseline is absent; neither
baselines nor budgets changed.

The core suite remains 74/75 with only the existing undo-model mismatch;
the dynamic ASCII-icon, ambiguous-width and Unicode cases pass. All 15 native
client/display checks pass in the rebuilt runtime
(`/tmp/lem-icon-inline-tests.log`, `/tmp/lem-icon-inline-native.log`). No
verified definition, shim or installed editor/profile changed.

Standard T3 passes every budget: startup 285.518 ms; plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets remain
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms. Results:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919125602.json`.
The matched 200 KB word-wrap pair explicitly uses 100 ms key spacing and
records 140 paints per build; both remain in the 32.768 ms p95 bucket and
miss the 30 ms target (`/tmp/lem-icon-inline-200k-{before,after}.{sh,log,kv}`).
The measured width/replay improvement does not establish a further typing
p95 bucket improvement.

### Undo-model scope audit (2026-09-19)

The remaining core failure is not only a signed-counter mismatch. A live
operation-by-operation probe against `8d787843d` compared the current buffer
with the certified historical linear session (`/tmp/lem-undo-audit.{lisp,log}`):

- Empty insertion and deletion at EOF preserve current content, points and
  generation; the model increments its tick despite no content change.
- Insert `abc`, boundary, undo, redo preserves matching content and points,
  but production generations are 1/2/3 while model ticks are 1/0/1.
- Insert `a`, boundary, insert `b`, boundary, undo, insert `c`, boundary, undo
  leaves `a` in production but an empty string in the model. Updating only the
  counter comparison cannot reconcile their command grouping.
- Insert `abc`, boundary, insert `x` at offset 1 with undo inhibited, boundary,
  undo is refused by production because the retained deletion no longer
  matches the live payload. The old model attempts replay instead.

`verified/README.md` now identifies the linear model's original commit
`aef520028` and the subsequent retained-tree integration `1b4a46892`.
Historical zero-divergence and false-clean findings are explicitly historical;
certification of that book does not certify the current undo tree. No theorem,
production integrity check, or differential assertion was changed or removed.
The differential runner now reports the operation, content/point equality and
both tick values at its first mismatch, including in shrunk failures.

New core regression cases pin clean/saved identity on sibling branches,
monotonic generations through undo/redo and explicit branch moves, unchanged
history for no-op edits, and preservation of text, point, generation and
history on an inconsistent inhibited-route refusal. Prefix/suffix inhibited
insertions still undo and redo successfully, and retain their dirty status.
These checks pass. The full suite remains 74/75, with the historical model
failure now explained directly in its output
(`/tmp/lem-undo-audit-final-tests.log`). No new production defect was found in
these bounded probes; a reference model matching the retained tree remains a
verification gap. This step changes tests/documentation only, so no performance
gain or new runtime-build validation is claimed.

### Inline layout width coercion (2026-09-19)

A fresh profile of the post-icon runtime collected 4,857 CPU samples on the
200 KB ordinary-wrap path with 100 ms key spacing. `k-sum-acc` accounted for
9.6% inclusive time and its per-width coercion helper `k-nat` for 3.5% self
time (`/tmp/lem-post-icon-profile.{sh,lisp,txt}`). The Common Lisp shim now
declares that small certified helper inline. This exposes its non-negative
integer result to the compiler within summation and clipping folds, without
restricting widths to fixnums or duplicating the definition.

Matched filtered T2 long-line medians improved from 149.001 to 141.001 ms;
the respective min/p90 ranges were 145.001-152.001 and 140.001-143.001 ms.
Results end in `t2-20260919130452.json` and `t2-20260919130531.json`.
New tests cover 80-bit widths, rational/negative/non-numeric values, improper
list tails and clipping beyond fixnum columns. These and the existing random
fold differentials and 300 KB render checks pass. The core suite remains
74/75 with the documented historical undo-model failure
(`/tmp/lem-nat-inline-tests.log`). All 15 rebuilt native display checks pass
(`/tmp/lem-nat-inline-native.log`).

All 12 books certified, with zero skips or failures
(`/tmp/lem-nat-inline-proofs.log`). The all-workload T2 run completed with
medians of 1,924.010 / 1,166.007 / 135.001 / 149.001 / 339.003 / 491.003 /
8,499.050 ms for big-file / isearch / lisp-edit / long-line / overlay-heavy /
scroll / undo-storm, in
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t2-20260919130905.json`.
T2 still exits 2 because the matching Nova baseline is absent; no baseline or
budget changed.

Standard T3 passes every budget: startup 286.941 ms; plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets remain
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms, in
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919131011.json`.
The matched 200 KB word-wrap pair at 100 ms key spacing records 140 paints per
build and the same 32.768 ms p95 bucket
(`/tmp/lem-nat-inline-200k-{before,after}.{sh,log,kv}`). This demonstrates a
replay-computation improvement, not a further typing p95 bucket improvement.
The histogram's coarse upper edge exceeds the 30 ms stress budget; raw stage
samples would distinguish smaller latency changes within that bucket. No
installed editor/profile changed.

### Raw pipeline samples and hidden latency improvements (2026-09-19)

The standard log2 histogram reports a 32.768 ms upper edge for every duration
in its roughly 16-33 ms bucket. It cannot distinguish improvements inside that
bucket, and an upper edge above a budget does not establish that the actual
percentile exceeds it. The existing budget gate remains unchanged.

`scripts/bench/e2e/pipeline-samples.lisp` is an optional diagnostic for private
benchmark editors. It chains the existing metrics sink, stores stage durations
in bounded preallocated arrays, and writes a CSV only when stopped or on exit.
It reports overflow and recorder replacement; the companion
`analyze-pipeline-samples.py` rejects incomplete captures and computes nearest-
rank percentiles from individual durations. Durations retain the pipeline
clock's own resolution; microsecond units do not guarantee microsecond
resolution. They end at core redisplay, before physical presentation.

To use it, place separate forms like these in an initialization script loaded
by the private tmux driver's eval form. Use the current checkout's absolute
path when measuring older saved executables, and a new output path per process:

```lisp
(load "/absolute/checkout/scripts/bench/e2e/pipeline-samples.lisp")
(lem-bench/pipeline-samples:start "/tmp/unique-capture.csv")
```

For allocation/GC correlation, pass `:resources t` to `start`. This adds
cumulative process CPU, GC CPU and allocation counters. The analyzer pairs
command completion with the following redraw, groups redraw wall times by
whether GC CPU increased, and lists the slowest redraws with their resource
deltas. It reports unpaired redraws instead of inventing a baseline. Counters
include other threads and recorder overhead; GC CPU time is **not** an elapsed
wall pause and must not be subtracted from wall time as if it were one.

The driver still opens its normal fixture and inserts its readiness marker.
The CSV is written on normal exit, or by `lem-bench/pipeline-samples:stop`.
Analyze one or more captures with:

```sh
python3 scripts/bench/e2e/analyze-pipeline-samples.py /tmp/unique-capture.csv
```

The recorder self-test exercises chaining, overflow accounting, restoration,
backend replacement, and loading with `*read-eval*` disabled (as in the editor):

```sh
nix develop --command sbcl --noinform --disable-debugger \
  --load .qlot/setup.lisp --eval '(ql:quickload :lem/core :silent t)' \
  --script scripts/bench/e2e/pipeline-samples-test.lisp
```

This self-test passed. Analyzer checks also confirmed nearest-rank results and
rejection of dropped samples, replaced sinks, inconsistent counts and unknown
stages. No normal runtime file, proof definition or default recorder changed.

Two before/after pairs compared the `0d68f80ad` runtime (bounded word-wrap
prefixes already present) with `97f2593f9` (subsequent split-eligibility, icon
and numeric-coercion optimizations). Both used a 200 KB word-wrapped line,
120 keys at 100 ms spacing plus 20 wall-trend samples. Every capture had 140
paint samples, no overflow, and no recorder replacement. Measurements in ms:

| Run | Input-to-core-paint p50 | Input-to-core-paint p95 | Redisplay p95 | Input-to-core-paint max |
| --- | ---: | ---: | ---: | ---: |
| Before 1 | 13 | 20 | 18 | 112.001 |
| After 1 | 11 | 17 | 16 | 80.001 |
| Before 2 | 13 | 25 | 18 | 88.001 |
| After 2 | 11 | 19 | 16 | 81 |

All four standard histogram p95 values were still 32.768 ms. The raw p95
values are below 30 ms in these runs, although the conservative histogram gate
continues to fail. This makes the cumulative rendering improvement visible;
it does not attribute the whole change to the most recent optimization.
Artifacts: `/tmp/lem-raw-{before,after}-{1,2}.{sh,log,kv,csv}` and
`/tmp/lem-raw-comparison.json`.

The long tail remains real: the second and third measured commands took
64-84 ms across these runs. In the current build they account for two early
74-81 ms input-to-paint samples; later redisplay outliers also occur. Their
cause has not yet been established. This capture identifies an early-command
profiling target instead of treating the unchanged histogram bucket as proof
that recent optimizations had no latency effect. No installed profile changed.

### Cold command dispatch is an SBCL heuristic cost (2026-09-19)

A CPU profile restricted to commands two and three attributed 78.4% of its
171 samples to SBCL's discrimination-net analysis. Timing the cost estimator
in a separate private editor identified `lem-core:execute`, with 1,163 methods:
two calls took 71 and 66 ms. Other observed generic functions took at most
1 ms. Artifacts: `/tmp/lem-early-profile.{lisp,sh,txt,log}` and
`/tmp/lem-dispatch-cost.{lisp,sh,txt,log}`.

In [SBCL 2.5.10's dispatcher](https://github.com/sbcl/sbcl/blob/sbcl-2.5.10/src/pcl/dfun.lisp),
`use-dispatch-dfun-p` compares estimated generated-dispatch cost with cached
dispatch. The estimator's cost limit bounds the resulting decision tree's
estimated execution cost, but does not bound the work spent analysing methods.
The expensive estimate here ultimately selects cached dispatch anyway.

`scripts/bench/diagnostics/cold-command-dispatch.lisp` reproduces this without Lem or Qlot:

```sh
sbcl --noinform --no-userinit --no-sysinit \
  --script scripts/bench/diagnostics/cold-command-dispatch.lisp
```

It defines 1,200 command classes and checks multiple values, around/before/after
ordering, method replacement and removal, changed mode classes, next-method
calls, and EQL specializers. Stock SBCL 2.5.10 took 74/89 ms for its first two
calls; dispatch after method changes took 68-110 ms. Warm calls were below the
clock resolution. All semantic assertions passed
(`/tmp/lem-cold-dispatch-stock.log`).

A private-process experiment bypassed the estimator for generic functions
with more than 256 methods, leaving SBCL's existing cached dispatcher in use.
Two 200 KB word-wrap captures recorded 140 command/paint samples each, no
overflow or recorder replacement. Maximum command duration fell from 70-71 ms
in the earlier current-build captures to 3 ms in both experimental runs.
Input-to-core-paint p50/p95/max were 11/17/31.001 and 11/17/34 ms, versus
11/17/80.001 and 11/19/81 ms before. This removes the early-command tail;
it does not eliminate later redisplay outliers. Artifacts:
`/tmp/lem-bounded-dispatch.lisp` and
`/tmp/lem-bounded-dispatch-{1,2}.{sh,log,kv,csv}`.

At this checkpoint this was experimental evidence, not a rebuilt runtime
result. No production Lem methods, installed profile, or budgets had changed.

### Rebuilt runtime removes cold command stalls (2026-09-19)

The Nix build now applies `patches/sbcl-bounded-dispatch-cost.patch` to SBCL
and uses that compiler throughout the ASDF dependency graph and development
shell. The compiler is also available as `.#sbcl-lem`. Generic functions with
more than 256 methods bypass the discrimination-net cost estimate and use
SBCL's ordinary cached dispatch. Smaller functions keep the existing heuristic.
This favors bounded setup work for large method sets; it is not a claim that
cached dispatch is the fastest steady-state strategy for every possible large
generic function. Lem's command methods, precedence, advice, and extension API
are unchanged. The patch applies to Nix builds, not arbitrary system SBCLs.

The compiler's full upstream check phase completed successfully in 6m25s,
with its declared expected failures and 47 platform/feature skips
(`/tmp/lem-bounded-sbcl-build.log`). The standalone dispatch check passed on
the rebuilt compiler: cold dispatch was 2 ms, and the method replacement,
changed mode, EQL-specializer and method-removal cases were 0-1 ms. These
durations retain the clock's millisecond-scale resolution. Run the check with:

```sh
nix build .#checks.x86_64-linux.cold-command-dispatch
```

The core suite ran with the patched SBCL and remained 74/75, with only the
documented undo-model mismatch (`/tmp/lem-bounded-core-tests.log`). Rebuilt
frontend checks passed: 15 native display, 27 configured screen-line, and
83 Vundo checks, including live reload and rollback refusal
(`/tmp/lem-bounded-runtime-checks.log`).

Two sequential before/after pairs used the previous `97f2593f9` executable
and the rebuilt runtime, with no private SBCL replacement or profiler hook.
The diagnostic sample collector remained enabled on both sides. Each 200 KB
word-wrap capture contains 140 commands and paints, 100 ms key spacing, no
overflow, and no recorder replacement. All values below are milliseconds:

| Run | Command max | Input-to-core-paint p50 | Input-to-core-paint p95 | Input-to-core-paint max |
| --- | ---: | ---: | ---: | ---: |
| Before 1 | 73 | 11 | 27 | 84 |
| After 1 | 2 | 11 | 17 | 30 |
| Before 2 | 67 | 11 | 17 | 82 |
| After 2 | 2 | 11 | 17 | 32 |

Commands two and three took 67/73 and 67/67 ms before, versus 1/1 ms in
both rebuilt runs. Redisplay p95 remained 16 ms throughout. This isolates
the improvement to the cold-command tail; remaining later redisplay outliers
still reach roughly 30 ms. These are core-paint durations, not physical
monitor presentation. The stress histogram still reports the conservative
32.768 ms p95 bucket and fails its unchanged 30 ms gate.
Artifacts: `/tmp/lem-sbcl-runtime-{before,after}-{1,2}.{sh,log,kv,csv}`.
The rebuilt executable is
`/nix/store/m7gcp7cvn78qqmmkks1rz8w36q5nszna-sbcl-lem-ncurses-unstable/bin/lem`.
No installed editor/profile was changed.

Matched T1/T2 runs used the same working tree and dependency environment, with
stock versus patched SBCL selected explicitly. T1 normal insert/delete and
newline medians stayed at 4/4.8 us/op; plain/long-line redisplay stayed at
228.571/2,250 us/op. Long-line newline insertion rose 5.5%; remaining medians
were unchanged or lower within the harness noise band. T1 files end in
`t1-20260919135347.json` (stock) and `t1-20260919135405.json` (patched).
The earlier T1 file ending `20260919135125` is excluded: its automatic sibling
discovery loaded the standalone reproducer. The probe now resides in the
`diagnostics/` subdirectory so it remains opt-in.

T2 medians in ms/workload, with identical frame counts on both sides:

| Workload | Stock SBCL | Patched SBCL |
| --- | ---: | ---: |
| big-file | 1938.012 | 1920.011 |
| isearch | 1183.007 | 1157.007 |
| lisp-edit | 140.001 | 135.001 |
| long-line | 146.002 | 147.001 |
| overlay-heavy | 347.002 | 336.002 |
| scroll | 498.003 | 491.002 |
| undo-storm | 8460.050 | 8547.050 |

These differences range from -3.6% to +1.0%; they show no substantial
steady-state regression in these workloads, not a general throughput speedup.
T2 files end in `t2-20260919135125.json` and `t2-20260919135405.json`.
Both T1/T2 runs completed their entries and exited 2 because the matching Nova
baselines are absent. No baseline or budget was changed. Logs:
`/tmp/lem-bounded-{bench-before,t1-before,bench-after}.log`.

Standard T3 passed every budget: warm startup 285.096 ms and plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets of
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms. Results end in
`t3-20260919135555.json` (`/tmp/lem-bounded-t3.log`). The standalone Nix check
was also verified after moving its source into `diagnostics/`.

### Bounded counters in the ACL2 length shim (2026-09-19)

A post-dispatch-fix CPU profile of the 200 KB word-wrap path collected 4,586
samples. The certified wrapping kernel accounted for 40.8% inclusive time;
`k-explode` accounted for 31.9%, including 6.3% self time in the shim's `len`
and further time in its per-cell generic addition. The remaining major costs
include prefix copying, width measurement and character classification.
Artifacts: `/tmp/lem-current-render-profile.{lisp,sh,txt,log}`.

The existing Common Lisp implementation of ACL2 `len` now counts batches of
at most 1,024 cons cells using a bounded integer counter. Its accumulated
total remains unrestricted, and it still returns the length of a dotted
list's cons prefix, or zero for any atom. No book definition, kernel record,
or shim translation rule changed. An alternating-order microbenchmark over
200 traversals of a 200,000-element list took 81-84 ms with the old helper and
29-31 ms with the new one (`/tmp/lem-len-micro.{lisp,log}`). This approximately
2.7x component improvement does not describe the entire rendering pipeline.

Matched filtered T2 long-line medians moved from 144.002 to 141.001 ms, with
min/p90 ranges 142.001-147.001 and 140.001-144.001 ms. Their overlap warrants
caution about the small whole-workload change. Files end in
`t2-20260919140102.json` and `t2-20260919140203.json`.

The rebuilt executable used for acceptance and paint timing is
`/nix/store/wl69sdms0fvnpfavim98hd2ysms15f6x-sbcl-lem-ncurses-unstable/bin/lem`.
Its derivation's source was checked against both edited files. Two comparisons
used 140 paced keys/paint samples apiece, with the run order reversed in the
second comparison. Captures had no overflow or recorder replacement. Values
are milliseconds, ending at core paint rather than monitor presentation:

| Run | Paint p50 | Paint p95 | Paint max |
| --- | ---: | ---: | ---: |
| Before 1 | 11 | 17 | 34 |
| After 1 | 10 | 16.001 | 36.001 |
| Before 2 | 11 | 16 | 25 |
| After 2 | 10 | 15.001 | 33 |

The median and p95 improvements repeat, at roughly the clock's one-millisecond
resolution. Maximum latency did not improve. The conservative histogram gate
fails in the first comparison and passes on both sides in the second; no
budget changed. Artifacts: `/tmp/lem-len-built-{before,after}-{1,2}.{sh,log,kv,csv}`.

New cases cover proper and dotted lists across batch boundaries, arbitrary
atom tails, and 300,000-element prefixes. They pass alongside the existing
300 KB render and kernel differential checks. Core remains 74/75 with the
historical undo-model mismatch (`/tmp/lem-chunked-len-tests.log`). All 12 books
certified, with zero skips/failures (`/tmp/lem-chunked-len-proofs.log`); the
unchanged books' certification is separate from testing the hand-written shim.
All 15 native display, 27 screen-line and 83 Vundo checks passed
(`/tmp/lem-chunked-len-runtime.log`). No installed profile changed.

Full T2 completed with medians of 1,901.010 / 1,177.007 / 139.001 / 143.001 /
338.002 / 499.003 / 8,490.049 ms for big-file / isearch / lisp-edit / long-line /
overlay-heavy / scroll / undo-storm. Frame counts match the previous runtime,
and median differences range from -2.7% to +3.0%, within the harness noise
band. Results end in `t2-20260919141011.json`
(`/tmp/lem-chunked-len-full-t2.log`). Filtered and full T2 still exit 2 because
the matching Nova baseline is absent; the results are comparative evidence,
not a passing baseline gate.

Standard T3 passed all budgets: warm startup 285.363 ms and plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets of
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms. Results end in
`t3-20260919141206.json` (`/tmp/lem-chunked-len-t3.log`).

### Avoid the second prefix allocation while splitting runs (2026-09-19)

`k-firstn` previously built a reversed accumulator and then copied it again.
ACL2 8.6's native `take` copies directly. The kernel now uses that primitive
for natural counts and proper lists, clamping the count to avoid NIL padding;
other inputs retain the existing accumulator. Its logical definition and
guard `t` remain intact. The new `k-firstn-is-clamped-take` equality theorem is
enabled only for guard verification. The shim adds the guarded `take` primitive
following ACL2's native implementation; the trust boundary is documented in
`verified/README.md`.

On `1e7371252`, an isolated before/after experiment over 50 splits of a
200,000-element run reduced allocation from about 320.2 MB to 160.1 MB.
Elapsed times were 120.001/105.001 ms before and 86.000/93.001 ms after
(`/tmp/lem-prefix-micro.{lisp,log}`, using `/tmp/lem-take-prefix.lisp`).
This is a component experiment, not an editor-wide speedup.

Filtered T2 long-line replay recorded 129.001 ms (min/p90 129.000-131.001)
and 126,050,976 allocated bytes, in `t2-20260919142104.json`. The subsequent
full T2 run gives a more conservative result: long-line median 142.001 ms
versus the prior 143.001 ms, while allocation fell from 171,244,064 to
126,229,408 bytes (about 26%). The full run's other medians were
1,939.012 / 1,177.008 / 135.002 / 340.002 / 500.003 / 8,595.052 ms for big-file /
isearch / lisp-edit / overlay-heavy / scroll / undo-storm. All frame counts
match; median changes range from -2.9% to +2.0%, within the noise band.
Results end in `t2-20260919143030.json`. Both runs completed and exited 2
because the matching Nova baseline is absent. No baseline or budget changed.

Rebuilt before/after editor comparisons used the same 200 KB word-wrap fixture
and 140 key/paint samples per run, with the order reversed in the second pair.
Captures were complete, without overflow or recorder replacement. Milliseconds:

| Run | Core-paint p50 | Core-paint p95 | Core-paint max |
| --- | ---: | ---: | ---: |
| Before 1 | 11 | 16 | 35 |
| After 1 | 11 | 16.001 | 42 |
| Before 2 | 11 | 18 | 34.001 |
| After 2 | 11 | 16 | 25 |

There is no repeatable median or maximum improvement in these captures. The
allocation saving is established; an end-to-end latency speedup is not.
Artifacts: `/tmp/lem-take-built-{before,after}-{1,2}.{sh,log,kv,csv}`.
The checked candidate executable is
`/nix/store/lpsc291csakpxc36y99wvwsgmcacik1r-sbcl-lem-ncurses-unstable/bin/lem`;
its derivation source matches the edited shim, layout book and regression test.

All 12 books certified, with zero skips or failures
(`/tmp/lem-take-prefix-proofs.log`). Tests cover padding versus clamping,
invalid and 80-bit counts, dotted lists, fresh prefixes, preserved leaf identity,
unchanged input lists, and 300 KB full rendering. Core remains 74/75 with the
documented undo-model mismatch (`/tmp/lem-take-prefix-tests.log`). All 15 native
display, 27 screen-line and 83 Vundo checks passed
(`/tmp/lem-take-prefix-runtime.log`). No installed profile changed.

Standard T3 passed all budgets: startup 286.447 ms and plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets of
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms, in
`t3-20260919143233.json` (`/tmp/lem-take-prefix-t3.log`).

### Stop width scans once overflow is certain (2026-09-19)

`k-wrap-row` used to sum an entire text run just to decide whether it reached
or exceeded the row boundary. It now uses `k-text-overflows-p`: a tail-recursive
scan stops when its natural-valued accumulator reaches the remaining width.
The equality theorems in `verified/layout.lisp` prove that this decision is the
same as comparing the complete sum; the existing layout theorems are unchanged.
Integer and rational bounds take the new path, while Common Lisp floats retain
the original arithmetic order to preserve rounding. No shim primitive, public
export, input budget, or rendering behavior changes.

Rebuilt before/after editors used the same 200 KB word-wrap fixture and
140 paced key/paint samples, with the order reversed in the second pair.
All captures were complete, without overflow or recorder replacement.
Core-paint durations in milliseconds:

| Run | p50 | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Before 1 | 10 | 15 | 22 |
| After 1 | 9 | 15 | 38 |
| Before 2 | 10 | 16 | 39 |
| After 2 | 10 | 14.001 | 28 |

The scan does less work on overflowing runs, but these captures do not establish
a repeatable median or maximum latency improvement. All four conservative
histogram gates passed; no budget changed. Artifacts:
`/tmp/lem-width-stop-built-{before,after}-{1,2}.{sh,log,kv,csv}`.
The candidate executable is
`/nix/store/2gpkjncl1iiq9vnl12hkmwyvssc16p7r-sbcl-lem-ncurses-unstable/bin/lem`;
its derivation source matches the edited layout book and unchanged shim.

All 12 books have current certificates: layout certified directly in
`/tmp/lem-width-stop-proof.log`, then the runner certified the other 11 and
reused that fresh layout certificate, with zero failures
(`/tmp/lem-width-stop-proofs.log`). The core suite remains 74/75, with only the
documented undo-model mismatch (`/tmp/lem-width-stop-tests.log`). New checks
cover large integers, ratios, floating-point rounding, dotted and junk width
lists, random full-sum comparisons, and a 300,000-entry zero-width scan that
must exhaust its input without a stack overflow. The existing 300 KB full
render tests also pass. All 15 native display, 27 configured screen-line and
83 Vundo checks passed (`/tmp/lem-width-stop-runtime.log`). No installed profile
changed.

Full T2 completed with medians of 1,870.011 / 1,138.007 / 135.001 / 132.000 /
326.001 / 471.004 / 7,932.047 ms for big-file / isearch / lisp-edit / long-line /
overlay-heavy / scroll / undo-storm. Frame counts match the prior run, and
median differences range from approximately 0% to -7.7%, inside the harness
noise band. The long-line result is down from 142.001 ms, but unrelated
workloads also became faster, so that comparison alone does not establish the
optimization's gain. Results end in `t2-20260919144549.json`
(`/tmp/lem-width-stop-full-t2.log`). The run exited 2 because the matching Nova
baseline is absent; these are comparative results, not a passing baseline gate.

Standard T3 passed every budget: startup 286.032 ms and plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets of
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 4.096 ms. Results end in
`t3-20260919144730.json` (`/tmp/lem-width-stop-t3.log`).

### Combine properness and length checks during prefix copies (2026-09-19)

A fresh profile of `e656fc021` on the 200 KB word-wrap typing fixture collected
3,968 samples. `len` accounted for 10.5% self time and `true-listp` for 7.9%:
prefix copying checked properness and then traversed the same list again to
clamp the requested count. Artifacts: `/tmp/lem-post-width-profile.{lisp,sh,log,txt}`.
These are profiler samples, not uninstrumented latency measurements.

A private prototype compared both scans against a combined traversal over
100 splits of a 200,000-element run. The original took 158.001/160.001 ms;
a simple generic counter took 181.001/185.000 ms; a bounded-batch counter took
128.001/127.001 ms. Allocation was unchanged at about 320.1 MB.
`/tmp/lem-proper-length-probe.{lisp,log}` captures the experiment on
`e656fc021`; rerunning that script after this change would no longer give the
same original binding. This component result motivated the implementation,
not an editor-wide speedup claim.

`k-firstn` now obtains properness and length together through
`k-proper-length-acc`. Its inner `k-length-chunk` counter is guarded to
0..1,024, enabling native integer arithmetic, while the total remains
arbitrary precision. The helpers are defined and proved in the layout book;
no shim construct, primitive or public export is added. The original logical
prefix definition and guard `t` remain intact, including the dotted-list
fallback. Invalid/zero counts and atomic inputs return without scanning.

Layout certified directly in `/tmp/lem-proper-length-layout-proof.log`.
The full runner certified the other 11 books and reused that fresh certificate,
with zero failures (`/tmp/lem-proper-length-proofs.log`). Core remains 74/75,
with only the documented undo-model mismatch (`/tmp/lem-proper-length-tests.log`).
New checks cover proper and dotted lists at batch boundaries through 300,000
entries, arbitrary atom tails, and an 80-bit starting total, alongside the
existing prefix equivalence and full rendering tests. All 15 native display,
27 configured screen-line and 83 Vundo checks passed
(`/tmp/lem-proper-length-runtime.log`).

The tested candidate executable is
`/nix/store/3f4hw6j98myskx83h1frzmqv1fn5yign-sbcl-lem-ncurses-unstable/bin/lem`.
Its derivation source matches the edited layout book, unchanged shim and
regression test byte for byte. No installed profile changed.

Rebuilt before/after comparisons used 140 paced key/paint samples per run on
the same 200 KB word-wrap fixture, reversing the order in the second pair.
All captures were complete, with no dropped samples or recorder replacement.
Core-paint durations in milliseconds:

| Run | p50 | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Before 1 | 9 | 14 | 35 |
| After 1 | 9 | 15 | 26.001 |
| Before 2 | 9 | 14 | 34 |
| After 2 | 9 | 13 | 27.001 |

Median latency is unchanged at the clock's one-millisecond resolution, and p95
moves in opposite directions. Maximum latency is lower in both comparisons,
but these few runs do not establish a general tail-latency guarantee. All four
conservative histogram gates passed. Artifacts:
`/tmp/lem-proper-length-built-{before,after}-{1,2}.{sh,log,kv,csv}`.

Full T2 completed with medians of 1,911.010 / 1,176.007 / 134.001 / 129.002 /
344.002 / 498.004 / 8,312.044 ms for big-file / isearch / lisp-edit / long-line /
overlay-heavy / scroll / undo-storm. All frame counts match the prior run.
Long-line replay decreased from 132.000 ms; changes across all workloads span
-2.3% to +5.7%, inside the harness noise band. Results end in
`t2-20260919150001.json` (`/tmp/lem-proper-length-full-t2.log`). The completed
run exited 2 because the matching Nova baseline is absent; this is comparative
evidence, not a passing baseline gate. No baseline or budget changed.

Standard T3 passed every budget: startup 285.366 ms and plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets of
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 2.048 ms. Results end in
`t3-20260919150141.json` (`/tmp/lem-proper-length-t3.log`). The word-wrap bucket
is lower than the prior run; this remains a conservative histogram boundary,
not an exact percentile or a measured twofold speedup.

### Inline the live character lookup and width wrapper (2026-09-19)

The post-width profile (`/tmp/lem-post-width-profile.txt`) attributed 7.2% self
time to `char-width` and 2.7% to `control-char`. Both wrappers now permit
inlining into their callers: character classification can read the replacement
table directly, and width loops can specialize the default tab argument and
existing width-step body. The tables and dynamic width setting are still read
at runtime; no cached classification or replacement table is introduced.

Separate component experiments on `1b71ab9ae` ran 20 million ASCII character
classifications or width steps. Classification took 123.000/122.001 ms before
and 113.001/112.001 ms after; the width loop took 134.000/132.001 ms before and
110.001/108.002 ms after. Artifacts:
`/tmp/lem-control-inline-probe.{lisp,log}` and
`/tmp/lem-width-inline-probe.{lisp,log}`. The classification probe also compared
the old and recompiled functions across all 1,114,112 supported character
codes, with identical results. These probes retain the initial compiled
function binding, so reproducing their before/after labels requires the
stated parent revision.

The existing width vectors, property checks, dynamic icon-registration cases,
tab settings and ambiguous-width cases pass. Core remains 74/75, with only the
known undo-model mismatch (`/tmp/lem-character-inline-tests.log`). All 15 native
display, 27 configured screen-line and 83 Vundo checks passed
(`/tmp/lem-character-inline-runtime.log`). Kernel sources and the shim are
unchanged; the proof runner verified that all 12 cached certificates remain
current, with zero failures (`/tmp/lem-character-inline-proofs.log`).

The rebuilt candidate is
`/nix/store/q5wvq3ks2jjc435gxqy3638p39pk1lma-sbcl-lem-ncurses-unstable/bin/lem`.
Its derivation source matches the edited width utility and the calling
character-classification and physical-line sources. No installed profile changed.

Matched before/after editor runs used the 200 KB word-wrap fixture and 140 paced
key/paint samples per capture, reversing order in the second pair. Captures
were complete, with no dropped samples or recorder replacement. Core-paint
durations in milliseconds:

| Run | p50 | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Before 1 | 9 | 14 | 33 |
| After 1 | 8 | 13 | 43 |
| Before 2 | 9 | 14 | 37 |
| After 2 | 8 | 13.001 | 35 |

The median and p95 improvement repeats, at about the clock's one-millisecond
resolution. Maximum latency does not improve consistently. All four
conservative histogram gates passed. Artifacts:
`/tmp/lem-character-inline-built-{before,after}-{1,2}.{sh,log,kv,csv}`.
The saved executable grew from 33,354,088 to 33,531,360 bytes (177,272 bytes,
about 0.53%); this is a measured image-size difference, not an allocation-per-key
claim. These changes trade some compiled code size for lower call overhead.

Full T2 completed with medians of 1,902.010 / 1,163.006 / 136.000 / 127.000 /
341.003 / 482.002 / 8,314.048 ms for big-file / isearch / lisp-edit / long-line /
overlay-heavy / scroll / undo-storm. Frame counts match the previous run, and
median changes range from -3.2% to +1.5%, within the harness noise band.
Results end in `t2-20260919151144.json`
(`/tmp/lem-character-inline-full-t2.log`). The run completed and exited 2
because the matching Nova baseline is absent; this is comparative evidence,
not a passing baseline gate. No baseline or budget changed.

Standard T3 passed every budget: startup 286.342 ms and plain / big-file /
long-line / scroll / truncate / word-wrap p95 buckets of
1.024 / 1.024 / 4.096 / 1.024 / 2.048 / 2.048 ms. Results end in
`t3-20260919151348.json` (`/tmp/lem-character-inline-t3.log`).

### Correlate long redraws with GC and allocation (2026-09-19)

The optional pipeline capture now accepts `:resources t`. In addition to stage
wall durations it records cumulative process CPU time, GC CPU time and bytes
consed in preallocated arrays. The analyzer validates monotonic counters and
clock units, pairs command completion with redraw completion, reports unpaired
redraws, and groups actual redraw wall times by whether GC CPU increased.
Default captures retain the original two-column CSV and summary.

SBCL 2.5.10's in-image documentation identifies `*gc-run-time*` as process CPU
time reported by `get-internal-run-time` (`/tmp/lem-gc-clock-doc.log`). It is
not elapsed stop-the-world time. Resource deltas include other threads and
recorder overhead, so CPU time may exceed the measured wall duration. The
older `gc-pause-ms` T2 field and the metrics GC "pause" fields are also CPU
estimates despite their historical names; comments now make this distinction
explicit. Their serialized names and historical measurement values are unchanged.

Three captures used the `af253d47a` executable and the existing 200 KB wrapped
line, with 140 paced key/paint samples each. The first two used a private
prototype; the third loaded the updated repository diagnostic. Every
capture was complete, with 140 paired redraws, no unpaired redraws, no dropped
samples and no recorder replacement. Redraw wall times in milliseconds:

| Capture | Redraws with GC | With-GC p50 / max | Redraws without GC | Without-GC p50 / max |
| --- | ---: | ---: | ---: | ---: |
| 1 | 15 | 13 / 30 | 125 | 8 / 12 |
| 2 | 15 | 14 / 31 | 125 | 8 / 10 |
| 3 | 15 | 12 / 39 | 125 | 8 / 10 |

All redraws above 25 ms coincided with GC. In capture 3, the 39 ms redraw had
44.995 ms of process CPU and 36.854 ms of GC CPU; these are not wall-pause
measurements. Roughly 15.8 MB was allocated during each redraw interval
(non-GC median 15,755,808 bytes in captures 2 and 3). This points toward
allocation as the next investigation target; it does not attribute every byte
to a particular function or establish that every possible stall is caused by GC.

Artifacts: `/tmp/lem-tail-resources-{1,2,3}.{sh,log,kv,csv}` and prototype
`/tmp/lem-pipeline-resources.lisp`. The executable remains
`/nix/store/q5wvq3ks2jjc435gxqy3638p39pk1lma-sbcl-lem-ncurses-unstable/bin/lem`.
All three private histogram gates passed. These instrumented captures are
for attribution, not a before/after performance claim or physical-presentation
measurement. No production timing, GC setting, benchmark budget or profile
activation changed.

The Lisp capture self-test passed with resource counters enabled, including
normal sink chaining/restoration, overflow handling, replacement detection and
`*read-eval* = nil` loading (`/tmp/lem-pipeline-resources-test.log`). Five Python
unit tests cover the original format, clock-unit conversion, CPU time exceeding
wall time, GC grouping, missing command baselines, malformed/decreasing counters,
loss and sink replacement. Run them with:

```sh
python3 scripts/bench/e2e/analyze-pipeline-samples-test.py
```

### Avoid redraws after empty idle-timer polls (2026-09-19)

An allocation profile of the current 200 KB wrapped-line typing case reached
its 50,000-sample cap (approximately 32 KB allocation regions). In that sampled
portion, layout splitting accounted for about 50% of allocation samples and
conversion to kernel records about 45%. More significantly, roughly 65% of
samples were under `read-event-internal`'s idle redraw path. This is an
allocation attribution profile, not a complete latency capture or an exact
byte census (`/tmp/lem-render-allocation-profile.{lisp,sh,log,txt}`).

The input loop unconditionally redrew after `update-idle-timers`, even when
that function returned NIL because no callback ran. A zero remaining deadline
enters the polling branch, while the scheduler's strict expiry predicate can
still reject that tick. The next poll then runs the real callback and redraws
again. A private observer recorded 131 empty updates and 144 updates with work
for 140 typed keys; the callbacks were the show-paren timer (142) and scheduled
syntax scan (2), in `/tmp/lem-idle-work-probe.{lisp,sh,log,txt}`.

The input loop now uses the scheduler's existing work-performed result to
request redraw only when a callback ran. Timer deadlines, callback dispatch,
repetition and the certified timer model are unchanged. Callbacks that return
NIL still cause redraw: the scheduler reports whether callbacks ran, not what
they returned.

A deterministic test scripts the clock through an exact deadline and expiry,
using the real timer scheduler and event queue with a counted redraw sink.
It covers both one-shot and repeating timers and a NIL-returning callback.
The old input function fails both empty-poll assertions; the candidate passes
all checks (`/tmp/lem-idle-redraw-regression-{before,after}.log`). The function
replacement used for the old-code check is private to that test process.

The paired packaged-runtime comparison used ABBA order, explicit word-boundary
wrapping of the 200 KB line, 140 paced keys per run, and resource capture in both
versions. The production baseline was
`/nix/store/q5wvq3ks2jjc435gxqy3638p39pk1lma-sbcl-lem-ncurses-unstable/bin/lem`;
the candidate was
`/nix/store/3yv384p78937dajxh8kr8pxz5axygs6l-sbcl-lem-ncurses-unstable/bin/lem`.
The candidate derivation's input and timer sources and regression test matched
the checkout byte for byte. Every run completed with 140 paired redraws, no
unpaired redraws, no dropped samples and no recorder replacement.

| Run | Captured allocation (bytes) | Process CPU (ms) | GC CPU (ms) | Keystroke p50 / p95 / max (ms) |
| --- | ---: | ---: | ---: | --- |
| Before 1 | 6,797,039,456 | 3824.638 | 394.884 | 9 / 13 / 30 |
| After 1 | 4,715,499,008 | 2577.376 | 240.405 | 8 / 14 / 32 |
| After 2 | 4,715,835,904 | 2598.666 | 236.173 | 8 / 15 / 34 |
| Before 2 | 6,813,361,920 | 3703.929 | 383.584 | 8 / 13 / 30 |

Allocation and CPU are differences between the first and last cumulative
counters in each complete capture. They include idle work between keys,
recorder overhead, other process threads and matched shutdown input; they are
not per-redraw allocation or physical presentation latency. Averaging the two
runs per version gives 30.7% less allocation and 31.2% less process CPU. GC CPU
fell 38.8%, but it is not wall-clock pause time. Keystroke median and tails did
not consistently improve; p95 and maximum were slightly higher in both
candidate runs. This change avoids redundant work without making the remaining
large redraws cheap. Raw captures, scripts and logs are
`/tmp/lem-idle-redraw-built-{before,after}-{1,2}.{csv,sh,log,kv}`; the extracted
results are `/tmp/lem-idle-redraw-results.json`.

Validation passed all 15 native display, 27 configured screen-line and 83 Vundo
checks. The full core suite remains 74/75, with only the previously documented
undo-model mismatch. All 12 ACL2 certificates are current (12 cached skips,
zero failures); this patch changes neither timer scheduling nor kernel source.
Logs: `/tmp/lem-idle-redraw-{runtime,tests,proofs}.log`. T2's direct replay does
not exercise this input polling path, so it was not rerun for this patch.

The standard T3 run passed unchanged budgets: warm startup 283.806 ms and
plain/bigfile/longline/scroll/truncate/wordwrap p95 histogram upper bounds of
1.024/1.024/4.096/1.024/2.048/2.048 ms. Result:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919155516.json`;
log: `/tmp/lem-idle-redraw-t3.log`. These are core input-to-redisplay measurements,
not physical-display timing. No installed editor profile was activated.

### Reuse immutable widths for large uniform text runs (2026-09-19)

The post-idle-redraw profile still attributed substantial allocation to
`kernel-display-object`'s per-character code and width lists. The adapter now
reuses a single immutable width list for uniform runs of 1024 through 262144
characters. It scans current character widths before reuse, so live icon,
ambiguous-width and tab settings remain authoritative. Nearby lengths share
list tails or prepend cells without modifying any returned list; a length
change larger than 1024 rebuilds the entry, bounding tail traversal. The cache
retains at most 262144 conses (roughly 4 MiB on 64-bit SBCL), stores no source
strings or drawing objects, and publishes complete immutable entries. The
kernel remains pure and unchanged.

Small and over-limit runs keep the uncached path. Mixed runs retain the
original decomposition, including exact pixel scaling and last-character
remainder. When the uniform scan finds a mismatch, fallback resumes there and
constructs the already-scanned prefix from its known delta; it does not
reclassify that prefix. This avoids a second long classification pass for mixed
Unicode runs. The fallback owns its fresh list, so its scaling cannot mutate
cached widths. The wrapping algorithm and kernel records are unchanged.

A private prototype matched the previous implementation in 588 comparisons
covering cache-size boundaries, Unicode, ambiguous widths, negative/zero/scaled
widths, and non-cell-aligned totals, while retaining old lists unchanged
(`/tmp/lem-uniform-width-cache-check-core.log`). The final source passed the same
comparison against the pre-change source function after the fallback revision
(`/tmp/lem-uniform-width-revised-check.log`). Its ABBA typing comparison
used the same baseline binary for both variants and loaded the prototype only
in candidate processes. Allocation across the captured interval fell from
4.716/4.716 GB to 3.806/3.806 GB; input-to-redisplay p95 changed from 15/14 ms to
12/12 ms. These prototype results motivated a packaged-build comparison below;
they are not a substitute for it. Artifacts:
`/tmp/lem-uniform-width-built-{before,after}-{1,2}.{csv,sh,log,kv}` and
`/tmp/lem-uniform-width-results.json`.

Regression coverage checks unchanged retained lists across growth, shrinkage,
eviction and width changes, live icon and ambiguous-width changes, late mixed
widths, scaling/remainders, and the cache's upper bound. The full core suite
remains 74/75 with only the existing undo-model mismatch. The existing 300000
character full-render test passes outside the cache range; an additional run
at 220000 characters passes inside it, comparing wrapped rows to the certified
kernel and horizontally scrolled rows to exact substrings with the cursor in
the middle and at the end. Logs:
`/tmp/lem-uniform-width-revised-{tests,check}.log`. All 12 ACL2 certificates remain
current (cached; no kernel source changed), in
`/tmp/lem-uniform-width-proofs.log`.

The focused final-source comparison performed 50 decompositions of a 200000
character run in ABBA order. Uniform ASCII took 105/98 ms before and 90/90 ms
after; uniform Greek took 167/165 ms before and 149/147 ms after. Each uniform
case's measured allocation fell from about 160 MB to 16 KB after warming the
cache. A Greek run with one Chinese character at its end took 167/164 ms before
and 178/176 ms after, with approximately unchanged allocation; an early
mismatch took 164/164 ms before and 166/169 ms after. Thus the fallback avoids a
second character-classification pass but is not free: the late-mismatch case
still costs about 0.2–0.3 ms more per decomposition in this component test.
Timing includes traversing each returned list for its length, and is not an
editor latency claim. The live adapter generally receives type-grouped runs,
but mixed widths within one type are possible and were deliberately measured.
Artifacts: `/tmp/lem-uniform-width-component.{lisp,log}`.

The final packaged ABBA comparison used the same 200 KB word-wrapped typing
case, 140 paced keys per run, and resource capture on both versions. Baseline:
`/nix/store/3yv384p78937dajxh8kr8pxz5axygs6l-sbcl-lem-ncurses-unstable/bin/lem`.
Final candidate:
`/nix/store/3mmzch6avcci3y1vf8cg9w18k24mk26s-sbcl-lem-ncurses-unstable/bin/lem`.
The candidate's adapter and regression-test source matched the checkout byte
for byte. All four captures had 140 paired redraws, zero unpaired redraws, no
sample loss and no recorder replacement.

| Run | Captured allocation (bytes) | Process CPU (ms) | GC CPU (ms) | Keystroke p50 / p95 / max (ms) |
| --- | ---: | ---: | ---: | --- |
| Before 1 | 4,715,944,320 | 2645.349 | 260.193 | 8 / 15 / 35 |
| After 1 | 3,805,575,424 | 2547.986 | 190.839 | 8 / 11 / 37 |
| After 2 | 3,805,977,088 | 2560.462 | 180.079 | 8 / 11.001 / 34 |
| Before 2 | 4,716,068,608 | 2639.824 | 269.271 | 8 / 14.001 / 38 |

Across each complete captured interval, average allocation fell 19.3%, process
CPU 3.3%, and GC CPU 29.9%. These cumulative counters include idle work,
shutdown input, recorder overhead and other process threads. GC CPU is not a
wall-clock pause. The median stayed at 8 ms; p95 improved in both candidate
runs, while the maximum did not consistently improve. Fifteen command redraws
coincided with GC in each baseline run versus nine in each candidate run. The
measurements end at core redisplay, not physical presentation. Artifacts:
`/tmp/lem-uniform-width-revised-{before,after}-{1,2}.{csv,sh,log,kv}` and
`/tmp/lem-uniform-width-revised-results.json`.

The final rebuild passed all 15 native display, 27 configured screen-line and
83 Vundo checks (`/tmp/lem-uniform-width-revised-runtime.log`). The full T2
replay completed with medians of 1934.010/1177.006/135.001/126.001/335.002/
487.004/8527.041 ms for big-file/isearch/lisp-edit/long-line/overlay-heavy/
scroll/undo-storm. Long-line allocation was 111,754,784 bytes per workload.
These are unpaired trend results, not a speedup claim; the harness exited 2
because the Nova baseline remains absent. No baseline or budget was changed.
Result: `bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t2-20260919161353.json`;
log: `/tmp/lem-uniform-width-revised-t2.log`.

Final T3 passed unchanged budgets: warm startup 284.468 ms and
plain/bigfile/longline/scroll/truncate/wordwrap p95 histogram upper bounds of
1.024/1.024/4.096/1.024/2.048/2.048 ms. Result:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919161504.json`;
log: `/tmp/lem-uniform-width-revised-t3.log`. No installed editor profile was
activated. The bounded cache leaves codepoint-list construction and repeated
layout splits as remaining allocation targets; it does not eliminate long-line
GC-related stalls.

### Wait through strict idle-timer deadlines (2026-09-19)

After removing empty-poll redraws, the input loop still repeatedly called
`update-idle-timers` when the next deadline equaled the integer millisecond
clock. The scheduler's expiry condition is strictly `< deadline now`, so no
callback could run on that tick. A private observer of 140 paced keys counted
383820 empty updates and 144 updates with work; the callbacks were show-paren
(142) and scheduled syntax scan (2). The candidate observer counted zero empty
updates and the same 144 active updates and callback counts. These counts are
instrumented observations, not CPU or latency measurements. Artifacts:
`/tmp/lem-idle-spin-observed-{before,after}.{lisp,sh,txt,log,kv}`.

The input loop now dispatches overdue timers when the remaining delay is
negative and waits for `(1+ delay)` milliseconds otherwise, reaching the first
integer tick eligible for strict expiry. The wait uses the existing event
queue: queued input wakes it immediately. Input available before expiry is
accepted first; already-overdue callbacks retain their existing priority.
The timer scheduler, repetition rules and certified timer model are unchanged.
Timed waiting replaces polling; actual wake time still depends on clock
quantization and OS scheduling.

A deterministic test covers input one tick before the deadline, exactly at
it, and after expiry. It checks the queue timeout, accepted key, callback and
redraw counts, and expiry state using the real timer scheduler and queue.
The previous input loop fails the new assertions; the candidate passes. The
existing one-shot/repeating NIL-callback test now enqueues its key from the
callback, so it still exercises an empty deadline followed by real work rather
than preempting that work with a ready key. Logs:
`/tmp/lem-idle-spin-{before-regression,focused}.log`.

The packaged comparison used ABBA order separately for plain scratch-buffer
input (25 ms pacing) and the 200 KB word-wrapped line (100 ms pacing), with 140
keys and resource recording in every run. Baseline:
`/nix/store/3mmzch6avcci3y1vf8cg9w18k24mk26s-sbcl-lem-ncurses-unstable/bin/lem`.
Candidate:
`/nix/store/nn3zpap4kk6bidbrsmp3r9prqkhln63i-sbcl-lem-ncurses-unstable/bin/lem`.
The candidate derivation's input-loop and timer sources matched the checkout
byte for byte. All eight captures contained 140 paired redraws, no unpaired
redraws, no dropped samples and no recorder replacement.

| Case/run | Process CPU (ms) | Captured allocation (bytes) | Keystroke p50 / p95 / max (ms) |
| --- | ---: | ---: | --- |
| Plain before 1 | 109.410 | 5,996,560 | 0 / 1 / 3 |
| Plain after 1 | 51.478 | 5,996,560 | 0 / 1 / 4 |
| Plain after 2 | 55.858 | 5,996,560 | 0 / 1 / 3 |
| Plain before 2 | 106.159 | 5,996,560 | 0 / 1 / 3 |
| Long before 1 | 2526.965 | 3,805,963,776 | 8 / 11 / 35 |
| Long after 1 | 2484.821 | 3,805,520,384 | 8 / 11 / 35 |
| Long after 2 | 2491.505 | 3,806,030,976 | 8 / 11 / 40 |
| Long before 2 | 2565.192 | 3,806,103,680 | 8 / 11 / 36 |

Average process CPU fell 50.2% in the plain case (107.785 to 53.668 ms across
the captured interval) and 2.3% in the long-line case (2546.079 to 2488.163 ms).
The absolute savings were similar, about 54–58 ms per 140-key capture. Resource
deltas include between-key idle work, matched shutdown input, recording
overhead and other process threads. Allocation and median/p95 latency were
essentially unchanged; maximum latency did not improve consistently. Recorded
zero durations in the plain case reflect the approximately millisecond clock
resolution. There was no GC in the plain captures; nine command redraws
coincided with GC in each long-line capture. This is an efficiency improvement,
not evidence of a visible latency reduction or physical-display timing.
Artifacts: `/tmp/lem-idle-spin-{plain,long}-{before,after}-{1,2}.{csv,sh,log,kv}`
and `/tmp/lem-idle-spin-results.json`.

Validation passed all 15 native display, 27 configured screen-line and 83 Vundo
checks. The full core suite remains 74/75 with only the known undo-model
mismatch. All 12 ACL2 certificates remain current (cached; zero failures).
Logs: `/tmp/lem-idle-spin-{runtime,tests,proofs}.log`. T2's direct replay bypasses
this input-wait path, so it was not rerun for this change.

T3 passed unchanged budgets: warm startup 286.258 ms and
plain/bigfile/longline/scroll/truncate/wordwrap p95 histogram upper bounds of
1.024/1.024/4.096/1.024/2.048/2.048 ms. Result:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919162535.json`;
log: `/tmp/lem-idle-spin-t3.log`. No installed editor profile was activated.

### Retain SDL pixels between sparse screen updates (2026-09-19)

The client still repainted every cell for cursor-only updates. A short CPU
profile (144 samples; attribution only) put most samples in drawing, including
glyph lookups and SDL copy/fill calls (`/tmp/lem-sdl-repaint-profile.{lisp,txt}`).
The client now retains one window-sized texture and repaints changed rows plus
the old/new cursor rows. Decoded rows are replaced, so identity detects changes.
Resize, font metrics, defaults, row count and renderer resets invalidate reuse.
At this checkpoint, every presentation cleared and completely repainted the
window backbuffer, whose previous contents cannot be relied on after
[SDL_RenderPresent](https://wiki.libsdl.org/SDL2/SDL_RenderPresent). Retention
uses a separate [render target](https://wiki.libsdl.org/SDL2/SDL_SetRenderTarget).
Unavailable target storage falls back to full repaint and retries on resize/reset.
The extra pixel storage is one 32-bit window image (about 3 MB in this fixture).

An initial version increased full-update repaint CPU by roughly one third.
The final version paints directly when at least half the rows change, marking
the texture stale; the next sparse update rebuilds it before reuse. This avoids
paying for both a full repaint and a texture copy on dense updates.

Final ABBA comparisons used 120 updates after warmup, the real client event
loop, a private socket peer and a software renderer. CPU/bytes below are the
average of two runs per version, summed over those 120 drawing calls. The
socket-to-present p95 columns list both runs. Baseline source was extracted
from `b3d498dfe:frontends/daemon/sdl-client.lisp`; both versions used the same
current Lisp environment. Resource counters include concurrent process threads
and recorder overhead; allocation counts Lisp bytes, not SDL/native storage.

| Backend / update | Draw CPU before → after (ms) | Lisp bytes before → after | Socket-to-present p95 before → after (ms) |
| --- | ---: | ---: | --- |
| Dummy / cursor | 134.664 → 28.205 | 23,796,608 → 703,040 | 2/3 → 2/2 |
| Dummy / one row | 145.191 → 30.279 | 25,864,256 → 805,696 | 3/2.999 → 2/2 |
| Dummy / full | 148.156 → 148.510 | 25,913,216 → 26,583,936 | 3/3 → 3/3.001 |
| Private X11 / cursor | 178.151 → 28.151 | 23,838,336 → 755,200 | 2/2 → 1/1 |

Sparse repaint CPU fell about 79–84% and Lisp allocation about 97%. Full-update
CPU stayed within baseline variation, with about 2.6% more Lisp allocation for
cache bookkeeping. Timing resolution is approximately 1 ms; zero samples mean
below that resolution. These endpoints are SDL presentation calls, not physical
keyboard-to-monitor measurements. Artifacts:
`/tmp/lem-sdl-adaptive-{cursor,row,full,x11}-{before,after}-{1,2}.log` and
`/tmp/lem-sdl-retained-resources.lisp`.

Pixel comparisons against full repaint pass on dummy and private X11 displays:
Unicode/styles, cursor movement/shape/removal, shorter/empty/replaced rows,
themes, row-count changes, resize, reset, allocation failure, and dense-to-sparse
recovery. Unchanged valid frames issue no glyph draws. The benchmark's pixel
capture now runs before presentation, and window repaints cannot acknowledge an
older screen while an update is in flight. Both fixture captures match SHA-256
`0be3e7682a118983994adc6e6bdb43ab23a0ed9f4dc4a6809b9bae5fb37c165e`.

Run pixel tests with `SDL_VIDEODRIVER=dummy scripts/run-tests.sh lem-daemon/sdl-render/tests`
in `nix develop`. The presentation benchmark now accepts `LEM_SDL_UPDATE_MODE`
values `cursor`, `row`, and `full`; use `LEM_SDL_PIXELS` separately because
readback adds measurement overhead. Graphical queue/reader tests pass, as do all
15 packaged native-client checks. Logs: `/tmp/lem-sdl-adaptive-{pixels,native}.log`,
`/tmp/lem-sdl-adaptive-x11-pixels.log`, `/tmp/lem-sdl-retained-client-tests.log`.
The checked package is `/nix/store/ba46fwnphcjjng0l8qhvv15z9h2hk1g8-sbcl-lemclient-unstable/bin/lemclient`;
its client source and ASDF definition matched the checkout. No core/kernel
source, proof obligation, benchmark budget or installed profile changed.

### Reuse single-character cells during daemon composition (2026-09-19)

The daemon's `implementation-screen` reconstructed every cell via `overlay-text`,
even though view rows already contained display cells. This allocated another
single-character string and measured its width twice for most occupied cells,
including spaces. The compositor now reuses single-character cell strings and
measures their current width once. A shared placement function preserves wide
cell cleanup, clipping and combining-character attachment. Multi-character
cells retain the original character-by-character path. Row edits replace strings;
composed screen arrays remain independent snapshots. Widths are recomputed from
live icon and ambiguous-width settings rather than trusted from old continuations.

`scripts/bench/e2e/daemon-composition.lisp` exercises the real frame compositor
on a 100×40 view, with ASCII and Unicode/control/combining text plus blank padding.
Each case composes 3,000 frames after 100 warmups. Cursor mode does not rerender
view rows; row/full modes call the daemon's `render-line` on one/all rows first.
The fixture measures server rendering/composition, including fresh screen arrays,
but excludes core redisplay, diff comparison, encoding, transport and client
presentation. It is not an end-to-end input-latency benchmark.

ABBA comparisons used the same patched SBCL environment. Baseline definitions
of `overlay-text` and `overlay-cells` were extracted from
`818f1e89c:frontends/daemon/implementation.lisp` to `/tmp/lem-overlay-before.lisp`
and loaded with `LEM_OVERLAY_SOURCE`. CPU and Lisp bytes below are means of two
runs, summed over 3,000 compositions. No builds or tests ran concurrently.

| Text / rerender | CPU before → after (ms) | Lisp bytes before → after |
| --- | ---: | ---: |
| ASCII / none | 797.442 → 460.836 | 612,764,288 → 219,480,192 |
| Unicode / none | 769.915 → 476.145 | 588,057,472 → 241,709,184 |
| ASCII / one row | 803.244 → 473.493 | 618,642,688 → 224,696,320 |
| Unicode / one row | 778.034 → 481.847 | 590,298,496 → 244,579,840 |
| ASCII / all rows | 1155.431 → 790.870 | 805,724,928 → 415,931,392 |
| Unicode / all rows | 1005.140 → 699.250 | 686,332,160 → 342,010,240 |

CPU fell 38–42% for unchanged/one-row frames and 30–32% for full rerenders;
allocation fell 48–64%. The absolute saving is about 0.10–0.12 ms per frame in
these fixtures, so this does not explain a large perceived input delay by itself.
Artifacts: `/tmp/lem-composition-final-{before,after}-{1,2}.log`.

All five daemon test modules pass, including 3,150 differential composition
cases against the frozen placement algorithm, live icon-width changes, snapshot
independence under later edits, session isolation and stopped-reader backpressure.
Log: `/tmp/lem-composition-tests.log`. No core/kernel source, proof obligation,
benchmark budget or installed profile changed.

The graphical client unit tests and all 15 packaged native-client checks also
pass (`/tmp/lem-composition-sdl-tests.log`, `/tmp/lem-composition-native.log`).
The tested packages are
`/nix/store/600jwp8x7gr6cxm9aksdrmcqw3xm2gq0-sbcl-lem-ncurses-unstable/bin/lem`
and `/nix/store/qdrzlkb6vyjdq7nhvxaz217r1dfk7y11-sbcl-lemclient-unstable/bin/lemclient`.
Their derivation inputs matched the modified daemon implementation and protocol
tests byte for byte. The previously documented core undo-model mismatch is
outside this change; the core suite was not rerun for this daemon-only edit.

### Avoid daemon text invalidation for cursor background changes (2026-09-19)

A private multi-client typing probe found that every daemon frame restoration
called the configured Vi cursor hook, which marked the entire focused window
dirty. A trace through `need-to-redraw` identified that hook; an experiment that
only removed forced peer redraws still encountered dirty windows on every visit.
The workaround exists for standalone ncurses, whose cursor cell caches its color.
Daemon clients instead receive cursor color and shape separately in every screen
message, and server text cells exclude the primary cursor background.

The configured hook now avoids daemon text invalidation for background-only
cursor updates. It still invalidates when Vi clears custom bold, underline or
reverse text styling, and standalone frontends retain the original behavior.
No new cache or change to peer redraw scheduling was introduced.

`scripts/bench/e2e/daemon-input.py` starts a private configured daemon and one or
four protocol clients on a shared 1,000-line buffer. Each capture alternates
insertion and Backspace, checks the resulting text on every peer, and verifies
that the final buffer equals the original file. There are 20 warmup keys and
200 latency samples, with 25 ms sleeps between completed updates. Timings run
from socket write to decoding the matching screen, excluding terminal/SDL
rendering and physical keyboard/monitor latency. Resource counters cover all
220 keys, intervening idle work and boundary eval requests; GC time is CPU time.
All eight captures completed, and no builds/tests ran during measurement.

ABBA runs used these configured packages:

- Before: `/nix/store/089nq54j3micf84s4qh7fgcbf72dklhl-lem-yath/bin/lem`.
- After: `/nix/store/qs8sy9hjy4sgxdg9h314y3wdx5h120qz-lem-yath/bin/lem`.

| Clients | Mean process CPU before → after (ms) | Mean Lisp bytes before → after | Active p50, both runs before → after (ms) | Active p95, both runs before → after (ms) |
| --- | ---: | ---: | --- | --- |
| 1 | 234.034 → 228.859 | 59,733,440 → 59,556,992 | 0.642/0.675 → 0.644/0.633 | 0.885/0.916 → 0.953/0.826 |
| 4 | 865.552 → 827.897 | 394,609,216 → 346,404,800 | 0.887/0.908 → 0.692/0.680 | 1.204/1.101 → 0.943/0.883 |

With four clients, allocation fell 12.2% and CPU 4.4%. Active-client median
latency improved by about 0.2 ms. Time to update every client had p95 values
2.495/2.399 ms before and 2.181/2.126 ms after. Maximum latency did not improve:
all-client maxima were 4.004/2.936 ms before and 5.428/3.991 ms after. Single-client
latency showed no consistent improvement. Artifacts:
`/tmp/lem-daemon-cursor-{1,4}-{before,after}-{1,2}.{json,log}`.

All 16 packaged native-client checks pass, including a new real-connection
check that normal/insert/Emacs cursor changes preserve text caches while sending
the correct color and shape, and that clearing custom cursor text styling still
invalidates the window. The complete standalone cursor/state suite also passes,
including themes, reloads, buffer-local states, raw terminal shape/color and
clean exit. Log: `/tmp/lem-daemon-cursor-final-runtime.log`. The candidate's
configured cursor source matched the checkout byte for byte.

The cursor test's exit check was checkpointed separately: it now records the
direct child wait status, avoiding missing tmux pane status observed in Nix runs.
It still requires status zero and a final steady box cursor. The revised test
also passes against the preceding package (`/tmp/lem-cursor-baseline-supervised.log`).
Core/kernel sources, proof obligations, benchmark budgets and installed profiles
were unchanged; the previously documented undo-model mismatch remains separate.

### Reuse peer rows while forwarding display invalidation (2026-09-19)

After removing redundant cursor invalidation, forced redraws of every daemon
peer remained a substantial cost. Ordinary peer updates now use their existing
row caches. The after-redraw hook receives `*after-redraw-display-force*`, scoped
to the completed frame, and forwards it to peers. This value includes explicit
force and dirty-window cache invalidation, preserving recoloring of attributes
shared across frames. Hook arity, session routing and output backpressure are
unchanged; direct `redraw-other-sessions` calls still default to forced repaint.

Forwarding only the explicit `:force` argument was insufficient. The drawing
object cache retains attribute references, so recoloring in place requires its
existing dirty-window invalidation. A new shared-overlay regression fails both
peer-color comparisons without forwarding that invalidation, and passes with it.
Tests also cover unchanged rows, shared edits at different frame widths,
Unicode/face/cursor equality against full repaint, explicit force, local peer
invalidation, nested hooks, suppressed force and restoration after hook errors.
Logs: `/tmp/lem-peer-invalidation-tests.log`, `/tmp/lem-peer-negative-check.log`.

Final ABBA captures used `daemon-input.py` with 20 warmup keys, 200 measured keys,
and 25 ms pacing. Resource counters include all 220 keys, idle time and boundary
evals. All clients observed every resulting edit, and each final buffer matched
the original file. No build or test ran concurrently. Packages:

- Before: `/nix/store/qs8sy9hjy4sgxdg9h314y3wdx5h120qz-lem-yath/bin/lem`.
- After: `/nix/store/ardnn7l3z4l4s9sfg6plkr9ah29pzrmy-lem-yath/bin/lem`.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after | All-client p50, both runs before → after (ms) | All-client p95, both runs before → after (ms) |
| --- | ---: | ---: | --- | --- |
| 1 | 220.454 → 220.020 | 59,335,616 → 59,548,224 | 0.644/0.483 → 0.477/0.663 | 0.821/0.835 → 0.855/0.743 |
| 4 | 806.636 → 577.436 | 345,847,744 → 204,161,344 | 1.956/1.895 → 1.309/1.422 | 2.084/2.064 → 1.712/1.724 |

Four-client CPU fell 28.4% and allocation 41.0%. Updating every peer became
faster, but the active client's p95 was slightly higher: 0.769/0.779 ms before
versus 0.845/0.828 ms after. Its maxima were 1.058/1.055 ms before versus
4.026/4.824 ms after. All-client maxima were 4.173/5.348 versus 4.703/5.565 ms.
These captures do not attribute individual stalls; this is a multi-client
resource/refresh improvement, not a universal tail-latency improvement.
Single-client behavior was within run variation, with 0.36% more allocation.
Timings end at decoded screen messages, excluding native rendering and physical
presentation. Artifacts: `/tmp/lem-peer-force-{1,4}-{before,after}-{1,2}.{json,log}`.

Validation passed all five daemon test modules, 16 native-client checks,
27 screen-line checks, 83 Vundo checks and 36 cursor-state checks. The full core
suite remains 74/75, with only the known undo-model mismatch. Logs:
`/tmp/lem-peer-force-{runtime,core-tests}.log`. All five modified Lisp source
files matched the tested base derivation byte for byte. Its executable is
`/nix/store/2mfrqwvav01iim8rsm5vn9pdn8dxh33v-sbcl-lem-ncurses-unstable/bin/lem`.

T3 passed unchanged budgets: warm startup 286.851 ms and plain/bigfile/longline/
scroll/truncate/wordwrap p95 histogram upper bounds of
1.024/1.024/4.096/1.024/1.024/4.096 ms. Result:
`bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919180539.json`;
log: `/tmp/lem-peer-force-t3.log`. Kernel sources, proof obligations and installed
profiles were unchanged.


### Attribute daemon typing tails to resource activity (2026-09-19)

`daemon-input.py --resources` now loads a private diagnostic that attaches the
input ID and receive/screen resource counters to active-client screen messages.
The driver validates the ID and nondecreasing counters for every measured input.
The Lisp wrappers are installed only in the disposable daemon, not in production
builds. They can be removed with `lem-bench/daemon-input-resources:stop`.
For example, with `LEM_BIN` pointing at the configured package:

```sh
python3 scripts/bench/e2e/daemon-input.py --clients 4 --count 600 \
  --resources --output /tmp/daemon-input-resources.json
```

Each sample's `server` object contains `received-*` and `screen-*` counters for
`wall`, `cpu`, `gc-cpu` and `consed`. Convert time differences using
`units-per-second`; allocation differences are bytes. The endpoint is entry to
`daemon-send`, before encoding, queueing and socket writing. CPU, GC and allocation
are process-wide, so other daemon threads contribute. GC CPU is not a wall pause;
SBCL wall counters also have coarser resolution than Python's wire timer. These
counters cannot attribute stalls outside their endpoints. Instrumentation itself
adds metadata, allocations and locking: use plain runs for speed comparisons.

Four-client ABBA captures used the preceding section's before/after packages,
600 measured keys, 20 warmup keys and 25 ms pacing. Every peer saw every edit and
all final buffers matched the fixture. No build, test or second benchmark ran
concurrently. The instrumented captures showed:

| Package/run | Active maximum (ms) | Inputs with GC between receive and screen | Active maximum without GC in that interval (ms) |
| --- | ---: | ---: | ---: |
| Before 1 | 1.162 | 0 | 1.162 |
| Before 2 | 2.673 | 1 | 1.251 |
| After 1 | 4.207 | 2 | 1.284 |
| After 2 | 4.825 | 1 | 1.269 |

All three candidate inputs above 2 ms coincided with GC in the measured interval:
wire latencies 4.207/2.750/4.825 ms and GC CPU deltas 9.578/4.829/9.973 ms.
The baseline's 2.673 ms input also coincided with GC (4.746 ms CPU).
This supports GC timing as an explanation for occasional active-client tails;
it does not prove the cause of individual stalls in the earlier plain captures.
Artifacts: `/tmp/lem-tail-resources-{before,after}-{1,2}.{json,log}`.

A separate uninstrumented ABBA repeated the same workload:

| Metric | Before, both runs | After, both runs |
| --- | --- | --- |
| Active p95 (ms) | 0.872 / 0.822 | 0.816 / 0.843 |
| Active maximum (ms) | 1.155 / 2.478 | 1.388 / 4.752 |
| All-client p95 (ms) | 2.180 / 2.121 | 1.717 / 1.703 |
| All-client maximum (ms) | 3.945 / 4.015 | 4.887 / 5.447 |
| Mean process CPU (ms, 620 keys plus idle/boundary evals) | 2,291.078 | 1,624.537 |
| Mean Lisp allocation (bytes) | 971,488,224 | 572,121,440 |

CPU fell 29.1% and allocation 41.1%, consistent with the earlier cache result.
All-peer p95 improved; active-client p95 was similar and maxima remained variable.
No universal tail-latency improvement is claimed. Artifacts:
`/tmp/lem-tail-plain-{before,after}-{1,2}.{json,log}`.

A separate private-daemon smoke check verifies wrapper installation, rejection of
nested start, exact function restoration, repeated stop and restart, followed by
20 successful real input updates and final-buffer equality:
`/tmp/lem-tail-resource-check.{lisp,json,log}`. The diagnostic captures also check
input-ID association and resource monotonicity. This checkpoint changes only
benchmark instrumentation and documentation; production sources, proof
obligations, budgets and installed profiles are unchanged. The previously
recorded core undo-model mismatch remains unresolved.


### Reuse private daemon composition grids (2026-09-19)

An allocation profile of configured four-client typing (600 measured keys plus
20 warmup keys) recorded 18,847 samples, without reaching the sample cap.
`implementation-screen` accounted for 61.4% of samples, predominantly allocating
fresh cell/face arrays. This was SBCL `sb-sprof` allocation mode, all threads,
one approximately 32 KB allocation region per sample. It attributes sampled
allocation, not exact byte counts or latency. Artifacts:
`/tmp/lem-daemon-input-allocation-profile.{lisp,txt,json,log}`.

Each daemon implementation now alternates two private composition grids. Before
composing, it clears every cell and face in the spare grid. The previous grid
remains intact for full/delta selection and row comparison; output writers own
encoded octets, never these arrays. Size changes allocate correctly sized
storage. The default `implementation-screen` call still returns a fresh snapshot;
only the display update path supplies reusable storage. Composition, live glyph
width lookup, face capture, repaint decisions and queue/backpressure limits are
unchanged. This retains one additional grid per client (about 64 KiB of cell/face
array payload at 100 by 40, plus headers), in exchange for less transient garbage.

A new regression reconstructs the actual queued full/delta messages and compares
them with fresh composition across Unicode/combining text, face changes, stale
rows, empty frames, clipping after view movement, both resize dimensions and a
forced full snapshot reset. It checks cursor coordinates, independent alternating
grids and immutable queued bytes after reuse. All 39 assertions pass. Removing
face clearing in a private negative control produces six failures, including
stale wire styles. Logs: `/tmp/lem-screen-reuse-regression-vectors.log` and
`/tmp/lem-screen-reuse-negative.log`.

All five daemon test modules pass, including backpressure and shutdown behavior.
The packaged native-client check passes all 16 checks, including mixed SDL/terminal
clients, Unicode paste, resizing, mode/prompt routing and peer failure:
`/tmp/lem-screen-reuse-native.log`. The modified implementation and regression
source matched the tested base derivation byte for byte. Packages:

- Before: `/nix/store/ardnn7l3z4l4s9sfg6plkr9ah29pzrmy-lem-yath/bin/lem`.
- After: `/nix/store/4m312faznms4x9pnndcsbg4d9jh37gqc-lem-yath/bin/lem`.
- Tested base: `/nix/store/bj6ar7cyxdv21vdzx1c9d4siqk7g27pg-sbcl-lem-ncurses-unstable/bin/lem`.

Uninstrumented ABBA comparisons used 600 measured keys, 20 warmup keys and 25 ms
pacing, separately for one and four clients. Every peer observed every edit and
all final buffers matched their fixtures. No test, build or other benchmark ran
concurrently. Resource counters cover all 620 keys, idle time and boundary evals.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after | Mean GC CPU before → after (ms) |
| --- | ---: | ---: | ---: |
| 1 | 643.326 → 629.351 | 162,434,464 → 75,600,544 | 9.140 → 8.509 |
| 4 | 1,588.101 → 1,531.617 | 571,925,152 → 220,678,496 | 27.678 → 16.615 |

Allocation fell 53.5%/61.4% with one/four clients. Mean CPU fell 2.2%/3.6%,
a much smaller difference than allocation; four-client GC CPU fell about 40%.
GC CPU remains a process-wide CPU measure, not a wall-clock pause.

| Clients / endpoint | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- |
| 1 / active | 1.019/0.946 → 0.994/0.928 | 3.799/1.464 → 3.642/1.386 |
| 4 / active | 0.988/0.941 → 1.019/0.854 | 2.596/1.239 → 4.680/1.191 |
| 4 / all peers | 1.821/1.820 → 1.854/1.727 | 5.773/4.936 → 5.351/4.453 |

Latency varied between runs and occasional multi-millisecond stalls remain.
This is primarily an allocation reduction, not evidence of a consistent typing
latency improvement. The endpoint is decoded protocol output, excluding native
rendering and physical presentation. Artifacts:
`/tmp/lem-screen-reuse-{1,4}-{before,after}-{1,2}.{json,log}`.

Kernel sources, proof obligations, benchmark budgets and installed profiles are
unchanged. The core suite was not rerun for this daemon-only change; its previously
recorded undo-model mismatch remains separate.


### Declare the compositor's actual array types (2026-09-19)

After grid reuse, a fresh four-client allocation profile recorded 7,382 samples;
mode predicates accounted for 20.8% of sampled allocation. A separate CPU profile
(1,437 samples at 1 ms) showed a different priority: `overlay-cells` accounted for
56.3% of sampled CPU, while `all-active-modes` accounted for only 1.4%. Generic
array access and arithmetic dominated composition. These profiles included all
daemon threads and the 600-key workload plus 20 warmups; they are attribution
samples, not timing gates. Artifacts:
`/tmp/lem-daemon-grid-{allocation,cpu}-profile.{lisp,txt,json,log}`.

The two `cell-row` array slots now declare `simple-vector`, matching every
constructor and caller in the repository. This lets the compiler specialize
access and length operations. The compositor algorithm, width calculations,
queue ownership, storage reuse and safety settings are unchanged. Disassembly of
`overlay-cell`, `clear-cell-at` and `overlay-cells` shows ten calls to generic
`VECTOR-HAIRY-DATA-VECTOR-*` helpers before, and none after; bounds-error paths
remain. Artifacts: `/tmp/lem-cell-types-disassembly-{before,after}.{txt,json,log}`.

All five daemon test modules and 16 packaged native-client checks pass, including
the 3,150 differential placement cases, live width changes, queued snapshots,
backpressure, mixed clients and resizing. Logs:
`/tmp/lem-cell-types-{tests,native}.log`. The implementation source matched the
tested base derivation byte for byte. Packages:

- Before: `/nix/store/4m312faznms4x9pnndcsbg4d9jh37gqc-lem-yath/bin/lem`.
- After: `/nix/store/7h14rdq9jr220gvy0bimbyjx8z5qa098-lem-yath/bin/lem`.
- Tested base: `/nix/store/kr17icfhmcrbfdyyq79l61vxqkk0cpnp-sbcl-lem-ncurses-unstable/bin/lem`.

Uninstrumented ABBA captures used one/four clients separately, 600 measured keys,
20 warmup keys and 25 ms pacing, with no concurrent build/test/benchmark. Every
client saw every edit; each final buffer matched its fixture. Counters include
all 620 keys, idle time and boundary evals.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| 1 | 580.215 → 514.093 | 75,606,560 → 75,461,792 |
| 4 | 1,580.173 → 1,291.266 | 220,744,992 → 220,793,376 |

Mean CPU fell 11.4%/18.3% for one/four clients; allocation was effectively
unchanged. Four-client GC CPU was also similar (18.937 → 18.772 ms).

| Clients / endpoint | p50, both runs before → after (ms) | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- | --- |
| 1 / active | 0.554/0.585 → 0.562/0.554 | 0.740/0.852 → 0.813/0.783 | 4.168/1.469 → 1.168/3.776 |
| 4 / active | 0.679/0.638 → 0.594/0.600 | 1.025/0.838 → 0.829/0.822 | 1.374/1.398 → 1.245/3.872 |
| 4 / all peers | 1.390/1.329 → 1.120/1.137 | 1.850/1.723 → 1.592/1.587 | 2.452/5.031 → 1.938/4.334 |

Four-client medians/p95 improved in these captures; single-client latency and
maxima varied. Occasional multi-millisecond stalls remain, so this does not
establish a universal tail-latency improvement. Measurements end at decoded
protocol output, excluding native rendering and physical presentation.
Artifacts: `/tmp/lem-cell-types-{1,4}-{before,after}-{1,2}.{json,log}`.

Core mode predicates were not changed. Kernel sources, proof obligations,
benchmark budgets and installed profiles are unchanged. The core suite was not
rerun for this daemon-only change; its previously recorded undo-model mismatch
remains separate.


### Replace ordinary cells without redundant clearing (2026-09-19)

For a one-column write, `overlay-cell` now replaces the string and face directly
when the old cell neither starts nor continues a wide glyph. Otherwise it uses
the existing wide-glyph repair before writing. Zero-width combining behavior and
clipping are unchanged. The wider-cell fallback computes its end column once,
reusing it for bounds, both loops and the return value. Live character width
lookup, face values and storage ownership are unchanged.

A new differential regression covers 396 boundary/face cases, comparing writes
into ASCII, wide and combining-text rows with the frozen reference algorithm.
The existing 3,150 composition cases and live icon-width tests also pass.
Removing the wide-head repair in a private negative control fails at width 2,
column 0, over `漢字abc`, demonstrating that the test detects orphaned continuation
cells. All five daemon test modules and 16 packaged native-client checks pass.
Logs: `/tmp/lem-single-cell-v2-{tests,native,negative}.log`. The implementation and
regression sources matched the tested base derivation byte for byte.

An isolated ABBA comparison used `daemon-composition.lisp`: 100 warmups followed
by 3,000 100-by-40 compositions per case. The before run loaded the exact committed
`overlay-cell` definition from `df7df0dd8`; the after run used the final checkout.
Other code and dependencies were identical. This includes fresh snapshot grid
allocation and optional row rendering, but excludes core redisplay, encoding,
transport and native presentation. A separate wide-only capture fills each row
with 50 CJK characters, exercising the fallback without ordinary cells. This
fixture is now also included in the checked-in composition benchmark.

| Fixture | Work per composition | Mean CPU before → after (ms, 3,000 compositions) |
| --- | --- | ---: |
| ASCII | Compose only | 317.826 → 171.784 |
| ASCII | Render one row, compose | 323.942 → 174.941 |
| ASCII | Render all rows, compose | 564.819 → 339.863 |
| Mixed Unicode | Compose only | 320.776 → 190.940 |
| Mixed Unicode | Render one row, compose | 336.564 → 193.310 |
| Mixed Unicode | Render all rows, compose | 487.169 → 319.111 |
| Wide only | Compose only | 255.330 → 243.252 |
| Wide only | Render one row, compose | 264.094 → 251.126 |
| Wide only | Render all rows, compose | 598.298 → 565.793 |

CPU fell 34.5–46.0% in ASCII/mixed cases and 4.7–5.4% in wide-only cases;
allocation was effectively unchanged. Artifacts:
`/tmp/lem-single-cell-{micro,wide}-v2-{before,after}-{1,2}.log`.

Final packaged before/after executables:

- Before: `/nix/store/7h14rdq9jr220gvy0bimbyjx8z5qa098-lem-yath/bin/lem`.
- After: `/nix/store/imrpjf3qs8zndks1c3i6j3k1ih31gzhv-lem-yath/bin/lem`.
- Tested base: `/nix/store/4jgszpxpsszwff11f5vlr4z53mk6rpyr-sbcl-lem-ncurses-unstable/bin/lem`.

Uninstrumented packaged ABBA captures used one/four clients separately, 600
measured keys, 20 warmup keys and 25 ms pacing. No test, build or other benchmark
ran concurrently. Every peer observed every edit, and final buffers matched their
fixtures. Resource counters include all 620 keys, idle time and boundary evals.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| 1 | 523.863 → 435.341 | 75,624,736 → 75,416,864 |
| 4 | 1,279.318 → 1,016.270 | 220,968,416 → 220,861,088 |

Mean CPU fell 16.9%/20.6% for one/four clients, with little allocation change.

| Clients / endpoint | p50, both runs before → after (ms) | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- | --- |
| 1 / active | 0.561/0.564 → 0.468/0.522 | 0.740/0.814 → 0.619/0.729 | 1.047/4.325 → 1.149/3.626 |
| 4 / active | 0.499/0.598 → 0.516/0.506 | 0.798/0.792 → 0.731/0.732 | 1.227/1.197 → 0.953/1.253 |
| 4 / all peers | 1.043/1.166 → 0.950/0.936 | 1.564/1.563 → 1.265/1.255 | 5.313/5.029 → 4.887/3.985 |

Single-client median/p95 improved in both runs; four-client active medians
overlapped, while active/all-peer p95 and all-peer medians improved. Maxima remain
variable and occasional multi-millisecond stalls persist. Measurements end at
decoded protocol output, excluding native rendering and physical presentation.
Artifacts: `/tmp/lem-single-cell-v2-{1,4}-{before,after}-{1,2}.{json,log}`.

Kernel sources, proof obligations, benchmark budgets and installed profiles are
unchanged. The core suite was not rerun for this daemon-only change; its previously
recorded undo-model mismatch remains separate.

The expanded checked-in composition benchmark completed all nine fixtures with
expected checksums: `/tmp/lem-single-cell-final-benchmark-smoke.log`.


### Query active modes without constructing a mode list (2026-09-19)

The earlier allocation profile attributed 20.8% of samples to `mode-active-p`,
which built `all-active-modes` solely to answer a boolean query. The predicate
now walks the existing local-minor, major, global-minor and global sources in
that order. It still resolves registration names through `ensure-mode-object`
and compares identifiers with EQL through `mode-identifier-name`; it returns
strict T/NIL. There is no cache. `all-active-modes` itself is unchanged.

A new core regression compares against the previous query for 384 combinations
of symbol/object storage and queries, checks identifier visitation order, and
exercises re-registration, removal and dynamically rebound global modes. Alias
registration names deliberately differ from identifiers, preventing a shortcut
that merely tests list membership. Object-valued modes retain their identity
when registration changes. The core suite is 75/76; only the known undo-model
tick mismatch fails (matching text and points, production/model ticks 0/1).
Log: `/tmp/lem-mode-query-core.log`.

All five daemon test modules pass. Packaged checks pass all 16 native-client,
27 screen-line, 83 Vundo and 36 cursor-state cases. Logs:
`/tmp/lem-mode-query-{daemon,runtime}.log`. The modified core source, test source
and ASDF test registration matched the tested base derivation byte for byte.
Packages:

- Before: `/nix/store/imrpjf3qs8zndks1c3i6j3k1ih31gzhv-lem-yath/bin/lem`.
- After: `/nix/store/h6vik6hdxh1q6bis73wh9n5ybv1jxi8x-lem-yath/bin/lem`.
- Tested base: `/nix/store/sji9dikc3nqx5b79wf6r6lc0i8hl8c7l-sbcl-lem-ncurses-unstable/bin/lem`.

A private configured-daemon ABBA component test performed one million queries
per case after 10,000 warmups and full GC. Hit counts were asserted. Counters
are process-wide, including other daemon threads, so small residual allocation
is not an exact per-query census. It excludes command handling and rendering.

| Query | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| Active major | 94.555 → 62.657 | 208,062,144 → 22,848 |
| Active global | 160.899 → 145.314 | 208,043,136 → 0 |
| Missing identifier | 160.452 → 122.389 | 208,095,424 → 11,392 |

Artifacts: `/tmp/lem-mode-query-micro.lisp` and
`/tmp/lem-mode-query-micro-{before,after}-{1,2}.{txt,json,log}`.

Uninstrumented typing ABBA captures used one/four clients separately, 600 measured
keys, 20 warmup keys and 25 ms pacing. No build, test or other benchmark ran
concurrently. Every client observed every edit and final buffers matched the
fixtures. Counters cover all 620 keys, idle time and boundary evals.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after | Mean GC CPU before → after (ms) |
| --- | ---: | ---: | ---: |
| 1 | 498.090 → 495.393 | 75,438,496 → 61,782,496 | 8.899 → 9.473 |
| 4 | 1,078.574 → 1,057.033 | 220,744,608 → 171,347,808 | 16.713 → 9.870 |

Allocation fell 18.1%/22.4% for one/four clients. Mean CPU fell only 0.5%/2.0%.
GC CPU is a process-wide CPU measure, not a wall-clock pause.

| Clients / endpoint | p50, both runs before → after (ms) | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- | --- |
| 1 / active | 0.577/0.572 → 0.573/0.573 | 0.847/0.838 → 0.840/0.860 | 1.124/1.295 → 4.126/3.997 |
| 4 / active | 0.555/0.606 → 0.561/0.603 | 0.847/0.856 → 0.811/0.823 | 3.581/3.695 → 1.172/1.247 |
| 4 / all peers | 0.956/1.003 → 0.965/0.994 | 1.441/1.450 → 1.358/1.430 | 4.111/4.245 → 1.625/1.679 |

This is an allocation reduction, not a consistent latency improvement. The
single-client maxima worsened in these captures while four-client maxima
improved; these plain captures do not attribute individual stalls. Protocol
measurements exclude native rendering and physical presentation. Artifacts:
`/tmp/lem-mode-query-{1,4}-{before,after}-{1,2}.{json,log}`.

T3 passed unchanged budgets: warm startup 286.811 ms; plain/bigfile/longline/
scroll/truncate/wordwrap p95 histogram upper bounds were
1.024/1.024/4.096/2.048/2.048/2.048 ms. Log: `/tmp/lem-mode-query-t3.log`.
Result: `bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919190650.json`.
Kernel sources, proof obligations, benchmark budgets and installed profiles
are unchanged. The previously documented undo-model mismatch remains unresolved.


### Encode byte RGB colors directly (2026-09-19)

A refreshed allocation profile after the mode-query change recorded 5,684
samples; `color-to-hex-string` accounted for 11.7%. This uses SBCL allocation
sampling across all daemon threads during configured four-client typing (600
measured keys plus 20 warmups), not an exact byte census. Artifacts:
`/tmp/lem-mode-query-allocation-profile.{lisp,txt,json,log}`.

For three unsigned-byte RGB components, `color-to-hex-string` now fills a fresh
seven-character base string directly. It keeps the original FORMAT expression
for other values: color slots are unrestricted, so negative/out-of-range numbers,
non-integers and other objects retain their previous formatting behavior. There
is no cache; in-place color changes are immediately visible and old returned
strings remain independent. The normal result remains a simple base string on
the tested SBCL, matching the preceding implementation.

New regressions compare 65,536 RGB triples against the old formatter, covering
every pair of channel bytes. They also compare 1,080 combinations of byte and
non-byte values, channel positions, print bases, print cases and radix settings,
including error outcomes, and check result independence/color mutation.
The core suite is 76/77, with only the known undo-model tick mismatch (equal
text/points, production/model ticks 0/1). All five daemon modules and the SDL
pixel regression module pass. Packaged checks pass all 16 native-client,
27 screen-line, 83 Vundo and 36 cursor-state cases. Logs:
`/tmp/lem-color-hex-{core,daemon,pixels,runtime}.log`. Modified source, test and
ASDF registration matched the tested base derivation byte for byte. Packages:

- Before: `/nix/store/h6vik6hdxh1q6bis73wh9n5ybv1jxi8x-lem-yath/bin/lem`.
- After: `/nix/store/i51wiqkz21vi76mwm2kbjb6kq3qnglfa-lem-yath/bin/lem`.
- Tested base: `/nix/store/49f4dzz8l9zmdyvciz6zysy6qfjjqjw4-sbcl-lem-ncurses-unstable/bin/lem`.

A private configured-daemon ABBA component test made one million conversions
per case after 10,000 warmups and full GC, asserting output/checksums. Counters
include all daemon threads; small residual variation is not per-call allocation.

| Color case | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| RGB bytes | 157.383 → 9.538 | 176,401,024 → 32,022,912 |
| Out-of-range/float fallback | 184.117 → 180.695 | 160,160,448 → 160,175,680 |

The byte case used 93.9% less CPU and 81.8% less allocation; the fallback was
within run variation. These are conversion-only results, excluding rendering
and input handling. Artifacts: `/tmp/lem-color-hex-micro.lisp` and
`/tmp/lem-color-hex-micro-{before,after}-{1,2}.{txt,json,log}`.

Uninstrumented typing ABBA captures used one/four clients separately, 600 measured
keys, 20 warmup keys and 25 ms pacing, without concurrent tests/builds/benchmarks.
Every peer observed every edit, and final buffers matched the fixtures. Counters
cover all 620 keys, idle time and boundary evals.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| 1 | 403.002 → 396.702 | 61,978,528 → 57,837,216 |
| 4 | 1,052.169 → 1,005.153 | 171,641,056 → 156,766,752 |

Allocation fell 6.7%/8.7%, and mean CPU fell 1.6%/4.5% for one/four clients.

| Clients / endpoint | p50, both runs before → after (ms) | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- | --- |
| 1 / active | 0.436/0.482 → 0.418/0.469 | 0.650/0.707 → 0.625/0.644 | 3.353/3.803 → 0.827/3.405 |
| 4 / active | 0.494/0.551 → 0.498/0.511 | 0.663/0.761 → 0.693/0.758 | 4.523/1.567 → 1.067/1.231 |
| 4 / all peers | 0.968/0.956 → 0.946/0.930 | 1.198/1.305 → 1.225/1.303 | 4.954/4.116 → 5.254/4.994 |

Single-client latency improved slightly in these captures; four-client latency
was mixed, with higher all-peer maxima in the candidate. This is not a consistent
tail-latency improvement. Measurements end at decoded protocol output, excluding
native rendering and physical presentation. Artifacts:
`/tmp/lem-color-hex-{1,4}-{before,after}-{1,2}.{json,log}`.

T3 passed unchanged budgets: warm startup 286.906 ms; plain/bigfile/longline/
scroll/truncate/wordwrap p95 histogram upper bounds were
1.024/1.024/4.096/1.024/2.048/2.048 ms. Log: `/tmp/lem-color-hex-t3.log`.
Result: `bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919192253.json`.
Kernel sources, proof obligations, budgets and installed profiles are unchanged.
The known core undo-model mismatch remains unresolved.


### Bounded character strings in daemon rows (2026-09-19)

A fresh four-client allocation profile of `42f1360d6` collected 5,186 samples
(about one 32 KiB allocation region per sample, all daemon threads). `STRING`
below `OVERLAY-TEXT` accounted for about 7% of samples. Artifacts:
`/tmp/lem-color-hex-allocation-profile.{lisp,txt,json,log}`.

`overlay-text` now reuses a fixed table of one-character strings for character
codes below 256. Other characters still allocate as before. Row edits already
replace cell strings; combining marks create new strings. The table contains
representations only: width/icon settings remain live, with no width cache or
invalidation rules. The same path handles SDL wire-row decoding. This retains
at most 256 small strings and one vector per process.

The regression compares codes 0–257 under both ambiguous-width settings against
the frozen placement algorithm (516 cases on SBCL), and checks independent rows,
repeated characters, combining marks, overwrite/clear operations and mutable
source text. Existing Unicode, wide-cell repair, live icon-width, retained-frame
and wire-snapshot regressions remain enabled. All five daemon test modules,
the SDL client module, the SDL pixel module and all 16 packaged native-client
checks pass. Final logs: `/tmp/lem-cell-strings-v2-{daemon,client,pixels,native}.log`.
Both modified Lisp files matched the tested base derivation byte for byte.

- Before: `/nix/store/i51wiqkz21vi76mwm2kbjb6kq3qnglfa-lem-yath/bin/lem`.
- After: `/nix/store/z5sh1r53qaq5c6lym2qy0j092m3g045j-lem-yath/bin/lem`.
- Tested base: `/nix/store/ilwnbg1r58ymkqz9982l2c7x8vdhqikr-sbcl-lem-ncurses-unstable/bin/lem`.

An initial prototype read the table length for every character. The final version
uses the fixed cutoff directly. Unversioned `/tmp/lem-cell-strings-component-*`
and `/tmp/lem-cell-strings-{1,4}-*` artifacts describe that prototype, not the
final results below. Final component/input artifacts use the `v2` prefix.

The final composition ABBA used 3,000 100×40 frames per case after 100 warmups,
with the exact old `overlay-text` definition as the only baseline override.
Checksums were 120,000 throughout. These component counters include fresh grid
allocation, excluding core redisplay, encoding, transport and client rendering.

| Fixture / operation | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| ascii / cursor | 175.425 → 173.363 | 222,042,048 → 221,934,976 |
| ascii / row | 174.755 → 174.806 | 226,844,864 → 221,921,216 |
| ascii / full | 344.195 → 323.479 | 418,916,352 → 221,921,664 |
| unicode / cursor | 192.969 → 191.814 | 243,831,552 → 231,961,536 |
| unicode / row | 196.120 → 193.168 | 246,656,832 → 232,020,736 |
| unicode / full | 321.887 → 312.714 | 344,120,576 → 254,234,112 |
| wide / cursor | 241.307 → 240.003 | 222,074,944 → 221,931,008 |
| wide / row | 250.968 → 248.374 | 226,859,584 → 226,774,400 |
| wide / full | 567.770 → 558.850 | 418,683,264 → 418,744,192 |

Full ASCII rendering used 47.0% less allocation and 6.0% less CPU; mixed Unicode
used 26.1% less allocation and 2.9% less CPU. Wide-only results were close to
baseline (CPU 0.5–1.6% lower, allocation within 0.1%). Artifacts:
`/tmp/lem-cell-strings-v2-component-{before,after}-{1,2}.log` and the baseline
`/tmp/lem-cell-strings-before.lisp`.

Configured-daemon typing ABBA used one/four clients separately, 600 measured
keys, 20 warmup keys and 25 ms pacing. Every peer observed every edit and final
buffers matched the fixtures. Counters cover all daemon threads, all 620 keys,
idle time and boundary evals. Tests, builds and other benchmarks ran separately.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| 1 | 388.037 → 408.240 | 57,906,464 → 55,441,120 |
| 4 | 1,007.041 → 1,013.857 | 156,717,472 → 147,410,976 |

Typing allocation fell 4.3%/5.9%, but mean CPU rose 5.2%/0.7% for one/four
clients. This does not establish a typing CPU or latency improvement.

| Clients / endpoint | p50, both runs before → after (ms) | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- | --- |
| 1 / active | 0.467/0.396 → 0.486/0.387 | 0.716/0.591 → 0.774/0.641 | 3.579/3.675 → 4.531/4.107 |
| 4 / active | 0.489/0.446 → 0.513/0.495 | 0.649/0.628 → 0.642/0.629 | 1.002/1.139 → 4.287/1.135 |
| 4 / all | 0.951/0.925 → 0.966/0.944 | 1.216/1.171 → 1.180/1.159 | 3.768/1.540 → 4.619/4.349 |

Single-client p95/maxima and four-client maxima worsened; four-client p95 was
similar. These results end at decoded protocol output, excluding native
rendering and physical presentation. Artifacts:
`/tmp/lem-cell-strings-v2-{1,4}-{before,after}-{1,2}.{json,log}`.

A separate private-X11 SDL ABBA exercised 120 single-row or full-frame updates
per run after the initial warmup frame. A private wrapper counted CPU/allocation
inside `update-screen` (process-wide counters over each call), excluding drawing,
JSON decoding and socket handling; its instrumentation adds overhead. The same
old `overlay-text` override isolated the change. Results:

| SDL update mode | Mean decoding CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| One row | 0.791 → 0.825 | 622,592 → 236,800 |
| Full frame | 17.727 → 13.526 | 26,634,624 → 10,091,904 |

Full-frame cell decoding used 23.7% less CPU and 62.1% less allocation; single-row
allocation fell 62.0%, while CPU increased by 0.034 ms over all 120 updates.
Socket-to-present medians/p95 remained 0/1 ms for row updates and 2/3 ms for full
frames, at the harness's roughly 1 ms clock resolution. Full-frame maxima were
4.001/3.000 ms before and 4.000/4.000 ms after. No physical monitor claim follows.
Artifacts: `/tmp/lem-cell-strings-sdl-{row,full}-{before,after}-{1,2}.log`,
`/tmp/lem-cell-strings-sdl.lisp` and `/tmp/lem-cell-strings-sdl.py`.

This checkpoint trades a small fixed pool for reduced row allocation and faster
full-frame SDL decoding; it is not a demonstrated general typing-latency win.
Core/kernel sources, proof obligations, budgets and installed profiles are
unchanged. The previously documented core undo-model mismatch remains unresolved;
the core suite was not rerun for this daemon-only change.


### Compiler specialization of daemon cell placement (2026-09-19)

A four-client CPU profile of the `34789a39d` production code collected 971
samples at 1 ms. `overlay-cells` accounted for 33.2% of samples including callees,
with `overlay-cell` at 11.6%; generic `LENGTH` accounted for 4.7% across the process.
Artifacts: `/tmp/lem-cell-pool-cpu-profile.{lisp,txt,json,log}`. An earlier private
experiment hoisted the character-pool variable out of the loop; it did not
improve component CPU and was discarded without a source change. Its artifacts
are `/tmp/lem-cell-pool-{current,local}-{1,2}.log` and corresponding `.lisp` files.

The retained change declares the private `overlay-cell` helper inline and tells
the compiler that a non-continuation cell is a string when computing its length.
Placement algorithms, live character widths, clipping and storage remain the
same. It does not restrict cells to simple strings or lower compiler safety.
New regression cases cover adjustable strings with fill pointers and displaced
Unicode storage, alongside the existing 3,150 placement cases, 396 overwrite
boundaries, byte-pool independence, live icon changes and wire/pixel snapshots.

Disassembly of `overlay-text` and `overlay-cells` shows the two helper calls and
the latter's generic `LENGTH` call removed. Caller code grows from 900/1,094 bytes
to 2,058/2,273 bytes (2,337 bytes total increase). Bounds-error paths remain.
Artifacts: `/tmp/lem-cell-inline-disassemble-{before,after}.{txt,log}` and
`/tmp/lem-cell-inline-disassemble.lisp`.

All five daemon modules, the SDL client module, the SDL pixel module and all 16
packaged native-client integration checks pass. Logs:
`/tmp/lem-cell-inline-{daemon,client,pixels,native}.log`. Both changed Lisp files
matched the tested base derivation byte for byte. Packages:

- Before: `/nix/store/z5sh1r53qaq5c6lym2qy0j092m3g045j-lem-yath/bin/lem`.
- After: `/nix/store/md47x0nl63jfx3kd5vbxl8262jl7r0ih-lem-yath/bin/lem`.
- Tested base: `/nix/store/dw5y3x9rp4wkvd0cwclwhxixnlc8i0zi-sbcl-lem-ncurses-unstable/bin/lem`.

Composition ABBA used 3,000 100×40 frames per fixture after 100 warmups; all
checksums were 120,000. Before/after definitions of the three overlay functions
were loaded into separate processes, explicitly controlling the inline
proclamation. This includes fresh composition-grid allocation, excluding core
redisplay, protocol encoding, transport and client rendering.

| Fixture / operation | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| ascii / cursor | 173.216 → 139.386 | 221,965,440 → 221,999,040 |
| ascii / row | 177.906 → 143.178 | 221,984,576 → 221,957,376 |
| ascii / full | 321.117 → 281.306 | 221,956,160 → 221,954,944 |
| unicode / cursor | 190.230 → 162.589 | 231,953,536 → 232,036,352 |
| unicode / row | 195.029 → 167.118 | 232,089,536 → 232,060,480 |
| unicode / full | 305.137 → 278.531 | 254,255,104 → 254,303,296 |
| wide / cursor | 238.931 → 224.812 | 221,949,760 → 221,956,032 |
| wide / row | 247.609 → 228.934 | 226,835,712 → 226,782,208 |
| wide / full | 554.555 → 534.929 | 418,435,392 → 418,475,264 |

CPU fell 12.4–19.5% for ASCII, 8.7–14.5% for mixed Unicode and 3.5–7.5% for
wide-only rows. Allocation stayed within 0.04% of baseline. Artifacts:
`/tmp/lem-cell-inline-{before,after}-{1,2}.log`, with function overrides in
`/tmp/lem-cell-inline-{before,after}.lisp`.

Uninstrumented configured-daemon ABBA used one/four clients separately, 600
measured keys, 20 warmups and 25 ms pacing. Every peer observed every edit;
final buffers matched the fixtures. Counters cover all threads, all 620 keys,
idle time and boundary evals. Builds, tests and other benchmarks ran separately.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| 1 | 372.616 → 350.927 | 55,364,832 → 55,365,280 |
| 4 | 934.909 → 891.176 | 147,394,016 → 147,484,384 |

Mean CPU fell 5.8%/4.7% for one/four clients; allocation stayed within 0.1%.
Individual runs varied appreciably, so these means are not a universal speedup.

| Clients / endpoint | p50, both runs before → after (ms) | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- | --- |
| 1 / active | 0.380/0.446 → 0.407/0.331 | 0.605/0.622 → 0.614/0.565 | 4.100/1.262 → 4.292/1.115 |
| 4 / active | 0.380/0.452 → 0.379/0.396 | 0.508/0.608 → 0.537/0.600 | 4.473/1.075 → 0.999/4.252 |
| 4 / all | 0.765/0.954 → 0.800/0.826 | 1.076/1.129 → 1.032/1.100 | 4.804/1.539 → 4.663/4.560 |

Latency remains mixed: four-peer p95 fell in both runs, but the second run's
maximum worsened. Measurements end at decoded protocol output, excluding native
rendering and physical presentation. Artifacts:
`/tmp/lem-cell-inline-{1,4}-{before,after}-{1,2}.{json,log}`.

Private-X11 SDL ABBA used 120 row/full updates after an initial warmup frame,
with the existing socket-to-present harness and a private `update-screen`
resource wrapper. The wrapper measures process-wide counters during each call,
so reader/producer-thread work can enter or leave its measurement intervals.

| SDL update mode | Mean update CPU before → after (ms) | Mean Lisp bytes counted before → after |
| --- | ---: | ---: |
| One row | 0.818 → 0.784 | 98,304 → 275,968 |
| Full frame | 15.110 → 12.533 | 9,668,352 → 10,107,648 |

The lower CPU coincided with increased counted allocation, which warranted an
isolated check rather than treating the counters as per-call allocation. Row
socket-to-present median/p95 stayed 0/1 ms; full-frame median stayed 2 ms and p95
was 2.001/3.000 ms before versus 3.000/3.000 ms after. Full-frame maxima rose from
3/3 ms to 3/4 ms. The clock has roughly 1 ms resolution, and these results do not
establish a presentation-latency improvement. Artifacts:
`/tmp/lem-cell-inline-sdl-{row,full}-{before,after}-{1,2}.log`,
`/tmp/lem-cell-inline-sdl.{py,lisp}`.

A separate decoding-only ABBA performed 120,000 `decode-row` calls per case after
1,000 warmups and full GC, without transport, a producer or rendering. It reused
the same mixed-Unicode SDL fixture with styled runs enabled/disabled. Each run's
checksum was 11,880,000 cells (the fixture is 99 columns). The first private
harness attempt incorrectly assumed 100 columns; its assertion failed before
measurement reporting, and was corrected to use the fixture's actual width.

| Decoded row | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| Unstyled | 251.539 → 234.856 | 234,078,336 → 233,654,784 |
| Styled | 286.670 → 275.371 | 290,699,136 → 290,275,968 |

CPU fell 6.6%/3.9%, and allocation stayed within 0.2%. The increase seen inside
the concurrent socket harness was not reproduced here. These component numbers
exclude JSON decoding, drawing and physical presentation. Artifacts:
`/tmp/lem-cell-inline-decode-{before,after}-{1,2}.log`,
`/tmp/lem-cell-inline-decode.{lisp,py}`.

The checkpoint reduces measured composition/decoding CPU, with mixed input and
presentation latency. Core/kernel sources, proof obligations, budgets and
installed profiles remain unchanged. The core suite was not rerun for this
daemon-only change; the previously documented undo-model mismatch remains open.


### Visible-line traversal without folding (2026-09-19)

A fresh allocation profile of `62989222c` collected 4,925 samples, about one
32 KiB allocation region per sample across all threads. `copy-point` accounted
for 13.8% of sampled allocation, with 11.9% under `move-to-next-visible-line`.
This operation made a temporary point for every displayed logical line even
when no visibility predicate was installed. Artifacts:
`/tmp/lem-cell-inline-alloc-profile.{lisp,txt,json,log}`.

Forward/backward visible-line movement now delegates to transactional
`line-offset` when the buffer's effective `line-hidden-function` is NIL. An
explicit zero-step branch preserves the current column. A non-NIL predicate
continues through the previous candidate-point traversal, including fresh
predicate lookup per visited line. There is no cached visibility state; local
and global editor-variable resolution remains the existing `:default` lookup.

A new regression compares against the old traversal across 13,860 cases:
NIL plus all 32 hidden-line masks, three point kinds, five starting lines,
two columns, seven step counts and both directions. It checks return identity,
position, column and point kind, including failed moves at both boundaries.
Additional cases exercise predicate installation/removal between calls, removal
during traversal, predicate errors without partial movement, and invalid counts.
The full core suite is 77/78, with only the known undo-model mismatch (equal
content/points, production/model ticks 0/1). All five daemon modules pass.
Logs: `/tmp/lem-visible-lines-{core,daemon}.log`.

- Before: `/nix/store/md47x0nl63jfx3kd5vbxl8262jl7r0ih-lem-yath/bin/lem`.
- Candidate: `/nix/store/iw507h4ymakfca3pzzanq2ss8abrw17v-lem-yath/bin/lem`.
- Tested base: `/nix/store/jy5a2asb5l6xzjr60vyz360a2d5rbwik-sbcl-lem-ncurses-unstable/bin/lem`.

Production source and ASDF registration matched this base byte for byte. The
local tests initially needed a missing parenthesis and quoted Rove condition
symbols fixed. The build snapshot predates only the condition-symbol quoting
fix; the final tests passed against the identical production source locally.

Packaged checks passed all 16 native integration, 27 screen-line, 61 Avy and 12
Org cases, including folding, navigation, structural edits and edge cases.
Log: `/tmp/lem-visible-lines-runtime.log`.

An isolated traversal ABBA used a 101-line buffer, 1,000 warmup pairs and full
GC before each case. One-step cases made 100,000 forward/backward pairs;
40-step cases made 10,000 pairs. The folded cases hid even-numbered lines using
a live predicate. Return values, final line and column were asserted. Counters
include the Lisp process and exclude redisplay, input handling and presentation.

| Traversal case | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| plain-one | 29.989 → 12.340 | 19,524,224 → 35,200 |
| plain-forty | 49.262 → 4.118 | 1,975,168 → 19,456 |
| folded-one | 44.407 → 51.311 | 19,491,072 → 19,506,816 |
| folded-forty | 108.656 → 111.406 | 1,975,168 → 1,987,456 |

Without folding, CPU fell 58.9%/91.6% for one/40-step movement, and allocation fell
99.8%/99.0%. With the trivial even-line predicate, CPU rose 15.5%/2.5%; the extra
check costs about 35 ns per one-step move in this component test. Folding-path
allocation stayed within 0.7%. This is an explicit tradeoff for avoiding temporary
points in the common no-predicate path, not a claim that every traversal is faster.
Artifacts: `/tmp/lem-visible-lines-component-{before,after}-{1,2}.log`,
`/tmp/lem-visible-lines-component.{lisp,py}`, and exact old traversal definitions
in `/tmp/lem-visible-lines-before.lisp`.

Configured-daemon typing ABBA used one/four clients separately, 600 measured
keys, 20 warmups and 25 ms pacing. Every peer observed every edit and final buffers
matched the fixtures. Counters cover all threads, all 620 keys, idle time and
boundary evals. No tests, builds or other benchmarks ran concurrently.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| 1 | 411.917 → 381.831 | 55,274,912 → 50,715,616 |
| 4 | 911.009 → 896.514 | 147,540,576 → 129,525,536 |

Allocation fell 8.2%/12.2%, while mean CPU fell 7.3%/1.6%. Individual CPU runs
varied substantially, so the allocation reduction is clearer evidence than the
small aggregate CPU change, especially with four clients.

| Clients / endpoint | p50, both runs before → after (ms) | p95, both runs before → after (ms) | Maximum, both runs before → after (ms) |
| --- | --- | --- | --- |
| 1 / active | 0.397/0.559 → 0.416/0.381 | 0.612/0.833 → 0.684/0.610 | 4.155/4.142 → 4.344/0.879 |
| 4 / active | 0.510/0.463 → 0.533/0.380 | 0.770/0.692 → 0.829/0.659 | 1.073/1.040 → 4.697/1.033 |
| 4 / all | 0.843/0.900 → 0.942/0.690 | 1.251/1.179 → 1.299/1.119 | 3.969/4.675 → 4.995/1.503 |

Latency was mixed: the first candidate runs generally worsened, while the second
improved. The reduced allocation does not establish fewer input-latency spikes.
These measurements end at decoded protocol output, excluding native rendering
and physical presentation. Artifacts:
`/tmp/lem-visible-lines-{1,4}-{before,after}-{1,2}.{json,log}`.

The standard T3 gate passed against the candidate **base image**: warm startup
284.707 ms; plain/bigfile/longline/scroll/truncate/wordwrap p95 histogram upper
bounds were 1.024/1.024/4.096/1.024/2.048/2.048 ms, with unchanged budgets.
Log: `/tmp/lem-visible-lines-t3-after-base.log`.
Result: `bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919201615.json`.

The first T3 invocation instead used the configured wrapper, which forces its
immutable init file despite the harness's sandbox. It passed startup/plain but
failed to exit the large-file scenario within the harness's 10-second stop
window, producing no metrics dump for that scenario. The preceding configured
build reproduced the same failure, so this is not introduced by the traversal
change. Small-file diagnostic captures showed both builds accepting the normal
modified-buffer quit prompt. The large-file shutdown/harness interaction remains
unresolved; configured T3 is **not** a passing gate. No timeout, budget or quit
behavior was relaxed. Artifacts:

- Candidate configured attempt: `/tmp/lem-visible-lines-t3.log`, result
  `bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919201224.json`.
- Preceding configured control: `/tmp/lem-visible-lines-t3-before-configured.log`,
  result `bench/results/nova-AMD-Ryzen-9-9950X3D-16-Core-Processor-32c-t3-20260919201536.json`.
- Small-file diagnostic: `/tmp/lem-visible-lines-exit-probe.sh`,
  `/tmp/lem-visible-lines-exit-{before,after}.log` and corresponding pane captures.

Kernel sources and proof obligations are unchanged, as are installed profiles.
The known core undo-model gap and the newly observed configured T3 shutdown
failure remain open; this checkpoint does not claim the complete suite is green.


### Recoverable oversized-buffer shutdown refusal (2026-09-19)

Retained terminal diagnostics resolved the configured T3 large-file stop failure
from the preceding checkpoint. It was not a ten-second cleanup delay: the final
recovery checkpoint rejected the modified `mixed-10m.txt` corpus against the
2 Mi-character text limit. `stop-configured-daemon-server` then ran its guaranteed
cleanup and raised the failure, leaving the interactive editor open with managers
cleared and a sticky shutdown error. The harness continued sending `y` into the
backtrace buffer. Artifacts: `/tmp/lem-configured-exit-diagnostic.{sh,log}`,
`/tmp/lem-configured-exit-{before,after}.txt`,
`/tmp/lem-configured-exit-debug.log`.

The existing shutdown contract intentionally reports real checkpoint/journal
failures and remembers failed cleanup after globals are cleared. That contract
and all storage limits remain intact. A new `check-checkpoint-limits` query checks
eligible buffer sizes without copying text, allocating recovery IDs or writing
records. The configured editor registers it after buffer-lock checks and before
service teardown. Known oversized buffers now produce a normal editor diagnostic
before any of those cleanup hooks run. Saving or reducing the buffer permits a
retry; `--force` still does not bypass recovery or journal guarantees.

Tests cover the exact limit, oversized modified text, excluded/read-only/clean
buffers, and absence of recovery side effects. The configured shutdown regression
records service identities and a cleanup-hook sentinel, attempts a forced stop,
checks that services and the source file remain intact, saves the oversized file,
and proves the next stop succeeds without reinitializing services. The old build
fails the new service-preservation check as expected:
`/tmp/lem-checkpoint-preflight-negative.log`.

Validation:

- Recovery unit suite passes, including the existing atomic-storage and failure
  cases: `/tmp/lem-checkpoint-preflight-unit.log`.
- All 27 native shutdown checks pass, including the unchanged checkpoint, draft,
  core-journal, job-journal, frame-teardown and incomplete-peer failure tests:
  `/tmp/lem-checkpoint-preflight-shutdown.log`,
  `/tmp/lem-shutdown-client-wt79cr1h/result.json`.
- All 16 packaged native display/integration checks pass:
  `/tmp/lem-checkpoint-preflight-native.log`.
- A real ncurses probe edits the 10 MB corpus, observes the early size diagnostic,
  saves via `C-x C-s`, and exits cleanly on retry. Artifacts:
  `/tmp/lem-checkpoint-preflight-tui.{sh,log}`,
  `/tmp/lem-checkpoint-preflight-refusal.txt`,
  `/tmp/lem-checkpoint-preflight-saved.txt`.

The tested recovery source, unit test, shutdown client test and configured daemon
source matched the built packages byte for byte:

- Configured: `/nix/store/qf6zqai0z49mgvy4jlc1zbd76cr62ld8-lem-yath/bin/lem`.
- Base: `/nix/store/yh767h0pg53v2w47l3r89dpsq070csij-sbcl-lem-ncurses-unstable/bin/lem`.
- Client: `/nix/store/hjfk4gwb4f31yz9qnxvpk84g7rswfdg4-sbcl-lemclient-unstable/bin/lemclient`.

This is a shutdown correctness fix, with no claimed typing speedup. Standard
configured T3 still cannot discard an oversized unsaved corpus through its `y`
loop; that policy refusal is intentional, and no budget, workload size or timeout
was relaxed. The base-image T3 gate remains the applicable preceding measurement.
Core/kernel sources, proof obligations and installed profiles are unchanged;
the previously documented core undo-model mismatch remains open.

### Configured large-file typing probe (2026-09-19)

`daemon-input.py --fixture PATH` now copies a UTF-8/LF fixture into its private
`.txt` buffer, prefixed with the screen marker. The source is never written.
After measured counters stop, the probe verifies the final text, saves only its
private copy, checks both files byte for byte and requires clean shutdown before
publishing results. The default 1,000-line workload is unchanged and does not
perform this extra save. Results record copied-document size and SHA-256.
This permits configured large-file measurements without weakening recovery limits
or treating the existing configured T3 discard-on-exit refusal as a passing gate.

Example, after generating `mixed-10m` with `bench/corpora/generate.lisp`:

```sh
LEM_BIN=/absolute/path/to/configured/lem \
  python3 scripts/bench/e2e/daemon-input.py --clients 4 --count 600 \
  --fixture /path/to/mixed-10m.txt --output /tmp/large-input.json
```

The editing location remains the initial marker line. These measurements exercise
plaintext buffer size, not language-mode analysis or edits inside long lines.
Loading, final text verification, saving and shutdown are outside the counters.
The endpoint remains decoded protocol screens, not physical presentation.

Small/large/large/small captures used the preceding configured package
`/nix/store/qf6zqai0z49mgvy4jlc1zbd76cr62ld8-lem-yath/bin/lem`, 600 measured plus
20 warmup keys and 25 ms pacing. Every capture verified all peers and final text,
and exited with status zero. No builds or tests ran concurrently. Mean counters:

| Clients | Buffer | Process CPU (ms) | Lisp bytes | All-client maxima, both runs (ms) |
| --- | --- | ---: | ---: | --- |
| 1 | 1,000 lines | 389.086 | 50,770,720 | 1.165 / 4.459 |
| 1 | 10 MB | 781.325 | 895,352,928 | 117.438 / 122.520 |
| 4 | 1,000 lines | 868.701 | 129,912,544 | 3.863 / 5.173 |
| 4 | 10 MB | 1,317.474 | 972,998,816 | 126.334 / 124.369 |

Large-file p95 remained 0.600/0.608 ms with one client and 1.252/1.135 ms for all
four clients. Single-client pauses over 5 ms recurred about every five seconds,
so p95 alone conceals this periodic cost. This checkpoint establishes the
reproduction; it makes no optimization claim. The copied large fixture contains
10,486,292 bytes / 10,443,047 characters, SHA-256
`ded569e84498271f23fa8ba9684a6bc00fab355649489013925aca23747c67d3`.
Artifacts: `/tmp/lem-wire-size-{1,4}-{small,large}-{1,2}.{json,log}` and runner
`/tmp/lem-wire-large-runs.py`. A separate Unicode fixture with no trailing newline
also passed exact-byte saving and shutdown: `/tmp/lem-wire-unicode-fixture.log`.
Python compilation and `git diff --check` pass. No production sources changed.

### Avoid per-byte boxing in external-change hashes (2026-09-19)

The large-file reproduction above exposed periodic work in the configured
external-change checker. Its masked 64-bit FNV accumulator shared state across
the chunk reader, byte loop and EOF handling. SBCL compiled the multiplication
as machine arithmetic, then boxed the result into a Lisp integer inside the byte
loop. A 10 MB read consequently allocated roughly 210 MB. Repeated checks on the
editor thread caused the five-second typing stalls.

`bounded-stream-content-digest` now uses a typed accumulator local to each byte
loop and transfers its result to the outer state once per chunk. Disassembly
places integer boxing after the loop. No compiler safety setting, hash algorithm,
chunk size, digest limit, polling interval, descriptor stability check or conflict
handling changed. File contents are still checked, including same-metadata
rewrites; neither dirty buffers nor notification-driven full digests are skipped.

The initial allocation profile reached its 50,000-sample cap, with 96.7% of
samples through unsigned-bignum allocation and 96.8% through file-state signatures.
It includes post-measurement verification/save work and must not be interpreted
as an exact typing-only attribution. Artifacts:
`/tmp/lem-wire-large-profile.{lisp,txt,json,log}`. Merely declaring the outer hash
type, even with a local speed preference, did not remove per-byte boxing; those
experiments are not part of the change.

An isolated ABBA probe hashes the original deterministic 10 MB corpus 20 times
after two warmups and full GC, checking each result against the independently
computed Python FNV value `4e7cf6b0bf4796f7`. Mean CPU fell from 1,337.230 to
174.352 ms (87.0%); allocation fell from 4,200,879,680 to 1,777,728 bytes (99.96%).
The stream buffer and one boxed result per chunk remain. Artifacts:
`/tmp/lem-digest-component-final-{before,after}-{1,2}.log`,
`/tmp/lem-digest-component.lisp`, `/tmp/lem-digest-{before,after}.lisp`.

Packaged ABBA typing captures used 600 measured keys plus 20 warmups, 25 ms
pacing and the same copied 10 MB fixture. Each capture verified every client's
text, the complete final buffer, unchanged source and saved private copy, then
exited cleanly. No builds/tests ran during measurement. Packages:

- Before: `/nix/store/qf6zqai0z49mgvy4jlc1zbd76cr62ld8-lem-yath/bin/lem`.
- After: `/nix/store/75xj5brwy4lwzkv37l6aj9srpsz59rjq-lem-yath/bin/lem`.

| Clients | Mean process CPU before → after (ms) | Mean Lisp bytes before → after | All-client maxima, both runs before → after (ms) |
| --- | ---: | ---: | --- |
| 1 | 901.563 → 471.955 | 894,961,760 → 47,005,408 | 135.290 / 125.101 → 9.780 / 9.842 |
| 4 | 1,441.078 → 959.097 | 972,775,328 → 124,754,720 | 124.522 / 120.248 → 17.594 / 9.445 |

That is 47.7%/33.4% less CPU and 94.7%/87.2% less allocation for one/four clients.
Single-client p95 was 0.882/0.780 before versus 0.892/0.853 ms after. Four-client
all-peer p95 was 1.477/1.366 versus 1.478/1.086 ms. Typical latency is mixed;
the demonstrated improvement is the periodic large-file stall. These are decoded
protocol-screen endpoints, not physical presentation. Full-file reads/hashing
still run synchronously, leaving a measurable periodic delay. Artifacts:
`/tmp/lem-digest-{1,4}-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-digest-runs.py`.

Validation: all 58 packaged persistence checks and 16 native display/client
checks pass (`/tmp/lem-digest-runtime.log`). The new digest regression compares
104 cases with an arbitrary-precision reference, covering all byte values,
empty streams, partial/exact/multiple chunks, bounded reads, nonzero starting
positions, EOF flags and final stream positions. Existing same-timestamp rewrites,
large stale-save guards, notification/polling fallback, dirty-buffer preservation,
save races and concurrent persistence checks remain enabled and pass. Production
source and both persistence test files matched the built package byte for byte.
No core/kernel source or installed profile changed; the known core undo-model
mismatch remains outside this checkpoint.

### Move routine file polling off the editor thread (2026-09-19)

The preceding hash optimization retained about 9 ms of synchronous work each
five seconds on the 10 MB fixture. Routine pre-command/timer polling now captures
tracked paths, baseline identities and digest policy on the editor thread, then
reads file signatures on one worker. Results return through the editor event
queue. A changed result is only a hint: the original synchronous checker re-reads
the file before reporting a conflict or reloading. Saved/reloaded baselines,
renamed paths, deleted/temporary buffers and cancelled scans invalidate old work.
An unchanged result does not mutate editor state.

There is at most one polling read in flight, including across configuration
reloads. Cancellation rejects results and stops the next read; it does not
interrupt an active I/O operation or wait for it on the editor thread. Ownership
is retained until that reader finishes, preventing a slow filesystem from
accumulating workers. Workers never modify buffers or write files. Saves, explicit
forced scans, buffer-switch checks, notifications and non-file adapters retain
their synchronous behavior and integrity checks. A key arriving during a poll
is now processed immediately: if the disk changed, those local edits are
preserved and a conflict is reported after the check, rather than reloading
before the key. This timing behavior is documented in the configuration README.

All 58 packaged persistence checks, 16 native display/client checks and 14 new
polling checks pass. The new test deliberately blocks real worker reads while
editing, saving, reloading, renaming, deleting, replacing the configuration and
shutting down. It checks a same-metadata rewrite, fresh disk rechecks, stale
baseline rejection, single-worker ownership, cancellation and resumed polling.
Existing idle notification/polling fallback, dirty-buffer, stale-save, directory
adapter and persistence merge tests remain enabled. A private negative control
without baseline-identity rejection fails the newer-reload test as intended:
`/tmp/lem-async-poll-negative.log`. Final checks:
`/tmp/lem-async-poll-final-runtime.log` and Nix `persistence-polling` output.
Production source, Lisp race fixture and Python runner matched the built sources.

ABBA captures use the unchanged 600-key plus 20-warmup, 25 ms, private 10 MB
plaintext workload. All peers, final text, source/copy bytes and clean shutdown
were verified. No builds/tests ran concurrently. Packages:

- Before: `/nix/store/75xj5brwy4lwzkv37l6aj9srpsz59rjq-lem-yath/bin/lem`.
- After: `/nix/store/fi6mgpas22a5mv5f10wq5fmyzs93akzm-lem-yath/bin/lem`.

| Clients | Mean process CPU before → after (ms) | Mean Lisp bytes before → after | All-client maxima, both runs before → after (ms) |
| --- | ---: | ---: | --- |
| 1 | 388.564 → 376.254 | 46,985,248 → 47,595,744 | 9.393 / 9.175 → 0.808 / 1.136 |
| 4 | 948.712 → 927.137 | 124,861,984 → 125,592,160 | 9.219 / 17.569 → 2.086 / 12.621 |

Both single-client controls had >5 ms updates at sample indices 176/372/568;
neither candidate did. Both four-client controls had them at 173/366/559; the
candidates had none at that cadence. A separate isolated tail remains: one
four-client control also stalled at index 501, and one candidate at 499.
Single-client p95 was 0.621/0.549 before versus 0.592/0.607 ms after; all-four p95
was 1.082/1.040 versus 1.095/1.065 ms. The demonstrated improvement is removal
of periodic polling stalls, not universally lower ordinary latency. Worker
overhead increased allocation 1.3%/0.6%; mean CPU fell 3.2%/2.3%, within the
variation seen between individual runs. Artifacts:
`/tmp/lem-async-poll-{1,4}-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-async-poll-runs.py`.

A separate instrumented four-client capture had one >2 ms update, at index 473:
12.992 ms to all peers, with a 13 ms server receive-to-screen wall interval and
25.225 ms process GC CPU accrued during that interval. GC CPU is not wall pause
duration. This supports GC attribution for that instrumented tail; it does not
prove the cause of each uninstrumented spike. Diagnostic overhead affects timing
and allocation, so these results are not folded into ABBA comparisons. Artifacts:
`/tmp/lem-async-poll-resources.{json,log}`. All timing endpoints remain decoded
protocol screens, not physical keyboard-to-monitor latency. Installed profiles
and core/kernel code are unchanged; the existing undo-model mismatch remains.

### Reuse daemon modeline cell storage (2026-09-19)

A fresh four-client allocation profile of the current 10 MB typing path collected
6,491 samples. `render-line-on-modeline` accounted for 13.8% inclusively and
`make-cell-row` for 9.1%; redraw/modeline construction and protocol encoding now
dominate rather than file hashing. The profiler stopped after 25 seconds of a
1,200-key diagnostic run, before final buffer verification/save/shutdown. Its
timer/report writing affects timing, so this capture is attribution only:
`/tmp/lem-polling-allocation-profile.{lisp,txt,json,log}`.

The daemon modeline renderer now reuses its view's existing cell row when the
width matches, filling both arrays before rendering. A width change allocates
new storage. Modeline expressions, faces, colors and character widths are still
evaluated on every draw; no content cache was introduced. The initial prototype
used the partial-row clearing helper and reduced allocation but increased
component CPU. The retained version uses full-array `fill`, as screen-grid reuse
already does. Unversioned component captures are that rejected clearing variant;
the final captures are explicitly `v2` below.

The isolated ABBA benchmark renders 100,000 100-column modelines after 1,000
warmups and full GC, preserving the resulting text. Mean CPU/allocation:

| Modeline | CPU before → after (ms) | Lisp bytes before → after |
| --- | ---: | ---: |
| Empty, styled padding | 26.016 → 12.596 | 194,744,832 → 11,532,288 |
| ASCII text and right segment | 114.145 → 94.016 | 205,925,824 → 24,358,400 |
| CJK/combining text and right segment | 107.356 → 86.721 | 236,371,200 → 53,160,320 |

That is 18–52% less component CPU and 78–94% less allocation. Artifacts:
`/tmp/lem-modeline-reuse-component-v2-{before,after}-{1,2}.log` and
`/tmp/lem-modeline-reuse-component.lisp`. This excludes core modeline evaluation,
frame composition, encoding, transport and presentation.

Packaged ABBA typing captures retained the 600 measured plus 20 warmup keys,
25 ms pacing and private 10 MB fixture. Every peer, final buffer text, source and
saved-copy bytes, and clean shutdown were verified. No builds/tests ran during
measurement. Before package:
`/nix/store/fi6mgpas22a5mv5f10wq5fmyzs93akzm-lem-yath/bin/lem`; after:
`/nix/store/sjrld5xjhj7lkclg8mcw12ni02404ab1-lem-yath/bin/lem`.

| Clients | Mean CPU before → after (ms) | Mean Lisp bytes before → after | All-client maxima, both runs before → after (ms) |
| --- | ---: | ---: | --- |
| 1 | 409.785 → 405.349 | 47,612,576 → 45,726,560 | 0.972 / 1.083 → 1.018 / 0.887 |
| 4 | 1,016.784 → 971.930 | 125,343,136 → 116,966,240 | 2.390 / 12.835 → 17.551 / 13.239 |

Allocation fell 4.0%/6.7%; mean CPU fell 1.1%/4.4%, with substantial variation
between individual captures. Single-client p95 was 0.756/0.586 before versus
0.684/0.580 ms after; all-four p95 was 1.113/1.073 versus 1.153/1.112 ms. The
four-client short-run tail was worse, so a longer ABBA comparison followed.

With 1,800 measured keys and four clients, mean allocation was
398,115,392 → 362,712,128 bytes (8.9% lower), mean CPU 2,921.374 → 2,555.248 ms,
and mean process GC CPU 33.285 → 32.777 ms. Individual CPU captures varied widely.
All-peer p95 was 1.083/1.072 before versus 1.069/1.065 ms after, while maxima
were 13.164/6.448 versus 12.465/15.157 ms. The isolated >3 ms event occurred at
sample 499 in both controls and 535 in both candidates. These results support
an allocation improvement, not elimination or consistent reduction of GC tails.
Artifacts: `/tmp/lem-modeline-reuse-v2-{1,4}-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-modeline-reuse-v2-long-4-{before,after}-{1,2}.{json,log}`. Endpoints are
decoded protocol screens, not physical keyboard-to-monitor latency.

All five daemon test modules and all 16 packaged native display/client checks
pass: `/tmp/lem-modeline-reuse-v2-{daemon,native}.log`. The new 134-assertion
regression compares fresh/reused rows across Unicode, wide continuations,
combining characters, overlapping left/right segments, live attribute changes,
empty redraws, zero width, shrink/grow, height changes and cleared views. Earlier
encoded row objects remain unchanged. Production and protocol-test sources
matched the built package byte for byte. Core/kernel sources, installed profiles
and the previously documented core undo-model mismatch are unchanged.

### Size protocol objects from their supplied fields (2026-09-19)

The retained allocation profile above attributed 11.1% of samples to protocol
object construction and 6.3% to hash-table growth. `make-object` now supplies an
initial size derived from its alternating name/value arguments. Screen headers
and indexed rows supply all their fields at construction instead of inserting
the row payload/index afterward. Object freshness, EQUAL keys, last-value-wins
duplicates, trailing names with NIL values and subsequent mutation remain
unchanged, as do the protocol schema, limits and JSON field values.

An isolated ABBA probe constructs 100,000 objects per case after 1,000 warmups
and full GC, using prebuilt field lists and checking field-count checksums:

| Distinct fields | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| ---: | ---: | ---: |
| 0 | 4.821 → 5.527 | 17,318,848 → 17,335,168 |
| 2 | 15.715 → 16.187 | 54,053,824 → 54,059,648 |
| 3 | 17.267 → 18.411 | 57,647,680 → 57,652,928 |
| 4 | 19.883 → 21.049 | 61,216,064 → 61,209,728 |
| 6 | 24.442 → 26.036 | 68,886,784 → 68,885,376 |
| 9 | 37.243 → 29.221 | 124,250,688 → 90,058,048 |
| 16 | 67.141 → 42.977 | 264,999,040 → 134,577,344 |

Nine-field objects use 27.5% less allocation and 21.5% less CPU; sixteen-field
objects use 49.2%/36.0% less. Small objects retain SBCL's minimum-size allocation
behavior and pay a small sizing cost, so this is not a universal constructor
speedup. A private minimum-eight-slot experiment increased small-object storage
and CPU and was rejected; a private inline declaration showed no useful
allocation gain and is not part of the change. Final component artifacts:
`/tmp/lem-protocol-sizing-component-{before,after}-{1,2}.log` and
`/tmp/lem-protocol-sizing-component.lisp`.

Packaged ABBA typing captures retain the private 10 MB plaintext fixture,
600 measured plus 20 warmup keys and 25 ms pacing. Every client's text, final
buffer, source/copy bytes and clean shutdown were verified, with no simultaneous
builds or tests. Before:
`/nix/store/sjrld5xjhj7lkclg8mcw12ni02404ab1-lem-yath/bin/lem`; after:
`/nix/store/f0qf2hsr8fcq2v1c7ip66bmg37jzb55c-lem-yath/bin/lem`.

| Clients | Mean process CPU before → after (ms) | Mean Lisp bytes before → after | All-client maxima, both runs before → after (ms) |
| --- | ---: | ---: | --- |
| 1 | 363.156 → 352.615 | 45,737,056 → 45,086,752 | 0.849 / 0.907 → 0.787 / 0.714 |
| 4 | 867.049 → 874.917 | 116,934,688 → 115,381,728 | 12.414 / 12.865 → 2.360 / 12.106 |

Allocation fell 1.4%/1.3%. Mean CPU changed -2.9%/+0.9%, with much larger
variation between individual four-client captures. Single-client p95 was
0.583/0.597 before versus 0.596/0.576 ms after; all-four p95 was 1.094/1.023
versus 1.018/1.110 ms. Latency remains mixed and GC tails remain; no consistent
worst-case improvement is claimed. Artifacts:
`/tmp/lem-protocol-sizing-{1,4}-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-protocol-sizing-runs.py`. These are decoded protocol-screen endpoints,
not physical presentation measurements.

All five daemon test modules, the SDL client module and all 16 packaged native
client/display checks pass: `/tmp/lem-protocol-sizing-{daemon,client,native}.log`.
New assertions cover field counts across size boundaries, duplicate keys,
value identity, trailing NIL values, unchanged input lists, extensibility and
omitted versus zero/nonzero row indices. Existing full/delta reconstruction,
retained wire snapshots, Unicode/styles, queue backpressure and client lifecycle
checks remain enabled. Production and protocol-test sources matched the built
package byte for byte. Core/kernel code and installed profiles are unchanged;
the previously documented core undo-model mismatch remains open.

### Avoid short point-comparison rest lists (2026-09-19)

The retained four-client allocation profile at
`/tmp/lem-polling-allocation-profile.txt` attributed 4.7% of its 6,491 samples to
`point<=` under overlay membership checks, entirely through `LISTIFY-&REST`.
That profile predates the preceding modeline and protocol changes; its percentage
is a lead, not an estimate of the final build's allocation share.

`point<=` now accepts its second and third points as optional arguments before
its remaining rest list. Common two/three-point calls therefore avoid building
that list. Arbitrary arity, equal positions, supplied NIL errors, and validation
of every buffer before short-circuiting comparisons are retained. No point
cache, object-lifetime declaration, compiler safety change or kernel change is
involved. Other comparison functions are unchanged.

An isolated ABBA probe makes one million calls per case, after 10,000 warmups
and full GC, with prebuilt argument lists and an asserted result checksum:

| Points | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| ---: | ---: | ---: |
| 1 | 5.563 → 5.296 | 26,240 → 26,240 |
| 2 | 25.035 → 20.557 | 16,050,432 → 26,240 |
| 3 | 49.978 → 44.091 | 32,040,960 → 26,240 |
| 4 | 61.043 → 57.268 | 48,048,128 → 16,043,264 |
| 6 | 116.685 → 124.935 | 80,076,352 → 48,057,472 |

The common two/three-point cases use 17.9%/11.8% less CPU and lose their per-call
rest-list allocation. Six-point CPU is 7.1% higher on average (individual
candidate runs 134.085 and 115.785 ms); longer calls are not a universal CPU win.
Their allocation still falls by two cons cells per call. Artifacts:
`/tmp/lem-point-compare-component-{before,after}-{1,2}.log`,
`/tmp/lem-point-compare-component.lisp` and saved before/after definitions.

Packaged ABBA typing uses the private 10 MB plaintext fixture, 600 measured plus
20 warmup keys and 25 ms pacing. Every client's text, final buffer, source/copy
bytes and clean shutdown were verified. No builds or tests ran concurrently
with either benchmark. Before:
`/nix/store/f0qf2hsr8fcq2v1c7ip66bmg37jzb55c-lem-yath/bin/lem`; after:
`/nix/store/311lvykwfsyzmsiwp5kkmaspl5bpl1c4-lem-yath/bin/lem`.

| Clients | Mean process CPU before → after (ms) | Mean Lisp bytes before → after | All-client maxima, both runs before → after (ms) |
| --- | ---: | ---: | --- |
| 1 | 404.112 → 383.421 | 46,649,824 → 45,105,568 | 0.982 / 0.922 → 0.895 / 0.840 |
| 4 | 926.043 → 805.604 | 117,013,472 → 110,811,232 | 12.560 / 15.376 → 12.431 / 12.593 |

Allocation fell 3.3%/5.3%; mean CPU fell 5.1%/13.0%, with substantial variation
between individual runs (four-client controls 1022.888 and 829.198 ms).
Single-client p95 was 0.639/0.612 before versus 0.616/0.580 ms after; all-four
p95 was 1.117/1.031 versus 1.067/1.115 ms. Four-client latency remains mixed and
roughly 12 ms tails remain; these measurements do not establish a general
worst-case improvement. They end at decoded protocol screens, not physical
presentation. Artifacts:
`/tmp/lem-point-compare-{1,4}-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-point-compare-runs.py`.

New regression coverage checks all 1,364 orderings of one through five points
at four positions spanning two lines, plus 40 invalid-argument cases. Invalid
buffers and explicitly supplied NIL are tested at every position of calls with
two through six arguments, including after an earlier out-of-order pair. The
core suite passes 77/78 modules; its sole failure remains the documented
`kernel-undo-conformance` mismatch. All five daemon modules and all 16 packaged
native client/display checks pass. Logs:
`/tmp/lem-point-compare-core-final.log`, `/tmp/lem-point-compare-daemon.log`,
`/tmp/lem-point-compare-native.log`. The production point source matched the
completed package's source byte for byte. Installed profiles are unchanged.

The base ncurses T3 benchmark also passes all budgets using
`/nix/store/yg362m21v5jvlgq4vz62wxl1aicsfb49-sbcl-lem-ncurses-unstable/bin/lem`:
warm startup 283.246 ms; in-image p95 histogram upper bounds for plain, bigfile,
longline, scroll, truncate and wordwrap are respectively 1.024, 1.024, 2.048,
1.024, 1.024 and 2.048 ms. Log: `/tmp/lem-point-compare-t3.log`. This is the
base image, not the configured wrapper, consistent with prior T3 captures.

### Construct drawing objects directly from character runs (2026-09-19)

A fresh four-client 10 MB typing allocation profile of checkpoint `340002b2e`
used the same 25-second timed profiler stop before final verification/save:
`/tmp/lem-point-allocation-profile.{lisp,txt,json,log}`. It captured 5,431 samples;
modeline construction accounted for 15.7%, drawing-object construction 8.9%,
and character-run splitting 2.8% (inclusive shares, not additive). The previous
`point<=` rest-list hotspot is absent. Profiler timing is diagnostic only.

Drawing construction now maps directly over character runs, removing the
intermediate list of `(type . substring)` pairs. Modeline construction calls
the shared text constructor directly instead of allocating an item wrapper.
The private mapper is inline so its callbacks can be compiled at the call site.
Run strings remain fresh copies, control characters remain separate runs, and
modeline functions, alignments and attributes are still evaluated every draw.
No content/style cache, object reuse or compiler safety change was added.

An isolated ABBA probe constructs 100,000 sets of drawing objects per case,
after 1,000 warmups and full GC. Result-count checksums match between versions:

| Case | Mean CPU before → after (ms) | Mean Lisp bytes before → after |
| --- | ---: | ---: |
| Empty | 4.381 → 4.564 | 8,073,088 → 8,047,360 |
| ASCII | 27.323 → 26.670 | 26,060,672 → 22,802,176 |
| Mixed Unicode | 80.218 → 73.131 | 125,721,856 → 102,897,088 |
| Controls | 58.570 → 55.429 | 128,938,560 → 109,553,088 |
| Three-field modeline | 128.033 → 115.374 | 172,222,272 → 139,795,392 |

The modeline case uses 18.8% less memory and 9.9% less CPU. Nonempty text cases
allocate 12.5–18.2% less and use 2.4–8.8% less CPU. Empty-text CPU increases
0.184 ms across 100,000 calls (4.2%); its allocation is essentially unchanged.
Artifacts: `/tmp/lem-drawing-runs-component-{before,after}-{1,2}.log`,
`/tmp/lem-drawing-runs-component.lisp` and the saved before/after definitions.

Packaged ABBA typing retains the private 10 MB plaintext fixture, 600 measured
plus 20 warmup keys and 25 ms pacing. Every client's text, final buffer,
source/copy bytes and clean shutdown were verified. No tests or builds ran
concurrently with benchmarks. Before:
`/nix/store/311lvykwfsyzmsiwp5kkmaspl5bpl1c4-lem-yath/bin/lem`; after:
`/nix/store/b0qk1zyxf8cm800g3ba986sfym6hqbms-lem-yath/bin/lem`.

| Clients | Mean process CPU before → after (ms) | Mean Lisp bytes before → after | All-client maxima, both runs before → after (ms) |
| --- | ---: | ---: | --- |
| 1 | 373.718 → 405.132 | 45,071,264 → 44,220,256 | 1.002 / 0.692 → 0.959 / 0.815 |
| 4 | 986.804 → 922.885 | 110,779,936 → 107,420,512 | 2.047 / 12.531 → 12.271 / 15.746 |

Allocation falls 1.9%/3.0%; CPU changes +8.4%/-6.5%, with substantial variation
between individual runs. Single-client p95 is 0.641/0.566 before versus
0.696/0.597 ms after; all-four p95 is 1.259/1.182 versus 1.080/1.243 ms.
These results support an allocation reduction, not a universal typing CPU or
latency improvement. Artifacts:
`/tmp/lem-drawing-runs-{1,4}-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-drawing-runs-runs.py`. Endpoints are decoded protocol screens, not
physical presentation.

New regressions compare 733 text and line-ending inputs against independent
character grouping, including controls, CJK, braille, emoji, folders, icons,
zero-width characters and combining text. They also check image dimensions,
empty-image precedence, independent output strings, live modeline function
calls, changed alignment and in-place attribute mutation. The core suite passes
77/78 modules, with only the documented `kernel-undo-conformance` mismatch.
All five daemon modules, SDL pixel tests and all 16 packaged native checks pass:
`/tmp/lem-drawing-runs-{core-final,daemon,pixels,native}.log`. Production and new
test sources matched the completed package's source byte for byte. Installed
profiles and kernel code are unchanged.

Longer four-client ABBA captures (1,800 measured plus 20 warmup keys) retain a
smaller allocation reduction: 341,118,464 → 338,448,384 bytes (-0.8%). Mean CPU
is 2808.111 → 2767.802 ms (-1.4%). All-client p95 is 1.189/1.236 before versus
1.209/1.217 ms after; maxima are 13.245/18.175 versus 3.483/17.814 ms. Thus the
longer runs also show no consistent tail-latency improvement. Artifacts:
`/tmp/lem-drawing-runs-long-4-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-drawing-runs-long-runs.py`. The smaller sustained allocation benefit
is reported separately rather than extrapolated from the short captures.

The base ncurses T3 benchmark passes all budgets using `/nix/store/56sc08ijln48yvrvvh8c214m5sm6kd9n-sbcl-lem-ncurses-unstable/bin/lem`. Warm startup
is 284.341 ms; in-image p95 histogram upper bounds for plain, bigfile, longline,
scroll, truncate and wordwrap are 1.024, 1.024, 4.096, 1.024, 1.024 and 2.048 ms.
The longline bound is higher than the preceding capture's 2.048 ms; no terminal
latency improvement is claimed. Log: `/tmp/lem-drawing-runs-t3.log`. As with prior
T3 captures, this uses the base image rather than the configured wrapper.

### Synthetic X11 input through the daemon to SDL presentation (2026-09-19)

`scripts/bench/e2e/sdl-input.py` complements the socket-only probes. It creates
a private Xvfb display, configuration, daemon and source-loaded SDL client,
then submits alternating XTest x/Backspace keys to the focused client. The
client uses the production SDL event loop and key translation. Its private
hooks acknowledge only a matching marker row after `SDL_RenderPresent` returns.
Sequence checks reject missing, duplicated or unexpected key input. Example:

```sh
LEM_BIN=/absolute/path/to/configured/lem nix develop --command \
  python3 scripts/bench/e2e/sdl-input.py --count 600 \
  --fixture /path/to/utf8-lf.txt --output /tmp/new-sdl-result.json
```

Outputs must be new files. Fixture text is copied into a private file (default
`bench.txt`, selectable with `--document-name`) with a marker prefix; final text, saved bytes and original fixture bytes must
match before clean client/daemon exits and result publication. The development
shell now supplies Python, Xvfb, xdotool and loadable X11/XTest libraries.

Two endpoints are reported: Python's key-submission-to-acknowledgement interval
includes X11/SDL event delivery and ack transport; the client-local interval
starts at `send-input` entry and ends immediately after presentation returns,
using SDL's high-resolution counter. These are software endpoints on Xvfb,
not physical keyboard-to-monitor measurements. The client loads this checkout
through Qlot and performs full GC before opening its window; it is not a saved
client image. Its source revision and SDL source hash are recorded.

Current baseline: daemon
`/nix/store/b0qk1zyxf8cm800g3ba986sfym6hqbms-lem-yath/bin/lem`, client source
`4238d833d`; 600 measured plus 20 warmup keys, 25 ms pacing, one 100×40 client.
The default fixture is 33,903 bytes; the large fixture is 10,486,292 bytes.
Both edit the short marker line, not long-line text or language analysis.

| Fixture / repeat | Submission→ack median / p95 / max (ms) | Client send→present median / p95 / max (ms) | Daemon / instrumented client CPU (ms) |
| --- | --- | --- | --- |
| Small / 1 | 1.267 / 1.869 / 5.238 | 1.109 / 1.569 / 5.018 | 420.619 / 594.159 |
| Small / 2 | 1.210 / 1.738 / 4.930 | 1.065 / 1.498 / 4.799 | 416.641 / 593.179 |
| Large / 1 | 1.125 / 1.652 / 3.058 | 0.981 / 1.421 / 2.862 | 416.460 / 554.380 |
| Large / 2 | 1.044 / 1.372 / 2.648 | 0.912 / 1.211 / 2.510 | 380.101 / 530.519 |

Client counters include setup after the initial fixture frame, warmup, idle and
ack instrumentation; daemon counters span evaluations before warmup and after
the final pacing interval. GC CPU is not pause duration. Instrumented client
CPU exceeds daemon CPU here, motivating client profiling; this is a baseline,
not an optimization comparison. Captures: `/tmp/lem-sdl-input-{small,large}-{1,2}.{json,log}`.

Smoke checks preserve Unicode and a missing trailing newline. A private wrong-key
probe fails on `a` instead of `x` and publishes no JSON; invalid count, NaN pacing
and existing output files are rejected before startup. Logs:
`/tmp/lem-sdl-input-{smoke-final,unicode,negative}.log`. Python compilation passes.
Nix formatting differences remain identical to HEAD's existing 85 changed lines;
no unrelated formatting was applied. No editor production code or profile changed.

The first smoke run also exposed a lifecycle issue: normal daemon shutdown while
an SDL client remains attached reaches that client as unexpected EOF, causing
an error exit. Evidence: `/tmp/lem-sdl-input-shutdown-client.log` and
`/tmp/lem-sdl-input-smoke.log`. The validated probe explicitly closes its client
through `lem-if:close-frontend` before stopping the daemon. The daemon-first
shutdown failure was not masked as success; the following checkpoint fixes it.


### Close attached clients after verified daemon shutdown (2026-09-19)

The GUI input probe exposed an actual lifecycle defect: completed daemon
shutdown sent the administrative success reply but closed attached clients'
sockets without a normal frame-close message. Their readers consequently
reported unexpected disconnects, including for ordinary non-waiting clients.

After the existing editor-thread join verifies a clean exit, the daemon now
queues a `close` message with reason `server-shutdown` for attached clients.
The administrative response remains first on its own connection. Notifications
use the existing bounded output queues and shared drain deadline; an
unresponsive/full peer is still dropped instead of delaying every other peer.
Failed exit reports or frame teardown do not publish normal closure. A close
message still cannot complete an unfinished external edit: ordinary clients
return 0, pending edits return 1, and unexpected disconnects remain errors.
No change was made to input handling, recovery policy or durability checks.

The new native regression fails against the preceding package at the ordinary
SDL client's exit status: `/tmp/lem-shutdown-close-before-native.log`. The final
package passes all 19 native display/lifecycle checks, including ordinary SDL
and terminal closure, pending-edit failure, failed frame teardown and actual
daemon death. Queue-level tests hold editor teardown behind a semaphore and
exercise successful, reported-failure and teardown-error results, with both
attached and unattached administrative connections and a full peer queue.
All five daemon test modules pass, including bounded stopped-reader shutdown.

All 27 packaged durability/shutdown checks and all 8 tab-ownership checks also
pass. The latter now asserts that both the peer and live tab-owning terminal
clients exit successfully. Existing checkpoint/journal/draft/job failure
injection, delayed exit hooks, truthful receipts, deadlines and source-file
preservation checks remain enabled. Artifacts:
`/tmp/lem-shutdown-close-{daemon,native,durability,tabs}.log`.

Validated binaries:
`/nix/store/y6lhichhfg0y2zkhniill0j58qwmdv0s-lem-yath/bin/lem` and
`/nix/store/71plfwmlgyp3sicd5d2rlql78dahc2y9-sbcl-lemclient-unstable/bin/lemclient`.
Production, queue-regression and native-regression sources matched the completed
package's source byte for byte; the updated tab test ran directly against those
binaries. This is a shutdown correctness fix, with no typing-speed claim.
Installed profiles are unchanged.


### Reuse SDL rectangles within each paint pass (2026-09-19)

A fresh full GUI-input profile (600 edits plus 20 warmup events on the 10 MB
fixture) attributed 20.9% of sampled client allocation to `SDL2:MAKE-RECT`,
with 5.7% of CPU samples inclusive in that function. Allocation and CPU were
separate diagnostic runs; inclusive percentages are not additive. Artifacts:
`/tmp/lem-sdl-profile-{alloc,cpu}.{txt,json,log}`.

`draw-screen-rows` now owns one rectangle for its paint pass and explicitly
passes it to the private fill/glyph helpers. Each operation overwrites all four
geometry fields before the same checked SDL call. The existing `with-rects`
unwind cleanup still frees it on failure. An all-zero dirty mask returns before
allocation. There is no persistent rectangle, additional cache or raw FFI path.

A same-process ABBA software-renderer comparison loaded complete before/after
SDL source files, warmed glyphs, and performed a full GC before each measured
phase. The 40-row styled Unicode screen moved its box cursor between columns;
sparse runs used the retained target and full runs repainted directly. Means:

| Rendering workload | CPU before → after | Lisp bytes before → after |
| --- | ---: | ---: |
| 3,000 sparse presentations | 558.652 → 539.652 ms (−3.4%) | 17,627,712 → 6,136,128 (−65.2%) |
| 400 full presentations | 396.145 → 282.594 ms (−28.7%) | 79,528,896 → 19,596,736 (−75.4%) |

This component measurement excludes event input, socket decoding and daemon
editing. Script and log: `/tmp/lem-sdl-rect-component.{lisp,log}`.

The full GUI-input probe also ran ABBA, 600 edits plus 20 warmup per run, 25 ms
pacing, the same 10 MB fixture and fixed daemon binary
`/nix/store/y6lhichhfg0y2zkhniill0j58qwmdv0s-lem-yath/bin/lem`.
Only the disposable source-loaded client's SDL implementation was overlaid.
Each JSON records the actual overlay path and SHA256; the before file matches
`a3605ca96`, and the after file matches the candidate production source.
Mean client allocation fell 48,276,032 → 38,802,560 bytes (−19.6%). Client CPU
was 557.286 → 543.401 ms (−2.5%); unchanged daemon CPU averaged
419.592 → 419.554 ms, with substantial variation between individual runs.
GC CPU did not improve (4.256 → 4.349 ms); it is not a wall-pause measurement.

| GUI-input run | Submission/ack median / p95 / max (ms) | Client send/present median / p95 / max (ms) |
| --- | --- | --- |
| Before 1 | 1.054 / 1.440 / 2.522 | 0.926 / 1.265 / 2.376 |
| After 1 | 1.270 / 1.892 / 3.241 | 1.099 / 1.622 / 2.998 |
| After 2 | 0.978 / 1.300 / 2.939 | 0.854 / 1.146 / 2.798 |
| Before 2 | 1.222 / 1.667 / 2.538 | 1.062 / 1.438 / 2.401 |

The end-to-end latency result is mixed, not a consistent typing-speed win.
These are Xvfb software presentations, not physical monitor latency. Counters
include setup after initial presentation, warmup, idle time and probe hooks.
Every run checked the complete buffer, saved bytes, unchanged fixture and clean
client/daemon exits. Artifacts: `/tmp/lem-sdl-rect-{before,after}-{1,2}.{json,log}`;
probe copies `/tmp/lem-sdl-rect{.py,-client.lisp,-runs.py}`.

The SDL pixel suite passes retained/full repaint comparisons and new independent
fresh-rectangle references for clipped/zero-sized fills, shrinking geometry,
ASCII/CJK/combining/bold glyphs and spaces. Injected SDL fill failure still
propagates and frees its rectangle; unchanged frames allocate none.
Log: `/tmp/lem-sdl-rect-pixels.log`.

The packaged build passes all 19 native display/lifecycle checks, including
keyboard input, Unicode clipboard paste, resize, multiple clients, crashes and
shutdown behavior. Validated binaries:
`/nix/store/iyxzw0s1iyl460yccsyib2g5gg5dhk9q-lem-yath/bin/lem` and
`/nix/store/76fpj0hjabk14l9zfm332fl7s52d5n2g-sbcl-lemclient-unstable/bin/lemclient`.
Production and pixel-test files match the completed build's source byte for
byte. Build outputs and acceptance log:
`/tmp/lem-sdl-rect-{build.paths,native.log}`. Installed profiles are unchanged.


### Allocate the protocol's UTF-8 string once (2026-09-20)

The SDL client profile attributed 20.2% of sampled allocation to SBCL's
`UTF8->STRING-AREF`. In the pinned SBCL 2.5.10 implementation that decoder grows
an adjustable character string, then copies it into a simple string. Babel,
already a core dependency and previously the non-SBCL protocol decoder, counts
characters and allocates the result once. `decode-message` now uses that public
API on SBCL too, with explicit `:errorp t`. The byte limit, Yason parser, object
requirement and `protocol-error` boundary remain in place. Caller bindings that
suppress Babel coding errors cannot allow malformed UTF-8 into the protocol.

An independent decoder comparison found zero differences in 67,324 cases:
every one- and two-byte input, structured longer malformed/truncated boundary
sequences, and every Unicode scalar value in bounded chunks. Both decoders
reject surrogates and out-of-range encodings and preserve noncharacters.
Diagnostic: `/tmp/lem-utf8-equivalence.{lisp,log}`.

A same-process ABBA comparison loads the complete before/after protocol source
and calls the actual `decode-message`, including its size/object/error checks.
Each phase warms the parser and performs a full GC before measurement. Means:

| Decoding workload | CPU before → after | Lisp bytes before → after |
| --- | ---: | ---: |
| 10,000 input messages, 33 bytes each | 17.135 → 13.013 ms (−24.1%) | 25,595,968 → 18,139,840 (−29.1%) |
| 10,000 one-row messages, 296 bytes each | 106.652 → 89.260 ms (−16.3%) | 137,124,096 → 89,008,704 (−35.1%) |
| 400 full screens, 6,419 bytes each | 87.444 → 75.934 ms (−13.2%) | 98,639,360 → 73,288,512 (−25.7%) |
| 400 Unicode screens, 15,019 bytes each | 121.925 → 98.286 ms (−19.4%) | 142,981,696 → 90,829,056 (−36.5%) |

These are decoding component costs, not typing latency. Artifacts:
`/tmp/lem-utf8-component.{lisp,log}`. The earlier exploratory comparison omitted
some protocol checks in its Babel branch and is not used for these results.

All five daemon test modules and the SDL client test module pass. New protocol
cases cover escaped controls, UTF-8 width boundaries, Unicode keys, combining
and astral characters, adjustable/displaced octet vectors, 44 malformed-input
placements under a permissive Babel binding, and messages at/above the byte
limit. Logs: `/tmp/lem-utf8-{daemon,sdl-client}.log`.

All 19 packaged native display/lifecycle checks also pass. Validated binaries:
`/nix/store/60b6xqgcigg766yvz1cmdx6ls61lxld5-lem-yath/bin/lem` and
`/nix/store/kc5r27w2n6h597v98bjcsf1byhpwgivl-sbcl-lemclient-unstable/bin/lemclient`.
The production and protocol-test files match the completed build's source byte
for byte. Build outputs and acceptance log:
`/tmp/lem-utf8-{build.paths,native.log}`. Installed profiles are unchanged.

The packaged Babel dependency and Qlot's Babel match byte for byte across all
19 source Lisp files. The complete GUI-input comparison used the previous
configured package (`/nix/store/iyxzw0s1iyl460yccsyib2g5gg5dhk9q-lem-yath/bin/lem`)
and the candidate above, with matching protocol overlays in the disposable
source-loaded SDL clients. Each JSON records the actual overlay SHA256 and
package paths. Both sides retain the preceding SDL rectangle improvement.

The initial ABBA sequence was interrupted during the final baseline: its three
completed results remain in `/tmp/lem-utf8-gui-{before,after}-*.json`, while
`before-2` has no result JSON. No benchmark processes survived. A fresh complete
ABBA sequence on September 20 supplies the following reported numbers; the
interrupted sequence is not folded into its averages. Each run contains 600
measured edits plus 20 warmup events, 25 ms pacing and the same private copy of
the 10 MB UTF-8 fixture.

| GUI-input run | Submission/ack median / p95 / max (ms) | Client send/present median / p95 / max (ms) |
| --- | --- | --- |
| Before 1 | 1.032 / 1.435 / 2.678 | 0.889 / 1.236 / 2.503 |
| After 1 | 1.090 / 1.589 / 2.445 | 0.941 / 1.333 / 2.051 |
| After 2 | 0.927 / 1.125 / 1.584 | 0.807 / 0.974 / 1.332 |
| Before 2 | 0.985 / 1.418 / 2.416 | 0.855 / 1.195 / 2.148 |

Mean client Lisp allocation fell 40,102,848 → 31,753,344 bytes (−20.8%), and
daemon allocation fell 45,005,392 → 44,212,240 bytes (−1.8%). Whole-run client
CPU was 492.674 → 486.326 ms (−1.3%); daemon CPU was
385.273 → 388.132 ms (+0.7%). Client GC CPU was 3.526 → 3.362 ms; this is not
wall-pause duration. End-to-end latency remains mixed. The reliable allocation
reduction and isolated decoder CPU savings do not establish a universal typing
latency improvement.

These are software-rendered Xvfb endpoints, not physical monitor latency.
Counters include warmup, idle time and instrumentation; client counters also
include setup after initial presentation. Every published result passed full
buffer-text, saved-byte, unchanged-fixture and clean client/daemon exit checks.
Artifacts: `/tmp/lem-utf8-gui-r2-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-utf8-gui-r2-runs.log`; probe copies:
`/tmp/lem-utf8-gui.py`, `/tmp/lem-utf8-client.lisp`, and
`/tmp/lem-utf8-gui-r2-runs.py`. No core or undo behavior was changed; the previously
documented historical undo-model verification gap remains open.


### Diagnose and exercise an actual GPU renderer (2026-09-20)

The daemon SDL client still explicitly requests `:software`; the standalone
SDL frontend requests acceleration. Before changing that policy, the new
`scripts/bench/diagnostics/sdl-renderer.lisp` probe reports the Lisp/libc/SDL
versions, selected video backend, actual renderer information and, for OpenGL,
the GL device/version strings. It creates hidden windows, defaults to the
offscreen video driver, and reports renderer failures without treating a
successful allocation as proof of hardware acceleration. Run from the repo:

```sh
nix develop --command sbcl --noinform --no-sysinit --no-userinit \
  --non-interactive --load .qlot/setup.lisp \
  --load scripts/bench/diagnostics/sdl-renderer.lisp
```

On this host the pinned SBCL 2.5.10 process uses glibc 2.40, while the host Mesa
26.2.2 library needs `GLIBC_ABI_GNU2_TLS`. Direct loading fails with that missing
symbol. With the ordinary environment, both software and accelerated requests
therefore reported an actual **software** renderer. The installed SDL2 API is
sdl2-compat 2.32.58 over SDL3 3.2.26. Its `SDL_CreateRenderer` delegates default
selection to SDL3, and its subsequent property lookup overwrites the original
creation error on failure. An explicit OpenGL request consequently produced
only `Parameter 'renderer' is invalid`; a direct SDL3 probe recovered the
backend error. Evidence: `/tmp/lem-renderer-diagnostic.log`,
`/tmp/lem-renderer-explicit.log`, `/tmp/lem-sdl3-gl-vendor.log`.

This is a runtime compatibility obstacle, not a demonstrated editor algorithm
limit. Fetching Mesa **25.2.6 from the existing repository Nix pin** (39.1 MiB,
no build or host activation) enabled the same SBCL process to create an actual
OpenGL renderer with flags 10 (accelerated + target texture). The GL renderer
identified the AMD integrated GPU's `radeonsi, raphael_mendocino` driver and
OpenGL 4.6 / Mesa 25.2.6. The host driver remains installed and still fails its
separate loader check. The process-local test environment was:

```sh
SDL_VIDEODRIVER=offscreen EGL_PLATFORM=surfaceless \
__EGL_VENDOR_LIBRARY_FILENAMES=/nix/store/72h0721w18pc8103hqsi2iaywji795hq-mesa-25.2.6/share/glvnd/egl_vendor.d/50_mesa.json \
XDG_CACHE_HOME=/tmp/lem-renderer-driver-cache \
nix develop --command sbcl --noinform --no-sysinit --no-userinit \
  --non-interactive --load .qlot/setup.lisp \
  --load scripts/bench/diagnostics/sdl-renderer.lisp
```

That store path is the measured Linux package, not a portable driver setting.
Artifacts: `/tmp/lem-mesa-pinned-{dry-run.log,build.log}`, and
`/tmp/lem-renderer-pinned-mesa.log`. The new pixel-test support accepts the
isolated `offscreen` backend and prints actual renderer identity. With the
same environment plus `SDL_RENDER_DRIVER=opengl`, the full pixel suite passes
on the actual OpenGL renderer, including retained/full repaint equivalence,
Unicode/styles, cursors, resizing, target failure and rectangle cleanup. The
normal dummy/software suite also passes. Logs:
`/tmp/lem-renderer-{gpu,software}-pixels.log`.

An offscreen same-process ABBA component comparison kept current editor code
and varied only renderer selection. Each phase warmed glyphs and performed a
full GC. The 40-row styled Unicode screen moved a box cursor; sparse updates
used the retained target, and full updates repainted directly. Means:

| Workload | Software → OpenGL process CPU | Software → OpenGL elapsed |
| --- | ---: | ---: |
| 3,000 sparse updates | 1,054.674 → 139.130 ms (−86.8%) | 1,058.504 → 222.502 ms (−79.0%) |
| 400 full repaints | 337.275 → 593.391 ms (+75.9%) | 339.003 → 336.001 ms (−0.9%) |

Lisp allocation was similar (sparse 6,265,984 → 6,198,272 bytes; full
19,526,144 → 19,526,016). CPU includes native driver threads. These are
render-submission component costs ending at `SDL_RenderPresent` return,
not GPU-completion, GUI-input or physical monitor timings. The full-repaint CPU
increase and missing full GPU-input comparison prevent a general speedup claim.
Script/log: `/tmp/lem-renderer-component.{lisp,log}`. Automatic renderer selection
and installed profiles are unchanged pending that comparison.

API references: [SDL renderer creation](https://wiki.libsdl.org/SDL2/SDL_CreateRenderer),
[renderer flags](https://wiki.libsdl.org/SDL2/SDL_RendererFlags), and
[the pinned compatibility implementation](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.58/src/sdl2_compat.c).


### Measure native SDL event input on an offscreen GPU (2026-09-20)

`scripts/bench/e2e/sdl-input.py` now supports `--input-method sdl` alongside the
existing default `x11` mode. The new Linux/SBCL mode writes `x`/Backspace commands
to a private pipe. A disposable client thread constructs native key-down,
text-input and key-up events using SDL3's C headers and queues them in the SDL3
runtime underlying SDL2-compat. Lem's existing SDL2 event loop handles them,
including its normal keyboard translation, socket round trip, editing and
rendering. This mode requires SDL2-compat/SDL3; it verifies that SDL3 video is
already initialized before injection. The development shell supplies `sdl3`
headers; production packages and editor behavior are unchanged.

The new `--renderer software|opengl` option sets the renderer hint and asserts
that the actual renderer name matches. Both modes record actual video/renderer
identity, flags, GL device/version where applicable, selected graphics
environment, and hashes of all three probe source files. A silent software
fallback cannot be reported as a requested OpenGL run. Example with the matched
Mesa package from the preceding investigation:

```sh
LEM_BIN=/nix/store/60b6xqgcigg766yvz1cmdx6ls61lxld5-lem-yath/bin/lem \
EGL_PLATFORM=surfaceless \
__EGL_VENDOR_LIBRARY_FILENAMES=/nix/store/72h0721w18pc8103hqsi2iaywji795hq-mesa-25.2.6/share/glvnd/egl_vendor.d/50_mesa.json \
nix develop --command python3 scripts/bench/e2e/sdl-input.py \
  --input-method sdl --renderer opengl --count 600 \
  --fixture /tmp/lem-wire-large-corpora/mixed-10m.txt --output /tmp/new-gpu-input.json
```

The outer interval now means pipe submission through presentation acknowledgement
in SDL mode, and retains X11 submission in X11 mode. The inner interval still
starts at client `send-input` entry and ends just after `SDL_RenderPresent`.
The offscreen mode excludes OS/X11 delivery, GPU completion and monitor scanout;
[SDL event injection](https://wiki.libsdl.org/SDL2/SDL_PushEvent) also does not
update physical device state. This is a comparison of the application input
path, not physical keyboard latency. Resource counters include the injector
thread, pipe handling, warmup, idle time and instrumentation on both renderers.
The existing full-buffer, saved-byte, unchanged-fixture and clean-exit checks
still gate result publication.

Two pinned dependency behaviors required explicit handling in the probe. First,
sdl2-compat 2.32.58's `Event2to3` returns null for a pushed `SDL_TEXTINPUT`; its
`SDL_PushEvent` then passes that to SDL3 3.2.26, which dereferences it. The failed
initial probe produced a native memory fault and no result JSON. Second, CFFI's
SBCL `%foreign-symbol-pointer` ignores its library argument, resolving SDL2's
same-named function even when SDL3 was requested. Native `dlopen`/`dlsym` now
selects the SDL3 ABI explicitly; the C helper itself has no SDL symbol imports.
The helper stays loaded until process exit because queued text points to its
static string. The injector is joined before window/SDL teardown; a finite FD
wait bounds cleanup if the GUI fails while Python awaits an acknowledgement.
These changes are confined to the benchmark, not dependency or editor patches.

The standalone native-event check confirms distinct SDL2/SDL3 function pointers
and receives `KEYDOWN, TEXTINPUT, KEYUP` through SDL2's queue. Full smoke runs
pass on software/offscreen, actual AMD OpenGL/offscreen, and software/X11.
A deliberately invalid pipe byte (`a`, 97) reaches the reader assertion, exits
with an error and publishes no JSON. The final GPU and X11 result hashes match
the checked-in probe sources. Python compilation and strict C compilation
(`-Wall -Wextra -Werror`) pass. Artifacts:
`/tmp/lem-sdl-inject-native-check.{lisp,log}`,
`/tmp/lem-sdl-event-smoke-software-v5.{json,log}`,
`/tmp/lem-sdl-event-smoke-{gpu,x11}.{json,log}`, and
`/tmp/lem-sdl-event-smoke-negative.log`. Initial failure evidence remains in
`/tmp/lem-sdl-event-smoke-software{,-v4}.log` and their recorded client roots.


### Native input renderer comparison and SDL batching (2026-09-20)

The complete native-input renderer ABBA ran software/OpenGL/OpenGL/software,
each with 600 measured inputs, 20 warmup inputs, 25 ms pacing and the same
10 MB UTF-8 fixture. Both OpenGL runs identified the AMD radeonsi device and
Mesa 25.2.6 above; both software runs identified `software`. Means of the two
runs per renderer:

| Metric | Software | OpenGL |
| --- | ---: | ---: |
| Client process CPU | 758.782 ms | 377.433 ms (−50.3%) |
| Client Lisp allocation | 30,948,416 bytes | 31,138,816 bytes (+0.6%) |
| Pipe-to-presentation-ack median | 2.277 ms | 1.527 ms |
| Pipe-to-presentation-ack p95 | 2.697 ms | 1.696 ms |
| Client send-to-present median | 1.620 ms | 1.244 ms |
| Client send-to-present p95 | 1.890 ms | 1.337 ms |

Each run passed full-buffer equality, saved-byte equality, unchanged-fixture
and clean daemon/client exit checks. Probe and client source hashes were
verified against `a30b481f9` before the subsequent batching edit. Artifacts:
`/tmp/lem-sdl-event-{software,opengl}-{1,2}.{json,log}`, driven by
`/tmp/lem-sdl-event-runs.py`. Daemon CPU varied substantially (394–517 ms for
software, 408–418 ms for OpenGL); the renderer comparison does not establish a
daemon speedup. These endpoints exclude GPU completion and physical scanout.
Software/offscreen timings also must not be compared directly with X11 timings
from preceding experiments. The production renderer choice remains software.

Inspection then found that SDL2-compat disables batching when a renderer is
selected explicitly, including the client's software flag or a renderer hint.
The previous automatic accelerated component test used a different default.
A new component experiment explicitly set `SDL_RENDER_BATCHING` to 0/1/1/0 for
each renderer, warming and collecting garbage before each measurement:

| Workload | Unbatched → batched CPU | Unbatched → batched elapsed |
| --- | ---: | ---: |
| Software, 3,000 sparse updates | 1,045.620 → 1,021.704 ms (−2.3%) | 1,051.501 → 1,029.001 ms |
| Software, 400 full repaints | 356.235 → 323.136 ms (−9.3%) | 358.500 → 325.000 ms |
| OpenGL, 3,000 sparse updates | 191.023 → 141.133 ms (−26.1%) | 222.501 → 220.500 ms |
| OpenGL, 400 full repaints | 963.038 → 635.070 ms (−34.1%) | 428.501 → 358.500 ms |

Allocation was essentially unchanged. CPU includes native driver workers;
GPU elapsed intervals still end at submission, not GPU completion. Script/log:
`/tmp/lem-renderer-batching-component.{lisp,log}`. Batching addresses part of
the full-repaint cost; OpenGL full repaints still used more process CPU than
software in this component workload.

The daemon SDL client now requests batching before renderer creation using a
normal-priority hint, so `SDL_RENDER_BATCHING=0` remains an override. All its
drawing uses SDL, which manages flushes at presentation, render-target changes,
texture dependencies and pixel readback. No frame is dropped or coalesced by
this change. The input probe now records the environment setting and the
resolved batching hint. References: [SDL batching contract](https://wiki.libsdl.org/SDL2/SDL_HINT_RENDER_BATCHING)
and [hint priorities](https://wiki.libsdl.org/SDL2/SDL_SetHintWithPriority).


Offscreen input also has a backend-specific timing limit: SDL 3.2.26's
[offscreen device](https://github.com/libsdl-org/SDL/blob/release-3.2.26/src/video/offscreen/SDL_offscreenvideo.c)
does not provide `WaitEventTimeout`/`SendWakeupEvent`. Its
[event loop](https://github.com/libsdl-org/SDL/blob/release-3.2.26/src/events/SDL_events.c)
therefore takes the fallback path with a 1 ms polling interval. This supports
using the offscreen results for matched renderer comparisons, but not treating
their absolute latency as a lower bound on a desktop client. It does not justify
adding polling or busy-waiting to Lem.


A subsequent full-input ABBA compared `SDL_RENDER_BATCHING=0` with the new
unset-environment default, separately on software/X11 and OpenGL/offscreen.
Every run recorded the resolved hint, actual renderer, source/probe hashes,
600 inputs, 20 warmups and the same 10 MB fixture. Means of each pair:

| Backend | Client CPU, off → on | Submission-to-ack median / p95, off → on | Send-to-present median / p95, off → on |
| --- | ---: | ---: | ---: |
| Software/X11 | 438.978 → 432.011 ms (−1.6%) | 0.909 / 1.051 → 0.906 / 1.044 ms | 0.794 / 0.910 → 0.789 / 0.898 ms |
| OpenGL/offscreen | 289.994 → 248.570 ms (−14.3%) | 1.427 / 1.503 → 1.389 / 1.462 ms | 1.198 / 1.232 → 1.169 / 1.194 ms |

X11 typing latency is effectively unchanged; its individual run medians
interleave. The stronger evidence is reduced rendering CPU, with a small
OpenGL input-path reduction. Allocation varied by about 1–1.5% in these runs;
the component experiment showed no material allocation change. No overall
allocation or physical typing speedup is attributed to batching.
All eight runs passed complete buffer/save/fixture comparisons and both clean
exit checks, and their recorded source/probe hashes were verified. Artifacts:
`/tmp/lem-batching-r2-{x11,sdl}-{off,on}-{1,2}.{json,log}`,
`/tmp/lem-batching-input-r2.{py,log}`.

The first X11 attempt mistakenly inherited the matched offscreen Mesa/EGL
settings and hit `FLOATING-POINT-INVALID-OPERATION` inside driver context creation
at `SDL_CreateRenderer`, before measurement. It produced no result JSON and was
excluded. The replacement runner restores the ordinary X11 graphics environment
and applies the private Mesa settings only to offscreen GPU runs. Evidence:
`/tmp/lem-batching-x11-off-1.log` and its client artifact root. This driver failure
is tracked separately from batching; it occurred with batching disabled.

Pixel suites pass on dummy/software with the default enabled, dummy/software
with the explicit disable override, and actual OpenGL/offscreen with the default
enabled. The regression asserts hint precedence and exercises retained/full
pixels, Unicode/styles, cursors, resize/reset, target failure and cleanup.
Logs: `/tmp/lem-batching-{default,override,gpu}-pixels.log`.


Packaged validation passed all 19 native display/lifecycle checks. The built
production SDL source and pixel-test source match the checkout byte-for-byte.
Configured package: `/nix/store/h9sjxv2l8dijamd7dpkwziyjrzr85z58-lem-yath`;
client: `/nix/store/ibkcln47vhnskhbqq6dyfgks1kxmdcjn-sbcl-lemclient-unstable`.
Evidence: `/tmp/lem-batching-build.paths`, `/tmp/lem-batching-native.log`.
No installed profile was activated.


### Restore native floating-point behavior in the SDL client (2026-09-20)

The Mesa/X11 startup failure above exposed a missing part of cl-sdl2's normal
thread setup. The daemon client deliberately uses one calling thread and
low-level `init*`/`quit*`, bypassing `SDL-MAIN-THREAD`, which normally masks
floating-point traps around native graphics calls. Under SBCL's default traps,
the matched Mesa runtime raised `FLOATING-POINT-INVALID-OPERATION` while creating
a renderer. Even the requested software renderer reached graphics context
creation through SDL's window framebuffer path.

`run-graphical` now reuses cl-sdl2's existing internal `without-fp-traps` macro
around initialization, the event loop and teardown. It retains the single UI
thread and restores the caller's traps on exit, including failed initialization.
The source comment records why the library's internal macro is used. No daemon
editor behavior or renderer selection changes.

A new SBCL regression exercises a real native `sqrt(-1)` call from substituted
initialization, window handling and cleanup functions. Before the fix, it
reproduced invalid-operation conditions and failed. Afterward, native calls
return IEEE NaNs as expected. The test covers normal multiple-value return and
injected failures at all three phases, verifies exact condition identity,
checks cleanup ordering and confirms the caller's trap settings are restored.
The final SDL client test suite passes. Evidence:
`/tmp/lem-native-float-before-tests.log`,
`/tmp/lem-native-float-after-tests.log`, `/tmp/lem-native-float-client.log`.

The source-loaded client also passes a four-input smoke with the exact graphics
settings that previously crashed: private X11, software renderer, batching
explicitly disabled, `EGL_PLATFORM=surfaceless` and matched Mesa 25.2.6. It
verifies full text, saved bytes and clean daemon/client exits. The same DRI3
warnings remain, but there is no floating-point exception. Artifact:
`/tmp/lem-native-float-x11-smoke.{json,log}`. This is a startup/correctness check,
not a timing comparison or proof of host GPU compatibility; the host-driver
GLIBC ABI mismatch remains a separate issue.


Final validation passes the SDL client suite, software and actual OpenGL pixel
suites, and all 19 packaged native display/lifecycle checks. Built production
SDL and both SDL test files match the checkout byte-for-byte. Configured package:
`/nix/store/sgzg162yqal3cqm5z7nbda9z52vqbccc-lem-yath`; native client:
`/nix/store/j2hi362gj94al6dd4wb8ki7zqm68w0km-sbcl-lemclient-unstable`.
Logs: `/tmp/lem-native-float-{software,gpu}-pixels.log`,
`/tmp/lem-native-float-build.paths`, `/tmp/lem-native-float-native.log`.
No installed profile was activated.


### Avoid allocating glyph lookup keys on cache hits (2026-09-20)

`draw-glyph` built a fresh three-cons key `(text foreground bold)` for every
non-space glyph, even when its texture was already cached. The temporary key
now has declared dynamic extent, which SBCL places on the stack. A cache miss
stores a `copy-list` of that key, preserving its lifetime in the texture cache.
The cache format, equality test, limits, glyph/style distinctions and surface
cleanup are unchanged. No global scratch key or additional cache is introduced.

A same-process ABBA changed only the renderer source, separately for software
and actual OpenGL on the matched offscreen Mesa runtime. Glyphs were warmed and
a full GC preceded each phase. Sparse updates used the retained frame cache;
full repaints used the direct path without a retained frame cache. Mean results:

| Workload | Lisp bytes, before → after | Process CPU, before → after |
| --- | ---: | ---: |
| Software, 3,000 sparse updates | 6,202,496 → 2,305,984 (−62.8%) | 805.008 → 803.533 ms |
| Software, 400 full repaints | 19,602,624 → 101,504 (−99.5%) | 302.360 → 302.435 ms |
| OpenGL, 3,000 sparse updates | 6,105,792 → 2,323,968 (−61.9%) | 144.362 → 133.014 ms |
| OpenGL, 400 full repaints | 19,598,656 → 103,552 (−99.5%) | 633.483 → 635.973 ms |

This is predominantly an allocation improvement. Software CPU and full-repaint
CPU are effectively unchanged; OpenGL sparse-update CPU fell about 7.9% in this
component workload. These figures do not measure typing or monitor latency.
Artifacts: `/tmp/lem-glyph-key-{before,after}.lisp` and
`/tmp/lem-glyph-key-component.{lisp,log}`. Both variants retain the preceding
batching and floating-point fixes.

The pixel suite now additionally verifies that six glyph/style keys remain
retrievable with their original texture identities after repeated later
lookups and full garbage collections. This exercises the persistent-key
lifetime independently of the temporary lookup objects. The full software and
OpenGL pixel suites pass, as does the SDL client suite. Logs:
`/tmp/lem-glyph-key-{client,software-pixels,gpu-pixels}.log`.

For reproducible full-input comparisons, `sdl-input.py` now accepts
`--client-sdl-source /path/to/sdl-client.lisp`. The disposable client loads that
file after normal system loading; the daemon package remains explicit through
`LEM_BIN`. Results record the selected source path and its hash, and reject a
source file changed during the run. Inherited `LEM_SDL_SOURCE` is cleared unless
the CLI option selects an override. Normal runs continue loading the checkout.
This avoids ad hoc edits to the probe for each before/after comparison.


The full X11 input ABBA used the same configured daemon, software renderer,
batching default, 10 MB UTF-8 fixture, 600 measured inputs, 20 warmups and 25 ms
pacing. Means of the two runs per source:

| Metric | Before | After |
| --- | ---: | ---: |
| Client process CPU | 434.763 ms | 432.182 ms (−0.6%) |
| Client Lisp allocation | 31,563,392 bytes | 29,440,064 bytes (−6.7%) |
| Client GC CPU | 4.241 ms | 4.161 ms |
| X11 submission-to-ack median / p95 | 0.887 / 1.169 ms | 0.875 / 1.121 ms |
| Client send-to-present median / p95 | 0.782 / 1.011 ms | 0.768 / 0.968 ms |

The individual median ranges overlap; maximum latency did not improve. The
supported full-path result is reduced client allocation, with essentially
unchanged CPU, rather than a general typing-latency claim. Daemon allocation
was effectively unchanged (44,168,016 → 44,164,432 bytes). Each run passed
full-buffer, saved-byte, unchanged-fixture and clean daemon/client exit checks.
Selected source paths/hashes, all probe hashes and sample counts were verified.
Artifacts: `/tmp/lem-glyph-key-{before,after}-{1,2}.{json,log}`, driven by
`/tmp/lem-glyph-key-input.{py,log}`.


All 19 packaged native display/lifecycle checks pass. Built production SDL and
pixel-test sources match the checkout byte-for-byte. Configured package:
`/nix/store/zpzni4jv3aj7w9nkpsz7bpr3vnqgw8nx-lem-yath`; native client:
`/nix/store/g8fx3k52p0rdy241zpq6lpgvz257086d-sbcl-lemclient-unstable`. Logs:
`/tmp/lem-glyph-key-build.paths`, `/tmp/lem-glyph-key-native.log`.
No installed profile was activated.


### Locate the remaining client cost with Lisp and native profiles (2026-09-20)

Profiles at `ca01a9b39` used the complete private X11/software input path and
10 MB fixture. After an initial pass showed cold dispatch/compiler activity,
refined probes started after 20 warmup inputs. Allocation profiling recorded
2,284 regions over 1,200 measured inputs at 5 ms pacing: protocol decoding was
on 62.1% of sampled allocation stacks, Yason string parsing on 35.0%, and screen
drawing on 3.0%. These are sampled regions, not exact byte attribution. The
CPU profile recorded 1,438 samples over 2,400 inputs at 2 ms pacing, but 72.9%
was unresolved by the Lisp report. Allocation alone was therefore insufficient
to identify the main CPU bottleneck.

Linux perf 6.18 was fetched from the locked Nixpkgs (`p.perf`, 2.9 MiB download)
without changing the development shell or system configuration. User-space
hardware counters are permitted with the host's existing `perf_event_paranoid=2`;
no privilege elevation was needed. A disposable client exported its SBCL perfmap,
then enabled a `cycles:u` capture after warmup using perf's control-pipe
acknowledgement. The clean 2,400-input capture had no lost samples:

| Native profile attribution | Share of sampled user-space cycles |
| --- | ---: |
| SDL3 library | 73.89% |
| `SDL_FillSurfaceRect4SSE` | 44.91% |
| `Blit8888to8888PixelSwizzleAVX2` | 25.07% |
| `Blit8888to8888PixelAlphaSwizzleAVX2` | 1.10% |

The function rows are included in the SDL3 total. This shifts the immediate CPU
priority to full-window clearing/copying, while JSON remains the main allocation
candidate. Kernel time, compositor work and physical scanout are outside this
capture. Profiling setup and instrumentation alter timings and allocations;
none of these profiled JSON results are used as latency or speedup benchmarks.
Both warm Lisp profiles and the final native capture passed the full document,
save, fixture and clean-exit checks.

Artifacts: `/tmp/lem-current-client-warm-{alloc,cpu}.{lisp,json,log}`,
`/tmp/lem-current-client-warm-{alloc,cpu}-report.txt`,
`/tmp/lem-current-client-native-r2.{lisp,json,log,perf.data}` and
`/tmp/lem-current-client-native-r2-{dso,symbols}.txt`. The initial native capture
was excluded because the probe rejected cleanup: perf 6.18 acknowledges with
`ack\n\0`, and UIOP reports the requested SIGINT exit as 130. The corrected
probe consumes all five acknowledgement bytes and accepts the expected status;
other failures remain errors. Evidence of that initial rejection remains in
`/tmp/lem-current-client-native.log` and its client artifact root.


### Remove the redundant clear before a complete cached-frame copy (2026-09-20)

The native profile above identified a full-window clear immediately followed
by a full-window copy from the retained texture. That clear is now omitted on
the cached path. The target is initialized completely before use, and SDL2
texture creation gives it `SDL_BLENDMODE_NONE`; the copy therefore overwrites
every window pixel. A runtime check returned blend mode 0, and the pinned
[SDL2 compatibility implementation](https://github.com/libsdl-org/sdl2-compat/blob/release-2.32.58/src/sdl2_compat.c)
explicitly sets this mode in `SDL_CreateTexture`. This differs from SDL3's
alpha-texture default; the client uses the SDL2 API. Diagnostic:
`/tmp/lem-frame-texture-info.{lisp,log}`.

SDL recommends clearing before each frame, even when overwriting it. This
optimization relies on the narrower complete-copy invariant and still treats
the old backbuffer as undefined. Direct/fallback repaint and target initialization
retain their clears. The pixel regression now poisons the window backbuffer
with an unrelated color before every candidate repaint, including unchanged
frames, to prove that every output pixel is reconstructed. Software and actual
OpenGL suites pass, including Unicode, styles, cursors, resize/reset, dense/sparse
transitions and target failure. The SDL client suite also passes. Logs:
`/tmp/lem-frame-clear-{client,software-pixels,gpu-pixels}.log`.

The warmed, same-process offscreen component ABBA used the same glyph-cache,
batching and floating-point fixes on both sides. Sparse updates use the retained
target; full updates use direct repaint. Means:

| Workload | Process CPU, before → after | Elapsed, before → after |
| --- | ---: | ---: |
| Software, 3,000 sparse updates | 961.739 → 652.856 ms (−32.1%) | 963.499 → 651.499 ms |
| Software, 400 full repaints | 302.548 → 301.449 ms | 303.000 → 302.000 ms |
| OpenGL, 3,000 sparse updates | 129.139 → 123.920 ms | 217.000 → 215.500 ms |
| OpenGL, 400 full repaints | 595.847 → 608.842 ms | 339.000 → 343.999 ms |

The direct full-repaint path is unchanged; its variation is not attributed to
this edit. Allocation was effectively unchanged. OpenGL measurements end at
`SDL_RenderPresent` return and do not establish GPU-completion performance.
Artifacts: `/tmp/lem-frame-clear-{before,after}.lisp` and
`/tmp/lem-frame-clear-component.{lisp,log}`.


The complete software/X11 input ABBA then used the same configured daemon,
10 MB UTF-8 fixture, 600 measured inputs, 20 warmups and 25 ms pacing. Means of
the two runs per source:

| Metric | Before | After |
| --- | ---: | ---: |
| Client process CPU | 474.278 ms | 308.909 ms (−34.9%) |
| Client Lisp allocation | 29,695,680 bytes | 29,623,040 bytes |
| X11 submission-to-ack median / p95 | 0.961 / 1.320 ms | 0.832 / 1.219 ms |
| Client send-to-present median / p95 | 0.827 / 1.140 ms | 0.704 / 1.021 ms |

Both candidate medians were below both baseline medians. The average
send-to-present median fell 14.9% and the submission-to-ack median 13.4%.
Individual p95 values overlapped, and the candidate's worst sample was not
lower than the baseline's worst sample; this is not an all-tail-latencies claim.
Daemon CPU was essentially unchanged (384.583 → 381.875 ms), as was allocation.
The timing endpoints still exclude physical monitor scanout and GPU completion.
All four runs passed full text/save/fixture comparisons and clean client/daemon
exits. Selected source paths/hashes and probe hashes were verified. Artifacts:
`/tmp/lem-frame-clear-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-frame-clear-input.{py,log}`.


All 19 packaged native display/lifecycle checks pass. The built production SDL
and strengthened pixel-test sources match the checkout byte-for-byte.
Configured package: `/nix/store/4sqyk13qg9v1sbk1c1zq752di11z1mqk-lem-yath`;
native client: `/nix/store/ylp6rb43xhivmxbq324sgalnza9vdcza-sbcl-lemclient-unstable`.
Evidence: `/tmp/lem-frame-clear-build.paths`, `/tmp/lem-frame-clear-native.log`.
The installed editor profile remains unchanged.


### Keep ARGB8888 after testing the preferred frame format (2026-09-20)

A fresh native profile at `3923d4515`, after removing the redundant clear,
attributed 52.22% of sampled user-space cycles to SDL3. Pixel conversion
(`Blit8888to8888PixelSwizzleAVX2`) accounted for 41.67%, while
`SDL_FillSurfaceRect4SSE` fell to 3.55%. The 2,400-input, 20-warmup X11/software
capture had 676 samples and no lost samples. Source/probe hashes, document/save
checks and clean exits passed. Artifacts: `/tmp/lem-no-clear-native.{lisp,json,log,perf.data}`,
`/tmp/lem-no-clear-native-{dso,symbols}.txt`. These are profiling observations,
not latency measurements; instrumentation and perfmap setup alter the run.

The candidate selected the renderer's first texture format when it was a
packed 32-bit layout with eight bits per RGB channel, otherwise retaining
ARGB8888. It queried once per target allocation, freed renderer information
on success/error, and kept the existing direct-repaint failure path. Here the
preferred software format was RGB888 (SDL3 XRGB8888), matching the window.
This eliminated conversion but **regressed performance**, so it was removed.

Warmed offscreen component ABBA, means of two runs per source:

| Workload | Process CPU, ARGB8888 → preferred format | Elapsed, ARGB8888 → preferred format |
| --- | ---: | ---: |
| Software, 3,000 sparse updates | 604.152 → 899.568 ms (+48.9%) | 634.500 → 897.501 ms |
| Software, 400 full repaints | 320.454 → 303.355 ms | 322.000 → 304.000 ms |
| OpenGL, 3,000 sparse updates | 133.235 → 132.614 ms | 216.000 → 215.000 ms |
| OpenGL, 400 full repaints | 631.000 → 615.813 ms | 357.500 → 349.500 ms |

Full repaints bypass the target and are unchanged; their variation is not a
format-selection gain. The complete X11/software input ABBA used the same
configured daemon, 10 MB UTF-8 document, 600 measured inputs, 20 warmups and
25 ms pacing. Means:

| Metric | ARGB8888 | Preferred format |
| --- | ---: | ---: |
| Client process CPU | 289.834 ms | 354.211 ms (+22.2%) |
| Client Lisp allocation | 29,514,048 bytes | 29,398,784 bytes |
| X11 submission-to-ack median / p95 | 0.759 / 1.068 ms | 0.871 / 1.082 ms |
| Client send-to-present median / p95 | 0.643 / 0.881 ms | 0.752 / 0.935 ms |

Both candidate medians exceeded both baseline medians. Mean send-to-present
median regressed 17.0%. The worst samples were lower for the candidate, so this
is a CPU/median regression, not a claim that every latency statistic worsened.
Daemon CPU stayed similar (344.555 → 341.697 ms). All four runs passed complete
text, save bytes, unchanged source fixture and clean exits; selected source and
probe hashes were checked. Endpoints exclude GPU completion and monitor scanout.
Artifacts: `/tmp/lem-frame-format-{before,after}-{1,2}.{json,log}`,
`/tmp/lem-frame-format-input.{py,log}`, `/tmp/lem-frame-format-component.{lisp,log}`
and `/tmp/lem-frame-format-{before,after}.lisp`.

The pinned [SDL3 copy implementation](https://github.com/libsdl-org/SDL/blob/release-3.2.26/src/video/SDL_blit_copy.c)
uses SSE streaming stores for aligned same-format copies. A separate warmed
30,000-sparse-frame candidate profile attributed 35.09% of sampled cycles to
`SDL_BlitCopy`, 47.86% to libc's `__memmove_avx512_unaligned_erms`, and only 1.70%
to the remaining alpha pixel conversion. It had 8,909 samples, none lost.
This confirms that different copy routines dominate; attributing the whole
regression specifically to streaming-store/cache behavior remains an inference.
Its counters are not used as a before/after benchmark. Artifacts:
`/tmp/lem-frame-format-component-native.{lisp,log,perf.data}`,
`/tmp/lem-frame-format-component-native-symbols.txt` and its `-perf.log`.

The candidate passed software/OpenGL pixel equivalence and synthetic preferred
format/fallback/cleanup checks, but correctness alone did not justify shipping
it. The production rendering behavior remains at `3923d4515`. Non-primary
foreground/background/cursor comparisons are retained for direct repaint,
target reconstruction and subsequent sparse cursor repaint;
final software and OpenGL tests pass against the retained production behavior.
Logs: `/tmp/lem-frame-format-final-{software,gpu}-pixels-r2.log`. Existing packaged
checks above still describe that production implementation; no new package or
installed-profile activation is claimed for this rejected experiment.


### Suppress unchanged daemon screen messages (2026-09-20)

A private X11 input capture at `3064910bd` found that each of 40 typed inputs
(20 warmups and 20 measured inputs) was followed by a second screen message
with no changed rows or display metadata. Sending these still incurred JSON
encoding/decoding, queue traffic, and potentially another full-window copy.

Each daemon implementation now retains the display properties of its last
accepted screen message: foreground/background, mouse mode, terminal escape
delay, cursor coordinates, shape and color. An update is omitted only when
its existing row diff is empty and all those properties match. Forced redraws
still send a message, and initial frames, dimension changes and snapshot resets
retain full-frame behavior. State is private to each client and is advanced
only after its message is accepted by the existing bounded output queue.
No wire format, acknowledgement, input handling or queue limit changed.

With the packaged candidate, the same capture fell from 83 to 43 screen
messages (including setup), with zero redundant empty updates. Removing those
40 duplicates from the baseline makes its remaining decoded messages **exactly
equal** to the candidate's sequence. Framed screen bytes fell from 47,392 to
39,792. Capture instrumentation is excluded from performance claims. Both runs
passed complete document/save/fixture and clean-exit checks; source/probe hashes
were verified. Artifacts: `/tmp/lem-screen-wire-sample{,-after}.{lisp,json,jsonl,log}`.

The uninstrumented complete-input ABBA used the same source-loaded client,
software/X11 renderer, 10 MB UTF-8 fixture, 600 measured inputs, 20 warmups and
25 ms pacing. Only the packaged daemon changed. Means of two runs per package:

| Metric | Before | After |
| --- | ---: | ---: |
| Client process CPU | 271.629 ms | 208.466 ms (−23.3%) |
| Client Lisp allocation | 29,038,400 bytes | 24,751,040 bytes (−14.8%) |
| Daemon process CPU | 342.423 ms | 323.630 ms (−5.5%) |
| Daemon Lisp allocation | 44,170,448 bytes | 41,802,320 bytes (−5.4%) |
| X11 submission-to-ack median / p95 | 0.760 / 1.086 ms | 0.741 / 1.117 ms |
| Client send-to-present median / p95 | 0.654 / 0.945 ms | 0.638 / 0.961 ms |

Both candidate client CPU measurements were below both baseline measurements.
Latency median ranges overlap, and mean p95 increased slightly despite a lower
mean median and worst sample. This is an efficiency result, not a general
latency improvement claim. GPU completion and physical monitor scanout remain
outside the timing endpoints. All four full text/save/fixture comparisons,
clean exits and client-source/probe hashes passed verification. Artifacts:
`/tmp/lem-screen-dedup-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-screen-dedup-input.{py,log}`.

Regression coverage exercises repeated unchanged redraws across grid reuse,
individual metadata changes, cursor-only updates, text/style and style-only
edits, independent client snapshots, forced redraws, both resize dimensions,
and snapshot reset. The daemon suite passes, including its integration and
backpressure checks. The final test uses the background-only attribute setter
so cleanup preserves the cursor's other style flags. Final suite log:
`/tmp/lem-screen-dedup-daemon-r2.log`.

All 19 packaged native display/lifecycle checks pass. Packaged production
implementation and SDL sources match the checkout byte-for-byte. The only
subsequent protocol-test adjustment was the background-only setter above;
production behavior is identical to the measured package. Configured package:
`/nix/store/43nrpq32ksq88ammff5rg8ixjfbma7i7-lem-yath`;
client: `/nix/store/iw017gpbsmkhd4cvw2q2085b8k30j6j0-sbcl-lemclient-unstable`.
Evidence: `/tmp/lem-screen-dedup-build.paths`, `/tmp/lem-screen-dedup-native.log`.
The installed editor profile remains unchanged.


### Preserve case-only screen changes without slowing cached comparisons (2026-09-20)

Review found an existing correctness bug in the daemon row diff: Common Lisp
`equalp` folds string case, so changing `x` to `X` could leave the client showing
its old row. Cursor movement or forced presentation did not repair a row whose
text was omitted from the diff. The independent wire-reconstruction regression
now covers ASCII case-only edits and `漢ä́` → `漢Ä́`, including wide and combining
cells. Both assertions fail before the fix and pass afterward. The row comparator
now checks cell text and faces case-sensitively, retaining dimension checks and
an explicit identity fast path for the immutable strings and face lists shared
by cached rows. There is no unsafe array access policy or implementation-specific
memory comparison.

A first case-sensitive single-pass candidate passed correctness checks but
increased full-input daemon CPU from 309.529 to 343.340 ms (+10.9%). Its component
benchmark lacked the representative case where both row snapshots share their
cell/face objects. Adding that case exposed recursive comparison overhead.
SBCL's own `equalp` array loop explicitly checks identity before descending;
the final comparator uses the same standard `eq`-then-`equal` pattern, preserving
case-sensitive text semantics. The slower candidate was not committed. Its
validated full-input artifacts remain at `/tmp/lem-row-case-{before,after}-{1,2}.{json,log}`
and `/tmp/lem-row-case-input.{py,log}`; they are excluded from final results.

Final warmed component ABBA, process CPU means for 400,000 row comparisons per
run. These common-workload cases have the same expected result under both
comparators; the separate regression above establishes the corrected behavior.

| Row pair | Original `equalp` | Final comparator |
| --- | ---: | ---: |
| Equal ASCII text, freshly constructed equal faces | 196.028 ms | 91.372 ms |
| Cached cells and faces shared by both snapshots | 23.669 ms | 26.958 ms |
| Equal Unicode text, freshly constructed equal faces | 147.921 ms | 86.943 ms |
| Early text difference | 4.007 ms | 4.180 ms |
| Early style difference | 16.843 ms | 4.596 ms |

The cached case retains a small absolute overhead (about 8 ns per row in this
component test); allocation remains effectively unchanged. This table is not an
end-to-end speedup claim. Artifact: `/tmp/lem-row-case-component-r3.{lisp,log}`.
Earlier component investigations are in `/tmp/lem-row-case-{component,component-r2,candidates,identity}.log`.

The daemon suite passes, including the new regressions, integration and
backpressure checks. Negative control: `/tmp/lem-row-case-before.log`; final
suite: `/tmp/lem-row-case-after-r3.log`. All 19 packaged native display/lifecycle
checks pass, and both production and regression-test sources match the built
snapshot. Configured package: `/nix/store/wfmyi7r8w172gpxq4s2xdwglzz3hy0mg-lem-yath`;
client: `/nix/store/g0hk4zis1h0ryafw1rn8hw9bbfspvhfj-sbcl-lemclient-unstable`.
Evidence: `/tmp/lem-row-case-r3-build.paths`, `/tmp/lem-row-case-r3-native.log`.
No installed-profile activation was performed.


Final complete-input ABBA against `400061038` used software/X11, the same 10 MB
UTF-8 `.txt` fixture, 600 measured inputs, 20 warmups and 25 ms pacing. Means:

| Metric | Before case fix | Final case fix |
| --- | ---: | ---: |
| Daemon process CPU | 316.526 ms | 325.339 ms (+2.8%) |
| Client process CPU | 199.043 ms | 203.422 ms (+2.2%) |
| Daemon Lisp allocation | 41,714,576 bytes | 41,715,024 bytes |
| Client Lisp allocation | 24,509,504 bytes | 24,247,360 bytes |
| X11 submission-to-ack median / p95 | 0.743 / 0.949 ms | 0.752 / 0.896 ms |
| Client send-to-present median / p95 | 0.641 / 0.816 ms | 0.640 / 0.758 ms |

Daemon CPU ranges overlap, as do median timing ranges. These runs do not prove
zero overhead, but the earlier 10.9% CPU regression was substantially reduced;
allocation stayed effectively flat and send-to-present medians stayed near
0.64 ms. The fix is retained for correctness without a general speedup claim.
All four full text/save/fixture comparisons, clean exits, client-source/probe
hashes and packaged production/test-source checks passed. Endpoints exclude
GPU completion and physical monitor latency. This `.txt` workload also does not
establish Lisp-mode or LSP performance. Artifacts:
`/tmp/lem-row-case-r3-{before,after}-{1,2}.{json,log}` and
`/tmp/lem-row-case-input-r3.{py,log}`.


### Measure configured Lisp-mode input, including editing hooks (2026-09-20)

The SDL input probe now accepts `--document-name` and `--expect-major-mode`.
Normal filename-based mode selection activates the configured editing hooks;
the probe records the actual major mode, active modes and syntax-highlighting
state before timing. A mismatched expected mode aborts the run. Document names
must be single filenames, and documents live in a private subdirectory so they
cannot collide with probe logs. The default remains `bench.txt`.

The pinned `lisp-500k-5cd018a9.lisp` corpus triggered normal format-on-save
indentation changes. The initial smoke run correctly rejected the saved-byte
mismatch (`/tmp/lem-lisp-mode-smoke.log`); the original corpus was not modified.
The prepared fixture `/tmp/lem-lisp-500k-formatted.lisp` is the saved private
copy from `/tmp/lem-sdl-input-nvdwe1ro/document/bench.lisp`, with exactly the
leading `BENCH_TARGET\n` marker removed. It has 524,731 bytes and SHA-256
`879c5b01637e0f9d80e7377476cc22439fc42a5da7a2e5a15473dc62da0cc3f9`.
A second smoke run passed the original strict text/save/fixture checks, proving
save stability for this workload. Formatting and other mode hooks stay enabled.

```sh
LEM_BIN=/absolute/path/to/configured/lem nix develop --command \
  python3 scripts/bench/e2e/sdl-input.py --renderer software --count 600 \
  --fixture /tmp/lem-lisp-500k-formatted.lisp --document-name bench.lisp \
  --expect-major-mode LISP-MODE --output /tmp/new-lisp-input.json
```

The Lisp workload reports `LISP-MODE`, `PAREDIT-MODE`, `LINK-MODE`, configured
lint, debugger and Git gutter modes, plus the usual snippet, line-number,
direnv, which-key and Vi modes. Syntax highlighting is enabled. The plain-text
comparison uses identical bytes under `bench.txt` and verifies
`FUNDAMENTAL-MODE`, with highlighting disabled by normal mode selection.
This is ordinary x/backspace input at the first line; it does not establish
REPL evaluation, completion, structural-command or deep-file editing latency.
Seven invalid/empty/path-traversing names were rejected before startup, and
Python syntax compilation passed without writing bytecode into the checkout.

A sequential text/Lisp/Lisp/text comparison used configured daemon
`/nix/store/wfmyi7r8w172gpxq4s2xdwglzz3hy0mg-lem-yath/bin/lem` and client source
`9e5a54632`, software/X11, 600 measured inputs plus 20 warmups, 25 ms pacing.
Means of two runs per mode:

| Metric | Plain text | Configured Lisp |
| --- | ---: | ---: |
| Daemon process CPU | 378.362 ms | 1,109.549 ms |
| Daemon Lisp allocation | 42,670,736 bytes | 332,662,096 bytes |
| Daemon GC CPU | 0.000 ms | 16.883 ms |
| Client process CPU | 262.390 ms | 289.986 ms |
| Client Lisp allocation | 24,530,112 bytes | 25,438,144 bytes |
| X11 submission-to-ack median / p95 | 0.892 / 1.325 ms | 1.571 / 2.252 ms |
| Client send-to-present median / p95 | 0.758 / 1.112 ms | 1.435 / 2.030 ms |

Both Lisp runs used substantially more CPU and allocation than either plain
text run. This comparison establishes workload cost, not an optimization gain
or the cost of any individual mode. All four full text/save/source-fixture
checks, clean exits and source/probe hashes passed. The prepared private
marker-prefixed document is 524,744 bytes with SHA-256
`db91818695a059eebc6a2f884ebd8fcb9cf53e1bdf6f9b90b9cd0bdb7291bc01`.
Artifacts: `/tmp/lem-language-{text,lisp}-{1,2}.{json,log}` and
`/tmp/lem-language-input.{py,log}`. GC CPU is not a pause measurement, and the
presentation endpoint excludes GPU completion and physical monitor latency.


### Skip idle debugger-gutter filesystem work (2026-09-20)

The configured Lisp-mode workload revealed a redraw cost hidden by `.txt`
benchmarks: `dap-gutter-content` canonicalized the current filename twice for
every visible line even when no debugger session or source breakpoint existed.
Its post-command attachment hook also resolved the path with an empty
breakpoint table. The new early exits preserve an active stopped-line marker;
when a marker can exist, the gutter reuses one canonical path for both stopped
location and breakpoint lookup. No path cache or invalidation policy is added.

A warmed SB-SPROF CPU capture of 2,400 inputs collected 3,925 samples and placed
1,343 (34.2%, including callees) in `dap-gutter-content`. `truename` accounted
for 814 samples (20.7%). The profile is diagnostic evidence only: after all
inputs and text/save checks, its client failed to exit within 20 seconds, so
no benchmark JSON was published. Its shutdown timeout remains unexplained;
this change does not claim to fix it. Artifacts:
`/tmp/lem-language-server-profile.py`,
`/tmp/lem-language-server-cpu-instrumented.py`,
`/tmp/lem-language-server-cpu.log`, and
`/tmp/lem-sdl-input-vuo_kypn/server-profile.txt`.

Ten focused checks cover idle and running sessions without markers, no-op
attachment, stopped locations without breakpoints, pending/verified markers,
stopped-line priority, other lines, and removal of the last breakpoint.
Seven path-lookup-count assertions fail before the change; all ten pass after.
Logs: `/tmp/lem-dap-gutter-before-r2.log` and
`/tmp/lem-dap-gutter-after-r2.log`. The latter loaded only the changed functions
into a disposable configured daemon; reloading the entire source is rejected
by the mode registry because its definitions belong to the packaged path.

Packaged validation passes all 140 DAP checks, including the new gutter checks
and real debugpy, Delve, GDB and LLDB sessions, plus all 19 native display and
lifecycle checks. Built configured daemon:
`/nix/store/pf06f7g9fq8yalp601savg48hgdb9nb3-lem-yath/bin/lem`;
client: `/nix/store/bnhz1k3cn08niz31bz8g18dnv0c0bkwc-sbcl-lemclient-unstable/bin/lemclient`.
Both the production DAP source and regression fixture match
`/nix/store/4svy7i2xkmhj1zig1lp3fs0vgjkjssrs-lem-yath` byte-for-byte.
Build/check logs: `/tmp/lem-dap-gutter-build.{paths,log}`. The installed editor
profile and running user sessions were not changed.

The complete-input ABBA compared the preceding `9e5a54632` daemon with this
candidate, using the same `5488e7334` client/probes, prepared 524 KB Lisp fixture,
software/X11, 600 measured inputs, 20 warmups and 25 ms pacing. All active modes
and highlighting settings matched. Means of two runs per version:

| Metric | Before | Idle-gutter fix |
| --- | ---: | ---: |
| Daemon process CPU | 1,080.100 ms | 730.298 ms (−32.4%) |
| Daemon Lisp allocation | 332,979,608 bytes | 162,383,696 bytes (−51.2%) |
| Daemon GC CPU | 19.553 ms | 15.172 ms |
| Client process CPU | 268.961 ms | 262.288 ms |
| Client Lisp allocation | 25,599,040 bytes | 25,369,216 bytes |
| X11 submission-to-ack median / p95 | 1.538 / 2.082 ms | 1.280 / 1.691 ms |
| Client send-to-present median / p95 | 1.404 / 1.868 ms | 1.143 / 1.492 ms |

Both candidate runs used less daemon CPU and allocation and had lower medians
than either baseline run. The client CPU ranges and p95 ranges overlap; mean
per-run maxima stayed roughly flat, so there is no general worst-case latency
claim. All four full text/save/fixture checks, clean exits and source/probe
hash checks passed. These software presentation endpoints do not measure GPU
completion or physical monitor latency. Artifacts:
`/tmp/lem-dap-gutter-{before,after}-{1,2}.{json,log}`,
`/tmp/lem-dap-gutter-input.{py,log}`, and
`/tmp/lem-dap-gutter-results.{py,log}`.


### Avoid unnecessary indentation-guide string parsing (2026-09-20)

`string-limited-indentation` parsed the string state of every displayed
programming line, including lines whose indentation could not be reduced.
Its opening-context limit is at least `spacing + 1`, because the opening guide
depth is nonnegative. The function now returns immediately for indentation at
or below that bound. Deeper indentation still uses the original parser and
opening-context calculation; blank-line synthesis and guide painting are
unchanged. No parser cache is added or retained across edits.

The preceding daemon CPU profile placed 565 of 3,925 samples (14.4%, including
callees) in this function. That older profile predates the debugger-gutter fix
and had the documented shutdown timeout, so it is used only to select work,
not as a performance comparison for this change.

A focused configured-runtime fixture exercises code, blank context and a
multiline string at six guide spacings, including the exact early-return
boundary. It made 138 string-state queries before and zero after, with every
result unchanged. Explicit deeper-string cases still clamp to columns 5, 9
and 17 as appropriate; ordinary code remains unclamped. Source text and
modified ticks stay intact. Logs:
`/tmp/lem-indent-limit-{before,after}.log`; driver:
`/tmp/lem-indent-limit-check.py`.

Packaged checks pass: 13 indentation-guide checks (including actual ncurses
rendering, blank-line cursor placement, tabs, toggle/reload and nonmutation),
nine Org rendering checks for the composed transformer, and all 19 native
client display/lifecycle checks. Production source, fixture and shell check
match `/nix/store/dn5grhz6m47f5x92sdihaqz3mxc84nhk-lem-yath` byte-for-byte.
Built daemon: `/nix/store/iki8wg9zj1c5wd25xzmzwh9mxsnv6s2j-lem-yath/bin/lem`.
Build/check artifacts: `/tmp/lem-indent-limit-build.{paths,log}`.
No installed profile or user editor session was changed.

The complete-input ABBA compared `71cba88ec` with the candidate, using identical
client/probe hashes, active modes, prepared 524 KB Lisp fixture, software/X11,
600 measured inputs, 20 warmups and 25 ms pacing. Means of two runs per version:

| Metric | Before | Shallow-indentation fix |
| --- | ---: | ---: |
| Daemon process CPU | 835.567 ms | 624.500 ms |
| Daemon Lisp allocation | 162,440,792 bytes | 117,260,240 bytes (−27.8%) |
| Client process CPU | 329.744 ms | 296.117 ms |
| Client Lisp allocation | 25,507,584 bytes | 25,702,080 bytes |
| X11 submission-to-ack median / p95 | 1.624 / 2.095 ms | 1.244 / 1.799 ms |
| Client send-to-present median / p95 | 1.435 / 1.840 ms | 1.081 / 1.568 ms |

Allocation stayed consistent within each version, but CPU and latency varied
substantially: baseline daemon CPU was 692.878 and 978.255 ms, versus 532.006 and
716.993 ms for the candidate. Baseline client CPU more than doubled between
repetitions despite unchanged client code. Timing ranges overlap, and the
candidate's worst single send-to-present event was 10.171 ms versus 8.793 ms
before. These runs support the allocation improvement more clearly than a
precise typing-latency gain; no general latency percentage is claimed.
All four full text/save/source-fixture checks, clean exits and source/probe
hash checks passed. Software presentation endpoints exclude GPU completion
and physical monitor latency. Artifacts:
`/tmp/lem-indent-limit-{before,after}-{1,2}.{json,log}`,
`/tmp/lem-indent-limit-input.{py,log}`, and
`/tmp/lem-indent-limit-results.{py,log}`.

A separate same-process component ABBA compiled both function bodies under the
same policy and calculated guide limits for the first 39 physical fixture lines
2,000 times per phase. It cleared syntax and blank-context caches per iteration
to represent invalidation by an edit at the beginning, warmed both variants,
and performed full GC before each measured phase. Mean process CPU fell from
326.694 to 22.047 ms (−93.3%); Lisp allocation fell from 64,479,040 to 10,979,072
bytes (−83.0%). Every per-line result and the complete source text matched.
This measures the component with surrounding indentation/context lookup, not
complete input or rendering. Artifacts:
`/tmp/lem-indent-limit-component.{lisp,py}` and
`/tmp/lem-indent-limit-component-r2.log`.


### Investigate the isolated profiling shutdown timeout (2026-09-20)

The earlier 2,400-input CPU profile reached all input and save checks but its
SDL client did not exit within 20 seconds. Three new diagnostic runs retained
the same 524 KB Lisp fixture, 2,400 measured inputs, 20 warmups, 5 ms pacing and
software/X11 event path:

- Original `9e5a54632` daemon, without profiling: clean client/daemon exits.
- Original daemon, with the same SB-SPROF CPU settings and report generation:
  clean client/daemon exits.
- Current `656f9c9e7` daemon, with CPU profiling: clean exits, followed by 20
  additional fresh SDL client attachments and clean closures against that
  daemon. Each client reached its initial matching fixture presentation first.

Every run passed text/save/source-fixture checks and source/probe hash checks.
The current run used `/nix/store/iki8wg9zj1c5wd25xzmzwh9mxsnv6s2j-lem-yath/bin/lem`.
A disposable SDL source copy installs a SIGUSR1 handler for thread traces; the
Python driver would collect client/daemon process wait states and thread
stacks on a close timeout before retaining the original failure. No timeout
occurred, so that diagnostic collection path was not exercised. These runs do
not identify the earlier failure's cause or prove it fixed. No production
shutdown behavior was changed, and profiled timing is not used as a speedup
measurement.

Artifacts: `/tmp/lem-shutdown-diagnostic.py`,
`/tmp/lem-shutdown-debug-sdl.lisp`,
`/tmp/lem-shutdown-{plain-old,cpu-old,cpu-current}.json`, corresponding
`-instrumented.py` snapshots, and logs
`/tmp/lem-shutdown-plain-old-r2.log`, `/tmp/lem-shutdown-cpu-old.log`,
`/tmp/lem-shutdown-cpu-current.log`. Private roots are respectively
`/tmp/lem-sdl-input-oblnyh7c`, `/tmp/lem-sdl-input-8we1hpvf`, and
`/tmp/lem-sdl-input-z0errabp`.

The successful current CPU capture contains 2,190 samples. The largest named
self hotspot is `overlay-cells` (133 samples, 6.1% self, 7.2% including callees).
`programming-buffer-p` accounts for 275 samples (12.6% including callees), split
mainly between line-number and indentation-guide rendering. Its class lookup
helper, `mode-object-typep`, accounts for 202 samples (9.2% including callees).
That predicate still resolves each excluded package/symbol/class on every row;
it also repeats class resolution when passing the symbol to `typep` after
already calling `find-class`. This is the next measured optimization candidate.
The capture is `/tmp/lem-sdl-input-z0errabp/server-profile.txt`.


### Reject mode lookup and display-string copy candidates (2026-09-20)

The latest daemon profile suggested two experiments. Neither was adopted;
production remains at the `656f9c9e7` indentation-guide implementation.

First, `mode-object-typep` was compiled with its already-resolved class passed
to `typep`, instead of passing the symbol and resolving the class again. A
same-process ABBA of 100,000 sweeps over Lisp and all seven excluded mode classes
saved only 2.0% of predicate CPU (294.648 versus 288.824 ms). Results agreed for
all modes. This component result does not establish a useful full-editor gain.
The production helper still performs fresh package/symbol/class lookup.
Artifacts: `/tmp/lem-mode-class-component.{lisp,py,log}` and private root
`/tmp/lem-mode-class-le5s2u77`.

Second, `transform-indent-guide-line` copied every programming-language display
string even when it painted no guide. The candidate added this guard immediately
after blank-line extension and before `copy-seq`:

```lisp
(when (<= (min indentation
               (length (lem-core::logical-line-string logical-line)))
          spacing)
  (return-from transform-indent-guide-line
    (lem-core::logical-line-attributes logical-line)))
```

The candidate preserved string ownership when painting and blank-line EOL cursor
anchoring. Its fixture covered zero/one-level indentation, empty/shortened display
strings, a cursor at a painted guide, and a blank context shallower than guide
spacing. All four unpainted strings were reused instead of copied. Text,
attributes, cursors and buffer modification ticks matched. All packaged checks
passed: 14 indentation-guide, 9 Org-modern and 19 native client/display/lifecycle
checks. Production and fixture bytes matched the built configuration source.

A same-process component ABBA compiled both function bodies under the same policy,
retaining declarations and named blocks. It transformed the first 39 physical
lines of the formatted Lisp fixture 2,000 times per phase, resetting input strings,
attributes and syntax/context caches each iteration. After warming both variants
and full GC before each phase, mean allocation fell from 23,747,520 to 11,204,160
bytes (52.8%). CPU was 88.133 versus 86.193 ms (2.2% lower). Every final string,
attribute and the complete source text matched.

Full typing results did not support keeping it. Each ABBA used the formatted
524 KB Lisp fixture, 600 measured inputs, 20 warmups, 25 ms pacing, X11/software
rendering and all configured language modes/highlighting. The first set used
ordinary scheduling. Because both candidate runs were slower, a second set
restricted the private benchmark and its descendants to CPUs 0–3 (four physical
cores sharing an L3 cache); no system scheduling settings were changed.
Numbers below are means of two runs, including means of per-run percentiles:

| Measurement | Ordinary baseline | Ordinary candidate | CPUs 0–3 baseline | CPUs 0–3 candidate |
| --- | ---: | ---: | ---: | ---: |
| Daemon CPU (ms) | 662.111 | 775.746 | 601.102 | 604.744 |
| Daemon allocated bytes | 117,592,864 | 112,570,200 | 117,457,176 | 112,486,680 |
| Client CPU (ms) | 324.386 | 413.858 | 268.442 | 276.539 |
| Client send-to-present median (ms) | 1.086 | 1.482 | 0.980 | 0.999 |
| Client send-to-present p95 (ms) | 1.754 | 2.006 | 1.278 | 1.416 |
| Submission-to-ack median (ms) | 1.226 | 1.730 | 1.113 | 1.136 |
| Submission-to-ack p95 (ms) | 2.032 | 2.327 | 1.436 | 1.596 |

The full allocation reduction reproduced (4.27% ordinary, 4.23% with affinity).
With affinity, mean daemon CPU was almost flat (+0.61%) and median latency ranges
overlapped, but both candidate p95 values (1.432/1.400 ms) exceeded both baseline
values (1.344/1.212 ms). Mean p95 rose 10.8%. This does not identify the cause of
the timing difference, and the unchanged client also varied, but it provides no
responsiveness win to justify retaining the candidate. The production change and
its candidate-only fixtures were removed. RenderPresent return is not physical
monitor latency; GC CPU is not a measured pause.

All eight full-input runs passed complete text/save/source-fixture integrity,
mode/renderer/probe/source hash checks and clean client/daemon exits. Baseline:
`/nix/store/iki8wg9zj1c5wd25xzmzwh9mxsnv6s2j-lem-yath/bin/lem`.
Rejected candidate: `/nix/store/scvncabmpwh95ph43azfmdnx094w7n1z-lem-yath/bin/lem`,
resolved editor `/nix/store/0x8f64nk03cy1sjgbyg1a0qfnir8c0q3-lem/bin/lem`,
configuration `/nix/store/gma7i9jwmcsr68mwcxhh06qfh0dzxywd-lem-yath`.

Artifacts: `/tmp/lem-indent-copy-rejected.patch`,
`/tmp/lem-indent-copy-check.py`, `/tmp/lem-indent-copy-{before,after}.log`,
`/tmp/lem-indent-copy-component.{lisp,py}`, successful component log
`/tmp/lem-indent-copy-component-r2.log`, `/tmp/lem-indent-copy-build.{paths,log}`,
`/tmp/lem-indent-copy-{before,after}-{1,2}.{json,log}`, and
`/tmp/lem-indent-copy-affinity-{before,after}-{1,2}.{json,log}`.
Drivers/verifiers and aggregate reports:
`/tmp/lem-indent-copy-{input,results}.{py,log}` and
`/tmp/lem-indent-copy-affinity-{input,results}.{py,log}`.
Ordinary run roots, in ABBA order: `wrcsbulq`, `mxe2zx_7`, `ij59r0pv`, `_lmp0gk9`;
affinity run roots: `xttav4ab`, `73p4mvam`, `ee_iv_3h`, `7vbd2mzs` (each prefixed
`/tmp/lem-sdl-input-`). Focused roots:
`/tmp/lem-indent-copy-o97fdt4d`, `/tmp/lem-indent-copy-t53ovde3`; successful component
root: `/tmp/lem-indent-copy-component-me4k6ui7`.


### Batch trailing blank cells during daemon composition (2026-09-20)

`overlay-cells` previously placed every blank padding cell separately. It now
finds a trailing run of shared one-character space strings and copies its cell
and face vectors together, after checking that the live space width is one.
Occupied cells retain the character-placement path. Only the clipped run's
edges need wide-glyph repair; interior cells are overwritten completely. Source
and destination sharing either cell or face storage keep forward placement.
There is no retained width cache. The suffix index only decreases from a vector
length to zero and is declared a fixnum.

Regression checkpoint `3c1fb825a` adds 2,016 differential cases covering repeated
cells, negative/right-edge clipping, independently varying faces and changing
space/x icon widths after source-row construction. It also adds 20 shared-storage
cases and four unequal cell/face-vector length cases, using the existing frozen
character-placement oracle. Both the old implementation and final candidate pass
all five daemon test modules. SDL client and pixel modules plus all 19 packaged
native display/lifecycle checks pass for the final candidate. Tested base source,
regression file and benchmark script matched the checkout byte for byte.

The component ABBA used 3,000 100-by-40 frame compositions after 100 warmups per
case, with full GC before timing, on CPUs 0–3. Both function versions were loaded
under the same compiler policy. The checked-in benchmark now includes fully
occupied alternating ASCII rows with no repeated cells, which exposed a cost in
the initial generic run-detection design. Final mean CPU milliseconds:

| Fixture | No rerender, before → after | One row, before → after | All rows, before → after |
| --- | ---: | ---: | ---: |
| ascii | 138.955 → 90.535 | 143.149 → 93.448 | 278.909 → 231.635 |
| unicode | 167.606 → 94.590 | 165.356 → 97.784 | 281.352 → 212.875 |
| wide | 220.221 → 225.117 | 232.048 → 232.154 | 545.955 → 537.480 |
| dense-ascii | 138.779 → 139.055 | 144.195 → 144.721 | 377.918 → 379.646 |

Padded ASCII/Unicode composition improved about 35–44% with no/one-row rerender
and 17–24% with full rerender. Wide rows ranged from 1.6% lower to 2.2% higher CPU;
dense ASCII was within 0.5%. Allocation was broadly unchanged. These counters
include fresh frame-grid allocation but exclude core redisplay, encoding,
transport and client presentation. Every checksum was 120,000. No builds,
tests or other benchmarks ran concurrently.

The first candidate detected runs at every occupied cell; its dense-ASCII
composition regressed about 8%, so it was replaced by suffix-only detection. An
untyped suffix prototype also regressed wide-row CPU. The final variant uses
an explicitly bounded fixnum suffix index and an explicit zero loop start;
only its final measurements above support the retained implementation.


The full X11/software ABBA used the formatted 524 KB Lisp fixture, 600 measured
inputs plus 20 warmups per run, 25 ms pacing, and CPUs 0–3 for the private benchmark
and descendants. Inputs alternate x/backspace on the first line; language mode,
highlighting and configured editing hooks remain enabled. It does not exercise
deep-file editing or an interactive language-server workload. Means of the two
runs (including means of per-run percentiles):

| Measurement | Before | After | Change |
| --- | ---: | ---: | ---: |
| Daemon CPU (ms) | 538.012 | 504.337 | -6.26% |
| Daemon allocated bytes | 117,252,944 | 117,210,512 | -0.04% |
| Client CPU (ms) | 229.071 | 225.097 | -1.73% |
| Client allocated bytes | 25,372,672 | 25,182,144 | -0.75% |
| Client send-to-present median (ms) | 0.835 | 0.809 | -3.06% |
| Client send-to-present p95 (ms) | 1.122 | 1.002 | -10.68% |
| Submission-to-ack median (ms) | 0.949 | 0.926 | -2.41% |
| Submission-to-ack p95 (ms) | 1.261 | 1.131 | -10.30% |

Both candidate daemon CPU values (508.922/499.751 ms) were below both baseline
values (540.673/535.350 ms). Both candidate median and p95 values also improved
over both baselines. This is a measured improvement for this synthetic input
path, not a physical-monitor latency claim. Allocation was essentially flat;
GC CPU is not a measured pause. All four runs passed complete text/save/source
fixture integrity, mode/renderer/probe/source hash checks and clean client/daemon
exits. No installed editor or user session was changed.

Baseline configured editor:
`/nix/store/iki8wg9zj1c5wd25xzmzwh9mxsnv6s2j-lem-yath/bin/lem`.
Its implementation source was compared with the committed pre-change file.
Final configured editor:
`/nix/store/jyplyd0wz66al9my1kdllsnkhwiscg88-lem-yath/bin/lem`, resolved to
`/nix/store/6qgzls8xalsgzjdjh0ss9pnj36b02p1b-lem/bin/lem`.
Tested base: `/nix/store/6hp8jrmpmjgfhsig66rzlbyk0jljw9h0-sbcl-lem-ncurses-unstable`.
Source: `/nix/store/hg15gkmc75v17v5f1pi4chqkd6cz821n-iq4nlqm9dl47dy0n6cgz3szjfccj2mp7-source-patched`.

Artifacts:
- Final component definitions: `/tmp/lem-cell-runs-before.lisp` and
  `/tmp/lem-cell-padding-after.lisp`; component driver/fixture:
  `/tmp/lem-cell-padding-typed-component.py`, `/tmp/lem-cell-padding-component.lisp`.
  Final logs: `/tmp/lem-cell-padding-typed-component-{before,after}-{1,2}.log`,
  aggregate `/tmp/lem-cell-padding-typed-component.log` and
  `/tmp/lem-cell-padding-typed-component-results.log`.
- Earlier generic-run and untyped-suffix prototypes:
  `/tmp/lem-cell-runs-after.lisp`, `/tmp/lem-cell-padding-untyped.lisp`,
  `/tmp/lem-cell-runs-component.log`, `/tmp/lem-cell-runs-dense.log`,
  `/tmp/lem-cell-padding-component.log`. These are not the retained results.
- Validation: `/tmp/lem-cell-runs-baseline-tests-r2.log`,
  `/tmp/lem-cell-padding-{daemon,client,pixels}-tests.log`,
  `/tmp/lem-cell-padding-build.{paths,log}` and
  `/tmp/lem-cell-padding-package-proof.json`.
- Full input: `/tmp/lem-cell-padding-{before,after}-{1,2}.{json,log}`,
  runner/verifier `/tmp/lem-cell-padding-{input,results}.{py,log}`.
  Roots in ABBA order: `/tmp/lem-sdl-input-ej121hd6`,
  `/tmp/lem-sdl-input-c1n3uxcv`, `/tmp/lem-sdl-input-c6pum53m`,
  `/tmp/lem-sdl-input-j08la476`.


### Measure SDL typing at an explicit file line (2026-09-20)

`sdl-input.py --target-line N` inserts its marker immediately before the
one-based fixture line N and opens the GUI at that marker through the existing
`+LINE` visit protocol. The default remains line 1. It verifies the actual
starting line/column and marker, plus the final line/column after all paired
inputs. Existing per-input presentation acknowledgements, whole-buffer text,
exact save bytes, unchanged source-fixture bytes and clean-exit checks remain.

Results record `target_line`, `target_byte_offset`, `fixture_source_bytes`,
`fixture_source_sha256`, and actual `editing.line_number` / `column_number`.
This separates source provenance from the marker-containing document hash when
comparing different positions. Input files containing the reserved
`BENCH_TARGET` marker are rejected to prevent ambiguous presentation matches.
Line insertion counts only LF, preserving UTF-8 and other control characters.
The original source file is never rewritten. For programming modes the selected
marker location must also survive the normal save/format hooks unchanged.

Python compilation and 12 preparation checks passed: invalid/nonpositive and
out-of-file lines, duplicate markers, empty input, no final newline, an empty
final line, UTF-8 byte offsets, and vertical-tab/form-feed characters that must
not be treated as line separators. Preparation artifacts are under
`/tmp/lem-target-validation-p99lbk8f`.

Two real software/X11 GUI smoke runs used the current `41c2dff49` configured
editor, `/nix/store/jyplyd0wz66al9my1kdllsnkhwiscg88-lem-yath/bin/lem`, with
20 measured inputs plus two warmups at 25 ms pacing on CPUs 0–3:

- Line 1, byte offset 0, private root `/tmp/lem-sdl-input-qdj9gym3`.
- Line 6,514, byte offset 263,301, root `/tmp/lem-sdl-input-vheopesx`.

Both confirmed LISP-MODE with highlighting and the configured editing modes,
passed text/save/source integrity, probe hashes and clean exits. Removing exactly
the marker at the recorded offset reconstructs the original 524,731-byte source
in both runs. These short runs validate the probe, not a performance conclusion.
Artifacts: `/tmp/lem-target-smoke.{py,log}` and
`/tmp/lem-target-{first,deep}-smoke.{json,log}`. The formatted source is still
`/tmp/lem-lisp-500k-formatted.lisp`, SHA-256
`879c5b01637e0f9d80e7377476cc22439fc42a5da7a2e5a15473dc62da0cc3f9`.


### Profile the deeper Lisp editing workload (2026-09-20)

The current `41c2dff49` editor was measured at lines 1 and 6,514 using the same
formatted 524,731-byte Lisp fixture. A first/deep/deep/first sequence used 600
measured x/backspace inputs, 20 warmups, 25 ms pacing and CPUs 0–3 with X11/software
rendering. All four runs verified the requested and actual line, column zero,
source reconstruction by removing the marker at its recorded byte offset,
complete text/save/source hashes, identical modes/renderer/probes and clean exits.

This compares two workloads in the same build, not an optimization. The visible
source differs, so higher costs cannot be attributed to file position alone.
Means of two runs, including means of each run's percentiles:

| Measurement | Line 1 | Line 6,514 |
| --- | ---: | ---: |
| Daemon CPU (ms) | 502.806 | 730.265 |
| Daemon allocated bytes | 117,235,536 | 241,818,768 |
| Client CPU (ms) | 228.070 | 257.394 |
| Client allocated bytes | 25,461,824 | 37,192,896 |
| Client send-to-present median (ms) | 0.807 | 1.041 |
| Client send-to-present p95 (ms) | 1.030 | 1.483 |
| Submission-to-ack median (ms) | 0.922 | 1.196 |
| Submission-to-ack p95 (ms) | 1.165 | 1.698 |

The deeper viewport used 45.2% more daemon CPU and 106.3% more Lisp allocation;
its median client send-to-present time was 29.0% higher. This justified a fresh
CPU profile at the deeper location, not a claim of an O(file-position) cost.
The diagnostic used 2,400 measured inputs plus 20 warmups at 5 ms pacing and
SB-SPROF at 1 ms across all daemon threads, retaining every integrity/exit gate.
It completed normally and produced 2,439 samples. Inclusive shares include:

- `string-limited-indentation`: 334 samples, 13.7%; its syntax-context work is
  part of the 350 samples (14.4%) under `syntax-ppss`, not an additional cost.
- `programming-buffer-p`: 293 samples, 12.0%; its mode lookup helper accounts for
  222 samples, 9.1%.
- `point-line-indentation`: 89 samples, 3.6%.
- `implementation-screen`: 144 samples, 5.9%, including 104 (4.3%) under
  `overlay-cells` after the previous composition optimization.

The indentation helper currently copies a point and walks it one character at
a time through spaces and tabs. Buffer-variable lookup resolves by buffer, not
point column, so a direct line-string scan is a candidate for removing that
point movement while preserving the tab-stop arithmetic. It has not yet been
implemented or measured. Syntax-context parsing and mode classification remain
larger targets; no feature has been disabled to improve these results.

Artifacts: `/tmp/lem-depth-input.{py,log}`, `/tmp/lem-depth-results.log`,
`/tmp/lem-depth-{first,deep}-{1,2}.{json,log}`. Roots in sequence:
`/tmp/lem-sdl-input-qygawfrd`, `/tmp/lem-sdl-input-c_ayjshr`,
`/tmp/lem-sdl-input-fu8pnybr`, `/tmp/lem-sdl-input-ac41dipl`.
Profile driver `/tmp/lem-depth-profile.py`, exact executed snapshot
`/tmp/lem-depth-profile-deep-instrumented.py`, and
`/tmp/lem-depth-profile-deep.{json,log}`; profile itself:
`/tmp/lem-sdl-input-0_7iwu6j/server-profile.txt`.
The private diagnostic SDL source only adds an on-demand shutdown stack handler;
its production prefix was byte-checked. No shutdown timeout occurred, so that
handler was not exercised. Profiled timings are not used as speedup evidence.


### Scan indentation text without moving temporary points (2026-09-20)

`point-line-indentation` now reads the existing line string directly. It retains
the same space/tab column arithmetic and blank-line result while removing the
point copy and per-character point traversal. No cached indentation, buffer
mutation or display feature changes are involved.

Regression checkpoint `3629490c9` keeps the original point walker as an oracle.
All 3,590 cases pass against both implementations: widths 1/2/4/8/16, mixed tabs
and spaces, long indentation, empty/blank/nonblank lines, Unicode and non-space
control characters, terminated and final lines, and every point column through
EOL. Each call preserves the supplied point, and scans preserve buffer text and
modified tick. The configured Nix build passed all 14 indentation-guide, nine
Org display and 19 native client display/lifecycle checks.

A same-process component ABBA comparison compiled both definitions with the same
policy. Each phase scanned 39 real fixture lines from line 6,514, 100,000 times
(3.9 million calls), after warmup and a full collection. On CPUs 0–3, mean CPU
was 1,994.458 → 264.084 ms (−86.8%). Allocation was 375,704,064 → 20,288 bytes;
the small remaining value includes harness/process overhead. All indentation and
blank results, buffer text and modified tick matched. This is a helper result,
not an 86.8% editor speedup.

Component artifacts: `/tmp/lem-indent-scan-{before,after}.lisp`,
`/tmp/lem-indent-scan-component.{lisp,py,log}`, private root
`/tmp/lem-indent-scan-v7xw6rgq`. Differential checks:
`/tmp/lem-indent-scan-before-check-r2.log` and
`/tmp/lem-indent-scan-after-check.log`; build log and output paths:
`/tmp/lem-indent-scan-build.{log,paths}`.

The complete X11/software input comparison used the formatted 524,731-byte Lisp
fixture at line 6,514: before/after/after/before, 600 measured inputs plus 20
warmups, 25 ms pacing, CPUs 0–3. Every run passed whole-buffer/save/original-source
integrity, exact marker-position reconstruction, mode/renderer/probe provenance,
and clean daemon/client exits. Means of two runs (and of their percentiles):

| Measurement | Before | After | Change |
| --- | ---: | ---: | ---: |
| Daemon CPU (ms) | 815.291 | 800.101 | −1.9% |
| Daemon allocated bytes | 242,206,176 | 236,826,528 | −2.2% |
| Client CPU (ms) | 283.770 | 286.071 | +0.8% |
| Client allocated bytes | 37,330,432 | 36,711,168 | −1.7% |
| Client send-to-present median (ms) | 1.144 | 1.137 | −0.6% |
| Client send-to-present p95 (ms) | 1.888 | 1.876 | −0.7% |
| Submission-to-ack median (ms) | 1.316 | 1.313 | −0.3% |
| Submission-to-ack p95 (ms) | 2.267 | 2.259 | −0.3% |

Allocation fell in both candidate runs. CPU and latency ranges overlap: daemon
CPU before 842.383/788.198 ms, after 815.777/784.424 ms; client send-to-present
medians before 1.164/1.124 ms, after 1.146/1.129 ms. These measurements support
removing helper work/allocation, but not a reliable end-to-end latency speedup.
The simpler scan is retained; no functionality is disabled.

Baseline configured editor was
`/nix/store/jyplyd0wz66al9my1kdllsnkhwiscg88-lem-yath/bin/lem`; candidate
`/nix/store/lb4z1zgrhjmcffp81af8d28sqgma66rr-lem-yath/bin/lem`.
`/tmp/lem-indent-scan-package-proof.json` verifies the packaged configuration,
fixtures, daemon implementation, SDL source and input probe against the checkout.
Candidate configuration source is
`/nix/store/53y6bcs5ql71m10zphzy9y64zm5ipchm-lem-yath`.
Artifacts: `/tmp/lem-indent-scan-{input,results}.{py,log}` and
`/tmp/lem-indent-scan-{before,after}-{1,2}.{json,log}`. Private roots in order:
`/tmp/lem-sdl-input-_wj39dpg`, `/tmp/lem-sdl-input-5_wghvj9`,
`/tmp/lem-sdl-input-h5pcmtno`, `/tmp/lem-sdl-input-5s4e8igl`.


### Follow-up probes and blank-context invalidation (2026-09-20)

Two private same-process ABBA probes did not justify production changes:

- Coercing the programming-mode exclusion descriptors from character strings to
  base strings preserved all eight mode classifications, but mean predicate CPU
  rose from 273.862 to 278.566 ms. The existing dynamic package/symbol/class
  lookups remain unchanged. Artifacts:
  `/tmp/lem-mode-names-component.{lisp,py,log}`, root
  `/tmp/lem-mode-names-um449lrp`.
- Skipping the syntax-cache setter when its head list stayed identical preserved
  all 39 parsed states in a deep-viewport component with invalidation between
  iterations. Mean CPU was 1,114.484 → 1,102.144 ms, an inconclusive 1.1% change
  with overlapping run ranges. The probe deliberately kept hook registration.
  It was not adopted or promoted to an editor latency claim. Artifacts:
  `/tmp/lem-ppss-write-{before,after}.lisp`,
  `/tmp/lem-ppss-write-component.{lisp,py,log}`, root
  `/tmp/lem-ppss-write-z8jo35ys`.

Blank-line indentation context had a separate correctness defect: its cache key
only tracked text changes, so a live tab-width change could leave guides at the
old depth. The production cache now includes the effective buffer tab width.
It still stores one value per text position; the range-cache prototypes below
are not part of this fix. The cache shape check also discards the previous
representation after reloading code into a running editor.

The new regression fixture compares 1,715 blank-context queries with uncached
neighbor scans. It covers empty/all-blank buffers, spaces/tabs, beginning/end
runs, separate runs, a 128-line run, all point columns, five tab widths, and
insertions at the beginning/middle/end followed by undo. Queries preserve text,
modified tick and point position. A separate same-tick sequence changes width
1 → 2 → 4 → 8 → 16 → 2 next to a tab-indented line: the previous editor reports
`BLANK-TAB-WIDTH correct=no`, while the fixed implementation reports `yes`.
Artifacts: `/tmp/lem-blank-runs-before-check.log`,
`/tmp/lem-blank-width-check.{py,log}`, and
`/tmp/lem-blank-width-fix.lisp`.

The performance lead is the old cache's per-line position collection and hash
entry creation across entire blank runs, even when only a small viewport is
visible. A private interval prototype reduced this work but needs further
validation: a linear range list has unbounded lookup cost across many runs;
64-line hash buckets regressed a scattered-run component by about 25%.
Eight-line buckets bound each lookup to at most four distinct blank runs. Their
10,000-blank-line component used 256.550 → 169.185 ms CPU and
277,958,464 → 38,259,584 allocated bytes, but scattered-run CPU was still higher
than the original cache (which lacked the necessary tab-width validation).
The next comparison must keep that correctness fix on both sides and verify
complete GUI input on both long blank runs and an ordinary Lisp viewport.
No range-cache optimization or editor speedup is claimed from these probes.

Prototype artifacts: `/tmp/lem-blank-runs-before-no-width.lisp`,
`/tmp/lem-blank-runs-{linear,bucket64,bucket8}.lisp`,
`/tmp/lem-blank-runs-component.{lisp,py}`,
`/tmp/lem-blank-runs-bucket8-component.log`,
`/tmp/lem-blank-scattered-component.{lisp,py}`,
`/tmp/lem-blank-scattered-bucket8-component.log`.
The long-blank Lisp fixture is `/tmp/lem-lisp-blank-runs.lisp`; it has not yet
passed the GUI probe's normal save/format integrity check.

The tab-width fix passed the configured Nix build and all 15 indentation-guide,
nine Org display and 19 native display/lifecycle checks. Its configured editor is
`/nix/store/7h3rf58ab9b11fkd517lfr8r18vq7s0z-lem-yath/bin/lem`.
Build artifacts: `/tmp/lem-blank-width-build.{log,paths}` and
`/tmp/lem-blank-width-package-proof.json` (exact configuration/fixture/core/probe
byte checks). This is a correctness checkpoint, not a measured latency gain.

The follow-up component comparison now uses the production tab-width fix in
both implementations. Each run is same-process ABBA on CPUs 0–3, with full GC
between phases, result assertions and source-text preservation. It still does
not measure full input latency. Means of two phases:

| Component workload | CPU before → after (ms) | Allocation before → after (bytes) |
| --- | ---: | ---: |
| 10 blank lines, 10,000 iterations | 27.114 → 22.321 | 10,753,728 → 6,759,872 |
| 10,000 blank lines, 250 iterations | 257.019 → 169.907 | 277,797,952 → 38,310,272 |
| 39 separate runs, 2,000 iterations | 33.953 → 33.199 | 24,060,928 → 21,505,984 |
| 2,000 separate runs, 50 iterations | 42.397 → 40.484 | 33,516,488 → 28,830,080 |

Both candidate phases use less CPU than both baseline phases in all four
workloads. The 10,000-line case queries only 39 visible blank lines per iteration;
the scattered cases query every listed run. Context caches are reset between
iterations. The candidate stores one range per contiguous blank run and indexes
it in eight-line buckets, bounding the candidate list to at most four runs per
bucket. It still scans to find both neighboring nonblank lines after an edit.
These results justify full GUI comparison; the prototype remains uncommitted
outside `/tmp`, and production still uses the per-position hash cache.
Exact compared definitions: `/tmp/lem-blank-fixed-{before,after}.lisp`. Drivers,
fixtures and logs: `/tmp/lem-blank-fixed-component.{lisp,py,log}` and
`/tmp/lem-blank-fixed-scattered-component.{lisp,py,log}`. Private roots:
`/tmp/lem-blank-fixed-w9qzmo74`, `/tmp/lem-blank-fixed-lrkw5xie`.

The new Lisp fixture also passed a real X11/software GUI smoke run on the fixed
production editor: 20 measured inputs plus two warmups at 25 ms pacing, CPUs 0–3,
LISP-MODE with highlighting and the configured editing modes. Whole-buffer,
save, original-source, probe/source hash and clean-exit checks passed. Source is
10,077 bytes (10,000 blank lines inside a nested form), SHA-256
`60248419aaef83f8f0f7879958a4c2314f9eda9a56831b9eab8772f76e2a1f16`;
marker-containing document SHA-256
`c2f629aa618f9925e54e734b6c8993ee976edb9380e3fd084bc5c905435ebc3f`.
Root `/tmp/lem-sdl-input-jinvctnc`; artifacts:
`/tmp/lem-blank-fixture-smoke.{py,json,log}` and
`/tmp/lem-blank-fixture-smoke-driver.log`. The short smoke timings are not used
as performance evidence.


### Validate blank-run spans in complete input (2026-09-20)

The candidate represents each contiguous blank run as `(start-line end-line
indentation)`, indexed in eight-line hash buckets. At most four distinct blank
runs overlap a bucket, so lookup stays bounded as more of a buffer is viewed.
Neighbor scans now retain only their boundary line numbers, avoiding a position
list and a hash entry for every blank line. Cache validity still includes both
text tick and effective tab width, and both neighboring nonblank lines still
determine context. A format tag discards old per-position caches on live reload.

All 1,716 blank-context regression cases pass, including an old-format cache
whose numeric entry at position zero would otherwise be misread as a run bucket.
The configured package passed all 15 indentation-guide, nine Org display and
19 native display/lifecycle checks. No rendering feature, input pacing, cache
invalidation condition or integrity gate was disabled.

Baseline is the tab-width-corrected `869bdc452` configured editor
`/nix/store/7h3rf58ab9b11fkd517lfr8r18vq7s0z-lem-yath/bin/lem`. Candidate:
`/nix/store/x9qjc0kvavx5h3slfsr2n298q4a85z2m-lem-yath/bin/lem`, configuration source
`/nix/store/r2gc4xpil63n8qv11ywj41fng8lm69kq-lem-yath`.
`/tmp/lem-blank-span-package-proof.json` verifies packaged source bytes against
the checkout; baseline indentation source was also compared with the preceding
commit. Build artifacts: `/tmp/lem-blank-span-build.{log,paths}`. Exact candidate
cache definitions: `/tmp/lem-blank-final-after.lisp`. Regression artifacts:
`/tmp/lem-blank-final-check.{py,log}`, root `/tmp/lem-blank-runs-e56ygkdx`.

Two complete X11/software ABBA comparisons used 600 measured x/backspace inputs
plus 20 warmups, 25 ms pacing and CPUs 0–3. All eight runs verified the expected
configured/resolved executable, modes, renderer, probe/source hashes, requested
line/column, whole-buffer/save/source integrity and clean exits. The original
source was reconstructed by removing the marker at its recorded byte offset.
Means of two runs, including means of their percentiles:

| Measurement | Long blank run before → after | Ordinary deep Lisp before → after |
| --- | ---: | ---: |
| Daemon CPU (ms) | 1,415.445 → 1,141.040 | 758.255 → 763.952 |
| Daemon allocated bytes | 825,611,808 → 233,883,936 | 236,941,792 → 237,116,576 |
| Client CPU (ms) | 248.558 → 244.730 | 263.409 → 260.610 |
| Client allocated bytes | 25,358,912 → 25,557,440 | 37,402,112 → 37,172,416 |
| Client send-to-present median (ms) | 2.061 → 1.752 | 1.112 → 1.110 |
| Client send-to-present p95 (ms) | 3.957 → 2.872 | 1.553 → 1.542 |
| Submission-to-ack median (ms) | 2.190 → 1.883 | 1.283 → 1.281 |
| Submission-to-ack p95 (ms) | 4.271 → 3.197 | 1.835 → 1.826 |

The long-blank workload improved daemon CPU by 19.4%, daemon allocation by
71.7%, median client send-to-present time by 15.0% and p95 by 27.4%. Both candidate
runs were below both baselines for each of these measures. CPU before was
1,370.079/1,460.810 ms, after 1,179.936/1,102.144 ms; medians before
2.050/2.072 ms, after 1.787/1.716 ms; p95 before 3.914/4.000 ms, after
2.930/2.813 ms. This is a verified benefit for long blank sections, not a claim
that ordinary typing is 15% faster or that physical scanout was measured.

Ordinary deep Lisp was essentially flat: daemon CPU +0.8%, allocation +0.07%,
median −0.2%, p95 −0.7%, with overlapping CPU and latency ranges. The much lower
observed maximum is not treated as a reliable tail guarantee. The range cache
is retained for the substantial long-run benefit while preserving normal
workload behavior and the tab-width correctness fix.

Artifacts: `/tmp/lem-blank-span-{input,results}.{py,log}`,
`/tmp/lem-blank-span-{long,deep}-{before,after}-{1,2}.{json,log}`. Long-run roots
in ABBA order: `/tmp/lem-sdl-input-7j6gzdg2`, `/tmp/lem-sdl-input-pzarjmtx`,
`/tmp/lem-sdl-input-iu5tmfmd`, `/tmp/lem-sdl-input-bkuavrpe`. Deep Lisp roots:
`/tmp/lem-sdl-input-b32oc_fx`, `/tmp/lem-sdl-input-16qhbb0e`,
`/tmp/lem-sdl-input-sw7xrgrk`, `/tmp/lem-sdl-input-yhd53ebz`.
The existing validated fixtures were unchanged: long blank source 10,077 bytes
at line 1, SHA-256 `60248419aaef83f8f0f7879958a4c2314f9eda9a56831b9eab8772f76e2a1f16`;
ordinary Lisp 524,731 bytes at line 6,514, SHA-256
`879c5b01637e0f9d80e7377476cc22439fc42a5da7a2e5a15473dc62da0cc3f9`.

The remaining neighbor scan still visits every blank line after an edit.
`point-line-indentation` also reads tab width on every visited line, including
empty lines and lines containing only spaces. Deferring that read until the
first tab is a further candidate; it has not been implemented or measured here.


### Defer indentation tab-width lookup until a tab occurs (2026-09-20)

`point-line-indentation` initializes its local width only when it encounters the
first leading tab. Empty lines, space-only indentation and unindented text no
longer read a buffer variable whose value they do not use. Tabs retain the same
arithmetic and one width lookup per helper call. The blank-context cache still
checks the effective width so live width changes invalidate its stored context.

All 3,590 original point-walker differential cases pass, preserving indentation,
blank detection, point position, source text and modified tick. The configured
package passed all 15 indentation-guide, nine Org display and 19 native
display/lifecycle checks.

Two same-process component ABBA probes compiled both function bodies with the
same policy and used CPUs 0–3, 100 warmup sweeps and full GC before each phase.
Each phase made 100,000 sweeps of 39 lines (3.9 million calls):

- Real Lisp lines from line 6,514: mean CPU 262.459 → 140.307 ms (−46.5%).
- A tab-heavy fixture cycling 0/1/2/4/8/16 leading tabs: 264.751 → 254.577 ms
  (−3.8%). Both candidate phases were below both baseline phases.

Every indentation/blank result and source/tick check matched. These are helper
CPU results, not editor-wide speedups; their small allocation counters varied
with process overhead and do not support an allocation claim. Artifacts:
`/tmp/lem-indent-width-{before,after}.lisp`,
`/tmp/lem-indent-width-component.{lisp,py,log}`,
`/tmp/lem-indent-width-tabs-component.{lisp,py,log}`,
`/tmp/lem-indent-width-check.{py,log}`. Roots: ordinary component
`/tmp/lem-indent-width-2tuhup3_`, tab-heavy `/tmp/lem-indent-width-xm13rkoa`,
regression check `/tmp/lem-indent-width-9i2c0w5j`.

Baseline configured editor is the `616897867` range-cache build
`/nix/store/x9qjc0kvavx5h3slfsr2n298q4a85z2m-lem-yath/bin/lem`. Candidate:
`/nix/store/5721vzwxbdj08jyq4yvdmcm1mycm6i55-lem-yath/bin/lem`, configuration
source `/nix/store/nwjmwhiv16frdbm82rgp6vf0wmn1j4js-lem-yath`.
Package/source/fixture/probe bytes are checked in
`/tmp/lem-indent-width-package-proof.json`; build artifacts:
`/tmp/lem-indent-width-build.{log,paths}`.

An additional 36 comparisons cover widths 0, −2, 3/2, 4.0, NIL and a nonnumeric
keyword across empty, space-only, unindented, trailing-tab and leading-tab lines.
Both functions return the same values or condition types; invalid widths have
not been normalized or silently accepted. Successful artifacts:
`/tmp/lem-indent-width-values-r2.{lisp,py,log}`, root
`/tmp/lem-indent-width-40kp3dq_`. The first auxiliary harness attempt placed its
report inside the line loop and failed on the second file creation; it was
corrected before the 36-case result and supplied no performance evidence.

Complete X11/software input comparisons used the unchanged long-blank fixture
at line 1 and 524,731-byte Lisp fixture at line 6,514. Each workload ran
before/after/after/before, 600 measured inputs plus 20 warmups, 25 ms pacing,
CPUs 0–3. All eight runs verified executable, modes, renderer, source/probe
hashes, line/column, whole-buffer/save/original-source integrity and clean exits.
Means of two runs, including means of their percentiles:

| Measurement | Long blank run before → after | Ordinary deep Lisp before → after |
| --- | ---: | ---: |
| Daemon CPU (ms) | 1,089.669 → 889.069 | 765.966 → 750.223 |
| Daemon allocated bytes | 233,781,216 → 233,679,840 | 236,825,248 → 236,988,384 |
| Client CPU (ms) | 225.613 → 227.097 | 262.696 → 253.739 |
| Client allocated bytes | 25,606,912 → 25,575,040 | 36,852,288 → 36,749,440 |
| Client send-to-present median (ms) | 1.710 → 1.386 | 1.114 → 1.092 |
| Client send-to-present p95 (ms) | 2.740 → 2.017 | 1.571 → 1.489 |
| Submission-to-ack median (ms) | 1.834 → 1.516 | 1.282 → 1.260 |
| Submission-to-ack p95 (ms) | 3.042 → 2.255 | 1.877 → 1.777 |

Long-blank daemon CPU fell 18.4% and median client send-to-present time fell
18.9%, with both candidate runs below both baselines. CPU before was
1,085.676/1,093.662 ms, after 899.556/878.582 ms; medians before 1.697/1.723 ms,
after 1.383/1.389 ms. The mean p95 fell 26.4%, but candidate tails varied
(2.492/1.541 ms versus baseline 2.743/2.738 ms), so that percentage is not a
stable tail guarantee. Allocation remained essentially flat.

Ordinary Lisp means improved modestly (daemon CPU −2.1%, median −2.0%,
p95 −5.2%), but CPU and latency ranges overlap. These runs do not establish a
precise general typing speedup. The small lazy lookup is retained for its
verified long-run benefit, unchanged results and absence of a clear normal
workload regression.

Artifacts: `/tmp/lem-indent-width-{input,results}.{py,log}`,
`/tmp/lem-indent-width-{long,deep}-{before,after}-{1,2}.{json,log}`. Long-run
roots in ABBA order: `/tmp/lem-sdl-input-q8g9mf5g`, `/tmp/lem-sdl-input-xqtkaoa_`,
`/tmp/lem-sdl-input-u_321ab_`, `/tmp/lem-sdl-input-48d5azbm`. Deep Lisp roots:
`/tmp/lem-sdl-input-tquydh8k`, `/tmp/lem-sdl-input-3y3lzpjd`,
`/tmp/lem-sdl-input-cwtqt3kc`, `/tmp/lem-sdl-input-idhcpolw`.


### Refresh profiles after the indentation improvements (2026-09-20)

The current `0e56d8fc6` configured editor was profiled again on ordinary deep Lisp
and the long-blank fixture. Both X11/software diagnostics used 2,400 measured
inputs plus 20 warmups, 5 ms pacing, CPUs 0–3 and SB-SPROF CPU sampling at 1 ms
across all daemon threads. Full text/save/source integrity, cursor location,
mode/renderer/executable/probe hashes and clean exits all passed. Profiled
timings are not speedup evidence.

The ordinary deep profile produced 2,414 samples. Inclusive costs include
`syntax-ppss` 379 (15.7%), `string-limited-indentation` 355 (14.7%, overlapping
with syntax parsing), `overlay-cells` 130 (5.4%), and `%move-to-position` 67
(2.8%). `point-line-indentation` and `nearby-nonblank-indentation` each account
for only four samples (0.2%). Some compiled functions have unresolved profiler
names, so they have not been attributed by guesswork.

The long-blank profile produced 2,876 samples. `line-offset` accounts for 763
inclusive samples (26.5%), including 486 (16.9%) in `%move-to-position`. This
justifies removing temporary point movement from the neighbor scan. The buffer
already exports `point-line`, `line-next`, `line-previous` and `line-string`
for direct read-only traversal. No core point-movement change is needed.

Artifacts: `/tmp/lem-current-profile.py`,
`/tmp/lem-current-profile-{deep,long}-instrumented.py`,
`/tmp/lem-current-profile-{deep,long}.{json,log}`. Deep root/profile:
`/tmp/lem-sdl-input-2iqcjx3l/server-profile.txt`; long blank:
`/tmp/lem-sdl-input-fwbize8l/server-profile.txt`. Both retain the optional shutdown
stack diagnostic whose SDL production prefix was byte-checked; neither timed
out, so the handler was not exercised. The earlier isolated shutdown timeout
remains unreproduced rather than fixed by these successful runs.

### Prototype direct neighbor-line traversal (2026-09-20)

The candidate passes an optional raw line to `point-line-indentation`; its point
argument continues to supply buffer-local settings. The neighbor helper walks
exported next/previous line links and updates an integer boundary, preserving
its existing adjacent-line scan behavior without copying or moving points.
All 3,590 original point-walker indentation cases, 1,716 blank-context cases,
source/point/tick invariants and live tab-width changes pass in a private editor.

Same-process component ABBA probes on CPUs 0–3 retain the current tagged span
cache, reset it between iterations and compile both function pairs under the
same policy. Full GC precedes each phase. Means of two phases:

| Component workload | CPU before → after (ms) | Allocation before → after (bytes) |
| --- | ---: | ---: |
| 10 blank lines, 10,000 iterations | 19.005 → 14.450 | 6,897,664 → 4,951,040 |
| 10,000 blank lines, 250 iterations | 97.537 → 25.724 | 38,411,008 → 38,366,464 |
| 39 separate runs, 2,000 iterations | 29.043 → 18.080 | 21,573,952 → 6,565,376 |
| 2,000 separate runs, 50 iterations | 34.860 → 21.577 | 28,844,224 → 10,059,968 |

Both candidate phases use less CPU than both baselines in every workload. The
long-run case queries 39 visible lines; scattered cases query every listed run.
The allocation benefit for scattered runs follows removal of two temporary
points per context scan. Full GUI typing remains the next validation gate.
Exact compared definitions: `/tmp/lem-raw-neighbor-{before,after}.lisp`.
Artifacts: `/tmp/lem-raw-neighbor-component.{lisp,py,log}`,
`/tmp/lem-raw-neighbor-scattered-component.{lisp,py,log}`,
`/tmp/lem-raw-neighbor-check-r2.{py,log}`. Roots: component
`/tmp/lem-raw-neighbor-zywkxdgo`, scattered `/tmp/lem-raw-neighbor-da161sta`,
regression `/tmp/lem-raw-neighbor-rfzprq_3`. The first private regression harness
omitted one test function from its extracted source; no candidate result was
claimed until the corrected harness loaded and passed both test groups.

The direct-traversal candidate passed the configured Nix build and all 43
packaged checks (15 indentation-guide, nine Org display, 19 native display and
lifecycle). Baseline is the `0e56d8fc6` configured editor
`/nix/store/5721vzwxbdj08jyq4yvdmcm1mycm6i55-lem-yath/bin/lem`; candidate
`/nix/store/d3f6rgqx5z82dw3cc15frb32vi373r93-lem-yath/bin/lem`, configuration source
`/nix/store/s1hdi94nkypkf56a0cr7r42lws5sb53l-lem-yath`. Exact package/source/fixture
and probe comparisons are recorded in `/tmp/lem-raw-neighbor-package-proof.json`;
build artifacts are `/tmp/lem-raw-neighbor-build.{log,paths}`.

Full X11/software input comparisons used the same long-blank and ordinary deep
Lisp fixtures, each in before/after/after/before order: 600 measured inputs plus
20 warmups, 25 ms pacing, CPUs 0–3. All eight runs verified executable, modes,
renderer, source/probe hashes, cursor line/column, complete buffer/save/source
integrity and clean exits. Means of two runs and their percentiles:

| Measurement | Long blank run before → after | Ordinary deep Lisp before → after |
| --- | ---: | ---: |
| Daemon CPU (ms) | 900.183 → 723.803 | 771.992 → 753.825 |
| Daemon allocated bytes | 233,432,096 → 233,730,144 | 236,772,512 → 236,452,000 |
| Client CPU (ms) | 229.564 → 238.842 | 265.424 → 271.392 |
| Client allocated bytes | 25,382,656 → 25,609,216 | 36,892,928 → 37,073,024 |
| Client send-to-present median (ms) | 1.398 → 1.087 | 1.117 → 1.106 |
| Client send-to-present p95 (ms) | 2.038 → 1.733 | 1.808 → 1.788 |
| Submission-to-ack median (ms) | 1.525 → 1.214 | 1.291 → 1.281 |
| Submission-to-ack p95 (ms) | 2.272 → 1.967 | 2.167 → 2.152 |

The long-blank workload improved daemon CPU by 19.6% and median client
send-to-present time by 22.3%; both candidate runs beat both baselines on these
measures. CPU before was 910.049/890.316 ms, after 753.892/693.714 ms; medians
before 1.407/1.389 ms, after 1.094/1.079 ms. The mean p95 improved 15.0%, but
its ranges overlap (before 2.526/1.551 ms, after 2.255/1.212 ms), so no precise
tail guarantee is inferred. Full-input allocation stayed essentially flat,
unlike the larger allocation savings in the scattered-run helper component.

Ordinary Lisp showed no clear regression: daemon CPU mean −2.4%, median −0.9%,
p95 −1.1%, with overlapping run ranges. Client CPU means rose 4.0% on long
blanks and 2.2% on ordinary code, also with overlapping ranges; both workloads'
combined daemon/client CPU means fell. The lower observed maxima are not used
as a general speedup claim. The direct scan is retained with all editing and
rendering behavior intact; only the private neighbor traversal changed.

Artifacts: `/tmp/lem-raw-neighbor-{input,results}.{py,log}`,
`/tmp/lem-raw-neighbor-{long,deep}-{before,after}-{1,2}.{json,log}`. Long-run
roots in ABBA order: `/tmp/lem-sdl-input-uhri55zb`, `/tmp/lem-sdl-input-z88gcs16`,
`/tmp/lem-sdl-input-7b0qc5pk`, `/tmp/lem-sdl-input-aqk75nn3`. Ordinary roots:
`/tmp/lem-sdl-input-xl4d6mcv`, `/tmp/lem-sdl-input-9whmlgf2`,
`/tmp/lem-sdl-input-ezap5rck`, `/tmp/lem-sdl-input-qjj6gaxb`.

A separate source-inspection lead remains in line-number formatting:
`programming-line-number-content` in the configuration and the upstream
line-number method both construct a default format-control string per row,
then pass it to `format`. A constant control with a dynamic width may avoid
that construction/parsing, but has not been implemented or measured here.
The profile's 11.2% line-number around-method share includes other gutter
providers and programming-mode classification; it must not be presented as
time spent solely formatting numbers.
