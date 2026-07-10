# Lem Editor — API / Capability Reference

Source-verified survey of **upstream Lem**, not a status report for lem-yath.
Every symbol and path below was refreshed against the flake-pinned Lem revision
`0ddb9ea78248db67abcd806377415e66bb326d45`; paths are relative to that source.
Use `docs/parity-ledger.tsv` for the configured port's current disposition and
verification state.

**CRITICAL PRE-READ — what is baked into the nix `lem-ncurses` image.**
The nix build (`flake.nix:348-351`) builds ASDF systems `"lem-ncurses" "tree-sitter-cl"
"lem-tree-sitter"`. `lem-ncurses` (`frontends/ncurses/lem-ncurses.asd`) depends on
`lem/core` **and** `lem/extensions`. `lem/extensions` (`lem.asd:235-306`) pulls in
**essentially every extension**: vi-mode, lsp-mode, lisp-mode, all language modes,
legit, terminal, paredit, copilot, claude-code, mcp-server, transient, dashboard,
tree-sitter, git-gutter, base16-themes, etc. So **the user config can simply call into
any of those packages without `ql:quickload`** — they are already in the image.

The nix build also injects `(pushnew :nix-build *features*)` (`flake.nix:331`), which
**removes `lem-extension-manager` from `lem/core`** (`lem.asd:39-41`). Consequently the
runtime cannot easily `ql:quickload` *new* Quicklisp dependencies that were not built
into the image. Anything not in the `lem/extensions` dependency tree (e.g. the
`contrib/` systems, see §10) must be made available to ASDF at build/image time, not
fetched at runtime.

---

## 1. Init & startup

### Config directory / `lem-home` — `src/config.lisp:3-8`
```lisp
(defun lem-home ()
  (let ((xdg-lem (uiop:xdg-config-home "lem/"))           ; ~/.config/lem/
        (dot-lem (merge-pathnames ".lem/" (user-homedir-pathname))))
    (or (uiop:getenv "LEM_HOME")
        (and (probe-file dot-lem) dot-lem)
        xdg-lem)))
```
Precedence: `$LEM_HOME` → `~/.lem/` (if it exists) → `~/.config/lem/`.

### Init file load order — `src/lem.lisp:36-48` (`load-init-file`)
1. `(lem-home)/init.lisp`  — the **primary user init file**.
2. else `~/.lemrc`.
3. additionally, if cwd ≠ home, `./.lemrc` in the current directory.

The init file is loaded with `*package*` bound to `:lem-user` (`src/lem.lisp:44`). Only
the **first** of `init.lisp`/`~/.lemrc` that exists is loaded (`or`). There is **no
`config.el`-style separate early/late split**; one init file.

`config.lisp` in `(lem-home)` is a **different** thing — a machine-managed plist (theme,
etc.), read/written by `(lem:config key)` / `(setf (lem:config key) v)`
(`src/config.lisp:25-40`). Not for hand-editing logic.

### Splitting config across files
- Plain `(load "...")` from `init.lisp` works (`*package*` is `:lem-user`).
- **Site-init / `~/.lem/inits/*.lisp` + ASDF system** mechanism exists:
  `src/site-init.lisp`. `raw-init-files` globs `(lem-home)/inits/*.lisp`
  (`site-init.lisp:19-24`); `load-site-init` builds an on-disk ASDF system named
  `lem-site-init` and loads it. Commands `site-init-add-dependency` /
  `site-init-remove-dependency` (`site-init.lisp:72-97`) edit that system's
  `:depends-on`. This is the intended way to declare extra `lem-*` systems to load.
- `build-init.lisp` (`src/lem.lisp:50-58`, `init-at-build-time`): loaded at **image
  build time**, not at startup. Relevant if you rebuild the image.

### Build-time vs runtime hooks
`*before-init-hook*`, `*after-init-hook*` (`src/lem.lisp:4-5`). `init` runs
`*before-init-hook*`, loads init file (unless `-q`), runs `*after-init-hook*`, then
applies CLI args (`src/lem.lisp:60-65`). Theme is loaded from a hook on
`*after-init-hook*` (`src/color-theme.lisp:145`).

### CLI flags — `src/command-line-arguments.lisp:3-82`
```
-q, --without-init-file   skip init.lisp / .lemrc
--debug                   enable debugger
--log-filename FILENAME   log file
-i, --interface INTERFACE  sdl2 | ncurses  (keyword-ized)
-v, --version             print version and exit
-h, --help                help and exit
-e, --eval FORM           a CL form (quoted) eval'd on startup
```
Bare args are treated as filenames to open (`apply-args`, lines 84-99).
Entry points: `lem:main` (`src/lem.lisp:135`), `lem:lem` (line 132). SBCL also hooks
`ed` (`*ed-functions*`, lines 138-144).

### `--eval` / non-interactive testing — caveat
`--eval`/`-e` evaluates a form **inside a started editor** (`apply-args` →
`(eval form)`, `command-line-arguments.lisp:94-100`). It is **not** a headless batch
mode — the frontend/event loop still starts. There is **no `--batch`/`--script`/`--kill`
flag** in the parser. For true headless/automation use the **server frontend**
(`lem-server`, JSON-RPC over WebSocket; `lem.asd:315`, `docs/ARCHITECTURE.md:150`) or the
`lem-fake-interface` system used by the test suites (`extensions/vi-mode/lem-vi-mode.asd`,
the `/tests` systems run via Rove). To exit programmatically: `lem:exit-lem` /
`(lem:exit-editor)`.

---

## 2. Config primitives

### `define-command` — `src/defcommand.lisp:113-190`
```lisp
(define-command name-and-options (params) (&rest arg-descriptors) &body body)
```
Arg descriptors (`parse-arg-descriptors`, `defcommand.lisp:10-86`):
`:universal` (default 1), `:universal-nil` (default nil), `(:string "Prompt: ")`,
`(:number "…")`, `(:buffer)`, `(:other-buffer)`, `(:file)`, `(:new-file)`, `(:region)`
(passes start+end), `(:splice form)`. Options on the name:
`(name (:name "cmd-name") (:mode mode) (:class …) (:advice-classes …))`.

### Keymaps — `src/keymap.lisp`, `src/fundamental-mode.lisp:6`
- Global map: `lem:*global-keymap*` (`fundamental-mode.lisp:6`, a `keymap*`).
- `(make-keymap &key undef-hook prefixes children description base)` —
  `keymap.lisp:269`. `:base` = inherit from another keymap (used by mode keymaps).
- `(define-key keymap "C-x C-f" 'command)` — `keymap.lisp:283`. Key notation prefixes:
  `C-` `M-` `S-`/`Shift-` `Super-`/`s-` `H-`/Hyper (`keymap.lisp:389-418`). Named keys:
  `Space Tab Return Backspace Escape Up Down …`.
- `(define-keys keymap ("k1" 'c1) ("k2" 'c2))` — `keymap.lisp:304`.
- `(undefine-key keymap "C-k")` / `undefine-keys` — `keymap.lisp:353,370`.
- `(define-named-key name)` macro — `src/key.lisp:10` (defines a symbolic key like
  `"Leader"`).
- `lookup-keybind`, `find-keybind`, `collect-command-keybindings` — keymap.lisp.

Lem uses a **tree of keymaps with prefixes**, not Emacs's flat sparse keymaps; the new
design adds `prefix`/`transient` objects (`keymap.lisp:3-75`) supporting which-key-style
menus. Multi-key sequences ("C-x C-f") still work like Emacs.

### Modes — `src/mode.lisp`
- `(define-major-mode name parent (:name … :keymap *km* :syntax-table *st*
   :mode-hook *hook* :formatter fn) &body)` — `mode.lisp:138`. Defines the mode, a
  command to switch to it, its keymap (auto `defvar`'d, `:base` from parent), and a
  `*…-hook*` var.
- `(define-minor-mode name (:name … :keymap *km* :global nil :enable-hook 'fn
   :disable-hook 'fn :hide-from-modeline nil) &body)` — `mode.lisp:196`. The generated
  command toggles/enables/disables.
- `(define-global-mode name (parent) (:name … :keymap *km* :enable-hook :disable-hook))`
  — `mode.lisp:248`. vi-mode is a global mode (§3).
- `(define-file-type ("ext1" "ext2") mode)` associates extensions (see
  `docs/extension-development.md`; defined in core file handling).

### Hooks — `src/common/hooks.lisp`
```lisp
(add-hook place callback &optional (weight 0))   ; higher weight runs first
(remove-hook place callback)
(run-hooks hooks &rest args)
```
A "place" is either a plain `defvar` hook list **or** an editor-variable hook fetched
with `(variable-value 'hook-name :buffer buf)` / `:global`.

**Important global / editor hook variables (verified):**
| Hook | Where | File:line |
|---|---|---|
| `*before-init-hook*` / `*after-init-hook*` | global defvar | `src/lem.lisp:4-5` |
| `*find-file-hook*` | global defvar | `src/buffer/file.lisp:3` |
| `before-save-hook` / `after-save-hook` | editor-variable (per-buffer/global) | `src/buffer/file.lisp:5-6` |
| `kill-buffer-hook` | editor-variable | `src/buffer-ext.lisp:3` |
| `before-change-functions` / `after-change-functions` | editor-variable (buffer) | used throughout (e.g. lsp-mode, grep) |
| `*switch-to-buffer-hook*` / `*switch-to-window-hook*` | global | `src/window/window.lisp:17-18` |
| `*pre-command-hook*` / `*post-command-hook*` | global | `src/command.lisp:3,5` |
| `*exit-editor-hook*` / `*editor-abort-hook*` | global | `src/interp.lisp:3-4` |
| `*after-load-theme-hook*` | global | `src/color-theme.lisp:3` |
| `*prompt-activate-hook*` … | global | `src/prompt.lisp:5-7` |
| `*buffer-mark-activate/deactivate-hook*` | global | `src/buffer/internal/buffer.lisp:96-98` |
| `self-insert-before/after-hook` | editor-variable | `src/commands/edit.lisp:72-73` |

There is **no `find-file-hook` as an editor-variable** — it is the global defvar
`*find-file-hook*`. Add hooks with `(add-hook lem:*find-file-hook* 'fn)`.

### Customization variables — STYLEGUIDE + `src/common/var.lisp`
Two systems:
1. Plain `defvar`/`defparameter` user-facing knobs (no `-p` suffix per STYLEGUIDE).
   Set them directly: `(setf lem/grep:*grep-command* "rg")`.
2. **Editor variables** (`define-editor-variable`, `src/common/var.lisp:32`) which have
   global + per-buffer scope: get/set via
   `(variable-value 'name [scope] [where])` / `(setf (variable-value 'name :global) v)`
   (lines 70-95). Scopes: `:default :global :buffer`.
3. Persistent plist config: `(setf (lem:config :key) v)` (`src/config.lisp`).

### Run code after startup
Best: `(add-hook lem:*after-init-hook* (lambda () …))`. For deferred/async, use a timer
(§11) or `(lem:start-timer (lem:make-idle-timer #'fn) …)`.

---

## 3. vi-mode  (`extensions/vi-mode/`, package `lem-vi-mode`)

### Enable — `extensions/vi-mode/README.md`, `core.lisp:80`
```lisp
(lem-vi-mode:vi-mode)     ; vi-mode is a global-mode; this command activates it
```
`vi-mode` is defined `(define-global-mode vi-mode (emacs-mode) …)` (`core.lisp:80-84`)
with `*enable-hook*` / `*disable-hook*` (`core.lisp:65-66`).

### State keymaps — `extensions/vi-mode/states.lisp:22-117`
Exported keymaps (all `vi-keymap`, a `keymap*` subclass):
`lem-vi-mode:*normal-keymap*`, `*insert-keymap*`, `*operator-keymap*`,
`*motion-keymap*` (child of normal), `*visual-keymap*` (from `visual.lisp`),
`*inner-text-objects-keymap*`, `*outer-text-objects-keymap*`,
`*replace-char-state-keymap*`, `*inactive-keymap*`. `*command-keymap*` is a **deprecated
alias** that warns and points to `*normal-keymap*` (`states.lisp:55-58`).

States (`define-state`, `core.lisp:119`): `normal`, `insert`, `replace-state`,
`operator`, `replace-char-state`, `vi-modeline` (the `:` COMMAND state), `visual`.
Each carries cursor type + modeline color.

### Defining bindings per state — README + `states.lisp`
```lisp
(define-key lem-vi-mode:*normal-keymap* "q" 'quit-active-window)
(define-key lem-vi-mode:*insert-keymap* "(" 'paredit-insert-paren)
(define-key lem-vi-mode:*visual-keymap* "u" 'downcase-region)
```

### Leader key — `extensions/vi-mode/leader.lisp` (THIS IS THE SPC-LEADER MECHANISM)
- `(define-named-key "Leader")` and an editor-variable `leader-key` **defaulting to
  `"\\"`** (`leader.lisp:9-11`).
- A `keymap-find` method on `vi-keymap` rewrites a press of the leader key into the
  symbolic `Leader` key (`leader.lisp:22-30`). So to bind leader chords:
  ```lisp
  (setf (variable-value 'lem-vi-mode/leader:leader-key) "Space")  ; make SPC the leader
  (define-key lem-vi-mode:*normal-keymap* "Leader f" 'project-find-file)
  (define-key lem-vi-mode:*normal-keymap* "Leader g" 'legit-status)
  ```
  This is the idiomatic Doom/Spacemacs `SPC`-leader emulation.
- **Caveat:** in normal mode `Space` is otherwise bound to `vi-forward-char` via
  `*motion-keymap*` (`binds.lisp:26`). Setting `leader-key` to `"Space"` makes the
  leader rewrite take precedence in `vi-keymap` so chord lookups win; a bare `Space`
  with no following chord still falls through. (Verify behavior interactively when
  porting; the cleanest approach is leaving leader as `\` or `,` if SPC feels off, or
  rebind/undefine `Space` in `*motion-keymap*`.)

### Ex commands — `extensions/vi-mode/ex-core.lisp:87` (`defmacro define-ex-command`)
```lisp
(lem-vi-mode:define-ex-command "regex" (range argument) &body)
```
Many built in (`ex-command.lisp`): `:e[dit] :w[rite] :wa :wq :wq! :x :q :q! :qa :qa!
:bn :bp :b[uffer] :bd :sp[lit] :vs[plit] :s[ubstitute] :set :read :cd :pwd :noh[lsearch]
:!cmd :ls/:buffers :jumps :close :only :new :vnew`. User-defined example in
`rc-example.lisp:15`.

### Text objects — `extensions/vi-mode/text-objects.lisp` (`lem-vi-mode/text-objects`)
Provided: `word-object broad-word-object paren-object bracket-object curly-object
angle-bracket-object paragraph-object double-quoted-object single-quoted-object
back-quoted-object tag-object`. `iw/aw/i(/a(/i"/a"/it/at` etc. all work.
Define your own with `lem-vi-mode:define-text-object-command`,
`define-motion`, `define-operator` (exported from `lem-vi-mode`, `vi-mode.lisp:39-57`).
Option `vi-operator-surrounding-blanks` (editor-variable, README §User Settings).

### Surround / sneak / easymotion
**No vim-surround, no sneak, no easymotion equivalents ship.** There is a `tag-object`
and quote/paren text objects but no `ys`/`cs`/`ds` surround commands and no `s`/`S`
2-char sneak motion. There IS a **jumplist** (`jumplist.lisp`, `:jumps` ex command,
`C-o`/`C-i`-style) and registers (`registers.lisp`).

### Options — `extensions/vi-mode/options.lisp`, README §Options
Vim-like global options via `(setf (lem-vi-mode:option-value "name") val)` or `:set`.
Shipped options: `autochdir`/`acd`, `number`/`nu`. (Small set — far fewer than Vim.)

### Repeat (`.`) — supported via `*enable-repeat-recording*`, `*last-repeat-keys*`
(`core.lisp:52,68`, `vi-mode.lisp` post-command hooks).

---

## 4. Completion & prompt

### Prompt API — `src/prompt.lisp`
`prompt-for-string` (line 71, supports `:completion-function :test-function
:history-symbol :initial-value`), `prompt-for-integer` (92), `prompt-for-buffer` (109),
`prompt-for-file` (125), `prompt-for-directory` (129), `prompt-for-character` (62),
`prompt-for-y-or-n-p` (65), `prompt-for-command` (158), `prompt-for-library` (169),
`prompt-for-encodings` (192). Prompt UI is the floating prompt-window
(`src/ext/prompt-window.lisp`).

### Completion behavior — `src/completion.lisp`, `src/ext/completion-mode.lisp`
`completion` (substring), `completion-hyphen` (hyphen-aware),
`completion-subsequence`, `fuzzy-completion` (subsequence plus length ranking), and
`completion-strings`. `*automatic-tab-completion*` (`prompt.lisp:13`) controls
whether the list opens instantly or on TAB. Core has fuzzy primitives, but no
Orderless component dispatch or persistent Prescient ranking; lem-yath adds the
prompt behavior described in `src/completion.lisp`.

Lem-yath carries `patches/lem-completion-lifecycle.patch` against the pinned Lem
revision. It separates display, filter, and insertion text, adds a final-accept
callback, and rejects stale asynchronous generations before they can update the
popup. Automatic contexts also keep a cancellable spinner, remember their origin
buffer, display rather than insert synchronous singletons, and carry their own
row-limit and cycling policy. Context filters retain the provider's unbounded raw
batch and run before the display cap, so item metadata and callbacks survive
local filtering. Every asynchronous refresh revalidates its buffer, modification
tick, and point before changing the menu.
Synchronous prompt providers may atomically normalize their input before
returning candidates; `scripts/prompt-completion-test.sh` verifies that file
refresh still retains path-aware candidates while asynchronous validation stays
strict.
The LSP adapter consequently honors plain `filterText`, `insertText`,
`TextEdit`, and `InsertReplaceEdit` new-text precedence. Provider-relative
replacement ranges are retained with tracked start/end points and per-item
offsets while the user continues editing. LSP `insertTextFormat=Snippet`,
completion resolve, additional edits, and completion commands remain separate
gaps.

### Automatic in-buffer completion — `lem-yath/src/auto-completion.lisp` (verified)

Lem-yath mirrors the active Corfu defaults with a 200 ms wall timer after
insertion or backward deletion, a three-symbol threshold, ten visible rows, and
non-cycling boundaries. Each request captures its window, buffer, modification
tick, point, and logical generation. Pending input, leaving Vi insert state,
opening a prompt, changing buffers, editing again, or canceling the context
prevents an obsolete request from opening a popup. Read-only buffers and keyboard
macros are excluded.

The buffer's mode-local completion spec remains authoritative, as Eglot's CAPF is
in the live Emacs setup. Where there is no mode provider, same-major-mode
dynamic abbreviations supply the ordinary-buffer candidate pool, while recognized
path contexts use file-at-point completion. File completion requires either
`file:` or a slash with an existing parent directory and may open before three
identifier characters, matching Cape's explicit file trigger.

`lem-yath/src/orderless.lisp` filters ordinary in-buffer candidates with the
configured portable Orderless behavior: escaped-space components, whole-query
smart case, any-order AND matching, overlapping and repeated components,
literal-or-valid-regexp matching, and the default `~`, `=`, `^`, `!`, and `,`
edge dispatchers. Filtering uses LSP `filterText` while acceptance retains the
original item's display, insertion text, range, focus action, and final action.
The `M-Space` command inserts Corfu's separator, invalidates any pending request,
and freezes the last fully accepted provider batch. Further components are
filtered locally, so a space-separated query is never sent to LSP. A zero-match
view hides only the popup; Backspace can recover it, and deleting the final
separator resumes provider queries. Plain Space before separator activation still
ends ordinary completion. Prompt completion remains Vertico-Prescient, and file
completion remains path-aware.

This is deliberately an approximation rather than a full Orderless claim:
CL-PPCRE and Emacs use different regexp dialects, and the pinned Orderless
package's `%` character-fold and `&` annotation dispatchers are not implemented.
Initialism parity is verified for deterministic ASCII word boundaries rather than
every Emacs syntax table.

`scripts/auto-completion-test.sh` drives all of this through the ncurses editor,
including the delay boundary, 12-candidate scrolling through a 10-row window,
both non-cycling edges, rapid-typing debounce, provider exclusivity, singleton
acceptance, whole-token and file-prefix replacement, unrelated movement and
buffer-switch cleanup, Escape cancellation, and out-of-order asynchronous delivery.
`scripts/orderless-completion-test.sh` separately exercises the matcher oracle,
raw-before-cap filtering, manual and automatic completion, local separator request
ownership, stale asynchronous delivery, zero-match recovery, tracked replacement
ranges, and prompt/file isolation through the real ncurses editor.

### Yasnippet-compatible expansion — `lem-yath/src/snippets.lisp` (verified subset)

The configured wrapper searches the repository's private snippets before the
exact flake-pinned `yasnippet-snippets` commit
`606ee926df6839243098de6d71332a697518cb86`. That collection contains 2,387
definitions. Every snippet file is treated solely as data; the corpus audit
classifies 2,243 definitions as portable and 144 that require executable or
conditional behavior as explicitly unavailable, and no embedded Emacs Lisp is
ever evaluated. The
configured private corpus contains one snippet, `org-mode/srcblock.snpt`; its
`jjs` trigger, `language` field, and final blank-line `$0` position are
reproduced exactly. The `.org` filename mapping makes it available even though
Lem currently opens Org files in Fundamental mode.

The portable grammar covers simple and braced numbered fields (`$1`, `${1}`),
numbered defaults, anonymous `${default}` fields, nested fields and defaults,
repeated braced placeholders, simple mirrors, escaped syntax characters,
`${0:default}`, the final `$0`, and `$>` indentation markers. Mirrors update
while their owning field changes, including dependencies nested inside a
containing field. Field order follows Yasnippet's numbered, anonymous, then-zero
ordering, including its observed repeated-placeholder ownership rules.

`Tab` expands a matching trigger or advances the active field; `Shift-Tab`
moves backward. `C-g` ends the session without deleting its text. At the start
of an untouched default, `C-d` clears it and advances, while `Backspace` clears
it and remains in the field; away from that position the underlying commands
retain their ordinary behavior. `${0:...}` permits one replacement edit before
the session commits. Expansion cancels pending automatic completion. An
ordinary completion popup owns `Tab` before expansion, whereas an already
active snippet field takes precedence over an incidental popup. Leaving Vi
insert state retains the session for later resumption, and edits inside fields
continue through Paredit and electric-pair behavior. With no trigger or session,
the original mode-specific `Tab` binding runs unchanged.

`M-x lem-yath-insert-snippet` exposes the active portable templates without
requiring a trigger. Its Prescient-filtered labels include the template name,
trigger, and source table; choosing one inserts it at point and starts the same
field session used by trigger expansion.

Roots retain private-before-community precedence. Tables combine natural
`prog-mode`, `text-mode`, and `fundamental-mode` ancestry with `.yas-parents`
using deterministic Emacs-31-style ordering. The explicit mappings used where
Lem's mode name alone cannot select the matching Yas table are:

| Lem mode or filename | Yas table |
|---|---|
| `clojure-repl-mode` | `cider-repl-mode` (then `clojure-mode`) |
| `elisp-mode` | `emacs-lisp-mode` |
| `lisp-mode` | `lisp-mode` |
| `legit-commit-mode` | `git-commit-mode` |
| `xml-mode` | `nxml-mode` |
| `posix-shell-mode` | `sh-mode` |
| `.org` | `org-mode` |
| `.md`, `.markdown` | `markdown-mode` |
| `Makefile`, `GNUmakefile`, `.mk` | `makefile-gmake-mode` |
| `.bib` | `bibtex-mode` |
| `.cc`, `.cpp`, `.cxx`, `.hh`, `.hpp`, `.hxx` | `c++-mode` |
| `.cs` | `csharp-mode` |
| `.gd` | `gdscript-mode` |
| `.nasm` | `nasm-mode` |
| `.tex` | `latex-mode` |

The data-only indentation policy recognizes the safe directives present in the
pinned corpus: fixed indentation, fixed indentation combined with disabled
region wrapping, automatic indentation of the first line, and `$>` line
markers. Other `expand-env` forms are unavailable rather than evaluated.
BibTeX snippets deliberately skip automatic indentation: deterministic template
text approximates Emacs' intended steady state, not its transient indentation
calls.

This is not full Yasnippet parity. The 144 definitions requiring backquoted
Elisp, field transforms, nontrivial conditions, command execution, or unsupported
`expand-env` forms cannot expand. Active sessions do not stack, direct snippet
key bindings are not installed, undo/redo does not revive a field session on
redo, and LSP completion items are not ingested as snippets. The real TUI gate
is `nix run .#snippet-test`; it drives the private snippet, portable field
grammar, the Prescient selector, navigation and editing keys,
completion/Vi/Paredit precedence,
indentation, lifecycle cleanup, undo, and a real pinned Python community snippet
through the ncurses editor.

### consult-like commands (verified)

- `M-x`: `execute-command` (bound `M-x`); command completion via `completion-command`
  (`prompt.lisp:151`).
- Find file: `lem:find-file` (`C-x C-f`).
- Buffer switch: `select-buffer` (`C-x b`), `list-buffers` (`C-x C-b`,
  `src/ext/list-buffers.lisp`). The configured TUI verifies Buffer/File columns,
  fuzzy narrowing, and Return-to-open; Emacs' saved Ibuffer groups remain absent.
- Recent files: `M-g r` opens Lem's persistent MRU after lem-yath sets the loaded
  history's 300-entry limit and normalizes oversized persisted histories to their
  newest 300 entries. Fresh-process TUI tests verify trimming, capping,
  deduplication, move-to-front, persistence, and opening.
- Find by name: `M-s f` (`lem-yath/src/find-name.lisp`) prompts for a root and
  wildcard, runs GNU find asynchronously with a NUL-delimited argv-safe protocol,
  and fills a persistent read-only `*Find*` buffer. Exact path properties make
  Vi Return safe for spaces, semicolons, literal `*`, `?`, and `[`, and displayed
  control characters; q leaves the result buffer available. Dired marking, file
  operations, long columns, and process cancellation remain absent.
- Grep: `lem/grep:grep` and `lem/grep:project-grep` (`src/ext/grep.lisp`, bound
  `C-x p g`). Default command **`git grep -nHI`** (`grep.lisp:14-18`); change with
  `(setf lem/grep:*grep-command* "rg")` or `lem/grep:change-grep-command`. **Results are
  editable** (wgrep-like): editing the results buffer writes through to files
  (`change-grep-buffer`, `grep.lisp:93-136`). Uses the split "peek-source" UI.
- ripgrep: not the default, but trivially `(setf lem/grep:*grep-command* "rg"
  lem/grep:*grep-args* "-nH")`.

### Project-aware finding — `src/commands/project.lisp`
`project-find-file` (`C-x p f`), `project-switch` (`C-x p p`), `project-root-directory`
(`C-x p d`), `project-grep`, `project-save`/`project-unsave`. Root markers:
`*root-directories*` = `.git .hg _FOSSIL_ .bzr _darcs`; `*root-files*` =
`.project .projectile Makefile configure.ac TAGS …` (`project.lisp:31-53`). `find-root`
walks up to the project root. Saved projects persisted to `(lem-home)/history/projects`.

### Completion UI config
`*prompt-buffer-completion-function*`, `*prompt-file-completion-function*`,
`*prompt-command-completion-function*` (`prompt.lisp:9-11`) can be overridden.
In-buffer completion popup: `src/ext/completion-mode.lisp` (`lem/completion-mode`).

### Daily editing workflows — `scripts/daily-workflows-test.sh` (verified)

`M-j` now follows Emacs `duplicate-dwim` for current lines and contiguous active
regions. The ncurses suite checks the otherwise easy-to-miss unterminated-EOF
newline rule against Emacs, point retention at EOF, one-step undo, forward and
reverse Vi character selections, V-LINE state, and Paredit's mode-local structural
override. V-BLOCK/rectangle duplication remains an explicit gap.

### Electric pairs and self-insert selection replacement — `lem-yath/src/electric-pair.lisp` (verified)

Ordinary self insertion replaces a nonempty active Emacs-style region and
cancels its mark. An opening delimiter or string quote instead wraps the
region and consumes the mark; delimiters land after the opener, while quotes
land on the originally typed side. A zero-width mark remains ordinary
insertion. Vi visual state keeps its modal operators and Vi replace state keeps
one-character overwrite. Paredit remains authoritative in Lisp-family buffers:
configured Lispy-style delimiters land on the opener with an inactive mark,
while quote wrapping retains the original outer selection orientation.
Selected quotes and backslashes are escaped so the wrapped Lisp string retains
the selected text's value.

Pair discovery uses each buffer's syntax table. Openers insert their matching
closer, escaped quotes remain literal, an immediate matching closer is reused,
and typing that closer advances over it. Numeric prefixes, odd/even escapes,
balanced adjacent pairs, syntax-safe whitespace/newline skipping, prompt
queries, and Lisp completion/Paredit dispatch are covered as well. Special
delimiter input closes an ordinary in-buffer completion popup without stale
state, while prompt completion refreshes in place. The real ncurses suite also
covers Fundamental, Python, Lisp/Paredit, read-only buffers, one-step undo, and
both region orientations.

This remains an approximation of the complete Emacs mode: preserve-balance does
not yet scan across intervening non-whitespace forms, adjacent-pair Backspace is
not global outside Paredit, and a zero-result prompt completion cannot yet be
recovered without reopening it. For a selected Lisp form containing an unmatched
embedded quote, Lem escapes the quote to keep the new string valid; configured Lispy
leaves that interior quote raw, so this is an intentional semantic improvement.

---

## 5. LSP  (`extensions/lsp-mode/`, package `lem-lsp-mode`)

### Enable — `lsp-mode.lisp:260` (`define-minor-mode lsp-mode`)
A language spec auto-adds `enable-lsp-mode` to the mode's hook
(`define-language-spec` macro, `lsp-mode.lisp:1832-1841`), so opening a file in a mode
that has a spec auto-starts LSP. Manual: `M-x lsp-mode`. Disable temporarily inside a
body with `(lem-lsp-mode:without-lsp-mode () …)`.

### Registering servers — `define-language-spec` (`lsp-mode.lisp:1832`)
```lisp
(lem-lsp-mode:define-language-spec (spec-name major-mode &key parent-spec)
  :language-id "…"  :root-uri-patterns '("Cargo.toml")
  :command '("server" "--stdio")   ; or (lambda (port) (...)) for :tcp
  :install-command "…" :readme-url "…" :connection-mode :stdio) ; :stdio | :tcp
```
Spec class slots in `lsp-mode/spec.lisp:16-47`. Override per-server init options with
`(defmethod spec-initialization-options ((spec my-spec)) (make-lsp-map …))`.
Customize the server command at runtime: redefine the spec, or set the relevant
defvars (some configs expose them, e.g. erlang `*lsp-erlang-server-command*`).

### Languages that ship a WORKING spec (verified active, loaded via each mode's asd):
| Language | language-id | command | mode | config file |
|---|---|---|---|---|
| Go | go | `gopls serve -port …` (TCP) | `lem-go-mode:go-mode` | `go-mode/lsp-config.lisp` |
| Python | python | `pylsp` | `lem-python-mode:python-mode` | `python-mode/lsp-config.lisp` |
| TypeScript | typescript-tsx | `typescript-language-server --stdio` | `typescript-mode` | `typescript-mode/lsp-config.lisp` |
| JavaScript | javascript | `typescript-language-server --stdio` | `js-mode` | `js-mode/lsp-config.lisp` |
| Vue | vue | (inherits js-spec) | `vue-mode` | `vue-mode/lsp-config.lisp` |
| Lua | lua | `lua-language-server` | `lua-mode` | `lua-mode/lsp-config.lisp` |
| Clojure | clojure | `clojure-lsp` | `clojure-mode` | `clojure-mode/lsp-config.lisp` |
| Kotlin | kotlin | `kotlin-language-server` | `kotlin-mode` | `kotlin-mode/lsp-config.lisp` |
| Perl | perl | `pls` | `perl-mode` | `perl-mode/lsp-config.lisp` |
| Elixir | elixir | `sh language_server.sh` | `elixir-mode` | `elixir-mode/lsp-config.lisp` |
| Zig | zig | `zls` | `zig-mode` | `zig-mode/lsp-config.lisp` |
| Swift | swift | `xcrun --toolchain swift sourcekit-lsp` | `swift-mode` | `swift-mode/lsp-config.lisp` |
| Terraform | terraform | `terraform-ls serve -port …` (TCP) | `terraform-mode` | `terraform-mode/lsp-config.lisp` |
| Erlang | erlang | ELP (`elp server …`) | `erlang-mode` | `erlang-mode/lsp-config.lisp` |
| Common Lisp | lisp | (LSP-side spec) | `lisp-mode` | `lisp-mode/v2/lsp-config.lisp` (lisp also has micros, §8) |

### Languages WITHOUT a working spec (GAPS — important):
- **Rust**: `rust-mode` ships **no** `lsp-config.lisp` at all (`extensions/rust-mode/`
  has only `rust-mode.lisp`). The `rust-spec` in `lsp-mode.lisp` is inside a `#|…|#`
  comment block (`lsp-mode.lisp:1853-1857`) and is **inactive**. → No rust-analyzer
  out of the box; you must `define-language-spec` yourself in init.lisp.
- **Nix** (`nix-mode/lsp-config.lisp`) and **wat** (`wat-mode/lsp-config.lisp`): specs
  are guarded by `#+(or)` → **disabled**. Re-enable by copying the spec into init.lisp
  (nix server = `nil`).
- **SQL** and **Dart** specs also live only in the commented `#|…|#` block in
  `lsp-mode.lisp` → inactive.

So: to get rust-analyzer / nil / sql etc., add (in `init.lisp`, package `lem-user`):
```lisp
(lem-lsp-mode:define-language-spec (my-rust-spec lem-rust-mode:rust-mode)
  :language-id "rust" :root-uri-patterns '("Cargo.toml")
  :command '("rust-analyzer") :connection-mode :stdio)
```

### LSP commands & default bindings — `lsp-mode.lisp`
Commands: `lsp-hover` (bound `C-c h`, `lsp-mode.lisp:258`), `lsp-signature-help`,
`lsp-type-definition`, `lsp-implementation`, `lsp-document-highlight`,
`lsp-document-symbol`, `lsp-code-action`, `lsp-organize-imports`, `lsp-document-format`,
`lsp-document-range-format`, `lsp-rename`, `lsp-document-diagnostics`,
`lsp-restart-server`, `lsp-sync-buffer` (lines 290-1817).
**Goto-def / references reuse language-mode bindings**: `lsp-mode` sets
`find-definitions-function`/`find-references-function` (`lsp-mode.lisp:266-269`), which
are invoked by `M-.` `find-definitions`, `M-?`/`M-_` `find-references`, `M-,`
`pop-definition-stack` (`src/ext/language-mode.lisp:94-97`). Completion via
`language-mode:completion-spec` set to async LSP completion (`lsp-mode.lisp:264`).
Diagnostics are shown as overlays; `*inhibit-highlight-diagnotics*` toggles inline
highlighting.

---

## 6. Tree-sitter  (`extensions/tree-sitter/`, package `lem-tree-sitter`)

Depends on `tree-sitter-cl` (FFI bindings). **Both `tree-sitter-cl` and `lem-tree-sitter`
are built into the nix image** (`flake.nix:351`). Bundled grammars (LD_LIBRARY_PATH in
`flake.nix:372`): **json, markdown, yaml, nix, python, javascript, typescript, go, perl,
clojure** (10 languages).

### What it provides — `extensions/tree-sitter/integration.lisp`, `package.lisp`
- `treesitter-parser` class — a `syntax-parser` replacement using highlights.scm/
  indents.scm queries (`integration.lisp:24-60`).
- `(lem-tree-sitter:make-treesitter-parser language &key highlight-query-path
   indent-query-path)`.
- `(lem-tree-sitter:enable-tree-sitter-for-mode syntax-table language query-path
   &key indent-query-path)` — `integration.lisp:173`. This swaps a mode's syntax table
   to use tree-sitter highlighting + (optional) indentation.
- `enable-tree-sitter-for-all-modes`, `tree-sitter-available-p`,
  `get-buffer-treesitter-parser` (exported, `package.lisp`).

### How it's enabled — **manual, not automatic.**
There is **no minor mode and no auto-wiring**: shipped language modes still use their
TextMate/regex syntax tables. To use tree-sitter you call `enable-tree-sitter-for-mode`
with a grammar name + a `highlights.scm` path. There is no ready set of bundled `.scm`
queries inside the lem package (you supply query paths). So tree-sitter is a
**capability/API**, not a turnkey feature — budget config effort. Incremental reparse is
supported (`record-tree-sitter-edit`, lines 220-249).

---

## 7. Git  (`extensions/legit/`, package `lem/legit`; porcelain in `lem/porcelain`)

Magit-inspired. `M-x legit-status` bound **`C-x g`** (`legit/legit.lisp:65`).

### Workflow / bindings (in the legit/peek-legit status window) — `legit/legit.lisp`, `peek-legit.lisp`
- Stage/unstage/discard file: `s` / `u` / `k` (`peek-legit.lisp:26-28`); hunk-level
  stage/unstage: `s`/`u` in the diff window (`legit.lisp:66-67`).
- Commit: `c` → opens commit buffer; finish `C-c C-c`, abort `M-q`/`C-c C-k`
  (`legit-commit.lisp:38-41`).
- Branches: checkout `b b`, create `b c` (`legit.lisp:74-76`).
- Push/Pull: `P p` / `F p` (`legit.lisp:80-82`).
- Log: `l l`, last/first page `l F` / pagination (`legit.lisp:86-87`).
- **Stash**: push `z z`, pop `z p` (`legit.lisp:111-112`).
- **Interactive rebase**: `r i`; abort/continue/skip `r a`/`r c`/`r s`
  (`legit.lisp:105-108`); full rebase-todo editing mode with `p r e s f x b d l t m`
  keys (`legit-rebase.lisp:49-77`).
- Refresh `g`, navigate `n`/`p`/`M-n`/`M-p`, help `?`/`C-x ?`, quit `q`.

### Porcelain coverage vs magit — `legit/README.md`
Covered: status, stage/unstage (file + hunk), discard, commit, branches (checkout/
create), push, pull/fetch, commits log with pagination, **stash push/pop**, interactive
rebase (pick/fixup/squash/drop/exec/break/label/reset/merge; reword & edit NOT yet
supported). Also basic Fossil + Mercurial. **Gaps vs magit:** no region-precise staging,
no multi-file staging, limited switches/transient submenus, no blame/bisect/cherry-pick
UI, no log graph filtering. Customize via `lem/porcelain:*git-base-arglist*`,
`*commits-log-page-size*`, `*nb-latest-commits*`, `*branch-sort-by*`,
`lem/legit:*vcs-existence-order*`.

### Also: git-gutter — `extensions/git-gutter/` (`lem-git-gutter`), in the image. Shows
add/modify/delete marks in the gutter.

---

## 8. Language modes (every directory in `extensions/`)

All of these are built into the nix `lem-ncurses` image (via `lem/extensions`, unless
noted `#+sbcl` which is fine since the image is SBCL). Package is `lem-<name>` and the
major mode `lem-<name>:<name>` unless noted.

**Programming:** `c-mode`, `go-mode`(+LSP, call-graph), `rust-mode` (NO LSP, see §5),
`python-mode`(+LSP, run-python REPL, call-graph), `js-mode`(+LSP),
`typescript-mode`(+LSP), `vue-mode`(+LSP), `ruby-mode`, `perl-mode`(+LSP),
`elixir-mode`(+LSP, `#+sbcl`), `erlang-mode`(+LSP), `haskell-mode`, `ocaml-mode`,
`scala-mode`, `kotlin-mode`(+LSP), `java-mode`, `swift-mode`(+LSP), `dart-mode`,
`lua-mode`(+LSP), `nim-mode`, `zig-mode`(+LSP), `clojure-mode`(+LSP, nREPL repl.lisp),
`scheme-mode` (`#-clasp`), `coalton-mode`, `elisp-mode`, `lisp-mode` (full SLIME, below),
`asm-mode`, `wat-mode`, `posix-shell-mode`, `sql-mode`, `terraform-mode`(+LSP),
`nix-mode` (LSP disabled, §5).

**Markup / data / config:** `markdown-mode`, `asciidoc-mode`, `html-mode`, `css-mode`,
`xml-mode`, `json-mode`, `yaml-mode`, `toml-mode`, `dot-mode` (Graphviz), `makefile-mode`,
`patch-mode`, `review-mode`, `documentation-mode`.

**Editing aids that are "modes":** `paredit-mode`, `shell-mode`, `skk-mode` (Japanese
input), `color-preview`.

### lisp-mode — full SLIME-like env (`extensions/lisp-mode/`, package `lem-lisp-mode`)
Uses **micros** (a maintained Swank fork) — `lem-lisp-mode.asd` depends on `micros`.
Provides: REPL (`repl.lisp`, `*lisp-repl-mode-keymap*`), eval (`C-c C-c`
`lisp-compile-defun`, `C-M-x` `lisp-eval-defun`, `C-c C-k` compile-and-load,
`C-c C-l` load-file), package set `C-c M-p`, **SLDB debugger** (`ext/sldb.lisp`),
**inspector** (`ext/inspector.lisp`), **autodoc** (`ext/autodoc.lisp`),
**macroexpand** (`ext/macroexpand.lisp`), apropos, trace, class-browser, hyperspec
lookup, quickdocs, test-runner, defstruct→defclass, organize-imports, paren-coloring,
connection-list. Start/connect: `C-c m s` `slime`, `C-c m c` `slime-connect`, `C-c m r`
restart, `C-c m q` quit. Switch to REPL `C-c C-z`. Keybindings in `lisp-mode.lisp:76-98`.

### paredit-mode — `extensions/paredit-mode/paredit-mode.lisp` (`lem-paredit-mode`)
Real structural editing: `paredit-slurp`, `paredit-barf`, `paredit-splice`(+fwd/bwd),
`paredit-raise`, `paredit-wrap-round`, `paredit-kill`, `paredit-forward`/`-backward`,
`paredit-meta-doublequote`, smart paren/bracket/brace/quote insertion & deletion
(`paredit-mode.lisp:67-617`, keys at line 617). `(paredit-mode)` to toggle.

### markdown-mode — `extensions/markdown-mode/` includes literate **eval-block** support
(`markdown-eval-block`, `interactive.lisp:105`) and a `preview`/`preview-default` generic
(`internal.lisp:6,29`) for rendering. (Aligns with Lem's "living canvas" vision.)

---

## 9. UI

### Themes — `src/color-theme.lisp`, `src/ext/themes.lisp`, `extensions/lem-base16-themes/`
- Define: `(define-color-theme "name" (optional-parent) (:foreground "#..")
   (:background "#..") (attribute …) …)` — `color-theme.lisp:30`.
- Load / set: **`(lem:load-theme "name")`** — `color-theme.lisp:89` (this is the real
  function; it also persists to `(lem:config :color-theme)`). `M-x load-theme` prompts.
- `M-x list-color-themes` (`src/ui/theme-list.lisp:15`) shows a selector.
- Built-in themes: `"lem-default"` (default, loaded on init via
  `initialize-color-theme`, `color-theme.lisp:142-145`), `"emacs-light"`, `"emacs-dark"`
  (`src/ext/themes.lisp:5,21,38`).
- **base16 themes**: `lem-base16-themes` ships **185** themes (`define-base16-color-theme`,
  e.g. `"apprentice"`, `"atelier-cave"`, all the standard base16 schemes;
  `extensions/lem-base16-themes/src/themes.lisp`). All available by name to `load-theme`.
- Hook after theme load: `*after-load-theme-hook*`.

### Modeline — `src/modeline.lisp`
`(lem:modeline-add-status-list item &optional buffer)` /
`modeline-remove-status-list` (`modeline.lisp:55,61`); items are functions returning
display strings. `*modeline-status-list*` is the global list.

### Line numbers — `src/ext/line-numbers.lisp`
`line-numbers-mode` minor mode (`line-numbers.lisp:41`); command
`toggle-line-numbers` (`:universal-nil`, line 46; prefix arg → relative). Editor
variables: `line-numbers` (line 37), `line-number-format` (21), `custom-current-line`
(26), `lem/line-numbers:*relative-line*` (14). Enable globally:
`(setf (variable-value 'lem/line-numbers:line-numbers :global) t)` then
`(lem/line-numbers:line-numbers-mode)` — or set via vi `:set number`.

### Show-paren — `src/ext/showparen.lisp`. `M-x toggle-show-paren` (line 69); enabled by
default via `lem/show-paren:enable`. Highlights matching paren.

### Highlight current line — `src/highlight-line.lisp`. Editor variable
`highlight-line` (default **t**, line 3) and `highlight-line-color` (line 4). On by
default.

### Tabs / window management
- **Frame multiplexer = tab bar** (`src/ext/frame-multiplexer.lisp`,
  `lem/frame-multiplexer`): `frame-multiplexer-mode` toggles a tmux-like tabbed frame;
  `frame-multiplexer-next/prev/switch-0..9/create`. There is also `src/tabbar-config.lisp`.
- Window splits/commands: `split-active-window-vertically`/`-horizontally`,
  `delete-other-windows` (`C-x 1`), `other-window`/`next-window` (`C-x o`),
  `delete-active-window` (`C-x 0`) — `src/commands/window.lisp`. Floating windows
  supported by frontends.

---

## 10. Apps / extras

- **Terminal**: `extensions/terminal/` (`lem-terminal`, **Unix-only**,
  `#-os-windows` in `lem.asd:294`). Uses **libvterm via CFFI** (`ffi.lisp`,
  `terminal.c`). Command `M-x terminal` (`terminal-mode.lisp:84`). A real terminal
  emulator inside Lem. (In the nix ncurses image, libvterm is linked.)
- **File manager / filer**: `directory-mode` (dired-like, `src/ext/directory-mode/`)
  and `src/ext/filer.lisp` (a tree/column filer). `find-file` on a directory opens it.
- **Encodings**: `extensions/encodings/` (`lem-encodings`): utf-8/16, cp932, euc-jp,
  gb2312, iso-8859-1, 8bit. `prompt-for-encodings`, `*default-external-format*`
  (`:detect-encoding` default).
- **which-key / transient menus**: `extensions/transient/` (`lem/transient`,
  `define-transient`) — magit-style popup menus with columns/descriptions
  (`transient/transient.lisp`). Combined with the new prefix keymap system this is the
  which-key analog. (No separate "which-key auto-popup on every prefix" toggle, but the
  prefix/transient infra exists.)
- **Snippets / templates (upstream)**: **NONE.** No yasnippet/tempel equivalent.
  `src/ext/abbrev.lisp` (`lem/abbrev`, `M-/`) is **dynamic abbrev** (word
  completion from buffers), not templating. Lem-yath adds the verified data-only
  compatibility layer described in §4; that does not change upstream Lem.
- **abbrev** (static expansion table like Emacs `abbrev-mode`): only the dynamic form
  above exists; no abbrev-table system.
- **isearch / occur**: `src/ext/isearch.lisp` (`lem/isearch`): `isearch-forward`/
  `-backward`/`-regexp`/`-symbol`, `query-replace`, `query-replace-regexp`,
  `query-replace-symbol`, isearch→multiple-cursors (`isearch-add-cursor-to-next-match`).
  **No dedicated `occur` command**; the grep/peek-source UI (§4) covers "list matches",
  and it is **editable like wgrep**.
- **Multiple cursors**: core support. `src/cursors.lisp` + `src/commands/multiple-cursors.lisp`
  (`add-cursors-to-next-line`, bound `M-C`); isearch can add cursors at matches.
- **Markdown preview**: yes, `preview` generic in markdown-mode (§8), plus literate
  eval-block.
- **AI / shipped in-tree (all in the image):**
  - **Copilot** — `extensions/copilot/` (`lem-copilot`): `copilot-mode` minor mode,
    `copilot-install-server`, `copilot-signin`, `copilot-complete`,
    `copilot-accept-suggestion`, `copilot-next/previous-suggestion`
    (`copilot.lisp:134-408`). Talks to the GitHub Copilot LSP.
  - **Claude Code** — `extensions/claude-code/` (`lem-claude-code`): `M-x claude-code`
    (`claude-code.lisp:194`), button interactions, an SDK wrapper
    (`claude-code-sdk.lisp`).
  - **MCP server** — `extensions/mcp-server/` (`lem-mcp-server`): Lem can expose an MCP
    server.
  - **deepl / google-translate**: `src/ext/deepl.lisp` (core) and
    `contrib/google-translate` (contrib).
- **Dashboard / welcome**: `extensions/lem-dashboard/` sets `lem:*splash-function*`
  (`lem-dashboard.lisp:146`) — the startup splash when no file is opened
  (`command-line-arguments.lisp:87-89`). `extensions/welcome/`, `extensions/lem-tutor/`
  (interactive tutorial).
- **bookmark**: `extensions/bookmark/` (`lem-bookmark`).
- **living-canvas / pixel-demo / call-graph**: experimental visual features
  (`#+sbcl lem-living-canvas`; call-graph providers for go/python via tree-sitter).
- **contrib/ (NOT in the default image)**: `bracket-paren-mode`, `calc-mode`, `fbar`,
  `migemo`, `modeline-battery`, `mouse-sgr1006`, `overwrite-mode`, `selection-mode`,
  `tetris`, `trailing-spaces`, `version-up`, `ollama`, `google-translate`. These are the
  `lem-contrib` system (`contrib/lem-contrib.asd`) and are **not** depended on by
  `lem/extensions` — they would need to be loaded explicitly (and since the nix image
  lacks the extension-manager, they must be present to ASDF; see top note).

---

## 11. Threading

- Lem uses **`bordeaux-threads` (bt2)** (`lem.asd:28`). The editor runs on a dedicated
  thread "editor" spawned by `run-editor-thread` via `bt2:make-thread`
  (`src/lem.lisp:67-81`). Find it with `lem-core::find-editor-thread`.
- **Event queue** — `src/event-queue.lisp`: `(lem:send-event obj)` enqueues onto
  `*editor-event-queue*`; if `obj` is a function/symbol it is **funcalled on the editor
  thread** (`event-queue.lisp:8,29-31`). This is the idiom for "run this in the editor
  thread from a background thread": do work in `bt2:make-thread`, then marshal UI/buffer
  mutations back with `(send-event (lambda () …))`. `send-abort-event` interrupts.
- **Timers** — `src/common/timer.lisp` (`lem/common/timer`, re-exported under `lem:`):
  `make-timer`, `make-idle-timer`, `start-timer`, `stop-timer`. Timer callbacks are
  delivered via `send-timer-notification` which `send-event`s the continuation and
  redraws (`src/lem.lisp:15-19`). Use these for debounced/idle work instead of raw sleep.
- **Rule of thumb**: never touch buffers/windows directly from a worker thread — wrap
  the mutation in `(lem:send-event (lambda () …))`. Background process I/O uses
  `lem-process` (`extensions/process/`, async-process) and `uiop:run-program`/
  `uiop:launch-program` (e.g. grep, LSP, legit).

---

## 12. Config best practices

- **User config package: `:lem-user`** (`src/external-packages.lisp:21-22`,
  `(defpackage :lem-user (:use :cl :lem))`). The init file is loaded with `*package*`
  bound to `:lem-user` (`src/lem.lisp:44`), so you usually do **not** need an
  `(in-package …)`, but the idiomatic header (matching `rc-example.lisp:1`) is:
  ```lisp
  (in-package :lem-user)
  ```
  All `lem:` symbols (core + commands, via `:use-reexport` in
  `external-packages.lisp:1-17`) are directly accessible. The `:lem` package is
  **locked** (`external-packages.lisp:18-19`) — don't redefine its symbols; define your
  own in `lem-user`.
- **What is already in the image (no quickload needed):** everything in
  `lem/extensions` (§ top): vi-mode, lsp-mode, lisp-mode, all language modes, legit,
  terminal, paredit, copilot, claude-code, mcp-server, transient, dashboard, git-gutter,
  base16-themes, tree-sitter (+ tree-sitter-cl). Just call into the packages:
  `(lem-vi-mode:vi-mode)`, `(lem-go-mode:go-mode)` (auto by file type),
  `(lem:load-theme "atelier-cave")`, etc.
- **What needs explicit loading:** `contrib/` systems and any third-party `lem-*` system
  not in `lem/extensions`. Mechanism: drop the system where ASDF can find it (e.g.
  `(lem-home)/inits/…`) and declare it via the site-init system
  (`site-init-add-dependency`, §1) or `(asdf:load-system :lem-foo)` in init.lisp.
  **`ql:quickload` of brand-new Quicklisp deps is unreliable in the nix image** because
  `:nix-build` removes `lem-extension-manager` and there is no Quicklisp dist wired in —
  prefer build-time inclusion for anything with new external dependencies.
- Sample configs to mirror: `extensions/vi-mode/rc-example.lisp` (vi bindings, hooks,
  `define-ex-command`), `docs/extension-development.md` (modes, syntax, file types).
- Persistent simple settings: `(setf (lem:config :key) value)`; per-mode behavior:
  editor variables via `(setf (variable-value 'name :buffer (current-buffer)) v)` inside
  a mode hook.

---

## Upstream summary (before lem-yath configuration)

Lem covers the **evil/lsp/magit** trio surprisingly well and it is **all baked into the
nix `lem-ncurses` image**: vi-mode gives modal editing with normal/insert/visual/operator
states, text objects, registers, jumplist, ex-commands (`define-ex-command`), Vim
options, and a real **leader-key** mechanism (set `leader-key` to `"Space"` +
`"Leader f"` bindings) for Spacemacs/Doom-style SPC menus. LSP ships **working** specs
for ~15 languages (go, python, ts/js, clojure, zig, lua, kotlin, elixir, erlang, swift,
terraform, perl, vue, lisp) with hover/goto/refs/rename/code-action/format/diagnostics —
but **Rust, Nix, SQL, Dart have no active spec** and need a one-line
`define-language-spec` in `init.lisp`. **legit** is a credible magit-lite: status, hunk
staging, commit, branch, push/pull, log, **stash**, and **interactive rebase** (reword/
edit excepted). LSP/grep results are even **wgrep-editable**. Common Lisp gets a full
SLIME (micros): REPL, SLDB, inspector, macroexpand, autodoc. Extras shipped in-tree:
libvterm **terminal**, **Copilot**, **Claude Code**, MCP server, transient (which-key-ish)
menus, multiple-cursors, isearch/query-replace, 185 base16 themes, line-numbers,
show-paren, highlight-line, frame-multiplexer tabs, dired-like filer, markdown preview +
literate eval.

**The big upstream gaps vs Emacs:** **no org-mode** (no agenda/babel/capture/export — markdown
eval-blocks are the closest), **no upstream snippet system** (no yasnippet/tempel;
only dynamic abbrev `M-/`; lem-yath adds the bounded data-only subset in §4),
**no static abbrev tables**, **completion has fuzzy primitives but
no Orderless/Prescient framework**, **tree-sitter is a manual API** (no auto-enabled
tree-sitter modes; you wire grammars+queries yourself, 10 grammars bundled), **vi-mode
lacks surround/sneak/easymotion**, **legit lacks blame/bisect/cherry-pick/region-staging**,
and the **nix image cannot freely `ql:quickload` new deps at runtime** (extension-manager
is compiled out), so anything outside `lem/extensions` must be added at image/ASDF time.
Config language is Common Lisp in package `:lem-user`, single `init.lisp` in
`~/.config/lem/` (or `~/.lem/`), with `add-hook`/`*after-init-hook*` and the
`~/.lem/inits/` site-init system for multi-file setups. Several of these upstream
gaps now have partial or exact lem-yath implementations; consult the ledger rather
than inferring current status from this capability survey.
