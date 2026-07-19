;;;; EditorConfig integration.  Matching and inheritance are delegated to the
;;;; official `editorconfig' CLI; this file only maps its resolved properties
;;;; onto Lem buffer state.

(in-package :lem-yath)

(defparameter *editorconfig-timeout-seconds* 5)
(defparameter *editorconfig-before-save-hook-weight* -50)

(defvar *editorconfig-program* :unknown)
(defvar *editorconfig-timeout-program* :unknown)
(defvar *editorconfig-warning-keys* (make-hash-table :test #'equal))

(defparameter *editorconfig-controlled-variables*
  '(indent-tabs-mode
    tab-width
    lem/language-mode:indent-size))

;;; Encodings -----------------------------------------------------------------

;; Lem's optional encoding extension is not guaranteed to be loaded in every
;; image.  These small write-only encodings make EditorConfig charset changes
;; deterministic without adding a runtime ASDF dependency.  Existing files
;; have already been decoded when the find-file hook runs, so the new encoding
;; intentionally affects subsequent writes only.

(defclass editorconfig-utf-8-bom-encoding
    (lem/buffer/encodings:encoding)
  ())

(defclass editorconfig-latin1-encoding
    (lem/buffer/encodings:encoding)
  ())

(defclass editorconfig-utf-16-encoding
    (lem/buffer/encodings:encoding)
  ((endianness
    :initarg :endianness
    :reader editorconfig-utf-16-endianness)))

(defun editorconfig-write-utf-8-codepoint (code stream)
  (cond
    ((<= code #x7f)
     (write-byte code stream))
    ((<= code #x7ff)
     (write-byte (+ #xc0 (ash code -6)) stream)
     (write-byte (+ #x80 (logand code #x3f)) stream))
    ((<= code #xffff)
     (write-byte (+ #xe0 (ash code -12)) stream)
     (write-byte (+ #x80 (logand (ash code -6) #x3f)) stream)
     (write-byte (+ #x80 (logand code #x3f)) stream))
    ((<= code #x10ffff)
     (write-byte (+ #xf0 (ash code -18)) stream)
     (write-byte (+ #x80 (logand (ash code -12) #x3f)) stream)
     (write-byte (+ #x80 (logand (ash code -6) #x3f)) stream)
     (write-byte (+ #x80 (logand code #x3f)) stream))
    (t
     (error "Character code ~X is not valid UTF-8" code))))

(defmethod lem/buffer/encodings:encoding-write
    ((encoding editorconfig-utf-8-bom-encoding) stream)
  (declare (ignore encoding))
  (write-byte #xef stream)
  (write-byte #xbb stream)
  (write-byte #xbf stream)
  (lambda (character)
    (when character
      (editorconfig-write-utf-8-codepoint (char-code character) stream))))

(defmethod lem/buffer/encodings:encoding-check
    ((encoding editorconfig-latin1-encoding))
  (declare (ignore encoding))
  (lambda (string eofp)
    (declare (ignore eofp))
    (loop :for character :across string
          :unless (<= (char-code character) #xff)
            :do (error "~S cannot be encoded as EditorConfig latin1"
                       character))))

(defmethod lem/buffer/encodings:encoding-write
    ((encoding editorconfig-latin1-encoding) stream)
  (declare (ignore encoding))
  (lambda (character)
    (when character
      (let ((code (char-code character)))
        (unless (<= code #xff)
          (error "~S cannot be encoded as EditorConfig latin1" character))
        (write-byte code stream)))))

(defun editorconfig-write-utf-16-unit (unit endianness stream)
  (ecase endianness
    (:big
     (write-byte (ldb (byte 8 8) unit) stream)
     (write-byte (ldb (byte 8 0) unit) stream))
    (:little
     (write-byte (ldb (byte 8 0) unit) stream)
     (write-byte (ldb (byte 8 8) unit) stream))))

(defun editorconfig-write-utf-16-codepoint (code endianness stream)
  (cond
    ((<= code #xffff)
     (when (<= #xd800 code #xdfff)
       (error "Surrogate character code ~X is not valid UTF-16 input" code))
     (editorconfig-write-utf-16-unit code endianness stream))
    ((<= code #x10ffff)
     (multiple-value-bind (high low)
         (truncate (- code #x10000) #x400)
       (editorconfig-write-utf-16-unit (+ #xd800 high) endianness stream)
       (editorconfig-write-utf-16-unit (+ #xdc00 low) endianness stream)))
    (t
     (error "Character code ~X is not valid UTF-16" code))))

(defmethod lem/buffer/encodings:encoding-write
    ((encoding editorconfig-utf-16-encoding) stream)
  (let ((endianness (editorconfig-utf-16-endianness encoding)))
    (lambda (character)
      (when character
        (editorconfig-write-utf-16-codepoint
         (char-code character) endianness stream)))))

;;; CLI -----------------------------------------------------------------------

(defun editorconfig-warn-once (key control &rest arguments)
  (unless (gethash key *editorconfig-warning-keys*)
    (setf (gethash key *editorconfig-warning-keys*) t)
    (ignore-errors
      (message "EditorConfig: ~a" (apply #'format nil control arguments)))))

(defun editorconfig-resolve-program (name cache-symbol)
  (let ((cached (symbol-value cache-symbol)))
    (cond
      ((eq cached :unknown)
       (setf (symbol-value cache-symbol) (executable-find name)))
      ((and cached (not (uiop:file-exists-p cached)))
       (setf (symbol-value cache-symbol) (executable-find name)))
      (t cached))))

(defun editorconfig-command (filename)
  (let ((editorconfig
          (editorconfig-resolve-program "editorconfig"
                                        '*editorconfig-program*))
        (timeout
          (editorconfig-resolve-program "timeout"
                                        '*editorconfig-timeout-program*)))
    (unless editorconfig
      (error "the official editorconfig executable is not on PATH"))
    (unless timeout
      (error "GNU timeout is not on PATH"))
    (list (namestring timeout)
          "--signal=TERM"
          "--kill-after=1s"
          (format nil "~ds" *editorconfig-timeout-seconds*)
          (namestring editorconfig)
          filename)))

(defun editorconfig-parse-cli-output (output)
  "Parse the official CLI's resolved KEY=VALUE output into an alist."
  (let ((properties nil))
    (with-input-from-string (stream (or output ""))
      (loop :for raw-line := (read-line stream nil nil)
            :while raw-line
            :for line := (string-trim '(#\Space #\Tab #\Return) raw-line)
            :unless (zerop (length line))
              :do (let ((equals (position #\= line)))
                    (unless (and equals (plusp equals))
                      (error "unexpected editorconfig output line ~S" raw-line))
                    (let ((key
                            (string-downcase
                             (string-trim '(#\Space #\Tab)
                                          (subseq line 0 equals))))
                          (value
                            (string-trim '(#\Space #\Tab)
                                         (subseq line (1+ equals)))))
                      ;; editorconfig-core-c emits KEY=unset for properties
                      ;; explicitly cleared by a nearer section.  Consumers
                      ;; should see those as absent resolved properties.
                      (setf properties
                            (if (string-equal value "unset")
                                (remove key properties
                                        :key #'car
                                        :test #'string=)
                                (acons key value
                                       (remove key properties
                                               :key #'car
                                               :test #'string=))))))))
    (nreverse properties)))

(defun editorconfig-query (buffer)
  "Return resolved properties, success-p, and an optional error string."
  (handler-case
      (let ((filename (expand-file-name (buffer-filename buffer))))
        (multiple-value-bind (output error-output status)
            (uiop:run-program
             (editorconfig-command filename)
             :directory (buffer-directory buffer)
             :output :string
             :error-output :string
             :ignore-error-status t)
          (if (and (integerp status) (zerop status))
              (values (editorconfig-parse-cli-output output) t nil)
              (values nil nil
                      (let ((detail
                              (string-trim
                               '(#\Space #\Tab #\Newline #\Return)
                               (or error-output ""))))
                        (if (plusp (length detail))
                            detail
                            (format nil "editorconfig exited with status ~a"
                                    status)))))))
    (error (condition)
      (values nil nil (princ-to-string condition)))))

;;; Buffer state --------------------------------------------------------------

(defun editorconfig-local-file-buffer-p (buffer)
  (and (typep buffer 'lem:buffer)
       (not (deleted-buffer-p buffer))
       (buffer-filename buffer)
       (ignore-errors
         (uiop:absolute-pathname-p
          (pathname (expand-file-name (buffer-filename buffer)))))))

(defun editorconfig-signature (buffer)
  (list (expand-file-name (buffer-filename buffer))
        (buffer-major-mode buffer)))

(defun editorconfig-buffer-properties (&optional (buffer (current-buffer)))
  "Return the official CLI properties last applied to BUFFER as an alist."
  (copy-tree
   (buffer-value buffer 'lem-yath-editorconfig-properties)))

(defun editorconfig-property (properties name)
  (cdr (assoc name properties :test #'string=)))

(defun editorconfig-property-value (properties name)
  (alexandria:when-let ((value (editorconfig-property properties name)))
    (string-downcase value)))

(defun editorconfig-capture-variable (buffer variable)
  (let ((descriptor (get variable 'lem/common/var::editor-variable)))
    (when descriptor
      (let* ((indicator
               (lem/common/var:editor-variable-local-indicator descriptor))
             (sentinel (gensym "UNBOUND"))
             (value (buffer-value buffer indicator sentinel)))
        (list :variable variable
              :indicator indicator
              :boundp (not (eq value sentinel))
              :value (unless (eq value sentinel) value))))))

(defun editorconfig-capture-buffer-value (buffer key)
  (let* ((sentinel (gensym "UNBOUND"))
         (value (buffer-value buffer key sentinel)))
    (list :key key
          :boundp (not (eq value sentinel))
          :value (unless (eq value sentinel) value))))

(defun editorconfig-restore-variable (buffer state)
  (when state
    (if (getf state :boundp)
        (setf (buffer-value buffer (getf state :indicator))
              (getf state :value))
        (buffer-unbound buffer (getf state :indicator)))))

(defun editorconfig-restore-buffer-value (buffer state)
  (if (getf state :boundp)
      (setf (buffer-value buffer (getf state :key))
            (getf state :value))
      (buffer-unbound buffer (getf state :key))))

(defun editorconfig-capture-baseline (buffer)
  (let ((encoding (buffer-encoding buffer)))
    (list :mode (buffer-major-mode buffer)
          :variables
          (remove nil
                  (mapcar (lambda (variable)
                            (editorconfig-capture-variable buffer variable))
                          *editorconfig-controlled-variables*))
          :fill-column
          (editorconfig-capture-buffer-value buffer 'lem-yath-fill-column)
          :encoding encoding
          :end-of-line
          (and encoding
               (lem/buffer/encodings:encoding-end-of-line encoding)))))

(defun editorconfig-restore-baseline-encoding (buffer baseline)
  (let ((encoding (getf baseline :encoding)))
    (setf (buffer-encoding buffer) encoding)
    (when encoding
      (setf (lem/buffer/encodings:encoding-end-of-line encoding)
            (getf baseline :end-of-line)))))

(defun editorconfig-restore-baseline (buffer baseline)
  (dolist (state (getf baseline :variables))
    (editorconfig-restore-variable buffer state))
  (editorconfig-restore-buffer-value buffer (getf baseline :fill-column))
  (editorconfig-restore-baseline-encoding buffer baseline))

(defun editorconfig-baseline-for-application (buffer)
  (let ((baseline (buffer-value buffer 'lem-yath-editorconfig-baseline)))
    (cond
      ((null baseline)
       (editorconfig-capture-baseline buffer))
      ((eq (getf baseline :mode) (buffer-major-mode buffer))
       (editorconfig-restore-baseline buffer baseline)
       baseline)
      (t
       ;; A normal major-mode activation has already cleared and rebuilt all
       ;; editor-local variables.  Restoring the old mode's bindings here would
       ;; overwrite the new mode's defaults.  Raw fill-column and encoding state
       ;; do survive a mode change and must be restored before recapturing.
       (editorconfig-restore-buffer-value buffer (getf baseline :fill-column))
       (editorconfig-restore-baseline-encoding buffer baseline)
       (editorconfig-capture-baseline buffer)))))

(defun editorconfig-positive-integer (value)
  (when (and value
             (plusp (length value))
             (every #'digit-char-p value))
    (let ((integer (parse-integer value)))
      (and (plusp integer) integer))))

(defun editorconfig-language-buffer-p (buffer)
  (ignore-errors
    (typep (ensure-mode-object (buffer-major-mode buffer))
           'lem/language-mode:language-mode)))

(defun editorconfig-set-local-variable (buffer variable value)
  (setf (variable-value variable :buffer buffer) value))

(defun editorconfig-apply-indentation (buffer properties)
  (let* ((style (editorconfig-property-value properties "indent_style"))
         (indent-value
           (editorconfig-property-value properties "indent_size"))
         (tab-value
           (editorconfig-property-value properties "tab_width"))
         (indent-size
           (or (editorconfig-positive-integer indent-value)
               (and (string= (or indent-value "") "tab")
                    (editorconfig-positive-integer tab-value))))
         (tab-width
           (or (editorconfig-positive-integer tab-value)
               (editorconfig-positive-integer indent-value))))
    (cond
      ((null style))
      ((string= style "space")
       (editorconfig-set-local-variable buffer 'indent-tabs-mode nil))
      ((string= style "tab")
       (editorconfig-set-local-variable buffer 'indent-tabs-mode t))
      (t
       (editorconfig-warn-once
        (list (buffer-filename buffer) "indent_style" style)
        "unsupported indent_style ~S in ~a" style (buffer-filename buffer))))
    (when tab-width
      (editorconfig-set-local-variable buffer 'tab-width tab-width))
    (when (and indent-size (editorconfig-language-buffer-p buffer))
      (editorconfig-set-local-variable
       buffer 'lem/language-mode:indent-size indent-size))))

(defun editorconfig-eol (buffer properties)
  (let ((value (editorconfig-property-value properties "end_of_line")))
    (cond
      ((null value) nil)
      ((string= value "lf") :lf)
      ((string= value "crlf") :crlf)
      ((string= value "cr") :cr)
      (t
       (editorconfig-warn-once
        (list (buffer-filename buffer) "end_of_line" value)
        "unsupported end_of_line ~S in ~a" value (buffer-filename buffer))
       nil))))

(defun editorconfig-make-charset-encoding (charset end-of-line)
  (cond
    ((string= charset "utf-8")
     (lem/buffer/encodings:encoding :utf-8 end-of-line))
    ((string= charset "utf-8-bom")
     (make-instance 'editorconfig-utf-8-bom-encoding
                    :end-of-line end-of-line))
    ((string= charset "latin1")
     (make-instance 'editorconfig-latin1-encoding
                    :end-of-line end-of-line))
    ((string= charset "utf-16be")
     (make-instance 'editorconfig-utf-16-encoding
                    :endianness :big
                    :end-of-line end-of-line))
    ((string= charset "utf-16le")
     (make-instance 'editorconfig-utf-16-encoding
                    :endianness :little
                    :end-of-line end-of-line))))

(defun editorconfig-apply-encoding (buffer properties)
  (let* ((charset (editorconfig-property-value properties "charset"))
         (configured-eol (editorconfig-eol buffer properties))
         (current-encoding (buffer-encoding buffer))
         (effective-eol
           (or configured-eol
               (and current-encoding
                    (lem/buffer/encodings:encoding-end-of-line
                     current-encoding))
               :lf)))
    (when charset
      (let ((encoding
              (handler-case
                  (editorconfig-make-charset-encoding charset effective-eol)
                (error (condition)
                  (editorconfig-warn-once
                   (list (buffer-filename buffer) "charset-error" charset)
                   "cannot use charset ~S for ~a: ~a"
                   charset (buffer-filename buffer) condition)
                  nil))))
        (if encoding
            (setf (buffer-encoding buffer) encoding
                  current-encoding encoding)
            (unless (member charset
                            '("utf-8" "utf-8-bom" "latin1"
                              "utf-16be" "utf-16le")
                            :test #'string=)
              (editorconfig-warn-once
               (list (buffer-filename buffer) "charset" charset)
               "unsupported charset ~S in ~a; keeping the current encoding"
               charset (buffer-filename buffer))))))
    (when configured-eol
      (unless current-encoding
        (setf current-encoding
              (lem/buffer/encodings:encoding :utf-8 configured-eol)
              (buffer-encoding buffer) current-encoding))
      (setf (lem/buffer/encodings:encoding-end-of-line current-encoding)
            configured-eol))))

(defun editorconfig-apply-max-line-length (buffer properties)
  (let ((value
          (editorconfig-property-value properties "max_line_length")))
    (cond
      ((or (null value) (string= value "off")))
      ((editorconfig-positive-integer value)
       (setf (buffer-value buffer 'lem-yath-fill-column)
             (editorconfig-positive-integer value)))
      (t
       (editorconfig-warn-once
        (list (buffer-filename buffer) "max_line_length" value)
        "unsupported max_line_length ~S in ~a"
        value (buffer-filename buffer))))))

(defun editorconfig-boolean-property (buffer properties name)
  (let ((value (editorconfig-property-value properties name)))
    (cond
      ((null value) nil)
      ((string= value "true") t)
      ((string= value "false") nil)
      (t
       (editorconfig-warn-once
        (list (buffer-filename buffer) name value)
        "unsupported ~a value ~S in ~a"
        name value (buffer-filename buffer))
       nil))))

(defun editorconfig-apply-properties (buffer properties signature)
  (let ((baseline (editorconfig-baseline-for-application buffer)))
    (editorconfig-apply-indentation buffer properties)
    (editorconfig-apply-encoding buffer properties)
    (editorconfig-apply-max-line-length buffer properties)
    (setf (buffer-value buffer 'lem-yath-editorconfig-baseline) baseline
          (buffer-value buffer 'lem-yath-editorconfig-properties) properties
          (buffer-value buffer 'lem-yath-editorconfig-trim)
          (editorconfig-boolean-property
           buffer properties "trim_trailing_whitespace")
          (buffer-value buffer 'lem-yath-editorconfig-mode)
          (buffer-major-mode buffer)
          (buffer-value buffer 'lem-yath-editorconfig-signature) signature)
    properties))

(defun editorconfig-refresh-buffer (&optional (buffer (current-buffer)))
  "Query and apply EditorConfig for BUFFER.

On CLI failure, retain every previously applied property and buffer setting."
  (when (editorconfig-local-file-buffer-p buffer)
    (let ((signature (editorconfig-signature buffer)))
      (multiple-value-bind (properties successp error-message)
          (editorconfig-query buffer)
        ;; This is retry metadata only; it does not describe applied state.
        (setf (buffer-value buffer 'lem-yath-editorconfig-attempt-signature)
              signature)
        (if successp
            (editorconfig-apply-properties buffer properties signature)
            (editorconfig-warn-once
             (list (first signature) error-message)
             "could not resolve ~a: ~a" (first signature) error-message))))))

;;; Save normalization --------------------------------------------------------

(defun editorconfig-trim-whole-buffer (buffer)
  (let ((*trimming-touched-lines* t))
    (with-point ((line (buffer-start-point buffer) :right-inserting))
      (loop
        (trim-line-trailing-whitespace line)
        (unless (line-offset line 1)
          (return))))))

(defun editorconfig-ensure-final-newline (buffer)
  (unless (point= (buffer-start-point buffer) (buffer-end-point buffer))
    (unless (start-line-p (buffer-end-point buffer))
      (let ((*trimming-touched-lines* t))
        (with-point ((end (buffer-end-point buffer) :left-inserting))
          (insert-character end #\Newline))))))

(defun editorconfig-normalize-buffer (buffer)
  (let* ((properties (editorconfig-buffer-properties buffer))
         (final-newline
           (editorconfig-property-value properties "insert_final_newline")))
    (when (buffer-value buffer 'lem-yath-editorconfig-trim)
      (editorconfig-trim-whole-buffer buffer))
    ;; An explicit EditorConfig value overrides a mode default.  False and
    ;; absent never remove a newline which is already present.
    (cond
      ((string= final-newline "true")
       (editorconfig-ensure-final-newline buffer))
      ((string= final-newline "false"))
      ((null final-newline)
       (when (variable-value 'lem-yath-require-final-newline :buffer buffer)
         (editorconfig-ensure-final-newline buffer)))
      (t
       (editorconfig-boolean-property
        buffer properties "insert_final_newline")))))

(defun editorconfig-before-save (&optional (buffer (current-buffer)))
  (when (editorconfig-local-file-buffer-p buffer)
    ;; Text normalization is owned by formatting-before-save-hook so formatter
    ;; output and EditorConfig cleanup share one retained transaction.  This
    ;; hook resolves settings first and deliberately changes no live text.
    (editorconfig-refresh-buffer buffer)))

;;; Hooks and reload ----------------------------------------------------------

(defun editorconfig-refresh-buffer-if-stale (buffer)
  (when (editorconfig-local-file-buffer-p buffer)
    (let ((signature (editorconfig-signature buffer)))
      (unless (equal signature
                     (buffer-value
                      buffer 'lem-yath-editorconfig-attempt-signature))
        (editorconfig-refresh-buffer buffer)))))

(defun editorconfig-post-command ()
  (editorconfig-refresh-buffer-if-stale (current-buffer)))

(defun initialize-editorconfig ()
  ;; Remove before adding so changed weights take effect across config reloads.
  (remove-hook *find-file-hook* 'editorconfig-refresh-buffer-if-stale)
  (remove-hook *switch-to-buffer-hook* 'editorconfig-refresh-buffer-if-stale)
  (remove-hook (variable-value 'before-save-hook :global t)
               'editorconfig-before-save)
  (remove-hook *post-command-hook* 'editorconfig-post-command)

  ;; Core mode detection runs on find-file at weight 5000 and before-save at
  ;; weight 0, so these callbacks always see the final filename and major mode.
  (add-hook *find-file-hook* 'editorconfig-refresh-buffer-if-stale)
  (add-hook *switch-to-buffer-hook* 'editorconfig-refresh-buffer-if-stale)
  (add-hook (variable-value 'before-save-hook :global t)
            'editorconfig-before-save
            *editorconfig-before-save-hook-weight*)
  (add-hook *post-command-hook* 'editorconfig-post-command -300)

  (dolist (buffer (buffer-list))
    (editorconfig-refresh-buffer-if-stale buffer)))

(initialize-editor-feature 'initialize-editorconfig)
