Interactive rebases use the same native Common Lisp `lemclient` for
`GIT_SEQUENCE_EDITOR` and `GIT_EDITOR`. Git waits on a daemon file request while
the todo or commit message is edited. There is no generated shell editor,
polling control file, signal protocol, or terminal-server dependency.

The configured rebase commands submit jobs to the shared Common Lisp
`lem-toolkit/jobs` manager. Starting, continuing, skipping, and aborting a stopped
rebase run asynchronously:
Git can request another commit message without blocking the editor that must
answer it. Submission does not wait for a todo file or a slow pre-rebase hook.
Legit's fourth return value delegates todo display to the native editor request,
avoiding an empty buffer created before Git writes the file. A second action is
refused while the prior job remains active, including its final process cleanup.
Pending todo requests can be continued or aborted from Legit status as well
as from the native file-edit bindings.

`lem-yath-legit-rebase-job` opens the current worktree's active job and bounded
stdout/stderr. Without an active session, it offers retained jobs for selection,
including durable history after a restart. Job identity, owner
(`human/git-rebase`), exact argv, worktree directory and result belong to the job
manager, not an inspection buffer. Closing that view, closing a Legit window,
or disconnecting an ordinary client leaves Git running. The editable todo is a
different contract: explicitly killing its buffer aborts the pending native file
request, so Git exits unsuccessfully. Explicit cancellation in a managed job view
uses the toolkit's immediate process-group SIGKILL policy; it is not a graceful
Git interrupt or an automatic `git rebase --abort`.

Queued submission is not successful execution. The editor polls the nonblocking
`job-result` API and labels a rebase step successful only when its state is
`exited` and exit code is zero. A successful edit stop may still leave a rebase
in progress. Nonzero exit, signal, cancellation, timeout, launch/guardian failure,
and interrupted recovery remain explicit unsuccessful results. Each output
stream retains at most 64 KiB, with total byte counts. The default managed rebase
timeout is 24 hours, allowing an unattended interactive edit without a short
startup timeout. This limit is configurable through `*legit-rebase-job-timeout*`.

Git resolves the todo location through `rev-parse --git-path`, including linked
worktrees. Todo buffers retain the selected worktree directory. An unmodified
todo retained by a previous native client is replaced before starting another
rebase; unsaved todo changes prevent that replacement.

Native file requests choose a switchable text window within their destination
frame. This lets Git open its editor while a Legit status peek is selected,
without replacing the peek's reserved buffer or selecting another client frame.

The shared manager journals queued intent before launch. Daemon failure closes
the guardian's private ownership channel, causing cleanup of the owned group.
On restart prior queued/running records become `interrupted`; no command or
pending editor approval is replayed. A killed sequence editor makes Git abort
the initial todo edit. An interrupted job may leave Git sequencer state requiring
explicit continue, skip, or abort after inspecting the repository and job result.
The configuration owns manager startup/shutdown; rebase hooks neither open a new
manager nor block waiting for Git during editor shutdown.

Run `nix build .#checks.x86_64-linux.git-rebase` from the Lem root for real Git
process checks: reword/fixup, consecutive rebases, abort, edit/amend, linked
worktrees, literal metacharacter paths, conflict continuation callbacks, skip,
slow startup hooks, unsuccessful Git exits and diagnostics, harmless inspection
closure/client disconnection, request-buffer death, and daemon SIGKILL/restart
without replay. The external test driver is Python; the
editor, client, and rebase control flow are Lisp. The existing full VCS gate
continues to exercise the interactive keybindings.

The configuration must load `lem-toolkit/jobs` and `lem-toolkit/jobs-ui` and
provide `lem-yath::ensure-toolkit-job-manager`, which returns the initialized
manager or immediately reports its absence. Packaging supplies the stock SBCL
guardian runtime. Git metadata reads and the existing commit/amend command remain
the ordinary porcelain paths; this migration covers managed rebase processes and
their native editor requests. Journal retention follows the shared manager's
policy; no separate rebase job database or recovery protocol is introduced.
