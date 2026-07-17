# `verified/` — the Lem verified kernel

This directory holds the **verified functional kernel** of Lem (SPEC-VK). Each
`*.lisp` file here (except `shim.lisp`) is an **ACL2 book**: a set of pure
functions written in the applicative Common Lisp subset, together with `defthm`
theorems ACL2 mechanically certifies. The *same source files* are loaded verbatim
into the running Lem SBCL image and executed — one source of truth (SPEC-VK
Constraint 2), never a hand-maintained shadow model.

Milestone V0 (toolchain bring-up) is what lives here today:

| File | Role |
|------|------|
| `hello.lisp` | Permanent canary book: `k-sq` + two theorems. First thing that goes red if the toolchain breaks. |
| `buffer-model.lisp` | VK-1 formal buffer model + `wf-buffer` well-formedness predicate. Certified; also the in-image runtime assertion. |
| `buffer-edit.lisp` | VK-2 edit primitives (`k-insert`, `k-delete`), shift-markers marker algebra, position algebra, and the five VK-2 obligation groups as certified theorems. |
| `undo.lisp` | VK-3 undo/redo kernel: edit records, session (history + redo + tick), `k-do-insert`/`k-do-delete`/`k-boundary`/`k-undo-group`/`k-redo-group`/inhibited-edit offset recomputation, and the certified VK-3 obligations. |
| `codec.lisp` | VK-5 EOL/encoding codec: pure `decode-eol`/`encode-eol` over codepoint lists, mirroring `src/buffer/file.lisp` read/write (post-DS-6); round-trip, no-char-loss and totality theorems. |
| `shim.lisp` | Dual-load shim (V0-3). Lets the ACL2 books load in a plain SBCL image. Part of the trust base — under 200 lines, every reinterpreted construct listed in its header. **Not a book**; the proof runner skips it. |
| `README.md` | This file. |

Books are certified in the dependency order pinned in `scripts/run-proofs.sh`
(`ORDERED_BOOKS` = `hello buffer-model buffer-edit undo codec`): `buffer-edit`
includes `buffer-model`, `undo` includes `buffer-edit`, and `codec` includes
`buffer-model` (for VK-1 `line-listp`); the alphabetical glob would order them
wrongly.

## VK-1 — buffer model + well-formedness

`buffer-model.lisp` defines the kernel buffer as `(list lines points tick)` and
`wf-buffer`, an executable predicate capturing every structural invariant
`src/buffer/internal/check-corruption.lisp` enforces, translated to the codepoint
representation (text = lists of naturals; a line excludes codepoint 10). It
certifies `wf-buffer` of the canonical empty buffer plus a set of reuse lemmas
for VK-2 (each wf component extracted; `find-point` membership; any member of an
in-bounds point-set is in bounds). The in-image acceptance is the rove test
`tests/pbt/kernel-model.lisp`: it converts PBT-generated production buffers to the
model and asserts `check-buffer-corruption` passing ⇒ `wf-buffer` holding (plus
`buffer-nlines = (len model-lines)`), and that hand-corrupted models are rejected.

**Model decision (deviation from the SPEC-VK VK-1 sketch, recorded per Constraint
5).** The SPEC-VK VK-1 model sketch lists an `nlines` component. The model here
has **no `nlines` field**: `nlines` is derived as `(len lines)`. The invariant is
not lost — the conformance mapper asserts production's cached `buffer-nlines`
equals `(len model-lines)` at the boundary — but the model has one fewer field
that could drift. Point kinds are `:left-inserting`/`:right-inserting` only;
production `:temporary` points are unregistered and out of the model, so only
registered points are converted and compared.

**Shim whitelist growth.** `buffer-model.lisp` is the first book to use the shim's
ACL2 base-function whitelist: `natp`, `len`, `true-listp` (each a fresh ACL2-package
symbol defined with its axiomatic semantics in `shim.lisp`). The exec path
otherwise uses only CL homonyms; no `std/` function is exec-reachable.

## VK-2 — edit primitives + marker algebra

`buffer-edit.lisp` defines the pure edit kernel:

- `k-insert (buffer linum charpos payload)` and
  `k-delete (buffer linum charpos n) → (mv buffer' deleted)`, faithful
  transcriptions of production `insert-string/point` / `delete-char/point`
  (`src/buffer/internal/buffer-insert.lisp:99-150`), with marker relocation
  transcribing `shift-markers`' exact four cases (`buffer-insert.lisp:39-97`)
  including the left-inserting-moves / right-inserting-stays boundary
  semantics (delete relocation is kind-independent, as in production).
- `k-position` / `k-point-at-position`: production `position-at-point`'s
  1-based absolute-position algebra (`src/buffer/internal/basic.lisp:382-387`).
- `k-shift-position-insert` / `k-shift-position-delete`: production
  `compute-edit-offset` (`src/buffer/internal/edit.lisp:40-51`).

Certified obligations (SPEC-VK VK-2, all five groups):

1. **wf-preservation**: `wf-buffer-of-k-insert`, `wf-buffer-of-k-delete`.
2. **Inverse law**: `k-delete-of-k-insert` — deleting exactly the inserted
   codepoints restores the lines and **every point exactly** and returns the
   payload as the deleted text. The kind-conditional boundary behaviour is
   stated separately and precisely
   (`shift-point-insert-left-inserting-at-position` — moves to the end of the
   inserted text; `shift-point-insert-right-inserting-at-position` — stays).
3. **Content laws**: `k-flatten-of-k-insert` (splice) and
   `content-of-k-delete` (excision + deleted-chunk equality) over the
   flattened codepoint content.
4. **Order preservation**: `shift-point-insert-preserves-strict-order`
   (strict order strictly preserved; weak order on coincident mixed-kind
   points is *intentionally* not preserved — that is the production boundary
   semantics), `shift-point-delete-preserves-order` (weak order preserved;
   collapses inside the deleted region may equalize).
5. **Offset algebra**: `k-shift-position-insert-tracks-content` /
   `k-shift-position-delete-tracks-content` — a shifted recorded position
   points at the same character of the flattened content (delete version for
   positions strictly past the deleted region), plus the
   `k-point-at-position-of-k-position` round trip.

**wf strengthening (VK-2 change to the VK-1 predicate).** `wf-distinguished`
now also pins start-point at charpos 0 with kind `:right-inserting` and
end-point kind `:left-inserting`. These are production truths
(`make-buffer-start-point` / `make-buffer-end-point`,
`src/buffer/internal/buffer.lisp:140-144`) and are exactly what makes
wf-preservation provable: without them an insert at (1,0) could carry a
left-inserting "start" off line 1.

**Differential acceptance**: `tests/pbt/kernel-conformance.lisp` runs ~2k
random edit scripts (newline-mixing multibyte inserts, deletes running off
the buffer end, extra registered points of both kinds, point moves) through
BOTH a live production buffer and the kernel from identical initial states,
comparing full content, every registered point's (linum charpos kind),
`buffer-nlines` vs `(len lines)`, the deleted string vs the kernel's deleted
payload, and production's landing coordinates vs `k-point-at-position`, after
every step. No divergence found; production is the spec.

**Shim growth for VK-2** (header updated in `shim.lisp`): `local` (no-op),
`include-book` (same-directory books load once via `load-verified-book`;
`:dir :system` community books are proof-only and ignored), `mv`/`mv-let`
(ACL2's own raw-Lisp semantics: `values` / `multiple-value-bind`). The
whitelist is unchanged; `arithmetic/top-with-meta` is included `local`ly so
nothing from it is exec-reachable.

## VK-3 — undo/redo kernel + tick semantics

`undo.lisp` models production's undo machinery (`src/buffer/internal/undo.lisp`,
`src/buffer/internal/edit.lisp`) as pure data on top of the VK-1 model and VK-2
edit primitives:

- **Edit record** `(kind position payload)` mirroring the production `edit`
  struct, with an **absolute 1-based position** (`position-at-point` algebra)
  and, for deletes, the **actually-removed** codepoints as payload (so
  insert↔delete are exact content inverses).
- **Session** `(buffer history redo)`; `history`/`redo` are `(edit | :separator)`
  lists (CAR = stack top, mirroring the fill-pointer vector / list discipline).
- Ops: `k-do-insert` / `k-do-delete` (`:edit` mode: push, clear redo, tick +1),
  `k-boundary` (`buffer-undo-boundary` with separator dedup), `k-undo-group` /
  `k-redo-group` (`buffer-undo` / `buffer-redo` — the exact separator push/pop
  dance, popping to the next separator), and `k-do-inhibited-insert` /
  `k-do-inhibited-delete` (`*inhibit-undo*`: mutate + tick +1, do **not** record,
  recompute every stored position via `compute-edit-offset`, reusing VK-2's
  `k-shift-position-insert` / `-delete`).

**Tick accounting.** Production `buffer-modify` sets the tick delta by *mode*
(`+1` in `:edit`/`:redo`, `-1` in `:undo`), not by insert-vs-delete. VK-2's
`k-insert`/`k-delete` already bump `+1` (correct for `:edit`/`:redo`); only the
undo step corrects to net `-1` (via `buf-with-tick`).

### Certified obligations

1. **Undo restores content + points + tick** (`k-undo-group-of-k-do-insert`):
   undoing a single recorded **insert** restores the pre-edit buffer *exactly* —
   lines, every registered point, and the tick. The tick restoration is the
   **sound tick fact**: the net signed edit-application count returns to zero.
2. **`redo ∘ undo = id`** (`k-redo-group-of-k-undo-group-of-k-do-insert`):
   redoing an undone insert restores the full session — buffer, history, **and**
   redo stack — to its pre-undo state (no intervening edit).
4. **Recorded positions are in bounds** (`k-position-in-bounds`): every position
   a user edit records lies in `[1, char-count+1]`, so `k-point-at-position`
   never runs off the buffer.

### VK-3.3 tick decision (obligation 3 — REFUTED, documented not silent)

The claim **"tick = 0 ⟺ content = content at last `unmark`"** is **REFUTED**, in
**both** directions, and — contrary to the initial suspicion that only the
`*inhibit-undo*` path breaks it — **even for plain edits with no inhibition**.
Reproducers (from the throwaway `tick-probe` experiment; all confirmed against
the live production buffer):

- `tick = 0 ⇏ content = C0`, no inhibit: insert `"a"`, `buffer-unmark` (tick 0,
  C0=`"a"`), `buffer-undo` (tick −1, `""`), insert `"b"` (the fresh edit clears
  redo and bumps tick back to **0** — at content `"b"` ≠ `"a"`).
- `content = C0 ⇏ tick = 0`: insert `"a"`, unmark, insert `"x"`, delete `"x"` —
  content back to `"a"` but tick = **2** (both edits increment in `:edit` mode;
  the counter only decrements under `:undo`).
- `tick = 0 ⇏ content = C0`, inhibit path: undo below the unmark, then an
  inhibited insert bumps the tick to 0 while recording nothing.

**Root cause.** The production modified-tick is a *net signed counter of buffer
mutations since unmark*, not a content-identity witness. It returns to zero
whenever `#(+1 steps) = #(−1 steps)`, which is decoupled from whether the
content matches the saved snapshot.

**The true, exported claim (what a verified kernel may soundly assert).**
`buffer-modified-p` (tick ≠ 0) is a **conservative dirty flag with a
false-clean hazard**: `buffer-modified-p = NIL` does **not** imply the content
equals the last-saved content, so it is **not** sound as a save-safety oracle in
the presence of undo-below-unmark or inhibited edits. The kernel proves only the
sound sub-claim it *can*: the tick **round-trips to its starting value** across a
recorded edit and its undo (obligation 1 above). This is a genuine latent
save-safety issue in production; per the item's charter we **do not change
production here** — the reproducers above are the record.

### VK-3 history-validity decision (obligation 4 — partial, inhibit path refuted)

The full invariant *"every stored position stays in bounds after ANY
interleaving of edits / undos / redos / inhibited edits"* is **REFUTED on the
inhibit path**. Reproducer (`tick-probe` c1): an inhibited delete shrinks the
buffer and recomputes stored positions *consistently with the shrunk buffer*,
but a later undo applies the group's edits sequentially, and an earlier-applied
undo can shrink the buffer **below** a still-stored position. Production's
`move-to-position` then returns `NIL` and the edit is silently mis-placed (the
undo "drifts"). The kernel's pure `k-point-at-position` has no cursor to drift,
so on this path the two **diverge in content** and the kernel model can even
leave `wf-buffer`. What is **proved** is the invariant's sound foundation
(`k-position-in-bounds`: recorded positions are in bounds); for inhibition-free
histories, undo reverses the recording order exactly and no undo ever goes
out of range (pinned by the strict differential suite, 1500 scripts, zero
divergences).

### Differential acceptance

`tests/pbt/kernel-undo-conformance.lisp` runs random interleavings through BOTH
a live production buffer (`buffer-undo` / `buffer-redo` / `buffer-undo-boundary`
/ `with-inhibit-undo`, `enable-undo-p` T) and the kernel session, driving edits
through a dedicated scratch point so `buffer-point` and the extras are relocated
only by marker algebra (as the kernel models). Two suites:

- **STRICT** (inhibition-free), 1500 scripts: full comparison after every op —
  content, tick, every registered point `(linum charpos kind)`, and kernel
  `wf-buffer`. Zero divergences.
- **INHIBITED** (with `*inhibit-undo*` edits), 1000 scripts: asserts the
  invariants that survive the refuted path — production tick == kernel tick (the
  ±1 accounting stays in lockstep) and production `check-buffer-corruption`
  passes after every op. Content/point equality is **not** asserted here (it is
  the refuted claim above).

### Kernel bug found and fixed during VK-3

`recompute-edit-offset` originally tested `(eq (car stored) :separator)`, but a
separator element **is** the keyword `:separator` (not a list), so `(car …)`
crashed on the inhibited path. Fixed to `(eq stored :separator)`; the inhibited
differential suite is the regression pin.

## VK-5 — EOL/encoding codec

`codec.lisp` models the end-of-line codec as pure functions on codepoint lists,
mirroring `src/buffer/file.lisp`'s post-DS-6 read/write paths:

- `decode-eol (cs eol) → (mv lines mixed-p)` — `strip-eols` performs the read
  transform (`%encoding-read`: for `:crlf` drop the CR of each CRLF pair — "strip
  only when present"; the EOF segment and lone CRs are kept; `:lf`/`:cr` are
  identity), `split-on-nl` splits on LF, and `crlf-mixed-p` is production's
  mixed-eol flag (only ever reported for `:crlf`, as in production's `:crlf`
  branch).
- `encode-eol (lines eol) → cs` — `join-with` emits each line followed by the
  uniform EOL sequence (`:crlf`→CR LF, `:lf`→LF, `:cr`→CR), the last line with no
  trailing separator (`%write-region-to-file`'s `unless eof-p`).

Certified obligations (SPEC-VK VK-5):

1. **Round-trip byte-identity** for single-EOL input, `encode-eol(decode-eol(cs,
   e), e) = cs`, over the precisely defined `single-eol-clean-p` predicate —
   `round-trip-lf` (any codepoint list: LF is the split/join separator),
   `round-trip-cr` (no LF present), `round-trip-crlf` (`crlf-clean-p`: every LF is
   a CRLF, i.e. not mixed), and the unified `round-trip-single-eol-clean`. Covers
   LF/CRLF/CR **with and without** a trailing line break (the clean predicate
   admits both).
2. **No-character-loss** for arbitrary (mixed) input — `no-char-loss`
   (`flatten(decode) = strip-eols`, the spec wording) plus the content teeth
   `no-char-loss-content` (`drop-nl(flatten(decode)) = content-codepoints`: every
   non-EOL codepoint appears in the output exactly once, in order).
3. **Totality / well-formedness** — `line-listp-of-decode-lines`: decode always
   yields a VK-1 `line-listp` (nat-lists, no 10) for codepoint-list input, and
   `consp-of-decode-lines` (always ≥ 1 line). `decode-eol`/`encode-eol` are
   **total** by ACL2 admission. The mixed flag is characterized
   (`crlf-clean-p-iff-not-mixed`; `:lf`/`:cr` never flag mixed).

**Documented scoping deviation (SPEC-VK Constraint 5).** SPEC-VK VK-5 words the
codec "over octet lists"; this book instead models the EOL layer over **decoded
codepoints**. Justification: production runs the EOL logic *post-decode* on the
already-UTF-8-decoded character stream (`%encoding-read`'s `read-line`), and
modeling raw octets would re-verify SBCL's UTF-8 decoder — which is trust base
(SBCL itself). The spec's actual intent (DS-6 EOL correctness, no character loss)
is preserved by the theorems above. The byte-level gap is closed empirically by
the differential suite, which feeds real UTF-8 byte files through the *production*
read/write path.

**Shim growth for VK-5:** none. `decode-eol`/`encode-eol` and their exec-path
callees use only CL homonyms; the whitelist is unchanged. Two symbols
(`DECODE-EOL`, `ENCODE-EOL`) were added to `*kernel-exports*`.

**Differential acceptance:** `tests/pbt/codec-conformance.lisp` — 300 random
UTF-8 byte files per run (random EOL mixes incl. lone CR, CRLF, no-trailing-
newline, interleaved with multibyte/emoji codepoints) opened through the real
`find-file-buffer` machinery (as `tests/eol-roundtrip.lisp`): the buffer line
list is compared against `decode-eol` over the same decoded codepoints, the
mixed-EOL notification against the kernel's mixed flag, and the saved bytes
against the UTF-8 of `encode-eol`. The `tests/eol-roundtrip.lisp` corpus is a
fixed regression subset. No divergence found.

## Proof status

All theorems in every book under `verified/` certify with real ACL2 (no
`skip-proofs`, `defaxiom`, trust tags, or `:program`-mode kernel functions), and
no statement was weakened. VK-1, VK-2 (five obligation groups) and VK-5 (all
three obligations) are fully certified.

**VK-3.** Certified: obligation 1 for the single recorded **insert**
(content + points + tick), obligation 2 (`redo ∘ undo = id`, full session), and
obligation 4's sound core (`k-position-in-bounds`). Obligation 3 is **REFUTED**
and documented above (no theorem claims the false biconditional; the sound
tick round-trip is what obligation 1 proves).

**PROOF PENDING (VK-3), PBT-pinned by the STRICT differential suite** (1500
scripts, full content+points+tick+wf, zero divergences — the mandatory
acceptance is green):

- **Obligation 1, group generalization + delete case** — undo of a recorded
  *group* and of a recorded *delete* restores content (and, for inserts, points).
  The delete case needs a `k-insert`-of-`k-delete` content inverse (and points
  are only partially restored — a point interior to a deleted region collapses
  to the deletion start on delete and cannot be resurrected by re-insert, exactly
  as in production). Not attempted as a closed-form theorem; pinned empirically.
- **Obligation 2, group generalization + delete case** — same scope, same pin.
- **Obligation 4, full cross-op invariant (inhibition-free)** — the inductive
  "all stored positions stay in bounds across any inhibition-free op sequence".
  The inhibit-path version is **refuted** (documented above); the
  inhibition-free version is pinned by the strict suite.

## ACL2 toolchain — install and pin

ACL2 is installed from **nixpkgs**, binary-cached; no from-source build needed
on this machine. The primary toolchain is the **full `acl2` package, which ships
the certified community books** (`std/`, `arithmetic/`, …), so kernel books may
freely `(include-book "std/lists/top" :dir :system)` — empirically verified to
certify. Reproducible install (the bundled glucose SAT library is unfree-licensed,
hence the flag):

```bash
NIXPKGS_ALLOW_UNFREE=1 nix build nixpkgs#acl2 --impure --no-link --print-out-paths
```

**Pinned store paths** (the exact builds these proofs are certified against):

```
/nix/store/pcm6pnmxikvnk9pg9abs6k3c0yamsqkj-acl2-8.6/bin/acl2   # full, WITH community books (primary)
/nix/store/ymb6xzcij4c22all84pcafvjv4wgvf9s-acl2-8.6/bin/acl2   # acl2-minimal, books-free fallback
```

- ACL2 version: **8.6** (both).
- ACL2's own host Lisp in these closures is **SBCL 2.6.5**. Lem's image runs
  **SBCL 2.5.10**. That difference is fine and does **not** violate the
  one-source rule: the certification host need not equal the execution host
  (SPEC-VK "Standing risks" — the kernel *sources* still run on Lem's SBCL either
  way). `perl` / `cert.pl` community-book prerequisites are not needed for the
  plain-`certify-book` driver.
- Binary resolution order in `scripts/run-proofs.sh`: `$ACL2` env override → the
  pinned full build → `command -v acl2` → the pinned minimal build. The pin beats
  `PATH` so certification stays reproducible regardless of user environment.

To repin after a nixpkgs bump: run the install command above, replace the store
paths here and in `scripts/run-proofs.sh` (`PINNED_ACL2`/`PINNED_ACL2_MINIMAL`),
then re-run the proofs.

## Running the proofs

```bash
scripts/run-proofs.sh
```

Certifies every book under `verified/` and **exits nonzero iff any book failed**.
Run it in the same pre-commit habit as `scripts/run-tests.sh`; a red proof blocks
commit exactly like a red rove suite (SPEC-VK Constraint 1). Notes:

- The ACL2 binary is resolved as `$ACL2` → `command -v acl2` → the pinned store
  path above.
- **The ACL2 binary exits 0 even when a proof fails** — it just doesn't write the
  book's `.cert`. The runner therefore gates on `.cert` existence/freshness,
  never on ACL2's exit status.
- Incremental: a book is skipped when its `.cert` is newer than both its `.lisp`
  source and `shim.lisp`.
- Per-book logs land in `verified/<book>.cert.out`. All `.cert`, `.cert.out`,
  `.port`, `@expansion.lsp`, `.fasl` outputs are git-ignored.

The in-image side is exercised by the rove test `tests/verified-shim.lisp`
(part of `lem-tests`): it loads `shim.lisp` + `hello.lisp` into the test image and
calls the certified `k-sq` through the `:lem/kernel` surface — proving the same
source *certifies in ACL2 and executes in-image*.

## Trust base

"Verified" here means: **ACL2 has proved the stated `defthm` properties of the
kernel functions.** It does **not** mean the whole editor is proved. What we are
trusting, unproven, is:

1. **SBCL itself** — the compiler/runtime executing the kernel in Lem.
2. **ACL2 itself** — the prover establishing the theorems.
3. **The dual-load shim** (`shim.lisp`) — it reinterprets ACL2isms for in-image
   execution; a shim bug could make certified code behave differently in-image.
   Mitigation: it is tiny, reviewed line by line, lists every construct it
   touches, and every kernel book gets an in-image rove test exercising the same
   functions ACL2 certified.
4. **The imperative shell** — the mutation/IO code that materializes
   kernel-computed results (kept small, conformance-tested, not proven).
5. **ncurses / libc / the OS kernel** — everything below Lem.
6. **Concurrency-model fidelity** — for the event-loop/interrupt work (V4), the
   theorems hold of an ACL2 interleaving model; whether that model faithfully
   captures SBCL's real thread/interrupt semantics (e.g. interrupts landing in
   foreign code) is bridged by stress tests, not proof, and stated as residue.

"Absolutely robust" is not a claim any toolchain delivers; this directory buys
the strongest guarantee available per subsystem and is explicit about the
residue. Per-milestone decisions that qualify a claim (e.g. the VK-3.3 tick
decision) are recorded here as they land.
