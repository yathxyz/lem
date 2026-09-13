# Native Legit frame ownership

Legit status, commit-list, diff and source panes now belong to the initiating
frame through window parameters. Each context retains exact private buffer and
overlay objects. Opening or refreshing a second repository does not replace the
first frame's pane references or diff contents. Configured Git log actions use
the active context and buffer metadata rather than a fixed buffer name.

Closing a view is synchronous. Direct deletion of either pane closes its peer
without recursively freeing the initiating window twice. A stale closed context
cannot close a replacement context. Frame teardown retires the exact context;
an editor event disposes its private buffers after backend teardown. Buffers
displayed in another live frame are retained, and shared file buffers are never
part of this disposal list.

Core `delete-window` rejects a live window outside the current frame before
calling a backend. Attached windows are checked through their parent; repeated
deletion of an already freed window remains harmless.

Popups anchored to an owned pane are also closed before that pane is freed.
This includes cursor-following progress messages created during interactive
rebase. Unrelated popups and other frames remain untouched. Without that cleanup,
redisplay could ask a surviving popup to read its deleted parent's cursor and
terminate the daemon.

Collector rendering into reused pane buffers runs inside a scoped read-only
override. The resulting view stays read-only, including after renderer failure.
This prevents TODO/status refresh from clearing the pane and then raising a
read-only error while rebuilding it.

Configured Git message editors retain their exact originating context. Finish
and abort cannot select a replacement or foreign pane; remote refresh retains
the initiating pane role, and merge preview remains in its owning source pane.
Fixed message-name collisions refuse a second editor before changing pending text
or context. The actual rebuilt profile passes 29 focused caller checks using two
terminal clients; successful Git commit mutations are simulated in that fixture,
while the broad VCS gate exercises real synthetic Git repositories.

## Focused acceptance

Run `scripts/legit-frame-test.py` with `LEM_BIN` and `LEMCLIENT_BIN` naming built
configured binaries, and Xvfb, xdotool and Git on `PATH`. The driver uses private
XDG directories and two synthetic repositories without replacing `HOME` or
using the live desktop. It never loads product source.

Two real SDL clients open independent status/diff views. Native keyboard input
drives refresh, close, navigation and staging. Administrative eval captures exact
frame state, establishes a nonempty selection, queues a refresh in its owning
frame, and inspects cleanup. Assertions cover both pane points and contents,
current buffer/window/point/selection, a foreign-window deletion refusal, the
next native key after peer closure or client loss, isolated staging, and private
view reclamation while source buffers survive.

Before the fix, the prepared configured profile disconnected during the second
SDL client's Legit command. The first client's pane was outside the second
frame but still live, and the old display code tried to delete it. A separate
source negative control confirms that the original `delete-window` frees this
foreign pane instead of refusing it. The final rebuilt configured SDL gate now
passes all 14 assertions with its actual binaries and no product-source overlay.
The focused source window suite passes 14 groups and the Legit suite passes 25,
including dependent-popup cleanup after pane closure. The configured native Git
rebase gate also passes all 27 assertions. The final broad configured VCS gate
remains pending; these focused results do not establish its completion.

## Boundary

The generic typeout popup implementation in `src/typeout.lisp` still has global
window state. Legit help and error popups use it. The separate `lem/peek-source`
implementation in `src/ext/peek-source.lisp` also shares window and buffer state;
grep, xrefs/LSP and project source previews use it. This change does not establish
independent ownership for those generic popups and previews; they need separate
reproduction and acceptance. The queued refresh in this fixture exercises display
ownership, not a new background Git polling service.
