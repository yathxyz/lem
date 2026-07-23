(in-package :lem-yath)

(defvar *so-long-test-report* (uiop:getenv "LEM_YATH_SO_LONG_REPORT"))

(defun so-long-test-log (control &rest arguments)
  (with-open-file (stream *so-long-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun so-long-test-state-name ()
  (alexandria:when-let ((state (lem-vi-mode/core:current-state)))
    (lem-vi-mode/core::state-name state)))

(defun so-long-test-mode-active-p (buffer mode)
  (if (ignore-errors (mode-active-p buffer mode)) "yes" "no"))

(defun so-long-test-hook-count (callback hooks)
  (count callback hooks :key #'car :test #'eq))

(define-command lem-yath-test-so-long-record () ()
  (let* ((buffer (current-buffer))
         (state (buffer-value buffer 'lem-yath-so-long-state)))
    (so-long-test-log
     (concatenate
      'string
      "STATE name=~a mode=~a vi=~a highlight=~a readonly=~a wrap=~a modified=~a "
      "active=~a original=~a chars=~d tree=~a lsp=~a gutter=~a "
      "dap=~a lint=~a paredit=~a global=~a")
     (buffer-name buffer)
     (symbol-name (buffer-major-mode buffer))
     (or (so-long-test-state-name) "none")
     (if (variable-value 'highlight-line :default buffer) "yes" "no")
     (if (buffer-read-only-p buffer) "yes" "no")
     (if (variable-value 'line-wrap :default buffer) "yes" "no")
     (if (buffer-modified-p buffer) "yes" "no")
     (if state "yes" "no")
     (if state (symbol-name (so-long-state-original-mode state)) "none")
     (count-characters (buffer-start-point buffer) (buffer-end-point buffer))
     (if (buffer-value buffer 'lem-yath-tree-sitter-parser) "yes" "no")
     (so-long-test-mode-active-p buffer 'lem-lsp-mode::lsp-mode)
     (so-long-test-mode-active-p buffer 'lem-yath-git-gutter-mode)
     (so-long-test-mode-active-p buffer 'lem-yath-dap-breakpoint-mode)
     (so-long-test-mode-active-p buffer 'lem-yath-lint-mode)
     (so-long-test-mode-active-p buffer 'lem-paredit-mode:paredit-mode)
     (if *global-so-long-mode-enabled* "yes" "no"))))

(define-command lem-yath-test-so-long-reinstall () ()
  (install-so-long-file-policy)
  (install-so-long-file-policy)
  (so-long-test-log
   "HOOKS find-guard=~d find-core=~d save-guard=~d save-core=~d"
   (so-long-test-hook-count 'so-long-process-file *find-file-hook*)
   (so-long-test-hook-count 'lem-core::process-file *find-file-hook*)
   (so-long-test-hook-count
    'so-long-before-save-process-file
    (variable-value 'before-save-hook :global t))
   (so-long-test-hook-count
    'lem-core::process-file
    (variable-value 'before-save-hook :global t))))

(define-command lem-yath-test-so-long-reload () ()
  (let ((source
          (merge-pathnames
           "src/so-long.lisp"
           (uiop:ensure-directory-pathname
            (uiop:getenv "LEM_YATH_SOURCE")))))
    (load source)
    (load source)
    (so-long-test-log
     "RELOAD global=~a find-guard=~d find-core=~d save-guard=~d save-core=~d"
     (if *global-so-long-mode-enabled* "yes" "no")
     (so-long-test-hook-count 'so-long-process-file *find-file-hook*)
     (so-long-test-hook-count 'lem-core::process-file *find-file-hook*)
     (so-long-test-hook-count
      'so-long-before-save-process-file
      (variable-value 'before-save-hook :global t))
     (so-long-test-hook-count
      'lem-core::process-file
      (variable-value 'before-save-hook :global t)))))

(define-command lem-yath-test-so-long-highlight-on () ()
  (setf (variable-value 'highlight-line :global) t))

(define-command lem-yath-test-so-long-highlight-off () ()
  (setf (variable-value 'highlight-line :global) nil))

(define-key *global-keymap* "F2" 'lem-yath-test-so-long-record)
(define-key *global-keymap* "F3" 'lem-yath-test-so-long-reinstall)
(define-key *global-keymap* "F4" 'lem-yath-test-so-long-highlight-on)
(define-key *global-keymap* "F5" 'lem-yath-test-so-long-highlight-off)
(define-key *global-keymap* "F6" 'lem-yath-test-so-long-reload)

(let ((buffer (make-buffer "so-long-origin")))
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (insert-string (buffer-end-point buffer) (format nil "SO LONG ORIGIN~%"))
    (buffer-unmark buffer))
  (switch-to-buffer buffer)
  (setf (lem-vi-mode/core:buffer-state buffer)
        (lem-vi-mode/core:ensure-state 'lem-vi-mode/states:normal))
  (so-long-test-log "READY"))
