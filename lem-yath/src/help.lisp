;;;; Helpful-style callable and variable inspection with typed prompt metadata.

(in-package :lem-yath)

(defparameter *help-variable-censor-patterns*
  '("pass" "auth-source-netrc-cache" "auth-source-.*-nonce" "api-?key")
  "Marginalia-compatible variable-name patterns whose values stay hidden.")

(defvar *help-command-symbols* nil)

(defun help-symbol-label (symbol)
  (format nil "~a::~a"
          (package-name (symbol-package symbol))
          (symbol-name symbol)))

(defun help-symbol-candidates (predicate)
  "Return unique qualified labels paired with symbols satisfying PREDICATE."
  (let ((table (make-hash-table :test 'equal)))
    (do-all-symbols (symbol)
      (when (and (symbol-package symbol) (funcall predicate symbol))
        (setf (gethash (help-symbol-label symbol) table) symbol)))
    (sort (loop :for label :being :each :hash-key :of table
                  :using (hash-value symbol)
                :collect (cons label symbol))
          #'string-lessp :key #'car)))

(defun help-symbol-choice (label candidates)
  (cdr (assoc label candidates :test #'string=)))

(defun help-callable-function (symbol)
  (or (macro-function symbol)
      (and (fboundp symbol) (symbol-function symbol))))

(defun help-command-symbol-p (symbol)
  (and *help-command-symbols* (gethash symbol *help-command-symbols*)))

(defun help-command-symbol-table ()
  (let ((table (make-hash-table :test 'eq)))
    (dolist (name (all-command-names) table)
      (setf (gethash
             (lem/common/command:command-name (find-command name)) table)
            t))))

(defun help-callable-type (symbol)
  (cond
    ((help-command-symbol-p symbol) "command")
    ((macro-function symbol) "macro")
    ((typep (help-callable-function symbol) 'generic-function) "generic")
    (t "function")))

(defun help-callable-lambda-list (symbol)
  (handler-case
      (alexandria:when-let* ((package
                              (or (find-package "SB-INTROSPECT")
                                  (progn
                                    (require :sb-introspect)
                                    (find-package "SB-INTROSPECT"))))
                             (name (find-symbol "FUNCTION-LAMBDA-LIST" package))
                             (function-name (and name (fboundp name) name)))
        (let ((*package* (symbol-package symbol)))
          (prin1-to-string
           (funcall function-name (help-callable-function symbol)))))
    (error () nil)))

(defun help-symbol-documentation (symbol kind)
  (completion-first-documentation-line
   (ignore-errors (documentation symbol kind))))

(defun help-callable-detail (symbol)
  (completion-join-annotation-fields
   (help-callable-type symbol)
   (completion-field
    (help-callable-lambda-list symbol) :truncate 0.5)
   (completion-field
    (help-symbol-documentation symbol 'function) :truncate 1.0)))

(defun help-sensitive-variable-p (symbol)
  (let ((name (string-downcase (help-symbol-label symbol))))
    (some (lambda (pattern) (ppcre:scan pattern name))
          *help-variable-censor-patterns*)))

(defun help-variable-value (symbol)
  "Return a bounded, one-line display of SYMBOL's value without leaking secrets."
  (cond
    ((help-sensitive-variable-p symbol) "*****")
    ((not (boundp symbol)) "#<UNBOUND>")
    (t
     (handler-case
         (let ((value (symbol-value symbol)))
           (typecase value
             (null "NIL")
             (hash-table "#<HASH-TABLE>")
             (stream "#<STREAM>")
             (function "#<FUNCTION>")
             (package (format nil "#<PACKAGE ~a>" (package-name value)))
             (t
              (let ((*package* (symbol-package symbol))
                    (*print-circle* t)
                    (*print-escape* t)
                    (*print-level* 3)
                    (*print-length* 8))
                (completion-bounded-annotation (prin1-to-string value))))))
       (error () "#<UNPRINTABLE>")))))

(defun help-variable-detail (symbol)
  (completion-join-annotation-fields
   (if (constantp symbol) "constant" "variable")
   (completion-field (help-variable-value symbol) :truncate 0.5)
   (completion-field
    (help-symbol-documentation symbol 'variable) :truncate 1.0)))

(defun help-prompt-symbol (prompt candidates detail-function category)
  (let ((choice
          (prompt-for-string
           prompt
           :completion-function
           (lambda (input)
             (completion-annotated-prompt-choices
              (prescient-filter input candidates
                                :key #'car
                                :category category)
              detail-function))
           :test-function
           (lambda (input)
             (help-symbol-choice input candidates)))))
    (help-symbol-choice choice candidates)))

(defun help-render-callable (symbol)
  (with-pop-up-typeout-window
      (out (make-buffer "*Callable Help*") :erase t)
    (format out "~a~2%Type: ~a~%"
            (help-symbol-label symbol)
            (help-callable-type symbol))
    (alexandria:when-let ((lambda-list (help-callable-lambda-list symbol)))
      (format out "Arguments: ~a~%" lambda-list))
    (format out "Package: ~a~2%~a~%"
            (package-name (symbol-package symbol))
            (or (ignore-errors (documentation symbol 'function))
                "No documentation is available."))))

(defun help-render-variable (symbol)
  (with-pop-up-typeout-window
      (out (make-buffer "*Variable Help*") :erase t)
    (format out "~a~2%Type: ~a~%Value: ~a~%Package: ~a~2%~a~%"
            (help-symbol-label symbol)
            (if (constantp symbol) "constant" "variable")
            (help-variable-value symbol)
            (package-name (symbol-package symbol))
            (or (ignore-errors (documentation symbol 'variable))
                "No documentation is available."))))

(define-command lem-yath-describe-callable () ()
  "Choose and describe any currently defined Lisp callable."
  (let ((*help-command-symbols* (help-command-symbol-table)))
    (let* ((candidates (help-symbol-candidates #'fboundp))
           (symbol (help-prompt-symbol
                    "Callable: " candidates #'help-callable-detail :function)))
      (when symbol (help-render-callable symbol)))))

(define-command lem-yath-describe-variable () ()
  "Choose and describe any currently bound Lisp variable."
  (let* ((candidates (help-symbol-candidates #'boundp))
         (symbol (help-prompt-symbol
                  "Variable: " candidates #'help-variable-detail :variable)))
    (when symbol (help-render-variable symbol))))
