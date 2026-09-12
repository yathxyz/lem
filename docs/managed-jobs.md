# Common Lisp managed jobs

`lem-toolkit/jobs` supplies external jobs for Lisp callers, editor commands, and
future native agent tools. `lem-toolkit/jobs-ui` adds inspection buffers. Neither
system changes existing shell, compilation, or model integrations automatically.

The existing `lem-process` runner does not provide a bounded durable result or an
anchored process-group lifecycle. The configured compilation implementation has a
careful guardian protocol, but that guardian is Python. This module uses the same
useful ownership principle with a small Common Lisp supervisor. It
does not wrap the old Python guardian or start an implicit shell.

## API

Manager setup is an explicit blocking operation. Run it during application startup
or on a worker, before exposing editor commands that submit jobs:

```lisp
(setf lem-toolkit/jobs:*default-manager*
      (lem-toolkit/jobs:open-job-manager :name "server"))

(defparameter *job*
  (lem-toolkit/jobs:start-job
   '("git" "status" "--short")
   :owner "human" :directory "/path/to/project/" :timeout 30
   :output-limit 65536))

(lem-toolkit/jobs:job-snapshot *job*)
(lem-toolkit/jobs:cancel-job *job*)
```

`start-job` and `cancel-job` perform no process launch, journal writes, or stream
reads on the caller. Submission copies bounded launch values and starts a controller
thread. `job-snapshot` returns detached JSON-compatible values under a short mutex;
`job-result` returns a snapshot only after terminal cleanup completes. Explicit
`wait-job :timeout seconds` and `close-job-manager` block and belong in REPL/workers
or orderly supervisor shutdown, not normal editor command callbacks.
`job-manager-ready-p` checks completed initialization and whether shutdown has
begun without I/O. GUI and daemon integrations should initialize a manager before
the event loop starts, or open one on a worker and then publish it to commands.

Arguments are an ordinary list of strings passed literally to `execvp`. There is
no interpolation, redirection, globbing, or implicit shell. A caller can deliberately
request a shell with an argv such as `("bash" "-c" "...")`. Directory is absolute.
Owner is an attribution label, not an authorization or privilege boundary; the
calling human/agent interface must authorize its operations.

States are `queued`, `running`, `exited`, `signaled`, `cancelled`, `timed-out`,
`failed`, and `interrupted`. Successful execution requires **`exited` and exit code
0**. A program returning 7 is `exited` with code 7. An unsuccessful `execvp` returns
127 with a diagnostic on stderr. `failed` describes guardian/controller/consumer
failure, including failure to record launch intent before execution.

A job snapshot includes ID, owner, literal argv, directory, state, reason, exit
code, start/finish timestamps, timeout, failure policy, bounded stdout/stderr text,
and retained/total byte counts. `job-output-octets` returns the retained raw bytes
and total bytes for either stream. Text views replace invalid UTF-8; raw retained
bytes remain available and survive journal reload.
`job-owner` and `job-directory` provide cheap detached attribution strings for
filtering histories. `job-snapshot :include-output nil` omits stdout/stderr without
copying or decoding their tails; timestamps, state and byte counts remain available.

## Private input and incremental output

`start-job` accepts `:input`, a UTF-8 string or octet vector capped at 1 MiB. It
travels through private pipes and is not included in argv, journal, or diagnostics.
Environment overrides are also excluded from journals. `:environment` replaces
the inherited environment with a list of `NAME=value` strings; omit it to inherit
the controller environment. Program output is recorded, so a program that echoes
its private input will itself put those bytes in the output record.

For native model transport, a caller can run `curl --config -` with credentials and
request body in `:input`, then consume streaming bytes through:

```lisp
(lem-toolkit/jobs:start-job
 '("curl" "--config" "-") :input request-configuration
 :on-output (lambda (job channel octets)
              ;; Incrementally frame/decode each <=4096-byte private copy.
              (consume-response-chunk job channel octets)))
```

The actual invocation is `(start-job argv :on-output callback ...)`. The controller
calls the callback outside job locks, off the editor thread, before reading the next
chunk. There is one consumer; buffer views read independent retained snapshots.
Callbacks must return promptly and enforce their own protocol framing limits. The
job toolkit does not parse SSE or JSON output. Callback exceptions close the control
and output streams, cancel the owned group, and record a generic consumer failure.
A callback that blocks indefinitely can stall its controller; it is not isolated
inside another process. Model adapters must therefore use incremental bounded work
and must not wait on user decisions inside an output callback.

Stdout and stderr each retain a bounded tail: default 64 KiB, maximum 1 MiB. Output
is drained even after the retained limit is reached. Guardian chunks are at most
4096 bytes; the private framing limit is 4 MiB. A tool that refuses stdin cannot
block cancellation or timeout, because the guardian feeds stdin without blocking
while checking control and draining both output streams.

## Process ownership and failure

A stock, single-threaded SBCL broker forks a watchdog and a separate command-group
anchor. The anchor forks the exec child directly, so there is no automatic
`run-program` child reaper in these supervisors. The watchdog and broker stay
outside the target group; stopping the target's immediate parent or its whole
group cannot stop the cancellation supervisor. A launch gate announces the owned
anchor before permitting target execution. The anchor remains an unreaped direct
child, reserving its identity even after the target exits. The broker acts as a
Linux child subreaper, so watchdog death transfers that still-reserved anchor to
it before cleanup. Neither supervisor signals a group after releasing its anchor.

The broker starts with a fixed minimal locale environment and init files disabled.
Target environment values travel in the bounded private launch frame and are
installed only in the gated exec child. A target's `PATH`, `SBCL_HOME`, or dynamic
loader environment therefore cannot configure supervisor startup. Linux parent
death protection prevents an unowned command from starting during a failed
handshake. A private heartbeat pipe makes broker death trigger watchdog cleanup.

The controller cancels through its private control pipe. The live guardian signals
the still-owned anchored target group; it never accepts a PID/PGID from a caller or from a saved
record. Cancellation and timeout use SIGKILL immediately; graceful SIGINT with a
delay is not part of this initial API. Closing the control pipe, including
when the daemon is SIGKILLed, also triggers group cleanup. Normal completion cleans remaining group descendants and drains each pipe to EOF
before reporting success. This final drain is bounded at 4 MiB per stream and
0.5 seconds; an incomplete drain records `failed` with an explicit diagnostic.
Byte totals count bytes observed by the controller, not bytes a terminated process
might have produced later. A deliberately detached process that creates a new
session/group is outside this policy. This is process lifecycle management, not a
sandbox against malicious code running as the same Unix user. Privileged/set-ID
programs have additional kernel rules and are outside the tested contract.

The daemon-failure policy is always `terminate-on-disconnect; never-replay` in this
first toolkit. A client or inspection buffer does not own the pipe and can close
without affecting the job. If the daemon dies, its guardian cleans the group; if
the guardian is killed, its watchdog does so. Simultaneous failure of both
supervisors and descendants that deliberately leave the owned group require
independent host supervision. The controller deliberately does not guess a signal
target from a numeric PID after an uncertain failure.

## Journal and inspection

The default journal directory is
`$XDG_STATE_HOME/lem/recovery/NAME/jobs/` (with the usual
`~/.local/state` fallback). `:directory` overrides it. A private exclusive file
lease prevents two managers from reconciling the same live journal. Close the old
manager before reopening its directory.

Durable queued intent precedes launching an external process. Running and terminal
transitions are recorded using the recovery store's private atomic JSON primitive.
Stdin and environment are not serialized. Retained output is encoded as raw hex,
so even malformed UTF-8 is preserved. Output updates are durable at recorded
transitions, not on every incoming chunk; a daemon crash can lose newer output.

On startup, validated `queued`/`running` records become `interrupted`. No command is
replayed, no old process is reattached, and no stored PID is signalled. The journal
schema has no PID/PGID field. Completed records remain inspectable. Malformed records
fail manager initialization without starting commands; use the standalone recovery
JSON reader to inspect/fix/archive them deliberately.

`(lem-toolkit/jobs:inspect-job-journal :name "server")` reads the journal without
loading Lem, acquiring the manager lease, launching commands, reconciling states,
or writing files. It returns validated journal objects and, separately,
`(pathname . diagnostic)` failures; `:directory` can name a private journal
directly. These raw records contain `stdout-hex`/`stderr-hex`. A saved `running`
state means only that it was the last recorded state, not that a process is alive.
This operation remains useful while the daemon is down or its main configuration
cannot load.

`lem-toolkit/jobs-ui:show-job` creates a read-only buffer showing state and bounded
outputs. `g` refreshes and `c` requests cancellation. `jobs-list` and `job-open`
provide access through commands and the default manager. Closing an inspection
buffer removes its view on the next refresh and leaves the job alive. No buffer
kill hook cancels a job.

No automatic journal eviction is implemented. Managers currently keep their job
records and retained tails in memory; large histories need an explicit retention
policy in a later integration. These files are private, not encrypted. External
actions remain uncertain across a crash; this toolkit never treats restart as
permission to retry them.

## Runtime packaging and tests

The job controller needs a stock SBCL executable and two adjacent Lisp files:
`guardian.lisp` and `wire.lisp`. It runs with system/user SBCL init
disabled and needs no Quicklisp or Lem configuration in those helper processes.
Set `LEM_TOOLKIT_SBCL` to the absolute SBCL executable and `LEM_TOOLKIT_GUARDIAN` to
the installed guardian script. Lisp callers can alternatively bind
`*guardian-program*` and `*guardian-path*`. In source checkouts the guardian path is
resolved from ASDF. A dumped Lem executable is not a substitute for stock SBCL
unless separately built as an explicit guardian executable. Deployment packaging
must install the two files together. No executable is resolved through a project
`PATH`; source tests must also set `LEM_TOOLKIT_SBCL` explicitly.

Validation commands, with this checkout's installed Qlot/native-library environment:

```sh
LEM_TOOLKIT_SBCL=/path/to/sbcl bash scripts/run-tests.sh lem-toolkit/jobs-tests
python3 scripts/test-daemon-jobs.py --sbcl /path/to/sbcl
bash scripts/run-tests.sh lem-daemon/recovery-tests
```

The Lisp tests execute real argv, failures, hangs, cancellation, bounded binary
stdout/stderr, private unread stdin, consumer exceptions, child spawning,
process-group cleanup even when the target stops its parent or its whole group,
private target environment isolation, journal leases, and interrupted restart records. Supervisor
fixtures explicitly SIGKILL the guardian and its watchdog separately and verify
descendant cleanup. The external daemon driver checks editor responsiveness, buffer/client detachment,
daemon SIGKILL cleanup, restart without replay, source identities, and orderly
shutdown. Python is only the external test driver; all product supervision,
transport, storage and inspection code is Common Lisp.
