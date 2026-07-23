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
    remote_command='nix flake check path:$PWD --option max-jobs 2 && nix run path:$PWD#interactive-test --option max-jobs 2 && nix run path:$PWD#structural-test --option max-jobs 2'
    ;;
  check)
    remote_command='nix flake check path:$PWD --option max-jobs 2'
    ;;
  compile)
    remote_command='nix run path:$PWD#compile-check'
    ;;
  compilation)
    remote_command='nix run path:$PWD#compilation-test --option max-jobs 2'
    ;;
  terminal)
    remote_command='nix run path:$PWD#terminal-test --option max-jobs 2'
    ;;
  server)
    remote_command='nix run path:$PWD#server-test --option max-jobs 2'
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
  llm-keybinding)
    remote_command='nix run path:$PWD#llm-keybinding-test'
    ;;
  llm-models)
    remote_command='nix run path:$PWD#llm-models-test --option max-jobs 2'
    ;;
  llm-backend)
    remote_command='nix run path:$PWD#llm-backend-test --option max-jobs 2'
    ;;
  llm-http)
    remote_command='nix run path:$PWD#llm-http-test --option max-jobs 2'
    ;;
  llm-oauth)
    remote_command='nix run path:$PWD#llm-oauth-test --option max-jobs 2'
    ;;
  llm-workflow)
    remote_command='nix run path:$PWD#llm-workflow-test --option max-jobs 2'
    ;;
  llm-tools)
    remote_command='nix run path:$PWD#llm-tools-test --option max-jobs 2'
    ;;
  llm-mcp)
    remote_command='nix run path:$PWD#llm-mcp-test --option max-jobs 2'
    ;;
  claude-code)
    remote_command='nix run path:$PWD#claude-code-test --option max-jobs 2'
    ;;
  lisp-eval)
    remote_command='nix run path:$PWD#lisp-eval-test'
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
  real-lsp)
    remote_command='nix run path:$PWD#real-lsp-test'
    ;;
  tree-sitter)
    remote_command='nix run path:$PWD#tree-sitter-test --option max-jobs 2'
    ;;
  dap)
    remote_command='nix run path:$PWD#dap-test --option max-jobs 2'
    ;;
  project-navigation)
    remote_command='nix run path:$PWD#project-navigation-test'
    ;;
  project-outline)
    remote_command='nix run path:$PWD#project-outline-test'
    ;;
  persistence)
    remote_command='nix run path:$PWD#persistence-test'
    ;;
  bookmarks)
    remote_command='nix run path:$PWD#bookmark-test'
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
  roam)
    remote_command='nix run path:$PWD#roam-test --option max-jobs 2'
    ;;
  roam-backlinks)
    remote_command='nix run path:$PWD#roam-backlink-test --option max-jobs 2'
    ;;
  org)
    remote_command='nix run path:$PWD#org-test'
    ;;
  org-modern)
    remote_command='nix run path:$PWD#org-modern-test --option max-jobs 2'
    ;;
  org-download)
    remote_command='nix run path:$PWD#org-download-test --option max-jobs 2'
    ;;
  org-nodes-sync)
    remote_command='nix run path:$PWD#org-nodes-sync-test --option max-jobs 2'
    ;;
  agenda)
    remote_command='nix run path:$PWD#agenda-test'
    ;;
  agenda-undo)
    remote_command='nix run path:$PWD#agenda-undo-test --option max-jobs 2'
    ;;
  agenda-filter)
    remote_command='nix run path:$PWD#agenda-filter-test --option max-jobs 2'
    ;;
  agenda-view)
    remote_command='nix run path:$PWD#agenda-view-test --option max-jobs 2'
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
  direnv)
    remote_command='nix run path:$PWD#direnv-test --option max-jobs 2'
    ;;
  electric-editing)
    remote_command='nix run path:$PWD#electric-editing-test'
    ;;
  ui-parity)
    remote_command='nix run path:$PWD#ui-parity-test'
    ;;
  business-visual)
    remote_command='nix run path:$PWD#business-visual-test --option max-jobs 2'
    ;;
  cursor-state)
    remote_command='nix run path:$PWD#cursor-state-test'
    ;;
  snipe)
    remote_command='nix run path:$PWD#snipe-test'
    ;;
  avy)
    remote_command='nix run path:$PWD#avy-test --option max-jobs 2'
    ;;
  documents)
    remote_command='nix run path:$PWD#documents-test --option max-jobs 2'
    ;;
  notmuch)
    remote_command='nix run path:$PWD#notmuch-test --option max-jobs 2'
    ;;
  *)
    echo "Usage: $0 [all|check|compile|compilation|terminal|server|boot|completion|completion-lifecycle|auto-completion|actions|llm-keybinding|llm-models|llm-backend|llm-http|llm-oauth|llm-workflow|llm-tools|llm-mcp|claude-code|lisp-eval|orderless-completion|snippets|lsp-snippets|lsp-project|real-lsp|tree-sitter|dap|project-navigation|project-outline|prompt-completion|daily-workflows|direnv|electric-editing|ui-parity|business-visual|cursor-state|snipe|avy|documents|notmuch|interactive|structural|notes|roam|roam-backlinks|org|org-modern|org-download|org-nodes-sync|agenda|agenda-undo|agenda-filter|agenda-view|editing]" >&2
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
