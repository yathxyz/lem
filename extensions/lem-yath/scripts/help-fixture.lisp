(in-package :lem-yath)

; Source layout intentionally exercises the non-evaluating form-offset reader.
#| Outer fixture comment #| with a nested block |# before the definition. |#

(defparameter *lem-yath-help-test-value*
  '(alpha beta gamma)
  "Zyzzyva-variable-documentation identifies the ordinary variable.")

(defparameter *lem-yath-help-test-api-key*
  "ZYZZYVA-SECRET-MUST-NEVER-RENDER"
  "A test credential whose value must remain censored.")

(define-attribute lem-yath-help-test-face
  (t :foreground "#12ab34" :background "#251144" :bold t :underline t))

(defun lem-yath-help-test-callable (alpha &optional beta)
  "Zyzzyva-callable-documentation identifies the non-command callable."
  (list alpha beta))

(declaim (notinline lem-yath-help-test-callable))

(defun lem-yath-help-test-caller ()
  "Call the unique fixture function so Helpful can expose a caller row."
  (lem-yath-help-test-callable :from-caller :retained))

(defun lem-yath-help-test-reader ()
  "Read the unique fixture variable so Helpful can expose a reference row."
  *lem-yath-help-test-value*)

(let* ((package (or (find-package "LEM-YATH-HELP-OTHER")
                    (make-package "LEM-YATH-HELP-OTHER" :use '(:cl))))
       (symbol (intern "*LEM-YATH-HELP-TEST-VALUE*" package)))
  (setf (symbol-value symbol) :other-package-value
        (documentation symbol 'variable)
        "Zyzzyva-other-package-documentation proves qualified selection."))

(define-command lem-yath-help-test-reload () ()
  (load (uiop:getenv "LEM_YATH_HELP_SOURCE"))
  (message "HELP-RELOADED"))

(define-command lem-yath-help-test-report () ()
  "Zyzzyva-key-command-documentation identifies Helpful key inspection."
  (let ((line-number (line-number-at-point (current-point)))
        (column (point-column (current-point))))
    (with-point ((point (current-point)))
      (line-start point)
      (let* ((location
               (text-property-at point :lem-yath-help-location))
             (line (string-downcase (line-string point)))
             (token
               (cond
                 ((search "lem-yath-help-test-caller" line) "caller")
                 ((search "lem-yath-help-test-callable" line) "callable")
                 ((search "lem-yath-help-test-reader" line) "reader")
                 ((search "lem-yath-help-test-face" line) "face")
                 ((search "zyzzyva-help-origin" line) "origin")
                 (t "other")))
             (state
               (format
                nil
                "HELP-STATE buffer=~a mode=~a modes=~d position=~d:~d location=~a token=~a"
                (buffer-name (current-buffer))
                (buffer-major-mode (current-buffer))
                (count 'lem-yath-help-mode (major-modes))
                line-number
                column
                (if location (getf location :label) "none")
                token)))
        (with-open-file
            (stream (uiop:getenv "LEM_YATH_HELP_REPORT")
                    :direction :output
                    :if-exists :append
                    :if-does-not-exist :create)
          (format stream "~a~%" state))
        (message "~a" state)))))

(define-command lem-yath-help-test-origin () ()
  "Return to a stable buffer used to prove Helpful quit-window behavior."
  (let ((buffer (make-buffer "*Help Origin*")))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer) "ZYZZYVA-HELP-ORIGIN\n"))
    (buffer-unmark buffer)
    (switch-to-buffer buffer)
    (buffer-start (current-point))
    (character-offset (current-point) 8)
    (delete-other-windows)))

(define-key *global-keymap* "F5" 'lem-yath-help-test-report)
(define-key *global-keymap* "F7" 'lem-yath-help-test-origin)
(define-key *global-keymap* "F8" 'lem-yath-help-test-reload)

(lem-yath-help-test-origin)
