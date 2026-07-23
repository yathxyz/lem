# Patch provenance

The `lem-*.patch` files in this directory preserve the reviewed boundaries of
the former standalone lem-yath patch queue. Their changes are integrated into
the surrounding `yathxyz/lem` source tree and the build does not apply them.
They remain as evidence for the parity ledger and for tracing the imported
history.

`jsonrpc-timeout-cleanup.patch` is different: JSON-RPC is an external pinned
dependency, so the integrated lem-yath package still applies that patch while
overriding the dependency derivation.
