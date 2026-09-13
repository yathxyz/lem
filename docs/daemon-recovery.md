# Durable text recovery

`lem-daemon/recovery` adds opt-in recovery for modified file buffers and writable,
non-temporary scratch buffers. The snapshot writer and recovery operations run in
Common Lisp. This is text recovery: it does not resume process stacks, shells,
REPL connections, agent actions, or undo history.

The existing `lem/checkpoint` mechanism only records file buffers, identifies
recovery by timestamps, and writes plain text through its older atomic-save
helper. The configured editor disables that mechanism in `src/persistence.lisp`.
The new module reuses Lem's buffer text, modification ticks, hooks, and idle timers;
its separate store supplies private creation, validated metadata, and strict
filesystem durability. It does not change or delete older checkpoint files.

## Enable and use

The integration's configured Nix editor includes recovery and enables a five-second
idle checkpoint interval under its actual daemon name. A deliberate editor exit
also attempts a final checkpoint; failures are written to the error log.
For other builds, include `lem-daemon/recovery`. On the editor thread, after the
configuration has initialized, call:

```lisp
(lem-daemon/recovery:enable :server-name "server" :interval 5)
```

Use the actual daemon name for independent named sessions. This creates
`$XDG_STATE_HOME/lem/recovery/server/`, defaulting to
`~/.local/state/lem/recovery/server/`. `:directory` accepts an explicit absolute,
private directory for tests or a different storage location. Loading the system
alone does not enable recovery or change any service/profile.

The editor commands are:

- `recovery-checkpoint`: checkpoint current modified text now, waiting for storage.
- `recovery-list`: display record IDs, buffer names, original paths, and disk status.
- `recovery-restore`: restore a selected ID into a separate unsaved buffer.
- `recovery-discard`: remove a selected record after confirmation.

Startup never restores records automatically and never presents a blocking
minibuffer prompt to a headless daemon. A recovered buffer has no visited filename,
even when the source file has not changed. The user can compare it with the current
file and deliberately save or copy the recovered edits. Recovery preserves both
existing buffers and disk files. It retains the source checkpoint until explicitly
discarded; repeated restoration creates independent buffers and independent future
checkpoints.

`buffer-recovery-origin` returns a plist with the source record ID, original filename,
and `:disk-status`. Status is `:scratch`, `:unchanged`, `:conflict`, or `:unknown`.
For a file observed while clean, the baseline is a SHA-256 digest of its raw disk
bytes. Size and timestamps alone cannot conceal a change. The digest is captured
on file visit/save and is diagnostic, not an authorization to overwrite a file.
Buffers already modified when recovery is enabled have an unknown baseline.
Unreadable, non-regular, or unusually large disk files also produce `:unknown`.

Saving a live buffer waits for an earlier background checkpoint to finish, then
removes that buffer's now-saved record. Killing a modified buffer retains its last
checkpoint; explicit discard is available for intentional deletion. Excluded,
unmodified, read-only, and temporary buffers produce no new checkpoint. The internal
`lem-daemon/recovery::recovery-exclude` buffer value excludes a generated buffer
such as the recovery listing.

Lisp callers can use `checkpoint-now`, `list-checkpoints`, `restore-checkpoint`, and
`discard-checkpoint` without UI prompts. Buffer-facing operations must run on the
editor thread. `disable` stops scheduling and waits for a pending writer; it retains
existing records. The deployed profile remains unchanged until the integration is installed.

## Failure and storage contract

Every record contains only a version, random ID, text, buffer name, source filename,
baseline digest, timestamp, and character position. The reader does not use the
Lisp reader, intern symbols, invoke saved modes, or deserialize arbitrary objects.
It validates the schema, file size, JSON nesting, numeric token size, and identifier.
The record ID determines its filename; saved source filenames are metadata.

Directories must be owned by the current user, private, and not final-component
symlinks. Resolved ancestors must belong to the user or the filesystem root's owner
(UID 0 on ordinary Linux, possibly unmapped in a Nix namespace) and must not permit
other users to replace path components (sticky `/tmp` is accepted). Files are created exclusively with mode `0600`; existing records must be
owned private regular files with one link. Symlinks and public directories/files
are rejected instead of silently changing their permissions. The writer flushes
and fsyncs a same-directory temporary file, atomically renames it, then fsyncs the
directory. New directory creation also fsyncs its parent. An error after rename is
reported as uncertain durability. Temporary files left by a killed writer are
ignored by record listing; the preceding or newly renamed complete JSON record
remains the recovery candidate. This sequence targets Linux/SBCL filesystems that
implement the POSIX fsync/rename semantics. The tests exercise process death, not
physical power loss or storage-device failure.

A periodic checkpoint starts after the configured idle interval. Continuous input
can postpone it. Text is copied on the editor thread; writes/fsyncs run on one
worker. No further batch is queued while that writer runs. Each text record is
limited to 2 Mi characters and each periodic batch to 16 Mi characters; deferred
buffers advance on a later pass. The disk-baseline read is limited to 16 MiB and a
JSON record to 16 MiB. `checkpoint-now` explicitly processes all eligible buffers
and waits for the writes. A rejected oversized buffer is reported, while other
eligible buffers still reach storage. `*last-error*` exposes failures to Lisp/UI
inspection. A slow or full filesystem can delay checkpoints, and edits since the
last completed checkpoint can be lost in a crash.

Recovery files contain document text, including whatever private text the user put
in writable scratch buffers. They are private on disk, not encrypted. No automatic
age/count eviction is performed because that could discard the only surviving edits;
retained records therefore require explicit cleanup. This module does not claim
that a process, agent decision, or external side effect has resumed or succeeded.

## Inspect without the editor

`lem-daemon/recovery-store` depends only on Yason, Ironclad, and Babel. It can read
records without a running daemon, frontend, editor event loop, or Lem user init.
The Nix `lem-recover` package builds a standalone Common Lisp executable; it needs
neither Qlot nor a working editor configuration at runtime:

```sh
lem-recover "$XDG_STATE_HOME/lem/recovery/server/"
lem-recover "$XDG_STATE_HOME/lem/recovery/server/" RECORD-ID
```

The first command lists metadata as JSON; the second exports plain text. Listing
returns status 1 if individual records are unreadable, and usage/storage errors
return status 2. `--help` describes the syntax. The prepared Nix profile includes
this command alongside `lem` and `lemclient`.

For development with this checkout's installed Qlot dependencies:

```sh
sbcl --noinform --disable-debugger --script scripts/lem-recovery.lisp \
  "$XDG_STATE_HOME/lem/recovery/server/"
```

The default path, when `XDG_STATE_HOME` is unset, is
`~/.local/state/lem/recovery/server/`. The command emits JSON metadata and separate
per-record diagnostics. Add a record ID to export only its plain text to stdout.
`LEM_QUICKLISP_SETUP` may point to an existing Qlot setup; the script asserts that
recovery systems resolve to this checkout. This entry point loads installed Lisp
dependencies, so a known working SBCL/dependency installation remains necessary.
It deliberately checks that the editor package was not loaded.

## Reusable private JSON storage

Other optional Lisp systems can depend on `lem-daemon/recovery-store` without
loading the editor. `new-id` generates a random 32-character hex identifier.
`write-private-json(directory, id, object :maximum-depth 16)` and
`read-private-json(directory, id :maximum-depth 16)` reuse the same ownership,
symlink, atomic replacement and fsync checks. Callers own their application schema.
`list-private-json(directory :maximum-depth 16)` returns two values: an alist of
`(id . parsed-object)` entries and an alist of `(pathname . diagnostic)` failures.
Listing an absent directory returns empty values without creating it.

The encoded record limit is 16 MiB. Nesting bounds are explicit integers from 1 to
64; numeric atoms are limited to 64 characters. Writes accept JSON data only:
string-keyed hash tables, vectors/proper lists, strings, finite floats, bounded
integers, and JSON boolean/null values. Cyclic/deep structures and arbitrary Lisp
objects are rejected before encoding. Parsing explicitly returns hash objects,
vector arrays, Yason boolean symbols, and NIL null, independently of ambient
Yason defaults. False, null, and an empty array therefore remain distinct through
recovery. Application schemas normalize their own typed fields when needed. The
recovery-specific wrappers retain their stricter buffer schema and depth bound.

The ancestor ownership check anchors trust at the owner of filesystem root `/`
and the current UID. This equals root UID 0 on normal Linux, and also handles Nix
build namespaces where the root owner is unmapped. All existing ancestor
write/sticky permission checks and private leaf ownership checks still apply.

## Validation

```sh
LEM_QUICKLISP_SETUP=/path/to/.qlot/setup.lisp \
  bash scripts/run-tests.sh lem-daemon/recovery-tests

LEM_QUICKLISP_SETUP=/path/to/.qlot/setup.lisp \
  python3 scripts/test-daemon-recovery.py --sbcl /path/to/sbcl
```

The first suite covers private atomic Unicode records; malformed, deeply nested,
long-numeric, trailing, and symlink data; file/scratch recovery and conflict metadata;
empty and repeated independent restores; an oversized buffer alongside a recoverable
buffer; and a save racing a background checkpoint. A same-size/same-timestamp disk
edit verifies that conflict detection depends on content.

The external Python test driver starts source-asserted Common Lisp daemons in private
XDG/LEM directories, without changing `HOME` or loading user init. It observes
automatic file and scratch checkpoints, SIGKILLs the daemon, inspects/exports with
the standalone Lisp program, changes the disk file, restarts, and validates explicit
separate-buffer recovery plus normal daemon operation and clean shutdown. Python
is test scaffolding only; the product recovery implementation and inspector are Lisp.
