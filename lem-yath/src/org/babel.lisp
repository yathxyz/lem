;;;; Configured Org Babel execution for the native Org subset.

(in-package :lem-yath)

(declaim (ftype function run-project-program project-path-in-directory-p))

(defparameter *org-babel-timeout* 600
  "Maximum seconds allowed for one configured Org source block.")

(defparameter *org-babel-output-limit* (* 16 1024 1024)
  "Maximum stdout or stderr characters retained from one source block.")

(defparameter *org-babel-input-limit* (* 16 1024 1024)
  "Maximum characters accepted from one source block.")

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
