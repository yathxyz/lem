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
For a normal init file, use `(add-hook lem:*after-init-hook* (lambda () …))`.
The lem-yath wrapper deliberately starts Lem with `-q --eval`, and CLI eval forms run
after that hook has already fired. Its `initialize-editor-feature` helper therefore
runs frame-dependent setup immediately when `*in-the-editor*` is true and registers a
hook only for pre-launch loads. For deferred/async work, use a timer (§11) or
`(lem:start-timer (lem:make-idle-timer #'fn) …)`.

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
Each carries cursor type, optional cursor color, and modeline color. The ncurses
frontend turns `:box`, `:bar`, and `:underline` into DECSCUSR terminal controls.
Changing the shared cursor attribute alone does not invalidate a stationary
cursor cell's drawing cache, so lem-yath marks the focused window dirty on an
ordinary Vi state change before the normal post-command redraw.

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

Lem-yath supplies those configured modal layers in `src/vi.lisp`. Its surround
dispatcher implements `ys`, `ds`, `cs`, and Visual `S`, the pinned
evil-surround delimiter/padding table, `#{...}`, XML tag prompts on `t`/`<`,
ordinary call prompts on `f`, and prefix forms on `C-f`. The XML path matches
nested tags while respecting quoted `>` characters and self-closing children;
its prompt supports the configured Emacs editing keys and `C-g` rollback. Tag
changes preserve prior attributes when submitted with Return and discard them
when an explicit `>` inserts that character and submits immediately. Malformed
nesting and multi-character block-string delimiters fail closed. Visual Block `S` applies
the chosen pair independently to each covered row with the pinned package's
corner orientation, short-line, cursor, state-exit, and one-step undo behavior.

Lem-yath supplies the configured Evil/Avy navigation separately in
`src/avy.lisp`. `SPC l/a/s` select visible line, character, and symbol-start
targets through Avy's balanced `a/s/d/f/g/h/j/k/l` tree. Borderless floating
windows place labels over target cells without changing source text, text
properties, modified state, or undo/redo history. Normal state considers every
visible ordinary or dedicated side text window unless a prefix narrows it to
the current one; transient floating popups are excluded. Visual and operator
states remain current-window-only. Character candidates are case-folded and
closest-first, while symbol selection uses syntax-table starts and treats
printable punctuation as a direct target.

Line selection follows displayed rows, including wrapped rows, and excludes
hidden lines. A raw digit during line selection opens the absolute-line
fallback, zero and singleton candidate sets retain Avy's behavior, and Escape
or `C-g` removes every label. A size change invalidates the cached screen
coordinates and aborts on the next Avy input. `scripts/avy-test.sh` verifies
these paths, jumplist integration, reload cleanup, and source non-mutation in
the real ncurses frontend. Avy's default `x/X/t/m/n/y/Y/i/z` dispatch actions
restart the selector and provide kill-and-move, kill-and-stay, teleport, mark,
copy, yank, line-yank, spell correction, and zap behavior; `?` displays the
stock action map. The `i` action invokes an exact flake-packaged Aspell binary
with the configured `en_US` dictionary and a bounded timeout. Character and
symbol targets correct the alphabetic word at or preceding the target; line
targets inspect every alphabetic word on the selected line. Suggestions retain
Aspell order under Prescient filtering. `0` through `9` choose the corresponding
proposal, `Space` accepts the spelling once, `a` records it for the current Lem
process, `i` saves it through Aspell's personal-dictionary protocol for use by a
fresh Lem or Emacs process, and `r` opens a validated free-text replacement.
The operation preserves the Avy origin and Vi state, and a text replacement
remains one undo step. Buffer-local dictionaries, dictionary switching,
Flyspell presentation, non-alphabetic word syntax, exotic display/syntax
geometry, and exact Emacs choices-window presentation remain approximate or
absent.

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

Prompt matching reproduces the pinned Prescient defaults: every space-separated
component may match as a literal, regexp, or initialism, with whole-query smart
case. Literal matching performs directional character folding, so plain input
matches diacritics, Unicode compatibility forms, and Prescient's ASCII quote
variants without simplifying non-ASCII query characters. The real TUI gate
accepts an accented result through plain input and verifies its exact identity;
the fixture oracle also covers directionality, smart case, compatibility forms,
quote variants, and Prescient's deliberate lack of `ae`/`ss` expansions for
`æ`/`ß`.

While any non-file prompt is active, `M-s` exposes the pinned
Vertico-Prescient toggle map: `a` anchored, `f` fuzzy, `i` initialism, `l`
literal, `P` literal-prefix, `p` prefix, `r` regexp, `'` character folding, and
`c` case folding. A method key adds or removes that method, `C-u M-s KEY`
selects it exclusively, and the sole active method cannot be removed. The
candidate list refreshes immediately, including from zero results. Settings
live on the prompt buffer and disappear on accept or abort, so the next prompt
starts with literal/regexp/initialism, smart case, and character folding again.
Prompt-local `C-u` deliberately uses minibuffer universal-argument semantics;
outside prompts the configured Evil delete-to-indentation behavior is unchanged.

Lem-yath gives prompt contexts Vertico-style display-only startup: presenting
candidates neither inserts a shared prefix nor automatically accepts a
synchronous singleton. `Tab` inserts the focused candidate and refreshes
completion without closing the prompt; one `Return` accepts it and submits the
prompt. `M-p` and `M-n` traverse prompt history and reopen completion. If an
edit produces no candidates, the prompt retains the unmatched input and the
next edit queries its provider again; deleting back into a valid command,
buffer, or path query and completing a Prescient regexp both restore the popup
in place. `scripts/prompt-completion-test.sh` drives the real M-x and annotated
buffer prompts through zero results and verifies stale rows, Backspace recovery,
and recovery through further input.

The prompt field inherits the configured Emacs 31 non-Evil minibuffer editing
surface without exposing its read-only label. In addition to character/word
motion, deletion, mark, kill-ring, transpose-character, and undo commands, the
field supports `M-t` word transpose, `M-u`/`M-l`/`M-c` word case conversion,
`C-q` quoted insertion, `M-\` horizontal-space deletion, and `C-x Backspace`
backward sentence kill. Signed word and sentence prefixes match the pinned GNU
oracle, a whitespace prefix deletes only before point, and every mutation
refreshes or reopens completion. The same keys close ordinary Corfu and replay
unchanged, preserving Paredit's Lisp-local `M-t` and Lem's ordinary quoted
insert rather than leaking prompt boundary logic into source buffers.

### Directory-local Consult outline — `lem-yath/src/project-outline.lisp` (verified)

The audited Emacs configuration binds `C-c i` to `consult-outline` only for
Emacs Lisp files below a project `.dir-locals.el` that also declares
`outline-regexp` as `;;;`. Lem-yath discovers the nearest declaration but never
evaluates it: the reader accepts at most 64 KiB, disables reader evaluation,
requires one complete form, and enables the hidden buffer-local mode only for
that exact binding and regexp. Its state-aware mode map exposes the command in
Normal and the custom Emacs state while preserving the configured LLM action in
Insert and Visual states.

The selector scans full matching lines in source order, includes longer
semicolon prefixes, displays line numbers, and uses Prescient matching without
learned reordering. Focus changes preview the match column in the source window
and recenter it. A prompt-local `C-g` or Escape restores the exact source point,
view, horizontal scroll, and invoking Vi state; Return commits the same
match-column jump and records it in the Vi jumplist. The real ncurses gate in
`scripts/project-outline-test.sh` covers presentation, preview, cancellation,
immediate reopen, final jump/return, key precedence, outside-tree isolation,
empty outlines, and a malicious read-time-evaluation form.

### Generic Imenu — `lem-yath/src/imenu.lisp`, `lem-yath/src/native-imenu.lisp` (verified, provider-partial)

`M-x imenu` uses the same Prescient-backed prompt surface without live preview.
In an LSP buffer, a ready server advertising document symbols supplies the
index synchronously just as Eglot does. Hierarchical `DocumentSymbol` results
open one successive prompt per parent and jump to the full range start; legacy
`SymbolInformation` results open kind, optional container, and name prompts.
Without that Eglot-style override, Lisp-family buffers scan the exact pinned GNU
Emacs function, quoted-alias, variable, valued-`defvar`, and type form sets.
Native Org buffers expose the pinned depth-two heading tree, normalize TODO,
priority, COMMENT, tags, and bracket-link labels, exclude source-block content,
and reveal a folded destination. Native Markdown buffers expose nested ATX and
Setext headings with GNU Markdown's literal `.` self entries and `-` level-gap
groups, plus unique visible footnote definitions; YAML front matter, fenced
content, and commented definitions stay out of the index.
Native Python buffers use the pinned tree-sitter sparse hierarchy for nested
functions and classes. Parent definitions retain their dedicated self-jump,
async functions use the ordinary `def` label, decorators do not displace the
jump from the definition node, and string/comment decoys are excluded. A ready
Eglot document-symbol provider still takes precedence over every native index.
Native Java buffers reproduce the pinned `Class`, `Interface`, `Enum`, and
`Method` sparse-tree categories in order. Nested matches retain the literal
space self-entry displayed as `.`, the pinned `Enum` category indexes records,
and constructors plus actual enum declarations remain absent. Annotated methods
jump to the declaration node start. String/comment decoys stay excluded.
Native C buffers reproduce the pinned `Enum`, `Struct`, `Union`, `Variable`,
and `Function` sparse-tree categories. Aggregate types and variables use
Emacs's ancestor-based top-level predicate, direct function prototypes remain
excluded, multi-declarator statements retain their first declarator, and
function definitions jump to the full node start, including attributes.
Nested/local declarations and comment/string decoys stay excluded.
Native `.cc`, `.cpp`, `.cxx`, and C++ header buffers now use a distinct
`c++-mode` and packaged C++ grammar rather than borrowing C parsing. Their
index adds the pinned `Class` category: nested classes and in-class function
definitions form sparse subtrees with literal-space self entries, while
qualified out-of-class definitions keep names such as `Outer::qualified`.
Namespace declarations remain visible according to Emacs's predicates, and
local classes remain Class entries exactly as in the pinned mode.
Native Rust buffers reproduce rust-ts-mode's ordered `Module`, `Enum`, `Impl`,
`Type`, `Struct`, and `Fn` sparse-tree categories. Nested modules and functions
retain literal-space self entries, trait implementations keep labels such as
`Display for Wrapper<T>`, inherent implementations retain their type label,
and strings/comments do not create definitions. A ready rust-analyzer document
symbol provider still takes precedence; the native index is the exact offline
and not-yet-ready fallback.
Native Go buffers reproduce go-ts-mode's ordered `Function`, `Method`,
`Struct`, `Interface`, `Type`, and `Alias` categories. Methods retain receiver
labels such as `(Record).Work`, local type declarations remain visible, and a
mixed parenthesized type declaration follows GNU's whole-declaration predicates
and first-spec naming, even when that repeats `GroupStruct` under multiple
categories. A ready gopls document-symbol provider remains authoritative.
Native GDScript buffers reproduce gdscript-ts-mode's single source-ordered
sparse tree over ordinary, exported, and onready variables, functions, and
classes. Entries retain the pinned `var`, `e-var`, `o-var`, `def`, and `class`
labels; nested parents expose the exact class/function definition self-jump,
and strings/comments do not create definitions. Ready Godot document symbols
remain authoritative over this offline and not-yet-ready fallback.
Native Typst buffers reproduce typst-ts-mode's ordered `Functions` and
`Headings` groups. Function entries are the identifier of a `let` pattern call,
so ordinary bindings and calls used as assigned values remain absent. Heading
entries preserve the complete heading node, including the leading equals signs
and inline markup, and both groups retain source order. The configured Emacs
path has no Typst Eglot hook, so this is its ordinary Imenu provider rather
than an LSP fallback.
Native Terraform buffers reproduce terraform-mode's three regexp passes and
nine lower-case groups for provider/backend/provisioner, variable/module/output,
and data/resource/ephemeral blocks. Labels strip quotes; data/resource/ephemeral
labels join type and name with `/` and jump to the type token. The pinned raw
index reverses group insertion and entries within each group, and its
syntax-blind scanner can index block-looking heredoc lines; Lem retains those
observable quirks. A ready `terraform-ls` document-symbol provider remains
authoritative.
Native Just buffers reproduce just-mode's three generic-Imenu expressions.
They present the pinned reverse declaration order (`task`, `variable`,
`setting`), retain source order inside each group, capture the same names, and
jump to column zero of the definition line. Matches beginning inside multiline
single-, double-, or backtick-quoted strings are excluded under the package's
syntax table; comment matches, assignment-shaped aliases, malformed settings,
and a task at end-of-buffer without the regexp's required following character
remain absent exactly as in the pinned package.
Native NASM buffers reproduce nasm-mode's merged nil-title generic index:
colon-terminated nonlocal labels plus standalone `%define` and `%macro` names
appear in one source-ordered list, while local/colonless labels, `%imacro`, and
matches beginning inside comments or single-, double-, and backtick-quoted
strings remain absent. The upstream expressions are deliberately unanchored
for macros, so an odd mid-instruction `%define` remains visible; destinations
land at column zero of the containing line.

Acceptance records one Vi jumplist entry and runs the configured Imenu feedback:
recenter only, with no Consult Pulsar pulse. `scripts/lsp-project-test.sh` and
`scripts/project-outline-test.sh` drive the command through physical M-x,
successive Return selections, exact target placement, viewport change, silent
feedback, folded Org reveal, and `C-o` return, including the regexp-driven Just
and NASM providers. Native indices for other non-LSP modes are not yet
implemented.

`lem-yath/src/annotations.lisp` supplies a bounded Marginalia-style layer for
the daily prompt categories. Commands show active bindings and their first
documentation line; ordinary and project buffers show modified/read-only state,
size, mode, and path; ordinary, recent, and project files show local Unix modes,
human size, age or date, and a non-default owner when relevant. The real
`load-library` prompt additionally shows loaded state, literal bounded ASDF
version/description fields, and source directory, registering an exact accepted
bundled ASD before delegating to Lem's loader when the dumped image omitted it.
The real `load-theme` prompt shows active state, parent inheritance, and direct
role count. Exact `M-x describe-face` completion ranges over the live Lem
attribute registry and shows the effective foreground, background, bold,
underline, and reverse state. Bookmark prompts show target type, abbreviated path, exact
line/column, and bounded containing-line context; they reuse an open buffer or
read at most 1 MiB without visiting a file or running mode hooks, and stale
targets degrade to missing-path metadata.

Annotations are computed after filtering for at most the 100 visible candidates,
metadata failure degrades to blank or safe fallback detail, and tests prove
annotation text cannot become filter input. For upstream command, buffer, and
file providers, the layer changes only each existing item's display detail,
leaving its label, filter text, replacement range, insertion text, rank, and
acceptance identity intact. Custom project, recent-file, library, theme, and
bookmark providers create correctly ranged items after ranking and retain the
selected raw value separately from display metadata. The ncurses gates cover
common local regular files and buffer states, a non-file special buffer with
its actual mode, conditional ownership from a real foreign-owned file, exact
library/theme/bookmark acceptance, loaded and active state, theme inheritance,
bookmark context, and missing targets. An unexpected annotation failure is
isolated to that candidate: its provider detail and exact selection identity
remain intact, and later candidates continue to be annotated. Candidate columns
follow the pinned Marginalia default: a
20-cell floor rounded upward in 10-cell steps. Labels are measured in terminal
cells, so CJK and other wide text cannot shift the detail column. Supported
documentation, signature, value, source, buffer-path, and bookmark fields use
the pinned maximum of 80 cells reduced to half the active terminal width;
documentation keeps its beginning, while paths keep their useful end. The real
ncurses gate verifies identical detail columns for narrow and wide labels. It
also keeps one prompt open while changing the terminal from 120 to 64 columns
and back, proving that field budgets repaint immediately while prompt input and
the focused candidate remain unchanged.
The ELPA package category has no truthful Nix-managed Lem equivalent. Per-field
semantic styling inside completion details and remote-file fields remain outside
this approximation.

The active Helpful leader workflows are no longer routed through generic
apropos. `SPC h k` indexes every currently fbound, package-qualified Lisp symbol
and shows its callable type, introspected lambda list, and first documentation
line; `SPC h v` indexes bound variables and shows type, a bounded printed value,
and documentation. Variable names matching Marginalia's credential patterns are
censored in both the candidate row and final help buffer. Selection preserves
package identity without reading prompt text as Lisp, while Prescient compiles
each regexp component once per candidate batch so the larger symbol tables remain
responsive.

Accepted callables, variables, and faces open an ordinary read-only `Helpful`
buffer. Face help renders its pangram with the selected live attribute, reports
the current theme layer and effective properties, and retains the defining
source form when SBCL exposes it.
SB-INTROSPECT supplies definition, caller, and reference records; when SBCL only
retains a top-level form path, a non-evaluating source reader derives the exact
character offset. `n`/`p` and `Tab`/backtab traverse source-backed rows cyclically,
Return visits one, `s` visits the main definition, `g` rebuilds the snapshot, and
`q` restores the originating window. Every jump enters Lem's location stack and
Vi jumplist, and a source timestamp change fails closed until refresh. `SPC h K`
reads a physical key and opens its resolved command through the same buffer;
`SPC h b` keeps Lem's binding list. `scripts/help-test.sh` physically covers all
of these paths, same-name package selection, display-only metadata, secret
censoring, exact form jumps, physical `M-x describe-face`, and live reload.
Helpful's advice, disassembly,
debugging/customization sections, syntax-highlighted embedded source, and
semantic button graph remain outside this approximation.

Lem-yath carries `patches/lem-completion-lifecycle.patch`,
`patches/lem-completion-detail-accessor.patch`, and
`patches/lem-completion-observer-change-group.patch` plus
`patches/lem-completion-presentation-focus.patch`,
`patches/lem-completion-groups.patch`, and
`patches/lem-completion-marginalia-layout.patch` against the pinned Lem
revision. They separate display, filter, and insertion text, add a final-accept
callback plus a distinct final-insertion callback, expose scoped presentation,
focus, and teardown observation, make an inactive row non-actionable, and reject
stale asynchronous generations before they can update the popup. A custom final inserter receives
the accepted tracked range only after the completion UI closes; its post-accept
callback runs exactly once only when insertion succeeds. Ordinary automatic
in-buffer contexts also keep a cancellable spinner, remember their origin
buffer, display rather than insert synchronous singletons, and carry their own
row-limit and cycling policy. Context filters retain the provider's unbounded raw
batch and run before the display cap, so item metadata and callbacks survive
local filtering. Every asynchronous refresh revalidates its buffer, modification
tick, and point before changing the menu.
Synchronous file-prompt providers may atomically normalize path input during a
refresh; this is distinct from completion-engine common-prefix insertion, which
prompt contexts disable. `scripts/prompt-completion-test.sh` verifies that file
refresh retains path-aware candidates while asynchronous validation stays strict.
The LSP adapter consequently honors plain `filterText`, `insertText`,
`TextEdit`, and `InsertReplaceEdit` new-text precedence. Provider-relative
replacement ranges are retained with tracked start/end points and per-item
offsets while the user continues editing. When lem-yath's literal LSP handler is
installed, the client advertises snippet support and routes
`insertTextFormat=Snippet` through that final-insertion seam. It also advertises
`InsertReplaceEdit` support and the one lazy property it implements,
`additionalTextEdits`. Acceptance resolves that property synchronously with a
two-second bound, retains every original insertion field, and falls back to the
original item if resolve fails or returns a partial item. Direct and resolved
additional edits are precomputed against one buffer snapshot, kept plain even
when they contain snippet markers, checked for invalid or overlapping ranges,
and applied with the primary insertion in one command-level undo unit. A bad
additional-edit batch is skipped while the primary completion still succeeds.
All affected ranges are checked for read-only protection before the first
mutation. Timed-out resolve requests remove their callback, notify the server,
and rely on the pinned JSON-RPC patch to discard any late response rather than
retaining it indefinitely.

The same patch now uses the originating workspace's position encoding at every
Lem LSP document boundary: incremental changes, requests, workspace and
formatting edits, diagnostics, definitions/references, highlights, document
symbols, and completion. The client advertises UTF-16, rejects offsets that
split a surrogate pair, and retains tested UTF-8/UTF-32 conversion helpers.
Generic edit batches are validated before mutation and applied in descending
order, so adjacent simultaneous edits cannot consume one another.
The final LSP insertion owns a separate retained-undo transaction after Corfu
has closed. If an additional edit, primary edit, snippet installer, or nested
buffer hook throws, Lem restores the exact pre-accept text, point, and undo-tree
node/current/payload state without retaining a live transaction owner. The
configured Emacs comparison does not enable Corfu Popupinfo, does not advertise
CompletionList item defaults or `insertTextMode`, and ignores completion
commands, so Lem deliberately does not add those as parity behavior.

### Embark-style actions — `lem-yath/src/actions.lisp` (verified subset)

Lem-yath adds typed target and action records plus ordered provider and action
registries.  `register-action-target-provider` and `register-action` replace an
entry by stable ID, so reloading built-ins remains idempotent without deleting
unrelated third-party registrations.  `SPC e a` resolves the current context in
this order: an active contiguous region, including an Evil Visual Block expanded
to the same linear span seen by pinned Embark, a property-backed `*Find*` path, a
movable peek-source row, an HTTP(S) URL or existing local path at point, a syntax
identifier, and finally the current buffer.  Outside completion it retains every
unique result in that order, deduplicated by typed target identity.  Repeating
the exact invoking chord, `SPC e a`, advances to the next target and wraps; the
menu title shows `[current/total]`, and the subsequent action uses that cycled
target.  Every target shares one origin snapshot, while target-local
copied points and the origin are all released on action, cancellation, or a
later provider abort.  Providers are extensible, and a failing ordinary provider
or action does not prevent later dispatches.  The dispatcher refuses ambiguous
duplicate action keys rather than showing a menu whose result depends on
registration order.

The resolved target kind and only its applicable actions appear immediately in
a terminal-safe, one-key transient:

| Target | Actions |
|---|---|
| Region | `w` copy region |
| URL | `Return` open URL; `w` copy URL |
| Existing local file | `Return` visit in Lem; `w` copy path; `x` open externally |
| Identifier | `d` definitions; `r` references; `w` copy identifier; `a` current-project LSP code actions when the target is still current and its workspace is ready |
| Search/location row | `Return` visit location; `w` copy the displayed line |
| Buffer | `s` save; `r` revert; `k` kill; `w` copy buffer name |
| Focused completion | `Return` accept the captured item; `w` copy its insertion text |

For ordinary targets, `m` delegates to the originating buffer's native mode
context menu when one is available, and `q` cancels.  URL and external-file
actions pass a direct argument vector to `xdg-open`; they do not construct a
shell command.  Removed buffers, stale completion contexts, and stale
identifier/LSP ownership fail closed.

Completion popups use `C-c a`: ncurses cannot represent `C-.` as a distinct
input chord.  The completion target snapshots the focused item and its context;
copying closes only the action transient and leaves completion live, while
accepting closes completion and runs its insertion/final actions exactly once.
The registry and bindings can be reloaded without accumulating duplicate
providers, actions, or keys.

`scripts/actions-test.sh` exercises the normal/visual leader binding, forward
and reverse character regions, forward and reverse Visual Blocks with exact
expanded text and retained block state, labeled transient dispatch and cancellation, exact-chord
URL/identifier/buffer cycling and wraparound, action dispatch after cycling,
shared-origin cleanup including provider abort, URL copying, exact one-argument
external URL/file launching, relative and property-backed file navigation,
identifier definition/reference delegation, native-menu delegation, all four
buffer actions, completion copy/accept lifecycle, Find and peek locations,
stale-origin cleanup, and reload idempotence through the actual ncurses editor.
`scripts/lsp-project-test.sh` additionally drives `SPC e a`, the code-action
request, native result selection, and server-side command execution over real
stdio JSON-RPC.  It proves a starting workspace withholds the action and cannot
let the document-highlight timer interrupt the transient before capabilities
are ready.

This is intentionally partial Embark parity.  Act-all, collect/export/live
views, arbitrary Embark action-map composition, and the richer embark-consult
adapter set are not implemented.

### Project-scoped LSP workspaces and symbols (verified)

The pinned `patches/lem-project-lsp-workspaces.patch` replaces Lem's ordinary
language-global routing with stable server-class and canonical-root keys plus an
explicit workspace pointer on every managed buffer. A starting workspace is registered
before connection, so two files opened while initialization is pending share one
process. Different roots using the same language remain isolated. Lem's Lisp-v2
self/manual connections are the intentional exception: they retain global connection
selection, and newly opened or restarted Lisp buffers follow the selected connection.

Servers start in the project directory, and initialization options plus workspace
configuration are frozen from the originating buffer. Initialization has a 30-second
bound; detaching the final pending
buffer cancels its spinner, retry loop, timer, registry entry, and process. Dead cached
child processes are replaced as one project unit. File URIs percent-encode reserved and
Unicode path characters, preserve literal `+`, and reject non-file or remote-authority
URIs rather than treating them as local paths.

Disabling LSP or killing a buffer removes its request hooks, restores the prior
completion/xref/revert handlers, clears diagnostics and their timer, and sends one
`didClose` for the URI that was actually opened. Save-as, root changes, and language-mode
changes close the old document and rebind eligible buffers before further requests. An
empty ready workspace remains cached, matching Eglot's default
`eglot-autoshutdown=nil` policy. `lsp-restart-server` snapshots and reopens every live
buffer owned by only the current project; `lsp-shutdown-server` can also release an idle
project explicitly. Both paths remove registry state first, use a bounded `shutdown`
request, send `exit`, disconnect JSON-RPC, and unconditionally dispose the process.
Late initialization, diagnostics, completion, signature, xref, and highlight callbacks
must still match the ready workspace and originating buffer ownership before affecting
the editor.

`SPC p s` captures that project once and opens one `LSP Symbols:` prompt. It matches
Consult's configured asynchronous defaults: no request below three characters, a
200-millisecond quiet interval, and at most one request start per 500 milliseconds.
Every replacement query cancels the pending timer, removes an in-flight JSON-RPC
callback, sends `$/cancelRequest`, and advances a generation so even an uncancellable
late reply cannot replace newer results. Successful replies retain server order while
Prescient filters the symbol name, kind, container, and root-relative file annotation;
the popup also shows contiguous kind groups.

Because the pinned Consult default has no separate narrow-prefix key, entering one
case-sensitive kind key as the sole input and then pressing `Space` activates the
corresponding local filter before the real query.  The exact Consult-Eglot map is
`c/f/e/i/m/n/p/s/t/v`, `A/B/C/E/F/M/N/O/P/S`, and `o` for otherwise unmapped LSP
kinds.  The prompt shows the selected label, such as `[Function]` or `[Constant]`;
the prefix itself never reaches the server, and Backspace on an empty narrowed prompt
widens without closing it.

Focused rows preview their exact UTF-16-aware LSP position in the caller's window
without recording buffer history or a jump. Moving focus restores the caller first;
`C-g` and `Escape` restore its exact buffer, point, viewport, horizontal scroll, and Vi
state and dispose clean preview buffers. One Return preserves the search text in prompt
history, restores the caller, performs one ordinary final jump, recenters and highlights
it, and records both Lem's xref stack and the Vi jumplist for `C-o`. A server error leaves
the same prompt live. The captured
workspace remains authoritative while previews switch buffers, so incremental queries
cannot leak to another project.

This remains partial Consult-Eglot parity: Lem has one language workspace per invoking
buffer rather than Eglot's possible multi-server project aggregation, and its typed LSP
model discards the package's nonstandard optional score field. The final matched-line
highlight substitutes for the configured Pulsar reveal effect.

`scripts/lsp-project-test.sh` exercises the actual ncurses editor against a deterministic
Python stdio language server. It verifies pending-start deduplication and timeout,
cross-root isolation, save-as migration and mode-change detachment, notification
ownership, handler and diagnostic cleanup, stale diagnostic ownership, symbol error
recovery, minimum-input/debounce timing, annotations and kind groups, focused preview,
case-sensitive Function/Constant narrowing, empty-Backspace widening, exact abort
rollback, query history, one-Return navigation and `C-o`, explicit cancellation,
out-of-order stale-response rejection, project-stable incremental routing,
project-only restart, idle retention/reuse/explicit stop,
bounded shutdown with forced disposal, graceful exit on responsive paths,
old-process death, and editor-exit cleanup. Its main fixture subclasses the
same configured Eglot project spec, while static Go and Terraform buffers prove
their exact non-Git marker and buffer-directory fallbacks, project.el-style
submodule merging, and linked-worktree separation. Static contracts
cover exact and glob root markers, `.git/` directory fallback, filesystem-root
termination, safe URI conversion, spec-instance-stable keys, fileless guards, global Lisp-v2
connection selection/restart, and both leader states.

Nix follows the configured buffer-local Eglot settings shape: initialization options
remain null, while a frozen outer `nixd` map contains the flake-derived nixpkgs,
formatter, NixOS, and Home Manager expressions. Lem answers the server's real
`workspace/configuration` request by resolving the requested section from that map.
The installed-wrapper gate proves nixd requests `nixd`, receives that exact settings
object, remains live, and shuts down cleanly.

Java deliberately follows the current Emacs configuration's manual activation
policy. `lem-yath-java-spec` is registered without adding a Java mode hook, and
`M-x lem-yath-java-lsp` starts packaged JDTLS only in the selected Java buffer.
It sends the exact configured Google Java style URL and `enabled=true`, roots at
the nearest Maven, Gradle, settings, or Git marker, and gives each canonical
project root an isolated JDTLS data directory under
`$XDG_CACHE_HOME/lem-yath/jdtls/`. The real installed-wrapper gate proves that
opening Java alone creates no workspace, explicit activation completes a JDTLS
handshake with those initialization options, and normal project shutdown
releases ownership and the server process. `patches/lem-lsp-json-type-error.patch`
makes malformed server results catchable as errors; this is required because
JDTLS 1.52 returns an object instead of the protocol's null shutdown result.

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
identifier characters, matching Cape's explicit file trigger. Dabbrev also
matches the pinned Cape case policy: an initial-cap prefix capitalizes the
candidate, an all-caps prefix uppercases it, and a single uppercase character
does not accidentally uppercase the whole expansion.

`lem-yath/src/orderless.lisp` filters ordinary in-buffer candidates with the
configured portable Orderless behavior: escaped-space components, whole-query
smart case, any-order AND matching, overlapping and repeated components,
literal-or-valid-regexp matching, and the default `~`, `%`, `=`, `^`, `!`, and
`,` edge dispatchers. `%` performs directional Unicode character folding like
the pinned package: plain input can match diacritics, compatibility forms, and
the package's ASCII quote variants, while non-ASCII forms typed in the query are
not silently generalized. Filtering uses LSP
`filterText` while acceptance retains the original item's display, insertion
text, range, focus action, and final action.
The `M-Space` command inserts Corfu's separator, invalidates any pending request,
and freezes the last fully accepted provider batch. Further components are
filtered locally, so a space-separated query is never sent to LSP. A zero-match
view hides only the popup; Backspace can recover it, and deleting the final
separator resumes provider queries. Plain Space before separator activation still
ends ordinary completion. Prompt completion remains Vertico-Prescient, and file
completion remains path-aware.

Automatic contexts also reproduce Corfu's selected-candidate interaction.  An
ordinary initial preselection is accepted by `Tab` or `Return`; a same-case
exact candidate is moved to the front, while provider-valid input distinct from
the first candidate (such as a case-folded exact match) starts on a real prompt
row, where neither key can accept a hidden item. `C-n`/`C-p`, arrow keys,
beginning/end commands, and
`M-n`/`M-p` navigate without cycling. Moving off the preselection draws a
source-aligned, display-only preview: source text, point, modified tick, dirty
state, and retained undo history remain unchanged.
`C-a`/`Home` and `C-e`/`End` first restore the configured preselection at the
completion range boundary, then retain ordinary source-line motion when
already at that boundary. `C-v`/`PageDown` and `M-v`/`PageUp` move forward or
backward by the configured ten-row Corfu page without wrapping; the shared
prompt path uses Vertico's configured twenty-row page.
`M-h` promotes the selected provider's rendered documentation into an ordinary
split. `C-M-v` and `C-M-Shift-v` scroll that split by a windowful without
dismissing it, and `M-PageUp` is the ncurses-safe reverse alias because legacy
terminals collapse shifted control letters. A subsequent unrelated command
closes the information split and restores the still-live completion popup.
Typing, deletion, movement, ordinary Space, and electric/Paredit commands commit
that semantic selection before the command runs.  `M-Space` instead clears the
selection, inserts one separator, and refilters without accepting it.

`Escape` first returns a navigated selection to the preselection, next cancels
only edits made since the popup opened, and finally closes unchanged input.
`C-g` closes in one stage while retaining real typed input and never applies a
display-only preview.  The reset uses a pinned, undo-honest retained-history
change group; accepting completion still leaves one Vi insertion as one undo.
Public undo, redo, and tree movement refuse while that group owns the buffer;
replay bookkeeping is buffer-scoped, and a teardown that cannot close safely
preserves live text while resetting the compromised history fail-closed.
Teardown is exercised for async nil, movement, buffer switches, and source-window
deletion without deleting unrelated floating windows; resize instead
recomputes the owned preview. Buffer deletion and editor exit converge on the
same cleanup path.

Lem has no inline display overlay equivalent to Corfu's child-frame overlay.
The ncurses implementation therefore uses a borderless one-row floating window
and suppresses preview when a multiline or wrapped replacement cannot be shown
exactly. Completion specs expose a provider validity predicate over the complete
input and unfiltered candidate batch. Automatic completion uses that predicate
for Corfu's `preselect=valid`; absent or failing predicates fail closed instead
of inferring truth from insertion text. Configured non-file providers use
case-folded validity, while file validity remains case-sensitive as in Emacs on
the target Linux filesystem. Float ownership is verified in the target
single-frame ncurses frontend; multi-frame GUI ownership remains unverified.

This is deliberately an approximation rather than a full Orderless claim:
CL-PPCRE and Emacs use different regexp dialects. The pinned `&` annotation
style is intentionally minibuffer-only upstream; because the active Emacs
minibuffer pipeline is Vertico-Prescient, it has no effective configured path
and is not added as extra behavior to Lem's ordinary popup. Initialism parity is
verified for deterministic ASCII word boundaries rather than every Emacs syntax
table.

`scripts/auto-completion-test.sh` drives all of this through the ncurses editor,
including the delay boundary, physical prompt-boundary and ten-row page
controls, 12-candidate scrolling through a 10-row window, both non-cycling
edges, rapid-typing debounce, provider exclusivity, singleton
acceptance, whole-token and file-prefix replacement, non-mutating preview and
commit-before-command behavior (including movement and Paredit), exact-valid and
zero-match prompt rows, staged Escape and one-stage `C-g`, a real normal-state
Vi undo, preview geometry/layering, preview resize plus async cleanup, source-window
deletion, unrelated floating-window ownership, buffer-switch cleanup, and
out-of-order asynchronous delivery.
`scripts/orderless-completion-test.sh` separately exercises the matcher oracle,
including directional diacritic/compatibility folding and a real `%` popup,
raw-before-cap filtering, manual and automatic completion, local separator request
ownership, stale asynchronous delivery, zero-match recovery, tracked replacement
ranges, and prompt/file isolation through the real ncurses editor.

### Yasnippet-compatible expansion — `lem-yath/src/snippets.lisp` (verified subset)

The configured wrapper searches the repository's private snippets before the
exact flake-pinned `yasnippet-snippets` commit
`606ee926df6839243098de6d71332a697518cb86`. That collection contains 2,387
definitions. Every snippet file is still treated solely as data: a bounded
semantic translator recognizes exact, audited dynamic forms without invoking a
Lisp reader or evaluator. The corpus audit classifies 2,327 definitions as
supported and 60 as explicitly unavailable. The supported set includes 84
definitions that previously required dynamic behavior; arbitrary embedded
Emacs Lisp remains non-executable. The
configured private corpus contains one snippet, `org-mode/srcblock.snpt`; its
`jjs` trigger, `language` field, and final blank-line `$0` position are
reproduced exactly. Native `.org` buffers now select the same `org-mode` snippet
table directly; the filename mapping remains a deterministic fallback for table
selection.

The portable grammar covers simple and braced numbered fields (`$1`, `${1}`),
numbered defaults, anonymous `${default}` fields, nested fields and defaults,
repeated braced placeholders, simple mirrors, escaped syntax characters,
`${0:default}`, the final `$0`, and `$>` indentation markers. Mirrors update
while their owning field changes, including dependencies nested inside a
containing field. Field order follows Yasnippet's numbered, anonymous, then-zero
ordering, including its observed repeated-placeholder ownership rules.

Trusted file snippets additionally translate the pinned corpus's pure
date/time, user, filename/class-name, comment-delimiter, selection, UUID, C++
namespace, and Clojure namespace backquote forms. Pure field mirrors cover case
conversion, initial capitalization, class-name extraction, display-width
underlines, numeric increment, comma-list normalization, and the audited
C/C++/C# conditionals. Emacs character literals retain their payload during
allowlist canonicalization, including the significant `? ` space used by the
pinned Nix `package url` and `package github` comma-list mirrors. Six common
conditions reproduce the configured shell,
Go, and JavaScript comment-context behavior. Literal data-only
`yas-choose-value` forms accept either the pinned quoted string list or direct
string arguments and open a Prescient-filtered `Choose: ` prompt. The pinned
`yas-auto-next` wrapper advances from the initial choice field after expansion;
canceling the prompt leaves the trigger and buffer untouched. Choice expressions
are parsed with strict size and syntax bounds, and computed lists, extra forms,
newlines, and unknown escapes are refused rather than read or evaluated. Dynamic
values are escaped back into the structural renderer, so filenames, selected
text, or choices cannot inject fields. This policy is attached explicitly to
parsed local files; LSP templates use a separate literal policy.

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

Each field session retains up to 16 snapshots whose roots contain at most
1,048,576 characters, keyed by the stable undo-tree identity and node ID for
the corresponding buffer state. Undo or redo removes live overlays before
replay, then restores the captured root, fields, mirrors, selection, and edit
hooks only when both the node identity and resulting text match. This covers
undoing and redoing the expansion itself as well as edits inside a live field;
restored mirrors continue to update through Vi Normal/Insert transitions. It
reproduces the configured `yas-snippet-revival t` path without placing mutable
editor objects in undo history or retaining unbounded snapshots.

`M-x lem-yath-insert-snippet` exposes the active portable templates without
requiring a trigger. Its Prescient-filtered labels include the template name,
trigger, and source table; choosing one inserts it at point and starts the same
field session used by trigger expansion.

### LSP completion snippets — `lem-yath/src/lsp-snippets.lisp` (verified subset)

The configured Emacs 31/Eglot path advertises snippet support and passes an
accepted LSP snippet directly to Yasnippet. Lem-yath mirrors that path safely:
format 2 is detected independently of the candidate kind, `TextEdit.newText`
or `InsertReplaceEdit.newText` retains precedence over `insertText`, the full
replace range is tracked through popup filtering, and final acceptance installs
the ordinary data-only field session only after the popup closes. Format 1 and
omitted formats remain literal completion text. If the handler is unavailable,
the capability is false and an unexpected snippet item is rejected rather than
inserting raw `${...}` syntax.

This covers the Eglot/Yasnippet behavior used in the profile: numbered fields,
defaults, nesting, mirrors, `$0`, field navigation, automatic Yas-style
indentation, and the existing completion/Vi/Paredit precedence. It also retains
the profile's observable direct-Yas treatment of `${TM_FILENAME}` and
`${1|one,two|}` as editable literal fields rather than pretending that they are
TextMate variables or choices. The intentional security difference is that
paired backquotes from a language server are inserted literally; they are never
evaluated as Emacs Lisp.

Snippet rendering finishes before any primary or additional buffer mutation.
Acceptance-time resolve imports only `additionalTextEdits`, because LSP forbids
changing the original sorting, filtering, and insertion properties during
resolve. Additional edit text is always literal, ranges before and after a
length-changing primary edit remain stable, and invalid or overlapping batches
are ignored as a unit. Resolve failure likewise leaves the original primary
completion usable.

This is not full LSP TextMate grammar support. Standard variables, choices,
variable transforms, and strict LSP escaping remain explicit gaps.
Focus-resolved documentation, CompletionList item defaults, `insertTextMode`,
and completion commands are not effective in the configured Eglot/Corfu path
and are therefore not parity requirements.
Malformed payloads are parsed before mutation; an invalid item does not discard
valid siblings, and a rejected accepted item leaves the completion prefix
unchanged.
`nix run .#lsp-snippet-test` verifies `insertText`, `TextEdit`, the
`InsertReplaceEdit.replace` path, direct and resolved additional edits on both
sides of the primary range, literal `$1` additional text, one-step undo,
invalid/overlap rejection, deferred exact-once resolve, original-primary
preservation, exact text/point/history rollback after a nested throwing mutation
hook, UTF-8/16/32 conversion and split-unit rejection, originating workspace
use, adjacent generic edits, diagnostic/navigation ranges, literal plain-format
markers, mirrors and field exit, Tab/Return acceptance, multiple-candidate
non-insertion, malformed recovery, bounded capability advertising, exact-once
callbacks, JSON-RPC timeout cleanup, and inert server-supplied backquotes through
the real ncurses editor.

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

This is not full Yasnippet parity. The remaining 60 definitions comprise 18
DIX-specific conditions, five unsupported or malformed backquote cases, and 37
side-effecting, embedded, or mode-specific field transforms. The pinned
corpus contains no command snippets. Active sessions do not stack because the
profile retains Yasnippet's `yas-triggers-in-field nil` default, and direct
snippet key bindings are not installed because the profile configures none.
Strict TextMate snippet grammar is not implemented. The file-snippet TUI gate
is `nix run .#snippet-test`; it drives the private snippet, portable field
grammar, bounded dynamic forms, exact corpus audit, the Prescient selector,
literal choice selection, cancellation, automatic initial-field advance,
fail-closed computed choices, navigation and editing keys,
completion/Vi/Paredit precedence,
indentation, lifecycle cleanup, expansion and field-edit undo/redo revival, and
a real pinned Python community snippet
through the ncurses editor.

### consult-like commands (verified)

- `M-x`: `execute-command` (bound `M-x`); command completion via `completion-command`
  (`prompt.lisp:151`).
- Find file: `lem:find-file` (`C-x C-f`).
- Buffer switch: `select-buffer` (`C-x b`), while `C-x C-b` invokes
  `lem-yath-list-buffers` (`src/buffer-list.lisp`). It partitions the native
  marked multi-column chooser in the configured exclusive first-match
  org/tramp/emacs/ediff/dired/terminal/help order, hides empty groups, preserves
  recency within each group, and appends unmatched buffers as `Default`.
  Distinct `[ name ]` headings collapse to `[ name ... ]` with Return and are
  excluded from buffer actions. Fuzzy narrowing temporarily displays only
  matching selectable buffers. The default rows preserve mark, modified and
  read-only status and live `L` lock state, 18-cell elided name, 9-cell
  right-aligned size, 16-cell elided mode, and filename. The pinned Ibuffer
  Evil-Collection controls select name, recency, size, filename, or major-mode
  sorting with `o a/v/s/f/m`, reverse with `o i`, traverse the lexical sorter cycle with
  comma, and switch between the detailed and compact name/file formats with
  backtick. Sorting preserves group order, headings, marks, and narrowing.
  `s m/n/f/b/.` enter live case-insensitive regexp filters for used mode, name,
  full filename, basename, or extension; Return pushes the pending filter and
  Escape cancels it. The modal operation core uses `m/u/Backspace/U/t/~` for ordinary marks,
  distinct `d` deletion marks followed by `x`, and `S` for marked saves;
  `L` toggles GNU Emacs's default `all` lock on ordinary-marked buffers or the
  current row, `% L` marks locked rows, and locked buffers refuse deletion and
  editor exit before any teardown mutation;
  `* *`/`* s`, `* m`, `* u`, `* r`, `* /`, `* e`, `* h`, and `* z` mark
  visible special, modified, unsaved, read-only, directory, dissociated, help,
  or compressed-file buffers; `.` marks buffers last displayed strictly more
  than the configurable 72-hour default ago while leaving never-displayed
  buffers unmarked;
  `{`/`}` cycle ordinary marks, `M/T/R` change marked modified/read-only/name
  state, and `X` buries the focused buffer while retaining its row;
  `gj/gk`, Tab/backtab, `C-j/C-k`, `]]/[[`, and `q` provide row movement, group
  movement, and quit. `M-j` completes over the displayed group headings and
  focuses one without changing its collapsed state. `C-o` displays the focused
  buffer in another ordinary window while the chooser remains selected; `M-o`
  visits it and removes other ordinary windows. `A`/`gv` display ordinary marks
  in balanced stacked windows and `gV` displays them side by side, excluding
  `D` and using the current row when nothing is ordinarily marked. `gR`
  redisplays the existing snapshot, `gr` rebuilds it
  from live buffers while preserving applicable marks and filters, `yb/yf`
  copy exact buffer/file names, and `go` visits in another ordinary window.
  `-`/`+` stage session-local hide/force-show name regexps; they remain pending
  through `gR` and activate on `gr`, with force-show precedence over hiding and
  ordinary filters. `K` hides visible ordinary-marked rows through `gR`; `gr`
  restores them unmarked and retains unrelated deletion marks.
  `s RET` selects one or more exact registered major modes, `s M` includes
  CLOS parent modes represented in the snapshot, `s *` selects GNU-style
  starred names, `s </>` apply strict character-size filters, and `s c`
  applies a case-insensitive content regexp. `s i/v` push modified and
  visiting-file filters onto an AND stack, while `s !`, `s p`, and `s /`
  negate the top, pop the top, or disable all filters. Control-character-safe
  display remains available.
  The real TUI verifies classification, ordering, every bound sorter, reversal,
  cycling, both formats, empty-group omission, heading collapse/expansion and
  safety, regexp filter input across modal command letters, stock field widths
  including wide characters, selection, every modal movement above, ordinary
  and deletion mark rendering, backward unmark and ordinary-mark traversal,
  all eight non-prompt starred mark predicates with hidden-row exclusion,
  exact used-mode and name/displayed-mode/file/bounded-content regexp marking,
  exact and derived multi-mode completion, live-process and file/working-directory
  filters, starred-name, strict-size, and bounded content filters including
  invalid-regexp refusal, filter
  composition/negation/pop/disable, marked save/deletion/state changes,
  Emacs-style unique renaming, one-confirmation `V` reversion of ordinary marks
  or the implicitly marked current row, deletion-mark exclusion, safe
  continuation after a per-buffer revert failure, focused burying, snapshot redisplay/update,
  exact name/path copying,
  selected and no-select alternate-window visits, one-window visits, group-name
  completion, stacked and side-by-side marked-buffer layouts with current-row
  fallback, exact snapshot completion and collapsed-group reveal on `J`/`M-g`,
  focused bounded `=` diffs for ordinary marks or the
  unmarked current row, and reload. Diff selection excludes `D` and non-file
  buffers; missing files fail before replacing the prior read-only patch view.
  `O` and `M-s a C-o` add bounded GNU-style marked-buffer Occur: ordinary marks
  are searched in reverse display order, `D` is excluded, and an unmarked
  current row receives GNU's persistent implicit mark. Smart-case, multiline
  CL-PPCRE patterns and nonnegative numeric context render into a persistent,
  read-only `*Occur*` without selecting it. Same-line matches share one
  navigation block, context ranges merge with separators, and control and
  Unicode format characters are escaped. Return/`C-c C-c`/Shift-Return/`g o`
  visit a live source point; `M-Return` displays it without selection;
  `gj/gk`, `C-j/C-k`, and `n/p` traverse and preview blocks. Invalid regexps
  retain the previous result, zero matches remove it, source edits move retained
  targets, and killed sources fail closed. Scanning is capped at 16 million
  characters per buffer and 64 million total, 10,000 matches, and 2 MiB of
  output. `i` and `C-x C-q` enter row-scoped Occur Edit. Vi insertion/deletion
  and native undo update the exact live source line transactionally; protected
  headings, prefixes and row boundaries, newline-created rows, read-only
  sources, and source-hook rejection fail before divergence. Control-safe rows
  decode on write-through, and collapsed empty rows remain writable with `A`.
  `C-x C-q`, `C-c C-c`, `ZZ`, and `ZQ` cease editing. `r` derives a name from
  the live sources, and `c` rescans them into an independently owned clone with
  separate navigation and edit markers.
  The effective Evil Collection `M-s a C-s` and `M-s a M-C-s` chords start
  literal or regexp incremental search over explicit ordinary marks in display
  order, excluding `D`, and refuse an empty marked set. Input pauses in the
  first source; `C-s`/`C-r` continue and wrap across live sources. Return keeps
  the exact match and records same-kind history, while `C-g` restores the first
  source's starting point; either exit removes transient search modes from all
  sources.
  Evil Collection's `Q` and `I` run smart-case literal or regexp
  query-replace over ordinary marks in display order, with `D` exclusion and
  the ordinary implicit-current fallback. The floating chooser is hidden while
  each target is queried from its beginning and is rebuilt afterward with its
  source window, point, focus, filters, and marks intact. `y`/Space replaces,
  `n`/Backspace skips, `!` replaces the rest of the current buffer without
  leaking into the next, `q`/Return advances, and `.` replaces once before
  advancing. `,` replaces without advancing; `^` backs up; `u`/`U` undo the
  latest/all live replacements; and `e`/`E` edit the current replacement with
  transferred/exact case. `d` displays a bounded, read-only whole-buffer
  replacement diff without advancing or moving source focus. `C-r` enters an
  ordinary recursive edit at the live occurrence; `C-w` deletes the occurrence
  first for manual replacement, and `C-M-c` resumes the query at the same
  occurrence. Live markers preserve edited regexp captures, `C-w` is uncounted,
  and the prior window layout is restored. Each affected target has one undo
  unit, including recursive and in-loop edits. Lowercase searches
  fold case and transfer lower,
  all-caps, or initial-cap patterns; unescaped uppercase searches are
  case-sensitive and retain exact replacement case. Regexp replacement expands
  `\&`, `\1`–`\9`, `\\`, and a per-buffer `\#` count. Unescaped `\?`
  removes its marker and prompts at that position for a per-match edit before
  expansion and case transfer; escaped `\\?` remains literal. Zero-width
  matches make GNU-style progress. Read-only target sets and invalid regexps or
  replacement directives fail before mutation.
  Ibuffer's arbitrary Emacs-Lisp predicate filters, other-frame, view-and-eval,
  shell, eval, and print operations are not reproduced.
  Marked-buffer regexp query-replace omits GNU Lisp-evaluated `\,`
  replacements.
  CL-PPCRE regexp syntax can differ from Emacs regexp syntax. Content filters
  skip buffers above 16 million characters, and mode completion uses
  package-qualified labels.
  Multi-buffer `V` uses GNU Ibuffer's exact
  count prompt without its auxiliary confirmation-name window. The diff view
  uses concise buffer headings rather than GNU Emacs's shell-command
  transcript and adds 10-second, 16-million-character input, and 2-MiB output
  bounds.
- Recent files: `M-g r` opens an annotated Lem persistent-MRU prompt after
  lem-yath sets the loaded
  history's 300-entry limit and normalizes oversized persisted histories to their
  newest 300 entries. Fresh-process TUI tests verify trimming, capping,
  deduplication, move-to-front, persistence, file metadata, and opening.

### Configured persistence and safe external changes (verified)

`lem-yath/src/file-notify.lisp` and `lem-yath/src/persistence.lisp` replace
pinned Lem's unsafe current-buffer pre-command reverter with bounded Linux
inotify watches shared by parent directory. Ordinary local file changes are
delivered to Lem's editor thread promptly, including same-metadata rewrites and
delete/recreate or atomic-replacement events. Each notification verifies a full
content digest before reloading. Matching the configured Emacs default
(`auto-revert-avoid-polling` remains nil), a reload-owned regular timer also
keeps the global five-second safety scan; symlinks, watch allocation failures,
invalidated directories, non-Linux hosts, and explicit non-file adapters rely
on that scan exclusively. The same throttled
scanner remains on pre-command and buffer-selection paths as a latency and
safety fallback. Notification descriptors, threads, file ownership, and shared
directory watches are released on buffer kill, Save As, configuration reload,
reader failure, and editor exit. Timer callbacks and notification deliveries
execute on Lem's editor thread, and stale callbacks from a source reload lose
ownership before they can touch a buffer. Clean, readable file buffers reload
transactionally after verified changes; periodic checks digest the current or
explicitly selected buffer up to 16 MiB. Dirty, deleted, unreadable, and
failed-decode buffers retain their live text. Transactional reload snapshots are
capped at 64 MiB so a huge or sparse file cannot force an editor-sized allocation;
larger changed files are retained for deliberate external handling. A before-save guard asks before a
dirty buffer overwrites a changed disk version. The accompanying pinned-source
patch stages decoded replacement text before touching the live buffer, makes
custom LSP-style manual reverts respect dirty-buffer confirmation, and asks
before user-facing single/project buffer kills. Save As asks before replacing
any existing target, including an unvisited file, and MCP deletion refuses a
modified buffer instead of discarding it remotely.

The profile also keeps the configured Emacs no-auto-write policy complete on
the refreshed fork: Lem auto-save and crash-recovery checkpoint modes are off,
and terminating-signal emergency checkpoints respect that opt-out. Editing,
idle waits, and SIGHUP teardown therefore create no backup, lock, auto-save, or
checkpoint sidecars.

The same module writes `(lem-home)/state/persistence.sexp` through an
exclusively created same-directory temporary file under an interprocess lock.
The directory is mode `0700`; state, lock, and temporary files are `0600` from
creation. Reads bind `*read-eval*` to false, accept exactly one aggregate
byte-bounded, versioned form from one descriptor, reject dispatch/evaluation syntax
before invoking the Common Lisp reader, and normalize bounded containers in linear
time. Each flush merges state already written by another Lem process.
Places and history categories use the last state actually applied to the live
process as a three-way baseline: independent additions are retained, unchanged
local entries follow newer disk updates or removals, and a stale process cannot
resurrect a cleared place, prompt, search, or kill entry. The live kill ring is
not rebuilt during a flush, so yank-pop rotation remains undisturbed.
It provides:

- up to 600 canonical local-file positions or exact selected directory entries,
  excluding point one and transient VCS commit-message files. Directory entry
  identity restores only on the first visit to a fresh buffer, so later buffer
  switches retain its live point; a missing entry leaves the normal initial row;
- a 120-entry live kill ring with the newest 40 entries persisted, retaining
  `:vi-line` and `:vi-block` paste semantics and suppressing only consecutive
  duplicates with identical semantics;
- distinct 16-entry literal and regexp rings on `C-s`/`C-r` and
  `C-M-s`/`C-M-r`, with `M-p`/`M-n` navigation inside isearch;
- live prompt histories capped at 100 and a default-deny persistence allowlist
  of reviewed navigation/query histories. The shared unnamed bucket, SQL,
  connection strings, compile commands, and unknown future names remain
  memory-only.

`scripts/persistence-test.sh` drives real ncurses processes and external file
writers. Its 55 checks include no-input periodic file and directory refresh,
retention of a directory selection, cursor column, and marks, and a fresh-process
selected-directory-entry round trip. They cover clean and
dirty reload behavior,
deletion/recreation, stale-save refusal including a same-metadata 17 MiB file,
first-save and late-target Save As races, modified quit refusal, fresh-process
restoration and Vi paste behavior, prompt privacy/live caps, bounded malformed
and dispatch/evaluation-free state reads, private file modes, failure-safe
commands/exit, reload-safe timer ownership, stale concurrent additions, and a
clear-then-stale-write sequence across three editor processes for every shared
place/history category.
Filesystem notifications and adapters for Lem's other non-file list buffers
remain gaps; the module exposes a buffer-local stale/revert adapter contract for
those modes.

### Retained undo tree and Vundo — `patches/lem-undo-tree.patch`, `patches/lem-undo-state-point.patch`, `lem-yath/src/vundo.lisp` (verified approximation)

The pinned-core patch replaces destructive linear redo history with a retained
branching tree. Ordinary `u` and `C-r` still work, but a new edit after undo now
creates another branch and records the branch most recently traversed as the
preferred redo path. The public snapshot and movement API uses generation-tagged
opaque node references, validates the complete route before replay, preserves
read-only state, and fails closed to a truthful dirty root if a mutating hook
invalidates the replay. Reload deliberately reroots history. Save identity,
generic clean state, and the monotonic mutation tick are tracked separately so
no-op edits, external reloads, saved-node navigation, and stale references do
not silently corrupt the graph.

Each retained state also records its source point. The first retained edit in a
pre-existing buffer initializes the root at that edit's starting position, and
each new child records the post-command point at its undo boundary. Ordinary
undo/redo and Vundo preview restore that clamped historical position; edits
deliberately excluded from undo transform the stored positions across every
retained branch along with their edit offsets.

The configured Emacs limits of 2,080,000 / 3,120,000 / 48,000,000 are retained,
but measure copied UTF-8 edit payload rather than Emacs heap allocation. Lem also
bounds history at 65,536 nodes and 262,144 edits and caps one validated movement
route at 128 MiB of UTF-8 work. Every ordinary undo/redo and Vundo preview
preflights its required return route before changing the live buffer. Pruning
keeps the current and newly protected command reachable while removing old
leaves; a pruned clean or saved node is cleared, and the latest surviving actual
save is recomputed.

Normal- and visual-state `SPC u` open a three-row Unicode tree in a bottom pane.
The source buffer previews the selected node live; `f`/Right and `b`/Left move
to a child and parent, `n`/Down and `p`/Up move among siblings, `a`/`w`/`e`
traverse stems, and `l`/`r` follow Vundo's saved-node chronology across branches.
The linear, sibling, and saved-node motions accept Evil numeric counts with the
same edge-clamping and unavailable-save refusal behavior as Vundo 2.4.
`m`/`u`/`d`, `C-x C-s`, `q`/`C-g`, and Return cover marking/diffing, saving,
rollback, and acceptance. A displaced bottom pane survives both delayed leader
help and Vundo with its geometry, point, view, cursor, and horizontal scroll.
Diff inputs are exclusively created mode-0600 files, invoked through an argv
list under a timeout, size-capped, and removed on every exit path.

`scripts/vundo-test.sh` exercises the real ncurses editor, including branch
retention and preferred redo, all public movement families, Unicode rendering,
distant point/view restoration, Emacs-oracle state-point restoration and
untracked-edit transformation, clean versus saved nodes, diff cleanup, save,
reload, killed windows and buffers, wide-tree pruning, mutating hooks,
stale-reference rejection, asymmetric route refusal, after-save descendants,
direct and re-entrant teardown, prior bottom panes, and read-only failures.
Vundo's internal debug keys `i`/`D` are not implemented.
Copilot-style paths do not yet use the constrained retained-undo change-group
API, so their intermediate transactions remain in history.

- Find by name: `M-s f` (`lem-yath/src/find-name.lisp`) prompts for a root and
  wildcard, runs GNU find asynchronously with a NUL-delimited argv-safe protocol,
  and fills a persistent read-only `*Find*` buffer. Exact path properties make
  Vi Return safe for spaces, semicolons, literal `*`, `?`, and `[`, and displayed
  control characters; q leaves the result buffer available. Dired-style `m`
  and `u` mark or unmark and advance, `U` clears every mark, and `t` toggles
  all result marks. A fresh search clears marks; `g` retains exact-path marks
  that still exist in the refreshed result set. `C`, `R`, and `D` copy,
  rename, or delete the marked set (falling back to the current row), with
  exact argv path handling, collision prompts, result refreshes, and Dired's
  per-top-level confirmations for recursive directory copies and non-empty
  directory deletion. Through the shared presentation in
  `lem-yath/src/dirvish.lisp`, each result also matches the pinned Dirvish
  defaults by rendering a display-only, six-cell file-size field at the right
  edge; directories
  show their direct child count, and resizing recomputes alignment without
  changing result-buffer text. Dired's wider operation surface remains absent.
  While a search is running,
  `C-c C-k` terminates only the subprocess owned by that `*Find*` request and
  leaves a persistent cancelled result buffer that can be retried with `g`.
- Grep: upstream `lem/grep:grep` and `lem/grep:project-grep` live in
  `src/ext/grep.lisp`. The configured global `M-s g` prompts with the exact
  `rg -nS --no-heading ` default, then prompts for a directory and honors
  ripgrep's smart-case and ignore-file behavior. The configured
  `C-x p g`/`SPC p g` route is `lem-yath-project-grep` in `src/project.lisp`;
  it instead searches the project's exact tracked-plus-untracked file set on
  a cancellable worker. Both routes share the same read-only result UI. Normal
  `i` (the effective Evil-Collection grep binding) or `C-c C-p` starts an isolated
  editable stage and highlights changed rows without mutating their sources.
  `ZZ`, Evil-Collection `:w`, `C-c C-c`/`C-c C-e`, or `C-x C-s` applies
  non-stale rows to source buffers without saving; `ZQ`/`C-c C-k` aborts, while
  `C-x C-q` and normal-state Escape
  use wgrep's apply-or-discard exit. Each source file is one cancellable change
  group, and changed-after-grep rows are rejected visibly rather than overwritten.
  Ordinary source-buffer save remains the persistence step. The real ncurses
  gates verify the global command and directory prompts, smart case, ignores,
  no-match and invalid-regexp recovery, Normal-state entry, navigation,
  cancellation, stage isolation, atomic multiline refusal, single-Escape return
  to Normal, apply, abort, save, and stale-source refusal.
  `patches/lem-grep-writeback.patch` still supplies the
  point-preserving replacement primitive, and
  `patches/lem-peek-source-timer.patch` owns and invalidates preview timers.
  Editable headers/newlines, whole-row deletion, region unmarking, multiline
  replacement, auto-save, and per-row error echo remain outside this bounded port.

### Project-aware finding — `src/commands/project.lisp`
`project-find-file` (`C-x p f`), `project-switch` (`C-x p p`), `project-root-directory`
(`C-x p d`), `project-grep`, `project-save`/`project-unsave`. Root markers:
`*root-directories*` = `.git .hg _FOSSIL_ .bzr _darcs`; `*root-files*` =
`.project .projectile Makefile configure.ac TAGS …` (`project.lisp:31-53`). `find-root`
walks up to the project root. Saved projects persisted to `(lem-home)/history/projects`.

`lem-yath/src/project-history.lisp` replaces that file's single-process writer
with an owner-validated, bounded reader and mode-0600 atomic replacement under
in-process and OS-released interprocess locks. Every automatic or stock
`project-save`/`project-unsave` mutation starts from the latest disk state;
concurrent additions retain both roots, MRU promotion remains deterministic,
and a later stale writer cannot resurrect a root another editor removed. If the
file becomes malformed or symlinked, read-only UI retains its last known-good
list while mutations refuse the unsafe storage without replacing it.

The configured editor replaces the high-frequency upstream commands in
`lem-yath/src/project.lisp`. Git roots (including initialized submodules and
linked worktrees whose `.git` marker is a file) are
canonicalized and automatically recorded in the same persistent history.
`SPC p f` uses NUL-safe `git ls-files` data for tracked and untracked files;
`SPC p g` converts Emacs regexp syntax and runs bounded ripgrep batches over
that exact file set on a request-owned, cancellable worker thread. Canonical
containment and visited-root tracking bound malformed or cyclic submodules.
`SPC p p` also offers an arbitrary directory and the audited `f/g/d/v/e/o`
project dispatch. `f`, `g`, and `d` find a file, regexp, or directory; `v`
opens Git status through Legit at the selected root even in a colocated jj
workspace. `e` creates a Lem terminal at that root and `o` invokes Lem's
M-x-style command prompt with that root as the buffer directory. Those last two
preserve the useful dispatch and working-directory behavior but remain
approximations of Emacs `project-eshell` and `project-any-command`.
`lem-yath/src/project-picker.lisp` makes `SPC SPC` a grouped Project
Buffer/File/Root picker. Buffer membership uses each buffer's lexical directory,
so compilation, terminal, and REPL-style buffers participate without
sibling-prefix or symlink-alias leakage; recent files and saved roots retain
their source identity even when labels collide. The picker supports `b/f/r
Space` source narrowing, empty-Backspace widening, `M-{`/`M-}` group rotation,
and preview-on-move with exact point, view, and horizontal-scroll rollback on
no match or abort. Unopened-file previews use raw UTF-8 text in unlisted
temporary buffers, avoid file/mode/switch/kill hooks, and skip undecodable,
binary, or over-1-MiB files; ordinary window-display hooks can still run. They
deliberately do not activate major
modes because Lem has no generic isolated activation path: arbitrary mode hooks
and unrelated native or service state could otherwise leak from a preview.
The two-process ncurses gate is `scripts/project-navigation-test.sh`; it also
forces overlapping cancellation, hostile submodule fixtures, grouped picker
lifecycle/identity cases, lexical symlinks, and filtering beyond the display
cap. File and buffer candidates carry the bounded metadata described above.

### Completion UI config
`*prompt-buffer-completion-function*`, `*prompt-file-completion-function*`,
`*prompt-command-completion-function*` (`prompt.lisp:9-11`) can be overridden.
In-buffer completion popup: `src/ext/completion-mode.lisp` (`lem/completion-mode`).

### Daily editing workflows — `scripts/daily-workflows-test.sh` (verified)

`M-j` now follows Emacs `duplicate-dwim` for current lines and contiguous active
regions. The ncurses suite checks the otherwise easy-to-miss unterminated-EOF
newline rule against Emacs, point retention at EOF, one-step undo, forward and
reverse Vi character selections, V-LINE state, and Paredit's mode-local structural
override. It also reproduces the pinned Emacs/Evil V-BLOCK quirk: because Evil
does not enable `rectangle-mark-mode` or an ordinary active region, `M-j`
duplicates the active cursor line, keeps V-BLOCK live, and lets the opposite
corner track inserted text.

### GNU rectangle editing — `scripts/rectangle-test.sh` (verified)

`C-x SPC` starts a separate buffer-local rectangle mark, preserves virtual
columns across uneven lines, and paints each nonempty visible row. `C-n`,
`C-p`, arrows, and `C-x C-x` retain rectangular corner geometry; ordinary edits
deactivate the mark as in Emacs. The stock rectangle surface used by this
configuration is present on `C-x r`: kill, copy, delete, clear, open, prompted
string replacement, safe integer numbering, and multiline yank. Operations
precompute every row before mutation, coerce tab or wide-character boundary
cells to spaces, honor prefix fill behavior on short lines, and refuse embedded
newlines or unsafe number formats before editing. Mutations use the retained
undo change-group API, so a throwing buffer hook restores the complete prior
text and history even after an earlier row changed. Rectangle `M-j` duplicates
every row to the right with its count, preserves both corners and the mark, and
undoes in one step.

The focused gate compares exact text, point, corner, padded-kill, numbering,
tab-boundary, and short-line results with the pinned Emacs oracle, then drives
physical `C-x SPC`, movement, counted `M-j`, undo, `C-x r k`, and the editable
`C-x r t` prompt through ncurses. Evil retains priority for its normal-state
`C-o`/`C-t`, exactly as in the configured Emacs; open and string rectangle stay
available on `C-x r o`/`t`. A terminal row with zero width or entirely beyond
EOL cannot show a region face, although its virtual geometry and subsequent
edits are retained. Lem also lacks Emacs's live string-rectangle minibuffer
preview; submission and cancellation remain transactional.

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

Pair discovery uses each buffer's syntax table, supplemented by Emacs's Unicode
single- and double-smart-quote pairs. Openers insert their matching closer,
escaped quotes remain literal, and an unmatched matching closer later in the
buffer is reused. The preserve-balance scan crosses intervening balanced forms,
stops at the first genuine mismatched closer, ignores string/comment decoys
from code, and maintains independent balance inside those text containers.
Typing a closer advances over it. Numeric prefixes, odd/even escapes, balanced
adjacent pairs, syntax-safe whitespace/newline skipping, prompt queries, and
Lisp completion/Paredit dispatch are covered as well. Special delimiter input
closes an ordinary in-buffer completion popup without stale state, while prompt
completion refreshes in place.

Physical Backspace immediately between a recognized pair preflights the complete
range and removes both sides within one editor command, regardless of whether
they were auto-inserted or escaped. A signed prefix removes its magnitude on
each side after checking both bounds. A positive prefix puts the backward half
in the kill ring; a negative prefix puts the forward half there, and both undo
to the original between-pair point like Emacs.
The syntax table keeps Python `''` paired while Fundamental mode treats it as
ordinary text. The behavior is active in Emacs editing and Vi insert state,
including completion prompts and active snippet fields with mirror updates.
Forward Delete and Vi normal, visual, and replace states retain their own
commands. A zero-width active mark or one-delimiter selection removes its full
pair, broader selections keep ordinary delete-selection behavior, and one undo
restores the deletion.
The real ncurses suites cover completion refresh, prompt refresh after paired
deletion, one-sided read-only preflight, Paredit protection for nonempty forms,
and snippet mirrors as well as Fundamental, Python, and Lisp buffers.

The remaining intentional approximation is active-selection behavior wider
than one delimiter: Lem deletes exactly the selection, while Emacs can also
consume an unselected adjacent delimiter depending on orientation, a
destructive quirk Lem deliberately does not reproduce.
Pair deletion deliberately preflights the complete range instead of reproducing
Emacs's partial mutation when a bound or one character's read-only property
fails. The two removals remain separately visible to change hooks. For a
selected Lisp form containing an unmatched embedded quote, Lem
escapes the quote to keep the new string valid; configured Lispy leaves that
interior quote raw, so this is an intentional semantic improvement.

### EditorConfig policy and Apheleia-style formatting — `lem-yath/src/editorconfig.lisp`, `lem-yath/src/formatting.lisp` (verified subset)

Lem-yath delegates EditorConfig matching, `root` handling, hierarchy, and
`unset` resolution to the official `editorconfig` CLI instead of implementing a
second parser. The CLI is invoked with a direct argument vector under a
five-second GNU `timeout`. At steady state, every absolute local file buffer is
resolved after find-file, re-resolved after filename or major-mode changes, and
queried again before save; buffer switches perform a cheap stale-state check.
The EditorConfig hook refreshes properties without changing text, then the
formatting save hook owns transactional ws-butler and EditorConfig text
normalization for mapped, unmapped, programming, and prose buffers alike.
This scope is deliberately broader than programming buffers. An error retains
the last successfully applied state rather than partially reverting it.

The mapped properties are `indent_style`, `indent_size`, `tab_width`,
`end_of_line` (`lf`, `cr`, or `crlf`), `charset` (`utf-8`, `utf-8-bom`,
`latin1`, `utf-16be`, or `utf-16le`), positive or `off` `max_line_length`,
`trim_trailing_whitespace`, and `insert_final_newline`. Indentation, encoding,
and fill-column baselines are restored before newly resolved properties are
applied, so a closer file can remove an inherited setting without leaving stale
buffer-local state. Charset runs after Lem has decoded an opened file and
therefore controls subsequent writes only; UTF-16BE/LE output intentionally has
no BOM. `insert_final_newline=true` adds a newline to a nonempty buffer, while
false or absent never removes one. `trim_trailing_whitespace=true` cleans every
line; false or absent retains ws-butler's touched-line policy for programming
buffers inside the same save transaction.

The formatter registry currently has these finite built-in mappings:

| Lem mode family | Backend selection |
|---|---|
| Python | `black --quiet --stdin-filename FILE -` |
| Rust | `rustfmt --quiet --emit stdout` |
| Go | `gofmt` |
| Nix | first available of `nixfmt-rfc-style`, `nixfmt`, or `alejandra` |
| C | `clang-format -assume-filename FILE` |
| TypeScript, JSON, JavaScript | project-local `node_modules/.bin/prettier`, then `prettier` on `PATH`, with the buffer's tab policy |
| Java | `google-java-format -` |
| Clojure | `cljfmt fix -` |
| Terraform | first available of `tofu` or `terraform`, then `fmt -` |
| Zig | `zig fmt --stdin` |
| Lua | `stylua -` |
| Common Lisp | in-process `indent-buffer` in a temporary buffer |

The packaged core runtime supplies Black, rustfmt, gofmt, nixfmt-rfc-style,
clang-format, and google-java-format; the remaining external mappings activate
when their executable is available. External backends receive the unsaved
buffer through stdin, run in the buffer directory with direct argv boundaries
and a ten-second timeout, and reject stdout beyond the configured result limit.
Changes are applied as diff hunks while keeping point, mark, and visible window
points stable. All formatter
hunk ranges, ordering, overlap, bounds, and local read-only properties are
preflighted before the first live edit. Save normalization runs inside the
retained transaction, so a later read-only conflict replays its earlier edits
rather than exposing a partial result.

`SPC b f` invokes the mapped CLI or in-process backend without saving. If no
mapped backend is usable, manual formatting may use a ready, current LSP
workspace that advertises document formatting. A CLI which starts and then
fails does not fall back to LSP. For a mapped programming file, the normal save
hook instead formats synchronously before the ordinary write when its backend is
available. A successful result is normalized through ws-butler and EditorConfig,
then reaches disk through that one write before LSP `didSave`. Automatic
formatting never falls back to LSP, and
a CLI launch, timeout, output-limit, or nonzero-exit failure applies no formatter
output; ordinary transactional ws-butler and EditorConfig normalization still
runs before the save. Applying the successful diff and the subsequent save
normalization is one retained change group. A throwing
change observer or normalization error cancels every edit, delivers ordinary
inverse change notifications to hook-backed consumers, and restores registered
points, active mark, modified state, and pre-existing undo/redo routes. The core
records a completed primitive before dispatching its after-change hooks, so
recursive same-buffer hook edits retain chronological undo order even when a
later hook throws. If cancellation itself fails, the uncertain live result is
left visibly dirty, its dishonest history is truncated, and the ordinary save is
aborted. A safe formatter or finalizer failure discards formatter output, then
retries only transactional save normalization before continuing the ordinary
save. If that normalization also fails safely, ws-butler's touched-line markers
remain pending across the save and next edit epoch until a later save completes
normalization successfully.
Unmapped programming modes, unavailable backends, and prose do not format
automatically.

This is not the asynchronous Apheleia execution model. There is no formatter
prompt or Apheleia-compatible per-project backend override table;
project-local Prettier discovery is the one formatter-specific executable
selection rule. The separate Direnv module described below can change global
`PATH` lookup before later formatter runs. `scripts/formatting-test.sh` drives
the real ncurses editor and
checks official-CLI parent/nearer/root/unset behavior, global no-tabs and local
indentation, true/false/absent whitespace policy, LF/CR/CRLF and final-newline
normalization, subsequent-write Latin-1 bytes, manual point/mark/undo and argv
stability, formatter-hunk read-only zero-mutation preflight, recursive observer
failure with coherent inverse notifications, save-path and post-format
normalization rollback, combined ws-butler/EditorConfig rollback,
pending-normalization retry, unsafe-rollback save abortion,
before-save/didSave ordering, CLI failure without an LSP fallback attempt,
prose exclusion, and reload idempotence. `scripts/vundo-test.sh` independently
checks ordinary nested insert/delete hook ordering and throwing change-group
cancellation in the patched core.

### Reusable ncurses editor client — `lem-yath/src/server.lisp`, `scripts/lemclient.sh` (verified approximation)

The packaged editor starts a bounded local Unix-socket listener only when its
packaged `lemclient` is available. The socket lives below `XDG_RUNTIME_DIR` or
the Lem-yath cache, with a user-owned 0700 parent, a 0600 socket, and an
optional 0600 tmux pane file. Existing non-socket paths, symlink pane metadata,
overlong socket paths, foreign ownership, malformed protocol fields, more than
64 files, and more than 64 simultaneous connections fail closed. A live socket
is reused rather than unlinked; only stale owner sockets and metadata created by
this process are removed.

`lemclient` accepts blocking or `--no-wait` requests and Emacs-style
`+LINE[:COLUMN]` positions. Blocking buffers enable a `Server` minor mode:
`ZZ`/`C-c C-c` saves and completes, `C-x #` completes only when clean, and
`ZQ`/`C-c C-k` aborts the request while preserving unsaved text. Multi-file
requests advance through every unfinished buffer before returning. A request
without files attaches to the current buffer. Killing a waiting buffer counts
as completion, while editor exit reports an error and closes every connection.

Inside tmux, the client validates the publishing tmux-server identity and pane,
switches the invoking client to Lem after `OPENED`, and restores the original
pane after the final result. `--no-focus` supports automation. If the socket or usable pane is
missing, the client executes a fresh configured Lem. Successful startup points
`GIT_EDITOR` at the packaged client's `--no-focus` form, because editor child
processes are already inside Lem's pane, and points otherwise-unset `VISUAL`
and `EDITOR` at the ordinary client. Parent shells must export those values
separately. This is deliberately narrower than Emacs's daemon: there is one
authoritative ncurses UI, no arbitrary Lisp evaluation, and no graphical or new
terminal frame creation. `scripts/server-test.sh` drives the real editor through
multi-file finish, no-wait, abort/recovery, zero-file attach, invalid input,
private metadata, partial-start rollback, and clean shutdown.

### Current-buffer Direnv environment — `lem-yath/src/direnv.lisp` (verified approximation)

Direnv is deliberately separate from `lem-yath/src/workspace.lisp`.
`workspace.lisp` resolves the notes `$WORKDIR` once at startup, matching the
configured Emacs `org-directory`; entering a project must not retarget notes.
The Direnv module instead tracks the exact existing directory of the current
eligible buffer. It does not collapse nested `.envrc` files to a Git or Lem
project root.

Selected file opens participate without installing a global find-file hook.
An unwind-protected `execute-find-file :around` method applies the destination
environment provisionally while the file is created, so its first mode hooks
and a synchronously launched language server see the right environment. It then
restores the visible buffer's environment; the ordinary switch hook makes the
destination current only when the open is actually selected. Direct background
`find-file-buffer` loads therefore do not retarget Lem, although selecting such
a buffer later does.

The non-file allowlist covers the process-oriented counterparts of Emacs's
default Direnv modes: directory, terminal and shell buffers; Lisp, Scheme,
Clojure, and Python REPL/listener buffers; grep/peek results; and Legit or
Jujutsu views. Matching walks each active major or minor mode's CLOS ancestry,
so derived modes participate. Shared process/compilation helpers also mark
their result buffers explicitly rather than relying on a mode name. Switch and
post-command hooks run at weight 20000 and cache the exact attempted directory,
covering selection and buffer-directory changes without exporting on every
command. Arbitrary non-file scratch and prompt buffers retain the current
environment.

`direnv export json` updates SBCL's global process environment synchronously.
Consequently a changed `PATH` is visible to lem-yath executable discovery and
to formatters, terminals, language servers, and other subprocesses launched
after the update. In the installed wrapper, project/Direnv PATH entries remain
first and the exact packaged runtime bins are appended as a deduplicated
fallback. Direnv can therefore select a project-local tool without unloading
packaged checkers, formatters, or language servers when no project override
exists. Already-running subprocesses are unchanged. `M-x
direnv-update-environment` forces a refresh, while `M-x direnv-allow` is the
only editor command that authorizes the current `.envrc`; automatic hooks never
grant trust.

Invocations use direct argv boundaries and a 300-second GNU `timeout` safety
cap. Stdout and stderr are drained concurrently and bounded while streaming to
4 MiB each, preventing either child pipe from blocking the other. Environment
names and JSON values are completely parsed and validated before mutation, so
malformed output changes nothing. Valid changes are then applied sequentially;
if a mutation fails, the saved prior values are restored sequentially before
the error is reported. This is rollback, not an atomic transaction. A nonzero
export carrying a valid unload diff is applied before the safe status
diagnostic, matching `emacs-direnv`; missing programs and timeouts retain the
prior environment. Successful whitespace-only output is treated as an empty
change set, matching Direnv outside an active environment. Stderr is drained
for safety but neither its contents nor
environment values are retained in module state or displayed; summaries and
diagnostics expose variable names and status only.

This intentionally shares Emacs Direnv's global-environment model rather than
inventing per-buffer environments. Lem worker threads share that environment,
so a background subprocess created concurrently with a buffer transition can
inherit whichever directory's environment is globally active at its launch.
During a multi-variable apply or rollback, a worker can also observe a
transient mixed environment. There is no retroactive update or per-process
snapshot for work already running. User-facing knobs and mode allowlists use
`defvar`, so preferences established before a source reload are preserved.

`scripts/direnv-test.sh` drives the real ncurses editor and real Direnv binary.
It verifies the command-line file's mode-hook and child-process environment,
direct argv safety, exact-directory caching and reload idempotence, nested
`.envrc` selection, project and outside-baseline transitions, eligible
directory/listener buffers and ineligible scratch retention, post-command
directory changes, denied files without auto-allow, explicit allow and manual
refresh, hard timeout retention, malformed-output prevalidation, and recovery.
The static production probe also covers successful empty export output.

### Emacs-style asynchronous compilation — `lem-yath/src/compilation.lisp` (verified approximation)

`SPC c c` prompts for a shell command and starts it asynchronously in the
originating buffer's exact directory with the process environment captured
there. The command is buffer-local to that origin, so returning to the same
source buffer recalls its last value. A buffer without a prior value starts
with the pinned Emacs 31 default `make -k -jN `, including its trailing space,
where `N` is `ceiling(2 * nproc / 3)` (equivalent to Emacs's
`ceiling(num-processors / 1.5)`). Processor discovery is affinity-aware through
`nproc`, with one processor as the fail-safe fallback.

Before launch, every modified file buffer receives the configured
`save-some-buffers` query. `y` saves the current buffer, `n` skips it, `!` saves
all remaining buffers, `.` saves the current buffer and stops asking, and `q`
cancels compilation. `d` opens a read-only unified disk-versus-buffer diff and
then repeats the same query; both inputs are limited to 16 MiB of characters.
The originating buffer and window are restored after the preflight.

The one fixed `*compilation*` buffer is read-only, has undo disabled, and
receives merged stdout and stderr while the process is still running. ANSI
state survives arbitrary read boundaries: basic and bright foreground and
background colors, xterm 256-color and RGB forms, bold, underline, and reverse
SGR are rendered, while CSI/OSC control bytes are consumed instead of shown.
The raw stream is capped at 8 MiB of bytes and an unfinished control tail
at 4,096 characters. These are deliberate safety bounds, not Emacs's
effectively open-ended process-buffer behavior.

The finite location parser covers the representative configured tool output:
GCC/Clang and ordinary `path:line:column` rows, Rust/Cargo arrows, Go/vet rows,
Python tracebacks and pytest/Ruff locations, and Nix-style messages containing
a source location. Relative paths resolve against the captured compilation
directory. In the log, Evil Collection's effective `gj`/`gk`, `C-j`/`C-k`, and
`Tab`/`S-Tab` move between diagnostics without selecting source; `[[`/`]]` move
between source files. `Return` visits the exact line and column, while `go`,
`M-Return`, and `S-Return` display it but retain the compilation window as the
selected window. If the remembered origin window was deleted, `go` displays
the source in another window while preserving the log and keeping it selected.
`q`, `ZZ`, and `ZQ` retain the expected result-window exit paths.

Global `M-g n` and `M-g p` route through the most recently selected error
provider. Starting or navigating a compilation selects its result sequence;
using linter/LSP diagnostic navigation selects the current buffer's diagnostic
sequence instead. `gr` reruns without prompting for a command and preserves the
exact command, directory, and captured environment. `C-c C-k` asks the live
guardian broker to signal its separately anchored command group with SIGINT
and applies a bounded SIGKILL fallback to members that remain in that group.

There is deliberately only one active, fixed-name compilation session.
Replacing it requires confirmation while its process is live. `C-c C-k`
requests group SIGINT; the reader asynchronously applies bounded SIGKILL
escalation, reports completion, and reaps the broker. Replacement,
compilation-buffer kill, source reload, and editor exit synchronously terminate
validated same-group descendants, join the reader, and reap the directly
launched broker. The pinned Python broker starts with a fixed environment;
Lem sends the command and captured environment over private framed stdin, so
project values never enter its argv or environment and a project `PATH` cannot
replace the pinned Python or Bash executables. Interrupt, kill, and release are
serialized over that same private capability. The broker and watchdog stay
outside the command group. The watchdog parents its unreaped anchor, and that
anchor directly parents Bash, so stopping Bash's parent or the whole command
group cannot stop control handling. The anchor pins the numeric group identity
until an authorized release; Lem retains the broker pipe plus a locked
armed-state Boolean, but never stores or signals the command PGID. The broker
signals the pinned group, while the watchdog kills it if the broker dies. Control EOF
disarms Lem's capability and fails the session closed. A gated fork cannot exec
Bash until the anchor has queued `STARTED`, so even hostile project startup code
cannot freeze Lem's synchronous launch handshake. Before exec it restores
ordinary shell signal dispositions and drops every inherited descriptor except
standard I/O and the anonymous script; the script's first line closes that last
transport descriptor before the requested command launches descendants.
Session identity plus buffer ownership prevent late events from an old process
altering the reused buffer. Normal terminal status reaps the broker after its
inner Bash command exits without waiting for a still-running descendant that
merely retains inherited stdout. After the ordered `EXIT` status, an underfull
read (possibly empty) establishes the bounded drain point; the continuously
writing regression also proves the live reader takes the positive-underfull
path. An out-of-group descendant therefore cannot deadlock normal completion
or synchronous teardown, and Lem does not signal that descendant.
`scripts/compilation-test.sh` drives all of this through real ncurses input,
including the installed default Make, live split-SGR output, six diagnostic
forms, navigation, deleted-origin `go`, exact recompile context,
hostile Bash and Python startup variables, project `PATH` shadows, a strict
broker-environment whitelist, secret-free broker argv, command-transport
descriptor closure, stdout-retaining and continuously writing descendants,
empty and positive underfull drain boundaries, complete and incomplete UTF-8,
default SIGINT and SIGPIPE dispositions, broker-only death, an immediate-parent stop, and a
SIGSTOPped command group,
leader-only PGID reservation, resistant same-group descendants, stale
callbacks, and synchronous buffer-kill/reload/exit cleanup.

This is a bounded reproduction of the configured daily workflow, not all of
`compile.el`: commands run through non-login, non-interactive Bash and streams
are decoded as UTF-8; the diagnostic grammar and SGR repertoire are finite;
the captured environment is limited to 16 MiB and commands to 1 MiB; there is
no Comint input, prefix-argument surface, custom compilation-buffer name, or
concurrent named compilation sessions. The private command transport requires
Linux `memfd_create` and `/proc/self/fd`, matching the flake's Linux-only target.
The guardian is lifecycle isolation, not a same-UID security sandbox:
`BASH_ENV` startup code can inspect the anonymous script descriptor before its
first line closes it. Normal successful release deliberately preserves
background jobs, including jobs that remain in the command group, while
abnormal cleanup signals only the anchored group and cannot reach a descendant
that escaped it. As with ordinary process supervision, an uninterruptible
kernel sleep can also prevent a nominally bounded kill-and-reap operation from
finishing.

### Flycheck-style diagnostics — `lem-yath/src/lint.lisp` (verified subset)

Programming buffers enable `lem-yath-lint-mode` unless Lem LSP owns the
buffer. Checks start when the mode is enabled, after save, immediately after a
newline insertion, or after 500 milliseconds of idle time following another
change. Every replacement check advances a generation, terminates its owned
bounded subprocess, and rejects results whose buffer tick, filename, mode,
generation, request, or LSP ownership became stale. Checker input and each
output stream are bounded, and subprocesses receive the editor thread's
captured Direnv environment.

The finite configured checker registry follows the effective Emacs tools:
Python runs Ruff over unsaved stdin and chains to Mypy for a clean saved file
when Ruff has no syntax error; C and C++ use Clang with GCC fallback; Rust uses
Cargo metadata plus `cargo test --no-run` for the owning target; Go runs
gofmt, vet, and build or test; POSIX shell uses Bash syntax checking; JSON uses
`python -m json.tool`; and Nix uses `nix-instantiate --parse`. The installed
application supplies Ruff, Mypy, Python, Clang, Go, Cargo, Bash, and the other
runtime dependencies. Temporary, read-only, and decrypted SOPS buffers are
never submitted to a checker.

Diagnostics use Lem LSP's existing severity overlays, point popup, navigable
list, and next/previous location representation. The modeline shows `FlyC`
state and error/warning counts. Flycheck's effective `C-c ! c/n/p/l` prefix is
available while the linter mode is active; global `M-g n` and `M-g p` route
between the most recently selected compilation result and the current buffer's
linter/LSP diagnostics. Explicit LSP attach clears and disables the linter,
while detach restores it only when it was expected before management.
Python is the deliberate exception to language-spec auto-start: Pyright stays
registered for manual `M-x lsp-mode`, matching the Emacs configuration's lack
of a Python Eglot hook, so Ruff/Mypy own Python by default.

`scripts/lint-test.sh` runs the installed ncurses package against real Ruff,
Mypy, Clang, Bash, JSON, Nix, Go, and Cargo failures. It also verifies exact
hooks and bindings, automatic trigger timing, shared overlays/navigation,
SOPS refusal, LSP handoff, captured runtime PATH, process cancellation, and
stale-result rejection. `scripts/real-lsp-test.sh` independently performs the
real Pyright handoff and verifies linter restoration after all programming LSP
workspaces shut down. The remaining gap is Flycheck's open-ended checker
catalog and its checker-selection, verification, compile-output,
explanation, and error-copy interfaces.

### Transparent SOPS editing — `lem-yath/src/sops.lisp` (verified approximation)

Existing local `.yaml`, `.yml`, `.json`, `.env`, `.ini`, and `.txt` files pass
through `sops filestatus` during file activation. Encrypted files are decrypted
into the live buffer, while a small patched-core buffer writer replaces the
ordinary save path and sends plaintext on stdin to `sops encrypt
--filename-override`; only successful, nonempty ciphertext is written. The
normal formatter is inhibited for these buffers. Persistence tracks the stable
on-disk ciphertext identity, so external changes still trigger the SOPS-aware
revert path rather than a false stale-save prompt.

Decrypt failure leaves the original ciphertext read-only and installs revert as
a retry. Encrypt failure aborts before disk writing, retaining both the old
ciphertext and the modified plaintext buffer. SOPS stderr is drained but never
shown because it may contain secret material. Calls use direct argv boundaries,
a 300-second GNU timeout, and a 64 MiB accepted-output limit. The ncurses gate
in `scripts/sops-test.sh` exercises successful open/save, plaintext fall-through,
format inhibition, both failure/retry paths, external revert, and reload. Guided
encrypted-file creation, custom input-type maps, remote files, and filesystem
notifications remain outside this implementation.

---

## 5. LSP  (`extensions/lsp-mode/`, package `lem-lsp-mode`)

Lem-yath adds automatic C# support for `.cs` and `.csx`: its native
`csharp-mode` supplies C-like indentation and a bounded TextMate fallback,
while `src/tree-sitter.lisp` automatically installs the packaged C# parser and
highlight query in eligible buffers. Rust, manual Python, Markdown, C#, Nix,
Go, and Terraform share the configured Eglot project policy: prefer the
containing Git root, because the Emacs early init restricts project.el to Git,
merge Git submodules into their parent as project.el does, keep linked worktrees
separate, then retain the language marker as a useful non-Git fallback. Go runs `gopls`
over stdio with no Lem-only initialization options, and Terraform runs
`terraform-ls serve` over stdio, matching Eglot rather than their upstream Lem
TCP specs. A `csharp-ls` spec falls back to the nearest `.sln` or `.csproj`
outside Git. The packaged server uses stdio and
LSP 3.17 pull diagnostics;
full reports feed the same diagnostic overlays as push diagnostics, unchanged
reports preserve them, stale responses are discarded, and server refresh
requests invalidate the cached result. Because csharp-ls can return an empty
report while Roslyn is still loading without sending a later refresh, that
specific initial state is retried for at most 30 seconds. The installed-wrapper
gate obtains a real `MissingType` semantic diagnostic and verifies server
cleanup.

This is intentionally partial parity with Emacs `csharp-mode`/
`csharp-ts-mode`: tree-sitter supplies highlighting, but the native mode and
C-like indentation remain in control rather than reproducing the full
tree-sitter major-mode semantics. Lem-yath acknowledges dynamic file-watch
registration and delivers `workspace/didChangeWatchedFiles` notifications from
bounded, nonblocking Linux inotify watches. String globs and LSP 3.17
`RelativePattern` bases use Eglot-compatible `**`, `*`, `?`, range, and brace
matching; Create/Change/Delete masks are honored, files already open in the
workspace are suppressed, newly created directories gain watches, and rename
events are split into delete/create notifications. Project-internal watches use
the configured project file set, external relative bases recurse without
following symlinked directories, and the Eglot-compatible global ceiling is
10,000 watched directories. Each registration is bounded and transactional;
unregister, replacement, workspace restart, shutdown, failed startup, and editor
exit release the reader thread, descriptor, and global reservations.

Lem-yath advertises work-done progress, accepts server
progress-token creation, and tracks at most 64 simultaneous reports per
workspace. Every attached buffer renders the Eglot-style aggregate percentage
in its right modeline; completed tokens remain at 100% for two seconds, expire
independently, and are cleared with the workspace. Eglot's graphical modeline
hover text for task titles and messages has no ncurses counterpart.

GDScript files use a native `gdscript-mode` with the pinned `.gd`, comment,
tab-width-4 indentation, and programming-mode behavior. The packaged GDScript
parser supplies highlighting and Expreg nodes. Its automatic LSP spec roots at
`project.godot` and connects to the already-running Godot editor over TCP; it
derives the editor-settings version from `project.godot`, honors a configured
`network/language_server/remote_port`, and otherwise uses port 6005. Lem does
not launch or own a Godot process. `scripts/gdscript-test.sh` verifies a real
ncurses handshake, exact language/root/port delivery, external-client
ownership, and nonfatal connection refusal.

### Enable — `lsp-mode.lisp:260` (`define-minor-mode lsp-mode`)
A language spec auto-adds `enable-lsp-mode` to the mode's hook
(`define-language-spec` macro, `lsp-mode.lisp:1832-1841`), so opening a file in a mode
that has a spec auto-starts LSP. Manual: `M-x lsp-mode`. Disable temporarily inside a
body with `(lem-lsp-mode:without-lsp-mode () …)`. Lem-yath registers its Pyright
spec without that hook, so Python is manual and the non-LSP checker remains the
default diagnostics provider.

### Registering servers — `define-language-spec` (`lsp-mode.lisp:1832`)
```lisp
(lem-lsp-mode:define-language-spec (spec-name major-mode &key parent-spec)
  :language-id "…"  :root-uri-patterns '("Cargo.toml")
  :command '("server" "--stdio")   ; or (lambda (port) (...)) for :tcp
  :install-command "…" :readme-url "…" :connection-mode :stdio) ; :stdio | :tcp
```
Spec class slots in `lsp-mode/spec.lisp:16-47`. Override per-server init options with
`(defmethod spec-initialization-options ((spec my-spec)) (make-lsp-map …))`, or frozen
server-requested settings with
`(defmethod spec-workspace-configuration ((spec my-spec)) (make-lsp-map …))`.
Customize the server command at runtime: redefine the spec, or set the relevant
defvars (some configs expose them, e.g. erlang `*lsp-erlang-server-command*`).

### Languages that ship a WORKING spec (verified active, loaded via each mode's asd):

This table describes upstream Lem. The installed lem-yath configuration
replaces the Go and Terraform entries with `gopls` and `terraform-ls serve`
stdio specs and applies the configured Git-project policy described above.

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

## 5A. DAP debugging  (`lem-yath/src/dap.lisp`)

Upstream Lem does not ship a DAP client. Lem-yath implements the bounded Dape
workflow used by the active Emacs configuration and installs Dape's stock
`C-x C-a` prefix map. It supports one foreground session over stdio or
loopback TCP and launches adapters with direct argument vectors rather than a
shell.

The built-in presets are:

- `debugpy`: launches the saved Python buffer through `python -m
  debugpy.adapter`, rooted at the nearest jj/Git project or the file directory.
- `dlv`: launches the nearest jj/Git root through `dlv dap`, falling back to
  the source directory outside version control.
- `lldb-dap`: launches project-root `a.out` for Rust, C, or C++.
- `gdb`: launches project-root `a.out` through `gdb --interpreter=dap`.

Source, conditional, hit-count, log, and function breakpoints are global to
the editor process and survive closing their source buffer. Pending and
verified breakpoints, plus the current stopped line, are rendered in the
gutter. Session inspection covers threads, stack frames, scopes, variables,
source references, watches and expression evaluation. Continue, pause,
step-over/in/out, restart, restart-frame, run-to-cursor, memory reads, and
disassembly requests are available when the adapter supports them.

The exact stock prefix contract is:

| Keys after `C-x C-a` | Commands |
|---|---|
| `d p c n s o` | start, pause, continue, next, step in, step out |
| `r f u` | restart, restart frame, run to cursor |
| `i R x w` | info, REPL, evaluate, watch |
| `b B l e h F` | toggle/remove-all/log/conditional/hit/function breakpoints |
| `t T S < >` | thread, session, stack, newer frame, older frame |
| `m M` | memory, disassembly |
| `D K q` | disconnect and keep debuggee, terminate, quit |

Adapter `runInTerminal` requests create an interactive Lem shell buffer, so a
program can read input as well as display output. Arguments remain literal;
requests asking for shell interpretation are rejected because reproducing
shell parsing safely is outside this client. Protocol parsing uses UTF-8 byte
lengths and bounded headers/messages, request timeouts are cleaned up, and
late events cannot revive a terminated session.

The deliberate boundaries are one foreground session, no nested
`startDebugging`, no general adapter-configuration editor, and no on-disk
breakpoint persistence. The latter matches the effective Emacs setup, which
enables Dape's global breakpoint mode but not its persistence hooks. The
installed-runtime gate is `scripts/dap-test.sh`: it covers a fragmented
Unicode mock adapter and real debugpy, Delve, LLDB, and GDB sessions across
Python, Go, C, C++, and Rust, including interactive terminal input and clean
termination.

---

## 6. Tree-sitter  (`extensions/tree-sitter/`, package `lem-tree-sitter`)

Depends on `tree-sitter-cl` (FFI bindings). **Both `tree-sitter-cl` and
`lem-tree-sitter` are built into the Nix image.** Upstream Lem exposes the API
below but does not automatically wire it into language modes.

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

### Lem-yath automatic policy — `lem-yath/src/tree-sitter.lisp`

The installed wrapper exports a deterministic bundle containing a parser and
`highlights.scm` query for **Bash, C, C++, C#, Clojure, CSS, Go, HTML, Java,
GDScript, JavaScript, JSON, Just, Lua, Markdown, Nix, Nu, Python, Rust, TOML,
TypeScript, TSX, Typst, and YAML** (24 grammar/query pairs). Eligible buffers automatically receive a
fresh parser when their existing Lem major mode has a corresponding entry.
File-backed buffers are eligible regardless of name; fileless buffers whose
names begin with a space or `*` are excluded, matching the configured Emacs
`treesit-auto` policy. Missing bundles, unavailable FFI support, and activation
errors leave the mode's original TextMate/regex parser in place.

Each buffer gets a copied syntax table and its own parser, query, tree, edit
cache, and tick. Mode changes and buffer deletion release the native parser
state. Query predicates needed by the packaged highlight files (`match?`,
`eq?`, and `any-of?`) are evaluated before capture application, and later
query patterns refine generic captures deterministically. The configuration
uses highlighting only: mode selection, indentation, LSP, and structural
editing remain owned by their existing implementations.

`lem-yath/src/language-modes.lisp` supplies the previously absent GDScript,
Just, Meson, NASM, nginx, Nushell, and Typst modes. It reproduces the pinned filename
associations, nginx content fallback, Nu shebang, comment syntax, indentation
widths, and GDScript's local tab policy. GDScript, Just, Nu, and Typst
participate in this parser bundle and Expreg; NASM, Meson, and nginx retain
bounded TextMate fallback highlighting. NASM additionally has its pinned
four-column label/directive/instruction indentation, mnemonic Tab insertion,
colon-triggered label reindent, string/symbol/comment syntax, and `.nasm`
association. Its structural instruction-field highlighter follows new and
project-local macro instructions without embedding nasm-mode's 41 KiB generated
token snapshot; the upstream comment-gutter and custom join-line commands are
not reproduced.

`lem-yath/src/meson-mode.lisp` augments the base Meson mode with the pinned
global builtin/keyword/variable table, receiver-specific methods, and exact
per-function keyword arguments. Completion is suppressed in strings and
comments, completion focus exposes the package's builtin signatures, and the
language idle hook supplies the same signatures while point remains inside a
call. Meson syntax uses only apostrophes (including triple-apostrophe strings),
and highlighting is limited to the pinned keywords, builtins, builtin
variables, and assignment targets. Its indentation follows the pinned
two-column block, delimiter, operator-continuation, closing-delimiter, and
multiline-string cases with a bounded structural scanner rather than a full
SMIE parser. Compilation recognizes the package's exact Meson error-location
line. The package defines no Imenu index, so none is invented here; its F1
manual lookup is inactive in the audited configuration because neither default
documentation directory exists.

The nginx mode reproduces the pinned package's double-quote string syntax,
apostrophe punctuation, hash comments, directive, rewrite-result, numeric and
named variable, trailing on/off, and block-context highlighting. Its
four-column indentation uses the package's backward hint scan, including
comment-only-line skipping and closing-brace behavior. Return inserts a newline
and indents it, and saves require a final newline unless an explicit
`insert_final_newline = false` EditorConfig property overrides the mode. The
pinned package defines neither completion nor Imenu, so Lem-yath invents
neither. Lem's generic filling layer does not reproduce nginx-mode's
comment-only auto-fill restriction or its exact paragraph separator variables.

This approximates the configured Emacs `treesit-font-lock-level 3`; it does not
load injection or locals queries. In particular, captures guarded by
`#is-not? local` are omitted rather than risking false builtin highlighting.
For correctness across Unicode and multiline edits, Lem-yath reparses the
current buffer text from scratch once per changed buffer tick instead of using
upstream Lem's approximate incremental byte edit. Languages without a Lem
major mode remain separate mode gaps. The installed-runtime gate is
`scripts/tree-sitter-test.sh`.

---

## 7. Git  (`extensions/legit/`, package `lem/legit`; porcelain in `lem/porcelain`)

Magit-inspired. `M-x legit-status` bound **`C-x g`** (`legit/legit.lisp:65`).

### Workflow / bindings (in the legit/peek-legit status window) — `legit/legit.lisp`, `peek-legit.lisp`
- Stage/unstage/discard file: `s` / `u` / `k` (`peek-legit.lisp:26-28`);
  hunk-level stage/unstage uses `s`/`u` in the diff window, while the same
  keys in a characterwise or linewise Visual selection affect only selected
  changed lines and may span several hunks in that file.
- Commit: lem-yath replaces upstream Legit's direct `c` with `c c`; finish
  `C-c C-c`, abort `M-q`/`C-c C-k` (`legit-commit.lisp:38-41`).
- Branches: checkout `b b`, create `b c` (`legit.lisp:74-76`).
- Push/Pull: lowercase `p` opens lem-yath's Evil Collection push dispatch
  (`p p` is the ordinary push-remote action); uppercase `F` opens the matching
  pull dispatch.
- **Log dispatch**: `l` opens the normally visible Magit log surface in status,
  diff, and log panes (`l l` remains current-branch log). It defaults to 256
  decorated commits and retains limit/author/message/change/occurrence,
  numeric line-trace, path/follow, ordering, graph/color, signature/header,
  patch, and stat arguments when reopened. Actions cover current, selected,
  `HEAD`, related, local/all branches, all refs, three reflogs, and the visible
  shortlog sub-dispatch. Rows keep Legit's two-pane preview; `f`/`b`, `F`/`B`,
  `g r`, `=`, and `q` provide page, refresh, limit, and status restoration.
  Same-repository synchronous actions that end in ordinary status refresh the
  originating log and retain its selected commit, with a prior-line fallback
  if the action moved that commit away; message, preview, list, and worktree
  root transitions remain focused. Log `c c`/`c a` and inherited actions that
  open a native commit-message buffer retain a buffer-local, one-shot origin:
  confirm or abort refreshes the same log and anchor, while a later unrelated
  status editor cannot inherit it. Multi-commit cherry edits transfer that
  origin between consecutive message buffers and restore only after the final
  editor closes.
- **Stash dispatch**: the configured Evil Collection default keeps Magit's
  lowercase `z` for the complete normally visible stash map in status and
  diff. `- u`/`- a` select untracked/all files;
  `z`/`i`/`w`/`x` stash both, index, worktree, or keep-index state;
  `Z`/`I`/`W` snapshot without cleaning; and `r` updates branch-scoped WIP
  refs. `a`/`p`/`k`, `l`/`v`, `b`/`B`, and `f` cover apply/pop/drop,
  list/show, base/current branch creation, and format-patch. Staged/worktree
  separation uses temporary-index commit-tree plumbing. The hidden level-5
  pathspec push sub-transient is not exposed. This dispatch replaces Legit's
  upstream direct `z z`/`z p` aliases, and synchronous execution has no Magit
  process buffer.
- **Interactive rebase**: `r i`; abort/continue/skip `r a`/`r c`/`r s`
  (`legit.lisp:105-108`); full rebase-todo editing mode with `p r e s f x b d l t m`
  keys (`legit-rebase.lisp:49-77`).
- **Commit / amend dispatch**: `c c` opens an ordinary commit buffer and `c a`
  opens the current message in a transient amend buffer;
  finish with `C-c C-c` or abort with `M-q`/`C-c C-k`.
- **Cherry-pick dispatch**: `A A` picks a prompted commit or continues an active
  pick; `A a` applies a prompted commit without committing or aborts an active
  pick; `A s` skips only while a pick is active. Completion is bounded to 200
  commits across all refs and accepts an arbitrary whitespace-free revision.
- **Bisect dispatch**: `B` opens Magit's initial or active action map. Initial
  `- n`, `- p`, `= o`, and `= n` configure no-checkout, first-parent, and
  custom terms before `B` starts or `s` starts-and-runs. Active `B`/`g`/`m`/`k`
  mark new, old, a prompted visible term, or skip; `r` confirms reset and `s`
  runs an explicit bounded shell predicate. Status shows the tested revision,
  active terms, and a bounded parsed log.
- **Fetch dispatch**: `f` keeps Magit's `- p` prune, `- t` tags, `- u`
  unshallow, and `- F` force toggles. `p`/`u`/`e`/`a` fetch the configured push
  remote, current upstream, another remote or URL, or all remotes; `o` fetches
  one branch, `r` an explicit refspec, and `m` populated submodules with the
  default verbose four-job policy. A missing push remote is selected and
  persisted before fetching. `C` configures the current branch's variables and
  repository defaults, then returns to the fetch map.
- **Pull dispatch**: uppercase `F` replaces Legit's fixed `F p` route in status
  and diff. Mutually exclusive `- f`/`- r` select fast-forward-only or rebase,
  and `- F` forces the fetch. `p`/`u`/`e` pull from the current branch's push
  remote, upstream, or a selected remote branch; `r` edits branch pull-rebase
  and `C` reuses complete branch configuration. Missing configured
  destinations require selection and confirmation before persistence. Direct
  argv calls are bounded to 120 seconds and 4 MiB; an option-like configured
  remote is resolved to its URL because Git drops pull's option separator in
  its internal fetch. Divergent fast-forward-only pulls remain mutation-free,
  while merge/rebase conflict state stays available to the matching lifecycle
  dispatch; an ordinary merge abort restores the exact pre-pull state after a
  merge conflict. Synchronous execution accepts Git's generated merge message,
  omits Magit's process buffer, and does not expose the normally hidden level-7
  autostash argument.
- **Push dispatch**: Evil Collection's lowercase `p` replaces Legit's `P p`
  entry in status and diff. `- f`/`- F`, `- h`, `- n`, `- u`, `- T`, and
  `- t` provide force-with-lease/force, no-verify, dry-run, set-upstream,
  all-tags, and follow-tags. `p`/`u` push the current branch to its push remote
  or upstream; `e` chooses another target, `o` chooses an arbitrary source and
  target, `r` accepts bounded comma-separated refspecs, `m` pushes matching
  branches, `T`/`t` push one/all tags, `n` pushes a notes ref, and `C` enters
  branch configuration. Missing destinations require confirmation before
  configuration is persisted. Direct argv calls are option-delimited, bounded,
  and synchronous;
  temporary prefix-argument reselection, unnamed URL upstreams, and Magit's
  process/credential-buffer presentation remain gaps.
- **Branch dispatch**: `b` replaces Legit's direct branch bindings in status
  and diff with Magit's configured checkout, local/remote tracking checkout,
  orphan, upstream-first create, spin-off/spin-out, configure, rename, reset,
  shelve/unshelve, and guarded local/remote-delete lifecycle. Direct
  configuration covers the current branch description, upstream, rebase, and
  push remote plus repository pull/push defaults and default-branch migration;
  nested `C` also covers migration and automatic merge/rebase setup.
  Evil Collection's `X` reset and `x` delete mapping is retained. Remote
  checkout records upstream and push remote, checked-out deletion switches or
  detaches first, unmerged and remote deletion confirm, remote rename retains
  the remote ref's own tip, and dirty spin-out preserves edits by becoming
  spin-off. Shelving moves the reflog under a dated ref and drops pushRemote;
  unshelving strips that date. The `- r` checkout submodule argument is present.
  Worktrees are covered by the separate `Z` dispatch below. Visual
  commit-region spin selection and asynchronous process presentation remain
  gaps.
- **Remote dispatch**: `M` opens Magit's normally visible remote map in status
  and diff. `- f` controls fetch-after-add; `u`/`U` and `s`/`S` replace the
  selected remote's fetch URL/refspec and push URL/refspec, while `O` and `h`
  set tag and remote-HEAD policy. `a` adds, `r` renames, `k` removes, `C`
  configures another remote, `p` prunes stale tracking branches, `P` prunes
  stale fetch refspecs, and `d u` reuses the default-branch migration. Rename
  and removal migrate or clear repository and branch push-remote settings;
  destructive remove/prune paths confirm. Values, candidates, subprocess
  output, and time are bounded and Git receives direct argv. Lem's single-line
  prompts replace Magit's multi-value URL/refspec editor, the hidden level-7
  unshallow action is absent, and execution is synchronous without a process
  buffer.
- **Submodule dispatch**: Evil Collection's apostrophe (`'`) opens the normally
  visible Magit submodule lifecycle in status and diff. `-f`, `-r`, `-N`,
  `-C`, `-R`, `-M`, and `-U` configure force, recursion, fetching, update
  strategy, and remote-tip use; `a`/`r`/`p`/`u`/`s`/`d`/`k`/`l`/`f` add,
  register, populate, update, synchronize, unpopulate, remove, list, and fetch.
  Paths and values are bounded and traversal-safe, direct argv preserves spaces
  and metacharacters. The list is a bounded textual pane dismissed with Space
  rather than Magit's navigable module-list buffer. Dirty removal requires force plus a second confirmation,
  stashes tracked and untracked content, and preserves `.git/modules`. Lem
  selects one prompted module rather than Magit's region/prefix multi-selection
  and executes synchronously; the prefix-only gitdir-trash action is absent.
- **Subtree dispatch**: Evil Collection's double quote (`"`) opens Magit's
  subtree import/export surface in status and diff. Import provides `-P`
  prefix, `-m` message, and `-s` squash before repository add, fetched-commit
  add, merge, or pull. Export provides `-P` prefix, `-a` annotation, `-b`
  branch, `-o` onto, `-i` ignore-joins, and `-j` rejoin before push or split.
  Prefixes are bounded repository-relative paths with traversal rejected;
  revisions and branch names are resolved through Git, and spaces and shell
  metacharacters remain literal direct arguments. Lem prompts for a relative
  prefix instead of Magit's absolute-inside-repository directory and runs the
  bounded operation synchronously without a process buffer.
- **Worktree dispatch**: Evil Collection's remapped uppercase `Z` opens its focused worktree
  map in status and diff. `b` checks out a branch, remote branch, or resolved
  commit in a new sibling-style path; `c` creates a branch and worktree from a
  selected revision; `m` moves a linked worktree; `k` deletes or prunes one;
  and `g` replaces the active Legit status with the selected worktree. The
  primary is excluded from move/delete, dirty deletion requires explicit
  confirmation, locked deletion fails closed, stale entries prune without a
  destructive prompt, and move/delete of the active linked worktree follows
  its new or primary status root. NUL-delimited porcelain, direct absolute
  argv paths, and 120-second / 4-MiB / 5000-candidate / 4096-character bounds
  retain paths containing whitespace and shell metacharacters. Execution is
  synchronous and Lem opens Legit rather than Magit's Dired fallback.
- **Reset dispatch**: Evil Collection's top-level `O` exposes `b` branch, `f`
  file, `m` mixed, `s` soft,
  `h` hard, `k` keep, `i` index-only, and `w` worktree-only actions in status
  and diff panes. Revision, branch, and revision-tree file completion is
  bounded; every mutation uses direct argv. Current dirty branch reset has
  Magit's loss confirmation, non-current branches move through reflogged
  `update-ref`, and worktree-only reset uses a private temporary index.
- **Merge dispatch**: `m` exposes fast-forward, strategy, strategy-option,
  whitespace, diff-algorithm, signing, and signoff arguments plus ordinary,
  edited-message, no-commit, preview, and squash actions in status and diff.
  The preview focuses a read-only prospective merge-tree without mutation;
  edited and active merges use Legit's native prefilled commit buffer. A live
  `MERGE_HEAD` reduces the dispatch to commit or confirmed abort, and conflict
  stops retain the unmerged index for ordinary Legit resolution. Execution is
  direct argv and bounded to 120 seconds / 4 MiB, with 1-MiB message input.
  Absorb and dissolve add explicit destructive and lease confirmations around
  Magit's update/switch/merge/delete lifecycle; main branches are protected,
  stale leases stop before merging, and failed merges retain their source.
  Automatic deletion of a Forge pull-request-only remote and octopus input
  remain explicit gaps at this checkpoint.
- **Revert dispatch**: Evil Collection remaps Magit's entry to `_`, preserves
  `V` for Visual Line, and exposes direct no-commit revert on `-`; Lem matches
  those keys in status and diff panes. The transient keeps mainline,
  edit/no-edit, strategy, GPG-sign, and signoff arguments plus `_` commit and
  `v` no-commit actions. Clean edited reverts open Git's prepared message in
  native commit mode. A stopped sequence switches to `_` continue, `s` skip,
  and confirmed `a` abort while retaining unmerged rows for resolution. Calls
  use direct argv with 120-second / 4-MiB bounds, messages are capped at 1 MiB,
  and one prompt accepts at most 64 comma-separated verified commits. Magit's
  visual commit-region selection and asynchronous process presentation remain
  outside this port.
- Refresh `g`, navigate `n`/`p`/`M-n`/`M-p`, help `?`/`C-x ?`, quit `q`.

Lem-yath registers the diff, commit, and rebase major-mode maps ahead of Vi's
normal-state map, so these native porcelain keys are not interpreted as Vim
motions or operators. It also repairs pinned Legit's patch path: normal-state
`s` and `u` construct a complete hunk patch, while an active characterwise or
linewise region constructs range-correct partial hunks and preserves
unselected removals as context. A region can span separated hunks but not
files; blockwise selection fails closed. Both paths use a private temporary
file, mutate only Git's index, and refresh status after success. Validating the
transient commit buffer no longer asks whether to save or kill it after Git has
already committed. Interactive rebase launches Git with a child-only
environment and a per-session owner-private control file: the sequence editor
exits normally after Lem publishes `continue` or `abort`, without signalling a
PID or mutating Lem's process-wide environment. This avoids recursive editor
launches and remains safe while the reusable-editor server thread is active.
The retained asynchronous Git process is reaped and explicitly closed before
another session starts. A `reword` stop opens Git's real `COMMIT_EDITMSG`
through the owner-private blocking client. The commit-mode confirm and abort
keys detect that request and save/release or abort Git instead of starting a
nested commit. At an `edit` stop, `c a` first reaps and closes the stopped rebase
process, then opens a prefilled transient message. A successful amend returns
focus explicitly to Legit's status pane so `r c` continues the same rebase.
The local commit dispatch deliberately replaces Legit's direct `c` command
with Magit's configured `c c`/`c a` muscle memory in status and diff panes.
The matching `A` prefix supplies Magit's complete normally visible cherry-pick
surface in both panes. `- m`, `= s`, `- F`, `- x`, `- e`, `- S`, and `+ s`
  retain mainline, strategy, fast-forward, source-reference, native message
  editing, GPG-signing, and signoff arguments. Actions pick, apply without a
  commit, harvest, squash, donate, spin out, and spin off; an active sequence
  changes to continue, abort, and skip. Exact prepared messages open in Legit's
  commit mode and a multi-commit edit advances through Git's real sequencer one
  message at a time. Edit mode and fast-forward are mutually exclusive in the
  popup and at argv validation; continuation reads Git's bounded on-disk
  sequencer option rather than retaining leak-prone global editor state. A
  conflict is treated as a normal stopped state, and the
pinned Legit parser renders every Git unmerged status once in the unstaged
section so its resolved file can be staged before continuing.

Cross-branch moves require a clean index, worktree, and untracked set. The
destination is committed first; only then does a source-tip lease permit tip
reset or an interior `rebase --onto`, after which harvest/spinoff restore the
requested destination checkout. A failed destination therefore never removes
source history, and a source-cleanup conflict remains a real manually
completable rebase. Up to 64 comma-separated commits replace Magit's visual
commit-region collection. Source removal of merge commits fails closed rather
than flattening uncertain topology, execution is synchronous without a process
buffer, and a Lem restart during a stopped branch-moving sequence cannot retain
its in-memory post-success source-cleanup intent.

### Porcelain coverage vs magit — `legit/README.md`
Covered: status, stage/unstage (file + hunk), discard, commit, branches (checkout/
create), push, pull/fetch, the configured visible log/reflog/shortlog dispatch,
the configured **stash dispatch**, interactive
rebase (pick/reword/edit/fixup/squash/drop/exec/break/label/reset/merge).
Also basic Fossil + Mercurial. **Gaps vs magit:** no multi-file staging,
limited switches/transient submenus, no graphical remaining-revisions or process view,
no complete argument surfaces outside the explicitly ported dispatches. The log
port intentionally omits hidden high-level history filters, matching/merged
selectors, conditional WIP logs, and function/regexp `-L` forms; its graph,
signature, and header presentation is compact rather than face-identical.
Selected-line staging is verified for ordinary tracked textual
diffs; untracked, binary, and combined-conflict diffs still require whole-file
handling. Customize via `lem/porcelain:*git-base-arglist*`,
`*commits-log-page-size*`, `*nb-latest-commits*`, `*branch-sort-by*`,
`lem/legit:*vcs-existence-order*`.

The installed-wrapper acceptance gate in `scripts/vcs-test.sh` uses real
keystrokes and three isolated repositories. It verifies exact Visual-line
stage/unstage of one replacement within a multi-change hunk, partial unstage
from that cached hunk, one selection spanning separated hunks, ordinary hunk
fallback, tracked and untracked file staging, commit editing and
validation, push to a bare remote, branch creation and checkout, every visible
stash action with exact index/worktree/untracked/snapshot/WIP boundaries, and
a pull from an independent peer clone. A later isolated pull matrix exercises
push-remote, upstream, and explicit option-like remote destinations; exact
branch rebase configuration; a real local-commit rebase; and mutation-free
fast-forward-only refusal. It also retains a real pull conflict's local HEAD,
unmerged index, and `MERGE_HEAD`, then aborts through the ordinary merge map
back to the exact pre-pull state. It then selects an older
status commit and opens a real two-row interactive-rebase todo with `r i`. It
saves the first row as `reword` and the second as `fixup`, continues with
`C-c C-c`, edits the actual server-owned `COMMIT_EDITMSG`, confirms through
the mode-local key, and verifies the rewritten two-commit history, new subject,
clean index/worktree, and retained content from both commits. The fixture uses
an isolated private server socket so it cannot target another running Lem. It
then immediately opens a fresh one-row rebase, rewords the rewritten commit
again through a second blocking client callback, and proves clean history after
the second session. Finally it starts another one-row rebase, marks `edit`,
waits for Git's real stop, changes and stages a file through Legit, opens `c a`,
edits and confirms the prefilled subject, and uses `r c` to prove the amended
content and message in a clean two-commit history. The amend path also proves
the stopped asynchronous process is reaped before the next Git subprocess. It
then creates five commits reachable only through side refs and drives `A A`
clean pick, `A a` no-commit apply, and genuine content plus add/add conflicts through
resolution plus status-row staging/continue, abort, and skip. Each path verifies
HEAD, index, worktree, sequencer cleanup, dispatch state, and non-modal conflict
handling against real Git.

`lem-yath/src/git-blame.lisp` adds the configured everyday current-file blame
workflow independently of Legit: `C-c M-g b` follows Magit's file dispatch and
`SPC g B` opens it directly. Git receives the live buffer through bounded
`--contents -` input, including unsaved lines, and line-porcelain output is
rendered in a read-only chunked view. Ordinary `j`/`k` remain Vi movement;
`gj`/`gk` and `C-j`/`C-k` move by chunk, `gJ`/`gK` find the next/previous chunk
from the same commit, `M-w` copies the full hash (or an active region), `RET`
opens a bounded `git show` child, and nested `q` returns through the exact source
buffer and point. The physical gate covers an unsaved Lisp edit, external-line
attribution, navigation, copy, commit inspection, cleanup, and source undo.
Removal/reverse/style/recursive-reblame and inline diff preview remain outside
this focused addition-blame implementation. Bisect is supplied separately by
the Legit integration described above.

### Configured VCS dispatch and time travel — `lem-yath/src/git.lisp`, `src/apps/timemachine.lisp`

The flake wrapper packages both Git and `jj`. `SPC g g` derives the root from
the visited filename and prefers Jujutsu in a colocated workspace; otherwise it
opens Legit at the Git root. `SPC g G` forces Git and `SPC g J` forces
Jujutsu. `.git` files are accepted throughout the patched root detection, so
Legit, project dispatch, the gutter, and time travel work from linked
worktrees. The repository-specific Jujutsu porcelain renders `jj status` plus
30 row-aware history entries. Its Evil-compatible core uses `C-j`/`C-k` or
`g j`/`g k` for adjacent revision rows; `.`, `[`, and `]` jump to the working
copy or a visible parent or child, prompting over annotated exact choices when
a relationship branches. `c` edits the selected description, `C` commits the
working copy, `o` prompts while creating a child, and `O`, `I`, and `A`
immediately create a child or insert a change before or after the selected row.
`a` opens the selected-row absorb workflow, `e` changes the working copy,
`s` to open squash configuration and native patch selection, `r` to open a selected-row rebase
popup, `_` to open a revert popup, `R` to open a restore popup, `S` to open a
partial-patch split view,
`u`/`C-r` to undo/redo operations,
`b` to manage local bookmarks, confirmed `x` to abandon, `d` or Return to
browse `jj show`, `g r` to refresh, `?` for help, and `q` to unwind first to
history and then the exact source buffer. Local bookmark names render directly
on their revision rows. The `b` popup retains Majutsu's `l/c/s/m/M/r/d/f`
local core: list, create, create-or-set, move, allow-backwards move, rename,
confirmed delete, and confirmed forget. Its list is a nested read-only view;
every mutating action refreshes bookmark labels without losing the selected
revision. The squash popup retains Majutsu's `s s` default: it moves the selected
change into its sole parent and accepts jj's complete prefilled combined
description. `r`, `f`, and `t` toggle the initiating row as revision, source,
or destination; `o`, `a`, and `b` choose destination, insert-after, or
insert-before placement. `- r/f/t/o/A/B` instead prompt over annotated history
while accepting arbitrary revsets, `- -` supplies one fileset expression,
`- k` keeps emptied sources, `- I` permits immutable rewrites, and `c` clears
the mutually exclusive revision selections. `i` freezes that state and opens
a bounded native file/hunk/changed-line selector whose `s` or Return moves only
the selected patch through a private direct-argv diff tool. Empty selections,
cross-hunk regions, and partial changed-line selection in added/deleted files
fail closed. Partial and fileset squashes retain both descriptions and their
source row when changes remain; a truly emptied default source selects the
rewritten parent. Cancellation and invalid revsets are non-mutating, and roots
and revision-mode merges fail before the popup. The rebase popup binds
the selected row as its source: Return/`b`, `s`, and `r` choose jj's branch,
source-with-descendants, or exact-revision mode, while `a` and `B` insert that
revision after or before the destination. A Prescient prompt offers bounded
history IDs with descriptions but accepts an arbitrary nonblank revset; Lem
then confirms before mutation and preserves the source row after success.
Majutsu's duplicate key split is also retained: lowercase `y` opens a compact
placement popup whose Return/`y`, `o`, `a`, and `b` actions duplicate the
selected row onto its existing parent, onto a prompted destination, or after
or before a prompted revision. Uppercase `Y` performs the existing-parent
case immediately. Destination prompts share the annotated Prescient revision
history, accept arbitrary nonblank revsets, and every successful form keeps
point on the original revision.
The `a` absorb popup follows pinned Majutsu's log behavior. With no explicit
endpoint, `a` or Return passes the initiating row as `--from`; `f` and `t`
toggle that row as the source or destination, while `- f` and `- t` accept an
arbitrary nonblank revset through the annotated history prompt. `- -` supplies
one arbitrary fileset expression or literal path, `- I` permits immutable
rewrites, and `c` clears both endpoints. If only a destination is selected,
the source remains jj's working-copy default. Cancellation is non-mutating,
execution uses direct argv, CLI refusal leaves history unchanged, and success
retains the initiating row when it still exists.
The `_` revert popup follows Majutsu's selected-row defaults: the source and
destination start at that revision and the reversal is inserted after it. `r`
changes the source revset, while `o`, `a`, and `b` select a prompted onto,
insert-after, or insert-before destination; `c` restores the defaults and `_`,
`V`, or Return executes. Both annotated prompts accept arbitrary nonblank
revsets. Cancellation and invalid sources are non-mutating, successful
execution retains the selected source row, and packaged `jj` 0.35 receives its
equivalent `--destination` spelling for Majutsu's newer `--onto` behavior.
The `R` restore popup preserves Majutsu's log-level default: with no selection,
`r` restores the working copy from its parent. `f`, `t`, and `c` toggle the
selected row as `--from`, `--into`, or `--changes-in`; `- f`, `- t`, and `- c`
instead prompt over annotated history while accepting arbitrary nonblank
revsets. `- -` supplies one arbitrary fileset or literal path, `- d` preserves
descendant content, `- I` permits immutable rewrites, and `x` clears all three
revision selections. From/into selections exclude changes-in exactly as in the
pinned transient. `- i` freezes that configured range and opens a bounded,
read-only native selector. `H` or Space toggles a hunk, `F` toggles its file, a
Visual selection followed by `R` toggles changed lines within one hunk, `C`
clears the selection, and `C-j`/`C-k` navigate hunks; `r` or Return
executes and `q` cancels. The private direct-argv diff tool gives jj the
complement patch, so only selected changes are restored and unselected changes
remain byte-for-byte represented in the working copy. Empty selections,
cross-hunk regions, and partial changed-line selection in newly added or
deleted files fail closed; complete hunks and files remain selectable.
Execution uses direct argv, reports CLI refusal without mutation, refreshes the
graph, and retains the initiating row.
The `S` split view renders the selected row's bounded Git-format diff without
making it editable. `H` or Space toggles a hunk, `F` toggles its file, a Visual
selection followed by `R` toggles changed lines within one hunk, and `C` clears
the selection. `C-j`/`C-k` and `]`/`[` move between hunks. `o`, `a`, and `b`
choose an onto/after/before revset, `c` restores the existing parent, and `p`
toggles jj's parallel layout; `s` or Return prompts for the selected change's
description and executes, while `q` cancels. Execution gives `jj split` a
private temporary diff tool that reconstructs the selected patch using direct
argv and verified sibling `left`/`right` directories. The view refuses empty
or non-textual revisions, patches over 8 MiB, execution without a selection,
cross-hunk regions, and partial changed-line selection in newly added or
deleted files; complete hunks and files remain selectable. Success restores
the history row by change ID.
Every subprocess uses direct argv; the history is bounded and refresh preserves
the selected change ID when that change still exists.
`scripts/jj-porcelain-test.sh` drives the complete loop through the installed
ncurses editor and real `jj` in a metacharacter-bearing repository path,
including the shared message editor's exact prefill, mode-local finish/abort
keys, non-mutating abort, exact multiline describe submission, selected-row
restoration, multiline working-copy commit, retained file content, and
selection of the fresh child working copy. Mutation failures leave the editor
open for correction; a successful mutation closes it before refresh so a
refresh failure cannot expose a retry path that repeats the mutation. The gate
also covers sole-parent/child navigation, root refusal, working-copy return,
exact selection between two visible children, all three direct new-change
placements, their graph rewrites and undo cleanup, squash popup cancellation,
exact multiline combination, content movement, parent restoration, root
refusal, both rebase cancellation paths,
content-bearing sibling rebase, row restoration, invalid self-destination, and
the complete local bookmark lifecycle with inline-label and nested-list checks.
It also drives duplicate-popup cancellation, immediate parent duplication,
onto/after/before placement, content retention, graph rewrites and fixture
undos, point preservation, and invalid-destination refusal. Revert coverage
drives popup cancellation, selected-row defaults, prompted onto and
insert-before placement, exact graph and file-state effects, operation undo,
point preservation, invalid-source refusal, and isolated fixture restoration.
Absorb coverage drives endpoint selection and clearing, cancellation, the
selected-row default, a prompted source plus selected destination, fileset
scoping, immutable-override transport, Return execution, operation undo,
source/destination row retention, invalid-revset refusal, and isolated fixture
restoration while checking the exact revision contents and remaining diff.
Squash coverage drives row selection and clearing, cancellation, the existing
whole-change `s s` default, one arbitrary fileset with immutable override,
prompted source plus selected destination, keep-emptied behavior, operation
undo, invalid-revset refusal, and isolated fixture restoration. It also opens a
three-hunk native selector, audits every local key, refuses empty execution,
checks file and hunk controls, selects one replacement through a physical
Visual region, proves only that replacement moves while the other file and
hunk remain in the source, preserves both descriptions and the surviving
source row, and undoes the exact operation.
Restore coverage drives cancellation, the argument-free working-copy default,
one-path fileset scope, explicit source revsets, selected historical destination
and changes-in modes, selection clearing, ordinary versus content-preserving
descendant rebases, immutable override transport, exact revision-tree effects,
row preservation, undo after every mutation, invalid-revset refusal, and
operation-scoped cleanup. It also opens and cancels the native three-hunk
selector, rejects empty execution and unsafe added-file line selection, checks
file and hunk controls, physically selects one tracked added line, proves the
complement preserves two unselected files, restores the initiating row, and
undoes the exact operation. Its tree observers use `--ignore-working-copy` and
an editor-side event barrier so the acceptance harness cannot create concurrent
jj operations. Split coverage
opens and cancels the two-hunk view, rejects an empty selection, checks file,
hunk, region, destination, and parallel-layout state, physically selects one
replacement from a two-replacement file, and proves real `jj split` moves only
that replacement while retaining the remainder and restoring the original
change-ID row. An empty revision is rejected without mutation.
The same repository- and revision-specific message buffer is resumed if it is
already open, preserving an unfinished edit. Majutsu's general transient
dispatch, repeated merge-placement values and shared diff-buffer selection
sessions for squash, multi-source/destination rebase selection and
advanced rebase flags, remote bookmark tracking and advance patterns,
multi-bookmark operations, multi-source/destination duplicate selection and
configurable duplicate descriptions, a shared visual multi-selection session
for revert sources/destinations, binary/conflict patch selection, word-level
selection, partial changed-line selection for added/deleted files,
conflict handling, operation log, workspaces, sparse checkout, and Majutsu's
wider arbitrary-revision/fileset/tool split options remain outside this focused
approximation.

Git status also appends navigable TODO/FIXME rows from tracked, nonbinary
files. Moving onto a row previews the exact source line and visiting it opens
that file. This is a bounded magit-todos approximation: the synchronous
`git grep` scan stops at 200 rendered results, 1 MiB of output, or five seconds,
and does not implement configurable keywords or magit-todos grouping. A small
pinned-upstream patch exposes the status-section hook used by this integration.

### GitHub Forge workflow — `lem-yath/src/forge.lisp`

The installed wrapper packages `gh`, but authentication remains owned by the
user's existing GitHub CLI and Git credential-helper setup; Lem neither reads
nor persists a token. `M-x lem-yath-forge`,
`lem-yath-forge-list-pullreqs`, and `lem-yath-forge-list-issues` open bounded
GitHub.com topic lists. `C-j`/`C-k` or `j`/`k` navigate, Return fetches a full
topic, `P`/`I`/`a` switch views, `g` explicitly refreshes, `r` opens a multiline
comment composition, `s` confirms close or reopens, `b` opens the topic
externally, and `c i`/`c p` open multiline issue or pull-request composition.
Compositions submit with `C-c C-c` and cancel with `C-c C-k`.

The current Emacs configuration sets `forge-add-default-bindings` to nil, so
the port deliberately installs no global or leader binding. A successful
explicit fetch populates an in-memory per-repository cache that Legit renders
as navigable PR/issue rows; ordinary status redraws never contact GitHub.
Every Git and `gh` subprocess uses bounded direct argv. The network-free
installed-editor gate uses a stateful fake `gh` in a repository path containing
spaces and a shell metacharacter, and exercises listing, inspection, multiline
comment and issue submission, close/reopen, cached previews, and argv secrecy.
This is a focused GitHub.com approximation: GitLab and GitHub Enterprise,
notifications, labels/assignees, review/merge administration, and Forge's
persistent offline database are not implemented.

`SPC g t` opens a read-only history buffer at the source point. `C-k` selects
the older revision, `C-j` the newer revision, `g t g` an oldest-numbered
revision, and `g t t` a revision by commit subject. `g t y` copies the pinned
12-character hash, `g t Y` copies the full hash, and `g t b` runs Git blame
against that revision's historical path in a focused read-only child buffer;
blame `q` removes the child and restores the unchanged history view. History
`q` returns to the exact live source buffer and point while removing the
history view. History follows renames, translates the anchor across changed
line counts, and rejects a currently untracked path even when that path has
older Git history; ordinary Evil `p`, `n`, and `t` remain unshadowed. Blame is
a separate text view rather than Magit's inline overlays. The installed TUI
gate drives every configured history key, verifies exact short/full kill-ring
values and revision-specific blame content, and checks nested cleanup and
reload idempotence.

### Also: git-gutter — `extensions/git-gutter/` (`lem-git-gutter`), in the image. Shows
add/modify/delete marks in the gutter. Lem-yath replaces the upstream global mode
with a buffer-local lifecycle matching Emacs `prog-mode`: programming files update
after edits and saves, while prose and utility buffers have neither marker state nor
a reserved gutter column. The installed-wrapper `scripts/vcs-test.sh` gate uses a
real linked worktree to render `+`, `~`, and `_`, checks clean-line composition with
another left-gutter provider, mode transitions, a real idle debounce refresh and
undo, cleanup, and reload safety.

---

## 8. Language modes

The upstream modes below are built into the nix `lem-ncurses` image (via
`lem/extensions`, unless noted `#+sbcl`, which is fine since the image is SBCL).
The native Org mode is instead supplied by lem-yath's own ASDF system. Package
is `lem-<name>` and the major mode `lem-<name>:<name>` unless noted.

**Programming:** `c-mode`, `go-mode`(+LSP, call-graph), `rust-mode` (NO LSP, see §5),
`python-mode`(+LSP, run-python REPL, call-graph), `js-mode`(+LSP),
`typescript-mode`(+LSP), `vue-mode`(+LSP), `ruby-mode`, `perl-mode`(+LSP),
`elixir-mode`(+LSP, `#+sbcl`), `erlang-mode`(+LSP), `haskell-mode`, `ocaml-mode`,
`scala-mode`, `kotlin-mode`(+LSP), `java-mode`, `swift-mode`(+LSP), `dart-mode`,
`lua-mode`(+LSP), `nim-mode`, `zig-mode`(+LSP), `clojure-mode`(+LSP, nREPL repl.lisp),
`scheme-mode` (`#-clasp`), `coalton-mode`, `elisp-mode`, `lisp-mode` (full SLIME, below),
`asm-mode`, `wat-mode`, `posix-shell-mode`, `sql-mode`, `terraform-mode`(+LSP),
`nix-mode` (LSP disabled, §5).

**Markup / data / config:** lem-yath's native `org-mode`, `markdown-mode`,
`asciidoc-mode`, `html-mode`, `css-mode`, `xml-mode`, `json-mode`, `yaml-mode`,
`toml-mode`, `dot-mode` (Graphviz), `makefile-mode`, `patch-mode`, `review-mode`,
`documentation-mode`.

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

Lem-yath's global `SPC m e e` wrapper deliberately calls the native
last-expression evaluator instead of Lem's region-sensitive
`lisp-eval-at-point`. This matches the configured Emacs `eval-last-sexp`
command in both Normal and Visual states: only the complete form immediately
before point is evaluated, while source text, point, and any Visual selection
remain intact. Evaluation errors open Lem's native SLDB pane and can be
dismissed back to the unchanged source buffer. `scripts/lisp-eval-test.sh`
drives the physical chord through all of those paths against the self-connected
Common Lisp runtime.

### paredit-mode — `extensions/paredit-mode/paredit-mode.lisp` (`lem-paredit-mode`)
Real structural editing: `paredit-slurp`, `paredit-barf`, `paredit-splice`(+fwd/bwd),
`paredit-raise`, `paredit-wrap-round`, `paredit-kill`, `paredit-forward`/`-backward`,
`paredit-meta-doublequote`, smart paren/bracket/brace/quote insertion & deletion
(`paredit-mode.lisp:67-617`, keys at line 617). `(paredit-mode)` to toggle.

### markdown-mode — `extensions/markdown-mode/` includes literate **eval-block** support
(`markdown-eval-block`, `interactive.lisp:105`) and a `preview`/`preview-default` generic
(`internal.lisp:6,29`) for rendering. (Aligns with Lem's "living canvas" vision.)

### Editable Org capture — `lem-yath/src/org-capture.lisp` (verified approximation)

`SPC o` now follows the configured Org capture interaction rather than writing
after a one-line prompt. A reload-stable minor map presents the one-key `i/t/p/r`
selector, then opens a private Org buffer in Insert state with point at `%?`.
The four audited templates retain their exact heading levels, TODO prefixes,
CREATED timestamp, public UUID, and inbox-versus-file placement. An active
contiguous Visual selection fills `%i`; for a local file, `%a` is a bounded
file-and-line Org link.

`C-c C-c` inserts the complete edited fragment into the current live target
buffer and saves it, preserving pre-existing content and marker-tracked source
points. `C-c C-k` discards it, and `C-x C-s` cannot bypass finalization. Template
cancellation, finalization, abort, buffer death, and source reload remove their
buffer-local hooks and restore the exact origin window, point, and Vi state.
Only one session can exist; invoking `SPC o` again focuses it. The implementation
is intentionally the configured four-template surface, not Org's general
template tree, arbitrary expansion language, remote targets, or full stored-link
provider ecosystem.

`scripts/notes-test.sh` retains the pure filesystem placement suite and also
drives the real ncurses editor through the production `SPC o`, `i/t/p/r`,
`C-g`, `C-x C-s`, `C-c C-c`, and `C-c C-k` paths. It proves `%?`, `%i`, `%a`,
metadata, public ID creation, single insertion, exact Normal and Visual origin
restoration, hook ownership, reload cleanup, and post-reload reuse.
It also proves that a pre-existing private buffer name is preserved and the
capture request fails closed without leaking hooks or session state.

### Native Org-roam graph — `lem-yath/src/roam.lisp`, `roam-backlinks.lisp` (verified approximation)

The node and capture paths recursively index canonical `.org` and `.md` files
below startup-cached `$WORKDIR/roam`. Org file and ID-bearing heading nodes plus
pinned md-roam YAML IDs, titles, aliases, and tags share the completion surface
used by find, insert, random, and the configured five-template capture flow.
Individual files, aggregate bytes, scanner output, pathnames, files, nodes,
reference declarations, and combined backlink/reflink occurrences all have
explicit limits; reads verify the opened regular file descriptor and
containment beneath the canonical roam root.

Canonical Markdown files below that roam root receive a buffer-local md-roam
minor mode. Its `C-c C-o` follows a unique `[[Title]]`, alias-first
`[[label|Alias]]`, or ID target. A missing target enters the same non-inserting
capture flow without changing the source buffer; duplicate names are refused.
The universal prefix opens an existing target in another window. Because Evil
Normal state retains `C-u`, that prefixed route is `C-z C-u C-c C-o` from
Normal state. Escaped link syntax and links inside Lem-recognized fenced code
blocks remain literal. Ordinary Markdown files outside the roam root do not
receive the binding. `scripts/roam-test.sh` exercises these paths with physical
terminal keys and also proves one reload-stable Markdown hook.

`M-x org-roam-buffer-toggle` supplies the persistent `*org-roam*` view in the
configured right-side window at 0.4 of the display width. One asynchronous
immutable snapshot maps bracketed Org `id:` links and pinned md-roam
`[[Title or Alias]]` links to their unique nodes. It also indexes direct file or
heading `ROAM_REFS` and reproduces Org-roam's separate `Reflinks:` section for
matching Org citations, md-roam/Pandoc citations, and ordinary Org or Markdown
HTTP(S) links—the forms present in the configured corpus. The panel follows the
nearest file or ID-bearing heading from cheap span lookups, retains the last
valid node through prompts and unrelated buffers, sorts every occurrence by
source-node title like Org-roam, and renders the source title, complete outline,
and a bounded direct-content preview. Duplicate target IDs and ambiguous wiki
names fail closed rather than pointing at an arbitrary note.

`Return` revalidates the source node and exact link or citation literal before
opening its line and column in the recorded main window. Saving a canonical Org
or Markdown note while the panel is visible coalesces an asynchronous
full-snapshot rebuild;
`g` provides the same refresh for out-of-band changes, and `q` restores a main
window before closing the side window. The save hook does no indexing while the
panel is hidden, avoiding permanent background work on the laptop.
The panel refuses to delete a right-side window after another subsystem has
replaced it, and configuration reload invalidates workers, closes the owned
window, kills the private buffer, and removes its post-command hook.
`scripts/roam-backlink-test.sh` proves ID and md-roam resolution, Org and
Markdown citation/URL reflinks, block/comment exclusion, outline/preview
ownership, M-x display, automatic node switching, exact Return navigation,
stale refusal, manual and save-driven refresh, side-window ownership, close,
and reload cleanup through the packaged ncurses editor.

This remains an in-memory snapshot rather than claiming Org-roam's persistent
SQLite database. External changes require `g`; there is no always-on incremental
autosync, arbitrary non-HTTP(S) third-party reference-scheme extraction,
or Markdown inline-file backlink extraction. Unsaved note geometry is not
applied to the disk-derived graph and is shown as requiring a save.

### Host-gated Org nodes projection — `lem-yath/src/org/nodes-sync.lisp` (verified approximation)

The configured external PostgreSQL projection is installed as two local Org
save hooks without embedding database logic in Lem. The default allowed host is
`nova`; `YATH_NODES_SYNC_HOSTS` retains the configured colon-separated override.
On an allowed host, an existing canonical `.org` file beneath the
startup-cached `$WORKDIR` runs the separately packaged
`nodes-org-sync --quiet --file FILE` command after save. The command and file
are distinct argv elements. Syncthing conflict names, files outside the root,
and in-root symlinks resolving outside it do nothing. Successful background
runs never switch buffers; failures are bounded, reported, and retained in
`*nodes-org-sync*`.

Automatic IDs remain disabled, matching the active Emacs preference. Enabling
`*org-nodes-auto-id-enabled*` adds IDs before the file is written only to
recognized TODO, scheduled, deadline, `reading`/`readlist` tag, and configured
reading-file headings. Source-block lookalikes and ordinary headings are
excluded. `M-x lem-yath-org-nodes-ensure-actionable-heading-ids` provides the
same manual promotion while automatic IDs remain off, and
`M-x lem-yath-org-nodes-sync-current-file` supplies the explicit sync entry.
The hooks survive source reload exactly once per Org buffer.

`scripts/org-nodes-sync-test.sh` physically saves files through packaged
ncurses Lem and proves the host/root/conflict policy, default and opt-in ID
behavior, exact canonical argv with metacharacters, asynchronous success and
failure, source-buffer preservation, symlink refusal, and reload idempotence.
Each Lem-launched projector is additionally bounded to five minutes and 1 MiB
per output stream; acceptance against the live `nova` database remains external.

### Native Org mode — `lem-yath/src/org/` (verified approximation)

Lem-yath adds a prose-class `.org` major mode; this is a local implementation,
not GNU Org or an upstream Lem extension. A custom parser applies semantic faces
to headings, exact configured TODO keywords, tags, priorities, timestamps,
drawers, lists/checklists, tables, bracket links, and source blocks. The
hidden-line patch adds the renderer and vertical-movement primitive needed for
non-destructive folding. Local `Tab` cycles folded/direct-children/full-subtree
visibility with the configured exact `" [...]"` ellipsis, while `Shift-Tab`
cycles the first global overview/contents/all implementation. Changes clear
folds, arbitrary movement into hidden text reveals it, and hidden rows are not
written to disk.

`src/org/modern.lisp` reproduces the active `org-modern-mode` hook as a
display-only terminal projection. Folded and expanded headings use distinct,
depth-sensitive one-cell symbols; TODO keywords, priorities, and terminal tag
groups receive compact labels; bullets, checkboxes, tables, horizontal rules,
block/keyword markers, timestamps, and internal/radio targets receive the
corresponding modern glyphs. The transformer skips source-block bodies,
composes with the existing indent-guide/Dirvish display path, and preserves
the source character count and terminal-cell width on every row. It therefore
does not modify the buffer, saves, undo history, or source-relative cursor
geometry. `M-x org-modern-mode` provides the buffer-local toggle.

`scripts/org-modern-test.sh` verifies all replacement glyph widths, logical
and real-ncurses projection, source-block exclusions, fold-state updates,
toggle and reload ownership, exact cursor position, and unchanged buffer and
disk bytes. Graphical font scaling, pixel spacing, fringe markers, dynamic
progress-cookie sizing, and exact `org-modern-agenda` decoration are outside
the ncurses/custom-agenda presentation model.

`src/org/download.lisp` supplies the two configured org-download entry points.
`M-x org-download-yank` reads an HTTP(S) or local `file:` URL from the kill
ring; `M-x org-download-clipboard` captures PNG data with `wl-paste` when
`XDG_SESSION_TYPE=wayland` and `xclip` otherwise. Both write org-download's
timestamped basename directly below startup-cached `$WORKDIR/media/`, insert a
seconds-precise `#+DOWNLOADED:` annotation and source-relative `file:` link,
and leave the Org buffer unsaved. Clipboard capture also creates or reuses the
current heading's Org ID. One Normal-state undo removes the complete buffer
edit but deliberately does not delete the already captured file, matching the
package's ordinary filesystem/undo boundary.

Network and clipboard readers use direct argument vectors behind a hard
timeout and 64-MiB stream bound. URL text enters curl through stdin config
rather than process argv; HTTP redirects remain restricted to HTTP(S). Secure
same-directory temporary files, regular-file checks, image/PDF signatures,
sanitized names, collision refusal, and retained buffer change groups prevent
partial links or files on failure. `scripts/org-download-test.sh` drives both
exact commands through physical M-x input and proves Wayland/X11 selection,
URL secrecy, relative links, local file URLs, timestamps, modes, one-step undo,
invalid/oversize cleanup, invalid-URL refusal, and read-only preflight. Unlike
the pinned Emacs package, URL retrieval is synchronous and images are not
rendered inline in the ncurses buffer; non-Linux clipboard backends are outside
the configured deployment.

The bounded editing layer supplies visible-row `j/k`, GNU-style
`gh/gl/gk/gj/gH` element-tree navigation, Org-aware `o/O`, heading insertion,
and context-dispatched Meta editing. `M-h/l` changes one heading or list item
and moves a table column, while falling back to prose-word motion. `M-k/j`
moves heading/simple unordered-list trees or table rows. `M-H/L` uses complete
subtree/list-tree scope or deletes/inserts a table column;
In Normal state, `M-K/J` deletes/inserts a table row, adjusts the selected timestamp endpoint
on a CLOCK line, or drags one literal non-CLOCK line. CLOCK endpoint edits
recompute the duration suffix; cross-entry `org-clock-history` coupling remains
outside the bounded in-buffer model.
In Visual state, `M-h/l` changes every selected heading or contiguous list
zone and retains the selection; table-column dispatch follows GNU Org's
expanded moving endpoint. `M-k/j` moves consecutive selected sibling
subtrees, or transposes any other selection by complete logical lines while
keeping the selection on the text that moved. Visual Block retains Block state.
The shifted `M-H/L/K/J` commands reproduce GNU Org's expanded-endpoint
dispatch and exit Visual state only after a successful edit; region lists
include continuation and child lines. Visual `M-K/J` adjusts only the CLOCK
timestamp endpoint under the moving end of the selection and recomputes a
closed clock's duration. Forward and reverse selections share that behavior,
and the edit is one undo transaction. Top-level promotion, unsafe ordered or
tab-structured lists, and unsupported CLOCK positions or shapes fail
byte-identically with the selection intact. Type-matched source blocks,
including mismatched nested end markers, are excluded from heading, list, and
table dispatch; literal `M-K/J` line dragging remains available.

The always-active Evil-Org base motions are also local to `.org` buffers.
`gh/gl/gk/gj` reproduce `org-up/down/backward/forward-element` across
headlines and sections, paragraphs and affiliated keywords, planning lines,
property drawers, nested list items and plain lists, table rows and formulas,
and matched quote/source blocks; `gH` climbs to the top ancestor headline.
Counts, Normal and Visual destinations, exclusive operator shapes, empty
elements, and malformed blocks follow the pinned Emacs oracle.

Immediate consecutive `#+TBLFM:` lines participate in structural table edits
like pinned GNU Org. Column insertion, deletion, and movement repair local
numeric `$N` references; row insertion, deletion, and movement repair numeric
`@N` references using data-row rather than horizontal-rule ordinals. A deleted
direct field formula is removed, other deleted references become `INVALID`,
and references after the edit shift numerically. Numeric references inside
`remote(...)` and named references remain unchanged. A blank line severs the
association, so the following formula text is left byte-identical. Normal,
Visual, and multi-cell operator paths share this repair pass, and one Vi undo
restores the table and every associated formula line together. Deleting the
terminal field of a formula range would make its target invalid, so that rare
case is refused before mutation instead of requiring GNU Org's recovery undo.
`(`/`)` use the pinned Emacs double-space sentence rules across wrapped prose;
inside tables they use GNU Org field boundaries and its complete-count behavior.
`{`/`}` use structural paragraph units rather than generic blank-line motion:
headings, prose, flat one-line lists, item-wise continuation/nested lists,
tables with associated `#+TBLFM`, affiliated keyword-plus-prose groups,
property lines, blank-separated block bodies, and consecutive clocks all match
the pinned GNU Org endpoints. Counts and negative counts work in Normal,
Visual, and operator-pending states. Exclusive operators reproduce Evil's BOL
linewise promotion and its mid-line newline exclusion, while Normal and Visual
motions retain the destination cursor and characterwise selection behavior.

A separate on-demand boundary model and Vi adapter implement all eight bindings
in the active Evil-Org text-object theme: `ae/ie`, `aE/iE`, `ar/ir`, and
`aR/iR` in operator-pending and Visual states. The bounded model covers inline
markup, bracket/plain links, balanced citations and citation references,
same-line and paragraph-bounded multiline standard, labeled-inline, and
anonymous inline footnote references, bounded footnote definitions with
paragraph and nested-inline children, whitespace entities, explicit line
breaks, timestamps, GNU-style depth-three
subscript/superscript objects, same-line
single/double-dollar and `\(...\)`/`\[...\]` LaTeX fragments, bounded multiline
double-dollar and delimited LaTeX fragments, flat TeX macros/entities, table
cells, paragraphs and rows, flat matched blocks,
point-sensitive space-indented ordered and unordered items/lists with wrapped,
nested, mixed-level, and blank-separated paragraphs, tables with
associated formulas, matched property/LOGBOOK/generic drawers with
node-property, CLOCK, and paragraph children, headline elements, sections,
and heading ancestry. Supported inline objects remain available in generic
drawer prose, CLOCK lines expose timestamps, and property values remain
opaque like pinned Org. It
preserves Evil-Org's characterwise versus linewise
register/Visual shapes, original-point count anchoring, ancestry climbing,
owned post-blank, and reverse or repeated Visual expansion without taking
ownership of normal `a/i`, stock `aw/iw`, surround, or operator Snipe.
Tab-structured list contexts fail object, element, and greater-element requests
closed; destructive ordered-list repair also refuses partial continuation items
and same-level mixed marker families. Empty drawer interiors, orphan-property
lines, malformed or unclosed drawers, and nested or unclosed block roots fail
the unavailable families closed. Malformed citations and recognized
unsupported or ambiguous inline/cell syntax fail object requests closed;
empty leaf-item or inner-subtree ranges abort. These aborts occur before mutation and
preserve text, registers, and an existing Visual selection. Type-mismatched
inner end markers remain literal inside an otherwise matched flat block.
Footnote definitions retain their own marker and trailing-blank ownership while
delegating to bounded paragraph, affiliated table, nested list, recursive block,
matched drawer, CLOCK, and inline-object children. Child ranges are clamped to
the definition contents, and counted greater-element ancestry climbs from a
nested list child through its list parents to the definition. Definition child
types outside this bounded set remain unsupported. Footnote-looking syntax that
crosses an Org paragraph separator fails closed instead of falling through to a
paragraph object.

The exact
`TODO → NEXT → WAITING → HOLD → SOMEDAY | DONE → CANCELLED`
sequence with immediate saving, checklist continuation/toggling, bracket-link
insertion plus file/URL/mailto/ID opening, and basic table alignment, cell
navigation, and row insertion. Normal-state `t/T`, `Return`, and `M-o` are
intentionally not rebound, preserving the configured Evil-Snipe, Evil Return,
and next-window behavior.

`scripts/org-test.sh` drives the real ncurses editor and verifies mode selection
and faces, negative key ownership, local and global visibility cycles, atomic
hidden-row movement, folded-tail and generic-reveal behavior without file
mutation, safe heading insertion before a sibling and at an unterminated EOF,
the complete configured TODO cycle with immediate persistence, reload and
multi-buffer kill cleanup, checklist `O`/`o` targeting and toggling, table row
and cell targeting plus indented and hline-only alignment, relative file-link
opening, current-heading versus complete-subtree scope, list-tree movement,
table column/row movement, inverse whole-buffer hashes, nested outdent and
star-bullet conversion, source-block fake-heading boundaries, hline column
targeting/navigation, plus fail-closed ordered and structurally tabbed lists,
point-only continuation indentation, blank-separated list movement,
source-block structural dispatch, immediate/blank-gap formulas, CLOCK-line
dragging, degenerate tables, GNU numeric formula repair, `remote(...)`
exclusion, direct-formula removal, and one-step formula/table undo. Mouse hit-testing,
overlapping nested folds, non-file link variants, and several broader commands
above remain outside this focused gate.

`scripts/org-operator-test.sh` independently drives the installed-wrapper TUI.
Its sentence/paragraph section resolves `(`/`)`/`{`/`}` in Normal, Visual, and
operator maps and checks double-space and wrapped sentences, table counts,
adjacent and blank-separated structures, complex lists, property lines, block
paragraphs, formula tables, clock groups, forward/backward counts, deletion
shape, registers, undo, and Visual selection against the pinned Emacs oracle.
It exercises normal `d/x/X` against safe nested ordered lists, `[@N]` counter
cookies, partial continuation-line deletion refusal, complete continuation-item
repair, headline-tag alignment, single-cell
table padding, counts, Visual deletion, registers, and one-step undo. It also
dynamically verifies doubled, counted, motion, and Visual `<`/`>` ranges across
headings, safe unordered and ordered lists, the top-level whole-list special
case, table columns and whole tables, and prose, including leftward movement,
wide Visual cell ranges, count nonmultiplication, undo, and fail-closed
top-level boundaries. Its formula case proves range-driven column movement,
numeric reference repair, and one-step undo. It dynamically exercises all eight text-object
bindings with delete/yank operators over
opaque/nested markup, bracket/plain links, timestamps, table cells/rules and
formula ownership, scripts, same-line and bounded multiline LaTeX
fragments/macros, same-line and multiline footnote references, definition
marker/body/post-blank ownership, affiliated tables, nested lists, recursive
blocks, matched drawers/CLOCK children, and counted ancestry, whitespace
entities, explicit line breaks, malformed-dollar fallback, paragraphs, headlines, flat leaf
and recursive blocks,
point-sensitive and empty lists, owned post-blank, and subtrees. It verifies
object/element count anchors, footnote count traversal, adjacent, empty, and
structurally rich definitions, would-be drawer splitting, nested markup,
paragraph splitting, malformed footnote refusal,
source-block opacity, unsupported-syntax barriers, subtree
ancestry count, character/line registers, representative one-step undo,
normal-state aborts (including nested and opaque unsupported syntax), and exact
Visual-abort preservation. It statically
resolves all eight Visual routes and dynamically covers characterwise,
linewise, reverse, and repeated selection through `ae`, `ar`, and `aR`. It
also verifies normal `a/i`, `daw`, `ys`/`ds`/`cs`, and that Visual defaults and
operator-Snipe `x/X` routing remain intact.

The pinned Evil-Org base bindings `0/$/I/A` are exact for the configured
`org-special-ctrl-a/e=nil`: endpoints remain literal, `I` starts at column zero
on real headings and items but at indentation elsewhere, and `A` appends after
headline tags. Source-block heading/list lookalikes retain ordinary Evil
indentation behavior.

Normal `d` follows the pinned Evil-Org repair boundary after ordinary Evil
deletion: safe ordered-list segments are renumbered by indentation, explicit
`[@N]` counter cookies restart numbering, nested levels remain independent, and
headline tags are realigned to the active terminal profile. Continuation lines,
tab-structured items, and mixed ordered/unordered markers at one indentation
cannot yet be repaired exactly, so those deletions abort before text or registers
change. Normal one-character `x/X` inserts replacement table padding like
`org-delete-char`; counted and Visual deletion deliberately retain ordinary Evil
semantics.

`src/org/date-reader.lisp` and `src/org/planning.lisp` provide GNU Org's
in-buffer `C-c C-s` scheduling and `C-c C-d` deadline chords. The shared date
prompt displays the existing field—or today—as a bracketed default and an
adaptive one- or three-month terminal calendar. It accepts empty/default,
validated ISO and partial numeric dates, English month and weekday names, ISO
weeks, today/tomorrow/yesterday, and signed hour/day/week/month/year or weekday
offsets. A doubled sign such as `++1m` is relative to the existing field; a
single sign is relative to today. Like the configured GNU Org default,
explicit prompted years are constrained to 1970–2037. `Shift` arrows move by
day/week, `M-Shift` arrows and `</>` move by month, `C-v`/`M-v` by quarter, and
`C-.` returns to today. Insertion creates the structural line immediately below
the current heading, replacement preserves the other planning field and its
order. Rescheduling also retains the field's post-weekday time, repeater, and
warning/delay syntax. One universal prefix removes only the requested field
(including the complete line when it becomes empty); two universal prefixes
prompt for `Warn starting from` or `Delay until`, compute the absolute day
distance from the planning date, and replace the final `-Nd`/`--Nd` cookie
without changing an earlier repeater. A missing field refuses the double-prefix
operation before prompting. In a Visual region the same commands map over all
selected headlines, including nested ones, and prompt once per headline. Like
pinned GNU Org, cancelling a later prompt retains earlier region edits; `C-z`
keeps the linewise selection active in Emacs state for `C-u` removal. Ordinary
Org-buffer edits remain modified but unsaved, matching the current Emacs
configuration; agenda mutations retain their separate immediate-save policy.
Read-only refusal occurs before prompting, and each completed command is one
undo step.
`scripts/org-planning-test.sh` drives both physical chords through the packaged
ncurses editor and proves those boundaries.

The same reader supplies GNU Org's ordinary timestamp workflow. `C-c .` and
`C-c !` insert or replace active `<...>` and inactive `[...]` timestamps at
point. Their bracketed prompt defaults to today or the timestamp at point and
accepts the shared date forms, a start time, or a start/end time range.
Replacement recomputes the weekday and preserves repeater and warning suffixes;
one universal prefix supplies the current time when none is entered, and a
double universal prefix inserts the current active or inactive timestamp
without prompting. Two successive active or inactive timestamp commands append
`--` and a second timestamp, including mixed-delimiter ranges; updating an
existing timestamp leaves point after it so the same succession works there.
An unrelated or cancelled command breaks the succession, and only the range
start retains an existing repeater or warning suffix. Ordinary-buffer mutations
remain unsaved and each command is one undo step.

At a timestamp, `Shift-Left`/`Shift-Right` and terminal-safe `C-c Left`/
`C-c Right` move its date while preserving delimiter type, time range, and
suffix. At a heading the same keys cycle the configured TODO sequence in the
corresponding direction and retain the profile's immediate-save behavior. In
a list they cycle the complete sibling level through GNU Org's configured
bullet order, including top-level star exclusion, ordered renumbering, and
the indentation change required by wider bullets. On a property line they
cycle through the nearest inherited `NAME_ALL` declaration, falling back to
buffer-wide `#+PROPERTY` values and GNU Org's unchecked/checked cycle for
checkbox-shaped values. Quoted multiword values, `NAME_ALL+` appends, reverse
cycling, wraparound, unlisted current values, and the unrestricted `:ETC`
marker follow GNU Org; edits remain unsaved and undo as one command. Missing
or malformed declarations, an unchanged single value, and read-only buffers
refuse before mutation. In a table data field the same horizontal keys
swap the current cell with its horizontal neighbor, leave formulas attached
to their table coordinates, and move point with the cell; table edges refuse
before alignment or mutation. Tab-structured and counter-cookie list levels
fail closed rather than risk lossy repair.

`Shift-Up`/`Shift-Down` and terminal-safe `C-c Up`/`C-c Down` provide the
corresponding vertical context dispatch. On ordinary timestamps they adjust
the cursor-selected year, month, day, hour, or minute, with GNU Org's calendar
overflow, midnight rollover, five-minute unprefixed rounding, exact numeric
prefixes, and start/end range coupling; an end-time field changes only that
endpoint, and either delimiter toggles active/inactive syntax. On headings the
same keys cycle the default A/B/C priority sequence, including GNU Org's
first-step and repeated wrap through no priority, without saving. In lists
they navigate to the previous or next direct sibling at column zero. In table
data cells they swap contents with the data row above or below, skip horizontal
rules, retain formulas at their coordinates, and move point with the cell.
Missing siblings, table edges, unsupported fields, and read-only mutations
fail before changing the buffer.

The active Evil-Org additional map is also reproduced: `C-Shift-h/l` select
the previous/next TODO keyword set (a stable no-op with this profile's single
set), while `C-Shift-k/j` adjust the date or time field under point on a CLOCK
line. Closed clocks move both endpoints by the same actual delta and repair the
duration; open clocks move their lone timestamp. Cursor-selected year, month,
day/weekday, hour, and minute fields follow the pinned Org oracle, including
five-minute unprefixed rounding, exact numeric prefixes, calendar overflow,
and midnight rollover. Traditional ncurses terminals cannot distinguish
Ctrl-Shift letters from Ctrl letters, so `C-c H/L/K/J` expose the same four
commands without stealing existing `C-h/j/k/l` behavior.

The focused `scripts/org-timestamp-test.sh` resolves the ordinary, exact
Evil-Org, and terminal-fallback production keys and drives insertion,
replacement, conversion, shifting, CLOCK synchronization, prefix behavior,
duration repair, open clocks, Normal-state `M-K` endpoint editing, list-level
bullet conversion, horizontal and vertical table-cell swapping, ordinary
timestamp field adjustment, priority cycling, direct list-sibling navigation,
inherited/file-wide property cycling, checkbox fallback, cancellation,
read-only and non-CLOCK refusal, undo, persistence boundaries,
successive active/mixed ranges, existing-timestamp ranges, interruption, and
TODO dispatch through packaged ncurses Lem.

`src/org/source-editing.lisp` supplies GNU Org's source-edit workflow on
`C-c '`. A bounded source body opens without block delimiters in a dedicated
buffer using the configured Bash, Python, C/C++, Nix, or SQL mode when
available, with Fundamental mode as the explicit fallback. The configured
`org-src-preserve-indentation` behavior is retained exactly: body indentation
is not rebased, and Org's leading protection comma before `*` and `#+` lines
is removed for editing and restored on writeback. Point uses GNU Org's
end-relative line coordinates, so that comma conversion retains the same
logical character.

Inside the edit buffer, `C-c '` writes back and exits, `C-c C-k` aborts, and
`C-x C-s` writes back, saves the source Org file, and continues editing.
Ordinary exit leaves the Org buffer modified but unsaved and replaces the
complete body as one undo step. A session validates its original delimiters,
language, body, and live markers before every writeback; concurrent source
edits and read-only sources therefore fail without discarding the temporary
edit. Source/edit buffer killing and configuration reload release the paired
markers and edit buffers. `scripts/org-source-edit-test.sh` drives the physical
production chords and proves language-mode selection, local bindings,
indentation and comma conversion, point mapping, commit, abort, save-without-
exit, persistence boundaries, one-step undo, stale-source retention, and
read-only/outside-block refusal plus reload cleanup. GNU Org's prefixed live Babel-session buffer
route remains unsupported and fails explicitly.

The pinned Evil-Org `<`/`>` range operators are available in Normal and Visual
states. Heading ranges promote or demote only selected heading lines by one
level. Safe list-item ranges move by the surrounding list's indentation step
and repair ordered numbering; `>>` on the first top-level item reproduces
Evil-Org's unusual one-column whole-list shift, including continuation lines.
A same-line table range moves the current column once per selected cell
boundary; the tested short operator and motion counts still move it only once.
`>>`/`<<` shift the complete table by the configured four columns. Other text
ranges use the same four-column shift. Counts extend the selected line range
without multiplying the shift, Visual operations return to
Normal, and successful mutations form one undo step. Promotion of a level-one
heading, partial child-list outdents, continuation/tab-structured list ranges,
and formula-owning table-column moves abort before mutation.

`C-c C-c` now context-dispatches source blocks through
`src/org/babel.lisp`. The configured Bash/Shell, Python, C/C++, Nix, SQLite,
PostgreSQL SQL, and DSQ paths run with direct argument vectors, the active
Direnv-derived process environment, a 600-second timeout, and independent
16-MiB source/stdout/stderr bounds. Shell shebangs, Python's configured
interpreter override, relative `:dir`, SQLite `:db`, and the PostgreSQL
engine/user/password/host/port/database headers are supported. Passwords enter
only the subprocess environment, never argv or diagnostics assembled by Lem.
Preamble `header-args` properties use the configured file-wide form; local
block headers win.

The pinned `ob-dsq` path accepts one or more regular JSON/CSV inputs, including
metacharacters and spaces without shell parsing, plus local or cross-file
named Org tables and adjacent results of named source blocks. Named values are
materialized only as private typed temporary inputs while the direct `dsq`
process is live. `:cache`, `:convert-numbers`, `:header`, `:hlines`,
`:null-value`, and `:false-value` retain their pinned defaults and overrides;
the first returned JSON object's key order defines a finite Org table exactly
as in the pinned package, and later rows are aligned by key. Each
file/reference is bounded to 64 MiB, live external Org buffers win over disk,
and plaintext SOPS buffers fail closed. Arbitrary Elisp-evaluated `:input` and
`:var` expressions remain intentionally unsupported because Lem does not
evaluate Emacs Lisp.

The confirmation predicate matches the active Emacs policy: only SQLite and
Emacs Lisp are exempt inside an existing file below startup-cached `$WORKDIR`.
Emacs Lisp remains deliberately non-executable because Common Lisp is not a
compatible evaluator; outside trusted notes it still reaches the ordinary
confirmation boundary first. Successful output replaces an adjacent
`#+RESULTS:` as one undoable edit, database rows become finite Org tables, and
`:results none` executes without buffer mutation. Cancellation, subprocess
failure, unsupported languages, SOPS plaintext, `:var`, live `:session`,
`:async`, and unsupported append/raw/file/drawer result modes fail before
result mutation. `scripts/org-babel-test.sh` drives the physical chord through
confirmation, cancellation, undo, Python and C execution, directory and
no-result headers, trusted SQLite, DSQ files and Org references, invalid-input
preservation, and a real private PostgreSQL server.

`src/org/publish.lisp` supplies the configured HTML export and publishing
layer without depending on a headless Emacs process. `C-c C-e` opens a
GNU-Org-shaped two-key dispatcher: `h h` exports the live buffer, including
unsaved text, to a sibling `.html` file; `h o` additionally opens it; and the
`P f`/`P p`/`P a`/`P x` branch publishes the current file, composite project,
all projects, or a selected configured project. The same workflows are
available as `lem-yath-org-export-html`, `lem-yath-org-publish`,
`lem-yath-org-publish-force`, and the narrower project commands.

The project definitions retain the active configuration's shape:
`org-roam-notes` recursively converts lowercase `.org` files below
`$WORKDIR/roam`, `static` recursively copies lowercase CSS, text, JPEG, GIF,
and PNG files below `$WORKDIR`, and `org-roam` composes both into
`~/proj/web/org-publishing`. A bounded fresh ID index rewrites `id:` links to
relative HTML files and heading anchors without modifying source notes;
`.org` file links become `.html`, including ID-backed or Pandoc-derived
heading anchors. Missing or duplicate IDs remain visible and are counted
rather than silently targeting the wrong note. MathJax is enabled for HTML
math.

Project preparation scans canonical regular files without following directory
symlinks. Per-file and aggregate inputs, scanner output, Pandoc output, and
process duration are bounded. HTML and binary assets are written through
same-directory temporary files, existing non-regular or unowned outputs are
rejected, and canonical parent checks prevent an output-directory symlink
from redirecting publication. Normal publication skips outputs at least as
new as their sources; force publication replaces all outputs. Full projects
run away from the editor thread in a progress buffer and can be cancelled,
including the active Pandoc process. `scripts/org-publish-test.sh` proves the
physical live-buffer dispatcher, unsaved export, ID and file-link resolution,
MathJax, note and asset placement, incremental and forced replacement,
cancellation convergence, and symlink-escape refusal through the packaged
Lem image.

Pandoc intentionally provides broad Org reading rather than GNU Org's exact
`ox-html` DOM, generated references, CSS classes, or exporter hooks. The
configured project has no custom exporter hooks or existing downstream HTML
contract, so this is the smaller independent replacement; exact `ox-html`
consumers would still require a different backend.

This is intentionally narrower than GNU Org and Evil-Org. Richer drawer,
affiliated or non-paragraph footnote-definition children, nested-special, and
malformed text-object contexts; structural
repairs beyond the bounded `d/x/X/< />` and Visual Meta behavior; generic
Org-element movement, clocktable horizontal Shift-arrow context,
and richer list/table semantics; mouse
calendar selection, Org's exact live echo overlay, and wider timestamp
variants; prefixed live Babel-session
source editing, Elisp-valued inputs, variables/sessions and the rest of Babel's
backend/header/result matrix; in-editor LaTeX preview, non-HTML export
backends, and exact `ox-html` output remain explicit gaps. The display-only
org-modern terminal subset and initial empty Org scratch are implemented;
exact graphical org-modern, inline image rendering, and agenda presentation
remain limitations. Agenda
scanning and capture/roam workflows are separate bounded implementations
rather than services of this major mode.

### Native agenda summary — `lem-yath/src/apps/agenda.lisp`

`SPC m a` opens and focuses a read-only grouped agenda over the current Emacs
configuration's existing canonical roots: `$WORKDIR`, `$PUBLIC_ORG_DIR`, and
`$PUBLIC_ORG_DIR/mcp`. Each directory contributes only its top-level,
non-hidden lowercase `.org` files. The parser recognizes the configured TODO
sequence plus immediate Org planning lines, preserves separate SCHEDULED and
DEADLINE rows, and groups entries into overdue, today, seven-day upcoming, and
unscheduled TODO sections. Ordinary active timestamps on headings or body text
join the today/upcoming sections; inactive timestamps do not. Timed events
retain their start and optional same-day end time, date ranges expand
inclusively with occurrence indices and per-day endpoint times, and `+`, `++`,
and `.+` hour/day/week/month/year repeaters generate the same agenda
occurrences across the visible horizon. The configured `org-anniversary` diary
form expands yearly with `%d` ages, inherited category/tag metadata, and an
exact source-line visit; arbitrary Lisp diary sexps are never evaluated.
COMMENT and ARCHIVE subtrees, drawers, source blocks, and comment lines are
excluded, while completed headings can still contribute timestamp events as
in GNU Org. Rendered source rows show the effective category as their leading
field and inherited/local tags in canonical Org syntax at the end; the exact
file and line are retained as navigation properties rather than printed debug
text.

`src/apps/agenda-reminder.lisp` separately projects the pinned stock Org
planning reminders over that immutable parse result. Open deadlines appear
under today from fourteen days before their due date and while overdue;
timestamp-local warning cookies replace that boundary. Late open schedules are
forwarded to today, while a positive schedule-delay cookie suppresses the base
row until its threshold is reached. Zero-day delays retain the base row, the
boundary is inclusive, completed planning rows remain visible only at their
exact dates, and completed tasks never acquire reminder copies. A projected
row keeps its source date and gains a separate display date, so visits,
refresh identity, `H`/`L`, and other mutations still validate and edit the real
planning token. Reminder labels use the exact stock `Sched.%2dx:`,
`In %3d d.:`, and `%2d d. ago:` leaders. Rows within each date use the
configured stock `time-up`, `urgency-down`, stable source order, including
numeric one- or two-digit times and A/B/C priority offsets. Terminal urgency
faces remain a presentation difference.

`src/apps/agenda-time-grid.lisp` interleaves the pinned stock terminal grid at
`08:00`, `10:00`, `12:00`, `14:00`, `16:00`, `18:00`, and `20:00` whenever
today or a one-day view contains a timed item. It uses the exact `......`,
`----------------`, and terminal current-time strings, orders numeric one- and
two-digit starts correctly, displays same-day `start-end` ranges, and keeps
every grid/current-time row decoration-only so visits, item motion, marks, and
mutations continue to target source-backed rows.

Scanning runs away from the editor thread. Before launching a worker, refresh
captures immutable text snapshots of modified live agenda-file buffers on the
editor thread; parsing and filter-metadata enrichment therefore see unsaved
edits without touching mutable editor state off-thread. Refresh requests
coalesce behind one worker per buffer, generations reject stale results, source
failures are shown instead of becoming a false empty agenda, and killed buffers
reject late delivery. Entry lines retain exact source pathname, line, and
scanned-heading properties. In Vi state, `Return` visits that source, `gr`/`gR`
refresh, and `q` closes the explicit popup split. Evil-Org `Tab`, `g Tab`, and
Shift-Return open the exact source row in the next ordinary window, reusing an
existing window and splitting only when the agenda is alone. `gj`/`gk` and
`C-j`/`C-k` move with counts between source-backed agenda or clock-report rows,
skipping headers, empty sections, status text, and clocktable decoration while
preserving the current column. Evil-Org's `t` opens the configured one-key
TODO/NEXT/WAITING/HOLD/SOMEDAY/DONE/CANCELLED selector. A selected state updates
and immediately saves the source before refreshing. Evil-Org's `K` and `J`
raise and lower GNU Org's default A/B/C priority cookies: an unprioritized
heading starts at B, while repeated movement wraps through no priority to the
opposite bound. GNU Org's `C-c C-s` and `C-c C-d` chords set SCHEDULED and
DEADLINE fields from validated `YYYY-MM-DD`, `+Nd`, or `+Nw` input, compute the
weekday, prepend a newly added field as Org does, and replace an existing field
in place while preserving its time/repeater/warning suffix. From C-z Emacs
state, one prefix removes the requested agenda planning field and two prefixes
choose the warning/delay start date; both save immediately, revalidate the
unchanged source field, refresh, and follow a visible reminder, remaining
planning row, or unscheduled TODO row. A future positively delayed schedule
falls back to the heading's deadline row when present because Org intentionally
hides that scheduled row. Evil-Org's `ct` and GNU Org's `C-c C-q`
both replace the current
heading's local tags. The prompt starts from the existing suffix, completes
canonical colon-delimited expressions from tags found across the configured
agenda sources, removes duplicates, offers an explicit clear row for empty
input, accepts the current valid expression on Return even while add-tag
candidates remain visible, and realigns the result to the active terminal tag
column.

`src/apps/agenda-view.lisp` owns the GNU span policy separately from scanning
and source mutation. Evil-Org `gD` dispatches day, week, fortnight, month,
year, and reset views; year retains GNU Org's confirmation. Week and fortnight
selection align to Monday, month and year selection align to their first day,
and every non-summary span renders a source-linked section for every date,
including empty dates. `[[` and `]]` move backward or forward by the current
span with GNU interactive-prefix counts while retaining the relative selected
date. `.` selects today, rebuilding the same span type only when necessary,
and `gd` uses the shared named/relative date reader while preserving the
current span length. Reset returns to the established grouped summary at the
date at point; `.` then returns that summary to today, matching the separation
between GNU Org's reset-view and goto-today commands. Active filters persist
through these generation-guarded rebuilds.

Evil-Org `dd` deletes the selected complete source subtree; GNU `C-k` reaches
the same command from Emacs state. The pinned default asks before deleting a
subtree with more than one nonblank line, cancellation is mutation-free, and a
successful deletion saves before refreshing to the nearest surviving row.
Evil-Org `ce`, GNU `e`, and `C-c C-x e` validate Org duration syntax and create
or replace the immediate `Effort` property without duplicating an existing
drawer field.

Evil-Org `H`/`L`, Shift-Left/Shift-Right, and `C-c C-x Left`/`C-c C-x Right`
move the selected SCHEDULED, DEADLINE, or ordinary active-event timestamp.
Ordinary use shifts whole days, moving a past non-range item later jumps to
today as configured. `C-u` selects hours, `C-u C-u` selects five-minute steps,
and an immediately repeated opposite command continues the chosen unit. Time
ranges cross midnight coherently and explicit date ranges move both endpoints.
All changes revalidate the exact scanned source line/token, save immediately,
refresh, and restore the logical occurrence.

Evil-Org `p`, and GNU Org's `>` alias from C-z Emacs state, prompt through the
shared Org date reader for the exact planning or ordinary-event timestamp
represented by the row. The command validates the source token both before and
after the prompt, preserves active/inactive delimiters, optional time ranges,
repeaters, and warning/delay suffixes, refuses stale or undated rows, and treats
the replacement as one remote source-buffer undo transaction. A prefix forces
time input and a double prefix uses the current date and time immediately. This
particular command deliberately does not save: the configured Emacs save advice
does not include `org-agenda-date-prompt`. Its asynchronous refresh consumes the
modified live-buffer snapshot, so automatic and later `gr` refreshes show the
unsaved result while disk remains unchanged.

`src/apps/agenda-undo.lisp` supplies the source-buffer transaction core before
the agenda mutation modules compile; `src/apps/agenda-undo-command.lisp` adds
the Evil-Org motion-state `u` command after those modules and their keymaps
exist. Each successful TODO, priority, planning, tag, delete, Effort, date
shift, exact `p`, archive, refile, or stock Vi clock mutation records the source
buffer's actual Lem undo group. A bulk action records one transaction per valid
target in source order, so repeated `u` unwinds the last processed rows first.
The configured delegated Emacs-state clock functions remain outside this stack,
as they do in the pinned Emacs configuration.

Remote undo operates on the source buffer's newest undo node rather than
restoring a private text snapshot. Consequently, an intervening local source
edit is the next edit undone, matching `org-with-remote-undo`. The command never
saves: undoing an autosaved agenda mutation leaves the live source modified
while disk retains the post-mutation contents, whereas undoing unsaved `p` back
to its saved node clears the modified flag. Archive undo restores only the live
source and deliberately retains the destination copy that Org already saved;
clock undo also invalidates the global runtime tracker when it removes the open
clock. Every successful undo refreshes from the live source snapshot and
restores the recorded logical row. Explicit `gr` clears this history before
rescanning, exactly as pinned `org-agenda-redo` clears
`org-agenda-undo-list`.

TODO,
priority, planning, and tag changes save immediately and restore the logical
agenda row after the asynchronous refresh. A shifted or changed source heading
fails closed instead of editing the line now occupying its stale location.
Evil-Org's `dA` archives the complete current subtree, while `da` first asks
`Archive this subtree or entry?`; GNU Org's `$`, `C-c $`, `C-c C-x C-s`, and
`C-c C-x C-a` routes reach the same default command. The bounded port mirrors
the configured `%s_archive::` location: it creates or appends the adjacent
`_archive` file, promotes the moved root to level one, preserves descendants
and existing properties, and records Org's default `ARCHIVE_TIME`,
`ARCHIVE_FILE`, `ARCHIVE_OLPATH`, `ARCHIVE_CATEGORY`, `ARCHIVE_TODO`, and
`ARCHIVE_ITAGS` context. The destination is saved before source deletion, so a
failed second write can leave a recoverable duplicate but cannot lose the
subtree. Exact scanned-heading validation happens before either file changes;
file- or heading-local custom archive locations are refused rather than
silently ignored.
GNU Org's agenda `C-c C-w` mirrors the active default
`org-refile-targets=nil` policy. It completes over real level-one headings in
the selected entry's source file, with TODO/priority/tag normalization and
bracket-link display text matching Org. Duplicate display names resolve to the
first source-order target, as they do through Org's completion table. After an
exact source-and-target recheck, the whole selected subtree becomes the
target's final child; its relative hierarchy, body, and tags are preserved and
heading levels and tag columns are adjusted. Cancellation is mutation-free.
The same-file move saves once, restores the original in-memory text if the
transaction signals, refreshes the agenda, and restores the logical row at its
new source line. A stale agenda row fails before opening target completion.
`scripts/agenda-test.sh` drives the production entry keys in the installed
ncurses wrapper and also verifies source scope, grouping, duplicate basenames,
active-event contexts/ranges/repeaters, TODO, priority, planning insertion,
suffix preservation, warning/delay cookies, prefix removal, and tag
persistence, completion, replacement, clearing, alignment, archive
confirmation/subtree shape/context/durability, custom-route refusal,
same-file refile completion/cancellation/hierarchy/persistence/row restoration,
stale-source refusal, refresh races, unmodified/undo-free generated buffers,
exact `p` defaults and planning/event replacement, time-range and suffix
preservation, cancellation and no-date refusal, unsaved disk separation, one
physical source undo, modified-live-buffer refresh, other-window source visits,
decoration-skipping item motion, and cleanup.
`scripts/agenda-reminder-test.sh` fixes today at a known date and checks the
default fourteen-day boundary, its excluded fifteenth day, explicit warning
cookies, active and hidden schedule delays, zero/base suppression behavior,
dual planning, completed rows, exact stock leaders, numeric time ordering, and
urgency ordering across A/B/C priorities through real ncurses Lem. It compares
the source byte-for-byte after rendering, then physically presses Evil-Org `H`
on a projected reminder and proves both source mutation and refreshed reminder
point restoration.
`scripts/agenda-undo-test.sh` separately drives the effective `u` binding and
proves empty-history reporting, newest-first saved TODO/priority undo without a
disk rewrite, intervening-local-edit ordering, exact unsaved timestamp restoration, per-row bulk ordering,
source-only archive undo, clock runtime cleanup, and the explicit `gr` history
boundary in real ncurses Lem.

`src/apps/agenda-clock.lisp` preserves the effective Evil/base key shadowing
rather than assigning one meaning to `I/O`. In Vi state, `I` starts the single
GNU Org-style current clock and first closes any different tracked clock at the
same current minute; repeating it on the same heading is a no-op, and `O`
closes that clock independent of point. In C-z Emacs state, `I` runs the
configured delegated-clock behavior over bulk-marked rows or the current row,
using one shared start time and refusing a second open clock in the same
heading section. Emacs-state `O` closes all open clocks at marked headings, or
all semantic open clocks in every top-level agenda file when no rows are
marked. New clocks use Org's default `LOGBOOK` placement after planning and a
property drawer; closed lines retain Org's minute timestamp and space-padded
`H:MM` duration shape. Evil-Org `cg` and the base agenda `J` move to the
clocked rendered row when present; otherwise they select its exact live source
heading in another window without destroying the agenda. Evil-Org `cc`, base
`X`, and the stock control chord cancel the active clock transactionally,
remove an otherwise empty `LOGBOOK`, and deliberately leave that source edit
unsaved, matching the user's unadvised GNU Org cancel path. Clock start, stop,
and delegated mutations continue to save immediately. Evil-Org `cr` and base
`R` toggle a clocktable derived off-thread from the displayed agenda span. It
matches Org's default exclusion of the running
clock, clips closed intervals at both date boundaries, rolls descendant time
into source-linked headings through reduced level two, and shows per-file and
all-file totals. Day/week/fortnight/month/year changes and `gd` immediately
recompute that range instead of retaining stale summary bounds.

The Evil mark surface (`m`, `~`, `*`, `%`, `M`) and base surface (`m`, `M-m`,
`*`, `M-*`, `%`, `u`, `U`) render Org's `>` prefix. Each rendered occurrence,
including duplicate rows for one heading, owns a live insertion-type source
point. Marks therefore follow earlier insertions in the same file, remain
visible across the clock-triggered asynchronous refresh, and still fail closed
if the target heading itself changes. `scripts/agenda-clock-test.sh` exercises
the state-specific maps, all/invert/regexp/clear marking, stock switching and
continuation, in-agenda and other-window clock jumps, cancellation and empty
drawer removal, exact unsaved/disk separation, one-step physical Vi undo/redo,
`cr`/`R` report toggling, boundary clipping, max-level-two rollups, multi-file
totals, report source links, duplicate marked targets, shared times, cross-file
close, source-block decoys, persistence, refresh restoration, live-marker
movement, and stale unmarked rows in ncurses Lem.

`src/apps/agenda-bulk.lisp` adds the effective dispatcher on Evil-Org `x` and
base-map `B`. It validates every marked live source point before prompting,
sorts entries by file and source position, and uses the current row when there
are no explicit marks. One shared choice then applies TODO, one tag addition or
removal, SCHEDULED, DEADLINE, default archive, or the configured same-file
level-one refile target to the selected set. Successful actions save through
the existing mutation backends, refresh once, and clear default marks;
cancellation, invalid input, unsupported actions, and stale-source refusal keep
the selection intact. Archive-sibling, scatter, arbitrary Emacs Lisp function
dispatch, persistent marks, and cross-file refile fail closed rather than
silently changing semantics. `scripts/agenda-bulk-test.sh` physically drives
both state maps, marked and current-row dispatch, shared prompts, tag inversion,
planning-line shape, destructive archive/refile order, unsupported-action mark
retention, and stale unsaved-source refusal.

`src/apps/agenda-filter.lisp` adds Evil-Org's complete effective filter chord
family: `sc` category, `sr` regexp, `se` Effort, `st` tag, `s^` top headline,
`ss` temporary limiting, and `S` clear. C-z Emacs state retains GNU Org's
corresponding `</=/_/\\/^/~/|` aliases plus the general `/` matcher. Normal-state
`/` remains Evil search. The off-thread agenda scan annotates
each item with GNU-style effective category (nearest `CATEGORY`, then
`#+CATEGORY`, then filename), inherited `#+FILETAGS` and ancestor/local tags,
local `Effort`, and the normalized top-level headline. These values are copied
to rendered rows; applying filters re-renders a cached immutable result and
never visits or changes a source buffer.

Category and top-headline commands toggle the value at point and accept a
negative prefix. Tag dispatch supports tagged-any, completion, tags at point,
positive/negative selection, explicit removal, and double-prefix intersection.
Regexp filters use case-folded display text, validate before changing state,
toggle off on a second ordinary invocation, and double-prefix accumulate.
Effort implements Org's default duration units and its inclusive `<`/`>`
comparison, including the pinned high-effort treatment of missing estimates;
`_` removes that filter. Different filter types and accumulated clauses compose
by AND, survive `gr` refresh in the current agenda, and appear in the first-line
status. `S`/`|` clears the filter stack. `ss` deliberately remains Org's
separate per-section entry/TODO/tag/cumulative-Effort limiter; its result lasts
for the current scan generation, `C-u ss` removes it, and a source refresh
rebuilds the full view. Agenda-local `C-u` is a universal prefix, matching the
user's default `evil-want-C-u-scroll=nil` configuration.

The general `/` prompt combines represented categories, tags, Effort
comparisons, and case-folded display regexps in one expression. Tags win when
a name is both a tag and a category; unknown names are reported and ignored.
Hyphenated or spaced categories use quotes, multiple positive categories use
GNU Org's OR semantics, and conditions of other types remain conjunctive.
Prescient completes the active quote/regexp-aware component without changing
an exact submitted expression. `C-u /` negates the complete expression,
`C-u C-u /` accumulates it with the active stack, and leading `+-`/`++` provides
GNU's accumulation shortcut. Parsing and regexp compilation finish before the
live state changes, so malformed regexps leave the old filter intact. The
unconfigured `C-u C-u C-u /` auto-exclusion route fails explicitly and also
preserves state.

`scripts/agenda-filter-test.sh` physically drives both state maps, inherited
metadata, positive and negative categories, refresh-stable top-headline
selection, tag completion and double-prefix accumulation, regexp toggle,
Effort comparison/removal, temporary limiting, and full filter clearing. It
also drives general `/` completion and all four combined condition types,
whole-expression negation, prefix and leading-sign accumulation, quoted and
multi-positive categories, tag priority, ignored names, refresh persistence,
invalid-regexp atomicity, and the unconfigured auto-exclusion refusal before
comparing the Org source byte-for-byte. Configured tag-group expansion, filter
presets, and auto-exclusion callbacks are not claimed.

`scripts/agenda-view-test.sh` physically drives the effective `gD`, `[[`,
`]]`, `.`, `gd`, `gr`, and `gR` routes in ncurses Lem. It proves Monday-aligned
weeks, exact seven- and fourteen-day spans, calendar month/year boundaries,
year confirmation, universal counts, selected-date restoration, Org date
input, state-specific `g` ownership, range-aware clock totals, and byte-identical
sources. It also proves required-timed grid suppression, today and non-today
daily grids, exact fixed/current-time ordering, complete same-day ranges,
per-day cross-date endpoints, ordinary headline AM/PM and 24-hour time ranges,
timestamp-time precedence,
bracketed-link exclusion, elapsed-hour repeater dates, decoration-skipping
`gj`, retained source time properties, and byte-identical grid rendering.

This is a task summary, not a replacement for GNU Org's arbitrary agenda
dispatcher. Diary sexps beyond the configured safe `org-anniversary` form,
configurable time-grid, AM/PM display, and default-duration presentation,
and configurable reminder-policy, leader, and sorting variables,
configurable or cross-file refile targets, target creation/copy/reverse and
prefix/cache variants, custom archive destinations and local archive
sibling/tag commands, bulk archive-sibling/scatter/arbitrary-function/persistent-
mark variants, clock recent-task/prefix variants, custom numeric report spans,
tag-group/preset/configured-auto-exclusion filtering,
the other `gD` display toggles (time grid, diary, inactive timestamps, follow,
log, archive, and entry text), `p` timestamp editing, custom commands, and the
wider org-super-agenda presentation remain explicit gaps.

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

Lem-yath defines and loads a native `"modus-vivendi-tinted"` theme in
`src/theme.lisp`, rather than relying on a similarly named Base16 theme. It
copies the current Emacs theme's foreground/background and the semantic palette
available through Lem's face model, then reapplies the profile after Lem's
persisted-theme startup hook. The resolved attributes retain the source hex
values, although the ncurses frontend ultimately renders them through the
terminal's available color model. `scripts/ui-parity-test.sh` verifies the
resolved palette, reload behavior, and multiple distinct rendered color classes.

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

Lem-yath keeps the global minor mode available but contributes numbers only
when the same programming-buffer predicate used by touched-line whitespace
cleanup succeeds. Its display method composes the number column after an
existing provider instead of masking Git markers, prompts, or app gutters.
Relative numbers therefore render in saved and unsaved `prog-mode`-equivalent
buffers and not in Markdown, AsciiDoc, XML/HTML, patch, fundamental, or utility
buffers. `nix run .#ui-parity-test` checks the actual synthesized mode class,
relative distance, unsaved-buffer behavior, and another provider's survival.

### Indentation guides — `lem-yath/src/indent-guides.lisp`

The active Emacs profile enables `indent-bars-mode` for programming buffers and
disables its tree-sitter specialization. Lem-yath now applies the same scope at
display time: `patches/lem-display-line-transformer.patch` supplies one narrow
logical-line transform point, and the configuration replaces indentation cells
with depth-colored `│` glyphs before ncurses drawing. It uses the buffer's
language/EditorConfig indentation size, expands leading tabs by visual column,
inherits the maximum adjacent context across blank lines, and limits guides
inside multiline strings to one level beyond the string opener. The transform
does not edit buffer text, create undo records, dirty files, or change source
cursor coordinates; virtual blank-line cells explicitly retain an end-of-line
cursor at its real column.

`M-x lem-yath-toggle-indent-guides` changes the setting buffer-locally. The
focused real-TUI gate, `nix run .#indent-guides-test`, checks nested levels,
blank context, tabs, multiline strings, prose exclusion, clean source bytes,
toggle/reload behavior, cursor anchoring, and the actual terminal glyph. This
remains a visual approximation: terminal characters and six native theme
colors replace Emacs' pixel stipple, arbitrary face blending, and GUI-specific
rendering.

### Centered document view — `lem-yath/src/centered-view.lisp`
`SPC y c` toggles a buffer-local `Center` minor mode with configurable
`*centered-view-width*` (default 100), with an optional buffer-local override
used by the business document profile. The pinned
`patches/lem-centered-content-width.patch` adds a mode-dispatched preferred
content width and a right-margin component to Lem windows. Redisplay derives
balanced margins independently from each window's current width, keeps an
existing left gutter inside the available margin, and feeds the reduced body
width to wrapping, horizontal scrolling, cursor geometry, and screen-line
motions. The mode enables visual wrapping just like the Emacs source and leaves
that choice intact when disabled. `scripts/centered-view-test.sh` drives the
real leader chord and verifies rendered first/continuation columns, live width
customization, resize, narrow and split windows, reload, horizontal clipping,
and restoration.

### Business document presentation — `lem-yath/src/business-visual.lisp`
The global `business-visual-mode` starts automatically only when the short host
name is present in `*business-visual-hosts*` (default `("workwin")`); it can be
tried explicitly elsewhere through `M-x business-visual-mode`. It installs the
native light `business-operandi` semantic palette, a compact modeline that
retains the Vi state indicator, shape-only Normal/Insert/Emacs/Visual/Replace
cursors, and the configured suppression of Pulsar-style jump feedback.

The hidden buffer-local `business-document-mode` applies only to Org,
Markdown/EPUB, plain `.txt`/`.text`, Notmuch message, feed-entry, and DevDocs
buffers. It enables wrapping, fill width 88, and centered content width 88.
PDF page text, Notmuch search lists, feed lists, code, and utility buffers stay
outside the document boundary. Every affected buffer saves its prior wrapping,
fill width, centered width, and centered-mode state; global toggle-off or a
major-mode transition restores those values. Existing centered views remain
active with their original width. Reload reasserts presentation after Lem
clears editor-local variables during a major-mode change without duplicating
mode state.

`scripts/business-visual-test.sh` runs the installed ncurses editor and proves
the `ex44` dark baseline, manual activation, rendered 88-column margins, mode
classification, compact modeline, light colors, cursor shapes, pulse
suppression, reload, document/code transitions, preservation of pre-existing
centering, and complete teardown. Proportional fonts, fractional line spacing,
hollow cursors, fringes, and graphical frame chrome have no ncurses analogue.

### Long-line display — `src/window/window.lisp`, `src/commands/window.lisp`
The `line-wrap` editor variable defaults to true upstream, and
`M-x toggle-line-wrap` changes it for the current buffer. Lem-yath changes the
global default to false so long lines truncate like the current Emacs config;
`SPC y v` still toggles wrapping buffer-locally.
`patches/lem-vi-screen-line.patch` adds Vi `:screen-line` ranges, a screen-line
Visual state, displayed-row motions, native line-register normalization,
separate logical/display goal columns, and tab/CJK-aware virtual-column
movement. `lem-yath/src/vi.lisp` applies the configured conditional motions
and operators. `patches/lem-word-boundary-wrap.patch` makes rendering, cursor
geometry, and virtual-line motion prefer the same space/tab boundary, while
long tokens retain display-width fallback. `scripts/screen-line-test.sh`
verifies the combined behavior in a 27-case, 40-column ncurses session,
including an assertion over the rendered continuation row.

### Show-paren — `src/ext/showparen.lisp`. `M-x toggle-show-paren` (line 69); enabled by
default via `lem/show-paren:enable`. Highlights matching paren.

### Nested delimiter colors — `extensions/lisp-mode/ext/paren-coloring.lisp`
Upstream exposes six cycling parenthesis attributes and applies them only when
the buffer's major mode is Common Lisp `lisp-mode`. Lem-yath disables that
special-case hook and installs one syntax-table-driven hook for all programming
buffers. It colors every mode-declared delimiter pair by nesting depth while
leaving strings and comments to syntax highlighting. The theme supplies all
nine default `rainbow-delimiters` depths with the exact colors resolved from the
active Emacs Modus Vivendi Tinted theme, and show-paren remains active. The real
TUI gate checks nine Lisp syntax properties and colors, mixed `()[]{}` nesting
in Python, string/comment/escape exclusion, distinct mismatched and unmatched
Modus faces (including negative parser depth), reload idempotence, and a live
matching-pair overlay. Lem and Emacs syntax tables can still classify individual
language constructs differently.

### Highlight current line — `src/highlight-line.lisp`. Editor variable
`highlight-line` (default **t**, line 3) and `highlight-line-color` (line 4).
Lem-yath overrides the global default to false because the current Emacs config
does not enable `hl-line-mode` or `global-hl-line-mode`.

### Tabs / window management
- **Frame multiplexer = tab bar** (`src/ext/frame-multiplexer.lisp`,
  `lem/frame-multiplexer`): `frame-multiplexer-mode` toggles a tmux-like tabbed frame;
  `frame-multiplexer-next/prev/switch-0..9/create`. Upstream enables it from an
  after-init hook. Lem-yath removes that hook so startup has no tab/header row,
  retains `C-x t` as the reachable tab/frame prefix, and makes `C-x t 2` (also
  `C-x t c`) enable the multiplexer and create a tab on demand. Upstream's global
  `C-z` prefix remains installed, while state-local Evil-compatible `C-z` takes
  precedence in Vi buffers. `lem-yath/src/window-history.lisp` adds a separate
  200-entry history to every live frame. `C-c Left` and `C-c Right` rebuild the
  ordinary window tree from recorded split types and proportions, restore exact
  buffer identity, selected leaf, and marker-tracked view starts, preserve each
  buffer's live point, coalesce consecutive identical commands, scale proportions
  after terminal resize, prune dead frames and old configurations, and skip
  unavailable or `*Completions*` configurations. Prompt, floating, side, header,
  and attached windows are not captured, so their owning subsystems keep their
  existing lifecycle. `scripts/window-history-test.sh` drives nested mixed splits,
  buffer changes, collapse, multi-step undo/redo, live point preservation, resize,
  coalescing, the exact bound, reload, and independent tab histories through the
  real ncurses editor. There is also `src/tabbar-config.lisp`.
- Window splits/commands: `split-active-window-vertically`/`-horizontally`,
  `delete-other-windows` (`C-x 1`), `other-window`/`next-window` (`C-x o`),
  `delete-active-window` (`C-x 0`) — `src/commands/window.lisp`. Floating windows
  supported by frontends.

---

## 10. Apps / extras

- **Terminal**: `extensions/terminal/` (`lem-terminal`, **Unix-only**,
  `#-os-windows` in `lem.asd:294`) uses **libvterm via CFFI**. Lem-yath exposes
  both `M-x vterm` and the upstream `M-x terminal`. `src/terminal.lisp` adds the
  installed Evil Collection vterm state flow where Lem has a safe equivalent:
  new buffers start at the live cursor in Insert; Escape and `C-x [` enter a
  live read-only Normal/copy view; `i/I/a/A` resume raw input; Normal `p/P`
  sends kill-ring text; Normal Return submits without leaving Normal; and
  `C-c C-z` toggles whether Escape is sent to the child. The Nix build replaces
  the matching native helper with `patches/lem-terminal-safe-cwd.patch`, which
  uses `openpty` plus `posix_spawn` to enter the literal buffer directory
  without constructing `shell -c` input, then terminates and reaps the child
  when its terminal is deleted. `scripts/terminal-test.sh` drives these paths
  through real ncurses, including a directory containing shell metacharacters,
  live navigation, raw input, process-ID cleanup, and registry cleanup. Lem has
  no safe prompt/cursor-to-process editing API, so vterm Normal-state
  delete/change operators are not reproduced.
- **File manager / filer**: `directory-mode` (Dired-like,
  `src/ext/directory-mode/`) is the ordinary full-buffer directory browser and
  `src/ext/filer.lisp` is a separate tree/column side browser. `find-file` on a
  directory opens `directory-mode`. Lem-yath's `src/dirvish.lisp` replaces the
  stock icon/date/detail rows there with the pinned Dirvish default presentation:
  compact names plus a display-only six-cell file-size field at the right edge,
  or direct-child count for directories. Resizing preserves alignment without
  changing buffer text; refreshes remain clean and read-only, and native
  directory-mode visiting, marking, sorting, copy, rename, and deletion continue
  to operate on exact path properties. The styled directory path remains visible
  as the first row, Lem's redundant blank header row is display-hidden, and the
  native footer carries the pinned ascending `name|mtime`, selected-symlink
  target, and current-entry/total segments. `M-x dirvish` uses the current buffer
  directory (or prompts with a prefix) and replaces the ordinary windows with
  the pinned one-parent/current/preview proportions. The root retains focus;
  movement drives a 20 ms debounced and 250 ms throttled preview. Regular UTF-8
  text is read through the shared nonblocking, mode-hook-free 1 MiB reader,
  directories expose at most 200 direct children, and binary, undecodable,
  oversized, symbolic-link, pipe, socket, or device entries expose metadata
  without being opened. Recognized archives, PDFs, EPUBs, and image/media files
  use cancellable background direct-argv dispatch instead of activating a file
  mode: libarchive lists at most 200 members without extraction, Poppler renders
  first-page text, sandboxed Pandoc produces bounded plain EPUB text, and
  `file(1)` reports media metadata. Each request has a three-second timeout and
  512-KiB stdout/stderr cap; document/archive inputs above 128 MiB stay
  metadata-only, and a superseded result cannot replace the current selection's
  preview. `Return` on a file restores the exact preceding layout
  before visiting it, `q` restores without visiting, and
  `dirvish-layout-toggle` keeps the directory in the restored selected window.
  Lem has no geometry-safe per-window header-line primitive, so the path row
  scrolls rather than staying sticky across the parent/current panes. Pixel
  image/video rendering, subtree/collapse extensions, and Dirvish's wider
  integrations are not reproduced.
  Filer retains its own tree presentation.
- **Encodings**: `extensions/encodings/` (`lem-encodings`): utf-8/16, cp932, euc-jp,
  gb2312, iso-8859-1, 8bit. `prompt-for-encodings`, `*default-external-format*`
  (`:detect-encoding` default).
- **PDF and EPUB readers**: `lem-yath/src/apps/documents.lisp` intercepts
  ordinary `.pdf` and `.epub` file opens before Lem attempts to decode their
  binary sources. PDF mode runs bounded `pdfinfo` and page-scoped `pdftotext`
  argv and provides `n`/`p`, `PageDown`/`PageUp`, `g`, `G`, `r`, `o`, and `q`.
  EPUB mode runs bounded sandboxed Pandoc conversion to Markdown, indexes the
  resulting headings, and provides chapter `n`/`p`, `PageDown`/`PageUp`, `g`,
  `r`, `o`, and `q`. Reader buffers are read-only and intentionally have no
  `buffer-filename`, preventing Lem's force-save path from replacing the
  binary source with converted text; the canonical source path is retained
  separately for refresh, reuse, direct-argv external viewing, and the normal
  recent-file history. Inputs must
  be finite regular files no larger than 512 MiB, subprocesses and outputs are
  bounded, converter controls are stripped, and metacharacter paths never pass
  through a shell.

  Notmuch show buffers mark received MIME leaf rows. Return extracts a selected
  PDF with bounded direct `notmuch show --format=raw --part=N` argv into a
  newly created owner-private directory and mode-0600 file, validates `%PDF-`
  before opening the shared ephemeral reader, restores the exact show pane on
  `q`, and removes the file and directory on every success or refusal path.
  Return on another MIME type invokes the configured save default; `. s`
  explicitly saves any selected part. The prompt proposes the path-safe MIME
  basename, remembers its last directory, asks before overwriting, then uses a
  same-directory mode-0600 staging file and atomic rename. Symlink and
  non-regular destinations fail closed. `scripts/documents-test.sh` proves dispatch, real Poppler/Pandoc argv,
  navigation, reuse, external fallback, non-file/size/output/timeout refusal,
  source preservation, and shell inertness through real ncurses;
  `scripts/notmuch-test.sh` additionally proves MIME discovery, private modes,
  binary extraction/save, overwrite decline and acceptance, staging cleanup,
  symlink refusal, and list/show restoration. This is a
  deliberate terminal approximation: PDF pixel layout, images, links,
  annotations, and forms, plus EPUB HTML/CSS layout and images, remain in the
  external viewer selected with `o`.

  The same Notmuch gate drives the configured Evil-collection triage keys
  through real ncurses. Search `a`, `d`, `!`, `=`, `+`, and `-` operate on an
  exact thread query; show `a`/`x` and `d`/`=`/`+`/`-` operate on the current
  Message-ID, while `A`/`X` archive only the Message-IDs already rendered.
  Opening visible messages removes `unread`, successful actions preserve the
  matching next-message/next-thread/exit behavior, and failed mutations leave
  the read-only projection and cursor untouched. The fake backend intentionally
  emits real bare JSON thread IDs so query-prefix regressions cannot hide.

  The configured Evil-collection mail loop is also present. `C`/`cc` opens a
  new RFC 822 composition from Notmuch's `user.name` and
  `user.primary_email`; `cr` and `cR` ask `notmuch reply --format=default` for
  the exact selected message/thread's sender or all-recipient template. On a
  shown message, `cf` prepares the stock inline-forward shape: `[Sender]`
  subject, `References`, included From/To/Cc/Date/Subject headers, start/end
  delimiters, plain body, and owner-private snapshots of regular attachments.
  `C-c C-c` submits through the packaged local-Bridge STARTTLS helper, files
  the exact normalized transmitted bytes through `notmuch insert` in `sent`,
  and applies `+replied` or `+forwarded` only after both stages succeed;
  `C-c C-k` cancels.
  SMTP credentials come from a matching owner-private `.authinfo.gpg`,
  `.authinfo`, or `.netrc` entry (or explicit paired environment variables),
  never argv. Bcc is retained in the envelope but removed from transmitted and
  FCC headers. The default self-signed-certificate exception is confined to a
  loopback SMTP host; non-loopback hosts use normal certificate verification.
  A failed FCC/tag stage leaves a read-only, stage-marked recovery buffer whose
  retry uses the fixed transmitted bytes and cannot submit the message twice.
  `C-x C-s` prepares a real MIME snapshot and inserts it into Notmuch's
  `drafts` folder with `+draft`; `C-c C-p` performs that save and closes the
  composer. Opening a `tag:draft` thread and pressing `e` removes transport
  headers, restores editable text/MML, and extracts the saved attachment bytes
  into a fresh owner-private directory. Resave inserts the replacement before
  marking the old version deleted, cancel leaves the durable draft intact,
  and send retires it only after SMTP and sent FCC have succeeded. Every close
  path removes resumed attachment files. Forward metadata and attachment bytes
  survive this same save/postpone/resume lifecycle. For signed/encrypted MIME,
  `cf` writes the complete source into a private mode-0600
  `forwarded-message.eml` attachment and keeps it byte-exact through draft
  resume and outgoing MIME expansion, avoiding Emacs's default
  signature-invalidating decode/re-encode path.
  The Notmuch gate proves a real local STARTTLS/AUTH exchange plus physical
  new/reply/forward/send/draft keys, exact templates and FCC bytes,
  malformed-recipient refusal, binary ordinary/protected-forward and draft
  attachment snapshots after source removal, private resume cleanup, durable
  draft replacement/retirement, an injected FCC failure, and duplicate-safe
  retry. Address completion and bounded MIME attachment composition are also
  covered. The remainder of stock Notmuch's richer received-part action map
  and Outlook integration remain outside this bounded text-mail port.

  The default Bridge credential entry has the ordinary authinfo shape
  `machine 127.0.0.1 port 1025 login BRIDGE_USER password BRIDGE_PASSWORD`.
  `LEM_YATH_SMTP_AUTHINFO` can select another private file;
  `LEM_YATH_SMTP_SERVER`, `LEM_YATH_SMTP_PORT`, and
  `LEM_YATH_SMTP_CA_FILE` override transport details. Paired
  `LEM_YATH_SMTP_USERNAME`/`LEM_YATH_SMTP_PASSWORD` are supported for an
  explicitly managed process environment, but the private authinfo path is the
  preferred match for the current Emacs setup.
- **which-key / transient menus**: `extensions/transient/` (`lem/transient`,
  `define-transient`) provides magit-style popup menus with columns and descriptions
  (`transient/transient.lisp`). Lem-yath's global `which-key-mode`
  (`src/prefix-help.lisp`) intercepts every ordinary keymap-backed incomplete
  prefix without rewriting the live maps. Each display snapshot walks the active
  global, mode, and Vi-state graph cycle-safely, then asks `lookup-keybind` for each
  candidate so late mode maps participate and the command dispatcher chooses the same
  shadow winner for display and execution.

  Entries are sorted by key and labeled from the raw lower-case command name, or
  `+prefix` for a further prefix; `SPC`, `RET`, and `DEL` use the configured compact
  spelling. The display is a fresh, display-only multi-column snapshot with at most
  `floor(display-height / 4)` entries per column. Both the primary prefix and every
  nested ordinary keymap-backed prefix wait a fresh one-second idle period. Fast
  commands, Escape, command completion, source reload, and leader-map rebuild remove
  pending or visible help; the pinned transient timer patch rejects a canceled callback
  that was already queued. Keymap activation inside an already executing command is
  deliberately ignored, matching Which-Key's inhibition during command-local reads such
  as help prompts.

  Explicit native transient menus bypass this automatic path, retaining Lem's 500ms
  opening delay and immediate nested refresh. `scripts/ui-parity-test.sh` exercises
  built-in `C-x`, normal-state `g`, insert-state `C-c`, the normal/visual Space leader,
  dynamically added global and mode maps, local shadowing, both delay policies, fast
  dispatch, Escape, preference-preserving reload, timer cancellation and stale callback
  rejection, and bounded traversal of a cyclic prefix graph through the real ncurses
  editor. This remains an approximation of Emacs Which-Key: `C-h` paging, its precise
  page/column layout, separators and default replacements, and exact echo-area
  presentation are not reproduced.
- **Snippets / templates (upstream)**: **NONE.** No yasnippet/tempel equivalent.
  `src/ext/abbrev.lisp` (`lem/abbrev`, `M-/`) is **dynamic abbrev** (word
  completion from buffers), not templating. Lem-yath adds the verified data-only
  compatibility layer described in §4; that does not change upstream Lem.
- **abbrev** (static expansion table like Emacs `abbrev-mode`): only the dynamic form
  above exists; no abbrev-table system.
- **isearch / occur**: `src/ext/isearch.lisp` (`lem/isearch`): `isearch-forward`/
  `-backward`/`-regexp`/`-symbol`, `query-replace`, `query-replace-regexp`,
  `query-replace-symbol`, isearch→multiple-cursors (`isearch-add-cursor-to-next-match`).
  Upstream has no dedicated `occur` command. Lem-yath adds the bounded,
  persistent marked-buffer Occur described in §4; configured project grep now
  covers read-only results plus wgrep-style staged editing, source-buffer apply,
  rollback, ordinary save, and stale-row refusal. Lem-yath also adds marked-buffer
  literal and regexp incremental isearch through the effective Evil Collection
  chords described in §4, plus the marked-buffer literal/regexp query-replace
  coordinator described there. GNU's Lisp-evaluated replacement form remains a
  gap.
- **Multiple cursors**: core support. `src/cursors.lisp` + `src/commands/multiple-cursors.lisp`
  (`add-cursors-to-next-line`, bound `M-C`); isearch can add cursors at matches.
- **Markdown preview**: yes, `preview` generic in markdown-mode (§8), plus literate
  eval-block.
- **AI / shipped in-tree (all in the image):**
  Lem-yath starts its Org scratch as a buffer-local LLM conversation and streams
  replies at the tracked send position before adding the next `* ` prompt.
  `C-c Return` reconstructs role-tagged user and assistant turns through point
  instead of flattening visible transcript text. Org user turns and active Org
  regions are rendered as bounded GitHub-flavored Markdown; source blocks and
  adjacent Babel results become language/text fences. Stateless HTTP providers
  receive the typed transcript, while resumable CLI and established OAuth
  sessions keep their provider-owned history and receive only the new user turn.
  Ordinary buffers retain a shared Markdown transcript for OpenRouter,
  Perplexity, GitHub Copilot Chat, native ChatGPT Codex and Grok OAuth HTTP,
  and the Claude Code, Codex, and Grok CLIs; read-only conversation buffers use
  that transcript without source mutation. Killing a request-bearing buffer
  aborts its tools/process, releases its response marker, and rejects late
  callbacks. `src/llm-visuals.lisp` projects the same semantic properties into
  fixed-width User/Assistant turn badges, an active-role modeline badge, and a
  terminal-safe assistant tint. A synthetic cursor highlights the exact
  mid-line insertion cell or renders `▌` at end of line while streaming, then
  disappears on completion, abort, mode disable, or buffer deletion. These
  overlays never enter conversation reconstruction; role presentation toggles
  with `M-x lem-yath-llm-role-visuals-toggle` and composes with other gutters.
  The configured diagnostic workflow is available through
  `M-x lem-yath-llm-request-trace-toggle` and
  `M-x lem-yath-llm-request-trace-open`. Its selected, read-only
  `*gptel-requests*` viewer records request/backend start, metadata-only chunk
  counts, and distinct complete, aborted, or killed terminal states. Prompt
  previews are control-normalized and bounded to 160 characters; provider
  objects, credentials, headers, request bodies, response content, tool
  arguments, and tool results are never logged. Disabling tracing clears live
  trace ownership and leaves the existing log byte-stable.
  The CLI adapters consume their native
  JSON event streams, retain a separate session ID for each backend for the
  lifetime of that buffer, render text/thinking/tool/command/file activity,
  and pass the native resume argument on later prompts. `SPC g b` selects a
  backend, `SPC g j` or Insert/Visual `C-c i` sends, `SPC g n` starts a fresh
  CLI conversation, and `SPC g a` aborts the one allowed in-flight request.
  Codex and Grok deliberately use read-only sandboxes. The hermetic
  `scripts/llm-backend-test.sh` drives these transports through real ncurses
  Lem with fake executables and no credentials.

  Claude thinking, tool use, and tool results render in the configured
  `#+begin_cc_thinking`, `#+begin_cc_tool`, and
  `#+begin_cc_tool_result` Org forms. Stream insertion attaches semantic text
  properties, and completion builds display-only hidden-line ranges: thinking
  and tool results always collapse, while tool blocks collapse only when they
  span more than eight lines. The begin line and a terminal ellipsis remain
  visible. `C-c C-t` in a conversation independently toggles every tool-result
  block; if the buffer has none, it dispatches the ordinary Org TODO command.
  Folding never removes or rewrites provider-visible text, and mode disable,
  buffer deletion, or source reload disposes its markers and overlays.

  OpenRouter model selection uses the configured account catalog rather than a
  free-form prompt. Lem loads a bounded JSON cache from
  `$XDG_CACHE_HOME/lem-yath/openrouter/models.json` before interaction, falls
  back to `openrouter/auto` and `openrouter/free`, and refreshes once after five
  idle seconds without blocking the editor. With `OPENROUTER_API_KEY` it calls
  `/api/v1/models/user`; without a key it calls the public `/api/v1/models`.
  Model ids are validated, deduplicated in provider order, and written through
  an owner-only `0700` directory and atomic `0600` regular file. The request
  URL and authorization header stay in curl's stdin config. `SPC g L`, then
  `m` (or compact `SPC g l`, `m`, `m`), provides Prescient completion, while
  `M-x lem-yath-openrouter-refresh-models` starts a manual asynchronous
  refresh. `scripts/llm-models-test.sh` proves cached startup, idle and manual
  refresh, both endpoints, malformed-entry filtering, argv isolation, private
  replacement, physical model selection, and offline restart in real Lem.

  ChatGPT Codex uses the same catalog-backed model prompt and private-cache
  discipline. Lem restores
  `$XDG_CACHE_HOME/lem-yath/chatgpt-codex/models.json` before interaction, then
  asynchronously probes the configured Emacs candidates `gpt-5.4`,
  `gpt-5.3-codex`, `gpt-5.2-codex`, and `gpt-5-codex` in order after five idle
  seconds. HTTP 200 and 429 identify supported candidates. All credentials,
  headers, URLs, and probe bodies stay in curl's stdin config; an automatic
  refresh with no auth fails quietly and never starts browser login. Presets
  choose the first available catalog model when their preferred model is not
  supported. `M-x lem-yath-chatgpt-codex-refresh-models` starts an explicit
  asynchronous refresh. `scripts/llm-codex-models-test.sh` proves cache
  filtering, exact probe policy and payloads, rate-limit acceptance, argv
  isolation, private atomic replacement, physical model selection, fresh
  restart, and the missing-auth/no-browser boundary in real Lem.

  `SPC g b` also selects **Perplexity** (`sonar` by default) and **Copilot**
  (`gpt-4.1` by default). Perplexity reads `PERPLEXITY_API_KEY`, streams its
  OpenAI-compatible response, and appends bounded final citations. Copilot is
  authorized explicitly with `M-x lem-yath-copilot-login`: Lem shows and
  copies GitHub's device code, opens the verification URI only in a local GUI
  session, polls according to the device-flow response, then exchanges the
  GitHub token for a short-lived Copilot token on demand. Native tokens live
  below `$XDG_CACHE_HOME/lem-yath/copilot/` in an owner-only directory and are
  atomically replaced as mode-0600 regular files. API keys, tokens, URLs,
  headers, prompts, and bodies are supplied through curl's stdin config rather
  than argv. `scripts/llm-http-test.sh` proves both fragmented SSE transports,
  citation rendering, pending device authorization, token expiry renewal,
  private persistence, provider presets, reload safety, and the argv boundary
  without network access or real credentials. This is text-chat parity;
  Copilot Responses API models, media, tools, and model discovery remain open.

  **ChatGPT Codex** is a distinct `chatgpt-codex` backend, separate from the
  Codex CLI. It reads the Codex CLI-compatible `~/.codex/auth.json`, refreshes
  JWTs within the configured five-minute window while preserving unknown CLI
  fields, retries one 401 after forced renewal, and streams
  `chatgpt.com/backend-api/codex/responses` with the configured originator,
  account, session, reasoning, and prompt-cache contracts. The
  `codex-agentic` preset uses model `gpt-5.4`, keeps conversation input plus
  stable session/cache UUIDs in the shared buffer, translates the five local
  tools to flattened Responses schemas, and feeds bounded function-call
  outputs into subsequent rounds. `M-x lem-yath-chatgpt-codex-login` runs the
  same OAuth2 PKCE authorization-code flow as the Emacs backend and atomically
  writes a mode-0600 CLI-compatible file. A remote SSH login must forward the
  registered localhost callback, normally with
  `ssh -L 1455:127.0.0.1:1455 ex44`.

  **Grok OAuth** is a distinct `grok-oauth` backend, separate from the Grok
  CLI agent. It reads the first usable credential in `~/.grok/auth.json`, asks
  the official CLI's exact `grok models` argv to refresh an expiring session,
  detects `grok version`, sends the required CLI-proxy headers, and streams
  OpenAI-compatible chat completions. The `grok-build-oauth-agentic` preset
  retains history and drives the same bounded five-tool loop. ex44 currently
  has neither a Grok auth file nor the `grok` executable, so live use there
  requires `grok login --oauth` or transferring that CLI state first.
  `scripts/llm-oauth-test.sh` verifies both native transports, refresh and 401
  behavior, a real loopback PKCE callback, exact payload/tool histories,
  private persistence, reload, and secret-free argv in a Nix sandbox.

  Native Claude conversation requests resolve the originating source buffer's
  canonical Git root and launch there, rather than inheriting the shared output
  buffer or editor process directory. `/` and the home directory are rejected
  as unsafe roots. Every fresh, resumed, and abortable request receives the
  configured `Bash`, `Read`, `Edit`, `Write`, `Glob`, `Grep`, `WebFetch`,
  `WebSearch`, and `Agent` allowlist. A safe owned regular project `.mcp.json`
  takes precedence over `~/.claude/.mcp.json`; symlinks and group/world-writable
  files are ignored. The real ncurses backend gate proves all four launched
  requests use the source Git root and exact argv, plus project precedence,
  home fallback, and symlink refusal inside a private test home.

  Claude Code's result session ID and message UUID are attached to the exact
  completed Assistant span. In an Org LLM conversation, `C-c C-f` uses the
  nearest preceding captured boundary to create the configured Claude Code
  project-session fork, while `C-c C-b` selects a registered project session
  with Prescient completion. Forking reads an owned regular JSONL source under
  `~/.claude/projects`, truncates only through the selected UUID, appends a new
  `last-prompt` continuation, and preserves unknown `sessions-index.json`
  fields during a locked atomic update. New files and the lock are mode 0600;
  unsafe ownership, symlinks, writable directories/files, oversized records,
  malformed indexes, and missing boundaries fail closed. If index registration
  fails, the unregistered fork is removed and the buffer retains its prior
  session. `LEM_YATH_CLAUDE_PROJECTS_DIR` permits an explicit private history
  root, which the ncurses gate uses so real user sessions are never touched.
  Lem maps gptel's Org-sibling branch behavior onto its linear role-tagged
  transcript: sending before an existing same-session Claude continuation
  automatically forks from the exact preceding Assistant boundary. The new
  branch becomes authoritative, so continuing it before the visually retained
  old branch does not fork again; fresh sessions and already divergent provider
  branches remain authoritative. The physical gate proves response placement
  before the old continuation, exact fork contents/index registration, and
  new-session resume argv.
  `CC_CWD` and `CC_ALLOWED_TOOLS` in the current Org property drawer or its
  nearest defining ancestor reproduce the backend's heading-local overrides.
  Relative cwd values resolve from the conversation buffer; the canonical
  result must be an existing non-root, non-home directory inside a local Git
  project. That exact cwd controls Claude launch, `.mcp.json` discovery, and
  project-session history selection. Tool values are comma-separated, retain
  Claude/MCP permission-pattern syntax, and reject controls or oversized lists.
  The physical gate proves inheritance, nearest-ancestor precedence, exact
  argv/cwd/MCP selection, matching private session-directory encoding,
  semantic block bytes, automatic collapse policy, and a physical two-way
  `C-c C-t` result toggle.

  `SPC g l` opens the compact three-column Presets/Handoff/Advanced menu used
  by the Emacs configuration. It loads or saves named presets and hands the active region
  (otherwise the complete buffer) to Claude web or ChatGPT normal, search,
  research, or model-hint URLs. Its `m` action opens the same full request menu
  as direct `SPC g L`. That four-column menu reflects and edits the live
  system instruction, backend, catalog model, response-token cap, temperature,
  and supported tool policy; loads or saves presets; and exposes additional
  directive/send, send, abort, fresh-session, and request-trace actions. Setting
  controls reopen the menu with their updated values. Blank temperature and
  token inputs select provider defaults, while backend changes clear tool/MCP
  state that the destination cannot apply. Its response column keeps one-shot
  `e`, `b`, `g`, and `k` targets for the echo area, exact point in another
  buffer, an existing or new typed Org LLM session, and the kill ring; `.`
  restores the ordinary destination. Redirected ownership remains visible to
  abort from the source buffer, private sinks are removed on completion, and a
  follow-up sent from the routed session fills the generated `* ` prompt and
  reconstructs the complete user/assistant/user history. As in gptel, routing
  the initial exchange changes its display destination without replacing the
  source buffer's provider context. `J` opens a read-only normalized
  JSON dry run containing the effective context-expanded messages and request
  settings but no credentials, headers, or dispatch side effect. With an active
  Assistant response, a conditional fifth column exposes `Space` to mark its
  exact semantic span, `M-Return` to regenerate from the typed transcript with
  the original backend/model/system/temperature/token/tool settings, `P` and
  `N` to rotate a bounded 16-entry/4-MiB variant history, and `E` to open a
  terminal unified comparison. Rotation is one undo group; undo/redo revives
  both the Assistant role and response metadata. OpenRouter, Perplexity,
  Copilot, ChatGPT Codex, Grok OAuth, and other transcript-backed backends can
  regenerate. Native `claude-code`, `codex`, and `grok` sessions refuse before
  mutation because their resumable provider histories cannot safely rewind.
  With an active
  Visual region, conditional `r` runs a mode-aware rewrite request into a
  private sink and highlights the tracked source while it waits. The completed
  response opens a selected, read-only terminal preview without changing the
  source. `A` accepts as one undo group, `K` rejects, `r` iterates on the staged
  proposal, `D` opens a bounded unified diff, `M` inserts an explicit merge
  conflict, and `q` closes the preview while retaining the highlighted pending
  rewrite. Overlapping rewrites, read-only sources, concurrent source requests,
  oversized responses, late generations, and killed sources fail closed and
  release their private sinks. Gptel's inline replacement overlay, graphical
  ediff, multi-region accept/reject, diff switches, native-CLI response
  regeneration, and media controls remain unimplemented rather than appearing
  as inert controls.
  Handoff context includes
  buffer, mode, file, and non-prompting project metadata; it is capped at
  13,000 characters while retaining the newest text. ChatGPT also receives
  the exact handoff prompt in Lem's kill ring. Brave is preferred and
  `xdg-open` is the final fallback; every launch uses an argument vector rather
  than a shell.

  The built-in `quick-lookup`, `project-readonly`, conditional `web-readonly`
  and `github-readonly`, `codex-agentic`, `grok-build`, and
  `grok-build-oauth-agentic` presets reproduce the usable Emacs
  policies whose transports exist here. Quick
  lookup is explicitly tool-free. Project-readonly exposes the configured
  `project_root`, `list_project_files`, `search_project`, `read_project_file`,
  and `read_emacs_symbol` names through OpenRouter's function-call protocol;
  the last tool inspects the equivalent Lem/Common Lisp symbol space. The
  originating root is captured before the output-buffer switch. Listing and
  regexp search use bounded direct-argv ripgrep, file reads resolve symlinks
  canonically and accept only in-root regular UTF-8 text, and there is no
  mutation, arbitrary command, or shell tool. Fragmented SSE calls are
  assembled under per-line, argument, call, and four-round limits; tool
  results remain visible in the transcript and feed the next model round.
  Abort covers curl, active project subprocesses, and a blocked MCP tool call.

  Web-readonly starts or reuses the pinned `uvx mcp-server-fetch` stdio server.
  GitHub-readonly appears when a GitHub token exists and starts the official
  container through direct Docker argv with `GITHUB_READ_ONLY=1` and only the
  configured `context,repos,issues,pull_requests,users` toolsets. The token is
  confined to the Docker child environment and named `-e` handoff; it is never
  placed in argv or persisted. The bounded MCP client negotiates current or
  supported older revisions, handles server ping, paginated tool discovery,
  namespaced OpenRouter schemas, structured/text/resource results, persistent
  session reuse, process cleanup, and response/time/size/tool limits. The M-x
  connect-one, connect-all, status, and stop-all commands cover the configured
  hub lifecycle. Arbitrary user server definitions, a rich hub buffer, idle
  asynchronous list-change handling, sampling, elicitation, and experimental
  tasks are intentionally not implemented.

  User presets persist backend, model, system message, temperature, token cap,
  local-tool opt-in, and configured MCP server names in
  `$XDG_CONFIG_HOME/lem-yath/llm-presets.json`; creation, locking, and atomic
  replacement enforce user ownership and private `0700`/`0600` modes on SBCL.
  `scripts/llm-workflow-test.sh` verifies direct and compact-to-full menu routes,
  persistent live setting changes, private save and fresh-process reload,
  a physical Visual rewrite through staging, focused preview, unified diff,
  iteration, one-step acceptance/undo, and non-mutating rejection, plus
  visual-region Claude handoff and bounded
  ChatGPT search handoff, kill-ring copy, and decoded URL parameters without
  opening a real browser.
  `scripts/llm-tools-test.sh` additionally drives a credential-free real
  ncurses request through five fragmented calls and a second HTTP round,
  validates exact schemas and follow-up messages, round-trips a tool-enabled
  private preset, and proves path traversal, escaping symlinks, binary files,
  malformed SSE/arguments, oversized fragments, and unknown tools fail closed.
  `scripts/llm-mcp-test.sh` drives both fake stdio servers through current and
  older-version negotiation, server ping, pagination, local plus MCP model
  tools, structured results, persistent reuse, GitHub read-only argv and token
  confinement, private preset round-trip, cancellation, and exact second-round
  OpenRouter messages without network access or real credentials.

  - **Copilot** — `extensions/copilot/` (`lem-copilot`): `copilot-mode` minor mode,
    `copilot-install-server`, `copilot-signin`, `copilot-complete`,
    `copilot-accept-suggestion`, `copilot-next/previous-suggestion`
    (`copilot.lisp:134-408`). Talks to the GitHub Copilot LSP.
  - **Claude Code** — `extensions/claude-code/` (`lem-claude-code`) supplies the
    interactive query/output UI and collapsible tool rows. Lem-yath binds
    normal-state `C-c c` to a project-aware wrapper which opens immediately in
    insert state, prefers direct `ccr code` argv with `claude` fallback, parses
    bounded fragmented or coalesced JSONL, and resumes the per-buffer session.
    `scripts/claude-code-test.sh` verifies physical-key launch, exact argv and
    cwd, rendered text/tool activity, resume, and injection of the private MCP
    config and explicit tool allowlist without credentials. The UI remains an
    approximation of Emacs's transient plus vterm.
  - **MCP server** — `extensions/mcp-server/` (`lem-mcp-server`): Lem can expose an MCP
    server. Lem-yath's Claude bridge patches it to require a bearer token,
    hides arbitrary evaluation and command tools, and disables arbitrary
    `file://` resources. `C-c c` starts a loopback endpoint and writes a private
    mode-0600 Claude HTTP config; its allowlist is inspection plus
    `openDiff`/`checkDiff`. Proposed whole-buffer edits open as focused,
    read-only unified diffs where `y` performs one retained undo transaction
    and `q` rejects without mutation. `scripts/claude-bridge-test.sh` exercises
    the installed editor, real HTTP session protocol, physical review keys,
    undo, authentication, capability policy, and cleanup. Unlike Monet, this
    path uses Streamable HTTP and polling rather than websocket IDE
    notifications, deferred responses, and Ediff.
  - **deepl / google-translate**: `src/ext/deepl.lisp` (core) and
    `contrib/google-translate` (contrib).
- **Dashboard / welcome**: `extensions/lem-dashboard/` sets `lem:*splash-function*`
  (`lem-dashboard.lisp:146`) — the startup splash when no file is opened
  (`command-line-arguments.lisp:87-89`). `extensions/welcome/`, `extensions/lem-tutor/`
  (interactive tutorial). Lem-yath deliberately overrides the splash with an
  empty Org `*scratch*` buffer to match the configured Emacs startup.
- **bookmark**: `extensions/bookmark/` (`lem-bookmark`).
- **GNU-style Calc parity (lem-yath, not upstream)**: `src/calc.lisp` supplies
  the configured `M-x calc` as a reusable read-only RPN stack in Evil Normal
  state. Common Evil-Collection entry, arithmetic, unary, stack, undo/redo,
  copy/yank, angle, precision, help, and quit keys drive a bounded direct-argv
  `qalc` evaluator; Escape aborts prompt entry transactionally and `q` restores
  the exact origin window. This deliberately does not load upstream contrib
  `calc-mode`, whose algebraic line evaluator does not match GNU Calc's RPN
  interaction model (`scripts/calc-test.sh`).
- **GNU So Long parity (lem-yath, not upstream)**: `src/so-long.lisp`
  intercepts ordinary file-mode selection for the configured global policy.
  A programming, CSS/XML, or fundamental-equivalent file with a line strictly
  over 10,000 UTF-8 bytes enters a wrapped, read-only basic mode before parser,
  LSP, lint, gutter, DAP, or Paredit activation. `C-c C-c` restores the
  selected mode and presentation; `M-x global-so-long-mode` toggles subsequent
  visits. Unlike GNU So Long, Lem performs the guard before original-mode
  activation and measures decoded text as UTF-8; the action menu and local
  policy/action customization are not reproduced (`scripts/so-long-test.sh`).
- **Large-file confirmation (lem-yath patch and configuration)**:
  `patches/lem-before-find-file.patch` adds a true pre-read lifecycle boundary,
  and `src/large-files.lisp` applies the configured strict 50 MiB threshold to
  new readable local regular files. `y` retains ordinary decoding and hooks;
  `n` aborts before buffer allocation; `l` maps bytes through Latin-1 with
  fixed LF handling, remains Fundamental, and skips file hooks. Literal save
  and safe external revert preserve every byte. Temporary implementation reads
  do not prompt, and Lem's literal representation remains character-backed
  rather than Emacs-unibyte (`scripts/large-file-test.sh`).
- **living-canvas / pixel-demo / call-graph**: experimental visual features
  (`#+sbcl lem-living-canvas`; call-graph providers for go/python via tree-sitter).
- **contrib/ (NOT in the default image)**: `bracket-paren-mode`, upstream
  `calc-mode`, `fbar`,
  `migemo`, `modeline-battery`, `mouse-sgr1006`, `overwrite-mode`, `selection-mode`,
  `tetris`, `trailing-spaces`, `version-up`, `ollama`, `google-translate`. These are the
  `lem-contrib` system (`contrib/lem-contrib.asd`) and are **not** depended on by
  `lem/extensions` — they would need to be loaded explicitly (and since the nix image
  lacks the extension-manager, they must be present to ASDF; see top note). The
  similarly named lem-yath Calc command described above is loaded independently.

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
staging, commit, branch, push/pull, log, **stash**, and **interactive rebase**
(lem-yath adds client-backed reword plus edit-stop amend/continue integration).
Grep result rows are editable with immediate source-buffer
write-through. Common Lisp gets a full
SLIME (micros): REPL, SLDB, inspector, macroexpand, autodoc. Extras shipped in-tree:
libvterm **terminal**, **Copilot**, **Claude Code**, MCP server, transient (which-key-ish)
menus, multiple-cursors, isearch/query-replace, 185 base16 themes, line-numbers,
show-paren, highlight-line, frame-multiplexer tabs, dired-like filer, markdown preview +
literate eval.

**The big upstream gaps vs Emacs:** **no upstream org-mode** (lem-yath adds the
bounded native editing subset in §8, but not GNU Org's Babel/export ecosystem),
**no upstream snippet system** (no yasnippet/tempel;
only dynamic abbrev `M-/`; lem-yath adds the bounded data-only subset in §4),
**no static abbrev tables**, **completion has fuzzy primitives but
no Orderless/Prescient framework**, **upstream tree-sitter is a manual API**
(lem-yath supplies 19 automatic grammar/query mappings for existing modes, with
the limitations in §6), **vi-mode
lacks surround/sneak/easymotion**, **upstream Legit lacks
blame/bisect/cherry-pick/region-staging** (lem-yath supplies bounded addition
blame, core bisect and cherry-pick lifecycles, and changed-line staging),
and the **nix image cannot freely `ql:quickload` new deps at runtime** (extension-manager
is compiled out), so anything outside `lem/extensions` must be added at image/ASDF time.
Config language is Common Lisp in package `:lem-user`, single `init.lisp` in
`~/.config/lem/` (or `~/.lem/`), with `add-hook`/`*after-init-hook*` and the
`~/.lem/inits/` site-init system for multi-file setups. Several of these upstream
gaps now have partial or exact lem-yath implementations; consult the ledger rather
than inferring current status from this capability survey.
