;;;; Org agenda tag/property and text-search queries.

(in-package :lem-yath)

(defstruct (agenda-query-term (:constructor make-agenda-query-term))
  kind value operand negative-p operator starred-p scanner operand-kind)

(defstruct (agenda-tags-query (:constructor make-agenda-tags-query))
  raw tag-branches todo-branches todo-open-only-p)

(defstruct (agenda-search-query (:constructor make-agenda-search-query))
  raw headline-only-p todo-only-p required forbidden)

(defparameter *agenda-query-property-scanner*
  (ppcre:create-scanner
   "^((?:[A-Za-z0-9_]+|\\\\[^ \\t\\r\\n])+)(<=|>=|==|!=|/=|<>|=|<|>)(\\*)?(\\{[^}]+\\}|\"[^\"]*\"|-?[.0-9]+(?:[eE][-+]?[0-9]+)?)"))

(defun agenda-query-regexp-scanner (regexp &key (case-insensitive-p nil))
  (handler-case
      (ppcre:create-scanner
       (project-regexp-to-extended regexp)
       :case-insensitive-mode case-insensitive-p
       :multi-line-mode t)
    (error ()
      (editor-error "Invalid Org agenda query regexp: ~a" regexp))))

(defun agenda-query-split-top-level (string delimiter)
  "Split STRING on DELIMITER outside braces, quotes, and escapes."
  (let ((start 0)
        (brace-depth 0)
        (quoted-p nil)
        (escaped-p nil)
        pieces)
    (loop :for index :from 0 :below (length string)
          :for character := (char string index)
          :do
             (cond
               (escaped-p (setf escaped-p nil))
               ((char= character #\\) (setf escaped-p t))
               ((char= character #\") (setf quoted-p (not quoted-p)))
               (quoted-p)
               ((char= character #\{) (incf brace-depth))
               ((and (char= character #\}) (plusp brace-depth))
                (decf brace-depth))
               ((and (zerop brace-depth) (char= character delimiter))
                (push (subseq string start index) pieces)
                (setf start (1+ index)))))
    (push (subseq string start) pieces)
    (nreverse pieces)))

(defun agenda-query-unescape-property-name (name)
  (with-output-to-string (stream)
    (loop :with escaped-p := nil
          :for character :across name
          :do
             (cond
               (escaped-p
                (write-char character stream)
                (setf escaped-p nil))
               ((char= character #\\) (setf escaped-p t))
               (t (write-char character stream))))))

(defun agenda-query-number (text)
  (let ((*read-eval* nil))
    (handler-case
        (multiple-value-bind (value end) (read-from-string text nil nil)
          (if (and (numberp value) (= end (length text)))
              value
              0))
      (error () 0))))

(defun agenda-query-time-operand-p (value)
  (and (> (length value) 2)
       (member (char value 0) '(#\< #\[) :test #'char=)
       (member (char value (1- (length value))) '(#\> #\]) :test #'char=)))

(defun agenda-query-time-date (value)
  (let* ((contents
           (if (agenda-query-time-operand-p value)
               (subseq value 1 (1- (length value)))
               value))
         (date-token
           (or (and (ppcre:scan "[0-9]{4}-[0-9]{2}-[0-9]{2}" contents)
                    (multiple-value-bind (start end)
                        (ppcre:scan "[0-9]{4}-[0-9]{2}-[0-9]{2}" contents)
                      (subseq contents start end)))
               contents)))
    (org-parse-date-input date-token :prefer-future nil)))

(defun agenda-query-property-term (text negative-p)
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan *agenda-query-property-scanner* text)
    (when (and start (zerop start))
      (let* ((name
               (string-upcase
                (agenda-query-unescape-property-name
                 (subseq text (aref registers 0) (aref register-ends 0)))))
             (operator
               (subseq text (aref registers 1) (aref register-ends 1)))
             (starred-p (not (null (aref registers 2))))
             (raw
               (subseq text (aref registers 3) (aref register-ends 3)))
             (regexp-p (char= (char raw 0) #\{))
             (quoted-p (char= (char raw 0) #\"))
             (operand
               (if (or regexp-p quoted-p)
                   (subseq raw 1 (1- (length raw)))
                   raw))
             (time-p (and quoted-p (agenda-query-time-operand-p operand)))
             (kind (cond (regexp-p :regexp)
                         (time-p :time)
                         (quoted-p :string)
                         (t :number))))
        (values
         (make-agenda-query-term
          :kind :property :value name :operand operand
          :negative-p negative-p :operator operator :starred-p starred-p
          :scanner (and regexp-p (agenda-query-regexp-scanner operand))
          :operand-kind kind)
         end)))))

(defun agenda-query-parse-branch (branch &key todo-p)
  (let ((index 0)
        (length (length branch))
        terms)
    (loop :while (< index length)
          :do
             (when (char= (char branch index) #\&)
               (incf index))
             (when (>= index length)
               (editor-error "Incomplete Org agenda matcher: ~a" branch))
             (let ((negative-p nil))
               (when (member (char branch index) '(#\+ #\- #\:) :test #'char=)
                 (setf negative-p (char= (char branch index) #\-))
                 (incf index))
               (when (>= index length)
                 (editor-error "Incomplete Org agenda matcher: ~a" branch))
               (let ((rest (subseq branch index)))
                 (cond
                   ((char= (char rest 0) #\{)
                    (let ((end (position #\} rest)))
                      (unless end
                        (editor-error "Unclosed regexp in Org agenda matcher"))
                      (let ((regexp (subseq rest 1 end)))
                        (push
                         (make-agenda-query-term
                          :kind (if todo-p :todo-regexp :tag-regexp)
                          :value regexp :negative-p negative-p
                          :scanner (agenda-query-regexp-scanner regexp))
                         terms))
                      (incf index (1+ end))))
                   ((and (not todo-p)
                         (multiple-value-bind (term consumed)
                             (agenda-query-property-term rest negative-p)
                           (when term
                             (push term terms)
                             (incf index consumed)
                             t))))
                   (t
                    (multiple-value-bind (start end)
                        (ppcre:scan "^[A-Za-z0-9_@#%]+" rest)
                      (declare (ignore start))
                      (unless end
                        (editor-error "Invalid Org agenda matcher near: ~a" rest))
                      (let ((value (subseq rest 0 end)))
                        (push
                         (make-agenda-query-term
                          :kind (if todo-p :todo :tag)
                          :value value :negative-p negative-p)
                         terms))
                      (incf index end)))))))
    (nreverse terms)))

(defun agenda-query-parse-branches (text &key todo-p)
  (when (plusp (length (string-trim '(#\Space #\Tab) text)))
    (mapcar (lambda (branch)
              (agenda-query-parse-branch branch :todo-p todo-p))
            (agenda-query-split-top-level text #\|))))

(defun agenda-compile-tags-query (raw)
  "Compile RAW using Org 9.8 tag/property and optional TODO syntax."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) raw))
         (parts (agenda-query-split-top-level trimmed #\/)))
    (when (> (length parts) 2)
      (editor-error "Only one top-level TODO separator is supported"))
    (let* ((tag-text (first parts))
           (todo-text (or (second parts) ""))
           (todo-open-only-p
             (and (plusp (length todo-text))
                  (char= (char todo-text 0) #\!))))
      (when todo-open-only-p
        (setf todo-text (subseq todo-text 1)))
      (make-agenda-tags-query
       :raw trimmed
       :tag-branches (agenda-query-parse-branches tag-text)
       :todo-branches (agenda-query-parse-branches todo-text :todo-p t)
       :todo-open-only-p todo-open-only-p))))

(defun agenda-query-property-value (item name)
  (cond
    ((string= name "LEVEL")
     (and (agenda-item-level item)
          (write-to-string (agenda-item-level item))))
    ((string= name "CATEGORY") (agenda-item-category item))
    ((string= name "TODO") (agenda-item-keyword item))
    (t (cdr (assoc name (agenda-item-properties item) :test #'string=)))))

(defun agenda-query-compare (operator left right)
  (cond
    ((member operator '("=" "==") :test #'string=) (equal left right))
    ((member operator '("!=" "/=" "<>") :test #'string=) (not (equal left right)))
    ((string= operator "<") (if (numberp left) (< left right) (string< left right)))
    ((string= operator ">") (if (numberp left) (> left right) (string> left right)))
    ((string= operator "<=")
     (if (numberp left) (<= left right) (not (string> left right))))
    ((string= operator ">=")
     (if (numberp left) (>= left right) (not (string< left right))))
    (t nil)))

(defun agenda-query-property-match-p (term item)
  (let* ((value (agenda-query-property-value item (agenda-query-term-value term)))
         (present-p (not (null value)))
         (matched-p
           (and (or present-p (not (agenda-query-term-starred-p term)))
                (ecase (agenda-query-term-operand-kind term)
                  (:regexp
                   (let ((found-p
                           (not (null
                                 (ppcre:scan (agenda-query-term-scanner term)
                                             (or value ""))))))
                     (if (member (agenda-query-term-operator term)
                                 '("!=" "/=" "<>") :test #'string=)
                         (not found-p)
                         found-p)))
                  (:string
                   (agenda-query-compare
                    (agenda-query-term-operator term)
                    (or value "") (agenda-query-term-operand term)))
                  (:number
                   (agenda-query-compare
                    (agenda-query-term-operator term)
                    (agenda-query-number (or value "0"))
                    (agenda-query-number (agenda-query-term-operand term))))
                  (:time
                   (let ((left (and value (agenda-query-time-date value)))
                         (right
                           (agenda-query-time-date
                            (agenda-query-term-operand term))))
                     (and left right
                          (agenda-query-compare
                           (agenda-query-term-operator term) left right))))))))
    (if (agenda-query-term-negative-p term) (not matched-p) matched-p)))

(defun agenda-query-term-match-p (term item)
  (let ((matched-p
          (ecase (agenda-query-term-kind term)
            (:tag
             (not (null (member (agenda-query-term-value term)
                                (agenda-item-tags item) :test #'string=))))
            (:tag-regexp
             (some (lambda (tag)
                     (ppcre:scan (agenda-query-term-scanner term) tag))
                   (agenda-item-tags item)))
            (:todo
             (equal (agenda-item-keyword item) (agenda-query-term-value term)))
            (:todo-regexp
             (and (agenda-item-keyword item)
                  (ppcre:scan (agenda-query-term-scanner term)
                              (agenda-item-keyword item))))
            (:property (agenda-query-property-match-p term item)))))
    (if (and (not (eq (agenda-query-term-kind term) :property))
             (agenda-query-term-negative-p term))
        (not matched-p)
        matched-p)))

(defun agenda-query-branches-match-p (branches item)
  (or (null branches)
      (some (lambda (branch)
              (every (lambda (term) (agenda-query-term-match-p term item))
                     branch))
            branches)))

(defun agenda-tags-query-match-p (query item &key todo-any-p)
  (and (or (not todo-any-p) (agenda-item-keyword item))
       (or (not (agenda-tags-query-todo-open-only-p query))
           (open-keyword-p (agenda-item-keyword item)))
       (agenda-query-branches-match-p
        (agenda-tags-query-tag-branches query) item)
       (agenda-query-branches-match-p
        (agenda-tags-query-todo-branches query) item)))

(defun agenda-search-tokenize (text)
  "Return whitespace-delimited search snippets, preserving quotes/braces."
  (let ((index 0)
        (length (length text))
        tokens)
    (loop
      (loop :while (and (< index length)
                        (member (char text index) '(#\Space #\Tab #\Newline)))
            :do (incf index))
      (when (>= index length) (return (nreverse tokens)))
      (let ((start index)
            (quoted-p nil)
            (brace-depth 0)
            (escaped-p nil))
        (loop :while (< index length)
              :for character := (char text index)
              :do
                 (cond
                   (escaped-p (setf escaped-p nil))
                   ((char= character #\\) (setf escaped-p t))
                   ((char= character #\") (setf quoted-p (not quoted-p)))
                   (quoted-p)
                   ((char= character #\{) (incf brace-depth))
                   ((and (char= character #\}) (plusp brace-depth))
                    (decf brace-depth))
                   ((and (zerop brace-depth)
                         (member character '(#\Space #\Tab #\Newline)))
                    (return)))
              :do (incf index))
        (push (subseq text start index) tokens)))))

(defun agenda-search-literal-regexp (text full-words-p)
  (let ((quoted (ppcre:quote-meta-chars (string-downcase text))))
    (if full-words-p (format nil "\\b(?:~a)\\b" quoted) quoted)))

(defun agenda-search-snippet-scanner (token full-words-p)
  (let* ((length (length token))
         (regexp-p
           (and (> length 1)
                (char= (char token 0) #\{)
                (char= (char token (1- length)) #\})))
         (quoted-p
           (and (> length 1)
                (char= (char token 0) #\")
                (char= (char token (1- length)) #\")))
         (value (if (or regexp-p quoted-p)
                    (subseq token 1 (1- length))
                    token))
         (regexp (if regexp-p
                     (project-regexp-to-extended value)
                     (agenda-search-literal-regexp value full-words-p))))
    (handler-case
        (ppcre:create-scanner regexp :case-insensitive-mode t :multi-line-mode t)
      (error () (editor-error "Invalid Org search regexp: ~a" value)))))

(defun agenda-compile-search-query (raw &key todo-only-p)
  "Compile RAW using the configured Org phrase/Boolean search defaults."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Return) raw))
         (headline-only-p nil)
         (full-words-p nil))
    (when (zerop (length trimmed))
      (editor-error "Org agenda search requires a phrase or snippet"))
    (when (char= (char trimmed 0) #\*)
      (setf headline-only-p t trimmed (subseq trimmed 1)))
    (when (and (plusp (length trimmed)) (char= (char trimmed 0) #\!))
      (setf todo-only-p t trimmed (subseq trimmed 1)))
    (when (and (plusp (length trimmed)) (char= (char trimmed 0) #\:))
      (setf full-words-p t trimmed (subseq trimmed 1)))
    (when (zerop (length trimmed))
      (editor-error "Org agenda search requires a phrase or snippet"))
    (let* ((boolean-p
             (member (char trimmed 0) '(#\+ #\- #\{) :test #'char=))
           (tokens (agenda-search-tokenize trimmed))
           (required '())
           (forbidden '()))
      (if boolean-p
          (dolist (raw-token tokens)
            (let ((negative-p nil)
                  (token raw-token))
              (when (and (plusp (length token))
                         (member (char token 0) '(#\+ #\-) :test #'char=))
                (setf negative-p (char= (char token 0) #\-)
                      token (subseq token 1)))
              (when (zerop (length token))
                (editor-error "Incomplete Org search snippet"))
              (if negative-p
                  (push (agenda-search-snippet-scanner token full-words-p)
                        forbidden)
                  (push (agenda-search-snippet-scanner token full-words-p)
                        required))))
          (let ((regexp
                  (format nil "~{~a~^\\s+~}"
                          (mapcar (lambda (token)
                                    (ppcre:quote-meta-chars token))
                                  (uiop:split-string
                                   trimmed
                                   :separator '(#\Space #\Tab #\Newline))))))
            (push (ppcre:create-scanner regexp :case-insensitive-mode t
                                               :multi-line-mode t)
                  required)))
      (make-agenda-search-query
       :raw raw :headline-only-p headline-only-p :todo-only-p todo-only-p
       :required (nreverse required) :forbidden (nreverse forbidden)))))

(defun agenda-search-query-match-p (query item)
  (let ((text (if (agenda-search-query-headline-only-p query)
                  (or (agenda-item-heading item) "")
                  (or (agenda-item-search-text item)
                      (agenda-item-heading item) ""))))
    (and (or (not (agenda-search-query-todo-only-p query))
             (open-keyword-p (agenda-item-keyword item)))
         (every (lambda (scanner) (ppcre:scan scanner text))
                (agenda-search-query-required query))
         (every (lambda (scanner) (not (ppcre:scan scanner text)))
                (agenda-search-query-forbidden query)))))

(defun agenda-query-heading-items (items)
  "Return one stable source row for every parsed heading in ITEMS."
  (let ((table (make-hash-table :test #'equal))
        keys)
    (dolist (item items)
      (let ((key (list (agenda-item-file item) (agenda-item-line item))))
        (multiple-value-bind (previous present-p) (gethash key table)
          (unless present-p (push key keys))
          (when (or (not present-p)
                    (and (agenda-item-event-p previous)
                         (not (agenda-item-event-p item))))
            (setf (gethash key table) item)))))
    (loop :for key :in (nreverse keys)
          :collect (gethash key table))))

(defun agenda-query-display-item (item)
  "Return a source-backed undated row derived from ITEM."
  (let ((copy (copy-agenda-item item)))
    (setf (agenda-item-date copy) nil
          (agenda-item-kind copy) nil
          (agenda-item-event-p copy) nil
          (agenda-item-end-date copy) nil
          (agenda-item-repeater copy) nil
          (agenda-item-time copy) nil
          (agenda-item-end-time copy) nil
          (agenda-item-range-end-time copy) nil
          (agenda-item-occurrence-index copy) nil
          (agenda-item-occurrence-count copy) nil
          (agenda-item-display-date copy) nil
          (agenda-item-reminder-kind copy) nil
          (agenda-item-reminder-days copy) nil)
    copy))

(defun agenda-query-matching-items (items query &key todo-any-p)
  (loop :for item :in (agenda-query-heading-items items)
        :when (etypecase query
                (agenda-tags-query
                 (agenda-tags-query-match-p query item :todo-any-p todo-any-p))
                (agenda-search-query (agenda-search-query-match-p query item)))
          :collect (agenda-query-display-item item)))

(defun agenda-query-tag-completions (input tags)
  (let* ((boundary
           (position-if (lambda (character)
                          (member character '(#\+ #\- #\: #\& #\| #\/)
                                  :test #'char=))
                        input :from-end t))
         (start (if boundary (1+ boundary) 0))
         (prefix (subseq input 0 start))
         (fragment (subseq input start)))
    (mapcar (lambda (tag) (concatenate 'string prefix tag))
            (prescient-filter fragment tags :category :symbol))))

(defun agenda-read-tags-query ()
  (let ((tags (agenda-known-tags)))
    (prompt-for-string
     "Match: "
     :completion-function
     (lambda (input) (agenda-query-tag-completions input tags))
     :history-symbol 'lem-yath-agenda-tags-query-history)))

(defun agenda-read-search-query ()
  (prompt-for-string
   "Phrase or [+-]Word/{Regexp} ...: "
   :history-symbol 'lem-yath-agenda-search-query-history))

(defun agenda-query-multi-occur-run (buffers pattern source-window)
  "Run the existing source-backed Occur engine over agenda BUFFERS."
  (let ((scanner (buffer-list-occur-scanner pattern))
        (total-characters
          (reduce #'+ buffers :key #'completion-buffer-size :initial-value 0))
        (remaining-matches *buffer-list-occur-match-limit*)
        sources)
    (when (> total-characters *buffer-list-occur-total-character-limit*)
      (editor-error "Org files exceed ~d total search characters"
                    *buffer-list-occur-total-character-limit*))
    (dolist (buffer buffers)
      (let ((source
              (buffer-list-occur-source-data buffer scanner remaining-matches)))
        (decf remaining-matches (buffer-list-occur-source-match-count source))
        (push source sources)))
    (setf sources (nreverse sources))
    (multiple-value-bind (state text total-matches)
        (buffer-list-occur-render-output sources pattern 0)
      (if (zerop total-matches)
          (progn
            (buffer-list-occur-clear-empty-output sources)
            (message "No Org files match \"~a\"" pattern)
            nil)
          (multiple-value-bind (target-map targets)
              (buffer-list-occur-target-map sources)
            (let ((buffer
                    (buffer-list-occur-install-output
                     sources state text pattern 0 target-map targets))
                  (occur-window nil))
              (setf occur-window
                    (with-current-window source-window
                      (pop-to-buffer buffer :split-action :sensibly)))
              (switch-to-window occur-window)
              (message "Org files: ~d matches for \"~a\""
                       total-matches pattern)
              buffer))))))

(defun agenda-query-multi-occur ()
  (let ((source-window (current-window))
        (pattern (prompt-for-string "Org-files matching: ")))
    (multiple-value-bind (files failures) (agenda-org-files)
      (declare (ignore failures))
      (if (null files)
          (message "No configured Org agenda files exist")
          (agenda-query-multi-occur-run
           (mapcar #'find-file-buffer files) pattern source-window)))))
