# lem-yath: emacs → lem

A faithful port of my Nix-managed Emacs configuration
(`~/proj/nix/computer/home/config/emacs`, ~9,100 lines of elisp, ~100 packages)
to [Lem](https://github.com/lem-project/lem), the Common Lisp editor —
terminal (ncurses) frontend, multi-threaded SBCL image.

## Layout

| Path | Purpose |
|---|---|
| `lem-yath/` | The port: ASDF system `lem-yath` (core modules in `src/`, app ports in `src/apps/`) |
| `docs/emacs-inventory.md` | Extracted feature inventory of the Emacs config |
| `docs/lem-capabilities.md` | Survey of Lem's real APIs (grounded in source) |
| `docs/port-map.md` | Emacs package → Lem equivalent mapping + gap report |
| `docs/vi-parity.md` | Vim/Evil behavior matrix, evidence, and remaining gaps |
| `docs/structural-editing.md` | Lispy/Lispyville key themes, safety model, and TUI evidence |
| `docs/porting-conventions.md` | Hard rules every module follows |
| `scripts/` | tmux-based TUI test harness |

## Run

The flake pins upstream Lem and exposes this port as a runnable app. The
wrapper binary is named `lem`, so installing it gives the configured editor
under the usual name (unconfigured upstream stays reachable as `nix run
.#lem-upstream`):

```sh
nix run
```

For development, the dev shell puts the flake-pinned upstream `lem` on PATH
and points `LEM_YATH_SOURCE` at the working tree:

```sh
nix develop
lem -q --eval '(load #P"lem-yath/init.lisp")'
```

The wrapper starts Lem without the user's normal init file, loads
`lem-yath/init.lisp`, and keeps ASDF build outputs under the user cache instead
of writing `.fasl` files into the source tree.

## What's in the port

- vi-mode with a Space leader reproducing every feasible SPC chord in normal
  and visual states (files, buffers, project, git, notes, LLM, help, navigation)
- surround / snipe / comment operator (`gc`) plus Lispyville-compatible,
  delimiter-safe structural editing in Common Lisp, Clojure, Scheme/Racket,
  and Emacs Lisp buffers
- orderless (space-separated substring) filtering in command and buffer
  prompts, with multi-token input kept alive; file prompts retain Lem's stock
  completion behavior
- LSP specs: rust-analyzer, pyright, harper-ls, and flake-aware nixd
- legit (magit) + jj dispatch on `SPC g g`, git-gutter, git-timemachine
- roam-lite notes, dailies, journal, capture over `$WORKDIR`
- streaming OpenRouter LLM client + claude/codex/grok CLI backends
- app ports under `lem-yath/src/apps/`: agenda, citar, devdocs, elfeed
  (Miniflux fever), notmuch, pg, salta, timemachine, llm-cli

See `docs/port-map.md` for the per-package disposition and known divergences.

## Testing

`nix flake check` runs the package, compile, and boot checks. The interactive
TUI checks are also exposed as flake apps:

```sh
nix flake check
nix run .#compile-check
nix run .#boot-test
nix run .#orderless-test
nix run .#interactive-test
nix run .#structural-test
```

The underlying scripts remain parallel-safe via `LEM_YATH_CHECK_ID` and accept
`LEM_BIN`/`LEM_YATH_SOURCE` overrides for direct debugging.

To keep builds and real TUI sessions off a weaker laptop, mirror the current
worktree to the dedicated cache directory on `ex44` and run the full gate there:

```sh
./scripts/test-on-ex44.sh
```

Pass `check`, `compile`, `boot`, `orderless`, `interactive`, or `structural` to run only that
gate. `LEM_YATH_TEST_HOST` and `LEM_YATH_REMOTE_ROOT` override the SSH host and
remote cache directory.
