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
scripts/bench/self-test.sh              # prove the gate catches a regression
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
| scroll | syntax-scanned `lisp-500k` buffer (real lisp-mode tmlanguage), sustained line-scroll (`scroll-down` ×1500) then page-scroll (`next-page` ×150) over styled text |
| long-line | 16 KB single line: `character-offset` cursor sweeps, beginning/end-of-line, net-zero edits at 8 positions, wrap-off and wrap-on render passes (×2) |

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
medians; `frames` is deterministic (identical every run).

| Workload | median ms | consed B | GC count | GC pause ms | frames |
|----------|----------:|---------:|---------:|------------:|-------:|
| `big-file` | 4745 | 678 769 920 | 4 | ~28 | 4976 |
| `scroll` | 1272 | 307 392 384 | 2 | ~5 | 1652 |
| `long-line` | 610 | 133 027 360 | 1 | ~0 | 172 |

(Absolute ms track machine load at baseline creation; the gate compares against
the committed median within the 20% band on a matching fingerprint, so a
per-machine rebaseline is the honest reset when the platform or its steady-state
load moves — Constraint 5.)

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

### Optimizations (OPT-n)

_None yet. P5 must not start before the P4 grounding report (SPEC-PERF)._

| Item | Date | Evidence (T0/T2 + profile) | Change | Before → After | Notes |
|------|------|----------------------------|--------|----------------|-------|
| —    | —    | —                          | —      | —              | —     |

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
