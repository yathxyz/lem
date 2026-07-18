;;;; Conservative, on-demand Org boundaries for Evil-Org text objects.

(in-package :lem-yath)

;;; The native Org mode deliberately does not maintain a second document tree.
;;; Text objects ask this module for a small, verified boundary at point.  A
;;; boundary is half-open: START is included and END is excluded.

(defstruct (%org-boundary
            (:constructor %make-org-boundary
                (start end inner-start inner-end kind node-type)))
  start
  end
  inner-start
  inner-end
  kind
  node-type)

(defstruct (%org-inline-candidate
            (:constructor %make-org-inline-candidate
                (start end outer-end inner-start inner-end node-type)))
  start
  end
  outer-end
  inner-start
  inner-end
  node-type)

(defun %org-line-point (origin column)
  (with-point ((point origin))
    (line-start point)
    (character-offset point column)
    (copy-point point :temporary)))

(defun %org-line-after (origin)
  "Return the start of the next line, or the buffer end after ORIGIN."
  (with-point ((point origin))
    (line-start point)
    (if (line-offset point 1)
        (copy-point point :temporary)
        (copy-point (buffer-end-point (point-buffer point)) :temporary))))

(defun %org-expand-blank-lines (origin)
  "Return the first non-blank line start at or after ORIGIN."
  (with-point ((point origin))
    (loop :while (and (not (end-buffer-p point))
                      (cl-ppcre:scan "^\\s*$" (line-string point)))
          :do (unless (line-offset point 1)
                (move-point point
                            (buffer-end-point (point-buffer point)))
                (return)))
    (copy-point point :temporary)))

(defun %org-positive-count (count)
  (cond
    ((null count) 1)
    ((and (integerp count) (plusp count)) count)))

(defun %org-point-in-half-open-range-p (point start end)
  (and (not (point< point start)) (point< point end)))

(defun %org-boundary-range (boundary inner-p)
  (when boundary
    (let ((start (if inner-p
                     (%org-boundary-inner-start boundary)
                     (%org-boundary-start boundary)))
          (end (if inner-p
                   (%org-boundary-inner-end boundary)
                   (%org-boundary-end boundary))))
      (when (and start end (point< start end))
        (values (copy-point start :temporary)
                (copy-point end :temporary)
                (%org-boundary-kind boundary))))))

;;; --- malformed and special contexts -------------------------------------

(defun %org-drawer-marker (line)
  (multiple-value-bind (start end register-starts register-ends)
      (cl-ppcre:scan "^\\s*:([-A-Za-z0-9_@#%]+):\\s*$" line)
    (declare (ignore start end))
    (when (and register-starts (aref register-starts 0))
      (let ((name (string-upcase
                   (subseq line (aref register-starts 0)
                           (aref register-ends 0)))))
        (if (string= name "END") :end name)))))

(defun %org-property-looking-line-p (line)
  "Whether LINE begins with an Org drawer/property-style :NAME: token."
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
         (second-colon
           (and (plusp (length trimmed))
                (eql (char trimmed 0) #\:)
                (position #\: trimmed :start 1))))
    (and second-colon
         (> second-colon 1)
         (every (lambda (character)
                  (not (member character
                               '(#\Space #\Tab #\Newline #\Return))))
                (subseq trimmed 1 second-colon)))))

(defun %org-inside-drawer-p (origin)
  "Whether ORIGIN is on or inside a conservatively recognized Org drawer."
  (with-point ((point (buffer-start-point (point-buffer origin)))
               (target origin))
    (line-start target)
    (loop :with open-drawer-p := nil
          :with open-block-type := nil
          :for line := (line-string point)
          :for block-marker := (org-block-marker line)
          :for drawer-marker := (%org-drawer-marker line)
          :do (cond
                (open-block-type
                 (when (and block-marker
                            (eq (car block-marker) :end)
                            (string= (cdr block-marker) open-block-type))
                   (setf open-block-type nil)))
                (open-drawer-p
                 (when (eq drawer-marker :end)
                   (when (same-line-p point target)
                     (return t))
                   (setf open-drawer-p nil)))
                ((and block-marker (eq (car block-marker) :begin))
                 (setf open-block-type (cdr block-marker)))
                ((and drawer-marker (not (eq drawer-marker :end)))
                 (setf open-drawer-p t)))
          :when (same-line-p point target)
            :return open-drawer-p
          :unless (line-offset point 1)
            :return nil)))

(defun %org-make-drawer-boundary (start end-marker name)
  "Return a matched drawer boundary from START through END-MARKER."
  (let* ((property-p (string= name "PROPERTIES"))
         (raw-inner-start (%org-line-after start))
         (inner-start
           (with-point ((point raw-inner-start))
             (unless property-p
               (loop :while (and (point< point end-marker)
                                  (cl-ppcre:scan
                                   "^\\s*$" (line-string point)))
                     :do (unless (line-offset point 1) (return))))
             (and (point< point end-marker)
                  (copy-point point :temporary))))
         (core-end (%org-line-after end-marker))
         (outer-end (%org-expand-blank-lines core-end)))
    (%make-org-boundary
     (copy-point start :temporary)
     outer-end
     inner-start
     (and inner-start (copy-point end-marker :temporary))
     :character
     (if property-p :property-drawer :drawer))))

(defun %org-drawer-boundary-at (origin)
  "Return the complete matched Org drawer containing ORIGIN.

Drawer-looking lines inside a matched drawer are content until its `:END:'.
Drawer markers inside a typed Org block remain literal.  Unclosed drawers
return NIL so callers retain the existing fail-closed boundary."
  (with-point ((point (buffer-start-point (point-buffer origin)))
               (target origin))
    (line-start target)
    (loop :with open-start := nil
          :with open-name := nil
          :with target-in-open-p := nil
          :with open-block-type := nil
          :for line := (line-string point)
          :for block-marker := (org-block-marker line)
          :for drawer-marker := (%org-drawer-marker line)
          :do
             (when (and open-start (same-line-p point target))
               (setf target-in-open-p t))
             (cond
               (open-block-type
                (when (and block-marker
                           (eq (car block-marker) :end)
                           (string= (cdr block-marker) open-block-type))
                  (setf open-block-type nil)))
               (open-start
                (when (eq drawer-marker :end)
                  (when target-in-open-p
                    (return (%org-make-drawer-boundary
                             open-start point open-name)))
                  (setf open-start nil
                        open-name nil
                        target-in-open-p nil)))
               ((and block-marker (eq (car block-marker) :begin))
                (setf open-block-type (cdr block-marker)))
               ((and drawer-marker (not (eq drawer-marker :end)))
                (setf open-start (copy-point point :temporary)
                      open-name drawer-marker
                      target-in-open-p (same-line-p point target))))
          :unless (line-offset point 1)
            :return nil)))

(defun %org-drawer-inline-kind (point drawer)
  "Return :FULL, :TIMESTAMP, or NIL for inline parsing inside DRAWER."
  (let ((line (line-string point)))
    (cond
      ((eq (%org-boundary-node-type drawer) :property-drawer) nil)
      ((or (same-line-p point (%org-boundary-start drawer))
           (and (%org-boundary-inner-end drawer)
                (same-line-p point (%org-boundary-inner-end drawer))))
       nil)
      ((cl-ppcre:scan "(?i)^\\s*CLOCK:" line) :timestamp)
      (t :full))))

(defun %org-special-line-p (point)
  "Whether POINT is on syntax this conservative model does not own."
  (let ((line (line-string point)))
    (or (%org-inside-drawer-p point)
        (cl-ppcre:scan "^\\s*#" line)
        (cl-ppcre:scan
         "(?i)^\\s*(?:SCHEDULED|DEADLINE|CLOSED|CLOCK):"
         line)
        ;; Drawer/property-looking syntax is special even when orphaned.  Do
        ;; not reinterpret a malformed :END: or :ID: value as prose.
        (%org-property-looking-line-p line)
        (cl-ppcre:scan "^\\s*:\\s" line)
        (cl-ppcre:scan "^\\s*\\\\(?:begin|end)\\{" line)
        (cl-ppcre:scan "^\\s*-{5,}\\s*$" line)
        (cl-ppcre:scan "^\\s*\\[fn:[^]]+\\]" line))))

;;; --- matched typed blocks ------------------------------------------------

(defun %org-block-context-at (origin)
  "Return the flat block at ORIGIN and its safety status.

The first value is a boundary for one type-matched, non-nested block.  The
second value is :VALID or :UNSAFE.  A nested or unclosed root block is unsafe
through its complete balanced range, including its post-blank, so tail text
cannot fall through to a paragraph or section after an inner end marker."
  (with-point ((point (buffer-start-point (point-buffer origin))))
    (loop :with type-stack := nil
          :with root-start := nil
          :with inner-start := nil
          :with nested-p := nil
          :for marker := (org-block-marker (line-string point))
          :do
             (cond
               ((null type-stack)
                (when (and marker (eq (car marker) :begin))
                  (setf type-stack (list (cdr marker))
                        root-start (copy-point point :temporary)
                        inner-start (%org-line-after point)
                        nested-p nil)))
               ((and marker (eq (car marker) :begin))
                (push (cdr marker) type-stack)
                (setf nested-p t))
               ((and marker
                     (eq (car marker) :end)
                     (string= (cdr marker) (first type-stack)))
                (pop type-stack)
                (when (null type-stack)
                  (let* ((inner-end (copy-point point :temporary))
                         (core-end (%org-line-after point))
                         (outer-end (%org-expand-blank-lines core-end)))
                    (when (%org-point-in-half-open-range-p
                           origin root-start outer-end)
                      (if nested-p
                          (return (values nil :unsafe))
                          (return
                            (values
                             (%make-org-boundary
                              root-start outer-end inner-start inner-end
                              :character
                              (cons :block (cdr marker)))
                             :valid)))))
                  (setf root-start nil inner-start nil nested-p nil))))
          :unless (line-offset point 1)
            :do
               (return
                 (if (and type-stack root-start
                          (not (point< origin root-start)))
                     (values nil :unsafe)
                     (values nil nil))))))

(defun %org-block-boundary-at (origin)
  (nth-value 0 (%org-block-context-at origin)))

(defun %org-unsafe-block-context-p (origin)
  (eq (nth-value 1 (%org-block-context-at origin)) :unsafe))

(defun %org-unclosed-block-at-p (origin)
  "Whether ORIGIN belongs to an unclosed or nested-ambiguous block."
  (%org-unsafe-block-context-p origin))

(defun %org-regexp-ranges (pattern line)
  (let ((ranges '()))
    (cl-ppcre:do-matches (start end pattern line)
      (push (cons start end) ranges))
    (nreverse ranges)))

(defun %org-string-delimited-ranges (line opener closer)
  (let ((ranges '())
        (search-from 0))
    (loop
      (let ((start (search opener line :start2 search-from)))
        (unless start
          (return (nreverse ranges)))
        (let ((close (search closer line
                             :start2 (+ start (length opener)))))
          (unless close
            (return (nreverse ranges)))
          (let ((end (+ close (length closer))))
            (push (cons start end) ranges)
            (setf search-from end)))))))

(defun %org-backslash-token-ranges (line)
  "Return conservative ranges for Org entities and line-break syntax."
  (let ((ranges '())
        (search-from 0))
    (loop
      (let ((start (position #\Backslash line :start search-from)))
        (unless start
          (return (nreverse ranges)))
        (let ((end (1+ start)))
          (loop :while (and (< end (length line))
                            (not (member (char line end)
                                         '(#\Space #\Tab))))
                :do (incf end))
          (when (> end (1+ start))
            (push (cons start end) ranges))
          (setf search-from (max (1+ start) end)))))))

(defun %org-unsupported-inline-ranges (line)
  "Return conservative ranges for Org objects not modeled by this module."
  (append
   (mapcan (lambda (pattern) (%org-regexp-ranges pattern line))
           '("\\[fn:[^]\\n]+\\]"
             "(?i)\\[cite(?:/[^]:\\n]+)?:[^]\\n]+\\]"
             "\\[(?:[0-9]+/[0-9]+|[0-9]+%)\\]"
             "@@[A-Za-z0-9_-]+:[^\\n]*?@@"
             "\\$+[^$\\n]+\\$+"
             "\\{\\{\\{[^\\n]*\\}\\}\\}"
             "<<[^>\\n]+>>"
             "(?i)\\bsrc_[A-Za-z0-9_-]+(?:\\[[^]]*\\])?\\{[^}\\n]*\\}"
             "(?i)\\bcall_[A-Za-z0-9_-]+(?:\\[[^]]*\\])?\\([^\\n)]*\\)(?:\\[[^]]*\\])?"
             "[A-Za-z0-9][_^](?:\\{[^}\\n]+\\}|[A-Za-z0-9+-]+)"))
   (%org-string-delimited-ranges line "\\(" "\\)")
   (%org-string-delimited-ranges line "\\[" "\\]")
   (%org-backslash-token-ranges line)))

(defun %org-unsupported-inline-at-point-p (point)
  (let ((column (point-charpos point)))
    (find-if (lambda (range)
               (and (<= (car range) column) (< column (cdr range))))
             (%org-unsupported-inline-ranges (line-string point)))))

;;; --- inline Org objects --------------------------------------------------

(defun %org-escaped-character-p (line index)
  (loop :for position :downfrom (1- index) :to 0
        :while (eql (char line position) #\Backslash)
        :count t :into count
        :finally (return (oddp count))))

(defun %org-emphasis-before-p (line index)
  (or (zerop index)
      (member (char line (1- index))
              '(#\Space #\Tab #\Newline #\- #\( #\{ #\' #\"))))

(defun %org-emphasis-after-p (line index)
  (or (= index (length line))
      (member (char line index)
              '(#\Space #\Tab #\Newline #\- #\. #\, #\; #\: #\!
                #\? #\' #\) #\} #\[ #\"))))

(defun %org-inline-delimited-candidates (line delimiter node-type)
  (let ((result '())
        (search-from 0))
    (loop
      (let ((open (position delimiter line :start search-from)))
        (unless open (return (nreverse result)))
        (let ((close (position delimiter line :start (1+ open))))
          (cond
            ((null close)
             (return (nreverse result)))
            ((or (%org-escaped-character-p line open)
                 (%org-escaped-character-p line close)
                 (not (%org-emphasis-before-p line open))
                 (not (%org-emphasis-after-p line (1+ close)))
                 (= close (1+ open))
                 (member (char line (1+ open)) '(#\Space #\Tab))
                 (member (char line (1- close)) '(#\Space #\Tab)))
             (setf search-from (1+ open)))
            (t
             (let ((outer-end (1+ close)))
               (loop :while (and (< outer-end (length line))
                                 (member (char line outer-end)
                                         '(#\Space #\Tab)))
                     :do (incf outer-end))
               (push (%make-org-inline-candidate
                      open (1+ close) outer-end
                      (1+ open) close node-type)
                     result))
             (setf search-from (1+ close)))))))))

(defun %org-link-candidates (line)
  (let ((result '()))
    (cl-ppcre:do-scans
        (start end register-starts register-ends
         "\\[\\[([^]\\n]+)\\](?:\\[([^]\\n]*)\\])?\\]" line)
      (unless (or (%org-escaped-character-p line start)
                  (search "[[" line :start2 (1+ start) :end2 end))
        (let ((outer-end end)
              (description-start (and (> (length register-starts) 1)
                                      (aref register-starts 1)))
              (description-end (and (> (length register-ends) 1)
                                    (aref register-ends 1))))
          (loop :while (and (< outer-end (length line))
                            (member (char line outer-end)
                                    '(#\Space #\Tab)))
                :do (incf outer-end))
          ;; A link without a description has no Org contents range.  Evil-Org
          ;; consequently leaves its brackets in the inner object.
          (push (%make-org-inline-candidate
                 start end outer-end
                 (or description-start start)
                 (or description-end end)
                 :link)
                result))))
    (nreverse result)))

(defun %org-plain-link-candidates (line)
  (let ((result '()))
    (cl-ppcre:do-matches
        (start matched-end
         "(?i)(?:https?|ftp|mailto|news):[^\\s<>()\\[\\]]+" line)
      (unless (or (%org-escaped-character-p line start)
                  (and (>= start 2)
                       (string= (subseq line (- start 2) start) "[[")))
        (let ((end matched-end))
          (loop :while (and (> end start)
                            (member (char line (1- end))
                                    '(#\. #\, #\; #\! #\?)))
                :do (decf end))
          (when (> end start)
            (let ((outer-end end))
              (loop :while (and (< outer-end (length line))
                                (member (char line outer-end)
                                        '(#\Space #\Tab)))
                    :do (incf outer-end))
              (push (%make-org-inline-candidate
                     start end outer-end start end :plain-link)
                    result))))))
    (nreverse result)))

(defun %org-timestamp-candidates (line)
  (let ((result '()))
    (cl-ppcre:do-matches
        (start end
         "(?:\\[[0-9]{4}-[0-9]{2}-[0-9]{2}[^]\\n]*\\]|<[0-9]{4}-[0-9]{2}-[0-9]{2}[^>\\n]*>)"
         line)
      (unless (%org-escaped-character-p line start)
        (let ((outer-end end))
          (loop :while (and (< outer-end (length line))
                            (member (char line outer-end)
                                    '(#\Space #\Tab)))
                :do (incf outer-end))
          ;; Org timestamps have no contents-begin/contents-end properties.
          (push (%make-org-inline-candidate
                 start end outer-end start end :timestamp)
                result))))
    (nreverse result)))

(defun %org-table-cell-candidates (point)
  (let ((line (line-string point)))
    (when (and (org-table-line-p point)
               (not (org-table-separator-line-p line))
               (cl-ppcre:scan "^\\s*\\|.*\\|\\s*$" line)
               (null (search "\\|" line)))
      (let ((pipes (loop :for index :from 0 :below (length line)
                         :when (eql (char line index) #\|)
                           :collect index))
            (result '()))
        (loop :for left :in pipes
              :for right :in (rest pipes)
              :do (let ((inner-start (1+ left))
                        (inner-end right))
                    (loop :while (and (< inner-start inner-end)
                                      (member (char line inner-start)
                                              '(#\Space #\Tab)))
                          :do (incf inner-start))
                    (loop :while (and (< inner-start inner-end)
                                      (member (char line (1- inner-end))
                                              '(#\Space #\Tab)))
                          :do (decf inner-end))
                    (push (%make-org-inline-candidate
                           (1+ left) (1+ right) (1+ right)
                           inner-start inner-end :table-cell)
                          result)))
        (nreverse result)))))

(defun %org-inline-contained-by-p (candidate container)
  (and (<= (%org-inline-candidate-start container)
           (%org-inline-candidate-start candidate))
       (<= (%org-inline-candidate-end candidate)
           (%org-inline-candidate-end container))))

(defun %org-line-object-candidates (point)
  (let* ((drawer (%org-drawer-boundary-at point))
         (drawer-kind (and drawer (%org-drawer-inline-kind point drawer))))
    (unless (or (%org-unclosed-block-at-p point)
                (org-inside-block-p point)
                (and drawer (null drawer-kind))
                (and (null drawer) (%org-special-line-p point)))
      (let ((line (line-string point)))
        (if (eq drawer-kind :timestamp)
            (%org-timestamp-candidates line)
            (let* ((links (%org-link-candidates line))
                   (plain-links
                     (remove-if
                      (lambda (plain-link)
                        (find-if
                         (lambda (link)
                           (%org-inline-contained-by-p plain-link link))
                         links))
                      (%org-plain-link-candidates line))))
              (append
               links
               plain-links
               (%org-timestamp-candidates line)
               (%org-inline-delimited-candidates line #\~ :code)
               (%org-inline-delimited-candidates line #\= :verbatim)
               (%org-inline-delimited-candidates line #\* :bold)
               (%org-inline-delimited-candidates line #\/ :italic)
               (%org-inline-delimited-candidates line #\_ :underline)
               (%org-inline-delimited-candidates line #\+ :strike-through)
               (%org-table-cell-candidates point))))))))

(defun %org-inline-span (candidate)
  (- (%org-inline-candidate-end candidate)
     (%org-inline-candidate-start candidate)))

(defun %org-unambiguous-inline (candidates)
  (when candidates
    ;; Code and verbatim are opaque in Org.  Delimiter-looking text inside
    ;; either object is literal and cannot win merely by having a shorter span.
    (let* ((opaque
             (remove-if-not
              (lambda (candidate)
                (member (%org-inline-candidate-node-type candidate)
                        '(:code :verbatim)))
              candidates))
           (ordered (sort (copy-list (or opaque candidates))
                          #'< :key #'%org-inline-span))
           (first (first ordered))
           (second (second ordered)))
      (unless (or (and second
                       (= (%org-inline-span first) (%org-inline-span second)))
                  ;; Nested markup has a well-defined deepest object.  Crossing
                  ;; spans do not, so reject them instead of guessing.
                  (find-if
                   (lambda (candidate)
                     (or (> (%org-inline-candidate-start candidate)
                            (%org-inline-candidate-start first))
                         (< (%org-inline-candidate-end candidate)
                            (%org-inline-candidate-end first))))
                   (rest ordered)))
        first))))

(defun %org-inline-to-boundary (line-point candidate)
  (%make-org-boundary
   (%org-line-point line-point (%org-inline-candidate-start candidate))
   (%org-line-point line-point (%org-inline-candidate-outer-end candidate))
   (%org-line-point line-point (%org-inline-candidate-inner-start candidate))
   (%org-line-point line-point (%org-inline-candidate-inner-end candidate))
   :character
   (%org-inline-candidate-node-type candidate)))

(defun %org-unsupported-table-object-at-point-p (point)
  "Whether POINT is on a table row whose cell boundaries are ambiguous."
  (and (org-table-line-p point)
       (not (org-table-separator-line-p (line-string point)))
       (search "\\|" (line-string point))))

(defun %org-link-description-covers-column-p (candidate column)
  (and (eq (%org-inline-candidate-node-type candidate) :link)
       (/= (%org-inline-candidate-inner-start candidate)
           (%org-inline-candidate-start candidate))
       (<= (%org-inline-candidate-inner-start candidate) column)
       (< column (%org-inline-candidate-inner-end candidate))))

(defun %org-link-opaque-at-column-p (candidate column)
  (case (%org-inline-candidate-node-type candidate)
    (:plain-link t)
    (:link (not (%org-link-description-covers-column-p candidate column)))))

(defun %org-unsupported-opaque-at-column-p (candidate column)
  (or (member (%org-inline-candidate-node-type candidate)
              '(:code :verbatim :plain-link))
      (and (eq (%org-inline-candidate-node-type candidate) :link)
           (not (%org-link-description-covers-column-p candidate column)))))

(defun %org-object-at-point (origin)
  (let* ((column (point-charpos origin))
         (all-covering
           (remove-if-not
            (lambda (candidate)
              (and (<= (%org-inline-candidate-start candidate) column)
                   (< column (%org-inline-candidate-outer-end candidate))))
            (%org-line-object-candidates origin)))
         ;; A plain link and a bracket-link target are opaque.  Descriptions
         ;; remain recursively parseable, so nested code or unsupported Org
         ;; objects can still become the context there.
         (opaque-link-covering
           (remove-if-not
            (lambda (candidate)
              (%org-link-opaque-at-column-p candidate column))
            all-covering))
         ;; Code and verbatim are opaque before links are.  A URL or bracket
         ;; link inside either wrapper is literal wrapper content, while an
         ;; unwrapped link target remains opaque before recursively parsed
         ;; containers such as emphasis.
         (opaque-code-covering
           (remove-if-not
            (lambda (candidate)
              (member (%org-inline-candidate-node-type candidate)
                      '(:code :verbatim)))
            all-covering))
         (covering (or opaque-code-covering
                       opaque-link-covering
                       all-covering))
         (candidate (%org-unambiguous-inline covering)))
    (cond
      ((and candidate
            (%org-unsupported-opaque-at-column-p candidate column))
       (%org-inline-to-boundary origin candidate))
      ;; Unsupported Org syntax inside opaque code/verbatim/link targets is
      ;; literal.  Everywhere else it beats a supported containing candidate
      ;; so ae cannot over-delete that container or its paragraph.
      ((or (%org-unsupported-table-object-at-point-p origin)
           (%org-unsupported-inline-at-point-p origin))
       nil)
      (candidate (%org-inline-to-boundary origin candidate))
      ;; An ambiguous inline parse must fail closed.  With no inline object,
      ;; org-element-context falls back to the containing element.
      (covering nil)
      (t (%org-element-at-point origin)))))

(defun %org-boundary-scan-barrier-p (point)
  "Whether forward text-object discovery must stop at POINT."
  (or (%org-unclosed-block-at-p point)
      (and (%org-special-line-p point)
           (null (%org-drawer-boundary-at point)))
      (%org-list-continuation-context-p point)
      (and (org-list-item-line-p point)
           (not (%org-current-list-item point)))))

(defun %org-next-object (origin)
  (with-point ((point origin))
    (loop
      (alexandria:when-let ((at-point (%org-object-at-point point)))
        (return at-point))
      (when (or (%org-boundary-scan-barrier-p point)
                (%org-unsupported-inline-at-point-p point))
        (return nil))
      (let ((eligible
              (remove-if
               (lambda (candidate)
                 (< (%org-inline-candidate-start candidate)
                    (point-charpos point)))
               (%org-line-object-candidates point))))
        (when eligible
          (let* ((first-start
                   (reduce #'min eligible
                           :key #'%org-inline-candidate-start))
                 (at-first
                   (remove-if-not
                    (lambda (candidate)
                      (= first-start (%org-inline-candidate-start candidate)))
                    eligible))
                 (candidate (%org-unambiguous-inline at-first)))
            (when candidate
              (return (%org-inline-to-boundary point candidate))))))
      (unless (line-offset point 1)
        (return nil)))))

;;; --- element boundaries --------------------------------------------------

(defun %org-safe-table-row-p (point)
  (and (org-table-line-p point)
       (cl-ppcre:scan "^\\s*\\|.*\\|\\s*$" (line-string point))))

(defun %org-table-row-boundary (origin)
  (when (%org-safe-table-row-p origin)
    (with-point ((start origin)
                 (inner-start origin)
                 (inner-end origin))
      (line-start start)
      (line-start inner-start)
      (line-end inner-end)
      (let ((pipe (position #\| (line-string origin)))
            (separator-p (org-table-separator-line-p (line-string origin))))
        (when pipe
          ;; A table rule has no contents.  Pinned Evil-Org uses the complete
          ;; visible rule line for iE instead of leaving a structurally invalid
          ;; lone pipe behind.
          (unless separator-p
            (character-offset inner-start (1+ pipe)))
          (%make-org-boundary
           (copy-point start :temporary)
           (%org-line-after start)
           (copy-point inner-start :temporary)
           (copy-point inner-end :temporary)
           :character :table-row))))))

(defun %org-table-formula-line-p (line)
  (not (null (cl-ppcre:scan "(?i)^\\s*#\\+TBLFM:" line))))

(defun %org-table-outer-end (origin last-row row-core-end)
  "Return the table end including associated formulas and post-blank."
  (if (not (org-table-formula-after-p origin))
      (%org-expand-blank-lines row-core-end)
      (with-point ((point last-row))
        (loop :while (line-offset point 1)
              :for line := (line-string point)
              :unless (cl-ppcre:scan "^\\s*$" line)
                :do
                   (return
                     (if (%org-table-formula-line-p line)
                         (loop :with formula-end
                               :do (setf formula-end (%org-line-after point))
                               :while
                                  (with-point ((next point))
                                    (and (line-offset next 1)
                                         (%org-table-formula-line-p
                                          (line-string next))
                                         (progn (move-point point next) t)))
                               :finally
                                  (return
                                    (%org-expand-blank-lines formula-end)))
                         (%org-expand-blank-lines row-core-end)))
              :finally (return (%org-expand-blank-lines row-core-end))))))

(defun %org-table-boundary (origin &key (kind :line))
  (when (%org-safe-table-row-p origin)
    (multiple-value-bind (start end) (org-table-bounds origin)
      (when (and start end
                 (with-point ((point start))
                   (loop
                     (unless (%org-safe-table-row-p point)
                       (return nil))
                     (when (same-line-p point end)
                       (return t))
                     (unless (line-offset point 1)
                       (return nil)))))
        (let* ((core-end (%org-line-after end))
               (outer-end (%org-table-outer-end origin end core-end)))
          (%make-org-boundary
           start outer-end (copy-point start :temporary) core-end
           kind :table))))))

(defun %org-table-element-boundary (origin)
  "Return pinned Org's table or table-row element at ORIGIN."
  (when (%org-safe-table-row-p origin)
    (multiple-value-bind (table-start table-end) (org-table-bounds origin)
      (declare (ignore table-end))
      (if (and table-start
               (zerop (point-charpos origin))
               (same-line-p origin table-start))
          (%org-table-boundary origin :kind :character)
          (%org-table-row-boundary origin)))))

(defun %org-safe-unordered-item-p (item)
  (multiple-value-bind (indent content-column text-column)
      (org-list-item-columns item)
    (declare (ignore content-column text-column))
    (and indent
         (not (org-list-ordered-item-p item))
         (not (org-list-context-tab-p item))
         (let ((bullet (char (line-string item) indent)))
           (or (member bullet '(#\- #\+))
               (and (plusp indent) (eql bullet #\*)))))))

(defun %org-safe-list-tree-p (item)
  (when (%org-safe-unordered-item-p item)
    (alexandria:when-let ((end (org-list-item-tree-end item)))
      (with-point ((point item))
        (line-start point)
        (loop :while (point< point end)
              :for line := (line-string point)
              :unless (and (plusp (length line))
                           (%org-safe-unordered-item-p point))
                :return nil
              :unless (line-offset point 1)
                :return t
              :finally (return t))))))

(defun %org-current-list-item (origin)
  (with-point ((item origin))
    (line-start item)
    (and (%org-safe-list-tree-p item)
         (copy-point item :temporary))))

(defun %org-list-point-context (origin)
  "Return ORIGIN's pinned Org list context, item, and text column.

Org classifies absolute BOL as the containing plain list, even before an
indented bullet.  The prefix after BOL is an item; actual non-empty item text
is a paragraph."
  (with-point ((item origin))
    (line-start item)
    (when (%org-safe-list-tree-p item)
      (multiple-value-bind (indent content-column text-column)
          (org-list-item-columns item)
        (declare (ignore indent content-column))
        (when text-column
          (let ((column (point-charpos origin))
                (line-length (length (line-string item))))
            (values
             (cond
               ((and (zerop column)
                     (null (org-list-previous-sibling item)))
                :plain-list)
               ((and (< text-column line-length)
                     (>= column text-column))
                :paragraph)
               (t :item))
             (copy-point item :temporary)
             text-column)))))))

(defun %org-list-continuation-context-p (origin)
  "Whether ORIGIN is non-list body text owned by an earlier list item."
  (unless (org-list-item-line-p origin)
    (with-point ((point origin)
                 (target origin))
      (line-start point)
      (line-start target)
      (loop :while (line-offset point -1)
            :for line := (line-string point)
            :until (or (zerop (length line)) (org-heading-line-p point))
            :when (org-list-item-line-p point)
              :do (let ((end (org-list-item-tree-end point)))
                    (when (and end (point< target end))
                      (return t)))))))

(defun %org-list-item-boundary (item)
  (when (%org-safe-list-tree-p item)
    (multiple-value-bind (indent content-column text-column)
        (org-list-item-columns item)
      (declare (ignore indent content-column))
      (let ((end (org-list-item-tree-end item)))
        (when (and text-column end)
          (let* ((text-present-p
                   (< text-column (length (line-string item))))
                 (inner-start
                   (cond
                     (text-present-p (%org-line-point item text-column))
                     ((org-list-item-has-child-p item)
                      (%org-line-after item)))))
            (%make-org-boundary
             (with-point ((start item))
               (line-start start)
               (copy-point start :temporary))
             (copy-point end :temporary)
             inner-start
             (and inner-start (copy-point end :temporary))
             :character :list-item)))))))

(defun %org-list-paragraph-boundary (item text-column)
  (when (and (%org-safe-list-tree-p item)
             text-column
             (< text-column (length (line-string item))))
    (let ((start (%org-line-point item text-column))
          (end (%org-line-after item)))
      (%make-org-boundary
       start end (copy-point start :temporary) (copy-point end :temporary)
       :character :paragraph))))

(defun %org-parent-list-item (item)
  (let ((indent (nth-value 0 (org-list-item-columns item))))
    (when indent
      (with-point ((point item))
        (line-start point)
        (loop :while (line-offset point -1)
              :for line := (line-string point)
              :until (or (zerop (length line)) (org-heading-line-p point))
              :when (org-list-item-line-p point)
                :do (let ((candidate-indent
                            (nth-value 0 (org-list-item-columns point))))
                      (when (and candidate-indent (< candidate-indent indent)
                                 (%org-safe-list-tree-p point))
                        (let ((end (org-list-item-tree-end point)))
                          (when (and end (point< item end))
                            (return (copy-point point :temporary)))))))))))

(defun %org-plain-list-boundary (item &key (kind :line))
  (when (%org-safe-list-tree-p item)
    (with-point ((start item)
                 (last item))
      (loop :for previous := (org-list-previous-sibling start)
            :while (and previous (%org-safe-list-tree-p previous))
            :do (move-point start previous))
      (loop :for next := (org-list-next-sibling last)
            :while (and next (%org-safe-list-tree-p next))
            :do (move-point last next))
      (let ((core-end (org-list-item-tree-end last)))
        (when core-end
          (let ((outer-end (%org-expand-blank-lines core-end)))
            (%make-org-boundary
             (copy-point start :temporary) outer-end
             (copy-point start :temporary) (copy-point core-end :temporary)
             kind :plain-list)))))))

(defun %org-list-element-boundary (origin)
  (multiple-value-bind (context item text-column)
      (%org-list-point-context origin)
    (case context
      (:plain-list (%org-plain-list-boundary item :kind :character))
      (:item (%org-list-item-boundary item))
      (:paragraph (%org-list-paragraph-boundary item text-column)))))

(defun %org-paragraph-line-p (point)
  (let ((line (line-string point)))
    (and (plusp (length line))
         (not (cl-ppcre:scan "^\\s*$" line))
         (not (org-heading-line-p point))
         (not (org-table-line-p point))
         (not (org-list-item-line-p point))
         (not (%org-list-continuation-context-p point))
         (null (org-block-marker line))
         (not (org-inside-block-p point))
         (not (%org-special-line-p point)))))

(defun %org-paragraph-boundary (origin)
  (when (%org-paragraph-line-p origin)
    (with-point ((start origin)
                 (end origin))
      (line-start start)
      (line-start end)
      (loop :while (with-point ((previous start))
                     (and (line-offset previous -1)
                          (%org-paragraph-line-p previous)
                          (progn (move-point start previous) t))))
      (loop :while (with-point ((next end))
                     (and (line-offset next 1)
                          (%org-paragraph-line-p next)
                          (progn (move-point end next) t))))
      (let* ((inner-end (%org-line-after end))
             (outer-end (%org-expand-blank-lines inner-end)))
        (%make-org-boundary
         (copy-point start :temporary) outer-end
         (copy-point start :temporary) inner-end
         :character :paragraph)))))

(defun %org-boundary-contains-point-p (boundary point)
  (and boundary
       (%org-point-in-half-open-range-p
        point (%org-boundary-start boundary) (%org-boundary-end boundary))))

(defun %org-previous-nonblank-line (origin)
  (when (cl-ppcre:scan "^\\s*$" (line-string origin))
    (with-point ((point origin))
      (line-start point)
      (loop
        (unless (line-offset point -1)
          (return nil))
        (unless (cl-ppcre:scan "^\\s*$" (line-string point))
          (return (copy-point point :temporary)))))))

(defun %org-root-list-item (item)
  (let ((root (copy-point item :temporary)))
    (loop :for parent := (%org-parent-list-item root)
          :while parent
          :do (move-point root parent))
    root))

(defun %org-postblank-element-boundary (origin)
  "Return the supported element that owns ORIGIN's blank line."
  (alexandria:when-let ((previous (%org-previous-nonblank-line origin)))
    (flet ((owned (boundary)
             (and (%org-boundary-contains-point-p boundary origin) boundary)))
      (or
       (alexandria:when-let ((item (%org-current-list-item previous)))
         (owned (%org-plain-list-boundary
                 (%org-root-list-item item) :kind :character)))
       (owned (%org-table-boundary previous :kind :character))
       (owned (%org-paragraph-boundary previous))))))

(defun %org-drawer-line-element-boundary (origin node-type)
  "Return one complete drawer child line at ORIGIN as NODE-TYPE."
  (with-point ((start origin)
               (inner-end origin))
    (line-start start)
    (line-end inner-end)
    (%make-org-boundary
     (copy-point start :temporary)
     (%org-line-after start)
     (copy-point start :temporary)
     (copy-point inner-end :temporary)
     :character node-type)))

(defun %org-drawer-paragraph-line-p (point)
  "Whether POINT is an ordinary paragraph line inside a valid drawer."
  (let ((line (line-string point)))
    (and (not (cl-ppcre:scan "^\\s*$" line))
         (null (%org-drawer-marker line))
         (null (org-block-marker line))
         (not (org-heading-line-p point))
         (not (org-table-line-p point))
         (null (org-navigation-list-anchor point))
         (not (cl-ppcre:scan
               "(?i)^\\s*(?:SCHEDULED|DEADLINE|CLOSED|CLOCK):" line))
         (not (cl-ppcre:scan "^\\s*#" line)))))

(defun %org-drawer-paragraph-boundary (origin drawer)
  "Return the paragraph child at ORIGIN, bounded by DRAWER contents."
  (let ((contents-start (%org-boundary-inner-start drawer))
        (contents-end (%org-boundary-inner-end drawer)))
    (when (and contents-start contents-end
               (%org-drawer-paragraph-line-p origin))
      (with-point ((start origin)
                   (end origin))
        (line-start start)
        (line-start end)
        (loop :while
                (with-point ((previous start))
                  (and (line-offset previous -1)
                       (not (point< previous contents-start))
                       (%org-drawer-paragraph-line-p previous)
                       (progn (move-point start previous) t))))
        (loop :while
                (with-point ((next end))
                  (and (line-offset next 1)
                       (point< next contents-end)
                       (%org-drawer-paragraph-line-p next)
                       (progn (move-point end next) t))))
        (let* ((core-end (%org-line-after end))
               (expanded (%org-expand-blank-lines core-end))
               (outer-end
                 (if (point< contents-end expanded)
                     (copy-point contents-end :temporary)
                     expanded)))
          (%make-org-boundary
           (copy-point start :temporary) outer-end
           (copy-point start :temporary) core-end
           :character :paragraph))))))

(defun %org-drawer-element-at-point (origin drawer)
  "Return the GNU Org child element at ORIGIN inside DRAWER."
  (let ((start (%org-boundary-start drawer))
        (contents-end (%org-boundary-inner-end drawer))
        (node-type (%org-boundary-node-type drawer))
        (line (line-string origin)))
    (cond
      ((or (same-line-p origin start)
           (and contents-end (same-line-p origin contents-end)))
       drawer)
      ((eq node-type :property-drawer)
       (unless (cl-ppcre:scan "^\\s*$" line)
         (%org-drawer-line-element-boundary origin :node-property)))
      ((cl-ppcre:scan "(?i)^\\s*CLOCK:" line)
       (%org-drawer-line-element-boundary origin :clock))
      ((cl-ppcre:scan
        "(?i)^\\s*(?:SCHEDULED|DEADLINE|CLOSED):" line)
       (%org-drawer-line-element-boundary origin :planning))
      ((%org-table-formula-line-p line)
       (%org-table-element-boundary origin))
      ((cl-ppcre:scan "(?i)^\\s*#\\+[A-Za-z0-9_]+:" line)
       (%org-drawer-line-element-boundary origin :keyword))
      ((org-table-line-p origin)
       (%org-table-element-boundary origin))
      ((org-navigation-list-anchor origin)
       (%org-list-element-boundary origin))
      (t
       (%org-drawer-paragraph-boundary origin drawer)))))

(defun %org-element-at-point (origin)
  (or (%org-block-boundary-at origin)
      (and (not (%org-unclosed-block-at-p origin))
           (alexandria:if-let ((drawer (%org-drawer-boundary-at origin)))
             (%org-drawer-element-at-point origin drawer)
             (or (and (org-heading-line-p origin)
                      (%org-heading-boundary origin :kind :character))
                 (%org-table-element-boundary origin)
                 (%org-list-element-boundary origin)
                 (%org-postblank-element-boundary origin)
                 (%org-paragraph-boundary origin))))))

(defun %org-next-element (origin)
  (with-point ((point origin))
    (loop
      (alexandria:when-let ((boundary (%org-element-at-point point)))
        (when (not (point< (%org-boundary-start boundary) origin))
          (return boundary)))
      (when (%org-boundary-scan-barrier-p point)
        (return nil))
      (unless (line-offset point 1)
        (return nil)))))

;;; --- greater elements and subtree ancestry ------------------------------

(defun %org-heading-boundary (heading &key (kind :line))
  (when (org-heading-line-p heading)
    (let ((end (org-subtree-end-point heading))
          (inner-start (%org-line-after heading)))
      (when end
        (%make-org-boundary
         (with-point ((start heading))
           (line-start start)
           (copy-point start :temporary))
         (copy-point end :temporary)
         inner-start (copy-point end :temporary)
         kind :headline)))))

(defun %org-section-boundary (origin)
  (let ((block (%org-block-boundary-at origin))
        (drawer (%org-drawer-boundary-at origin)))
    (unless (or (%org-unclosed-block-at-p origin)
                (and (%org-special-line-p origin)
                     (null block)
                     (null drawer))
                (%org-list-continuation-context-p origin)
                (org-heading-line-p origin))
      (alexandria:if-let ((heading (org-current-heading-point origin)))
        (let ((start (%org-line-after heading))
              (end (org-section-end-point heading)))
          (when (and start end
                     (%org-point-in-half-open-range-p origin start end))
            (%make-org-boundary
             start end start end :line :section)))
        (let ((start (copy-point
                      (buffer-start-point (point-buffer origin)) :temporary))
              (end (or (org-next-heading-point
                        (buffer-start-point (point-buffer origin)))
                       (copy-point
                        (buffer-end-point (point-buffer origin)) :temporary))))
          (when (and (point< start end)
                     (%org-point-in-half-open-range-p origin start end))
            (%make-org-boundary
             start end start end :line :section)))))))

(defun %org-heading-ancestors (origin)
  (let ((result '())
        (heading (org-current-heading-point origin)))
    (loop :while heading
          :do (alexandria:when-let ((boundary (%org-heading-boundary heading)))
                (push boundary result))
              (setf heading (org-parent-heading-point heading)))
    (nreverse result)))

(defun %org-list-greater-chain (item)
  (let ((result '())
        (current item))
    (loop :while current
          :do (alexandria:when-let ((item-boundary
                                      (%org-list-item-boundary current)))
                (setf (%org-boundary-kind item-boundary) :line)
                (push item-boundary result))
              (alexandria:when-let ((list-boundary
                                      (%org-plain-list-boundary current)))
                (push list-boundary result))
              (setf current (%org-parent-list-item current)))
    (nreverse result)))

(defun %org-greater-block-boundary-p (boundary)
  (let ((node-type (and boundary (%org-boundary-node-type boundary))))
    (when (and (consp node-type) (eq (car node-type) :block))
      (let ((type (cdr node-type)))
        (or (member type '("quote" "center") :test #'string=)
            ;; Org parses unknown #+begin_NAME blocks as recursive special
            ;; blocks.  Known leaf blocks instead climb to their section.
            (not (member type
                         '("src" "example" "export" "comment" "verse")
                         :test #'string=)))))))

(defun %org-greater-chain (origin)
  (let ((block (%org-block-boundary-at origin))
        (drawer (%org-drawer-boundary-at origin)))
    (when drawer
      (setf (%org-boundary-kind drawer) :line)
      (return-from %org-greater-chain
        (append
         (list drawer)
         (alexandria:when-let ((section (%org-section-boundary origin)))
           (list section))
         (%org-heading-ancestors origin))))
    (when (or (%org-inside-drawer-p origin)
              (%org-unclosed-block-at-p origin)
              (%org-list-continuation-context-p origin)
              (and (%org-special-line-p origin) (null block))
              (and (org-list-item-line-p origin)
                   (not (%org-current-list-item origin))))
      (return-from %org-greater-chain nil))
    (multiple-value-bind (list-context item text-column)
        (%org-list-point-context origin)
      (declare (ignore text-column))
      (let* ((postblank (%org-postblank-element-boundary origin))
             (table (%org-table-boundary origin))
             (local
               (cond
                 ((org-heading-line-p origin) nil)
                 (list-context
                  (let ((chain (%org-list-greater-chain item)))
                    (if (eq list-context :plain-list)
                        (rest chain)
                        chain)))
                 ((%org-greater-block-boundary-p block)
                  (setf (%org-boundary-kind block) :line)
                  (list block))
                 (table (list table))
                 ((and postblank
                       (member (%org-boundary-node-type postblank)
                               '(:plain-list :table)))
                  (setf (%org-boundary-kind postblank) :line)
                  (list postblank))
                 (t
                  (alexandria:when-let
                      ((section (%org-section-boundary origin)))
                    (list section))))))
        (if (org-heading-line-p origin)
            (%org-heading-ancestors origin)
            (append local
                    (unless (find :section local
                                  :key #'%org-boundary-node-type)
                      (alexandria:when-let
                          ((section (%org-section-boundary origin)))
                        (list section)))
                    (%org-heading-ancestors origin)))))))

(defun %org-subtree-boundary (origin count)
  (let ((drawer (%org-drawer-boundary-at origin)))
    (unless (or (and (%org-inside-drawer-p origin) (null drawer))
                (%org-unclosed-block-at-p origin)
              (and (%org-special-line-p origin)
                     (null (%org-block-boundary-at origin))
                     (null drawer)))
      (alexandria:when-let ((heading (org-current-heading-point origin)))
        ;; Evil-Org saturates an over-large subtree count at the root heading.
        (dotimes (_ (1- count))
          (alexandria:when-let ((parent (org-parent-heading-point heading)))
            (setf heading parent)))
        (%org-heading-boundary heading)))))

;;; --- public boundary API -------------------------------------------------

(defun org-text-object-boundary
    (class inner-p &key (origin (current-point)) (count 1)
                         selection-start selection-end)
  "Return a conservative Org text-object boundary.

CLASS is :OBJECT, :ELEMENT, :GREATER-ELEMENT, or :SUBTREE.  Return three
values: an inclusive temporary START point, an exclusive temporary END point,
and either :CHARACTER or :LINE.  Unsupported, malformed, empty-inner, and
ambiguous contexts return NIL values without moving point or editing text.

COUNT moves outer object/element requests forward, climbs greater-element or
subtree ancestry, and is intentionally ignored for inner object/element
requests, matching the pinned Evil-Org implementation.  SELECTION-START and
SELECTION-END may be existing visual bounds.  For outer object/element
expansion, scanning begins at SELECTION-END and START remains anchored at the
earlier of SELECTION-START and the new node, preserving Evil-Org's expansion
quirk."
  (let ((count (%org-positive-count count)))
    (unless count
      (return-from org-text-object-boundary (values nil nil nil)))
    (labels
        ((count-forward (first next-function)
           (let ((boundary first))
             (dotimes (_ (1- count) boundary)
               (setf boundary
                     (and boundary
                          (funcall next-function
                                   (%org-boundary-end boundary)))))))
         (anchor-outer-start (boundary)
           (let ((anchor (or selection-start origin)))
             (when (and boundary
                        (point< anchor (%org-boundary-start boundary)))
             (setf (%org-boundary-start boundary)
                     (copy-point anchor :temporary))))
           boundary))
      (let ((boundary
              (ecase class
                (:object
                 (if inner-p
                     (%org-object-at-point origin)
                     (anchor-outer-start
                      (count-forward
                       (or (%org-object-at-point (or selection-end origin))
                           (and selection-end
                                (%org-next-object selection-end)))
                       #'%org-next-object))))
                (:element
                 (if inner-p
                     (%org-element-at-point origin)
                     (anchor-outer-start
                      (count-forward
                       (or (%org-element-at-point (or selection-end origin))
                           (and selection-end
                                (%org-next-element selection-end)))
                       #'%org-next-element))))
                (:greater-element
                 (let* ((anchor (or selection-start origin))
                        (chain (%org-greater-chain anchor))
                        (covered-first-p
                          (and (not inner-p) selection-end chain
                               (not (point< selection-end
                                            (%org-boundary-end
                                             (first chain))))))
                        (index (+ (1- count) (if covered-first-p 1 0))))
                   (nth index chain)))
                (:subtree
                 (%org-subtree-boundary origin count)))))
        ;; Inner greater elements are characterwise in Evil-Org; outer greater
        ;; elements and both subtree variants are linewise.
        (when (and boundary inner-p (eq class :greater-element))
          (setf (%org-boundary-kind boundary) :character))
        (%org-boundary-range boundary inner-p)))))
