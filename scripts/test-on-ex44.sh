#!/usr/bin/env bash
# Mirror this worktree to ex44 and run the requested test there.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${LEM_YATH_TEST_HOST:-ex44}"
remote_root="${LEM_YATH_REMOTE_ROOT:-/home/yanni/.cache/codex/lem-yath-parity}"
test_name="${1:-all}"

case "$remote_root" in
  /home/*/.cache/* | /tmp/*) ;;
  *)
    echo "Refusing to use --delete outside a remote cache or /tmp: $remote_root" >&2
    exit 2
    ;;
esac

case "$test_name" in
  all)
    remote_command='nix flake check path:$PWD && nix run path:$PWD#interactive-test && nix run path:$PWD#structural-test'
    ;;
  check)
    remote_command='nix flake check path:$PWD'
    ;;
  compile)
    remote_command='nix run path:$PWD#compile-check'
    ;;
  boot)
    remote_command='nix run path:$PWD#boot-test'
    ;;
  completion)
    remote_command='nix run path:$PWD#completion-test'
    ;;
  completion-lifecycle)
    remote_command='nix run path:$PWD#completion-lifecycle-test'
    ;;
  auto-completion)
    remote_command='nix run path:$PWD#auto-completion-test'
    ;;
  orderless-completion)
    remote_command='nix run path:$PWD#orderless-completion-test'
    ;;
  interactive)
    remote_command='nix run path:$PWD#interactive-test'
    ;;
  structural)
    remote_command='nix run path:$PWD#structural-test'
    ;;
  notes)
    remote_command='nix run path:$PWD#notes-test'
    ;;
  editing)
    remote_command='nix run path:$PWD#editing-test'
    ;;
  prompt-completion)
    remote_command='nix run path:$PWD#prompt-completion-test'
    ;;
  daily-workflows)
    remote_command='nix run path:$PWD#daily-workflows-test'
    ;;
  electric-editing)
    remote_command='nix run path:$PWD#electric-editing-test'
    ;;
  *)
    echo "Usage: $0 [all|check|compile|boot|completion|completion-lifecycle|auto-completion|orderless-completion|prompt-completion|daily-workflows|electric-editing|interactive|structural|notes|editing]" >&2
    exit 2
    ;;
esac

printf -v remote_root_q '%q' "$remote_root"
ssh -o BatchMode=yes "$host" "mkdir -p $remote_root_q"
rsync -a --delete \
  --exclude .git/ \
  --exclude .direnv/ \
  --exclude result \
  "$root/" "$host:$remote_root/"

ssh -o BatchMode=yes "$host" \
  "cd $remote_root_q && LEM_YATH_CHECK_ID=ex44-$$ $remote_command"
