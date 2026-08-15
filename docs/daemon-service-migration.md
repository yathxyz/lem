# Daemon service migration: first-class Lem daemon, legacy tmux server removal

Status: specification, not yet implemented. Companion to
[`daemon-client.md`](daemon-client.md), whose milestones 1–8 are implemented
and tested on Linux/SBCL/ncurses. This document specifies the remaining
*service* work: making the shipped editor daemon-capable, giving plain
interactive Lem an Emacs `M-x server-start`-style in-session listener,
deleting the legacy tmux/socat server from the lem-yath extension, and
supervising the daemon with a systemd user unit in the Nix deployment.

This specification is self-contained. An agent starting in a fresh checkout of
this repository (the Lem fork, branch `main`) can execute the fork sections
without further context. The final section addresses a *different* repository,
the Nix configuration at `~/proj/nix/computer`, and is clearly separated; if
you are only pointed at one repository, execute only its sections.

All file paths are relative to the repository root of the repo named in the
section heading. Cited line numbers are anchored at fork commit `3d1fac5e9`
("Fix lem-yath Linux AOT source count"); if the tree has moved, locate the
cited definitions by the identifier names given alongside every line number.

## Purpose and outcome

The fork already contains a complete Emacs-style daemon under
`frontends/daemon/` (`lem --daemon` owning all editor state, a native
`lemclient` for file requests, `-t` terminal frames, `--eval`, and
`--stop-server`, over a Unix-domain socket). What is missing is everything
around it:

1. **The shipped editor cannot be a daemon.** The Nix `lem-ncurses` package
   does not build the `lem-daemon` system, so `src/lem.lisp:129` errors with
   "This Lem executable was built without daemon support".
2. **Nothing supervises the daemon.** tmux remains the de facto keeper of the
   long-lived editor.
3. **The legacy tmux/socat server is still live and broken.** The lem-yath
   extension's `lem-yath/src/server.lisp` auto-starts inside every configured
   Lem, publishes tmux pane metadata, and exports
   `GIT_EDITOR="<client> --no-focus"` — but the packaged `lemclient` is now
   the native daemon client, which rejects `--no-focus` as an unknown option
   (`frontends/daemon/client.lisp:369`, `parse-client-arguments`). Its own
   README says it is retained "only until the native persistent daemon …
   replace[s] it", which is now true.

After this migration:

- `lem --daemon` works in the shipped build and runs as a systemd user
  service; `lemclient` is the everyday entry point, like `emacsclient`.
- A plain interactive `lem` starts an in-session listener (Emacs
  `M-x server-start` parity), so `git commit` and shell edits from inside a
  terminal buffer round-trip into the same editor.
- The legacy tmux subsystem is deleted; no tmux, socat, or shell client
  remains in the editor's runtime path.

## Recorded decisions

These were resolved during planning and must not be re-litigated by the
executing agent; the rationale is recorded so future changes can revisit them
deliberately.

1. **`--eval` stays available on the in-session listener.** The daemon
   transport authenticates same-UID peers via socket peer credentials plus an
   owner-private runtime directory, and eval-for-agents is an explicit v1
   goal of `daemon-client.md`. Anyone able to connect can already ptrace the
   process. If this is ever reversed, the guard is one line in the request
   dispatch of `frontends/daemon/server.lisp` (the `(string= type "eval")`
   clause): reject when `*daemon-root-implementation*` is nil.
2. **`attach` is refused on the in-session listener.** `handle-attach-on-editor`
   (`frontends/daemon/server.lisp:322`) creates a `daemon-implementation`,
   calls `activate-implementation`, and on detach restores
   `*daemon-root-implementation*` — inside a plain ncurses session that would
   steal the process-global ncurses `*implementation*` and, on detach,
   activate nil. Attach therefore requires a real `lem --daemon`.
3. **In-session listener name falls back rather than fighting a headless
   daemon.** If the default endpoint name `server` is already owned by a live
   daemon, the in-session listener claims `session-<pid>` instead, and the
   editor points its *own children's* `GIT_EDITOR` at
   `lemclient --server-name session-<pid>`. Rationale: with the systemd
   daemon running, every interactive `lem` would otherwise either fail to
   listen or, worse, route its own `git commit` into the invisible headless
   daemon. `valid-server-name-p` (`frontends/daemon/protocol.lisp:93`)
   accepts this name shape (alphanumerics, `_.-`, ≤64 chars).
4. **`GIT_EDITOR` is forced (not merely defaulted) for the editor's own
   children; `VISUAL`/`EDITOR` are filled only when unset.** This mirrors the
   legacy `server-configure-editor-environment` and guarantees that Git
   started from inside Lem always calls back into *this* Lem, regardless of
   what the parent shell exported.
5. **Shell-level environment wiring is out of scope.** The user decided that
   `EDITOR=nvim` stays system-wide (see the Nix section); no shell exports
   `EDITOR`/`VISUAL`/`GIT_EDITOR` pointing at `lemclient` yet.
6. **The systemd unit targets `default.target`, all `yanni` homes, and the
   stable imperative-profile path.** Details and rationale in the Nix
   section.
7. **User-visible behavior changes are accepted:** no tmux focus handoff
   (the client no longer switches the invoking tmux pane to Lem and back),
   and `lemclient` with no reachable daemon errors unless
   `--alternate-editor` is given (no silent fresh-Lem fallback).

## Part 1 — this repository (the Lem fork)

Four commits. After each commit, `nix flake check path:$PWD` must pass. Note
the root flake imports the extension flake from the working tree
(`flake.nix:527-539`, `lemYathOutputs`), and the root flake's `checks` are
exactly the extension's checks (`flake.nix:591`) — so root and extension
always move together in one commit.

The daemon test suite is rove-based (`lem-daemon/tests` in
`frontends/daemon/lem-daemon.asd`) and is **not** part of `nix flake check`.
Run it per commit with SBCL and Qlot as the repository's Makefile does for
its other targets, e.g.:

```sh
qlot install   # once
qlot exec sbcl --non-interactive \
  --eval '(ql:quickload :lem-daemon/tests)' \
  --eval '(asdf:test-op :lem-daemon/tests)'
```

(If `qlot` is not set up in the environment, `nix develop` on the flake or
plain Quicklisp with the repo on the source registry is acceptable; the gate
is that all rove tests pass, including the new ones added below.)

### Commit 1 — in-session listener (Emacs `M-x server-start` parity)

All changes in `frontends/daemon/`, plus docs. The key observation, verified
against the code: `start-daemon-transport`
(`frontends/daemon/server.lisp:537-550`) has no dependency on headless
startup — it is invoked from `lem-if:invoke` of `daemon-implementation`
(`frontends/daemon/implementation.lisp:286`) but reads only `*daemon-name*`
and module-level state. The request dispatch (`server.lisp:370-445`) enqueues
`visit` and `eval` requests as plain editor events that operate on the
current frame — they already work when the current frame is the interactive
ncurses one. Only `attach` (and the frame-bound `input`/`resize`/`redisplay`,
which already error without an attached frame) assumes daemon mode.

Scope:

1. **`start-server` / `stop-server` functions.** In
   `frontends/daemon/server.lisp` add:
   - `start-server` — callable from a running interactive editor. Behavior:
     no-op returning the existing endpoint if this process's transport is
     already running (`*daemon-listener*` non-nil); otherwise validate and
     set `*daemon-name*` (default `"server"`), call
     `start-daemon-transport`, and return the endpoint. If binding fails
     because a *live* daemon already owns the endpoint (the transport layer's
     stale-endpoint handling distinguishes live from stale), retry once with
     the name `session-<pid>` (decision 3) before signaling. Accept
     `&key name` so callers and tests can pick names explicitly.
   - `stop-server` — stop the transport only (`stop-daemon-transport`),
     never the editor. Distinct from the exported `stop-daemon`, which exits.
2. **`daemon-server-start` / `daemon-server-stop` commands** — thin
   `define-command` wrappers over the two functions, with `message` feedback
   including the endpoint path. These are the interactive
   `M-x server-start` / `M-x server-stop` equivalents.
3. **Attach guard.** In the `(string= type "attach")` dispatch clause
   (`server.lisp:386-394`) or at the top of `handle-attach-on-editor`
   (`server.lisp:322`): when `*daemon-root-implementation*` is nil, send a
   structured protocol error (suggested code `"attach-unsupported"`, message
   telling the user to attach to a `lem --daemon` instead) and do not create
   an implementation. This keeps `lemclient -t` against an in-session
   listener a clean client-side error rather than a stolen ncurses screen.
4. **Kill-buffer hook.** The daemon currently has no kill-buffer handling
   (verified: no `kill-buffer` reference under `frontends/daemon/`), so
   killing a buffer with a pending blocking `visit` request leaks the request
   and hangs the client forever. The legacy server handled this
   (`server-kill-buffer-hook` in the extension counted a killed buffer as
   completed). Add `daemon-kill-buffer-hook`: for each request in
   `(request-buffer-list buffer)`, complete the request as finished
   (mirroring `complete-buffer-requests` with `abort-p` nil) but without
   buffer navigation side effects. Register it on the global
   `kill-buffer-hook` when the transport starts and deregister when it
   stops. This fixes the same leak in the headless daemon, not just
   in-session.
5. **Exports.** Extend the `:lem-daemon` defpackage
   (`frontends/daemon/package.lisp:37-49`) exports with: `:start-server`,
   `:stop-server`, `:daemon-server-start`, `:daemon-server-stop`,
   `:request-buffer-list`, and `:server-name` (add a trivial reader
   `(defun server-name () *daemon-name*)` — the extension needs it to build
   the `--server-name` argument in Commit 3). `request-buffer-list` already
   exists (`server.lisp:99`) and only needs exporting.
6. **Tests.** Extend `frontends/daemon/tests/integration.lisp` with
   in-session coverage. The existing suite drives a daemon through
   `invoke-daemon`; add cases that instead start only the transport via
   `start-server` inside an editor whose `*daemon-root-implementation*` is
   nil (the suite's helpers `send-request` / `visit-nowait` / `eval-primary`
   apply unchanged):
   - `eval` round-trips against the in-session listener;
   - a blocking `visit` completes via `daemon-edit-save-and-done`;
   - killing a buffer with a pending request completes the client (new hook);
   - `attach` returns the structured `attach-unsupported` error;
   - `start-server` name fallback: occupy the `server` endpoint directly via
     the transport layer (`transport:open-local-listener backend "server" …`,
     without going through `start-server`, so `*daemon-listener*` stays nil),
     then call `start-server` and assert it claims `session-<pid>`;
   - `stop-server` leaves the editor running and releases the endpoint.
7. **Docs.** Update `docs/daemon-client.md`: add a short "In-session server"
   subsection under "Using the implementation" documenting
   `M-x daemon-server-start`, the attach refusal, and the name-fallback
   behavior; move "socket activation, systemd user units" phrasing in
   "Current limits" (`docs/daemon-client.md:289-291`) to reflect that a
   systemd user unit now exists in the user's deployment (keep socket
   activation listed as future).

Verification gate (Commit 1):

```sh
nix flake check path:$PWD
# rove suite as above — all tests green, including the six new cases
```

### Commit 2 — daemon-capable editor image

Root `flake.nix` only.

1. In the `lem-ncurses` package (`flake.nix:358-366`), extend `systems`:

   ```nix
   systems = [
     "lem-ncurses"
     "lem-daemon"
     "tree-sitter-cl"
     "lem-tree-sitter"
   ];
   ```

   No new `lispLibs` are needed: `lem-daemon` depends on `lem/core` and
   `yason` (`frontends/daemon/lem-daemon.asd`), both already in the closure
   (the separate `lemclient` package at `flake.nix:393-421` already builds
   `lem-daemon` with the same `lispLibs`).
2. In the `lemYathOutputs` import (`flake.nix:527-539`), pass the native
   client through so Commit 3 can reference it:

   ```nix
   lem = {
     outPath = ./.;
     packages.${system} = {
       lem-ncurses = lem-ncurses;
       lemclient = lemclient;
     };
   };
   ```

   (The extension flake reads `lem.packages.${system}.lem-ncurses` today and
   will read `.lemclient` after Commit 3; standalone extension use via its
   own `inputs.lem` gets both attributes for free since that input *is* this
   flake.)

Verification gate (Commit 2):

```sh
nix flake check path:$PWD
nix build path:$PWD#lem-ncurses path:$PWD#lemclient
# Smoke test — headless daemon from the shipped image:
./result/bin/lem --daemon &        # result = lem-ncurses build
sleep 2
nix run path:$PWD#lemclient -- --eval '(length (lem:buffer-list))'
nix run path:$PWD#lemclient -- -t   # attach, verify a frame, detach (C-x C-c equivalent detaches the frame)
nix run path:$PWD#lemclient -- --stop-server
```

The `--eval` call must return a value; `--stop-server` must terminate the
daemon cleanly. (Interactive `lem` behavior is unchanged by this commit; the
legacy server still auto-starts and still exports a broken `GIT_EDITOR` —
that is removed in Commit 3, not here.)

### Commit 3 — atomic legacy-server removal and migration (extension)

All paths in this section are under `extensions/lem-yath/` unless prefixed
with `(root)`. This commit is atomic: partial application leaves either two
`bin/lemclient` providers or none, and breaks the vcs check.

**Deletions:**

- `lem-yath/src/server.lisp` (the entire legacy tmux/socat server)
- `lem-yath/src/server-windows.lisp`
- `scripts/lemclient.sh`
- `scripts/server-test.sh`
- `scripts/server-fixture.lisp`
- In `lem-yath/lem-yath.asd` (lines 14-15), the two components:

  ```lisp
  (:file "server" :if-feature (:not :os-windows))
  (:file "server-windows" :if-feature :os-windows)
  ```

**New file `lem-yath/src/daemon.lisp`** (add `(:file "daemon")` to the .asd
where the server entries were — it must load after `base.lisp`, which
provides `initialize-editor-feature`, `lem-yath/src/base.lisp:8`):

```lisp
;;;; In-session daemon listener and editor-child environment.
;;;;
;;;; The native lem-daemon transport replaces the retired tmux/socat server.
;;;; A configured interactive Lem listens on the daemon protocol so shell
;;;; and Git edit requests from its own children reuse this editor; a
;;;; headless `lem --daemon' already listens before the config loads, in
;;;; which case only the environment step below applies.

(in-package :lem-yath)

(defun daemon-client-pathname ()
  (alexandria:if-let ((override (uiop:getenv "LEM_YATH_CLIENT")))
    (uiop:parse-native-namestring override)
    (executable-find "lemclient")))

(defun daemon-configure-editor-environment (client)
  (let ((command (format nil "~a --server-name ~a"
                         (uiop:escape-shell-token
                          (uiop:native-namestring client))
                         (lem-daemon:server-name))))
    ;; Git children of this editor must call back into this exact process;
    ;; force GIT_EDITOR past whatever the parent shell exported.
    (setf (uiop:getenv "GIT_EDITOR") command)
    (unless (uiop:getenv "VISUAL")
      (setf (uiop:getenv "VISUAL") command))
    (unless (uiop:getenv "EDITOR")
      (setf (uiop:getenv "EDITOR") command))))

(defun daemon-server-start-maybe ()
  (handler-case
      (progn
        (lem-daemon:start-server)
        (alexandria:when-let ((client (daemon-client-pathname)))
          (daemon-configure-editor-environment client)))
    (error (condition)
      (message "lem daemon listener unavailable: ~a" condition))))

(initialize-editor-feature 'daemon-server-start-maybe)
```

Notes for the implementer:

- `lem-daemon:start-server` (Commit 1) is a no-op returning the endpoint
  when the transport already runs in-process (the headless daemon case), and
  falls back to `session-<pid>` when another process owns `server`; the
  `--server-name` argument built here therefore always names *this*
  process's endpoint.
- If startup proves racy under the vcs check (successive editor sessions in
  one fixture reusing a runtime directory), add one bounded retry around
  `start-server` here — see Risks.
- The legacy `add-hook`/`remove-hook` block at the bottom of the deleted
  `server.lisp` (exit and kill-buffer hooks) is **not** reproduced: transport
  shutdown and kill-buffer handling now live inside `lem-daemon` itself
  (Commit 1).

**`lem-yath/src/git.lisp`** — two clause replacements. In
`lem-yath-legit-commit-continue` (lines 339-346) replace:

```lisp
((server-buffer-requests)
 ;; ... comment retained ...
 (lem-yath-server-save-done))
```

with:

```lisp
((lem-daemon:request-buffer-list)
 ;; Git invokes the packaged blocking client for reword.  COMMIT_EDITMSG
 ;; still selects Legit's commit major mode, so its ordinary command would
 ;; incorrectly start a second `git commit'.  Save the file and release
 ;; the waiting Git process instead.
 (lem-daemon:daemon-edit-save-and-done))
```

and in `lem-yath-legit-commit-abort` (lines 365-368) replace the
`(server-buffer-requests)` → `(lem-yath-server-abort)` clause with:

```lisp
((lem-daemon:request-buffer-list)
 (lem-daemon:daemon-edit-abort))
```

Both `daemon-edit-save-and-done` and `daemon-edit-abort` are already
exported commands (`frontends/daemon/package.lisp:47-49`), callable as
functions. If the Windows configuration build (which compiles lem-yath
without a validated `lem-daemon`) breaks on the package reference, use the
late-binding fallback recorded under Risks.

**`flake.nix` (extension)** — the legacy shell client and its test plumbing:

- Delete the `lemClient = pkgs.writeShellApplication { ... }` block
  (lines 355-363; the one with `socat` and `tmux` in `runtimeInputs` reading
  `scripts/lemclient.sh`).
- Bind the native client near the existing
  `lemNcurses = lem.packages.${system}.lem-ncurses;` binding:

  ```nix
  lemClient = lem.packages.${system}.lemclient;
  ```

  Keeping the `lemClient` binding name minimizes the diff at every
  `${lemClient}/bin/lemclient` reference; both the AOT derivation
  (line 403, `export LEM_YATH_CLIENT=${lemClient}/bin/lemclient`) and the
  `lemYathEditor` wrapper (line 447) then point at the native client
  unchanged.
- In `lemYathEditor` (line 448) delete
  `export LEM_YATH_ALTERNATE_EDITOR="$0"` — it was consumed only by the
  deleted `scripts/lemclient.sh`, and the native client's explicit
  `--alternate-editor` policy deliberately replaces implicit fallback.
- AOT FASL count check (lines 436-441): with both server sources gone, the
  platform exclusion is obsolete. Replace:

  ```nix
  # ASDF selects exactly one platform-specific server implementation.
  expected=$(find ${self}/lem-yath/src -type f -name '*.lisp' ! -name 'server-windows.lisp' | wc -l)
  ```

  with:

  ```nix
  expected=$(find ${self}/lem-yath/src -type f -name '*.lisp' | wc -l)
  ```

- `lemYath` symlinkJoin (lines 538-542): remove `lemClient` from `paths`
  (leaving `[ lemYathEditor smtpSubmit ]`). The configured-editor package no
  longer ships any `bin/lemclient`; the native client is a separate package
  composed downstream (see the Nix repository section).
- Delete `apps.server-test` (lines 690-693, the
  `mkTestAppWithLemAndInputs lemYath [ pkgs.socat pkgs.util-linux ] ...`
  entry) and `checks.server` (line 833). This removes the last socat and
  util-linux test dependencies; keep the `mkTestAppWithLemAndInputs` /
  `mkCheckWithLemAndInputs` helpers, which other gates (e.g. dap) still use.

**Tests:**

- `scripts/vcs-test.sh`: delete lines 19-20:

  ```sh
  export LEM_YATH_SERVER_SOCKET="$root/server/server.sock"
  export LEM_YATH_SERVER_PANE_FILE="$root/server/server.sock.pane"
  ```

  No replacement is needed: the daemon transport falls back to
  `$XDG_CACHE_HOME/lem/runtime/` when `XDG_RUNTIME_DIR` is unset
  (`frontends/daemon/transport-unix.lisp:39-48`), and the test already sets a
  per-run `XDG_CACHE_HOME` (line 16), so sandbox runs stay isolated.
- `scripts/vcs-fixture.lisp` (line 1619): replace
  `(server-buffer-requests buffer)` with
  `(lem-daemon:request-buffer-list buffer)`. Keep the `server=` field name
  in the log format string and all screen assertions unchanged — the test
  retains its single-process end-to-end shape: a real `git rebase -i`
  round-trips through the in-session daemon listener via the forced
  `GIT_EDITOR`.
- `scripts/test-on-ex44.sh`: drop the `server)` case (lines 45-46) and
  remove `server` from the usage string (line 202).

**(root) `scripts/win-deploy.lisp`:** after `(ql:quickload :lem)` add
`(ql:quickload :lem-daemon)` so the Windows image contains the `lem-daemon`
package and the `git.lisp` references resolve. The daemon's Unix transport is
`#+linux`/`#+sbcl`-gated and the portable protocol/request layers compile
off-Linux by design (`docs/daemon-client.md`, Portability); this load
replaces the deleted `server-windows.lisp` stub. See Risks if it does not
compile cleanly on Windows.

**Docs (extension):**

- `README.md` lines 50-75: replace the legacy-client section ("The installed
  package still provides the legacy `lemclient` … no daemon implementation is
  part of this migration.") with a short section stating the native daemon
  model: `lem --daemon` + native `lemclient`, in-session listener in every
  configured interactive Lem, forced child `GIT_EDITOR`, and a pointer to
  `../../docs/daemon-client.md`. Mention explicitly that tmux focus handoff
  and the fresh-Lem fallback are gone, and that `--alternate-editor` is the
  explicit fallback mechanism.
- `README.md` lines 106-111 (the "an `emacsclient`-style `lemclient` backed
  by an owner-private local Unix socket … headless editor daemon" bullet in
  "What's in the port"): rewrite to describe the native daemon client and
  in-session listener; it *does* now support arbitrary evaluation and a
  headless daemon, and no longer does tmux-pane handoff.
- `docs/port-map.md` line 39 (the `server / emacsclient (built-ins)` row):
  rewrite the status cell — implementation is now
  `frontends/daemon/` in the fork plus `lem-yath/src/daemon.lisp`; blocking
  and no-wait positioned multi-file requests, save/clean finish, recoverable
  abort, `-t` terminal frames, `--eval`, `--stop-server`, named daemons; the
  remaining gaps are graphical frames and Windows.
- `docs/lem-capabilities.md` lines 1649-1676 (section "Reusable ncurses
  editor client — `lem-yath/src/server.lisp`, `scripts/lemclient.sh`"):
  rewrite header and body for the native daemon; the verification pointer
  changes from `scripts/server-test.sh` to the fork's `lem-daemon/tests`
  rove suite plus `scripts/vcs-test.sh` for the in-session Git round trip.
- `docs/parity-ledger.tsv` — this is a TSV; edit whole rows and re-validate:
  - Row `MISC-009` (line 156): implementation files →
    `lem-yath/src/daemon.lisp` (plus the fork's `frontends/daemon/`), deps
    drop `socat,tmux`, status can advance from `approximation` (one reused
    pane) to reflect a true headless daemon + in-session server; evidence →
    the fork daemon suite and `scripts/vcs-test.sh`; drop the
    `scripts/server-test.sh` reference.
  - Row `VCS-001` (line 70): remove `lem-yath/src/server.lisp` from the
    files column (the reword/abort routing now goes through `lem-daemon`);
    adjust the narrative phrase about the "isolated private blocking client"
    only if it names tmux/socat mechanics.
  - Re-run the validator: `python3 scripts/check-parity-ledger.py`.
- `(root) docs/daemon-client.md` lines 218-235 ("Compatibility and
  migration"): move to past tense — the legacy lem-yath client has been
  removed and the compatibility baseline is satisfied; keep the preserved
  behavior list as a statement of what was preserved.

Verification gate (Commit 3):

```sh
nix flake check path:$PWD                    # includes the vcs gate end-to-end
python3 extensions/lem-yath/scripts/check-parity-ledger.py
# Targeted gates (faster iteration than the full flake check; the root flake
# re-exposes the extension's test apps, flake.nix:585-589):
nix run path:$PWD#compile-check
nix run path:$PWD#boot-test
nix run path:$PWD#startup-test
nix run path:$PWD#vcs-test        # the in-session Git round-trip gate
# Residual-reference sweep — every command must print nothing:
grep -rn "lem-yath-server" extensions/lem-yath --include='*.lisp' --include='*.sh' --include='*.nix'
grep -rn "server-buffer-requests" extensions/lem-yath
grep -rn "LEM_YATH_SERVER_" extensions/lem-yath
grep -rn "LEM_YATH_ALTERNATE_EDITOR" extensions/lem-yath
grep -rn "lemclient.sh\|server-test.sh\|server-fixture" extensions/lem-yath
grep -rn "no-focus" extensions/lem-yath
grep -rn "socat" extensions/lem-yath
# bin/lemclient collision check — configured editor no longer ships a client:
nix build "path:$PWD#lem-yath" -o /tmp/lem-yath-check && test ! -e /tmp/lem-yath-check/bin/lemclient
# Legacy behavior gone from plain lem (manual): start the built editor in a
# terminal, run M-x lisp-eval or a terminal buffer, confirm GIT_EDITOR names
# the native client with --server-name and that no *server* socket/pane pair
# appears under $XDG_RUNTIME_DIR/lem-yath/.
# Daemon suite unaffected by the removal:
#   re-run the rove suite from Commit 1 — all green.
```

Note: `tmux` remains a dependency of the AOT *build harness* and several test
drivers (e.g. the AOT derivation runs Lem under a private tmux server,
extension `flake.nix:418-427`); that is build scaffolding, not an editor
runtime dependency, and is explicitly out of scope.

### Commit 4 (optional housekeeping) — retired standalone mirror

The standalone repository at `~/proj/lisp/lem-yath` was retired in favor of
this in-tree extension (its final commit: "docs: retire standalone
repository"). If it is still being mirrored, sync the extension tree once so
the retired mirror does not advertise the deleted tmux server; otherwise skip
this commit entirely. Do not resurrect it as a maintained copy.

## Part 2 — Nix repository (`~/proj/nix/computer`)

Execute only after Part 1 has landed on the fork's `main` (the flake input
`lem` follows `github:yathxyz/lem`). Cited line numbers are as of 2026-08-15.

### Systemd user service for `lem --daemon`

Precedent in the same file: the Emacs daemon service
(`home/default.nix:790-802`) and, structurally, the
`systemd.user.services.nodes-bib-export` unit (`home/default.nix:608`).

Add to `home/default.nix`, next to the existing lem wrapper wiring
(`lemYathProfileWrapper` is defined at line 332 and gated
`homeUsername == "yanni"` at line 605; `lemYathProfilePath` at line 321
already names the imperative profile):

```nix
systemd.user.services.lem-daemon = lib.mkIf (homeUsername == "yanni") {
  Unit = {
    Description = "Lem editor daemon";
    # The imperative profile may not be synced on this host yet; stay inert
    # instead of crash-looping.
    ConditionPathExists = "%h/.local/state/nix/profiles/lem-yath/bin/lem";
  };
  Service = {
    ExecStart = "%h/.local/state/nix/profiles/lem-yath/bin/lem --daemon";
    Restart = "on-failure";
    RestartSec = 5;
  };
  Install.WantedBy = ["default.target"];
};
```

Recorded decisions behind this shape:

- **All `yanni` homes**, via the same `homeUsername == "yanni"` conditional
  as the wrapper — not per-host. `ConditionPathExists` makes the unit inert
  on machines where `scripts/sync-lem-yath-profile` has never run.
- **`ExecStart` uses the stable imperative-profile path directly**
  (hash-independent). Daemon restarts pick up `sync-lem-yath-profile`
  upgrades without a Home Manager rebuild — the same resolution the
  `lemYathProfileWrapper` scripts perform, minus wrapper indirection systemd
  does not need. The profile's `bin/lem` is itself the extension's wrapper
  script, so the daemon inherits the full `LEM_YATH_*` environment and
  runtime `PATH` (compilers, git, LSPs) that interactive Lem gets.
- **`default.target`, not `graphical-session.target`**: the daemon is
  terminal-first (ncurses client) and must exist on ssh-only logins too.
  (Contrast the Emacs service, which is `startWithUserSession = "graphical"`.)
- **`Restart = "on-failure"`** means a deliberate
  `lemclient --stop-server` (clean exit) stays stopped, while a crash
  restarts within 5 s.
- **Client environment wiring: none** (user decision). `EDITOR = "nvim"`
  stays in `modules/common.nix:81`; no shell-level `EDITOR`/`VISUAL`/
  `GIT_EDITOR` changes. The daemon itself points *its own children's* editor
  variables at the client (fork-side behavior), so Git from inside Lem works
  with zero Nix changes. Shell-level wiring is an explicit future follow-up.

No change is needed in `pkgs/lem-yath-profile/default.nix`: it already
composes the native `lemclient` package with the configured editor
(`symlinkJoin { paths = [daemonClient configuredLem]; }`), and after fork
Commit 3 the configured editor no longer carries a colliding
`bin/lemclient`.

### Repin and rollout

```sh
cd ~/proj/nix/computer
nix flake update lem
scripts/sync-lem-yath-profile      # refresh the imperative profile (builds lem-yath-profile)
just home                          # nh home switch . — installs the new unit
systemctl --user daemon-reload
systemctl --user start lem-daemon
```

### Acceptance checks (deployment)

```sh
systemctl --user status lem-daemon          # active (running)
ls "$XDG_RUNTIME_DIR"/lem/                  # daemon endpoint present
lemclient --eval '(length (lem:buffer-list))'   # returns a value from a shell
lemclient -t                                # attaches a frame; detach leaves the daemon running
lemclient -t                                # reattach sees prior buffers/state
lemclient /tmp/spec-accept.txt              # blocks until C-x # (or C-c C-c) in the frame
git -c core.editor=lemclient commit --allow-empty   # opens COMMIT_EDITMSG via the daemon; abort with C-c C-k
lemclient --stop-server && systemctl --user status lem-daemon  # inactive (dead), not restarting
systemctl --user start lem-daemon
# In-session parity: run plain `lem` in a terminal; inside it, `git commit`
# from a terminal/legit buffer must open in that same interactive Lem (the
# session-<pid> listener), not in the headless daemon.
```

## Risks

Record outcomes against these when executing; they are known, not blockers.

1. **Windows `lem-daemon` compile is untested.** The transport is
   platform-gated, but if `(ql:quickload :lem-daemon)` in
   `scripts/win-deploy.lisp` fails on Windows, fall back to late binding in
   the two `git.lisp` clauses:

   ```lisp
   ((and (find-package :lem-daemon)
         (uiop:symbol-call :lem-daemon :request-buffer-list))
    (uiop:symbol-call :lem-daemon :daemon-edit-save-and-done))
   ```

   (and the analogous abort clause), and drop the win-deploy load.
2. **vcs-test session-restart socket race.** The vcs fixture drives several
   editor phases in one sandbox; if a fresh session starts while the previous
   session's endpoint is mid-cleanup, `start-server` may transiently fail.
   Mitigation, only if the gate is flaky: one bounded retry (~200 ms) around
   `lem-daemon:start-server` inside `daemon-server-start-maybe`. The
   transport's stale-endpoint handling makes the retry safe.
3. **User-visible behavior changes** (accepted, decision 7): no tmux focus
   handoff; no silent fresh-Lem fallback when no daemon is reachable —
   `lemclient` errors unless `--alternate-editor` is supplied.
4. **`C-c C-c` shadowing between `daemon-edit-mode` and legit commit-mode.**
   Both the daemon minor mode's `daemon-edit-save-and-done` and the
   dispatching `lem-yath-legit-commit-continue` resolve a client-owned
   `COMMIT_EDITMSG` to "save and release Git", so either precedence outcome
   is behaviorally equivalent — but watch the vcs gate's REWORD assertions,
   which check which command the key resolves to
   (`scripts/vcs-fixture.lisp` around line 1625).

## Out of scope

- Shell-level `EDITOR`/`VISUAL`/`GIT_EDITOR` wiring (deferred by user
  decision).
- Socket activation, SDL2/webview attachment, daemon state persistence
  across restarts (`docs/daemon-client.md`, Current limits).
- Broader test-suite restructuring of the extension (tiered checks,
  per-feature runtime paths, unit-test migration of pure-logic suites) — a
  separate follow-up already discussed with the user.
- Windows daemon validation (milestone 9 of `daemon-client.md`).
