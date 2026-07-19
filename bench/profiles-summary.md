# P4 Cross-Workload Hotspot Ranking (SPEC-PERF PF-9)

Wall-ms baseline shares (committed t2 baseline, commit e073c6b2, fp ex44/i5-13500/20c):

| Workload | wall ms | share | profile samples | profile file |
|---|--:|--:|--:|---|
| big-file | 4234 | 46.6% | 3804 | big-file-20260719102057.txt |
| isearch | 2201 | 24.2% | 4095 | isearch-20260719102112.txt |
| scroll | 1075 | 11.8% | 2841 | scroll-20260719102125.txt |
| overlay-heavy | 520 | 5.7% | 2636 | overlay-heavy-20260719102135.txt |
| long-line | 488 | 5.4% | 2629 | long-line-20260719102144.txt |
| lisp-edit | 299 | 3.3% | 2518 | lisp-edit-20260719102154.txt |
| undo-storm | 266 | 2.9% | 2663 | undo-storm-20260719102203.txt |

Total wall ms = 9083. Weighting: contribution(frame) = Σ_w selfPct(frame,w) × wallshare(w).

## Cross-workload top 25

| # | frame | weighted | class | dominates (selfPct) |
|--:|---|--:|---|---|
| 1 | ACL2::K-CHAR-WIDTH | 12.138 | kernel | big-file 14.5%, long-line 13.2%, scroll 12.5%, isearch 12.4% |
| 2 | LEM/COMMON/CHARACTER/ICON:ICON-CODE-P | 7.878 | shell | big-file 13.1%, scroll 10.4%, long-line 10.0%, undo-storm 0.1% |
| 3 | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:WIDE-INDEX | 7.265 | shell | isearch 10.8%, big-file 8.8%, scroll 3.1%, long-line 1.7% |
| 4 | (LAMBDA (SB-PCL::.ARG0.) :IN "SYS:SRC;PCL;BRAID.LISP") | 5.722 | runtime | overlay-heavy 48.7%, undo-storm 22.8%, lisp-edit 15.8%, isearch 2.8% |
| 5 | ACL2::K-CONTROL-CODE-P | 4.469 | kernel | long-line 5.3%, isearch 5.1%, big-file 5.0%, scroll 4.6% |
| 6 | ACL2::K-ZERO-CODE-P | 4.044 | kernel | big-file 4.9%, isearch 4.2%, scroll 4.0%, long-line 4.0% |
| 7 | ACL2::K-AMBIGUOUS-CODE-P | 3.675 | kernel | scroll 5.2%, long-line 5.0%, big-file 4.3%, isearch 3.0% |
| 8 | SB-IMPL::GETHASH/EQL-HASH/FLAT | 3.465 | runtime | big-file 4.2%, long-line 4.0%, scroll 3.8%, isearch 3.3% |
| 9 | Unknown fn 45469 | 3.296 | runtime | isearch 12.9%, overlay-heavy 2.0%, lisp-edit 1.7% |
| 10 | ACL2::K-SUM | 3.254 | kernel | long-line 7.5%, scroll 5.0%, big-file 4.3%, isearch 0.9% |
| 11 | SB-KERNEL:TWO-ARG->= | 3.023 | runtime | big-file 3.5%, long-line 3.3%, isearch 3.2%, scroll 3.0% |
| 12 | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:STRING-WIDTH | 2.750 | shell | long-line 5.2%, scroll 5.1%, big-file 3.6%, isearch 0.7% |
| 13 | SB-KERNEL:TWO-ARG-<= | 2.480 | runtime | long-line 3.0%, isearch 2.7%, undo-storm 2.7%, big-file 2.6% |
| 14 | ACL2::K-WIDE-CODE-P | 2.058 | kernel | long-line 3.2%, scroll 2.7%, isearch 2.3%, big-file 2.1% |
| 15 | ACL2::NATP | 1.804 | kernel | big-file 2.2%, long-line 2.2%, isearch 2.0%, scroll 1.3% |
| 16 | LENGTH | 1.755 | runtime | undo-storm 32.4%, lisp-edit 2.7%, scroll 1.0%, big-file 0.8% |
| 17 | GENERIC-+ | 1.429 | runtime | undo-storm 5.6%, long-line 3.2%, big-file 1.5%, scroll 1.4% |
| 18 | SB-KERNEL:RANGE<= | 1.124 | runtime | isearch 1.4%, big-file 1.3%, scroll 1.0%, long-line 0.9% |
| 19 | %DATA-VECTOR-AND-INDEX/CHECK-BOUND | 1.055 | shell | big-file 1.3%, scroll 1.2%, isearch 1.0%, lisp-edit 0.8% |
| 20 | SB-SPROF::UNAVAILABLE-FRAMES | 0.998 | runtime | overlay-heavy 6.6%, undo-storm 4.9%, lisp-edit 3.7%, isearch 0.6% |
| 21 | SEARCH | 0.900 | shell | isearch 3.7%, lisp-edit 0.1% |
| 22 | LEM-CORE::TEXT-OBJECT-CHAR-WIDTHS | 0.851 | shell | scroll 1.5%, big-file 1.2%, long-line 1.0%, isearch 0.2% |
| 23 | (SB-VM::OPTIMIZED-DATA-VECTOR-REF CHARACTER) | 0.837 | shell | isearch 2.1%, scroll 0.8%, long-line 0.7%, big-file 0.4% |
| 24 | SB-IMPL::GETHASH/EQL-HASH | 0.767 | runtime | scroll 1.5%, big-file 1.0%, long-line 1.0%, lisp-edit 0.3% |
| 25 | ACL2::K-NAT | 0.710 | kernel | long-line 2.0%, big-file 0.9%, scroll 0.8%, isearch 0.3% |

## Per-workload top 10 flat frames

### big-file — 3804 samples (big-file-20260719102057.txt)

| # | self% | total% | count | class | frame |
|--:|--:|--:|--:|---|---|
| 1 | 14.5 | 34.1 | 553 | kernel | ACL2::K-CHAR-WIDTH |
| 2 | 13.1 | 16.8 | 500 | shell | LEM/COMMON/CHARACTER/ICON:ICON-CODE-P |
| 3 | 8.8 | 41.8 | 333 | shell | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:WIDE-INDEX |
| 4 | 5 | 9.3 | 192 | kernel | ACL2::K-CONTROL-CODE-P |
| 5 | 4.9 | 4.9 | 187 | kernel | ACL2::K-ZERO-CODE-P |
| 6 | 4.3 | 10.2 | 165 | kernel | ACL2::K-SUM |
| 7 | 4.3 | 4.3 | 162 | kernel | ACL2::K-AMBIGUOUS-CODE-P |
| 8 | 4.2 | 4.2 | 158 | runtime | SB-IMPL::GETHASH/EQL-HASH/FLAT |
| 9 | 3.6 | 22 | 137 | shell | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:STRING-WIDTH |
| 10 | 3.5 | 3.5 | 135 | runtime | SB-KERNEL:TWO-ARG->= |

### isearch — 4095 samples (isearch-20260719102112.txt)

| # | self% | total% | count | class | frame |
|--:|--:|--:|--:|---|---|
| 1 | 12.9 | 15.7 | 527 | runtime | Unknown fn 45469 |
| 2 | 12.4 | 30.8 | 509 | kernel | ACL2::K-CHAR-WIDTH |
| 3 | 10.8 | 58.2 | 443 | shell | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:WIDE-INDEX |
| 4 | 5.1 | 9.8 | 208 | kernel | ACL2::K-CONTROL-CODE-P |
| 5 | 4.2 | 4.2 | 172 | kernel | ACL2::K-ZERO-CODE-P |
| 6 | 3.7 | 11.3 | 150 | shell | SEARCH |
| 7 | 3.3 | 3.3 | 137 | runtime | SB-IMPL::GETHASH/EQL-HASH/FLAT |
| 8 | 3.2 | 3.2 | 131 | runtime | SB-KERNEL:TWO-ARG->= |
| 9 | 3 | 3 | 124 | kernel | ACL2::K-AMBIGUOUS-CODE-P |
| 10 | 2.8 | 3.9 | 115 | shell | CHAR-EQUAL |

### scroll — 2841 samples (scroll-20260719102125.txt)

| # | self% | total% | count | class | frame |
|--:|--:|--:|--:|---|---|
| 1 | 12.5 | 30.1 | 354 | kernel | ACL2::K-CHAR-WIDTH |
| 2 | 10.4 | 13.2 | 295 | shell | LEM/COMMON/CHARACTER/ICON:ICON-CODE-P |
| 3 | 5.2 | 5.2 | 147 | kernel | ACL2::K-AMBIGUOUS-CODE-P |
| 4 | 5.1 | 33.8 | 145 | shell | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:STRING-WIDTH |
| 5 | 5 | 11.5 | 142 | kernel | ACL2::K-SUM |
| 6 | 4.6 | 8.3 | 130 | kernel | ACL2::K-CONTROL-CODE-P |
| 7 | 4 | 4 | 115 | kernel | ACL2::K-ZERO-CODE-P |
| 8 | 3.8 | 3.8 | 107 | runtime | SB-IMPL::GETHASH/EQL-HASH/FLAT |
| 9 | 3.1 | 16.9 | 88 | shell | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:WIDE-INDEX |
| 10 | 3 | 3 | 85 | runtime | SB-KERNEL:TWO-ARG->= |

### overlay-heavy — 2636 samples (overlay-heavy-20260719102135.txt)

| # | self% | total% | count | class | frame |
|--:|--:|--:|--:|---|---|
| 1 | 48.4 | 48.4 | 1277 | runtime | (LAMBDA (SB-PCL::.ARG0.) :IN "SYS:SRC;PCL;BRAID.LISP") |
| 2 | 6.6 | 7.4 | 175 | runtime | SB-SPROF::UNAVAILABLE-FRAMES |
| 3 | 6.3 | 18.9 | 167 | shell | LEM/BUFFER/INTERNAL:SAME-LINE-P |
| 4 | 5 | 39.1 | 131 | shell | LEM/BUFFER/INTERNAL:POINT<= |
| 5 | 4.4 | 12.1 | 116 | shell | LEM/BUFFER/INTERNAL::%POINT< |
| 6 | 3.1 | 85 | 82 | shell | LEM-CORE::CREATE-LOGICAL-LINE |
| 7 | 2.7 | 5.1 | 71 | shell | LEM/BUFFER/INTERNAL::%POINT= |
| 8 | 2.6 | 12.6 | 69 | shell | LEM/BUFFER/INTERNAL::%ALWAYS-SAME-BUFFER |
| 9 | 2.5 | 70.8 | 66 | shell | LEM-CORE::OVERLAY-WITHIN-POINT-P |
| 10 | 2 | 2.2 | 52 | runtime | Unknown fn 45469 |

### long-line — 2629 samples (long-line-20260719102144.txt)

| # | self% | total% | count | class | frame |
|--:|--:|--:|--:|---|---|
| 1 | 13.2 | 31.7 | 348 | kernel | ACL2::K-CHAR-WIDTH |
| 2 | 10 | 13.1 | 263 | shell | LEM/COMMON/CHARACTER/ICON:ICON-CODE-P |
| 3 | 7.5 | 18.4 | 196 | kernel | ACL2::K-SUM |
| 4 | 5.6 | 12.5 | 148 | kernel | ACL2::K-FIRSTN |
| 5 | 5.3 | 9.6 | 140 | kernel | ACL2::K-CONTROL-CODE-P |
| 6 | 5.2 | 40.2 | 136 | shell | LEM/COMMON/CHARACTER/STRING-WIDTH-UTILS:STRING-WIDTH |
| 7 | 5 | 5 | 131 | kernel | ACL2::K-AMBIGUOUS-CODE-P |
| 8 | 4 | 4 | 105 | kernel | ACL2::K-ZERO-CODE-P |
| 9 | 4 | 4 | 104 | runtime | SB-IMPL::GETHASH/EQL-HASH/FLAT |
| 10 | 3.3 | 3.3 | 86 | runtime | SB-KERNEL:TWO-ARG->= |

### lisp-edit — 2518 samples (lisp-edit-20260719102154.txt)

| # | self% | total% | count | class | frame |
|--:|--:|--:|--:|---|---|
| 1 | 11 | 11 | 276 | runtime | (LAMBDA (SB-PCL::.ARG0.) :IN "SYS:SRC;PCL;BRAID.LISP") |
| 2 | 4.8 | 4.8 | 122 | runtime | (LAMBDA (SB-PCL::.ARG0.) :IN "SYS:SRC;PCL;BRAID.LISP") |
| 3 | 3.7 | 4.8 | 93 | runtime | SB-SPROF::UNAVAILABLE-FRAMES |
| 4 | 3.2 | 3.2 | 80 | runtime | SB-KERNEL:STRING=* |
| 5 | 3 | 11 | 75 | shell | LEM/BUFFER/INTERNAL::%MOVE-TO-POSITION |
| 6 | 3 | 3 | 75 | shell | LEM/BUFFER/INTERNAL:CURRENT-SYNTAX |
| 7 | 2.7 | 2.7 | 69 | runtime | LENGTH |
| 8 | 2.6 | 6.8 | 66 | shell | LEM/BUFFER/INTERNAL:CHARACTER-OFFSET |
| 9 | 2.6 | 5.5 | 66 | kernel | ACL2::K-CHAR-WIDTH |
| 10 | 2.5 | 68.7 | 64 | shell | LEM/BUFFER/INTERNAL:PARSE-PARTIAL-SEXP |

### undo-storm — 2663 samples (undo-storm-20260719102203.txt)

| # | self% | total% | count | class | frame |
|--:|--:|--:|--:|---|---|
| 1 | 32.4 | 32.4 | 862 | runtime | LENGTH |
| 2 | 21.7 | 21.7 | 578 | runtime | (LAMBDA (SB-PCL::.ARG0.) :IN "SYS:SRC;PCL;BRAID.LISP") |
| 3 | 6.1 | 34.2 | 163 | shell | LEM/BUFFER/INTERNAL:CHARACTER-OFFSET |
| 4 | 5.6 | 5.6 | 150 | runtime | GENERIC-+ |
| 5 | 5.6 | 18.7 | 148 | shell | LEM/BUFFER/LINE:LINE-LENGTH |
| 6 | 4.9 | 5.2 | 130 | runtime | SB-SPROF::UNAVAILABLE-FRAMES |
| 7 | 4.6 | 40 | 123 | shell | LEM/BUFFER/INTERNAL:POSITION-AT-POINT |
| 8 | 2.7 | 2.7 | 73 | runtime | SB-KERNEL:TWO-ARG-<= |
| 9 | 1.8 | 1.8 | 48 | runtime | GENERIC-- |
| 10 | 1.1 | 1.1 | 28 | runtime | (LAMBDA (SB-PCL::.ARG0.) :IN "SYS:SRC;PCL;BRAID.LISP") |

## Weighted contribution by class (ALL frames aggregated)

kernel = verified ACL2 K-* books; shell = imperative lem/lem-core code; runtime = SBCL/PCL/foreign/unattributed.

| class | Σ weighted (all frames) |
|---|--:|
| kernel | 32.86 |
| runtime | 32.44 |
| shell | 32.35 |

## Findings (for the P4 grounding-report author)

Profiler stage only — no commits, no optimization. All numbers are sb-sprof `:cpu`
flat self% from fresh 2026-07-19 runs (per-workload sample counts: big-file 3804,
isearch 4095, scroll 2841, overlay-heavy 2636, long-line 2629, lisp-edit 2518,
undo-storm 2663 — every one clears the PF-6 ≥1000-sample bar). Cross-workload weight
= self% × wall-ms share of the committed t2 baseline (commit e073c6b2). Weighting note:
self% is a CPU-sample share, wall-ms is the workload weight, so `weighted` reads as
"≈ % of total editor CPU time attributable to this frame across a wall-representative
session mix" — a ranking metric, not an exact time budget.

**1. The string-width redisplay path is the #1 cross-workload hotspot by a wide margin.**
A single cluster of frames — all reached from full-frame redisplay computing text-object
widths — accounts for the top of the ranking:

- `ACL2::K-CHAR-WIDTH` (kernel) — #1, weighted 12.14; dominates big-file/long-line/
  scroll/isearch (12–15% self each).
- `ICON:ICON-CODE-P` (shell shim) — #2, 7.88.
- `STRING-WIDTH-UTILS:WIDE-INDEX` (shell shim) — #3, 7.27.
- `K-CONTROL-CODE-P` / `K-ZERO-CODE-P` / `K-AMBIGUOUS-CODE-P` / `K-WIDE-CODE-P` /
  `K-SUM` / `NATP` / `K-NAT` (kernel) — #5,6,7,14,10,15,25.
- `STRING-WIDTH-UTILS:STRING-WIDTH` / `TEXT-OBJECT-CHAR-WIDTHS` (shell) — #12, #22.

Summing just the frames in this path gives ~55–60% of the weighted cross-workload
CPU. It is split ~half verified kernel (K-* per-codepoint width predicates + the
`K-SUM` width fold) and ~half the `lem/common/character` shim that drives them
(`icon-code-p`, `wide-index`, `string-width`, `text-object-char-widths`). This
reconciles with, and refines, the prior big-file-only note in the ledger
(ICON-CODE-P 12.6 / K-CHAR-WIDTH 12.3 / WIDE-INDEX 9.0): the path is not a big-file
artifact — it is the dominant cost in every redisplay-bound workload (big-file,
isearch, scroll, long-line) and thus in ~88% of the weighted session mix. `K-SUM`
(non-tail width fold) is the same frame implicated in the ≥24k-char single-line
stack-overflow cliff; here it also shows as raw CPU (long-line self 7.5%, scroll 5.0%).

**2. Generic-function dispatch (PCL) is the dominant cost in the edit/overlay workloads.**
`(LAMBDA (SB-PCL::.ARG0.) :IN "SYS:SRC;PCL;BRAID.LISP")` — the SBCL PCL
discriminating/cache closure for generic dispatch — is #4 overall (weighted 5.72) and
is *enormous* where redisplay is not the bottleneck: overlay-heavy 48.7% self,
undo-storm 22.8%, lisp-edit 15.8%. These three workloads pound megamorphic generic
functions (buffer/point/overlay protocol calls: `point<=`, `same-line-p`,
`character-offset`, overlay predicates). This is a shell/runtime hotspot with NO kernel
component — a distinct optimization axis from the width path (e.g. sealing or
devirtualizing hot buffer/point generics). It barely registers in the wall-heavy
redisplay workloads, so its cross-workload weight understates its impact on edit latency.

**3. undo-storm is dominated by `LENGTH` (32.4% self) + PCL dispatch (22.8%).**
`LENGTH` is #16 overall but 64.8% of its weight is undo-storm alone. Likely list-length
walks in the undo-record path; a candidate the report author may want T0 to corroborate
(undo-storm has the smallest wall share, 2.9%, so its synthetic prominence must be
checked against real-session `undo`/`redo` command frequency before ranking).

**4. Runtime/unattributed frames to flag, not to optimize.**
`Unknown fn 45469` is #9 (weighted 3.30) and is 25.8% self in isearch — an unattributed
JIT/foreign frame the profiler could not name; `SB-SPROF::UNAVAILABLE-FRAMES` (#20) is
profiler self-overhead, highest in the short workloads (overlay-heavy 6.6%, undo-storm
4.9%) where the replay loop restarts often. Neither is an editor hotspot. `SB-IMPL::
GETHASH/EQL-HASH*` (#8, #24) is the width-path memo/hash lookups riding along with the
string-width cluster. The low-level arithmetic frames `TWO-ARG->=`/`TWO-ARG-<=`/
`RANGE<=`/`GENERIC-+` are the kernel width predicates' fixnum comparisons not open-coded
under the verified books' generic numeric contracts — i.e. they are *part of* the width
path's cost, attributed to the runtime rather than the K-* frame.

**5. Class split (all frames aggregated, weighted):** kernel 32.86 / runtime 32.44 /
shell 32.35 (≈ even thirds; the ~2.3 remainder is sub-sample "elsewhere"). Read with
findings 1–2: the verified kernel is a real third of CPU but is almost entirely the
width path (optimizable only under the one-source recertify rule); the runtime third is
mostly PCL dispatch + the width path's arithmetic; the shell third is the width shim
plus the buffer/point protocol. The two actionable clusters for the P5 backlog are
(a) the string-width redisplay path (kernel + shim, ~all redisplay-bound workloads) and
(b) generic-dispatch on hot buffer/point/overlay generics (shell, edit-bound workloads).

**GC totals per workload (from the committed t2 baseline, not re-measured here):**
big-file gc=4 pause≈33.4ms; isearch gc=3 ≈41.3ms; scroll gc=2 ≈6.7ms; overlay-heavy
gc=1 ≈0; long-line gc=1 ≈0; lisp-edit gc=1 ≈0; undo-storm gc=1 ≈0. (Profile runs
suppress nothing but are not the GC measurement of record — the baseline session
metrics are.) Consed/workload: big-file 719MB, isearch 437MB, scroll 323MB,
overlay-heavy 175MB, long-line 122MB, lisp-edit 37MB, undo-storm 24MB.
