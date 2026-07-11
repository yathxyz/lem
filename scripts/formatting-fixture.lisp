(in-package :lem-yath)

;; This fixture is loaded after the real configuration but before Lem opens
;; the file passed on its command line.  Consequently the first Python buffer
;; exercises the production find-file hooks rather than a test-side reapply.

(defvar *formatting-test-report*
  (uiop:getenv "LEM_YATH_FORMATTING_REPORT"))

(defvar *formatting-test-lsp-call-count* 0)
(defvar *formatting-test-lsp-originals* nil)

(defun formatting-test-log (control &rest arguments)
  (with-open-file (stream *formatting-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun formatting-test-yes-no (value)
  (if value "yes" "no"))

(defun formatting-test-string-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (format stream "~2,'0X" (char-code character)))))

(defun formatting-test-file-hex (pathname)
  (handler-case
      (with-open-file (stream pathname
                              :direction :input
                              :element-type '(unsigned-byte 8))
        (with-output-to-string (output)
          (loop :for byte := (read-byte stream nil nil)
                :while byte
                :do (format output "~2,'0X" byte))))
    (file-error () "missing")))

(defun formatting-test-buffer-text (&optional (buffer (current-buffer)))
  (points-to-string (buffer-start-point buffer) (buffer-end-point buffer)))

(defun formatting-test-path (variable)
  (or (uiop:getenv variable)
      (error "Missing formatting fixture variable ~a" variable)))

(defun formatting-test-properties (&optional (buffer (current-buffer)))
  (when (fboundp 'editorconfig-buffer-properties)
    (editorconfig-buffer-properties buffer)))

(defun formatting-test-property (name &optional (buffer (current-buffer)))
  (cdr (assoc name (formatting-test-properties buffer)
              :test #'string-equal)))

(defun formatting-test-formatter-id (&optional (buffer (current-buffer)))
  (handler-case
      (let ((spec (and (fboundp 'formatting-resolve-spec)
                       (formatting-resolve-spec buffer))))
        (if spec
            (formatter-spec-id spec)
            "none"))
    (error () "error")))

(defun formatting-test-token-position (token &optional (buffer (current-buffer)))
  (search token (formatting-test-buffer-text buffer)))

(defun formatting-test-point-on-token-p (point token &optional (buffer (current-buffer)))
  (let ((position (formatting-test-token-position token buffer)))
    (and position (= (1+ position) (position-at-point point)))))

(defun formatting-test-install-lsp-probes ()
  "Count any forbidden CLI-failure fallback without changing its behavior."
  (dolist (name '("LSP-DOCUMENT-FORMAT" "TEXT-DOCUMENT/FORMATTING"))
    (alexandria:when-let* ((package (find-package :lem-lsp-mode))
                           (symbol (find-symbol name package)))
      (when (and (fboundp symbol)
                 (null (assoc symbol *formatting-test-lsp-originals*)))
        (let ((original (symbol-function symbol)))
          (push (cons symbol original) *formatting-test-lsp-originals*)
          (setf (symbol-function symbol)
                (lambda (&rest arguments)
                  (incf *formatting-test-lsp-call-count*)
                  (apply original arguments))))))))

;; A .py buffer would normally try to launch pyright during this isolated
;; fixture.  Formatting is under test, not LSP startup, and the wrappers above
;; still detect any explicit formatting fallback.
(ignore-errors
  (remove-hook lem-python-mode:*python-mode-hook*
               'lem-lsp-mode::enable-lsp-mode))
(formatting-test-install-lsp-probes)

(define-major-mode lem-yath-formatting-test-mode
    lem/language-mode:language-mode
    (:name "Formatting Fixture"))

(define-file-type ("fmtfixture") lem-yath-formatting-test-mode)

(defun formatting-test-state-label (&optional (buffer (current-buffer)))
  (or (buffer-value buffer :formatting-test-label)
      (file-namestring (or (buffer-filename buffer) (buffer-name buffer)))))

(defun formatting-test-format-hook-entries (&optional (buffer (current-buffer)))
  (remove-if-not
   (lambda (entry)
     (eq 'lem-yath-format-after-save (car entry)))
   (variable-value 'after-save-hook :buffer buffer)))

(defun formatting-test-format-hook-summary (&optional (buffer (current-buffer)))
  (let ((entries (formatting-test-format-hook-entries buffer)))
    (if entries
        (format nil "~{~a@~a~^,~}"
                (mapcan (lambda (entry)
                          (list (car entry) (cdr entry)))
                        entries))
        "none")))

(defun formatting-test-record-state ()
  (let* ((buffer (current-buffer))
         (point (current-point))
         (mark (cursor-mark point))
         (mark-point (mark-point mark))
         (encoding (buffer-encoding buffer)))
    (formatting-test-log
     (concatenate
      'string
      "STATE label=~a text-hex=~a disk-hex=~a modified=~a "
      "point=~d mark=~a mark-point=~a point-keep=~a mark-tail=~a "
      "global-tabs=~a local-tabs=~a tab-width=~a editorconfig=~a "
      "trim=~s auto=~s formatter=~a format-hook-count=~d "
      "format-hooks=~a encoding=~a eol=~a lsp=~d")
     (formatting-test-state-label buffer)
     (formatting-test-string-hex (formatting-test-buffer-text buffer))
     (if (buffer-filename buffer)
         (formatting-test-file-hex (buffer-filename buffer))
         "none")
     (formatting-test-yes-no (buffer-modified-p buffer))
     (position-at-point point)
     (formatting-test-yes-no (mark-active-p mark))
     (if mark-point (position-at-point mark-point) "none")
     (formatting-test-yes-no
      (formatting-test-point-on-token-p point "KEEP_MARKER" buffer))
     (formatting-test-yes-no
      (and mark-point
           (formatting-test-point-on-token-p mark-point "TAIL_MARKER" buffer)))
     (formatting-test-yes-no
      (variable-value 'indent-tabs-mode :global))
     (formatting-test-yes-no
      (variable-value 'indent-tabs-mode :buffer buffer))
     (variable-value 'tab-width :buffer buffer)
     (formatting-test-yes-no
      (buffer-value buffer 'lem-yath-editorconfig-mode))
     (buffer-value buffer 'lem-yath-editorconfig-trim)
     (buffer-value buffer 'lem-yath-format-after-save-active)
     (formatting-test-formatter-id buffer)
     (length (formatting-test-format-hook-entries buffer))
     (formatting-test-format-hook-summary buffer)
     (type-of encoding)
     (encoding-end-of-line encoding)
     *formatting-test-lsp-call-count*)))

(define-command lem-yath-test-formatting-record () ()
  (formatting-test-record-state))

(define-command lem-yath-test-formatting-static-checks () ()
  (let ((failures 0)
        (buffer (current-buffer)))
    (labels ((check (condition label)
               (formatting-test-log "~a STATIC ~a"
                                    (if condition "PASS" "FAIL") label)
               (unless condition (incf failures))))
      (let* ((properties (formatting-test-properties buffer))
             (formatter-id (formatting-test-formatter-id buffer))
             (expected (ignore-errors
                         (truename
                          (formatting-test-path
                           "LEM_YATH_FORMATTING_MANUAL"))))
             (actual (ignore-errors
                       (truename (buffer-filename buffer)))))
        (check (fboundp 'editorconfig-buffer-properties)
               "editorconfig-api-present")
        (check (fboundp 'formatting-resolve-spec)
               "formatter-api-present")
        (check (and expected actual (equal expected actual))
               "command-line-file-opened")
        (check (programming-buffer-p buffer)
               "python-is-programming")
        (check (buffer-value buffer 'lem-yath-editorconfig-mode)
               "editorconfig-active-on-open")
        (check (equal "space" (formatting-test-property "indent_style" buffer))
               "parent-python-indent-style")
        (check (equal "6" (formatting-test-property "indent_size" buffer))
               "nearer-indent-size-wins")
        (check (equal "7" (formatting-test-property "tab_width" buffer))
               "explicit-parent-tab-width-survives")
        (check (null (assoc "trim_trailing_whitespace" properties
                            :test #'string-equal))
               "unset-removes-inherited-trim")
        (check (equal "false"
                      (formatting-test-property "insert_final_newline" buffer))
               "nearer-final-newline-wins")
        (check (equal "lf" (formatting-test-property "end_of_line" buffer))
               "nearer-eol-wins")
        (check (equal "utf-8" (formatting-test-property "charset" buffer))
               "nearer-charset-wins")
        (check (null (assoc "max_line_length" properties
                            :test #'string-equal))
               "root-true-stops-parent-search")
        (check (null (variable-value 'indent-tabs-mode :global))
               "global-no-tabs")
        (check (= 4 (variable-value 'tab-width :global))
               "global-tab-width-four")
        (check (null (variable-value 'indent-tabs-mode :buffer buffer))
               "editorconfig-space-indentation")
        (check (= 7 (variable-value 'tab-width :buffer buffer))
               "editorconfig-tab-width-applied")
        (check (search "PYTHON" (princ-to-string formatter-id)
                       :test #'char-equal)
               "python-resolves-python-backend"))
      (formatting-test-log "SUMMARY STATIC ~a failures=~d"
                           (if (zerop failures) "PASS" "FAIL")
                           failures))))

(defun formatting-test-open (variable label)
  (let ((buffer (find-file-buffer (formatting-test-path variable))))
    (switch-to-buffer buffer)
    (setf (buffer-value buffer :formatting-test-label) label)
    (formatting-test-log "OPEN label=~a file-hex=~a"
                         label
                         (formatting-test-string-hex
                          (namestring (buffer-filename buffer))))))

(define-command lem-yath-test-formatting-open-true () ()
  (formatting-test-open "LEM_YATH_FORMATTING_TRUE" "true-open"))

(define-command lem-yath-test-formatting-open-unset () ()
  (formatting-test-open "LEM_YATH_FORMATTING_UNSET" "unset-open"))

(define-command lem-yath-test-formatting-open-false () ()
  (formatting-test-open "LEM_YATH_FORMATTING_FALSE" "false-open"))

(define-command lem-yath-test-formatting-open-bytes () ()
  (formatting-test-open "LEM_YATH_FORMATTING_BYTES" "bytes-open"))

(define-command lem-yath-test-formatting-open-manual () ()
  (formatting-test-open "LEM_YATH_FORMATTING_MANUAL" "manual-open"))

(define-command lem-yath-test-formatting-open-auto () ()
  (formatting-test-open "LEM_YATH_FORMATTING_AUTO" "auto-open"))

(define-command lem-yath-test-formatting-open-failure () ()
  (formatting-test-open "LEM_YATH_FORMATTING_FAILURE" "failure-open"))

(defun formatting-test-touch-second-line (label)
  (let ((buffer (current-buffer)))
    ;; Insert and remove the same character through normal buffer primitives.
    ;; The file text remains unchanged, but ws-butler observes line two and the
    ;; buffer remains modified for the subsequent real C-x C-s.
    (with-point ((point (buffer-start-point buffer)))
      (line-offset point 1)
      (line-start point)
      (insert-character point #\X))
    (with-point ((point (buffer-start-point buffer)))
      (line-offset point 1)
      (line-start point)
      (delete-character point 1))
    (setf (buffer-value buffer :formatting-test-label) label)
    (formatting-test-log "TOUCH label=~a modified=~a"
                         label
                         (formatting-test-yes-no
                          (buffer-modified-p buffer)))))

(define-command lem-yath-test-formatting-touch-true () ()
  (formatting-test-touch-second-line "true-touched"))

(define-command lem-yath-test-formatting-touch-unset () ()
  (formatting-test-touch-second-line "unset-touched"))

(define-command lem-yath-test-formatting-touch-false () ()
  (formatting-test-touch-second-line "false-touched"))

(define-command lem-yath-test-formatting-prepare-bytes () ()
  (let ((buffer (current-buffer)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-point buffer)
                     (format nil "caf~c  ~%line"
                             (code-char #xE9))))
    (setf (buffer-value buffer :formatting-test-label) "bytes-ready")
    (formatting-test-log "PREPARE label=bytes-ready modified=~a"
                         (formatting-test-yes-no
                          (buffer-modified-p buffer)))))

(define-command lem-yath-test-formatting-prepare-manual () ()
  (let* ((buffer (current-buffer))
         (text (formatting-test-buffer-text buffer))
         (keep (search "KEEP_MARKER" text))
         (tail (search "TAIL_MARKER" text)))
    (unless (and keep tail)
      (error "Manual fixture tokens are missing"))
    (buffer-mark-cancel buffer)
    (buffer-start (buffer-point buffer))
    (character-offset (buffer-point buffer) keep)
    (with-point ((mark (buffer-start-point buffer)))
      (character-offset mark tail)
      (setf (buffer-mark buffer) mark))
    (clear-buffer-edit-history buffer)
    (setf (buffer-value buffer :formatting-test-label) "manual-ready")
    (formatting-test-log
     "PREPARE label=manual-ready point=~d mark=~d modified=~a"
     (position-at-point (buffer-point buffer))
     tail
     (formatting-test-yes-no (buffer-modified-p buffer)))))

(defun formatting-test-insert-first-line (text)
  (let ((buffer (current-buffer)))
    (with-point ((start (buffer-start-point buffer) :left-inserting))
      (insert-string start (format nil "~a~%" text)))
    (formatting-test-log (concatenate
                          'string
                          "EDIT label=~a modified=~a programming=~a "
                          "formatter=~a format-hook-count=~d "
                          "format-hooks=~a")
                         (formatting-test-state-label buffer)
                         (formatting-test-yes-no
                          (buffer-modified-p buffer))
                         (formatting-test-yes-no
                          (programming-buffer-p buffer))
                         (formatting-test-formatter-id buffer)
                         (length (formatting-test-format-hook-entries buffer))
                         (formatting-test-format-hook-summary buffer))))

(define-command lem-yath-test-formatting-edit-auto () ()
  (formatting-test-insert-first-line "# user edit"))

(define-command lem-yath-test-formatting-edit-failure () ()
  (formatting-test-insert-first-line "# failure edit"))

(defun formatting-test-one-hook-p (hooks callback weight)
  (let ((matches (remove-if-not (lambda (entry)
                                  (eq callback (car entry)))
                                hooks)))
    (and (= 1 (length matches))
         (= weight (cdr (first matches))))))

(defun formatting-test-editorconfig-hooks-ok-p ()
  (and (formatting-test-one-hook-p
        *find-file-hook* 'editorconfig-refresh-buffer-if-stale 0)
       (formatting-test-one-hook-p
        *switch-to-buffer-hook* 'editorconfig-refresh-buffer-if-stale 0)
       (formatting-test-one-hook-p
        (variable-value 'before-save-hook :global t)
        'editorconfig-before-save *editorconfig-before-save-hook-weight*)
       (formatting-test-one-hook-p
        *post-command-hook* 'editorconfig-post-command -300)))

(defun formatting-test-formatting-hooks-ok-p (buffer)
  (and (formatting-test-one-hook-p
        *find-file-hook* 'formatting-find-file-hook 3000)
       (formatting-test-one-hook-p
        *post-command-hook* 'formatting-post-command-hook 0)
       (formatting-test-one-hook-p
        (variable-value 'before-save-hook :global t)
        'formatting-before-save-hook -100)
       (formatting-test-one-hook-p
        (variable-value 'after-save-hook :buffer buffer)
        'lem-yath-format-after-save 1000)))

(defun formatting-test-after-save-observer (&optional (buffer (current-buffer)))
  (when (typep buffer 'lem:buffer)
    (formatting-test-log
     (concatenate
      'string
      "AFTER-SAVE label=~a modified=~a programming=~a formatter=~a "
      "format-hook-count=~d format-hooks=~a")
     (formatting-test-state-label buffer)
     (formatting-test-yes-no (buffer-modified-p buffer))
     (formatting-test-yes-no (programming-buffer-p buffer))
     (formatting-test-formatter-id buffer)
     (length (formatting-test-format-hook-entries buffer))
     (formatting-test-format-hook-summary buffer))))

(define-command lem-yath-test-formatting-reload () ()
  (handler-case
      (let* ((buffer (current-buffer))
             (properties-before (copy-tree
                                 (formatting-test-properties buffer)))
             (spec-before (formatting-test-formatter-id buffer))
             (editorconfig-source
               (asdf:system-relative-pathname
                "lem-yath" "src/editorconfig.lisp"))
             (formatting-source
               (asdf:system-relative-pathname
                "lem-yath" "src/formatting.lisp")))
        (load editorconfig-source)
        (load editorconfig-source)
        (let ((editorconfig-hooks
                (formatting-test-editorconfig-hooks-ok-p)))
          (load formatting-source)
          (load formatting-source)
          (formatting-test-log
           (concatenate
            'string
            "RELOAD editorconfig-hooks=~a formatting-hooks=~a "
            "properties=~a spec=~a")
           (formatting-test-yes-no editorconfig-hooks)
           (formatting-test-yes-no
            (formatting-test-formatting-hooks-ok-p buffer))
           (formatting-test-yes-no
            (equal properties-before
                   (formatting-test-properties buffer)))
           (formatting-test-yes-no
            (equal spec-before (formatting-test-formatter-id buffer))))))
    (error (condition)
      (formatting-test-log "RELOAD error-hex=~a"
                           (formatting-test-string-hex
                            (princ-to-string condition))))))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F5" 'lem-yath-test-formatting-record))

(remove-hook (variable-value 'after-save-hook :global t)
             'formatting-test-after-save-observer)
(add-hook (variable-value 'after-save-hook :global t)
          'formatting-test-after-save-observer -10000)

(formatting-test-log "READY")
