;;;; Common Lisp evaluation parity for the configured `SPC m e e` command.

(in-package :lem-yath)

(define-command lem-yath-lisp-eval-last-expression () ()
  "Evaluate the complete Lisp form immediately before point.

Unlike Lem's region-sensitive `lisp-eval-at-point`, this intentionally ignores
an active Visual selection.  That matches the configured Emacs
`eval-last-sexp` binding in both Normal and Visual states."
  (lem-lisp-mode/internal:check-connection)
  (lem-lisp-mode/eval::eval-last-expression (current-point)))
