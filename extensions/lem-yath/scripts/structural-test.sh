#!/usr/bin/env bash
# Lispy/Lispyville parity tests driven through a real Lem TUI.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-structural-$$}"
KEY_DELAY="${KEY_DELAY:-0.25}"
SESSIONS=()
FAILED=0

cleanup() {
  for s in "${SESSIONS[@]:-}"; do
    [ -n "$s" ] && tmux_cmd kill-session -t "$s" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  FAILED=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

start() { # start <label> <file> <wait-pattern>
  local label="$1" file="$2" pattern="$3" s="lem-struct-$1-$id"
  SESSIONS+=("$s")
  # LEM_BIN is the configured wrapper: it loads lem-yath as the init file
  # before command-line files, matching the installed editor lifecycle.
  lem_start "$s" "$file"
  if ! lem_wait_for "$s" "$pattern" 40 >/dev/null; then
    fail "$label" "file did not open" "$s"
    return 1
  fi
  sleep 0.5
  tmux_cmd send-keys -t "$s" Escape
  sleep "$KEY_DELAY"
  STRUCT_SESSION="$s"
}

keys() { # keys <session> <key...>
  local s="$1" key; shift
  for key in "$@"; do
    tmux_cmd send-keys -t "$s" "$key"
    sleep "$KEY_DELAY"
  done
}

screen_has() { lem_wait_for "$1" "$2" 5 >/dev/null; }

# 01: Paredit activates in every Lisp language configured in Emacs.
mode_ok=1
for ext in lisp clj cljs cljc edn scm rkt el; do
  file="/tmp/lem-yath-struct-mode.$ext"
  printf '%s\n' '(foo bar)' > "$file"
  if start "01-mode-$ext" "$file" 'foo bar'; then
    if ! lem_wait_for "$STRUCT_SESSION" 'paredit' 10 >/dev/null; then
      printf 'Paredit did not activate for .%s\n' "$ext" >&2
      mode_ok=0
    fi
  else
    mode_ok=0
  fi
done
if [ "$mode_ok" = 1 ]; then
  pass 01-mode-activation "all configured Common Lisp, Clojure, Scheme/Racket, and Elisp files use Paredit"
else
  fail 01-mode-activation "Paredit missing from at least one Lisp mode" ""
fi

# 02: smart pair insertion and Lispyville's delimiter-splicing x.
pair=/tmp/lem-yath-struct-pair.lisp
printf '%s\n' 'seed' > "$pair"
pair_ok=0
if start 02-pair "$pair" seed; then
  keys "$STRUCT_SESSION" 0 i '('
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l x
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(x\) seed' && pair_ok=1
fi
splice=/tmp/lem-yath-struct-splice-x.lisp
printf '%s\n' '(foo bar)' > "$splice"
splice_ok=0
if start 02-splice-x "$splice" 'foo bar'; then
  keys "$STRUCT_SESSION" x
  screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*foo bar[[:space:]]*$' && splice_ok=1
fi
if [ "$pair_ok" = 1 ] && [ "$splice_ok" = 1 ]; then
  pass 02-pairs-and-x "smart pairs and delimiter-splicing x work"
else
  fail 02-pairs-and-x "pair or x behavior diverged" "$STRUCT_SESSION"
fi

# 03: safe d operators preserve unmatched delimiters.
dw=/tmp/lem-yath-struct-dw.lisp
printf '%s\n' '(foo bar)' > "$dw"
dw_ok=0
if start 03-safe-dw "$dw" 'foo bar'; then
  keys "$STRUCT_SESSION" d w
  # Vim's w motion from an opening delimiter selects only that unmatched
  # delimiter; Lispyville therefore leaves the buffer unchanged.
  screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*\(foo bar\)[[:space:]]*$' && dw_ok=1
fi
dd=/tmp/lem-yath-struct-dd.lisp
printf '%s\n' '(foo' '  bar)' > "$dd"
dd_ok=0
if start 03-safe-dd "$dd" foo; then
  keys "$STRUCT_SESSION" d d
  screen_has "$STRUCT_SESSION" '\([[:space:]]*bar\)' && dd_ok=1
fi
if [ "$dw_ok" = 1 ] && [ "$dd_ok" = 1 ]; then
  pass 03-safe-operators "dw and dd exclude unmatched delimiters"
else
  fail 03-safe-operators "safe delete behavior diverged" "$STRUCT_SESSION"
fi

# 04: Lispyville slurp/barf keys grow and restore the inner list.
slurp=/tmp/lem-yath-struct-slurp.lisp
printf '%s\n' '(foo (bar) baz)' > "$slurp"
slurp_ok=0
if start 04-slurp-barf "$slurp" 'foo.*bar.*baz'; then
  keys "$STRUCT_SESSION" w w w '>'
  if screen_has "$STRUCT_SESSION" '\(foo \(bar baz\)\)'; then
    keys "$STRUCT_SESSION" '<'
    screen_has "$STRUCT_SESSION" '\(foo \(bar\) baz\)' && slurp_ok=1
  fi
fi
if [ "$slurp_ok" = 1 ]; then
  pass 04-slurp-barf "> slurps and < barfs"
else
  fail 04-slurp-barf "slurp/barf behavior diverged" "$STRUCT_SESSION"
fi

# 05: additional theme: drag, split, raise-list, and convolute.
drag=/tmp/lem-yath-struct-drag.lisp
printf '%s\n' '(a b c)' > "$drag"
drag_ok=0
if start 05-drag "$drag" 'a b c'; then
  keys "$STRUCT_SESSION" w w M-j
  screen_has "$STRUCT_SESSION" '\(a c b\)' && drag_ok=1
fi
split=/tmp/lem-yath-struct-split.lisp
printf '%s\n' '(a b c)' > "$split"
split_ok=0
if start 05-split "$split" 'a b c'; then
  keys "$STRUCT_SESSION" w w M-S
  screen_has "$STRUCT_SESSION" '\(a[[:space:]]*\)' && \
    screen_has "$STRUCT_SESSION" '\(b c\)' && split_ok=1
fi
raise=/tmp/lem-yath-struct-raise.lisp
printf '%s\n' '(top (a b) end)' > "$raise"
raise_ok=0
if start 05-raise "$raise" 'top.*a b.*end'; then
  keys "$STRUCT_SESSION" w w w M-R
  screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*\(a b\)[[:space:]]*$' && raise_ok=1
fi
conv=/tmp/lem-yath-struct-convolute.lisp
printf '%s\n' '(top (foo (bar baz) quux) end)' > "$conv"
conv_ok=0
if start 05-convolute "$conv" 'top.*foo.*bar baz'; then
  keys "$STRUCT_SESSION" w w w w w w M-v
  screen_has "$STRUCT_SESSION" '\(foo \(top \(bar baz\) end\) quux\)' && conv_ok=1
fi
if [ "$drag_ok" = 1 ] && [ "$split_ok" = 1 ] && \
   [ "$raise_ok" = 1 ] && [ "$conv_ok" = 1 ]; then
  pass 05-additional-theme "drag, split, raise-list, and convolute match Lispyville"
else
  fail 05-additional-theme "one or more structural transforms diverged" "$STRUCT_SESSION"
fi

# 06: atom-movement remaps capital-W to skip delimiters and land on atoms.
atom=/tmp/lem-yath-struct-atom.lisp
printf '%s\n' '(foo (bar baz))' > "$atom"
atom_ok=0
if start 06-atom "$atom" 'foo.*bar baz'; then
  keys "$STRUCT_SESSION" w W i
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(foo \(Xbar baz\)\)' && atom_ok=1
fi
if [ "$atom_ok" = 1 ]; then
  pass 06-atom-motion "W moved to the next atom instead of a delimiter"
else
  fail 06-atom-motion "atom motion diverged" "$STRUCT_SESSION"
fi

# 07: additional-insert beginning/end commands enter insert at list bounds.
ib=/tmp/lem-yath-struct-insert-bounds.lisp
printf '%s\n' '(a b c)' > "$ib"
ib_ok=0
if start 07-insert-begin "$ib" 'a b c'; then
  keys "$STRUCT_SESSION" w w M-i
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(Xa b c\)' && ib_ok=1
fi
ie=/tmp/lem-yath-struct-insert-end.lisp
printf '%s\n' '(a b c)' > "$ie"
ie_ok=0
if start 07-insert-end "$ie" 'a b c'; then
  keys "$STRUCT_SESSION" w w M-a
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(a b cX\)' && ie_ok=1
fi
if [ "$ib_ok" = 1 ] && [ "$ie_ok" = 1 ]; then
  pass 07-list-insert "M-i and M-a enter insert at list bounds"
else
  fail 07-list-insert "list insertion commands diverged" "$STRUCT_SESSION"
fi

# 08: safe J keeps code before an inline comment.
join=/tmp/lem-yath-struct-join.lisp
printf '%s\n' '(foo ; comment' '  bar)' > "$join"
join_ok=0
if start 08-safe-join "$join" 'foo.*comment'; then
  keys "$STRUCT_SESSION" J
  screen_has "$STRUCT_SESSION" '\(foo bar\)[[:space:]]+; comment' && \
    [ "$(lem_capture "$STRUCT_SESSION" | grep -c 'bar)')" = 1 ] && join_ok=1
fi
if [ "$join_ok" = 1 ]; then
  pass 08-safe-join "J kept joined code ahead of the inline comment"
else
  fail 08-safe-join "comment-safe join diverged" "$STRUCT_SESSION"
fi

# 09: insert C-w uses safe backward atom deletion.
cw=/tmp/lem-yath-struct-cw.lisp
printf '%s\n' '(foo bar)' > "$cw"
cw_ok=0
if start 09-safe-cw "$cw" 'foo bar'; then
  keys "$STRUCT_SESSION" w w M-a C-w Escape
  screen_has "$STRUCT_SESSION" '\(foo[[:space:]]*\)' && cw_ok=1
fi
if [ "$cw_ok" = 1 ]; then
  pass 09-safe-C-w "insert C-w deleted an atom without unbalancing the list"
else
  fail 09-safe-C-w "safe backward deletion diverged" "$STRUCT_SESSION"
fi

# 10: remaining additional-theme primitives retain their Lispy meanings.
primitive=/tmp/lem-yath-struct-primitives.lisp
printf '%s\n' '(top (a b) end)' > "$primitive"
splice_form_ok=0
if start 10-splice "$primitive" 'top.*a b.*end'; then
  keys "$STRUCT_SESSION" w w w M-s
  screen_has "$STRUCT_SESSION" '\(top a b end\)' && splice_form_ok=1
fi
raise_form=/tmp/lem-yath-struct-raise-form.lisp
printf '%s\n' '(top (a b) end)' > "$raise_form"
raise_form_ok=0
if start 10-raise-form "$raise_form" 'top.*a b.*end'; then
  keys "$STRUCT_SESSION" w w w w M-r
  screen_has "$STRUCT_SESSION" '\(top b end\)' && raise_form_ok=1
fi
transpose=/tmp/lem-yath-struct-transpose.lisp
printf '%s\n' '(a b c)' > "$transpose"
transpose_ok=0
if start 10-transpose "$transpose" 'a b c'; then
  keys "$STRUCT_SESSION" w w w M-t
  screen_has "$STRUCT_SESSION" '\(a c b\)' && transpose_ok=1
fi
list_join=/tmp/lem-yath-struct-list-join.lisp
printf '%s\n' '(a b) (c d)' > "$list_join"
list_join_ok=0
if start 10-list-join "$list_join" 'a b.*c d'; then
  keys "$STRUCT_SESSION" s ')' Space M-J
  screen_has "$STRUCT_SESSION" '\(a b c d\)' && list_join_ok=1
fi
drag_back=/tmp/lem-yath-struct-drag-back.lisp
printf '%s\n' '(a b c)' > "$drag_back"
drag_back_ok=0
if start 10-drag-back "$drag_back" 'a b c'; then
  keys "$STRUCT_SESSION" w w M-j M-k
  screen_has "$STRUCT_SESSION" '\(a b c\)' && drag_back_ok=1
fi
if [ "$splice_form_ok" = 1 ] && [ "$raise_form_ok" = 1 ] && \
   [ "$transpose_ok" = 1 ] && [ "$list_join_ok" = 1 ] && \
   [ "$drag_back_ok" = 1 ]; then
  pass 10-remaining-additional "splice, raise, transpose, list join, and backward drag work"
else
  fail 10-remaining-additional \
    "diverged (splice=$splice_form_ok raise=$raise_form_ok transpose=$transpose_ok join=$list_join_ok drag-back=$drag_back_ok)" \
    "$STRUCT_SESSION"
fi

# 11: E and B complete the configured atom-motion trio.
atom_e=/tmp/lem-yath-struct-atom-e.lisp
printf '%s\n' '(foo (bar baz))' > "$atom_e"
atom_e_ok=0
if start 11-atom-E "$atom_e" 'foo.*bar baz'; then
  keys "$STRUCT_SESSION" w E a
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(fooX \(bar baz\)\)' && atom_e_ok=1
fi
atom_b=/tmp/lem-yath-struct-atom-b.lisp
printf '%s\n' '(foo (bar baz))' > "$atom_b"
atom_b_ok=0
if start 11-atom-B "$atom_b" 'foo.*bar baz'; then
  keys "$STRUCT_SESSION" w W W B i
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(foo \(Xbar baz\)\)' && atom_b_ok=1
fi
if [ "$atom_e_ok" = 1 ] && [ "$atom_b_ok" = 1 ]; then
  pass 11-atom-E-B "E and B use atom boundaries"
else
  fail 11-atom-E-B "E or B atom motion diverged" "$STRUCT_SESSION"
fi

# 12: M-o/M-O open an indented insertion point outside the current list.
below=/tmp/lem-yath-struct-open-below.lisp
printf '%s\n' '(a b)' > "$below"
below_ok=0
if start 12-open-below "$below" 'a b'; then
  keys "$STRUCT_SESSION" w w M-o
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '^.*\(a b\)' && screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*X[[:space:]]*$' && below_ok=1
fi
above=/tmp/lem-yath-struct-open-above.lisp
printf '%s\n' '(a b)' > "$above"
above_ok=0
if start 12-open-above "$above" 'a b'; then
  keys "$STRUCT_SESSION" w w M-O
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*X[[:space:]]*$' && screen_has "$STRUCT_SESSION" '\(a b\)' && above_ok=1
fi
if [ "$below_ok" = 1 ] && [ "$above_ok" = 1 ]; then
  pass 12-list-open "M-o and M-O open below and above the list"
else
  fail 12-list-open "list open command diverged" "$STRUCT_SESSION"
fi

# 13: safe X, C, and D preserve balance while retaining Vim state semantics.
safe_x=/tmp/lem-yath-struct-safe-X.lisp
printf '%s\n' '(foo bar)' > "$safe_x"
safe_x_ok=0
if start 13-safe-X "$safe_x" 'foo bar'; then
  keys "$STRUCT_SESSION" w X
  screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*foo bar[[:space:]]*$' && safe_x_ok=1
fi
safe_c=/tmp/lem-yath-struct-safe-C.lisp
printf '%s\n' '(foo bar)' > "$safe_c"
safe_c_ok=0
if start 13-safe-C "$safe_c" 'foo bar'; then
  keys "$STRUCT_SESSION" w C
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(X\)' && safe_c_ok=1
fi
safe_d=/tmp/lem-yath-struct-safe-D.lisp
printf '%s\n' '(foo bar)' > "$safe_d"
safe_d_ok=0
if start 13-safe-D "$safe_d" 'foo bar'; then
  keys "$STRUCT_SESSION" w D
  screen_has "$STRUCT_SESSION" '\([[:space:]]*\)' && safe_d_ok=1
fi
if [ "$safe_x_ok" = 1 ] && [ "$safe_c_ok" = 1 ] && [ "$safe_d_ok" = 1 ]; then
  pass 13-safe-X-C-D "X, C, and D preserve delimiters and state transitions"
else
  fail 13-safe-X-C-D "a safe normal-state command diverged" "$STRUCT_SESSION"
fi

# 14: evil-snipe's S override remains authoritative in Lisp buffers.
snipe=/tmp/lem-yath-struct-snipe-S.lisp
printf '%s\n' 'ab xx ab yy' > "$snipe"
snipe_ok=0
if start 14-snipe-S "$snipe" 'ab xx ab yy'; then
  keys "$STRUCT_SESSION" '$' S a b i
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" 'ab xx Xab yy' && snipe_ok=1
fi
if [ "$snipe_ok" = 1 ]; then
  pass 14-snipe-S "S remains the configured backward snipe motion"
else
  fail 14-snipe-S "S was shadowed by structural editing" "$STRUCT_SESSION"
fi

# 15: numeric counts reach slurp/barf and nested-list insertion commands.
count_slurp=/tmp/lem-yath-struct-count-slurp.lisp
printf '%s\n' '(a (b) c d)' > "$count_slurp"
count_slurp_ok=0
if start 15-count-slurp "$count_slurp" 'a.*b.*c d'; then
  keys "$STRUCT_SESSION" w w w 2 '>'
  if screen_has "$STRUCT_SESSION" '\(a \(b c d\)\)'; then
    keys "$STRUCT_SESSION" 2 '<'
    screen_has "$STRUCT_SESSION" '\(a \(b\) c d\)' && count_slurp_ok=1
  fi
fi
count_insert=/tmp/lem-yath-struct-count-insert.lisp
printf '%s\n' '(outer (inner x) tail)' > "$count_insert"
count_insert_ok=0
if start 15-count-insert "$count_insert" 'outer.*inner x.*tail'; then
  keys "$STRUCT_SESSION" w w w w 2 M-i
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(Xouter \(inner x\) tail\)' && count_insert_ok=1
fi
if [ "$count_slurp_ok" = 1 ] && [ "$count_insert_ok" = 1 ]; then
  pass 15-counts "counts repeat structural transforms and select outer lists"
else
  fail 15-counts "structural count semantics diverged" "$STRUCT_SESSION"
fi

# 16: safe y and Lispyville Y omit unmatched delimiters from registers.
safe_y=/tmp/lem-yath-struct-safe-y.lisp
printf '%s\n' '(foo (bar))' 'target' > "$safe_y"
safe_y_ok=0
if start 16-safe-y "$safe_y" 'foo.*bar'; then
  keys "$STRUCT_SESSION" w y W j 0 P
  second="$(lem_capture "$STRUCT_SESSION" | grep 'target' | head -1)"
  [[ "$second" == *foo*target* && "$second" != *'('* ]] && safe_y_ok=1
fi
safe_Y=/tmp/lem-yath-struct-safe-Y.lisp
printf '%s\n' '(foo bar)' 'target' > "$safe_Y"
safe_Y_ok=0
if start 16-safe-Y "$safe_Y" 'foo bar'; then
  keys "$STRUCT_SESSION" w Y j 0 P
  second="$(lem_capture "$STRUCT_SESSION" | grep 'target' | head -1)"
  [[ "$second" == *foo*bar*target* && "$second" != *')'* ]] && safe_Y_ok=1
fi
if [ "$safe_y_ok" = 1 ] && [ "$safe_Y_ok" = 1 ]; then
  pass 16-safe-yank "y motions and Y store only balanced register text"
else
  fail 16-safe-yank "safe yank register contents diverged (y=$safe_y_ok Y=$safe_Y_ok)" "$STRUCT_SESSION"
fi

# 17: strings and comments do not confuse delimiter balancing.
string_case=/tmp/lem-yath-struct-string-safe.lisp
printf '%s\n' '(foo "(" bar)' > "$string_case"
string_ok=0
if start 17-string-safe "$string_case" 'foo.*bar'; then
  keys "$STRUCT_SESSION" w D
  screen_has "$STRUCT_SESSION" '\([[:space:]]*\)' && string_ok=1
fi
comment_case=/tmp/lem-yath-struct-comment-safe.lisp
printf '%s\n' '(foo ; fake )' '  bar)' > "$comment_case"
comment_ok=0
if start 17-comment-safe "$comment_case" 'foo.*fake'; then
  keys "$STRUCT_SESSION" d d
  screen_has "$STRUCT_SESSION" '\([[:space:]]*bar\)' && comment_ok=1
fi
if [ "$string_ok" = 1 ] && [ "$comment_ok" = 1 ]; then
  pass 17-syntax-awareness "strings and comments are ignored by delimiter safety"
else
  fail 17-syntax-awareness "string or comment balancing diverged" "$STRUCT_SESSION"
fi

# 18: Clojure vectors and maps receive the same delimiter-safe operations.
vector=/tmp/lem-yath-struct-vector.clj
printf '%s\n' '[foo bar]' > "$vector"
vector_ok=0
if start 18-vector "$vector" 'foo bar'; then
  keys "$STRUCT_SESSION" x
  screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*foo bar[[:space:]]*$' && vector_ok=1
fi
map=/tmp/lem-yath-struct-map.clj
printf '%s\n' '{:a {:b 1} :c 2}' > "$map"
map_ok=0
if start 18-map "$map" ':a.*:b 1.*:c 2'; then
  keys "$STRUCT_SESSION" w w w 2 '>'
  screen_has "$STRUCT_SESSION" '\{:a \{:b 1 :c 2\}\}' && map_ok=1
fi
if [ "$vector_ok" = 1 ] && [ "$map_ok" = 1 ]; then
  pass 18-clojure-delimiters "vectors and maps support splice and slurp"
else
  fail 18-clojure-delimiters "non-parenthesis delimiter behavior diverged" "$STRUCT_SESSION"
fi

# 19: doubled line operators and ordinary J retain Lispyville line semantics.
cc=/tmp/lem-yath-struct-cc.lisp
printf '%s\n' '(foo' '  bar)' > "$cc"
cc_ok=0
if start 19-safe-cc "$cc" foo; then
  keys "$STRUCT_SESSION" c c
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l X
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '\(X[[:space:]]*$' && \
    screen_has "$STRUCT_SESSION" 'bar\)' && cc_ok=1
fi
yy=/tmp/lem-yath-struct-yy.lisp
printf '%s\n' '(foo' '  bar)' 'target' > "$yy"
yy_ok=0
if start 19-safe-yy "$yy" foo; then
  keys "$STRUCT_SESSION" y y j j 0 P
  screen_has "$STRUCT_SESSION" '^[[:space:][:digit:]]*foo[[:space:]]*$' && yy_ok=1
fi
plain_join=/tmp/lem-yath-struct-plain-J.lisp
printf '%s\n' '(foo' '  bar)' > "$plain_join"
plain_join_ok=0
if start 19-plain-J "$plain_join" foo; then
  keys "$STRUCT_SESSION" J
  screen_has "$STRUCT_SESSION" '\(foo bar\)' && plain_join_ok=1
fi
if [ "$cc_ok" = 1 ] && [ "$yy_ok" = 1 ] && [ "$plain_join_ok" = 1 ]; then
  pass 19-linewise "cc, yy, and plain J preserve structural line semantics"
else
  fail 19-linewise "linewise behavior diverged (cc=$cc_ok yy=$yy_ok J=$plain_join_ok)" "$STRUCT_SESSION"
fi

# 20: Paredit's quote behavior matches `lispy-close-quotes-at-end-p'.
quote=/tmp/lem-yath-struct-quote.lisp
printf '%s\n' 'seed' > "$quote"
quote_ok=0
if start 20-smart-quote "$quote" seed; then
  keys "$STRUCT_SESSION" 0 i '"'
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l x
  keys "$STRUCT_SESSION" '"'
  tmux_cmd send-keys -t "$STRUCT_SESSION" -l y
  keys "$STRUCT_SESSION" Escape
  screen_has "$STRUCT_SESSION" '"x"y' && quote_ok=1
fi
if [ "$quote_ok" = 1 ]; then
  pass 20-smart-quote "typing a closing quote exits the completed string"
else
  fail 20-smart-quote "smart quote behavior diverged" "$STRUCT_SESSION"
fi

# 21: register prefixes flow through Lispyville's delimiter-safe operators.
named_register=/tmp/lem-yath-struct-named-register.lisp
printf '%s\n' '(alpha beta)' 'sink' > "$named_register"
named_register_ok=0
if start 21-named-register "$named_register" 'alpha beta'; then
  keys "$STRUCT_SESSION" '"' a y y j '"' a p
  [ "$(lem_capture "$STRUCT_SESSION" | grep -cE '^[[:space:][:digit:]]*\(alpha beta\)[[:space:]]*$')" = 2 ] &&
    named_register_ok=1
fi
if [ "$named_register_ok" = 1 ]; then
  pass 21-named-register "named line registers survive delimiter-safe yank and paste"
else
  fail 21-named-register "structural operators lost the selected register or its type" "$STRUCT_SESSION"
fi

echo
if [ "$FAILED" = 0 ]; then
  echo "STRUCTURAL TEST PASSED"
  exit 0
else
  echo "STRUCTURAL TEST FAILED"
  exit 1
fi
