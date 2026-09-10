# Configured daemon and service integration

The integration branch replaces the lem-yath tmux/socat server and shell client
with the native Common Lisp daemon/client. The configured editor already included
`lem-daemon` transitively through `lem-ncurses`; a missing Nix ASDF dependency was
not the startup problem. The daemon lacked theme operations needed by the full
configuration, and configuration errors were previously swallowed.

The daemon now implements foreground/background operations and propagates
initialization failures to the owning process after transport cleanup. Interactive
startup retains its existing error reporting. The configured editor starts an
in-session native listener and directs child Git editors to its actual name;
plain interactive sessions fall back to `session-<pid>` when `server` is occupied.
Only a headless daemon permits terminal attachments. Native file/eval requests
also work against in-session listeners.

The old `src/server.lisp`, `src/server-windows.lisp`, `scripts/lemclient.sh`, and
legacy server tests have been removed. The Linux configuration uses
`src/daemon.lisp` and the root flake's `lemclient`. Windows still has no local
transport backend; deleting the old no-op Windows listener does not establish
Windows daemon support. Existing tmux-based TUI build/test drivers are not runtime
client dependencies.

## Verification

The core suite must load the checkout under test. `scripts/run-tests.lisp`
prioritizes its source registry over Qlot's checkout-specific searcher and checks
source identity before and after loading. A cached dependency installation from
another worktree can be selected with `LEM_QUICKLISP_SETUP`:

```sh
LEM_QUICKLISP_SETUP=/path/to/.qlot/setup.lisp scripts/run-tests.sh lem-daemon/tests
nix build --no-link .#checks.x86_64-linux.daemon
nix run .#daemon-test
```

The package test starts only private named daemons in temporary runtime/config/
cache directories. It exercises full configured startup, Org scratch, positioned
visits, independent eval connections, child Git routing, blocking save/abort,
client death, stale endpoint reclamation, clean stop, and failed initialization.
The Python file is an external test driver; the runtime client and editor are Lisp.

`lemclient --wait-for-server SECONDS` retries connection failures while a daemon
starts. It does not impose an execution deadline on a submitted Lisp evaluation.
Supervision must bound the entire readiness command.

## Nix user service

The companion `computer-lem-integration` checkout defines a `lem.service` for
the `yanni` Home Manager configuration. It uses the existing imperative profile:

```ini
[Service]
Type=exec
ExecStart=/home/yanni/.local/state/nix/profiles/lem-yath/bin/lem --daemon
ExecStartPost=/home/yanni/.local/state/nix/profiles/lem-yath/bin/lemclient --wait-for-server 60 --eval t
Restart=on-failure
RestartSec=3
TimeoutStartSec=90
TimeoutStopSec=30
UMask=0077
```

The service is wanted by `default.target`, has a profile executable condition,
and limits restart attempts to three in 120 seconds. Completion of the eval reply
requires completion of configuration initialization; `ExecStartPost` keeps the
unit activating until then. Deliberate successful client shutdown stays stopped.
A crash triggers restart. Systemd stopping the unit is process termination, not
an interactive save prompt. Save work before stopping/restarting until the later
checkpoint recovery milestone is complete.

This definition is prepared in a separate Nix integration checkout. It is not
installed into the user's active Home Manager generation, and the installed
editor profile is not upgraded by the source edits. The Emacs service and shell
`EDITOR` defaults remain as deployed.

## Rollout order

1. Pass the daemon package check and configured interactive/VCS checks. Review
   the integration diff and preserve the prior profile generation.
2. Publish the reviewed Lem revision, then pin the computer flake's `lem` input
   to that revision. A source revision and its lock hash must refer to the same
   published content; do not invent an unreleased hash.
3. Build the computer flake's `legacyPackages.x86_64-linux.lem-yath-profile` and
   the appropriate Home Manager activation package. During local validation use
   `--override-input lem path:/path/to/lem-integration --no-write-lock-file`.
4. After saving any work, install the profile from the updated computer checkout
   using `scripts/sync-lem-yath-profile`; this is separate from Home Manager
   activation. Activate the matching Home Manager generation and start the unit.
5. Check `systemctl --user status lem`, evaluate the configured boot status with
   `lemclient`, attach with `lemclient -t`, and exercise Git editing. Keep the
   previous profile and Home Manager generations for rollback.

No GUI attachment, durable unsaved-buffer restoration, native agent harness, or
Emacs cutover is claimed by this milestone. Those remain in the broader plan.
