# Durable native agent drafts

The optional `lem-agent/drafts` system owns unsent text independently of session
history. It depends only on the agent core and its Linux/SBCL private JSON store;
it has no editor, provider, credential, network, or process execution dependency.
The UI captures buffers; a single store writer owns all filesystem operations.

## Host lifecycle

On a startup worker, create the agent manager, call `restore-sessions`, then open
the draft store. Opening awaits restored session readiness before reconciliation.
Use a separate namespace such as the named daemon recovery root's `agent-drafts/`,
beside its `agents/` journals:

```lisp
(let ((draft-store (lem-agent/drafts:open-store
                    :directory private-agent-drafts-directory
                    :manager restored-manager)))
  (setf lem-agent/ui:*default-manager* restored-manager
        lem-agent/ui:*default-draft-store* draft-store
        lem-agent/ui:*require-durable-drafts* t))
```

The directory must be absolute and private. The store holds an exclusive lease,
checks owned regular files through non-following descriptors, bounds reads before
allocation, and atomically writes/fsyncs records and their directory. Opening
malformed, unsafe, or over-capacity storage fails without deleting its files.
The host can continue with transcripts/decisions available and an explicit draft
recovery diagnostic. Mandatory durability refuses new composers in that state;
it never silently falls back to an uncheckpointed composer. Repair or inspect
preserved private JSON separately before retrying startup; there is no automatic
malformed-file deletion or eviction.

Orderly shutdown stops draft admission immediately, then drains it on a worker
while the core actor remains available:

```lisp
(lem-agent/drafts:close-store draft-store) ; nonblocking admission stop
;; Shutdown worker, with core still running:
(lem-agent/drafts:close-store draft-store :wait t)
(lem-agent:close-manager manager :wait t)
```

The draft lease survives every registered submission worker and queued snapshot.
Draining does not await editor events or UI callbacks. A killed composer cannot
cancel admitted input, and a late UI request cannot submit after store admission
closes. Never close the core first when an orderly draft drain is required.

## Records and bounds

Each version-1 record contains exactly `id`, `session_id`, `root`, `provider`,
`model`, `text`, zero-based `point`, monotonic `revision`, original `decision`,
optional `attempt`, and `version`. Clarification metadata preserves the exact
decision/turn IDs, generation, question, choices, and original pending state.
No record owns authority to answer a later or changed question.

The limits are 32 records, 65,536 text characters, 32 KiB encoded decision
metadata, 1 MiB per encoded record, and 16 MiB aggregate. Admission reserves
new IDs even while a write is in flight. Snapshots coalesce per ID, retaining the
greatest text revision; equal-revision/different-text publication fails. Prepared
and unknown attempts reserve another 128 encoded bytes within both the record
and aggregate bounds for an accepted marker/result. Preparation checks the newest
already admitted snapshot plus exact submitted text before core enqueue; later
checkpoints preserve that reservation. Text
changes, including undo, advance revision independently of text equality, while
cursor-only updates preserve revision. The editor owns one publication claim per
live composer. A restored claim refuses an older checkpoint while newer data is
pending. Closing releases that claim; stale callbacks cannot publish through it.

The public low-level capture APIs are `new-record`, `claim-draft` (with `:new t`
only for a fresh UUID), `queue-snapshot :owner claim`, and `release-draft`.
These copy bounded data and perform no filesystem I/O. `list-drafts` and
`find-draft` return copied durable cached checkpoints. Ordinary capture is
asynchronous: the status distinguishes queued edits from an actual durable
checkpoint. A crash can lose edits that have not reached a checkpoint.

## Submission and crash recovery

`submit-draft store snapshot session :owner claim` admits a bounded worker and
returns a core-style request receipt. The UI admits it synchronously before the
composer can close; filesystem work and receipt waits remain off the editor.

1. The store fsyncs a prepared attempt with a fresh submission ID, message/decision
   kind, exact decision ID, submitted revision, exact submitted text, and SHA-256
   input digest. The original submission stays inspectable separately from newer
   draft text, even if the stopped host never accepted it.
2. The core accepts that exact ID in the same session checkpoint as the message
   or decision resolution. Its retained receipt survives history trimming.
3. The store fsyncs the accepted result before acknowledging the core receipt.
4. The UI clears text only if its modification tick still matches the submitted
   revision. Newer edits remain and are checkpointed independently.

After a crash, startup reconciles prepared/unknown attempts only with the restored
core's exact durable receipts, while exclusive ownership excludes old workers.
It never infers acceptance from text, turn position, or trimmed history and never
replays input. A poisoned core journal cannot prove acceptance. A valid restored
session without the receipt means the stopped host did not accept that attempt;
a missing session leaves acceptance unknown. Accepted markers already in the
draft store remain authoritative after their core receipt was acknowledged.

Unchanged accepted revisions, missing/closed sessions, and cancelled/resolved or
changed clarification decisions restore for inspection only. A later unsubmitted
revision remains editable when its exact session and decision are still valid.
Typing and restoration never answer a decision. The human can deliberately copy
text into a new composer when a previous session or question is no longer usable.

## Human inspection and discard

`agent-draft-list` shows exact IDs, session IDs, message/clarification kind, attempt
state, revision, and text length. `i` opens complete text and metadata, Return
restores an unnamed buffer at its saved point, `g` refreshes the current list, and
`q` closes only the view. Inspection/restore functions never select a window from
callbacks, visit a file, or run file/mode hooks. There are eight inspection/list
slots. Owned composers are excluded from generic text-only buffer recovery.

`d` requires an exact row/revision and human confirmation. Close an owned composer
first; live submissions and pending snapshots also prevent discard. The store
retires the ID under its admission lock before unlink, so a concurrent restore
cannot acquire an editor claim. A failed unlink/directory fsync preserves cached
evidence and makes durability unavailable until reopening; an unsynced absence
is never acknowledged as a successful discard.

Recovered orphaned unknown attempts need prior complete inspection and a separate
explicit acknowledgement that deleting them removes uncertain submission evidence.
The low-level equivalent is `discard-draft :expected-revision n
:acknowledge-uncertainty t`. That flag cannot bypass a live owner, active worker,
pending checkpoint, or an unreconciled live attempt. Records are never removed
automatically to make room, including accepted checkpoints awaiting human cleanup.

## Validation

`bash scripts/run-tests.sh lem-agent/drafts/tests` exercises temporary private
stores and fake providers, including real SIGKILL before core enqueue, after
acceptance but before draft cleanup, and after the accepted draft marker. It also
covers late workers, newer pending edits, editor claim retirement, quota/security
failures, uncertain unlink, and explicit orphan cleanup. `lem-agent/ui/tests`
covers text/point restoration, cancelled clarification, generic recovery exclusion,
and draining while the UI callback is deliberately left unconsumed. No live
provider calls or user files are used by these tests.
