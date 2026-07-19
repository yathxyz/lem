;;;; Small native modes for configured Emacs languages which Lem does not
;;;; provide.  Just, Nushell, and Typst receive parser-backed highlighting in
;;;; tree-sitter.lisp; these TextMate scanners remain the safe fallback.

(in-package :lem-yath)

(defun language-mode-token-pattern (strings)
  `(:sequence
    :word-boundary
    (:alternation ,@(sort (copy-list strings) #'> :key #'length))
    :word-boundary))

(defun make-configured-language-tmlanguage
    (&key line-comment block-comment strings keywords extra-patterns)
  (let ((patterns '()))
    (when line-comment
      (push (lem/language-mode-tools:make-tm-line-comment-region line-comment)
            patterns))
    (when block-comment
      (push (lem/language-mode-tools:make-tm-block-comment-region
             (car block-comment) (cdr block-comment))
            patterns))
    (dolist (delimiter strings)
      (push (lem/language-mode-tools:make-tm-string-region delimiter)
            patterns))
    (when keywords
      (push (make-tm-match (language-mode-token-pattern keywords)
                           :name 'syntax-keyword-attribute)
            patterns))
    (dolist (pattern extra-patterns)
      (push pattern patterns))
    (make-tmlanguage
     :patterns (apply #'make-tm-patterns (nreverse patterns)))))

(defun language-previous-nonblank-line (point)
  "Return the previous nonblank line's indentation and text."
  (with-point ((line point))
    (loop :while (line-offset line -1)
          :for text := (line-string line)
          :unless (every (lambda (character)
                           (member character '(#\Space #\Tab)))
                         text)
            :do (back-to-indentation line)
                (return (values (point-column line) text))
          :finally (return (values 0 "")))))

(defun language-simple-indent
    (point width &key open-pattern close-pattern)
  "Indent from the previous nonblank line using bounded lexical patterns."
  (let ((current (string-left-trim '(#\Space #\Tab) (line-string point))))
    (multiple-value-bind (indent previous)
        (language-previous-nonblank-line point)
      (cond
        ((and close-pattern (cl-ppcre:scan close-pattern current))
         (max 0 (- indent width)))
        ((and open-pattern (cl-ppcre:scan open-pattern previous))
         (+ indent width))
        (t indent)))))

(defun just-calc-indent (point)
  (language-simple-indent
   point 4
   :open-pattern "^[^ \\t#:][^#:]*:[^=]*(?:#.*)?$"))

(defparameter *nasm-zero-column-keywords*
  '("__?NASM_CDecl?__" "absolute" "align" "alignb" "alignmode" "at"
    "bf16" "bits"
    "build_version" "common" "cpu" "debug" "default" "dollarhex"
    "end" "endp" "ends" "endstruc" "export" "extern" "float"
    "global" "gprefix" "group" "gsuffix" "iend" "import" "istruc"
    "library" "limit" "list" "lprefix" "lsuffix" "map" "maxdump"
    "module" "no_dead_strip" "nodepend" "noseclabels" "options" "org"
    "osabi" "pragma" "prefix" "proc" "required" "safeseh" "sectalign"
    "section" "static" "struc" "subsections_via_symbols"
    "suffix" "uppercase" "use16" "use32" "use64" "useabs" "usebnd"
    "usenobnd" "userel" "warning"))

(defparameter *nasm-preprocessor-directives*
  '("%aliases" "%arg" "%assign" "%clear" "%defalias" "%define"
    "%defstr" "%deftok" "%depend" "%elif" "%elifctx" "%elifdef"
    "%elifdefalias" "%elifdifi" "%elifdirective" "%elifempty"
    "%elifenv" "%eliffile" "%elifid" "%elifidn" "%elifidni"
    "%elifmacro" "%elifn" "%elifnctx" "%elifndef" "%elifndefalias"
    "%elifndifi" "%elifndirective" "%elifnempty" "%elifnenv"
    "%elifnfile" "%elifnid" "%elifnidn" "%elifnidni" "%elifnmacro"
    "%elifnnum" "%elifnstr" "%elifntoken" "%elifnum" "%elifnusable"
    "%elifnusing" "%elifstr" "%eliftoken" "%elifusable" "%elifusing"
    "%else" "%endif" "%endm" "%endmacro" "%endrep" "%error"
    "%exitmacro" "%exitrep" "%fatal" "%iassign" "%idefalias"
    "%idefine" "%idefstr" "%ideftok" "%if" "%ifctx" "%ifdef"
    "%ifdefalias" "%ifdifi" "%ifdirective" "%ifempty" "%ifenv"
    "%iffile" "%ifid" "%ifidn" "%ifidni" "%ifmacro" "%ifn"
    "%ifnctx" "%ifndef" "%ifndefalias" "%ifndifi" "%ifndirective"
    "%ifnempty" "%ifnenv" "%ifnfile" "%ifnid" "%ifnidn" "%ifnidni"
    "%ifnmacro" "%ifnnum" "%ifnstr" "%ifntoken" "%ifnum"
    "%ifnusable" "%ifnusing" "%ifstr" "%iftoken" "%ifusable"
    "%ifusing" "%imacro" "%include" "%ipathsearch" "%irmacro"
    "%istrcat" "%istrlen" "%isubstr" "%ixdefine" "%line" "%local"
    "%macro" "%note" "%null" "%pathsearch" "%pop" "%pragma"
    "%push" "%rep" "%repl" "%require" "%rmacro" "%rotate"
    "%stacksize" "%strcat" "%strlen" "%substr" "%undef"
    "%undefalias" "%unimacro" "%unmacro" "%use" "%warning"
    "%xdefine"))

(defparameter *nasm-highlight-directives*
  (remove-duplicates
   (append *nasm-zero-column-keywords*
           '("byte" "dword" "long" "oword" "qword" "tword" "word"
             "yword" "zword"))
   :test #'string=))

(defun nasm-token-regexp (tokens)
  (format nil "(?i)\\b(?:~{~a~^|~})\\b"
          (mapcar #'ppcre:quote-meta-chars tokens)))

(defun nasm-first-token (line)
  (let ((end (position-if
              (lambda (character)
                (member character '(#\Space #\Tab)))
              line)))
    (subseq line 0 (or end (length line)))))

(defun nasm-zero-column-line-p (line)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) line)))
    (or (ppcre:scan
         "^[A-Za-z_?][A-Za-z0-9_$#@~?]*[ \\t]*:" trimmed)
        (ppcre:scan
         "^\\.[A-Za-z_?][A-Za-z0-9_$#@~?]*(?:[ \\t]*:)?(?:[ \\t;]|$)"
         trimmed)
        (ppcre:scan "^\\[" trimmed)
        (ppcre:scan "^;;+" trimmed)
        (let ((token (nasm-first-token trimmed)))
          (or (member token *nasm-zero-column-keywords* :test #'string-equal)
              (member token *nasm-preprocessor-directives*
                      :test #'string-equal))))))

(defun nasm-calc-indent (point)
  "Match pinned nasm-mode's zero-column forms and four-column code field."
  (if (nasm-zero-column-line-p (line-string point)) 0 4))

(defun nginx-calc-indent (point)
  (language-simple-indent
   point 4
   :open-pattern "\\{[ \\t]*(?:#.*)?$"
   :close-pattern "^[ \\t]*\\}"))

(defun nushell-calc-indent (point)
  (language-simple-indent
   point 2
   :open-pattern "[({\\[][ \\t]*(?:#.*)?$"
   :close-pattern "^[ \\t]*[]})]"))

(defun typst-calc-indent (point)
  (language-simple-indent
   point 4
   :open-pattern "[({\\[][ \\t]*(?://.*)?$"
   :close-pattern "^[ \\t]*[]})]"))

(defun gdscript-calc-indent (point)
  (language-simple-indent
   point 4
   :open-pattern "(?::|[({\\[])[ \\t]*(?:#.*)?$"
   :close-pattern "^[ \\t]*(?:(?:elif|else)\\b|[]})])"))

(defvar *just-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_ #\-)
           :paren-pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\]))
           :string-quote-chars '(#\" #\' #\`)
           :line-comment-string "#")))
    (set-syntax-parser
     table
     (make-configured-language-tmlanguage
      :line-comment "#"
      :strings '("\"" "'" "`")
      :keywords '("alias" "else" "export" "if" "import" "mod" "set" "shell")
      :extra-patterns
      (list
       (make-tm-match "^[A-Za-z_][A-Za-z0-9_-]*[ \\t]*:"
                      :name 'syntax-function-name-attribute)
       (make-tm-match "^[A-Za-z_][A-Za-z0-9_-]*[ \\t]*:="
                      :name 'syntax-variable-attribute))))
    table))

(defvar *nasm-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_ #\$ #\# #\@ #\? #\~ #\.)
           :paren-pairs '((#\( . #\)) (#\[ . #\]))
           :string-quote-chars '(#\" #\' #\`)
           :line-comment-string ";")))
    (set-syntax-parser
     table
     (make-configured-language-tmlanguage
      :line-comment ";"
      :strings '("\"" "'" "`")
      :extra-patterns
      (list
       (make-tm-match
        "(?i)^[ \\t]*(?:section|segment)[ \\t]+(\\.[A-Za-z0-9_$#@~.?]+)"
        :captures (vector nil (make-tm-name 'syntax-type-attribute)))
       (make-tm-match
        "^[ \\t]*([A-Za-z_?][A-Za-z0-9_$#@~?]*)[ \\t]*:"
        :captures
        (vector nil (make-tm-name 'syntax-function-name-attribute)))
       (make-tm-match
        "^[ \\t]*(\\.[A-Za-z_?][A-Za-z0-9_$#@~?]*)(?:[ \\t]*:)?"
        :captures
        (vector nil (make-tm-name 'syntax-function-name-attribute)))
       (make-tm-match "(?i)%[A-Za-z][A-Za-z0-9]*"
                      :name 'syntax-keyword-attribute)
       (make-tm-match (nasm-token-regexp *nasm-highlight-directives*)
                      :name 'syntax-keyword-attribute)
       (make-tm-match
        "(?i)\\b(?:[re]?(?:ax|bx|cx|dx|si|di|bp|sp)|[abcd][lh]|[sb]pl|[sd]il|r(?:[89]|[12][0-9]|3[01])(?:b|w|d)?|[er]ip|[cdefgs]s|(?:[xyz]mm|cr|dr)(?:[0-9]|[12][0-9]|3[01])|mm[0-7]|k[0-7]|bnd[0-3]|st[0-7]|tmm[0-7])\\b"
        :name 'syntax-variable-attribute)
       (make-tm-match
        "(?i)\\b\\$?[-+]?[0-9][-+_0-9A-FHXTQOBYE.]*\\b"
        :name 'syntax-constant-attribute)
       ;; The pinned token table contains every NASM 3.01rc0 mnemonic.  A
       ;; field-shaped matcher preserves the same visual role for new and
       ;; project-local macro instructions without embedding 41 KiB of data.
       (make-tm-match
        "(?i)(?<=\\n)[ \\t]+(?:[A-Za-z_?][A-Za-z0-9_$#@~?]*[ \\t]*:[ \\t]*)?(?:(?:a16|a32|a64|bnd|lock|o16|o32|o64|rep|repe|repne|repnz|repz|wait|xacquire|xrelease)[ \\t]+)?([A-Za-z][A-Za-z0-9_]*)"
        :captures (vector nil (make-tm-name 'syntax-builtin-attribute))))))
    table))

(defvar *meson-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_)
           :paren-pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\]))
           :string-quote-chars '(#\')
           :block-string-pairs '(("'''" . "'''"))
           :line-comment-string "#")))
    (set-syntax-parser
     table
     (make-configured-language-tmlanguage
      :line-comment "#"
      :strings '("'''" "'")
      :keywords '("and" "break" "continue" "elif" "else" "endforeach"
                  "endif" "false" "foreach" "if" "in" "not" "or" "true")
      :extra-patterns
      (list
       (make-tm-match "[A-Za-z_][A-Za-z0-9_]*(?=[ \\t]*\\()"
                      :name 'syntax-function-name-attribute)
       (make-tm-match "\\b[0-9]+(?:\\.[0-9]+)?\\b"
                      :name 'syntax-constant-attribute))))
    table))

(defvar *nginx-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_ #\- #\$)
           :paren-pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\]))
           :string-quote-chars '(#\' #\")
           :line-comment-string "#")))
    (set-syntax-parser
     table
     (make-configured-language-tmlanguage
      :line-comment "#"
      :strings '("'" "\"")
      :keywords '("break" "http" "if" "last" "location" "off" "on"
                  "permanent" "redirect" "server" "upstream")
      :extra-patterns
      (list
       (make-tm-match "\\$[A-Za-z0-9_-]+"
                      :name 'syntax-variable-attribute)
       (make-tm-match "^[ \\t]*[A-Za-z0-9_-]+"
                      :name 'syntax-keyword-attribute))))
    table))

(defvar *nushell-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_ #\- #\$)
           :paren-pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\]))
           :string-quote-chars '(#\' #\" #\`)
           :line-comment-string "#")))
    (set-syntax-parser
     table
     (make-configured-language-tmlanguage
      :line-comment "#"
      :strings '("'" "\"" "`")
      :keywords '("alias" "catch" "const" "def" "else" "error" "export"
                  "export-env" "extern" "for" "if" "in" "let" "loop"
                  "match" "module" "mut" "try" "use" "while")
      :extra-patterns
      (list
       (make-tm-match "\\$[A-Za-z_][A-Za-z0-9_-]*"
                      :name 'syntax-variable-attribute)
       (make-tm-match "\\b[0-9]+(?:\\.[0-9]+)?\\b"
                      :name 'syntax-constant-attribute))))
    table))

(defvar *typst-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_ #\-)
           :paren-pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\]))
           :string-quote-chars '(#\")
           :line-comment-string "//"
           :block-comment-pairs '(("/*" . "*/")))))
    (set-syntax-parser
     table
     (make-configured-language-tmlanguage
      :line-comment "//"
      :block-comment '("/\\*" . "\\*/")
      :strings '("\"")
      :keywords '("as" "auto" "break" "context" "continue" "else" "false"
                  "for" "if" "import" "in" "include" "let" "none" "not"
                  "return" "set" "show" "true" "while")
      :extra-patterns
      (list
       (make-tm-match "^=+[ \\t]+.*$" :name 'document-header1-attribute)
       (make-tm-match "@[A-Za-z0-9_:-]+" :name 'document-link-attribute)
       (make-tm-match "\\b[0-9]+(?:\\.[0-9]+)?\\b"
                      :name 'syntax-constant-attribute))))
    table))

(defvar *gdscript-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_ #\$)
           :paren-pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\]))
           :string-quote-chars '(#\' #\")
           :line-comment-string "#")))
    (set-syntax-parser
     table
     (make-configured-language-tmlanguage
      :line-comment "#"
      :strings '("'" "\"")
      :keywords '("and" "as" "assert" "await" "break" "breakpoint"
                  "class" "class_name" "const" "continue" "elif" "else"
                  "enum" "export" "extends" "for" "func" "if" "in" "is"
                  "match" "not" "onready" "or" "pass" "return" "self"
                  "signal" "static" "super" "tool" "var" "when" "while"
                  "yield")
      :extra-patterns
      (list
       (make-tm-match "^[ \\t]*func[ \\t]+[A-Za-z_][A-Za-z0-9_]*"
                      :name 'syntax-function-name-attribute)
       (make-tm-match "\\b(?:true|false|null)\\b"
                      :name 'syntax-constant-attribute)
       (make-tm-match "@[A-Za-z_][A-Za-z0-9_]*"
                      :name 'syntax-constant-attribute))))
    table))

(defmacro define-configured-language-mode
    (mode name syntax-table hook width comment indent-function
     &optional indent-tabs)
  `(define-major-mode ,mode lem/language-mode:language-mode
       (:name ,name
        :description ,(format nil "~a source editing" name)
        :keymap ,(intern (format nil "*~a-KEYMAP*" mode))
        :syntax-table ,syntax-table
        :mode-hook ,hook)
     (setf (variable-value 'enable-syntax-highlight) t
           (variable-value 'indent-tabs-mode) ,indent-tabs
           (variable-value 'tab-width) ,width
           (variable-value 'calc-indent-function) ',indent-function
           (variable-value 'lem/language-mode:line-comment) ,comment
           (variable-value 'lem/language-mode:insertion-line-comment)
           ,(format nil "~a " comment))))

(define-configured-language-mode
 just-mode "Just" *just-syntax-table* *just-mode-hook* 4 "#" just-calc-indent)
(define-configured-language-mode
 nasm-mode "NASM" *nasm-syntax-table* *nasm-mode-hook* 4 ";" nasm-calc-indent)
(define-configured-language-mode
 meson-mode "Meson" *meson-syntax-table* *meson-mode-hook* 2 "#" meson-calc-indent)
(define-configured-language-mode
 nginx-mode "nginx" *nginx-syntax-table* *nginx-mode-hook* 4 "#" nginx-calc-indent)
(define-configured-language-mode
 nushell-mode "Nushell" *nushell-syntax-table* *nushell-mode-hook* 2 "#" nushell-calc-indent)
(define-configured-language-mode
 typst-mode "Typst" *typst-syntax-table* *typst-mode-hook* 4 "//" typst-calc-indent)
(define-configured-language-mode
 gdscript-mode "GDScript" *gdscript-syntax-table* *gdscript-mode-hook*
 4 "#" gdscript-calc-indent t)

(define-file-associations just-mode
  ((:file-namestring "Justfile")
   (:file-namestring "justfile")
   (:file-namestring ".Justfile")
   (:file-namestring ".justfile")))
(define-file-type ("nasm") nasm-mode)
(define-file-associations meson-mode
  ((:file-namestring "meson.build")
   (:file-namestring "meson_options.txt")
   (:file-namestring "meson.options")))
(define-file-associations nginx-mode
  ((:file-namestring "nginx.conf")))
(define-file-type ("nu") nushell-mode)
(define-file-type ("typ") typst-mode)
(define-file-type ("gd") gdscript-mode)
(define-program-name-with-mode ("nu") nushell-mode)

(defun nasm-mnemonic-before-point-p (point)
  (with-point ((start point))
    (back-to-indentation start)
    (ppcre:scan
     "(?i)^(?:(?:a16|a32|a64|bnd|lock|o16|o32|o64|rep|repe|repne|repnz|repz|wait|xacquire|xrelease)[ \\t]+)?[A-Za-z][A-Za-z0-9_]*$"
     (points-to-string start point))))

(define-command nasm-tab () ()
  (if (nasm-mnemonic-before-point-p (current-point))
      (insert-character (current-point) #\Tab)
      (indent-line (current-point))))

(define-command nasm-colon () ()
  (insert-character (current-point) #\:)
  (indent-line (current-point)))

(define-key *nasm-mode-keymap* "Tab" 'nasm-tab)
(define-key *nasm-mode-keymap* ":" 'nasm-colon)

(defun language-mode-buffer-prefix (buffer limit)
  (with-point ((start (buffer-start-point buffer))
               (end (buffer-end-point buffer)))
    (let ((length (1- (position-at-point end))))
      (move-point end start)
      (character-offset end (min limit length)))
    (points-to-string start end)))

(defun nginx-magic-buffer-p (buffer)
  (and (eq (buffer-major-mode buffer)
           'lem/buffer/fundamental-mode:fundamental-mode)
       (cl-ppcre:scan
        "(?m)^[ \\t]*(?:http|server|location[ \\t]+.+|upstream[ \\t]+.+)[ \\t]+\\{"
        (language-mode-buffer-prefix buffer 65536))))

(defun configured-language-path-mode (buffer)
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (let* ((pathname (pathname filename))
           (name (string-downcase (file-namestring pathname)))
           (path (string-downcase (namestring pathname))))
      (cond
        ((member name '("justfile" ".justfile") :test #'string=)
         'just-mode)
        ((cl-ppcre:scan "(?:^|/)nginx/.+\\.conf$" path)
         'nginx-mode)
        ((nginx-magic-buffer-p buffer)
         'nginx-mode)))))

(defun ensure-configured-language-path-mode (buffer)
  "Apply the pinned modes' filename-regexp and nginx magic associations."
  (unless (so-long-buffer-active-p buffer)
    (alexandria:when-let ((mode (configured-language-path-mode buffer)))
      (unless (eq mode (buffer-major-mode buffer))
        (change-buffer-mode buffer mode)))))

(remove-hook *find-file-hook* 'ensure-configured-language-path-mode)
;; Core file association processing runs at 5000.  This narrower regexp/magic
;; layer follows it and precedes formatting/project feature hooks.
(add-hook *find-file-hook* 'ensure-configured-language-path-mode 4000)
