;;;; Helpful-style callable, variable, face, and key inspection.
;;;;
;;;; Completion rows retain the Marginalia-style metadata from the original
;;;; port.  Accepted symbols open ordinary read-only buffers whose source and
;;;; cross-reference rows can be traversed and visited like Helpful buttons.

(in-package :lem-yath)

(defparameter *help-variable-censor-patterns*
  '("pass" "auth-source-netrc-cache" "auth-source-.*-nonce" "api-?key")
  "Marginalia-compatible variable-name patterns whose values stay hidden.")

(defparameter *help-xref-limit* 200
  "Maximum caller or reference locations rendered in one help buffer.")

(defparameter *help-source-scan-limit* (* 16 1024 1024)
  "Maximum source size read to recover a missing top-level character offset.")

(defvar *help-command-symbols* nil)

(defun help-symbol-label (symbol)
  (alexandria:if-let ((package (symbol-package symbol)))
    (format nil "~a::~a" (package-name package) (symbol-name symbol))
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
  (or (and *help-command-symbols*
           (gethash symbol *help-command-symbols*))
      (ignore-errors
        (not (null (lem/common/command:get-command symbol))))))

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

(defun help-face-attribute (symbol)
  "Return SYMBOL's effective attribute under the current theme, or NIL."
  (ignore-errors (ensure-attribute symbol nil)))

(defun help-face-candidates ()
  "Return unique qualified labels for the currently defined Lem faces."
  (sort
   (loop :for symbol :in (remove-duplicates lem-core::*attributes* :test #'eq)
         :when (and (symbolp symbol)
                    (symbol-package symbol)
                    (help-face-attribute symbol))
           :collect (cons (help-symbol-label symbol) symbol))
   #'string-lessp :key #'car))

(defun help-face-value-string (value)
  (cond
    ((null value) "default")
    ((stringp value) value)
    ((typep value 'lem/common/color:color)
     (lem/common/color:color-to-hex-string value))
    (t (princ-to-string value))))

(defun help-face-style-fields (symbol)
  "Return bounded human-readable fields for SYMBOL's effective face."
  (alexandria:when-let ((attribute (help-face-attribute symbol)))
    (remove
     nil
     (list
      (format nil "fg ~a"
              (help-face-value-string
               (lem-core:attribute-foreground attribute)))
      (format nil "bg ~a"
              (help-face-value-string
               (lem-core:attribute-background attribute)))
      (and (lem-core:attribute-bold attribute) "bold")
      (and (lem-core:attribute-reverse attribute) "reverse")
      (alexandria:when-let ((underline
                             (lem-core:attribute-underline attribute)))
        (if (eq underline t)
            "underline"
            (format nil "underline ~a"
                    (help-face-value-string underline))))))))

(defun help-face-detail (symbol)
  (apply #'completion-join-annotation-fields
         "AaBbYyZz"
         (help-face-style-fields symbol)))

(defun help-face-theme-origin (symbol)
  "Return the current theme layer and raw specification for SYMBOL."
  (loop :for name := (current-theme)
          :then (and theme (lem-core::color-theme-parent theme))
        :while name
        :for theme := (find-color-theme name)
        :for specification :=
          (and theme (assoc symbol (lem-core::color-theme-specs theme)))
        :when specification
          :return (values name (rest specification))))

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

;;; --- SBCL source and cross-reference data ---------------------------------

(defun help-introspection-function (name)
  "Return SB-INTROSPECT function NAME without a read-time package dependency."
  (handler-case
      (let* ((package (or (find-package "SB-INTROSPECT")
                          (progn
                            (require :sb-introspect)
                            (find-package "SB-INTROSPECT"))))
             (symbol (and package (find-symbol name package))))
        (and symbol (fboundp symbol) (symbol-function symbol)))
    (error () nil)))

(defun help-introspection-call (name &rest arguments)
  (alexandria:when-let ((function (help-introspection-function name)))
    (handler-case (apply function arguments)
      (error () nil))))

(defun help-source-layout-character-p (character)
  (find character '(#\Space #\Tab #\Newline #\Return #\Page)))

(defun help-source-skip-block-comment (text position)
  "Return the position after a nested #|...|# comment, or NIL if incomplete."
  (let ((depth 1)
        (length (length text)))
    (loop :while (< position length)
          :do (cond
                ((and (< (1+ position) length)
                      (char= (char text position) #\#)
                      (char= (char text (1+ position)) #\|))
                 (incf depth)
                 (incf position 2))
                ((and (< (1+ position) length)
                      (char= (char text position) #\|)
                      (char= (char text (1+ position)) #\#))
                 (decf depth)
                 (incf position 2)
                 (when (zerop depth) (return position)))
                (t (incf position))))))

(defun help-source-skip-layout (text position)
  "Skip Lisp whitespace and comments in TEXT from POSITION."
  (let ((length (length text)))
    (loop
      (loop :while (and (< position length)
                        (help-source-layout-character-p
                         (char text position)))
            :do (incf position))
      (cond
        ((>= position length) (return position))
        ((char= (char text position) #\;)
         (alexandria:if-let
             ((newline (position #\Newline text :start position)))
           (setf position (1+ newline))
           (return length)))
        ((and (< (1+ position) length)
              (char= (char text position) #\#)
              (char= (char text (1+ position)) #\|))
         (alexandria:if-let
             ((next (help-source-skip-block-comment text (+ position 2))))
           (setf position next)
           (return position)))
        (t (return position))))))

(defun help-definition-source-form-offset (source pathname)
  "Derive a character offset from SOURCE's zero-based top-level form path."
  (let* ((path
           (help-introspection-call "DEFINITION-SOURCE-FORM-PATH" source))
         (target (and (consp path) (first path))))
    (when (and (integerp target) (not (minusp target)))
      (handler-case
          (let ((text
                  (with-open-file (stream pathname :direction :input)
                    (let ((size (file-length stream)))
                      (when (and (integerp size)
                                 (<= size *help-source-scan-limit*))
                        (uiop:read-file-string pathname)))))
                (position 0)
                (eof (gensym "HELP-SOURCE-EOF")))
            (when text
              (loop :for index :from 0
                    :for start := (help-source-skip-layout text position)
                    :when (= index target) :return start
                    :do (let ((*read-eval* nil)
                              (*read-suppress* t)
                              (*readtable* (copy-readtable nil)))
                          (multiple-value-bind (value next)
                              (read-from-string text nil eof :start start)
                            (declare (ignore value))
                            (unless (and next (> next start))
                              (return nil))
                            (setf position next))))))
        (error () nil)))))

(defun help-definition-source-location (source label)
  "Convert an SB-INTROSPECT SOURCE into a stable, visitable location plist."
  (when source
    (let* ((raw-path
             (help-introspection-call "DEFINITION-SOURCE-PATHNAME" source))
           (pathname
             (and raw-path
                  (ignore-errors (truename raw-path))))
           (offset
             (or (help-introspection-call
                  "DEFINITION-SOURCE-CHARACTER-OFFSET" source)
                 (and pathname
                      (help-definition-source-form-offset source pathname))))
           (write-date
             (and pathname
                  (ignore-errors (file-write-date pathname)))))
      (when (and pathname
                 (uiop:file-exists-p pathname)
                 (not (uiop:directory-exists-p pathname))
                 (integerp offset)
                 (not (minusp offset))
                 (integerp write-date))
        (list :label label
              :pathname pathname
              :offset offset
              :write-date write-date)))))

(defun help-definition-source-by-name (symbol types)
  (loop :for type :in types
        :for sources :=
          (help-introspection-call
           "FIND-DEFINITION-SOURCES-BY-NAME" symbol type)
        :when sources :return (first sources)))

(defun help-callable-definition-location (symbol)
  (let ((source
          (or (help-introspection-call
               "FIND-DEFINITION-SOURCE" (help-callable-function symbol))
              (help-definition-source-by-name
               symbol
               (cond
                 ((macro-function symbol) '(:macro :function))
                 ((typep (help-callable-function symbol) 'generic-function)
                  '(:generic-function :function))
                 (t '(:function)))))))
    (help-definition-source-location source (help-symbol-label symbol))))

(defun help-variable-definition-location (symbol)
  (help-definition-source-location
   (help-definition-source-by-name
    symbol (if (constantp symbol) '(:constant :variable) '(:variable)))
   (help-symbol-label symbol)))

(defun help-xref-name-label (name)
  (cond
    ((symbolp name) (help-symbol-label name))
    (t
     (let ((*package* (find-package :keyword))
           (*print-escape* t)
           (*print-pretty* nil))
       (prin1-to-string name)))))

(defun help-location-key (location)
  (list (getf location :label)
        (namestring (getf location :pathname))
        (getf location :offset)))

(defun help-xref-locations (symbol operation)
  "Return bounded, source-backed cross references for SYMBOL."
  (let ((seen (make-hash-table :test 'equal))
        (locations '()))
    (dolist (entry (help-introspection-call operation symbol))
      (when (consp entry)
        (alexandria:when-let
            ((location
               (help-definition-source-location
                (cdr entry) (help-xref-name-label (car entry)))))
          (let ((key (help-location-key location)))
            (unless (gethash key seen)
              (setf (gethash key seen) t)
              (push location locations)
              (when (>= (length locations) *help-xref-limit*)
                (return)))))))
    (nreverse locations)))

;;; --- navigable help buffer -------------------------------------------------

(defun help-buffer-p (&optional (buffer (current-buffer)))
  (eq (buffer-major-mode buffer) 'lem-yath-help-mode))

(define-major-mode lem-yath-help-mode nil
    (:name "Helpful"
     :keymap *lem-yath-help-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t)
  (buffer-disable-undo (current-buffer)))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode lem-yath-help-mode))
  (declare (ignore mode))
  (list *lem-yath-help-mode-keymap*))

(defun help-insert (point control &rest arguments)
  (insert-string point (apply #'format nil control arguments)))

(defun help-location-display (location &optional full-path-p)
  (format nil "~a @ character ~d"
          (if full-path-p
              (namestring (getf location :pathname))
              (file-namestring (getf location :pathname)))
          (getf location :offset)))

(defun help-insert-location-row (point text location)
  (with-point ((start point))
    (insert-string point text)
    (put-text-property start point :lem-yath-help-location location)))

(defun help-render-location-section (point title locations)
  (help-insert point "~a (~d)~%" title (length locations))
  (if locations
      (dolist (location locations)
        (help-insert-location-row
         point
         (format nil "  ~a  —  ~a~%"
                 (getf location :label)
                 (help-location-display location))
         location))
      (help-insert point "  No source-backed ~a found.~%"
                   (string-downcase title))))

(defun help-render-definition-section (point location)
  (help-insert point "Source~%")
  (if location
      (help-insert-location-row
       point
       (format nil "  ~a~%" (help-location-display location t))
       location)
      (help-insert point "  No source location is available.~%"))
  (help-insert point "~%"))

(defun help-render-callable-content (point symbol key-sequence definition xrefs)
  (help-insert point "~a~2%" (help-symbol-label symbol))
  (when key-sequence
    (help-insert point "Key: ~a~%" (keyseq-to-string key-sequence)))
  (help-insert point "Type: ~a~%" (help-callable-type symbol))
  (alexandria:when-let ((lambda-list (help-callable-lambda-list symbol)))
    (help-insert point "Arguments: ~a~%" lambda-list))
  (help-insert point "Package: ~a~2%Documentation~%~a~2%"
               (package-name (symbol-package symbol))
               (or (ignore-errors (documentation symbol 'function))
                   "No documentation is available."))
  (help-render-definition-section point definition)
  (help-render-location-section point "Callers" xrefs))

(defun help-render-variable-content (point symbol definition xrefs)
  (help-insert point "~a~2%Type: ~a~%Value: ~a~%Package: ~a~2%"
               (help-symbol-label symbol)
               (if (constantp symbol) "constant" "variable")
               (help-variable-value symbol)
               (package-name (symbol-package symbol)))
  (help-insert point "Documentation~%~a~2%"
               (or (ignore-errors (documentation symbol 'variable))
                   "No documentation is available."))
  (help-render-definition-section point definition)
  (help-render-location-section point "References" xrefs))

(defun help-render-face-content (point symbol definition)
  (help-insert point "~a~2%" (help-symbol-label symbol))
  (multiple-value-bind (theme specification)
      (help-face-theme-origin symbol)
    (help-insert point "Theme: ~a~%Theme layer: ~a~%"
                 (or (current-theme) "none")
                 (or theme "attribute default"))
    (when specification
      (let ((*print-pretty* nil)
            (*print-escape* t))
        (help-insert point "Theme specification: ~s~%" specification))))
  (alexandria:when-let ((attribute (help-face-attribute symbol)))
    (help-insert point "Foreground: ~a~%Background: ~a~%Bold: ~:[no~;yes~]~%"
                 (help-face-value-string
                  (lem-core:attribute-foreground attribute))
                 (help-face-value-string
                  (lem-core:attribute-background attribute))
                 (not (null (lem-core:attribute-bold attribute))))
    (help-insert point "Underline: ~a~%Reverse: ~:[no~;yes~]~2%"
                 (help-face-value-string
                  (lem-core:attribute-underline attribute))
                 (not (null (lem-core:attribute-reverse attribute))))
    (help-insert point "Sample~%  ")
    (with-point ((start point))
      (insert-string point "AaBbYyZz — The quick brown fox jumps over the lazy dog.")
      (put-text-property start point :attribute symbol))
    (insert-character point #\newline 2))
  (help-render-definition-section point definition))

(defun help-render-symbol-buffer (buffer symbol kind key-sequence)
  "Render SYMBOL of KIND into BUFFER and replace its navigation snapshot."
  (let* ((definition
           (case kind
             (:callable (help-callable-definition-location symbol))
             ((:variable :face) (help-variable-definition-location symbol))))
         (xrefs
           (case kind
             (:callable (help-xref-locations symbol "WHO-CALLS"))
             (:variable (help-xref-locations symbol "WHO-REFERENCES")))))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((point (buffer-end-point buffer)))
        (help-insert point
                     "Helpful: q quit, g refresh, s source, RET visit, n/p rows~2%")
        (ecase kind
          (:callable
           (help-render-callable-content
            point symbol key-sequence definition xrefs))
          (:variable
           (help-render-variable-content point symbol definition xrefs))
          (:face
           (help-render-face-content point symbol definition)))))
    (setf (buffer-value buffer 'lem-yath-help-symbol) symbol
          (buffer-value buffer 'lem-yath-help-kind) kind
          (buffer-value buffer 'lem-yath-help-key-sequence) key-sequence
          (buffer-value buffer 'lem-yath-help-definition) definition)
    (setf (buffer-read-only-p buffer) t)
    (buffer-unmark buffer)
    buffer))

(defun help-reset-horizontal-scroll (&optional (window (current-window)))
  (setf (window-parameter window 'lem-core::horizontal-scroll-start) 0))

(defun help-open-symbol-buffer (symbol kind &optional key-sequence)
  (let ((buffer
          (make-buffer
           (ecase kind
             (:callable "*Callable Help*")
             (:variable "*Variable Help*")
             (:face "*Face Help*")))))
    (change-buffer-mode buffer 'lem-yath-help-mode)
    (help-render-symbol-buffer buffer symbol kind key-sequence)
    (move-point (buffer-point buffer) (buffer-start-point buffer))
    (let ((window (pop-to-buffer buffer)))
      (switch-to-window window)
      (help-reset-horizontal-scroll window))
    (redraw-display)))

(defun help-render-callable (symbol &optional key-sequence)
  (help-open-symbol-buffer symbol :callable key-sequence))

(defun help-render-variable (symbol)
  (help-open-symbol-buffer symbol :variable))

(defun help-render-face (symbol)
  (help-open-symbol-buffer symbol :face))

(defun help-current-location ()
  (when (help-buffer-p)
    (with-point ((point (current-point)))
      (line-start point)
      (text-property-at point :lem-yath-help-location))))

(defun help-location-rows (&optional (buffer (current-buffer)))
  (let ((rows '()))
    (with-point ((point (buffer-start-point buffer)))
      (loop
        (alexandria:when-let
            ((location
               (text-property-at point :lem-yath-help-location)))
          (push (cons (line-number-at-point point) location) rows))
        (unless (line-offset point 1) (return))))
    (nreverse rows)))

(defun help-move-to-location (location)
  (alexandria:when-let
      ((row
         (find (help-location-key location) (help-location-rows)
               :key (lambda (entry) (help-location-key (cdr entry)))
               :test #'equal)))
    (move-point (current-point) (buffer-start-point (current-buffer)))
    (line-offset (current-point) (1- (car row)))
    (help-reset-horizontal-scroll)
    (window-recenter (current-window))
    t))

(defun help-select-relative-location (direction)
  (unless (help-buffer-p)
    (editor-error "This is not a Helpful buffer."))
  (let* ((rows (help-location-rows))
         (line (line-number-at-point (current-point)))
         (row
           (if (plusp direction)
               (or (find-if (lambda (entry) (> (car entry) line)) rows)
                   (first rows))
               (or (find-if (lambda (entry) (< (car entry) line))
                            (reverse rows))
                   (car (last rows))))))
    (unless row
      (editor-error "This help buffer has no source-backed rows."))
    (move-point (current-point) (buffer-start-point (current-buffer)))
    (line-offset (current-point) (1- (car row)))
    (help-reset-horizontal-scroll)
    (window-recenter (current-window))))

(defun help-skip-source-leading-whitespace (point)
  "Move POINT from SBCL's top-level anchor to the first source form character."
  (loop :for character := (character-at point)
        :while (and character
                    (help-source-layout-character-p character))
        :do (unless (character-offset point 1)
              (return)))
  point)

(defun help-visit-location (location)
  (let* ((pathname (getf location :pathname))
         (expected-date (getf location :write-date))
         (actual-date
           (and (uiop:file-exists-p pathname)
                (ignore-errors (file-write-date pathname)))))
    (unless actual-date
      (editor-error "Helpful source no longer exists: ~a" pathname))
    (unless (eql expected-date actual-date)
      (editor-error "Helpful source changed; press g to refresh its locations."))
    (lem/language-mode::push-location-stack (current-point))
    (lem-vi-mode/jumplist:with-jumplist
      (find-file pathname)
      (buffer-start (current-point))
      (unless (character-offset (current-point) (getf location :offset))
        (editor-error "Helpful source offset is no longer valid; refresh first."))
      (help-skip-source-leading-whitespace (current-point)))
    (window-recenter (current-window))))

(define-command lem-yath-help-next-reference () ()
  "Move to the next source or cross-reference row, cyclically."
  (help-select-relative-location 1))

(define-command lem-yath-help-previous-reference () ()
  "Move to the previous source or cross-reference row, cyclically."
  (help-select-relative-location -1))

(define-command lem-yath-help-visit () ()
  "Visit the exact source location represented by the current row."
  (alexandria:if-let ((location (help-current-location)))
    (help-visit-location location)
    (message "No source location on this line.")))

(define-command lem-yath-help-source () ()
  "Visit the described symbol's definition source."
  (unless (help-buffer-p)
    (editor-error "This is not a Helpful buffer."))
  (alexandria:if-let
      ((location
         (buffer-value (current-buffer) 'lem-yath-help-definition)))
    (help-visit-location location)
    (message "No source location is available.")))

(define-command lem-yath-help-refresh () ()
  "Refresh the current Helpful buffer, preserving its selected location."
  (unless (help-buffer-p)
    (editor-error "This is not a Helpful buffer."))
  (let* ((buffer (current-buffer))
         (selected (help-current-location))
         (symbol (buffer-value buffer 'lem-yath-help-symbol))
         (kind (buffer-value buffer 'lem-yath-help-kind))
         (key-sequence
           (buffer-value buffer 'lem-yath-help-key-sequence)))
    (unless (and symbol kind)
      (editor-error "This Helpful buffer has no inspection target."))
    (help-render-symbol-buffer buffer symbol kind key-sequence)
    (unless (and selected (help-move-to-location selected))
      (move-point (current-point) (buffer-start-point buffer)))
    (redraw-display)))

(define-command lem-yath-help-quit () ()
  "Quit the Helpful window and restore its originating window."
  (quit-active-window))

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

(define-command (lem-yath-describe-face (:name "describe-face")) () ()
  "Choose and describe a Lem face under the current color theme."
  (let* ((candidates (help-face-candidates))
         (symbol (help-prompt-symbol
                  "Face: " candidates #'help-face-detail :face)))
    (when symbol (help-render-face symbol))))

(define-command lem-yath-describe-key () ()
  "Read a key and inspect its resolved command in the Helpful buffer."
  (show-message "Helpful key: ")
  (redraw-display)
  (let* ((key-sequence (read-key-sequence))
         (command (find-keybind key-sequence)))
    (if (and command (symbolp command) (fboundp command))
        (let ((*help-command-symbols* (help-command-symbol-table)))
          (help-render-callable command key-sequence))
        (message "~a is not bound to an inspectable command."
                 (keyseq-to-string key-sequence)))))

(define-key *lem-yath-help-mode-keymap* "q" 'lem-yath-help-quit)
(define-key *lem-yath-help-mode-keymap* "C-g" 'lem-yath-help-quit)
(define-key *lem-yath-help-mode-keymap* "g" 'lem-yath-help-refresh)
(define-key *lem-yath-help-mode-keymap* "s" 'lem-yath-help-source)
(define-key *lem-yath-help-mode-keymap* "Return" 'lem-yath-help-visit)
(define-key *lem-yath-help-mode-keymap* "n" 'lem-yath-help-next-reference)
(define-key *lem-yath-help-mode-keymap* "p" 'lem-yath-help-previous-reference)
(define-key *lem-yath-help-mode-keymap* "Tab" 'lem-yath-help-next-reference)
(define-key *lem-yath-help-mode-keymap* "S-Tab"
  'lem-yath-help-previous-reference)
(define-key *lem-yath-help-mode-keymap* "Shift-Tab"
  'lem-yath-help-previous-reference)
