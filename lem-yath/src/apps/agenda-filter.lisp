;;;; Stacked GNU Org and Evil-Org agenda filters for the bounded agenda view.

(in-package :lem-yath)

(defparameter *agenda-filter-effort-values*
  '("0" "0:10" "0:30" "1:00" "2:00" "3:00" "4:00" "5:00"
    "6:00" "7:00")
  "The pinned Org default Effort choices, addressed by 1..9 and 0.")

(defparameter *agenda-filter-duration-unit-minutes*
  '(("min" . 1d0) ("h" . 60d0) ("d" . 1440d0)
    ("w" . 10080d0) ("m" . 43200d0) ("y" . 525960d0)))

(defparameter *agenda-filter-duration-token-scanner*
  (ppcre:create-scanner
   "([0-9]+(?:\\.[0-9]*)?)\\s*(min|h|d|w|m|y)"))

(defstruct (agenda-filter-condition
            (:constructor make-agenda-filter-condition))
  value negative-p scanner operator minutes)

(defstruct (agenda-filter-state (:constructor make-agenda-filter-state))
  category tags regexps efforts top-headline limit limit-generation)

(defun agenda-filter-state (buffer)
  (or (buffer-value buffer 'lem-yath-agenda-filter-state)
      (setf (buffer-value buffer 'lem-yath-agenda-filter-state)
            (make-agenda-filter-state))))

(defun agenda-filter-prefix-magnitude (argument)
  (if argument (org-prefix-magnitude argument) 0))

(defun agenda-filter-decimal (value)
  "Parse a non-negative decimal VALUE without invoking the Lisp reader."
  (let ((dot (position #\. value)))
    (if dot
        (let* ((whole (if (zerop dot) 0 (parse-integer value :end dot)))
               (fraction-text (subseq value (1+ dot)))
               (scale (expt 10 (length fraction-text)))
               (fraction (if (zerop (length fraction-text))
                             0
                             (parse-integer fraction-text))))
          (+ (coerce whole 'double-float)
             (/ (coerce fraction 'double-float) scale)))
        (coerce (parse-integer value) 'double-float))))

(defun agenda-filter-hms-minutes (value)
  (let ((parts (uiop:split-string value :separator '(#\:))))
    (when (member (length parts) '(2 3))
      (let ((hours (parse-integer (first parts)))
            (minutes (parse-integer (second parts)))
            (seconds (and (third parts) (parse-integer (third parts)))))
        (+ (* 60d0 hours) minutes (/ (or seconds 0) 60d0))))))

(defun agenda-filter-unit-minutes (value)
  (let ((total 0d0))
    (ppcre:do-register-groups (number unit)
        (*agenda-filter-duration-token-scanner* value)
      (incf total
            (* (agenda-filter-decimal number)
               (or (cdr (assoc unit *agenda-filter-duration-unit-minutes*
                               :test #'string=))
                   (error "Unknown duration unit: ~a" unit)))))
    total))

(defun agenda-filter-duration-minutes (value)
  "Translate Org duration VALUE to minutes using the pinned default units."
  (when value
    (let ((trimmed (string-trim '(#\Space #\Tab #\Return) value)))
      (unless (agenda-duration-p trimmed)
        (error "Invalid duration format: ~s" value))
      (cond
        ((string= trimmed "") 0d0)
        ((ppcre:scan "^[0-9]+(?::[0-9]{2}){1,2}$" trimmed)
         (agenda-filter-hms-minutes trimmed))
        ((ppcre:scan "^[0-9]+(?:\\.[0-9]*)?$" trimmed)
         (agenda-filter-decimal trimmed))
        (t
         (multiple-value-bind (start end registers register-ends)
             (ppcre:scan "([0-9]+(?::[0-9]{2}){1,2})\\s*$" trimmed)
           (declare (ignore end))
           (if (and start registers (plusp start))
               (+ (agenda-filter-unit-minutes (subseq trimmed 0 start))
                  (agenda-filter-hms-minutes
                   (subseq trimmed (aref registers 0)
                           (aref register-ends 0))))
               (agenda-filter-unit-minutes trimmed))))))))

(defun agenda-filter-condition-match-p (condition matched-p)
  (if (agenda-filter-condition-negative-p condition)
      (not matched-p)
      matched-p))

(defun agenda-filter-categories-match-p (conditions item)
  "Match GNU Org's OR-positive and AND-negative category semantics."
  (let ((category (or (agenda-item-category item) ""))
        (positive '())
        (negative '()))
    (dolist (condition conditions)
      (if (agenda-filter-condition-negative-p condition)
          (push condition negative)
          (push condition positive)))
    (and (or (null positive)
             (some (lambda (condition)
                     (string= category
                              (agenda-filter-condition-value condition)))
                   positive))
         (every (lambda (condition)
                  (not (string= category
                                (agenda-filter-condition-value condition))))
                negative))))

(defun agenda-filter-top-headline-match-p (condition item)
  (agenda-filter-condition-match-p
   condition
   (string= (agenda-filter-condition-value condition)
            (or (agenda-item-top-headline item) ""))))

(defun agenda-filter-tag-match-p (condition item)
  (let ((tag (agenda-filter-condition-value condition))
        (tags (agenda-item-tags item)))
    (agenda-filter-condition-match-p
     condition
     (if (string= tag "")
         (not (null tags))
         (not (null (member tag tags :test #'string=)))))))

(defun agenda-filter-regexp-match-p (condition item)
  (agenda-filter-condition-match-p
   condition
   (not (null
         (ppcre:scan (agenda-filter-condition-scanner condition)
                     (agenda-display-line item))))))

(defun agenda-filter-effort-match-p (condition item)
  (let ((effort
          (if (agenda-item-effort item)
              (agenda-filter-duration-minutes (agenda-item-effort item))
              most-positive-fixnum))
        (threshold (agenda-filter-condition-minutes condition)))
    (agenda-filter-condition-match-p
     condition
     (ecase (agenda-filter-condition-operator condition)
       (#\< (<= effort threshold))
       (#\> (>= effort threshold))
       (#\= (= effort threshold))))))

(defun agenda-filter-item-visible-p (buffer item)
  "Whether ITEM satisfies every active agenda filter in BUFFER."
  (let ((state (agenda-filter-state buffer)))
    (and
     (agenda-filter-categories-match-p
      (agenda-filter-state-category state) item)
     (or (null (agenda-filter-state-top-headline state))
         (agenda-filter-top-headline-match-p
          (agenda-filter-state-top-headline state) item))
     (every (lambda (condition)
              (agenda-filter-tag-match-p condition item))
            (agenda-filter-state-tags state))
     (every (lambda (condition)
              (agenda-filter-regexp-match-p condition item))
            (agenda-filter-state-regexps state))
     (every (lambda (condition)
              (agenda-filter-effort-match-p condition item))
            (agenda-filter-state-efforts state)))))

(defun agenda-filter-effective-limit (buffer)
  (let ((state (agenda-filter-state buffer)))
    (when (and (agenda-filter-state-limit state)
               (= (or (agenda-filter-state-limit-generation state) -1)
                  (agenda-buffer-generation buffer)))
      (agenda-filter-state-limit state))))

(defun agenda-filter-limit-value (item kind)
  (ecase kind
    (:entries 1)
    (:todos (and (agenda-item-keyword item) 1))
    (:tags (and (agenda-item-tags item) 1))
    (:effort
     (if (agenda-item-effort item)
         (agenda-filter-duration-minutes (agenda-item-effort item))
         most-positive-fixnum))))

(defun agenda-filter-limit-items (items kind maximum)
  "Apply GNU Org's cumulative MAXIMUM limiter to one sorted section."
  (let ((include-unqualified-p (minusp maximum))
        (limit (abs maximum))
        (total 0d0)
        (result '()))
    (dolist (item items (nreverse result))
      (let ((value (agenda-filter-limit-value item kind)))
        (when value (incf total value))
        (when (or (and value (<= total limit))
                  (and include-unqualified-p (null value)))
          (push item result))))))

(defun agenda-filter-transform-section (buffer section items)
  (declare (ignore section))
  (alexandria:if-let ((limit (agenda-filter-effective-limit buffer)))
    (agenda-filter-limit-items items (first limit) (second limit))
    items))

(defun agenda-filter-condition-label (condition prefix)
  (format nil "~a~a~a"
          prefix
          (if (agenda-filter-condition-negative-p condition) "-" "+")
          (agenda-filter-condition-value condition)))

(defun agenda-filter-status (buffer)
  "Return a compact, visible summary of BUFFER's active filters and limit."
  (let* ((state (agenda-filter-state buffer))
         (parts
           (append
            (mapcar (lambda (condition)
                      (agenda-filter-condition-label condition "Cat:"))
                    (agenda-filter-state-category state))
            (mapcar (lambda (condition)
                      (agenda-filter-condition-label condition "Tag:"))
                    (agenda-filter-state-tags state))
            (mapcar (lambda (condition)
                      (agenda-filter-condition-label condition "Re:"))
                    (agenda-filter-state-regexps state))
            (mapcar
             (lambda (condition)
               (format nil "Eff:~a~c~a"
                       (if (agenda-filter-condition-negative-p condition)
                           "-" "+")
                       (agenda-filter-condition-operator condition)
                       (agenda-filter-condition-value condition)))
             (agenda-filter-state-efforts state))
            (when (agenda-filter-state-top-headline state)
              (list (agenda-filter-condition-label
                     (agenda-filter-state-top-headline state) "Top:")))
            (alexandria:when-let ((limit (agenda-filter-effective-limit buffer)))
              (list (format nil "Max-~(~a~):~d" (first limit) (second limit)))))))
    (if parts (format nil "  [~{~a~^ ~}]" parts) "")))

(defun agenda-filter-rerender (&optional (buffer (current-buffer)))
  "Re-render BUFFER from its last unfiltered scan without source I/O."
  (let ((items (buffer-value buffer 'lem-yath-agenda-cached-items)))
    (if (null (buffer-value buffer 'lem-yath-agenda-cache-ready))
        (message "Agenda data is not ready yet")
        (progn
          (setf (buffer-value buffer 'lem-yath-agenda-restore-entry)
                (agenda-entry-key-at-point (buffer-point buffer)))
          (render-agenda
           buffer items
           (buffer-value buffer 'lem-yath-agenda-cached-failures)
           (buffer-value buffer 'lem-yath-agenda-cached-clock-report))
          t))))

(defun agenda-filter-current-value (property description)
  (or (text-property-at (current-point) property)
      (progn
        (message "No ~a on this agenda line" description)
        nil)))

(defun agenda-filter-known-categories (buffer)
  (sort
   (agenda-unique-strings
    (loop :for item :in (buffer-value buffer 'lem-yath-agenda-cached-items)
          :for category := (agenda-item-category item)
          :when category :collect category))
   #'string-lessp))

(defun agenda-filter-general-name-delimiter-p (character)
  (member character '(#\Space #\Tab #\Return #\Newline
                      #\+ #\- #\< #\> #\= #\/)
          :test #'char=))

(defun agenda-filter-general-quoted-category (category)
  (if (or (find #\" category)
          (not (find-if #'agenda-filter-general-name-delimiter-p category)))
      category
      (format nil "\"~a\"" category)))

(defun agenda-filter-general-completion-candidates (buffer)
  "Return represented general-filter names with tag priority."
  (remove-duplicates
   (append
    (remove-if (lambda (tag)
                 (find-if #'agenda-filter-general-name-delimiter-p tag))
               (agenda-filter-known-tags buffer))
    (mapcar #'agenda-filter-general-quoted-category
            (agenda-filter-known-categories buffer)))
   :test #'string=))

(defun agenda-filter-general-completion-boundary (input)
  "Return the last active component delimiter in general filter INPUT.

Quoted category punctuation and regexp contents are data, not boundaries."
  (let ((boundary nil)
        (quoted-p nil)
        (regexp-p nil))
    (loop :for character :across input
          :for index :from 0
          :do
             (cond
               (regexp-p
                (when (char= character #\/)
                  (setf regexp-p nil)))
               (quoted-p
                (when (char= character #\")
                  (setf quoted-p nil)))
               ((char= character #\")
                (setf quoted-p t))
               ((char= character #\/)
                (setf boundary index
                      regexp-p t))
               ((member character '(#\+ #\- #\< #\> #\=)
                        :test #'char=)
                (setf boundary index))))
    boundary))

(defun agenda-filter-general-completions (buffer input)
  "Complete the active name or Effort component of general filter INPUT."
  ;; Lem opens a synchronous completion provider while the prompt's editable
  ;; field is still empty.  Returning candidates at that instant asks the
  ;; completion range code to inspect a nonexistent preceding character.
  (when (zerop (length input))
    (return-from agenda-filter-general-completions nil))
  (let* ((boundary (agenda-filter-general-completion-boundary input))
         (operator (and boundary (char input boundary)))
         (start (if boundary (1+ boundary) 0))
         (prefix (subseq input 0 start))
         (needle (subseq input start))
         (candidates
           (cond
             ((member operator '(#\< #\> #\=) :test #'char=)
              *agenda-filter-effort-values*)
             ((and operator (char= operator #\/)) nil)
             (t (agenda-filter-general-completion-candidates buffer)))))
    (let ((completions
            (mapcar (lambda (candidate)
                      (concatenate 'string prefix candidate))
                    (prescient-filter needle candidates))))
      ;; An exact expression is ready for the prompt's Return command.  Leaving
      ;; an exact singleton displayed would make the first Return merely accept
      ;; the already-present candidate and require an Emacs-incongruent second
      ;; Return to apply the filter.
      (unless (member input completions :test #'string=)
        completions))))

(defun agenda-filter-condition-equal-p (left right)
  (and (string= (agenda-filter-condition-value left)
                (agenda-filter-condition-value right))
       (eql (agenda-filter-condition-negative-p left)
            (agenda-filter-condition-negative-p right))
       (eql (agenda-filter-condition-operator left)
            (agenda-filter-condition-operator right))))

(defun agenda-filter-merge-conditions (existing additions)
  (remove-duplicates (append existing additions)
                     :test #'agenda-filter-condition-equal-p
                     :from-end t))

(defun agenda-filter-general-condition-label (condition &key regexp-p)
  (format nil "~c~a~a~a"
          (if (agenda-filter-condition-negative-p condition) #\- #\+)
          (or (agenda-filter-condition-operator condition) "")
          (if regexp-p "/" "")
          (if regexp-p
              (concatenate 'string
                           (agenda-filter-condition-value condition) "/")
              (agenda-filter-condition-value condition))))

(defun agenda-filter-general-current-input (state)
  (with-output-to-string (stream)
    (dolist (condition (agenda-filter-state-category state))
      (write-string
       (agenda-filter-general-condition-label
        (make-agenda-filter-condition
         :value (agenda-filter-general-quoted-category
                 (agenda-filter-condition-value condition))
         :negative-p (agenda-filter-condition-negative-p condition)))
       stream))
    (dolist (condition (agenda-filter-state-tags state))
      (write-string (agenda-filter-general-condition-label condition) stream))
    (dolist (condition (agenda-filter-state-efforts state))
      (write-string (agenda-filter-general-condition-label condition) stream))
    (dolist (condition (agenda-filter-state-regexps state))
      (write-string
       (agenda-filter-general-condition-label condition :regexp-p t)
       stream))))

(defun agenda-filter-general-parse (input tags categories negate-p)
  "Parse GNU Org general filter INPUT without evaluating Lisp.

Return category, tag, Effort, and regexp conditions plus ignored names."
  (let ((index 0)
        (length (length input))
        (category-conditions '())
        (tag-conditions '())
        (effort-conditions '())
        (regexp-conditions '())
        (ignored '()))
    (labels
        ((skip-space ()
           (loop :while (and (< index length)
                             (member (char input index)
                                     '(#\Space #\Tab #\Return #\Newline)
                                     :test #'char=))
                 :do (incf index)))
         (negative-p (explicit-negative-p)
           (if negate-p (not explicit-negative-p) explicit-negative-p))
         (add-name (name explicit-negative-p)
           (let ((condition
                   (make-agenda-filter-condition
                    :value name
                    :negative-p (negative-p explicit-negative-p))))
             (cond
               ((member name tags :test #'string=)
                (push condition tag-conditions))
               ((member name categories :test #'string=)
                (push condition category-conditions))
               (t (push name ignored)))))
         (read-name ()
           (if (and (< index length) (char= (char input index) #\"))
               (let ((end (position #\" input :start (1+ index))))
                 (if end
                     (prog1 (subseq input (1+ index) end)
                       (setf index (1+ end)))
                     (prog1 nil (setf index length))))
               (let ((start index))
                 (loop :while (and (< index length)
                                   (not (agenda-filter-general-name-delimiter-p
                                         (char input index))))
                       :do (incf index))
                 (and (< start index) (subseq input start index)))))
         (read-effort (operator explicit-negative-p)
           (let ((start index))
             (loop :while (and (< index length)
                               (or (digit-char-p (char input index))
                                   (char= (char input index) #\:)))
                   :do (incf index))
             (if (= start index)
                 (push (subseq input start) ignored)
                 (let ((value (subseq input start index)))
                   (handler-case
                       (push
                        (make-agenda-filter-condition
                         :value value
                         :negative-p (negative-p explicit-negative-p)
                         :operator operator
                         :minutes (agenda-filter-duration-minutes value))
                        effort-conditions)
                     (error ()
                       (editor-error "Invalid agenda Effort: ~a" value)))))))
         (read-regexp (explicit-negative-p)
           (incf index)
           (let* ((start index)
                  (end (or (position #\/ input :start index) length))
                  (pattern (subseq input start end)))
             (setf index (if (< end length) (1+ end) end))
             (if (zerop (length pattern))
                 (push pattern ignored)
                 (let ((scanner
                         (handler-case
                             (ppcre:create-scanner
                              (project-regexp-to-extended pattern)
                              :case-insensitive-mode t)
                           (error ()
                             (editor-error
                              "Invalid agenda regexp: ~a" pattern)))))
                   (push
                    (make-agenda-filter-condition
                     :value pattern
                     :negative-p (negative-p explicit-negative-p)
                     :scanner scanner)
                    regexp-conditions))))))
      (loop
        (skip-space)
        (when (>= index length) (return))
        (let ((explicit-negative-p nil))
          (when (member (char input index) '(#\+ #\-) :test #'char=)
            (setf explicit-negative-p (char= (char input index) #\-))
            (incf index))
          (when (>= index length) (return))
          (let ((character (char input index)))
            (cond
              ((member character '(#\< #\> #\=) :test #'char=)
               (incf index)
               (read-effort character explicit-negative-p))
              ((char= character #\/)
               (read-regexp explicit-negative-p))
              (t
               (alexandria:if-let ((name (read-name)))
                 (add-name name explicit-negative-p)
                 (progn
                   (push (subseq input index) ignored)
                   (setf index length)))))))))
    (values (nreverse category-conditions)
            (nreverse tag-conditions)
            (nreverse effort-conditions)
            (nreverse regexp-conditions)
            (nreverse ignored))))

(define-command lem-yath-agenda-filter-general (&optional argument)
    (:universal-nil)
  "Prompt for GNU Org's combined category/tag/Effort/regexp filter."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer))
         (magnitude (agenda-filter-prefix-magnitude argument)))
    (when (= magnitude 64)
      (editor-error "Agenda auto-exclude function is not configured"))
    (let* ((initial (agenda-filter-general-current-input state))
           (raw-input
             (prompt-for-string
              (if (= magnitude 4)
                  "Negative filter [+cat-tag<0:10-/regexp/]: "
                  "Filter [+cat-tag<0:10-/regexp/]: ")
              :initial-value initial
              :completion-function
              (lambda (input)
                (agenda-filter-general-completions buffer input))
              :history-symbol 'lem-yath-agenda-general-filters))
           (shortcut-p
             (and (> (length raw-input) 1)
                  (char= (char raw-input 0) #\+)
                  (member (char raw-input 1) '(#\+ #\-) :test #'char=)))
           (input (if shortcut-p (subseq raw-input 1) raw-input))
           (accumulate-p (or (= magnitude 16) shortcut-p)))
      (multiple-value-bind (categories tags efforts regexps ignored)
          (agenda-filter-general-parse
           input
           (agenda-filter-known-tags buffer)
           (agenda-filter-known-categories buffer)
           (= magnitude 4))
        (setf (agenda-filter-state-category state)
              (if accumulate-p
                  (agenda-filter-merge-conditions
                   (agenda-filter-state-category state) categories)
                  categories)
              (agenda-filter-state-tags state)
              (if accumulate-p
                  (agenda-filter-merge-conditions
                   (agenda-filter-state-tags state) tags)
                  tags)
              (agenda-filter-state-efforts state)
              (if accumulate-p
                  (agenda-filter-merge-conditions
                   (agenda-filter-state-efforts state) efforts)
                  efforts)
              (agenda-filter-state-regexps state)
              (if accumulate-p
                  (agenda-filter-merge-conditions
                   (agenda-filter-state-regexps state) regexps)
                  regexps)
              (agenda-filter-state-top-headline state) nil)
        (agenda-filter-rerender buffer)
        (if ignored
            (message "Agenda filter applied; ignored: ~{~s~^, ~}" ignored)
            (message "Agenda filter applied"))))))

(define-command lem-yath-agenda-filter-by-category (&optional argument)
    (:universal-nil)
  "Toggle a positive or prefix-negative filter for the category at point."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer)))
    (if (agenda-filter-state-category state)
        (progn
          (setf (agenda-filter-state-category state) nil)
          (agenda-filter-rerender buffer)
          (message "Category filter removed"))
        (alexandria:when-let
            ((category (agenda-filter-current-value
                        :agenda-category "category")))
          (setf (agenda-filter-state-category state)
                (list
                 (make-agenda-filter-condition
                  :value category :negative-p (not (null argument)))))
          (agenda-filter-rerender buffer)
          (message "Category filter: ~a~a"
                   (if argument "exclude " "") category)))))

(define-command lem-yath-agenda-filter-by-top-headline (&optional argument)
    (:universal-nil)
  "Toggle a positive or prefix-negative filter for point's top headline."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer)))
    (if (agenda-filter-state-top-headline state)
        (progn
          (setf (agenda-filter-state-top-headline state) nil)
          (agenda-filter-rerender buffer)
          (message "Top-headline filter removed"))
        (alexandria:when-let
            ((headline (agenda-filter-current-value
                        :agenda-top-headline "top-level headline")))
          (setf (agenda-filter-state-top-headline state)
                (make-agenda-filter-condition
                 :value headline :negative-p (not (null argument))))
          (agenda-filter-rerender buffer)
          (message "Top-headline filter: ~a~a"
                   (if argument "exclude " "") headline)))))

(defun agenda-filter-read-regexp (negative-p)
  (let* ((pattern
           (prompt-for-string
            (if negative-p
                "Hide entries matching regexp: "
                "Narrow to entries matching regexp: ")))
         (scanner
           (handler-case
               (ppcre:create-scanner
                (project-regexp-to-extended pattern)
                :case-insensitive-mode t)
             (error () (editor-error "Invalid agenda regexp")))))
    (make-agenda-filter-condition
     :value pattern :negative-p negative-p :scanner scanner)))

(define-command lem-yath-agenda-filter-by-regexp (&optional argument)
    (:universal-nil)
  "Toggle, negate, or double-prefix-accumulate an agenda regexp filter."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer))
         (magnitude (agenda-filter-prefix-magnitude argument))
         (accumulate-p (= magnitude 16)))
    (if (and (agenda-filter-state-regexps state) (not accumulate-p))
        (progn
          (setf (agenda-filter-state-regexps state) nil)
          (agenda-filter-rerender buffer)
          (message "Regexp filter removed"))
        (let ((condition (agenda-filter-read-regexp (= magnitude 4))))
          (setf (agenda-filter-state-regexps state)
                (append (if accumulate-p
                            (agenda-filter-state-regexps state)
                            nil)
                        (list condition)))
          (agenda-filter-rerender buffer)
          (message "Regexp filter applied")))))

(defun agenda-filter-read-effort-condition (negative-p)
  (loop :for operator := (prompt-for-character
                          "Effort operator? (> = or <), or _ to remove: ")
        :do
           (cond
             ((null operator) (return nil))
             ((char= operator #\_) (return :remove))
             ((member operator '(#\< #\> #\=) :test #'char=)
              (let ((choice
                      (loop :for character :=
                              (prompt-for-character
                               "Effort [1]0 [2]0:10 [3]0:30 [4]1:00 [5]2:00 [6]3:00 [7]4:00 [8]5:00 [9]6:00 [0]7:00: ")
                            :for index :=
                              (and character
                                   (digit-char-p character))
                            :when index
                              :return (nth (mod (1- index) 10)
                                           *agenda-filter-effort-values*))))
                (return
                  (make-agenda-filter-condition
                   :value choice
                   :negative-p negative-p
                   :operator operator
                   :minutes (agenda-filter-duration-minutes choice))))))))

(define-command lem-yath-agenda-filter-by-effort (&optional argument)
    (:universal-nil)
  "Apply, negate, accumulate, or explicitly remove an Effort filter."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer))
         (magnitude (agenda-filter-prefix-magnitude argument))
         (accumulate-p (= magnitude 16))
         (condition (agenda-filter-read-effort-condition (= magnitude 4))))
    (cond
      ((null condition))
      ((eq condition :remove)
       (setf (agenda-filter-state-efforts state) nil)
       (agenda-filter-rerender buffer)
       (message "Effort filter removed"))
      (t
       (setf (agenda-filter-state-efforts state)
             (append (if accumulate-p
                         (agenda-filter-state-efforts state)
                         nil)
                     (list condition)))
       (agenda-filter-rerender buffer)
       (message "Effort filter applied")))))

(defun agenda-filter-known-tags (buffer)
  (sort
   (agenda-unique-strings
    (loop :for item :in (buffer-value buffer 'lem-yath-agenda-cached-items)
          :nconc (copy-list (agenda-item-tags item))))
   #'string-lessp))

(defun agenda-filter-read-tag-name (buffer)
  (let ((tags (agenda-filter-known-tags buffer)))
    (prompt-for-string
     "Tag: "
     :completion-function
     (lambda (input) (prescient-filter input tags :category :symbol))
     :test-function (lambda (input) (member input tags :test #'string=))
     :history-symbol 'lem-yath-agenda-filter-tags)))

(defun agenda-filter-read-tag-selection (buffer exclude-p)
  "Return tag list, exclusion mode, and action from Org's tag dispatcher."
  (loop
    :for character :=
      (prompt-for-character
       (format nil "~a by tag: [SPC]tagged [TAB]tag [.]at point [\\]off [q]uit: "
               (if exclude-p "Exclude[+]" "Filter[-]")))
    :do
       (cond
         ((or (null character) (member character '(#\q #\Q #\Escape)
                                       :test #'char=))
          (return (values nil exclude-p :cancel)))
         ((char= character #\-)
          (setf exclude-p t))
         ((char= character #\+)
          (setf exclude-p nil))
         ((char= character #\\)
          (return (values nil exclude-p :remove)))
         ((or (char= character #\Return) (char= character #\Newline))
          (return (values nil exclude-p :remove)))
         ((char= character #\Space)
          (return (values (list "") exclude-p :apply)))
         ((char= character #\Tab)
          (return (values (list (agenda-filter-read-tag-name buffer))
                          exclude-p :apply)))
         ((char= character #\.)
          (alexandria:if-let
              ((tags (text-property-at (current-point) :agenda-tags)))
            (return (values (copy-list tags) exclude-p :apply))
            (message "No tags on this agenda line"))))))

(define-command lem-yath-agenda-filter-by-tag (&optional argument)
    (:universal-nil)
  "Filter by tags with Org's prefix-negation and accumulation behavior."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer))
         (magnitude (agenda-filter-prefix-magnitude argument))
         (accumulate-p (= magnitude 16)))
    (multiple-value-bind (tags exclude-p action)
        (agenda-filter-read-tag-selection buffer (= magnitude 4))
      (ecase action
        (:cancel nil)
        (:remove
         (setf (agenda-filter-state-tags state) nil)
         (agenda-filter-rerender buffer)
         (message "Tag filter removed"))
        (:apply
         (setf (agenda-filter-state-tags state)
               (append
                (if accumulate-p (agenda-filter-state-tags state) nil)
                (mapcar
                 (lambda (tag)
                   (make-agenda-filter-condition
                    :value tag :negative-p exclude-p))
                 tags)))
         (agenda-filter-rerender buffer)
         (message "Tag filter applied"))))))

(define-command lem-yath-agenda-limit-interactively (&optional argument)
    (:universal-nil)
  "Temporarily limit entries, TODOs, tagged rows, or cumulative Effort."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer)))
    (if argument
        (progn
          (setf (agenda-filter-state-limit state) nil
                (agenda-filter-state-limit-generation state) nil)
          (agenda-filter-rerender buffer)
          (message "Agenda limits removed"))
        (let* ((character
                 (prompt-for-character
                  "Number of [e]ntries [t]odos [T]ags [E]ffort? "))
               (kind (case character
                       (#\e :entries) (#\t :todos)
                       (#\T :tags) (#\E :effort))))
          (if (null kind)
              (message "Wrong agenda limit input")
              (let ((number
                      (prompt-for-integer
                       (if (eq kind :effort)
                           "How many minutes? "
                           (format nil "How many ~(~a~)? " kind)))))
                (setf (agenda-filter-state-limit state) (list kind number)
                      (agenda-filter-state-limit-generation state)
                      (agenda-buffer-generation buffer))
                (agenda-filter-rerender buffer)
                (message "Agenda limit applied")))))))

(define-command lem-yath-agenda-filter-remove-all () ()
  "Remove all stacked filters; generation-local `ss' limits are unchanged."
  (let* ((buffer (current-buffer))
         (state (agenda-filter-state buffer)))
    (setf (agenda-filter-state-category state) nil
          (agenda-filter-state-tags state) nil
          (agenda-filter-state-regexps state) nil
          (agenda-filter-state-efforts state) nil
          (agenda-filter-state-top-headline state) nil)
    (agenda-filter-rerender buffer)
    (message "All agenda filters removed")))

(setf *agenda-item-filter-function* 'agenda-filter-item-visible-p
      *agenda-section-transform-function* 'agenda-filter-transform-section
      *agenda-status-function* 'agenda-filter-status)

;; Effective Evil-Org filter bindings.
(define-key *lem-yath-agenda-vi-keymap* "C-u"
  'lem/universal-argument:universal-argument)
(define-key *lem-yath-agenda-vi-keymap* "s c"
  'lem-yath-agenda-filter-by-category)
(define-key *lem-yath-agenda-vi-keymap* "s r"
  'lem-yath-agenda-filter-by-regexp)
(define-key *lem-yath-agenda-vi-keymap* "s e"
  'lem-yath-agenda-filter-by-effort)
(define-key *lem-yath-agenda-vi-keymap* "s t"
  'lem-yath-agenda-filter-by-tag)
(define-key *lem-yath-agenda-vi-keymap* "s ^"
  'lem-yath-agenda-filter-by-top-headline)
(define-key *lem-yath-agenda-vi-keymap* "s s"
  'lem-yath-agenda-limit-interactively)
(define-key *lem-yath-agenda-vi-keymap* "S"
  'lem-yath-agenda-filter-remove-all)

;; GNU Org's base agenda aliases remain available in Emacs state.
(define-key *lem-yath-agenda-mode-keymap* "\\"
  'lem-yath-agenda-filter-by-tag)
(define-key *lem-yath-agenda-mode-keymap* "_"
  'lem-yath-agenda-filter-by-effort)
(define-key *lem-yath-agenda-mode-keymap* "="
  'lem-yath-agenda-filter-by-regexp)
(define-key *lem-yath-agenda-mode-keymap* "/"
  'lem-yath-agenda-filter-general)
(define-key *lem-yath-agenda-mode-keymap* "|"
  'lem-yath-agenda-filter-remove-all)
(define-key *lem-yath-agenda-mode-keymap* "~"
  'lem-yath-agenda-limit-interactively)
(define-key *lem-yath-agenda-mode-keymap* "<"
  'lem-yath-agenda-filter-by-category)
(define-key *lem-yath-agenda-mode-keymap* "^"
  'lem-yath-agenda-filter-by-top-headline)
