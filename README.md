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
| `docs/parity-ledger.tsv` | Behavior-level parity audit with explicit evidence, divergence, and blockers |
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

- vi-mode with one shared Space leader in normal and visual states; every
  feasible chord is preserved and a described which-key-style continuation
  menu appears after the configured one-second pause
- state-aware terminal cursors and a genuine buffer-local Evil-style Emacs
  state on `C-z`: red-box normal, green-bar insert, cyan-box Emacs, portable
  visual/replace shapes, Emacs mark semantics, and exact prior-state return
- Evil's visual-line policy on `SPC y v`: wrapped buffers swap screen/logical
  `j/k`, `gj/gk`, endpoints, insert/append, operators, registers, paste, and
  `V`, with a focused ncurses gate; Lem hard-wraps at display width rather than
  preferring Emacs word boundaries
- surround / exact configured evil-snipe 2.1.3 / comment operator (`gc`) plus Lispyville-compatible,
  delimiter-safe structural editing in Common Lisp, Clojure, Scheme/Racket,
  and Emacs Lisp buffers
- Prescient-style literal/regexp/initialism filtering and persistent learned
  ranking in command, buffer, and custom prompts; file prompts retain Lem's
  path-aware matching and gain the same ranking
- completion candidates keep display, filtering, and insertion text separate;
  final insertion and post-accept callbacks are explicit, tracked replacement
  ranges survive filtering, and stale asynchronous results are rejected
- an Embark-style, typed action dispatcher on `SPC e a` covers contiguous
  regions, URLs, existing local files, identifiers, buffers, native mode menus,
  completion candidates, and search locations; completion-local `C-c a` can
  copy without closing the popup or accept the captured candidate exactly once
- exact expansion of the configured private Org `jjs` source-block snippet and
  a data-only Yasnippet session engine over the flake-pinned community corpus;
  numbered, anonymous, and nested fields, defaults, mirrors, escapes, safe
  indentation directives, forward/reverse field navigation, and a Prescient
  `M-x` insertion prompt are supported for 2,243 definitions; the 144 executable
  or conditional definitions remain unavailable, and embedded Elisp is never evaluated
- LSP `insertTextFormat=Snippet` candidates enter the same field-session UI
  after `insertText`, `TextEdit`, or `InsertReplaceEdit` acceptance; direct and
  lazily resolved `additionalTextEdits` share the acceptance undo step,
  UTF-16 ranges are decoded consistently, malformed payloads fail closed, and
  server-supplied backquoted Lisp remains inert
- Emacs-like daily navigation/editing: region-or-line `M-j`, a persistent
  300-entry `M-g r` MRU, filterable `C-x C-b`, and asynchronous persistent
  `M-s f` name search with property-backed Return and persistent q/revisit behavior
- project.el-style navigation: persistent automatic project MRU, Git-aware
  tracked/untracked file finding, cancellable bounded asynchronous regexp search, exact
  directory-based project buffers, and arbitrary-directory command dispatch on
  `SPC p f/g/p` and `SPC SPC`
- safe global refresh of externally changed clean files, stale-save protection
  for dirty buffers, and private cross-process persistence for file positions,
  reviewed non-secret prompt histories, Vi-aware kills, and separate literal and
  regexp search rings
- retained branching undo with the configured raised payload budgets and a
  three-row Unicode Vundo UI on `SPC u`; live previews support branch, stem,
  saved-node, mark/diff, save, rollback, and accept workflows while ordinary
  `u`/`C-r` continue along the selected branch
- global syntax-aware delimiter/quote pairing and self-insert selection
  replacement, including region wrapping without taking keys away from Paredit or Vi
- official-CLI EditorConfig resolution for steady-state local file buffers,
  including indentation, line endings, write charset, fill column, whitespace,
  and final-newline policy; charset changes affect subsequent writes, and
  `trim_trailing_whitespace=false` or an absent property leaves ws-butler's
  touched-line cleanup in place
- synchronous, CLI-first Apheleia-style formatting for a finite set of
  programming modes: `SPC b f` formats without saving, while normal saves run a
  mapped formatter, when available and successful, before LSP observes the
  final buffer; commands use direct argument vectors with a timeout, and only
  manual formatting can fall back to a ready LSP formatter when no mapped
  backend is available
- relative line numbers in programming buffers only, matching the Emacs
  `prog-mode` scope while leaving prose and utility buffers clean
- the current Modus Vivendi Tinted palette, truncated long lines, no global
  current-line highlight or startup tab header, `C-x t 2` tabs on demand, and
  six Modus-matched delimiter depths in Common Lisp buffers
- project-scoped LSP lifecycle: canonical-root isolation, in-flight startup
  deduplication and timeout, explicit buffer ownership with save-as migration,
  project-wide restart, bounded shutdown/disposal, graceful exit when responsive,
  and `SPC p s` workspace-symbol
  search with annotated narrowing; optional Lisp-v2 connections remain globally
  selected when loaded
- installed LSP stack for Rust, Python, Markdown, Nix, Go, and Terraform:
  rust-analyzer, pyright, harper-ls, flake-aware nixd, gopls, and terraform-ls,
  plus the Rust toolchain required by rust-analyzer
- legit (magit) + jj dispatch on `SPC g g`, git-gutter, git-timemachine
- roam-lite notes, root-level roam dailies, journal, and i/t/r capture over
  `$WORKDIR`, plus public TODO capture over `$PUBLIC_ORG_DIR`
- streaming OpenRouter LLM client + claude/codex/grok CLI backends
- app ports under `lem-yath/src/apps/`: agenda, citar, devdocs, elfeed
  (Miniflux fever), notmuch, pg, salta, timemachine, llm-cli

See `docs/port-map.md` for the per-package disposition and known divergences.
Use `docs/parity-ledger.tsv` for behavior-level planning: its dispositions are
`exact`, `approximation`, `gap`, `n-a`, and `unassessed`. The validator accepts
`exact` only with automated evidence or an explicitly approved manual record.

## Testing

`nix flake check` runs the package, compile, boot, prompt and in-buffer
completion, completion-lifecycle, automatic-completion, Embark-style actions,
editing, formatting, Orderless completion, snippets, LSP snippets, real installed
language-server handshakes, daily-workflows,
electric-editing, UI parity, project navigation, persistence, retained undo/Vundo,
project-scoped LSP lifecycle, LLM key dispatch, cursor/state parity, evil-snipe
parity, screen-line/Evil parity, notes, and parity-ledger checks. The ledger can
also be validated directly, and the
interactive TUI checks are exposed as flake apps:

```sh
nix flake check
python3 scripts/check-parity-ledger.py
nix run .#compile-check
nix run .#boot-test
nix run .#completion-test
nix run .#prompt-completion-test
nix run .#completion-lifecycle-test
nix run .#auto-completion-test
nix run .#actions-test
nix run .#llm-keybinding-test
nix run .#cursor-state-test
nix run .#snipe-test
nix run .#screen-line-test
nix run .#orderless-completion-test
nix run .#snippet-test
nix run .#lsp-snippet-test
nix run .#lsp-project-test
nix run .#real-lsp-test
nix run .#project-navigation-test
nix run .#persistence-test
nix run .#vundo-test
nix run .#editing-test
nix run .#formatting-test
nix run .#daily-workflows-test
nix run .#electric-editing-test
nix run .#ui-parity-test
nix run .#notes-test
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

Pass `check`, `compile`, `boot`, `completion`, `prompt-completion`,
`completion-lifecycle`, `auto-completion`, `actions`, `editing`,
`daily-workflows`, `llm-keybinding`, `orderless-completion`, `snippets`, `lsp-snippets`,
`lsp-project`, `real-lsp`, `project-navigation`, `persistence`, `vundo`, `electric-editing`, `ui-parity`, `cursor-state`, `snipe`, `interactive`, `structural`, or
`notes` to run only that gate.
`LEM_YATH_TEST_HOST` and `LEM_YATH_REMOTE_ROOT` override the SSH host and remote
cache directory.
