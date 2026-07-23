;;;; Native C# editing mode for the configured csharp-mode/eglot workflow.

(in-package :lem-yath)

(defparameter *csharp-keywords*
  '("abstract" "add" "alias" "and" "as" "ascending" "async" "await"
    "base" "bool" "break" "by" "byte" "case" "catch" "char" "checked"
    "class" "const" "continue" "decimal" "default" "delegate" "descending"
    "do" "double" "dynamic" "else" "enum" "equals" "event" "explicit"
    "extern" "false" "file" "finally" "fixed" "float" "for" "foreach"
    "from" "get" "global" "goto" "group" "if" "implicit" "in" "init"
    "int" "interface" "internal" "into" "is" "join" "let" "lock" "long"
    "managed" "namespace" "new" "nint" "not" "notnull" "nuint" "null"
    "object" "on" "operator" "or" "orderby" "out" "override" "params"
    "partial" "private" "protected" "public" "readonly" "record" "ref"
    "remove" "required" "return" "sbyte" "scoped" "sealed" "select"
    "set" "short" "sizeof" "stackalloc" "static" "string" "struct"
    "switch" "this" "throw" "true" "try" "typeof" "uint" "ulong"
    "unchecked" "unmanaged" "unsafe" "ushort" "using" "value" "var"
    "virtual" "void" "volatile" "when" "where" "while" "with" "yield"))

(defparameter *csharp-operators*
  '("=>" "??=" "??" "?." "::" "++" "--" "&&" "||" "==" "!="
    "<=" ">=" "<<=" ">>=" "+=" "-=" "*=" "/=" "%=" "&=" "|="
    "^=" "<<" ">>" "=" "+" "-" "*" "/" "%" "&" "|" "^" "!"
    "~" "<" ">" "?" ":"))

(defun csharp-token-pattern (boundary strings)
  (let ((alternation
          `(:alternation ,@(sort (copy-list strings) #'> :key #'length))))
    (if boundary
        `(:sequence ,boundary ,alternation ,boundary)
        alternation)))

(defun make-csharp-tmlanguage ()
  (make-tmlanguage
   :patterns
   (make-tm-patterns
    (lem/language-mode-tools:make-tm-line-comment-region "//")
    (lem/language-mode-tools:make-tm-block-comment-region "/\\*" "\\*/")
    (lem/language-mode-tools:make-tm-string-region "'")
    (lem/language-mode-tools:make-tm-string-region "\"")
    (make-tm-match (csharp-token-pattern :word-boundary *csharp-keywords*)
                   :name 'syntax-keyword-attribute)
    (make-tm-match (csharp-token-pattern nil *csharp-operators*)
                   :name 'syntax-builtin-attribute))))

(defvar *csharp-syntax-table*
  (let ((table
          (make-syntax-table
           :space-chars '(#\Space #\Tab #\Newline)
           :symbol-chars '(#\_)
           :paren-pairs '((#\( . #\)) (#\{ . #\}) (#\[ . #\]))
           :string-quote-chars '(#\" #\')
           :line-comment-string "//")))
    (set-syntax-parser table (make-csharp-tmlanguage))
    table))

(define-major-mode csharp-mode lem/language-mode:language-mode
    (:name "C#"
     :description "C# source editing"
     :keymap *csharp-mode-keymap*
     :syntax-table *csharp-syntax-table*
     :mode-hook *csharp-mode-hook*)
  (setf (variable-value 'enable-syntax-highlight) t
        (variable-value 'indent-tabs-mode) nil
        (variable-value 'calc-indent-function) 'lem-c-mode::calc-indent
        (variable-value 'tab-width) 4
        (variable-value 'lem/language-mode:line-comment) "//"
        (variable-value 'lem/language-mode:insertion-line-comment) "//"))

(define-file-type ("cs" "csx") csharp-mode)
