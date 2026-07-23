(in-package :lem-yath)

;;; Real-editor fixture for scripts/lisp-eval-test.sh.

(defvar *lisp-eval-test-report*
  (uiop:getenv "LEM_YATH_LISP_EVAL_REPORT"))
(defvar *lisp-eval-test-source*
  (uiop:getenv "LEM_YATH_LISP_EVAL_SOURCE"))
(defvar *lisp-eval-test-value* 0)

(defun lisp-eval-test-log (control &rest arguments)
  (with-open-file (stream *lisp-eval-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun lisp-eval-test-state-name ()
  (let ((state (lem-vi-mode/core:current-state)))
    (cond
      ((typep state 'lem-vi-mode:normal) "normal")
      ((typep state 'lem-vi-mode:visual) "visual")
      ((typep state 'lem-vi-mode:insert) "insert")
      (t "other"))))

(defun lisp-eval-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun lisp-eval-test-remember-source-state (label)
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer :lisp-eval-test-label) label
          (buffer-value buffer :lisp-eval-test-text)
          (lisp-eval-test-buffer-text)
          (buffer-value buffer :lisp-eval-test-point)
          (position-at-point (current-point)))))

(defun lisp-eval-test-setup (label text value &key point-at-start)
  (let ((buffer (current-buffer)))
    (setf (buffer-read-only-p buffer) nil)
    (buffer-mark-cancel buffer)
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer) text)
    (if point-at-start
        (buffer-start (buffer-point buffer))
        (buffer-end (buffer-point buffer)))
    (clear-buffer-edit-history buffer)
    (setf *lisp-eval-test-value* value)
    (lisp-eval-test-remember-source-state label)
    (lisp-eval-test-log "SETUP label=~a value=~s point=~d mark=~a vi=~a"
                        label
                        *lisp-eval-test-value*
                        (position-at-point (current-point))
                        (if (buffer-mark-p buffer) "yes" "no")
                        (lisp-eval-test-state-name))))

(define-command lem-yath-test-lisp-eval-normal-setup () ()
  (lisp-eval-test-setup
   "normal"
   (format nil "(incf lem-yath::*lisp-eval-test-value*)~%")
   0))

(define-command lem-yath-test-lisp-eval-visual-setup () ()
  (lisp-eval-test-setup
   "visual"
   (format nil
           "(incf lem-yath::*lisp-eval-test-value* 100)~%(incf lem-yath::*lisp-eval-test-value*)~%")
   0
   :point-at-start t))

(define-command lem-yath-test-lisp-eval-visual-end () ()
  (buffer-end (current-point))
  (lisp-eval-test-remember-source-state "visual")
  (lisp-eval-test-log "VISUAL-END point=~d mark=~a vi=~a"
                      (position-at-point (current-point))
                      (if (buffer-mark-p (current-buffer)) "yes" "no")
                      (lisp-eval-test-state-name)))

(define-command lem-yath-test-lisp-eval-error-setup () ()
  (lisp-eval-test-setup
   "error"
   (format nil "(error \"lem-yath intentional evaluation error\")~%")
   :unchanged))

(define-command lem-yath-test-lisp-eval-static () ()
  (let ((normal (leader-binding-command
                 lem-vi-mode:*normal-keymap* "m e e"))
        (visual (leader-binding-command
                 lem-vi-mode:*visual-keymap* "m e e"))
        (command (get-command 'lem-yath-lisp-eval-last-expression)))
    (lisp-eval-test-log
     "~a STATIC normal=~a visual=~a command=~a"
     (if (and (eq normal 'lem-yath-lisp-eval-last-expression)
              (eq visual 'lem-yath-lisp-eval-last-expression)
              command)
         "PASS"
         "FAIL")
     (or normal "none")
     (or visual "none")
     (if command "yes" "no"))))

(define-command lem-yath-test-lisp-eval-record () ()
  (let* ((buffer (current-buffer))
         (text (lisp-eval-test-buffer-text))
         (point (position-at-point (current-point))))
    (lisp-eval-test-log
     "STATE label=~a value=~s text=~a point=~a mark=~a vi=~a"
     (or (buffer-value buffer :lisp-eval-test-label) "none")
     *lisp-eval-test-value*
     (if (string= text (or (buffer-value buffer :lisp-eval-test-text) ""))
         "same"
         "changed")
     (if (eql point (buffer-value buffer :lisp-eval-test-point))
         "same"
         point)
     (if (buffer-mark-p buffer) "yes" "no")
     (lisp-eval-test-state-name))))

(define-command lem-yath-test-lisp-eval-reload () ()
  (handler-case
      (progn
        (load *lisp-eval-test-source*)
        (load *lisp-eval-test-source*)
        (lisp-eval-test-log
         "RELOAD binding=~a command=~a"
         (leader-binding-command lem-vi-mode:*normal-keymap* "m e e")
         (if (get-command 'lem-yath-lisp-eval-last-expression) "yes" "no")))
    (error (condition)
      (lisp-eval-test-log "RELOAD ERROR ~a" condition))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F5" 'lem-yath-test-lisp-eval-normal-setup)
  (define-key keymap "F6" 'lem-yath-test-lisp-eval-visual-setup)
  (define-key keymap "F7" 'lem-yath-test-lisp-eval-visual-end)
  (define-key keymap "F8" 'lem-yath-test-lisp-eval-static)
  (define-key keymap "F9" 'lem-yath-test-lisp-eval-error-setup)
  (define-key keymap "F10" 'lem-yath-test-lisp-eval-reload)
  (define-key keymap "F12" 'lem-yath-test-lisp-eval-record))

(lisp-eval-test-log "READY")
