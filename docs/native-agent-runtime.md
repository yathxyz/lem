# Native Lisp agent runtime

Implementation contract following the daemon/client and shared toolkit milestones.
This document records planned behavior, not completed agent acceptance.

The session owns its history, work, and pending decisions. A transcript buffer is
a view: closing a buffer or disconnecting its client does not approve, cancel, or
destroy the session. Explicit stop cancels the current model request and managed
tools. Follow-up messages queue at a turn boundary; an interrupt invalidates late
callbacks before they can mutate the editor.

## Reuse and boundaries

The preserved untracked `lem-agent-harness/extensions/agent` prototype contributes
the provider-neutral session and event vocabulary. Its Python SDK bridge and
provider-owned turn loop are not the runtime for this integration. The configured
`llm.lisp` already provides Lisp chat-completions encoding and streaming tool-call
assembly, but request ownership is tied to buffers and its input reader checks line
length only after allocating a whole line. Reuse useful encoding/parser logic with
bounded incremental input and session ownership.

Assuming the existing OpenRouter configuration supplies the initial adapter while
the user's provider preference is pending. The model remains explicitly selectable;
local fake-provider tests require no credentials or network. The current
[OpenRouter tool-calling contract](https://openrouter.ai/docs/guides/features/tool-calling)
returns requested function calls to the application. Lisp validates and executes
them and supplies results in subsequent model messages. Streaming may fragment
tool arguments, so dispatch occurs only after a complete, validated call.

The core session runtime must not depend on a provider CLI or an SDK agent loop.
Ordinary external utilities remain available through `lem-toolkit/jobs`. Request
credentials and bodies travel through private input streams and are not copied to
process arguments or job journals. Tools, permissions, turn limits, cancellation,
and recovery state remain Lisp-owned.

## Shared operations

- File/context reads prefer the current unsaved buffer, with source identity and
  revision recorded. Project paths resolve inside the session's chosen root.
- Process tools use managed argv/cwd jobs with bounded output and time limits.
  Approval names the actual operation and its arguments; it is resolved once.
- Edit tools create `lem-buffer-proposals` objects. Explicit acceptance verifies
  captured content/revision and applies one undo group. Stale proposals preserve
  current human text and expose a conflict for review.
- Human commands and the Lisp REPL can invoke the same jobs and proposal APIs
  without a model or agent session.

Network/process I/O and the turn loop run outside the editor thread. Buffer reads,
view updates, and mutations run on the serialized editor loop. No session lock is
held while waiting for an editor callback or an external process. Callback results
carry session/turn identity so work arriving after cancellation cannot act on the
next turn. Output retention and context limits report omissions explicitly and
preserve complete tool-call/result pairs.

## Decisions and recovery

Permission and clarification requests are session records with stable IDs. Any
attached view may inspect them; elapsed time or a lost client is never approval.
Persist pending and resolved decisions before dependent external work proceeds.
Recover a prior active turn as interrupted. Preserve its transcript and diagnostic
job state, and require deliberate continuation; never replay an operation whose
external result is uncertain. A restored transcript cannot recreate a process
stack or prove an external action succeeded.

## Acceptance

Use deterministic Lisp fake providers to exercise concurrent sessions, fragmented
streaming, bounded malformed output, tool rounds, queued follow-ups, interrupt,
approval/deny, and tool failure. Kill transcript views and clients while work or
decisions are pending, then reconnect. Kill/restart the daemon around decision and
tool boundaries and verify that no uncertain action is repeated. Exercise human
edits between context capture and proposal acceptance, including undo. Finally run
a small explicitly selected real-provider session with the configured credentials;
fake-provider success alone does not establish live authentication or model support.
