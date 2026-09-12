# Configured Lisp toolkit integration

Status: the prepared integration passes source process/recovery/proposal tests,
configured compilation, daemon, proposal, startup, rewrite and native Git gates,
and a private service crash/restart check. The broader VCS gate exposed a rebase
view transition regression; its correction is under validation. The installed
editor and its running services have not been changed.

The configured editor opens a named `lem-toolkit/jobs` manager during startup,
using the same server name as its listener and text recovery directory. Commands
use `lem-yath::ensure-toolkit-job-manager`, which checks readiness without opening
files or launching a process. Orderly shutdown closes the manager; daemon failure
closes private supervisor pipes. Startup reconciles old active records as
interrupted and never repeats uncertain actions.

`jobs-list`, `job-open`, and the Lisp job API inspect bounded results independently
of the buffers that display them. Closing a job or compilation view leaves its
job alive. `lem-recover --jobs DIRECTORY` lists validated journal records and
per-file errors without loading the editor, acquiring ownership, reconciling
states, or writing files. Its raw records contain hex-encoded retained output;
a saved running state does not establish that a process is currently alive.

## Compilation

Linux compilation submits a managed job through pinned Bash, preserving its
captured directory and target environment. A fixed Bash adapter reads the command
from private stdin, closes that input, merges stderr into stdout, and evaluates
the command. Command text and target environment are excluded from argv and job
journals. Programs can still deliberately echo either into recorded output.

Launch and cancellation return without waiting for subprocess or journal I/O.
An output consumer decodes bounded chunks and coalesces them into at most one
pending editor event per session, draining at most 16 chunks (64 KiB) per turn.
The existing ANSI parser, diagnostic navigation,
save query, origin tracking and recompile context remain. Session identity stops
late output from changing a replacement compilation buffer.

`C-c C-k` requests immediate cancellation. This differs from the old SIGINT grace
period. Compilation output exceeding 8 MiB is cancelled; the journal retains at
most 1 MiB per stream. Private command input is limited to 512 KiB and the job has
a 24-hour timeout. A foreground command's successful completion also cleans its
remaining process-group descendants. Deliberately detached groups and
uninterruptible kernel waits are outside the tested cleanup contract.

Killing the compilation buffer preserves the job and its eventual result.
`jobs-list`/`job-open` can inspect the retained output after the original view is
gone. Replacing a live compilation requires the existing confirmation and then
cancels asynchronously. Reload explicitly cancels the previous adapter session.
The adapter still has one current fixed-name compilation view; this does not
limit the manager to one job.

The former Linux Python guardian and tests tied to its private protocol were
removed. Their original source remains in Git history. The replacement native
daemon gate exercises real compilation, nonzero status, ANSI/UTF-8, source
navigation, private input and environment, exact recompile context, bounded noisy
output, view closure, cancellation, and daemon crash/restart. Supervisor failures,
stopped groups and process ownership belong to the shared toolkit's real-process
suite. These gates do not establish complete Emacs `compile.el` parity.

## Interactive Git rebase

Initial rebase, continue, skip and abort submit jobs to the same manager. The
editor does not wait for Git to create its todo or finish. Git's native Lisp file
client opens each request when its file exists. The initiating status command
closes its floating panes synchronously so they cannot obscure the todo or commit
message. Worktree metadata and request completion are scoped to the exact todo
path, including simultaneous rebases in different repositories.

Closing a Legit or job view preserves the job. Killing an editable managed todo
aborts that editor request and produces an unsuccessful Git result; killing an
ordinary visited file still completes its ordinary client normally. Native client
loss does not discard the daemon's managed job. `lem-yath-legit-rebase-job` opens
the worktree's retained result, including bounded failure diagnostics.

Existing status and amend helpers remain upstream synchronous operations. This
migration covers ownership of the interactive rebase process, rather than every
Git operation. Legit's global display variables also need independent-frame
acceptance before sustained daily use.

## Buffer proposals

`lem-buffer-proposals` captures live unsaved regions, retains original and
candidate text, and checks both source revision and proposal generation before
applying edits. Applying creates one undoable change. Human edits touching the
captured region, incomplete change observation, deleted sources and stale review
generations produce conflicts. Closing a review keeps its proposal pending.
The existing rewrite UI uses this same API.

Proposals currently live in the editor image. Durable agent histories must retain
candidate/source metadata and restore decisions as interrupted after a daemon
crash; they must not recreate permission to apply an edit automatically.

## Validation entry points

```sh
bash scripts/run-tests.sh lem-daemon/recovery-tests
bash scripts/run-tests.sh lem-buffer-proposals/tests
bash scripts/run-tests.sh lem-toolkit/jobs-tests
nix build .#checks.x86_64-linux.compilation
nix build .#checks.x86_64-linux.git-rebase
nix build .#checks.x86_64-linux.buffer-proposal
nix build .#checks.x86_64-linux.daemon
```

Configured checks run in private temporary directories through native daemon
clients. Python is an external acceptance driver, not part of the runtime job
manager, agent loop, supervisor or client protocol. No provider credentials,
existing notes, installed profiles or active user services are needed.

As of 12 September 2026, configured gates pass 17 compilation, 22 daemon,
12 proposal and 27 native Git assertions. Startup and the existing LLM workflow
gate also pass. The rebuilt profile passes private systemd readiness, live-job,
daemon SIGKILL/restart, interrupted job recovery and deliberate-stop checks.
The broader VCS gate is being rerun after the status-pane fix in `6fd3268bb`.
Archived logs include the earlier failures and subsequent correction evidence:
[toolkit validation](/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/toolkit).

The native agent core in `559ca9cac` passes 18 source groups and remains optional.
Its provider/tool adapters and disposable buffer views require configured
integration and live-provider acceptance. Job records and retained output tails
currently accumulate in the manager; an explicit retention policy is still needed
before long-running daily operation.
