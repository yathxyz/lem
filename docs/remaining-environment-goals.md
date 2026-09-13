# Linux Lisp environment: delivery status and remaining boundaries

The user authorized implementation through successive goals and parallel agents.
The canonical editor checkout is `lem-integration`, branch
`integration/linux-lisp-environment`; its companion is
`~/proj/nix/computer-lem-integration`, branch `integration/lem-daemon`.
Original worktrees, installed profiles/services, and user documents remain
preserved. No deployment or default-editor cutover is part of these goals.

## Goals and evidence

| Goal | Result |
| --- | --- |
| 1. Consolidate the configured native daemon | Complete. One Common Lisp client/server path, initialization failure propagation, readiness, native visits and Git editor routing. |
| 2. Independent styled clients and text recovery | Complete. Terminal and SDL frames, client ownership, persistent shared buffers, private JSON checkpoints and standalone inspection. |
| 3. Shared Lisp toolkit and failure recovery | Complete. Managed jobs, compilation, native Git lifecycle, proposals, bounded output/cancellation and interrupted records without replay. |
| 4. Recoverable agent workspaces | Complete. Lisp agent loop/tools, durable decisions, drafts, historical candidates, exact submission receipts and explicit bounded storage cleanup. |
| 5. Notes and daily workflows | Implementation and focused/configured native checks complete; final broad VCS gate is running. |
| 6. Reviewable cutover | Final profile retained and actual binaries tested; final evidence/documentation preparation in progress. Live activation is excluded. |

The final tested source snapshot is `d941801c7`. Subsequent documentation commits
do not change that build identity. Validation is retained outside the worktrees:

- `../.recovery/2026-09-10-lem-integration/validation/toolkit/`
- `../.recovery/2026-09-10-lem-integration/validation/agent-recovery/`
- `../.recovery/2026-09-10-lem-integration/validation/notes-daily/`
- `../.recovery/2026-09-10-lem-integration/validation/final-candidate/`

## Notes and daily workflow integration

The pinned structured-notes semantic library passes 393 tests with dependency
isolation; its selected public API contains 1,198 implemented exports. The
minimal notes adapter passes 12 focused source groups. It uses startup-owned
workspace roots and planning-time buffer identity, filename, revision and source
checks before unsaved edits through the shared proposal API. Explicit LSM daily,
journal, capture and ID commands preserve the existing Org defaults. No broad
CalDAV transport or mixed-notes adapter was adopted, and no real notes or remote
calendar data was used during acceptance.

Native acceptance exposed and fixed two concrete daily-use failures: Legit panes
could delete another client's windows or leave a progress popup attached to a
freed pane; asynchronous REPL prompts could leave the next expression outside
the input area. Per-frame pane ownership and tail-following listener windows
now preserve peer navigation and the next native key destination.

Configured gates pass notes (36 reported checks), independent SDL Legit (14),
project/shell/REPL workflows (9), native Git (27), agent recovery (87), daemon (25),
compilation (17), and proposals (12). The actual retained computer profile passes
agent (87), notes (36), daily tools (9), terminal/SDL (15), and private service (5)
checks. Agent counts include repetitions across startups: 87 reported checks are
62 distinct descriptions. Historical failing runs and source overlays remain
labeled separately from rebuilt configured/actual-profile acceptance.

## Reviewable cutover

The retained candidate is
`/nix/store/59xmq7z6m0jjmk5fdzprmk44jhk8pllf-lem-yath-profile`, rooted at
`../.recovery/2026-09-10-lem-integration/validation/final-candidate/prepared-profile-v1`.
The shared Nix module prepares both headless and desktop homes. Both built service
units pass verification, and the actual candidate passes private readiness,
SIGKILL restart, interrupted-job recovery and deliberate shutdown checks. The
profile helper passes 14 disposable-profile checks including exact-output
installation, rollback and failure preservation.

Follow the companion checkout's
[cutover instructions](/home/yanni/proj/nix/computer-lem-integration/docs/lem-daemon-rollout.md)
for publishing/pinning, configuration ownership, activation, rollback and recovery.
The current host uses NixOS-managed headless Home Manager; the standalone desktop
activation is a different target. Complete activation packages and their unrelated
configuration changes remain a deployment review step. No installed profile,
live service, editor default, user note or remote account has been changed.

## Boundaries that remain

- Full `lem-tests` has six pre-existing failing suites and 14 assertion failures/
  errors, independently reproduced at the prior milestone. See the
  [baseline audit](core-test-baseline-2026-09-13.md). A clean whole-repository gate
  requires repairing that test/conformance debt.
- Recovery restores checkpointed text, drafts, candidates and job/session records;
  it does not reconstruct arbitrary shell/REPL execution stacks or undo history.
  Edits since the last completed checkpoint remain vulnerable. External actions
  are never automatically replayed after a crash.
- SDL renders a styled character grid. Embedded images/widgets are not provided
  by this protocol. Synchronous minibuffer prompts temporarily queue peer input.
- Generic typeout help/error popups still have global display state. The focused
  Legit acceptance establishes pane ownership; it does not establish independent
  ownership for every generic popup.
- Broad CalDAV integration, notes migration, Windows daemon support and full Emacs
  package parity remain outside this delivered candidate. Approved external
  process tools are not a filesystem sandbox.

These limits matter when deciding whether the candidate can replace the current
editor for a particular day. Passing the recorded workflows is not a claim of
complete Emacs equivalence.
