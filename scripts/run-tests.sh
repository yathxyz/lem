#!/usr/bin/env bash
# Run a rove test system with a meaningful exit code.
# (make test and `asdf:test-system` always exit 0; .qlot/bin/rove needs roswell.)
# Usage: scripts/run-tests.sh [system]   (default: lem-tests)
# LEM_QUICKLISP_SETUP may reuse an installed dependency environment.
set -euo pipefail
cd "$(dirname "$0")/.."
exec sbcl --dynamic-space-size 4GiB --noinform --no-sysinit --no-userinit \
  --script scripts/run-tests.lisp "${1:-lem-tests}"
