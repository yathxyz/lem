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
| `shim.lisp` | Dual-load shim (V0-3). Lets the ACL2 books load in a plain SBCL image. Part of the trust base — under 200 lines, every reinterpreted construct listed in its header. **Not a book**; the proof runner skips it. |
| `README.md` | This file. |

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

## Proof status

All theorems in every book under `verified/` certify with real ACL2 (no
`skip-proofs`, `defaxiom`, trust tags, or `:program`-mode kernel functions). No
theorem is PROOF PENDING.

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
