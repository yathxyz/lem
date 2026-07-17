;;;; Generic Imenu parity for the configured Emacs workflows.
;;;;
;;;; Eglot replaces a mode's native Imenu index with document symbols whenever
;;;; the server advertises that provider.  Otherwise the Lisp-family modes use
;;;; GNU Emacs's pinned `lisp-imenu-generic-expression' definition forms.  The
;;;; default `imenu-flatten' is nil, so groups and document-symbol parents open
;;;; successive prompts rather than being collapsed into one completion row.

(in-package :lem-yath)

(defparameter *imenu-lisp-function-forms*
  '("defun" "defmacro" "defun*" "defsubst" "define-inline"
    "define-advice" "defadvice" "define-skeleton"
    "define-compilation-mode" "define-minor-mode"
    "define-globalized-minor-mode" "define-derived-mode"
    "define-generic-mode" "ert-deftest" "cl-defun" "cl-defsubst"
    "cl-defmacro" "cl-define-compiler-macro" "cl-defgeneric"
    "cl-defmethod" "define-compiler-macro" "define-modify-macro"
    "defsetf" "define-setf-expander" "define-method-combination"
    "defgeneric" "defmethod"))

(defparameter *imenu-lisp-quoted-function-forms*
  '("defalias" "define-obsolete-function-alias"))

(defparameter *imenu-lisp-variable-forms*
  '("defconst" "defcustom" "defvar-keymap" "defconstant"
    "defparameter" "define-symbol-macro"))

(defparameter *imenu-lisp-type-forms*
  '("defgroup" "deftheme" "define-widget" "define-error" "defface"
    "cl-deftype" "cl-defstruct" "oclosure-define" "deftype"
    "defstruct" "define-condition" "defpackage" "defclass"))

(defstruct imenu-candidate
  label
  detail
  group
  children
  point)

(defstruct imenu-session
  source-buffer
  source-window
  candidates
  selected)

(defparameter *imenu-prompt-keymap*
  (let ((keymap (make-keymap :description "Imenu prompt")))
    (define-key keymap "C-g" 'lem/prompt-window::prompt-quit)
    (define-key keymap "Escape" 'lem/prompt-window::prompt-quit)
    keymap))

(defun imenu-delete-candidates (candidates)
  (dolist (candidate candidates)
    (imenu-delete-candidates (imenu-candidate-children candidate))
    (alexandria:when-let ((point (imenu-candidate-point candidate)))
      (ignore-errors (delete-point point)))))

;;; --- Eglot document symbols ---------------------------------------------

(defun imenu-lsp-sequence-list (value)
  (unless (or (null value) (lem-lsp-base/type:lsp-null-p value))
    (map 'list #'identity value)))

(defun imenu-document-symbol-children (symbol)
  (imenu-lsp-sequence-list
   (handler-case (lsp:document-symbol-children symbol)
     (unbound-slot () nil))))

(defun imenu-point-for-position (buffer workspace position)
  (let ((point (copy-point (buffer-start-point buffer))))
    (if (lem-lsp-mode::move-to-workspace-position point position workspace)
        point
        (progn
          (delete-point point)
          nil))))

(defun imenu-kind-name (kind)
  (or (nth-value 0
                 (lem-lsp-mode::symbol-kind-to-string-and-attribute kind))
      "Unknown"))

(defun imenu-document-symbol-candidates
    (workspace buffer symbols)
  (let ((candidates '()))
    (dolist (symbol symbols candidates)
      (let* ((name (lsp:document-symbol-name symbol))
             (kind (imenu-kind-name (lsp:document-symbol-kind symbol)))
             (children
               (imenu-document-symbol-children symbol)))
        (if children
            (setf candidates
                  (nconc candidates
                         (list
                          (make-imenu-candidate
                           :label name
                           :detail (format nil "[~a]" kind)
                           :group kind
                           :children
                           (imenu-document-symbol-candidates
                            workspace buffer children)))))
            (let* ((range (lsp:document-symbol-range symbol))
                   (point (imenu-point-for-position
                           buffer workspace (lsp:range-start range))))
              (when point
                (setf candidates
                      (nconc
                       candidates
                       (list
                        (make-imenu-candidate
                         :label name
                         :detail (format nil "[~a] line ~d"
                                         kind
                                         (line-number-at-point point))
                         :group kind
                         :point point)))))))))))

(defun imenu-current-document-location-p (buffer symbol)
  (let ((file (workspace-symbol-location-pathname symbol))
        (buffer-file (buffer-filename buffer)))
    (and file buffer-file
         (ignore-errors (uiop:pathname-equal file buffer-file)))))

(defun imenu-symbol-information-candidates (workspace buffer symbols)
  (labels ((append-child (parent child)
             (setf (imenu-candidate-children parent)
                   (nconc (imenu-candidate-children parent) (list child))))
           (find-or-add-parent (label parents)
             (alexandria:if-let
                 ((parent
                    (find label parents :key #'imenu-candidate-label
                                        :test #'string=)))
               (values parent parents)
               (let ((parent
                       (make-imenu-candidate
                        :label label)))
                 (setf parents (nconc parents (list parent)))
                 (values parent parents)))))
    (let ((kind-parents '()))
      (dolist (symbol symbols kind-parents)
        (when (and (typep symbol 'lsp:symbol-information)
                   (imenu-current-document-location-p buffer symbol))
          (let* ((location (workspace-symbol-location symbol))
                 (point
                   (and (typep location 'lsp:location)
                        (imenu-point-for-position
                         buffer workspace
                         (lsp:range-start (lsp:location-range location))))))
            (when point
              (let* ((name (lsp:base-symbol-information-name symbol))
                     (kind (workspace-symbol-kind-name symbol))
                     (container (workspace-symbol-container symbol))
                     (leaf
                       (make-imenu-candidate
                        :label name
                        :detail (format nil "line ~d"
                                        (line-number-at-point point))
                        :group kind
                        :point point)))
                (multiple-value-bind (kind-parent updated-parents)
                    (find-or-add-parent kind kind-parents)
                  (setf kind-parents updated-parents)
                  (if container
                      (multiple-value-bind
                          (container-parent updated-children)
                          (find-or-add-parent
                           container (imenu-candidate-children kind-parent))
                        (setf (imenu-candidate-children kind-parent)
                              updated-children)
                        (append-child container-parent leaf))
                      (append-child kind-parent leaf)))))))))))

(defun imenu-lsp-candidates (buffer)
  "Return candidates and true when Eglot-style document symbols apply."
  (let ((workspace (lem-lsp-mode::buffer-workspace buffer nil)))
    (if (and workspace
             (eq :ready (lem-lsp-mode::workspace-state workspace))
             (lem-lsp-mode::provide-document-symbol-p workspace))
        (let* ((response (lem-lsp-mode::text-document/document-symbol buffer))
               (symbols (imenu-lsp-sequence-list response))
               (head (first symbols)))
          (values
           (typecase head
             (lsp:document-symbol
              (imenu-document-symbol-candidates workspace buffer symbols))
             (lsp:symbol-information
              (imenu-symbol-information-candidates workspace buffer symbols))
             (t nil))
           t))
        (values nil nil))))

;;; --- pinned GNU Emacs Lisp Imenu grammar --------------------------------

(defun imenu-lisp-form-classification (operator)
  (cond
    ((member operator *imenu-lisp-function-forms* :test #'string=)
     (values nil :unquoted nil))
    ((member operator *imenu-lisp-quoted-function-forms* :test #'string=)
     (values nil :quoted nil))
    ((member operator *imenu-lisp-variable-forms* :test #'string=)
     (values "Variables" :unquoted nil))
    ((member operator '("defvar" "defvar-local") :test #'string=)
     (values "Variables" :unquoted t))
    ((member operator *imenu-lisp-type-forms* :test #'string=)
     (values "Types" :optional-quote nil))))

(defun imenu-lisp-name-point (point quote-policy)
  (skip-whitespace-forward point)
  (case quote-policy
    (:quoted
     (unless (eql (character-at point) #\')
       (return-from imenu-lisp-name-point nil))
     (character-offset point 1))
    (:optional-quote
     (when (eql (character-at point) #\')
       (character-offset point 1))))
  (and (symbol-string-at-point point) point))

(defun imenu-lisp-defvar-has-value-p (name-point)
  ;; This intentionally matches the pinned regexp: whitespace after the name
  ;; must be followed by something other than the form's closing parenthesis.
  (with-point ((point name-point))
    (skip-chars-forward point #'syntax-symbol-char-p)
    (let ((before (copy-point point :temporary)))
      (unwind-protect
           (progn
             (skip-whitespace-forward point)
             (and (not (point= before point))
                  (let ((character (character-at point)))
                    (and character (char/= character #\))))))
        (delete-point before)))))

(defun imenu-lisp-line-candidate (line-point)
  (with-point ((point line-point))
    (skip-whitespace-forward point t)
    (unless (and (eql (character-at point) #\()
                 (not (in-string-or-comment-p point)))
      (return-from imenu-lisp-line-candidate nil))
    (character-offset point 1)
    (let ((operator (symbol-string-at-point point)))
      (unless operator
        (return-from imenu-lisp-line-candidate nil))
      (setf operator (string-downcase operator))
      (skip-chars-forward point #'syntax-symbol-char-p)
      (unless (and (character-at point)
                   (syntax-space-char-p (character-at point)))
        (return-from imenu-lisp-line-candidate nil))
      (multiple-value-bind (group quote-policy require-value-p)
          (imenu-lisp-form-classification operator)
        (unless quote-policy
          (return-from imenu-lisp-line-candidate nil))
        (let ((name-point (imenu-lisp-name-point point quote-policy)))
          (unless name-point
            (return-from imenu-lisp-line-candidate nil))
          (let ((name (symbol-string-at-point name-point)))
            (when (and require-value-p
                       (not (imenu-lisp-defvar-has-value-p name-point)))
              (return-from imenu-lisp-line-candidate nil))
            (make-imenu-candidate
             :label name
             :detail (format nil "[~a] line ~d"
                             operator (line-number-at-point name-point))
             :group group
             :point (copy-point name-point))))))))

(defun imenu-lisp-candidates (buffer)
  (let ((raw-candidates '()))
    (with-current-buffer buffer
      (with-point ((line (buffer-start-point buffer)))
        (loop
          (alexandria:when-let ((candidate (imenu-lisp-line-candidate line)))
            (push candidate raw-candidates))
          (unless (line-offset line 1) (return)))))
    (setf raw-candidates (nreverse raw-candidates))
    (let ((functions
            (remove-if #'imenu-candidate-group raw-candidates))
          (variables
            (remove-if-not
             (lambda (candidate)
               (equal "Variables" (imenu-candidate-group candidate)))
             raw-candidates))
          (types
            (remove-if-not
             (lambda (candidate)
               (equal "Types" (imenu-candidate-group candidate)))
             raw-candidates)))
      (nconc
       functions
       (when variables
         (list (make-imenu-candidate
                :label "Variables"
                :children variables)))
       (when types
         (list (make-imenu-candidate
                :label "Types"
                :children types)))))))

(defun imenu-candidates (buffer)
  (multiple-value-bind (candidates lsp-applicable-p)
      (imenu-lsp-candidates buffer)
    (cond
      (lsp-applicable-p candidates)
      ((structural-language-buffer-p buffer)
       (imenu-lisp-candidates buffer))
      (t nil))))

;;; --- completion and jump -------------------------------------------------

(defun imenu-display-label (candidate)
  ;; Match GNU Imenu's default `imenu-space-replacement' value.
  (substitute #\. #\space (imenu-candidate-label candidate)))

(defun imenu-completion-item (session candidate)
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (lem/prompt-window::current-prompt-start-point)))
    (let ((candidate candidate))
      (lem/completion-mode:make-completion-item
       :label (imenu-display-label candidate)
       :insert-text (imenu-display-label candidate)
       :filter-text (imenu-display-label candidate)
       :detail (imenu-candidate-detail candidate)
       :start start
       :end (line-end end)
       :accept-action
       (lambda ()
         (setf (imenu-session-selected session) candidate))))))

(defun imenu-completion-items (session candidates input)
  (mapcar
   (lambda (candidate) (imenu-completion-item session candidate))
   (prescient-filter
    input
    candidates
    :key #'imenu-display-label
    :category :imenu
    :rank-p t)))

(defun imenu-read-level (session candidates initial-value)
  (setf (imenu-session-selected session) nil)
  (prompt-for-string
   "Index item: "
   :initial-value initial-value
   :completion-function
   (lambda (input) (imenu-completion-items session candidates input))
   :test-function
   (lambda (input)
     (alexandria:when-let ((selected (imenu-session-selected session)))
       (string= input (imenu-display-label selected))))
   :history-symbol 'lem-yath-imenu
   :special-keymap *imenu-prompt-keymap*)
  (imenu-session-selected session))

(defun imenu-read-candidate (session initial-value)
  (loop
    :with candidates = (imenu-session-candidates session)
    :with initial = initial-value
    :for selected = (imenu-read-level session candidates initial)
    :do (unless selected (return nil))
        (if (imenu-candidate-children selected)
            (setf candidates (imenu-candidate-children selected)
                  initial "")
            (return selected))))

(defun imenu-final-jump (session candidate)
  (let ((window (imenu-session-source-window session))
        (buffer (imenu-session-source-buffer session))
        (point (imenu-candidate-point candidate)))
    (unless (and (project-picker-live-window-p window)
                 (project-picker-live-buffer-p buffer)
                 (alive-point-p point))
      (editor-error "The selected Imenu destination is no longer available"))
    (with-current-window window
      (unless (eq (current-buffer) buffer)
        (lem-core::%switch-to-buffer buffer nil nil))
      (lem-vi-mode/jumplist:with-jumplist
        (move-point (buffer-point buffer) point))
      ;; The configured `imenu-after-jump-hook' only recenters.  Pulsar's
      ;; Consult hook is deliberately not part of this command path.
      (window-recenter window))))

(define-command imenu () ()
  "Select a current-buffer definition using Eglot or Lisp Imenu data."
  (let* ((buffer (current-buffer))
         (candidates (imenu-candidates buffer)))
    (unless candidates
      (editor-error "No Imenu index items in this buffer"))
    (let ((session (make-imenu-session
                    :source-buffer buffer
                    :source-window (current-window)
                    :candidates candidates)))
      (unwind-protect
           (alexandria:when-let
               ((selected
                  (imenu-read-candidate
                   session (or (symbol-string-at-point (current-point)) ""))))
             (imenu-final-jump session selected))
        (imenu-delete-candidates candidates)))))
