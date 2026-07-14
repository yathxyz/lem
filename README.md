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
  feasible chord is preserved. Globally enabled Which-Key-style guidance
  composes the live global, mode, and Vi-state maps for every ordinary
  keymap-backed prefix, honors dispatcher shadowing, and shows sorted raw command or `+prefix`
  labels in multi-column snapshots capped at one quarter of the frame height.
  Both the initial page and each nested page wait a fresh idle second, while
  native Lem transients keep their 500ms opening delay and immediate nesting
- state-aware terminal cursors and a genuine buffer-local Evil-style Emacs
  state on `C-z`: red-box normal, green-bar insert, cyan-box Emacs, portable
  visual/replace shapes, Emacs mark semantics, and exact prior-state return
- Winner-style window history on `C-c Left` / `C-c Right`: each tab frame keeps
  a bounded 200-layout route over split topology, proportions, displayed
  buffers, selection, and scroll state while retaining live buffer points;
  restored proportions adapt to terminal resizes
- Evil's visual-line policy on `SPC y v`: wrapped buffers swap screen/logical
  `j/k`, `gj/gk`, endpoints, insert/append, operators, registers, paste, and
  `V`, with a focused ncurses gate; Lem hard-wraps at display width rather than
  preferring Emacs word boundaries
- evil-surround defaults (`ys`/`ds`/`cs`/Visual `S`, row-wise Visual Block
  surrounds, padded and compact pairs, XML tags, call and prefix forms) /
  exact configured evil-snipe 2.1.3 /
  comment operator (`gc`) plus Lispyville-compatible,
  delimiter-safe structural editing in Common Lisp, Clojure, Scheme/Racket,
  and Emacs Lisp buffers
- Expreg-style `SPC v` region growth through lexical and Python/JSON syntax
  tiers, including balanced list interiors inside ordinary and block strings;
  arbitrary Visual selections use their active endpoint and retain contained
  generated tiers for contraction.  The configured unbound
  `M-x expreg-contract` walks backward through the generated selection sequence
  and expansion can then move forward again
- configured Avy jumps on `SPC l/a/s` use balanced `a/s/d/f/g/h/j/k/l`
  floating labels over visible line, character, and symbol targets. Normal state
  searches every ordinary or side text window, Visual stays in the current
  window, wrapped and hidden rows are respected, and the display never mutates
  source buffers. During selection, `x/X/t/m/n/y/Y/z` provide Avy's default
  kill, teleport, mark, copy, yank, and zap actions, while `?` shows the action
  keys; `i` reports that no spell backend is configured
- Prescient-style literal/regexp/initialism filtering and persistent learned
  ranking in command, buffer, and custom prompts; file prompts retain Lem's
  path-aware matching and gain the same ranking
- bounded, display-only Marginalia-style context for commands, Lisp symbols,
  buffers, files, loadable Lisp libraries, themes, and bookmarks; metadata
  failures do not alter candidate identity or prevent ordinary selection
- completion candidates keep display, filtering, and insertion text separate;
  final insertion and post-accept callbacks are explicit, tracked replacement
  ranges survive filtering, and stale asynchronous results are rejected
- an Embark-style, typed action dispatcher on `SPC e a` covers contiguous
  regions, URLs, existing local files, identifiers, buffers, native mode menus,
  completion candidates, and search locations; repeating `SPC e a` cycles every
  valid target at point and wraps before dispatch, while completion-local
  `C-c a` can copy without closing the popup or accept the captured candidate
  exactly once
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
  tracked/untracked file finding, cancellable bounded asynchronous regexp search,
  and arbitrary-directory command dispatch on `SPC p f/g/p`; `SPC SPC` combines
  lexical project buffers, recent files, and saved roots in fixed, narrowable
  groups with reversible preview-on-move. The project switch menu preserves
  `f/g/d/v/e/o`, with root-correct Git status and close terminal/M-x
  approximations for Emacs's Eshell and arbitrary-command entries
- the Emacs configuration tree's directory-local `C-c i` opens a
  Consult-style Elisp outline in Normal and Emacs states: line-numbered
  headings retain source order, Prescient filtering previews and recenters
  matches, `C-g` restores the exact point/view, Return records a Vi jump, and
  the `.dir-locals.el` declaration is parsed as bounded data without evaluation
- current-buffer Direnv integration is implemented in `src/direnv.lisp`: file
  buffers, derived process-oriented modes, and explicitly marked process output
  buffers update Lem's global process environment, so `PATH` lookup and future
  terminals, formatters, language servers, and other subprocesses use the
  selected directory's environment. Selected file opens provision that
  environment during initial mode hooks without letting direct background file
  loads retarget the editor. Authorization remains explicit through `M-x
  direnv-allow`; `.envrc` files are never allowed automatically. `$WORKDIR`
  remains a separately initialized, startup-cached notes root in
  `src/workspace.lisp` (`scripts/direnv-test.sh`).
- safe global refresh of externally changed clean files, stale-save protection
  for dirty buffers, and private cross-process persistence for file positions,
  bookmarks, reviewed non-secret prompt histories, Vi-aware kills, and separate
  literal and regexp search rings
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
- `C-x C-b` grouped like the effective Ibuffer setup: ordered, first-match
  org/tramp/emacs/ediff/dired/terminal/help headings, hidden empty groups, and a
  Default tail. Return collapses or expands a heading, while live filtering,
  marks, save/kill, and Return selection remain available
- project-scoped LSP lifecycle: canonical-root isolation, in-flight startup
  deduplication and timeout, explicit buffer ownership with save-as migration,
  project-wide restart, bounded shutdown/disposal, graceful exit when responsive,
  and a one-prompt `SPC p s` workspace-symbol search with Consult's minimum
  input, debounce/throttle timing, annotated kind groups, cancellable incremental
  requests, reversible preview, and Vi-jumplist acceptance; optional Lisp-v2
  connections remain globally selected when loaded
- installed LSP stack for Rust, Python, Markdown, C#, Nix, Go, Terraform, and
  manually enabled Java: rust-analyzer, pyright, harper-ls, csharp-ls,
  flake-aware nixd, gopls, terraform-ls, and JDTLS, plus the Rust toolchain
  required by rust-analyzer
- Legit (Magit approximation) plus packaged `jj` smart dispatch on `SPC g g`;
  the Jujutsu side is a read-only status/log view, while programming buffers get
  buffer-local Git markers, Git status includes navigable tracked-file
  TODO/FIXME rows, and `SPC g t` supplies the audited git-timemachine
  revision-navigation workflow
- metadata-aware Org file/heading and pinned md-roam node completion with
  find/insert/random workflows. A typed missing title opens the configured
  one-key `n/c/p/s/m` roam capture templates; `C-c C-c` finalizes the new Org
  or Markdown note and any deferred link, while `C-c C-k` aborts without a
  file. Root-level roam dailies, journal, and i/t/r capture operate over
  `$WORKDIR`, with public TODO capture over `$PUBLIC_ORG_DIR`
- a grouped Org agenda over the exact existing work/public/public-MCP roots,
  with top-level file scope, ordinary and repeating active-timestamp events,
  modal Return/g/q navigation, and Evil-Org-style `t` fast TODO selection plus
  `J`/`K` GNU Org priority cycling, `C-c C-s`/`C-c C-d` planning edits, and
  `ct`/`C-c C-q` completion-backed local-tag replacement and clearing,
  all with immediate source persistence. Evil-Org `dA` archives a complete
  subtree to Org's default sibling `_archive` file, while `da` confirms first;
  archive metadata and both files are persisted destination-first. GNU Org's
  `C-c C-w` completes over the current file's level-one headings and
  refiles the selected complete subtree as the target's final child. Agenda
  clocking preserves the effective state split in the Emacs setup: Vi `I/O`
  controls one GNU Org-style global clock, while C-z Emacs-state `I/O` starts
  concurrent delegated clocks on the current or bulk-marked rows and closes
  marked clocks—or every open clock across agenda files when nothing is
  marked. Evil/base mark keys render `>` prefixes and keep live source points
  across clock insertions and agenda refreshes.
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
language-server handshakes, daily-workflows, Direnv environment switching,
electric-editing, grouped-buffer-list, UI parity, project navigation and outline, VCS,
persistence, bookmarks,
retained undo/Vundo, project-scoped LSP lifecycle, LLM key dispatch,
cursor/state parity, evil-snipe and Avy parity, screen-line/Evil parity, notes,
roam, native Org, agenda, agenda-clock, and parity-ledger checks. The ledger can also be
validated directly, and the
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
nix run .#avy-test
nix run .#screen-line-test
nix run .#orderless-completion-test
nix run .#snippet-test
nix run .#lsp-snippet-test
nix run .#lsp-project-test
nix run .#real-lsp-test
nix run .#project-navigation-test
nix run .#project-outline-test
nix run .#persistence-test
nix run .#bookmark-test
nix run .#vundo-test
nix run .#editing-test
nix run .#formatting-test
nix run .#daily-workflows-test
nix run .#direnv-test
nix run .#electric-editing-test
nix run .#ui-parity-test
nix run .#vcs-test
nix run .#notes-test
nix run .#roam-test
nix run .#org-test
nix run .#agenda-test
nix run .#agenda-clock-test
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
`daily-workflows`, `direnv`, `llm-keybinding`, `orderless-completion`, `snippets`, `lsp-snippets`,
`lsp-project`, `real-lsp`, `project-navigation`, `project-outline`, `persistence`, `bookmarks`,
`vundo`, `electric-editing`, `ui-parity`, `cursor-state`, `snipe`, `avy`,
`interactive`, `structural`, `roam`, or
`notes` to run only that gate.
`LEM_YATH_TEST_HOST` and `LEM_YATH_REMOTE_ROOT` override the SSH host and remote
cache directory.
