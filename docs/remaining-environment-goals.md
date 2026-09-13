# Linux Lisp environment: delivery status and remaining boundaries

The canonical editor checkout is `lem-integration`, branch
`integration/linux-lisp-environment`. The user subsequently authorized complete
deployment on `ex44`, reconciliation into the Nix repository's `master`, and
default-editor cutover. Current deployment configuration and instructions live in
[`~/proj/nix/computer`](/home/yanni/proj/nix/computer/docs/lem-daemon-rollout.md).
Exact activation status, source pins, generations and live acceptance are recorded
in `/home/yanni/proj/nix/.recovery/2026-09-13-lem-deployment/`.

The six goals and retained candidate below document the earlier preparation
milestone. At that milestone installed profiles/services and defaults were
unchanged. `computer-lem-integration` is its historical preparation checkout;
use the current Nix `master` for deployment. Original development worktrees and
user documents remain preserved.

## Goals and evidence

| Goal | Result |
| --- | --- |
| 1. Consolidate the configured native daemon | Complete. One Common Lisp client/server path, initialization failure propagation, readiness, native visits and Git editor routing. |
| 2. Independent styled clients and text recovery | Complete. Terminal and SDL frames, client ownership, persistent shared buffers, private JSON checkpoints and standalone inspection. |
| 3. Shared Lisp toolkit and failure recovery | Complete. Managed jobs, compilation, native Git lifecycle, proposals, bounded output/cancellation and interrupted records without replay. |
| 4. Recoverable agent workspaces | Complete. Lisp agent loop/tools, durable decisions, drafts, historical candidates, exact submission receipts and explicit bounded storage cleanup. |
| 5. Notes and daily workflows | Complete. Selective semantic core and explicit notes adapter; independent Legit panes and daily tools; nine configured gates pass, including the full VCS workflow. |
| 6. Reviewable cutover | Complete. Exact tested profile retained, both service units verified, installation/rollback helper checked, and activation/recovery instructions recorded. Live activation is excluded. |

The preparation milestone tested runtime snapshot `b44f88a68`; its documentation
and VCS fixture follow-ups did not change that product code. Deployment adds
native visible-client edit completion and orderly shutdown fixes, with separate
acceptance in the deployment record above. Earlier validation is retained outside
the worktrees:

- [Shared toolkit evidence](/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/toolkit/)
- [Agent recovery evidence](/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/agent-recovery/)
- [Notes and daily acceptance](/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/notes-daily/final-acceptance.json)
- [Final candidate evidence](/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/final-candidate/final-acceptance.json)

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
the input area. Reused Git collectors also needed a scoped read-only override,
and remaining Git message/remote/merge callers needed exact context ownership. Per-frame pane ownership and tail-following listener windows
now preserve peer navigation and the next native key destination.

Configured gates pass notes (36 reported checks), independent SDL Legit (14),
project/shell/REPL workflows (9), native Git (27), agent recovery (87), daemon (25),
compilation (17), and proposals (12). The actual retained computer profile passes
agent (87), notes (36), daily tools (9), terminal/SDL (15), Git caller ownership
(29), and private service (5) checks. Agent counts include repetitions across startups: 87 reported checks are
62 distinct descriptions. Historical failing runs and source overlays remain
labeled separately from rebuilt configured/actual-profile acceptance.

The final broad VCS gate passes 275 workflow checks and 377 static assertions
at fixture revision `92679c6d6`, using real synthetic repositories. Earlier runs
exposed stale completion submissions, readiness observations and fixed-delay
assumptions in the test driver; the corrected fixture submits actions once and
waits for fresh observations. These fixture corrections do not change the tested
runtime. Failed runs and focused controls are retained with their limits in the
acceptance record; counts from separate gates are not a unique-test total.

## Earlier prepared cutover

The retained candidate is
`/nix/store/87wp1xjkfyv7y1ba6xx13wkahcldbph2-lem-yath-profile`, rooted at
`../.recovery/2026-09-10-lem-integration/validation/final-candidate/prepared-profile-v2`.
The shared Nix module prepares both headless and desktop homes. Both built service
units pass verification, and the actual candidate passes private readiness,
SIGKILL restart, interrupted-job recovery and deliberate shutdown checks. The
profile helper passes 14 disposable-profile checks including exact-output
installation, rollback and failure preservation.

Follow the current Nix checkout's
[deployment instructions](/home/yanni/proj/nix/computer/docs/lem-daemon-rollout.md)
for publishing/pinning, configuration ownership, activation, rollback and recovery.
The current host uses NixOS-managed headless Home Manager; the standalone desktop
activation is a different target. At the preparation milestone, complete activation
packages and their unrelated changes remained a deployment review step; no installed
profile, live service, editor default, user note or remote account had been changed.

The preparation preservation checks compare original Lem heads, status and tracked patches, plus
all 13 archived agent prototype files byte-for-byte. They also compare the original
Nix checkout's HEAD/status and installed profile/service state; pre-existing
untracked Nix file contents have no initial byte-hash baseline and were not compared.

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
- Generic typeout help/error popups and `lem/peek-source` previews still have
  global display state. Grep, xrefs/LSP and project source previews use the latter.
  The focused Legit acceptance establishes ownership for its panes; independent
  ownership of these generic popups and previews remains unverified.
- Broad CalDAV integration, notes migration, Windows daemon support and full Emacs
  package parity remain outside this delivered candidate. Approved external
  process tools are not a filesystem sandbox.

These limits matter when deciding whether the candidate can replace the current
editor for a particular day. Passing the recorded workflows is not a claim of
complete Emacs equivalence.
