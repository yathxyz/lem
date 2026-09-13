# Explicit Lem notes adapter

`lem-structured-notes/lem-notes-adapter` adopts the two notes bridge files from
`dd570df2ddb279f52f8d7b302f8538a7777b37d7`. It depends only on the adopted semantic
library, Lem core, and shared buffer proposals. It installs explicit commands;
it changes no Org command, binding, file association, diary syntax, or default
capture format. The calendar and 27-file Yath adapters are not loaded.

## Startup and unavailable roots

The host calls this once, before admitting notes commands:

```lisp
(lem-structured-notes/lem-adapter:configure-lem-notes-workspaces
 :work-root #p"/absolute/existing/work/"
 :public-root nil) ; or an explicit existing public directory
```

The same canonical roots are idempotent; a different configuration is refused.
No environment variable, home fallback, attached client's directory, file or
directory creation is involved. Roots may be resolved once through a configured
symlink; target components below those canonical roots must be ordinary
directories and regular files, without symlinks or dot segments.

An invalid or unavailable root signals `notes-adapter-error` with a short message
and a `notes-adapter-error-code`, leaving the prior configuration intact. The
host can report that failure and continue running the editor. With no successful
configuration, notes commands report `:unavailable-workspace`; they do not infer
another root. A missing destination parent reports `:unavailable-parent`. Create
`roam/` and `roam/journal/` explicitly before their first use.

## Daily use

| M-x command | Behavior and destination |
| --- | --- |
| `structured-notes-lsm-open-today` | Open or reuse `WORK/roam/YYYY-MM-DD.md`; unchanged reuse has no edit or undo entry. |
| `structured-notes-lsm-journal-entry` | Append an entry to `WORK/roam/journal/YYYYMMDD.md`. |
| `structured-notes-lsm-capture` | Prompt for key and title. `i` uses `WORK/inbox.md`, `t` uses `WORK/todo.md`, `r` uses `WORK/readlist.md`, and `p` uses explicitly configured `PUBLIC/inbox.md`. |
| `structured-notes-lsm-assign-id` | Assign or reuse the current LSM heading's persistent ID. |

These are explicit operator actions. Opening a file can run ordinary Lem file
hooks. Existing live buffers supply their unsaved text. New buffers remain
private until the semantic plan and its unsaved application succeed; failed
planning or capacity admission does not publish a partial note. Commands select
the resulting buffer only after success. Library daily/journal/capture helpers
accept `:switch-p nil` for callers that manage their own windows.

No command saves a file or creates a directory. Use normal explicit save after
reviewing the buffer. Current disk text, encoding, write-date baseline and Org
files remain unchanged by notes edits. Existing-ID and daily reuse do not
consume proposal capacity. Ordinary Markdown and Org text are not implicitly
converted into `lsm/1`.

## Planning and the mutation boundary

All buffer operations belong on the editor thread. Call
`lem-current-lsm-snapshot` before semantic edit planning; it returns the pure
snapshot and an opaque live source context. For document planning, call
`lem-capture-notes-source` and pass `lem-notes-source-base` to the pure planner.
That base is a copied string, or NIL for a new empty file.

The context retains the exact buffer object, monotonic edit tick, filename,
configured authority, and original text. The semantic revision also contains
the buffer identity and tick. A change followed by undo, a renamed source, a
deleted/recreated buffer, or a mismatched snapshot cannot reuse that context.
Capture at application time is insufficient: callers must keep the context
obtained before constructing their plan.

`lem-stage-notes-document-plan (context plan)` and
`lem-stage-lsm-edit-plan (context plan snapshot)` validate the original context
and the domain plan, then return a shared proposal and the one-based Lem focus
position. An identical document result returns NIL instead of a proposal. The
LSM helper additionally returns the verified candidate snapshot; acquire a new
live snapshot before planning a subsequent edit. Staging does not change text,
point, windows, files, or hooks. The ordinary shared proposal list/review supplies
human accept/reject; closing its view retains the proposal.

The corresponding `lem-apply-*` functions are for a deliberately requested edit.
They use the same staging path and shared proposal application, with a leading
and trailing undo boundary. One undo removes the notes edit while preserving an
earlier human insertion. Read-only sources are refused. Failed modification
hooks roll back the original text and source point; direct adapter application
releases its failed private proposal. Shared review also refuses a buffer whose
visited filename changed after staging. No separate erase/insert
mutation path remains.

Source snapshots are limited to 1 MiB of characters. Initial ordinary visits
reject files above 4 MiB of bytes before reading; the character bound is checked
again after the visit. Shared proposals enforce their existing 64-object,
1-MiB-per-text and 16-MiB aggregate retention limits. Literal target checks govern
local editor visits; filesystem publication and its clobber checks remain the
normal explicit Lem save operation.

## Recovery and verification

Adapter loading and checkpoint restoration visit no note files and invoke no
file hooks. Generic buffer recovery restores plain modified text with no visited
filename. Notes edit APIs refuse that unnamed buffer with `:unavailable-buffer`;
the human must explicitly associate a file before making a fresh plan. Neither
old planning contexts nor approvals become valid through restoration.

The focused `lem-structured-notes/lem-notes-adapter-tests` suite uses temporary
work/public directories and a fake editor. It covers pinned roots and unsafe
targets, fresh edits and independent undo, planning-time ABA, deleted/recreated
sources, document-plan provenance, read-only buffers, failed hooks, proposal
capacity, unsaved daily/journal/capture/ID workflows, and inert recovery. Native
daemon acceptance and configured startup wiring are separate integration gates.
