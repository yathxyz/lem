# Persistent Lem daemon and clients

Status: implemented for Linux, SBCL, and ncurses. The Unix transport, native
client, independent-frame routing, blocking edit lifecycle, and integration
tests live under `frontends/daemon/`. Windows and graphical attachment remain
later milestones.

## Purpose

Lem should support an Emacs-like persistent editor process. The daemon owns the
editor state, while short-lived command-line clients submit work or attach a
user interface. Closing the final user interface must not discard buffers,
history, subprocesses, or other daemon-owned state.

The first supported platform is Linux with SBCL and the ncurses frontend. The
protocol and ownership model must not make Windows support impractical. Windows
support is an intended later milestone, not an unspecified afterthought.

## Using the implementation

Build the normal ncurses editor and the native client, then start a named or
default daemon:

```sh
make ncurses
make daemon-client
./lem --daemon

# In other processes:
./lemclient README.md                 # wait until the edit is finished
./lemclient --no-wait README.md       # submit and return immediately
./lemclient +120:4 README.md          # line 120, column 4
./lemclient -t README.md              # attach an independent terminal frame
./lemclient --eval '(length (lem:all-buffers))'
./lemclient --stop-server
```

The Nix flake exposes `.#lemclient` as both a package and an app. The ncurses
runtime is split from the optional language-mode bundle so the short-lived
client image does not load LSPs and every extension.

A blocking file request enables `daemon-edit-mode` in each requested buffer:

- `C-x #` finishes without saving;
- `C-c C-c` saves and finishes;
- `C-c C-k` aborts the request without killing the daemon or buffer.

`Ctrl-C` in a blocking SBCL client sends protocol cancellation and exits with
status 130. A client connection failure is an error unless
`--alternate-editor COMMAND` was explicitly supplied.

## Implemented architecture and performance

The daemon uses one serialized Lem editor loop. Each attached connection owns a
real Lem frame and a session-scoped headless implementation containing its own
dimensions, selected window, cursor, and redisplay state. Shared buffers remain
ordinary daemon-owned Lem buffers. Routed input events retain their client
session across multi-key prefixes, preventing concurrent terminals from
completing one another's key sequences.

Connection readers and writers run concurrently, but all editor mutations enter
the editor event queue. This matches the important Emacs daemon semantics: one
persistent editor state, independent frames, shared buffer contents, and UI
disconnects that do not stop the process.

Redisplay composes a terminal cell matrix using Lem's width calculation, sends
one full screen on attachment or width change, and then sends only changed rows
plus the cursor. The client applies those rows through ncurses. Consequently,
wire traffic for an ordinary keystroke is proportional to the changed rows,
while server-side composition remains proportional to the visible cell matrix.
The protocol bounds every frame at 1 MiB and file collections at 64 entries.

This is suitable for a local Unix socket and avoids the original full-screen
broadcast design, but it is not a claim of performance parity with GNU Emacs's
decades-optimized C redisplay engine. Lem still composes a complete logical
screen before diffing, and version one does not transmit face/color runs.

## Required user model

The eventual command-line surface should be recognizably similar to Emacs,
without requiring exact option spelling where Lem has different concepts:

```text
lem --daemon[=NAME]
lemclient [OPTIONS] [FILE ...]
lemclient -t [FILE ...]
lemclient --eval FORM
lemclient --stop-server
lemclient --server-name NAME
lemclient --alternate-editor COMMAND
```

`lem --daemon` starts a long-lived editor process, loads configuration once,
creates or claims a private endpoint, and remains alive with no attached UI.

`lemclient FILE` submits a file request to an existing daemon. Waiting versus
non-waiting behavior must be explicit and must preserve the useful semantics of
the existing lem-yath client: positioned files, multiple files, save-and-finish,
clean finish, and recoverable abort.

`lemclient -t` attaches the current terminal and creates a client-owned frame.
Disconnecting removes that frame only. The daemon and shared buffers remain
alive.

`lemclient --eval FORM` evaluates Common Lisp in the daemon and returns a
machine-readable success value or a useful error. Evaluation is intentionally
part of the first useful version because shell tools and agentic harnesses need
a direct automation surface. It is allowed only over an authenticated local
same-user connection by default.

When no daemon is reachable, `lemclient` must fail clearly unless an explicit
alternate-editor policy was supplied. Automatic fallback belongs in an option
or host service configuration, not in an implicit client side effect.

## State and frame semantics

- One daemon owns buffers, buffer-local state, histories, registers, kill rings,
  projects, subprocesses, language servers, and configuration.
- Every interactive attachment owns an independent frame, dimensions, selected
  window, redisplay stream, and frontend resources.
- Multiple clients may attach concurrently. Input and resize events are routed
  only to the originating client frame.
- Buffer contents are shared immediately between frames.
- A client disconnect must clean up its frames and pending client-specific
  requests without stopping the editor.
- A frontend failure must not corrupt daemon state or terminate unrelated
  clients.
- Stopping the daemon must use the normal modified-buffer policy and provide a
  deliberate force option. It must not silently discard edits.
- Configuration and global startup hooks run once per daemon. Frame and frontend
  hooks run for each attachment and detach cleanly.

A single shared frame broadcast to all clients is not sufficient. It would
reproduce terminal multiplexing rather than the Emacs daemon model.

## Process boundaries

The core feature must not depend on tmux, screen, socat, or another process or
terminal-session manager. The daemon and client should be Common Lisp programs
built from the Lem tree. Native libraries already required by a frontend, such
as ncurses, are not process-lifecycle dependencies.

Service managers may supervise the daemon, but are integrations rather than
requirements. The NixOS/Home Manager deployment may offer systemd user units
and socket activation after the standalone daemon lifecycle works correctly.

## Transport and security

Version one uses a local Unix-domain socket in an owner-private runtime
directory. The protocol must have:

- an explicit version and capability negotiation;
- bounded message and collection sizes;
- request identifiers, structured errors, and cancellation;
- separate request types for file visits, evaluation, frame attachment, input,
  redisplay, resize, detach, and shutdown;
- no Common Lisp reader use on untrusted protocol framing;
- same-user endpoint validation in addition to filesystem permissions where the
  platform exposes peer credentials;
- safe stale-endpoint handling without unlinking another process's endpoint;
- deterministic cleanup on normal exit and recoverable behavior after crashes;
- no network listener unless the user explicitly enables and secures one.

Arbitrary evaluation is privileged. A future remote transport must not inherit
local `--eval` permission by default.

Named daemons require independent endpoints and metadata. Endpoint selection
must be deterministic and must reject unsafe names rather than interpolating
them into paths unchecked.

## Frontend architecture

The current Lem implementation is process-global, and the server frontend
broadcasts display updates. The implementation must evolve so display and input
can be associated with a client session and frame. Possible designs include:

1. Make frontend implementations frame- or session-scoped in the editor core.
2. Keep a persistent routing implementation that owns multiple frontend
   sessions and routes each view to exactly one connection.

The design should minimize dynamic global rebinding and keep the editor command
loop serialized unless evidence requires concurrent buffer mutation. Connection
I/O may be concurrent, but editor mutations must enter through the editor event
queue.

The existing JSON-RPC server transport and rendering messages should be reused
where their lifecycle and security properties fit. Existing broadcast and
first-login assumptions must not be treated as required compatibility.

The ncurses client should reuse Lem's terminal input decoding and drawing
behavior rather than introducing a second incompatible key or width model.

## Portability

Linux/SBCL/ncurses is the first acceptance target. Platform abstractions must be
identified before Unix details spread through the editor lifecycle:

| Concern | Linux first implementation | Windows direction |
| --- | --- | --- |
| Local transport | Unix-domain socket | Named pipe or a comparably private local IPC transport |
| Peer identity | Socket peer credentials and filesystem ownership | Named-pipe owner/ACL and client identity checks |
| Runtime metadata | XDG runtime directory | Per-user local application data/runtime location |
| Background process | Foreground daemon, optionally systemd-supervised | Console/background process, optionally service-supervised |
| Terminal attachment | ncurses client | Windows terminal frontend using the existing supported console path |

The wire protocol, request state machine, and frame lifecycle must be portable
Common Lisp. OS-specific endpoint and credential operations should live behind
a small backend protocol. Windows support may initially omit Unix-only service
manager integration, but not shared buffers, independent frames, or safe eval.

SDL2 and webview attachments are later milestones. The architecture must allow
them, but version one does not require implementing every frontend.

## Compatibility and migration

The existing lem-yath `lemclient` behavior is the compatibility baseline for
file requests, except for tmux focus handoff. The new client supersedes its
shell, socat, socket, and pane-metadata implementation.

Useful behavior to preserve includes:

- `+LINE[:COLUMN]` locations;
- multiple files in one request;
- blocking and no-wait requests;
- a visible per-buffer server-edit state;
- save-and-finish, finish-clean, and recoverable abort;
- editor environment suitable for `EDITOR`, `VISUAL`, and `GIT_EDITOR`;
- bounded requests and owner-private local metadata.

The compatibility promise does not include graphical frame creation in version
one, tmux pane switching, or silently starting a daemon.

## Initial acceptance milestones

1. A headless daemon initializes exactly once and remains alive without clients.
2. A Common Lisp client submits positioned single- and multi-file requests.
3. `--eval` returns values and structured errors over an authenticated local
   connection.
4. One ncurses client attaches, edits, resizes, disconnects, and reconnects
   without losing daemon state.
5. Two ncurses clients have independent frames while observing shared buffer
   edits.
6. Client crashes and malformed requests leave the daemon and other clients
   usable.
7. Modified-buffer shutdown policy, forced shutdown, endpoint cleanup, named
   daemons, and alternate-editor fallback are covered by integration tests.
8. The existing lem-yath file-request test matrix passes without tmux-specific
   assertions.
9. Windows transport and terminal prototypes validate that the abstractions do
   not require a Linux-only redesign.

## Remaining design questions

- Whether session routing should eventually become a public core implementation
  abstraction rather than the daemon's routed-input extension.
- Whether a future graphical attachment may own several Lem frames. Version one
  maps each attachment to exactly one frame.
- Whether `--eval` should add typed JSON values. Version one returns a JSON
  object containing bounded readable Common Lisp representations.
- How interactive prompts requested by noninteractive file clients are surfaced.
- Whether socket activation starts an uninitialized daemon or only transports
  requests to an already initialized process.
- How graphical clients discover and negotiate frontend-specific capabilities.
- Which daemon state should be persisted across process restarts; persistence is
  separate from surviving client disconnects.

These questions should be resolved through focused prototypes and lifecycle
tests before committing to a broad public protocol.

## Current limits

- Linux/SBCL Unix sockets and ncurses are the only implemented transport and
  interactive client combination. The wire framing is portable, but extracting
  endpoint and peer-credential operations behind a Windows-capable backend,
  then validating a named-pipe/console prototype, remains outstanding.
- Terminal text, cursor position, wide-character layout, resize, keys, and
  bracketed paste are supported. Face/color runs and mouse events are not yet
  transported.
- Socket activation, systemd user units, SDL2/webview attachment, and daemon
  state restoration after a process restart remain future integrations.
