(in-package :lem-yath)

;;; Installed-runtime acceptance fixture for automatic tree-sitter highlighting.

(defvar *tree-sitter-test-report*
  (uiop:getenv "LEM_YATH_TREE_SITTER_REPORT"))
(defvar *tree-sitter-test-main-file*
  (uiop:getenv "LEM_YATH_TREE_SITTER_FILE"))
(defvar *tree-sitter-test-language-mode-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_LANGUAGE_MODE_ROOT")))
(defvar *tree-sitter-test-failures* 0)
(defvar *tree-sitter-test-grammar-successes* 0)

(defun tree-sitter-test-log (control &rest arguments)
  (with-open-file (stream *tree-sitter-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun tree-sitter-test-safe (value)
  (let ((text (princ-to-string value)))
    (map 'string
         (lambda (character)
           (if (member character '(#\Newline #\Return #\Tab))
               #\Space
               character))
         text)))

(defun tree-sitter-test-check (condition label &optional detail)
  (tree-sitter-test-log "~a ~a~@[ -- ~a~]"
                        (if condition "PASS" "FAIL")
                        label
                        (and detail (tree-sitter-test-safe detail)))
  (unless condition
    (incf *tree-sitter-test-failures*))
  condition)

(defun tree-sitter-test-parser (&optional (buffer (current-buffer)))
  (let ((syntax-table (buffer-syntax-table buffer)))
    (and syntax-table (syntax-table-parser syntax-table))))

(defun tree-sitter-test-active-p (&optional (buffer (current-buffer)))
  (typep (tree-sitter-test-parser buffer)
         'lem-yath-tree-sitter-parser))

(defun tree-sitter-test-disable-lint (buffer)
  (with-current-buffer buffer
    (when (mode-active-p buffer 'lem-yath-lint-mode)
      (lem-yath-lint-mode nil))))

(defun tree-sitter-test-python-mode (buffer)
  (with-current-buffer buffer
    (let ((lem-lsp-mode::*disable* t))
      (lem-python-mode:python-mode)))
  (tree-sitter-test-disable-lint buffer)
  buffer)

(defun tree-sitter-test-set-text (buffer text)
  (with-current-buffer buffer
    (let ((lem/buffer/internal:*inhibit-modification-hooks* t))
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer) text))
    ;; Normal edits clear this from before-change-functions.  The fixture
    ;; suppresses those hooks to avoid unrelated asynchronous services.
    (setf (variable-value 'lem/buffer/internal::syntax-ppss-cache
                          :buffer buffer)
          nil)))

(defun tree-sitter-test-delete-buffer (buffer)
  (when (and buffer (not (deleted-buffer-p buffer)))
    (buffer-unmark buffer)
    (delete-buffer buffer)))

(defun tree-sitter-test-scan (buffer)
  (with-current-buffer buffer
    (lem-core::syntax-scan-buffer buffer)))

(defun tree-sitter-test-attribute (buffer text)
  (with-point ((point (buffer-start-point buffer)))
    (when (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (character-offset point (- (length text)))
      (text-property-at point :attribute))))

(defun tree-sitter-test-check-bundle ()
  (let ((root (tree-sitter-bundle-root)))
    (tree-sitter-test-check
     (and root (uiop:directory-exists-p root))
     "deterministic-bundle-is-present"
     root)
    (tree-sitter-test-check
     (and (= 23 (length *tree-sitter-specs*))
          (every
           (lambda (spec)
             (and (probe-file (tree-sitter-spec-parser-path spec))
                  (probe-file (tree-sitter-spec-query-path spec))))
           *tree-sitter-specs*))
     "all-configured-parser-and-query-paths-exist")))

(defun tree-sitter-test-check-grammar-compilation (buffer)
  (setf *tree-sitter-test-grammar-successes* 0)
  (dolist (spec *tree-sitter-specs*)
    (let ((parser nil))
      (unwind-protect
           (handler-case
               (progn
                 (setf parser
                       (make-lem-yath-tree-sitter-parser buffer spec))
                 (tree-sitter-test-check
                  (and (lem-tree-sitter::treesitter-parser-highlight-query
                        parser)
                       (= (length
                           (tree-sitter-parser-pattern-predicates parser))
                          (tree-sitter:query-pattern-count
                           (lem-tree-sitter::treesitter-parser-highlight-query
                            parser))))
                  (format nil "grammar-~a-compiles"
                          (tree-sitter-spec-language spec)))
                 (incf *tree-sitter-test-grammar-successes*))
             (error (condition)
               (tree-sitter-test-check
                nil
                (format nil "grammar-~a-compiles"
                        (tree-sitter-spec-language spec))
                condition)))
        (when parser
          (dispose-tree-sitter-parser parser)))))
  (tree-sitter-test-check
   (= *tree-sitter-test-grammar-successes*
      (length *tree-sitter-specs*))
   "every-bundled-grammar-and-query-loads"
   (format nil "~d/~d"
           *tree-sitter-test-grammar-successes*
           (length *tree-sitter-specs*))))

(defun tree-sitter-test-spec-buffer-name (spec)
  (format nil "tree-sitter-expreg.~a"
          (or (first (tree-sitter-spec-extensions spec))
              (tree-sitter-spec-language spec))))

(defun tree-sitter-test-check-expreg-registry ()
  "Prove every installed mode exposes its exact grammar to SPC v."
  (dolist (spec *tree-sitter-specs*)
    (let ((buffer nil))
      (unwind-protect
           (handler-case
               (progn
                 (setf buffer
                       (make-buffer
                        (tree-sitter-test-spec-buffer-name spec)))
                 (with-current-buffer buffer
                   (let ((lem-lsp-mode::*disable* t))
                     (funcall (tree-sitter-spec-mode spec))))
                 (tree-sitter-test-disable-lint buffer)
                 (tree-sitter-test-check
                  (and (tree-sitter-test-active-p buffer)
                       (string=
                        (tree-sitter-spec-language spec)
                        (expand-region-tree-sitter-language buffer)))
                  (format nil "expreg-uses-installed-~a-grammar"
                          (tree-sitter-spec-language spec))))
             (error (condition)
               (tree-sitter-test-check
                nil
                (format nil "expreg-uses-installed-~a-grammar"
                        (tree-sitter-spec-language spec))
                condition)))
        (tree-sitter-test-delete-buffer buffer)))))

(defun tree-sitter-test-check-current-python (buffer)
  (tree-sitter-test-disable-lint buffer)
  (tree-sitter-test-check
   (eq (buffer-major-mode buffer) 'lem-python-mode:python-mode)
   "python-file-selects-python-mode")
  (tree-sitter-test-check
   (tree-sitter-test-active-p buffer)
   "python-file-activates-tree-sitter")
  (let ((parser (tree-sitter-test-parser buffer)))
    (tree-sitter-test-check
     (and (typep parser 'lem-yath-tree-sitter-parser)
          (eq buffer (tree-sitter-parser-buffer parser))
          (string= "python"
                   (lem-tree-sitter:treesitter-parser-language-name parser)))
     "parser-is-owned-by-the-python-buffer")
    (tree-sitter-test-check
     (some #'identity
           (tree-sitter-parser-pattern-predicates parser))
     "query-predicate-metadata-is-loaded"))
  (tree-sitter-test-scan buffer)
  (dolist (entry '(("lower" lem:syntax-variable-attribute)
                   ("Upper" lem:syntax-type-attribute)
                   ("custom" lem:syntax-function-name-attribute)
                   ("print" lem:syntax-builtin-attribute)
                   ("if" lem:syntax-keyword-attribute)
                   ("hello" lem:syntax-string-attribute)))
    (destructuring-bind (text expected) entry
      (let ((actual (tree-sitter-test-attribute buffer text)))
        (tree-sitter-test-check
         (eq expected actual)
         (format nil "python-capture-~a" text)
         (format nil "expected=~a actual=~a" expected actual))))))

(defun tree-sitter-test-make-python-buffer (name &optional filename)
  (let ((buffer (make-buffer name)))
    (when filename
      (setf (buffer-filename buffer) filename))
    (tree-sitter-test-python-mode buffer)
    buffer))

(defun tree-sitter-test-check-eligibility ()
  (let ((hidden nil)
        (space-prefixed nil)
        (named nil)
        (file-backed-hidden nil))
    (unwind-protect
         (progn
           (setf hidden
                 (tree-sitter-test-make-python-buffer
                  "*tree-sitter-hidden*"))
           (tree-sitter-test-check
            (not (tree-sitter-test-active-p hidden))
            "internal-star-buffer-keeps-fallback")
           (setf space-prefixed
                 (tree-sitter-test-make-python-buffer
                  " tree-sitter-hidden"))
           (tree-sitter-test-check
            (not (tree-sitter-test-active-p space-prefixed))
            "internal-space-buffer-keeps-fallback")
           (setf named
                 (tree-sitter-test-make-python-buffer
                  "tree-sitter-named.py"))
           (tree-sitter-test-check
            (tree-sitter-test-active-p named)
            "named-fileless-buffer-is-eligible")
           (setf file-backed-hidden
                 (tree-sitter-test-make-python-buffer
                  "*tree-sitter-file-backed*"
                  *tree-sitter-test-main-file*))
           (tree-sitter-test-check
            (tree-sitter-test-active-p file-backed-hidden)
            "file-backed-hidden-name-is-eligible")
           (let ((parser (tree-sitter-test-parser named)))
             (tree-sitter-test-delete-buffer named)
             (tree-sitter-test-check
              (and (deleted-buffer-p named)
                   (null
                    (lem-tree-sitter::treesitter-parser-highlight-query
                     parser))
                   (null
                    (lem-tree-sitter::treesitter-parser-handle parser)))
              "kill-buffer-releases-native-parser-state")
             (setf named nil)))
      (dolist (buffer (list hidden space-prefixed named file-backed-hidden))
        (tree-sitter-test-delete-buffer buffer)))))

(defun tree-sitter-test-check-buffer-isolation ()
  (let ((first nil)
        (second nil))
    (unwind-protect
         (progn
           (setf first
                 (tree-sitter-test-make-python-buffer "tree-sitter-one.py")
                 second
                 (tree-sitter-test-make-python-buffer "tree-sitter-two.py"))
           (tree-sitter-test-set-text first "Alpha = 1\n")
           (tree-sitter-test-set-text second "beta = 1\n")
           (tree-sitter-test-check
            (= (buffer-modified-tick first)
               (buffer-modified-tick second))
            "isolation-fixtures-have-equal-edit-ticks")
           (tree-sitter-test-scan first)
           (tree-sitter-test-scan second)
           (tree-sitter-test-check
            (and (not (eq (buffer-syntax-table first)
                          (buffer-syntax-table second)))
                 (not (eq (tree-sitter-test-parser first)
                          (tree-sitter-test-parser second))))
            "same-mode-buffers-have-distinct-parser-state")
           (tree-sitter-test-check
            (eq 'lem:syntax-type-attribute
                (tree-sitter-test-attribute first "Alpha"))
            "first-buffer-uses-its-own-tree")
           (tree-sitter-test-check
            (eq 'lem:syntax-variable-attribute
                (tree-sitter-test-attribute second "beta"))
            "second-buffer-does-not-reuse-the-first-tree"))
      (dolist (buffer (list first second))
        (tree-sitter-test-delete-buffer buffer)))))

(defun tree-sitter-test-check-full-reparse (buffer)
  (let* ((parser (tree-sitter-test-parser buffer))
         (old-tree (lem-tree-sitter:treesitter-parser-tree parser)))
    (tree-sitter-test-set-text
     buffer
     (format nil "π_value = 1~%custom(π_value)~%Upper = 2~%"))
    (tree-sitter-test-scan buffer)
    (tree-sitter-test-check
     (and (eq parser (tree-sitter-test-parser buffer))
          (lem-tree-sitter:treesitter-parser-tree parser)
          (not (eq old-tree
                   (lem-tree-sitter:treesitter-parser-tree parser)))
          (null (lem-tree-sitter::treesitter-parser-pending-edits parser))
          (eql (buffer-modified-tick buffer)
               (lem-tree-sitter::treesitter-parser-cached-tick parser)))
     "unicode-multiline-edit-is-reparsed-from-current-text")
    (tree-sitter-test-check
     (eq 'lem:syntax-variable-attribute
         (tree-sitter-test-attribute buffer "π_value"))
     "unicode-byte-offset-maps-to-the-right-identifier")
    (tree-sitter-test-check
     (eq 'lem:syntax-function-name-attribute
         (tree-sitter-test-attribute buffer "custom"))
     "false-builtin-predicate-does-not-overhighlight")
    (tree-sitter-test-check
     (eq 'lem:syntax-type-attribute
         (tree-sitter-test-attribute buffer "Upper"))
     "post-edit-constructor-highlight-is-current")))

(defun tree-sitter-test-check-hooks ()
  (let* ((mode-hook-symbol
           (mode-hook-variable 'lem-python-mode:python-mode))
         (mode-hook (and mode-hook-symbol
                         (symbol-value mode-hook-symbol))))
    (tree-sitter-test-check
     (= 1 (count 'configure-tree-sitter-for-current-buffer
                 mode-hook :key #'car))
     "mode-hook-is-installed-once")
    (tree-sitter-test-check
     (= 1 (count 'release-current-buffer-tree-sitter-parser
                 (variable-value 'kill-buffer-hook :global t)
                 :key #'car))
     "kill-hook-is-installed-once")))

(defun tree-sitter-test-language-path (relative)
  (merge-pathnames relative *tree-sitter-test-language-mode-root*))

(defun tree-sitter-test-open-language-file (relative)
  (let ((buffer
          (lem-lsp-mode:without-lsp-mode ()
            (find-file-buffer (tree-sitter-test-language-path relative)))))
    (tree-sitter-test-disable-lint buffer)
    buffer))

(defun tree-sitter-test-check-mode-file
    (relative expected-mode &key grammar width comment programming tabs)
  (let ((buffer nil))
    (unwind-protect
         (handler-case
             (progn
               (setf buffer (tree-sitter-test-open-language-file relative))
               (tree-sitter-test-check
                (eq expected-mode (buffer-major-mode buffer))
                (format nil "~a-selects-~a" relative expected-mode)
                (buffer-major-mode buffer))
               (with-current-buffer buffer
                 (tree-sitter-test-check
                  (= width (variable-value 'tab-width))
                  (format nil "~a-uses-configured-indent-width" relative))
                 (tree-sitter-test-check
                 (string= comment
                           (variable-value 'lem/language-mode:line-comment))
                  (format nil "~a-uses-configured-comment" relative))
                 (tree-sitter-test-check
                  (eq tabs (not (null (variable-value 'indent-tabs-mode))))
                  (format nil "~a-uses-configured-tab-policy" relative))
                 (tree-sitter-test-check
                  (eq programming (not (null (programming-buffer-p buffer))))
                  (format nil "~a-retains-emacs-mode-class" relative)))
               (when grammar
                 (tree-sitter-test-check
                  (and (tree-sitter-test-active-p buffer)
                       (string=
                        grammar
                        (expand-region-tree-sitter-language buffer)))
                  (format nil "~a-activates-~a-parser" relative grammar))))
           (error (condition)
             (tree-sitter-test-check
              nil (format nil "~a-opens-in-configured-mode" relative)
              condition)))
      (tree-sitter-test-delete-buffer buffer))))

(defun tree-sitter-test-check-language-highlighting ()
  (dolist (entry
           '((".JuStFiLe" "build" lem:syntax-function-name-attribute)
             ("meson.build" "if" lem:syntax-keyword-attribute)
             ("nginx/sites/site.conf" "$host"
              lem:syntax-variable-attribute)
             ("script.nu" "let" lem:syntax-keyword-attribute)
             ("document.typ" "Heading" lem:document-header1-attribute)
             ("player.gd" "ready" lem:syntax-function-name-attribute)))
    (destructuring-bind (relative text expected) entry
      (let ((buffer nil))
        (unwind-protect
             (handler-case
                 (progn
                   (setf buffer
                         (tree-sitter-test-open-language-file relative))
                   (tree-sitter-test-scan buffer)
                   (tree-sitter-test-check
                    (eq expected
                        (tree-sitter-test-attribute buffer text))
                    (format nil "~a-highlights-~a" relative text)
                    (tree-sitter-test-attribute buffer text)))
               (error (condition)
                 (tree-sitter-test-check
                  nil (format nil "~a-highlighting-completes" relative)
                  condition)))
          (tree-sitter-test-delete-buffer buffer))))))

(defun tree-sitter-test-indent-result (mode text)
  (let ((buffer (make-buffer (format nil "*~a-indent*" mode))))
    (unwind-protect
         (with-current-buffer buffer
           (funcall mode)
           (tree-sitter-test-set-text buffer text)
           (let ((point (buffer-end-point buffer)))
             (funcall (variable-value 'calc-indent-function) point)))
      (tree-sitter-test-delete-buffer buffer))))

(defun tree-sitter-test-check-language-modes ()
  (tree-sitter-test-check-mode-file
   ".JuStFiLe" 'just-mode :grammar "just" :width 4 :comment "#"
   :programming t)
  (tree-sitter-test-check-mode-file
   "jUsTfIlE" 'just-mode :grammar "just" :width 4 :comment "#"
   :programming t)
  (tree-sitter-test-check-mode-file
   "meson.build" 'meson-mode :width 2 :comment "#" :programming t)
  (tree-sitter-test-check-mode-file
   "meson_options.txt" 'meson-mode :width 2 :comment "#" :programming t)
  (tree-sitter-test-check-mode-file
   "meson.options" 'meson-mode :width 2 :comment "#" :programming t)
  (tree-sitter-test-check-mode-file
   "nginx.conf" 'nginx-mode :width 4 :comment "#" :programming t)
  (tree-sitter-test-check-mode-file
   "nginx/sites/site.conf" 'nginx-mode :width 4 :comment "#" :programming t)
  (tree-sitter-test-check-mode-file
   "magic.conf" 'nginx-mode :width 4 :comment "#" :programming t)
  (tree-sitter-test-check-mode-file
   "script.nu" 'nushell-mode :grammar "nu" :width 2 :comment "#"
   :programming t)
  (tree-sitter-test-check-mode-file
   "nu-script" 'nushell-mode :grammar "nu" :width 2 :comment "#"
   :programming t)
  (tree-sitter-test-check-mode-file
   "document.typ" 'typst-mode :grammar "typst" :width 4 :comment "//"
   :programming nil)
  (tree-sitter-test-check-mode-file
   "player.gd" 'gdscript-mode :grammar "gdscript" :width 4 :comment "#"
   :programming t :tabs t)
  (tree-sitter-test-check-language-highlighting)
  (dolist (entry
           `((just-mode ,(format nil "build:~%") 4)
             (meson-mode ,(format nil "if true~%") 2)
             (nginx-mode ,(format nil "server {~%") 4)
             (nushell-mode ,(format nil "if true {~%") 2)
             (typst-mode ,(format nil "#let value = (~%") 4)
             (gdscript-mode ,(format nil "func ready():~%") 4)))
    (destructuring-bind (mode text expected) entry
      (tree-sitter-test-check
       (= expected (tree-sitter-test-indent-result mode text))
       (format nil "~a-indents-after-opener" mode))))
  (dolist (entry
           `((meson-mode ,(format nil "if true~%  value = 1~%endif") 0)
             (nginx-mode ,(format nil "server {~%    listen 80;~%}") 0)
             (nushell-mode ,(format nil "if true {~%  print yes~%}") 0)
             (typst-mode ,(format nil "#let value = (~%    1~%)") 0)
             (gdscript-mode ,(format nil "if true:~%\tpass~%else:") 0)))
    (destructuring-bind (mode text expected) entry
      (tree-sitter-test-check
       (= expected (tree-sitter-test-indent-result mode text))
       (format nil "~a-dedents-closing-line" mode)))))

(defun tree-sitter-test-run ()
  (let ((buffer (find-file-buffer *tree-sitter-test-main-file*)))
    (unless buffer
      (error "The main Python fixture is not open"))
    (switch-to-buffer buffer)
    (tree-sitter-test-check-bundle)
    (tree-sitter-test-check-hooks)
    (tree-sitter-test-check-current-python buffer)
    (tree-sitter-test-check-grammar-compilation buffer)
    (tree-sitter-test-check-expreg-registry)
    (tree-sitter-test-check-language-modes)
    (tree-sitter-test-check-eligibility)
    (tree-sitter-test-check-buffer-isolation)
    (tree-sitter-test-check-full-reparse buffer)))

(handler-case
    (tree-sitter-test-run)
  (error (condition)
    (tree-sitter-test-check nil "fixture-completes" condition)))

(tree-sitter-test-log
 "SUMMARY ~a failures=~d grammars=~d/~d"
 (if (zerop *tree-sitter-test-failures*) "PASS" "FAIL")
 *tree-sitter-test-failures*
 *tree-sitter-test-grammar-successes*
 (length *tree-sitter-specs*))
