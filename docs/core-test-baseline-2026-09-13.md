# Existing core test failures

The full `lem-tests` run reports six failing suites out of 75, with 14 failed
assertions/errors. Each reported failure also reproduces at the completed
prior milestone, `7287ad1f8`. Focused comparisons against `c47e1e9e8` produce
identical output after normalizing checkout paths and object addresses. These
are retained failures, not a passing full-suite claim.

| Suite | Reproduced cause or discrepancy |
| --- | --- |
| `pbt/kernel-undo-conformance` | Existing undo smoke and two exact-seed model conformance failures. |
| `pbt/layout-conformance` | The test frontend lacks the `get-char-width` method required by the reduced wide-character case. |
| `pbt/redisplay-cache` | The test calls the four-argument fingerprint function with three arguments. |
| `mcp-server/integration` | Its buffer deletion assertions expect removal of modified text that the existing handler refuses. |
| `emergency-save` | An earlier checkpoint test disables global checkpoint mode; this test does not establish its required enabled state. It passes alone on both revisions. |
| `display-cache` | Old fingerprint arity and associated expectations. |

The audit used clean isolated checkouts, source-identity assertions, the same
SBCL and installed dependencies, and the production JSON-RPC patch. The baseline
preloads its own shell mode, which its file tests reference without declaring;
the current test system now declares that dependency. No original worktree was
modified. Exact seeds, commands, runners and paired logs are retained in
`/home/yanni/proj/lisp/.recovery/2026-09-10-lem-integration/validation/notes-daily/`,
including `lem-goal4-baseline-audit.md` and `lem-goal4-audit-comparison.json`.

The new window, Legit, listener, notes and proposal regressions have separate
focused source and native configured acceptance. The full-suite failures still
need a separate repair of their tests and conformance discrepancies before
claiming a clean repository-wide gate.
