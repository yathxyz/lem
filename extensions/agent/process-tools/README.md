# Managed process tools for Lisp agents

Load `lem-agent/process-tools`, then register its tool against a ready shared job
manager before exposing sessions:

```lisp
(lem-agent/process-tools:install-process-tools
 agent-manager :job-manager lem-toolkit/jobs:*default-manager*)
```

This registers `run_process`. It does not start a manager, provider, process or
editor. The existing jobs API remains available to human commands and the Lisp
REPL. Each agent invocation becomes an ordinary managed job whose owner contains
the session ID, turn ID and generation; its terminal result includes `job_id` for
inspection with `lem-toolkit/jobs-ui:show-job`.

Every invocation requires the core's durable permission decision before execution.
The decision records the actual executable and arguments. Denial creates no job.
The tool does not retry failed, cancelled, timed-out or uncertain work.

Arguments are a strict JSON object:

| Field | Meaning |
| --- | --- |
| `argv` | Required array of 1–64 literal strings, each at most 4096 UTF-8 bytes. The executable must be nonempty. |
| `cwd` | Existing directory within the session root; defaults to `.` relative to that root. Absolute paths within it are also accepted. |
| `timeout_ms` | Integer from 1 to 300000, default 30000. |
| `input` | Public stdin text, at most 4096 UTF-8 bytes, default empty. |
| `output_limit` | Retained raw bytes per stream, 1–2048, default 2048. |

Strings cannot contain NUL. The core's total argument budget also applies. Unknown fields, including
`environment` and credential options, are rejected. Arguments—including stdin—are
part of the private agent transcript. Credentials belong in provider adapter
configuration and must not be supplied as process tool arguments.

There is no shell interpolation unless the reviewed argv explicitly invokes a
shell. Directory resolution runs on the executor worker after approval. Native
Unix pathname parsing treats names containing brackets, `*` or `?` literally.
Canonical paths outside the root, missing directories, and symlink escapes are
rejected before job submission.

These are **approved, unsandboxed local processes**. Cwd validation chooses where
the command starts; it does not restrict what an approved program can read, write,
execute or contact. A process can access outside the project using normal user
permissions. Directory identity is not pinned across resolution and the later
supervisor `chdir`; concurrent directory renames can change that relationship.
Approval is the execution boundary, not a filesystem confinement guarantee.

Child environment is limited to ordinary user/runtime variables: PATH, home and
user names, locale, terminal/temp directory, XDG paths, display/DBus addresses, SSH
agent socket, and certificate/Nix paths. Arbitrary provider API key variables are
not inherited. This is not a secret sandbox: approved local commands still have
the user's normal filesystem and socket access. No environment values are added
to the process result.

After job creation the executor immediately registers generation cancellation.
The core also runs registrations made after interruption, covering cancellation
between job creation and registration. The executor checks its operation before
submission, throughout its worker-only wait and before returning. An interrupted
operation cannot publish a late success. Closing a subscribing view leaves the
session and job alive. Cancellation, timeout, descendants and daemon failure use
the shared Lisp supervisor's existing policy; there is no second process runner.

Results contain JSON values only. `success` is true only for `state="exited"` and
`exit_code=0` and no journal error. A known exit still has `outcome="completed"`
when its snapshot reports a durability error, but success is false and
`journal_error` explains the storage failure. The current job controller changes
final-write failures to `failed`; those results remain explicitly uncertain.
A nonzero exit remains `outcome="completed"` with success false;
signals, cancellation and timeout report `outcome="interrupted"`. Failed or
historical interrupted jobs have `outcome="unknown"`; rejection before submission
reports `outcome="not-started"`. The core separately records interrupted tool
calls as uncertain when their worker can no longer publish a result.

Stdout/stderr each include text, observed byte count, retained byte count and an
explicit truncation flag. Invalid UTF-8 is replaced for display; raw bytes remain
in the job journal. Observed counts describe bytes read by the supervisor, not
output a terminated process might have produced. Retaining at most 2048 raw bytes
per stream keeps even worst-case JSON escaping within the core's default 32768-byte
result budget; reason and journal diagnostics are each capped at 512 characters.
A session configured with a smaller result budget can still omit a result under
its own policy. Streams are drained after their retained tail fills.

Validation uses a fake provider and real managed commands, with no network or live
provider credentials:

```sh
LEM_TOOLKIT_SBCL=/absolute/path/to/sbcl \
  bash scripts/run-tests.sh lem-agent/process-tools-tests
```

The suite verifies denial and pending permission cause no external effect, literal
argv, strict argument rejection, root/path handling, nonzero exits, inherited-key
exclusion, worst-case noisy binary output, timeout/child cleanup, view detachment,
and interruption during the launch/registration race.
