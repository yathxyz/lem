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
| evil | lem-builtin | `lem-vi-mode`, enabled in `src/vi.lisp` |
| evil-collection | lem-builtin | vi-mode's own mode integrations |
| evil-surround | ported/partial | standard `ys`/`ds`/`cs`, visual `S`, common delimiter padding; tag prompts and syntax-aware balancing remain gaps (`src/vi.lisp`) |
| evil-snipe | ported/partial | visible-scope `s`/`S`, repeat, and operator `z/Z/x/X`; incremental highlighting remains a gap (`src/vi.lisp`) |
| evil-nerd-commenter | ported | `g c` operator (`src/vi.lisp`) |
| evil-org | partial | no Org major mode; shared-file workflows and `SPC m I` heading IDs work in plain buffers |
| general (SPC leader) | ported/partial | normal and visual states share one described Space-leader keymap with exact binding verification and delayed continuation help; remaining capability gaps are listed in `docs/vi-parity.md` |
| vertico | ported/lem-builtin | prompt list opens immediately, shows up to 20 rows, and cycles; focused TUI coverage in `scripts/completion-test.sh` |
| orderless | ported/partial | ordinary-buffer completion has escaped-space components, whole-query smart case, any-order literal/regexp filtering, and `~ = ^ ! ,` affix dispatch through `M-Space`; CL-PPCRE differs from Emacs regexp syntax, and `%` char-fold plus `&` annotation dispatch remain gaps (`src/orderless.lisp`) |
| marginalia | partial | M-x keybindings, buffer paths, and provider-specific LSP/Lisp details exist; no general category annotation layer |
| consult | ported/partial | project buffers `SPC SPC`, project-grep, isearch; no preview-on-move |
| consult-eglot | gap | `SPC p s` currently invokes document symbols, not the configured workspace-symbol search |
| corfu (TTY via Emacs 31) | ported/partial | Lem has an ncurses popup, correct display/filter/insert metadata, distinct final-insert and post-accept callbacks, tracked ranges, stale-result rejection, automatic identifier completion after the configured 3-character/0.2-second threshold, and local `M-Space` filtering with zero-match recovery; Corfu's wider command surface remains unported |
| cape | ported/partial | automatic same-major-mode dabbrev and path-aware file-at-point fallbacks are composed and TUI-tested; raw dabbrev candidates feed Orderless, while Cape's broader provider library is not ported |
| yasnippet (+ snippets) | ported/partial | the configured private Org `jjs` source-block snippet is exact, and `src/snippets.lisp` uses the audited data-only subset of the 2,387 definitions at pinned `yasnippet-snippets` commit `606ee926df6839243098de6d71332a697518cb86`; numbered, anonymous, and nested fields, defaults, repeated placeholders, mirrors, escapes, `${0:...}`, `$0`, safe indentation directives, field navigation, a Prescient `M-x lem-yath-insert-snippet` selector, and common Eglot LSP snippet sessions work, while executable definitions and strict TextMate choices/variables/transforms remain unavailable |
| prescient (+vertico-) | ported/partial | prompt literal/regexp/initialism filtering and persistent recency/frequency ranking are implemented; interactive toggles and char folding remain gaps |
| embark (+consult) | gap | Lem has context menus and LSP code-action menus, but no generic target classifier/action maps behind `SPC e a` |
| wgrep | lem-builtin | grep results are editable & write back (better than default Emacs) |
| eglot + eglot-booster | lem-builtin+ported | `lem-lsp-mode`; booster n/a (native client); `insertTextFormat=Snippet` uses the data-only field engine with dynamic capability advertising, and accepted items support bounded lazy resolve plus direct/resolved `additionalTextEdits`; resolved documentation/detail and completion commands remain gaps |
| flycheck (+rust) | partial | LSP diagnostics overlays; no non-LSP linter framework |
| apheleia | partial | `SPC b f` → LSP format (`src/ide.lisp`); configured format-on-save behavior is absent |
| dape (DAP debugging) | gap | Lem has no DAP client |
| treesit-auto / tree-sitter-langs / tsc / grammars | partial | `lem-tree-sitter` + 10 grammars baked in; modes default to TextMate highlighting (manual opt-in API) |
| nix-mode | lem-builtin+ported | `lem-nix-mode` + **nixd** spec incl. flake options/formatter (`src/ide.lisp`) |
| rust-mode | lem-builtin+ported | `lem-rust-mode` + **rust-analyzer** spec (`src/ide.lisp`) |
| go-mode | lem-builtin | `lem-go-mode` + gopls spec (in-tree) |
| markdown-mode / markdown-ts-mode | lem-builtin+ported | `lem-markdown-mode` + **harper-ls** spec (`src/ide.lisp`) |
| (python via pyright) | ported | spec overridden pylsp → **pyright** (`src/ide.lisp`) |
| terraform-mode | lem-builtin | in-tree spec (terraform-ls) |
| clojure-ts-mode / cider | lem-builtin | `lem-clojure-mode` + clojure-lsp + nREPL repl |
| eglot-java | gap | no jdtls spec (jdt launcher out of scope); `lem-java-mode` syntax only |
| gdscript-mode | gap | no Godot mode/LSP in Lem |
| nasm-mode | lem-builtin | `lem-asm-mode` |
| just-mode / meson-mode / nginx-mode / nushell-ts-mode / typst-ts-mode | gap | open as fundamental (no Lem modes) |
| yaml-mode | lem-builtin | `lem-yaml-mode` |
| sqlite3 | n/a | elisp FFI library |
| lispy / lispyville | ported | Paredit in Common Lisp, Clojure, Scheme/Racket, and Elisp; delimiter-safe Vim operators, atom motions, slurp/barf, drag, splice, split, raise, transpose, convolute, and list insertion/opening (`src/structural.lisp`, `scripts/structural-test.sh`); plus full SLIME via micros |
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
| vundo | gap | linear undo/redo only |
| pulsar | n/a | jump recentering is default behavior |
| indent-bars | gap | no indent guides in ncurses frontend |
| rainbow-delimiters | partial | paren coloring in lisp-mode; show-paren elsewhere |
| display-line-numbers (built-in) | ported | relative numbers render in saved and unsaved programming buffers, compose with other gutters, and stay out of prose and utility buffers (`src/ui.lisp`, `scripts/ui-parity-test.sh`) |
| dirvish | lem-builtin | `directory-mode` + filer |
| find-name-dired (built-in) | ported/partial | `M-s f` asynchronously fills a persistent, read-only `*Find*` buffer with safely escaped rows backed by exact paths (`src/find-name.lisp`); Dired marking, long columns, file operations, and process cancellation remain gaps |
| electric-pair-mode / delete-selection-mode (built-ins) | ported/partial | syntax-table delimiter/quote pairing, local balance reuse/skip, numeric prefixes, ordinary region replacement, and Emacs-style opener/quote region wrapping; an unmatched embedded quote is escaped to keep the Lisp string valid instead of reproducing Lispy's raw interior quote, while full forward balance scanning, global paired Backspace, and zero-result prompt recovery remain gaps (`src/electric-pair.lisp`, `scripts/electric-editing-test.sh`) |
| ws-butler | ported | track changed programming-buffer lines and trim only those lines on save (`src/editing.lisp`) |
| ibuffer | lem-builtin/partial | `list-buffers` (`C-x C-b`) provides Buffer/File columns, fuzzy narrowing, and Return-to-open; the configured org/tramp/emacs/ediff/dired/terminal/help saved groups are absent |
| bookmarks (built-in) | lem-builtin | `lem-bookmark`, `SPC b m` / `SPC RET` |
| avy | partial | `SPC l` goto-line, `SPC a` snipe, `SPC s` isearch-symbol |
| gcmh / no-littering / use-package / direnv / sops / editorconfig | n/a or gap | SBCL image needs no GC hacks; no-littering n/a; **direnv/sops/editorconfig: gap** |
| auto-revert / savehist / save-place / recentf (built-ins) | partial | recentf is ported as a persistent, deduplicated 300-file MRU on `M-g r`; global auto-revert, save-place, and the expanded savehist variables remain gaps |
| doom-themes | n/a | Emacs config loaded no theme; Lem default kept (185 base16 themes available) |
| notmuch-outlook / business-visual profile / nodes-org-sync | gap | host-gated bespoke integrations, out of scope |

## Behavioral divergences worth knowing

- **Surround grammar**: standard `ys`/`ds`/`cs` and visual `S` work, including
  common padded delimiters, but tag prompts and syntax-aware balancing do not.
- **Format-on-save** is manual (`SPC b f`), not automatic.
- **org files** open as plain text; the workflows (capture/dailies/journal/agenda)
  operate on the same files but there is no org folding/links/tables UI.
- **Completion previews**: no consult-style live preview while cycling candidates.
- **Find-name results** persist after opening a match and are safe for spaces,
  control characters, and shell-looking patterns, but they are a path list rather
  than a full Dired buffer with marking and file operations.
- **Buffer list groups**: `C-x C-b` has useful columns and fuzzy narrowing, but
  not the configured Ibuffer saved filter groups.
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
