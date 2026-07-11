# Vim / Evil parity

The target is the configured Evil layer in
`~/proj/nix/computer/home/config/emacs/lisp/init-evil.el`, with stock Vim
behavior supplied by the flake-pinned upstream `lem-vi-mode` where the Emacs
configuration does not override it.

## Implemented and verified

| Area | Lem behavior | Evidence |
|---|---|---|
| Vim states and core editing | Upstream normal, insert, visual, operator, replace, registers, text objects, counts, dot-repeat, macros, jumplist, windows, search, and Ex commands | Pinned `lem-vi-mode`; lem-yath regression coverage protects overridden operators |
| Leader | `SPC` in normal and visual shares one described, reload-safe keymap; every entry is checked against its command, and pausing for one second opens nested continuation help without changing other transient menus | `leader-bindings: T` in `boot-test.sh`; `ui-parity-test.sh` |
| Native operators | `d/c/y`, doubled `dd/cc/yy`, visual operators, counts, text objects, and dot-repeat survive the surround dispatch layer | interactive checks 8, 9, and 12–14 |
| Whole-line yank | `Y` yanks the current line, matching configured Evil and `yy` even when the cursor is mid-line | interactive check 22 |
| evil-surround | `ys{motion}`, `ds{char}`, `cs{old}{new}`, visual `S`; padded `(`/`[`/`{` and compact closing-delimiter variants | interactive check 10 |
| evil-snipe | `s/S`, immediate repeat, visible-window scope, operator `z/Z` inclusive and `x/X` exclusive, `;`/`,` repeat fallback | interactive checks 5 and 15 |
| evil-nerd-commenter | `gc{motion}` and visual `gc` | interactive check 4 |
| Insert controls | `C-u` deletes back to indentation, `M-Backspace` deletes a word, `C-n/C-p` retain ordinary line movement, `C-c i` sends text through point to the LLM; the same chord sends a Vi selection from VISUAL | interactive checks 16 and 20 plus `llm-keybinding-test.sh` |
| Editing leader commands | Org ID creation, auto fill, visual-line wrapping, paragraph filling, variable help | interactive checks 17–19 plus exact leader-map check |
| Region expansion | Repeated `SPC v` expands through word, nearest delimiter, line, and paragraph | interactive check 21 |
| Lispy/Lispyville structural editing | Paredit smart insertion plus safe Vim operators, `W/E/B` atom motions, `>/<` slurp/barf, all configured additional and additional-insert transforms, comments/strings, and Lisp-family delimiters | `structural-test.sh` |
| Retained undo / Vundo | Ordinary `u`/`C-r` retain abandoned branches; normal and visual `SPC u` open a Unicode three-row tree with live preview, arrows and `f/b/n/p`, `a/w/e`, cross-branch `l/r`, `m/u/d`, `C-x C-s`, rollback, and accept | `vundo-test.sh` |
| Embark-style actions | `SPC e a` in normal and visual states opens the same one-key action dispatcher; an active forward or reverse visual region takes precedence over point targets, and copying it leaves the buffer unchanged | `actions-test.sh` |

Run the complete gate away from the laptop with:

```sh
./scripts/test-on-ex44.sh
```

## Remaining capability gaps

These bindings are intentionally not mapped to unrelated commands:

| Emacs binding / feature | Gap in Lem |
|---|---|
| `SPC y c` (`yath/centered-view-mode`) | The ncurses frontend has no equivalent balanced window-margin facility. |
| `evil-respect-visual-line-mode` | `SPC y v` toggles wrapping, but `j/k` retain Vim logical-line movement instead of changing to display-line movement while wrapping is active. |
| Completion-local `C-.` | The ncurses input path cannot represent this key distinctly, so the completion popup uses `C-c a` for its action menu. |
| Full Embark workflow | The dispatcher has typed, extensible providers and a focused action set, but visual-block selection is not a region target, and there is no target cycling, act-all, collect/export/live views, arbitrary Embark action-map composition, or richer embark-consult adapters. |
| Avy leader jumps | `SPC l/a/s` use goto-line, snipe, and symbol search; they do not render Avy labels over every visible target. |
| Full expreg syntax awareness | Incremental expansion is present, but it uses delimiters and text boundaries rather than a parser-backed syntax tree. |
| evil-snipe highlighting | Motions, scope, repeat, and operator behavior are present; incremental candidate highlighting is not. |
| Full evil-surround grammar | Common delimiters and padding are present; tag prompts and syntax-aware balanced matching are not. |
| evil-org / all evil-collection integrations | Lem has no Org major mode and does not contain integrations for every Emacs mode. Org file workflows and heading IDs still operate on the shared files. |

These are implementation gaps, not untested claims. Closing one requires adding
the missing editor capability or a faithful equivalent, followed by a focused
TUI regression.
