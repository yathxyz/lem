# Native agent buffers

`lem-agent/ui` is an optional system depending on `lem-agent/drafts`, `lem/core`,
and the opt-in `lem-daemon/recovery` definitions (loading does not enable recovery).
It registers no provider, tool, daemon hook, global key binding, or credential
lookup. The host creates/restores the manager on a startup worker, registers its
provider and tools, then supplies configuration:

```lisp
(setf lem-agent/ui:*default-manager* manager
      lem-agent/ui:*default-provider* "openrouter"
      lem-agent/ui:*default-model* configured-model)
```

The provider name defaults to `"openrouter"`; the manager and model default to
`nil`. A new session always asks the human for an absolute project root and model.
The root prompt does not scan the filesystem or require that a missing project
still exists. The UI never reads credentials or starts a provider on load.

## Commands

`M-x agent-new-session` creates a session and opens its transcript.
`M-x agent-session-list` lists the configured manager's sessions; `Return` on a
row opens another transcript. The list is refreshed explicitly with `g`.

Transcript and decision views share these keys:

| Key | Action |
| --- | --- |
| `c` | Open a separate editable message draft |
| `p` | Open the session's decisions |
| `g` | Refresh this view |
| `i` | Interrupt the session's current operation |
| `r` | Deliberately resume retained queued messages |
| `x` | Close the session itself |
| `q` | Kill only this view |

In a decision view, place point inside the displayed pending decision:

| Key | Action |
| --- | --- |
| `a` | Allow that permission decision |
| `d` | Deny that permission decision |
| `e` | Open an editable answer to that clarification |

Each actionable block includes the decision ID, kind, status, question, tool name,
complete JSON arguments, and choices. Truncated blocks have no action target.
Actions use the exact session object and decision ID attached to that block;
they do not search for whichever decision happens to be pending later. The core's
durable once-only resolution settles competing views and rejects stale answers.
Clarification answers never use a synchronous prompt waiting on an agent question.

A composer contains only its editable message or answer. Its name identifies the
session (and clarification ID for an answer). `C-c C-c` submits deliberately;
`C-c C-s` displays its receipt status. The modeline also shows pending, accepted,
stale, or failed status. While a receipt is pending, further typing remains possible
but another submission from that composer is refused. Durable acceptance clears
the draft only when its modification tick still matches the submitted revision.
Newer edits, even edits later undone, are retained. Rejections retain the draft.

## View and operation ownership

All public buffer functions run on the editor thread. These return new buffers
without selecting or displaying a window:

```lisp
(lem-agent/ui:show-session session)
(lem-agent/ui:show-decisions session)
(lem-agent/ui:show-composer session)
(lem-agent/ui:show-session-list manager)
```

For programmatic input, fill a composer on the editor thread, then call
`submit-composer buffer`. `composer-status buffer` returns its latest status.
Every transcript call creates an independent view, so clients can use separate
buffers when they need separate positions. Ordinary buffer deletion unsubscribes
and retires its view worker; it never interrupts, closes, approves, or answers.
Closing a composer does not withdraw a submission already issued. A callback for
a killed view cannot affect a replacement buffer, even if it has the same name.

Each live view has one worker that copies cached session snapshots and formats
bounded text. Actor subscriptions only mark it dirty and signal that worker.
At most one redraw per view is queued for the editor; further events coalesce.
The editor applies that prepared text and properties without reading journals or
waiting for requests. Worker callbacks never select windows or produce popups.
Up to 32 live views and 32 pending receipt workers are allowed. Receipt waits
have no false timeout acceptance: an unresolved receipt remains pending and holds
its capacity slot. Interrupt and close invalidate the core generation immediately
in the initiating editor command, then wait on a worker; a separate lifecycle
slot lets them run while that buffer has a pending message or approval receipt.

Display text is limited to 65,536 characters plus a fixed truncation notice.
Queued follow-ups have 512-character previews. Current streamed text precedes
history, and turns are shown newest first with messages within each turn in their
original order. Omitted history, stopped sessions, queued follow-ups, and unknown
tool outcomes are explicit. Results are structured JSON; this UI does not itself
apply edit proposals. Operation errors display condition types rather than
printing arbitrary provider conditions. Explicit failure/reason fields supplied
by the core are rendered as task data.

The session journal owns accepted messages and decisions. Configured composers
use a separate private durable draft store with exact session and clarification
metadata; see [DRAFTS.md](DRAFTS.md) for its startup, recovery, and shutdown contract.
`agent-draft-list` lists checkpoints; `i` inspects complete text and authority,
Return restores an unnamed composer, and `d` deliberately discards a checkpoint.
There are at most eight draft list/inspection views; `g` refreshes the current
buffer. Closing any such view or composer retains its checkpoint and admitted
submission. Restoring never submits, visits files, or runs file/mode hooks.

`C-c C-w` captures the composer explicitly; ordinary text edits and cursor commands
also capture it. Disk writes run on the draft worker. `C-c C-s` distinguishes a
durable checkpoint from queued/uncheckpointed edits. Configured hosts set
`*require-durable-drafts*` to true, refusing new composers if storage is unavailable.
Optional standalone users may leave the policy false; without a configured store,
the composer explicitly reports that its text is retained only in memory.

## Source acceptance

Run `bash scripts/run-tests.sh lem-agent/ui/tests` in the configured dependency
environment. The fake-interface suite uses only fake providers and temporary
private journals. It covers independent streaming sessions, coalesced redraws,
focus preservation, killing/reopening views with queued callbacks, competing
allow/deny decisions, gated journal writes and draft revisions, editable
clarification and invalid choices, explicit interrupt/resume/close, late operation
callbacks, uncertain tool outcomes, bounded rendering, and session-list opening.
