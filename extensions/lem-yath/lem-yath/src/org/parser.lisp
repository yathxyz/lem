;;;; Native Org document parsing and semantic highlighting.

(in-package :lem-yath)

(defparameter *org-todo-keywords*
  '("TODO" "NEXT" "WAITING" "HOLD" "SOMEDAY" "DONE" "CANCELLED"))

(defparameter *org-open-todo-keywords*
  '("TODO" "NEXT" "WAITING" "HOLD" "SOMEDAY"))

(defparameter *org-done-todo-keywords* '("DONE" "CANCELLED"))

(defparameter *org-todo-keyword-pattern*
  (format nil "(?:~{~a~^|~})" *org-todo-keywords*))

(define-attribute org-todo-attribute
  (t :foreground :base0A :bold t))
(define-attribute org-done-attribute
  (t :foreground :base0B :bold t))
(define-attribute org-tag-attribute
  (t :foreground :base0C))
(define-attribute org-timestamp-attribute
  (t :foreground :base0E))
(define-attribute org-priority-attribute
  (t :foreground :base09 :bold t))

(defclass org-syntax-parser () ())

(defun make-org-syntax-parser ()
  (make-instance 'org-syntax-parser))

(defun org-heading-level-from-line (line)
  "Return LINE's Org heading level, or NIL."
  (multiple-value-bind (start end register-starts register-ends)
      (cl-ppcre:scan "^(\\*+)\\s+" line)
    (declare (ignore start end))
    (when (and register-starts
               (aref register-starts 0)
               (aref register-ends 0))
      (- (aref register-ends 0) (aref register-starts 0)))))

(defun org-block-marker (line)
  "Return LINE's type-qualified Org block marker, or NIL."
  (let ((line (string-downcase
               (string-left-trim '(#\Space #\Tab) line))))
    (labels ((marker-for (prefix marker)
               (when (alexandria:starts-with-subseq prefix line)
                 (let* ((rest (subseq line (length prefix)))
                        (end (or (position-if
                                  (lambda (character)
                                    (member character '(#\Space #\Tab)))
                                  rest)
                                 (length rest))))
                   (and (plusp end)
                        (cons marker (subseq rest 0 end)))))))
      (or (marker-for "#+begin_" :begin)
          (marker-for "#+end_" :end)))))

(defun org-inside-block-p (&optional (origin (current-point)))
  "Whether ORIGIN is inside a type-matched Org #+begin_/#+end_ block."
  (with-point ((point (buffer-start-point (point-buffer origin)))
               (target origin))
    (line-start target)
    ;; Inside an outer block, other begin/end-looking lines are literal body
    ;; text.  Only its own end marker closes it.  Scanning forward preserves
    ;; that distinction when a source body contains unmatched block keywords.
    (loop :with open-type := nil
          :for marker := (org-block-marker (line-string point))
          :do (cond
                ((null open-type)
                 (when (and marker (eq (car marker) :begin))
                   (setf open-type (cdr marker))))
                ((and marker
                      (eq (car marker) :end)
                      (string= (cdr marker) open-type))
                 (setf open-type nil)))
          :when (same-line-p point target)
            :return (not (null open-type))
          :unless (line-offset point 1)
            :return nil)))

(defun org-heading-level-at (point)
  (unless (org-inside-block-p point)
    (org-heading-level-from-line (line-string point))))

(defun org-heading-line-p (point)
  (not (null (org-heading-level-at point))))

(defun org-current-heading-point (&optional (origin (current-point)))
  "Return the nearest heading at or before ORIGIN as a temporary point."
  (with-point ((point origin))
    (line-start point)
    (loop
      (when (org-heading-line-p point)
        (return (copy-point point :temporary)))
      (unless (line-offset point -1)
        (return nil)))))

(defun org-next-heading-point (&optional (origin (current-point)))
  "Return the first heading strictly after ORIGIN."
  (with-point ((point origin))
    (line-start point)
    (loop :while (line-offset point 1)
          :when (org-heading-line-p point)
            :return (copy-point point :temporary))))

(defun org-previous-heading-point (&optional (origin (current-point)))
  "Return the first heading strictly before ORIGIN."
  (with-point ((point origin))
    (line-start point)
    (loop :while (line-offset point -1)
          :when (org-heading-line-p point)
            :return (copy-point point :temporary))))

(defun org-subtree-end-point (heading)
  "Return the exclusive end of HEADING's complete subtree."
  (let ((level (org-heading-level-at heading)))
    (unless level
      (return-from org-subtree-end-point nil))
    (with-point ((point heading))
      (line-start point)
      (loop :while (line-offset point 1)
            :for candidate := (org-heading-level-at point)
            :when (and candidate (<= candidate level))
              :return (copy-point point :temporary)
            :finally (return (copy-point (buffer-end-point (point-buffer point))
                                         :temporary))))))

(defun org-section-end-point (heading)
  "Return the next heading, or the end of the buffer."
  (or (org-next-heading-point heading)
      (copy-point (buffer-end-point (point-buffer heading)) :temporary)))

(defun org-direct-child-headings (heading)
  "Return direct child heading points under HEADING."
  (let ((level (org-heading-level-at heading))
        (end (org-subtree-end-point heading))
        (children '()))
    (when (and level end)
      (with-point ((point heading))
        (loop :while (and (line-offset point 1) (point< point end))
              :when (eql (org-heading-level-at point) (1+ level))
                :do (push (copy-point point :temporary) children))))
    (nreverse children)))

(defun org-parent-heading-point (&optional (origin (current-point)))
  "Return ORIGIN's nearest lower-level ancestor heading."
  (alexandria:when-let* ((heading (org-current-heading-point origin))
                         (level (org-heading-level-at heading)))
    (with-point ((point heading))
      (loop :while (line-offset point -1)
            :for candidate := (org-heading-level-at point)
            :when (and candidate (< candidate level))
              :return (copy-point point :temporary)))))

(defun org-first-child-heading-point (&optional (origin (current-point)))
  (first (org-direct-child-headings
          (or (org-current-heading-point origin) origin))))

(defun org-same-level-sibling (heading direction)
  "Return HEADING's adjacent sibling in DIRECTION (-1 or 1)."
  (let ((level (org-heading-level-at heading)))
    (with-point ((point heading))
      (loop :while (line-offset point direction)
            :for candidate := (org-heading-level-at point)
            :when (and candidate (< candidate level))
              :return nil
            :when (eql candidate level)
              :return (copy-point point :temporary)))))

(defun org-put-line-slice-attribute (point start end attribute)
  (when (and start end (< start end))
    (with-point ((from point)
                 (to point))
      (line-start from)
      (line-start to)
      (character-offset from start)
      (character-offset to end)
      (put-text-property from to :attribute attribute))))

(defun org-put-line-attribute (point attribute)
  (org-put-line-slice-attribute point 0 (length (line-string point)) attribute))

(defun org-scan-inline (point line)
  (flet ((paint (pattern attribute)
           (cl-ppcre:do-matches (start end pattern line)
             (org-put-line-slice-attribute point start end attribute))))
    (paint "\\*[^*\\n]+\\*" 'document-bold-attribute)
    (paint "/[^/\\n]+/" 'document-italic-attribute)
    (paint "_[^_\\n]+_" 'document-underline-attribute)
    (paint "(?:~[^~\\n]+~|=[^=\\n]+=)" 'document-inline-code-attribute)
    (paint "\\[[ Xx-]\\]" 'document-task-list-attribute)
    (paint "(?:<|\\[)[0-9]{4}-[0-9]{2}-[0-9]{2}[^]>]*(?:>|\\])"
           'org-timestamp-attribute)
    (paint "\\[#[A-Z0-9]\\]" 'org-priority-attribute)
    ;; Links are last so their face wins over punctuation-like emphasis.
    (paint "\\[\\[[^]\\n]+\\](?:\\[[^]\\n]*\\])?\\]"
           'document-link-attribute)))

(defun org-scan-heading (point line)
  (let* ((level (org-heading-level-from-line line))
         (attribute (case (min level 6)
                      (1 'document-header1-attribute)
                      (2 'document-header2-attribute)
                      (3 'document-header3-attribute)
                      (4 'document-header4-attribute)
                      (5 'document-header5-attribute)
                      (otherwise 'document-header6-attribute))))
    (org-put-line-attribute point attribute)
    (multiple-value-bind (start end register-starts register-ends)
        (cl-ppcre:scan
         (format nil "^\\*+\\s+(~a)(?:\\s|$)" *org-todo-keyword-pattern*)
         line)
      (declare (ignore start end))
      (when (and register-starts (aref register-starts 0))
        (let* ((keyword-start (aref register-starts 0))
               (keyword-end (aref register-ends 0))
               (keyword (subseq line keyword-start keyword-end)))
          (org-put-line-slice-attribute
           point keyword-start keyword-end
           (if (member keyword *org-done-todo-keywords* :test #'string=)
               'org-done-attribute
               'org-todo-attribute)))))
    (multiple-value-bind (start end)
        (cl-ppcre:scan "(?i)(:[[:alnum:]_@#%]+(?::[[:alnum:]_@#%]+)*:)\\s*$" line)
      (when start
        (org-put-line-slice-attribute point start end 'org-tag-attribute)))
    (org-scan-inline point line)))

(defun org-scan-region (start end)
  (clear-region-major-mode start end)
  (let ((in-drawer nil)
        (in-source nil))
    (with-point ((point start))
      (line-start point)
      (loop :while (point< point end)
            :for line := (line-string point)
            :do
               (cond
                 (in-source
                  (if (cl-ppcre:scan "(?i)^#\\+end_src\\s*$" line)
                      (progn
                        (org-put-line-attribute point 'document-metadata-attribute)
                        (setf in-source nil))
                      (org-put-line-attribute point 'document-code-block-attribute)))
                 ((cl-ppcre:scan "(?i)^#\\+begin_src(?:\\s|$)" line)
                  (org-put-line-attribute point 'document-metadata-attribute)
                  (setf in-source t))
                 (in-drawer
                  (org-put-line-attribute point 'document-metadata-attribute)
                  (when (string-equal line ":END:")
                    (setf in-drawer nil)))
                 ((string-equal line ":PROPERTIES:")
                  (org-put-line-attribute point 'document-metadata-attribute)
                  (setf in-drawer t))
                 ((org-heading-level-from-line line)
                  (org-scan-heading point line))
                 ((cl-ppcre:scan "^\\s*\\|" line)
                  (org-put-line-attribute point 'document-table-attribute)
                  (org-scan-inline point line))
                 ((cl-ppcre:scan "^\\s*(?:[-+] |[0-9]+[.)] )" line)
                  (org-put-line-attribute point 'document-list-attribute)
                  (org-scan-inline point line))
                 ((cl-ppcre:scan "(?i)^\\s*(?:SCHEDULED|DEADLINE|CLOSED):" line)
                  (org-put-line-attribute point 'document-metadata-attribute)
                  (org-scan-inline point line))
                 ((cl-ppcre:scan "^#\\+" line)
                  (org-put-line-attribute point 'document-metadata-attribute))
                 ((cl-ppcre:scan "^#(?:\\s|$)" line)
                  (org-put-line-attribute point 'syntax-comment-attribute))
                 (t (org-scan-inline point line)))
            :unless (line-offset point 1)
              :do (return)))))

(defmethod lem/buffer/internal::%syntax-scan-region
    ((parser org-syntax-parser) start end)
  ;; Multi-line drawers and source blocks require context.  Org note files are
  ;; typically modest, and Markdown in the same pinned Lem uses this strategy.
  (declare (ignore parser))
  (with-point ((buffer-start start)
               (buffer-end end))
    (lem:buffer-start buffer-start)
    (lem:buffer-end buffer-end)
    (remove-text-property buffer-start buffer-end :attribute)
    (org-scan-region buffer-start buffer-end)))

(defvar *org-syntax-table*
  (let ((table (make-syntax-table
                :space-chars '(#\Space #\Tab #\Newline))))
    (set-syntax-parser table (make-org-syntax-parser))
    table))
