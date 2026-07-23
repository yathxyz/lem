;;;; Evil's numeric expression register, using the configured bounded Calc
;;;; evaluator.  Arbitrary Emacs Lisp is deliberately not interpreted as
;;;; Common Lisp: the two languages have different semantics, and evaluating
;;;; user input in Lem's own image would expose editor internals.

(in-package :lem-yath)

(defvar *evil-expression-register-last-input* nil)

(defun evil-expression-register-whitespace-p (character)
  (find character '(#\Space #\Tab #\Newline #\Return #\Page)
        :test #'char=))

(defun evil-numeric-expression-p (expression)
  "Return true when EXPRESSION selects Evil's GNU Calc evaluation branch."
  (alexandria:when-let
      ((position
         (position-if-not #'evil-expression-register-whitespace-p expression)))
    (find (char expression position) "0123456789+-." :test #'char=)))

(defun read-evil-expression-register ()
  (let ((expression
          (prompt-for-string
           "="
           :initial-value (or *evil-expression-register-last-input* "")
           :history-symbol 'lem-yath-evil-expression-register)))
    ;; Evil retains the entered expression even when evaluation reports an
    ;; error, so the next prompt can be corrected in place.
    (setf *evil-expression-register-last-input* expression)
    (unless (evil-numeric-expression-p expression)
      (editor-error
       "Emacs-Lisp expression registers require Emacs; Lem supports numeric Evil expressions"))
    (values (calc-evaluate-expression (make-calc-session) expression) :char)))

(lem-vi-mode/registers:set-expression-register-function
 #'read-evil-expression-register)
