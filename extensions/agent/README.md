# Native Lisp agent core

`lem-agent` is optional and does not load Lem or its extensions. Session actors own
the transcript, decisions, queued follow-ups, and turn loop. Views subscribe to
events; removing a view or client does not change session lifetime.

Create a manager with `make-manager :directory <private absolute pathname>` on a
startup worker. It acquires an exclusive private directory lease before reading or
writing journals; a second manager fails promptly. The lease survives asynchronous
close until every journal-writing actor stops. Process exit releases the lease;
recovery does not trust a stale process identifier or remove a lock file.
Register providers and tools before creating sessions. `create-session` returns a
session immediately; its `session-ready` receipt reports durable initialization.
`submit-message`, `resume-session`, `resolve-decision`, `interrupt-session`, and `close-session`
return receipts. `await-request` is a **blocking worker/test API**, never an editor
callback. `restore-sessions` and `close-manager :wait t` also belong on workers.
Other public session operations perform no filesystem or network I/O.

`close-manager` is orderly host shutdown: it invalidates operations immediately,
stops the journal actors, and releases the manager lease. It preserves idle,
interrupted, and failed sessions for restoration; it does not permanently close
them. Active turns become `interrupted`; unfinished tool results distinguish
`unknown` started effects from `not-started` calls, and pending decisions are
retained as cancelled with a `host-shutdown` reason. Queued follow-ups remain
durable and require explicit resume or a new submission after restoration.
`close-session` is deliberate, permanent human closure, which survives both
orderly shutdown and crash recovery. Session handles belonging to a shut-down
manager cannot accept further work; restore them in a new manager first.
Shutdown waits for journal actors before releasing ownership, even when the
final checkpoint fails. It does not wait for arbitrary provider/tool or
cancellation workers: those must cooperate, and their late output cannot write
to a journal after its actor stops.

Providers are functions `(request emit-text context)`. The request is a private
JSON copy containing `model`, `messages`, and registered `tools`; credentials stay
in adapter closures. Call `(funcall emit-text fragment)` for streamed text. Return
a JSON object with optional `content`, `tool_calls` (a vector of objects containing
`id`, `name`, and an **already parsed JSON object** `arguments`), or `clarification`
(`question`, optional string-vector `choices`). The transport adapter assembles and
bounds fragmented tool arguments before returning them; the core validates the
complete calls before dispatch. It does not run a provider-owned agent loop.

`register-tool` takes `:schema`, `:validate`, `:execute`, and optional `:permission`.
The validator receives a private arguments object and returns non-nil or signals an
error. Validators and permission-question functions must be bounded, pure functions
on the session actor; execution and I/O belong in the executor. The executor is
`(arguments context)` and returns JSON data. A true `:permission` requires approval;
a function may instead return a specific question from the validated arguments.
Decisions name the concrete tool, call ID, and arguments.
Permission answers are `"allow"` or `"deny"`; clarification answers are strings
(and must match a supplied choice). Stable decision IDs resolve once. Pending and
resolved records are fsynced **before** dependent execution. Tool-start intent is
also durable before invocation, so recovery can report uncertain outcomes.

`register-tool :retain-for-review t` additionally preserves the exact tool
arguments and historical result in `retained_reviews`, outside rolling turns.
Only `propose_edit` opts in among the supplied tools. The actor reserves space
and fsyncs the review together with tool-start intent **before** launching the
executor. Capacity or checkpoint failure prevents that launch. History trimming,
interruption, session closure, and host restart never evict retained reviews.
They are task data in the same private session journal and use its existing lease.

Each record has `id` (a new random 32-hex review ID), `turn_id`, `call_id`, `tool`,
`arguments`, `status`, `generation`, and `result`. Origin and arguments never
change. Status starts as `executing`, generation 0, result null; a recorded tool
return becomes `returned`, generation 1. Interruption, failure, excessive result
structure, or recovery of an executing intent becomes `unknown`, generation 1,
with an explicit unknown-outcome result. `returned` records a historical tool
return; an old proposal ID or successful staging result does **not** establish
current applicability, approval, or whether the human later applied/rejected it.
Restoration never invokes a retained tool. Journals without `retained_reviews`
normalize to an empty collection; already evicted transcript data cannot be rebuilt.

`list-retained-reviews` returns a list of complete copied JSON records in creation
order; `find-retained-review` returns a copied record or nil. Like snapshots, these
read-only APIs remain usable on closed session handles. They perform no I/O and
do not confer authority on a historical candidate. Human recovery must select a
fresh current region, create a new proposal, and review that proposal separately.

`discard-retained-review session id :expected-generation n` returns a receipt:
true after a durable removal, nil if already absent, or an error when stale,
executing, closed, or unable to checkpoint. A failed discard preserves the live
copy and reports its uncertain durability. This is archive cleanup only; it never
accepts, rejects, or edits a live proposal. Restored permanently closed sessions
may process metadata cleanup while retaining their closed status; handles whose
actors already stopped follow the ordinary closed-handle rejection contract.

Per-session limits are 16 reviews, 64 KiB encoded per record, and 512 KiB encoded
for the collection. Arguments keep the session's maximum 16 KiB bound; retained
results are at most 32 KiB. Each argument/result value additionally has at most
256 JSON nodes and depth 12. Excessive arguments fail before execution; excessive
results become an explicit unknown/omitted result while preserving the candidate.
Reservation includes maximum result growth, the current turn's history bound,
and both copies in history/archive.
Every checkpoint validates copying and preserves the remaining result space
inside the agent's 2 MiB encoded and 20,000-node journal bounds. These are stricter
than the shared store's 16 MiB record limit; archive nesting remains below the
24-level store bound. Full capacity fails explicitly, never silently evicting
records. Only an explicit discard frees space, including after human application
or rejection. The number of session journals is not globally bounded by this API.
Individual quotas are ceilings, not a promise that every maximum fits together:
UTF-8 and JSON escaping affect the enclosing byte budget. Follow-up admission
checks that combined budget, including reserved result growth, before modifying
the queue; an oversized follow-up is rejected without stopping the active tool.

Each provider/tool invocation has its own worker. `check-operation` must be used
by an adapter immediately before a marshalled editor mutation; a generation change
invalidates every late result and stream callback. Register a cancellation
function with `register-cancellation` as soon as a request/job exists. Registration
after cancellation schedules cancellation immediately. Failure, stream exhaustion,
and explicit interruption schedule registered cleanup. Cancellation functions run
on separate workers so they cannot block the session actor. They must be bounded
and cooperative; an operation may register at most 16 of them, including late
registration. Common Lisp cannot safely stop an arbitrary uncooperative
function or roll back an external effect. Use managed subprocesses for work that
needs an enforceable kill boundary. Late output is discarded and reported; this
is not process isolation or forced Lisp thread termination.

The actor serializes storage, decisions, and tool rounds without holding session
locks during storage, callbacks, provider calls, or tool execution. Subscribers
run on that actor and should only enqueue view work; exceptions are isolated.
Snapshots and subscriber payloads are deep copies. A provider/tool must not mutate
an object after returning it. Limits bound output, tool arguments/results, rounds,
tool calls, queued messages, retained turns, and context size. Context eviction
removes complete turns, preserving tool-call/result pairs and reporting omissions.

An interrupted turn gets explicit failure results for unfinished tool calls,
distinguishing `not-started` work from a started effect whose outcome is `unknown`.
Restart changes prior active turns to `interrupted`, cancels pending decisions
with `daemon-interrupted`, and never replays an uncertain action. Queued messages
are retained but do not start automatically after restart/interrupt; `resume-session`
or an explicit new submission deliberately resumes processing. Invalid journal
lifecycle, duplicate identities, decision relationships, and unmatched completed
tool exchanges are rejected without rewriting that journal. Authentication
configuration is never part of the journal. User prompts and tool arguments/results are task data
and are retained in the private journal.

Adapters may specialize `operation-error-summary` to supply a bounded,
credential-free category/status diagnostic. Its default reports only the condition
type, never arbitrary printed error arguments. Methods must be pure and avoid
request bodies, headers and raw stderr. Invalid, excessive or failing summaries
fall back to the condition type. OpenRouter exposes its safe category and numeric
status in durable session diagnostics so authentication failures are actionable.
