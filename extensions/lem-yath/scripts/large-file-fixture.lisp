(in-package :lem-yath)

(defvar *large-file-test-report* (uiop:getenv "LEM_YATH_LARGE_FILE_REPORT"))

(defun large-file-test-log (control &rest arguments)
  (with-open-file (stream *large-file-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun large-file-test-hook-count (callback hooks)
  (count callback hooks :key #'car :test #'eq))

(defun large-file-test-encoding-name (buffer)
  (let ((encoding (buffer-encoding buffer)))
    (cond
      ((null encoding) "none")
      ((typep encoding 'lem/buffer/encodings:internal-encoding)
       (symbol-name
        (lem/buffer/encodings:encoding-external-format encoding)))
      (t (symbol-name (class-name (class-of encoding)))))))

(defun large-file-test-eol-name (buffer)
  (alexandria:when-let ((encoding (buffer-encoding buffer)))
    (symbol-name (lem/buffer/encodings:encoding-end-of-line encoding))))

(define-command lem-yath-test-large-file-record () ()
  (let ((buffer (current-buffer)))
    (large-file-test-log
     (concatenate
      'string
      "STATE name=~a mode=~a literal=~a chars=~d modified=~a readonly=~a "
      "encoding=~a eol=~a tree=~a lsp=~a lint=~a paredit=~a threshold=~a")
     (buffer-name buffer)
     (symbol-name (buffer-major-mode buffer))
     (if (variable-value 'find-file-literally :default buffer) "yes" "no")
     (count-characters (buffer-start-point buffer) (buffer-end-point buffer))
     (if (buffer-modified-p buffer) "yes" "no")
     (if (buffer-read-only-p buffer) "yes" "no")
     (large-file-test-encoding-name buffer)
     (or (large-file-test-eol-name buffer) "none")
     (if (buffer-value buffer 'lem-yath-tree-sitter-parser) "yes" "no")
     (if (ignore-errors (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
         "yes" "no")
     (if (ignore-errors (mode-active-p buffer 'lem-yath-lint-mode))
         "yes" "no")
     (if (ignore-errors
           (mode-active-p buffer 'lem-paredit-mode:paredit-mode))
         "yes" "no")
     *large-file-warning-threshold*)))

(define-command lem-yath-test-large-file-use-small-threshold () ()
  (setf *large-file-warning-threshold* 64)
  (large-file-test-log "THRESHOLD value=~d" *large-file-warning-threshold*))

(define-command lem-yath-test-large-file-reload () ()
  (let ((source
          (merge-pathnames
           "src/large-files.lisp"
           (uiop:ensure-directory-pathname
            (uiop:getenv "LEM_YATH_SOURCE")))))
    (load source)
    (load source)
    (large-file-test-log
     "RELOAD threshold=~d hook=~d"
     *large-file-warning-threshold*
     (large-file-test-hook-count
      'large-file-before-find-file *before-find-file-hook*))))

(define-command lem-yath-test-large-file-abort-state () ()
  (let* ((filename
           (namestring
            (truename (uiop:getenv "LEM_YATH_LARGE_FILE_ABORT"))))
         (visited
           (find filename (buffer-list)
                 :key #'buffer-filename :test #'equal)))
    (large-file-test-log
     "ABORT current=~a visited=~a"
     (buffer-name (current-buffer))
     (if visited "yes" "no"))))

(define-command lem-yath-test-large-file-temporary () ()
  (let ((buffer nil))
    (unwind-protect
         (progn
           (setf buffer
                 (find-file-buffer
                  (uiop:getenv "LEM_YATH_LARGE_FILE_TEMPORARY")
                  :temporary t))
           (large-file-test-log
            "TEMPORARY opened=yes chars=~d literal=~a"
            (count-characters (buffer-start-point buffer)
                              (buffer-end-point buffer))
            (if (variable-value 'find-file-literally :default buffer)
                "yes" "no")))
      (when (and buffer (bufferp buffer))
        (delete-buffer buffer)))))

(define-command lem-yath-test-large-file-revert () ()
  (lem-core/commands/file:revert-buffer nil))

(define-key *global-keymap* "F2" 'lem-yath-test-large-file-record)
(define-key *global-keymap* "F3" 'lem-yath-test-large-file-use-small-threshold)
(define-key *global-keymap* "F4" 'lem-yath-test-large-file-reload)
(define-key *global-keymap* "F5" 'lem-yath-test-large-file-abort-state)
(define-key *global-keymap* "F6" 'lem-yath-test-large-file-temporary)
(define-key *global-keymap* "F7" 'lem-yath-test-large-file-revert)

(let ((buffer (make-buffer "large-file-origin")))
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (insert-string (buffer-end-point buffer) "LARGE FILE ORIGIN\n")
    (buffer-unmark buffer))
  (switch-to-buffer buffer)
  (setf (lem-vi-mode/core:buffer-state buffer)
        (lem-vi-mode/core:ensure-state 'lem-vi-mode/states:normal))
  (large-file-test-log
   "READY threshold=~d hook=~d"
   *large-file-warning-threshold*
   (large-file-test-hook-count
    'large-file-before-find-file *before-find-file-hook*)))
