# Remaining Linux Lisp environment goals

The user authorized implementation through successive goals and parallel agents.
Original worktrees, installed profiles/services, and user documents remain
preserved. No deployment or default-editor cutover is part of these goals.

## Completed toolkit validation

The shared Lisp job runtime, configured compilation, native Git ownership,
proposal API, standalone recovery and private service checks are implemented and
tested. Native Git passes 27 checks. The broader configured VCS gate passed 275
reported workflow checks and 377 static assertions. Its legacy driver now waits
for native asynchronous file visits and replaces entire remote URL prompts.
Failed and passing evidence and original-worktree preservation are archived.

## Completed recoverable agent workspaces

The native Lisp agent stage is integrated into the canonical checkout. Retained
candidates live outside rolling history; recovery requires a human's fresh live
selection and separate proposal acceptance. Composer checkpoints preserve exact
session/decision metadata, current unsent text and submitted text independently.
Core submission receipts resolve crash ambiguity without replay. Session and job
admission reserve bounded slots, while native inventory/inspection provides
explicit fingerprint-checked cleanup with protection for active/uncertain work.

The configured native agent gate passes 87 reported checks (62 distinct
assertion descriptions across four startups), including actual candidate/draft
inspection, restaging, submission, cleanup and degraded draft startup. The
prepared computer profile passes those same 87 checks through its actual binaries,
15 native terminal/SDL checks and five private service checks. Configured daemon,
compilation, Git and proposal gates and the relevant source suites pass.
The configured gate exposed JSON false/null and empty-array loss; all three
relevant parsers now preserve types and regression tests cover clarification
receipt reconciliation as well as candidate results. Evidence, failed attempts,
exact derivations and a retained profile are in `validation/agent-recovery/`.

## Adopt notes and verify daily workflows

Follow the existing notes/CalDAV component map. Adopt only the selected components
and validate them in isolation before adapter integration. Preserve Org defaults;
Markdown support is opt-in. Exclude the identified diary percent regression. Do
not merge the old branch's editor, frontend or Nix configuration wholesale, and
do not touch real notes or remote CalDAV data during acceptance.

Exercise file visiting, persistent buffers, shell/REPLs, compilation, Git,
projects, notes and agent sessions through native terminal and SDL clients.
Specifically verify Legit's remaining global display state across independent
frames. Document concrete gaps and avoid claiming full Emacs equivalence from a
feature list or synthetic tests alone.

## Prepare a reviewable cutover

Build and retain the final Nix profile; inspect the generated user service and
repeat private readiness/crash/stop tests. Provide exact activation, emacsclient
replacement, rollback and recovery instructions, with the original configuration
available for comparison. Present that concrete result before any live service,
profile or default-editor activation.
