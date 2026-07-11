(in-package :lem-yath)

(defvar *cursor-state-report*
  (uiop:getenv "LEM_YATH_CURSOR_STATE_REPORT"))
(defvar *cursor-state-source-buffer* (current-buffer))
(defvar *cursor-state-other-buffer* nil)

(defun cursor-state-log (control &rest arguments)
  (with-open-file (stream *cursor-state-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun cursor-state-name (state)
  (and state (lem-vi-mode/core::state-name state)))

(defun cursor-state-type-name (state)
  (and state
       (string-downcase
        (symbol-name (lem-vi-mode/core::state-cursor-type state)))))

(defun cursor-state-configured-color (state)
  (and state
       (slot-value state 'lem-vi-mode/core::cursor-color)))

(defun cursor-state-effective-color (state)
  (and state (lem-vi-mode/core::state-cursor-color state)))

(defun cursor-state-live-color ()
  (handler-case
      (color-to-hex-string
       (attribute-background-color (ensure-attribute 'cursor)))
    (error () "unknown")))

(defun cursor-state-global-name ()
  (cond
    ((typep (current-global-mode) 'lem-vi-mode/core:vi-mode) "vi")
    ((typep (current-global-mode) 'lem-core::emacs-mode) "emacs")
    (t "other")))

(defun cursor-state-visual-name ()
  (cond
    ((lem-vi-mode/visual:visual-char-p) "char")
    ((lem-vi-mode/visual:visual-line-p) "line")
    ((lem-vi-mode/visual:visual-block-p) "block")
    (t "none")))

(defun cursor-state-kill-head ()
  (or (ignore-errors
        (lem/common/killring:peek-killring-item (current-killring) 0))
      "none"))

(defun cursor-state-effective-state (buffer)
  "Return BUFFER's stored Vi state, or the active initial state for BUFFER."
  (or (lem-vi-mode/core:buffer-state buffer)
      (and (eq buffer (current-buffer))
           (lem-vi-mode/core:current-state))))

(defun cursor-state-record ()
  (let* ((buffer (current-buffer))
         (state (cursor-state-effective-state buffer))
         (return-state
           (buffer-value buffer :lem-yath-emacs-return-state nil)))
    (cursor-state-log
     (concatenate
      'string
      "STATE buffer=~a state=~a type=~a configured=~a effective=~a "
      "cursor=~a global=~a visual=~a mark=~a point=~d return=~a kill=~a")
     (buffer-name buffer)
     (or (cursor-state-name state) "none")
     (or (cursor-state-type-name state) "none")
     (or (cursor-state-configured-color state) "default")
     (or (cursor-state-effective-color state) "default")
     (cursor-state-live-color)
     (cursor-state-global-name)
     (cursor-state-visual-name)
     (if (buffer-mark-p buffer) "yes" "no")
     (position-at-point (current-point))
     (or (cursor-state-name return-state) "none")
     (cursor-state-kill-head))))

(defun cursor-state-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun cursor-state-hook-count (hook callback)
  (count callback hook :key #'car :test #'eq))

(defun cursor-state-spec-p (state-name color type)
  (let ((state (lem-vi-mode/core:ensure-state state-name)))
    (and (equal color (cursor-state-configured-color state))
         (eq type (lem-vi-mode/core::state-cursor-type state)))))

(define-command lem-yath-test-cursor-static () ()
  (let ((failures 0))
    (labels ((check (condition name)
               (cursor-state-log "~a STATIC ~a"
                                 (if condition "PASS" "FAIL")
                                 name)
               (unless condition
                 (incf failures))))
      (check (cursor-state-spec-p 'lem-vi-mode/states:normal "red" :box)
             "normal-red-box")
      (check (cursor-state-spec-p 'lem-vi-mode/states:insert "green" :bar)
             "insert-green-bar")
      (check (cursor-state-spec-p 'lem-vi-mode/states:replace-state
                                  nil :underline)
             "replace-default-underline")
      (dolist (state '(lem-vi-mode/visual::visual-char
                       lem-vi-mode/visual::visual-line
                       lem-vi-mode/visual::visual-block))
        (check (cursor-state-spec-p state nil :box)
               (format nil "~(~a~)-default-box" state)))
      (check (and (eq *lem-yath-emacs-state*
                      (get 'lem-yath-emacs-state
                           'lem-vi-mode/core::state))
                  (equal "cyan"
                         (cursor-state-configured-color
                          *lem-yath-emacs-state*))
                  (eq :box
                      (lem-vi-mode/core::state-cursor-type
                       *lem-yath-emacs-state*)))
             "emacs-singleton-cyan-box")
      (check (eq 'lem-yath-toggle-emacs-state
                 (cursor-state-key-command
                  lem-vi-mode:*motion-keymap* "C-z"))
             "motion-C-z-toggle")
      (check (eq 'lem-yath-toggle-emacs-state
                 (cursor-state-key-command
                  lem-vi-mode:*insert-keymap* "C-z"))
             "insert-C-z-toggle")
      (check (eq 'lem-yath-toggle-emacs-state
                 (cursor-state-key-command
                  *lem-yath-emacs-state-keymap* "C-z"))
             "emacs-C-z-toggle")
      (let* ((package (find-package :lem/frame-multiplexer))
             (symbol (and package (find-symbol "*KEYMAP*" package)))
             (keymap (and symbol (boundp symbol) (symbol-value symbol))))
        (check (and keymap
                    (eq keymap
                        (cursor-state-key-command *global-keymap* "C-z")))
               "global-C-z-frame-prefix-retained")
        (check (and keymap
                    (eq keymap
                        (cursor-state-key-command *global-keymap* "C-x t")))
               "global-C-x-t-frame-prefix"))
      (check (= 1 (cursor-state-hook-count
                   *buffer-mark-activate-hook*
                   'lem-yath-emacs-mark-activate))
             "one-mark-activate-wrapper")
      (check (= 1 (cursor-state-hook-count
                   *buffer-mark-deactivate-hook*
                   'lem-yath-emacs-mark-deactivate))
             "one-mark-deactivate-wrapper")
      (check (zerop (cursor-state-hook-count
                     *buffer-mark-activate-hook*
                     'lem-vi-mode/visual::enable-visual-from-hook))
             "stock-mark-activate-replaced")
      (check (zerop (cursor-state-hook-count
                     *buffer-mark-deactivate-hook*
                     'lem-vi-mode/visual::disable-visual-from-hook))
             "stock-mark-deactivate-replaced")
      (check (= 1 (cursor-state-hook-count
                   *exit-editor-hook*
                   'restore-terminal-cursor-profile))
             "one-exit-cursor-restore")
      (check (= 1 (cursor-state-hook-count
                   *switch-to-buffer-hook*
                   'lem-yath-sync-vi-state-before-buffer-switch))
             "one-buffer-state-sync")
      (cursor-state-log "SUMMARY STATIC ~a failures=~d"
                        (if (zerop failures) "PASS" "FAIL")
                        failures))))

(define-command lem-yath-test-cursor-record () ()
  (cursor-state-record))

(define-command lem-yath-test-cursor-source () ()
  (switch-to-buffer *cursor-state-source-buffer*)
  (buffer-start (current-point)))

(define-command lem-yath-test-cursor-other () ()
  (unless (and *cursor-state-other-buffer*
               (member *cursor-state-other-buffer* (buffer-list) :test #'eq))
    (setf *cursor-state-other-buffer* (make-buffer "*cursor-state-other*"))
    (let ((buffer *cursor-state-other-buffer*))
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer)
                     (format nil "CURSOR_OTHER~%"))
      (buffer-unmark buffer)))
  (switch-to-buffer *cursor-state-other-buffer*)
  (buffer-start (current-point)))

(define-command lem-yath-test-cursor-reload () ()
  (let ((source (uiop:getenv "LEM_YATH_CURSOR_STATE_SOURCE"))
        (state (lem-vi-mode/core:buffer-state))
        (emacs-state *lem-yath-emacs-state*))
    (load source)
    (load source)
    (cursor-state-log
     (concatenate
      'string
      "RELOAD state-same=~a emacs-same=~a activate=~d deactivate=~d "
      "exit=~d switch=~d")
     (if (eq state (lem-vi-mode/core:buffer-state)) "yes" "no")
     (if (eq emacs-state *lem-yath-emacs-state*) "yes" "no")
     (cursor-state-hook-count *buffer-mark-activate-hook*
                              'lem-yath-emacs-mark-activate)
     (cursor-state-hook-count *buffer-mark-deactivate-hook*
                              'lem-yath-emacs-mark-deactivate)
     (cursor-state-hook-count *exit-editor-hook*
                              'restore-terminal-cursor-profile)
     (cursor-state-hook-count
      *switch-to-buffer-hook*
      'lem-yath-sync-vi-state-before-buffer-switch))))

(define-command lem-yath-test-cursor-prompt () ()
  (handler-case
      (let ((value (prompt-for-string "Cursor prompt: ")))
        (cursor-state-log "PROMPT value=~a state=~a"
                          value
                          (cursor-state-name
                           (lem-vi-mode/core:buffer-state))))
    (editor-abort ()
      (cursor-state-log "PROMPT aborted state=~a"
                        (cursor-state-name
                         (lem-vi-mode/core:buffer-state))))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*
                      *lem-yath-emacs-state-keymap*))
  (define-key keymap "F7" 'lem-yath-test-cursor-static)
  (define-key keymap "F8" 'lem-yath-test-cursor-source)
  (define-key keymap "F9" 'lem-yath-test-cursor-other)
  (define-key keymap "F10" 'lem-yath-test-cursor-reload)
  (define-key keymap "F11" 'lem-yath-test-cursor-prompt)
  (define-key keymap "F12" 'lem-yath-test-cursor-record))

(buffer-start (current-point))
(cursor-state-log "READY")
