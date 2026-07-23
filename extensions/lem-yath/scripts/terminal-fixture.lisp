(in-package :lem-yath)

(defvar *terminal-test-report*
  (uiop:getenv "LEM_YATH_TERMINAL_REPORT"))

(defun terminal-test-log (control &rest arguments)
  (with-open-file (stream *terminal-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun terminal-test-yes-no (value)
  (if value "yes" "no"))

(defun terminal-test-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun terminal-test-hook-count (hook callback)
  (count callback hook :key #'car :test #'eq))

(define-command lem-yath-test-terminal-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (terminal-test-log "~a STATIC ~a"
                                  (if condition "PASS" "FAIL")
                                  name)
               (unless condition
                 (incf failures))))
      (check (find-command "vterm") "vterm-command")
      (check (eq (terminal-test-key-command
                  *lem-yath-terminal-input-keymap* "Escape")
                 'lem-yath-terminal-escape)
             "insert-escape")
      (check (eq (terminal-test-key-command
                  *lem-yath-terminal-input-keymap* "C-c C-z")
                 'lem-yath-terminal-toggle-send-escape)
             "insert-toggle")
      (check (eq (terminal-test-key-command
                  *lem-yath-terminal-normal-keymap* "Return")
                 'lem-yath-terminal-submit)
             "normal-submit")
      (dolist (key '("i" "I" "a" "A"))
        (check (eq (terminal-test-key-command
                    *lem-yath-terminal-normal-keymap* key)
                   'lem-yath-terminal-enter-insert)
               (format nil "normal-~a" key)))
      (dolist (key '("p" "P"))
        (check (eq (terminal-test-key-command
                    *lem-yath-terminal-normal-keymap* key)
                   'lem-yath-terminal-paste)
               (format nil "normal-~a" key)))
      (dolist (command '(lem-yath-terminal-enter-normal
                         lem-yath-terminal-enter-insert
                         lem-yath-terminal-escape
                         lem-yath-terminal-toggle-send-escape
                         vterm))
        (check (member command
                       lem-terminal/terminal-mode::*bypass-commands*)
               (format nil "bypass-~a" command)))
      (check (= 1 (terminal-test-hook-count
                   *switch-to-buffer-hook*
                   'lem-yath-terminal-initialize-vi-state))
             "single-state-hook"))
    (terminal-test-log "SUMMARY STATIC ~a failures=~d"
                       (if (zerop failures) "PASS" "FAIL")
                       failures)))

(defun terminal-test-state-name (state)
  (or (and state (lem-vi-mode/core::state-name state)) "none"))

(define-command lem-yath-test-terminal-record () ()
  (let* ((buffer (current-buffer))
         (terminal
           (ignore-errors
             (lem-terminal/terminal-mode::buffer-terminal buffer))))
    (terminal-test-log
     (concatenate
      'string
      "STATE mode=~a state=~a directory=<~a> escape-to-vterm=~a "
      "terminal=~a live-normal=~a registry=~d point=~d lines=~d")
     (buffer-major-mode buffer)
     (terminal-test-state-name
      (lem-vi-mode/core:buffer-state buffer))
     (uiop:native-namestring (buffer-directory buffer))
     (terminal-test-yes-no
      (lem-yath-terminal-send-escape-p buffer))
     (terminal-test-yes-no terminal)
     (terminal-test-yes-no
      (and terminal
           (not (lem-terminal/terminal::terminal-copy-mode terminal))))
     (length lem-terminal/terminal::*terminals*)
     (position-at-point (current-point))
     (buffer-nlines buffer))))

(define-command lem-yath-test-terminal-seed-paste () ()
  (lem/common/killring:push-killring-item (current-killring) "PASTED")
  (terminal-test-log "SEEDED paste=PASTED"))

(define-command lem-yath-test-terminal-kill () ()
  (kill-buffer (current-buffer))
  (terminal-test-log "CLEANUP registry=~d mode=~a"
                     (length lem-terminal/terminal::*terminals*)
                     (buffer-major-mode (current-buffer))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      *lem-yath-terminal-input-keymap*
                      *lem-yath-terminal-normal-keymap*))
  (define-key keymap "F7" 'lem-yath-test-terminal-static)
  (define-key keymap "F8" 'lem-yath-test-terminal-kill)
  (define-key keymap "F9" 'lem-yath-test-terminal-seed-paste)
  (define-key keymap "F12" 'lem-yath-test-terminal-record))

(dolist (command '(lem-yath-test-terminal-static
                   lem-yath-test-terminal-kill
                   lem-yath-test-terminal-seed-paste
                   lem-yath-test-terminal-record))
  (pushnew command lem-terminal/terminal-mode::*bypass-commands*))

(terminal-test-log "READY")
