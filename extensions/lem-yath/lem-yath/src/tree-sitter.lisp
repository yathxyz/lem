;;;; Automatic tree-sitter highlighting for the modes already provided by Lem.
;;;; This mirrors the configured treesit-auto policy without changing modes,
;;;; indentation, language servers, or structural editing.

(in-package :lem-yath)

(defstruct (tree-sitter-spec
            (:constructor make-tree-sitter-spec
                (&key mode language symbol-name extensions)))
  mode
  language
  symbol-name
  extensions
  language-object)

(defparameter *tree-sitter-specs*
  (list
   (make-tree-sitter-spec
    :mode 'lem-posix-shell-mode:posix-shell-mode :language "bash")
   (make-tree-sitter-spec
    :mode 'lem-c-mode:c-mode :language "c")
   (make-tree-sitter-spec
    :mode 'c++-mode :language "cpp")
   (make-tree-sitter-spec
    :mode 'csharp-mode :language "c_sharp")
   (make-tree-sitter-spec
    :mode 'lem-clojure-mode:clojure-mode :language "clojure")
   (make-tree-sitter-spec
    :mode 'lem-css-mode:css-mode :language "css")
   (make-tree-sitter-spec
    :mode 'lem-go-mode:go-mode :language "go")
   (make-tree-sitter-spec
    :mode 'gdscript-mode :language "gdscript")
   (make-tree-sitter-spec
    :mode 'lem-html-mode:html-mode :language "html")
   (make-tree-sitter-spec
    :mode 'lem-java-mode:java-mode :language "java")
   (make-tree-sitter-spec
    :mode 'lem-js-mode:js-mode :language "javascript")
   (make-tree-sitter-spec
    :mode 'lem-json-mode:json-mode :language "json")
   (make-tree-sitter-spec
    :mode 'just-mode :language "just")
   (make-tree-sitter-spec
    :mode 'lem-lua-mode:lua-mode :language "lua")
   (make-tree-sitter-spec
    :mode 'lem-markdown-mode:markdown-mode :language "markdown")
   (make-tree-sitter-spec
    :mode 'lem-nix-mode:nix-mode :language "nix")
   (make-tree-sitter-spec
    :mode 'nushell-mode :language "nu")
   (make-tree-sitter-spec
    :mode 'lem-python-mode:python-mode :language "python")
   (make-tree-sitter-spec
    :mode 'lem-rust-mode:rust-mode :language "rust")
   (make-tree-sitter-spec
    :mode 'lem-toml-mode:toml-mode :language "toml")
   (make-tree-sitter-spec
    :mode 'lem-typescript-mode:typescript-mode
    :language "tsx"
    :extensions '("tsx"))
   (make-tree-sitter-spec
    :mode 'lem-typescript-mode:typescript-mode :language "typescript")
   (make-tree-sitter-spec
    :mode 'typst-mode :language "typst")
   (make-tree-sitter-spec
    :mode 'lem-yaml-mode:yaml-mode :language "yaml")))

(defclass lem-yath-tree-sitter-parser (lem-tree-sitter:treesitter-parser)
  ((buffer :initarg :buffer :reader tree-sitter-parser-buffer)
   (spec :initarg :spec :reader tree-sitter-parser-spec)
   (pattern-predicates
    :initarg :pattern-predicates
    :reader tree-sitter-parser-pattern-predicates)))

;;; tree-sitter-cl exposes query matches but not predicate metadata.  The
;;; metadata is part of tree-sitter's stable C API and is needed to avoid, for
;;; example, highlighting every Python identifier as a constructor.

(cffi:defcstruct yath-ts-query-predicate-step
  (type :uint32)
  (value-id :uint32))

(cffi:defcfun ("ts_query_predicates_for_pattern"
               %ts-query-predicates-for-pattern)
    :pointer
  (query :pointer)
  (pattern-index :uint32)
  (step-count :pointer))

(cffi:defcfun ("ts_query_string_value_for_id"
               %ts-query-string-value-for-id)
    :pointer
  (query :pointer)
  (id :uint32)
  (length :pointer))

(defun tree-sitter-query-string-value (query-pointer id)
  (cffi:with-foreign-object (length :uint32)
    (let ((pointer (%ts-query-string-value-for-id query-pointer id length)))
      (unless (cffi:null-pointer-p pointer)
        (cffi:foreign-string-to-lisp
         pointer
         :count (cffi:mem-ref length :uint32)
         :encoding :utf-8)))))

(defun tree-sitter-query-pattern-predicates (query pattern-index)
  "Return PATTERN-INDEX predicates as tagged capture/string operands."
  (let ((query-pointer (tree-sitter/types:ts-query-ptr query)))
    (cffi:with-foreign-object (step-count :uint32)
      (let* ((steps (%ts-query-predicates-for-pattern
                     query-pointer pattern-index step-count))
             (count (cffi:mem-ref step-count :uint32))
             (predicates '())
             (current '()))
        (dotimes (index count)
          (let* ((step
                   (cffi:mem-aptr
                    steps '(:struct yath-ts-query-predicate-step) index))
                 (type
                   (cffi:foreign-slot-value
                    step '(:struct yath-ts-query-predicate-step) 'type))
                 (value-id
                   (cffi:foreign-slot-value
                    step '(:struct yath-ts-query-predicate-step) 'value-id)))
            (case type
              (0
               (when current
                 (push (nreverse current) predicates)
                 (setf current nil)))
              (1 (push (cons :capture value-id) current))
              (2
               (push (cons :string
                           (tree-sitter-query-string-value
                            query-pointer value-id))
                     current))
              (otherwise (push (cons :unsupported type) current)))))
        (when current
          (push (nreverse current) predicates))
        (nreverse predicates)))))

(defun tree-sitter-compile-pattern-predicates (query)
  (let* ((count (tree-sitter:query-pattern-count query))
         (predicates (make-array count)))
    (dotimes (index count predicates)
      (setf (aref predicates index)
            (tree-sitter-query-pattern-predicates query index)))))

(defun tree-sitter-bundle-root ()
  (alexandria:when-let ((root (uiop:getenv "LEM_YATH_TREE_SITTER_BUNDLE")))
    (uiop:ensure-directory-pathname root)))

(defun tree-sitter-spec-directory (spec)
  (alexandria:when-let ((root (tree-sitter-bundle-root)))
    (merge-pathnames
     (format nil "~a/" (tree-sitter-spec-language spec)) root)))

(defun tree-sitter-spec-parser-path (spec)
  (alexandria:when-let ((directory (tree-sitter-spec-directory spec)))
    (merge-pathnames "parser" directory)))

(defun tree-sitter-spec-query-path (spec)
  (alexandria:when-let ((directory (tree-sitter-spec-directory spec)))
    (merge-pathnames "highlights.scm" directory)))

(defun tree-sitter-buffer-extension (buffer)
  (let ((name (or (buffer-filename buffer) (buffer-name buffer))))
    (when name
      (alexandria:when-let
          ((type (ignore-errors (pathname-type (pathname name)))))
        ;; SBCL represents wildcard pathname components with an internal
        ;; pattern object.  Synthetic buffers can legitimately contain `*'
        ;; in their display names, but such an object is not an extension.
        (when (stringp type)
          (string-downcase type))))))

(defun tree-sitter-spec-for-buffer (buffer)
  (let* ((mode (buffer-major-mode buffer))
         (extension (tree-sitter-buffer-extension buffer))
         (mode-specs
           (remove-if-not
            (lambda (spec)
              (eq mode (tree-sitter-spec-mode spec)))
            *tree-sitter-specs*)))
    (or (find-if
         (lambda (spec)
           (and (tree-sitter-spec-extensions spec)
                (member extension
                        (tree-sitter-spec-extensions spec)
                        :test #'string=)))
         mode-specs)
        (find-if (lambda (spec)
                   (null (tree-sitter-spec-extensions spec)))
                 mode-specs))))

(defun tree-sitter-eligible-buffer-p (buffer)
  "Match yath/treesit-auto--eligible-buffer-p from the Emacs config."
  (let ((name (buffer-name buffer)))
    (and name
         (or (buffer-filename buffer)
             (and (plusp (length name))
                  (not (member (char name 0) '(#\Space #\*))))))))

(defun ensure-tree-sitter-language (spec)
  (or (tree-sitter-spec-language-object spec)
      (let ((parser-path (tree-sitter-spec-parser-path spec)))
        (unless (and parser-path (probe-file parser-path))
          (error "Tree-sitter parser is missing for ~a"
                 (tree-sitter-spec-language spec)))
        (setf (tree-sitter-spec-language-object spec)
              (tree-sitter:load-language
               (tree-sitter-spec-language spec)
               parser-path
               :symbol-name (tree-sitter-spec-symbol-name spec))))))

(defun make-lem-yath-tree-sitter-parser (buffer spec)
  (let ((query-path (tree-sitter-spec-query-path spec)))
    (unless (and query-path (probe-file query-path))
      (error "Tree-sitter highlight query is missing for ~a"
             (tree-sitter-spec-language spec)))
    (let* ((language (ensure-tree-sitter-language spec))
           (handle (tree-sitter:make-parser language))
           (query nil)
           (success nil))
      (unwind-protect
           (progn
             (setf query
                   (tree-sitter:query-compile
                    language (uiop:read-file-string query-path)))
             (let ((parser
                     (make-instance
                      'lem-yath-tree-sitter-parser
                      :language-name (tree-sitter-spec-language spec)
                      :parser handle
                      :highlight-query query
                      :buffer buffer
                      :spec spec
                      :pattern-predicates
                      (tree-sitter-compile-pattern-predicates query))))
               (setf success t)
               parser))
        (unless success
          (when query
            (tree-sitter:query-delete query))
          (tree-sitter:parser-delete handle))))))

(defun delete-tree-sitter-tree (tree)
  (when tree
    (trivial-garbage:cancel-finalization tree)
    (tree-sitter/ffi:ts-tree-delete
     (tree-sitter/types:ts-tree-ptr tree))))

(defun delete-tree-sitter-node (node)
  (when node
    (cffi:foreign-free (tree-sitter/types:ts-node-buffer node))))

(defun dispose-tree-sitter-parser (parser)
  "Release the native resources of an uninstalled or replaced PARSER."
  (delete-tree-sitter-tree
   (lem-tree-sitter:treesitter-parser-tree parser))
  (setf (lem-tree-sitter:treesitter-parser-tree parser) nil)
  (alexandria:when-let
      ((query (lem-tree-sitter::treesitter-parser-highlight-query parser)))
    (tree-sitter:query-delete query)
    (setf (lem-tree-sitter::treesitter-parser-highlight-query parser) nil))
  (alexandria:when-let
      ((handle (lem-tree-sitter::treesitter-parser-handle parser)))
    (tree-sitter:parser-delete handle)
    (setf (lem-tree-sitter::treesitter-parser-handle parser) nil)))

(defun tree-sitter-node-text (buffer node)
  (multiple-value-bind (start end)
      (lem-tree-sitter::byte-range-to-points
       buffer
       (tree-sitter:node-start-byte node)
       (tree-sitter:node-end-byte node))
    (unwind-protect
         (when (and start end)
           (points-to-string start end))
      (when start (delete-point start))
      (when end (delete-point end)))))

(defun tree-sitter-predicate-step-values (step match buffer)
  (case (car step)
    (:string (list (cdr step)))
    (:capture
     (loop :for capture :in (tree-sitter:match-captures match)
           :when (= (tree-sitter:capture-index capture) (cdr step))
             :collect (tree-sitter-node-text
                       buffer (tree-sitter:capture-node capture))))
    (otherwise nil)))

(defun tree-sitter-regexp-match-p (pattern string)
  (handler-case
      (not (null (cl-ppcre:scan pattern string)))
    (error () nil)))

(defun tree-sitter-text-predicate-p (predicate match buffer)
  (let* ((operator-step (first predicate))
         (operator (and (eq (car operator-step) :string)
                        (cdr operator-step)))
         (arguments (rest predicate)))
    (cond
      ((and (string= operator "match?") (= (length arguments) 2))
       (let ((values
               (tree-sitter-predicate-step-values
                (first arguments) match buffer))
             (patterns
               (tree-sitter-predicate-step-values
                (second arguments) match buffer)))
         (and values patterns
              (every (lambda (value)
                       (some (lambda (pattern)
                               (tree-sitter-regexp-match-p pattern value))
                             patterns))
                     values))))
      ((and (string= operator "eq?") (= (length arguments) 2))
       (let ((left
               (tree-sitter-predicate-step-values
                (first arguments) match buffer))
             (right
               (tree-sitter-predicate-step-values
                (second arguments) match buffer)))
         (and left right
              (every (lambda (value)
                       (member value right :test #'string=))
                     left))))
      ((and (string= operator "any-of?") (rest arguments))
       (let ((values
               (tree-sitter-predicate-step-values
                (first arguments) match buffer))
             (choices
               (mapcan (lambda (step)
                         (tree-sitter-predicate-step-values step match buffer))
                       (rest arguments))))
         (and values choices
              (every (lambda (value)
                       (member value choices :test #'string=))
                     values))))
      ;; #is-not? local requires a locals query and scope engine.  Rejecting
      ;; those optional builtin patterns is safer than false highlighting.
      ((string= operator "is-not?") nil)
      (t nil))))

(defun tree-sitter-match-predicates-p (parser match buffer)
  (let* ((index (tree-sitter:match-pattern-index match))
         (predicates
           (aref (tree-sitter-parser-pattern-predicates parser) index)))
    (every (lambda (predicate)
             (tree-sitter-text-predicate-p predicate match buffer))
           predicates)))

(defparameter *tree-sitter-extra-capture-attributes*
  '(("charset" . lem:syntax-keyword-attribute)
    ("conditional" . lem:syntax-keyword-attribute)
    ("constructor" . lem:syntax-type-attribute)
    ("embedded" . lem:syntax-builtin-attribute)
    ("escape" . lem:syntax-constant-attribute)
    ("import" . lem:syntax-keyword-attribute)
    ("keyframes" . lem:syntax-keyword-attribute)
    ("media" . lem:syntax-keyword-attribute)
    ("module" . lem:syntax-type-attribute)
    ("namespace" . lem:syntax-type-attribute)
    ("none" . lem:syntax-constant-attribute)
    ("parameter" . lem:syntax-variable-attribute)
    ("preproc" . lem:syntax-keyword-attribute)
    ("repeat" . lem:syntax-keyword-attribute)
    ("supports" . lem:syntax-keyword-attribute)))

(defun tree-sitter-capture-attribute (capture-name)
  (or (cdr (assoc capture-name *tree-sitter-extra-capture-attributes*
                  :test #'string=))
      (lem-tree-sitter/highlight:capture-to-attribute capture-name)))

(defstruct tree-sitter-highlight
  start-byte
  end-byte
  attribute
  pattern-index)

(defun tree-sitter-highlight-for-capture
    (capture pattern-index start-byte end-byte)
  (let* ((node (tree-sitter:capture-node capture))
         (node-start (tree-sitter:node-start-byte node))
         (node-end (tree-sitter:node-end-byte node))
         (attribute
           (tree-sitter-capture-attribute
            (tree-sitter:capture-name capture))))
    (when (and attribute
               (< node-start node-end)
               (< node-start end-byte)
               (> node-end start-byte))
      (make-tree-sitter-highlight
       :start-byte node-start
       :end-byte node-end
       :attribute attribute
       :pattern-index pattern-index))))

(defun apply-tree-sitter-highlight (buffer highlight)
  (multiple-value-bind (start end)
      (lem-tree-sitter::byte-range-to-points
       buffer
       (tree-sitter-highlight-start-byte highlight)
       (tree-sitter-highlight-end-byte highlight))
    (unwind-protect
         (when (and start end)
           (put-text-property
            start end :attribute
            (tree-sitter-highlight-attribute highlight)))
      (when start (delete-point start))
      (when end (delete-point end)))))

(defun dispose-tree-sitter-match (match)
  (dolist (capture (tree-sitter:match-captures match))
    (delete-tree-sitter-node (tree-sitter:capture-node capture))))

(defun apply-lem-yath-tree-sitter-highlights
    (parser tree buffer start end)
  (let ((query (lem-tree-sitter::treesitter-parser-highlight-query parser)))
    (when query
      (let ((root (tree-sitter:tree-root-node tree))
            (start-byte (point-bytes start))
            (end-byte (point-bytes end))
            (highlights '()))
        (unwind-protect
             (tree-sitter/query:with-query-cursor (cursor)
               (tree-sitter/ffi:ts-query-cursor-set-byte-range
                cursor start-byte end-byte)
               (tree-sitter/query:query-exec cursor query root)
               (cffi:with-foreign-object
                   (match-pointer '(:struct tree-sitter/ffi:ts-query-match))
                 (loop
                   :while (tree-sitter/ffi:ts-query-cursor-next-match
                           cursor match-pointer)
                   :for match :=
                     (tree-sitter/query::extract-match
                      query root match-pointer)
                   :do (unwind-protect
                            (when (tree-sitter-match-predicates-p
                                   parser match buffer)
                              (let ((pattern-index
                                      (tree-sitter:match-pattern-index match)))
                                (dolist (capture
                                         (tree-sitter:match-captures match))
                                  (alexandria:when-let
                                      ((highlight
                                         (tree-sitter-highlight-for-capture
                                          capture pattern-index
                                          start-byte end-byte)))
                                    (push highlight highlights)))))
                         (dispose-tree-sitter-match match)))))
          (delete-tree-sitter-node root))
        ;; Tree-sitter cursors order matches by source location.  Highlight
        ;; queries use later patterns to refine earlier generic captures, so
        ;; apply by pattern order to make those refinements deterministic.
        (dolist (highlight
                 (stable-sort (nreverse highlights) #'<
                              :key #'tree-sitter-highlight-pattern-index))
          (apply-tree-sitter-highlight buffer highlight))))))

(defun reparse-lem-yath-tree-sitter-buffer (parser source tick)
  "Parse SOURCE from scratch; correctness is preferred over approximate edits."
  (let* ((old-tree (lem-tree-sitter:treesitter-parser-tree parser))
         (new-tree
           (tree-sitter:parser-parse-string
            (lem-tree-sitter::treesitter-parser-handle parser) source)))
    (setf (lem-tree-sitter::treesitter-parser-source-cache parser) source
          (lem-tree-sitter::treesitter-parser-pending-edits parser) nil
          (lem-tree-sitter:treesitter-parser-tree parser) new-tree
          (lem-tree-sitter::treesitter-parser-cached-tick parser)
          (and new-tree tick))
    (delete-tree-sitter-tree old-tree)
    new-tree))

(defmethod lem/buffer/internal::%syntax-scan-region
    ((parser lem-yath-tree-sitter-parser) start end)
  (let* ((buffer (point-buffer start))
         (tick (buffer-modified-tick buffer)))
    (unless (eq buffer (tree-sitter-parser-buffer parser))
      (error "A tree-sitter parser was shared between Lem buffers"))
    (remove-text-property start end :attribute)
    (handler-case
        (let ((tree
                (if (and (lem-tree-sitter:treesitter-parser-tree parser)
                         (eql tick
                              (lem-tree-sitter::treesitter-parser-cached-tick
                               parser)))
                    (lem-tree-sitter:treesitter-parser-tree parser)
                    (reparse-lem-yath-tree-sitter-buffer
                     parser (buffer-text buffer) tick))))
          (when tree
            (apply-lem-yath-tree-sitter-highlights
             parser tree buffer start end)))
      (error (condition)
        (log:warn "Tree-sitter scan failed for ~a: ~a"
                  (buffer-name buffer) condition)))))

(defun restore-mode-syntax-table (buffer parser)
  (when (and parser
             (eq parser
                 (syntax-table-parser (buffer-syntax-table buffer))))
    (setf (buffer-syntax-table buffer)
          (mode-syntax-table (buffer-major-mode buffer)))))

(defun release-buffer-tree-sitter-parser (buffer &key restore-syntax-table)
  (let ((parser (buffer-value buffer 'lem-yath-tree-sitter-parser)))
    (when restore-syntax-table
      (restore-mode-syntax-table buffer parser))
    (when parser
      (dispose-tree-sitter-parser parser))
    (setf (buffer-value buffer 'lem-yath-tree-sitter-parser) nil
          (buffer-value buffer 'lem-yath-tree-sitter-language) nil)))

(defun release-current-buffer-tree-sitter-parser
    (&optional (buffer (current-buffer)))
  (release-buffer-tree-sitter-parser buffer))

(defun configure-tree-sitter-for-current-buffer ()
  "Install a fresh parser for the current eligible supported-mode buffer."
  (let ((buffer (current-buffer)))
    (release-buffer-tree-sitter-parser
     buffer :restore-syntax-table t)
    ;; Check the activation policy before interpreting a synthetic buffer name
    ;; as a pathname.  Timemachine and other internal `*...*' buffers inherit
    ;; programming modes but deliberately retain their fallback highlighter.
    (when (and (tree-sitter-eligible-buffer-p buffer)
               (tree-sitter-bundle-root)
               (lem-tree-sitter:tree-sitter-available-p))
      (let ((spec (tree-sitter-spec-for-buffer buffer)))
        (when spec
          (handler-case
              (let* ((parser
                       (make-lem-yath-tree-sitter-parser buffer spec))
                     (syntax-table
                       (lem/buffer/syntax-table::copy-syntax-table
                        (buffer-syntax-table buffer))))
                (set-syntax-parser syntax-table parser)
                (setf (buffer-syntax-table buffer) syntax-table
                      (buffer-value buffer 'lem-yath-tree-sitter-parser) parser
                      (buffer-value buffer 'lem-yath-tree-sitter-language)
                      (tree-sitter-spec-language spec)
                      (lem-core::buffer-scanned-region buffer) nil)
                t)
            (error (condition)
              (log:warn "Tree-sitter activation failed for ~a: ~a"
                        (buffer-name buffer) condition)
              nil)))))))

(defun install-tree-sitter-mode-hooks ()
  ;; Hook every existing major mode so changing away from a supported mode
  ;; promptly releases its native parser as well as enabling supported modes.
  (dolist (mode (major-modes))
    (alexandria:when-let ((hook (mode-hook-variable mode)))
      (add-hook (symbol-value hook)
                'configure-tree-sitter-for-current-buffer
                50)))
  (remove-hook (variable-value 'kill-buffer-hook :global t)
               'release-current-buffer-tree-sitter-parser)
  (add-hook (variable-value 'kill-buffer-hook :global t)
            'release-current-buffer-tree-sitter-parser
            50)
  ;; This also makes source reloads take effect for already-open buffers.
  (dolist (buffer (buffer-list))
    (unless (deleted-buffer-p buffer)
      (with-current-buffer buffer
        (configure-tree-sitter-for-current-buffer)))))

(install-tree-sitter-mode-hooks)
