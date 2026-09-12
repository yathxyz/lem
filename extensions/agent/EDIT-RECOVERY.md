# Historical edit candidates

Load the optional `lem-agent/edit-recovery` system after configuring the native
agent manager. This module does not install providers or tools. The host must
register `propose_edit` with retained review support.

From a session-associated transcript, composer, or historical view, invoke
`agent-retained-reviews`. Return opens the exact historical row. These read-only
buffers show the recorded origin, original and replacement JSON strings, and
historical result. Root/path values are metadata: opening a view never finds,
visits, activates, or saves a file. Views refresh deliberately with `g`; closing
one neither discards history nor changes any live proposal.

Historical `returned` means a tool return was recorded. It does **not** establish
whether a proposal was accepted, rejected, or subsequently changed. `unknown`
means the outcome is uncertain. Every view explicitly leaves current
applicability and prior application unknown. Retention does not recover the old
live proposal or authorize an edit.

To reuse a candidate:

1. Select its exact original text in a writable live buffer. For insertion,
   explicitly set the mark at the insertion position even though the region is
   empty.
2. Invoke `agent-restage-retained-review`, then choose the exact session ID and
   retained review ID. The selected region is captured before either prompt.
3. Inspect the new ordinary proposal, then separately accept or reject it with
   the existing proposal commands. Restaging itself does not modify source text.

The temporary capture has a new proposal ID and tracks the source's modification
chain through both prompts. Revalidation checks that exact live buffer,
captured revision/generation, proposal identity, and original text. Changed
text, edit/undo ABA, deleted/replaced buffers, and changed live proposal generations
are refused. Only the explicitly selected region is used, even if the same text
occurs elsewhere. There is no search, filename rebinding, or force override.
Cancellation or failure rejects and forgets the temporary capture.

The retained ID, tool-call origin, and arguments are rechecked before and after
staging. A missing or changed record is refused; observing discard during
staging abandons the still-unapplied new proposal. Historical result/status
enrichment alone does not change candidate identity. An executing record cannot
be restaged until the operation returns or is interrupted. Later metadata
discard does not revoke an already published new proposal.

`d` queues metadata-only discard for the exact displayed ID and generation.
Actor receipt waiting runs on a worker. Stale generations report failure;
already absent entries are reported as such. A late receipt cannot overwrite a
new buffer that reused a killed view's name. Receipt completion never selects a
window. Refresh resets point if it would otherwise inherit a different row.

The core retains at most 16 entries, each at most 64 KiB and together at most
512 KiB. It refuses new retained tool execution when capacity is full until the
human explicitly discards an entry. This UI accepts only complete bounded JSON
records, limits views to 32 and pending discard receipts to 16, and renders at
most 192 Ki characters plus a fixed truncation notice. A truncated historical
view has no actions. Staging also obeys the live proposal registry's admission
limit; pending proposals are never evicted to make room.

`agent-show-session` deliberately opens a new transcript from a
session-associated buffer. `C-c C-z` invokes it in native composers, native
views, historical views, and new restaged proposal reviews. Ordinary proposal
reviews that have no session association report that fact.

Programmatic entry points `show-retained-reviews(session)` and
`show-retained-review(session, id)` return buffers without selecting them.
`capture-selection`, `restage-selection`, and `release-selection` run on the
editor thread. Callers must release a capture in `unwind-protect` if their own
prompt is cancelled. Interactive restaging verifies the configured manager still
owns the exact selected session. Cached historical snapshots remain inspectable
on closed session handles; programmatic callers choose the session explicitly.

Run `scripts/run-tests.sh lem-agent/edit-recovery-tests` in the prepared Lisp
dependency environment. These source tests use the real actor and durable
retention with fake providers, a fake editor interface, actual buffer undo, and
administrative prompt/race synchronization. They make no live provider calls and
do not constitute a configured native-client or deployment gate.
