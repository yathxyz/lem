# Native file and buffer tools

Load `lem-agent/editor-tools`, then call
`(lem-agent/editor-tools:install-editor-tools manager)` before creating agent
sessions. The installer returns its bounded inspection registry. It registers
three permission-free tools; none accepts a proposal, saves a file, evaluates
Lisp, invokes a shell, or selects a window.

| Tool | Arguments | Result |
| --- | --- | --- |
| `list_directory` | `path` relative to the session root; empty means root | At most 128 entries in filesystem order, entry types, and a truncation flag |
| `read_file` | `path`, optional zero-based character `offset` and `limit` (default/max 4096) | Live text slice, source kind, opaque `revision`, range, total length, modified/truncated flags |
| `propose_edit` | `path`, inspected `revision`, exact `original`, and `replacement` (each at most 4096 characters) | Shared `proposal_id`, captured buffer `revision`, candidate `generation`, source location and activation metadata |

The opaque inspection revision and the proposal's integer buffer revision serve
different purposes. An inspection token binds its session, root, literal path,
source identity, revision and text range. `propose_edit` consumes it once. A
second candidate requires a fresh inspection. Returned JSON shares no mutable
strings with retained token state or live buffer metadata.

Open buffers take precedence, including unsaved changes and files whose disk
encoding has since become invalid. Their content comes from the editor thread;
the worker only validates the path and file type. Monotonic buffer ticks detect
edit-and-restore ABA, and weak buffer identities prevent a recreated same-name
buffer from inheriting a token. A human opening a previously unopened source
between disk inspection and proposal staging also requires fresh inspection.
Closing inspection/review views does not discard staged proposals.

Unopened regular files are read on the worker through an owned descriptor, with
a 1 MiB byte limit and strict UTF-8 decoding. NUL-containing input is refused.
Consistent CRLF or CR endings become normal buffer newlines with the original
line-ending encoding retained. Mixed endings retain their literal characters.
Identity, SHA-256, size, nanosecond ctime/mtime and mode are checked again before
publishing a file buffer. These are optimistic checks using metadata supplied by
the filesystem; a filesystem that hides changes at its timestamp resolution
cannot provide a stronger disk ABA guarantee. Existing live buffers always use
Lem's monotonic revision instead.

Publishing a verified disk snapshot creates an ordinary file buffer with its
filename, directory, UTF-8/line-ending encoding, undo support and saved baseline.
Its disk text starts unmodified. For a missing file, staging creates a prospective
unsaved buffer; the path remains absent on disk. All replacement text remains in
the shared proposal until a human accepts it. Acceptance changes the buffer in
the proposal API's ordinary undo transaction and still does not save the file.
Preparation remains private until staging succeeds. A full proposal registry or
another staging error leaves no new visible buffer and preserves the inspection
token for retry.

File mode, project and other find-file hooks are deferred during publication.
After visiting the source buffer, the human can run
`M-x agent-activate-file-buffer` to perform normal file setup. Results expose
`needs_activation` and `activation_command` for a UI to offer this action.
Activation is explicit because ordinary hooks may access the filesystem, start
language services, or ask questions. The agent callback never invokes those hooks.

Filesystem access is Linux/SBCL Common Lisp. It walks the absolute session root
and each literal relative component with `openat`, `O_PATH`, `O_NOFOLLOW` and
directory descriptors. Absolute tool paths, dot/parent/empty components, symlink
traversal and nonregular file inputs are refused. Leaf type is checked before a
read stream opens, so a FIFO cannot block a regular file read. The verified inode
is reopened through its owned `/proc/self/fd` descriptor. Linux `statx` supplies
sub-second timestamps; this requires the relevant metadata support. These tools
do not provide a filesystem sandbox for other tools or for later human saves.

Editor callbacks perform no filesystem I/O. Workers wait for bounded receipts;
64 pending callbacks per installer and a ten-second wait limit prevent unbounded
queue growth. Cancellation and expired waits make still-queued callbacks inert.
`check-operation` runs before dispatch and directly before buffer/proposal
publication. A callback already executing is a short editor transaction; this is
cooperative cancellation, not forced Lisp thread termination or rollback of a
completed human-visible proposal.

Inspection history retains at most 128 tokens and 8 Mi characters of captured
file/range text, evicting the oldest inspections. Expired tokens require another
read; pending proposals use the shared proposal registry and are not evicted by
that history. Tokens and shared proposals are image-local. Durable agent history
retains tool arguments/results, but stale IDs after daemon restart cannot replay
an edit; recovery requires fresh inspection and another proposal.

Validation:

```sh
scripts/run-tests.sh lem-agent/editor-tools-tests
LEMCLIENT_BIN=/path/to/lemclient python3 extensions/agent/tests/editor-tools-native.py
```

Set `LEM_QUICKLISP_SETUP` to a prepared dependency environment for source tests.
The native fixture loads source-asserted core/daemon/agent systems, uses a local
fake provider, and drives a real Lisp agent actor and editor loop. Its Python code
is external test orchestration, not a runtime dependency or agent implementation.
