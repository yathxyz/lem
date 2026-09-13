# Native client display milestone

Status: implementation and acceptance work following the configured-daemon
foundation at `5348a27b0`. Protocol 2, native SDL attachment and styled terminal
rendering are implemented. Acceptance gates cover packaging and client failures.

This milestone gives terminal and SDL clients the same shared-buffer,
independent-frame model. The daemon remains the only editor; clients own input
and rendering. Both client implementations and their protocol code are Common
Lisp. Existing Vi/Evil-style configuration remains in the daemon.

## Display representation

Protocol 2 requires shipping editor and client together. A screen
row contains its text and styled runs. Each run records its starting cell column,
text, foreground/background colors, and bold/underline/reverse flags. Colors use
RGB hex strings; absent colors use the screen's defaults. Unicode continuation
cells and combining characters stay attached to their owning text cells.

Full screen updates contain every row. Incremental updates identify changed row
indices and include both text and runs, so a face-only change triggers redisplay.
Screen metadata includes default foreground/background and cursor position,
shape, color, mouse-mode enablement and terminal Escape delay.
Rows are composed in the daemon using the existing window/floating-window order;
modelines, highlighted backgrounds, and end-of-line fill retain their attributes.
Protocol message and display-dimension limits remain enforced.

The terminal client applies native ncurses attributes. The SDL client renders
the same rows using the existing SDL/font facilities where practical, without
starting a second local editor. `lemclient -c` opens an independent graphical
attachment. SDL initialization occurs only when graphical attachment is requested.

## Input and lifetime

Keyboard and paste input use per-connection routing. Validated
mouse press/release, movement, and wheel messages carry cell coordinates and
button information. GUI pixels are converted to cells at the client boundary.
Resize belongs to the originating frame. Rendering and input errors must release
that client without stopping other clients or the daemon.

A synchronous prompt or completion command retains its originating client's input
until it returns or is cancelled. Other clients' input is queued during that
command; administrative evaluation and background callbacks remain available.
This protects the existing recursive prompt stack, Vi state and completion
context. Agent decisions will be asynchronous session records, so waiting for an
agent approval will not hold this synchronous prompt boundary.

The existing `close-frontend` method already makes ordinary `exit-lem` close the
active client frame. Preserve this behavior; explicit daemon shutdown remains a
separate operation. Closing the last client retains modified buffers and running
Lisp/shell work. Terminal teardown restores terminal settings. GUI close destroys
only its local window and connection.

## Acceptance

- Unit coverage for Unicode cell composition, face runs, background fill,
  face-only changes, mouse validation, and screen decoding.
- Two native terminal clients, two SDL clients, and a mixed pair independently
  select/scroll/resize while editing the same buffer.
- Check actual native terminal input and rendering through PTYs. Respect the
  client's Escape decoding delay when generating separate Escape and prefix keys.
- Exercise SDL under an isolated display and inspect rendered output. Cover
  keyboard input, paste, mouse selection/wheel, resize, and normal window close.
- Kill one client, continue in another, close the final client, and reconnect to
  the retained buffers and Lisp state. Reuse the configured daemon acceptance
  tests and source identity checks from the foundation milestone.

Private text recovery is integrated separately; see `daemon-recovery.md` for its
checkpoint interval, independent inspector and restoration limits. The shared
jobs toolkit and native Lisp agent harness are also integrated; see
`managed-jobs.md` and `native-agent-integration.md` for their acceptance and limits.

Run `nix build .#checks.x86_64-linux.native-client-display` to exercise actual
terminal clients through PTYs and SDL clients under a private Xvfb display. The
check output contains `acceptance.log` and `display.png`. It requires no running
desktop or tmux. `scripts/daemon-client-display-test.py` is an external Python
test driver; the editor, client protocol, input handling and renderer are Lisp.
`checks.x86_64-linux.native-terminal-failure` exercises local input/argument errors,
daemon loss and normal close through a real PTY and verifies terminal settings are
restored. The source daemon suite checks that stalled peers release both reader
and writer threads after queue overflow and daemon shutdown.

The SDL client uses a fixed character grid and bundled fonts. It preserves text
faces, Unicode width, modelines and cursor styles. Embedded images and rich
graphical widgets are not represented by this protocol yet. SDL owns input and
rendering on its process main thread; socket reception runs separately. Ctrl-Shift-V
pastes the local SDL clipboard as literal text. Vi state follows the buffer,
with pending temporary operator state retained during frame context switches.
