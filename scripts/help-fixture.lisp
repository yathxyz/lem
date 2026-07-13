(in-package :lem-yath)

(defparameter *lem-yath-help-test-value*
  '(alpha beta gamma)
  "Zyzzyva-variable-documentation identifies the ordinary variable.")

(defparameter *lem-yath-help-test-api-key*
  "ZYZZYVA-SECRET-MUST-NEVER-RENDER"
  "A test credential whose value must remain censored.")

(defun lem-yath-help-test-callable (alpha &optional beta)
  "Zyzzyva-callable-documentation identifies the non-command callable."
  (list alpha beta))

(let* ((package (or (find-package "LEM-YATH-HELP-OTHER")
                    (make-package "LEM-YATH-HELP-OTHER" :use '(:cl))))
       (symbol (intern "*LEM-YATH-HELP-TEST-VALUE*" package)))
  (setf (symbol-value symbol) :other-package-value
        (documentation symbol 'variable)
        "Zyzzyva-other-package-documentation proves qualified selection."))

(define-command lem-yath-help-test-reload () ()
  (load (uiop:getenv "LEM_YATH_HELP_SOURCE"))
  (message "HELP-RELOADED"))

(define-key *global-keymap* "F8" 'lem-yath-help-test-reload)
