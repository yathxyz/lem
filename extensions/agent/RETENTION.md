# Session capacity and deliberate cleanup

Managers admit at most 64 loaded sessions and 64 stored session slots. Tests or
hosts can lower this with `make-manager :maximum-sessions`; values above 64 are
rejected. Creation reserves both limits before starting the journal actor.
Uncertain initial writes keep their reservation. A failed thread launch before
any writer exists releases its reservation. No session is evicted by age or use.

Startup counts canonical lowercase 32-hex JSON filenames without retaining a
directory catalog. It examines at most the session limit in payloads per restore
pass, including malformed records. Existing overflow remains on disk and is
reported; it does not prevent manager startup. Directory iteration order is
unspecified. Inventory pages are sorted and bounded; they can inspect unloaded
records without attaching actors or running historical work. Noncanonical names
are listed as unaddressable manual-inspection entries and do not consume slots;
the agent never creates such names. Unsafe symlinks, nonregular files, and
oversized files remain untouched and require filesystem inspection.

`session-capacity` returns an I/O-free copied status with `limit`, `loaded`,
`reserved`, `unloaded`, and an optional `pending_cleanup` ID. Reservations include
initialization still in progress. Each admitted journal has the core's existing
2 MiB encoded bound; archive and transcript ceilings still apply together.
Manually supplied older or malformed files can exceed these application limits;
the shared reader imposes its independent 16 MiB bound before parsing.

The following are **blocking worker APIs**:

- `list-session-journals manager :after cursor :limit n` returns at most 64 name
  entries, a next cursor, and the total JSON-name count. Reserved loaded IDs and
  pending deletion IDs remain in inventory even when no file exists. A final empty page ends
  traversal. This total includes noncanonical names and is not the slot count.
- `inspect-session-journal manager id` returns a copied validated record, SHA-256
  of the exact bytes read, and a diagnostic. Malformed content has a fingerprint
  and diagnostic with unknown contents/counts. A loaded reservation whose write
  never reached disk has the explicit `missing` fingerprint and unknown contents.
  Inspection never normalizes work
  into a running session or checkpoints it.
- `discard-session-journal manager id fingerprint :acknowledge-uncertain t`
  deliberately removes that entire inspected journal. The caller must obtain
  human confirmation for its exact ID, fingerprint, and stored contents. Unknown
  tool outcomes, interrupted/failed history, and malformed contents require the
  acknowledgement flag. A stored running status in unloaded history is inert
  and uncertain, never evidence of an active worker.

A loaded session must first be explicitly closed. Cleanup waits for its closing
actor to finish, including when the closing checkpoint failed, and refuses while it owns any live provider, tool, or cancellation
worker. Old handles stay closed; inspection and cached views confer no execution
authority. Subscribers retain the core's enqueue-only, nonblocking contract.
Deletion neither reverses an external effect nor saves an editor buffer. Separate
composer drafts remain after journal deletion and cannot assume their old session
still exists.

Filesystem work uses a dedicated maintenance lock. Ordinary manager lookups and
capacity reads never wait for disk I/O. Shutdown keeps the exclusive directory
lease until actors and in-progress maintenance finish. Deletion re-reads the
fingerprint, unlinks, and fsyncs the directory before freeing a slot. A failed
cleanup keeps one exact pending deletion receipt and blocks new admissions and
other deletions. Refresh can inspect that receipt even if unlink already removed
the file. Deliberately retry the same ID/fingerprint to fsync its absence and
finish cleanup. Changed content is refused. Manager restart re-counts actual
files; it never replays deleted work.

The optional `lem-agent/retention-ui` system provides `agent-journals`. Return
inspects a complete inventory row, `n` advances a page, `g` refreshes, and `q`
closes a view. In an inspection, `x` confirms permanent session closure and `d`
confirms whole-history deletion, including uncertain outcomes and omitted preview
text. Counts are explicitly stored counts: live composers may contain newer text.
Inspection limits its JSON preview to 65,536 characters. Eight views and eight
pending operations are allowed. All I/O and receipt waiting runs on workers;
completion never selects a window or overwrites a replacement for a killed view.

Source acceptance covers 12 retention groups and four UI groups: concurrent
admission, failed initialization/launch, bounded malformed startup, pagination,
inert inspection, stale fingerprints, worker ownership, unknown tool outcomes,
fsync failure and exact retry, lease retention without blocking manager lookups,
copied fingerprints, killed views, and changes during human confirmation. These
source checks are distinct from the configured native-client integration gate.
