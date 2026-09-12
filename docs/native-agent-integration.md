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
| `SPC A j` | `jobs-list` | Inspect the shared process registry. |
| `SPC A R` | `lem-yath-agent-recovery-report` | Inspect rejected session journals from startup. |

In a composer, `C-c C-c` submits. The composer clears only after durable
acceptance, and only if its captured contents have not changed. In a decision
view, `a` allows, `d` denies, and `e` answers a question. Exact session and decision
identities are attached to actionable text. Truncated text cannot grant approval.
Closing a view or disconnecting a client does not close its session, answer a
decision, or cancel an already submitted message. Explicit `agent-close-session`
permanently closes the session.

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

Shutdown closes agent actors before closing the shared job manager. Opening or
refreshing a view does not initialize storage or wait for provider/tool work on
the editor thread. The configured startup and exit phases are explicit blocking
lifecycle boundaries.

Proposal objects and revision-token identity are still image-local. Session
history can retain candidate arguments, but it does not recreate a valid old
proposal or preserve candidates after history eviction. A durable candidate
review/recovery workflow is required before daily use. Unsent composer recovery
also needs session metadata beyond the existing text-buffer checkpoint.

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

One separate real OpenRouter check passed on the preceding configured package:
one provider round, the requested `LEM_NATIVE_OK` reply, zero tool calls, and a
durable completed turn. It used only a synthetic empty project. This verifies
live transport and core completion, not model quality or real-provider tool use.

Evidence is archived outside the checkout in
`/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/native-agent/`.
Run `nix run .#native-agent-test` from `extensions/lem-yath` with the intended
local Lem input override, or build `checks.x86_64-linux.native-agent`.

Remaining acceptance includes durable candidates and unsent composers, global
job/session retention, notes/daily workflows, and Legit's shared display state
across independent frames. The frozen toolkit's broader legacy VCS gate remains
under diagnosis. These are prerequisites for a reviewable editor cutover.
