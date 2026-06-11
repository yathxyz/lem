# emacs → lem

A faithful port of my Nix-managed Emacs configuration
(`~/proj/nix/computer/home/config/emacs`, ~9,100 lines of elisp, ~100 packages)
to [Lem](https://github.com/lem-project/lem), the Common Lisp editor —
terminal (ncurses) frontend, multi-threaded SBCL image.

## Layout

| Path | Purpose |
|---|---|
| `lem-vile/` | The port: ASDF system `vile` (core modules in `src/`, app ports in `src/apps/`) |
| `docs/emacs-inventory.md` | Extracted feature inventory of the Emacs config |
| `docs/lem-capabilities.md` | Survey of Lem's real APIs (grounded in source) |
| `docs/port-map.md` | Emacs package → Lem equivalent mapping + gap report |
| `docs/porting-conventions.md` | Hard rules every module follows |
| `scripts/` | tmux-based TUI test harness |
| `vendor/lem` | Lem source clone (gitignored; used for builds + API grounding) |

## Build / install Lem

Lem is not in nixpkgs; it ships its own flake:

```sh
git clone --depth 1 https://github.com/lem-project/lem vendor/lem
nix build ./vendor/lem#lem-ncurses -o result-lem
./result-lem/bin/lem
```

The config is wired in via a 3-line `~/.config/lem/init.lisp` shim that loads
`lem-vile/init.lisp` from this repo, which in turn loads the `vile` ASDF system.

## What's in the port

- vi-mode with a Space leader reproducing the full SPC chord map (files,
  buffers, project, git, notes, LLM, help, navigation)
- surround / snipe / comment operator (`gc`) / paredit on lisp buffers
- orderless (space-separated substring) filtering in every prompt, popup open
  by default, multi-token input kept alive (Space re-filters in prompts)
- LSP specs: rust-analyzer, pyright, harper-ls, and flake-aware nixd
- legit (magit) + jj dispatch on `SPC g g`, git-gutter, git-timemachine
- roam-lite notes, dailies, journal, capture over `$WORKDIR`
- streaming OpenRouter LLM client + claude/codex/grok CLI backends
- app ports under `lem-vile/src/apps/`: agenda, citar, devdocs, elfeed
  (Miniflux fever), notmuch, pg, salta, timemachine, llm-cli

See `docs/port-map.md` for the per-package disposition and known divergences.

## Testing

All scripts are parallel-safe via `VILE_CHECK_ID`:

```sh
VILE_CHECK_ID=me ./scripts/compile-check.sh    # force-recompile, full diagnostics, must end LOAD OK
VILE_CHECK_ID=me ./scripts/boot-test.sh        # boots lem in tmux, asserts the boot report
VILE_CHECK_ID=me ./scripts/orderless-test.sh   # interactive: multi-token prompt filtering
```
