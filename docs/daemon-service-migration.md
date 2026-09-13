# Configured daemon and service integration

The prepared Linux editor includes a Common Lisp daemon/client, terminal and SDL
frames, shared Lisp jobs, a native Lisp agent loop and tools, durable text and
agent recovery, explicit structured notes, and the independent `lem-recover`
inspector. Runtime client routing uses neither tmux nor an external agent
executable. Native libraries, curl, Git and other approved external programs
remain available to the Lisp environment.

`lem --daemon` hosts persistent buffers and multiple client frames. `lemclient -t`
attaches a terminal, `lemclient -c` opens SDL, and file/eval requests use the same
native transport. Closing a client retains buffers, sessions and running work.
Ordinary interactive Lem sessions also start a native listener for file/eval
requests and child Git editors; they choose `session-<pid>` if `server` is already
occupied. Client-frame attachments require a headless daemon.

Configured initialization failures propagate to the owning process after
transport cleanup. The old shell client and tmux/socat runtime server have been
removed. Windows still lacks a local transport backend. Some historical TUI test
drivers use tmux; it is not a daemon/client runtime dependency.

## Prepared service and configuration ownership

The companion checkout is `~/proj/nix/computer-lem-integration`. Its shared
`home/lem-daemon.nix` is imported by both `home/headless.nix` and the desktop
`home/default.nix` for `yanni`. It provides profile-backed `lem`, `lemclient`, and
`lem-recover` launchers plus this user service:

```ini
[Service]
Type=exec
ExecStart=/home/yanni/.local/state/nix/profiles/lem-yath/bin/lem --daemon
ExecStartPost=/home/yanni/.local/state/nix/profiles/lem-yath/bin/lemclient --wait-for-server 60 --eval t
Restart=on-failure
RestartSec=3
TimeoutStartSec=90
TimeoutStopSec=30
WorkingDirectory=/home/yanni
UMask=0077
Environment=WORKDIR=/home/yanni/work
Environment=LEM_YATH_OPENROUTER_MODEL_REFRESH=0
Environment=LEM_YATH_CODEX_MODEL_REFRESH=0
EnvironmentFile=-%h/.config/lem/daemon.env
```

The service is wanted by `default.target`, starts only when the profile executable
exists, and limits restart attempts to three in 120 seconds. Its eval response
requires completed editor initialization. `--wait-for-server` bounds connection
retries, not evaluation execution; systemd's startup timeout bounds the entire
readiness command. Deliberate successful client shutdown stays stopped.

Readiness does not imply healthy note roots or draft storage. Missing note roots
leave explicit notes commands unavailable. Damaged draft storage preserves its
files and permits editing/jobs/session inspection, while mandatory durability
blocks new composers. Inspect `M-x lem-yath-notes-status` and `SPC A R` after
startup. Missing provider credentials leave local editing and toolkit use
available; provider calls require their configured credentials.

Both homes set `WORKDIR` to `~/work`. The desktop additionally sets
`PUBLIC_ORG_DIR` to `~/public-org`; headless public capture remains unconfigured
unless explicitly supplied. Optional operator-managed workspace/provider values
can go in `~/.config/lem/daemon.env` with mode `0600`, using systemd environment-file
syntax. Preparation does not generate or read that file. The shared service
module creates no note directories or files. Notes roots are pinned at startup;
missing `roam/` or `roam/journal/` parents require deliberate setup. The explicit
LSM commands create unsaved edits and retain existing Org commands/bindings; see
[the notes adapter](../extensions/structured-notes/ADAPTER.md).

The actual preparation host is `ex44`, whose active Home Manager generation is
owned by NixOS through `modules/home-yanni.nix` and `home/headless.nix`. Its current
installed configuration has no Lem or Emacs user service and defaults to Neovim.
Activating standalone `homeConfigurations.yanni` here would also introduce
unrelated desktop configuration and its existing public-Org activation actions.
Use the headless configuration owner for this host. The prepared service/profile
has not been installed, activated, or selected as the global editor default.

## Build, review and cutover

The companion `docs/lem-daemon-rollout.md` records the retained candidate, exact
build identity and acceptance evidence. Its editor profile and generated service
units have been built and checked. Full Home Manager/NixOS activation packages
contain unrelated configuration and still require deployment review.

From the prepared computer checkout, these local-override commands build without
installing or writing the lock file:

```sh
nix build --no-link --no-write-lock-file \
  --override-input lem path:/home/yanni/proj/lisp/lem-integration \
  .#legacyPackages.x86_64-linux.lem-yath-profile

# The actual host's headless Home Manager package:
nix build --no-link --no-write-lock-file \
  --override-input lem path:/home/yanni/proj/lisp/lem-integration \
  .#nixosConfigurations.ex44.config.home-manager.users.yanni.home.activationPackage

# For the intended standalone desktop home:
nix build --no-link --no-write-lock-file \
  --override-input lem path:/home/yanni/proj/lisp/lem-integration \
  .#homeConfigurations.yanni.activationPackage
```

Both computer checkouts still pin the Lem input to `3d1fac5e9`. Before deployment,
publish the reviewed Lem revision, pin that exact revision, and regenerate/review
its lock with Nix. Integrate the prepared Nix commits into the intended computer
checkout. An ordinary sync against the old pin would still build the old editor.

After review, preserve the current profile and active configuration generations,
save work, and stop the old editor using its matching client/service. Run
`scripts/sync-lem-yath-profile` from the reviewed pinned computer checkout with
Python 3, Git and Nix on `PATH`. The corrected helper builds once, retains a
temporary GC root, prepares a profile from the exact output store path, and
publishes it in one Nix generation change. It preserves priority and rollback
history, refuses mixed/unrecognized profiles, and never follows an old entry's
flake URL. Direct profile commands must not run concurrently with it; see the
companion `scripts/sync-lem-yath-profile.md`.

Activate through the configuration owner: the reviewed NixOS deployment on
`ex44` (`sudo -A nixos-rebuild switch --flake .#ex44`), or
`home-manager switch --flake .#yanni` on the intended standalone desktop machine.
These activate complete configurations. Then start and inspect `lem.service`,
use the newly installed matching client, and exercise the intended daily tasks
before changing editor defaults:

```sh
systemctl --user start lem
systemctl --user status lem
lemclient --eval '(and (lem-yath:boot-ok-p) (lem-yath::native-agent-ready-p) (lem-toolkit/jobs:job-manager-ready-p))'
lemclient -t
lemclient -c
lemclient +42:3 /path/to/file
lemclient --no-wait /path/to/file
```

Roll back both the profile and its configuration owner after stopping the
candidate. Use `nix profile rollback --profile PATH --to PREVIOUS_GENERATION`
for the recorded Lem profile generation. NixOS uses its reviewed system rollback;
a standalone home uses its recorded previous activation generation. The separate
`home-manager-4` profile on `ex44` is not its active NixOS-managed home generation.
Record the actual ownership and generation again immediately before deployment.

## Shutdown and recovery limits

`lemclient --stop-server` checks modified buffers before orderly shutdown; an
explicit forced stop bypasses that check. Orderly exit attempts a final text
checkpoint, drains draft snapshots/submissions while core actors remain open,
then stops the agent actors and job manager. A final checkpoint failure is logged.
`systemctl --user stop/restart lem` terminates the process and does not present a
save prompt or guarantee that orderly checkpoint/drain sequence.

Text checkpoints start after five idle seconds. Continuous input can postpone
them, and edits since the last completed checkpoint can be lost. Records retain
up to 2 Mi characters each; periodic batches are bounded to 16 Mi characters and
encoded records to 16 MiB. Storage must satisfy private ownership/regular-file
checks; records are private but unencrypted. There is no automatic text-record
eviction. See [durable text recovery](daemon-recovery.md) for the complete contract.

Use `M-x recovery-list` to inspect checkpoint IDs and metadata, then
`M-x recovery-restore` with an exact ID to open its text in a separate unsaved
buffer without a visited filename, file hooks, or overwriting the current file.
The independent inspector remains usable without a working editor:

```sh
lem-recover "$HOME/.local/state/lem/recovery/server/"
lem-recover "$HOME/.local/state/lem/recovery/server/" RECORD_ID
lem-recover --jobs "$HOME/.local/state/lem/recovery/server/jobs/" --limit 64
```

Use the actual server name and XDG state root when configured differently.
[Managed jobs](managed-jobs.md) terminate owned process groups after daemon
failure and never replay commands from journals. [Agent recovery](native-agent-integration.md)
retains interrupted/unknown outcomes, queued messages, historical edit candidates
and exact submission receipts. Draft inspection/restoration never submits text or
answers a cancelled decision. Historical candidates require a fresh live proposal;
restoration does not recreate old edit authority. Defaults bound retained sessions
to 64, jobs to 256, and drafts to 32; exhaustion requires deliberate cleanup.

Shell/REPL execution stacks and undo history are not reconstructed after daemon
death. The SDL protocol is a styled character grid without embedded images or
rich widgets. Synchronous minibuffer prompts queue other clients' input. Generic
typeout popups and `lem/peek-source` previews retain global display state; see the
[client ownership boundary](native-legit-frames.md#boundary). Approved process
tools are not filesystem sandboxed, and broad CalDAV/mixed-notes adapters remain
outside this candidate.

## Verification

`scripts/run-tests.lisp` checks source identity before and after loading, including
when `LEM_QUICKLISP_SETUP` borrows dependencies from another worktree. Focused
checks use private named daemons, synthetic repositories and isolated XDG paths:

```sh
LEM_QUICKLISP_SETUP=/path/to/.qlot/setup.lisp scripts/run-tests.sh lem-daemon/tests
nix build --no-link .#checks.x86_64-linux.daemon
nix run .#daemon-test
```

Configured client, agent, notes, project/shell/REPL, service and Git acceptance are
recorded separately in the companion rollout document and retained validation
logs. The rebuilt [Legit frame/rebase gates](native-legit-frames.md) pass their
focused scenarios; the final broad configured VCS gate remains pending. This is
not a clean full-suite claim: see the [core test baseline](core-test-baseline-2026-09-13.md).
External Python test drivers do not change the Common Lisp runtime ownership.
