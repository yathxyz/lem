;;;; Read-only, project-scoped tools for agentic LLM presets.

(in-package :lem-yath)

(defparameter *llm-tool-max-lines* 300)
(defparameter *llm-tool-max-results* 200)
(defparameter *llm-tool-file-byte-limit* (* 1024 1024))
(defparameter *llm-tool-process-output-limit* (* 1024 1024))
(defparameter *llm-tool-result-character-limit* (* 128 1024))
(defparameter *llm-tool-string-argument-limit* (* 16 1024))

(defstruct llm-tool-context
  root
  project-request
  mcp-server-names
  mcp-sessions)

(defun llm-json-object (&rest entries)
  "Return an equal-keyed JSON object from alternating key/value ENTRIES."
  (unless (evenp (length entries))
    (error "Odd JSON object entry count"))
  (let ((object (make-hash-table :test #'equal)))
    (loop :for (key value) :on entries :by #'cddr
          :do (setf (gethash key object) value))
    object))

(defun llm-tool-parameter (type description)
  (llm-json-object "type" type "description" description))

(defun llm-tool-schema (name description properties required)
  (llm-json-object
   "type" "function"
   "function"
   (llm-json-object
    "name" name
    "description" description
    "parameters"
    (llm-json-object
     "type" "object"
     "properties" properties
     "required" (coerce required 'vector)))))

(defun llm-tool-definitions (&optional mcp-sessions)
  "Return OpenAI-compatible schemas for the configured read-only tools."
  (concatenate
   'vector
   (vector
    (llm-tool-schema
     "project_root"
     "Return the active project root for the originating buffer. Use this before reading or searching project files."
     (llm-json-object)
     '())
    (llm-tool-schema
     "list_project_files"
     "List files in the active project. Optionally pass a glob like *.lisp or *.org to narrow the result."
     (llm-json-object
      "glob" (llm-tool-parameter
              "string" "Optional glob used to limit the file list, for example *.lisp"))
     '())
    (llm-tool-schema
     "search_project"
     "Search the active project with ripgrep and return matching lines. Prefer this for discovery before reading whole files."
     (llm-json-object
      "pattern" (llm-tool-parameter
                 "string" "Search pattern to look for in project files")
      "glob" (llm-tool-parameter
              "string" "Optional glob used to limit the search, for example *.lisp"))
     '("pattern"))
    (llm-tool-schema
     "read_project_file"
     "Read a UTF-8 text file from the active project. The path must stay inside the project root. Optionally request a line range."
     (llm-json-object
      "path" (llm-tool-parameter
              "string" "Path relative to the current project root")
      "start_line" (llm-tool-parameter
                    "integer" "Optional 1-based starting line number")
      "end_line" (llm-tool-parameter
                  "integer" "Optional 1-based ending line number"))
     '("path"))
    (llm-tool-schema
     "read_emacs_symbol"
     "Return function or variable documentation for the equivalent Lem/Common Lisp symbol. Package-qualified names are supported."
     (llm-json-object
      "name" (llm-tool-parameter
              "string" "Name of the function or variable to inspect"))
     '("name")))
   (if mcp-sessions
       (llm-mcp-tool-definitions mcp-sessions)
       #())))

(defun llm-capture-tool-context (&optional mcp-server-names)
  "Capture the originating buffer's root and a cancellable project request."
  (let* ((directory (or (buffer-directory (current-buffer)) (uiop:getcwd)))
         (root (or (lem-yath-project-root-for-directory directory)
                   (canonical-project-directory directory))))
    (make-llm-tool-context
     :root root
     :project-request
     (make-live-project-request 0 (capture-project-request-origin))
     :mcp-server-names (copy-list mcp-server-names))))

(defun llm-tool-root-name (context)
  (project-native-directory (llm-tool-context-root context)))

(defun llm-tool-string-argument (arguments name &key optional)
  (multiple-value-bind (value present-p) (gethash name arguments)
    (cond
      ((and optional (or (not present-p) (null value))) nil)
      ((not (stringp value))
       (error "~a must be a string" name))
      ((> (length value) *llm-tool-string-argument-limit*)
       (error "~a exceeds the argument size limit" name))
      (t value))))

(defun llm-tool-line-argument (arguments name)
  (multiple-value-bind (value present-p) (gethash name arguments)
    (cond
      ((or (not present-p) (null value)) nil)
      ((and (integerp value) (plusp value)) value)
      (t (error "~a must be a positive integer" name)))))

(defun llm-tool-truncate-lines (text maximum)
  "Cap TEXT at MAXIMUM newline-delimited rows with an omission note."
  (let* ((lines (uiop:split-string text :separator '(#\Newline)))
         (total (length lines)))
    (if (<= total maximum)
        text
        (format nil "~{~a~^~%~}~%... [~d additional lines omitted]"
                (subseq lines 0 maximum) (- total maximum)))))

(defun llm-tool-bound-result (text)
  (if (<= (length text) *llm-tool-result-character-limit*)
      text
      (format nil "~a~%... [result truncated at ~d characters]"
              (subseq text 0 *llm-tool-result-character-limit*)
              *llm-tool-result-character-limit*)))

(defun llm-tool-project-root (context arguments)
  (declare (ignore arguments))
  (llm-tool-root-name context))

(defun llm-tool-list-project-files (context arguments)
  (let* ((glob (llm-tool-string-argument arguments "glob" :optional t))
         (root (llm-tool-context-root context))
         (rg (or (executable-find "rg")
                 (error "ripgrep (rg) is required for list_project_files"))))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (append (list (namestring rg) "--files")
                 (when (and glob (plusp (length glob)))
                   (list "--glob" glob)))
         :directory root
         :request (llm-tool-context-project-request context)
         :output-limit *llm-tool-process-output-limit*)
      (declare (ignore error-output))
      (if (and (integerp status) (zerop status))
          (format nil "Project root: ~a~2%~a"
                  (llm-tool-root-name context)
                  (llm-tool-truncate-lines
                   (string-right-trim '(#\Newline #\Return) output)
                   *llm-tool-max-results*))
          (error "Could not list files in ~a" (llm-tool-root-name context))))))

(defun llm-tool-search-project (context arguments)
  (let* ((pattern (llm-tool-string-argument arguments "pattern"))
         (glob (llm-tool-string-argument arguments "glob" :optional t))
         (root (llm-tool-context-root context))
         (rg (or (executable-find "rg")
                 (error "ripgrep (rg) is required for search_project"))))
    (when (zerop (length pattern))
      (error "pattern must not be empty"))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (append
          (list (namestring rg) "--no-heading" "--line-number"
                "--color" "never" "--smart-case")
          (when (and glob (plusp (length glob))) (list "--glob" glob))
          (list "--" pattern "."))
         :directory root
         :request (llm-tool-context-project-request context)
         :output-limit *llm-tool-process-output-limit*)
      (cond
        ((and (integerp status) (zerop status))
         (format nil "Project root: ~a~%Pattern: ~a~2%~a"
                 (llm-tool-root-name context) pattern
                 (llm-tool-truncate-lines
                  (string-right-trim '(#\Newline #\Return) output)
                  *llm-tool-max-results*)))
        ((eql status 1)
         (format nil "No matches for ~s in ~a"
                 pattern (llm-tool-root-name context)))
        (t
         (error "ripgrep failed while searching ~a: ~a"
                (llm-tool-root-name context)
                (string-trim '(#\Space #\Tab #\Newline #\Return)
                             error-output)))))))

(defun llm-tool-safe-relative-path-p (path)
  (and (safe-project-relative-path-p path)
       (every #'plusp (mapcar #'length
                              (uiop:split-string path :separator "/")))))

(defun llm-tool-resolve-project-file (context relative)
  "Resolve existing RELATIVE to a regular file canonically below CONTEXT."
  (unless (llm-tool-safe-relative-path-p relative)
    (error "Unsafe project-relative path: ~s" relative))
  (let* ((root (llm-tool-context-root context))
         (candidate (project-native-relative-path root relative))
         (resolved (handler-case (truename candidate)
                     (error () (error "File does not exist: ~a" relative)))))
    (unless (project-path-in-directory-p resolved root)
      (error "Path escapes project root: ~a" relative))
    #+sbcl
    (let ((stat (sb-posix:stat (uiop:native-namestring resolved))))
      (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                 sb-posix:s-ifreg)
        (error "Path is not a regular file: ~a" relative)))
    #-sbcl
    (error "Safe project file inspection requires SBCL")
    resolved))

(defun llm-tool-stat-signature (stat)
  (list (sb-posix:stat-dev stat)
        (sb-posix:stat-ino stat)
        (sb-posix:stat-size stat)
        (sb-posix:stat-mtime stat)
        (let ((symbol (find-symbol "STAT-CTIME" :sb-posix)))
          (and symbol (fboundp symbol) (funcall symbol stat)))
        (let ((symbol (find-symbol "STAT-MTIME-NSEC" :sb-posix)))
          (and symbol (fboundp symbol) (funcall symbol stat)))
        (let ((symbol (find-symbol "STAT-CTIME-NSEC" :sb-posix)))
          (and symbol (fboundp symbol) (funcall symbol stat)))))

(defun llm-tool-read-file-octets (pathname root)
  "Read a stable regular PATHNAME through a verified descriptor below ROOT."
  #+sbcl
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring pathname)
                  (logior sb-posix:o-rdonly sb-posix:o-nonblock
                          sb-posix:o-nofollow)))
           (let* ((before (sb-posix:fstat descriptor))
                  (size (sb-posix:stat-size before))
                  (opened
                    (ignore-errors
                      (truename (format nil "/proc/self/fd/~d" descriptor)))))
             (unless (= (logand (sb-posix:stat-mode before) sb-posix:s-ifmt)
                        sb-posix:s-ifreg)
               (error "Path is not a regular file"))
             (unless (and opened (project-path-in-directory-p opened root))
               (error "Opened file escaped the project root"))
             (when (> size *llm-tool-file-byte-limit*)
               (error "File exceeds the ~d-byte inspection limit"
                      *llm-tool-file-byte-limit*))
             (let ((fd descriptor))
               (setf stream
                     (sb-sys:make-fd-stream
                      fd :input t :element-type '(unsigned-byte 8)
                      :buffering :full
                      :name (uiop:native-namestring pathname))
                     descriptor nil)
               (let ((octets
                       (make-array size :element-type '(unsigned-byte 8)))
                     (count 0))
                 (loop :while (< count size)
                       :for next := (read-sequence octets stream :start count)
                       :do (when (= next count) (return))
                           (setf count next))
                 (let ((after (sb-posix:fstat fd)))
                   (unless (and (= count size)
                                (equal (llm-tool-stat-signature before)
                                       (llm-tool-stat-signature after)))
                     (error "File changed while it was being read")))
                 octets))))
      (when stream (ignore-errors (close stream)))
      (when descriptor (ignore-errors (sb-posix:close descriptor)))))
  #-sbcl
  (error "Safe project file inspection requires SBCL"))

(defun llm-tool-read-utf8-file (pathname root)
  (let ((octets (llm-tool-read-file-octets pathname root)))
    (when (position 0 octets)
      (error "Refusing a binary file"))
    #+sbcl
    (handler-case
        (sb-ext:octets-to-string octets :external-format :utf-8)
      (error () (error "File is not valid UTF-8 text")))
    #-sbcl
    (error "UTF-8 project file inspection requires SBCL")))

(defun llm-tool-read-project-file (context arguments)
  (let* ((relative (llm-tool-string-argument arguments "path"))
         (start (or (llm-tool-line-argument arguments "start_line") 1))
         (requested-end (llm-tool-line-argument arguments "end_line"))
         (pathname (llm-tool-resolve-project-file context relative))
         (text (llm-tool-read-utf8-file
                pathname (llm-tool-context-root context)))
         (lines (or (uiop:split-string text :separator '(#\Newline))
                    '("")))
         (total (length lines)))
    (when (> start total)
      (error "start_line ~d is beyond the file's ~d lines" start total))
    (when (and requested-end (< requested-end start))
      (error "end_line must not precede start_line"))
    (let* ((end (min total
                     (or requested-end (+ start *llm-tool-max-lines* -1))
                     (+ start *llm-tool-max-lines* -1)))
           (body (format nil "~{~a~^~%~}" (subseq lines (1- start) end)))
           (note (if (< end total)
                     (format nil "~%... [~d additional lines omitted]"
                             (- total end))
                     "")))
      (format nil
              "Project root: ~a~%File: ~a~%Showing lines ~d-~d of ~d~2%~a~a"
              (llm-tool-root-name context) relative start end total body note))))

(defun llm-tool-find-symbol (name)
  "Find NAME without interning it, preferring Lem-yath's own packages."
  (let* ((separator (position #\: name))
         (package-name (and separator (subseq name 0 separator)))
         (symbol-start
           (and separator
                (+ separator
                   (if (and (< (1+ separator) (length name))
                            (char= (char name (1+ separator)) #\:))
                       2 1)))))
    (if separator
        (let ((package (and (plusp (length package-name))
                            (find-package package-name))))
          (and package (< symbol-start (length name))
               (find-symbol (string-upcase (subseq name symbol-start)) package)))
        (let ((target (string-upcase name)))
          (or (loop :for preferred :in '("LEM-YATH" "LEM" "COMMON-LISP")
                    :for package := (find-package preferred)
                    :for symbol := (and package (find-symbol target package))
                    :when symbol :return symbol)
              (do-all-symbols (symbol)
                (when (string= target (symbol-name symbol))
                  (return symbol))))))))

(defun llm-tool-read-emacs-symbol (context arguments)
  (declare (ignore context))
  (let* ((name (llm-tool-string-argument arguments "name"))
         (symbol (llm-tool-find-symbol name)))
    (cond
      ((null symbol)
       (format nil "No Lem/Common Lisp symbol named ~a is interned" name))
      ((fboundp symbol)
       (format nil "Function: ~a~%Args: ~a~2%~a"
               (help-symbol-label symbol)
               (or (help-callable-lambda-list symbol) "unknown")
               (or (ignore-errors (documentation symbol 'function))
                   "No function documentation available.")))
      ((boundp symbol)
       (format nil "Variable: ~a~%Value type: ~s~2%~a"
               (help-symbol-label symbol)
               (type-of (symbol-value symbol))
               (or (ignore-errors (documentation symbol 'variable))
                   "No variable documentation available.")))
      (t
       (format nil "Symbol ~a exists but is neither a function nor a variable"
               (help-symbol-label symbol))))))

(defun llm-invoke-tool (context name arguments-text)
  "Invoke allowlisted read-only tool NAME with JSON ARGUMENTS-TEXT."
  (handler-case
      (progn
        (unless (and (stringp arguments-text)
                     (<= (length arguments-text)
                         *llm-tool-result-character-limit*))
          (error "Tool arguments exceed the size limit"))
        (let ((arguments (yason:parse arguments-text)))
          (unless (hash-table-p arguments)
            (error "Tool arguments must be a JSON object"))
          (llm-tool-bound-result
           (cond
             ((string= name "project_root")
              (llm-tool-project-root context arguments))
             ((string= name "list_project_files")
              (llm-tool-list-project-files context arguments))
             ((string= name "search_project")
              (llm-tool-search-project context arguments))
             ((string= name "read_project_file")
              (llm-tool-read-project-file context arguments))
             ((string= name "read_emacs_symbol")
              (llm-tool-read-emacs-symbol context arguments))
             ((llm-mcp-find-tool (llm-tool-context-mcp-sessions context) name)
              (llm-mcp-invoke-tool
               (llm-tool-context-mcp-sessions context) name arguments))
             (t (error "Unknown tool: ~a" name))))))
    (project-request-cancelled () "Tool error: request cancelled")
    (error (condition) (format nil "Tool error: ~a" condition))))
