(in-package :lem-yath)

(defvar *server-test-report* (uiop:getenv "LEM_YATH_SERVER_REPORT"))

(defun server-test-log (control &rest arguments)
  (with-open-file (stream *server-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun server-test-yes-no (value)
  (if value "yes" "no"))

(defun server-test-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find keymap (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun server-test-hook-count (hook callback)
  (count callback hook :key #'car :test #'eq))

(define-command lem-yath-test-server-static () ()
  (let ((failures 0)
        (client (uiop:getenv "LEM_YATH_CLIENT")))
    (labels ((check (condition name)
               (server-test-log "~a STATIC ~a"
                                (if condition "PASS" "FAIL") name)
               (unless condition (incf failures))))
      (check *server-running-p* "running")
      (check (and *server-socket-pathname*
                  (probe-file *server-socket-pathname*))
             "socket-present")
      (check (and client
                  (string= (uiop:getenv "GIT_EDITOR")
                           (format nil "~a --no-focus"
                                   (uiop:escape-shell-token client))))
             "git-editor")
      (check (and (uiop:getenv "VISUAL") (uiop:getenv "EDITOR"))
             "visual-editor")
      (check (eq (server-test-key-command
                  *lem-yath-server-edit-mode-keymap* "Z Z")
                 'lem-yath-server-save-done)
             "zz-save-done")
      (check (eq (server-test-key-command
                  *lem-yath-server-edit-mode-keymap* "Z Q")
                 'lem-yath-server-abort)
             "zq-abort")
      (check (eq (server-test-key-command
                  *lem-yath-server-edit-mode-keymap* "C-x #")
                 'lem-yath-server-edit-done)
             "cx-hash-done")
      (check (= 1 (server-test-hook-count
                   (variable-value 'kill-buffer-hook :global t)
                   'server-kill-buffer-hook))
             "single-kill-hook")
      (check (= 1 (server-test-hook-count
                   *exit-editor-hook* 'server-shutdown))
             "single-exit-hook"))
    (server-test-log "SUMMARY STATIC ~a failures=~d"
                     (if (zerop failures) "PASS" "FAIL") failures)))

(define-command lem-yath-test-server-failed-start () ()
  (server-test-log
   "FAILED-START running=~a socket=~a git=~a visual=~a editor=~a"
   (server-test-yes-no *server-running-p*)
   (server-test-yes-no *server-socket*)
   (or (uiop:getenv "GIT_EDITOR") "none")
   (or (uiop:getenv "VISUAL") "none")
   (or (uiop:getenv "EDITOR") "none")))

(define-command lem-yath-test-server-record () ()
  (let* ((buffer (current-buffer))
         (filename (buffer-filename buffer)))
    (server-test-log
     "STATE file=~a line=~d column=~d mode=~a requests=~d modified=~a total=~d"
     (if filename (file-namestring filename) (buffer-name buffer))
     (line-number-at-point (current-point))
     (point-charpos (current-point))
     (server-test-yes-no
      (mode-active-p buffer 'lem-yath-server-edit-mode))
     (length (server-buffer-requests buffer))
     (server-test-yes-no (buffer-modified-p buffer))
     (length *server-requests*))))

(define-command lem-yath-test-server-open-abort-buffer () ()
  (let* ((target (uiop:parse-native-namestring
                  (uiop:getenv "LEM_YATH_SERVER_ABORT_FILE")))
         (buffer (find-if
                  (lambda (candidate)
                    (alexandria:when-let
                        ((filename (buffer-filename candidate)))
                      (uiop:pathname-equal target filename)))
                  (buffer-list))))
    (unless buffer
      (editor-error "The abort fixture buffer is missing"))
    (switch-to-buffer buffer)
    (lem-yath-test-server-record)))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      *lem-yath-server-edit-mode-keymap*))
  (define-key keymap "F7" 'lem-yath-test-server-static)
  (define-key keymap "F6" 'lem-yath-test-server-failed-start)
  (define-key keymap "F11" 'lem-yath-test-server-open-abort-buffer)
  (define-key keymap "F12" 'lem-yath-test-server-record))

(server-test-log "READY")
