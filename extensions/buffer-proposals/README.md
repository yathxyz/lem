# Live buffer proposals

`lem-buffer-proposals` is the shared Common Lisp edit proposal API. It captures
the live, unsaved buffer through existing Lem points and revision ticks. It does
not invoke providers, execute tools, save files, or apply edits automatically.

Assumptions: calls that inspect or change live buffers run on the editor thread;
acceptance is an explicit human decision; a conflict requires a fresh capture
after review. Worker threads must queue these calls onto the editor thread.

```lisp
(let* ((proposal (lem-buffer-proposals:capture-region start end))
       (id (lem-buffer-proposals:proposal-id proposal))
       (revision (lem-buffer-proposals:proposal-revision proposal)))
  ;; Return id, revision, original text and source location to the agent.
  ;; Its response is staged later on the editor thread, without editing source.
  (lem-buffer-proposals:stage-replacement proposal "replacement text")
  (lem-buffer-proposals:show-proposal proposal)
  ;; After a human reviews this exact candidate:
  (let ((generation (lem-buffer-proposals:proposal-generation proposal)))
    ;; A queued approval must retain all three values from that review.
    (lem-buffer-proposals:apply-proposal
     (lem-buffer-proposals:find-proposal id)
     :expected-revision revision :expected-generation generation)))
```

The final call belongs to an explicit acceptance handler, not the agent loop.
Direct synchronous REPL acceptance can omit the expected values; queued
decisions must pass both reviewed values. Staging a new candidate increments its
generation. An old approval signals `proposal-conflict` without changing source
or invalidating a still-current proposal. A refreshed review requires another
accept action.

`proposal-original`, `proposal-replacement`, `proposal-id`, and
`proposal-source-location` return copies of mutable data. Source locations carry
buffer identity metadata, optional filename, one-based line, zero-based column,
captured/current revision and whether the region is still tracked. The source
button navigates to the original live buffer; it never substitutes another
buffer with the same name or reloads a disk version. IDs remain stable while
retained in the current Lisp image. They are not durable recovery records.

The registry is bounded to 64 records, 1,048,576 characters per original or
candidate, and 16,777,216 retained text characters in total. Review sections show
at most 65,536 characters each, with a truncation notice. The stored candidate is
complete. Old applied/rejected records may be evicted; pending/conflicted work
is never silently discarded to make room. Call `reject-proposal` and then
`forget-proposal` to release an unwanted pending record. `list-proposals` returns
retained records in creation order.

The states are `:captured`, `:pending`, `:conflict`, `:applied`, `:rejected`, and
`:forgotten` (`:applying` exists only inside a synchronous edit). The captured
revision is immutable. Lem's existing registered points track outside edits;
before/after hooks account for each subsequent tick. Outside-region edits are
accepted only when that complete revision chain was observed and the tracked
region still exactly matches the captured text. Touching either boundary,
editing the region and undoing it, missing a hook, killing the source buffer,
or another overlapping proposal creates a conservative conflict. A failed
before-change attempt may also conservatively conflict. There is no automatic
merge or conflict override.

Acceptance checks readiness, content, observed revisions, reviewed candidate,
and read-only status before editing. It uses a Lem change group with its own
undo boundaries, including during an open Vi insertion command. A failed edit
rolls the group back with modification hooks inhibited, preserving original
text even if an edit hook keeps failing. Undo-disabled buffers cannot accept a
text change. Accepting identical text creates no edit/undo entry. Rejecting has
no source edit or undo entry. The `proposal-finished` generic notifies integrations
after acceptance/rejection commits; methods must not edit source or signal
errors. The configured rewrite adapter uses it to clear overlays and previews.

The review displays original/current/proposed text, reason, ID, revision,
candidate version and a source link. `A` accepts, `K` rejects, `s`/Return visits
source, `g` refreshes, and `q` closes. Conflicts preserve human text and can only
be rejected or replaced by a fresh capture. Existing `llm-rewrite` now uses this
same API. Its normal accept and manual conflict-marker action both reject stale
source. Its provider/backend behavior is unchanged.

Run the focused source-asserting suite with
`scripts/run-tests.sh lem-buffer-proposals/tests` (set `LEM_QUICKLISP_SETUP` to a
dependency environment if necessary). From the Lem root,
`nix build .#checks.x86_64-linux.buffer-proposal` checks actual configured native
daemon/rewrite acceptance without providers. The existing
`nix build .#checks.x86_64-linux.llm-workflow` exercises the full rewrite UI with
its fake provider fixture.
