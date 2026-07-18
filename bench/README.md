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
| `lisp-500k` | ~500 KB syntactically-valid Common Lisp (deterministic concatenation of whole repo source files) |
| `unicode-mixed` | ~100 KB of mixed ASCII / CJK / emoji / combining-mark text |
| `long-line-200k` | one 200 000-char line (the PI-1 corpus the edit/points benches stress) |

`lisp-500k` and `unicode-mixed` are the corpora for the width/syntax entries
that land later; all three are regenerated (and thus validated) on every bench
run. The bench image loads `:lem/core` only, so `generate.lisp` reproduces
SplitMix64 locally rather than depending on `tests/pbt/harness.lisp`.

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
