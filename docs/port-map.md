# Port map: every declared Emacs package → its Lem disposition

This is a package-level orientation only. The authoritative status and test
evidence live in `docs/parity-ledger.tsv`; a package row here can summarize
several independently exact, approximate, or missing behaviors.

Status legend:
- **lem-builtin** — feature ships in the Lem image; configured/enabled by the port
- **ported** — reimplemented in Common Lisp in this repo (`lem-yath/src/...`)
- **n/a** — Emacs-plumbing with no meaning in Lem (or unused in the Emacs config itself)
- **partial** — core workflow ported, listed aspects missing
- **gap** — no Lem counterpart; not faithfully portable in scope (reason given)

| Emacs package | Status | Lem equivalent / location |
|---|---|---|
| evil | lem-builtin+ported/partial | `lem-vi-mode`, enabled in `src/vi.lisp`; `src/cursor-state.lisp` supplies the configured cursors and buffer-local Emacs state. `SPC y v` activates the patched conditional screen/logical policy for `j/k`, `gj/gk`, `0/g0`, `$/g$`, `I/A`, `D/C`, line operators/registers, paste, and `V`, restoring ordinary logical-line behavior when disabled (`patches/lem-vi-screen-line.patch`, `scripts/screen-line-test.sh`). Lem's display-width row breaking remains an approximation of Emacs word wrapping. |
| evil-collection | lem-builtin | vi-mode's own mode integrations |
| evil-surround | ported/partial | standard `ys`/`ds`/`cs`, visual `S`, common delimiter padding; tag prompts and syntax-aware balancing remain gaps (`src/vi.lisp`) |
| evil-snipe | ported | configured 2.1.3 behavior: visible `s/S/f/F/t/T`, whole-visible `;`/`,` and transient pair repeats, exact inclusive/exclusive operators, counts/dot/jumplist behavior, leading-whitespace skipping, and incremental/final faces (`src/vi.lisp`, `scripts/snipe-test.sh`) |
| evil-nerd-commenter | ported | `g c` operator (`src/vi.lisp`) |
| evil-org | partial | no Org major mode; shared-file workflows and `SPC m I` heading IDs work in plain buffers |
| general (SPC leader) | ported/partial | normal and visual states share one described Space-leader keymap with exact binding verification and delayed continuation help; remaining capability gaps are listed in `docs/vi-parity.md` |
| vertico | ported/lem-builtin | prompt list opens immediately, shows up to 20 rows, and cycles; focused TUI coverage in `scripts/completion-test.sh` |
| orderless | ported/partial | ordinary-buffer completion has escaped-space components, whole-query smart case, any-order literal/regexp filtering, and `~ = ^ ! ,` affix dispatch through `M-Space`; CL-PPCRE differs from Emacs regexp syntax, and `%` char-fold plus `&` annotation dispatch remain gaps (`src/orderless.lisp`) |
| marginalia | partial | M-x keybindings, buffer paths, and provider-specific LSP/Lisp details exist; no general category annotation layer |
| consult | ported/partial | `src/project.lisp` supplies persistent project MRU, tracked+untracked file selection, project-buffer membership by directory, bounded asynchronous regexp search, and Emacs-style switch dispatch on `SPC p f/g/p` and `SPC SPC`; prompt preview-on-move and Consult metadata remain gaps |
| consult-eglot | ported/partial | `SPC p s` sends `workspace/symbol` to the current project, then opens an annotated Prescient picker; incremental server queries and preview-on-move remain gaps |
| corfu (TTY via Emacs 31) | ported/partial | Lem has an ncurses popup, correct display/filter/insert metadata, distinct final-insert and post-accept callbacks, tracked ranges, stale-result rejection, automatic identifier completion after the configured 3-character/0.2-second threshold, and local `M-Space` filtering with zero-match recovery; Corfu's wider command surface remains unported |
| cape | ported/partial | automatic same-major-mode dabbrev and path-aware file-at-point fallbacks are composed and TUI-tested; raw dabbrev candidates feed Orderless, while Cape's broader provider library is not ported |
| yasnippet (+ snippets) | ported/partial | the configured private Org `jjs` source-block snippet is exact, and `src/snippets.lisp` uses the audited data-only subset of the 2,387 definitions at pinned `yasnippet-snippets` commit `606ee926df6839243098de6d71332a697518cb86`; numbered, anonymous, and nested fields, defaults, repeated placeholders, mirrors, escapes, `${0:...}`, `$0`, safe indentation directives, field navigation, a Prescient `M-x lem-yath-insert-snippet` selector, and common Eglot LSP snippet sessions work, while executable definitions and strict TextMate choices/variables/transforms remain unavailable |
| prescient (+vertico-) | ported/partial | prompt literal/regexp/initialism filtering and persistent recency/frequency ranking are implemented; interactive toggles and char folding remain gaps |
| embark (+consult) | ported/partial | `SPC e a` opens a typed, extensible action dispatcher for contiguous regions, URLs, existing local files, identifiers, buffers, native mode menus, focused completion candidates, and search/location rows; completion-local `C-c a` can copy in place or accept once (`src/actions.lisp`). Target cycling, act-all, collect/export/live views, arbitrary Embark action-map composition, and richer embark-consult adapters remain gaps |
| wgrep | lem-builtin | grep results are editable & write back (better than default Emacs) |
| eglot + eglot-booster | lem-builtin+ported/partial | `lem-lsp-mode` uses a native JSON-RPC client, so Eglot Booster is unnecessary. The installed application packages rust-analyzer, pyright, harper-ls, nixd, gopls, terraform-ls, and the `nixfmt` executable from nixfmt-rfc-style; an installed-wrapper ncurses gate performs real handshakes and process-cleanup checks. Stdio servers use real pipes with stderr isolated from JSON-RPC, and Lem advertises and answers `workspace/configuration` so servers can use their defaults. Ordinary local-file workspaces are isolated by stable server identity + canonical root, pending starts deduplicate and time out, save-as/mode changes rebind explicit ownership, restart/shutdown is project-scoped and graceful, and server cwd/init options are frozen to the project. Lem still differs in language-root selection, Python auto-start, Nix settings delivery, and Go/Terraform transport; resolved completion documentation/detail and completion commands also remain gaps. |
| flycheck (+rust) | partial | LSP diagnostics overlays; no non-LSP linter framework |
| apheleia | ported/partial | `SPC b f` formats unsaved buffer text through a mapped CLI/in-process backend, with ready LSP fallback only when manual formatting has no usable mapped backend; mapped programming modes with an available, successful backend also format synchronously after the first save and are silently rewritten before LSP `didSave` (`src/formatting.lisp`, `scripts/formatting-test.sh`). The registry is broad but finite, and async formatting, formatter prompts, and Apheleia-style per-project backend overrides are absent |
| dape (DAP debugging) | gap | Lem has no DAP client |
| treesit-auto / tree-sitter-langs / tsc / grammars | partial | `lem-tree-sitter` + 10 grammars baked in; modes default to TextMate highlighting (manual opt-in API) |
| nix-mode | lem-builtin+ported/partial | Packaged **nixd** with flake-derived nixpkgs/options and packaged `nixfmt` from nixfmt-rfc-style (`src/ide.lisp`). Lem sends these as initialization options and roots at a Nix marker; Emacs uses workspace configuration at its project.el root and its declared daemon PATH normally supplies no formatter candidate. |
| rust-mode | lem-builtin+ported/partial | Packaged **rust-analyzer**, cargo, rustc, rustfmt, and clippy auto-start and are installed-wrapper tested; Lem uses the nearest Cargo.toml rather than Emacs's project.el root. |
| go-mode | lem-builtin+partial | Packaged **gopls** is handshake-tested through the upstream TCP spec rooted at go.mod; Emacs uses boosted stdio at its project.el root, and Lem adds completeUnimported and fuzzy-matcher initialization options. |
| markdown-mode / markdown-ts-mode | ported/partial | Packaged **harper-ls --stdio** is handshake-tested. Lem has one Markdown mode rooted at `.git`; Emacs hooks both ordinary and tree-sitter modes at their project.el roots. |
| (python via pyright) | ported/partial | Packaged **pyright-langserver --stdio** is handshake-tested. Lem auto-starts it at a Python metadata root; the current Emacs config merely selects Pyright after manual Eglot startup because no Python Eglot hook is configured. |
| terraform-mode | lem-builtin+partial | Packaged **terraform-ls** is handshake-tested through upstream Lem's TCP spec with `.git` fallback; Emacs uses boosted stdio at its project.el root. |
| clojure-ts-mode / cider | lem-builtin | `lem-clojure-mode` + clojure-lsp + nREPL repl |
| eglot-java | gap | no jdtls spec (jdt launcher out of scope); `lem-java-mode` syntax only |
| gdscript-mode | gap | no Godot mode/LSP in Lem |
| nasm-mode | lem-builtin | `lem-asm-mode` |
| just-mode / meson-mode / nginx-mode / nushell-ts-mode / typst-ts-mode | gap | open as fundamental (no Lem modes) |
| yaml-mode | lem-builtin | `lem-yaml-mode` |
| sqlite3 | n/a | elisp FFI library |
| lispy / lispyville | ported | Paredit in Common Lisp, Clojure, Scheme/Racket, and Elisp; delimiter-safe Vim operators, atom motions, slurp/barf, drag, splice, split, raise, transpose, convolute, and list insertion/opening (`src/structural.lisp`, `scripts/structural-test.sh`); wrapped-row delimiter safety and Lispyville's screen-row character-register quirk are covered by `scripts/screen-line-test.sh`; plus full SLIME via micros |
| magit | lem-builtin | `lem/legit` (status/stage/commit/branch/push/pull/stash/rebase); `SPC g G` |
| magit-todos | gap | no TODO section in legit |
| forge | gap | no GitHub/GitLab integration |
| git-gutter | lem-builtin | `lem-git-gutter`, enabled globally (`src/git.lisp`) |
| git-timemachine | ported | `SPC g t` (`src/apps/timemachine.lisp`) |
| majutsu (jj) | ported/partial | smart dispatch `SPC g g` + jj status/log view (`src/git.lisp`); no staging UI |
| org (capture) | ported | `SPC o` → inbox/todo/readlist with CREATED property (`src/notes.lisp`) |
| org-roam | ported/partial | find/insert/random over $WORKDIR/roam incl. .md (`src/notes.lisp`); no backlinks/db |
| md-roam | partial | .md notes are discoverable, but YAML IDs/titles/tags and graph semantics are not indexed |
| org-roam-dailies | ported | `SPC n r d t` / `SPC n r d d` (`src/notes.lisp`) |
| org-journal | ported | `SPC n j j`, same file layout + timestamp headings |
| org-agenda / org-super-agenda | ported/partial | scanning agenda: overdue/today/upcoming/todos (`src/apps/agenda.lisp`) |
| org-modern / org-download / org-ref / org-contrib / ob-async / ob-dsq / engrave-faces / cdlatex | gap | org ecosystem (visuals/babel/export) — no org-mode in Lem |
| citar / ebib / reftex | ported (citar) | bib parse + open file/url/note, `SPC y o` (`src/apps/citar.lisp`); ebib/reftex gap |
| gptel | partial | OpenRouter streaming exists, but presets, model discovery, conversation/tool semantics, handoff, transforms, and tracing remain open |
| gptel-claude-code / gptel-codex / gptel-grok-build | partial | CLI process backends exist without rich agent-event rendering and backend-specific semantics |
| gptel-chatgpt-codex / gptel-grok-build-oauth | gap | OAuth/PKCE token flows out of scope |
| gptel-tooling / gptel-stability | partial | some parts are Emacs hardening, but user-visible agent tools and project/MCP behavior are not yet ported |
| claude-code.el | lem-builtin | `lem-claude-code` extension, `C-c c` |
| monet | partial | Lem ships an MCP **server** + Claude Code integration natively |
| mcp.el | partial | `lem-mcp-server` (Lem as server); no generic MCP client hub |
| notmuch | partial | search/read/refresh daily path exists; composition, sending, attachments/PDF preview, and the Salta bridge do not |
| elfeed + elfeed-protocol | ported | Miniflux Fever API reader (`src/apps/elfeed.lisp`) |
| devdocs | ported | devdocs.io index lookup + text rendering, `SPC h d` (`src/apps/devdocs.lisp`) |
| pdf-tools | gap | terminal frontend; PDFs open externally (xdg-open) |
| nov (EPUB) | gap | no EPUB rendering |
| vterm | lem-builtin | `lem-terminal` (libvterm), `M-x terminal` |
| pgmacs / pg | ported | psql-backed query/table viewer (`src/apps/pg.lisp`) |
| salta.el | partial | six primary Supabase/PostgREST workflows exist; the notmuch payment-email bridge and some UI semantics remain open |
| helpful | lem-builtin | describe-key / describe-bindings / apropos-command (`SPC h *`) |
| which-key | ported/partial | the shared Space-leader tree opens a described `lem/transient` menu after one second, refreshes nested prefixes immediately, and cancels cleanly on fast dispatch, reload, or Escape without changing unrelated transient timing; arbitrary non-leader prefixes remain silent (`scripts/ui-parity-test.sh`) |
| transient | lem-builtin | `lem/transient` |
| multiple-cursors | lem-builtin | core multi-cursors (`M-C`, isearch add-cursor); Emacs config only used it internally |
| expreg | ported/partial | repeated `SPC v` expands word → delimiters → line → paragraph; no parser-backed syntax expansion |
| vundo | ported/partial | `SPC u` opens a three-row Unicode retained tree with live preview, branch/stem/saved-node navigation, mark/diff, save, rollback, and accept (`src/vundo.lisp`, `patches/lem-undo-tree.patch`, `scripts/vundo-test.sh`); numeric prefixes and debug keys `i`/`D` are absent |
| pulsar | n/a | jump recentering is default behavior |
| indent-bars | gap | no indent guides in ncurses frontend |
| rainbow-delimiters | ported/partial | `src/ui.lisp` enables upstream coloring in Common Lisp buffers, and `src/theme.lisp` maps its six cycling depths to the first six Modus delimiter colors; Emacs applies rainbow-delimiters throughout `prog-mode` and exposes additional depths. Show-paren remains available elsewhere (`scripts/ui-parity-test.sh`). |
| display-line-numbers (built-in) | ported | relative numbers render in saved and unsaved programming buffers, compose with other gutters, and stay out of prose and utility buffers (`src/ui.lisp`, `scripts/ui-parity-test.sh`) |
| truncate-lines / visual-line-mode / hl-line-mode (built-ins) | ported/partial | `src/ui.lisp` starts with long lines truncated and disables Lem's upstream current-line highlight, matching the active Emacs baseline; `SPC y v` retains buffer-local wrap toggling and activates the configured modal row policy (`scripts/ui-parity-test.sh`, `scripts/screen-line-test.sh`). Emacs word-wrap and Lem display-width wrapping can choose different row boundaries. |
| tab-bar / winner-mode (built-ins) | partial | no tab header is shown at startup; `C-x t 2` lazily enables Lem's frame multiplexer and creates a tab. Winner-style window-layout undo/redo is absent (`src/ui.lisp`, `scripts/ui-parity-test.sh`). |
| dirvish | lem-builtin | `directory-mode` + filer |
| find-name-dired (built-in) | ported/partial | `M-s f` asynchronously fills a persistent, read-only `*Find*` buffer with safely escaped rows backed by exact paths (`src/find-name.lisp`); Dired marking, long columns, file operations, and process cancellation remain gaps |
| electric-pair-mode / delete-selection-mode (built-ins) | ported/partial | syntax-table delimiter/quote pairing, local balance reuse/skip, numeric prefixes, ordinary region replacement, and Emacs-style opener/quote region wrapping; an unmatched embedded quote is escaped to keep the Lisp string valid instead of reproducing Lispy's raw interior quote, while full forward balance scanning, global paired Backspace, and zero-result prompt recovery remain gaps (`src/electric-pair.lisp`, `scripts/electric-editing-test.sh`) |
| ws-butler | ported | track changed programming-buffer lines and trim only those lines on save (`src/editing.lisp`); EditorConfig `trim_trailing_whitespace=true` additionally normalizes the whole buffer, while false/absent retains touched-line cleanup |
| ibuffer | lem-builtin/partial | `list-buffers` (`C-x C-b`) provides Buffer/File columns, fuzzy narrowing, and Return-to-open; the configured org/tramp/emacs/ediff/dired/terminal/help saved groups are absent |
| bookmarks (built-in) | lem-builtin/partial | `lem-bookmark`, `SPC b m` / `SPC RET`; unlike the configured Emacs, modified bookmarks are not automatically saved at exit |
| avy | partial | `SPC l` goto-line, `SPC a` snipe, `SPC s` isearch-symbol |
| gcmh / no-littering / use-package / direnv / sops | n/a or gap | SBCL image needs no GC hacks; no-littering/use-package n/a; **direnv/sops: gap** |
| editorconfig | ported/partial | the official CLI resolves hierarchy/inheritance for every steady-state local file buffer; Lem maps indentation, line endings, write charset, fill column, trailing whitespace, and final-newline policy (`src/editorconfig.lisp`, `scripts/formatting-test.sh`). Charset is applied only to subsequent writes, not initial decoding |
| auto-revert / savehist / save-place / recentf (built-ins) | ported/partial | `src/persistence.lisp` safely polls every file buffer before commands, transactionally reloads only clean readable files up to a 64 MiB safety cap, protects stale saves, restores up to 600 local-file positions, and atomically persists allowlisted non-secret prompt histories, a 120-entry live/40-entry saved Vi-aware kill ring, and separate 16-entry literal/regexp search rings; recentf remains a 300-file MRU on `M-g r`. Idle-time/filesystem notifications, larger automatic reloads, directory-buffer positions, and broad non-file stale adapters remain gaps |
| modus-vivendi-tinted (built-in) / doom-themes | ported/partial | the active Emacs startup theme is recreated natively in `src/theme.lisp`; resolved semantic colors are tested, while ncurses rendering is limited by the terminal color model and Lem has fewer face roles. `doom-themes` remains declared but inactive. |
| notmuch-outlook / business-visual profile / nodes-org-sync | gap | host-gated bespoke integrations, out of scope |

## Behavioral divergences worth knowing

- **Visual-line row geometry**: the configured Evil screen/logical-line policy
  is ported and TUI-tested. Emacs `visual-line-mode` wraps preferentially at
  word boundaries, whereas Lem wraps at display width, so commands can
  encounter different displayed-row boundaries.
- **Display palette and delimiters**: Lem retains the configured Modus hex
  values for its available semantic attributes, but ncurses maps them through
  the terminal's color capabilities. Nested colors cover six cycling depths in
  Common Lisp only; other modes retain matching-pair highlighting rather than
  Emacs's all-`prog-mode` rainbow coverage.
- **Tabs and layout history**: startup correctly has no tab row and `C-x t 2`
  creates one on demand, but Lem's frame multiplexer is not a complete Emacs tab
  implementation and there is no winner-mode layout history.
- **Surround grammar**: standard `ys`/`ds`/`cs` and visual `S` work, including
  common padded delimiters, but tag prompts and syntax-aware balancing do not.
- **Formatting lifecycle**: mapped programming modes with an available,
  successful backend format synchronously after the ordinary save, then receive
  a silent second write before LSP `didSave`.
  External commands use stdin and direct argument vectors under a timeout. CLI
  launch, timeout, nonzero-exit, and output-limit failures occur before buffer
  mutation, leave the first save intact, and do not fall back to LSP; diff
  application itself has no transactional rollback. LSP fallback is manual-only
  when no mapped backend is usable. There is no async worker, formatter prompt,
  or Apheleia-style per-project backend table.
- **EditorConfig scope**: matching is delegated to the official CLI, but Lem
  maps only the documented core properties. A charset rule cannot re-decode an
  already opened file and affects later writes only; UTF-16BE/LE writes do not
  add a BOM. `trim_trailing_whitespace=false` does not disable ws-butler's
  touched-line policy. Direnv remains a separate, unimplemented integration.
- **org files** open as plain text; the workflows (capture/dailies/journal/agenda)
  operate on the same files but there is no org folding/links/tables UI.
- **Completion previews**: no consult-style live preview while cycling candidates.
- **Undo accounting**: the configured 2,080,000 / 3,120,000 / 48,000,000
  Vundo budgets are applied to copied UTF-8 edit payload, not Emacs heap usage.
  Lem additionally caps retained history at 65,536 nodes, 262,144 edits, and
  128 MiB of UTF-8 route-validation work. Retained nodes do not store
  historical point values, so preview point is replay-derived. Vundo movement has no numeric-prefix
  variants or `i`/`D` debug commands, and speculative rectangle/Copilot-style
  transactions are retained because Lem has no discard-transaction API.
- **Embark scope**: completion uses `C-c a` because the ncurses input path cannot
  represent `C-.` distinctly. The typed dispatcher does not yet provide target
  cycling, act-all, collect/export/live views, arbitrary Embark action-map
  composition, or the wider embark-consult adapter set.
- **Find-name results** persist after opening a match and are safe for spaces,
  control characters, and shell-looking patterns, but they are a path list rather
  than a full Dired buffer with marking and file operations.
- **Buffer list groups**: `C-x C-b` has useful columns and fuzzy narrowing, but
  not the configured Ibuffer saved filter groups.
- **Persistence scope**: clean local files are polled globally every five
  seconds and whenever selected; no filesystem notification backend is present.
  File positions exclude temporary VCS commit files, but directory-buffer
  positions are not saved. Shared/unnamed, SQL/compile, credential-like, and
  unknown prompt histories deliberately remain memory-only, and non-file auto-revert requires an
  explicit buffer-local stale/revert adapter. Persistence is default-deny for
  prompt names and applies per-entry and 32 MiB aggregate budgets; oversized
  kills or query strings remain live but are not written. Concurrent merging
  preserves additions, while a stale process can resurrect a history clear.
- **Rectangle duplication**: `M-j` matches line and contiguous-region behavior,
  including Vi character/line selections, but V-BLOCK remains unsupported.
- **Electric-pair scope**: syntax-table pairs, quotes, numeric prefixes,
  escapes, and local syntax-safe closer reuse/skip are covered. Full forward
  balance scanning across forms, global adjacent-pair Backspace, and recovery
  after a zero-result prompt query remain open.
- **In-buffer Orderless scope**: automatic mode/Cape completion supports
  multi-component matching and Corfu's `M-Space` separator. CL-PPCRE differs
  from Emacs regexp syntax, `%` character folding and `&` annotation dispatch
  remain absent, and initialism is scoped to deterministic ASCII boundaries.
- **Snippet scope**: `Tab`, `Shift-Tab`, `C-g`, `C-d`, and `Backspace` provide
  the tested field-session workflow, with completion, Vi, and Paredit retaining
  their intended precedence. Root and table inheritance plus common filename
  mappings expose the pinned community data without executing Emacs Lisp. LSP
  format-2 candidates use the same safe session after tracked final acceptance;
  plain format stays literal, malformed payloads preserve the prefix, and
  backquoted server text is inert. Acceptance-time completion resolve supports
  lazy `additionalTextEdits`; direct and resolved edits remain plain, are
  validated against the primary range and each other, and share one undo step
  with the primary insertion. Resolve failure or a bad additional batch falls
  back to the original primary completion.
  Stacked active sessions, direct snippet bindings, redo-time session revival,
  strict TextMate variables/choices/transforms, resolved documentation/detail,
  CompletionList item defaults, completion commands, and native transactional
  rollback after arbitrary mutation-hook errors remain gaps. LSP document
  positions consistently use the originating workspace's advertised UTF-16
  encoding, including edits, diagnostics, navigation, symbols, and completion.
  BibTeX expansion deterministically omits automatic indentation; this
  approximates the intended steady-state text rather than reproducing Emacs'
  transient indentation calls.
