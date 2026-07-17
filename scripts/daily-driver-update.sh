#!/usr/bin/env bash
# Fork-owned update loop (SPEC.md M0-4).
# `make update` alone does NOT rebuild the image; always rebuild after pulling.
# Run terminal Lem inside tmux (M0-3) until DS-3 crash recovery lands.
set -euo pipefail
cd "$(dirname "$0")/.."
git fetch upstream --tags
git pull --rebase origin main
qlot install
make ncurses
echo "lem rebuilt: $(ls -lh lem | awk '{print $5, $9}')"
