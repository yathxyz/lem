# Emacs Configuration Feature Inventory ("lem-yath")

Authoritative inventory for porting this Emacs config (config name: **lem-yath**, user `yanni`/`yath`) to the Lem editor (Common Lisp). Built from the elisp under `home/config/emacs/` and the Nix package declarations in `lib/emacs-profile.nix`.

Source root: `/home/yanni/proj/nix/computer/home/config/emacs/`
Packages provided by Nix/Home-Manager (`package-enable-at-startup nil`); `use-package-always-ensure nil`.

Completion behavior was refreshed against computer commit
`883f9737f82359e2f634973e10dbab761e2b5138` and the running Emacs 31 daemon on
2026-07-10. Other sections still require row-by-row refresh through
`docs/parity-ledger.tsv` rather than being assumed current.

Key environment:
- `WORKDIR` env var (default `~/work`) is the notes/org root. `org-directory` = `$WORKDIR`.
- `org-roam` directory = `$WORKDIR/roam/`.
- Requires Emacs >= 30. `treesit-extra-load-path` from `$TREE_SITTER_GRAMMARS`.
- Server/daemon: `lem-yath/server-start-maybe` starts an Emacs server on init; `GIT_EDITOR`/`VISUAL`/`EDITOR` set to an `emacsclient --create-frame` invocation.

---

## 1. Keybinding scheme (MOST IMPORTANT)

### 1.1 Evil setup

`init-evil.el`:
- `evil-mode 1`, with `evil-want-integration t`, `evil-want-keybinding nil` (defers to evil-collection).
- `evil-respect-visual-line-mode t`.
- `evil-undo-system 'undo-redo` (uses built-in `undo-redo`, NOT undo-tree).
- `evil-want-C-u-delete t` (C-u deletes to indent in insert state).
- `evil-want-minibuffer nil` (Evil is not active in the minibuffer).
- After `evil-maps` loads: `C-n` and `C-p` are **unbound** in `evil-motion-state-map`, `evil-insert-state-map`, `evil-emacs-state-map` (so they fall through to completion/global).
- `evil-collection` installed and `(evil-collection-init)` called globally (all default integrations).
- `evil-org` (with `evil-org-agenda-set-keys`) for org buffers.

Cursor colors (terminal): insert = green, normal = red, emacs = cyan. (In the optional business-visual profile these become shape-based: insert `(bar . 2)`, normal `box`, emacs `(bar . 2)`, visual `hollow`, replace `hbar`.)

Explicit initial states: `gptel-context-buffer-mode` -> `emacs`.

### 1.2 Leader key

**Leader = `SPC`** in normal and visual states, via `general.el`, keymap `override`. There is also an **insert-state `C-c` prefix** with one binding.

#### Leader (`SPC`) bindings — normal + visual states

| Key sequence | Command | What it does |
|---|---|---|
| `SPC h k` | `helpful-callable` | Describe function (helpful) |
| `SPC h v` | `helpful-variable` | Describe variable (helpful) |
| `SPC h K` | `helpful-key` | Describe key (helpful) |
| `SPC h d` | `devdocs-lookup` | DevDocs documentation lookup |
| `SPC f f` | `find-file` | Find file |
| `SPC <` | `switch-to-buffer` | Switch buffer |
| `SPC n r f` | `org-roam-node-find` | Find/open roam node |
| `SPC n r i` | `org-roam-node-insert` | Insert link to roam node |
| `SPC n r a` | `org-roam-node-random` | Open random roam node |
| `SPC n r d t` | `org-roam-dailies-goto-today` | Today's daily note |
| `SPC n r d d` | `org-roam-dailies-goto-date` | Daily note by date |
| `SPC n j j` | `org-journal-new-entry` | New org-journal entry |
| `SPC m I` | `org-id-get-create` | Create/get Org ID on heading |
| `SPC m a` | `org-agenda` | Org agenda |
| `SPC o` | `org-capture` | Org capture |
| `SPC g g` | `lem-yath-vcs-status` | Smart VCS status: jj->majutsu, git->magit (auto-detect) |
| `SPC g G` | `lem-yath-magit-status` | Force Magit status at git root |
| `SPC g J` | `lem-yath-majutsu-status` | Force Majutsu (jj) log at jj root |
| `SPC g t` | `git-timemachine` | Git time machine |
| `SPC p f` | `project-find-file` | Project find file |
| `SPC p g` | `project-find-regexp` | Project grep (regexp) |
| `SPC p p` | `project-switch-project` | Switch project |
| `SPC p s` | `consult-eglot-symbols` | LSP workspace symbol search |
| `SPC SPC` | `consult-project-buffer` | Project buffer switcher |
| `SPC g l` | `yath/gptel-preset-menu` | gptel preset/handoff transient menu |
| `SPC g L` | `gptel-menu` | Full gptel transient menu |
| `SPC g j` | `gptel-send` | Send to LLM (gptel) |
| `SPC c c` | `compile` | Compile |
| `SPC y o` | `citar-open` | Open citation resource (citar) |
| `SPC b m` | `bookmark-set` | Set bookmark |
| `SPC RET` | `bookmark-jump` | Jump to bookmark |
| `SPC m e e` | `eval-last-sexp` | Eval last sexp |
| `SPC y a` | `auto-fill-mode` | Toggle auto-fill |
| `SPC y c` | `yath/centered-view-mode` | Toggle centered-margin view (custom) |
| `SPC y v` | `visual-line-mode` | Toggle visual-line |
| `SPC y w` | `fill-paragraph` | Fill paragraph |
| `SPC b k` | `kill-current-buffer` | Kill current buffer |
| `SPC b f` | `apheleia-format-buffer` | Format buffer (apheleia) |
| `SPC e a` | `embark-act` | Embark act |
| `SPC u` | `vundo` | Visual undo tree |
| `SPC l` | `evil-avy-goto-line` | Avy: jump to line |
| `SPC a` | `evil-avy-goto-char` | Avy: jump to char |
| `SPC s` | `evil-avy-goto-symbol-1` | Avy: jump to symbol |
| `SPC v` | `expreg-expand` | Expand region (expreg) |

Note: avy commands are bound but `avy` is **not** an explicitly declared/configured package in nix or elisp — assume it ships with evil-collection / is a transitive dep, OR is a porting gap to flag.

#### Insert-state `C-c` prefix (keymap override)

| Key | Command | What it does |
|---|---|---|
| `C-c i` | `gptel-send` | Send to LLM from insert state |

#### Other evil bindings (init-evil.el)

| Key | State | Command | What it does |
|---|---|---|---|
| `M-<backspace>` | insert | `evil-delete-backward-word` | Delete previous word |
| `gc` | normal, visual | `evilnc-comment-operator` | Comment operator (evil-nerd-commenter) |

### 1.3 Global (non-leader) bindings — `use-package emacs` in `init.el`

| Key | Command | What it does |
|---|---|---|
| `M-o` | `other-window` | Switch window |
| `M-j` | `duplicate-dwim` | Duplicate line/region |
| `M-g r` | `recentf` | Recent files |
| `M-s g` | `grep` | Grep |
| `M-s f` | `find-name-dired` | Find files by name -> dired |
| `C-x C-b` | `ibuffer` | ibuffer (custom saved filter groups: org/tramp/emacs/ediff/dired/terminal/help) |

### 1.4 Mode-local bindings

| Mode / map | Key | Command |
|---|---|---|
| `evil-normal-state-map` (Claude Code) | `C-c c` | `claude-code-transient` (via `:general`) |
| `notmuch-show-mode-map` | `C-c s e` | `salta-open-payment-email-from-notmuch` |
| global | `C-c s` | `yath/salta-prefix-map` (Salta prefix, see below) |
| `elfeed-show-mode-map` | `A` | `elfeed-show-archive` (open entry via archive.is in eww) |
| `.dir-locals.el` (per-project eval) | `C-c i` | `consult-outline` (set in a safe local var) |

**Salta prefix `C-c s` (`yath/salta-prefix-map`):**

| Key | Command |
|---|---|
| `C-c s s` | `salta-find-property` |
| `C-c s d` | `salta-property-detail` |
| `C-c s r` | `salta-property-reckoner` |
| `C-c s c` | `salta-contractor-rates` |
| `C-c s f` | `salta-contractor-financials` |
| `C-c s p` | `salta-payments` |

### 1.5 Text objects / operators / structural editing

- **evil-surround**: `global-evil-surround-mode 1` — `ys`/`cs`/`ds` surround operators (defaults).
- **evil-snipe**: `evil-snipe-mode 1` + `evil-snipe-override-mode 1`. `evil-snipe-scope 'visible`, `evil-snipe-repeat-scope 'whole-visible`. Overrides `f`/`t`/`s`/`S` with 1- and 2-char snipe motions.
- **evil-nerd-commenter**: `gc` operator in normal + visual (see above).
- **expreg**: `expreg-expand`/`expreg-contract` (deferred). Bound to `SPC v`. (Replaces expand-region.)
- **lispy / lispyville** (Lisp structural editing): `lispy-mode` on `lisp-mode`, `emacs-lisp-mode`, `ielm-mode`, `scheme-mode`, `racket-mode`, `clojure-mode`. `lispyville-mode` follows lispy. `lispyville-key-theme`: `((operators normal) c-w (prettify insert) (atom-movement t) slurp/barf-lispy additional additional-insert)`. `lispy-close-quotes-at-end-p t`. Evil-escape is inhibited while in lispy insert state.

---

## 2. Editing behavior

- **Indentation**: `indent-tabs-mode -1` (spaces, global). `tab-width 4`. `tab-always-indent 'complete` (TAB indents then completes). `editorconfig-mode` on `prog-mode`. `org-src-preserve-indentation t`. A safe-local var sets `smie-indent-basic 2`.
- **ws-butler**: `ws-butler-mode` on `prog-mode` (trims trailing whitespace only on touched lines).
- **Electric pairs**: `electric-pair-mode t` (global auto-pairing).
- **delete-selection-mode 1**: typing replaces active region.
- **Scrolling**: `scroll-conservatively`/`scroll-margin` are present but **commented out** (defaults in effect). `truncate-lines t` default (long lines truncate, arrow glyph `→`). Vertical border glyph `│`.
- **Undo**: `evil-undo-system 'undo-redo` (built-in). `vundo` for a visual undo tree (`SPC u`), `vundo-glyph-alist = vundo-unicode-symbols`. Undo limits raised: `undo-limit` 13*160000, `undo-strong-limit` 13*240000, `undo-outer-limit` 2*24000000.
- **multiple-cursors**: declared in nix; **no keybindings or config**. Only used *internally* by `init-ai.el` to draw a fake cursor overlay during gptel streaming (`mc/make-cursor-overlay-at-point`). Not an interactive editing feature here.
- **expreg**: region expansion (see §1.5).
- **Misc**: `kill-do-not-save-duplicates t`, `set-mark-command-repeat-pop t`, no lockfiles, no backup files, no auto-save. `M-j` = `duplicate-dwim`. `delete-selection-mode`.

---

## 3. Completion stack

| Package | Status | Config |
|---|---|---|
| **vertico** | active (`after-init`) | `vertico-count 20`, `vertico-cycle t`, `vertico-resize t`, `vertico-scroll-margin 0` |
| **orderless** | active globally | `completion-styles '(orderless)` outside Vertico; files initially override this with `partial-completion` |
| **marginalia** | active (`after-init`) | annotations, defaults |
| **corfu** | active | global, automatic in-buffer popup; live defaults use a 3-character prefix, 0.2-second delay, 10 rows, and no cycling |
| **TTY Corfu rendering** | active | Emacs 31 native `tty-child-frames`; no `corfu-terminal` package or mode is installed |
| **cape** | deferred providers | prepends `cape-file` and `cape-dabbrev` to `completion-at-point-functions`; no Cape snippet provider |
| **yasnippet** | active (`after-init`, `yas-global-mode`) | snippet dir = `user-emacs-directory/snippets/`; it currently contains only the Org `jjs` source-block snippet described below |
| **yasnippet-snippets** | active if installed | 2,387 community definitions at commit `606ee926df6839243098de6d71332a697518cb86` |
| **prescient / vertico-prescient** | active | persistent usage data; Vertico locally uses Prescient literal/regexp/initialism filtering and learned sorting instead of the global Orderless style |
| **consult** | deferred/autoloaded | `consult-project-buffer` (`SPC SPC`); `consult-outline` is bound by `.dir-locals.el` but has a cold-start autoload defect in Emacs that Lem should not reproduce |
| **consult-eglot** | deferred/autoloaded | `consult-eglot-symbols` (`SPC p s`) performs workspace-symbol search |
| **embark** | deferred/autoloaded | only `embark-act` is exposed (`SPC e a` and `M-x`); no minibuffer binding or custom action maps |
| **embark-consult** | installed only | no load/configuration path in the current config |
| **wgrep** | deferred; `wgrep-change-to-wgrep-mode` (editable grep buffers) |

Core completion settings (`init.el`): `completion-ignore-case t`,
`completions-detailed t`, `tab-always-indent 'complete`. In effect there are two
pipelines: Vertico + Marginalia + Prescient for minibuffers, and Corfu +
Orderless + mode/Cape CAPFs in ordinary buffers. Yasnippet expands separately
through `TAB`; it is not a Cape candidate source.

The private corpus is exactly `org-mode/srcblock.snpt`. Its `jjs` trigger
expands the following body, first visiting the `language` field and then the
final position on the blank line:

```text
#+BEGIN_SRC ${1:language}
$0
#+END_SRC
```

The community collection is not purely declarative: alongside ordinary fields,
defaults, nesting, and mirrors, some definitions use backquoted Emacs Lisp,
field transforms, conditions, command snippets, or contextual expansion
settings. Reproducing basic placeholder syntax alone therefore does not imply
full Yasnippet compatibility.

---

## 4. IDE / language tooling

**LSP client = Eglot (built-in), boosted by `eglot-booster`** (`eglot-booster-mode 1`; requires `emacs-lsp-booster` binary on PATH).

The pinned runtime advertises `completionItem.snippetSupport` because
Yasnippet is active. On acceptance, Corfu closes first and Eglot passes format-2
`insertText` or the winning `textEdit.newText` directly to
`yas-expand-snippet`; there is no TextMate-to-Yas translation layer.
Consequently numbered fields, mirrors, and `$0` work, while
`${TM_FILENAME}` and `${1|one,two|}` become editable literal Yas fields and
paired backquotes are executable in Emacs. Eglot resolves a data-bearing item
synchronously when the server supports resolve, applies `additionalTextEdits`
after the primary expansion, ignores the completion command, and does not
advertise CompletionList item defaults or `insertTextMode`.

Diagnostics policy (`yath/eglot-managed-diagnostics`): when an Eglot-managed buffer becomes active, **Flycheck is turned off and Flymake (Eglot's default) is used**; Flycheck is restored when Eglot detaches. So Flycheck is the linter for non-LSP prog buffers, Flymake for LSP buffers.

`eglot-ensure` wrapper `yath/eglot-ensure` skips minibuffers and remote (TRAMP) dirs.

**Tree-sitter**: `treesit-auto` with `treesit-auto-install nil` (grammars from Nix `treesit-grammars.with-all-grammars` / `$TREE_SITTER_GRAMMARS`), `global-treesit-auto-mode 1`, added to `auto-mode-alist` for all. `treesit-font-lock-level 4`. An advice skips activation in transient internal buffers.

**apheleia** = formatter-on-save: `apheleia-mode` on `prog-mode` (`SPC b f` = `apheleia-format-buffer`). Uses apheleia's default per-language formatter registry (no custom formatter overrides in elisp) — backed by the Nix-provided binaries below.

**dape** = DAP debugging: `dape-breakpoint-global-mode`, deferred, default adapter config. (Python debug via `debugpy`/`debugpy-adapter`, Go via `dlv`/`dlv-dap`, Rust/C via `lldb-dap`.)

### Per-language

| Language | Major mode | LSP server (binary) | Formatter (apheleia) | Linter | Debug | Notes |
|---|---|---|---|---|---|---|
| **Nix** | `nix-mode` (`.nix`) | **`nixd`** (custom workspace config: nixpkgs expr from flake, flake option sources for `~/proj/nix/computer` -> `nixosConfigurations.nova.options` + `homeConfigurations.yanni.options`, formatter = nixfmt-rfc-style/nixfmt/alejandra) | nixd `formatting.command` | — | — | extensive custom `yath/nixd-*` setup |
| **Rust** | `rust-ts-mode` (`.rs`), also `rust-mode` hooked | **`rust-analyzer`** | `rustfmt` | `flycheck-rust` (`flycheck-rust-setup`) | `lldb-dap` | `cargo`, `rustc`, `clippy`/`cargo-clippy` on PATH |
| **Go** | `go-mode` / `go-ts-mode` (eglot via hook) | **`gopls`** | `gofmt`/`goimports` (apheleia; `goimports` on PATH) | Flymake (eglot) | `dlv`/`dlv-dap` (delve) | `go-mode` declared, no explicit use-package |
| **Python** | python-ts/python-mode | **`pyright`** (`pyright-langserver`) | `ruff`/`black` (apheleia) | `ruff`, `mypy` | `debugpy` | `emacsDevPython` bundles debugpy+pytest |
| **Markdown** | `markdown-ts-mode` (`.md`), also `markdown-mode` | **`harper-ls --stdio`** (grammar/prose) | — | harper | — | `yath/eglot-ensure` on `markdown-mode` |
| **Java** | `java-mode`/`java-ts-mode` | **Eclipse JDT** via `eglot-java` (cache `~/.cache/eglot-java-eclipse-jdt-cache`) | Google Java style XML (remote URL) | Flymake | — | `eglot-java-mode` |
| **C# / .NET** | `csharp-mode`/`csharp-ts-mode` | eglot-ensure (server not pinned in elisp; relies on eglot default e.g. omnisharp/csharp-ls if present) | — | Flymake | — | hooked only |
| **GDScript** | `gdscript-mode` | eglot-ensure; `gdscript-eglot-version 3` (Godot's built-in LSP on TCP) | — | — | — | |
| **Terraform** | `terraform-mode` | eglot-ensure (terraform-ls if present) | — | Flymake | — | |
| **C / C++** | cc/c-ts modes | (clangd if present) | clang-format (apheleia) | Flycheck | `lldb`/`gdb` | `clang-tools`, `gcc`, `gdb`, `gnumake`, `pkg-config` on PATH |
| **Emacs Lisp / Lisp / Scheme / Racket / Clojure** | respective + `lispy`/`lispyville` | — | — | Flycheck (elisp `load-path inherit`) | — | `clojure-ts-mode`, `cider` declared in nix, **no explicit config** |
| **NASM** | `nasm-mode` (`.nasm`) | — | — | — | — | |
| **Nushell** | `nushell-ts-mode` (`.nu`) | — | — | — | — | |
| **Typst** | `typst-ts-mode` | declared in nix, **no explicit config** | — | — | — | gap to confirm |
| **YAML / Meson / nginx / Just** | `yaml-mode`, `meson-mode`, `nginx-mode`, `just-mode` | declared in nix, **no explicit config (defaults)** | — | — | — | |

**LSP server binaries required on PATH** (from `emacsRuntimeRequiredExecutables` + `emacsSharedDevTools`): `nixd`, `harper-ls` (pkg `harper`), `gopls`, `rust-analyzer`, `pyright-langserver` (pkg `pyright`), plus `emacs-lsp-booster`. Tooling binaries: `go`, `goimports` (gotools), `dlv`/`dlv-dap` (delve), `cargo`, `rustc`, `rustfmt`, `cargo-clippy` (clippy), `lldb-dap` (lldb), `python`, `debugpy`, `debugpy-adapter`, `pytest`, `ruff`, `black`, `mypy`, `clang-tools`, `gcc`, `gdb`, `gnumake`, `pkg-config`.

Helpers: `lem-yath/nixpkgs-build-outpath` (build a nixpkgs attr, return store path); `eglot-java` Google-style formatting init opts.

---

## 5. Git / VCS workflow

| Package | Status | Bindings / commands |
|---|---|---|
| **magit** | deferred | `magit-status`, `magit-dispatch` |
| **magit-todos** | active (`magit-todos-mode 1`) | TODO/FIXME listing inside magit |
| **forge** | deferred, `:after magit` | GitHub/GitLab PR & issue integration (default config) |
| **git-gutter** | active on `prog-mode` (`git-gutter-mode`) | gutter diff indicators (NOTE: `git-gutter`, not diff-hl) |
| **git-timemachine** | deferred | `SPC g t` — step through file history |
| **majutsu** | deferred (custom trivialBuild from `0WD0/majutsu`) | `majutsu-log`, `majutsu-dispatch` — **Jujutsu (jj)** porcelain, magit-style |

**Smart VCS dispatch** (custom, in `init-evil.el`):
- `lem-yath-vcs-status` (`SPC g g`): finds enclosing `.jj` -> opens `majutsu-log`; else `.git` -> `magit-status`; else `magit-status`. Operates from buffer-file dir.
- `lem-yath-magit-status` (`SPC g G`): force magit at git root.
- `lem-yath-majutsu-status` (`SPC g J`): force majutsu at jj root.
- Helper roots: `lem-yath-vcs--jj-root` (dominating `.jj`), `lem-yath-vcs--git-root` (dominating `.git`).

`vc-handled-backends '(Git)` only. `magit`/`magit-todos`/`forge`/`git-gutter`/`git-timemachine` all loaded via `init-evil`.

---

## 6. UI

- **Theme**: `doom-themes` declared (deferred), but **no `load-theme` is called at startup** in the elisp — the default Emacs theme is used unless the optional business profile is on. `custom-safe-themes` lists 9 hashes (doom variants) marked safe. So: *no active doom theme by default* — flag this; the only theme actually loaded by code is in the business-visual profile (`modus-operandi`, fallback `leuven`). **`doom-modeline` is referenced in `custom.el` (`doom-modeline-check-simple-format t`) but `doom-modeline` is NOT in the nix package list and never required** — likely vestigial. No modeline package is active; default Emacs modeline (mode-line disabled during early-init then restored).
- **Line numbers**: `display-line-numbers-type 'relative`; `display-line-numbers-mode` on `prog-mode` only.
- **pulsar**: deferred; `pulsar-delay 0.03`, `pulsar-iterations 4`, all auto-pulse functions disabled (`pulsar-pulse-functions nil`, region nil, on-window-change nil). Hooked into `consult-after-jump-hook` (recenter + reveal) and `imenu-after-jump-hook` (recenter). Effectively: recenter on jump, minimal flashing.
- **indent-bars**: `indent-bars-mode` on `prog-mode`; `indent-bars-treesit-support nil`.
- **rainbow-delimiters**: `rainbow-delimiters-mode` on `prog-mode`.
- **Fonts**: JetBrainsMono Nerd Font family chain (`JetBrainsMono Nerd Font Mono` -> `JetBrainsMono Nerd Font` -> `JetBrainsMono`), default height `120`. Applied to `default` + `fixed-pitch` via hooks (`after-init`, `window-setup`, `after-make-frame-functions`). `font-use-system-font nil`.
- **Tabs / windows**: `tab-bar` hints on, no close/new buttons. `winner-mode` (window layout undo). `split-width-threshold 170`, `split-height-threshold nil`. `switch-to-buffer-obey-display-actions t`. `org-roam` buffer shows in a right side-window (width 0.4).
- **dirvish**: `dirvish-override-dired-mode` on `after-init` (dirvish replaces dired everywhere).
- **Custom view modes**:
  - `yath/centered-view-mode` (`SPC y c`): balanced window margins to center text at `yath/centered-view-width` (default 100).
  - `yath/business-document-mode` & `yath/business-visual-mode`: an entire alternate "office document" presentation profile (proportional fonts: Aptos/Segoe UI/etc.; modus-operandi theme; calm faces; simplified modeline; variable-pitch; centered docs). **Auto-enabled only on hosts in `yath/business-visual-hosts` (default `("workwin")`).** Applies to org/markdown/text/message/notmuch/elfeed/nov/eww/helpful/Info modes. Large amount of code; T2/T3 for porting.
- Other UI: `which-key` (deferred 1s, `which-key-mode`), `helpful` (better help buffers), `transient` (`transient-default-level 7`, `q` quits), ANSI color in compilation output.

---

## 7. Org & notes

**Org root** = `$WORKDIR` (default `~/work`). `org-agenda-files` = `$WORKDIR`. `initial-major-mode org-mode`. `org-ellipsis " [...]"`.

### Capture (`org-capture-templates`)
- `i` Inbox -> `inbox.org` ("Inbox" headline), with CREATED prop.
- `t` TODO -> `todo.org` ("Inbox"), TODO state.
- `r` Reading -> `readlist.org` ("Inbox"), TODO state.

### org-roam
- `org-roam-directory` = `$WORKDIR/roam/` (truename). `:demand t`.
- Display template: `${file:30} :: ${title} ${tags:10}`.
- `org-roam-completion-everywhere t`. `org-roam-file-extensions '("org" "md")`. `org-roam-list-files-commands '(fd fdfind rg find)`.
- `org-roam-db-autosync-mode 1`. Excludes Syncthing `*.sync-conflict-*.org` files from indexing.
- **md-roam** (`nobiot/md-roam`, custom build): `md-roam-mode 1`, `md-roam-file-extension "md"` — markdown notes participate in roam graph (YAML front-matter id/title/created/tags).
- Roam capture templates: `n` note, `c` concept (`:concept:`), `p` project (`:project:`), `s` source (under `references/`, `:source:`), `m` markdown note (`.md` with YAML front-matter).
- **org-roam-dailies**: template `d` daily -> `%Y-%m-%d.org`. Bound via `SPC n r d t` / `SPC n r d d`.

### org-journal
- `:after org-roam`. `org-journal-dir` = `$WORKDIR/roam/journal/`. File format `%Y%m%d.org`, date format `%a, %Y-%m-%d`, date prefix `#+TITLE: `. `SPC n j j`.

### Agenda
- `org-agenda` on `SPC m a`.
- **org-super-agenda** (`org-super-agenda-mode 1`) — grouped agenda views (no custom groups defined in elisp; defaults).
- **evil-org-agenda** keys set.

### Visuals & babel
- **org-modern**: `org-modern-mode` on org buffers + `org-modern-agenda` on agenda finalize.
- **org-download** (deferred): `org-download-clipboard`/`org-download-yank`. Image dir = `$WORKDIR/media/`, `org-download-heading-lvl nil`.
- **Babel**: loaded langs = shell, sqlite, emacs-lisp, C, sql, python. `org-confirm-babel-evaluate` = custom `yath/org-confirm-babel-evaluate` (no prompt for `emacs-lisp`/`sqlite` inside trusted `$WORKDIR` notes). Python results = output; export = code. Custom `org-babel-execute:my/nix` (nix-build blocks). `ob-dsq` (datasette query), `ob-async` declared. LaTeX preview scale 2.
- **Publishing**: `org-publish-project-alist` — `org-roam-notes` (org->html) + `static` (assets) from `~/work/roam/` & `~/work/` to `~/proj/web/org-publishing/`.

### Bibliography / citations (in `init.el`)
- Bib files (lookup order): `~/work/librarium/nodes.bib` (PostgreSQL-generated), then `~/work/librarium/zotero.bib`.
- **citar** (`:after org`): `citar-notes-paths` = `$WORKDIR/roam/references/`; opens html/pdf externally, others via find-file. `SPC y o` = `citar-open`.
- **ebib** (deferred): preloads readable bib files.
- **reftex** (deferred): `reftex-default-bibliography` from the bib files.
- **org-ref**, **org-contrib**: declared in nix, **no explicit config (defaults)**.
- **cdlatex** declared (deferred), no hooks set.

### Nodes graph sync (custom, host-gated)
- On save, actionable org headings (TODO/scheduled/deadline/reading tags) under `$WORKDIR` are (optionally) given stable Org IDs and synced via external `nodes-org-sync` CLI. Enabled only on hosts in `yath/org-nodes-sync-hosts` (default `("nova")`). Auto-ID off by default. Skips Syncthing conflict files. This is a bespoke external integration — T3 for porting.

---

## 8. Apps

| App | Package | Status / config | Entry / bindings |
|---|---|---|---|
| **Mail** | `notmuch` | deferred. SMTP via local Proton Bridge: `smtpmail` to `127.0.0.1:1025` STARTTLS. `mail-user-agent notmuch-user-agent`. Newest-first search. Custom PDF attachment preview (`yath/notmuch-save-or-view-part`, opens PDFs in pdf-view, else saves). `notmuch-outlook.el` loaded if present (WSL). | `M-x notmuch` / `notmuch-search` / `notmuch-hello`; `yath/fetchmail` = `mbsync -a && notmuch new`. Pipeline: Proton Bridge -> `mbsync` (isync) -> notmuch. |
| **Feeds** | `elfeed` + `elfeed-protocol` | deferred. Fever protocol against `http://rss.wg:8070/fever/` (Miniflux), authinfo. `elfeed-use-curl t`, default filter `@2-years-ago`. Title widths tuned. Custom `elfeed-show-archive` (`A` key) -> archive.is in eww. | `M-x elfeed`. Pipeline: Miniflux -> elfeed-protocol (fever) -> elfeed. |
| **PDF** | `pdf-tools` | deferred (`pdf-tools-install`, `pdf-view-mode`) | used by notmuch attachment preview; opens PDFs |
| **EPUB** | `nov` | declared in nix; **no use-package config** (just in `yath/business-document-modes`). `nov-mode` for `.epub` (auto-mode by package default). | gap: confirm auto-mode mapping |
| **Terminal** | `vterm` | deferred (`commands (vterm)`). Used as `claude-code-terminal-backend`. | `M-x vterm` |
| **DevDocs** | `devdocs` | deferred | `SPC h d` = `devdocs-lookup`; `devdocs-install` |
| **PostgreSQL UI** | `pgmacs` (+ `pg`) | declared in nix (custom build from `emarsden/pgmacs`); **no use-package config / no binding** | `M-x pgmacs` available; no elisp wiring |

---

## 9. AI integrations

Core: **gptel** (deferred), heavily customized in `init-ai.el` (~1400 lines).

### gptel core config
- `gptel-default-mode 'org-mode`; prompt prefixes per mode (`# ` markdown/text, `* ` org).
- `gptel-use-tools nil` (default), `gptel-expert-commands t`, system message "Very short answers. Be helpful." API key from `OPENAI_API_KEY`.
- Loads local `gptel-stability.el` (`yath/gptel-stability-mode 1`) — hardening shims (killed-buffer callbacks, FSM/UI live-buffer assumptions, parallel prompt-transform races).
- **Default backend = OpenRouter** (`gptel-make-openai "OpenRouter"`, `openrouter.ai/api/v1/chat/completions`, key `OPENROUTER_API_KEY`), default model `openrouter/auto`. Async model discovery (`yath/openrouter-refresh-models`) with on-disk cache (`openrouter-models-cache.el`); falls back to `openrouter/auto` / `openrouter/free`.
- Other backends if available: GitHub Copilot (`gptel-make-gh-copilot`), Perplexity (`PERPLEXITY_API_KEY`).
- Org user prompts are rewritten to markdown before sending (`yath/gptel-org-prompt-transform`, with src/result block fencing).
- Visual polish: streaming fake-cursor overlay + role badges (User/Assistant) in header-line and inline (`yath/gptel-role-visuals-*`), toggle `yath/gptel-role-visuals-toggle`. Request tracing toggle `yath/gptel-debug-requests-toggle` (+ `-open`).
- **Presets** (`gptel-make-preset`): `quick-lookup` (default at startup, short answers, OpenRouter/auto, temp 0.2, max 800, no tools), `codex-agentic`, `grok-build`, `grok-build-oauth-agentic`. Preset model-compatibility advice (`yath/gptel--apply-preset-compatibility`).

### gptel preset/handoff menu (`yath/gptel-preset-menu` transient, `SPC g l`)
- Presets: load / save.
- Handoff to external chat apps: **Claude Desktop** (`claude://...` or web `claude.ai/new?q=`), **ChatGPT** (normal/temporary/search/research/model URL hints), prefilling current buffer/region as context (truncated to ~13000 chars). Browser preference: brave -> browse-url.
- `yath/llm-capture`: capture a prompt into today's dailies org topic and send via gptel.

### Local gptel backend plumbing files (load-path = user-emacs-directory)
- **gptel-claude-code.el** — Claude Code CLI (`claude`) as a gptel backend. Advises `gptel--handle-wait` to spawn an async subprocess (NDJSON streaming) instead of curl; CLI handles all tool execution (file edits, shell) and `--resume` for session continuity; org heading properties store session/message metadata for conversation forking. Registered via `gptel-make-claude-code "Claude Code" :executable "claude"`. No direct keybinding (used through gptel backend selection).
- **gptel-chatgpt-codex.el** — Native ChatGPT Codex backend: OAuth2+PKCE login against auth.openai.com, shares `~/.codex/auth.json`, refresh-token rotation, model discovery, SSE streaming from `/backend-api/codex/responses`. `gptel-make-chatgpt-codex "ChatGPT Codex"`; powers the `codex-agentic` preset (model `gpt-5.4`, agentic tools). Entry via gptel preset/menu.
- **gptel-codex.el** — OpenAI Codex CLI (`codex`) as a backend: `codex exec --json` / `codex exec resume --json`, JSONL streaming, renders command executions & file changes inline. `gptel-make-codex "Codex" :executable "codex"`.
- **gptel-grok-build.el** — xAI Grok Build CLI (`grok`) backend: `grok -p ... --output-format streaming-json`, OAuth/session inside CLI, read-only sandbox default (`read-only`, permission `dontAsk`). `gptel-make-grok-build "Grok Build"`; preset `grok-build`.
- **gptel-grok-build-oauth.el** — OpenAI-compatible HTTP proxy backend reading the `grok login --oauth` session; gptel drives the agentic tool loop. `gptel-make-grok-build-oauth-proxy "Grok Build OAuth"`; preset `grok-build-oauth-agentic`.
- **gptel-tooling.el** — read-only gptel tools (`project_root`, `list_project_files`, `search_project`, `read_project_file`, `read_emacs_symbol`) + optional MCP server definitions (fetch via `uvx mcp-server-fetch`; GitHub via dockerized `github-mcp-server`, read-only toolsets `context,repos,issues,pull_requests,users`). Used by agentic presets.
- **gptel-stability.el** — defensive shims (see above).

### claude-code.el (IDE integration)
- **claude-code** (deferred): `claude-code-terminal-backend 'vterm`, `claude-code-executable "npx ccr code"`. Binding `C-c c` -> `claude-code-transient` (evil normal state). Commands `claude-code`, `claude-code-transient`.
- **monet** (`stevemolitor/monet`, custom build): `monet-mode 1`; provides the MCP/websocket bridge so Claude Code can drive Emacs (diffs via `monet-ediff-tool`). Hooked into `claude-code-process-environment-functions`.

### mcp.el
- **mcp** (deferred): `mcp-hub`, `mcp-hub-start-all-server`, `mcp-hub-close-all-server`. Loads `gptel-tooling.el` on init. Server specs come from `gptel-tooling` (fetch + github).

---

## 10. Misc settings

- **no-littering**: `(require 'no-littering)` early (before any package writes data) — relocates var/etc files.
- **gcmh**: `gcmh-mode` on `after-init`; `gcmh-idle-delay 'auto`, factor 10, high threshold 16 MiB. (GC managed by gcmh after startup; during init `gc-cons-threshold` = most-positive-fixnum.)
- **direnv**: `direnv-mode` on `after-init` (per-project env via `direnv` binary).
- **sops**: `global-sops-mode` on `after-init` (transparent SOPS-encrypted file editing).
- **wgrep**: editable grep buffers (deferred).
- **helpful**: better help buffers (`SPC h k/v/K`, `helpful-at-point`).
- **editorconfig**: `editorconfig-mode` on `prog-mode`.
- **which-key**: deferred 1s.
- **Startup**: early-init disables tool/scroll/menu/blink-cursor bars, silences startup messages, sets `gc-cons-threshold` huge + `file-name-handler-alist nil` for fast init (restored on `emacs-startup-hook`). Native-comp warnings silenced. `inhibit-startup-message`, empty scratch message.
- **Server/daemon**: `lem-yath/server-start-maybe` starts server on init; `recentf-auto-cleanup` differs under daemon; editor env vars point to `emacsclient`.
- **xref/grep**: `xref-search-program 'ripgrep`; `grep-command "rg -nS --no-heading "`; extra ignored dirs (node_modules, build, dist, VCS).
- **auto-revert**: `global-auto-revert-mode`, also non-file buffers. `repeat-mode`, `savehist-mode` (+ kill ring and literal/regexp search rings), `save-place-mode` (limit 600).
- **`custom.el`**: `custom-safe-themes` (9 doom hashes), `newsticker-url-list` (many news/blog RSS feeds), `ede-project-directories`, warning suppression, and `safe-local-variable-values` (per-project org-roam db relocation, a gptel-context helper, `consult-outline` on `C-c i`, `smie-indent-basic 2`).
- **Native-compile**: all config files are AOT native-compiled by Nix.
- **markdown-ts-mode** / **nushell-ts-mode** / **sqlite3** loaded on non-Windows; `guix-autoloads` loaded if present.

---

## 11. Priority ranking for the Lem port

### Tier 1 — defines the daily editing experience (must port)
- **Evil/vim modal editing** (normal/insert/visual states, `undo-redo`) — Lem has vi-mode; map states + the `C-n`/`C-p` unbinding behavior.
- **`SPC` leader scheme** (general.el bindings) — the entire §1.2 table is the muscle-memory core. Highest-value port target.
- **evil-surround, evil-snipe (f/t/s overrides), evil-nerd-commenter (`gc`), expreg (`SPC v`)** — text-object/operator layer.
- **Completion**: Vertico/Marginalia/Prescient minibuffers plus automatic
  Corfu/Orderless/Cape in-buffer completion and separate Yasnippet expansion.
- **consult/project navigation** (`SPC p f/g/p/s`, `SPC SPC`, `project-find-file/regexp/switch`).
- **Editing defaults**: spaces (no tabs, width 4), electric-pair, ws-butler, delete-selection, vundo, relative line numbers on code.
- **Lisp structural editing** (lispy/lispyville) — relevant since Lem is Common Lisp; map to Lem's paredit-like features.
- **Fonts/UI basics**: JetBrainsMono, relative line numbers, rainbow-delimiters, which-key-equivalent.

### Tier 2 — important IDE features
- **LSP via Eglot** per language (nixd, rust-analyzer, gopls, pyright, harper-ls, eclipse-jdt) — Lem has `lem-lsp-mode`; replicate server list and the nixd custom workspace config + Go/Rust/Python/Nix coverage.
- **apheleia format-on-save** (`SPC b f`) and **flycheck/flymake** diagnostics policy.
- **tree-sitter** highlighting (`treesit-auto`) — Lem has its own highlighting; map grammar coverage.
- **Git**: magit (`SPC g g/G`) + git-gutter + git-timemachine; smart jj/git dispatch; majutsu (jj) if a Lem jj porcelain exists (likely a gap).
- **dape** debugging (Python/Go/Rust/C) — likely partial/gap in Lem.
- **Org capture + org-roam + dailies + journal** (`SPC o`, `SPC n r *`, `SPC n j j`) — large workflow; Lem has no org — major gap, document the capture/roam/journal data model and key paths (`$WORKDIR`, `roam/`, `roam/journal/`, `references/`, `media/`).
- **vundo, pulsar (recenter-on-jump), indent-bars, dirvish** UI niceties.
- **AI: gptel + claude-code/monet + mcp** entry commands (`SPC g j/l/L`, `C-c c`, `C-c i`) — Lem has no gptel; document as a port/gap (could wire an LLM client).

### Tier 3 — apps / bespoke integrations with likely no Lem equivalent (document as gaps)
- **notmuch mail** (+ Proton Bridge/mbsync pipeline, PDF preview) — no Lem mail client; gap.
- **elfeed RSS** (Miniflux/fever) — gap.
- **pdf-tools, nov (EPUB)** — gap.
- **citar/ebib/reftex/org-ref bibliography**, **org publishing**, **org-modern/super-agenda** — org-ecosystem, gap.
- **salta.el** (Supabase/PostgREST property/contractor/payments client; tabulated-list UIs; `C-c s` prefix; notmuch payment-email bridge) — bespoke business tool; would need a full reimplementation in CL (REST client + list UI) if desired. Document its commands (§ below).
- **business-visual / business-document modes** (office presentation profile, host-gated to `workwin`) — niche; gap/optional.
- **nodes-org-sync** (PostgreSQL graph sync of org headings, host-gated to `nova`), **pgmacs** (Postgres UI) — bespoke/external; gap.
- The many **gptel CLI backends** (Codex, Grok Build x2, ChatGPT Codex OAuth) — deeply Emacs/process-specific; gap unless a generic LLM client is built.

### salta.el commands (reference for any port)
- `salta-find-property` (fuzzy property search -> tabulated list), `salta-property-detail`, `salta-property-reckoner` (revenue/cost/profit + totals/margin), `salta-contractor-rates`, `salta-contractor-financials`, `salta-payments`, plus list/detail navigation (`RET` open, `w` copy, `r` reckoner, `g` refresh; detail: `c` claims, `p` payments) and `salta-open-payment-email-from-notmuch`. Talks to a Supabase PostgREST API (`/rest/v1/...`, RPCs `fuzzy_search_properties`, `get_reckoner_data`); creds via `salta-base-url`/`salta-api-key`/env/`~/.config/salta/credentials.json`.

---

## Packages declared in Nix but with NO explicit elisp config (defaults / vestigial)

`embark-consult`, `multiple-cursors` (internal overlay use only), `nov`,
`pgmacs`/`pg`, `eldoc-box`, `org-ref`, `org-contrib`, `ob-async`, `yaml-mode`,
`meson-mode`, `nginx-mode`, `just-mode`, `cider`, `clojure-ts-mode`, `go-mode`
(hooked but no use-package), `typst-ts-mode`, `engrave-faces`,
`tree-sitter-langs`/`tsc`, `cdlatex` (declared, no hook). `doom-modeline` is
referenced in `custom.el` but is **not** in the package list and never loaded
(dead reference).
