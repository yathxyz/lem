;;;; Yasnippet-compatible, data-only snippet sessions.
;;;;
;;;; The configured Emacs loads one private snippet directory followed by the
;;;; pinned yasnippet-snippets collection.  Lem has no native snippet engine,
;;;; so this module implements the portable part of Yasnippet's file format:
;;;; numbered fields, defaults, nesting, mirrors, escapes, Tab navigation and
;;;; the $0 exit.  Executable Emacs Lisp is deliberately never evaluated.

(in-package :lem-yath)

(defparameter *snippet-mode-aliases*
  '(("CLOJURE-REPL-MODE" . "cider-repl-mode")
    ("ELISP-MODE" . "emacs-lisp-mode")
    ("LISP-MODE" . "lisp-mode")
    ("LEGIT-COMMIT-MODE" . "git-commit-mode")
    ("XML-MODE" . "nxml-mode")
    ("POSIX-SHELL-MODE" . "sh-mode")))

(defparameter *snippet-text-tables*
  '("org-mode" "markdown-mode" "asciidoc-mode" "git-commit-mode"
    "html-mode" "nxml-mode" "latex-mode" "tex-mode" "text-mode"))

(defparameter *snippet-prog-tables*
  '("c++-mode" "c-mode" "clojure-mode" "csharp-mode" "css-mode"
    "elixir-mode" "gdscript-mode" "go-mode" "haskell-mode" "java-mode"
    "js-mode" "js2-mode" "julia-mode" "makefile-mode" "nasm-mode"
    "nix-mode" "perl-mode" "php-mode" "prog-mode" "python-mode"
    "ruby-mode" "rust-mode" "scala-mode" "sh-mode" "swift-mode"
    "tuareg-mode" "typescript-mode"))

(defparameter *snippet-non-prog-tables*
  '("run-shell-mode" "run-python-mode" "lisp-repl-mode"
    "scheme-repl-mode" "cider-repl-mode"))

(defparameter *snippet-derived-parents*
  '(("makefile-gmake-mode" . ("makefile-mode"))
    ("latex-mode" . ("tex-mode"))))

(defparameter *snippet-file-table-overrides*
  '(("bib" . "bibtex-mode")
    ("cc" . "c++-mode")
    ("cpp" . "c++-mode")
    ("cxx" . "c++-mode")
    ("hh" . "c++-mode")
    ("hpp" . "c++-mode")
    ("hxx" . "c++-mode")
    ("cs" . "csharp-mode")
    ("gd" . "gdscript-mode")
    ("nasm" . "nasm-mode")
    ("tex" . "latex-mode")))

(defvar *snippet-table-cache* (make-hash-table :test #'equal))
(defvar *snippet-editing* nil)

(define-attribute snippet-inactive-field)

(define-minor-mode lem-yath-snippet-mode
    (:name "Snippet"
     :description "Yasnippet-compatible field expansion"
     :keymap *snippet-mode-keymap*)
  (unless (mode-active-p (current-buffer) 'lem-yath-snippet-mode)
    (snippet-end-session)))

(defstruct snippet-template
  name
  key
  uuid
  body
  pathname
  table
  supported-p
  unsupported-reason
  fixed-indent-p
  auto-indent-first-line-p)

(defstruct snippet-occurrence
  id
  number
  parent-id
  sequence
  start
  end
  placeholder-p)

(defstruct snippet-rendering
  text
  occurrences
  indent-offsets)

(defstruct snippet-field
  id
  number
  parent-id
  container-ids
  sequence
  overlay
  mirrors
  modified-p
  disabled-p)

(defstruct snippet-session
  buffer
  template
  root-overlay
  fields
  exit-overlay
  current-index
  pending-field-edit-p
  defer-zero-exit-p)

(defun snippet-root-directories ()
  "Return configured snippet roots in private-to-community precedence order."
  (let* ((configured (uiop:getenv "LEM_YATH_SNIPPET_DIRS"))
         (parts
           (if (and configured (plusp (length configured)))
               (remove-if
                (lambda (part) (zerop (length part)))
                (uiop:split-string configured :separator '(#\:)))
               (list (merge-pathnames
                      "snippets/"
                      (asdf:system-source-directory "lem-yath"))))))
    (remove-if-not
     #'uiop:directory-exists-p
     (mapcar #'uiop:ensure-directory-pathname parts))))

(defun snippet-reload ()
  "Forget lazily parsed snippet tables."
  (clrhash *snippet-table-cache*)
  t)

(define-command lem-yath-snippet-reload () ()
  "Reload private and community snippet files on their next use."
  (snippet-reload)
  (message "Snippet tables will be reloaded on next Tab"))

(defun snippet-template-selection-label (template)
  (format nil "~a — ~a (~a)"
          (snippet-template-name template)
          (or (snippet-template-key template) "no trigger")
          (snippet-template-table template)))

(define-command lem-yath-insert-snippet () ()
  "Select and insert a portable snippet without typing its trigger."
  (let ((templates
          (remove-if-not #'snippet-template-supported-p
                         (snippet-active-templates))))
    (if (null templates)
        (message "No portable snippets are active for this buffer")
        (let* ((choices
                 (mapcar (lambda (template)
                           (cons (snippet-template-selection-label template)
                                 template))
                         templates))
               (labels (mapcar #'car choices))
               (choice
                 (prompt-for-string
                  "Snippet: "
                  :completion-function
                  (lambda (input) (prescient-filter input labels))))
               (template (cdr (assoc choice choices :test #'string=))))
          (when template
            (snippet-expand-template template
                                     (current-point)
                                     (current-point)))))))

(defun snippet-active-session (&optional (buffer (current-buffer)))
  (buffer-value buffer :lem-yath-snippet-session))

(defun snippet-active-session-p (&optional (buffer (current-buffer)))
  (not (null (snippet-active-session buffer))))

(defun snippet-current-field (&optional (session (snippet-active-session)))
  (when (and session
             (integerp (snippet-session-current-index session)))
    (nth (snippet-session-current-index session)
         (snippet-session-fields session))))

(defun snippet-current-field-number (&optional (buffer (current-buffer)))
  (alexandria:when-let* ((session (snippet-active-session buffer))
                         (field (snippet-current-field session)))
    (snippet-field-number field)))

;;; File discovery -----------------------------------------------------------

(defun snippet-file-table-name (&optional (buffer (current-buffer)))
  (let* ((filename (buffer-filename buffer))
         (basename (and filename (file-namestring filename)))
         (type (and filename (pathname-type filename)))
         (file-override
           (and type
                (cdr (assoc (string-downcase type)
                            *snippet-file-table-overrides*
                            :test #'string=)))))
    (cond
      ((and basename
            (or (string-equal basename "Makefile")
                (string-equal basename "GNUmakefile")
                (and type (string-equal type "mk"))))
       "makefile-gmake-mode")
      ((and type (string-equal type "org")) "org-mode")
      ((and type (member (string-downcase type) '("md" "markdown")
                         :test #'string=))
       "markdown-mode")
      (file-override file-override)
      (t
       (let* ((mode-name (symbol-name (buffer-major-mode buffer)))
              (alias (assoc mode-name *snippet-mode-aliases*
                            :test #'string=)))
         (or (cdr alias)
             (string-downcase mode-name)))))))

(defun snippet-language-buffer-p (&optional (buffer (current-buffer)))
  (ignore-errors
    (typep (lem-core::ensure-mode-object (buffer-major-mode buffer))
           'lem/language-mode:language-mode)))

(defun snippet-read-parent-file (root table)
  (let ((pathname (merge-pathnames
                   (format nil "~a/.yas-parents" table) root)))
    (when (uiop:file-exists-p pathname)
      (remove-if
       (lambda (part) (zerop (length part)))
       (uiop:split-string (uiop:read-file-string pathname)
                          :separator '(#\Space #\Tab #\Newline #\Return))))))

(defun snippet-ordered-merge (lists)
  "Stable topological merge used by Emacs 31 for mode ancestry."
  (let ((nodes nil)
        (edges (make-hash-table :test #'equal))
        (indegrees (make-hash-table :test #'equal))
        (selected (make-hash-table :test #'equal)))
    (labels ((ensure-node (node)
               (unless (nth-value 1 (gethash node indegrees))
                 (setf (gethash node indegrees) 0
                       nodes (append nodes (list node)))))
             (add-edge (from to)
               (ensure-node from)
               (ensure-node to)
               (unless (member to (gethash from edges) :test #'equal)
                 (push to (gethash from edges))
                 (incf (gethash to indegrees)))))
      (dolist (list lists)
        (dolist (node list)
          (ensure-node node))
        (loop :for (from to) :on list
              :while to
              :do (add-edge from to)))
      (loop :with result = nil
            :repeat (length nodes)
            :for node =
              (or (find-if
                   (lambda (candidate)
                     (and (not (gethash candidate selected))
                          (zerop (gethash candidate indegrees))))
                   nodes)
                  ;; A malformed parent cycle should remain deterministic.
                  (find-if (lambda (candidate)
                             (not (gethash candidate selected)))
                           nodes))
            :while node
            :do (setf (gethash node selected) t)
                (setf result (append result (list node)))
                (dolist (successor (gethash node edges))
                  (decf (gethash successor indegrees)))
            :finally (return result)))))

(defun snippet-direct-explicit-parents (table roots)
  (let ((seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (root roots)
      (dolist (parent (snippet-read-parent-file root table))
        (unless (gethash parent seen)
          (setf (gethash parent seen) t)
          (setf result (append result (list parent))))))
    result))

(defun snippet-natural-parent-tables (table primary buffer)
  (or (cdr (assoc table *snippet-derived-parents* :test #'string=))
      (cond
        ((string= table "fundamental-mode") nil)
        ((or (string= table "prog-mode")
             (string= table "text-mode"))
         '("fundamental-mode"))
        ((member table *snippet-text-tables* :test #'string=)
         '("text-mode"))
        ((or (member table *snippet-prog-tables* :test #'string=)
             (and (string= table primary)
                  (not (member table *snippet-non-prog-tables*
                               :test #'string=))
                  (snippet-language-buffer-p buffer)))
         '("prog-mode"))
        (t '("fundamental-mode")))))

(defun snippet-table-names (&optional (buffer (current-buffer)))
  "Return active Yas table names in Emacs 31 ancestry order."
  (let* ((primary (snippet-file-table-name buffer))
         (roots (snippet-root-directories))
         (memo (make-hash-table :test #'equal)))
    (labels ((ancestry (table visiting)
               (let ((cached (gethash table memo :missing)))
                 (cond
                   ((not (eq cached :missing)) cached)
                   ((member table visiting :test #'equal) (list table))
                   (t
                    (let* ((next-visiting (cons table visiting))
                           (natural
                             (mapcar
                              (lambda (parent)
                                (ancestry parent next-visiting))
                              (snippet-natural-parent-tables
                               table primary buffer)))
                           (explicit
                             (mapcar
                              (lambda (parent)
                                (ancestry parent next-visiting))
                              (snippet-direct-explicit-parents table roots)))
                           (result
                             (snippet-ordered-merge
                              (append (list (list table))
                                      natural
                                      explicit))))
                      (setf (gethash table memo) result)))))))
      (ancestry primary nil))))

(defun snippet-definition-file-p (pathname)
  (let ((name (file-namestring pathname))
        (type (pathname-type pathname)))
    (and (plusp (length name))
         (char/= (char name 0) #\.)
         (not (and type
                   (member (string-downcase type) '("el" "elc")
                           :test #'string=))))))

(defun snippet-directory-files-recursively (directory)
  "Return files in Yas override precedence, highest precedence first."
  (labels ((walk (dir)
             (append
              (loop :for subdirectory
                      :in (sort (copy-list (uiop:subdirectories dir))
                                #'string> :key #'namestring)
                    :unless (char= (char (car (last (pathname-directory
                                                     subdirectory))) 0)
                                   #\.)
                      :append (walk subdirectory))
              ;; Within one directory Yas's earlier alphabetical definition
              ;; wins, while a later recursively loaded subdirectory overrides
              ;; an earlier directory.  Visiting subdirectories in reverse
              ;; order before local files lets a first-wins dedupe express both.
              (remove-if-not #'snippet-definition-file-p
                             (sort (copy-list (uiop:directory-files dir))
                                   #'string< :key #'namestring)))))
    (walk directory)))

(defun snippet-skip-leading-blank-lines (content start)
  "Match Yas's greedy whitespace after the `# --' separator."
  (loop :with length = (length content)
        :for newline = (position #\Newline content :start start)
        :for end = (or newline length)
        :for line = (subseq content start end)
        :while (every (lambda (character)
                        (find character '(#\Space #\Tab #\Return)
                              :test #'char=))
                      line)
        :when newline :do (setf start (1+ newline))
        :unless newline :do (return length)
        :finally (return start)))

(defun snippet-header-and-body (content)
  (loop :with length = (length content)
        :for start = 0 :then (1+ newline)
        :for newline = (position #\Newline content :start start)
        :for end = (or newline length)
        :for line = (subseq content start end)
        :when (string= (string-trim '(#\Space #\Tab #\Return) line)
                       "# --")
          :do (return
                (values
                 (subseq content 0 start)
                 (if newline
                     (subseq content
                             (snippet-skip-leading-blank-lines
                              content (1+ newline)))
                     "")))
        :while newline
        :finally (return (values nil nil))))

(defun snippet-unescaped-p (string index)
  (loop :for position :downfrom (1- index) :to 0
        :while (char= (char string position) #\\)
        :count t :into backslashes
        :finally (return (evenp backslashes))))

(defun snippet-transform-start-p (body index)
  (when (char= (char body index) #\$)
    (let ((cursor index)
          (length (length body)))
      (loop :while (and (< cursor length)
                        (char= (char body cursor) #\$))
            :do (incf cursor))
      (loop :while (and (< cursor length)
                        (find (char body cursor)
                              '(#\Space #\Tab #\Newline #\Return)
                              :test #'char=))
            :do (incf cursor))
      (and (< cursor length)
           (char= (char body cursor) #\()))))

(defun snippet-normalize-newlines (content)
  "Decode CRLF pairs the same way Emacs does when visiting snippet files."
  (with-output-to-string (output)
    (loop :with index = 0
          :with length = (length content)
          :while (< index length)
          :for character = (char content index)
          :do (if (and (char= character #\Return)
                       (< (1+ index) length)
                       (char= (char content (1+ index)) #\Newline))
                  (progn
                    (write-char #\Newline output)
                    (incf index 2))
                  (progn
                    (write-char character output)
                    (incf index))))))

(defun snippet-executable-body-reason (body)
  (loop :with field-depth = 0
        :for index :from 0 :below (length body)
        :for character = (char body index)
        :for unescaped-p = (snippet-unescaped-p body index)
        :when (and unescaped-p
                   (or (char= character #\`)
                       (and (plusp field-depth)
                            (snippet-transform-start-p body index))))
          :do (return "embedded Emacs Lisp or a field transform")
        :when (and unescaped-p
                   (char= character #\$)
                   (< (1+ index) (length body))
                   (char= (char body (1+ index)) #\{))
          :do (incf field-depth)
        :when (and unescaped-p
                   (char= character #\})
                   (plusp field-depth))
          :do (decf field-depth)))

(defun snippet-expand-env-policy (expand-env)
  "Recognize the complete data-only expand-env vocabulary in the pinned set."
  (if (null expand-env)
      (values t nil nil)
      (let ((canonical
              (string-downcase
               (remove-if (lambda (character)
                            (find character
                                  '(#\Space #\Tab #\Newline #\Return)
                                  :test #'char=))
                          expand-env))))
        (cond
          ((string= canonical "((yas-indent-line'fixed))")
           (values t t nil))
          ((string= canonical
                    "((yas-indent-line'fixed)(yas-wrap-around-regionnil))")
           (values t t nil))
          ((string= canonical "((yas-also-auto-indent-first-linet))")
           (values t nil t))
          (t (values nil nil nil))))))

(defun snippet-parse-definition (pathname table)
  (handler-case
      (let ((content
              (snippet-normalize-newlines
               (uiop:read-file-string pathname))))
        (multiple-value-bind (header body)
            (snippet-header-and-body content)
          (unless body
            (return-from snippet-parse-definition nil))
          (let ((name (file-namestring pathname))
                (key nil)
                (uuid nil)
                (condition nil)
                (type nil)
                (binding nil)
                (expand-env nil))
            (dolist (line (uiop:split-string header :separator '(#\Newline)))
              (multiple-value-bind (match groups)
                  (cl-ppcre:scan-to-strings
                   "^#\\s*([^:]+):\\s*(.*)\\r?$" line)
                (when match
                  (let ((directive (string-downcase
                                    (string-trim '(#\Space #\Tab)
                                                 (aref groups 0))))
                        (value (string-trim '(#\Space #\Tab #\Return)
                                            (aref groups 1))))
                    (cond
                      ((string= directive "name") (setf name value))
                      ((string= directive "key") (setf key value))
                      ((string= directive "uuid") (setf uuid value))
                      ((string= directive "condition")
                       (setf condition value))
                      ((string= directive "type") (setf type value))
                      ((string= directive "binding") (setf binding value))
                      ((string= directive "expand-env")
                       (setf expand-env value)))))))
            (multiple-value-bind (expand-env-supported-p
                                  fixed-indent-p
                                  auto-indent-first-line-p)
                (snippet-expand-env-policy expand-env)
              (let* ((key (if (or key binding)
                              key
                              (file-namestring pathname)))
                     (body-reason (snippet-executable-body-reason body))
                     (reason
                       (cond
                         ((and condition
                               (not (string-equal condition "t")))
                          "an executable # condition")
                         ((and type (string-equal type "command"))
                          "a command snippet")
                         ((not expand-env-supported-p)
                          "an unsupported # expand-env")
                         (body-reason body-reason))))
                (make-snippet-template
                 :name name
                 :key key
                 :uuid uuid
                 :body body
                 :pathname pathname
                 :table table
                 :supported-p (null reason)
                 :unsupported-reason reason
                 :fixed-indent-p fixed-indent-p
                 :auto-indent-first-line-p
                 auto-indent-first-line-p))))))
    (error () nil)))

(defun snippet-template-identity (template)
  (or (snippet-template-uuid template)
      (snippet-template-name template)))

(defun snippet-dedupe-table-templates (templates)
  "Keep the first template in the Yas precedence traversal."
  (let ((seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (template templates)
      (let ((identity (snippet-template-identity template)))
        (unless (gethash identity seen)
          (setf (gethash identity seen) t)
          (push template result))))
    (nreverse result)))

(defun snippet-load-table-from-root (root table)
  (let* ((key (list (namestring root) table))
         (cached (gethash key *snippet-table-cache* :missing)))
    (if (not (eq cached :missing))
        cached
        (let ((directory (merge-pathnames (format nil "~a/" table) root)))
          (setf (gethash key *snippet-table-cache*)
                (if (uiop:directory-exists-p directory)
                    (snippet-dedupe-table-templates
                     (remove nil
                             (mapcar
                              (lambda (pathname)
                                (snippet-parse-definition pathname table))
                              (snippet-directory-files-recursively
                               directory))))
                    nil))))))

(defun snippet-active-templates (&optional (buffer (current-buffer)))
  (let ((seen (make-hash-table :test #'equal))
        (templates nil))
    ;; Table specificity is primary.  Root order only decides overrides inside
    ;; one table, matching how Yas merges each configured snippet directory.
    (dolist (table (snippet-table-names buffer))
      (dolist (root (snippet-root-directories))
        (dolist (template (snippet-load-table-from-root root table))
          (let ((identity (list table
                                (snippet-template-identity template))))
            (unless (gethash identity seen)
              (setf (gethash identity seen) t)
              (push template templates))))))
    (nreverse templates)))

;;; Portable template parser -------------------------------------------------

(defun snippet-resolve-occurrence-identities (occurrences)
  "Attach simple `$N' forms to Yas's winning braced field for N."
  (let* ((ordered (sort (copy-list occurrences) #'<
                        :key #'snippet-occurrence-sequence))
         (braced-fields (make-hash-table))
         (simple-fields (make-hash-table)))
    ;; Yas parses every braced field first.  Its field lookup then returns the
    ;; last braced occurrence for a repeated number.
    (dolist (occurrence ordered)
      (when (and (snippet-occurrence-placeholder-p occurrence)
                 (snippet-occurrence-number occurrence))
        (setf (gethash (snippet-occurrence-number occurrence) braced-fields)
              occurrence)))
    ;; The first simple form creates a field only when no braced field exists;
    ;; subsequent simple forms are mirrors of that same field.  Zero is always
    ;; a separate exit marker and is handled during session construction.
    (dolist (occurrence ordered)
      (let ((number (snippet-occurrence-number occurrence)))
        (when (and number
                   (plusp number)
                   (not (snippet-occurrence-placeholder-p occurrence)))
          (let ((primary
                  (or (gethash number braced-fields)
                      (gethash number simple-fields))))
            (if primary
                (setf (snippet-occurrence-id occurrence)
                      (snippet-occurrence-id primary))
                (setf (gethash number simple-fields) occurrence))))))
    ordered))

(defun snippet-render-template (template)
  "Render TEMPLATE to plain text and position records without evaluating code."
  (let* ((source (snippet-template-body template))
         (length (length source))
         (output (make-array 128 :element-type 'character
                             :adjustable t :fill-pointer 0))
         (occurrences nil)
         (indent-offsets nil)
         (occurrence-counter 0))
    (labels ((emit (character)
               (vector-push-extend character output))
             (output-position () (fill-pointer output))
             (next-sequence () (incf occurrence-counter))
             (field-id (sequence) (list :field sequence))
             (simple-id (sequence) (list :simple sequence))
             (read-number (index)
               (let ((end index))
                 (loop :while (and (< end length)
                                   (digit-char-p (char source end)))
                       :do (incf end))
                 (values (and (< index end)
                              (parse-integer source :start index :end end))
                         end)))
             (parse-segment (index terminator parent-id)
               (loop
                 (when (>= index length)
                   (when terminator
                     (error "Unclosed snippet field"))
                   (return index))
                 (let ((character (char source index)))
                   (cond
                     ((and terminator (char= character terminator))
                      (return (1+ index)))
                     ((char= character #\\)
                      (if (and (< (1+ index) length)
                               (find (char source (1+ index))
                                     '(#\\ #\` #\" #\' #\$ #\} #\{
                                       #\( #\))
                                     :test #'char=))
                          (progn
                            (emit (char source (1+ index)))
                            (incf index 2))
                          (progn (emit character) (incf index))))
                     ((and (char= character #\$)
                           (< (1+ index) length)
                           (digit-char-p (char source (1+ index))))
                      (multiple-value-bind (number end)
                          (read-number (1+ index))
                        (let ((position (output-position))
                              (sequence (next-sequence)))
                          (push (make-snippet-occurrence
                                 :id (simple-id sequence) :number number
                                 :parent-id parent-id
                                 :sequence sequence
                                 :start position :end position
                                 :placeholder-p nil)
                                occurrences))
                        (setf index end)))
                     ((and (char= character #\$)
                           (< (1+ index) length)
                           (char= (char source (1+ index)) #\>))
                      (push (output-position) indent-offsets)
                      (incf index 2))
                     ((and (char= character #\$)
                           (< (1+ index) length)
                           (char= (char source (1+ index)) #\{))
                      (multiple-value-bind (number after-number)
                          (read-number (+ index 2))
                        (let ((numbered-syntax-p
                                (and number
                                     (< after-number length)
                                     (find (char source after-number)
                                           '(#\} #\:) :test #'char=))))
                          (if numbered-syntax-p
                              (cond
                                ((char= (char source after-number) #\})
                                 (let ((position (output-position))
                                       (sequence (next-sequence)))
                                   (push (make-snippet-occurrence
                                          :id (simple-id sequence)
                                          :number number
                                          :parent-id parent-id
                                          :sequence sequence
                                          :start position :end position
                                          :placeholder-p nil)
                                         occurrences))
                                 (setf index (1+ after-number)))
                                (t
                                 (let* ((sequence (next-sequence))
                                        (id (field-id sequence))
                                        (start (output-position)))
                                   (setf index
                                         (parse-segment
                                          (1+ after-number) #\} id))
                                   (push (make-snippet-occurrence
                                          :id id :number number
                                          :parent-id parent-id
                                          :sequence sequence
                                          :start start
                                          :end (output-position)
                                          :placeholder-p t)
                                         occurrences))))
                              ;; Yas's anonymous placeholder syntax is
                              ;; `${default}` (including digit-leading text
                              ;; such as `${12px}`), not `${:default}`.
                              (let* ((sequence (next-sequence))
                                     (id (field-id sequence))
                                     (start (output-position)))
                                (setf index
                                      (parse-segment (+ index 2) #\} id))
                                (push (make-snippet-occurrence
                                       :id id :number nil
                                       :parent-id parent-id
                                       :sequence sequence
                                       :start start
                                       :end (output-position)
                                       :placeholder-p t)
                                      occurrences))))))
                     (t
                      (emit character)
                      (incf index)))))))
      (parse-segment 0 nil nil))
    (make-snippet-rendering
     :text (coerce output 'string)
     :occurrences (snippet-resolve-occurrence-identities occurrences)
     :indent-offsets (nreverse indent-offsets))))

;;; Session construction and editing ----------------------------------------

(defun snippet-point-at-offset (start offset)
  (let ((point (copy-point start :temporary)))
    (or (character-offset point offset)
        point)))

(defun snippet-occurrence-overlay (root-start occurrence)
  (let ((start (snippet-point-at-offset
                root-start (snippet-occurrence-start occurrence)))
        (end (snippet-point-at-offset
              root-start (snippet-occurrence-end occurrence))))
    (make-overlay start end 'snippet-inactive-field)))

(defun snippet-overlay-string (overlay)
  (points-to-string (overlay-start overlay) (overlay-end overlay)))

(defun snippet-replace-overlay-string (overlay string)
  (with-point ((start (overlay-start overlay) :right-inserting)
               (end (overlay-end overlay) :left-inserting))
    (delete-between-points start end)
    (insert-string start string)))

(defun snippet-primary-occurrence (occurrences)
  (or (find-if #'snippet-occurrence-placeholder-p occurrences)
      (first occurrences)))

(defun snippet-exit-occurrence-p (occurrence)
  (and (eql (snippet-occurrence-number occurrence) 0)
       (not (snippet-occurrence-placeholder-p occurrence))))

(defun snippet-field-navigation-before-p (left right)
  "Order fields like Yas: positive numbers, anonymous fields, then zero."
  (let ((left-number (snippet-field-number left))
        (right-number (snippet-field-number right)))
    (cond
      ((and left-number right-number)
       (cond
         ((/= left-number right-number)
          (cond
            ((zerop left-number) nil)
            ((zerop right-number) t)
            (t (< left-number right-number))))
         ;; Yas pushes braced fields while parsing.  Equal positive numbers
         ;; consequently navigate right-to-left; equal zero fields are the
         ;; observed exception and retain source order.
         ((zerop left-number)
          (< (snippet-field-sequence left)
             (snippet-field-sequence right)))
         (t
          (> (snippet-field-sequence left)
             (snippet-field-sequence right)))))
      (left-number (not (zerop left-number)))
      (right-number (zerop right-number))
      (t
       (< (position-at-point
           (overlay-start (snippet-field-overlay left)))
          (position-at-point
           (overlay-start (snippet-field-overlay right))))))))

(defun snippet-make-fields (root-start occurrences)
  (let ((groups (make-hash-table :test #'equal))
        (order nil)
        (exit-occurrence nil))
    (dolist (occurrence occurrences)
      (when (snippet-exit-occurrence-p occurrence)
        ;; The last simple `$0' or `${0}' is the exit.  Braced `${0:...}'
        ;; remains an ordinary final field and is never grouped with it.
        (setf exit-occurrence occurrence)))
    (dolist (occurrence
              (remove-if #'snippet-exit-occurrence-p occurrences))
      (let ((id (snippet-occurrence-id occurrence)))
        (unless (gethash id groups)
          (push id order))
        (push occurrence (gethash id groups))))
    (let ((fields
            (loop :for id :in (nreverse order)
                  :for group = (nreverse (gethash id groups))
                  :for primary = (snippet-primary-occurrence group)
                  :for primary-overlay =
                    (snippet-occurrence-overlay root-start primary)
                  :for mirrors =
                    (nreverse
                     (loop :for occurrence :in group
                           :unless (eq occurrence primary)
                             :collect (snippet-occurrence-overlay
                                       root-start occurrence)))
                  :for field =
                    (make-snippet-field
                     :id id
                     :number (snippet-occurrence-number primary)
                     :parent-id (snippet-occurrence-parent-id primary)
                     :container-ids
                     (remove-duplicates
                      (remove nil
                              (mapcar #'snippet-occurrence-parent-id group))
                      :test #'equal)
                     :sequence (snippet-occurrence-sequence primary)
                     :overlay primary-overlay
                     :mirrors mirrors
                     :modified-p nil
                     :disabled-p nil)
                  :collect field)))
      (values
       (sort fields #'snippet-field-navigation-before-p)
       (and exit-occurrence
            (snippet-occurrence-overlay root-start exit-occurrence))))))

(defun snippet-field-descendant-p (field ancestor-id fields)
  (loop :for parent = (snippet-field-parent-id field)
          :then (alexandria:when-let ((parent-field
                                       (find parent fields
                                             :key #'snippet-field-id
                                             :test #'equal)))
                  (snippet-field-parent-id parent-field))
        :while parent
        :thereis (equal parent ancestor-id)))

(defun snippet-disable-descendants (session field)
  (let ((*snippet-editing* t))
    (dolist (candidate (snippet-session-fields session))
      (when (snippet-field-descendant-p
             candidate (snippet-field-id field)
             (snippet-session-fields session))
        ;; Removing a parent placeholder removes every nested field, including
        ;; mirrors which live outside the parent's text range.
        (snippet-replace-overlay-string
         (snippet-field-overlay candidate) "")
        (dolist (mirror (snippet-field-mirrors candidate))
          (snippet-replace-overlay-string mirror ""))
        (setf (snippet-field-disabled-p candidate) t)))))

(defun snippet-field-dependencies (field fields)
  "Fields whose occurrences are nested inside FIELD."
  (remove-if-not
   (lambda (candidate)
     (member (snippet-field-id field)
             (snippet-field-container-ids candidate)
             :test #'equal))
   fields))

(defun snippet-sync-mirrors (session)
  ;; A containing field's mirror includes the rendered values of nested
  ;; fields.  Synchronize dependencies first, then the container, rather than
  ;; relying on numeric order.  Cyclic templates settle deterministically at
  ;; the first already-visiting field instead of recursing forever.
  (let ((*snippet-editing* t)
        (done (make-hash-table :test #'equal))
        (visiting (make-hash-table :test #'equal))
        (fields (snippet-session-fields session)))
    (labels ((sync-field (field)
               (let ((id (snippet-field-id field)))
                 (unless (gethash id done)
                   (unless (gethash id visiting)
                     (setf (gethash id visiting) t)
                     (dolist (dependency
                               (snippet-field-dependencies field fields))
                       (sync-field dependency))
                     (remhash id visiting)
                     (unless (or (snippet-field-disabled-p field)
                                 (null (snippet-field-number field)))
                       (let ((text
                               (snippet-overlay-string
                                (snippet-field-overlay field))))
                         (dolist (mirror (snippet-field-mirrors field))
                           (snippet-replace-overlay-string mirror text))))
                     (setf (gethash id done) t))))))
      (dolist (field fields)
        (sync-field field)))))

(defun snippet-delete-field-overlays (field)
  (delete-overlay (snippet-field-overlay field))
  (dolist (mirror (snippet-field-mirrors field))
    (delete-overlay mirror)))

(defun snippet-end-session (&optional (buffer (current-buffer)))
  "End BUFFER's live field session while retaining inserted text."
  (alexandria:when-let ((session (snippet-active-session buffer)))
    (setf (buffer-value buffer :lem-yath-snippet-session) nil)
    (remove-hook (variable-value 'before-change-functions :buffer buffer)
                 'snippet-before-change)
    (remove-hook (variable-value 'after-change-functions :buffer buffer)
                 'snippet-after-change)
    (dolist (field (snippet-session-fields session))
      (snippet-delete-field-overlays field))
    (when (snippet-session-exit-overlay session)
      (delete-overlay (snippet-session-exit-overlay session)))
    (delete-overlay (snippet-session-root-overlay session))
    t))

(defun snippet-point-within-overlay-p (point overlay)
  (and (eq (point-buffer point) (overlay-buffer overlay))
       (point<= (overlay-start overlay) point (overlay-end overlay))))

(defun snippet-deletion-within-overlay-p (point length overlay)
  (and (snippet-point-within-overlay-p point overlay)
       (with-point ((end point))
         (and (character-offset end length)
              (point<= end (overlay-end overlay))))))

(defun snippet-clear-field-default (session field point)
  (unless (snippet-field-modified-p field)
    (setf (snippet-field-modified-p field) t)
    (snippet-disable-descendants session field)
    (let ((*snippet-editing* t))
      (snippet-replace-overlay-string (snippet-field-overlay field) ""))
    (move-point point (overlay-start (snippet-field-overlay field)))))

(defun snippet-before-change (point argument)
  (unless *snippet-editing*
    (alexandria:when-let* ((session (snippet-active-session
                                     (point-buffer point)))
                           (field (snippet-current-field session)))
      (let ((overlay (snippet-field-overlay field)))
        (if (if (stringp argument)
                (snippet-point-within-overlay-p point overlay)
                (snippet-deletion-within-overlay-p point argument overlay))
            (progn
              (when (and (stringp argument)
                         (not (snippet-field-modified-p field))
                         (point= point (overlay-start overlay)))
                (snippet-clear-field-default session field point))
              (setf (snippet-field-modified-p field) t
                    (snippet-session-pending-field-edit-p session) t))
            (snippet-end-session (point-buffer point)))))))

(defun snippet-after-change (start end old-length)
  (declare (ignore end old-length))
  (unless *snippet-editing*
    (let ((buffer (point-buffer start)))
      (alexandria:when-let ((session (snippet-active-session buffer)))
      (if (snippet-session-pending-field-edit-p session)
          (progn
            (setf (snippet-session-pending-field-edit-p session) nil)
            (snippet-sync-mirrors session)
            ;; `${0:text}' is the selected final replacement field.  Retain it
            ;; for one edit so ordinary typing replaces TEXT, then commit.
            (alexandria:when-let ((field (snippet-current-field session)))
              (when (eql (snippet-field-number field) 0)
                (snippet-end-session buffer))))
          (snippet-end-session buffer))))))

(defun snippet-next-enabled-index (session index direction)
  (loop :for candidate = (+ index direction) :then (+ candidate direction)
        :while (<= 0 candidate)
        :while (< candidate (length (snippet-session-fields session)))
        :for field = (nth candidate (snippet-session-fields session))
        :unless (snippet-field-disabled-p field)
          :do (return candidate)))

(defun snippet-activate-index (session index)
  (alexandria:when-let ((old (snippet-current-field session)))
    (set-overlay-attribute 'snippet-inactive-field
                           (snippet-field-overlay old)))
  (setf (snippet-session-current-index session) index)
  (let ((field (snippet-current-field session)))
    (setf (snippet-session-defer-zero-exit-p session)
          (eql (snippet-field-number field) 0))
    (set-overlay-attribute 'region (snippet-field-overlay field))
    (move-point (buffer-point (snippet-session-buffer session))
                (overlay-start (snippet-field-overlay field)))
    field))

(defun snippet-finish-at-exit (session)
  (let ((buffer (snippet-session-buffer session)))
    (when (snippet-session-exit-overlay session)
      (move-point (buffer-point buffer)
                  (overlay-start (snippet-session-exit-overlay session))))
    (snippet-end-session buffer)))

(defun snippet-current-zero-field-p (session)
  (alexandria:when-let ((field (snippet-current-field session)))
    (eql (snippet-field-number field) 0)))

(defun snippet-move-field (direction)
  (alexandria:when-let ((session (snippet-active-session)))
    (lem/completion-mode:completion-end)
    (let ((next
            (unless (and (plusp direction)
                         (snippet-current-zero-field-p session))
              (snippet-next-enabled-index
               session (snippet-session-current-index session) direction))))
      (if next
          (snippet-activate-index session next)
          (snippet-finish-at-exit session)))
    t))

;;; Indentation --------------------------------------------------------------

(defun snippet-indent-fixed (root-overlay column)
  (with-point ((line (overlay-start root-overlay) :left-inserting))
    (line-end line)
    (loop :while (and (line-offset line 1)
                      (point<= line (overlay-end root-overlay)))
          :do (line-start line)
              ;; Yas's fixed mode prefixes the trigger column; it preserves
              ;; the template's own relative indentation.
              (when (plusp (length (line-string line)))
                (insert-string line (make-string column
                                                 :initial-element #\Space))))))

(defun snippet-indent-auto (root-overlay include-first-line-p)
  (with-point ((line (overlay-start root-overlay) :left-inserting))
    (unless include-first-line-p
      (line-offset line 1))
    (loop :while (point< line (overlay-end root-overlay))
          :do (unless (zerop (length
                              (string-trim '(#\Space #\Tab)
                                           (line-string line))))
                (ignore-errors (indent-line line)))
          :while (line-offset line 1))))

(defun snippet-make-indent-marker-points (root-start offsets)
  (mapcar (lambda (offset)
            (copy-point (snippet-point-at-offset root-start offset)
                        :left-inserting))
          offsets))

(defun snippet-indent-marker-points (points)
  (dolist (line points)
    (ignore-errors (indent-line line))))

;;; Trigger matching and expansion ------------------------------------------

(defun snippet-whitespace-character-p (character)
  (find character '(#\Space #\Tab #\Newline #\Return) :test #'char=))

(defun snippet-trigger-bounds-candidates (point)
  (let ((candidates nil))
    (labels ((record (start)
               (let ((text (points-to-string start point)))
                 (unless (find text candidates :key #'second
                               :test #'string=)
                   (push (list (copy-point start :temporary) text)
                         candidates))))
             (scan (predicate)
               (with-point ((start point))
                 (skip-chars-backward start predicate)
                 (record start))))
      (scan (lambda (character)
              (not (snippet-whitespace-character-p character))))
      (scan (lambda (character)
              (or (alphanumericp character)
                  (find character "_-+*/.<>=!?():" :test #'char=))))
      (scan (lambda (character)
              (or (alphanumericp character)
                  (find character "_-+*/.<>=!?" :test #'char=))))
      (scan (lambda (character)
              (or (alphanumericp character)
                  (find character "_-+*/<>=!?" :test #'char=))))
      (scan #'alphanumericp))
    (nreverse candidates)))

(defun snippet-trigger-match (&optional (point (current-point)))
  (let ((templates (snippet-active-templates (point-buffer point))))
    (dolist (candidate (snippet-trigger-bounds-candidates point))
      (destructuring-bind (start text) candidate
        (let ((matching (remove-if-not
                         (lambda (template)
                           (and (snippet-template-key template)
                                (string= text
                                         (snippet-template-key template))))
                         templates)))
          (when matching
            (return (values matching start point))))))))

(defun snippet-select-template (templates)
  (let ((supported (remove-if-not #'snippet-template-supported-p templates)))
    (cond
      ((null supported)
       (message "Snippet ~a is unavailable: it requires ~a"
                (snippet-template-key (first templates))
                (snippet-template-unsupported-reason (first templates)))
       :unsupported)
      ((null (rest supported)) (first supported))
      (t
       (let* ((labels (mapcar #'snippet-template-name supported))
              (choice
                (prompt-for-string
                 "Snippet: "
                 :completion-function
                 (lambda (input) (prescient-filter input labels)))))
         (or (find choice supported :key #'snippet-template-name
                   :test #'string=)
             (first supported)))))))

(defun snippet-expand-template (template trigger-start trigger-end)
  (handler-case
      (let* ((rendering (snippet-render-template template))
             (buffer (point-buffer trigger-start))
             (original-column (point-charpos trigger-start))
             (original-text (points-to-string trigger-start trigger-end)))
        (snippet-end-session buffer)
        (auto-completion-cancel-timer)
        (lem/completion-mode:completion-end)
        (with-point ((start trigger-start :right-inserting)
                     (end trigger-end :left-inserting))
          (handler-case
              (progn
                (delete-between-points start end)
                (move-point (buffer-point buffer) start)
                (insert-string (buffer-point buffer)
                               (snippet-rendering-text rendering))
                (with-point ((root-end (buffer-point buffer) :left-inserting))
                  (let ((root-overlay
                          (make-overlay start root-end
                                        'snippet-inactive-field)))
                    (multiple-value-bind (fields exit-overlay)
                        (snippet-make-fields
                         (overlay-start root-overlay)
                         (snippet-rendering-occurrences rendering))
                      (unless exit-overlay
                        (setf exit-overlay
                              (make-overlay
                               (overlay-end root-overlay)
                               (overlay-end root-overlay)
                               'snippet-inactive-field)))
                      (let ((session
                              (make-snippet-session
                               :buffer buffer
                               :template template
                               :root-overlay root-overlay
                               :fields fields
                               :exit-overlay exit-overlay
                               :current-index nil
                               :pending-field-edit-p nil
                               :defer-zero-exit-p nil)))
                        (setf (buffer-value buffer :lem-yath-snippet-session)
                              session)
                        (add-hook
                         (variable-value 'before-change-functions
                                         :buffer buffer)
                         'snippet-before-change)
                        (add-hook
                         (variable-value 'after-change-functions
                                         :buffer buffer)
                         'snippet-after-change)
                        (let ((indent-points
                                (and
                                 (snippet-template-fixed-indent-p template)
                                 (snippet-make-indent-marker-points
                                  (overlay-start root-overlay)
                                  (snippet-rendering-indent-offsets
                                   rendering)))))
                          (unwind-protect
                               (progn
                                 (snippet-sync-mirrors session)
                                 (let ((*snippet-editing* t))
                                   (cond
                                     ((snippet-template-fixed-indent-p
                                       template)
                                      (snippet-indent-marker-points
                                       indent-points)
                                      (snippet-indent-fixed root-overlay
                                                            original-column))
                                     ((string=
                                       (snippet-template-table template)
                                       "bibtex-mode")
                                      nil)
                                     (t
                                      (snippet-indent-auto
                                       root-overlay
                                       (snippet-template-auto-indent-first-line-p
                                        template))))))
                            (dolist (point indent-points)
                              (ignore-errors (delete-point point)))))
                        (if fields
                            (snippet-activate-index session 0)
                            (snippet-finish-at-exit session)))))))
            (error (condition)
              ;; Preserve the user's trigger if a runtime/editor primitive
              ;; fails after mutation has begun.  Consume this Tab rather
              ;; than also invoking the underlying indentation command.
              (snippet-end-session buffer)
              (let ((*snippet-editing* t))
                (delete-between-points start end)
                (move-point (buffer-point buffer) start)
                (insert-string (buffer-point buffer) original-text))
              (message "Cannot expand snippet ~a: ~a"
                       (snippet-template-name template) condition))))
        t)
    (error (condition)
      (message "Cannot expand snippet ~a: ~a"
               (snippet-template-name template) condition)
      t)))

(defun snippet-expand-at-point ()
  (multiple-value-bind (templates start end)
      (snippet-trigger-match)
    (when templates
      (let ((template (snippet-select-template templates)))
        (cond
          ((eq template :unsupported) t)
          (template (snippet-expand-template template start end))
          (t nil))))))

;;; Conditional keymap -------------------------------------------------------

(defun snippet-mode-present-p (&optional (buffer (current-buffer)))
  (member 'lem-yath-snippet-mode (buffer-minor-modes buffer)))

(defun snippet-restore-mode-at-low-priority (buffer)
  (when (and (snippet-buffer-eligible-p buffer)
             (not (member 'lem-yath-snippet-mode
                          (buffer-minor-modes buffer))))
    (setf (buffer-minor-modes buffer)
          (append (buffer-minor-modes buffer)
                  (list 'lem-yath-snippet-mode)))))

(defun snippet-execute-underlying-key (keyspec)
  "Execute KEYSPEC with the conditional snippet minor map absent."
  (let* ((buffer (current-buffer))
         (had-mode (snippet-mode-present-p buffer))
         (command nil))
    (when had-mode
      (setf (buffer-minor-modes buffer)
            (remove 'lem-yath-snippet-mode (buffer-minor-modes buffer))))
    (unwind-protect
         (let ((prefix (lem-core::lookup-keybind
                        (lem-core::parse-keyspec keyspec))))
           (setf command (and prefix (lem-core::prefix-suffix prefix)))
           (when (and command (not (typep command 'keymap)))
             (execute
              (lem-core::get-active-modes-class-instance buffer)
              (lem/common/command:ensure-command command)
              (universal-argument-of-this-command))))
      (when had-mode
        (if (snippet-buffer-eligible-p buffer)
            (snippet-restore-mode-at-low-priority buffer)
            (snippet-end-session buffer))))
    command))

(define-command lem-yath-snippet-tab () ()
  "Advance a field, expand a trigger, or run the underlying Tab binding."
  (cond
    ((snippet-active-session-p) (snippet-move-field 1))
    ((and (snippet-buffer-eligible-p) (snippet-expand-at-point)))
    (t (snippet-execute-underlying-key "Tab"))))

(define-command lem-yath-snippet-next-field () ()
  "Move to the next active snippet field or its final exit point."
  (if (snippet-active-session-p)
      (snippet-move-field 1)
      (snippet-execute-underlying-key "Tab")))

(define-command lem-yath-snippet-prev-field () ()
  "Move to the previous active snippet field, or exit from the first."
  (if (snippet-active-session-p)
      (snippet-move-field -1)
      (snippet-execute-underlying-key "Shift-Tab")))

(define-command lem-yath-snippet-abort () ()
  "End the current snippet session without deleting its text."
  (if (snippet-end-session)
      (message "Snippet aborted")
      (snippet-execute-underlying-key "C-g")))

(define-command lem-yath-snippet-delete-previous-char () ()
  "Clear a pristine placeholder, otherwise run ordinary Backspace."
  (alexandria:if-let ((session (snippet-active-session)))
    (let ((field (snippet-current-field session)))
      (if (and field
               (not (snippet-field-modified-p field))
               (point= (current-point)
                       (overlay-start (snippet-field-overlay field))))
          (progn
            (snippet-clear-field-default session field (current-point))
            (snippet-sync-mirrors session))
          (snippet-execute-underlying-key "Backspace")))
    (snippet-execute-underlying-key "Backspace")))

(define-command lem-yath-snippet-skip-and-clear () ()
  "Clear an untouched field at its start and advance, like Yasnippet C-d."
  (alexandria:if-let ((session (snippet-active-session)))
    (let ((field (snippet-current-field session)))
      (if (and field
               (not (snippet-field-modified-p field))
               (point= (current-point)
                       (overlay-start (snippet-field-overlay field))))
          (progn
            (snippet-clear-field-default session field (current-point))
            (snippet-sync-mirrors session)
            (snippet-move-field 1))
          (snippet-execute-underlying-key "C-d")))
    (snippet-execute-underlying-key "C-d")))

(define-key *snippet-mode-keymap* "Tab" 'lem-yath-snippet-tab)
(define-key *snippet-mode-keymap* "Shift-Tab" 'lem-yath-snippet-prev-field)
(define-key *snippet-mode-keymap* "C-g" 'lem-yath-snippet-abort)
(define-key *snippet-mode-keymap* "C-d" 'lem-yath-snippet-skip-and-clear)
(define-key *snippet-mode-keymap* 'delete-previous-char
  'lem-yath-snippet-delete-previous-char)

;;; Completion precedence ----------------------------------------------------

(defmethod execute :around
    (mode
     (command
       lem/completion-mode::completion-narrowing-down-or-next-line)
     argument)
  (declare (ignore mode command argument))
  (if (snippet-active-session-p)
      (snippet-move-field 1)
      (call-next-method)))

(defun snippet-shift-tab-command-p ()
  (some (lambda (key)
          (match-key key :shift t :sym "Tab"))
        (this-command-keys)))

(defmethod execute :around
    (mode (command lem/completion-mode::completion-previous-line) argument)
  (declare (ignore mode command argument))
  (if (and (snippet-active-session-p)
           (snippet-shift-tab-command-p))
      (snippet-move-field -1)
      (call-next-method)))

;;; Global activation and cleanup -------------------------------------------

(defun snippet-buffer-eligible-p (&optional (buffer (current-buffer)))
  (and (not (buffer-temporary-p buffer))
       (buffer-enable-undo-p buffer)
       (not (buffer-read-only-p buffer))))

(defun snippet-hook-installed-p (variable callback buffer)
  (member callback
          (variable-value variable :buffer buffer)
          :key (lambda (entry) (if (consp entry) (car entry) entry))))

(defun snippet-overlay-live-in-buffer-p (overlay buffer)
  (and overlay
       (lem-core::overlay-alive-p overlay)
       (eq buffer (overlay-buffer overlay))))

(defun snippet-field-overlays-live-p (field buffer)
  (and (snippet-overlay-live-in-buffer-p
        (snippet-field-overlay field) buffer)
       (every (lambda (overlay)
                (snippet-overlay-live-in-buffer-p overlay buffer))
              (snippet-field-mirrors field))))

(defun snippet-session-valid-p (session buffer)
  (and (eq buffer (snippet-session-buffer session))
       (snippet-buffer-eligible-p buffer)
       (snippet-mode-present-p buffer)
       (not (snippet-session-pending-field-edit-p session))
       (snippet-hook-installed-p
        'before-change-functions 'snippet-before-change buffer)
       (snippet-hook-installed-p
        'after-change-functions 'snippet-after-change buffer)
       (snippet-overlay-live-in-buffer-p
        (snippet-session-root-overlay session) buffer)
       (snippet-overlay-live-in-buffer-p
        (snippet-session-exit-overlay session) buffer)
       (every (lambda (field)
                (snippet-field-overlays-live-p field buffer))
              (snippet-session-fields session))))

(defun snippet-ensure-session-valid (&optional (buffer (current-buffer)))
  (alexandria:when-let ((session (snippet-active-session buffer)))
    (unless (snippet-session-valid-p session buffer)
      (snippet-end-session buffer))))

(defun snippet-enable-buffer (buffer)
  (with-current-buffer buffer
    (when (snippet-buffer-eligible-p buffer)
      (unless (snippet-mode-present-p buffer)
        (lem-yath-snippet-mode t))
      ;; Keep completion and structural minor maps ahead of the conditional
      ;; trigger map; an active session is promoted by the execute methods.
      (setf (buffer-minor-modes buffer)
            (append (remove 'lem-yath-snippet-mode
                            (buffer-minor-modes buffer))
                    (list 'lem-yath-snippet-mode)))
      (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                'snippet-kill-buffer))))

(defun snippet-kill-buffer (&optional buffer)
  (snippet-end-session (or buffer (current-buffer))))

(defun snippet-undo-command-p ()
  (member (symbol-name (command-name (this-command)))
          '("UNDO" "REDO" "VI-UNDO" "VI-REDO")
          :test #'string=))

(defun snippet-major-mode-command-p ()
  (member (command-name (this-command)) (major-modes)))

(defun snippet-pre-command ()
  ;; Undo/redo replays every recorded primary and mirror edit.  Tear down
  ;; derived overlays first so the inverse edits cannot recursively mirror.
  (snippet-ensure-session-valid)
  (when (and (snippet-active-session-p)
             (or (snippet-undo-command-p)
                 (snippet-major-mode-command-p)))
    (snippet-end-session)))

(defun snippet-post-command ()
  ;; Major-mode activation clears buffer-local minor modes.  Reapply the
  ;; configured global behavior after the command has finished, and withdraw
  ;; it if a buffer became temporary or read-only.
  (let ((buffer (current-buffer)))
    (snippet-ensure-session-valid buffer)
    (alexandria:when-let* ((session (snippet-active-session buffer))
                           (field (snippet-current-field session)))
      (unless (snippet-point-within-overlay-p
               (buffer-point buffer) (snippet-field-overlay field))
        (snippet-end-session buffer))
      (when (and (snippet-active-session buffer)
                 (eql (snippet-field-number field) 0))
        ;; Yas force-exits after selecting field zero.  Lem has no generic
        ;; delete-selection self-insert, so grant one command of replacement
        ;; semantics and then commit automatically.
        (if (snippet-session-defer-zero-exit-p session)
            (setf (snippet-session-defer-zero-exit-p session) nil)
            (snippet-end-session buffer))))
    (if (snippet-buffer-eligible-p buffer)
        ;; Mode changes clear editor-local hooks but leave the minor-mode slot.
        ;; Reinstall both the mode ordering and cleanup hook idempotently.
        (snippet-enable-buffer buffer)
        (progn
          (snippet-end-session buffer)
          (when (snippet-mode-present-p buffer)
            (lem-yath-snippet-mode nil))))))

(add-hook *find-file-hook* 'snippet-enable-buffer)
(add-hook *switch-to-buffer-hook* 'snippet-enable-buffer)
(add-hook *pre-command-hook* 'snippet-pre-command)
(add-hook *post-command-hook* 'snippet-post-command -200)

(dolist (buffer (buffer-list))
  (snippet-enable-buffer buffer))
