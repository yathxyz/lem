# Vim / Evil parity

The target is the configured Evil layer in
`~/proj/nix/computer/home/config/emacs/lisp/init-evil.el`, with stock Vim
behavior supplied by the flake-pinned upstream `lem-vi-mode` where the Emacs
configuration does not override it.

## Implemented and verified

| Area | Lem behavior | Evidence |
|---|---|---|
| Vim states and core editing | Upstream normal, insert, visual, operator, replace, registers, text objects, counts, dot-repeat, macros, jumplist, windows, search, and Ex commands | Pinned `lem-vi-mode`; lem-yath regression coverage protects overridden operators |
| Prefix guidance and leader | Globally enabled guidance composes the live global, major/minor-mode, and Vi-state maps, so late mode bindings participate and dispatcher shadowing determines the one displayed winner. Every ordinary initial or nested prefix waits a fresh idle second, then shows sorted raw command or `+prefix` labels in multi-column snapshots capped at one quarter of the frame height. `SPC` in normal and visual shares one reload-safe keymap; native transients retain their 500ms opening delay and immediate nesting. | `leader-bindings: T` in `boot-test.sh`; real-ncurses timing, composition, timer, reload, cycle, Escape, and dispatch coverage in `ui-parity-test.sh` |
| Native operators | `d/c/y`, doubled `dd/cc/yy`, visual operators, counts, text objects, and dot-repeat survive the surround dispatch layer; while wrapping is active, doubled operators use complete displayed rows and native line-register normalization | interactive checks 8, 9, and 12–14; `screen-line-test.sh` |
| Whole-line yank | `Y` and `yy` use a logical line normally and a complete displayed row while wrapping is active | interactive check 22; `screen-line-test.sh` |
| Evil visual-line policy | `SPC y v` reversibly swaps `j/k` with `gj/gk` and `0/$` with `g0/g$`; while wrapping is active, `I/A`, `D/C`, doubled line operators, `Y`, native registers/paste, and `V` follow displayed rows. Counts, goal families, boundary clamping, exclusive-motion BOL promotion, empty ranges, wide cells, undo/redo, and Lispyville delimiter safety are covered. | 26-case 40-column ncurses `screen-line-test.sh` |
| Centered document view | `SPC y c` toggles a buffer-local `Center` mode with a configurable 100-column target. Balanced margins are derived independently for every window and feed both rendering and screen-line geometry; resize, splits, wrapping, reload, and toggle restoration remain coherent. | real-ncurses `centered-view-test.sh`; screen-line regression suite |
| evil-surround | `ys{motion}`, `ds{char}`, `cs{old}{new}`, visual `S`; padded `(`/`[`/`{`, compact closing-delimiter variants, `#{…}`, XML tag prompts on `t`/`<`, call prompts on `f`, and prefix forms on `C-f`. Visual Block `S` surrounds every covered row independently, skips rows ending left of the block, wraps partial and exactly-left-EOL rows like the pinned package, exits to Normal at the same upper boundary, preflights every insertion, and remains one undo step. Tag matching is nested and quote-aware; changing a tag preserves attributes on Return or discards them with an explicit `>`. Delete/change selects the narrowest balanced pair, isolates character delimiters by syntax domain, preflights read-only boundaries, and fails closed on malformed or triple-quoted input. | `surround-test.sh`; interactive check 10; Org operator compatibility gate |
| evil-snipe 2.1.3 | Case-sensitive `s/S/f/F/t/T`, counts, visible initial scope, whole-visible repeats, persistent `;`/`,`, lower/upper transient pairs, operator `z/Z/x/X`, leading-whitespace skipping, incremental/final highlighting, cancellation, dot-repeat, and jumplist semantics | `snipe-test.sh`; interactive checks 5 and 15 |
| Avy visible-target jumps | `SPC l/a/s` use balanced `a/s/d/f/g/h/j/k/l` floating labels for visible lines, closest case-folded characters, and symbol starts or punctuation. Normal state covers every text window, Visual stays current-window, wrapped and hidden rows are respected, resize aborts on the next input, a raw digit falls back to an absolute line, and selection never mutates source state. Stock `x/X/t/m/n/y/Y/z` dispatch actions and `?` help are present; `i` explicitly reports the missing spell backend. | `avy-test.sh` |
| evil-nerd-commenter | `gc{motion}` and visual `gc` | interactive check 4 |
| Insert controls | `C-u` deletes back to indentation, `M-Backspace` deletes a word, `C-n/C-p` retain ordinary line movement, `C-c i` sends through the end of the current word or punctuation run without moving point; the same chord sends a Vi selection from VISUAL | interactive checks 16 and 20 plus `llm-keybinding-test.sh` |
| Cursor and Emacs state | `NORMAL` is a red box, `INSERT` a green bar, visual a default-color box, and replace a default-color underline; `C-z` enters a cyan, buffer-local `EMACS` state with ordinary Emacs movement and mark/copy semantics, then returns to the prior state | `cursor-state-test.sh` |
| Editing leader commands | Org ID creation, auto fill, visual-line wrapping, paragraph filling, and package-qualified callable/variable help with typed completion metadata | interactive checks 17–19; `help-test.sh`; exact leader-map check |
| Org / Evil-Org subset | `.org` supplies folding, hidden-row and heading motion, Org-aware `o/O`, context-safe Meta editing, and the active `ae/ie`, `aE/iE`, `ar/ir`, `aR/iR` text objects in operator and Visual states. The bounded boundary model preserves character/line shape, counts, normal `a/i`, `aw/iw`, surround, and Snipe; recognized unsafe contexts fail closed according to their object class, while type-mismatched inner block ends remain literal. Structural list/table/formula/CLOCK operations likewise fail closed where exact repair is unavailable. Normal `t/T`, `Return`, and `M-o` retain Evil-Snipe/Evil/window ownership. | `org-test.sh`; `org-operator-test.sh` |
| Region expansion | Repeated `SPC v` expands lexical subwords and symbols through Python/JSON syntax nodes, including whitespace-sensitive balanced-list tiers inside parser-bounded ordinary/block strings; parserless modes retain balanced-delimiter and paragraph fallback. Arbitrary forward/reverse Visual selections generate from the active endpoint and retain contained generated tiers for contraction. The configured but unbound `M-x expreg-contract` walks backward through the unchanged generated sequence, and `SPC v` can expand forward again. | `expreg-test.sh`; interactive check 21 |
| Lispy/Lispyville structural editing | Paredit smart insertion plus safe Vim operators, `W/E/B` atom motions, `>/<` slurp/barf, all configured additional and additional-insert transforms, comments/strings, and Lisp-family delimiters | `structural-test.sh` |
| Retained undo / Vundo | Ordinary `u`/`C-r` retain abandoned branches; normal and visual `SPC u` open a Unicode three-row tree with live preview, arrows and `f/b/n/p`, `a/w/e`, cross-branch `l/r`, `m/u/d`, `C-x C-s`, rollback, and accept | `vundo-test.sh` |
| Embark-style actions | `SPC e a` in normal and visual states opens the same one-key action dispatcher; an active forward or reverse visual region takes precedence over point targets, and copying it leaves the buffer unchanged | `actions-test.sh` |

The modal behavior matches the configured Emacs TTY oracle over Lem's
displayed rows. It remains an approximation of Emacs `visual-line-mode`
because Emacs prefers word-boundary wrapping while Lem breaks rows at display
width.

Run the complete gate away from the laptop with:

```sh
./scripts/test-on-ex44.sh
```

## Remaining capability gaps

These bindings are intentionally not mapped to unrelated commands:

| Emacs binding / feature | Gap in Lem |
|---|---|
| Completion-local `C-.` | The ncurses input path cannot represent this key distinctly, so the completion popup uses `C-c a` for its action menu. |
| Exact Which-Key presentation | Global active-map composition and timing are implemented, but Lem lacks Emacs Which-Key's `C-h` paging, precise page/column layout, separators and default replacements, and exact echo-area presentation. |
| Full Embark workflow | The dispatcher has typed, extensible providers and a focused action set, but visual-block selection is not a region target, and there is no target cycling, act-all, collect/export/live views, arbitrary Embark action-map composition, or richer embark-consult adapters. |
| Full Avy dispatch and exact presentation | Navigation, `x/X/t/m/n/y/Y/z` actions, and `?` help are implemented. The stock `i` action cannot correct spelling because no spell backend is configured; exotic display/syntax geometry and exact Emacs minibuffer presentation remain approximate. |
| Full expreg language coverage | Parser-backed expansion currently covers exact Python and JSON file modes. Other languages use lexical, balanced-delimiter, and paragraph fallback. Malformed ERROR fragments use useful containing nodes rather than partial error ranges. |
| Full evil-surround grammar | The pinned default delimiter, tag, function, prefix-function, and Visual Block insertion grammar is present, including tag deletion/change and attribute retention. Arbitrary minibuffer editing within the compact tag reader, mode-local custom pair functions, and multi-character block-string editing are not. |
| Workwin cursor geometry | The active terminal profile colors match, but ncurses cannot reproduce the optional graphical profile's two-pixel bar width or hollow visual cursor. |
| Remaining Evil-Org / evil-collection integrations | The native Org subset now provides the active object/element/greater/subtree text objects, but not Org-aware `0/$`, `I/A`, structural `d/x/X`, richer unsupported Org syntax, the full list/table meta theme, source editing, timestamp/schedule/deadline workflows, or integrations for every other Emacs mode. |

These are implementation gaps, not untested claims. Closing one requires adding
the missing editor capability or a faithful equivalent, followed by a focused
TUI regression.
