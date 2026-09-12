# Remaining Linux Lisp environment goals

The user authorized implementation through successive goals and parallel agents.
Original worktrees, installed profiles/services, and user documents remain
preserved. No deployment or default-editor cutover is part of these goals.

## Finish toolkit validation

The shared Lisp job runtime, configured compilation, native Git ownership,
proposal API, standalone recovery and private service checks are implemented and
tested. Native Git passes 27 checks. Finish the broader configured VCS gate;
diagnosis must distinguish product defects from the legacy driver's assumptions
about synchronous file visits. Preserve failed and passing evidence.

## Complete recoverable agent workspaces

Integrate the tested native provider/tools/UI configuration into the canonical
checkout after the toolkit gate. The configured native agent, daemon, compilation
and SDL gates already pass in the isolated agent integration checkout. One live
OpenRouter round has passed; broader model quality is not implied.

Add durable edit candidates outside rolling transcript history in the existing
session journal and actor. Retain origin, exact original/replacement arguments,
and bounded historical results before launching the staging executor. Reserve
capacity first, reject explicitly on exhaustion, and never silently evict a
candidate. Use 16 records, 64 KiB per record, and 512 KiB total per session only
after checking these fit all enclosing journal and JSON limits. Applying or
rejecting a live proposal does not prove its text reached recovery storage, so
archive removal must remain explicit.

After restart, candidates are unbound historical reviews. Old proposal IDs,
buffer names, inspection tokens and revision numbers cannot prove applicability
to a new image. A human selects a current buffer region and explicitly creates
a new proposal, then reviews and accepts separately. Require exact original text
and revalidate identity, revision, generation and text after prompts. Never search
for matching text, open files, run mode hooks or apply on recovery. Surrounding
unsaved buffers continue to use independent text checkpoints.

Add unsent-composer recovery with exact session/decision metadata and explicit
restoration. A restored draft must never submit itself or answer an old cancelled
decision. Distinguish unsent drafts from durably accepted submissions, including
crashes between acknowledgement and view cleanup.

Bound long-lived job/session registries and stored history with an explicit,
inspectable retention policy. Keep active work and uncertain outcomes protected;
make capacity exhaustion and deliberate cleanup visible to the human.

Acceptance must cover candidate survival beyond transcript trimming, quota and
write failures before executor publication, crash before/after staging/results,
no replay or file hooks, explicit fresh restaging, stale/ABA/empty selections,
previously applied candidates, malformed records, draft recovery and ownership.
Repeat relevant configured client/provider/tool/recovery gates after integration.

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
