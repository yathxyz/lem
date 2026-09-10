Interactive rebases use the same native Common Lisp `lemclient` for
`GIT_SEQUENCE_EDITOR` and `GIT_EDITOR`. Git waits on a daemon file request while
the todo or commit message is edited. There is no generated shell editor,
polling control file, signal protocol, or terminal-server dependency.

The configured rebase commands retain ownership of the asynchronous Git
process. Continuing or skipping a stopped rebase also runs asynchronously:
Git can request another commit message without blocking the editor that must
answer it. A second action is refused while that Git process is still running.
Pending todo requests can be continued or aborted from Legit status as well
as from the native file-edit bindings.

Git resolves the todo location through `rev-parse --git-path`, including linked
worktrees. Todo buffers retain the selected worktree directory. An unmodified
todo retained by a previous native client is replaced before starting another
rebase; unsaved todo changes prevent that replacement.

Native file requests choose a switchable text window within their destination
frame. This lets Git open its editor while a Legit status peek is selected,
without replacing the peek's reserved buffer or selecting another client frame.

Closing the daemon releases its native editor connections. A killed sequence
editor makes Git abort the initial todo edit. Failures after Git has begun
applying commits may leave its sequencer state for explicit continue, skip, or
abort; external Git operations are never silently replayed.

Run `nix build .#checks.x86_64-linux.git-rebase` from the Lem root for real Git
process checks: reword/fixup, consecutive rebases, abort, edit/amend, linked
worktrees, literal metacharacter paths, conflict continuation callbacks, skip,
client death, and daemon shutdown. The external test driver is Python; the
editor, client, and rebase control flow are Lisp. The existing full VCS gate
continues to exercise the interactive keybindings.

The asynchronous session currently tracks Git process ownership and pending
native file requests. A persistent job output buffer and structured completion
history belong to the shared Lisp toolkit milestone; this change does not add
a separate job framework.
