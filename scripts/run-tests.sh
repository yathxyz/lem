#!/usr/bin/env bash
# Run a rove test system with a meaningful exit code.
# (make test and `asdf:test-system` always exit 0; .qlot/bin/rove needs roswell.)
# Usage: scripts/run-tests.sh [system]   (default: lem-tests)
set -euo pipefail
cd "$(dirname "$0")/.."
SYSTEM="${1:-lem-tests}"
exec sbcl --dynamic-space-size 4GiB --noinform --no-sysinit --no-userinit \
  --non-interactive \
  --load .qlot/setup.lisp \
  --eval "(ql:quickload :$SYSTEM :silent t)" \
  --eval "(uiop:quit (if (rove:run :$SYSTEM) 0 1))"
