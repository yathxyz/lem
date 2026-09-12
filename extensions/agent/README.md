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
