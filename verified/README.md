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
| `crash-safety.lisp` | VK-6 crash-safety protocol: operational model of the DS-2 atomic save + DS-3 checkpoint interplay with a crash transition after every step; durability/delete-ordering invariants proved inductive over all reachable states, plus `encode-path` injectivity and checkpoint-name namespace disjointness. |
| `input-decode.lisp` | VK-7 terminal input decode kernel: `k-decode` over byte/keycode/timeout item lists, the CSI key/modifier decoder and bracketed-paste state machine that production `frontends/ncurses/input.lisp` now delegates to (the first one-source swap), with totality/wf, progress/no-overconsumption, table-wide encode/decode round-trip and paste-reconstruction theorems. |
| `eastasian-data.lisp` | VK-10 East-Asian width tables as a certified constant book: `k-wide-code-p`/`k-ambiguous-code-p`/`k-zero-code-p`, generated (`scripts/gen-eastasian.lisp acl2`) as balanced binary-search decision trees recognizing exactly production's `*eastasian-full*`/`*eastasian-ambiguous*`/`*zero-width*` codepoints (same UCD parse). |
| `width.lisp` | VK-10 character/string width algebra: `k-char-width` (per-codepoint), `k-string-width`, `k-wide-index` that production `src/common/character/string-width-utils.lisp` now delegates to, with the additivity/fold, prefix-monotonicity, tab-stop and wide-index Galois theorems. |
| `shim.lisp` | Dual-load shim (V0-3). Lets the ACL2 books load in a plain SBCL image. Part of the trust base — ~200 lines (exports list is the only thing that grows), every reinterpreted construct listed in its header. **Not a book**; the proof runner skips it. |
| `shim-loader.lisp` | Sole component of the `lem-verified-kernel` ASDF system (`lem-verified-kernel.asd` at the repo root): loads the shim + the books production depends on. **Not a book**; the proof runner skips `shim*.lisp`. |
| `README.md` | This file. |

Books are certified in the dependency order pinned in `scripts/run-proofs.sh`
(`ORDERED_BOOKS` = `hello buffer-model buffer-edit undo codec crash-safety
input-decode eastasian-data width`): `buffer-edit` includes `buffer-model`,
`undo` includes `buffer-edit`, `codec` includes `buffer-model` (for VK-1
`line-listp`), and `width` includes `eastasian-data`; the alphabetical glob
would order them wrongly (`crash-safety` and `input-decode` are self-contained
but listed for a deterministic order).

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

## VK-6 — crash-safety protocol

`crash-safety.lisp` model-checks the DS-2 atomic save + DS-3 checkpoint
machinery as an ACL2 small-step operational model: an abstract filesystem
state (target file, save temp, checkpoint temp, checkpoint file — each a
`(content synced-p)` record — plus per-protocol pcs), the step sequences
transcribed from production (`write-file-atomically`,
src/buffer/file-utils.lisp:242-285; `write-string-to-file-atomically`,
src/ext/checkpoint.lisp:88-105; `delete-checkpoint-on-save` on the
after-save hook), and a **crash transition enabled after every step**. The
invariant `cs-inv` is proved inductive over the step relation
(`cs-inv-of-reachable`), so every theorem quantifies over **all** reachable
states — every interleaving of the two protocols (a superset of production's
single-threaded scheduling) and every crash point.

**Scope boundary.** Only the default `*atomic-save*` = T path is modeled. The
`write-file-in-place` fallback (src/buffer/file-utils.lisp, taken when
`*atomic-save*` is NIL or a virtual-file handler claims the target) truncates
and rewrites the target directly and provides none of the guarantees below —
disabling `*atomic-save*` opts out of these theorems. This matches DS-2 scope
(atomic save is the default).

**Hook ordering, verified in production.** `call-with-write-hook`
(src/buffer/file.lisp:182-186) runs the after-save hooks (which include
`delete-checkpoint-on-save`, wired at src/ext/checkpoint.lisp:249) strictly
after the writer returns, and `write-file-atomically` returns normally only
after `sb-posix:rename` commits — a failed rename signals `editor-error`,
unwinding before the hooks. The model's `:save-delete-checkpoint` step is
therefore enabled only in the post-rename state.

Certified obligations (SPEC-VK VK-6):

1. **Durability invariant** — `crash-safety-target-old-or-new`: in every
   reachable state, including every crash state, the target holds old-content
   or new-content — never torn, never lost. `crash-safety-checkpoint-never-junk`
   + the recoverability theorems give the "old + checkpoint" disjunct its
   precise form (below).
2. **Checkpoint-deletion ordering** — `crash-safety-checkpoint-delete-ordering`:
   checkpoint absent ⇒ target = new-content; no reachable state has
   "checkpoint gone, target still old" (the delete-then-crash window is closed
   by the verified hook ordering).
3. **`encode-path` injectivity** — `encode-path-injective` (verbatim codepoint
   port of src/ext/checkpoint.lisp:61-71, proved via the explicit prefix-code
   inverse `decode-path`), full-name injectivity `encoded-name-injective`, and
   namespace disjointness `encoded-and-hash-names-disjoint` /
   `checkpoint-name-collision-implies-equal-paths`: an encoded **absolute**
   path's name starts with `!s` (33 115) while a hash-fallback name starts
   with a base-36 digit codepoint, so the two namespaces (dispatched on the
   200-char threshold, checkpoint.lisp:81) can never collide.

**"Recoverable", precisely** (`crash-safety-recoverable-no-crash` /
`-any-state`): in every reachable state where a checkpoint write has committed
and the save has not renamed, the target still holds old-content, the
checkpoint file is present, and it holds the checkpointed edits **exactly** in
non-crash states — in crash states at worst a **prefix** of them (next
paragraph). Recovery is then production's find-file offer
(`maybe-offer-recovery` → `recover-buffer-from-checkpoint`).

**Filesystem axioms (trust base).** The crash transition is *defined* by:
POSIX rename atomicity (a name maps to the whole old or whole new file, never
a mixture); fsync durability (synced data survives a crash exactly); unsynced
data may be lost or torn to an arbitrary prefix (the crash action's
adversarial choices); ordered durable metadata (create/rename/unlink become
durable in program order — metadata journaling; a crash losing a metadata
suffix lands in an earlier protocol state, all of which the theorems already
cover). These axioms are the definition of `tear-file`/`:crash` in the book,
not `defaxiom`s; they are what we trust about the OS/filesystem below Lem.

**Production durability gap, documented (not fixed here — VK-6 charter).** The
save path fsyncs its temp before rename, so the renamed-in target is durable
and obligation 1 is unconditional. The checkpoint writer
(`write-string-to-file-atomically`) only `finish-output`s — **it never
fsyncs** — so on power loss a filesystem that reorders data vs. rename may
leave the checkpoint file torn to a prefix of the new checkpoint (that is
exactly the crash-state prefix disjunct in the theorems; the model applies
the fsync axiom uniformly, carrying the temp's synced flag through rename).
One `fsync` added to the checkpoint writer would strengthen the prefix
disjunct to equality. Also documented: intra-hash-namespace collisions
(`sxhash` is not injective) remain possible for two ≥200-char-encoding paths
with equal hashes and equal tails, and the namespace-disjointness guarantee
is conditional on paths being absolute (production guarantees that:
`buffer-filename` comes from `expand-file-name` and `checkpoint-filename`
tries `truename` first).

**Shim growth for VK-6:** none in the whitelist — the exec path (`cs-init`,
`cs-step`, `cs-run`, `cs-inv`, accessors, `prefix-p`, `take-at-most`,
`encode-path`) uses only CL homonyms. Seventeen symbols were added to
`*kernel-exports*`.

**Fault-injection acceptance:** `tests/pbt/crash-safety-faults.lisp` — a
driver executes the real syscall sequence (step-faithful transcription: same
syscalls, same order, same open flags; checkpoint path from the real
`checkpoint-filename`) against a tmpdir, stopping after k steps for every
k = 0..9. Stopping **is** the crash model (power loss / lying fsyncs are
covered by the axioms above, not testable from userland). At every kill point
the on-disk state is asserted against the VK-6 invariant AND against the
kernel model's predicted state (exact for synced/absent files, prefix for
unsynced ones), pinning the model's step semantics to reality. Plus
differential PBT of `encode-path` (kernel vs. production) and fixed
namespace-dispatch fixtures.

## VK-7 — terminal input decode kernel + ncurses one-source swap

`input-decode.lisp` models the ncurses terminal input decoder as a pure
function over item lists and is the **first book whose code runs on a
production code path**: `frontends/ncurses/input.lisp` now delegates its pure
decision logic to the shim-loaded kernel (via the new `lem-verified-kernel`
ASDF system, which `lem-ncurses` and `lem-tests` depend on).

**Model.** Input is a list of items: a byte `0..255`, `(:code n)` for a curses
keypad-translated keycode ≥ 256, or `:timeout` (production getch −1; end of
the item list is also modeled as a timeout). `k-decode` maps item lists to
event lists, transcribing `get-event`'s case analysis: key events are records
`(:key sym shift meta ctrl)` with sym a **codepoint list** (never ACL2
strings), paste events carry codepoint-list payloads, and `(:char bytes)` /
`(:meta-char bytes)` / `(:meta-code n)` / `(:curses-key n)` / `(:resize)` /
`(:abort)` / `(:mouse)` cover the rest.

**One-source swap (Constraint 2).** Production now delegates:

- `decode-csi-key` → `k-decode-csi-key` (+ `k-decode-csi-modifier` inside it):
  the sym/modifier tables and the whole decode live only in the book;
  production converts the final-byte char to a codepoint and the kernel key
  record to a lem key (`kernel-key-event->key`).
- `collect-bracketed-paste` → a getch driver over `k-paste-init` /
  `k-paste-step` / `k-paste-payload`: the terminator matching, partial-match
  flush and keycode-drop logic live only in the book.

The superseded production code (`decode-csi-modifier`, `make-modified-key`,
`+csi-final-syms+`, `+csi-tilde-syms+`, `+bracketed-paste-end+`, the inline
matcher loop) is **deleted**. The `lem-ncurses/tests` suites (`csi-decode`,
`bracketed-paste`) pass **unchanged** against the kernel-backed entry points.

**Boundary with the shell** (each of these remains in
`frontends/ncurses/input.lisp` and is *modeled* by the book, pinned by PBT,
but not swapped):

- **UTF-8 assembly**: production assembles multibyte characters in `get-key`,
  strictly below the CSI layer (CSI bytes are pure ASCII). The byte-counting
  (`utf8-bytes`) is transcribed as `k-utf8-len` so the list model can consume
  multibyte groups; validity checking and decoding to a character stay in the
  shell (babel/SBCL — trust base).
- **Keycode tables**: the terminfo keycode→key table (`lem-ncurses/key`) is
  shell data; the model emits `(:curses-key n)` / `(:meta-code n)`.
- **SGR mouse**: only the stream *consumption* of `read-sgr-mouse-event` is
  modeled (`k-read-mouse` → `(:mouse)`); its decoding is out of VK-7 scope.
- **`read-csi` / `get-event` impure weave**: the getch/wtimeout/tagbody
  skeleton stays in the shell; `k-read-csi`/`k-decode-1`/`k-decode` are its
  pure mirror.

**Certified obligations** (SPEC-VK VK-7, all five):

1. **Totality + wf** — `k-decode` admits with measure `(len items)` (the
   "fail closed to Escape" behavior is a termination + `event-listp-of-k-decode`
   theorem, *unconditional*: any garbage input yields a wf event list).
2. **Progress / no-overconsumption** — `k-decode-1-progress` (every event
   consumes ≥ 1 item), `k-decode-1-no-overconsumption` (the remainder is a
   genuine suffix of the input, `k-suffixp`, for true-list inputs; per-helper
   suffix lemmas cover every level), `k-decode-event-count`.
3. **Round-trip** — `k-decode-of-k-encode-key`: decode∘encode = identity for
   **every** key the table supports, quantified via the recognizer
   `supported-key-evp` over `all-supported-keys` (23 syms × 8 modifier
   combinations = 184 keys; proved via an exhaustively *evaluated* ground
   theorem `all-supported-keys-round-trip` plus a membership lemma).
4. **Paste reconstruction** — `paste-exact-reconstruction`: for ANY byte
   payload not containing the full terminator — including payloads with
   embedded and trailing **proper prefixes** of `ESC[201~` —
   `collect(P ++ terminator) = P`. (The restart-at-ESC flush is exact for
   this terminator because ESC occurs only at its first position.)
5. **Keycodes in pastes** — `paste-drops-codes`: the payload of a stream
   equals the payload of the same stream with all `(:code n)` items removed —
   they never corrupt the payload and never abort the paste. Timeout behavior
   (payload-so-far returned, pending partial match *not* flushed) is
   production behavior, pinned by the ncurses suite and fixed PBT cases.

**Deviations** (recorded per Constraint 5, also in the book header): non-item
garbage is dropped one element at a time (unreachable from production;
totality demands some behavior); a `(:code n)`/`:timeout` inside a UTF-8
continuation window ends the byte group early (production would store getch's
raw return into an `(unsigned-byte 8)` vector — a latent type error, not
transcribable); the paste flush uses an explicit prefix table (`term-prefix`)
— the unrolling of production's index loop; `k-decode` processes a whole list
while production reads one event per call.

**Shim growth for VK-7:** none in the whitelist — the exec path uses only CL
homonyms (`logbitp`, `revappend`, `nth`, `floor`, `mod` are standard CL).
Twenty-seven symbols added to `*kernel-exports*`. New infrastructure:
`lem-verified-kernel.asd` + `verified/shim-loader.lisp` (ASDF loader for shim
+ production-needed books; `load-verified-book` load-once semantics make it
idempotent against tests that load further books ad hoc).

**Differential/PBT acceptance:** `tests/pbt/input-decode-conformance.lisp`
(main suite) — random item streams (byte soup, truncated CSI, interleaved
timeouts/keycodes) asserting wf + progress + genuine-tail + no signal;
encode/decode round-trip PBT over randomly drawn supported keys, singly and
concatenated; paste reconstruction with embedded terminator prefixes,
interleaved keycodes, and a 50k-byte payload; fixed regression cases
transcribed from both ncurses test corpora. The ncurses suite itself
(`scripts/run-tests.sh lem-ncurses/tests`) is the production-integration gate.

## VK-10 — character/string width algebra + one-source swap

`width.lisp` is the certified width algebra over **codepoints** (VK-1's
representation), and the **second book whose code runs on a production code
path**: `src/common/character/string-width-utils.lisp` is now a thin shell over
the shim-loaded kernel (production `lem/core` depends on `lem-verified-kernel`).

- `k-char-width (code col tab-size icon-p amb-width)` — the per-codepoint step
  returning the new column, a verbatim transcription of production `char-width`'s
  branch order: TAB → next tab stop; NEWLINE → 0; control (0-31/127/`#xE000..#xE0FF`)
  → `col + (len *char-replacement*)`; zero-width (Mn/Me + ZWJ) → `col`; wide
  (▼ U+25BC, icon, East_Asian W/F + emoji) → `col+2`; ambiguous (East_Asian A) →
  `col + amb-width`; else → `col+1`. The two pieces of **dynamic** state the
  kernel cannot hold are explicit arguments (contract.yml `functional_style`):
  `icon-p` (the runtime extension icon table) and `amb-width`
  (`*ambiguous-character-width*`). Control-char replacement is a `+ length`
  (its recursion collapses because every replacement glyph is narrow ASCII —
  witnessed by `narrow-run-is-plus-len`).
- `k-string-width` / `k-wide-index` — the fold and the reverse lookup; the shell
  iterates the string calling `k-char-width` with `char-code` (no per-call
  codepoint-list allocation — string-width is redisplay-hot).
- `eastasian-data.lisp` — the East-Asian tables as a **certified constant book**,
  GENERATED by `scripts/gen-eastasian.lisp acl2` (documented in the book header;
  reproducible from the same UCD parse as production's `eastasian.lisp`, the two
  emitters share `compute-ranges`). Emitted as three balanced binary-search
  **decision-tree predicates** (`k-wide-code-p`/`k-ambiguous-code-p`/
  `k-zero-code-p`) carrying production's own `(declare (type (unsigned-byte 32)
  code) (optimize (speed 3) (safety 0)))` policy, so SBCL compiles them to the
  same O(log n) literal fixnum comparisons as production's `gen-binary-search-function`.

Certified obligations (SPEC-VK VK-10):

1. **Additivity / fold law** — `k-string-width-append`:
   `string-width(a ++ b, c) = string-width(b, string-width(a, c))`, the left-fold
   formulation.
2. **Monotonicity** — `k-char-width-lower-bound` (each non-newline step is
   non-decreasing) and `k-string-width-prefix-le` (prefix width ≤ whole width for
   newline-free input). Stated newline-free because production resets the column
   to 0 on a newline (physical lines are split on newline before measuring).
3. **wide-index Galois / least-index** — `k-wide-index-prefix-within` (the
   returned index `i` has `width(take i) ≤ goal`), `k-wide-index-next-exceeds`
   (`width(take i+1) > goal`, so `i` is the *greatest* feasible prefix length),
   and `k-wide-index-nil-iff` (returns an index exactly when `goal < total`, else
   NIL — production's exact convention: it returns the first index whose inclusive
   width exceeds `goal`, NIL if the whole run fits). All under the shell's loop
   invariant `col ≤ goal` (established by starting at `col = 0`, `goal` natural).
4. **Tab-stop law** — `tab-stop-strictly-greater` / `tab-stop-is-a-multiple` /
   `tab-stop-is-least`: after a tab the column is the least multiple of tab-size
   strictly greater than the current column.

**Shim growth for VK-10:** three constructs reinterpreted (documented in
`shim.lisp`): `encapsulate` (→ `progn` of its non-local events — the book confines
`arithmetic-5` there so its rewriter can't loop book-wide) and `in-theory`
(proof-only, → no-op); plus the whitelist is **unchanged** (the exec path uses
only CL homonyms + `natp`). Three symbols added to `*kernel-exports*`
(`K-CHAR-WIDTH`, `K-STRING-WIDTH`, `K-WIDE-INDEX`); `width` added to
`verified/shim-loader.lisp` (production now depends on it).

**Deviation from the SPEC-VK sketch (Constraint 5).** The spec lists the tables
"as certified constant data (… emitted in both loadable forms)". They are emitted
in **one** loadable form — the certified `eastasian-data.lisp` predicates — not a
duplicate shape; production keeps its own `eastasian.lisp` (a separate O(log n)
binary-search generated from the same UCD parse, so the two cannot drift). The
kernel classifies East-Asian wide/ambiguous/zero-width itself (its own certified
tables); production's `wide-char-p`/`control-char` remain the exported
classification helpers but are no longer on `char-width`'s path.

**One-source swap + performance.** `char-width`/`string-width`/`wide-index`
delegate to the kernel; `wide-char-p`/`control-char` are kept (exported API,
imported by tests). `tests/string-width-utils.lisp` passes **unchanged**. Perf is
a gate-level concern (string-width is redisplay-hot): measured on 10k-char strings,
2000 reps, before (production-fasl `lem/core` at the pre-swap baseline) vs after
(kernel-backed):

| input (10k chars) | before (ms/call) | after (ms/call) | ratio |
|-------------------|------------------|-----------------|-------|
| ASCII             | 0.41             | 0.30            | 0.73× |
| CJK (all wide)    | 0.31             | 0.32            | 1.04× |
| mixed (tab/CJK/control/combining) | 0.42 | 0.24     | 0.57× |

No regression (the initial O(n) list-scan table cost CJK ~30×; the binary-search
decision-tree book with production's fixnum/`(speed 3)` policy restored parity).

**Differential/PBT acceptance:** `tests/pbt/width-conformance.lisp` — the
`tests/pbt/width-vectors.lisp` regression corpus (228 width + 213 wide-index
`(codepoints, tab-size, ambiguous-width, expected)` vectors captured from the
ORIGINAL production char-width/string-width/wide-index **before** the swap, since
a post-swap differential against live production is vacuous) is asserted against
BOTH the kernel and the kernel-backed production shell (the swap changed nothing
observable), plus property tests of all four theorems on random inputs (ASCII,
CJK, tabs, control, emoji, combining marks). No divergence.

## VK-11 — line layout kernel (wrapping & clipping)

**Book:** `layout.lisp` (standalone; no sibling includes). Transcribes the two
pure layout algorithms of `src/display/physical-line.lisp` over an abstract
display-object type:

- `(:text codes widths tag)` — a text run: codepoint list plus the ALIGNED
  per-char width list (the ncurses column widths), `tag` an opaque payload
  carried verbatim (attribute/type/CLOS identity for an adapter);
- `(:opaque width tag)` — an unbreakable non-text object (void / eol-cursor /
  extend-to-eol / image; all width 0 on ncurses).

`k-wrap-row`/`k-wrap` transcribe `separate-objects-by-width` (with its inner
`explode-object` halving at `(floor len 2)`) and the row loop of
`redraw-logical-line-when-line-wrapping`; `k-clip`/`k-clip-chars` transcribe
`clip-objects-to-display-range`; `k-scroll-adjust` transcribes the
horizontal-scroll-start adjustment of
`redraw-logical-line-when-horizontal-scroll`.

Certified obligations (SPEC-VK VK-11):

1. **Content preservation** — `k-wrap-row-preserves-contents` /
   `k-wrap-preserves-contents` (+ `-wcontents` width-list versions): appending
   the emitted rows' contents and the leftover's contents reproduces the input
   contents exactly — nothing dropped, duplicated or reordered (opaque objects
   appear in the content stream as themselves, so their order is pinned too).
2. **Width bound** — `k-wrap-row-width-bound` / `k-wrap-rows-fit`: every row's
   total width ≤ (view-width − 1) + the width of the row's opaque objects;
   `k-wrap-rows-all-lt`: with all-zero opaque widths (the ncurses reality)
   every row is strictly narrower than the view. **The exception, stated as
   production actually behaves:** production never over-fills a row with text —
   an unbreakable (single-codepoint) text object at least as wide as the view is
   *never placed at all*; it is pushed back and only wrap-marker rows are
   emitted until the height budget runs out. `k-wrap-row-blocked` characterizes
   that stuck case precisely (empty row + non-nil rest ⟹ the head is a
   ≤ 1-codepoint text object with `view-width ≤ total + width`). Only opaque
   (non-text) objects, which production places unconditionally, can push a row
   past the view width — the bound accounts for them column-for-column.
3. **Termination/totality** — admission itself: `k-wrap-row` terminates by the
   explode-tree node-count measure `k-objs-msr` (halving strictly decreases
   it; zero-length runs take the unbreakable branch), `k-wrap` by fuel — the
   row budget production itself enforces via the window height (ncurses rows
   all have height 1), which is why fuel, not list length, is the measure
   (see the blocked case above: production genuinely does not make progress).
4. **Clip correctness** — `k-clip-width-bound` (clipped output width fits the
   display range, zero-opaque hypothesis), `k-clip-keeps-fully-visible` (an
   object fully inside the range survives clipping verbatim, with the exact
   strict-side boundary conditions production's cond order imposes),
   `k-scroll-adjust-contains-cursor` (the auto-scroll postcondition: the
   adjusted range contains the cursor cells whenever the cursor is no wider
   than the window) and their composition `k-clip-contains-cursor-object`
   (after adjustment, clipping keeps the cursor object itself).

**Documented deviations (Constraint 5):**

- **Wrap marker abstracted as the row boundary.** Production pushes a
  `wrap-line-character` letter object onto every wrapped row; kernel rows never
  contain marker objects — a row was wrapped iff the returned rest is non-nil,
  and the adapter/test re-attaches the marker there. The differential suite
  asserts production's marker is exactly where the kernel's row boundaries say.
- **Char granularity with exact per-char widths.** Production
  `clip-objects-to-display-range` approximates per-char width as total/len;
  that is exact precisely for uniform-per-char-width runs — which is what the
  ncurses pipeline produces — and exists for SDL2 surface metrics, out of scope
  per the spec's monospace non-goal. `k-clip-chars` walks the exact per-char
  width list instead. For wrapping there is no such gap: production re-measures
  each half with `string-width`, which equals the sum of the recorded per-char
  widths for every object the pipeline builds (no raw multi-char tab runs reach
  drawing objects; a tab run's deltas from column 0 are all tab-size anyway).

**Production swap DEFERRED to VK-4 (differential adapter is tests-only).**
`separate-objects-by-width` / `clip-objects-to-display-range` live in
frontend-generic core display code shared by SDL2, and `lem-if:object-width`
dispatches per implementation. In this fork SDL2 measures *text* objects
cell-aligned (`text-cell-width` = `string-width` × display cell width,
deliberately mirroring ncurses semantics), so a per-char width decomposition
for SDL2 text is likely feasible; but `image-object` still measures by
`sdl2:surface-width`, and rerouting the shared hot path through a kernel
adapter is a cross-frontend change either way. Not a low-risk ncurses-only
swap, so per the
spec's incremental-swap philosophy the kernel + theorems land now, pinned to
production by the mandatory differential suite, and the production delegation
rides the VK-4 shell swap (which already owns the "swap the running editor
onto the kernel" risk budget). The adapter that converts CLOS drawing objects
↔ kernel records (ncurses width semantics) lives in the test suite.

**Shim growth for VK-11:** none — no new constructs, no whitelist changes (the
exec path uses only CL homonyms + `natp`/`len`/`true-listp`). Six symbols added
to `*kernel-exports*` (`K-TEXT`, `K-OPAQUE`, `K-WRAP`, `K-WRAP-ROW`, `K-CLIP`,
`K-SCROLL-ADJUST`). `layout` is *not* in `shim-loader.lisp` (production does
not call it yet — VK-4); the test suite loads it via `load-verified-book`.

**Differential/PBT acceptance:** `tests/pbt/layout-conformance.lisp` — random
drawing-object lists (narrow/wide/emoji runs, mixed-width Greek+CJK runs,
single tabs, control characters, zero-width combining runs, zero-width opaque
objects) with view widths down to 1 and row budgets down to 1, through
production `separate-objects-by-width` (iterated with the redraw loop's height
cutoff) vs `k-wrap` — comparing row break positions, per-row contents,
per-object widths, marker placement and the leftover — and through production
`clip-objects-to-display-range` vs `k-clip` (uniform-width runs; multi-char
control objects excluded from clip inputs because production's straddle
rebuild of an already-replaced control string maps to a NIL string — an edge
the real pipeline cannot reach). Plus property tests of all four theorem
groups on random kernel inputs. No divergence.

## VK-12 — screen-matches-buffer & cache soundness (PBT, **no book**)

By design (SPEC-VK VK-12) this scope item ships **no ACL2 book**: the composed
redisplay pipeline crosses too much CLOS to port, so it is verified empirically
— but the rigor comes from a **kernel-as-oracle differential** structure, not
hand-checked expectations. Two rove/PBT suites drive a real Lem editor session
through a new **recording fake interface**
(`frontends/fake-interface/fake-interface.lisp`,
`recording-fake-interface`), added additively so the ~30 existing
`with-fake-interface` users are untouched. The recording interface (a) reports
the real ncurses `object-width` (`string-width` for text, 0 otherwise) instead
of the base stub's constant 1, and (b) paints each `render-line` into a
**persistent per-view character grid** keyed by screen row, evicted from `y`
down by `clear-to-end-of-window` — modelling the SDL2 persistent texture, on
which a frame the cache wrongly skips leaves stale (ghosted) content.

**Suite 1 — cache soundness** (`tests/pbt/redisplay-cache.lisp`). Random
edit/scroll/resize scripts run in lockstep against two windows over identical
buffers: a **cached** window redrawn with `force = nil` and never marked
`need-to-redraw` (so it relies purely on the drawing-object + line-fingerprint
caches to detect changes — strictly harder than production, which force-clears
on `need-to-redraw`; note that buffer edits do **not** set `need-to-redraw`, so
production likewise leans on the fingerprint after a plain edit), and a
**fresh** window redrawn with `force = t` (a full ground-truth render every
frame). After every step the two persistent grids — cells carry text, a
content-based attribute signature, width and cursor flag — must be `equal`; a
stale row diverges. The `tests/display-cache.lisp` invariants are folded in as
fixed cases: (i) an attribute recoloured **in place** must change
`compute-line-fingerprint` (asserted through the real overlay →
`create-logical-line` path), and (ii) the stale-tail hazard — a large deletion
blanks the lower rows via `clear-to-end-of-window`, then identical content
re-inserted must re-render rather than hit a stale
`evict-line-fingerprints-from` / `remove-drawing-cache-entries-from` entry.

**Suite 2 — projection** (`tests/pbt/screen-projection.lisp`), "what you see is
what's in the buffer". After each random buffer render, the concatenated visible
row text (control chars as their `^X`/`\N` replacement, `:zero-width` chars as
the middle dot, wrap markers stripped) equals the buffer text under the SAME
projection, with the **verified width/layout kernel as the oracle**:
`lem:string-width`/`char-width` (VK-10 `k-char-width`) for column layout and tab
stops, and the certified `k-wrap` row-width bound (VK-11 `k-wrap-rows-all-lt`,
the zero-opaque ncurses corollary) checked on every wrapped row. Cursor
screen-column consistency against `k-string-width` of the line prefix is checked
on the current window.

**Volume:** ~40 cache scripts × (seed + up to 18 steps) × 2 renders plus 4
projection properties × ~120 renders — well over ~1k random frames total,
measured **under a second** combined (far under the ~2-3 min CI budget). Both
suites are registered in `lem-tests.asd`.

**No shim/book change** (`*kernel-exports*` untouched; VK-12 calls the existing
VK-10/VK-11 exports through `lem:string-width`/`char-width`).

**Coverage boundaries (precise, not silently narrowed).** These are the places
fake-interface / the char-level oracle cannot faithfully reach, plus real
production edges the suites deliberately steer around:

- **Drawing-object cache & in-place attribute mutation.** `drawing-object-equal`
  → `attribute-equal` is content-based, but the cached object and the freshly
  built object share the ONE mutated attribute, so they compare equal — a
  reference-based cache cannot by itself observe an in-place recolour. Only the
  **line fingerprint** (a content snapshot) catches it; production closes the
  residual gap by pairing recolours with `need-to-redraw` (`color-theme.lisp`).
  Suite 1 therefore asserts the fingerprint invariant that holds and the
  production-faithful recolour redraw, and does not claim the drawing cache
  detects an in-place mutation on its own.
- **Leading zero-width runs are clipped.** A run of display-width-0 objects at
  column 0 has `obj-end = 0 <= start-x = 0`, so
  `clip-objects-to-display-range` (and the certified `k-clip`) drops it. The
  projection oracle uses only positive-width glyphs (bare combining marks are
  excluded; combining-mark WIDTH is already certified by VK-10) to keep the
  char-level oracle exact.
- **`expand-tab` is character-index based, the width kernel column based.** They
  agree on printable-ASCII runs (index = column); the tab-projection test uses
  printable ASCII and derives the expansion from the kernel, while raw tabs are
  excluded from the mixed wide/control/zero-width lines. A production quirk
  (`src/display/logical-line.lisp`), recorded not papered over.
- **Window width ≤ 2 under line-wrap infinite-loops in production.**
  `map-wrapping-line` scans with goal `body-width - 1`; when that is ≤ 1 a
  width-2 glyph makes `wide-index` return its own start index, so the
  wrap-offset scan (reached from scroll / cursor-y) never advances. The suites
  keep window width ≥ 4 (a real terminal never renders a 1–2-column window); the
  edge is noted here as a finding, out of VK-12's PBT scope to fix.
- **Floating windows, SDL2 surface-metric per-char widths and multi-cursor
  rendering** are out of scope for fake-interface (the ncurses monospace model),
  matching the VK-10/VK-11 non-goals.

## Proof status

All theorems in every book under `verified/` certify with real ACL2 (no
`skip-proofs`, `defaxiom`, trust tags, or `:program`-mode kernel functions), and
no statement was weakened. VK-1, VK-2 (five obligation groups), VK-5 (all
three obligations), VK-6 (all three obligations, with the checkpoint-tear
prefix disjunct and the intra-hash-namespace residue stated explicitly rather
than over-claimed — see the VK-6 section), VK-7 (all five obligations), VK-10
(all four obligations) and VK-11 (all four obligation groups, including the
blocked-head characterization and the clip/auto-scroll composition) are fully
certified. **VK-12 has no book by design** (SPEC-VK VK-12): it is verified
empirically by two kernel-as-oracle differential PBT suites (see the VK-12
section) — cache soundness and the screen-matches-buffer projection — with the
VK-10/VK-11 kernels as the oracle.

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
(part of `lem-tests`): the `lem-verified-kernel` system loads `shim.lisp` (plus
the production-needed books), the test loads `hello.lisp` on top and calls the
certified `k-sq` through the `:lem/kernel` surface — proving the same source
*certifies in ACL2 and executes in-image*.

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
5. **ncurses / libc / the OS kernel** — everything below Lem. For VK-6 this
   is made explicit as the filesystem axioms defining the crash transition
   (rename atomicity, fsync durability, unsynced-data prefix tearing, ordered
   durable metadata — see the VK-6 section).
6. **Concurrency-model fidelity** — for the event-loop/interrupt work (V4), the
   theorems hold of an ACL2 interleaving model; whether that model faithfully
   captures SBCL's real thread/interrupt semantics (e.g. interrupts landing in
   foreign code) is bridged by stress tests, not proof, and stated as residue.

"Absolutely robust" is not a claim any toolchain delivers; this directory buys
the strongest guarantee available per subsystem and is explicit about the
residue. Per-milestone decisions that qualify a claim (e.g. the VK-3.3 tick
decision) are recorded here as they land.
