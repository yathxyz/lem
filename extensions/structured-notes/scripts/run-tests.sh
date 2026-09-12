#!/usr/bin/env bash
# Local semantic fixtures only; requires an already installed dependency setup.
set -euo pipefail
cd "$(dirname "$0")/.."
notes_test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lem-structured-notes.XXXXXX")
trap 'rm -rf -- "$notes_test_tmp"' EXIT
TMPDIR="$notes_test_tmp" "${LEM_STRUCTURED_NOTES_SBCL:-sbcl}" \
  --dynamic-space-size 4GiB --noinform --no-sysinit --no-userinit \
  --script scripts/run-tests.lisp
