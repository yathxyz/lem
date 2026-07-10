# Port map: every declared Emacs package → its Lem disposition

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
| evil-surround | ported | visual `S`, `g s` motion, `d s`, `c s` (`src/vi.lisp`) |
| evil-snipe | ported | `s`/`S` 2-char snipe (`src/vi.lisp`) |
| evil-nerd-commenter | ported | `g c` operator (`src/vi.lisp`) |
| evil-org | n/a | no org buffers in Lem |
| general (SPC leader) | ported | vi-mode leader = Space + full chord map (`src/keybindings.lisp`) |
| vertico | ported/lem-builtin | prompt completion list opens instantly (`src/completion.lisp`) |
| orderless | ported | `orderless-filter` wired into command/buffer prompts; Space re-filters instead of closing the popup, so multi-token input works (`src/completion.lisp`) |
| marginalia | lem-builtin | M-x candidates show keybindings (kept by the wrapper) |
| consult | ported/partial | project buffers `SPC SPC`, project-grep, isearch; no preview-on-move |
| consult-eglot | partial | `SPC p s` → `lsp-document-symbol` (document-, not workspace-wide) |
| corfu (+terminal) | lem-builtin | `lem/completion-mode` popup (LSP/async) |
| cape | partial | dynamic abbrev `M-/`; no file/yasnippet sources |
| prescient (+vertico-) | n/a | never enabled in the Emacs config either |
| embark (+consult) | gap | no action-at-point framework in Lem |
| wgrep | lem-builtin | grep results are editable & write back (better than default Emacs) |
| eglot + eglot-booster | lem-builtin | `lem-lsp-mode`; booster n/a (native client) |
| flycheck (+rust) | partial | LSP diagnostics overlays; no non-LSP linter framework |
| apheleia | ported | `SPC b f` → LSP format (`src/ide.lisp`); no save-hook auto-format |
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
| lispy / lispyville | lem-builtin | `lem-paredit-mode` on lisp buffers (`src/vi.lisp`); plus full SLIME via micros |
| magit | lem-builtin | `lem/legit` (status/stage/commit/branch/push/pull/stash/rebase); `SPC g G` |
| magit-todos | gap | no TODO section in legit |
| forge | gap | no GitHub/GitLab integration |
| git-gutter | lem-builtin | `lem-git-gutter`, enabled globally (`src/git.lisp`) |
| git-timemachine | ported | `SPC g t` (`src/apps/timemachine.lisp`) |
| majutsu (jj) | ported/partial | smart dispatch `SPC g g` + jj status/log view (`src/git.lisp`); no staging UI |
| org (capture) | ported | `SPC o` → inbox/todo/readlist with CREATED property (`src/notes.lisp`) |
| org-roam | ported/partial | find/insert/random over $WORKDIR/roam incl. .md (`src/notes.lisp`); no backlinks/db |
| md-roam | ported | .md notes are first-class in the roam-lite layer |
| org-roam-dailies | ported | `SPC n r d t` / `SPC n r d d` (`src/notes.lisp`) |
| org-journal | ported | `SPC n j j`, same file layout + timestamp headings |
| org-agenda / org-super-agenda | ported/partial | scanning agenda: overdue/today/upcoming/todos (`src/apps/agenda.lisp`) |
| org-modern / org-download / org-ref / org-contrib / ob-async / ob-dsq / engrave-faces / cdlatex | gap | org ecosystem (visuals/babel/export) — no org-mode in Lem |
| citar / ebib / reftex | ported (citar) | bib parse + open file/url/note, `SPC y o` (`src/apps/citar.lisp`); ebib/reftex gap |
| gptel | ported | OpenRouter streaming client, `SPC g j/l/L` (`src/llm.lisp`) |
| gptel-claude-code / gptel-codex / gptel-grok-build | ported | CLI backends + `SPC g b` switcher (`src/apps/llm-cli.lisp`) |
| gptel-chatgpt-codex / gptel-grok-build-oauth | gap | OAuth/PKCE token flows out of scope |
| gptel-tooling / gptel-stability | n/a | Emacs-internals hardening / tool plumbing |
| claude-code.el | lem-builtin | `lem-claude-code` extension, `C-c c` |
| monet | partial | Lem ships an MCP **server** + Claude Code integration natively |
| mcp.el | partial | `lem-mcp-server` (Lem as server); no generic MCP client hub |
| notmuch | ported | search/read/refresh via notmuch CLI (`src/apps/notmuch.lisp`) |
| elfeed + elfeed-protocol | ported | Miniflux Fever API reader (`src/apps/elfeed.lisp`) |
| devdocs | ported | devdocs.io index lookup + text rendering, `SPC h d` (`src/apps/devdocs.lisp`) |
| pdf-tools | gap | terminal frontend; PDFs open externally (xdg-open) |
| nov (EPUB) | gap | no EPUB rendering |
| vterm | lem-builtin | `lem-terminal` (libvterm), `M-x terminal` |
| pgmacs / pg | ported | psql-backed query/table viewer (`src/apps/pg.lisp`) |
| salta.el | ported | Supabase/PostgREST client, `C-c s` prefix (`src/apps/salta.lisp`) |
| helpful | lem-builtin | describe-key / describe-bindings / apropos-command (`SPC h *`) |
| which-key | lem-builtin | prefix/transient keymap UI (`lem/transient`) |
| transient | lem-builtin | `lem/transient` |
| multiple-cursors | lem-builtin | core multi-cursors (`M-C`, isearch add-cursor); Emacs config only used it internally |
| expreg | gap | no expand-region; vi text objects cover most cases |
| vundo | gap | linear undo/redo only |
| pulsar | n/a | jump recentering is default behavior |
| indent-bars | gap | no indent guides in ncurses frontend |
| rainbow-delimiters | partial | paren coloring in lisp-mode; show-paren elsewhere |
| dirvish | lem-builtin | `directory-mode` + filer |
| ws-butler | ported | trim trailing whitespace on save (`src/editing.lisp`, whole-buffer) |
| ibuffer | lem-builtin | `list-buffers` (`C-x C-b`) |
| bookmarks (built-in) | lem-builtin | `lem-bookmark`, `SPC b m` / `SPC RET` |
| avy | partial | `SPC l` goto-line, `SPC a` snipe, `SPC s` isearch-symbol |
| gcmh / no-littering / use-package / direnv / sops / editorconfig | n/a or gap | SBCL image needs no GC hacks; no-littering n/a; **direnv/sops/editorconfig: gap** |
| savehist / save-place / recentf | partial | prompt histories persist per-session; Lem keeps its own history files |
| doom-themes | n/a | Emacs config loaded no theme; Lem default kept (185 base16 themes available) |
| notmuch-outlook / business-visual profile / nodes-org-sync | gap | host-gated bespoke integrations, out of scope |

## Behavioral divergences worth knowing

- **Surround keys**: `ys` is `g s` (visual `S` unchanged) — `y`/`c`/`d` are real
  vi operators in Lem and read a motion next.
- **ws-butler** trims the whole buffer, not only touched lines.
- **Format-on-save** is manual (`SPC b f`), not automatic.
- **org files** open as plain text; the workflows (capture/dailies/journal/agenda)
  operate on the same files but there is no org folding/links/tables UI.
- **Completion previews**: no consult-style live preview while cycling candidates.
