(in-package :lem-core)

(defvar *file-associations-modes* '())
(defvar *file-type-relationals* '())
(defvar *program-name-relationals* '())

(defun (setf file-mode-associations) (specs mode)
  (pushnew mode *file-associations-modes*)
  (setf (get mode 'file-mode-associations) specs))

(defun file-mode-associations (mode)
  (get mode 'file-mode-associations))

(defmacro define-file-associations (mode specs)
  "Associate a mode to a list of file names so that the files are always open in this mode.

  Specs are in the form (:spec \"filename\"),

  Available specs:

  :file-namestring

  Example:

  (define-file-associations makefile-mode
    ((:file-namestring \"Makefile\")
     (:file-namestring \"makefile\")))

  See also DEFINE-FILE-TYPE."
  `(setf (file-mode-associations ',mode) ',specs))

(defun get-file-mode (pathname)
  (dolist (mode *file-associations-modes*)
    (loop :for spec :in (file-mode-associations mode)
          :do (cond ((and (consp spec)
                          (eq :file-namestring (first spec))
                          (equal (second spec)
                                 (file-namestring pathname)))
                     (return-from get-file-mode mode)))))
  (loop :with filename := (file-namestring pathname)
        :for (file-type . mode) :in *file-type-relationals*
        :do (when (alexandria:ends-with-subseq (format nil ".~A" file-type)
                                               filename)
              (return mode))))

(defun associate-file-type (type-list mode)
  (dolist (type type-list)
    (pushnew (cons type mode)
             *file-type-relationals*
             :test #'equal)))

(defmacro define-file-type ((&rest type-list) mode)
  `(associate-file-type ',type-list ',mode))

(defun get-program-mode (program-name)
  (alexandria:assoc-value *program-name-relationals*
                          program-name
                          :test #'string=))

(defun associate-program-name-with-mode (program-names mode)
  (dolist (name program-names)
    (pushnew (cons name mode)
             *program-name-relationals*
             :test #'equal)))

(defmacro define-program-name-with-mode ((&rest program-names) mode)
  `(associate-program-name-with-mode ',program-names ',mode))

;;;
(defun parse-shebang (line)
  (let* ((args (split-sequence:split-sequence #\space line :remove-empty-subseqs t))
         (program (alexandria:lastcar
                   (split-sequence:split-sequence #\/ (alexandria:lastcar args)))))
    (cond ((string= program "env")
           (second args))
          (t
           program))))

(defun program-name-to-mode (program)
  (get-program-mode program))

(defun guess-file-mode-from-shebang (buffer)
  (with-point ((point (buffer-point buffer)))
    (buffer-start point)
    (let ((header-line (line-string point)))
      (when (alexandria:starts-with-subseq "#!" header-line)
        (program-name-to-mode (parse-shebang header-line))))))

(defun parse-property-line (string)
  (ppcre:do-register-groups (key value) ("(\\w+)\\s*:\\s*(\\w+)" string)
    (when (string-equal key "mode")
      (alexandria:when-let ((mode (find-mode value)))
        (return-from parse-property-line mode)))))

(defun guess-file-mode-from-property-line (buffer)
  (with-point ((point (buffer-point buffer)))
    (buffer-start point)
    (loop
      :until (blank-line-p point)
      :do (let ((line (line-string point)))
            (ppcre:register-groups-bind (content)
                ("-\\*-(.*)-\\*-" line)
              (when content
                (return (parse-property-line content)))))
      :while (line-offset point 1))))

(defun detect-file-mode (buffer)
  (or (get-file-mode (buffer-filename buffer))
      (guess-file-mode-from-shebang buffer)
      (guess-file-mode-from-property-line buffer)))

(define-editor-variable large-file-threshold nil
  "Size in bytes above which a file opens in fundamental mode with syntax
highlighting and expensive mode hooks disabled, after a confirmation prompt on
the find-file path. NIL disables the guard and preserves upstream behavior.")

(defvar *inhibit-file-mode-detection* nil
  "When true, PROCESS-FILE leaves the buffer in fundamental mode instead of
detecting a major mode, and marks the buffer so that later saves keep skipping
detection. Bound by the large-file guard while a large file is being opened.")

(defun large-file-size (pathname)
  "Return PATHNAME's size in bytes when it names an existing regular file larger
than LARGE-FILE-THRESHOLD, otherwise NIL. Probes the file's length without
reading its contents."
  (let ((threshold (variable-value 'large-file-threshold :global)))
    (when (and threshold
               (not (uiop:directory-pathname-p pathname))
               (probe-file pathname))
      (let ((size (ignore-errors
                    (with-open-file (in pathname :element-type '(unsigned-byte 8))
                      (file-length in)))))
        (when (and size (> size threshold))
          size)))))

(defun process-file (buffer)
  ;; The large-file guard binds *INHIBIT-FILE-MODE-DETECTION* while reading; stamp
  ;; the buffer so mode detection stays off on later saves too.
  (when *inhibit-file-mode-detection*
    (setf (buffer-value buffer 'inhibit-mode-detection) t))
  (unless (buffer-value buffer 'inhibit-mode-detection)
    (alexandria:when-let (mode (detect-file-mode buffer))
      (change-buffer-mode buffer mode)))
  (values))

;;;
(define-editor-variable detect-encoding-scheme :jp
  "Inquisitor language scheme used to auto-detect a file's character encoding.

Every scheme tries UTF-8 first; the scheme only decides which legacy encodings
are considered next. The default :JP preserves upstream behavior. Available
schemes: :jp :tw :cn :kr :ru :ar :tr :gr :hw :pl :bl.

When decoding under the detected encoding fails, FIND-FILE-BUFFER falls back to
*ENCODING-FALLBACK-EXTERNAL-FORMAT* (latin-1) rather than refusing the file, so
this variable only affects which encoding is attempted first.")

(defun detect-external-format-from-file (pathname)
  (values (inq:dependent-name
           (inq:detect-encoding (pathname pathname)
                                (variable-value 'detect-encoding-scheme :global)))
          (or (inq:detect-end-of-line (pathname pathname)) :lf)))

(setf *external-format-function* 'detect-external-format-from-file)

(setf *mixed-eol-notification-function*
      (lambda (filename)
        (message "~A has mixed line endings; normalized to the dominant style on save."
                 filename)))

(setf *encoding-fallback-notification-function*
      (lambda (filename external-format)
        (message "~A: could not decode with the detected encoding; ~
                  opened as ~(~A~). Use M-x revert-buffer-with-encoding to choose another."
                 filename external-format)))
