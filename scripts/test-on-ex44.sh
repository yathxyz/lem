#!/usr/bin/env bash
# Mirror this worktree to ex44 and run the requested test there.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${LEM_YATH_TEST_HOST:-ex44}"
remote_root="${LEM_YATH_REMOTE_ROOT:-/home/yanni/.cache/codex/lem-yath-parity}"
test_name="${1:-all}"

case "$host" in
  "" | -* | *[!A-Za-z0-9._:@-]*)
    echo "Refusing unsafe SSH host: $host" >&2
    exit 2
    ;;
esac

case "$remote_root" in
  "" | *[!A-Za-z0-9._/-]*)
    echo "Remote root must be an absolute path using only letters, digits, '.', '_', '-', and '/': $remote_root" >&2
    exit 2
    ;;
  /*) ;;
  *)
    echo "Remote root must be absolute: $remote_root" >&2
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
  actions)
    remote_command='nix run path:$PWD#actions-test'
    ;;
  orderless-completion)
    remote_command='nix run path:$PWD#orderless-completion-test'
    ;;
  snippets)
    remote_command='nix run path:$PWD#snippet-test'
    ;;
  lsp-snippets)
    remote_command='nix run path:$PWD#lsp-snippet-test'
    ;;
  lsp-project)
    remote_command='nix run path:$PWD#lsp-project-test'
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
  ui-parity)
    remote_command='nix run path:$PWD#ui-parity-test'
    ;;
  *)
    echo "Usage: $0 [all|check|compile|boot|completion|completion-lifecycle|auto-completion|actions|orderless-completion|snippets|lsp-snippets|lsp-project|prompt-completion|daily-workflows|electric-editing|ui-parity|interactive|structural|notes|editing]" >&2
    exit 2
    ;;
esac

printf -v remote_root_q '%q' "$remote_root"
remote_root="$(
  ssh -o BatchMode=yes "$host" "
    set -eu
    requested=$remote_root_q
    cache_root=\$(realpath -m -- \"\$HOME/.cache\")
    tmp_root=\$(realpath -m -- /tmp)

    validate_root() {
      candidate=\$1
      case \"\$candidate/\" in
        \"\$cache_root\"/*)
          test \"\$candidate\" != \"\$cache_root\"
          ;;
        \"\$tmp_root\"/*)
          test \"\$candidate\" != \"\$tmp_root\"
          ;;
        *)
          return 1
          ;;
      esac
    }

    resolved=\$(realpath -m -- \"\$requested\")
    if ! validate_root \"\$resolved\"; then
      echo \"Refusing to use --delete outside \$cache_root or \$tmp_root: \$resolved\" >&2
      exit 2
    fi

    mkdir -p -- \"\$resolved\"
    resolved=\$(realpath -- \"\$resolved\")
    if ! validate_root \"\$resolved\"; then
      echo \"Refusing symlink-resolved destination outside \$cache_root or \$tmp_root: \$resolved\" >&2
      exit 2
    fi
    case \"\$resolved\" in
      *[!A-Za-z0-9._/-]*)
        echo \"Refusing destination with unsafe characters: \$resolved\" >&2
        exit 2
        ;;
    esac
    printf '%s\\n' \"\$resolved\"
  "
)"
printf -v remote_root_q '%q' "$remote_root"
rsync -a --delete \
  --protect-args \
  --exclude .git/ \
  --exclude .direnv/ \
  --exclude result \
  "$root/" "$host:$remote_root/"

ssh -o BatchMode=yes "$host" \
  "cd $remote_root_q && LEM_YATH_CHECK_ID=ex44-$$ $remote_command"
