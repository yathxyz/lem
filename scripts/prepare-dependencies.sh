#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
jsonrpc_glob="$project_dir/.qlot/dists/jsonrpc/software/jsonrpc-ref-"'*'

# Deliberately leave the glob unquoted: exactly one locked Qlot checkout must
# exist. An unmatched glob or multiple checkouts is a packaging error.
# shellcheck disable=SC2086
set -- $jsonrpc_glob
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "Unable to identify the locked Qlot JSONRPC source" >&2
    exit 1
fi

jsonrpc_dir=$1
if grep -q '(defun remove-callback-for-id' "$jsonrpc_dir/connection.lisp"; then
    exit 0
fi

patch --batch --forward \
    -d "$jsonrpc_dir" \
    -p1 \
    < "$project_dir/extensions/lem-yath/patches/jsonrpc-timeout-cleanup.patch"
