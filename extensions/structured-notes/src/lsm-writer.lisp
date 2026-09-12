(in-package #:lem-structured-notes)

(defun lsm-newline-string (style)
  (ecase style
    (:lf (string #\Newline))
    (:crlf (coerce (list #\Return #\Newline) 'string))
    (:cr (string #\Return))))

(defun lsm-quoted-scalar (value)
  (let ((value (if (stringp value) value (princ-to-string value))))
    (with-output-to-string (stream)
      (write-char #\" stream)
      (loop :for character :across value
            :do (case character
                  (#\\ (write-string "\\\\" stream))
                  (#\" (write-string "\\\"" stream))
                  (#\Newline (write-string "\\n" stream))
                  (#\Return (write-string "\\r" stream))
                  (#\Tab (write-string "\\t" stream))
                  (otherwise
                   (let ((code (char-code character)))
                     (if (or (< code 32) (<= 127 code 159))
                         (format stream "\\u~4,'0X" code)
                         (write-char character stream))))))
      (write-char #\" stream))))

(defun render-lsm-temporal-local-value (value)
  (let ((local (temporal-value-local-value value)))
    (if (eq :minute (temporal-value-precision value))
        (cond
          ((and (>= (length local) 3)
                (string= ":00" local :start2 (- (length local) 3)))
           (subseq local 0 (- (length local) 3)))
          ((and (>= (length local) 4)
                (string= ":00Z" local :start2 (- (length local) 4)))
           (concatenate 'string
                        (subseq local 0 (- (length local) 4)) "Z"))
          (t local))
        local)))

(defun render-lsm-temporal (value)
  (when value
    (let ((local (render-lsm-temporal-local-value value)))
      (case (temporal-value-kind value)
      (:zoned
       (format nil "~a[~a]"
               local
               (temporal-value-timezone-id value)))
        (otherwise local)))))

(defun render-lsm-string-list (values)
  (format nil "[~{~a~^, ~}]" (mapcar #'lsm-quoted-scalar values)))

(defun ensure-canonical-lsm-node-supported (node)
  (dolist (content (semantic-node-body node))
    (ensure-canonical-lsm-content-supported content (semantic-node-id node)))
  (when (semantic-node-extensions node)
    (model-error :unsupported-node-extension (semantic-node-id node)
                 "canonical writer refuses to drop opaque source extensions"))
  (let ((task (semantic-node-task node)))
    (when (and task
               (task-facet-dependencies task))
      (model-error :unsupported-task-detail (semantic-node-id node)
                   "canonical writer does not yet render task dependencies")))
  node)

(defun render-lsm-org-content (content emit-line)
  (funcall emit-line ":::{lem-org-opaque}")
  (funcall emit-line "kind: ~a"
           (string-downcase (symbol-name (content-node-kind content))))
  (when (content-node-name content)
    (funcall emit-line "name: ~a"
             (lsm-quoted-scalar (content-node-name content))))
  (when (content-node-text content)
    (funcall emit-line "text: ~a"
             (lsm-quoted-scalar (content-node-text content))))
  (funcall emit-line "raw: ~a"
           (lsm-quoted-scalar (content-node-raw content)))
  (funcall emit-line ":::"))

(defun render-lsm-source-opaque-content (content emit-line)
  (funcall emit-line ":::{lem-source-opaque}")
  (funcall emit-line "kind: opaque")
  (funcall emit-line "format: ~a"
           (string-downcase
            (symbol-name (content-node-source-format content))))
  (funcall emit-line "raw: ~a"
           (lsm-quoted-scalar (content-node-raw content)))
  (funcall emit-line ":::"))

(defun lsm-source-opaque-content-p (content)
  (and (eq :opaque (content-node-kind content))
       (member (content-node-source-format content)
               '(:commonmark :myst))
       (null (content-node-name content))
       (null (content-node-attributes content))
       (null (content-node-text content))
       (null (content-node-inlines content))
       (null (content-node-items content))
       (null (content-node-table content))
       (null (content-node-code-block content))))

(defun ensure-canonical-lsm-content-supported (content owner)
  (let ((native-paragraph-p
          (content-node-native-commonmark-paragraph-p content))
        (native-list-p
          (content-node-native-commonmark-list-p content))
        (native-table-p
          (content-node-native-gfm-table-p content))
        (native-code-p
          (content-node-native-code-block-p content))
        (native-quote-p
          (content-node-native-commonmark-quote-p content))
        (native-drawer-p
          (content-node-native-myst-drawer-p content)))
    (when (content-node-inlines content)
      (unless (or native-paragraph-p native-quote-p native-drawer-p)
        (model-error :unsupported-inline-projection owner
                     "paragraph quote or drawer inline semantics disagree with source evidence or exceed the native profile"))
      (unless (cond
                (native-quote-p
                 (quote-inlines-canonical-commonmark-p
                  (content-node-inlines content)))
                (native-drawer-p
                 (drawer-inlines-canonical-myst-p
                  (content-node-name content)
                  (content-node-inlines content)))
                (t
                 (inline-nodes-canonical-commonmark-p
                  (content-node-inlines content))))
        (model-error :unsafe-inline-rendering owner
                     "rendered inline semantics do not reparse as the selected CommonMark block")))
    (when (content-node-items content)
      (unless native-list-p
        (model-error :unsupported-list-projection owner
                     "list semantics disagree with source evidence or exceed the native profile"))
      (unless (list-items-canonical-commonmark-p (content-node-items content))
        (model-error :unsafe-list-rendering owner
                     "rendered list semantics do not reparse as a CommonMark list")))
    (when (content-node-table content)
      (unless native-table-p
        (model-error :unsupported-table-projection owner
                     "table semantics disagree with source evidence or exceed the GFM profile"))
      (unless (table-data-canonical-gfm-p (content-node-table content))
        (model-error :unsafe-table-rendering owner
                     "rendered table semantics do not reparse as a GFM table")))
    (when (content-node-code-block content)
      (unless native-code-p
        (model-error :unsupported-code-block-projection owner
                     "code block semantics disagree with source evidence or exceed the fenced-code profile"))
      (unless (code-block-data-canonical-commonmark-p
               (content-node-code-block content))
        (model-error :unsafe-code-block-rendering owner
                     "rendered code block semantics do not reparse as fenced code")))
    (unless (or (eq (content-node-source-format content) :org)
                native-paragraph-p
                native-list-p
                native-table-p
                native-code-p
                native-quote-p
                native-drawer-p
                (lsm-source-opaque-content-p content)
                (content-node-native-myst-comment-p content))
      (model-error :unsupported-canonical-content owner
                   "canonical writer only renders source-preserved Org content or supported native content")))
  (when (content-node-attributes content)
    (model-error :unsupported-content-attributes owner
                 "canonical writer does not yet render content attributes"))
  content)

(defun canonical-lsm-opaque-content-p (content)
  (not (or (content-node-native-commonmark-paragraph-p content)
           (content-node-native-commonmark-list-p content)
           (content-node-native-gfm-table-p content)
           (content-node-native-code-block-p content)
           (content-node-native-commonmark-quote-p content)
           (content-node-native-myst-drawer-p content)
           (content-node-native-myst-comment-p content))))

(defun render-lsm-content (content emit-line)
  (cond
    ((content-node-native-commonmark-paragraph-p content)
     (funcall emit-line "~a"
              (render-commonmark-inlines (content-node-inlines content))))
    ((content-node-native-commonmark-list-p content)
     (dolist (line (render-commonmark-list-lines
                    (content-node-items content)))
       (funcall emit-line "~a" line)))
    ((content-node-native-gfm-table-p content)
     (dolist (line (render-gfm-table-lines (content-node-table content)))
       (funcall emit-line "~a" line)))
    ((content-node-native-code-block-p content)
     (dolist (line
              (if (content-node-native-myst-code-cell-p content)
                  (render-myst-code-cell-lines
                   (content-node-code-block content))
                  (render-commonmark-fenced-code-lines
                   (content-node-code-block content))))
       (funcall emit-line "~a" line)))
    ((content-node-native-commonmark-quote-p content)
     (funcall emit-line "~a"
              (render-commonmark-quote-line
               (content-node-inlines content))))
    ((content-node-native-myst-drawer-p content)
     (dolist (line (render-myst-drawer-lines
                    (content-node-name content)
                    (content-node-inlines content)))
       (funcall emit-line "~a" line)))
    ((content-node-native-myst-comment-p content)
     (funcall emit-line "% ~a" (content-node-text content)))
    ((lsm-source-opaque-content-p content)
     (render-lsm-source-opaque-content content emit-line))
    (t (render-lsm-org-content content emit-line))))

(defun render-lsm-recurrence-date (value)
  (if (recurrence-period-p value)
      (format nil "~a/~a"
              (render-lsm-temporal (recurrence-period-start value))
              (if (recurrence-period-end value)
                  (render-lsm-temporal (recurrence-period-end value))
                  (recurrence-period-duration value)))
      (render-lsm-temporal value)))

(defun render-lsm-recurrence-date-list (values)
  (render-lsm-string-list (mapcar #'render-lsm-recurrence-date values)))

(defun render-lsm-temporal-list (values)
  (render-lsm-string-list (mapcar #'render-lsm-temporal values)))

(defun render-lsm-recurrence-fields (recurrence emit-line)
  (when (recurrence-rules recurrence)
    (funcall emit-line "recurrence-rules: ~a"
             (render-lsm-string-list (recurrence-rules recurrence))))
  (when (recurrence-dates recurrence)
    (funcall emit-line "recurrence-dates: ~a"
             (render-lsm-recurrence-date-list
              (recurrence-dates recurrence))))
  (when (recurrence-exception-dates recurrence)
    (funcall emit-line "recurrence-exception-dates: ~a"
             (render-lsm-temporal-list
              (recurrence-exception-dates recurrence))))
  (funcall emit-line "recurrence-policy: ~a"
           (string-downcase (symbol-name (recurrence-policy recurrence))))
  (when (recurrence-original-lexeme recurrence)
    (funcall emit-line "recurrence-original: ~a"
             (lsm-quoted-scalar
              (recurrence-original-lexeme recurrence)))))

(defun render-lsm-task (task emit-line)
  (funcall emit-line ":::{lem-task}")
  (funcall emit-line "workflow: ~a"
           (lsm-quoted-scalar (task-facet-workflow-id task)))
  (funcall emit-line "state: ~a"
           (lsm-quoted-scalar (task-facet-state task)))
  (funcall emit-line "done: ~:[false~;true~]" (task-facet-done-p task))
  (when (task-facet-priority task)
    (funcall emit-line "priority: ~a"
             (if (integerp (task-facet-priority task))
                 (format nil "~d" (task-facet-priority task))
                 (lsm-quoted-scalar (task-facet-priority task)))))
  (when (task-facet-progress task)
    (funcall emit-line "progress: ~d" (task-facet-progress task)))
  (when (task-facet-effort task)
    (funcall emit-line "effort: ~a"
             (lsm-quoted-scalar (task-facet-effort task))))
  (dolist (entry
           (list (cons "scheduled" (task-facet-scheduled task))
                 (cons "deadline" (task-facet-deadline task))
                 (cons "closed" (task-facet-closed task))))
    (when (cdr entry)
      (funcall emit-line "~a: ~a" (car entry)
               (lsm-quoted-scalar (render-lsm-temporal (cdr entry))))))
  (when (task-facet-scheduled-delay task)
    (funcall emit-line "scheduled-delay: ~a"
             (lsm-quoted-scalar (task-facet-scheduled-delay task))))
  (when (task-facet-deadline-warning task)
    (funcall emit-line "deadline-warning: ~a"
             (lsm-quoted-scalar (task-facet-deadline-warning task))))
  (when (task-facet-logs task)
    (funcall emit-line "clocks: ~a"
             (render-lsm-string-list
              (mapcar #'render-lsm-task-clock (task-facet-logs task)))))
  (let ((recurrence (task-facet-recurrence task)))
    (when recurrence
      (render-lsm-recurrence-fields recurrence emit-line)))
  (funcall emit-line ":::"))

(defun render-lsm-event (event emit-line)
  (funcall emit-line ":::{lem-event}")
  (dolist (entry
           (list (cons "start" (event-facet-start event))
                 (cons "end" (event-facet-end event))))
    (when (cdr entry)
      (funcall emit-line "~a: ~a" (car entry)
               (lsm-quoted-scalar (render-lsm-temporal (cdr entry))))))
  (dolist (entry
           (list (cons "duration" (event-facet-duration event))
                 (cons "status" (event-facet-status event))
                 (cons "location" (event-facet-location event))
                 (cons "url" (event-facet-url event))))
    (when (cdr entry)
      (funcall emit-line "~a: ~a" (car entry)
               (lsm-quoted-scalar (cdr entry)))))
  (when (event-facet-transparency event)
    (funcall emit-line "transparency: ~a"
             (string-downcase
              (symbol-name (event-facet-transparency event)))))
  (when (event-facet-recurrence event)
    (render-lsm-recurrence-fields (event-facet-recurrence event) emit-line))
  (funcall emit-line ":::"))

(defun render-lsm-calendar-binding (binding emit-line)
  (funcall emit-line ":::{lem-calendar-binding}")
  (funcall emit-line "id: ~a"
           (lsm-quoted-scalar (calendar-binding-id binding)))
  (funcall emit-line "projection: ~a"
           (string-downcase
            (symbol-name (calendar-binding-projection-kind binding))))
  (dolist (entry
           (list (cons "account" (calendar-binding-account-id binding))
                 (cons "calendar" (calendar-binding-calendar-id binding))
                 (cons "uid" (calendar-binding-uid binding))))
    (when (cdr entry)
      (funcall emit-line "~a: ~a" (car entry)
               (lsm-quoted-scalar (cdr entry)))))
  (when (calendar-binding-recurrence-id binding)
    (funcall emit-line "recurrence-id: ~a"
             (lsm-quoted-scalar
              (render-lsm-temporal
               (calendar-binding-recurrence-id binding)))))
  (funcall emit-line "ownership: ~a"
           (string-downcase
            (symbol-name (calendar-binding-ownership binding))))
  (funcall emit-line "write-policy: ~a"
           (string-downcase
            (symbol-name (calendar-binding-write-policy binding))))
  (funcall emit-line ":::"))

(defun render-lsm-node-lines (node emit-line)
  (ensure-canonical-lsm-node-supported node)
  (when (find-if (lambda (character)
                   (member character '(#\Newline #\Return)))
                 (semantic-node-title node))
    (model-error :invalid-heading-title (semantic-node-title node)
                 "LSM heading title cannot contain a newline"))
  (funcall emit-line "")
  (funcall emit-line "~a ~a"
           (make-string (min 6 (semantic-node-level node))
                        :initial-element #\#)
           (semantic-node-title node))
  (funcall emit-line "")
  (funcall emit-line ":::{lem-node}")
  (funcall emit-line "id: ~a" (lsm-quoted-scalar (semantic-node-id node)))
  (when (> (semantic-node-level node) 6)
    (funcall emit-line "depth: ~d" (semantic-node-level node)))
  (when (semantic-node-aliases node)
    (funcall emit-line "aliases: ~a"
             (render-lsm-string-list (semantic-node-aliases node))))
  (let ((citations
          (loop :for reference :in (semantic-node-references node)
                :when (eq :citation (node-reference-kind reference))
                  :collect (node-reference-value reference)))
        (urls
          (loop :for reference :in (semantic-node-references node)
                :when (eq :url (node-reference-kind reference))
                  :collect (node-reference-value reference))))
    (when citations
      (funcall emit-line "citation-refs: ~a"
               (render-lsm-string-list citations)))
    (when urls
      (funcall emit-line "url-refs: ~a"
               (render-lsm-string-list urls))))
  (when (semantic-node-tags node)
    (funcall emit-line "tags: ~a"
             (render-lsm-string-list (semantic-node-tags node))))
  (when (semantic-node-inactive-dates node)
    (funcall emit-line "inactive-dates: ~a"
             (render-lsm-recurrence-date-list
              (semantic-node-inactive-dates node))))
  (funcall emit-line ":::")
  (when (semantic-node-event node)
    (funcall emit-line "")
    (render-lsm-event (semantic-node-event node) emit-line))
  (when (semantic-node-task node)
    (funcall emit-line "")
    (render-lsm-task (semantic-node-task node) emit-line))
  (dolist (binding (semantic-node-calendar-bindings node))
    (funcall emit-line "")
    (render-lsm-calendar-binding binding emit-line))
  (when (semantic-node-properties node)
    (funcall emit-line "")
    (funcall emit-line ":::{lem-properties}")
    (dolist (property (semantic-node-properties node))
      (unless (and (stringp (car property))
                   (plusp (length (car property)))
                   (not (find #\: (car property)))
                   (not (find #\Newline (car property))))
        (model-error :invalid-property-name (car property)
                     "property name cannot be emitted safely"))
      (unless (stringp (cdr property))
        (model-error :unsupported-property-value (cdr property)
                     "canonical writer only renders string property values"))
      (funcall emit-line "~a: ~a"
               (car property) (lsm-quoted-scalar (cdr property))))
    (funcall emit-line ":::"))
  (dolist (content (semantic-node-body node))
    (funcall emit-line "")
    (render-lsm-content content emit-line))
  node)

(defun render-lsm-node (node &key (newline :lf))
  "Render one canonical LSM node fragment, including its leading separator."
  (let ((line-ending (lsm-newline-string newline)))
    (with-output-to-string (stream)
      (flet ((emit-line (control &rest arguments)
               (apply #'format stream control arguments)
               (write-string line-ending stream)))
        (render-lsm-node-lines node #'emit-line)))))

(defmethod render-source-node ((provider lsm-provider) node
                               &key (newline :lf) &allow-other-keys)
  (render-lsm-node node :newline newline))

(defun canonical-lsm-frontmatter-extension (document newline)
  (let ((extensions (semantic-document-extensions document)))
    (unless (or (null extensions)
                (and (null (rest extensions))
                     (lsm-frontmatter-extension-p (first extensions))))
      (model-error :unsupported-document-extension
                   (semantic-document-id document)
                   "canonical writer only renders one validated opaque YAML frontmatter extension"))
    (when extensions
      (let ((raw
              (validate-lsm-extra-frontmatter-raw
               (opaque-extension-raw-value (first extensions)))))
        (unless (eq newline (source-newline-style raw))
          (model-error :frontmatter-newline-mismatch raw
                       "preserved frontmatter newline style differs from the document"))
        raw))))

(defun render-lsm-document (document &key newline)
  "Render the currently supported semantic subset as canonical LSM/1.

The writer fails closed for semantic fields it cannot yet serialize."
  (validate-document document)
  (when (semantic-document-metadata document)
    (model-error :unsupported-document-metadata
                 (semantic-document-id document)
                 "canonical writer does not yet render document metadata"))
  (dolist (content (semantic-document-preamble document))
    (ensure-canonical-lsm-content-supported
     content (semantic-document-id document)))
  (let* ((newline (or newline (semantic-document-newline document)))
         (line-ending (lsm-newline-string newline))
         (frontmatter (canonical-lsm-frontmatter-extension document newline)))
    (with-output-to-string (stream)
      (labels ((emit-line (control &rest arguments)
                 (apply #'format stream control arguments)
                 (write-string line-ending stream)))
        (emit-line "---")
        (emit-line "lem:")
        (emit-line "  profile: ~a" (lsm-quoted-scalar "lsm/1"))
        (emit-line "  document-id: ~a"
                    (lsm-quoted-scalar (semantic-document-id document)))
        (when frontmatter
          (write-string frontmatter stream)
          (unless (or (zerop (length frontmatter))
                      (char= (char frontmatter (1- (length frontmatter)))
                             (char line-ending (1- (length line-ending)))))
            (write-string line-ending stream)))
        (emit-line "---")
        (dolist (content (semantic-document-preamble document))
          (emit-line "")
          (render-lsm-content content #'emit-line))
        (dolist (node (semantic-document-nodes document))
          (render-lsm-node-lines node #'emit-line))))))
