# Structured notes semantic library

This optional library provides source-preserving Org and LSM parsing, typed
iCalendar values and recurrence, local notes plans, and explicit migration
operations. Loading it installs no editor commands or keybindings and changes
no notes defaults. It does not discover accounts, resolve DNS, dereference URI
evidence, or perform HTTP requests.

The only ASDF systems in this adoption are `lem-structured-notes` and
`lem-structured-notes/tests`. The main system depends on Alexandria; ASDF/UIOP
provides pathname support. Durable migration operations use SBCL's POSIX
facilities on Linux. Those operations are explicit calls, not load-time work.
Node ID generation uses `/dev/urandom` when requested. Workspace resolution
accepts explicit roots; a future daemon adapter must pin those roots once.

## Provenance and scope

The source snapshot is `dd570df2ddb279f52f8d7b302f8538a7777b37d7` from the
preserved `caldav-robustness` branch. [provenance.tsv](provenance.tsv) records
original and destination Git blobs, whole-file imports, exact extracted forms,
and deliberate adaptations. The repository's [MIT license](../../LICENCE)
already matches the source snapshot byte for byte.

All 37 originally declared semantic source files are unchanged. One additional
`src/caldav-uri.lisp` component contains pure URI helpers extracted from three
otherwise excluded files. The original semantic write classifiers referenced
these helpers from the XML system; keeping that accidental dependency would
break the standalone library. The extraction includes bounded URI resolution,
same-origin/resource comparisons, DNS-name syntax validation, and their data
types. It imports no XML, transport, account discovery, or synchronization code.

The focused suite retains 29 original semantic test files and their runner.
Four ASCII calendar fixtures now use the existing `ascii-octets` helper instead
of an XML-owned encoder. Small common test helpers are extracted into
`tests/fixtures.lisp`; the only specification fixture is the pinned
`spec/leap-second-snapshot.tsv`. Its source URLs and dates are historical fixture
metadata, not a claim that external data was refreshed during this adoption.
Three existing URI cases are extracted into `tests/caldav-uri-test.lisp`.

The remaining calendar systems, conformance ledgers, interoperability drivers,
live notes adapters, and Yath adapters are excluded. Exported symbol names in
the unchanged original package file do not imply that excluded implementations
are available. This import makes no claim about broad CalDAV conformance or
live daemon notes workflows.

## Focused gate

With local dependencies already installed:

```sh
LEM_QUICKLISP_SETUP=/path/to/installed/.qlot/setup.lisp \
LEM_STRUCTURED_NOTES_SBCL=/path/to/sbcl \
  bash extensions/structured-notes/scripts/run-tests.sh
```

The script starts a fresh SBCL image, uses a private temporary fixture/cache
directory, verifies that the ASD and every component belong to this checkout,
and runs the custom ASDF test operation with a failing process exit code on any
error. It requires all 390 semantic and three extracted URI test definitions.
The migration tests exercise temporary-file publication, injected persistence
failures, recovery, rollback, and refusal to overwrite divergent content. They
do not open user notes or carry out a user-data migration.

The gate checks dependencies before loading, after loading, and after testing.
No structured-notes XML/HTTP system, CXML, Dexador, Drakma, CL+SSL, usocket, or Lem
editor runtime may load. Quicklisp's download boundary is disabled after loading
the local setup. Missing dependencies fail instead of being downloaded. The
repository's generic Rove runner is not used because this suite has its own
`define-foundation-test` runner.

Live buffer adoption remains separate: it needs the current proposal API's
single undo unit and hook-safe rollback, buffer identity/revision captured at
planning time, explicit workspace roots, and source/daemon acceptance tests.
