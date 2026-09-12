# Native Lisp agents in the configured editor

The Linux configuration starts a persistent native agent manager alongside the
named daemon and its managed jobs. The agent loop, tool validation, permission
decisions, editor tools, process supervision and views run in Common Lisp. Curl
provides HTTPS transport; Git and other approved programs remain ordinary child
processes. This workflow does not require an external agent executable or tmux.

This is an integration checkout, not an activated user profile. The original
worktrees, installed editor and deployed service are preserved.

## Human controls

The configured Vi leader has a native agent group at `SPC A`:

| Key | Command | Effect |
| --- | --- | --- |
| `SPC A n` | `agent-new-session` | Choose an absolute project root and model; create a session. |
| `SPC A l` | `agent-session-list` | Inspect retained sessions. |
| `SPC A c` | `agent-compose` | Open a separate editable message buffer. |
| `SPC A d` | `agent-decisions` | Review concrete pending tools or questions. |
| `SPC A i` | `agent-interrupt` | Invalidate current work and request cancellation. |
| `SPC A r` | `agent-resume` | Deliberately process retained queued messages. |
| `SPC A p` | `buffer-proposal-list` | List shared edit proposals. |
| `SPC A o` | `buffer-proposal-open` | Open a proposal by its exact ID. |
| `SPC A e` | `agent-activate-file-buffer` | Deliberately run normal file mode/hooks for a buffer prepared by a file tool. |
| `SPC A h` | `agent-retained-reviews` | Inspect historical edit candidates for the current session. |
| `SPC A s` | `agent-restage-retained-review` | Capture the selected live region, choose a historical candidate, and create a fresh proposal. |
| `SPC A H` | `agent-journals` | Inspect session capacity, stored history, and deliberate cleanup. |
| `SPC A D` | `agent-draft-list` | Inspect, explicitly restore, or discard durable composer checkpoints. |
| `SPC A j` | `jobs-list` | Inspect bounded job history and deliberate cleanup. |
| `SPC A R` | `lem-yath-agent-recovery-report` | Inspect session recovery failures, draft storage health, and session capacity. |

In a composer, `C-c C-c` submits. The composer clears only after durable
acceptance, and only if its captured contents have not changed. In a decision
view, `a` allows, `d` denies, and `e` answers a question. Exact session and decision
identities are attached to actionable text. Truncated text cannot grant approval.
Closing a view or disconnecting a client does not close its session, answer a
decision, or cancel an already submitted message. Explicit `agent-close-session`
permanently closes the session.
`C-c C-z` opens a session transcript from a composer, historical candidate view,
or newly restaged proposal review.

Each client retains its own frame and focus. Background output redraws idle
clients too. Peer resize and redisplay switch implementation, buffer and point
together, then restore the previous client before its next input.

## Provider and tools

The initial provider is OpenRouter, matching the existing configuration. The
default model is `openrouter/auto`, overridable by `LEM_AGENT_MODEL` or the model
chosen when creating a session. The matching `OPENROUTER_API_KEY` is read lazily
on a provider worker. It is not placed in the request's process arguments,
session journal or managed process tool environment. There is no OpenAI-key
fallback to OpenRouter. Nix pins curl and the CA bundle. The configured request
limit is 120 seconds and 4096 output tokens per provider round.

`list_directory` and `read_file` inspect literal relative paths within the chosen
project, reject symlink traversal and special files, and prefer live unsaved
buffer text. `propose_edit` consumes a bounded revision token and exact original
text to stage a shared proposal. It does not apply or save it. The human reviews
and applies through the existing proposal UI; concurrent buffer changes cause a
conflict, and an accepted edit has one undo step. Prepared file buffers run no
normal mode or file hooks until the human explicitly activates them.

`run_process` requires approval of its exact argv, directory, input and limits.
The process executes through the shared Lisp job manager. Its working directory
must be inside the session root, but an approved program is **not filesystem
sandboxed**. Cancellation targets the managed process group, including ordinary
children. A program that deliberately creates another session/process group or
enters an uninterruptible kernel wait is outside that cleanup guarantee.

The core bounds rounds, tools, streamed output, arguments/results, queued messages,
workers and retained history. The default history retains at most 16 complete
turns within 512 KiB. Views also have rendering and concurrency bounds. See the
[core contract](../extensions/agent/README.md),
[OpenRouter transport](../extensions/agent/OPENROUTER.md), and the source tool
schemas for exact limits. Provider failures persist a safe category and numeric
status instead of arbitrary printed error arguments.

## Recovery and ownership

Session journals live under the named daemon's private recovery directory in
`agents/`. Startup acquires an exclusive manager lease, registers the configured
provider and tools, restores journals, and completes reconciliation before
publishing the default manager. Malformed journals remain unchanged and appear
in the recovery report.

A daemon crash interrupts old active turns, cancels their pending decisions,
retains queued messages and never replays uncertain effects. A started tool whose
result was lost is reported as having an unknown outcome. Resume is an explicit
human action. Orderly shutdown has the same ownership boundary: `close-manager`
stops journal actors while preserving resumable sessions; `close-session` is the
separate permanent human action. The manager lease remains held until all journal
actors stop, including when the final checkpoint fails. Arbitrary uncooperative
provider/tool Lisp workers cannot keep that lease or publish late results.

Retained edit candidates live outside rolling transcript history. Their arguments
are checkpointed before the staging executor runs. After restart they are inert
historical records: old proposal IDs and revision tokens do not establish current
applicability or whether an earlier proposal was applied. A human selects a live
region, explicitly restages a fresh proposal, and reviews acceptance separately.
See [historical candidates](../extensions/agent/EDIT-RECOVERY.md).

Managers now reserve at most 64 session slots and 256 job slots by default.
Existing overflow stays on disk with bounded inventory and inspection. Unknown
outcomes are not automatically evicted. Explicit whole-history cleanup checks
the exact inspected file fingerprint, writer lifetime and uncertainty
acknowledgement. An unwritten initial reservation remains visible; a failed
deletion sync retains its slot until deliberate exact retry confirms absence.
See [session retention](../extensions/agent/RETENTION.md) and
[managed jobs](managed-jobs.md). Durable submission receipts additionally survive
transcript trimming, so draft recovery can distinguish accepted input from unsent
text without matching transcript contents.

Unsent composer text and point use the separate `agent-drafts/` namespace, with
exact session and clarification metadata. Text changes queue asynchronous
checkpoints; `C-c C-s` requests a checkpoint and reports whether it has reached
durable storage. Inspection shows the current draft and exact submitted text
separately when newer edits followed a submission. Restore opens an unnamed
buffer without submitting it. An accepted unchanged revision, missing session,
or cancelled question restores for inspection only. The store retains at most
32 drafts, each with 65,536 text characters, within 1 MiB per encoded record and
16 MiB total; exhaustion requires deliberate cleanup instead of silent eviction.
See [durable drafts](../extensions/agent/DRAFTS.md).

If draft storage is damaged, startup preserves its files and continues for
editing, jobs, and session inspection. Mandatory durability blocks new composers;
the recovery report explains the unavailable store. Generic text recovery
excludes owned composers because text alone cannot establish submission authority.
Edits not yet checkpointed remain vulnerable to a crash.

Shutdown drains draft snapshots and admitted submissions while core actors are
still running, then closes those actors and the shared job manager. Opening or
refreshing a view does not initialize storage or wait for provider/tool work on
the editor thread. The configured startup and exit phases are explicit blocking
lifecycle boundaries.

Proposal objects and revision-token identity are still image-local. Session
recovery preserves historical candidates independently of history eviction, but
does not recreate a valid old proposal or claim that its text was saved.

## Verified on 12 September 2026

The Nix `native-agent` check uses two actual native terminal clients and the
configured image. It loads only its test fixture; no product code is injected.
Fake providers make the gate deterministic and require no credentials or network.
It covers streams on both terminals, independent focus, approval after client
loss, exactly-once decisions, denial without effects, process/child interruption,
queued resume, unsaved-file proposals, concurrent edits, native accept/undo,
SIGKILL recovery, explicit resume, orderly restart and permanent human closure.

Configured package `xcn0bjn333hnjvx9idcgd3lz9lh0xgip-lem-yath` passes that full
gate, the daemon gate with peer redisplay regressions, and managed compilation.
Core source tests pass 23 groups, including shutdown races, failed checkpoints,
lease ownership and uncooperative workers. A negative control with the old
peer-context behavior fails the new next-key destination regression.

The updated daemon also passes all 15 native terminal/SDL display checks on an
isolated X display: two GUI frames, shared edits, independent Vi state and prompts,
Unicode clipboard input, resize/mouse routing, client loss and daemon death. The
two-client screenshot is retained with the acceptance log.

The prepared profile built through the isolated Nix computer configuration also
passes the full native agent suite. Its private transient user-service check
verifies native manager readiness, a live managed job, daemon crash/restart,
interrupted recovery without replay, and deliberate shutdown staying stopped.
The profile is retained under `validation/native-agent/prepared-profile-v1`;
the installed profile and `lem.service` were not changed.

One separate real OpenRouter check passed on the preceding configured package:
one provider round, the requested `LEM_NATIVE_OK` reply, zero tool calls, and a
durable completed turn. It used only a synthetic empty project. This verifies
live transport and core completion, not model quality or real-provider tool use.

Evidence is archived outside the checkout in
`/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/native-agent/`.
Run `nix run .#native-agent-test` from `extensions/lem-yath` with the intended
local Lem input override, or build `checks.x86_64-linux.native-agent`.

## Recoverable workspaces verified on 13 September 2026

The canonical runtime through `e5cf77f4f` passes the expanded Nix native agent
gate: 87 reported checks, 62 distinct descriptions across four daemon starts.
Candidates survive transcript trimming and SIGKILL with exact arguments/results;
native inspection opens no files, stale restaging is refused, and a fresh human
selection produces a separately accepted proposal. Unsent drafts survive restart,
restore without submission, submit deliberately once, and require confirmed
cleanup. Damaged draft storage leaves core/jobs ready, blocks composers, reports
the failure, and preserves the corrupt synthetic journal byte for byte.

Source tests pass 39 core, 13 draft, 13 agent UI, 11 historical review, 12 session
retention, 4 session inventory UI, 19 job, 5 job UI, 9 provider, 7 process-tool,
and 14 shared recovery groups. Configured daemon (25), compilation (17), Git
rebase (27), and proposal (12) checks pass too. The broader toolkit VCS gate
previously passed 275 reported workflow checks and 377 static assertions; its
evidence remains in the adjacent `validation/toolkit/` archive.

This acceptance exposed and fixed a real journal/parser defect: JSON `false`
became `null` after restart, and empty arrays were also ambiguous. Journal,
provider, and draft parsers now preserve those types explicitly, independently
of ambient parser settings. Source regressions fail on the preceding readers
and pass with the fix. Known true clarification receipts retain their `T` API.

The Nix computer profile `jgcfnmcs2kpl2yyvaizxr0kxdsac6v40-lem-yath-profile`
passes the same 87 native checks through its actual binaries, all 15 terminal/SDL
display checks, and five private user-service checks including crash/restart and
deliberate shutdown. It is retained under
`validation/agent-recovery/prepared-profile-v3`. The service check requires the
native core and mandatory open draft store on initial startup and after restart.
No installed profile or deployed service was changed. The original five worktrees
and all 13 archived prototype files still match the preservation archive.

Passing and failed logs, exact derivations, screenshots and the final acceptance
manifest are in `validation/agent-recovery/` beside the earlier native evidence.
Notes/daily workflows and Legit's shared display state across independent frames
remain prerequisites for a reviewable editor cutover.
