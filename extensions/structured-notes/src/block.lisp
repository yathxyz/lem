(in-package #:lem-structured-notes)

(defun list-item-equivalent-p (left right)
  (and (list-item-p left)
       (list-item-p right)
       (eq (list-item-ordered-p left) (list-item-ordered-p right))
       (eql (list-item-ordinal left) (list-item-ordinal right))
       (eq (list-item-checkbox left) (list-item-checkbox right))
       (equalp (list-item-attributes left) (list-item-attributes right))
       (inline-nodes-equivalent-p (list-item-inlines left)
                                  (list-item-inlines right))))

(defun list-items-equivalent-p (left right)
  (and (= (length left) (length right))
       (every #'list-item-equivalent-p left right)))

(defun list-marker-spec (text)
  (let ((length (length text)))
    (cond
      ((and (>= length 2)
            (member (char text 0) '(#\- #\+ #\*))
            (char= (char text 1) #\Space))
       (values nil nil 2 t))
      (t
       (let ((digits-end (position-if-not #'digit-char-p text)))
         (if (and digits-end
                  (plusp digits-end)
                  (<= digits-end 9)
                  (< (1+ digits-end) length)
                  (member (char text digits-end) '(#\. #\)))
                  (char= (char text (1+ digits-end)) #\Space))
             (let ((ordinal (parse-integer text :end digits-end)))
               (if (plusp ordinal)
                   (values t ordinal (+ digits-end 2) t)
                   (values nil nil nil nil)))
             (values nil nil nil nil)))))))

(defun list-checkbox-spec (text content-start)
  (if (and (<= (+ content-start 3) (length text))
           (char= (char text content-start) #\[)
           (char= (char text (+ content-start 2)) #\]))
      (if (and (< (+ content-start 3) (length text))
               (char= (char text (+ content-start 3)) #\Space))
          (case (char text (1+ content-start))
            (#\Space (values :unchecked (+ content-start 4) t))
            ((#\x #\X) (values :checked (+ content-start 4) t))
            (otherwise (values nil nil nil)))
          (values nil nil nil))
      (values nil content-start t)))

(defun list-description-separator-p (text)
  (loop :for start := (search "::" text)
          :then (and start (search "::" text :start2 (+ start 2)))
        :while start
        :thereis (and (plusp start)
                      (< (+ start 2) (length text))
                      (inline-space-p (char text (1- start)))
                      (inline-space-p (char text (+ start 2))))))

(defun make-list-source-span
    (byte-prefixes source-id character-base byte-base start end)
  (make-source-span
   :source-id source-id
   :character-start (+ character-base start)
   :character-end (+ character-base end)
   :byte-start (+ byte-base (aref byte-prefixes start))
   :byte-end (+ byte-base (aref byte-prefixes end))))

(defun parse-flat-list-items
    (raw source-format inline-parser source-id character-base byte-base)
  (let ((lines (scan-source-lines raw))
        (byte-prefixes (source-byte-prefixes raw))
        (items nil)
        (ordered-p nil)
        (order-known-p nil))
    (unless lines
      (return-from parse-flat-list-items (values nil nil)))
    (dolist (line lines)
      (let ((text (source-line-text line)))
        (multiple-value-bind (item-ordered-p ordinal content-start marker-p)
            (list-marker-spec text)
          (unless marker-p
            (return-from parse-flat-list-items (values nil nil)))
          (when (and (eq source-format :org)
                     (not item-ordered-p)
                     (char= (char text 0) #\*))
            (return-from parse-flat-list-items (values nil nil)))
          (when (and order-known-p (not (eq ordered-p item-ordered-p)))
            (return-from parse-flat-list-items (values nil nil)))
          (setf ordered-p item-ordered-p order-known-p t)
          (multiple-value-bind (checkbox inline-start checkbox-p)
              (list-checkbox-spec text content-start)
            (unless checkbox-p
              (return-from parse-flat-list-items (values nil nil)))
            (let ((content (subseq text inline-start)))
              (when (or (list-description-separator-p content)
                        (and (eq source-format :org)
                             (>= (length content) 2)
                             (char= (char content 0) #\[)
                             (char= (char content 1) #\@)))
                (return-from parse-flat-list-items (values nil nil)))
              (let* ((line-start (source-line-character-start line))
                     (line-end (source-line-character-end line))
                     (inline-local-start (+ line-start inline-start))
                     (inline-raw (subseq raw inline-local-start line-end)))
                (multiple-value-bind (inlines valid-p)
                    (if (zerop (length content))
                        (values nil t)
                        (funcall inline-parser inline-raw
                                 :source-id source-id
                                 :character-base
                                 (+ character-base inline-local-start)
                                 :byte-base
                                 (+ byte-base
                                    (aref byte-prefixes inline-local-start))))
                  (unless valid-p
                    (return-from parse-flat-list-items (values nil nil)))
                  (push
                   (make-list-item
                    :source-format source-format
                    :raw (subseq raw line-start line-end)
                    :span (make-list-source-span
                           byte-prefixes source-id character-base byte-base
                           line-start line-end)
                    :ordered-p item-ordered-p :ordinal ordinal
                    :checkbox checkbox :inlines inlines)
                   items))))))))
    (values (nreverse items) t)))

(defun parse-org-list-items
    (raw &key (source-id "list") (character-base 0) (byte-base 0))
  "Parse flat, single-line Org list items supported by the native profile."
  (parse-flat-list-items raw :org #'parse-org-paragraph-inlines
                         source-id character-base byte-base))

(defun parse-commonmark-list-items
    (raw &key (source-id "list") (character-base 0) (byte-base 0))
  "Parse flat CommonMark/GFM list items supported by the native profile."
  (parse-flat-list-items raw :commonmark
                         #'parse-commonmark-paragraph-inlines
                         source-id character-base byte-base))

(defun render-commonmark-list-item (item)
  (when (list-item-attributes item)
    (model-error :unsupported-list-item-attributes item
                 "canonical CommonMark lists do not support item attributes"))
  (unless (or (null (list-item-inlines item))
              (inline-nodes-canonical-commonmark-p
               (list-item-inlines item)))
    (model-error :unsafe-list-item-inlines item
                 "list item inlines do not reparse with equal semantics"))
  (let ((marker (if (list-item-ordered-p item)
                    (format nil "~d." (list-item-ordinal item))
                    "-"))
        (checkbox
          (case (list-item-checkbox item)
            ((nil) "")
            (:unchecked "[ ] ")
            (:checked "[x] ")
            (:partial
             (model-error :unsupported-partial-checkbox item
                          "GFM has no portable partial checkbox state")))))
    (format nil "~a ~a~a" marker checkbox
            (render-commonmark-inlines (list-item-inlines item)))))

(defun render-commonmark-list-lines (items)
  (unless items
    (model-error :empty-list items "canonical list requires at least one item"))
  (let ((ordered-p (list-item-ordered-p (first items))))
    (unless (every (lambda (item)
                     (eq ordered-p (list-item-ordered-p item)))
                   items)
      (model-error :mixed-list-order items
                   "one list block cannot mix ordered and unordered items")))
  (mapcar #'render-commonmark-list-item items))

(defun list-items-canonical-commonmark-p (items)
  (handler-case
      (let ((rendered
              (with-output-to-string (stream)
                (dolist (line (render-commonmark-list-lines items))
                  (write-string line stream)
                  (write-char #\Newline stream)))))
        (multiple-value-bind (parsed valid-p)
            (parse-commonmark-list-items rendered)
          (and valid-p (list-items-equivalent-p items parsed))))
    (semantic-model-error () nil)))

(defun content-node-native-commonmark-list-p (content)
  (and (content-node-p content)
       (eq :list (content-node-kind content))
       (content-node-items content)
       (null (content-node-name content))
       (null (content-node-attributes content))
       (multiple-value-bind (parsed valid-p)
           (case (content-node-source-format content)
             (:org (parse-org-list-items (content-node-raw content)))
             (:commonmark
              (parse-commonmark-list-items (content-node-raw content)))
             (otherwise (values nil nil)))
         (and valid-p
              (list-items-equivalent-p parsed
                                       (content-node-items content))))))

(defun table-cell-equivalent-p (left right)
  (and (table-cell-p left)
       (table-cell-p right)
       (equalp (table-cell-attributes left) (table-cell-attributes right))
       (inline-nodes-equivalent-p (table-cell-inlines left)
                                  (table-cell-inlines right))))

(defun table-row-equivalent-p (left right)
  (and (table-row-p left)
       (table-row-p right)
       (equalp (table-row-attributes left) (table-row-attributes right))
       (= (length (table-row-cells left)) (length (table-row-cells right)))
       (every #'table-cell-equivalent-p
              (table-row-cells left) (table-row-cells right))))

(defun table-data-equivalent-p (left right)
  (and (table-data-p left)
       (table-data-p right)
       (equal (table-data-alignments left) (table-data-alignments right))
       (equalp (table-data-attributes left) (table-data-attributes right))
       (= (length (table-data-rows left)) (length (table-data-rows right)))
       (every #'table-row-equivalent-p
              (table-data-rows left) (table-data-rows right))))

(defun escaped-character-p (text index)
  (let ((slashes 0))
    (loop :for cursor :downfrom (1- index) :to 0
          :while (char= (char text cursor) #\\)
          :do (incf slashes))
    (oddp slashes)))

(defun table-cell-ranges (text)
  (unless (and (>= (length text) 3)
               (char= (char text 0) #\|)
               (char= (char text (1- (length text))) #\|))
    (return-from table-cell-ranges nil))
  (let ((pipes nil))
    (loop :for character :across text
          :for index :from 0
          :when (and (char= character #\|)
                     (not (escaped-character-p text index)))
            :do (push index pipes))
    (setf pipes (nreverse pipes))
    (unless (and (= 0 (first pipes))
                 (= (1- (length text)) (car (last pipes))))
      (return-from table-cell-ranges nil))
    (loop :for (left right) :on pipes
          :while right
          :collect
          (let ((start (1+ left))
                (end right))
            (loop :while (and (< start end)
                              (inline-space-p (char text start)))
                  :do (incf start))
            (loop :while (and (< start end)
                              (inline-space-p (char text (1- end))))
                  :do (decf end))
            (cons start end)))))

(defun org-table-hline-column-count (text)
  (unless (and (>= (length text) 3)
               (char= (char text 0) #\|)
               (char= (char text (1- (length text))) #\|))
    (return-from org-table-hline-column-count nil))
  (let ((start 1)
        (end (1- (length text)))
        (count 0))
    (loop
      (let ((separator (position #\+ text :start start :end end)))
        (let ((segment-end (or separator end)))
          (unless (and (< start segment-end)
                       (every (lambda (character) (char= character #\-))
                              (subseq text start segment-end)))
            (return-from org-table-hline-column-count nil))
          (incf count))
        (unless separator (return count))
        (setf start (1+ separator))))))

(defun org-table-hline-p (text)
  (not (null (org-table-hline-column-count text))))

(defun org-special-table-row-p (text)
  (let ((ranges (table-cell-ranges text)))
    (and ranges
         (member (subseq text (car (first ranges)) (cdr (first ranges)))
                 '("#" "*" "/") :test #'string=))))

(defun gfm-alignment-cell (text)
  (let* ((length (length text))
         (left-p (and (plusp length) (char= (char text 0) #\:)))
         (right-p (and (plusp length)
                       (char= (char text (1- length)) #\:)))
         (start (if left-p 1 0))
         (end (if right-p (1- length) length)))
    (when (and (>= (- end start) 3)
               (every (lambda (character) (char= character #\-))
                      (subseq text start end)))
      (cond
        ((and left-p right-p) :center)
        (left-p :left)
        (right-p :right)
        (t :default)))))

(defun parse-gfm-alignment-row (text)
  (let ((ranges (table-cell-ranges text)))
    (when ranges
      (let ((alignments
              (mapcar (lambda (range)
                        (gfm-alignment-cell
                         (subseq text (car range) (cdr range))))
                      ranges)))
        (when (every #'identity alignments) alignments)))))

(defun table-string-prefix-p (prefix text)
  (and (<= (length prefix) (length text))
       (string-equal prefix text :end2 (length prefix))))

(defun parse-table-row
    (raw line source-format inline-parser source-id character-base byte-base
     byte-prefixes)
  (let* ((text (source-line-text line))
         (ranges (table-cell-ranges text))
         (line-start (source-line-character-start line))
         (line-end (source-line-character-end line))
         (cells nil))
    (unless ranges (return-from parse-table-row (values nil nil)))
    (dolist (range ranges)
      (let* ((start (+ line-start (car range)))
             (end (+ line-start (cdr range)))
             (cell-raw (subseq raw start end))
             (inlines nil))
        (when (plusp (length cell-raw))
          (multiple-value-bind (parsed valid-p)
              (funcall inline-parser cell-raw
                       :source-id source-id
                       :character-base (+ character-base start)
                       :byte-base (+ byte-base (aref byte-prefixes start)))
            (unless valid-p
              (return-from parse-table-row (values nil nil)))
            (setf inlines parsed)))
        (push
         (make-table-cell
          :source-format source-format :raw cell-raw :inlines inlines
          :span (make-list-source-span
                 byte-prefixes source-id character-base byte-base start end))
         cells)))
    (values
     (make-table-row
      :source-format source-format
      :raw (subseq raw line-start line-end)
      :span (make-list-source-span
             byte-prefixes source-id character-base byte-base
             line-start line-end)
      :cells (nreverse cells))
     t)))

(defun parse-table-data
    (raw source-format inline-parser source-id character-base byte-base)
  (let* ((lines (scan-source-lines raw))
         (byte-prefixes (source-byte-prefixes raw)))
    (unless (>= (length lines) 2)
      (return-from parse-table-data (values nil nil)))
    (let ((alignments
            (if (eq source-format :org)
                (and (org-table-hline-p
                      (source-line-text (second lines)))
                     (not (org-special-table-row-p
                           (source-line-text (first lines))))
                     (let ((header-ranges
                             (table-cell-ranges
                              (source-line-text (first lines)))))
                       (and header-ranges
                            (= (length header-ranges)
                               (org-table-hline-column-count
                                (source-line-text (second lines))))
                            (make-list (length header-ranges)
                                       :initial-element :default))))
                (parse-gfm-alignment-row
                 (source-line-text (second lines))))))
      (unless alignments
        (return-from parse-table-data (values nil nil)))
      (when (and (eq source-format :org)
                 (or (some (lambda (line)
                             (let ((text (source-line-text line)))
                               (or (org-table-hline-p text)
                                   (org-special-table-row-p text)
                                   (table-string-prefix-p
                                    "#+TBLFM:"
                                    (string-left-trim '(#\Space #\Tab)
                                                      text)))))
                           (cddr lines))))
        (return-from parse-table-data (values nil nil)))
      (let ((rows nil))
        (dolist (line (cons (first lines) (cddr lines)))
          (multiple-value-bind (row valid-p)
              (parse-table-row raw line source-format inline-parser source-id
                               character-base byte-base byte-prefixes)
            (unless (and valid-p
                         (= (length alignments)
                            (length (table-row-cells row))))
              (return-from parse-table-data (values nil nil)))
            (push row rows)))
        (values (make-table-data :alignments alignments
                                 :rows (nreverse rows))
                t)))))

(defun parse-org-table-data
    (raw &key (source-id "table") (character-base 0) (byte-base 0))
  (parse-table-data raw :org #'parse-org-paragraph-inlines
                    source-id character-base byte-base))

(defun parse-gfm-table-data
    (raw &key (source-id "table") (character-base 0) (byte-base 0))
  (parse-table-data raw :commonmark #'parse-commonmark-paragraph-inlines
                    source-id character-base byte-base))

(defun unescaped-pipe-p (text)
  (loop :for character :across text
        :for index :from 0
        :thereis (and (char= character #\|)
                      (not (escaped-character-p text index)))))

(defun render-gfm-table-cell (cell)
  (when (table-cell-attributes cell)
    (model-error :unsupported-table-cell-attributes cell
                 "GFM table cells do not support attributes"))
  (let ((rendered (render-commonmark-inlines (table-cell-inlines cell))))
    (unless (or (null (table-cell-inlines cell))
                (inline-nodes-canonical-commonmark-p
                 (table-cell-inlines cell)))
      (model-error :unsafe-table-cell-inlines cell
                   "table cell inlines do not reparse canonically"))
    (when (unescaped-pipe-p rendered)
      (model-error :unsafe-table-cell-pipe cell
                   "table cell rendering contains an unescaped pipe"))
    rendered))

(defun render-gfm-table-row (row)
  (when (table-row-attributes row)
    (model-error :unsupported-table-row-attributes row
                 "GFM table rows do not support attributes"))
  (format nil "| ~{~a~^ | ~} |"
          (mapcar #'render-gfm-table-cell (table-row-cells row))))

(defun render-gfm-alignment (alignment)
  (ecase alignment
    (:default "---")
    (:left ":---")
    (:center ":---:")
    (:right "---:")))

(defun render-gfm-table-lines (table)
  (when (table-data-attributes table)
    (model-error :unsupported-table-attributes table
                 "GFM table rendering does not support attributes"))
  (let ((rows (table-data-rows table)))
    (cons (render-gfm-table-row (first rows))
          (cons (format nil "| ~{~a~^ | ~} |"
                        (mapcar #'render-gfm-alignment
                                (table-data-alignments table)))
                (mapcar #'render-gfm-table-row (rest rows))))))

(defun table-data-canonical-gfm-p (table)
  (handler-case
      (let ((rendered
              (with-output-to-string (stream)
                (dolist (line (render-gfm-table-lines table))
                  (write-string line stream)
                  (write-char #\Newline stream)))))
        (multiple-value-bind (parsed valid-p) (parse-gfm-table-data rendered)
          (and valid-p (table-data-equivalent-p table parsed))))
    (semantic-model-error () nil)))

(defun content-node-native-gfm-table-p (content)
  (and (content-node-p content)
       (eq :table (content-node-kind content))
       (content-node-table content)
       (null (content-node-name content))
       (null (content-node-attributes content))
       (multiple-value-bind (parsed valid-p)
           (case (content-node-source-format content)
             (:org (parse-org-table-data (content-node-raw content)))
             (:commonmark (parse-gfm-table-data (content-node-raw content)))
             (otherwise (values nil nil)))
         (and valid-p
              (table-data-equivalent-p parsed
                                       (content-node-table content))))))

(defun code-block-data-equivalent-p (left right)
  (and (code-block-data-p left)
       (code-block-data-p right)
       (equal (code-block-data-language left)
              (code-block-data-language right))
       (string= (code-block-data-code left) (code-block-data-code right))
       (equalp (code-block-data-attributes left)
               (code-block-data-attributes right))))

(defun portable-code-language-p (language)
  (or (null language)
      (and (plusp (length language))
           (every (lambda (character)
                    (or (alphanumericp character)
                        (member character '(#\+ #\- #\_ #\. #\#))))
                  language))))

(defun normalized-code-from-lines (lines)
  (with-output-to-string (stream)
    (dolist (line lines)
      (write-string (source-line-text line) stream)
      (write-char #\Newline stream))))

(defun code-block-source-span
    (raw source-id character-base byte-base)
  (let ((prefixes (source-byte-prefixes raw)))
    (make-list-source-span prefixes source-id character-base byte-base
                           0 (length raw))))

(defun parse-org-source-block-data
    (raw &key (source-id "code") (character-base 0) (byte-base 0))
  "Parse a closed Org src block without switches or Babel header arguments."
  (let ((lines (scan-source-lines raw))
        (prefix "#+begin_src"))
    (unless (>= (length lines) 2)
      (return-from parse-org-source-block-data (values nil nil)))
    (let* ((opening (source-line-text (first lines)))
           (closing (source-line-text (car (last lines))))
           (language
             (cond
               ((string-equal opening prefix) nil)
               ((and (> (length opening) (length prefix))
                     (string-equal prefix opening :end2 (length prefix))
                     (member (char opening (length prefix))
                             '(#\Space #\Tab)))
                (let ((tail (string-trim '(#\Space #\Tab)
                                         (subseq opening (length prefix)))))
                  (and (portable-code-language-p tail) tail)))
               (t nil))))
      (unless (and (or (string-equal opening prefix) language)
                   (string-equal closing "#+end_src"))
        (return-from parse-org-source-block-data (values nil nil)))
      (let ((code (normalized-code-from-lines
                   (subseq lines 1 (1- (length lines))))))
        (values
         (make-code-block-data
          :source-format :org :raw raw :language language :code code
          :span (code-block-source-span raw source-id character-base byte-base))
         t)))))

(defun portable-fence-opening-spec (text)
  (when (and (>= (length text) 3)
             (member (char text 0) '(#\` #\~)))
    (let* ((marker (char text 0))
           (width (or (position-if-not
                       (lambda (character) (char= character marker)) text)
                      (length text)))
           (info (string-trim '(#\Space #\Tab) (subseq text width))))
      (when (and (>= width 3)
                 (or (zerop (length info))
                     (portable-code-language-p info))
                 (or (char= marker #\~) (not (find #\` info))))
        (values marker width
                (and (plusp (length info)) info))))))

(defun portable-fence-closing-p (text marker width)
  (let ((run (or (position-if-not
                  (lambda (character) (char= character marker)) text)
                 (length text))))
    (and (>= run width)
         (every #'whitespace-character-p (subseq text run)))))

(defun parse-commonmark-fenced-code-data
    (raw &key (source-id "code") (character-base 0) (byte-base 0))
  "Parse the canonical fenced-code subset used by LSM/1."
  (let ((lines (scan-source-lines raw)))
    (unless (>= (length lines) 2)
      (return-from parse-commonmark-fenced-code-data (values nil nil)))
    (multiple-value-bind (marker width language)
        (portable-fence-opening-spec (source-line-text (first lines)))
      (unless marker
        (return-from parse-commonmark-fenced-code-data (values nil nil)))
      (unless (portable-fence-closing-p
               (source-line-text (car (last lines))) marker width)
        (return-from parse-commonmark-fenced-code-data (values nil nil)))
      (when (some (lambda (line)
                    (portable-fence-closing-p
                     (source-line-text line) marker width))
                  (subseq lines 1 (1- (length lines))))
        (return-from parse-commonmark-fenced-code-data (values nil nil)))
      (values
       (make-code-block-data
        :source-format :commonmark :raw raw :language language
        :code (normalized-code-from-lines
               (subseq lines 1 (1- (length lines))))
        :span (code-block-source-span raw source-id character-base byte-base))
       t))))

(defun leading-backtick-run (text)
  (or (position-if-not (lambda (character) (char= character #\`)) text)
      (length text)))

(defun render-commonmark-fenced-code-lines (code-block)
  (when (code-block-data-attributes code-block)
    (model-error :unsupported-code-block-attributes code-block
                 "canonical fenced code does not support block attributes"))
  (unless (portable-code-language-p (code-block-data-language code-block))
    (model-error :unsafe-code-language (code-block-data-language code-block)
                 "code language is not safe in a canonical fence info string"))
  (let* ((body-lines (scan-source-lines (code-block-data-code code-block)))
         (width (max 3
                     (1+ (or (loop :for line :in body-lines
                                   :maximize
                                   (leading-backtick-run
                                    (source-line-text line)))
                             0))))
         (fence (make-string width :initial-element #\`))
         (opening (if (code-block-data-language code-block)
                      (format nil "~a~a" fence
                              (code-block-data-language code-block))
                      fence)))
    (append (list opening)
            (mapcar #'source-line-text body-lines)
            (list fence))))

(defun myst-code-cell-opening-spec (text)
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) text))
         (width (or (position-if-not (lambda (character)
                                       (char= character #\:))
                                     trimmed)
                    (length trimmed))))
    (when (and (>= width 3)
               (< width (length trimmed))
               (char= (char trimmed width) #\{))
      (let ((close (position #\} trimmed :start (1+ width))))
        (when (and close
                   (string= "code-cell"
                            (string-downcase
                             (string-trim '(#\Space #\Tab)
                                          (subseq trimmed (1+ width) close)))))
          (let ((language
                  (string-trim '(#\Space #\Tab)
                               (subseq trimmed (1+ close)))))
            (when (portable-code-language-p language)
              (values width language))))))))

(defun myst-code-cell-closing-p (text width)
  (let* ((trimmed (string-trim '(#\Space #\Tab) text))
         (run (or (position-if-not (lambda (character)
                                     (char= character #\:))
                                   trimmed)
                  (length trimmed))))
    (and (>= run width) (= run (length trimmed)))))

(defun myst-code-cell-option (text)
  (when (and (> (length text) 2) (char= (char text 0) #\:))
    (let ((close (position #\: text :start 1)))
      (when close
        (let ((name (string-downcase (subseq text 1 close)))
              (value (string-trim '(#\Space #\Tab)
                                  (subseq text (1+ close)))))
          (when (and (plusp (length name))
                     (alpha-char-p (char name 0))
                     (every (lambda (character)
                              (or (alphanumericp character)
                                  (member character '(#\- #\_))))
                            name))
            (values name value)))))))

(defun parse-myst-code-cell-data
    (raw &key (source-id "code-cell") (character-base 0) (byte-base 0))
  "Parse one standard root-level MyST code-cell directive into typed code."
  (let ((lines (scan-source-lines raw)))
    (unless (>= (length lines) 2)
      (return-from parse-myst-code-cell-data (values nil nil)))
    (multiple-value-bind (width language)
        (myst-code-cell-opening-spec (source-line-text (first lines)))
      (unless (and width
                   (myst-code-cell-closing-p
                    (source-line-text (car (last lines))) width))
        (return-from parse-myst-code-cell-data (values nil nil)))
      (let ((index 1)
            (end (1- (length lines)))
            (attributes nil))
        (loop :while (< index end)
              :for text := (source-line-text (nth index lines))
              :do
                 (cond
                   ((every #'whitespace-character-p text)
                    (incf index)
                    (return))
                   (t
                    (multiple-value-bind (name value)
                        (myst-code-cell-option text)
                      (unless name (return))
                      (when (assoc name attributes :test #'string=)
                        (model-error :duplicate-code-cell-option name
                                     "MyST code-cell options must be unique"))
                      (push (cons name value) attributes)
                      (incf index)))))
        (values
         (make-code-block-data
          :source-format :myst :raw raw :language language
          :code (normalized-code-from-lines (subseq lines index end))
          :attributes (nreverse attributes)
          :span (code-block-source-span
                 raw source-id character-base byte-base))
         t)))))

(defun leading-colon-run (text)
  (or (position-if-not (lambda (character) (char= character #\:)) text)
      (length text)))

(defun render-myst-code-cell-lines (code-block)
  "Render typed executable code as the pinned MyST code-cell directive."
  (unless (eq :myst (code-block-data-source-format code-block))
    (model-error :invalid-code-cell-format code-block
                 "MyST code-cell rendering requires MyST source format"))
  (unless (portable-code-language-p (code-block-data-language code-block))
    (model-error :unsafe-code-language (code-block-data-language code-block)
                 "code-cell language is not a portable token"))
  (dolist (attribute (code-block-data-attributes code-block))
    (unless (and (stringp (car attribute))
                 (stringp (cdr attribute))
                 (plusp (length (car attribute)))
                 (alpha-char-p (char (car attribute) 0))
                 (every (lambda (character)
                          (or (alphanumericp character)
                              (member character '(#\- #\_))))
                        (car attribute))
                 (not (find-if (lambda (character)
                                 (member character '(#\Newline #\Return)))
                               (cdr attribute))))
      (model-error :invalid-code-cell-option attribute
                   "code-cell options require single-line string values")))
  (let* ((body-lines (scan-source-lines (code-block-data-code code-block)))
         (width (max 3
                     (1+ (or (loop :for line :in body-lines
                                   :maximize
                                   (leading-colon-run
                                    (source-line-text line)))
                             0))))
         (fence (make-string width :initial-element #\:)))
    (append
     (list (format nil "~a{code-cell} ~a" fence
                   (code-block-data-language code-block)))
     (mapcar (lambda (attribute)
               (format nil ":~a:~@[ ~a~]" (car attribute)
                       (and (plusp (length (cdr attribute)))
                            (cdr attribute))))
             (code-block-data-attributes code-block))
     (list "")
     (mapcar #'source-line-text body-lines)
     (list fence))))

(defun code-block-data-canonical-commonmark-p (code-block)
  (handler-case
      (let ((rendered
              (with-output-to-string (stream)
                (dolist (line
                         (render-commonmark-fenced-code-lines code-block))
                  (write-string line stream)
                  (write-char #\Newline stream)))))
        (multiple-value-bind (parsed valid-p)
            (parse-commonmark-fenced-code-data rendered)
          (and valid-p
               (code-block-data-equivalent-p code-block parsed))))
    (semantic-model-error () nil)))

(defun content-node-native-fenced-code-p (content)
  (and (content-node-p content)
       (eq :source-block (content-node-kind content))
       (content-node-code-block content)
       (null (content-node-name content))
       (null (content-node-attributes content))
       (multiple-value-bind (parsed valid-p)
           (case (content-node-source-format content)
             (:org (parse-org-source-block-data (content-node-raw content)))
             (:commonmark
              (parse-commonmark-fenced-code-data (content-node-raw content)))
             (otherwise (values nil nil)))
         (and valid-p
              (code-block-data-equivalent-p
               parsed (content-node-code-block content))))))

(defun content-node-native-myst-code-cell-p (content)
  (and (content-node-p content)
       (eq :source-block (content-node-kind content))
       (eq :myst (content-node-source-format content))
       (string= "code-cell" (or (content-node-name content) ""))
       (content-node-code-block content)
       (multiple-value-bind (parsed valid-p)
           (parse-myst-code-cell-data (content-node-raw content))
         (and valid-p
              (code-block-data-equivalent-p
               parsed (content-node-code-block content))))))

(defun content-node-native-code-block-p (content)
  (or (content-node-native-fenced-code-p content)
      (content-node-native-myst-code-cell-p content)))

(defun org-inner-block-prefix-p (text)
  "Recognize Org block candidates that must not be flattened into inline text."
  (let ((length (length text)))
    (or (and (plusp length)
             (member (char text 0) '(#\| #\:)))
        (and (>= length 2)
             (or (and (member (char text 0) '(#\# #\- #\+ #\*))
                      (member (char text 1) '(#\Space #\Tab)))
                 (and (char= (char text 0) #\#)
                      (char= (char text 1) #\+))))
        (let ((stars (position-if-not
                      (lambda (character) (char= character #\*)) text)))
          (and stars (plusp stars) (< stars length)
               (member (char text stars) '(#\Space #\Tab))))
        (let ((digits (position-if-not #'digit-char-p text)))
          (and digits (plusp digits) (< (1+ digits) length)
               (member (char text digits) '(#\. #\)))
               (member (char text (1+ digits)) '(#\Space #\Tab)))))))

(defun parse-org-quote-inlines
    (raw &key (source-id "quote") (character-base 0) (byte-base 0))
  "Parse a closed, parameter-free Org quote block containing one paragraph."
  (let ((lines (scan-source-lines raw)))
    (unless (= 3 (length lines))
      (return-from parse-org-quote-inlines (values nil nil)))
    (unless (and (string-equal "#+begin_quote"
                               (source-line-text (first lines)))
                 (string-equal "#+end_quote"
                               (source-line-text (third lines))))
      (return-from parse-org-quote-inlines (values nil nil)))
    (let* ((body (second lines))
           (start (source-line-character-start body))
           (end (source-line-character-end body))
           (byte-prefixes (source-byte-prefixes raw)))
      (when (org-inner-block-prefix-p (source-line-text body))
        (return-from parse-org-quote-inlines (values nil nil)))
      (parse-org-paragraph-inlines
       (subseq raw start end)
       :source-id source-id
       :character-base (+ character-base start)
       :byte-base (+ byte-base (aref byte-prefixes start))))))

(defun parse-commonmark-quote-inlines
    (raw &key (source-id "quote") (character-base 0) (byte-base 0))
  "Parse one canonical CommonMark blockquote line."
  (let ((line (source-single-line-text raw)))
    (unless (and line (> (length line) 2)
                 (char= (char line 0) #\>)
                 (char= (char line 1) #\Space))
      (return-from parse-commonmark-quote-inlines (values nil nil)))
    (parse-commonmark-paragraph-inlines
     (subseq line 2)
     :source-id source-id
     :character-base (+ character-base 2)
     :byte-base (+ byte-base 2))))

(defun render-commonmark-quote-line (inlines)
  (format nil "> ~a" (render-commonmark-inlines inlines)))

(defun quote-inlines-canonical-commonmark-p (inlines)
  (handler-case
      (let ((rendered
              (format nil "~a~%" (render-commonmark-quote-line inlines))))
        (multiple-value-bind (parsed valid-p)
            (parse-commonmark-quote-inlines rendered)
          (and valid-p (inline-nodes-equivalent-p inlines parsed))))
    (semantic-model-error () nil)))

(defun content-node-native-commonmark-quote-p (content)
  (and (content-node-p content)
       (eq :quote (content-node-kind content))
       (content-node-inlines content)
       (null (content-node-name content))
       (null (content-node-attributes content))
       (multiple-value-bind (parsed valid-p)
           (case (content-node-source-format content)
             (:org (parse-org-quote-inlines (content-node-raw content)))
             (:commonmark
              (parse-commonmark-quote-inlines (content-node-raw content)))
             (otherwise (values nil nil)))
         (and valid-p
              (inline-nodes-equivalent-p
               parsed (content-node-inlines content))))))

(defun portable-drawer-name-p (name)
  (and (plusp (length name))
       (every (lambda (character)
                (or (alphanumericp character)
                    (member character '(#\- #\_))))
              name)
       (not (member (string-upcase name)
                    '("END" "PROPERTIES" "LOGBOOK") :test #'string=))))

(defun parse-org-drawer-inlines
    (raw &key (source-id "drawer") (character-base 0) (byte-base 0))
  "Parse a closed one-line generic Org drawer in the portable profile."
  (let ((lines (scan-source-lines raw)))
    (unless (= 3 (length lines))
      (return-from parse-org-drawer-inlines (values nil nil nil)))
    (let* ((opening (source-line-text (first lines)))
           (opening-length (length opening))
           (name (and (> opening-length 2)
                      (char= (char opening 0) #\:)
                      (char= (char opening (1- opening-length)) #\:)
                      (subseq opening 1 (1- opening-length)))))
      (unless (and name (portable-drawer-name-p name)
                   (string-equal ":END:"
                                 (source-line-text (third lines))))
        (return-from parse-org-drawer-inlines (values nil nil nil)))
      (let* ((body (second lines))
             (start (source-line-character-start body))
             (end (source-line-character-end body))
             (byte-prefixes (source-byte-prefixes raw)))
        (when (org-inner-block-prefix-p (source-line-text body))
          (return-from parse-org-drawer-inlines (values nil nil nil)))
        (multiple-value-bind (inlines valid-p)
            (parse-org-paragraph-inlines
             (subseq raw start end)
             :source-id source-id
             :character-base (+ character-base start)
             :byte-base (+ byte-base (aref byte-prefixes start)))
          (if valid-p
              (values name inlines t)
              (values nil nil nil)))))))

(defun drawer-field-value (prefix text)
  (and (> (length text) (length prefix))
       (string= prefix text :end2 (length prefix))
       (subseq text (length prefix))))

(defun parse-myst-drawer-inlines
    (raw &key (source-id "drawer") (character-base 0) (byte-base 0))
  "Parse the canonical lem-drawer MyST directive emitted by LSM/1."
  (let ((lines (scan-source-lines raw)))
    (unless (= 4 (length lines))
      (return-from parse-myst-drawer-inlines (values nil nil nil)))
    (let ((name (drawer-field-value
                 "name: " (source-line-text (second lines))))
          (content (drawer-field-value
                    "content: " (source-line-text (third lines)))))
      (unless (and (string= ":::{lem-drawer}"
                            (source-line-text (first lines)))
                   (string= ":::" (source-line-text (fourth lines)))
                   name (portable-drawer-name-p name) content)
        (return-from parse-myst-drawer-inlines (values nil nil nil)))
      (let* ((content-line (third lines))
             (prefix-length (length "content: "))
             (local-start (+ (source-line-character-start content-line)
                             prefix-length))
             (byte-prefixes (source-byte-prefixes raw)))
        (multiple-value-bind (inlines valid-p)
            (parse-commonmark-paragraph-inlines
             content :source-id source-id
             :character-base (+ character-base local-start)
             :byte-base (+ byte-base (aref byte-prefixes local-start)))
          (if valid-p
              (values name inlines t)
              (values nil nil nil)))))))

(defun render-myst-drawer-lines (name inlines)
  (unless (portable-drawer-name-p name)
    (model-error :unsafe-drawer-name name
                 "drawer name is outside the portable directive profile"))
  (list ":::{lem-drawer}"
        (format nil "name: ~a" name)
        (format nil "content: ~a" (render-commonmark-inlines inlines))
        ":::"))

(defun drawer-inlines-canonical-myst-p (name inlines)
  (handler-case
      (let ((rendered
              (format nil "~{~a~%~}" (render-myst-drawer-lines name inlines))))
        (multiple-value-bind (parsed-name parsed-inlines valid-p)
            (parse-myst-drawer-inlines rendered)
          (and valid-p (string= name parsed-name)
               (inline-nodes-equivalent-p inlines parsed-inlines))))
    (semantic-model-error () nil)))

(defun content-node-native-myst-drawer-p (content)
  (and (content-node-p content)
       (eq :drawer (content-node-kind content))
       (content-node-name content)
       (content-node-inlines content)
       (null (content-node-attributes content))
       (multiple-value-bind (parsed-name parsed-inlines valid-p)
           (case (content-node-source-format content)
             (:org (parse-org-drawer-inlines (content-node-raw content)))
             (:myst (parse-myst-drawer-inlines (content-node-raw content)))
             (otherwise (values nil nil nil)))
         (and valid-p
              (string= parsed-name (content-node-name content))
              (inline-nodes-equivalent-p
               parsed-inlines (content-node-inlines content))))))
