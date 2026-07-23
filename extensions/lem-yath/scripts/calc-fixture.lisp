(in-package :lem-yath)

(defvar *calc-test-report* (uiop:getenv "LEM_YATH_CALC_REPORT"))

(defun calc-test-log (control &rest arguments)
  (with-open-file (stream *calc-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun calc-test-state-name ()
  (alexandria:when-let ((state (lem-vi-mode/core:current-state)))
    (lem-vi-mode/core::state-name state)))

(defun calc-test-session ()
  (buffer-value (current-buffer) 'calc-session))

(define-command lem-yath-test-calc-record () ()
  (let ((session (calc-test-session)))
    (calc-test-log
     (concatenate
      'string
      "STATE buffer=~a mode=~a state=~a windows=~d height=~d "
      "readonly=~a modified=~a stack=~{~a~^|~} precision=~d angle=~a")
     (buffer-name (current-buffer))
     (buffer-major-mode (current-buffer))
     (or (calc-test-state-name) "none")
     (length (window-list))
     (window-height (current-window))
     (if (buffer-read-only-p (current-buffer)) "yes" "no")
     (if (buffer-modified-p (current-buffer)) "yes" "no")
     (and session (calc-session-stack session))
     (if session (calc-session-precision session) -1)
     (if session (calc-session-angle session) "none"))))

(define-command lem-yath-test-calc-seed-kill () ()
  (copy-to-clipboard-with-killring "6 * 7")
  (calc-test-log "KILL seeded=6-times-7"))

(define-command lem-yath-test-calc-origin-record () ()
  (calc-test-log
   "ORIGIN buffer=~a state=~a windows=~d text=~a"
   (buffer-name (current-buffer))
   (or (calc-test-state-name) "none")
   (length (window-list))
   (string-right-trim '(#\Newline #\Return)
                      (buffer-text (current-buffer)))))

(define-key *global-keymap* "F2" 'lem-yath-test-calc-record)
(define-key *global-keymap* "F3" 'lem-yath-test-calc-seed-kill)
(define-key *global-keymap* "F4" 'lem-yath-test-calc-origin-record)

(let ((buffer (make-buffer "calc-origin")))
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (insert-string (buffer-end-point buffer) (format nil "CALC ORIGIN~%"))
    (buffer-unmark buffer))
  (switch-to-buffer buffer)
  (setf (lem-vi-mode/core:buffer-state buffer)
        (lem-vi-mode/core:ensure-state 'lem-vi-mode/states:normal))
  (calc-test-log "READY"))
