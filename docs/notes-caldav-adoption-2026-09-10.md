# Notes and CalDAV adoption map

This is the preserved assessment of the revisions below. The integration now
contains the selected semantic library and explicit two-file notes adapter;
see [the adopted boundary](../extensions/structured-notes/README.md) and
[the adapter contract](../extensions/structured-notes/ADAPTER.md). Those documents
record the focused tests and adaptations. The broader calendar and mixed Yath
adapters described here remain unadopted.

The preserved branch is useful, but importing its history or enabling its full
adapter unchanged is the wrong integration boundary. Adopt its existing semantic
model and source-preserving libraries in reviewable layers, keep the current Org
commands and files, and make new Markdown and calendar workflows explicit until
their daemon behavior is verified. There is no need to replace Lem's buffer core.

Assuming this is a local adoption assessment, existing Org documents remain
authoritative, no format migration or remote calendar access is authorized by
this subtask, and changing the default notes format is a separate product
decision. No runtime tests, imports, migrations, account discovery, calendar requests or
user-note reads were performed. Only local Git/source/configuration inspection
was used. This report and its component manifest are the only new artifacts.

## Compared revisions and actual scope

| Ref | Revision |
| --- | --- |
| Current daemon/display integration examined | `08346fa6c95862f24e38586554176448b624e0e7` |
| Preserved `caldav-robustness` | `dd570df2ddb279f52f8d7b302f8538a7777b37d7` |
| Common ancestor | `5af59f9b9c8007ec6e6e8def582dcaa29f7974d5` |

The branches have 49 integration-only and 2,568 CalDAV-only commits. The current
integration contains no `extensions/structured-notes` tree. The preserved tree
has 2,091 files: 332 under `src/`, 27 under `lem-yath/`, seven under `lem/`,
294 test files, 452 scripts, 858 specification/evidence files, 118 interoperability
files, and its ASD/README/generated report. Runtime Lisp is approximately 13.4 MB;
the generated conformance report alone is approximately 1.4 MB. This is a large
library/evidence project, not a small calendar mode.

Crucially, comparing the CalDAV branch with the common ancestor shows **no changes
to `src/`, `frontends/`, or `lem.asd`**. No CalDAV-specific Lem core patch needs
adoption. Comparing the two tips directly produces many misleading core and
frontend differences because the CalDAV branch lacks the later daemon work.

Outside `extensions/structured-notes`, its actual changes are limited to:

- `qlfile`, `qlfile.lock`, `flake.nix`: CXML dependency declaration.
- `extensions/lem-yath/lem-yath/lem-yath.asd`: one agenda component entry.
- `extensions/lem-yath/lem-yath/src/apps/agenda-dispatch-extensions.lisp`.
- `extensions/lem-yath/lem-yath/src/apps/agenda-diary.lisp` and corresponding
  `scripts/agenda-test.sh`; the diary change should **not** be adopted as written.
- `extensions/lem-yath/scripts/agenda-dispatch-test.sh` and `tui-driver.sh`.
- `.gitignore`, `Makefile`, and five `docs/*CALDAV*`/`RFC8607-INTEROPERABILITY.md`
  design/operations documents.

Do not copy its root Nix file, lem-yath ASD, old `server.lisp`, or frontend tree
over integration. In particular, the old ASD would restore the removed server
entry and remove `private-files`/`daemon`; apply only the new agenda entry.

## Exact implementation boundaries

[notes-caldav-component-map.tsv](notes-caldav-component-map.tsv) records every
declared runtime component, its owning ASDF system, Git blob and pinned source
revision. It contains 366 rows, excludes test systems, and is derived from the
preserved ASD and Git tree rather than filename guesses.

| Existing system | Components | Dependencies and adoption boundary |
| --- | ---: | --- |
| `lem-structured-notes` | 37 | Alexandria; pure semantic/source layer, Org/LSM CSTs, iCalendar values, minimal edit/migration/notes plans. No live HTTP dependency. |
| `lem-structured-notes/lem-notes-adapter` | 2 | Main system and Lem core except under its `nix-build` feature. Live file-buffer notes workflow, workspace configuration and ordinary unsaved edits. |
| `lem-structured-notes/lem-yath-adapter` | 27 | Main notes adapter and configured lem-yath. Org agenda projection, mixed views, capture, roam, editing/Babel/publishing adapters. Many components mutate command/binding ownership at load time. |
| `lem-structured-notes/caldav-xml` | 186 | Main system, CXML, Yason, Ironclad. XML, discovery/plans, sync/write/merge/scheduling stores and recovery graphs. This is much larger than its name suggests. |
| `lem-structured-notes/lem-live-source-adapter` | 5 | XML system, notes adapter, Bordeaux Threads. Scalar/multi-file buffer coordination and write/merge/retention/projection reviews. |
| `lem-structured-notes/caldav-http` | 109 | XML system, Dexador, Bordeaux Threads, Ironclad, CL+SSL, usocket, CFFI. Live transports plus interoperability drivers; keep out of initial notes startup. |

The main system's `test-op` delegates to `lem-structured-notes/tests`, which
depends on the entire HTTP system and lists 289 test components. Thus testing
the pure notes system currently expands to the complete calendar suite. A small
notes adoption needs a focused test-system boundary selecting the existing pure
tests; it should not claim to have run the broader suite.

Use the final `dd570df2d` blobs when importing a selected system. The historical
commits below establish provenance and explain choices; they are not an ordered
cherry-pick recipe. Most also change large ledgers and depend on earlier work.

| Provenance | Relevant paths/behavior |
| --- | --- |
| `b4befc51c`, `b88ea4ba1` | `src/migration.lisp`: stale-safe migration planning, later crash recovery. Keep dry-run planning separate from publication. |
| `f2d653e0e`, `ff020f1cb`, `e502bde63`, `d27d08290`, `b7044e759` | `src/notes-workflow.lisp`, `lem/notes-workflow.lisp`: unsaved note plans, verified edits, daily/capture flows, pinned workspaces. |
| `d22dbc0b4`, `5c0140cf4`, `5b32f4d44`, `81d914d5f` | `lem-yath/roam-adapter.lisp`: typed LSM nodes/backlinks/references and later Markdown-primary capture behavior. |
| `6944fb78a`, `6972b9754`, `084bf7252` | Mixed agenda notes and dispatcher extension; adopt the final agenda component and its single ASD entry when needed. |
| `b84484b59` | `src/webdav-xml.lisp` and CXML additions in root dependency files. CXML is required for the XML/calendar layer, not the pure notes layer. |
| `f22351635`, `62ec5343f`, `45289eced`, `c5718886a` | `lem/live-source-coordinator.lisp`: scalar/multi-file application, exact source discovery, editor-thread enforcement. Do not adopt an earlier coordinator without the thread fix. |
| `764438883` | Declares the branch's selected CalDAV umbrella milestone complete and activates its Markdown phase; does not establish full standards compliance. |
| `84d1306f0`, `dd570df2d` | Markdown-primary milestone assessment and verification repair. These are milestone/test-evidence commits, not a ready-made daemon integration patch. |
| `bdce41c01` | Test-only Bash pin for the old tmux TUI driver. Useful if retaining those tests temporarily; it is not a runtime dependency or a daemon-client test. |

## Conflicts and risks that need deliberate treatment

**Org defaults and preservation.** The branch's M11 goal makes canonical `lsm/1`
Markdown primary and freezes Org as an auxiliary provider. That differs from the
current task's promise to preserve the user's Org environment. Loading
`lem-yath/notes-keybindings.lisp` changes `SPC n r d t`, `SPC n r d d`, and
`SPC n j j` to Markdown daily/journal destinations. `lsm-capture.lisp` installs
Markdown-primary `SPC o`; `mixed-agenda-view.lisp` installs mixed `SPC m a` and
relocates the Org route to `SPC m A`. These changes are not mere parser support.
Keep current defaults and add explicit entry commands for the first adoption.
Make installation deliberate instead of relying on these load-time effects.

**Roam function replacement.** The final `roam-adapter.lisp` installs eight
`fdefinition` replacements, including node scanning, backlink parsing, insertion,
link following, capture rendering and template selection. It recognizes explicit
`lsm/1` frontmatter and retains a legacy Markdown fallback, but can change ordinary
capture semantics. Integrate through owned provider/dispatch hooks in the current
roam code, with exact Org/legacy Markdown/LSM fixtures. Avoid layering another
set of saved-old-function wrappers over the existing replacements.

**Diary regression.** `3b8d68d4c` changes the literal sexp diary prefix from `%%`
to `%`; `34ac5953c` only adjusts the old gate's expectation to match. Local installed
Emacs 30.2 and 31.0.90 `lisp/calendar/diary-lib.el.gz` both define
`diary-sexp-entry-symbol` as `"%%"`. Current Lem root output matches that default.
The inspected 30.2 library is
`/nix/store/kdjahjsd6bafj3b3gjx5gb9m989av8ha-emacs-30.2/share/emacs/30.2/lisp/calendar/diary-lib.el.gz`.
Preserve it. Imported adapter tests at `tests/lem-yath-adapter/test.lisp:6748`
also expect the changed single-percent output and need correction. A passing
rewritten string assertion is not evidence of Emacs diary interoperability.

**Unsaved edits and recovery.** The semantic source protocol already validates
provider/source identity, revision, content fingerprint and metadata fingerprint
(`src/source-protocol.lisp`, `assert-edit-plan-current`). Keep those guarantees.
The notes adapter's `lem-replace-buffer-source` erases/reinserts using an existing
Lem change group; assess it against the new proposal API's independent undo
boundary and rollback under failing hooks. The proposal API should provide the
shared buffer mutation boundary while domain plans retain their richer semantic
checks. Do not replace the multi-file CalDAV journal with single-buffer proposal
objects: it also coordinates disk publication, exact target sets and uncertain
external effects. Pending network decisions must reconcile after daemon failure
without interpreting restart as approval or retry authority.

**Daemon/frame ownership.** The branch's live-source coordinator explicitly
requires the creating/editor thread and serializes bounded source sets; preserve
that final implementation. Mixed-agenda background refresh already copies dirty
buffer snapshots, bounds scan inputs, coalesces requests and checks generations.
It still owns raw threads and buffer-local request state, and queues callbacks
with plain `lem:send-event`. Verify detached clients, independently focused frames,
shared views, killed source buffers, cancelled jobs and daemon restart against the
new job/recovery architecture before advertising daemon readiness.

**Nix and workspace roots.** The current configured package AOT-compiles lem-yath
against the packaged image. The branch does not add structured-notes to that
production startup; adding CXML alone does not deploy the feature. Add selected
systems and source/FASL ownership to the current AOT path, preserving immutable
system handling. Do not copy its old wrapper or entire flake. The notes adapter
pins `WORKDIR`/`PUBLIC_ORG_DIR` process-wide, using the launch directory for relative
paths and `~/work` as its fallback. The current computer configuration already
supplies those environment variables. Initialize explicit canonical roots in the
daemon once; do not derive them from a newly attached client's working directory.
New daily/journal destinations use `.md` in the existing roam layout, and the LSM
public workspace is optional where current Org code has a default public root.
Verify these distinctions with synthetic roots before enabling commands.

**Source and historical evidence.** `test-lem-yath-adapter.sh` explicitly loads the
branch's ASD and init plus the dispatcher extension, but still defaults `LEM_BIN`
to a PATH executable; other scripts load their checkout's `.qlot/setup.lisp`.
Add assertions for the actual Lem core, lem-yath and structured-notes directories,
and run a freshly packaged configured image. Historical frozen-Org inventory
checks intentionally reference old blobs; retain them as archival evidence and
add a separate integration acceptance record rather than relabeling that baseline.

## Adoption sequence and bounded daily gates

1. **Import the semantic notes layer without activating defaults.** Bring the
   final main system's 37 component paths from the manifest, the minimal two-file
   Lem adapter, their license/design material and focused existing test fixtures.
   Adapt the ASD to declare only the imported systems and focused tests at this
   stage; do not create a second parser/model. Compile in the current Nix image.
   Gate: explicit `lsm/1` versus ordinary Markdown discrimination, UTF-8 spans,
   unknown Org blocks preserved, metadata retained, stale plan refusal and exact
   one-undo unsaved edits. No account/network dependency should load here.

2. **Expose explicit mixed-notes workflows.** Import the coherent 27-file
   lem-yath adapter group and final dispatcher component, but replace automatic
   default takeover with explicit activation/owned dispatch. Keep current Org
   bindings and diary syntax. Gate on fixture-only roots: mixed read-only agenda,
   source jump, TODO/schedule/deadline/tag/priority edits and undo, refresh after
   unsaved source edits, Org/legacy Markdown/LSM roam and ambiguous-ID refusal.
   Then capture/daily/journal finalize, abort, reopen and explicit save. Compare
   all original Org and unrelated fixture bytes before/after each operation.

3. **Prove native daemon workflows and preserve existing notes behavior.** Run
   the current Nix `notes`, `roam`, `roam-backlinks`, `org`, `agenda`,
   `agenda-dispatch`, `agenda-undo`, and `agenda-clock` checks first. Reuse branch
   `test-lem-yath-adapter.sh`, `test-lsm-{capture,daily,journal,id,roam}-tui.sh`,
   and `test-mixed-agenda-{note,capture,clock,derived}-tui.sh` as behavior fixtures,
   then add a focused native terminal/SDL two-client gate: one client edits while
   another refreshes/reviews, disconnect either, reconnect, and retain unsaved
   text without stale acceptance or focus theft. The branch's authoritative
   `spec/org-agenda-regression-suites.tsv` now lists **25**, not the 23 in its
   older milestone prose; run the full serial inventory before changing defaults.
   Its tmux driver remains test infrastructure only. Babel/nodes-sync/publishing
   tests may use isolated PostgreSQL/Python/pandoc dependencies; they are not
   permission to publish or synchronize real notes.

4. **Adopt calendar planning/recovery before live accounts.** Import the complete
   existing XML and live-source subsystem groups with their declared dependencies
   and relevant tests. Avoid cherry-picking one write/merge file out of its store
   graph. First gates use synthetic iCalendar/XML and private fixture stores:
   unknown-property round trip; recurrence/timezone bounds; stale ETag and local
   edit conflicts; scalar/multi-file failure at each publication boundary;
   pending review and journal restart without duplicate external action. Load
   the HTTP group only after it has a shared-job adapter and an explicit account
   workflow with preview, bounded I/O, cancellation and inspectable results.

5. **Live use and migration are separate later decisions.** Start with a selected
   disposable account only when explicitly authorized, then bounded read-only
   synchronization before write/invitation scenarios. Never replay the branch's
   archived interop admission scripts: their recorded authority was one-shot
   and exhausted. Existing Org-to-LSM dry-run plans can be exposed, but no batch
   migration, replacement of originals, publication or default-format switch is
   needed for the daemon replacement. Any later migration must have a concrete
   per-file preview, unchanged-source check, non-overwriting destination, backup
   and recovery result before approval.

## Claim to retain

The pinned generated report explicitly says **NOT FULLY COMPLIANT**, with open
normative inventory sentinels. It records 2,780 ledger rows: 2,618 implemented,
160 partial and two not started. All 15 declared CalDAV umbrella gates and all
10 Markdown-primary requirement rows are marked implemented, but that is the
branch's declared profile, not independent certification and not evidence that
this current daemon package passed those gates. Keep that distinction in the
consolidation report and record newly executed integration checks separately.
