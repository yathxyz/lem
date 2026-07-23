# Structural editing parity

The reference is the active Emacs configuration in
`portable/dot_config/emacs/lisp/init-prog.el`:

```elisp
(setq lispyville-key-theme
      '((operators normal) c-w (prettify insert) (atom-movement t)
        slurp/barf-lispy additional additional-insert))
```

Lem uses `lem-paredit-mode` for balanced insertion and supplies the
Lispyville/Evil integration in `lem-yath/src/structural.lisp`.  The integration
is buffer-local in effect: ordinary Vim behavior remains unchanged outside
Lisp-family modes.

## Language coverage

Paredit and the structural Vi layer activate for:

- Common Lisp (`.lisp` and the Lisp REPL family)
- Clojure (`.clj`, `.cljs`, `.cljc`, and `.edn`)
- Scheme and Racket (`.scm` and `.rkt`)
- Emacs Lisp (`.el`)

Activation is installed on the individual mode hooks and reinforced after
lazy mode loading, file opening, and buffer switching.

## Configured key-theme mapping

| Emacs theme / key | Lem behavior |
|---|---|
| `operators`: `d/c/y`, `dd/cc/yy`, `D/C/Y`, `x/X`, `J` | Regions exclude unmatched delimiters; `x/X` splice a selected delimiter pair; `J` keeps joined code ahead of inline comments |
| `c-w`: insert `C-w` | Deletes the previous atom without deleting unmatched delimiters |
| `(prettify insert)` | The configured state does not replace a live insert-state key in Emacs; Lem therefore retains normal insert behavior |
| `(atom-movement t)`: `W/E/B` | Move by atoms, skipping list delimiters and treating strings/comments as atoms |
| `slurp/barf-lispy`: `>` / `<` | Grow/shrink the containing list; numeric counts repeat the transform |
| `additional`: `M-j/M-k` | Drag the current atom or list forward/backward |
| `additional`: `M-J/M-s/M-S` | Join lists, splice a list, or split a list |
| `additional`: `M-r/M-R` | Raise the current form or containing list |
| `additional`: `M-t/M-v` | Transpose adjacent forms or convolute nested lists |
| `additional-insert`: `M-i/M-a` | Enter insert state at the beginning/end of the selected enclosing list |
| `additional-insert`: `M-o/M-O` | Open an indented insertion point below/above the selected enclosing list |

The Emacs `evil-snipe-override-mode` wins over Lispyville for normal-state
`s/S`; Lem preserves the same precedence.  Paredit also retains its native
smart delimiter/quote insertion, structural kill, wrap, splice-forward/back,
and `C-Right`/`C-Left` commands. Outside Vi visual state, the global
electric-editing layer gives active Paredit delimiter regions configured
Lispy's opener position and inactive mark; quote wrapping retains Lispy's outer
selection and orientation. Ordinary Paredit insertion remains unchanged.

## Safety model

For an operator region, Lem scans syntax-aware delimiter pairs while ignoring
delimiters inside strings and comments.  It performs the operation on the
ordered subregions between unmatched delimiters, exactly matching
Lispyville's safe-region rule.  Yank/delete registers retain the concatenated
safe text and the appropriate character/line type. Normal/Visual `"` uses the
same named, append, blackhole, numbered-read, count, and repeat semantics as
ordinary buffers; Insert-state `"` continues to use Paredit's smart quote.

`scripts/structural-test.sh` drives a real ncurses Lem in tmux.  It covers every
configured theme above, numeric counts, register paste behavior, mode
activation, comments/strings, and Clojure parentheses/vectors/maps.  Run it on
the remote test host with:

```sh
./scripts/test-on-ex44.sh structural
```
