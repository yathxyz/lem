;;;; Yasnippet-compatible snippet sessions.
;;;;
;;;; The configured Emacs loads one private snippet directory followed by the
;;;; pinned yasnippet-snippets collection.  Lem has no native snippet engine,
;;;; so this module implements its portable file format plus a bounded,
;;;; non-evaluating translation of the pure dynamic forms used by that pinned
;;;; collection.  Arbitrary Emacs Lisp is deliberately never evaluated.

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
(defvar *snippet-time-function* #'get-universal-time)
(defparameter *snippet-revival-state-limit* 16)
(defparameter *snippet-revival-character-limit* (* 1024 1024))

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
  evaluation-policy
  condition-policy
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
  placeholder-p
  transform-kind)

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
  mirror-transforms
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

(defstruct snippet-mirror-revival
  start
  end
  transform-kind)

(defstruct snippet-field-revival
  id
  number
  parent-id
  container-ids
  sequence
  start
  end
  mirrors
  modified-p
  disabled-p)

(defstruct snippet-revival
  buffer
  template
  undo-table
  undo-node-id
  root-start
  root-text
  fields
  exit-start
  exit-end
  current-index
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
  (let* ((point (current-point))
         (templates
           (remove-if-not
            (lambda (template)
              (and (snippet-template-supported-p template)
                   (snippet-condition-allows-p template point)))
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

(defun snippet-canonical-elisp (source)
  "Return SOURCE without insignificant whitespace outside string literals."
  (with-output-to-string (output)
    (loop :with quoted-p = nil
          :with escaped-p = nil
          :for character :across source
          :do (cond
                (escaped-p
                 (write-char character output)
                 (setf escaped-p nil))
                ((and quoted-p (char= character #\\))
                 (write-char character output)
                 (setf escaped-p t))
                ((char= character #\")
                 (write-char character output)
                 (setf quoted-p (not quoted-p)))
                ((and (not quoted-p)
                      (find character '(#\Space #\Tab #\Newline #\Return)
                            :test #'char=)))
                (t (write-char character output))))))

(defparameter *snippet-safe-backquote-forms*
  '((("(format-time-string\"%Y\")") . :year)
    (("(format-time-string\"%Y-%m-%d\")") . :date)
    (("(format-time-string\"%Y-%m-%dT%H:%M:%S%:z\")") . :timestamp)
    (("(user-full-name)" "user-full-name") . :user-full-name)
    (("(yas-jsx-get-class-name-by-file-name)") . :jsx-class-name)
    (("(yas-php-get-class-name-by-file-name)") . :file-stem)
    (("(file-name-nondirectory(file-name-sans-extension(buffer-file-name)))")
     . :file-stem)
    (("(file-name-nondirectory(file-name-sans-extension(or(buffer-file-name)(buffer-name))))"
      "(file-name-base(or(buffer-file-name)(buffer-name)))")
     . :file-stem-or-buffer)
    (("(file-name-nondirectory(buffer-file-name))") . :file-name)
    (("(file-name-base(orbuffer-file-name(buffer-name)))")
     . :file-stem-or-buffer)
    (("(concat(capitalize(file-name-nondirectory(directory-file-name(file-name-directorybuffer-file-name))))\".\")")
     . :elixir-directory-prefix)
    (("(mapconcat'capitalize(split-string(file-name-base)\"_\")\"\")")
     . :elixir-file-class)
    (("(upcase(replace-regexp-in-string\"[^A-Za-z0-9_]\"\"_\"(file-name-nondirectory(or(buffer-file-name)))))")
     . :include-guard)
    (("comment-start") . :comment-start)
    (("comment-end") . :comment-end)
    (("(yas-trimmed-comment-start)" "(yas-trimmed-add-comment)")
     . :trimmed-comment-start)
    (("(unless(eq(lengthcomment-end)0)(concat\" \"(yas-trimmed-comment-end)))")
     . :optional-comment-end)
    (("yas/selected-text") . :selected-text)
    (("(oryas/selected-text(carkill-ring))") . :selected-or-kill)
    (("(org-id-uuid)") . :uuid)
    (("(if(eq(point)(line-end-position))\";\"\"\")") . :line-end-semicolon)
    (("(progn(goto-char(point-min))(unless(re-search-forward\"^using\\\\s-+namespace std;\"nil'no-error)\"std::\"))"
      "(progn(goto-char(point-min))(unless(re-search-forward\"^using\\\\s-+namespace std;\"nil'no-errer)\"std::\"))")
     . :cxx-std-prefix)
    (("(let((fn(capitalize(file-name-nondirectory(file-name-sans-extension(or(buffer-file-name)(buffer-name(current-buffer))))))))(replace-regexp-in-string\"_\"\"\"fntt))")
     . :capitalized-file-stem)
    (("(let((fn(capitalize(file-name-nondirectory(file-name-sans-extension(or(buffer-file-name)(buffer-name(current-buffer))))))))(while(string-match\"_\"fn)(setqfn(replace-match\"\"nilnilfn)))fn)")
     . :capitalized-file-stem)
    (("(cl-flet((try-src-prefix(pathsrc-pfx)(let((parts(split-stringpathsrc-pfx)))(if(=2(lengthparts))(cl-secondparts)nil))))(let*((p(buffer-file-name))(p2(cl-first(cl-remove-if-not(lambda(x)x)(mapcar(lambda(pfx)(try-src-prefixppfx))'(\"/src/cljs/\"\"/src/clj/\"\"/src/\"\"/test/\")))))(p3(file-name-sans-extensionp2))(p4(mapconcat(lambda(x)x)(split-stringp3\"/\")\".\")))(replace-regexp-in-string\"_\"\"-\"p4)))")
     . :clojure-namespace))
  "Canonical forms translated without invoking an Emacs Lisp evaluator.")

(defun snippet-safe-backquote-kind (expression)
  (let ((canonical (snippet-canonical-elisp expression)))
    (loop :for (forms . kind) :in *snippet-safe-backquote-forms*
          :when (member canonical forms :test #'string=)
            :return kind)))

(defparameter *snippet-safe-transform-forms*
  '((("(upcaseyas-text)") . :upcase)
    (("(downcaseyas-text)") . :downcase)
    (("(upcase-initialsyas-text)") . :upcase-initials)
    (("(yas/substryas-text\"[^: ]*\")"
      "(yas-c++-class-nameyas-text)") . :before-colon)
    (("(make-string(string-widthyas-text)?\\=)") . :underline-equals)
    (("(make-string(string-widthyas-text)?\\-)") . :underline-hyphens)
    (("(number-to-string(1+(string-to-numberyas-text)))") . :increment)
    (("((yas-snake-caseyas-text))") . :snake-upcase)
    (("(yas-text)") . :identity)
    (("(replace-regexp-in-string\"  *\"\" \"(subst-char-in-string?,? yas-text))")
     . :comma-list)
    (("(if(>(lengthyas-text)0)(format\"_%s%s\"(downcase(substringyas-text01))(substringyas-text1(lengthyas-text)))\"\")")
     . :private-field)
    (("(if(string=(upcaseyas-text)\"VOID\")\"\"(format\"%s%s%s\"\"\\n/// <returns><c>\"yas-text\"</c></returns>\"))")
     . :csharp-return-doc)
    (("(if(string-match\"%\"yas-text)\", \"\"\\);\")")
     . :printf-middle)
    (("(if(string-match\"%\"yas-text)\"\\);\"\"\")")
     . :printf-end)
    (("(if(string-match\"\\{\"yas-text)\"\\}\"\"\")")
     . :close-brace))
  "Pure mirror transforms implemented without evaluating snippet code.")

(defun snippet-safe-transform-kind (expression)
  (let ((canonical (snippet-canonical-elisp expression)))
    (loop :for (forms . kind) :in *snippet-safe-transform-forms*
          :when (member canonical forms :test #'string=)
            :return kind)))

(defun snippet-transform-expression-at (source index)
  "Return an expression and end offset for `$...(' syntax at INDEX."
  (let ((cursor index)
        (length (length source)))
    (unless (and (< cursor length) (char= (char source cursor) #\$))
      (return-from snippet-transform-expression-at (values nil nil)))
    (loop :while (and (< cursor length)
                      (char= (char source cursor) #\$))
          :do (incf cursor))
    (loop :while (and (< cursor length)
                      (find (char source cursor)
                            '(#\Space #\Tab #\Newline #\Return)
                            :test #'char=))
          :do (incf cursor))
    (unless (and (< cursor length) (char= (char source cursor) #\())
      (return-from snippet-transform-expression-at (values nil nil)))
    (let ((start cursor)
          (depth 0)
          (quoted-p nil)
          (escaped-p nil))
      (loop :while (< cursor length)
            :for character = (char source cursor)
            :do (cond
                  (escaped-p (setf escaped-p nil))
                  ((and quoted-p (char= character #\\))
                   (setf escaped-p t))
                  ((char= character #\")
                   (setf quoted-p (not quoted-p)))
                  ((not quoted-p)
                   (cond ((char= character #\() (incf depth))
                         ((char= character #\))
                          (decf depth)
                          (when (zerop depth)
                            (return-from snippet-transform-expression-at
                              (values (subseq source start (1+ cursor))
                                      (1+ cursor))))))))
            :do (incf cursor))
      (values nil nil))))

(defun snippet-pure-transform-at (source index)
  "Return a safe transform kind and offset after its field-closing brace."
  (multiple-value-bind (expression after-expression)
      (snippet-transform-expression-at source index)
    (when expression
      (let ((cursor after-expression))
        (loop :while (and (< cursor (length source))
                          (find (char source cursor)
                                '(#\Space #\Tab #\Newline #\Return)
                                :test #'char=))
              :do (incf cursor))
        (when (and (< cursor (length source))
                   (char= (char source cursor) #\}))
          (values (snippet-safe-transform-kind expression) (1+ cursor)))))))

(defun snippet-safe-transform-reason (body)
  (loop :with field-depth = 0
        :with index = 0
        :while (< index (length body))
        :for character = (char body index)
        :for unescaped-p = (snippet-unescaped-p body index)
        :do (cond
              ((and unescaped-p
                    (plusp field-depth)
                    (snippet-transform-start-p body index))
               (multiple-value-bind (kind after-field)
                   (snippet-pure-transform-at body index)
                 (let ((before index))
                   (loop :while (and (plusp before)
                                     (find (char body (1- before))
                                           '(#\Space #\Tab #\Newline #\Return)
                                           :test #'char=))
                         :do (decf before))
                   (unless (and kind after-field (plusp before)
                                (char= (char body (1- before)) #\:))
                     (return "an unsupported field transform"))
                   (setf index after-field)
                   (decf field-depth))))
              ((and unescaped-p
                    (char= character #\$)
                    (< (1+ index) (length body))
                    (char= (char body (1+ index)) #\{))
               (incf field-depth)
               (incf index))
              ((and unescaped-p (char= character #\}) (plusp field-depth))
               (decf field-depth)
               (incf index))
              (t (incf index)))))

(defun snippet-upcase-initials (string)
  (let ((result (copy-seq string))
        (word-start-p t))
    (loop :for index :below (length result)
          :for character = (char result index)
          :do (cond
                ((alphanumericp character)
                 (when word-start-p
                   (setf (char result index) (char-upcase character)))
                 (setf word-start-p nil))
                (t (setf word-start-p t))))
    result))

(defun snippet-apply-transform (kind text)
  (case kind
    (:upcase (string-upcase text))
    (:downcase (string-downcase text))
    (:upcase-initials (snippet-upcase-initials text))
    (:before-colon
     (subseq text 0 (or (position-if (lambda (character)
                                      (find character '(#\: #\Space)
                                            :test #'char=))
                                    text)
                        (length text))))
    (:underline-equals
     (make-string (lem/common/character:string-width text)
                  :initial-element #\=))
    (:underline-hyphens
     (make-string (lem/common/character:string-width text)
                  :initial-element #\-))
    (:increment
     (write-to-string
      (1+ (or (parse-integer text :junk-allowed t) 0))))
    (:snake-upcase
     (format nil "~{~a~^_~}"
             (mapcar #'string-upcase
                     (remove-if (lambda (part) (zerop (length part)))
                                (cl-ppcre:split "[^[:alnum:]_]+" text)))))
    (:identity text)
    (:comma-list
     (string-trim '(#\Space #\Tab #\Newline #\Return)
                  (cl-ppcre:regex-replace-all
                   "[ ]+" (substitute #\Space #\, text) " ")))
    (:private-field
     (if (zerop (length text)) ""
         (concatenate 'string "_"
                      (string-downcase (subseq text 0 1))
                      (subseq text 1))))
    (:csharp-return-doc
     (if (string= (string-upcase text) "VOID") ""
         (format nil "~%/// <returns><c>~a</c></returns>" text)))
    (:printf-middle (if (find #\% text) ", " ");"))
    (:printf-end (if (find #\% text) ");" ""))
    (:close-brace (if (find #\{ text) "}" ""))
    (otherwise (error "Unsupported snippet field transform"))))

(defun snippet-map-backquotes (body function)
  "Replace every unescaped backquoted expression in BODY through FUNCTION."
  (with-output-to-string (output)
    (loop :with index = 0
          :with length = (length body)
          :while (< index length)
          :for character = (char body index)
          :do (if (and (char= character #\`)
                       (snippet-unescaped-p body index))
                  (let ((end
                          (loop :for scan-index :from (1+ index) :below length
                                :when (and (char= (char body scan-index) #\`)
                                           (snippet-unescaped-p body scan-index))
                                  :return scan-index)))
                    (unless end
                      (error "Unclosed backquoted snippet expression"))
                    (write-string
                     (funcall function (subseq body (1+ index) end)) output)
                    (setf index (1+ end)))
                  (progn
                    (write-char character output)
                    (incf index))))))

(defun snippet-safe-backquote-reason (body)
  (handler-case
      (progn
        (snippet-map-backquotes
         body
         (lambda (expression)
           (unless (snippet-safe-backquote-kind expression)
             (error "unsupported"))
           ""))
        nil)
    (error () "unsupported backquoted Emacs Lisp")))

(defun snippet-file-stem (name)
  (let* ((basename (file-namestring (pathname name)))
         (dot (position #\. basename :from-end t)))
    (if (and dot (plusp dot)) (subseq basename 0 dot) basename)))

(defun snippet-buffer-file-or-name (buffer)
  (or (buffer-filename buffer) (buffer-name buffer)))

(defun snippet-path-last-component (path)
  (let* ((trimmed (string-right-trim '(#\/ #\\) (namestring (pathname path))))
         (slash (position-if (lambda (character)
                               (find character '(#\/ #\\) :test #'char=))
                             trimmed :from-end t)))
    (subseq trimmed (if slash (1+ slash) 0))))

(defun snippet-comment-parts (buffer)
  (let* ((syntax-table (buffer-syntax-table buffer))
         (line
           (or (variable-value 'lem/language-mode:insertion-line-comment
                               :buffer buffer)
               (variable-value 'lem/language-mode:line-comment
                               :buffer buffer)))
         (block (and syntax-table
                     (first
                      (lem/buffer/syntax-table:syntax-table-block-comment-pairs
                       syntax-table)))))
    (values (or line (car block) "")
            (if line "" (or (cdr block) "")))))

(defun snippet-selected-text (buffer)
  (multiple-value-bind (start end) (action-region-bounds buffer)
    (and start (points-to-string start end))))

(defun snippet-latest-kill ()
  (ignore-errors
    (lem/common/killring:peek-killring-item (current-killring) 0)))

(defun snippet-user-full-name ()
  (let* ((passwd (ignore-errors
                   (completion-posix-call "GETPWUID" (sb-posix:getuid))))
         (gecos (and passwd
                     (ignore-errors
                       (completion-posix-call "PASSWD-GECOS" passwd))))
         (full-name (and (stringp gecos)
                         (first (uiop:split-string gecos :separator '(#\,))))))
    (or (and full-name (plusp (length full-name)) full-name)
        (uiop:getenv "NAME")
        (uiop:getenv "USER")
        "")))

(defun snippet-format-time (kind)
  (multiple-value-bind (second minute hour day month year weekday dst timezone)
      (decode-universal-time (funcall *snippet-time-function*))
    (declare (ignore weekday))
    (case kind
      (:year (format nil "~4,'0d" year))
      (:date (format nil "~4,'0d-~2,'0d-~2,'0d" year month day))
      (:timestamp
       (let* ((offset (+ (- timezone) (if dst 1 0)))
              (sign (if (minusp offset) #\- #\+))
              (minutes (round (* (abs offset) 60))))
         (multiple-value-bind (zone-hour zone-minute) (floor minutes 60)
           (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d~c~2,'0d:~2,'0d"
                   year month day hour minute second sign
                   zone-hour zone-minute)))))))

(defun snippet-uuid-v4 ()
  (let ((octets (loop :repeat 16 :collect (random 256))))
    (setf (nth 6 octets) (logior #x40 (logand #x0f (nth 6 octets)))
          (nth 8 octets) (logior #x80 (logand #x3f (nth 8 octets))))
    (string-downcase
     (format nil "~{~2,'0x~}~{-~{~2,'0x~}~}"
             (subseq octets 0 4)
             (list (subseq octets 4 6) (subseq octets 6 8)
                   (subseq octets 8 10) (subseq octets 10 16))))))

(defun snippet-cxx-std-prefix (buffer)
  (if (cl-ppcre:scan "(^|\\n)using[ \\t]+namespace[ \\t]+std;"
                     (points-to-string (buffer-start-point buffer)
                                       (buffer-end-point buffer)))
      ""
      "std::"))

(defun snippet-clojure-namespace (buffer)
  (let* ((filename (namestring (or (buffer-filename buffer)
                                   (error "A file is required"))))
         (prefixes '("/src/cljs/" "/src/clj/" "/src/" "/test/"))
         (relative
           (loop :for prefix :in prefixes
                 :for position = (search prefix filename)
                 :when position
                   :return (subseq filename (+ position (length prefix))))))
    (unless relative (error "The file is outside a source tree"))
    (let ((dot (position #\. relative :from-end t)))
      (substitute #\- #\_
                  (substitute #\. #\/
                              (if dot (subseq relative 0 dot) relative))))))

(defun snippet-evaluate-backquote (expression buffer point)
  (let* ((kind (or (snippet-safe-backquote-kind expression)
                   (error "Unsupported backquoted snippet expression")))
         (file (buffer-filename buffer))
         (fallback (snippet-buffer-file-or-name buffer))
         (value
           (case kind
             ((:year :date :timestamp) (snippet-format-time kind))
             (:user-full-name (snippet-user-full-name))
             (:file-stem (snippet-file-stem (or file (error "A file is required"))))
             (:file-stem-or-buffer (snippet-file-stem fallback))
             (:file-name (file-namestring (or file (error "A file is required"))))
             (:jsx-class-name
              (let ((stem (and file (snippet-file-stem file))))
                (cond ((null stem) "")
                      ((string= stem "index")
                       (snippet-path-last-component
                        (uiop:pathname-directory-pathname file)))
                      (t stem))))
             (:elixir-directory-prefix
              (format nil "~:(~a~)."
                      (snippet-path-last-component
                       (uiop:pathname-directory-pathname
                        (or file (error "A file is required"))))))
             (:elixir-file-class
              (format nil "~{~:(~a~)~}"
                      (uiop:split-string (snippet-file-stem fallback)
                                         :separator '(#\_))))
             (:include-guard
              (string-upcase
               (cl-ppcre:regex-replace-all
                "[^A-Za-z0-9_]" (file-namestring (or file (error "A file is required"))) "_")))
             (:comment-start
              (multiple-value-bind (start end) (snippet-comment-parts buffer)
                (declare (ignore end))
                (cond
                  ((zerop (length start)) "")
                  ((find (char start (1- (length start)))
                         '(#\Space #\Tab) :test #'char=)
                   start)
                  (t (concatenate 'string start " ")))))
             (:trimmed-comment-start
              (multiple-value-bind (start end) (snippet-comment-parts buffer)
                (declare (ignore end))
                (string-trim '(#\Space #\Tab #\Newline #\Return) start)))
             (:comment-end
              (multiple-value-bind (start end) (snippet-comment-parts buffer)
                (declare (ignore start)) end))
             (:optional-comment-end
              (multiple-value-bind (start end) (snippet-comment-parts buffer)
                (declare (ignore start))
                (if (zerop (length end)) ""
                    (concatenate 'string " "
                                 (string-trim '(#\Space #\Tab #\Newline #\Return)
                                              end)))))
             (:selected-text (or (snippet-selected-text buffer) ""))
             (:selected-or-kill
              (or (snippet-selected-text buffer) (snippet-latest-kill) ""))
             (:uuid (snippet-uuid-v4))
             (:line-end-semicolon
              (with-point ((line-end point))
                (line-end line-end)
                (if (point= point line-end) ";" "")))
             (:cxx-std-prefix (snippet-cxx-std-prefix buffer))
             (:capitalized-file-stem
              (remove #\_ (string-capitalize (snippet-file-stem fallback))))
             (:clojure-namespace (snippet-clojure-namespace buffer))
             (otherwise (error "Unsupported safe snippet expression")))))
    (unless (and (stringp value) (<= (length value) (* 1024 1024)))
      (error "Unsafe snippet expression result"))
    value))

(defun snippet-escape-render-literal (string)
  (with-output-to-string (output)
    (loop :for character :across string
          :when (find character '(#\\ #\$ #\`) :test #'char=)
            :do (write-char #\\ output)
          :do (write-char character output))))

(defun snippet-expand-safe-backquotes (body buffer point)
  (snippet-map-backquotes
   body
   (lambda (expression)
     (snippet-escape-render-literal
      (snippet-evaluate-backquote expression buffer point)))))

(defun snippet-executable-body-reason (body)
  (or (snippet-safe-transform-reason body)
      (snippet-safe-backquote-reason body)))

(defun snippet-condition-policy (condition)
  "Classify CONDITION without reading or evaluating it."
  (let ((canonical (and condition (snippet-canonical-elisp condition))))
    (cond
      ((or (null canonical) (string-equal canonical "t"))
       (values t nil))
      ((string= canonical "(not(membermajor-mode'(sh-modebash-ts-mode)))")
       (values t :not-shell))
      ((string= canonical
                "(progn(forward-line0)(not(and(eq(point-min)(point))(looking-at-p\"package\"))))")
       (values t :go-main))
      ((string= canonical
                "(=(js2-node-type(js2-node-at-point))js2-COMMENT)")
       (values t :in-comment))
      ((string= canonical
                "(not(=(js2-node-type(js2-node-at-point))js2-COMMENT))")
       (values t :outside-comment))
      (t (values nil nil)))))

(defun snippet-condition-allows-p (template point)
  (case (snippet-template-condition-policy template)
    (:not-shell
     (not (eq (buffer-major-mode (point-buffer point))
              'lem-posix-shell-mode:posix-shell-mode)))
    (:go-main
     (with-point ((line point))
       (line-start line)
       (not (and (point= line (buffer-start-point (point-buffer line)))
                 (alexandria:starts-with-subseq "package" (line-string line))))))
    (:in-comment (in-comment-p point))
    (:outside-comment (not (in-comment-p point)))
    (otherwise t)))

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
              (multiple-value-bind (condition-supported-p condition-policy)
                  (snippet-condition-policy condition)
                (let* ((key (if (or key binding)
                                key
                                (file-namestring pathname)))
                       (body-reason (snippet-executable-body-reason body))
                       (reason
                         (cond
                           ((not condition-supported-p)
                            "an unsupported # condition")
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
                   :evaluation-policy :safe-yasnippet
                   :condition-policy condition-policy
                   :supported-p (null reason)
                   :unsupported-reason reason
                   :fixed-indent-p fixed-indent-p
                   :auto-indent-first-line-p
                   auto-indent-first-line-p)))))))
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

(defun snippet-render-template
    (template &optional (buffer (current-buffer)) (point (buffer-point buffer)))
  "Render TEMPLATE to plain text and position records.

Only trusted file templates may use the bounded Yasnippet translation layer."
  (let* ((source
           (if (eq (snippet-template-evaluation-policy template)
                   :safe-yasnippet)
               (snippet-expand-safe-backquotes
                (snippet-template-body template) buffer point)
               (snippet-template-body template)))
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
                                 (multiple-value-bind (transform-kind
                                                       after-transform)
                                     (snippet-pure-transform-at
                                      source (1+ after-number))
                                   (if transform-kind
                                       (let ((position (output-position))
                                             (sequence (next-sequence)))
                                         (push
                                          (make-snippet-occurrence
                                           :id (simple-id sequence)
                                           :number number
                                           :parent-id parent-id
                                           :sequence sequence
                                           :start position :end position
                                           :placeholder-p nil
                                           :transform-kind transform-kind)
                                          occurrences)
                                         (setf index after-transform))
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
                                               occurrences))))))
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
                  :for mirror-occurrences =
                    (remove primary group :test #'eq)
                  :for mirrors =
                    (mapcar (lambda (occurrence)
                              (snippet-occurrence-overlay
                               root-start occurrence))
                            mirror-occurrences)
                  :for mirror-transforms =
                    (loop :for occurrence :in mirror-occurrences
                          :for overlay :in mirrors
                          :when (snippet-occurrence-transform-kind occurrence)
                            :collect
                            (cons overlay
                                  (snippet-occurrence-transform-kind occurrence)))
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
                     :mirror-transforms mirror-transforms
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
                           (let ((transform
                                   (cdr (assoc
                                         mirror
                                         (snippet-field-mirror-transforms field)
                                         :test #'eq))))
                             (snippet-replace-overlay-string
                              mirror
                              (if transform
                                  (snippet-apply-transform transform text)
                                  text))))))
                     (setf (gethash id done) t))))))
      (dolist (field fields)
        (sync-field field)))))

(defun snippet-delete-field-overlays (field)
  (delete-overlay (snippet-field-overlay field))
  (dolist (mirror (snippet-field-mirrors field))
    (delete-overlay mirror)))

(defun snippet-current-undo-node (&optional (buffer (current-buffer)))
  (ignore-errors (buffer-undo-tree-current buffer)))

(defun snippet-current-undo-identity (&optional (buffer (current-buffer)))
  (let ((node (snippet-current-undo-node buffer)))
    (when node
      (values (lem/buffer/internal::buffer-%undo-tree-table buffer)
              (buffer-undo-tree-node-id node)))))

(defun snippet-prune-revivals (&optional (buffer (current-buffer)))
  "Release snapshots whose undo tree or retained node no longer exists."
  (let ((table (lem/buffer/internal::buffer-%undo-tree-table buffer)))
    (setf (buffer-value buffer :lem-yath-snippet-revivals)
          (remove-if-not
           (lambda (revival)
             (and (eq table (snippet-revival-undo-table revival))
                  (gethash (snippet-revival-undo-node-id revival) table)))
           (buffer-value buffer :lem-yath-snippet-revivals)))))

(defun snippet-overlay-relative-bounds (overlay root-position)
  (values (- (position-at-point (overlay-start overlay)) root-position)
          (- (position-at-point (overlay-end overlay)) root-position)))

(defun snippet-capture-field-revival (field root-position)
  (multiple-value-bind (start end)
      (snippet-overlay-relative-bounds
       (snippet-field-overlay field) root-position)
    (make-snippet-field-revival
     :id (snippet-field-id field)
     :number (snippet-field-number field)
     :parent-id (snippet-field-parent-id field)
     :container-ids (copy-list (snippet-field-container-ids field))
     :sequence (snippet-field-sequence field)
     :start start
     :end end
     :mirrors
     (loop :for mirror :in (snippet-field-mirrors field)
           :collect
           (multiple-value-bind (mirror-start mirror-end)
               (snippet-overlay-relative-bounds mirror root-position)
             (make-snippet-mirror-revival
              :start mirror-start
              :end mirror-end
              :transform-kind
              (cdr (assoc mirror
                          (snippet-field-mirror-transforms field)
                          :test #'eq)))))
     :modified-p (snippet-field-modified-p field)
     :disabled-p (snippet-field-disabled-p field))))

(defun snippet-capture-revival (session undo-table undo-node-id)
  "Capture SESSION's overlay geometry for one bounded undo-tree state."
  (let* ((root (snippet-session-root-overlay session))
         (root-position (position-at-point (overlay-start root)))
         (root-length
           (- (position-at-point (overlay-end root)) root-position))
         (exit (snippet-session-exit-overlay session)))
    (when (<= root-length *snippet-revival-character-limit*)
      (multiple-value-bind (exit-start exit-end)
          (snippet-overlay-relative-bounds exit root-position)
        (make-snippet-revival
         :buffer (snippet-session-buffer session)
         :template (snippet-session-template session)
         :undo-table undo-table
         :undo-node-id undo-node-id
         :root-start root-position
         :root-text (snippet-overlay-string root)
         :fields
         (mapcar (lambda (field)
                   (snippet-capture-field-revival field root-position))
                 (snippet-session-fields session))
         :exit-start exit-start
         :exit-end exit-end
         :current-index (snippet-session-current-index session)
         :defer-zero-exit-p
         (snippet-session-defer-zero-exit-p session))))))

(defun snippet-store-current-revival (session)
  "Remember SESSION's current state under its stable undo-tree node."
  (let ((buffer (snippet-session-buffer session)))
    (multiple-value-bind (undo-table undo-node-id)
        (snippet-current-undo-identity buffer)
      (let ((revival
              (and undo-table
                   undo-node-id
                   (snippet-capture-revival
                    session undo-table undo-node-id))))
        (when revival
          (let ((states
                  (remove-if
                   (lambda (candidate)
                     (and (eq undo-table
                              (snippet-revival-undo-table candidate))
                          (= undo-node-id
                             (snippet-revival-undo-node-id candidate))))
                   (buffer-value buffer :lem-yath-snippet-revivals))))
            (setf (buffer-value buffer :lem-yath-snippet-revivals)
                  (subseq (cons revival states)
                          0 (min *snippet-revival-state-limit*
                                 (1+ (length states)))))))
        revival))))

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
                                         (snippet-template-key template))
                                (snippet-condition-allows-p template point)))
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

(defun snippet-install-rendering (template rendering trigger-start trigger-end)
  "Install a precomputed RENDERING over TRIGGER-START..TRIGGER-END.

Return true only when the replacement and field session are installed
successfully.  On an editor failure after replacement begins, restore the
original text and return NIL."
  (handler-case
      (let* ((buffer (point-buffer trigger-start))
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
                        (setf (buffer-value buffer :lem-yath-snippet-revivals)
                              nil)
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
                            (snippet-finish-at-exit session))
                        t)))))
            (error (condition)
              ;; Preserve the user's trigger if a runtime/editor primitive
              ;; fails after mutation has begun.
              (snippet-end-session buffer)
              (let ((*snippet-editing* t))
                (delete-between-points start end)
                (move-point (buffer-point buffer) start)
                (insert-string (buffer-point buffer) original-text))
              (message "Cannot expand snippet ~a: ~a"
                       (snippet-template-name template) condition)
              nil))))
    (error (condition)
      (message "Cannot expand snippet ~a: ~a"
               (snippet-template-name template) condition)
      nil)))

(defun snippet-expand-template (template trigger-start trigger-end)
  "Render and expand TEMPLATE while consuming its matched trigger.

Once a trigger has selected TEMPLATE, return true even when rendering or
installation fails.  This retains the ordinary snippet command's contract:
Tab reports the failure without also invoking its fallback indentation."
  (handler-case
      (progn
        (snippet-install-rendering
         template
         (snippet-render-template template
                                  (point-buffer trigger-end)
                                  trigger-end)
         trigger-start
         trigger-end)
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

(defmethod execute :around
    (mode (command lem-yath-completion-tab) argument)
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
      (setf (buffer-value buffer :lem-yath-snippet-revivals) nil)
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

(defun snippet-revival-offset-valid-p (start end root-length)
  (and (integerp start)
       (integerp end)
       (<= 0 start end root-length)))

(defun snippet-revival-valid-p (revival buffer)
  (and (eq buffer (snippet-revival-buffer revival))
       (multiple-value-bind (undo-table undo-node-id)
           (snippet-current-undo-identity buffer)
         (and (eq undo-table (snippet-revival-undo-table revival))
              (eql undo-node-id (snippet-revival-undo-node-id revival))))
       (let ((root-length (length (snippet-revival-root-text revival))))
         (and
          (snippet-revival-offset-valid-p
           (snippet-revival-exit-start revival)
           (snippet-revival-exit-end revival)
           root-length)
          (every
           (lambda (field)
             (and
              (snippet-revival-offset-valid-p
               (snippet-field-revival-start field)
               (snippet-field-revival-end field)
               root-length)
              (every
               (lambda (mirror)
                 (snippet-revival-offset-valid-p
                  (snippet-mirror-revival-start mirror)
                  (snippet-mirror-revival-end mirror)
                  root-length))
               (snippet-field-revival-mirrors field))))
           (snippet-revival-fields revival))))))

(defun snippet-revival-overlay (root-start start end)
  (make-overlay (snippet-point-at-offset root-start start)
                (snippet-point-at-offset root-start end)
                'snippet-inactive-field))

(defun snippet-revive-field (revival root-start)
  (let* ((overlay
           (snippet-revival-overlay
            root-start
            (snippet-field-revival-start revival)
            (snippet-field-revival-end revival)))
         (mirror-revivals (snippet-field-revival-mirrors revival))
         (mirrors
           (mapcar
            (lambda (mirror)
              (snippet-revival-overlay
               root-start
               (snippet-mirror-revival-start mirror)
               (snippet-mirror-revival-end mirror)))
            mirror-revivals)))
    (make-snippet-field
     :id (snippet-field-revival-id revival)
     :number (snippet-field-revival-number revival)
     :parent-id (snippet-field-revival-parent-id revival)
     :container-ids (copy-list (snippet-field-revival-container-ids revival))
     :sequence (snippet-field-revival-sequence revival)
     :overlay overlay
     :mirrors mirrors
     :mirror-transforms
     (loop :for mirror-revival :in mirror-revivals
           :for mirror :in mirrors
           :when (snippet-mirror-revival-transform-kind mirror-revival)
             :collect
             (cons mirror
                   (snippet-mirror-revival-transform-kind mirror-revival)))
     :modified-p (snippet-field-revival-modified-p revival)
     :disabled-p (snippet-field-revival-disabled-p revival))))

(defun snippet-revival-root-points (revival buffer)
  (let ((start (copy-point (buffer-start-point buffer) :temporary)))
    (when (move-to-position start (snippet-revival-root-start revival))
      (let ((end (copy-point start :temporary)))
        (when (character-offset end (length (snippet-revival-root-text revival)))
          (values start end))))))

(defun snippet-restore-revival (revival buffer)
  "Restore REVIVAL's field overlays without changing BUFFER's text or history."
  (multiple-value-bind (root-start root-end)
      (snippet-revival-root-points revival buffer)
    (when (and root-start
               root-end
               (string= (points-to-string root-start root-end)
                        (snippet-revival-root-text revival)))
      (let* ((root-overlay
               (make-overlay root-start root-end 'snippet-inactive-field))
             (fields
               (mapcar (lambda (field)
                         (snippet-revive-field field root-start))
                       (snippet-revival-fields revival)))
             (exit-overlay
               (snippet-revival-overlay
                root-start
                (snippet-revival-exit-start revival)
                (snippet-revival-exit-end revival)))
             (session
               (make-snippet-session
                :buffer buffer
                :template (snippet-revival-template revival)
                :root-overlay root-overlay
                :fields fields
                :exit-overlay exit-overlay
                :current-index nil
                :pending-field-edit-p nil
                :defer-zero-exit-p
                (snippet-revival-defer-zero-exit-p revival))))
        (setf (buffer-value buffer :lem-yath-snippet-session) session)
        (add-hook (variable-value 'before-change-functions :buffer buffer)
                  'snippet-before-change)
        (add-hook (variable-value 'after-change-functions :buffer buffer)
                  'snippet-after-change)
        (snippet-activate-index session
                                (snippet-revival-current-index revival))
        t))))

(defun snippet-restore-after-history-move
    (&optional (buffer (current-buffer)))
  (let ((revival
          (find-if (lambda (candidate)
                     (snippet-revival-valid-p candidate buffer))
                   (buffer-value buffer :lem-yath-snippet-revivals))))
    (when revival
      (snippet-restore-revival revival buffer))))

(defun snippet-major-mode-command-p ()
  (member (command-name (this-command)) (major-modes)))

(defun snippet-pre-command ()
  ;; Undo/redo replays every recorded primary and mirror edit.  Tear down
  ;; derived overlays first so the inverse edits cannot recursively mirror.
  (snippet-ensure-session-valid)
  (alexandria:when-let ((session (snippet-active-session)))
    (if (snippet-major-mode-command-p)
        (progn
          (setf (buffer-value (current-buffer)
                              :lem-yath-snippet-revivals)
                nil)
          (snippet-end-session))
        (progn
          ;; Save the state before every command. If that command creates a
          ;; new undo node, this is precisely the parent state needed by a
          ;; later undo; before a history move, it also records the state
          ;; needed by the inverse move.
          (snippet-store-current-revival session)
          (when (snippet-undo-command-p)
            (snippet-end-session))))))

(defun snippet-post-command ()
  ;; Major-mode activation clears buffer-local minor modes.  Reapply the
  ;; configured global behavior after the command has finished, and withdraw
  ;; it if a buffer became temporary or read-only.
  (let ((buffer (current-buffer)))
    (snippet-ensure-session-valid buffer)
    (snippet-prune-revivals buffer)
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
          (setf (buffer-value buffer :lem-yath-snippet-revivals) nil)
          (when (snippet-mode-present-p buffer)
            (lem-yath-snippet-mode nil))))
    (when (and (snippet-undo-command-p)
               (not (snippet-active-session-p buffer)))
      (snippet-restore-after-history-move buffer))))

(add-hook *find-file-hook* 'snippet-enable-buffer)
(add-hook *switch-to-buffer-hook* 'snippet-enable-buffer)
(add-hook *pre-command-hook* 'snippet-pre-command)
(add-hook *post-command-hook* 'snippet-post-command -200)

(dolist (buffer (buffer-list))
  (snippet-enable-buffer buffer))
