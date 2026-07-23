# Patch provenance

The `lem-*.patch` files in this directory preserve the reviewed boundaries of
the former standalone lem-yath patch queue. Their changes are integrated into
the surrounding `yathxyz/lem` source tree and the build does not apply them.
They remain as evidence for the parity ledger and for tracing the imported
history.

`jsonrpc-timeout-cleanup.patch` is different: JSON-RPC is an external pinned
dependency, so the root Qlot and Nix builds apply it to that dependency. Keeping
the patch here records its lem-yath provenance while giving every Lem package
the JSON-RPC API required by the integrated LSP sources.
