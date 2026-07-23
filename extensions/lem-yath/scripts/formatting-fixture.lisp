(in-package :lem-yath)

;; The harness loads this fixture before opening its first file.  Every fixture
;; buffer therefore exercises the production find-file hooks.

(defvar *formatting-test-report*
  (uiop:getenv "LEM_YATH_FORMATTING_REPORT"))

(defvar *formatting-test-lsp-call-count* 0)
(defvar *formatting-test-lsp-originals* nil)
(defvar *formatting-test-lsp-attempt-count* 0)
(defvar *formatting-test-lsp-attempt-original* nil)
(defvar *formatting-test-normalize-original* nil)

(defun formatting-test-install-normalize-failure ()
  (unless *formatting-test-normalize-original*
    (let ((original (symbol-function 'editorconfig-normalize-buffer)))
      (setf *formatting-test-normalize-original* original
            (symbol-function 'editorconfig-normalize-buffer)
            (lambda (buffer)
              (prog1 (funcall original buffer)
                (when (and (buffer-value
                            buffer :formatting-test-fail-normalize)
                           (buffer-value
                            buffer 'lem-yath-format-before-save-active))
                  (setf (buffer-value buffer :formatting-test-fail-normalize)
                        nil)
                  (with-point ((tail (buffer-end-point buffer) :left-inserting))
                    (insert-string tail "# normalize hook mutation"))
                  (setf (buffer-value
                         buffer :formatting-test-normalize-forward-count)
                        (or (buffer-value
                             buffer :formatting-test-change-count)
                            0))
                  (formatting-test-log
                   "NORMALIZE-INJECT label=~a changes=~d"
                   (formatting-test-state-label buffer)
                   (buffer-value
                    buffer :formatting-test-normalize-forward-count))
                  (error "Injected EditorConfig normalization failure"))))))))

(defun formatting-test-install-lsp-attempt-probe ()
  (unless *formatting-test-lsp-attempt-original*
    (let ((original (symbol-function 'formatting-run-lsp)))
      (setf *formatting-test-lsp-attempt-original* original
            (symbol-function 'formatting-run-lsp)
            (lambda (buffer)
              (incf *formatting-test-lsp-attempt-count*)
              (funcall original buffer))))))

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

(defun formatting-test-protected-token-p (&optional (buffer (current-buffer)))
  (let ((position (formatting-test-token-position "prefix_value" buffer)))
    (when position
      (with-point ((point (buffer-start-point buffer)))
        (character-offset point position)
        (text-property-at point :read-only)))))

(defun formatting-test-shadow-current-p (&optional (buffer (current-buffer)))
  (and (buffer-value buffer :formatting-test-shadow-valid)
       (string= (or (buffer-value buffer :formatting-test-shadow-text) "")
                (formatting-test-buffer-text buffer))))

(defun formatting-test-shadow-before-change (point argument)
  "Apply one Lem before-change notification to a shadow document."
  (let ((buffer (point-buffer point)))
    (when (buffer-value buffer :formatting-test-observe-shadow)
      (let* ((live (formatting-test-buffer-text buffer))
             (shadow (or (buffer-value buffer :formatting-test-shadow-text) ""))
             (position (1- (position-at-point point))))
        (unless (string= live shadow)
          (setf (buffer-value buffer :formatting-test-shadow-valid) nil))
        (handler-case
            (setf (buffer-value buffer :formatting-test-shadow-text)
                  (etypecase argument
                    (string
                     (concatenate 'string
                                  (subseq shadow 0 position)
                                  argument
                                  (subseq shadow position)))
                    (integer
                     (concatenate
                      'string
                      (subseq shadow 0 position)
                      (subseq shadow (min (length shadow)
                                         (+ position argument)))))))
          (error ()
            (setf (buffer-value buffer :formatting-test-shadow-valid) nil)))
        (setf (buffer-value buffer :formatting-test-shadow-version)
              (1+ (or (buffer-value
                       buffer :formatting-test-shadow-version)
                      0)))))))

(defun formatting-test-start-observers (buffer)
  (setf (buffer-value buffer :formatting-test-change-count) 0
        (buffer-value buffer :formatting-test-observe-changes) t
        (buffer-value buffer :formatting-test-shadow-text)
        (formatting-test-buffer-text buffer)
        (buffer-value buffer :formatting-test-shadow-valid) t
        (buffer-value buffer :formatting-test-shadow-version) 0
        (buffer-value buffer :formatting-test-observe-shadow) t
        (buffer-value buffer :formatting-test-normalize-forward-count) 0))

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
(ignore-errors
  ;; The harness supplies Black through a private PATH.  Directory transitions
  ;; belong to the dedicated direnv gate and must not restore a pre-harness
  ;; PATH while formatter execution is under test.
  (direnv-mode nil))
(formatting-test-install-lsp-probes)

(define-major-mode lem-yath-formatting-test-mode
    lem/language-mode:language-mode
    (:name "Formatting Fixture"))

(define-file-type ("fmtfixture") lem-yath-formatting-test-mode)

(defun formatting-test-state-label (&optional (buffer (current-buffer)))
  (or (buffer-value buffer :formatting-test-label)
      (file-namestring (or (buffer-filename buffer) (buffer-name buffer)))))

(defun formatting-test-format-hook-entries (&optional (buffer (current-buffer)))
  (declare (ignore buffer))
  (remove-if-not
   (lambda (entry)
     (eq 'formatting-before-save-hook (car entry)))
   (variable-value 'before-save-hook :global t)))

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
         (encoding (buffer-encoding buffer))
         (undo (ignore-errors (lem:buffer-undo-tree-snapshot buffer))))
    (formatting-test-log
     (concatenate
      'string
      "STATE label=~a text-hex=~a disk-hex=~a modified=~a "
      "point=~d mark=~a mark-point=~a point-keep=~a mark-tail=~a "
      "global-tabs=~a local-tabs=~a tab-width=~a editorconfig=~a "
      "trim=~s auto=~s formatter=~a format-hook-count=~d "
      "format-hooks=~a encoding=~a eol=~a lsp=~d changes=~d "
      "protected=~a shadow=~a shadow-version=~d normalize-forward=~d "
      "normalization-pending=~a undo-truncated=~a undo-clean=~a "
      "undo-saved=~a lsp-attempts=~d")
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
     (buffer-value buffer 'lem-yath-format-before-save-active)
     (formatting-test-formatter-id buffer)
     (length (formatting-test-format-hook-entries buffer))
     (formatting-test-format-hook-summary buffer)
     (type-of encoding)
     (encoding-end-of-line encoding)
     *formatting-test-lsp-call-count*
     (or (buffer-value buffer :formatting-test-change-count) 0)
     (formatting-test-yes-no (formatting-test-protected-token-p buffer))
     (formatting-test-yes-no (formatting-test-shadow-current-p buffer))
     (or (buffer-value buffer :formatting-test-shadow-version) 0)
     (or (buffer-value buffer :formatting-test-normalize-forward-count) 0)
     (formatting-test-yes-no
      (buffer-value buffer 'lem-yath-save-normalization-pending))
     (formatting-test-yes-no (and undo (getf undo :truncated)))
     (or (and undo (getf undo :clean)) "none")
     (or (and undo (getf undo :last-saved)) "none")
     *formatting-test-lsp-attempt-count*)))

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
               "production-find-file-opened")
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

(define-command lem-yath-test-formatting-open-normalize-error () ()
  (formatting-test-open
   "LEM_YATH_FORMATTING_NORMALIZE_ERROR" "normalize-error"))

(define-command lem-yath-test-formatting-open-unset () ()
  (formatting-test-open "LEM_YATH_FORMATTING_UNSET" "unset-open"))

(define-command lem-yath-test-formatting-open-false () ()
  (formatting-test-open "LEM_YATH_FORMATTING_FALSE" "false-open"))

(define-command lem-yath-test-formatting-open-bytes () ()
  (formatting-test-open "LEM_YATH_FORMATTING_BYTES" "bytes-open"))

(define-command lem-yath-test-formatting-open-manual () ()
  (formatting-test-open "LEM_YATH_FORMATTING_MANUAL" "manual-open"))

(define-command lem-yath-test-formatting-open-java () ()
  (formatting-test-open "LEM_YATH_FORMATTING_JAVA" "java-open"))

(define-command lem-yath-test-formatting-java-checks () ()
  (let ((failures 0)
        (buffer (current-buffer)))
    (labels ((check (condition label)
               (formatting-test-log "~a JAVA ~a"
                                    (if condition "PASS" "FAIL") label)
               (unless condition (incf failures))))
      (let* ((formatter (formatting-resolve-spec buffer))
             (command (and formatter
                           (funcall (formatter-spec-command-builder formatter)
                                    buffer)))
             (expected (formatting-test-path
                        "LEM_YATH_TEST_GOOGLE_JAVA_FORMAT")))
        (check (eq 'lem-java-mode:java-mode (buffer-major-mode buffer))
               "java-major-mode")
        (check (and formatter
                    (eq 'java (formatter-spec-id formatter)))
               "java-formatter")
        (check (and command
                    (equal '("-") (rest command)))
               "java-formatter-arguments")
        (check (and command
                    (uiop:pathname-equal (truename expected)
                                         (truename (first command))))
               "java-formatter-packaged-path")
        (check (typep (lem-lsp-mode/spec:get-language-spec
                       'lem-java-mode:java-mode)
                      'lem-yath-java-spec)
               "java-jdtls-spec")
        (check (null (buffer-value buffer 'lem-lsp-mode::lsp-workspace))
               "java-no-automatic-workspace")
        (check (not (mode-active-p buffer 'lem-lsp-mode::lsp-mode))
               "java-no-automatic-lsp-mode"))
      (formatting-test-log "SUMMARY JAVA ~a failures=~d"
                           (if (zerop failures) "PASS" "FAIL")
                           failures))))

(define-command lem-yath-test-formatting-open-auto () ()
  (formatting-test-open "LEM_YATH_FORMATTING_AUTO" "auto-open"))

(define-command lem-yath-test-formatting-open-failure () ()
  (formatting-test-open "LEM_YATH_FORMATTING_FAILURE" "failure-open"))

(define-command lem-yath-test-formatting-open-transaction-manual () ()
  (formatting-test-open
   "LEM_YATH_FORMATTING_TRANSACTION_MANUAL" "transaction-manual"))

(define-command lem-yath-test-formatting-open-transaction-auto () ()
  (formatting-test-open
   "LEM_YATH_FORMATTING_TRANSACTION_AUTO" "transaction-auto"))

(define-command lem-yath-test-formatting-open-transaction-finalizer () ()
  (formatting-test-open
   "LEM_YATH_FORMATTING_TRANSACTION_FINALIZER" "transaction-finalizer"))

(define-command lem-yath-test-formatting-open-finalizer-mark () ()
  (formatting-test-open
   "LEM_YATH_FORMATTING_FINALIZER_MARK" "finalizer-mark"))

(define-command lem-yath-test-formatting-open-rollback-failure () ()
  (formatting-test-open
   "LEM_YATH_FORMATTING_ROLLBACK_FAILURE" "rollback-failure"))

(define-command lem-yath-test-formatting-open-read-only () ()
  (formatting-test-open
   "LEM_YATH_FORMATTING_READ_ONLY" "read-only-preflight"))

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

(define-command lem-yath-test-formatting-prepare-normalize-error () ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer :formatting-test-label) "normalize-error")
    (formatting-test-install-normalize-failure)
    (formatting-test-start-observers buffer)
    (setf (buffer-value buffer :formatting-test-fail-normalize) t)
    ;; Make the whitespace-bearing second line touched without changing
    ;; visible text.  ws-butler trims it first inside the same transaction in
    ;; which EditorConfig trims the remaining line.
    (with-point ((point (buffer-start-point buffer)))
      (line-offset point 1)
      (line-start point)
      (insert-string point "X")
      (with-point ((delete (buffer-start-point buffer)))
        (line-offset delete 1)
        (line-start delete)
        (delete-character delete 1)))
    (formatting-test-start-observers buffer)
    (formatting-test-log
     "PREPARE label=normalize-error modified=~a"
     (formatting-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-formatting-retry-normalize-error () ()
  (let ((buffer (current-buffer)))
    ;; A no-net-text edit starts the next dirty epoch. Pending normalization
    ;; must retain the earlier touched-line marker across this change.
    (with-point ((point (buffer-start-point buffer)))
      (line-offset point 2)
      (line-start point)
      (insert-character point #\X)
      (with-point ((delete (buffer-start-point buffer)))
        (line-offset delete 2)
        (line-start delete)
        (delete-character delete 1)))
    (formatting-test-start-observers buffer)
    (formatting-test-log
     "RETRY label=normalize-error modified=~a pending=~a"
     (formatting-test-yes-no (buffer-modified-p buffer))
     (formatting-test-yes-no
      (buffer-value buffer 'lem-yath-save-normalization-pending)))))

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

(defun formatting-test-set-token-anchors (buffer)
  (let* ((text (formatting-test-buffer-text buffer))
         (keep (search "KEEP_MARKER" text))
         (tail (search "TAIL_MARKER" text)))
    (unless (and keep tail)
      (error "Formatting fixture tokens are missing"))
    (buffer-mark-cancel buffer)
    (buffer-start (buffer-point buffer))
    (character-offset (buffer-point buffer) keep)
    (with-point ((mark (buffer-start-point buffer)))
      (character-offset mark tail)
      (setf (buffer-mark buffer) mark))
    (values keep tail)))

(defun formatting-test-restore-mark-before-format (buffer)
  (when (buffer-value buffer :formatting-test-restore-mark-before-format)
    (setf (buffer-value buffer :formatting-test-restore-mark-before-format)
          nil)
    (formatting-test-set-token-anchors buffer)))

(define-command lem-yath-test-formatting-prepare-manual () ()
  (let ((buffer (current-buffer)))
    (multiple-value-bind (keep tail)
        (formatting-test-set-token-anchors buffer)
      (declare (ignore keep))
      (clear-buffer-edit-history buffer)
      (setf (buffer-value buffer :formatting-test-label) "manual-ready")
      (formatting-test-log
       "PREPARE label=manual-ready point=~d mark=~d modified=~a"
       (position-at-point (buffer-point buffer))
       tail
       (formatting-test-yes-no (buffer-modified-p buffer))))))

(defun formatting-test-fail-after-change-once (start end old-length)
  (declare (ignore end))
  (let ((buffer (point-buffer start)))
    (when (buffer-value buffer :formatting-test-fail-after-change)
      (setf (buffer-value buffer :formatting-test-fail-after-change) nil)
      (formatting-test-log
       "INJECT label=~a old-length=~d modified=~a"
       (formatting-test-state-label buffer)
       old-length
       (formatting-test-yes-no (buffer-modified-p buffer)))
      ;; Mutate recursively before throwing.  The outer edit must already be
      ;; retained so cancellation can replay this nested edit first.
      (with-point ((tail (buffer-end-point buffer) :left-inserting))
        (insert-string tail "# nested hook mutation"))
      (error "Injected one-shot formatter after-change failure"))))

(defun formatting-test-fail-after-change-persistently (start end old-length)
  (declare (ignore end))
  (let ((buffer (point-buffer start)))
    (when (buffer-value buffer :formatting-test-fail-persistently)
      (formatting-test-log
       "PERSISTENT-INJECT label=~a old-length=~d"
       (formatting-test-state-label buffer) old-length)
      (error "Injected persistent formatter after-change failure"))))

(defun formatting-test-count-after-change (start end old-length)
  (declare (ignore end old-length))
  (let ((buffer (point-buffer start)))
    (when (buffer-value buffer :formatting-test-observe-changes)
      (setf (buffer-value buffer :formatting-test-change-count)
            (1+ (or (buffer-value buffer :formatting-test-change-count)
                    0))))))

(defun formatting-test-install-after-change-failure (buffer)
  (formatting-test-start-observers buffer)
  (setf (buffer-value buffer :formatting-test-fail-after-change) t))

(defun formatting-test-install-persistent-failure (buffer)
  (formatting-test-start-observers buffer)
  (setf (buffer-value buffer :formatting-test-fail-persistently) t))

(define-command lem-yath-test-formatting-prepare-transaction-manual () ()
  (let ((buffer (current-buffer)))
    (with-point ((start (buffer-start-point buffer) :left-inserting))
      (insert-string start (format nil "# transaction edit~%")))
    (setf (buffer-value buffer :formatting-test-label) "transaction-manual")
    (multiple-value-bind (keep tail)
        (formatting-test-set-token-anchors buffer)
      (formatting-test-install-after-change-failure buffer)
      (formatting-test-log
       (concatenate
        'string
        "PREPARE label=transaction-manual point=~d mark=~d "
        "keep=~d modified=~a")
       (position-at-point (buffer-point buffer)) tail keep
       (formatting-test-yes-no (buffer-modified-p buffer))))))

(define-command lem-yath-test-formatting-prepare-transaction-auto () ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer :formatting-test-label) "transaction-auto")
    (formatting-test-insert-first-line "# transaction save")
    (formatting-test-install-after-change-failure buffer)
    (formatting-test-log
     "PREPARE label=transaction-auto modified=~a"
     (formatting-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-formatting-prepare-transaction-finalizer () ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer :formatting-test-label)
          "transaction-finalizer")
    (formatting-test-insert-first-line "# transaction finalizer")
    (formatting-test-install-normalize-failure)
    (formatting-test-start-observers buffer)
    (setf (buffer-value buffer :formatting-test-fail-normalize) t)
    (formatting-test-log
     "PREPARE label=transaction-finalizer modified=~a"
     (formatting-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-formatting-prepare-finalizer-mark () ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer :formatting-test-label) "finalizer-mark")
    (formatting-test-insert-first-line "# mark save")
    (multiple-value-bind (keep tail)
        (formatting-test-set-token-anchors buffer)
      (formatting-test-start-observers buffer)
      (setf (buffer-value buffer :formatting-test-restore-mark-before-format)
            t)
      (formatting-test-log
       (concatenate
        'string
        "PREPARE label=finalizer-mark point=~d mark=~d keep=~d "
        "modified=~a")
       (position-at-point (buffer-point buffer)) tail keep
       (formatting-test-yes-no (buffer-modified-p buffer))))))

(define-command lem-yath-test-formatting-prepare-rollback-failure () ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer :formatting-test-label) "rollback-failure")
    (formatting-test-insert-first-line "# rollback failure")
    (formatting-test-install-persistent-failure buffer)
    (formatting-test-log
     "PREPARE label=rollback-failure modified=~a"
     (formatting-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-formatting-prepare-read-only () ()
  (let ((buffer (current-buffer)))
    ;; Establish one known user undo step before the refusal.
    (with-point ((start (buffer-start-point buffer) :left-inserting))
      (insert-string start (format nil "# read-only edit~%")))
    (let* ((text (formatting-test-buffer-text buffer))
         (keep (search "KEEP_MARKER" text))
         (prefix (search "prefix_value" text)))
      (unless (and keep prefix)
        (error "Read-only formatting fixture tokens are missing"))
      (with-point ((start (buffer-start-point buffer))
                   (end (buffer-start-point buffer)))
        (character-offset start prefix)
        (character-offset end (+ prefix (length "prefix_value")))
        (put-text-property start end :read-only t))
      (setf (buffer-value buffer :formatting-test-label) "read-only-preflight")
      (formatting-test-set-token-anchors buffer)
      (formatting-test-start-observers buffer)
      (formatting-test-log
       "PREPARE label=read-only-preflight protected=~d modified=~a"
       prefix
       (formatting-test-yes-no (buffer-modified-p buffer))))))

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
  (formatting-test-install-lsp-attempt-probe)
  (formatting-test-insert-first-line "# failure edit   ")
  ;; Observe save normalization after the formatter process fails, without
  ;; accepting its partial stdout.
  (formatting-test-start-observers (current-buffer)))

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
       (not (find 'trim-trailing-whitespace-hook
                  (variable-value 'before-save-hook :global t)
                  :key #'car))
       (not (find 'lem-yath-format-after-save
                  (variable-value 'after-save-hook :buffer buffer)
                  :key #'car))))

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
        ;; Simulate reloading from the former post-save implementation.
        (add-hook (variable-value 'after-save-hook :buffer buffer)
                  'lem-yath-format-after-save 1000)
        (add-hook (variable-value 'before-save-hook :global t)
                  'trim-trailing-whitespace-hook)
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
            (and properties-before
                 (equal properties-before
                        (formatting-test-properties buffer))))
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

(remove-hook (variable-value 'before-change-functions :global t)
             'formatting-test-shadow-before-change)
(add-hook (variable-value 'before-change-functions :global t)
          'formatting-test-shadow-before-change 30000)
(remove-hook (variable-value 'before-save-hook :global t)
             'formatting-test-restore-mark-before-format)
(add-hook (variable-value 'before-save-hook :global t)
          'formatting-test-restore-mark-before-format -75)
(remove-hook (variable-value 'after-change-functions :global t)
             'formatting-test-count-after-change)
(add-hook (variable-value 'after-change-functions :global t)
          'formatting-test-count-after-change 20000)
(remove-hook (variable-value 'after-change-functions :global t)
             'formatting-test-fail-after-change-persistently)
(add-hook (variable-value 'after-change-functions :global t)
          'formatting-test-fail-after-change-persistently 11000)
(remove-hook (variable-value 'after-change-functions :global t)
             'formatting-test-fail-after-change-once)
(add-hook (variable-value 'after-change-functions :global t)
          'formatting-test-fail-after-change-once 10000)

(remove-hook (variable-value 'after-save-hook :global t)
             'formatting-test-after-save-observer)
(add-hook (variable-value 'after-save-hook :global t)
          'formatting-test-after-save-observer -10000)

(formatting-test-log "READY")
