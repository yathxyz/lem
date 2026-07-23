;;;; Configured Org Babel execution for the native Org subset.

(in-package :lem-yath)

(declaim (ftype function run-project-program project-path-in-directory-p))

(defparameter *org-babel-timeout* 600
  "Maximum seconds allowed for one configured Org source block.")

(defparameter *org-babel-output-limit* (* 16 1024 1024)
  "Maximum stdout or stderr characters retained from one source block.")

(defparameter *org-babel-input-limit* (* 16 1024 1024)
  "Maximum characters accepted from one source block.")

(defparameter *org-babel-dsq-input-limit* (* 64 1024 1024)
  "Maximum bytes accepted from one DSQ file or named Org input.")

(defstruct org-babel-block
  language
  headers
  begin
  body-start
  end
  body
  indent)

(defstruct org-babel-result
  text
  (kind :output))

(defun org-babel-source-line-info (line)
  "Return language, header text, and indentation for a begin_src LINE."
  (cl-ppcre:register-groups-bind (indent language headers)
      ("(?i)^(\\s*)#\\+begin_src(?:\\s+([^\\s]+))?(.*)$" line)
    (when language
      (values (string-downcase language) (or headers "") indent))))

(defun org-babel-end-source-line-p (line)
  (not (null (cl-ppcre:scan "(?i)^\\s*#\\+end_src\\s*$" line))))

(defun org-babel-block-at-point (&optional (origin (current-point)) errorp)
  "Return the complete source block containing ORIGIN, or NIL.

Nested begin-looking lines remain literal source text, matching the native Org
parser.  When ERRORP is true, report a source block without a matching end."
  (with-point ((line (buffer-start-point (point-buffer origin))))
    (line-start line)
    (loop :with open := nil
          :with contains-origin-p := nil
          :do
             (if open
                 (progn
                   (when (same-line-p line origin)
                     (setf contains-origin-p t))
                   (when (org-babel-end-source-line-p (line-string line))
                     (when contains-origin-p
                       (let* ((begin (getf open :begin))
                              (body-start (with-point ((point begin))
                                            (line-offset point 1)
                                            (copy-point point :temporary)))
                              (end (copy-point line :temporary)))
                         (return
                           (make-org-babel-block
                            :language (getf open :language)
                            :headers (getf open :headers)
                            :begin begin
                            :body-start body-start
                            :end end
                            :body (points-to-string body-start end)
                            :indent (getf open :indent)))))
                     (setf open nil
                           contains-origin-p nil)))
                 (multiple-value-bind (language headers indent)
                     (org-babel-source-line-info (line-string line))
                   (when language
                     (setf open
                           (list :language language
                                 :headers headers
                                 :indent indent
                                 :begin (copy-point line :temporary))
                           contains-origin-p (same-line-p line origin)))))
          :unless (line-offset line 1)
            :do
               (when (and errorp open contains-origin-p)
                 (editor-error "Source block has no matching #+end_src"))
               (return nil))))

(defun org-babel-decode-header-value (value)
  "Trim VALUE and decode the quoted escapes used by Org header arguments."
  (let* ((value (string-trim '(#\Space #\Tab) (or value "")))
         (length (length value))
         (quoted-p (and (> length 1)
                        (member (char value 0) '(#\" #\'))
                        (char= (char value 0) (char value (1- length)))))
         (value (if quoted-p (subseq value 1 (1- length)) value)))
    (with-output-to-string (output)
      (loop :for index :from 0 :below (length value)
            :for character := (char value index)
            :do
               (if (and (char= character #\\)
                        (< index (1- (length value))))
                   (let ((next (char value (incf index))))
                     (write-char
                      (case next
                        (#\n #\Newline)
                        (#\r #\Return)
                        (#\t #\Tab)
                        (otherwise next))
                      output))
                   (write-char character output))))))

(defun org-babel-parse-headers (text)
  "Parse Babel header argument TEXT into a lower-case alist.

Values extend to the next whitespace-prefixed :key, so quoted commands and
multi-word `:results' values remain intact without invoking a Lisp reader."
  (let ((matches nil))
    (cl-ppcre:do-scans (start end register-starts register-ends
                       "(?i)(?:^|[ \\t]):([a-z][a-z0-9_-]*)(?=[ \\t]|$)"
                       (or text ""))
      (push (list (string-downcase
                   (subseq text (aref register-starts 0)
                           (aref register-ends 0)))
                  end start)
            matches))
    (setf matches (nreverse matches))
    (loop :for match :in matches
          :for next :in (append (rest matches) (list nil))
          :for name := (first match)
          :for value-start := (second match)
          :for value-end := (if next (third next) (length text))
          :collect (cons name
                         (org-babel-decode-header-value
                          (subseq text value-start value-end))))))

(defun org-babel-global-headers (block language)
  "Return file-wide header arguments applicable to BLOCK and LANGUAGE.

Both #+PROPERTY forms and the configuration's preamble property-drawer form
are recognized.  Drawer properties below the first heading are deliberately
not treated as global; heading inheritance is outside this bounded parser."
  (with-point ((line (buffer-start-point (point-buffer
                                           (org-babel-block-begin block)))))
    (line-start line)
    (loop :with headers := nil
          :with before-first-heading-p := t
          :until (same-line-p line (org-babel-block-begin block))
          :for text := (line-string line)
          :do
             (when (org-heading-level-from-line text)
               (setf before-first-heading-p nil))
             (multiple-value-bind (key value)
                 (cl-ppcre:register-groups-bind (key value)
                     ("(?i)^\\s*#\\+property:\\s+(header-args(?:[^\\s]*))\\s+(.*)$"
                      text)
                   (values key value))
               (when key
                 (let* ((key (string-downcase key))
                        (separator (position #\: key))
                        (property-language
                          (and separator (subseq key (1+ separator)))))
                   (when (or (null property-language)
                             (string= property-language language))
                     (setf headers
                           (append headers
                                   (org-babel-parse-headers value)))))))
             (when before-first-heading-p
               (multiple-value-bind (property-language value)
                   (cl-ppcre:register-groups-bind (property-language value)
                       ("(?i)^\\s*:header-args(?::([^:]+))?:\\s*(.*)$" text)
                     (values property-language value))
                 (when (and value
                            (or (null property-language)
                                (string= (string-downcase property-language)
                                         language)))
                   (setf headers
                         (append headers
                                 (org-babel-parse-headers value))))))
          :unless (line-offset line 1)
            :do (return headers)
          :finally (return headers))))

(defun org-babel-effective-headers (block)
  "Return BLOCK's effective headers, with block-local values winning."
  (let ((headers (append
                  (org-babel-global-headers
                   block (org-babel-block-language block))
                  (org-babel-parse-headers
                   (org-babel-block-headers block))))
        (result nil))
    (dolist (entry headers (nreverse result))
      (setf result (delete (car entry) result :key #'car :test #'string=))
      (push entry result))))

(defun org-babel-header (name headers)
  (cdr (assoc name headers :test #'string=)))

(defun org-babel-normalized-language (language)
  (cond
    ((member language '("bash" "sh" "shell") :test #'string=) "bash")
    ((member language '("python" "python3") :test #'string=) "python")
    ((member language '("c") :test #'string=) "c")
    ((member language '("c++" "cpp") :test #'string=) "c++")
    ((member language '("nix" "my/nix") :test #'string=) "nix")
    ((member language '("sqlite" "sqlite3") :test #'string=) "sqlite")
    ((string= language "sql") "sql")
    ((string= language "dsq") "dsq")
    ((member language '("emacs-lisp" "elisp") :test #'string=)
     "emacs-lisp")
    (t language)))

(defun org-babel-trusted-buffer-p (&optional (buffer (current-buffer)))
  "Whether BUFFER's existing file is inside the startup-cached notes root."
  (let ((filename (buffer-filename buffer)))
    (and filename
         (probe-file filename)
         (project-path-in-directory-p filename (workdir)))))

(defun org-babel-confirm-execution-p (language)
  "Apply the active Emacs configuration's Babel confirmation policy."
  (or (and (org-babel-trusted-buffer-p)
           (member language '("emacs-lisp" "sqlite") :test #'string=))
      (prompt-for-y-or-n-p
       (format nil "Execute ~a source block?" language))))

(defun org-babel-directory (headers)
  "Resolve `:dir' like the configured local Org workflow."
  (let ((value (org-babel-header "dir" headers)))
    (if (or (null value)
            (member (string-downcase value) '("nil" "'nil")
                    :test #'string=))
        (or (ignore-errors (buffer-directory (current-buffer)))
            (uiop:getcwd))
        (let* ((base (or (ignore-errors (buffer-directory (current-buffer)))
                         (uiop:getcwd)))
               (directory (expand-file-name value base))
               (existing (uiop:directory-exists-p directory)))
          (unless existing
            (editor-error "Babel :dir does not name an existing directory"))
          (uiop:ensure-directory-pathname existing)))))

(defun org-babel-program (name)
  (or (executable-find name)
      (editor-error "Babel backend executable is unavailable: ~a" name)))

(defun org-babel-run (arguments directory &key input environment)
  "Run a configured Babel command with shared process bounds."
  (let ((*project-process-timeout* *org-babel-timeout*))
    (run-project-program arguments
                         :directory directory
                         :input input
                         :environment environment
                         :output-limit *org-babel-output-limit*)))

(defun org-babel-clean-diagnostic (stdout stderr status)
  (let* ((text (if (plusp (length stderr)) stderr stdout))
         (text (cl-ppcre:regex-replace-all "[\\r\\n\\t ]+" text " "))
         (text (string-trim '(#\Space) text))
         (text (if (> (length text) 1000)
                   (concatenate 'string (subseq text 0 999) "…")
                   text)))
    (if (plusp (length text))
        (format nil "Babel exited with status ~a — ~a" status text)
        (format nil "Babel exited with status ~a" status))))

(defun org-babel-success-output (arguments directory &key input environment)
  (multiple-value-bind (stdout stderr status)
      (org-babel-run arguments directory :input input :environment environment)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (org-babel-clean-diagnostic stdout stderr status)))
    stdout))

(defun org-babel-shell-result (block headers directory)
  (let* ((shebang (org-babel-header "shebang" headers))
         (body (org-babel-block-body block)))
    (if (and shebang (plusp (length shebang)))
        (uiop:with-temporary-file
            (:pathname path :stream stream :direction :output
             :element-type 'character)
          (write-string shebang stream)
          (unless (and (plusp (length shebang))
                       (char= (char shebang (1- (length shebang))) #\Newline))
            (terpri stream))
          (write-string body stream)
          (finish-output stream)
          (close stream)
          (sb-posix:chmod (uiop:native-namestring path) #o700)
          (make-org-babel-result
           :text (org-babel-success-output
                  (list (uiop:native-namestring path)) directory)))
        (make-org-babel-result
         :text (org-babel-success-output
                (list (uiop:native-namestring (org-babel-program "bash")))
                directory :input body)))))

(defun org-babel-python-result (block headers directory)
  (let ((custom (org-babel-header "python" headers))
        (body (org-babel-block-body block)))
    (make-org-babel-result
     :text
     (if (and custom (plusp (length custom)))
         (org-babel-success-output
          (list (uiop:native-namestring (org-babel-program "bash"))
                "-c" custom)
          directory :input body)
         (org-babel-success-output
          (list (uiop:native-namestring (org-babel-program "python3")) "-")
          directory :input body)))))

(defun org-babel-c-result (block directory c++-p)
  (uiop:with-temporary-file
      (:pathname source :stream source-stream :direction :output
       :element-type 'character)
    (write-string (org-babel-block-body block) source-stream)
    (finish-output source-stream)
    (close source-stream)
    (uiop:with-temporary-file
        (:pathname executable :stream executable-stream :direction :output
         :element-type '(unsigned-byte 8))
      (close executable-stream)
      (let ((compiler (org-babel-program (if c++-p "clang++" "clang"))))
        (org-babel-success-output
         (list (uiop:native-namestring compiler)
               "-x" (if c++-p "c++" "c")
               (uiop:native-namestring source)
               "-o" (uiop:native-namestring executable))
         directory)
        (make-org-babel-result
         :text (org-babel-success-output
                (list (uiop:native-namestring executable)) directory))))))

(defun org-babel-nix-result (block directory)
  (uiop:with-temporary-file
      (:pathname source :stream stream :direction :output
       :element-type 'character)
    (write-string (org-babel-block-body block) stream)
    (finish-output stream)
    (close stream)
    (make-org-babel-result
     :text (org-babel-success-output
            (list (uiop:native-namestring (org-babel-program "nix-build"))
                  (uiop:native-namestring source))
            directory))))

(defun org-babel-tabular-output (output)
  "Turn unaligned tab-separated database OUTPUT into an Org table result."
  (let* ((output (string-right-trim '(#\Newline #\Return) output))
         (lines (unless (zerop (length output))
                  (uiop:split-string output :separator '(#\Newline))))
         (rows (mapcar (lambda (line)
                         (uiop:split-string
                          (string-right-trim '(#\Return) line)
                          :separator '(#\Tab)))
                       lines)))
    (if (< (length rows) 2)
        (make-org-babel-result :text output)
        (labels ((cell (value)
                   (cl-ppcre:regex-replace-all "\\|" value "\\\\vert{}"))
                 (row (values)
                   (format nil "| ~{~a~^ | ~} |" (mapcar #'cell values))))
          (make-org-babel-result
           :kind :table
           :text (format nil "~a~%|~{~a~^+~}|~{~%~a~}"
                         (row (first rows))
                         (make-list (length (first rows))
                                    :initial-element "---")
                         (mapcar #'row (rest rows))))))))

(defun org-babel-data-path (value directory)
  (if (or (null value) (string= value "") (string= value ":memory:"))
      ":memory:"
      (uiop:native-namestring (expand-file-name value directory))))

(defun org-babel-sqlite-result (block headers directory)
  (let ((output
          (org-babel-success-output
           (list (uiop:native-namestring (org-babel-program "sqlite3"))
                 "-batch" "-header" "-separator" (string #\Tab)
                 (org-babel-data-path
                  (or (org-babel-header "db" headers)
                      (org-babel-header "database" headers))
                  directory))
           directory :input (org-babel-block-body block))))
    (org-babel-tabular-output output)))

(defun org-babel-environment-with (name value)
  (let ((prefix (concatenate 'string name "=")))
    (cons (concatenate 'string prefix value)
          (remove-if (lambda (entry)
                       (alexandria:starts-with-subseq prefix entry))
                     (lint-capture-environment)))))

(defun org-babel-sql-result (block headers directory)
  (let ((engine (string-downcase (or (org-babel-header "engine" headers)
                                     "postgres"))))
    (unless (member engine '("postgres" "postgresql") :test #'string=)
      (editor-error "Only the configured PostgreSQL SQL backend is supported"))
    (let* ((password (org-babel-header "dbpassword" headers))
           (arguments
             (append
              (list (uiop:native-namestring (org-babel-program "psql"))
                    "-X" "--set" "ON_ERROR_STOP=1" "--quiet"
                    "--no-align" "--field-separator" (string #\Tab)
                    "--pset" "footer=off")
              (alexandria:when-let ((host (org-babel-header "dbhost" headers)))
                (list "--host" host))
              (alexandria:when-let ((port (org-babel-header "dbport" headers)))
                (list "--port" port))
              (alexandria:when-let ((user (org-babel-header "dbuser" headers)))
                (list "--username" user))
              (alexandria:when-let
                  ((database (or (org-babel-header "database" headers)
                                 (org-babel-header "db" headers))))
                (list "--dbname" database))))
           (output
             (org-babel-success-output
              arguments directory
              :input (org-babel-block-body block)
              :environment (and password
                                (org-babel-environment-with
                                 "PGPASSWORD" password)))))
      (org-babel-tabular-output output))))

;;; --- ob-dsq ---------------------------------------------------------------

(defstruct org-babel-dsq-source
  pathname
  data
  format)

(defun org-babel-dsq-yes-p (value &optional default)
  (if value
      (string= (string-downcase (string-trim '(#\Space #\Tab) value)) "yes")
      default))

(defun org-babel-dsq-probe-file (pathname)
  "Return PATHNAME's probe result without exposing native wildcard errors."
  (ignore-errors (probe-file pathname)))

(defun org-babel-dsq-input-words (value directory)
  "Split the pinned ob-dsq :input VALUE without invoking a shell.

A whole existing pathname wins before tokenization, which retains the common
quoted-path-with-spaces case after the generic Babel header decoder removes its
outer quotes."
  (let* ((value (string-trim '(#\Space #\Tab) (or value "")))
         (whole (and (plusp (length value))
                     (expand-file-name value directory))))
    (when (zerop (length value))
      (editor-error "DSQ requires at least one :input"))
    (when (and whole (org-babel-dsq-probe-file whole))
      (return-from org-babel-dsq-input-words (list value)))
    (let ((words nil)
          (word (make-array 32 :element-type 'character
                               :adjustable t :fill-pointer 0))
          (quote nil)
          (escaped-p nil))
      (labels ((finish-word ()
                 (when (plusp (length word))
                   (push (copy-seq word) words)
                   (setf (fill-pointer word) 0))))
        (loop :for character :across value
              :do
                 (cond
                   (escaped-p
                    (vector-push-extend character word)
                    (setf escaped-p nil))
                   ((char= character #\\)
                    (setf escaped-p t))
                   (quote
                    (if (char= character quote)
                        (setf quote nil)
                        (vector-push-extend character word)))
                   ((member character '(#\" #\'))
                    (setf quote character))
                   ((member character '(#\Space #\Tab))
                    (finish-word))
                   (t
                    (vector-push-extend character word))))
        (when escaped-p
          (vector-push-extend #\\ word))
        (when quote
          (editor-error "DSQ :input contains an unterminated quote"))
        (finish-word))
      (or (nreverse words)
          (editor-error "DSQ requires at least one :input")))))

(defun org-babel-dsq-file-size (pathname)
  (handler-case
      (with-open-file (stream pathname :direction :input
                              :element-type '(unsigned-byte 8))
        (file-length stream))
    (error () nil)))

(defun org-babel-dsq-regular-input-file-p (pathname)
  (and (org-babel-dsq-probe-file pathname)
       (not (uiop:directory-exists-p pathname))
       (let ((size (org-babel-dsq-file-size pathname)))
         (and size (<= size *org-babel-dsq-input-limit*)))))

(defun org-babel-dsq-check-file (pathname)
  (unless (org-babel-dsq-probe-file pathname)
    (editor-error "DSQ input does not exist: ~a" pathname))
  (when (uiop:directory-exists-p pathname)
    (editor-error "DSQ input is a directory: ~a" pathname))
  (let ((size (org-babel-dsq-file-size pathname)))
    (unless size
      (editor-error "DSQ input is not a readable regular file: ~a" pathname))
    (when (> size *org-babel-dsq-input-limit*)
      (editor-error "DSQ input exceeds the ~d-byte limit: ~a"
                    *org-babel-dsq-input-limit* pathname)))
  pathname)

(defun org-babel-dsq-same-file-p (left right)
  (and left right
       (handler-case
           (equal (truename left) (truename right))
         (error () nil))))

(defun org-babel-dsq-live-file-buffer (pathname)
  (find-if (lambda (buffer)
             (and (buffer-filename buffer)
                  (org-babel-dsq-same-file-p
                   (buffer-filename buffer) pathname)))
           (buffer-list)))

(defun org-babel-dsq-read-org-text (pathname)
  "Read PATHNAME, preferring the corresponding live Lem buffer."
  (let ((buffer (org-babel-dsq-live-file-buffer pathname)))
    (if buffer
        (progn
          (when (sops-buffer-active-p buffer)
            (editor-error "DSQ will not read a plaintext SOPS buffer"))
          (let ((text (buffer-text buffer)))
            (when (> (length text) *org-babel-dsq-input-limit*)
              (editor-error
               "DSQ Org reference exceeds the configured input limit"))
            text))
        (progn
          (org-babel-dsq-check-file pathname)
          (handler-case (uiop:read-file-string pathname)
            (error (condition)
              (editor-error "Cannot read DSQ Org reference ~a — ~a"
                            pathname condition)))))))

(defun org-babel-dsq-lines (text)
  (mapcar (lambda (line) (string-right-trim '(#\Return) line))
          (uiop:split-string text :separator '(#\Newline))))

(defun org-babel-dsq-blank-line-p (line)
  (every (lambda (character) (member character '(#\Space #\Tab))) line))

(defun org-babel-dsq-table-line-p (line)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (and (plusp (length trimmed)) (char= (char trimmed 0) #\|))))

(defun org-babel-dsq-table-hline-p (line)
  (let ((trimmed (string-trim '(#\Space #\Tab #\|) line)))
    (and (plusp (length trimmed))
         (every (lambda (character)
                  (member character '(#\- #\+ #\: #\Space #\Tab)))
                trimmed))))

(defun org-babel-dsq-table-cells (line)
  "Return the cells in one ordinary Org table LINE."
  (let* ((line (string-trim '(#\Space #\Tab) line))
         (start (if (and (plusp (length line))
                         (char= (char line 0) #\|))
                    1 0))
         (end (if (and (> (length line) start)
                       (char= (char line (1- (length line))) #\|))
                  (1- (length line)) (length line)))
         (cells nil)
         (cell (make-array 32 :element-type 'character
                              :adjustable t :fill-pointer 0))
         (escaped-p nil))
    (labels ((finish-cell ()
               (push (string-trim '(#\Space #\Tab) (copy-seq cell)) cells)
               (setf (fill-pointer cell) 0)))
      (loop :for index :from start :below end
            :for character := (char line index)
            :do
               (cond
                 (escaped-p
                  (vector-push-extend character cell)
                  (setf escaped-p nil))
                 ((char= character #\\)
                  (setf escaped-p t))
                 ((char= character #\|)
                  (finish-cell))
                 (t
                  (vector-push-extend character cell))))
      (when escaped-p (vector-push-extend #\\ cell))
      (finish-cell))
    (nreverse cells)))

(defun org-babel-dsq-csv-cell (value)
  (format nil "\"~a\""
          (cl-ppcre:regex-replace-all "\"" (or value "") "\"\"")))

(defun org-babel-dsq-table-csv (lines)
  (with-output-to-string (output)
    (dolist (line lines)
      (when (and (org-babel-dsq-table-line-p line)
                 (not (org-babel-dsq-table-hline-p line)))
        (format output "~{~a~^,~}~%"
                (mapcar #'org-babel-dsq-csv-cell
                        (org-babel-dsq-table-cells line)))))))

(defun org-babel-dsq-detect-format (data)
  (let ((trimmed (string-left-trim '(#\Space #\Tab #\Newline #\Return)
                                   (or data ""))))
    (cond
      ((and (plusp (length trimmed))
            (member (char trimmed 0) '(#\{ #\[)))
       "json")
      ((find #\, trimmed) "csv")
      (t nil))))

(defun org-babel-dsq-valid-format (format)
  (and format
       (plusp (length format))
       (every (lambda (character) (or (alphanumericp character)
                                      (char= character #\-)))
              format)))

(defun org-babel-dsq-result-data (lines start)
  "Return data and a format from a named source block result at START."
  (let ((index start)
        (length (length lines)))
    (loop :while (and (< index length)
                      (org-babel-dsq-blank-line-p (nth index lines)))
          :do (incf index))
    (unless (and (< index length)
                 (cl-ppcre:scan "(?i)^\\s*#\\+results(?:[^:]*):" (nth index lines)))
      (editor-error "Named DSQ source input has no adjacent results"))
    (incf index)
    (loop :while (and (< index length)
                      (org-babel-dsq-blank-line-p (nth index lines)))
          :do (incf index))
    (cond
      ((and (< index length) (org-babel-dsq-table-line-p (nth index lines)))
       (let ((table nil))
         (loop :while (and (< index length)
                           (org-babel-dsq-table-line-p (nth index lines)))
               :do (push (nth index lines) table) (incf index))
         (values (org-babel-dsq-table-csv (nreverse table)) "csv")))
      ((and (< index length)
            (cl-ppcre:scan "^\\s*:(?:\\s|$)" (nth index lines)))
       (let ((data
               (with-output-to-string (output)
                 (loop :while (and (< index length)
                                   (cl-ppcre:scan "^\\s*:(?:\\s|$)"
                                                 (nth index lines)))
                       :for line := (nth index lines)
                       :for colon := (position #\: line)
                       :for content-start := (and colon (1+ colon))
                       :do
                          (when (and content-start (< content-start (length line))
                                     (char= (char line content-start) #\Space))
                            (incf content-start))
                          (write-line (subseq line content-start) output)
                          (incf index)))))
         (values data (org-babel-dsq-detect-format data))))
      (t
       (editor-error "Named DSQ source input has no tabular or verbatim result")))))

(defun org-babel-dsq-reference-data (text reference)
  "Resolve REFERENCE from Org TEXT into data and its detected format."
  (let* ((lines (org-babel-dsq-lines text))
         (name-pattern
           (format nil "(?i)^\\s*#\\+name:\\s*~a(?:\\s|$)"
                   (cl-ppcre:quote-meta-chars reference)))
         (name-index
           (loop :for line :in lines :for index :from 0
                 :when (cl-ppcre:scan name-pattern line)
                   :return index)))
    (unless name-index
      (editor-error "Unknown DSQ Org reference: ~a" reference))
    (let ((index (1+ name-index))
          (length (length lines)))
      (loop :while (and (< index length)
                        (org-babel-dsq-blank-line-p (nth index lines)))
            :do (incf index))
      (unless (< index length)
        (editor-error "DSQ Org reference has no data: ~a" reference))
      (cond
        ((org-babel-dsq-table-line-p (nth index lines))
         (let ((table nil))
           (loop :while (and (< index length)
                             (org-babel-dsq-table-line-p (nth index lines)))
                 :do (push (nth index lines) table) (incf index))
           (values (org-babel-dsq-table-csv (nreverse table)) "csv")))
        ((cl-ppcre:scan "(?i)^\\s*#\\+begin_src(?:\\s|$)" (nth index lines))
         (loop :do (incf index)
               :until (or (>= index length)
                          (cl-ppcre:scan "(?i)^\\s*#\\+end_src\\s*$"
                                        (nth index lines))))
         (when (>= index length)
           (editor-error "Named DSQ source input has no matching #+end_src"))
         (org-babel-dsq-result-data lines (1+ index)))
        ((cl-ppcre:scan "(?i)^\\s*#\\+begin_(?:quote|example)\\s*$"
                       (nth index lines))
         (let ((data
                 (with-output-to-string (output)
                   (loop :do (incf index)
                         :until (or (>= index length)
                                    (cl-ppcre:scan
                                     "(?i)^\\s*#\\+end_(?:quote|example)\\s*$"
                                     (nth index lines)))
                         :do (write-line (nth index lines) output)))))
           (when (>= index length)
             (editor-error "Named DSQ literal input has no matching end marker"))
           (values data (org-babel-dsq-detect-format data))))
        (t
         (editor-error "Unsupported DSQ Org reference shape: ~a" reference))))))

(defun org-babel-dsq-reference-location (spec directory)
  "Return an external Org pathname and reference from SPEC, if present."
  (loop :for position := (position #\: spec :from-end t)
          :then (and position (position #\: spec :from-end t :end position))
        :while position
        :for file-part := (subseq spec 0 position)
        :for reference := (subseq spec (1+ position))
        :for pathname := (expand-file-name file-part directory)
        :when (and (plusp (length reference))
                   (org-babel-dsq-regular-input-file-p pathname))
          :return (values pathname reference)))

(defun org-babel-dsq-source-for-spec (spec directory current-text)
  (let ((pathname (expand-file-name spec directory)))
    (when (org-babel-dsq-probe-file pathname)
      (org-babel-dsq-check-file pathname)
      (return-from org-babel-dsq-source-for-spec
        (make-org-babel-dsq-source :pathname pathname))))
  (let* ((percent (position #\% spec :from-end t))
         (format (and percent (string-downcase (subseq spec (1+ percent)))))
         (reference-spec (if percent (subseq spec 0 percent) spec)))
    (when (and percent (not (org-babel-dsq-valid-format format)))
      (editor-error "Invalid DSQ reference format: ~a" format))
    (multiple-value-bind (reference-path reference)
        (org-babel-dsq-reference-location reference-spec directory)
      (multiple-value-bind (data detected-format)
          (if reference-path
              (org-babel-dsq-reference-data
               (org-babel-dsq-read-org-text reference-path) reference)
              (org-babel-dsq-reference-data current-text reference-spec))
        (let ((effective-format (or format detected-format)))
          (unless (org-babel-dsq-valid-format effective-format)
            (editor-error
             "Cannot detect the format for DSQ reference ~a; append %%FORMAT"
             reference-spec))
          (when (and format (string= detected-format "csv")
                     (not (string= format "csv")))
            (editor-error "Tabular DSQ references require csv format"))
          (when (> (length data) *org-babel-dsq-input-limit*)
            (editor-error "DSQ reference exceeds the configured input limit"))
          (make-org-babel-dsq-source
           :data data :format effective-format))))))

(defun org-babel-dsq-call-with-sources (sources function &optional paths)
  "Call FUNCTION with every prepared source pathname while temps are live."
  (if (null sources)
      (funcall function (nreverse paths))
      (let ((source (first sources)))
        (if (org-babel-dsq-source-pathname source)
            (org-babel-dsq-call-with-sources
             (rest sources) function
             (cons (org-babel-dsq-source-pathname source) paths))
            (uiop:with-temporary-file
                (:pathname pathname :stream stream :direction :output
                 :element-type 'character
                 :type (org-babel-dsq-source-format source))
              (write-string (org-babel-dsq-source-data source) stream)
              (finish-output stream)
              (close stream)
              (org-babel-dsq-call-with-sources
               (rest sources) function (cons pathname paths)))))))

(defun org-babel-dsq-value-text (value null-value false-value)
  (cond
    ((eq value :null) (or null-value "nil"))
    ((eq value yason:false) (or false-value "false"))
    ((eq value yason:true) "t")
    ((null value) "nil")
    ((stringp value) value)
    ((numberp value) (princ-to-string value))
    (t (princ-to-string value))))

(defun org-babel-dsq-table-row (values)
  (format nil "| ~{~a~^ | ~} |"
          (mapcar (lambda (value)
                    (cl-ppcre:regex-replace-all "\\|" value "\\\\vert{}"))
                  values)))

(defun org-babel-dsq-table-separator (width)
  (format nil "|~{~a~^+~}|" (make-list width :initial-element "---")))

(defun org-babel-dsq-json-result (output headers)
  (let* ((rows
           (handler-case
               (yason:parse output :object-as :alist
                            :json-booleans-as-symbols t
                            :json-nulls-as-keyword t)
             (error (condition)
               (editor-error "DSQ returned invalid JSON — ~a" condition))))
         (rows (if (vectorp rows) (coerce rows 'list) rows))
         (first-row (first rows)))
    (unless (and (listp rows)
                 (or (null rows)
                     (and (listp first-row)
                          (every (lambda (row)
                                   (and (listp row) (every #'consp row)))
                                 rows))))
      (editor-error "DSQ result is not an array of objects"))
    (if (null rows)
        (make-org-babel-result :text "nil")
        (let* ((columns (mapcar #'car first-row))
               (header-p (org-babel-dsq-yes-p
                          (org-babel-header "header" headers) t))
               (hlines-p (org-babel-dsq-yes-p
                          (org-babel-header "hlines" headers) nil))
               (null-value (org-babel-header "null-value" headers))
               (false-value (org-babel-header "false-value" headers))
               (data-rows
                 (mapcar
                  (lambda (row)
                    (org-babel-dsq-table-row
                     (mapcar
                      (lambda (column)
                        (org-babel-dsq-value-text
                         (cdr (assoc column row :test #'string=))
                         null-value false-value))
                      columns)))
                  rows))
               (separator (org-babel-dsq-table-separator (length columns)))
               (lines nil))
          (when header-p
            (push (org-babel-dsq-table-row columns) lines)
            (push separator lines))
          (loop :for row :in data-rows
                :for firstp := t :then nil
                :do
                   (when (and hlines-p (not firstp)) (push separator lines))
                   (push row lines))
          (make-org-babel-result
           :kind :table
           :text (format nil "~{~a~^~%~}" (nreverse lines)))))))

(defun org-babel-dsq-result (block headers directory)
  (let* ((input-value (org-babel-header "input" headers))
         (specs (org-babel-dsq-input-words input-value directory))
         (current-text (buffer-text (point-buffer (org-babel-block-begin block))))
         (sources (mapcar (lambda (spec)
                            (org-babel-dsq-source-for-spec
                             spec directory current-text))
                          specs))
         (cache-p (org-babel-dsq-yes-p (org-babel-header "cache" headers)))
         (convert-p (org-babel-dsq-yes-p
                     (org-babel-header "convert-numbers" headers) t))
         (result-headers (string-downcase
                          (or (org-babel-header "results" headers) "table"))))
    (when (or (search "list" result-headers)
              (search "raw" result-headers)
              (search "code" result-headers))
      (editor-error "This ob-dsq :results presentation is not yet supported: ~a"
                    result-headers))
    (org-babel-dsq-call-with-sources
     sources
     (lambda (paths)
       (let* ((arguments
                (append
                 (list (uiop:native-namestring (org-babel-program "dsq")))
                 (when cache-p (list "--cache"))
                 (when convert-p (list "--convert-numbers"))
                 (mapcar #'uiop:native-namestring paths)
                 (list (org-babel-block-body block))))
              (output (org-babel-success-output arguments directory)))
         (if (search "verbatim" result-headers)
             (make-org-babel-result :text output)
             (org-babel-dsq-json-result output headers)))))))

(defun org-babel-result-mode (headers)
  (let ((value (string-downcase (or (org-babel-header "results" headers)
                                    "replace"))))
    (cond
      ((or (search "none" value) (search "silent" value)) :none)
      ((or (search "append" value) (search "prepend" value)
           (search "file" value) (search "raw" value)
           (search "drawer" value))
       (editor-error "This Babel :results mode is not yet supported: ~a" value))
      (t :replace))))

(defun org-babel-validate-headers (headers)
  (dolist (name '("var" "session" "async"))
    (alexandria:when-let ((value (org-babel-header name headers)))
      (unless (member (string-downcase value) '("" "nil" "none")
                      :test #'string=)
        (editor-error "Babel :~a is not supported yet" name)))))

(defun org-babel-validate-block (block)
  (when (> (length (org-babel-block-body block)) *org-babel-input-limit*)
    (editor-error "Babel source exceeds the ~d-character limit"
                  *org-babel-input-limit*)))

(defun org-babel-execute (block headers directory)
  (let ((language (org-babel-normalized-language
                   (org-babel-block-language block))))
    (cond
      ((string= language "bash")
       (org-babel-shell-result block headers directory))
      ((string= language "python")
       (org-babel-python-result block headers directory))
      ((string= language "c")
       (org-babel-c-result block directory nil))
      ((string= language "c++")
       (org-babel-c-result block directory t))
      ((string= language "nix")
       (org-babel-nix-result block directory))
      ((string= language "sqlite")
       (org-babel-sqlite-result block headers directory))
      ((string= language "sql")
       (org-babel-sql-result block headers directory))
      ((string= language "dsq")
       (org-babel-dsq-result block headers directory))
      ((string= language "emacs-lisp")
       (editor-error
        "Emacs Lisp blocks require Emacs; Lem will not evaluate them as Common Lisp"))
      (t
       (editor-error "No configured Babel backend for language: ~a" language)))))

(defun org-babel-result-line-p (line)
  (or (cl-ppcre:scan "^\\s*:(?:\\s|$)" line)
      (cl-ppcre:scan "^\\s*\\|" line)))

(defun org-babel-existing-result-bounds (block)
  "Return the marker and exclusive end points of BLOCK's adjacent result."
  (with-point ((line (org-babel-block-end block)))
    (unless (line-offset line 1)
      (return-from org-babel-existing-result-bounds nil))
    (loop :while (and (cl-ppcre:scan "^\\s*$" (line-string line))
                      (line-offset line 1)))
    (unless (cl-ppcre:scan "(?i)^\\s*#\\+results:" (line-string line))
      (return-from org-babel-existing-result-bounds nil))
    (let ((start (copy-point line :temporary))
          (end nil))
      (if (line-offset line 1)
          (progn
            (loop :while (org-babel-result-line-p (line-string line))
                  :do (unless (line-offset line 1)
                        (line-end line)
                        (return)))
            (setf end (copy-point line :temporary)))
          (progn
            (line-end line)
            (setf end (copy-point line :temporary))))
      (values start end))))

(defun org-babel-output-lines (text)
  (let ((text (string-right-trim '(#\Newline #\Return) (or text ""))))
    (if (zerop (length text))
        '("")
        (mapcar (lambda (line) (string-right-trim '(#\Return) line))
                (uiop:split-string text :separator '(#\Newline))))))

(defun org-babel-render-result (block result)
  (let ((indent (org-babel-block-indent block)))
    (with-output-to-string (output)
      (format output "~a#+RESULTS:~%" indent)
      (ecase (org-babel-result-kind result)
        (:output
         (dolist (line (org-babel-output-lines (org-babel-result-text result)))
           (format output "~a:~@[ ~a~]~%" indent
                   (unless (zerop (length line)) line))))
        (:table
         (dolist (line (org-babel-output-lines (org-babel-result-text result)))
           (format output "~a~a~%" indent line)))))))

(defun org-babel-insert-result (block result)
  "Replace BLOCK's adjacent result as one undoable buffer edit."
  (let* ((buffer (point-buffer (org-babel-block-begin block)))
         (rendered (org-babel-render-result block result)))
    (multiple-value-bind (old-start old-end)
        (org-babel-existing-result-bounds block)
      (let ((insertion
              (or old-start
                  (with-point ((point (org-babel-block-end block)))
                    (line-end point)
                    (copy-point point :temporary)))))
        (buffer-disable-undo-boundary buffer)
        (unwind-protect
             (progn
               (when old-start
                 (delete-between-points old-start old-end))
               (insert-string insertion
                              (if old-start
                                  rendered
                                  (format nil "~%~%~a" rendered))))
          (buffer-enable-undo-boundary buffer)
          (buffer-undo-boundary buffer))))))

(define-command lem-yath-org-babel-execute () ()
  "Execute the configured Org source block at point and update its results."
  (let* ((block (or (org-babel-block-at-point (current-point) t)
                    (editor-error "Point is not in an Org source block")))
         (language (org-babel-normalized-language
                    (org-babel-block-language block)))
         (headers (org-babel-effective-headers block)))
    (when (sops-buffer-active-p (current-buffer))
      (editor-error "Babel will not send plaintext from a SOPS buffer"))
    (org-babel-validate-block block)
    (org-babel-validate-headers headers)
    (unless (org-babel-confirm-execution-p language)
      (message "Babel execution cancelled")
      (return-from lem-yath-org-babel-execute nil))
    (let* ((directory (org-babel-directory headers))
           (result-mode (org-babel-result-mode headers))
           (result (org-babel-execute block headers directory)))
      (unless (eq result-mode :none)
        (org-babel-insert-result block result))
      (message "Executed ~a source block" language)
      t)))
