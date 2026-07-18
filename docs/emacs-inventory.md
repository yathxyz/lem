# Emacs Configuration Feature Inventory ("lem-yath")

Authoritative inventory for porting this Emacs config (config name: **lem-yath**, user `yanni`/`yath`) to the Lem editor (Common Lisp). Built from the authored elisp under `portable/dot_config/emacs/` and the Nix package declarations in `lib/emacs-profile.nix`.

Source root: `/home/yanni/proj/nix/computer/portable/dot_config/emacs/`
Packages provided by Nix/Home-Manager (`package-enable-at-startup nil`); `use-package-always-ensure nil`.

Completion and VCS behavior were refreshed against computer commit
`6bb888bba6d2547409b5c05c9740f0392fa96e30` and the running Emacs 31 daemon on
2026-07-12. AI startup and conversation behavior were refreshed against computer
commit `8d3d28d3438c44c4d63a7fb5b4e18d4297a68bee` on 2026-07-16. Other sections still require row-by-row refresh through
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
- `evil-respect-visual-line-mode t`: while `visual-line-mode` is active,
  `j/k`, `0/$`, `I/A`, `D/C`, doubled line operators, `Y`, and `V` follow
  screen rows, while `gj/gk` and `g0/g$` retain logical-line access.
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

The audited Nix-built Emacs profile contains Avy `20241101.1357`. The user
configuration has no Avy-specific variable or face overrides, so these commands
use the package defaults: balanced labels over `a/s/d/f/g/h/j/k/l`, `at-full`
placement, case-folded matching, immediate single-candidate jumps, every window
in the current frame from normal state (a prefix narrows to the current window),
and the current window from Visual or operator state with or without a prefix.
The stock dispatch map includes `x/X/t/m/n/y/Y/i/z` plus `?` help. Its `i`
action runs `ispell-word` at or before character/symbol targets and
`ispell-region` across line targets; the active configuration sets
`ispell-dictionary` to `en_US`.

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
| `M-s f` | `find-name-dired` | Find files by name -> Dirvish-overridden dired |
| `C-x C-b` | `ibuffer` | ibuffer (custom saved filter groups: org/tramp/emacs/ediff/dired/terminal/help) |

The Lem mapping preserves that group order and Ibuffer's exclusive first-match
partition, omits empty groups, retains unmatched buffers under `Default`, and
renders each group as a distinct collapsible heading. Its default row mirrors
the configured stock format's mark, modified/read-only/locked status, 18-cell
elided name, 9-cell right-aligned size, 16-cell elided mode, and file fields.
`L` toggles GNU Emacs's default `all` lock on ordinary-marked buffers or the
current row, `% L` marks locked rows, and the lock refuses buffer deletion and
editor exit before any window or teardown mutation.
The active Emacs defaults sort by recency. Evil-Collection remaps the stock sort
prefix: `o a/v/s/f/m` select name, recency, size, filename, or major-mode
sorting, `o i` reverses it, comma cycles the available sorters, and backtick
rotates to the second stock name/file format; `s` remains its filter prefix.
The Lem chooser implements those controls within each configured group. Its
effective modal core also matches `m/u/Backspace/U/t/~`, deletion marking and
execution with `d` then `x`, marked save with `S`, cyclic ordinary-mark
navigation with `{`/`}`, visible-snapshot starred marking for special,
modified, unsaved, read-only, Dired, dissociated, help, and compressed-file
buffers on `* *`/`* s`, `* m`, `* u`, `* r`, `* /`, `* e`, `* h`, and `* z`,
exact used-mode marking on `* M`, and name/mode/file/content regexp marking on
`% n/m/f/g`,
marked modified/read-only toggles and Emacs-style
unique renaming with `M/T/R`, one-confirmation marked-or-current reversion with
`V`, focused-buffer burying with `X`, row movement
with `gj/gk`, group
movement with Tab/backtab, `C-j/C-k`, and `]]/[[`, and quit with `q`.
Picker-local `M-j` completes over the currently displayed group headings and
moves to the exact heading without changing its collapsed state. `C-o`
displays the focused buffer in another ordinary window while retaining chooser
focus, and `M-o` visits it after deleting the other ordinary windows. `A` and
`gv` replace the chooser with balanced stacked windows for the ordinary-marked
buffers, while `gV` lays them out side by side; with no ordinary marks these
view commands use the current row, and `D` marks are excluded.
`gR` redisplays the existing snapshot, `gr` rebuilds it from live buffers while
preserving applicable marks and filters, `yb/yf` copy the focused buffer name or
visiting filename, and `go` visits the focused buffer in another window. `J`
and `M-g` complete over every snapshot buffer, expand a collapsed target group,
and retain GNU Ibuffer's refusal to bypass active filters. `=` opens a focused,
read-only unified diff for ordinary-marked file buffers or the unmarked current
row; non-file and `D`-marked buffers are ignored.
`s m/n/f/b/.` enter live case-insensitive regexp filters for used mode, buffer
name, full filename, basename, or extension; modal command letters remain
literal while entering a filter, Return pushes it onto the stack, and Escape
cancels only the pending input. `s RET` completes over one or more exact
registered major modes and accepts the displayed current-mode default; `s M`
offers snapshot modes and their CLOS parents. `s *` matches GNU's exact starred
name form, `s E` retains live generic, shell, compilation, and terminal process
owners, `s F` matches a file's containing directory or a non-file buffer's
working directory, `s <`/`s >` compare character sizes strictly, and `s c`
applies a case-insensitive content regexp. `s i` and `s v` push GNU Ibuffer's
modified and visiting-file filters, multiple filters compose by AND, `s !`
negates the top filter, `s p` removes it, and `s /` disables the stack
(`src/buffer-list.lisp`, `scripts/buffer-list-test.sh`).
`O` and `M-s a C-o` reproduce `ibuffer-do-occur` over ordinary marks, in GNU's
reverse display order, excluding `D`; with no ordinary marks the current row is
visibly marked and searched. A nonnegative numeric argument supplies context,
and the smart-case CL-PPCRE pattern may span lines. The persistent read-only
`*Occur*` result groups multiple matches on one source line, merges overlapping
context, retains live source points, and is displayed without selecting it.
Return, `C-c C-c`, Shift-Return, and `g o` visit; `M-Return` displays without
selection; `gj/gk`, `C-j/C-k`, and `n/p` traverse match blocks while previewing
the source. Invalid regexps preserve the prior result, no matches remove it,
and navigation refuses killed sources. Inputs are bounded at 16 million
characters per buffer and 64 million total, with 10,000 matches and 2 MiB of
rendered output.
`M-s a C-s` and `M-s a M-C-s` reproduce Evil Collection's
`ibuffer-do-isearch` and regexp variant over explicit ordinary marks in display
order, excluding `D`; unlike `define-ibuffer-op` actions, an empty marked set is
refused rather than implicitly marking the current row. Search starts at the
beginning of the first marked buffer and pauses there while input fails.
`C-s`/`C-r` continue and wrap across live marked buffers, pattern edits remain
incremental after a buffer crossing, Return retains the exact match and records
the appropriate literal/regexp history, and `C-g` restores the first source's
starting point while removing transient search modes from every source.
Evil Collection's `Q` and `I` reproduce the configured literal and regexp
marked-buffer query-replace entry points. They use ordinary marks in display
order, exclude `D`, and inherit the ordinary bulk-operation current-row
fallback. The chooser is hidden while each live buffer is queried from its
beginning, then rebuilt with its source window, point, focus, filters, and marks
intact. `y`/Space replaces, `n`/Backspace skips, `!` replaces the rest of the
current buffer only, `q`/Return advances to the next buffer, and `.` replaces
once before advancing. Each affected buffer receives one undo unit, and the
entire target set is checked for read-only buffers before any prompt can mutate
an earlier source. Matching
uses the configured GNU smart-case rule: lowercase searches fold case and
transfer lower, all-caps, or initial-cap patterns to replacements, while an
unescaped uppercase search is case-sensitive and keeps exact replacement case.
Regexp replacement expands `\&`, `\1`–`\9`, `\\`, and the per-buffer `\#`
count. Invalid regexps, invalid or unsupported replacement directives, and
empty-matching regexps are refused before mutation. GNU Lisp-evaluated `\,`,
per-match `\?` editing, zero-width matches, and the advanced `^`, `u/U`,
`e/E`, and recursive-edit actions remain gaps.
Like GNU Ibuffer, ordinary bulk operations implicitly mark the current row when
there are no ordinary marks and exclude `D` deletion marks. Revert failures are
isolated per buffer so a missing file does not prevent later buffers from being
reverted. The terminal implementation uses the exact one/count confirmation
prompt but omits GNU Ibuffer's auxiliary buffer-name window for a multi-buffer
confirmation.
Diff generation uses direct argument vectors, private temporary files, a
ten-second bound, 16-million-character per-input and 2-MiB output limits. A
missing associated file aborts before replacing the previous diff view. The
view uses a concise buffer heading instead of GNU Emacs's displayed
shell-command transcript.
Content filters skip buffers above 16 million characters rather than allocating
an unbounded copy; Lem also shows package-qualified mode labels to disambiguate
its Common Lisp mode registry.
The stock `.` command uses a real last-window-display timestamp and GNU
Ibuffer's configurable 72-hour default. The comparison is strict, and a buffer
with no display timestamp is not marked.
The effective Evil-Collection `-` and `+` commands stage session-local hide and
force-show name regexps with the focused name quoted as input. `gR` retains the
current rows, while `gr` activates the staged rules; force-show takes precedence
over hiding and ordinary filters. `K` hides visible ordinary-marked lines until
`gr`, which restores them unmarked without disturbing a visible `D` mark.

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
- **lispy / lispyville** (Lisp structural editing): `lispy-mode` on `lisp-mode`, `emacs-lisp-mode`, `ielm-mode`, `scheme-mode`, `racket-mode`, `clojure-mode`. `lispyville-mode` follows lispy. `lispyville-key-theme`: `((operators normal) c-w (prettify insert) (atom-movement t) slurp/barf-lispy additional additional-insert)`. `lispy-close-quotes-at-end-p t`. The configuration registers an Evil-Escape inhibition hook for Lispy insert state, but does not declare or enable `evil-escape`; no escape chord is effective in the audited configuration.

---

## 2. Editing behavior

- **Indentation**: `indent-tabs-mode -1` (spaces, global). `tab-width 4`. `tab-always-indent 'complete` (TAB indents then completes). `editorconfig-mode` on `prog-mode`. `org-src-preserve-indentation t`. A safe-local var sets `smie-indent-basic 2`.
- **ws-butler**: `ws-butler-mode` on `prog-mode` (trims trailing whitespace only on touched lines).
- **Electric pairs**: `electric-pair-mode t` (global auto-pairing).
- **delete-selection-mode 1**: typing replaces active region.
- **Scrolling**: `scroll-conservatively`/`scroll-margin` are present but **commented out** (defaults in effect). `truncate-lines t` is the default (long lines truncate, arrow glyph `→`); `SPC y v` toggles buffer-local, word-wrapped visual-line mode. Vertical border glyph `│`.
- **Large files**: `large-file-warning-threshold` is 50 MiB. A newly visited readable file strictly larger than that prompts before reading; Emacs 31 offers normal open, abort, or literal byte-oriented Fundamental mode. An already visited buffer is reused without the size prompt.
- **Undo**: `evil-undo-system 'undo-redo` (built-in). `vundo` for a visual undo tree (`SPC u`), `vundo-glyph-alist = vundo-unicode-symbols`. Undo limits raised: `undo-limit` 13*160000, `undo-strong-limit` 13*240000, `undo-outer-limit` 2*24000000.
- **multiple-cursors**: declared in nix; **no keybindings or config**. Only used *internally* by `init-ai.el` to draw a fake cursor overlay during gptel streaming (`mc/make-cursor-overlay-at-point`). Not an interactive editing feature here.
- **expreg**: region expansion (see §1.5).
- **Misc**: `kill-do-not-save-duplicates t`, `set-mark-command-repeat-pop t`, no lockfiles, no backup files, no auto-save. `M-j` = `duplicate-dwim`. In the pinned Emacs/Evil combination, Evil Visual Block leaves both `rectangle-mark-mode` and the ordinary region inactive, so `M-j` duplicates the active cursor line while retaining the block; only a native Emacs rectangular region takes `duplicate-dwim`'s duplicate-to-the-right path. `delete-selection-mode`.

---

## 3. Completion stack

| Package | Status | Config |
|---|---|---|
| **vertico** | active (`after-init`) | `vertico-count 20`, `vertico-cycle t`, `vertico-resize t`, `vertico-scroll-margin 0` |
| **orderless** | active globally | `completion-styles '(orderless)` outside Vertico; files initially override this with `partial-completion` |
| **marginalia** | active (`after-init`) | annotations with defaults: left alignment, a 20-column initial candidate width rounded upward in 10-cell steps, an 80-column maximum field width reduced to half the active window, right truncation for documentation, and left truncation for path fields |
| **corfu** | active | global, automatic in-buffer popup; live defaults use a 3-character prefix, 0.2-second delay, 10 rows, and no cycling |
| **TTY Corfu rendering** | active | Emacs 31 native `tty-child-frames`; no `corfu-terminal` package or mode is installed |
| **cape** | deferred providers | prepends `cape-file` and `cape-dabbrev` to `completion-at-point-functions`; no Cape snippet provider |
| **yasnippet** | active (`after-init`, `yas-global-mode`) | snippet dir = `user-emacs-directory/snippets/`; it currently contains only the Org `jjs` source-block snippet described below. No override changes the pinned defaults `yas-triggers-in-field nil` or `yas-snippet-revival t`, and no direct snippet key bindings are configured. |
| **yasnippet-snippets** | active if installed | 2,387 community definitions at commit `606ee926df6839243098de6d71332a697518cb86` |
| **prescient / vertico-prescient** | active | persistent usage data; Vertico locally uses Prescient's default directional character-folded literal/regexp/initialism filtering, smart case, and learned sorting instead of the global Orderless style; filtering also installs Prescient's prompt-local `M-s` toggle map (`a/f/i/l/P/p/r/'/c`), with a prefix argument selecting one method exclusively |
| **consult** | deferred/autoloaded | `consult-project-buffer` (`SPC SPC`); `consult-outline` is bound by `.dir-locals.el` but has a cold-start autoload defect in Emacs that Lem should not reproduce |
| **consult-eglot** | deferred/autoloaded | `consult-eglot-symbols` (`SPC p s`) queries every symbol-capable Eglot server registered to the current project, progressively appending responses without deduplication |
| **embark** | deferred/autoloaded | only `embark-act` is exposed (`SPC e a` and `M-x`); no minibuffer binding or custom action maps |
| **embark-consult** | effective on demand | no user configuration; the pinned Embark package loads it automatically after Consult loads when the installed library is available |
| **wgrep** | deferred; `wgrep-change-to-wgrep-mode` (editable grep buffers) |

The pinned Consult default leaves `consult-narrow-key` unset.  Its narrow map
still makes a sole, case-sensitive Consult-Eglot kind key followed by `Space`
activate that type before the ordinary query is entered; for example, `f Space`
selects Function and `C Space` selects Constant.  Backspace on an empty narrowed
prompt widens.  The active map is `c/f/e/i/m/n/p/s/t/v` for the lowercase
classes, `A/B/C/E/F/M/N/O/P/S` for the uppercase classes, and `o` for every
unlisted kind.  Lem reproduces this default path rather than inventing a global
narrow-prefix binding (`src/workspace-symbol.lisp`,
`scripts/lsp-project-test.sh`).

Lem mirrors the pinned multi-server source: an invoking project fans each
debounced query out to all of its ready symbol providers, appends responses as
they arrive, re-sorts the cumulative list by the optional numeric server score
(missing scores are zero), isolates server failures, and cancels every
outstanding request when input changes. Servers belonging to another open
project are excluded, and each result retains its source workspace for position
conversion, preview, and the final jump. Outside a recognized project, both
implementations fall back to the invoking language server.

The Lem port now covers the effective directory-local `consult-outline` path
without reproducing the Emacs cold-start defect: the exact declaration is read
without evaluation, `C-c i` keeps its Insert/Visual LLM meaning, and the
Normal/Emacs-state selector retains source order, preview rollback, matched-text
placement, recentering, and jumplist return (`src/project-outline.lisp`,
`scripts/project-outline-test.sh`).

The ordinary `M-x imenu` path is also effective and leaves GNU Imenu's defaults
unchanged: `imenu-flatten` is nil, spaces in names are displayed as dots, and a
nested group or document-symbol parent opens a successive `Index item` prompt.
When Eglot owns a buffer and advertises `documentSymbolProvider`, its response
replaces the mode-local index; hierarchical `DocumentSymbol` parents and the
older kind/container-grouped `SymbolInformation` schema are both accepted.
The configured `imenu-after-jump-hook` recenters but does not pulse the
destination. Lem reproduces this path for those Eglot buffers, for the pinned
Lisp generic-expression forms, and for native Org and Markdown indices
(`src/imenu.lisp`, `src/native-imenu.lisp`). Org uses the pinned depth-two
heading tree and reveals folded destinations. Markdown includes nested ATX and
Setext headings plus the pinned Footnotes group while excluding front matter,
fences, and comments. Native indices for other non-LSP modes remain a provider
gap.

The `embark-consult` load path comes from the pinned package rather than this
configuration: its `embark.el` registers a `with-eval-after-load` form for
Consult and then requires the installed integration library.  It is therefore
effective after both packages have loaded, not merely an unused declaration.

The audited Emacs 31 `project-switch-project` menu uses `f` find file, `g` find
regexp, `d` directory, `v` `project-vc-dir`, `e` `project-eshell`, and `o`
`project-any-command`. These are the interaction targets for Lem's project
switch transient, independently of the leader bindings that enter it.

Core completion settings (`init.el`): `completion-ignore-case t`,
`completions-detailed t`, `tab-always-indent 'complete`. In effect there are two
pipelines: Vertico + Marginalia + Prescient for minibuffers, and Corfu +
Orderless + mode/Cape CAPFs in ordinary buffers. Yasnippet expands separately
through `TAB`; it is not a Cape candidate source.

The pinned Corfu source supplies the active defaults `corfu-preselect 'valid`
and `corfu-preview-current 'insert`.  Corfu first moves a same-case exact
candidate to the front.  A provider-valid input still distinct from that first
candidate (including a case-folded exact match) starts on Corfu's prompt row;
otherwise the first candidate is preselected without being previewed. Moving to
another candidate displays a
non-mutating preview which is committed before subsequent ordinary input.
`TAB` completes, `RET` inserts the selection, `Escape` resets selection/input in
stages, `C-g` quits while retaining typed input, and `M-Space` inserts the
Orderless separator without accepting a preview. The default Corfu map also
uses `C-a`/`Home` and `C-e`/`End` for prompt-boundary motion, and moves by its
ten-row page with `C-v`/`PageDown` and `M-v`/`PageUp`. `M-TAB` expands the
common prefix unless the current candidate is explicitly previewed, in which
case it completes that candidate. `M-h` requests the selected candidate's
`company-doc-buffer`, which Eglot supplies from completion documentation, and
`M-g` requests `company-location`. Of the configured providers, Cape file
completion supplies locations, while Eglot and Cape Dabbrev do not.

An isolated live-Vertico probe confirmed that opening candidates does not insert
a common prefix or accept a singleton. `TAB` inserts the focused candidate while
retaining the minibuffer, `RET` accepts and submits once, and `M-p`/`M-n` traverse
history. Evil is disabled in the minibuffer, so standard Emacs line, character,
word, kill, yank, and transpose editing remains available while Vertico is
visible. `C-g` aborts; one physical `Escape` starts a Meta sequence rather than
aborting.

The pinned Orderless default affix table includes `%` character folding and `&`
annotation matching. `%` is effective in the ordinary Corfu/Orderless pipeline.
Upstream `orderless-annotation` deliberately returns metadata only in a
minibuffer, while this configuration's minibuffers use Vertico-Prescient rather
than Orderless; consequently `&` has no effective configured completion path.

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

**Tree-sitter**: `treesit-auto` with `treesit-auto-install nil` (grammars from Nix `treesit-grammars.with-all-grammars` / `$TREE_SITTER_GRAMMARS`), `global-treesit-auto-mode 1`, added to `auto-mode-alist` for all. `treesit-font-lock-level 3`. An advice skips activation in transient internal buffers.

**apheleia** = formatter-on-save: `apheleia-mode` on `prog-mode` (`SPC b f` = `apheleia-format-buffer`). Uses apheleia's default per-language formatter registry (no custom formatter overrides in elisp) — backed by the Nix-provided binaries below.

**dape** = DAP debugging: `dape-breakpoint-global-mode`, deferred, default adapter config. (Python debug via `debugpy`/`debugpy-adapter`, Go via `dlv`/`dlv-dap`, Rust/C via `lldb-dap`.)

### Compilation workflow

The configuration does not replace `compile.el`: `SPC c c` invokes the stock
`compile` command, and the only `use-package compile` customization adds
`ansi-color-compilation-filter` to `compilation-filter-hook`.  In the pinned
Emacs 31 build, `compilation-read-command` is therefore still `t`, so every
invocation prompts with the current buffer's `compile-command`.  Its untouched
default is `make -k -jN `, where `N = ceil(num-processors / 1.5)` (equivalently
`ceil(2 * num-processors / 3)`), including the trailing space.

Before starting, `compile` calls `save-some-buffers` for modified file-visiting
buffers.  This configuration prepends a `d` action which displays the live
buffer-versus-file diff and then returns to the save question.  The pinned
stock prompt also supports save, skip, save-all, save-this-and-finish, cancel,
view-buffer, visit-and-quit, mark-unmodified, and help actions.  The command
then runs asynchronously through a shell from the originating buffer's
`default-directory`, streams stdout/stderr into read-only `*compilation*`, and
leaves point at the beginning because `compilation-scroll-output` remains
`nil`.  The configured filter renders ANSI colour before the ordinary
`compile.el` diagnostic machinery drives source navigation.

The installed Evil Collection puts `compilation-mode` in Normal state and
supplies these effective modal bindings (stock `compile.el` supplies
`C-c C-k`, while the global next-error map supplies `M-g n/p`):

| Key | Effective command | Behavior |
|---|---|---|
| `RET` | `compile-goto-error` | Visit the diagnostic on the current log line |
| `go`, `M-RET`, `S-RET` | `compilation-display-error` | Display its source while retaining the compilation log as the selected window |
| `TAB`, `gj`, `C-j` | `compilation-next-error` | Move to the next diagnostic inside the log without selecting its source |
| `S-TAB`, `gk`, `C-k` | `compilation-previous-error` | Move to the previous diagnostic inside the log |
| `[[`, `]]` | `compilation-previous-file`, `compilation-next-file` | Move to a diagnostic for the previous or next source file |
| `gr` | `recompile` | Repeat the prior compilation context |
| `C-c C-k` | `kill-compilation` | Interrupt the running compilation process |
| `q`, `ZZ` | `quit-window` | Quit the read-only result window |
| `ZQ` | `evil-quit` | Use Evil's quit behavior |
| global `M-g n`, `M-g p` | `next-error`, `previous-error` | Visit the next or previous source diagnostic |

### Per-language

| Language | Major mode | LSP server (binary) | Formatter (apheleia) | Linter | Debug | Notes |
|---|---|---|---|---|---|---|
| **Nix** | `nix-mode` (`.nix`) | **`nixd`** (custom workspace config: nixpkgs expr from flake, flake option sources for `~/proj/nix/computer` -> `nixosConfigurations.nova.options` + `homeConfigurations.yanni.options`; formatter setting is conditional on nixfmt-rfc-style/nixfmt/alejandra being externally available) | conditional nixd `formatting.command` | — | — | extensive custom `yath/nixd-*` setup; the declared Emacs daemon PATH contains no Nix formatter candidate |
| **Rust** | `rust-ts-mode` (`.rs`), also `rust-mode` hooked | **`rust-analyzer`** | `rustfmt` | `flycheck-rust` (`flycheck-rust-setup`) | `lldb-dap` | `cargo`, `rustc`, `clippy`/`cargo-clippy` on PATH |
| **Go** | `go-mode` / `go-ts-mode` (eglot via hook) | **`gopls`** | `gofmt`/`goimports` (apheleia; `goimports` on PATH) | Flymake (eglot) | `dlv`/`dlv-dap` (delve) | `go-mode` declared, no explicit use-package |
| **Python** | python-ts/python-mode | **`pyright`** (`pyright-langserver`) when Eglot is started manually; no Python Eglot hook is configured | `ruff`/`black` (apheleia) | `ruff`, `mypy` | `debugpy` | `emacsDevPython` bundles debugpy+pytest |
| **Markdown** | `markdown-ts-mode` (`.md`), also `markdown-mode` | **`harper-ls --stdio`** (grammar/prose) | — | harper | — | `yath/eglot-ensure` on `markdown-mode` |
| **Java** | `java-mode`/`java-ts-mode` | **Eclipse JDT** via manually invoked `eglot-java-mode` (cache `~/.cache/eglot-java-eclipse-jdt-cache`); no Java Eglot hook is configured | Google Java style XML (remote URL) | Flymake | — | `eglot-java-mode` |
| **C# / .NET** | `csharp-mode`/`csharp-ts-mode` | eglot-ensure (server not pinned in elisp; relies on eglot default e.g. omnisharp/csharp-ls if present) | — | Flymake | — | hooked only |
| **GDScript** | `gdscript-ts-mode` when its packaged grammar is ready, derived from `gdscript-mode` | `eglot-ensure`; the obsolete configured `gdscript-eglot-version` variable is ignored by the pinned package, whose effective contact reads the project-version editor settings and otherwise uses Godot's built-in TCP LSP on port 6005 | — | — | — | Lem reproduces `.gd`, parser highlighting, tab-width-4 indentation, `project.godot` rooting, settings-port discovery, and the external TCP connection |
| **Terraform** | `terraform-mode` | eglot-ensure (terraform-ls if present) | — | Flymake | — | |
| **C / C++** | cc/c-ts modes | (clangd if present) | clang-format (apheleia) | Flycheck | `lldb`/`gdb` | `clang-tools`, `gcc`, `gdb`, `gnumake`, `pkg-config` on PATH |
| **Emacs Lisp / Lisp / Scheme / Racket / Clojure** | respective + `lispy`/`lispyville` | — | — | Flycheck (elisp `load-path inherit`) | — | `clojure-ts-mode`, `cider` declared in nix, **no explicit config** |
| **NASM** | `nasm-mode` (`.nasm`) | — | — | — | — | |
| **Nushell** | `nushell-ts-mode` (`.nu`) | — | — | — | — | |
| **Typst** | `typst-ts-mode` | declared in nix, **no explicit config** | — | — | — | Lem now recognizes `.typ` with the pinned default mode semantics and packaged grammar |
| **YAML / Meson / nginx / Just** | `yaml-mode`, `meson-mode`, `nginx-mode`, `just-mode` | declared in nix, **no explicit config (defaults)** | — | — | — | Lem now covers the packages' effective default file associations and highlighting |

**LSP server binaries required on PATH** (from `emacsRuntimeRequiredExecutables` + `emacsSharedDevTools`): `nixd`, `harper-ls` (pkg `harper`), `gopls`, `terraform-ls`, `rust-analyzer`, `pyright-langserver` (pkg `pyright`), plus `emacs-lsp-booster`. Tooling binaries: `go`, `goimports` (gotools), `dlv`/`dlv-dap` (delve), `cargo`, `rustc`, `rustfmt`, `cargo-clippy` (clippy), `lldb-dap` (lldb), `python`, `debugpy`, `debugpy-adapter`, `pytest`, `ruff`, `black`, `mypy`, `clang-tools`, `gcc`, `gdb`, `gnumake`, `pkg-config`. The declared daemon PATH does not include nixfmt-rfc-style, nixfmt, or alejandra, so the configured nixd formatter field is normally omitted.

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

Inside git-timemachine, the audited Evil collection keeps ordinary normal-state
`p`/`n` behavior and binds `C-k` to the previous (older) revision, `C-j` to the
next (newer) revision, `g t g` to numeric revision selection, `g t t` to fuzzy
revision selection, `g t y`/`g t Y` to short/full hash copying, `g t b` to
blame, and `q` to quit.

Lem now implements that complete configured map. Its blame command uses a
focused read-only child buffer rather than Magit's overlays and returns to the
unchanged history view with `q`.

`vc-handled-backends '(Git)` only. `magit`/`magit-todos`/`forge`/`git-gutter`/`git-timemachine` all loaded via `init-evil`.

---

## 6. UI

- **Theme**: startup explicitly disables any active themes and loads the built-in `modus-vivendi-tinted` theme. The optional business profile can replace it on configured hosts with `modus-operandi` (fallback `leuven`). `doom-themes` is still declared but is not the active startup theme; the 9 Doom hashes in `custom-safe-themes` only mark themes safe. **`doom-modeline` is referenced in `custom.el` (`doom-modeline-check-simple-format t`) but is not in the Nix package list and is never required** — likely vestigial. No modeline package is active; the default Emacs modeline is disabled during early init and then restored.
- **Line numbers**: `display-line-numbers-type 'relative`; `display-line-numbers-mode` on `prog-mode` only.
- **Current line**: neither `hl-line-mode` nor `global-hl-line-mode` is enabled. The host-gated business profile customizes the `hl-line` face but does not enable the mode.
- **pulsar**: deferred; `pulsar-delay 0.03`, `pulsar-iterations 4`, all auto-pulse functions disabled (`pulsar-pulse-functions nil`, region nil, on-window-change nil). Hooked into `consult-after-jump-hook` (recenter + reveal) and `imenu-after-jump-hook` (recenter). Effectively: recenter on jump, minimal flashing.
- **indent-bars**: `indent-bars-mode` on `prog-mode`; `indent-bars-treesit-support nil`.
- **rainbow-delimiters**: `rainbow-delimiters-mode` on every `prog-mode` buffer; the Emacs configuration does not impose a six-depth or Common-Lisp-only restriction.
- **Fonts**: JetBrainsMono Nerd Font family chain (`JetBrainsMono Nerd Font Mono` -> `JetBrainsMono Nerd Font` -> `JetBrainsMono`), default height `120`. Applied to `default` + `fixed-pitch` via hooks (`after-init`, `window-setup`, `after-make-frame-functions`). `font-use-system-font nil`.
- **Tabs / windows**: tab hints are enabled and close/new buttons are hidden, but `tab-bar-mode` itself is **not** enabled, so startup has no tab bar. Emacs retains the built-in `C-x t` prefix (`C-x t 2` creates a tab on demand). `winner-mode` is enabled after init with its default 200-entry per-frame history and `C-c Left` / `C-c Right` bindings for window-layout undo/redo. The Lem port now supplies those bindings with bounded frame-local split, buffer, selection, view, resize, and repeated-command behavior (`src/window-history.lisp`, `scripts/window-history-test.sh`). `split-width-threshold 170`, `split-height-threshold nil`. `switch-to-buffer-obey-display-actions t`. `org-roam` buffers show in a right side window (width 0.4).
- **dirvish**: `dirvish-override-dired-mode` on `after-init` (dirvish replaces dired everywhere). The pinned package retains its defaults: details hidden and a single six-cell `file-size` attribute at the right edge; directories show their direct child count in that field. Lem now reproduces that active baseline in ordinary full-buffer `directory-mode` and `*Find*` results through `src/dirvish.lisp`; Filer stays a separate side tree, and optional Dirvish preview/layout/integration layers remain gaps.
- **Custom view modes**:
  - `yath/centered-view-mode` (`SPC y c`): balanced window margins to center text at `yath/centered-view-width` (default 100).
  - `yath/business-document-mode` & `yath/business-visual-mode`: an entire alternate "office document" presentation profile (proportional fonts: Aptos/Segoe UI/etc.; modus-operandi theme; calm faces; simplified modeline; variable-pitch; centered docs). **Auto-enabled only on hosts in `yath/business-visual-hosts` (default `("workwin")`).** Applies to org/markdown/text/message/notmuch/elfeed/nov/eww/helpful/Info modes. Large amount of code; T2/T3 for porting.
- Other UI:
  - Emacs loads Which-Key after one idle second and enables `which-key-mode`. Independently, the untouched Which-Key defaults wait one second before an initial popup and, because the secondary delay is `nil`, wait the full delay again after a nested prefix; paging, page/column layout, separators, replacements, and echo-area presentation also remain at their defaults.
  - The Lem port globally composes live global, mode, and Vi-state maps with dispatcher-accurate shadowing. Ordinary initial and nested prefixes each wait a fresh second before showing 25%-height, width-bounded cyclic pages labeled with raw commands or `+prefix`; native transients retain Lem's 500ms opening delay and immediate nesting. After display, the pinned `C-h` map supplies cyclic `n/p`, nested-prefix `u`, docstring `d`, focused help `h`, abort `a`, and digit arguments; before display, `C-h` opens focused prefix help. The real TUI covers those physical routes, dynamic maps, fast dispatch, Escape, reload, timer races, and cyclic maps. Exact separators, default replacement rendering, echo-area styling, and the one-prefix undo-to-top-level popup remain presentation differences.
  - `helpful` supplies richer help buffers; `transient` uses `transient-default-level 7` and `q` to quit; compilation output receives ANSI color.

---

## 7. Org & notes

**Org root** = `$WORKDIR` (default `~/work`). `org-agenda-files` contains the
existing canonical directories, in order, from `$WORKDIR`, `$PUBLIC_ORG_DIR`
(default `~/public-org`), and `$PUBLIC_ORG_DIR/mcp`; Org expands each directory
to its top-level, non-hidden `.org` files. `initial-major-mode org-mode`.
`org-ellipsis " [...]"`.

### Capture (`org-capture-templates`)
- `i` Inbox -> `inbox.org` ("Inbox" headline), with CREATED prop.
- `t` TODO -> `todo.org` ("Inbox"), TODO state.
- `p` Public TODO -> `$PUBLIC_ORG_DIR/inbox.org`, top-level TODO with ID and CREATED props.
- `r` Reading -> `readlist.org` ("Inbox"), TODO state.

### org-roam
- `org-roam-directory` = `$WORKDIR/roam/` (truename). `:demand t`.
- Display template: `${file:30} :: ${title} ${tags:10}`.
- `org-roam-completion-everywhere t`. `org-roam-file-extensions '("org" "md")`. `org-roam-list-files-commands '(fd fdfind rg find)`.
- `org-roam-db-autosync-mode 1`. Excludes Syncthing `*.sync-conflict-*.org` files from indexing.
- **md-roam** (`nobiot/md-roam` at `1113a568`, custom build): `md-roam-mode 1`, `md-roam-file-extension "md"` — Markdown notes participate through front-matter `id:`/`title:`, flow `ROAM_ALIASES`, and Zettlr `#tag`/`@tag` tokens. The configured default insertion form is `[[Title]]`; the global mode advises Markdown's `C-c C-o` so an existing title/alias/ID target opens, a missing target starts roam capture, and a universal prefix uses another window.
- Roam capture templates: `n` note, `c` concept (`:concept:`), `p` project (`:project:`), `s` source (under `references/`, `:source:`), `m` markdown note (`.md` with YAML front-matter).
- **org-roam-dailies**: template `d` daily -> `%Y-%m-%d.org`. Bound via `SPC n r d t` / `SPC n r d d`.

### org-journal
- `:after org-roam`. `org-journal-dir` = `$WORKDIR/roam/journal/`. File format `%Y%m%d.org`, date format `%a, %Y-%m-%d`, date prefix `#+TITLE: `. `SPC n j j`.

The configured command path is exact in Lem: Normal or Visual `SPC n j j`
opens the compact-date Org buffer, creates or repairs its one daily title,
appends the blank-separated `* HH:MM ` prefix, and leaves a Normal cursor on
the trailing text-ready space. The profile binds no other org-journal command
(`src/notes.lisp`, `scripts/notes-test.sh`).

### Agenda
- `org-agenda` on `SPC m a`.
- Agenda sources are the top-level `.org` files in the three existing roots above; roam, journal, and other nested trees are not included by those directory entries.
- **org-super-agenda** (`org-super-agenda-mode 1`) — grouped agenda views (no custom groups defined in elisp; defaults).
- **evil-org-agenda** keys set.
- Evil-Org `Tab`, Shift-Return, and `g TAB` run `org-agenda-goto`, opening the
  exact source marker in another window; Return instead runs
  `org-agenda-switch-to` in the agenda window. `gj`/`gk` and `C-j`/`C-k` move
  between source-backed items rather than stopping on agenda decoration.
- Lem now covers the configured mutation paths exposed by that map: `dd`
  deletes a complete subtree with GNU Org's multi-line confirmation threshold,
  `ce` sets `Effort`, and `H`/`L` move the selected planning or ordinary-event
  timestamp. GNU `C-k`, `e`/`C-c C-x e`, Shift-Left/Shift-Right, and
  `C-c C-x Left`/`C-c C-x Right` remain available from the effective base map.
  Universal prefixes select hour and five-minute movement, and an immediately
  repeated opposite shift retains that unit as in pinned Org.
- Effective agenda `I/O` is state-dependent: Evil-Org motion state shadows the
  base map with stock single-current-clock commands; Emacs state reaches the
  custom delegated-clock commands. The latter use bulk-marked rows (or the
  current row for `I`), and unmarked `O` closes open clocks in all agenda files.
- Evil-Org `cg`/`cc`/`cr` and base `J`/`X`/`R` expose clock goto, cancel, and
  clock-report mode. Lem's report uses the currently displayed agenda span,
  clips closed clocks at both boundaries, and retains source-linked level-one
  and level-two rollups.
- Evil-Org `gD` exposes day, week, fortnight, month, year, and reset views.
  `[[`/`]]` move by the current span with counts, `.` returns to today, `gd`
  reads an Org-style date, and `gr`/`gR` refresh. Week and fortnight views
  align to Monday when selected through `gD`; `gd` retains the span but starts
  it on the requested date, matching pinned Org. Non-summary spans show every
  date, including empty dates, and retain the selected relative date across
  navigation. The interim bare-`g` Lem refresh is gone because it prevented
  the configured Evil `g` prefix; C-z Emacs state still exposes base-map `g`.
- Evil-Org motion-state `p` invokes pinned `org-agenda-date-prompt`; the GNU
  base-map alias is `>`. It edits the exact planning or ordinary timestamp at
  the row marker and leaves the source buffer modified. Unlike the other
  configured agenda mutations, `org-agenda-date-prompt` is absent from
  `yath/org-save-modified-agenda-source-buffers`' advice list, so not saving is
  an intentional property of the effective configuration rather than a gap.
- Evil-Org motion-state `u` invokes pinned `org-agenda-undo`. Agenda mutations
  wrapped by `org-with-remote-undo` register the changed live source buffers and
  undo their newest ordinary buffer group; they do not restore private source
  snapshots. The configured save advice does not include `org-agenda-undo`, so
  undoing an autosaved agenda edit leaves disk at the post-command state and the
  restored live source modified. Bulk dispatch records each processed row
  separately. Default archive undo restores only the source—the destination was
  already saved before source deletion—and explicit agenda redo clears the
  remote-undo list. The custom delegated Emacs-state clock functions bypass
  `org-with-remote-undo`; stock clock commands use it.
- Evil-Org `x` and base `B` expose the bulk-action dispatcher. Lem prompts once
  for TODO, tag addition/removal, schedule, deadline, default archive, or the
  configured same-file refile target, applies it to marked rows (or the current
  row when unmarked), and clears marks only after success. Archive-sibling,
  scatter, arbitrary Emacs Lisp functions, persistent marks, and cross-file
  refile remain explicit divergences.
- Evil-Org `sc/sr/se/st/s^/ss/S` and GNU Org's base `</=/_/\\/^/~/|`
  aliases expose category, regexp, Effort, tag, top-headline, temporary-limit,
  and clear operations. Category and top-headline filters toggle from the row
  at point; tag, regexp, and Effort filters support the pinned negative and
  double-prefix accumulation forms. Active filters stack by intersection,
  remain display-only across `gr`, and are visible in the agenda header. `ss`
  remains Org's generation-local limiter rather than being conflated with the
  filter stack. Lem derives inherited category and tags, local Effort, and the
  normalized top headline during the asynchronous scan. Arbitrary `/` matcher
  expressions and tag-group expansion remain outside this bounded surface.

### Visuals & babel
- **org-modern**: `org-modern-mode` on org buffers + `org-modern-agenda` on agenda finalize.
- **org-download** (deferred command loading in Emacs): `org-download-clipboard`/`org-download-yank`. Image dir = `$WORKDIR/media/`, `org-download-heading-lvl nil`. The Lem port exposes the same command names and destination policy in `src/org/download.lisp`.
- **Babel**: loaded langs = shell, sqlite, emacs-lisp, C, sql, python. `org-confirm-babel-evaluate` = custom `yath/org-confirm-babel-evaluate` (no prompt for `emacs-lisp`/`sqlite` inside trusted `$WORKDIR` notes). Python results = output; export = code. Custom `org-babel-execute:my/nix` (nix-build blocks). `ob-dsq` (datasette query), `ob-async` declared. LaTeX preview scale 2. Lem now covers the pinned DSQ file, named-table, cross-file reference, and named-source-result paths plus its active rendering headers; arbitrary Elisp-valued inputs and Babel variables/sessions remain outside the Common Lisp editor boundary.
- **Publishing**: `org-publish-project-alist` — `org-roam-notes` (org->html) + `static` (assets) from `~/work/roam/` & `~/work/` to `~/proj/web/org-publishing/`.

### Bibliography / citations (in `init.el`)
- Bib files (lookup order): `~/work/librarium/nodes.bib` (PostgreSQL-generated), then `~/work/librarium/zotero.bib`.
- **citar** (`:after org`): `citar-notes-paths` = `$WORKDIR/roam/references/`; opens html/pdf externally, others via find-file. `SPC y o` = `citar-open`.
- **ebib** (deferred): preloads readable bib files.
- **reftex** (deferred): `reftex-default-bibliography` from the bib files.
- **org-ref**, **org-contrib**: declared in nix, **no explicit config (defaults)**.
- **cdlatex** declared (deferred), no hooks set.

### Nodes graph sync (custom, host-gated)
- On save, actionable org headings (TODO/scheduled/deadline/reading tags) under `$WORKDIR` are (optionally) given stable Org IDs and synced via external `nodes-org-sync` CLI. Enabled only on hosts in `yath/org-nodes-sync-hosts` (default `("nova")`). Auto-ID is off by default. Lem now reproduces the separate host/path/conflict save-hook policy, exact external argv, optional/manual actionable ID promotion, asynchronous failure buffer, and reload lifecycle in `src/org/nodes-sync.lisp`; the owner-operated live `nova`/PostgreSQL graph remains outside hermetic validation.

---

## 8. Apps

| App | Package | Status / config | Entry / bindings |
|---|---|---|---|
| **Mail** | `notmuch` | deferred. SMTP via local Proton Bridge: `smtpmail` to `127.0.0.1:1025` STARTTLS. `mail-user-agent notmuch-user-agent`. Newest-first search. Custom PDF attachment preview (`yath/notmuch-save-or-view-part`, opens PDFs in pdf-view, else saves). `notmuch-outlook.el` loaded if present (WSL). | `M-x notmuch` / `notmuch-search` / `notmuch-hello`; `yath/fetchmail` = `mbsync -a && notmuch new`. Pipeline: Proton Bridge -> `mbsync` (isync) -> notmuch. |
| **Feeds** | `elfeed` + `elfeed-protocol` | deferred. Fever protocol against `http://rss.wg:8070/fever/` (Miniflux), authinfo. `elfeed-use-curl t`, default filter `@2-years-ago`. Title widths tuned. Custom `elfeed-show-archive` (`A` key) -> archive.is in eww. | `M-x elfeed`. Pipeline: Miniflux -> elfeed-protocol (fever) -> elfeed. |
| **PDF** | `pdf-tools` | deferred (`pdf-tools-install`, `pdf-view-mode`) | used by notmuch attachment preview; Lem approximates the configured reading path with page-at-a-time text and an external-viewer escape hatch |
| **EPUB** | `nov` | declared in nix; **no use-package config** (just in `yath/business-document-modes`). `nov-mode` for `.epub` is active through the package's default auto-mode association. | Lem approximates the default open/navigation path with bounded Markdown conversion and chapter navigation |
| **Terminal** | `vterm` | deferred (`commands (vterm)`). Used as `claude-code-terminal-backend`. | `M-x vterm` |
| **DevDocs** | `devdocs` | deferred | `SPC h d` = `devdocs-lookup`; `devdocs-install` |
| **PostgreSQL UI** | `pgmacs` (+ `pg`) | declared in nix (custom build from `emarsden/pgmacs`); **no use-package config / no binding** | `M-x pgmacs` available; no elisp wiring |

---

## 9. AI integrations

Core: **gptel** (deferred), heavily customized in `init-ai.el` (~1400 lines).

### gptel core config
- No-file startup runs `vile/scratch-gptel-mode`: `*scratch*` is an Org buffer
  with `gptel-mode` enabled. The mode binds `C-c RET` to `gptel-send`, inserts
  streamed replies at the send marker, and adds the next Org prompt prefix
  after a completed response.
- `gptel-default-mode 'org-mode`; prompt prefixes per mode (`# ` markdown/text, `* ` org).
- `gptel-use-tools nil` (default), `gptel-expert-commands t`, system message "Very short answers. Be helpful." API key from `OPENAI_API_KEY`. Expert commands expose `r` in the full menu for an active-region rewrite (or iteration at a pending rewrite); gptel stages the response and offers accept, reject, iterate, merge-conflict, diff, and ediff actions. At an existing response the expert menu also marks the response with `SPC`, regenerates with `M-RET`, rotates previous/next variants with `P`/`N`, and compares the previous variant with `E`.
- Loads local `gptel-stability.el` (`yath/gptel-stability-mode 1`) — hardening shims (killed-buffer callbacks, FSM/UI live-buffer assumptions, parallel prompt-transform races).
- **Default backend = OpenRouter** (`gptel-make-openai "OpenRouter"`, `openrouter.ai/api/v1/chat/completions`, key `OPENROUTER_API_KEY`), default model `openrouter/auto`. Async model discovery (`yath/openrouter-refresh-models`) with on-disk cache (`openrouter-models-cache.el`); falls back to `openrouter/auto` / `openrouter/free`.
- Other backends if available: GitHub Copilot (`gptel-make-gh-copilot`), Perplexity (`PERPLEXITY_API_KEY`).
- Org user prompts are rewritten to markdown before sending (`yath/gptel-org-prompt-transform`, with src/result block fencing).
- The Emacs configuration tree declares `vile-config/add-elisp-to-gptel-context`
  in `.dir-locals.el`; it adds `early-init.el`, `init.el`, and the `lisp/`
  directory as buffer-local gptel request context.
- Visual polish: streaming fake-cursor overlay + role badges (User/Assistant) in header-line and inline (`yath/gptel-role-visuals-*`), toggle `yath/gptel-role-visuals-toggle`. Request tracing toggle `yath/gptel-debug-requests-toggle` (+ `-open`).
- **Presets** (`gptel-make-preset`): `quick-lookup` (default at startup, short answers, OpenRouter/auto, temp 0.2, max 800, no tools), `codex-agentic`, `grok-build`, `grok-build-oauth-agentic`. Preset model-compatibility advice (`yath/gptel--apply-preset-compatibility`).

### gptel preset/handoff menu (`yath/gptel-preset-menu` transient, `SPC g l`)
- Presets: load / save.
- Handoff to external chat apps: **Claude Desktop** (`claude://...` or web `claude.ai/new?q=`), **ChatGPT** (normal/temporary/search/research/model URL hints), prefilling current buffer/region as context (truncated to ~13000 chars). Browser preference: brave -> browse-url.
- `yath/llm-capture`: capture a prompt into today's dailies org topic and send via gptel. Lem now exposes the same M-x command, writes the tagged topic/ID/preset metadata, and streams one response inline without turning the whole daily into a conversation buffer.

### Local gptel backend plumbing files (load-path = user-emacs-directory)
- **gptel-claude-code.el** — Claude Code CLI (`claude`) as a gptel backend. Advises `gptel--handle-wait` to spawn an async subprocess (NDJSON streaming) instead of curl; CLI handles all tool execution (file edits, shell) and `--resume` for session continuity; org heading properties store session/message metadata for conversation forking. The active registration resolves the surrounding Git root as cwd, pre-approves Bash/Read/Edit/Write/Glob/Grep/WebFetch/WebSearch/Agent, and auto-selects project `.mcp.json` before `~/.claude/.mcp.json`. Thinking, tool, and result events use semantic `cc_*` Org blocks; thinking/results auto-collapse, tools collapse above eight lines, and `C-c C-t` toggles every result. Registered via `gptel-make-claude-code "Claude Code" :executable "claude"`.
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
- **calc**: deferred built-in `M-x calc`; starts GNU Calc's RPN stack with
  precision 12 and degree angles. Evil-Collection puts Calc in Normal state
  and supplies its digit/algebraic-entry, arithmetic, stack, undo, copy/yank,
  angle, precision, and quit keys; the local override makes Escape abort
  recursive digit entry.
- **so-long**: `global-so-long-mode` on `after-init`, with its uncustomized
  defaults. A programming, CSS, SGML/XML, or Fundamental-mode file whose line
  exceeds 10,000 bytes is replaced by read-only, wrapped `so-long-mode`;
  `C-c C-c` restores the original major mode. The threshold is strictly
  greater than 10,000 bytes, not characters.
- **editorconfig**: `editorconfig-mode` on `prog-mode`.
- **which-key**: enabled globally after a one-second deferred package load; its independent one-second popup delay and the paging, column, separator, replacement, and echo-area settings retain their defaults.
- **Startup**: early-init disables tool/scroll/menu/blink-cursor bars, silences startup messages, sets `gc-cons-threshold` huge + `file-name-handler-alist nil` for fast init (restored on `emacs-startup-hook`). Native-comp warnings silenced. `inhibit-startup-message`, empty scratch message; the resulting Org `*scratch*` enables `gptel-mode`.
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
- **LSP via Eglot** per language (nixd, rust-analyzer, gopls, terraform-ls,
  manually selected pyright, harper-ls, eclipse-jdt, and an unpinned Eglot
  default for C#) — Lem has `lem-lsp-mode`; replicate server selection and the
  nixd custom workspace config plus Go/Rust/Python/Nix/C# coverage.
- **apheleia format-on-save** (`SPC b f`) and **flycheck/flymake** diagnostics policy.
- **tree-sitter** highlighting (`treesit-auto`) — Lem-yath automatically applies its packaged grammar/query bundle to existing modes and now supplies the formerly missing GDScript, Just, Meson, nginx, Nushell, and Typst modes.
- **Git**: magit (`SPC g g/G`) + git-gutter + git-timemachine; smart jj/git dispatch; the focused Lem jj porcelain now covers row-aware shared multiline describe/working-copy-commit, adjacent and parent/child/working-copy navigation, prompt-based and direct child/before/after creation, selected-row absorb with prompted from/into revsets and fileset scoping, selected or arbitrary squash endpoints with a native file/hunk/changed-line selector, selected-row rebase, Majutsu-style source/placement revert, revision/fileset restore with a native file/hunk/changed-line `- i` selector, duplicate, local bookmarks, edit, undo/redo, confirmed abandon, and diff workflows plus an `S` split view with file, hunk, and changed-line patch selection. Majutsu's shared multi-selection sessions, repeated merge-placement values, configurable duplicate descriptions, remote/multi-bookmark operations, binary/conflict and word-level patch selection, partial added/deleted-file line selection, and wider conflict/workspace/operation-log surfaces remain approximate.
- **dape** debugging (Python/Go/Rust/C) — likely partial/gap in Lem.
- **Org capture + org-roam + dailies + journal** (`SPC o`, `SPC n r *`, `SPC n j j`) — Lem now has bounded native Org editing, a shared named/partial/relative date reader with a terminal calendar, in-buffer scheduling/deadline insertion, suffix-preserving replacement, one-prefix removal, and two-prefix warning/delay editing on the stock chords, active/inactive ordinary timestamp insertion/replacement, successive-command timestamp ranges, and date shifting, metadata-aware Org/Markdown roam-node selection, the configured five roam capture templates with finalize/abort and deferred insertion, an editable one-key implementation of all four configured general capture templates with initial selection and local source context, a persistent right-side backlink/reflink view with exact source visits, save-driven visible-panel refresh, and manual refresh for out-of-band changes, exact configured journal entry creation, daily, and agenda implementations. Org-roam's persistent database, always-on incremental autosync and arbitrary third-party reference schemes, plus arbitrary Org capture template language/stored-link providers remain gaps; broader org-journal commands are unconfigured package surface rather than parity requirements.
- **vundo, pulsar (recenter-on-jump), indent-bars, dirvish** UI niceties.
- **AI: gptel + claude-code/monet + mcp** entry commands (`SPC g j/l/L`, `C-c c`, `C-c i`, conversation-local `C-c RET`) — Lem starts its Org scratch in an LLM conversation mode, reconstructs separate user/assistant turns, renders bounded Org user prompts as Markdown, and streams tagged replies at the tracked send position before adding the next `* ` prompt. Terminal-native User/Assistant gutters, active-role modeline status, assistant tint, a moving synthetic stream cursor, and a presentation toggle reproduce the configured role visuals without changing transcript text. The configured opt-in request-tracing toggle and read-only `*gptel-requests*` viewer cover request/backend start, chunk metadata, and complete/abort/kill lifecycle states with bounded prompt previews and a stricter secret boundary. The full menu now provides gptel-compatible `-r`, `-b`, `-f`, and `-d` text-context actions, a clean read-only inspector, and `-e` for the exact audited Emacs-config helper; attached context is buffer-local, bounded, read live at dispatch where applicable, and excluded from the visible transcript and trace. Its conditional `r` action also stages a selected-region rewrite in a focused terminal preview with accept, reject, iterate, unified diff, and merge-conflict actions; source stays unchanged until acceptance, which is one undo step. At an Assistant response, the menu marks the exact span, regenerates from the typed transcript with captured request settings, rotates bounded previous/next variants as one property-preserving undo group, and opens a terminal unified comparison. Native resumable Claude/Codex/Grok CLI histories deliberately refuse regeneration rather than rewind provider-owned state unsafely. Claude Code requests now match the configured default Git-root cwd, nine-tool allowlist, project-then-home MCP config discovery, and inherited Org `CC_CWD`/`CC_ALLOWED_TOOLS` overrides; responses retain their provider session/message boundary, conversation-local `C-c C-f` creates a project-scoped registered JSONL fork at the nearest preceding Assistant response, and `C-c C-b` selects an indexed project session. Sending before an existing same-session continuation automatically performs the equivalent fork in Lem's linear transcript and continuing that branch does not refork. The exact `M-x yath/llm-capture` also creates one tagged, identified topic in today's daily and streams its response inline. It also has OpenRouter and ChatGPT Codex with private cached asynchronous model discovery and completed model selection, Perplexity-with-citations, GitHub Copilot Chat, ChatGPT Codex Responses, and Grok OAuth-proxy streaming; explicit Copilot device and Codex PKCE authorization plus token renewal; resumable native CLI backend ports; the configured Codex/Grok agentic presets; private named presets; bounded local agent tools; configured fetch/read-only-GitHub stdio MCP clients; Claude/ChatGPT web handoff; and a tested project-aware interactive Claude Code buffer. Emacs's inline rewrite overlay, graphical ediff and multi-region rewrite controls, media controls, native-CLI response regeneration, Claude transient/vterm, arbitrary third-party MCP registry/UI, and advanced MCP client capabilities remain gaps.

Claude activity additionally uses the same semantic `cc_*` Org blocks,
automatic thinking/result and long-tool collapse, and conversation-local
`C-c C-t` result toggling without changing transcript bytes.

### Tier 3 — apps / bespoke integrations with likely no Lem equivalent (document as gaps)
- **notmuch mail** (+ Proton Bridge/mbsync pipeline, PDF preview) — a CLI-backed Lem reader covers search/read/refresh and owner-private PDF extraction into the shared page-text reader; composition, sending, non-PDF attachment actions, and Outlook integration remain gaps.
- **elfeed RSS** (Miniflux/fever) — the Fever listing/reading/archive path is ported; full Elfeed filtering and local-database behavior remain gaps.
- **pdf-tools, nov (EPUB)** — bounded text-first Lem readers cover ordinary opening, PDF page and EPUB chapter navigation, refresh, and external fallback. Pixel PDF semantics and EPUB HTML/CSS/images remain terminal-specific divergences.
- **citar/ebib/reftex/org-ref bibliography**, **org publishing**, **org-modern/super-agenda** — Citar-like lookup, bounded publishing and grouped agenda workflows, and a source-preserving terminal org-modern projection are ported. The wider bibliography, exact graphical org-modern/agenda styling, and arbitrary agenda interfaces remain gaps.
- **salta.el** (Supabase/PostgREST property/contractor/payments client; tabulated-list UIs; `C-c s` prefix; notmuch payment-email bridge) — the six primary REST/list/detail workflows are ported and covered against a hermetic fake API; `C-c s e` also tracks the current rendered Notmuch message and opens its URL-encoded payment-email page through a direct desktop argv. The owner-operated live API and web application remain outside hermetic validation.
- **business-visual / business-document modes** (office presentation profile, host-gated to `workwin`) — ported as a reversible ncurses analogue with a light semantic palette, compact modeline, shape-only cursors, disabled jump pulse, and 88-column centered/wrapped Org, Markdown/EPUB, text, Notmuch-message, feed-entry, and DevDocs buffers. `M-x business-visual-mode` permits an explicit trial on other hosts. Proportional/fixed-pitch font mixing, fractional line spacing, hollow cursors, fringes, GUI chrome, and unavailable message/EWW/Helpful/Info modes remain terminal divergences.
- **nodes-org-sync** (PostgreSQL graph sync of Org headings, host-gated to `nova`) is wired through Lem's native Org save lifecycle while retaining the external projector and database; the psql-backed viewer separately covers the pgmacs entry workflow.
- The **gptel backends** include bounded Claude/Codex/Grok process adapters with native event rendering and resumable per-backend sessions plus credential-safe Perplexity, GitHub Copilot Chat, ChatGPT Codex Responses, and Grok OAuth HTTP adapters. The latter two retain per-buffer history and execute the configured project tools. Lem now has tracked source-position Org replies, typed user/assistant reconstruction, bounded Org-to-Markdown user transforms, independent buffer-local request/session/context ownership, killed-buffer request/process cleanup, private cached asynchronous OpenRouter/Codex model discovery, one-shot echo-area/other-buffer/LLM-session/kill-ring response destinations, a credential-free normalized JSON dry run, staged selected-region rewriting, bounded response regeneration/history navigation for transcript-backed providers, and explicit or automatic Claude project-session forking plus browsing at captured response boundaries. Native-CLI response regeneration, parallel replies in one buffer, media context, graphical ediff/multi-region rewrite controls, and richer Copilot request families remain gaps.

### salta.el commands (reference for any port)
- `salta-find-property` (fuzzy property search -> tabulated list), `salta-property-detail`, `salta-property-reckoner` (revenue/cost/profit + totals/margin), `salta-contractor-rates`, `salta-contractor-financials`, `salta-payments`, plus list/detail navigation (`RET` open, `w` copy, `r` reckoner, `g` refresh; detail: `c` claims, `p` payments) and `salta-open-payment-email-from-notmuch`. Talks to a Supabase PostgREST API (`/rest/v1/...`, RPCs `fuzzy_search_properties`, `get_reckoner_data`); creds via `salta-base-url`/`salta-api-key`/env/`~/.config/salta/credentials.json`.

---

## Packages declared in Nix but with NO explicit elisp config (defaults / vestigial)

`embark-consult` (effective through Embark's automatic Consult hook),
`multiple-cursors` (internal overlay use only), `nov`,
`pgmacs`/`pg`, `eldoc-box`, `org-ref`, `org-contrib`, `ob-async`, `yaml-mode`,
`meson-mode`, `nginx-mode`, `just-mode`, `cider`, `clojure-ts-mode`, `go-mode`
(hooked but no use-package), `typst-ts-mode`, `engrave-faces`,
`tree-sitter-langs`/`tsc`, `cdlatex` (declared, no hook). `doom-modeline` is
referenced in `custom.el` but is **not** in the package list and never loaded
(dead reference).

Assessment outcome: the language packages' active default associations and
tooling are routed to the existing language/IDE rows; the declared-only Org
packages add no hooks, bindings, or activation beyond separately tracked
Babel, citation, publishing, and visual behavior; and `nov`/`pgmacs` are
tracked by APP-004/APP-007 respectively. Package availability alone adds no
further port target, so the declared-package ledger has no unassessed rows.
