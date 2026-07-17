# Lem Verified Kernel — Formal Verification Spec

**Baseline:** `yathxyz/lem` main @ `e739c782` (2026-07-17), i.e. after the Daily-Driver
spec (SPEC.md) landed in full.
**Fork policy:** soft divergence. We stop rebasing onto upstream and are free to
restructure the core; the `upstream` remote is kept for deliberate cherry-picks of
bug fixes and extension updates. The `lem-core` / `lem` exported API stays stable so
the 50+ extensions keep working unmodified.
**Toolchain policy (hard constraint):** CL-native only. Mechanized proofs live in
**ACL2** (which is itself applicative Common Lisp and runs on SBCL); empirical
properties live in an **in-image property-based-testing (PBT) harness** driven from
rove. No TLA+/Java, no Lean/Coq. Concurrency is verified against ACL2 operational
models (interleaving semantics as data), not an external model checker.

## Goal

Rebuild the four core subsystems — buffer/undo/file-I/O, input decoding, redisplay,
event loop — around a **verified functional kernel**: pure functions written in the
ACL2-provable subset of CL, certified by ACL2, loaded verbatim into the SBCL image,
and wrapped by a thin imperative shell that only *materializes* kernel-computed
results. Every kernel claim is anchored to production twice: by proof (ACL2 theorem)
and by differential PBT (kernel vs. production behavior on generated inputs).

**What "verified" does and does not mean here.** Proofs establish stated properties
of the kernel functions. The trust base remains: SBCL itself, ACL2 itself, the
dual-load shim (V0-3), the imperative shell (kept small and conformance-tested, not
proven), ncurses/libc/kernel, and — for concurrency — the fidelity of our
interleaving model to SBCL's actual thread/interrupt semantics. "Absolutely robust"
is not a claim any toolchain can deliver; this spec buys the strongest guarantees
available per subsystem and is explicit about the residue.

## Non-goals

- Verifying extensions, modes, LSP, or any frontend other than ncurses.
- Performance parity during the transition (paranoid/conformance modes may be slow;
  the default build must stay usable — see VK-5).
- Verifying SDL2/webview rendering, image/emoji drawing objects, or proportional
  fonts. The layout kernel is verified for the monospace model only.
- Upstreaming any of this.

## Constraints

1. **Proofs are CI-gated like tests.** `scripts/run-proofs.sh` certifies every book
   under `verified/` and exits nonzero on any failure; a red proof blocks commit
   exactly like a red rove suite. Never commit red.
2. **One source of truth.** Kernel functions are written once, in the ACL2 subset,
   under `verified/`, and loaded into both ACL2 (for certification) and the SBCL
   image (for execution). Hand-maintained "shadow models" that can drift from
   executed code are forbidden; where production keeps an optimized imperative
   implementation, a differential PBT suite pins it to the kernel.
3. **Extension API stability.** `lem-core`'s exported symbols and behavior are
   frozen for the duration; kernel adoption happens beneath them.
4. **Every milestone ends green:** all ACL2 books certify, full rove suite passes
   via `scripts/run-tests.sh`, and the editor builds and runs (`make ncurses`).
5. Spec documents (SPEC.md, SPEC-VK.md) are requirements, not scratch space —
   implementers do not edit them to match what was built; deviations are recorded
   in the tracking issue.

---

## Milestone V0 — Toolchain bring-up

| ID | Requirement | Done when |
|----|-------------|-----------|
| V0-1 | Build ACL2 from source against SBCL 2.5.10 (`make LISP=sbcl`), pin the commit in `scripts/`, install community-books `cert.pl` prerequisites (perl). Document in `verified/README.md`. | `acl2` starts; a hello-world book certifies |
| V0-2 | `scripts/run-proofs.sh`: certify all books under `verified/` (via cert.pl or plain `certify-book` driver), meaningful exit code, incremental (unchanged certified books skipped). | red proof ⇒ nonzero exit; wired into the same pre-commit habit as run-tests.sh |
| V0-3 | **Dual-load shim** `verified/shim.lisp`: a small package (`:lem/kernel`) + macro layer letting the same `verified/*.lisp` sources load in a raw SBCL image (defining or stubbing the ACL2isms actually used: `defthm` ⇒ no-op, guards ⇒ optional `check-type`s, `b*`/`define` if used ⇒ local macros). The shim is part of the trust base: keep it under ~200 lines and list every construct it reinterprets. | one file under `verified/` certifies in ACL2 **and** its functions are callable from a rove test in the Lem image |
| V0-4 | **PBT harness** `tests/pbt/harness.lisp`: generators (integers, strings incl. multibyte/combining/emoji, buffer contents, edit scripts, byte streams), explicit seed (printed on failure, settable via env var for reproduction), shrinking on failure, `deftest`-compatible driver `for-all`. Evaluate `check-it` from Quicklisp first; if bitrotten, write the ~300-line harness in-repo (no heavyweight dependency for a core testing primitive). | a deliberately-failing property shrinks to a small counterexample and prints a reproducing seed |
| V0-5 | Baseline conformance test: random edit scripts against the **production** buffer with `check-buffer-corruption` asserted after every step (the existing well-formedness predicate, `src/buffer/internal/check-corruption.lisp`). This is the pre-kernel anchor; it must pass before any rewrite starts, and any failure found is fixed first. | 10k-step scripted fuzz green in CI |

---

## Milestone V1 — Verified buffer kernel (the heart)

The buffer core is a doubly-linked list of line objects with registered points
relocated by `shift-markers` (`src/buffer/internal/buffer-insert.lisp:39-97`), an
integer modified-tick, and an undo history of `edit` records with `:separator`
boundaries. The kernel re-derives all of this as pure data.

### VK-1: Formal buffer model + well-formedness

**Deliverable.** `verified/buffer-model.lisp`: buffer as `(list-of-strings ×
point-set × nlines × tick)`; a point is `(id, linum, charpos, kind)` with kind ∈
{`:left-inserting`, `:right-inserting`, `:temporary`}; `wf-buffer` capturing every
invariant `check-buffer-corruption` checks today (point-in-bounds, linum/line
agreement, nlines = length of line list, start/end/point membership, end-point at
end of last line).

**Proof obligations.** `wf-buffer` holds of the empty buffer; `wf-buffer` is
decidable/executable (it doubles as a runtime assertion via the shim).

**Acceptance.** Book certifies. A rove test converts a production buffer to the
model (`buffer->model`) and asserts `wf-buffer` ⟺ `check-buffer-corruption`
agreement on generated buffers, including corrupted ones produced by deliberately
broken mutations in a sandbox. **Size:** M.

### VK-2: Edit primitives + marker algebra

**Deliverable.** `verified/buffer-edit.lisp`: pure `k-insert (buffer pos string)`
and `k-delete (buffer pos n)` returning a new buffer with all points relocated,
implementing exactly the four `shift-markers` cases and the left-/right-inserting
kind semantics; pure `position<->point` conversion (absolute-offset algebra used by
undo records).

**Proof obligations (minimum set).**
1. wf-preservation: `wf-buffer(b) ⇒ wf-buffer(k-insert(b,…)) ∧ wf-buffer(k-delete(b,…))`.
2. Inverse law: deleting exactly what was inserted restores content **and every
   point** (per kind semantics — state the precise point-restoration claim; for
   points that coincided with the edit position it is kind-dependent, prove the
   kind-conditional version).
3. Content law: `k-insert` content equals splice; `k-delete` returns the deleted
   string and content equals excision.
4. Marker monotonicity: relative order of points is preserved by every edit.
5. Offset algebra: `compute-edit-offset` (production `src/buffer/internal/edit.lisp:40-51`)
   semantics — shifting a recorded position past an untracked edit keeps it pointing
   at the same content location.

**Acceptance.** Book certifies. Differential PBT: random edit scripts executed in
production (`insert-string/point`, `delete-char/point`) and in the kernel from the
same initial state; assert equal content, equal point positions for all registered
points, equal nlines, after every step. 10k scripts in CI. **Size:** L. This is the
single hardest proof item in the spec; land it before anything downstream.

### VK-3: Undo/redo kernel

**Deliverable.** `verified/undo.lisp`: history as a list of `edit ∪ {:separator}`,
redo stack, modified tick with the production ±1 semantics
(`src/buffer/internal/undo.lisp:47-53`), `k-undo-group` / `k-redo-group` popping to
the next separator, `k-record-edit` (clears redo stack in `:edit` mode),
inhibited-edit position recomputation.

**Proof obligations.**
1. `k-undo-group(k-record-group(b, es)) ≡ b` in content and registered points.
2. `k-redo-group ∘ k-undo-group ≡ id` when no intervening edit.
3. Tick soundness: **investigate and then prove or refute** "tick = 0 ⟺ content =
   content at last `unmark`". The `*inhibit-undo*` path and the multi-cursor undo
   cases (`tests/buffer/internal.lisp` multiuser-undo tests) are suspected
   counterexample sources. If refuted, either fix production semantics or weaken
   the exported claim (`buffer-modified-p` NIL ⇒ safe-to-not-save) — a documented
   decision, not a silent one.
4. History validity: after any interleaving of recorded edits, inhibited edits (with
   offset recomputation), undos and redos, every stored position in
   history/redo-stack is in bounds (no undo can ever signal out-of-range).

**Acceptance.** Book certifies. Differential PBT: random interleavings of
edit/undo/redo/boundary/inhibited-edit against production; assert content, tick,
and `check-buffer-corruption` after every step. **Size:** L.

### VK-4: Shell swap — kernel-backed edit engine

**Deliverable.** Production `buffer-insert.lisp` mutation engine restructured as an
imperative shell: for each edit, the kernel computes the result **restricted to the
affected region** (touched lines + points registered on them — edits are local, so
the hot path stays O(span), not O(buffer)); the shell materializes it into the
line linked-list. Hooks, read-only checks, interrupts, and undo recording stay in
the shell but call kernel functions for all position/offset computation.

**Modes.**
- `:release` (default): shell fast path, no per-edit checking.
- `:paranoid` (feature flag `:lem-paranoid`, on in the daily-driver build until V1
  has soaked): after every mutation, assert `wf-buffer` via the shim-loaded
  predicate (replaces/absorbs `check-buffer-corruption`).
- `:conformance` (tests only): every mutation additionally mirrored through the
  full kernel and compared.

**Acceptance.** Entire existing rove suite green unmodified (56+ tests); V0-5 fuzz
green in `:paranoid`; editor daily-drivable with no perceptible latency regression
on normal files (spot-check with the PI-1 200KB-line corpus: bounded-time
guarantees from SPEC.md must not regress). **Size:** L. **Risk:** highest
regression surface in the spec; the conformance suite is the mitigation.

---

## Milestone V2 — File I/O & crash safety, verified

### VK-5: EOL/encoding codec kernel

**Deliverable.** `verified/codec.lisp`: pure `decode (bytes, eol) → (lines,
mixed-flag)` and `encode (lines, eol) → bytes` mirroring
`src/buffer/file.lisp` read/write paths (post-DS-6 semantics), over octet lists.

**Proof obligations.** Round-trip byte-identity `encode(decode(bs)) = bs` for
single-EOL inputs (LF/CRLF/CR, with and without trailing newline); no-character-loss
for mixed-EOL inputs (every non-EOL byte of input appears in output, in order);
totality on arbitrary byte input.

**Acceptance.** Book certifies. Differential PBT vs. the production read/write
functions over generated byte files (random EOL mixes, multibyte boundaries); the
existing `tests/eol-roundtrip.lisp` corpus becomes a fixed regression subset.
**Size:** M.

### VK-6: Crash-safety protocol, model-checked in ACL2

**Deliverable.** `verified/crash-safety.lisp`: an operational model of the
DS-2 + DS-3 machinery — abstract filesystem state (target content, temp files,
checkpoint content, fsync'd-or-not distinction), the atomic-save step sequence
(`write temp → fsync → preserve-metadata → rename → delete-checkpoint`), the
checkpoint writer, and a **crash transition enabled after every step**. Because the
state space is finite and small, "model checking" is an ACL2 theorem: an invariant
proved inductive over all transitions (or exhaustive reachability by execution —
either is acceptable, the inductive proof is preferred).

**Proof obligations.**
1. Durability invariant: in every reachable state, including every crash state, the
   disk holds old-content, or new-content, or old-content + a complete checkpoint
   of the unsaved edits. Never a torn target; never loss of both copies.
2. Checkpoint-deletion ordering: the checkpoint is only ever deleted in states
   where the rename has committed (protects against the delete-then-crash window).
3. `encode-path` injectivity (`src/ext/checkpoint.lisp:61-71`): port the function
   verbatim; prove `encode(a) = encode(b) ⇒ a = b`. (Also covers the long-path
   hash fallback: prove the *dispatch* never mixes the two namespaces, i.e. hashed
   names can't collide with encoded names — encoded names always end in the
   original tail, hashed ones are prefixed; state and prove the actual separator
   property, or fix the naming so one holds.)

**Acceptance.** Book certifies. One rove test executes the model's step function
against a real tmpdir performing the same syscall sequence with injected faults
(kill point enumeration via a wrapper), asserting the invariant on the real
filesystem for every kill point. **Size:** M. Highest assurance-per-effort item in
the spec.

---

## Milestone V3 — Input decoding, verified total

### VK-7: Byte-stream → key-event kernel

**Deliverable.** `verified/input-decode.lisp`: the ncurses decode state machine as
a pure function over a list of input items (bytes ∪ `:timeout` markers ∪ curses
keycodes ≥ 256) → list of key events + remaining input. Port
`decode-csi-key`, `decode-csi-modifier`, `collect-bracketed-paste`
(`frontends/ncurses/input.lisp` — already pure and unit-tested) near-verbatim;
model the ESC-timeout branching and `read-csi` accumulation around them.

**Proof obligations.**
1. Totality: for **every** finite input item sequence the decoder terminates and
   returns without error (no hang, no signal — the "fail closed to Escape"
   behavior becomes a theorem, not a comment).
2. Bounded lookahead: the decoder never consumes past a committed sequence's final
   byte (progress + no-overconsumption).
3. Round-trip on the supported set: for every key in the supported table (CSI
   letter/tilde families × modifiers 1–8), `decode(encode(key)) = [key]`.
4. Bracketed paste: for any payload P not containing the terminator,
   `collect(P ++ terminator) = P` — including payloads containing every proper
   prefix of the terminator (the re-injection subtlety hardened in `ada2e53a`/`e739c782`).
5. Keycodes ≥ 256 inside a paste are dropped, never corrupt the payload, never
   abort the paste.

**Acceptance.** Book certifies. Production `input.lisp` refactored so the pure
parts **are** the shim-loaded kernel functions (one source of truth per
Constraint 2); the impure remainder (getch, timeouts) shrinks to a driver.
Differential PBT: random byte soup + real-key encodings + torn/interleaved
sequences fed to the kernel and to the production driver via a byte-feeder stub;
existing `csi-decode`/`bracketed-paste` rove suites stay green. **Size:** M.

---

## Milestone V4 — Event loop & interrupt protocol

ACL2 has no threads; both items are verified as **small-step operational models**:
system state × labeled actions (one per atomic step of each thread), with theorems
quantified over all action interleavings. The model-to-SBCL fidelity gap is the
residue here — narrowed by stress tests, stated honestly in `verified/README.md`.

### VK-8: Interrupt-delivery protocol

**Deliverable.** `verified/interrupt-model.lisp`: model of
`src/buffer/interrupt.lisp` — `*interrupts-enabled*`/`*interrupted*` flags,
`without-interrupts` enter/exit, `check-interrupt` polls, `interrupt` (with and
without `force`) arriving at any interleaving point, editor-interrupt delivery as
an observable action.

**Proof obligations.**
1. No lost interrupt: an `interrupt` arrival is eventually followed by delivery,
   provided the trace eventually exits the outermost `without-interrupts` or polls
   `check-interrupt` (state liveness as: every complete trace containing an arrival
   contains a delivery).
2. No torn state: delivery never occurs between `without-interrupts` enter and exit
   except via an explicit `check-interrupt` poll.
3. Nesting correctness: nested `without-interrupts` regions restore the outer
   enabled-state correctly (the `prev-enabled` logic).
4. `force` bypasses deferral exactly when specified.

**Acceptance.** Book certifies. New rove stress test (currently a coverage gap):
real editor thread executing instrumented `without-interrupts`/`check-interrupt`
loops while another thread fires `bt2:interrupt-thread` interrupts; assert
delivered-exactly-once per arrival and never inside a marked critical section,
across 1k randomized runs. **Size:** M.

### VK-9: Event queue & cross-thread handoff

**Deliverable.** `verified/event-queue-model.lisp`: producer/consumer model of
`concurrent-queue` + `send-event`/`receive-event` semantics including the `:resize`
coalescing rule and thunk auto-execution, with producers = {input thread, timer
thread, background jobs}.

**Proof obligations.** No lost events; per-producer FIFO; resize coalescing
delivers exactly one `update-on-display-resized` for any burst; thunks execute only
in consumer steps (editor-thread-only execution as a model invariant); idle-timer
next-fire computation (`get-next-timer-timing-ms`) never sleeps past a due timer
and never busy-wakes with nothing due.

**Acceptance.** Book certifies. Stress rove test: N producer threads × M events
through the real `concurrent-queue`, assert count/order per producer; timer test
extends the existing simulated-manager tests (`tests/common/timer.lisp`) with
PBT-generated timer sets checked against the model's fire schedule. **Size:** M.

---

## Milestone V5 — Redisplay, verified layout

### VK-10: Width algebra

**Deliverable.** `verified/width.lisp`: `char-width`/`string-width`/`wide-index`
(`src/common/character/string-width-utils.lisp` — pure today) ported as the single
source of truth, with the eastasian/icon tables as certified constant data
(generated by the existing `scripts/gen-eastasian.lisp`, emitted in both loadable
forms).

**Proof obligations.** Additivity: `string-width(a++b, start-col c) =`
the fold composition (width is a left fold — state it as such); monotonicity in
`end`; `wide-index` is the exact inverse: it returns the least index whose
cumulative width exceeds the goal (Galois connection with `string-width`); tab
stops: width after a tab is the least multiple of tab-size strictly greater than
the current column.

**Acceptance.** Book certifies; production package re-exports the shim-loaded
functions; `tests/string-width-utils.lisp` (incl. TF-4's emoji/ZWJ cases) green
unchanged. **Size:** S-M.

### VK-11: Layout kernel (wrapping & clipping)

**Deliverable.** `verified/layout.lisp`: pure versions of
`separate-objects-by-width` (+ `explode-object` splitting) and
`clip-objects-to-display-range` (`src/display/physical-line.lisp:301-332,610-657`)
over an abstract drawing-object type (width + content only — text objects; images
etc. are opaque unbreakable widths).

**Proof obligations.**
1. Content preservation: concatenating the emitted physical rows reproduces the
   input object sequence's content exactly — nothing dropped, nothing duplicated.
2. Width bound: every emitted row fits `view-width`, except a row whose sole
   object is a single unbreakable unit wider than the view (state the exception
   precisely).
3. Termination: `explode-object` halving reaches single characters (measure:
   object length), so wrapping terminates on all inputs including width-0 runs.
4. Clip correctness: the clipped range has bounded width and, when the cursor
   column is supplied, contains it (the auto-scroll postcondition).

**Acceptance.** Book certifies; production functions replaced by shim-loaded
kernel + thin adapters over real drawing-object classes; differential PBT over
generated object lists (random widths incl. 0 and > view-width). **Size:** M.

### VK-12: Screen-matches-buffer & cache soundness (PBT, not proof)

**Deliverable & properties.** Two harness suites (no new ACL2 book — the
composed pipeline crosses too much CLOS to port; this is the one scope item
verified empirically only, by design):
1. End-to-end: for generated buffers + window geometries, render via
   fake-interface twice — with caches enabled and with caches force-invalidated
   every frame — and assert identical emitted `render-line` calls across a random
   edit/scroll/resize script (cache soundness modulo fingerprint collisions, which
   the fingerprint being a hash makes irreducible; documented).
2. Projection: concatenated visible text of rendered rows equals the buffer
   region under the defined projection (tab expansion, control-char replacement,
   wrap markers stripped) — the "what you see is what's in the buffer" property.

**Acceptance.** 1k random frames green in CI; the existing
`tests/display-cache.lisp` invariants (eviction, attribute-mutation detection)
folded in as fixed cases. **Size:** M.

---

## Sequencing

```
V0 (toolchain)  →  VK-1 → VK-2 → VK-3 → VK-4   (buffer kernel, strictly ordered)
                →  VK-5, VK-6                   (file I/O — after VK-1, independent of VK-3/4)
                →  VK-7                          (input — independent of buffer track)
                →  VK-8, VK-9                    (event loop — independent)
                →  VK-10 → VK-11 → VK-12         (redisplay — VK-10 first, needs nothing else)
```

Parallelizable across tracks; strictly ordered within. VK-2 is the long pole —
start it first and let the independent tracks (VK-6, VK-7, VK-10) land early wins.

**The goal is met when:** every book under `verified/` certifies via
`scripts/run-proofs.sh`; every differential/stress/PBT suite above is green in CI
alongside the full pre-existing rove suite; the shell swap (VK-4) and one-source
refactors (VK-7, VK-10, VK-11) are the code actually running in the daily-driver
binary; and `verified/README.md` states the trust base and the VK-3.3 tick
decision.

**Tracking:** GitHub milestones `V0 Toolchain`, `V1 Buffer kernel`, `V2 Crash
safety`, `V3 Input`, `V4 Event loop`, `V5 Redisplay` on `yathxyz/lem`, one issue
per VK item linking to its section here.

## Standing risks

- **Proof effort is the schedule.** VK-2/VK-3 are real theorem-proving work
  (marker algebra + undo laws); expect ACL2 to demand lemma scaffolding an order
  of magnitude larger than the functions themselves. Mitigation: the differential
  PBT suites land first in each item and have independent value even if a proof
  stalls; a stalled proof downgrades the item to "PBT-pinned, proof pending" in
  the tracker rather than blocking the milestone — explicitly, never silently.
- **ACL2-on-SBCL bring-up** (V0-1) may fight the distro; fallback is building
  ACL2's supported CCL solely as the certification host (the *kernel sources*
  still run on SBCL in Lem either way; certification host ≠ execution host does
  not violate the one-source rule).
- **Shim fidelity** (V0-3): a shim bug could make certified code behave
  differently in-image. Mitigation: shim is tiny, reviewed line-by-line, and every
  kernel book gets at least one in-image rove test exercising the same functions
  ACL2 certified.
- **Performance of the kernel-backed shell** (VK-4): locality restriction is the
  design answer; the PI-1 bounded-time acceptance is the regression tripwire.
- **Concurrency model gap** (V4): theorems hold of the model, SBCL's
  `interrupt-thread` has its own subtleties (e.g. interrupts landing in foreign
  code). The stress tests are the empirical bridge; the residue is documented,
  not hidden.
- **Soft-divergence drift:** cherry-picks from upstream now require conformance
  suites to pass against changed production code — which is exactly what they are
  for; a cherry-pick that breaks a kernel property is a finding, not a nuisance.
