(in-package #:lem-structured-notes)

(defclass lsm-provider (source-provider) ())

(defparameter +lsm-frontmatter-extension-namespace+
  "urn:lem:lsm:frontmatter:yaml")

(defparameter +lsm-frontmatter-extension-character-limit+ 65536)
(defparameter +lsm-source-max-characters+ (* 1024 1024))
(defparameter +lsm-source-max-lines+ 100000)
(defparameter +lsm-directive-max-depth+ 256)

(defparameter +lsm-forbidden-frontmatter-keys+
  '("password" "passwd" "secret" "token" "accesstoken" "refreshtoken"
    "credential" "credentials" "auth" "authorization" "cookie" "apikey"
    "accesskey" "privatekey"))

(defun lsm-forbidden-frontmatter-key-p (key)
  (or (member key +lsm-forbidden-frontmatter-keys+ :test #'string=)
      (some (lambda (fragment) (search fragment key))
            '("password" "secret" "token" "credential"
              "authorization" "cookie" "accesskey" "privatekey"))))

(defmethod source-provider-format ((provider lsm-provider))
  (declare (ignore provider))
  :lsm)

(defmethod source-provider-profile ((provider lsm-provider))
  (declare (ignore provider))
  "lsm/1")

(defmethod source-content-fingerprint ((provider lsm-provider) source)
  (declare (ignore provider))
  ;; Exact source comparison is collision-free. A later bounded file adapter
  ;; can replace this in-memory representation with a cryptographic digest.
  (require-non-empty-string source :invalid-lsm-source "LSM source")
  source)

(defmethod source-metadata-fingerprint ((provider lsm-provider) source)
  (declare (ignore provider source))
  "inline-source/no-external-metadata")

(defstruct (parsed-heading
            (:constructor make-parsed-heading
                (start end level title span)))
  start end level title span id parent-id child-ids task-fields task-raw
  node-fields node-raw event-fields event-raw properties-fields properties-raw
  calendar-binding-fields calendar-binding-raw body-nodes)

(defun whitespace-character-p (character)
  (member character '(#\Space #\Tab #\Return #\Newline)))

(defun whitespace-string-p (string)
  (every #'whitespace-character-p string))

(defun trim-source-space (string)
  (string-trim '(#\Space #\Tab #\Return) string))

(defun strip-scalar-quotes (string)
  (let* ((trimmed (trim-source-space string))
         (length (length trimmed)))
    (cond
      ((and (>= length 2)
            (char= (char trimmed 0) #\")
            (char= (char trimmed (1- length)) #\"))
       (with-output-to-string (stream)
         (loop :with index := 1
               :while (< index (1- length))
               :for character := (char trimmed index)
               :do
                  (if (not (char= character #\\))
                      (progn (write-char character stream) (incf index))
                      (progn
                        (incf index)
                        (when (>= index (1- length))
                          (model-error :invalid-scalar-escape trimmed
                                       "quoted scalar ends with an escape"))
                        (let ((escape (char trimmed index)))
                          (case escape
                            (#\n (write-char #\Newline stream))
                            (#\r (write-char #\Return stream))
                            (#\t (write-char #\Tab stream))
                            (#\\ (write-char #\\ stream))
                            (#\" (write-char #\" stream))
                            (#\u
                             (let ((hex-end (+ index 5)))
                               (when (> hex-end (1- length))
                                 (model-error :invalid-unicode-escape trimmed
                                              "Unicode escape needs four hex digits"))
                               (let* ((digits (subseq trimmed (1+ index)
                                                      hex-end))
                                      (code
                                        (ignore-errors
                                          (parse-integer digits :radix 16
                                                        :junk-allowed nil)))
                                      (decoded (and code (code-char code))))
                                 (unless decoded
                                   (model-error :invalid-unicode-escape digits
                                                "invalid Unicode escape"))
                                 (write-char decoded stream)
                                 (incf index 4))))
                            (otherwise
                             (model-error :invalid-scalar-escape escape
                                          "unsupported quoted scalar escape"))))
                        (incf index))))))
      ((and (>= length 2)
            (char= (char trimmed 0) #\')
            (char= (char trimmed (1- length)) #\'))
       (subseq trimmed 1 (1- length)))
      (t trimmed))))

(defun line-indentation (line)
  (or (position-if-not (lambda (character)
                         (member character '(#\Space #\Tab)))
                       line)
      (length line)))

(defun simple-field (line &key preserve-key-case-p)
  (let ((colon (position #\: line)))
    (when colon
      (let ((key (funcall (if preserve-key-case-p
                              #'identity
                              #'string-downcase)
                          (trim-source-space (subseq line 0 colon))))
            (value (trim-source-space (subseq line (1+ colon)))))
        (when (plusp (length key))
          (values key value))))))

(defun frontmatter-end-index (lines)
  (when (and lines (string= "---" (source-line-text (first lines))))
    (loop :for line :in (rest lines)
          :for index :from 1
          :when (string= "---" (source-line-text line))
            :return index)))

(defun parse-lsm-frontmatter (lines end-index)
  "Return the LSM profile and document ID from the top-level lem mapping."
  (let ((inside-lem nil)
        (lem-indent nil)
        (lem-count 0)
        (profile nil)
        (document-id nil))
    (loop :for line :in (subseq lines 1 end-index)
          :for text := (source-line-text line)
          :for trimmed := (trim-source-space text)
          :for indentation := (line-indentation text)
          :do (cond
                ((zerop (length trimmed)))
                ((and (null inside-lem)
                      (zerop indentation)
                      (string= "lem:" (string-downcase trimmed)))
                 (incf lem-count)
                 (when (> lem-count 1)
                   (model-error :duplicate-lsm-frontmatter-key "lem"
                                "LSM frontmatter contains duplicate top-level lem mappings"))
                 (setf inside-lem t lem-indent indentation))
                ((and inside-lem (<= indentation lem-indent))
                 (setf inside-lem nil))
                (inside-lem
                 (multiple-value-bind (key value) (simple-field trimmed)
                   (cond
                     ((and key (string= key "profile"))
                      (setf profile (strip-scalar-quotes value)))
                     ((and key (string= key "document-id"))
                      (setf document-id (strip-scalar-quotes value))))))))
    (values profile document-id)))

(defun lsm-normalize-frontmatter-key (key)
  (remove-if (lambda (character)
               (member character
                       '(#\- #\_ #\. #\Space #\Tab #\' #\")))
             (string-downcase (trim-source-space key))))

(defun lsm-frontmatter-normalized-keys (line)
  "Return block and flow-mapping keys without interpreting YAML values."
  (let ((trimmed (trim-source-space line)))
    (when (or (zerop (length trimmed))
              (char= (char trimmed 0) #\#))
      (return-from lsm-frontmatter-normalized-keys nil)))
  (let ((keys nil)
        (candidate-start 0)
        (flow-map-depth 0)
        (quote nil)
        (escaped nil)
        (expecting-key t))
    (loop :for index :from 0 :below (length line)
          :for character := (char line index)
          :do
             (cond
               (escaped (setf escaped nil))
               ((and quote (char= quote #\") (char= character #\\))
                (setf escaped t))
               (quote
                (when (char= character quote)
                  (setf quote nil)))
               ((member character '(#\' #\"))
                (setf quote character))
               ((char= character #\#)
                (loop-finish))
               ((char= character #\{)
                (incf flow-map-depth)
                (setf candidate-start (1+ index) expecting-key t))
               ((char= character #\})
                (setf flow-map-depth (max 0 (1- flow-map-depth))
                      expecting-key nil))
               ((and (char= character #\,) (plusp flow-map-depth))
                (setf candidate-start (1+ index) expecting-key t))
               ((and expecting-key (char= character #\:))
                (let ((key
                        (lsm-normalize-frontmatter-key
                         (subseq line candidate-start index))))
                  (when (plusp (length key)) (push key keys)))
                (setf expecting-key nil))))
    (nreverse keys)))

(defun validate-lsm-extra-frontmatter-raw (raw)
  (unless (and (stringp raw)
               (<= (length raw)
                   +lsm-frontmatter-extension-character-limit+))
    (model-error :invalid-lsm-frontmatter-extension raw
                 "preserved frontmatter exceeds its character boundary"))
  (when (find-if (lambda (character)
                   (and (< (char-code character) 32)
                        (not (member character
                                     '(#\Tab #\Newline #\Return)))))
                 raw)
    (model-error :invalid-lsm-frontmatter-extension raw
                 "preserved frontmatter contains a forbidden control character"))
  (dolist (line (scan-source-lines raw))
    (let* ((text (source-line-text line))
           (trimmed (trim-source-space text))
           (indentation (line-indentation text))
           (keys (lsm-frontmatter-normalized-keys text)))
      (when (and (zerop indentation)
                 (member (string-downcase trimmed) '("---" "...")
                         :test #'string=))
        (model-error :invalid-lsm-frontmatter-extension text
                     "preserved frontmatter cannot contain a YAML document boundary"))
      (when (and (zerop indentation)
                 (string= "lem" (first keys)))
        (model-error :invalid-lsm-frontmatter-extension text
                     "preserved frontmatter cannot redefine the owned lem namespace"))
      (dolist (key keys)
        (when (lsm-forbidden-frontmatter-key-p key)
          (model-error :forbidden-lsm-frontmatter-key key
                       "credentials and secret-bearing keys are forbidden in document frontmatter")))))
  raw)

(defun lsm-extra-frontmatter-raw (source)
  "Return exact frontmatter outside the one owned top-level lem mapping."
  (let* ((lines (scan-source-lines source))
         (end-index (frontmatter-end-index lines)))
    (unless end-index
      (return-from lsm-extra-frontmatter-raw nil))
    (let ((inside-lem nil)
          (lem-indent nil)
          (lem-count 0)
          (stream (make-string-output-stream)))
      (loop :for line :in (subseq lines 1 end-index)
            :for text := (source-line-text line)
            :for trimmed := (trim-source-space text)
            :for indentation := (line-indentation text)
            :do
               (when (and inside-lem
                          (plusp (length trimmed))
                          (<= indentation lem-indent))
                 (setf inside-lem nil))
               (cond
                 ((and (null inside-lem)
                       (zerop indentation)
                       (string= "lem:" (string-downcase trimmed)))
                  (incf lem-count)
                  (when (> lem-count 1)
                    (model-error :duplicate-lsm-frontmatter-key "lem"
                                 "LSM frontmatter contains duplicate top-level lem mappings"))
                  (setf inside-lem t lem-indent indentation))
                 (inside-lem)
                 (t
                  (write-string
                   (subseq source
                           (source-line-character-start line)
                           (source-line-character-end line))
                   stream))))
      (let ((raw (get-output-stream-string stream)))
        (and (plusp (length raw))
             (validate-lsm-extra-frontmatter-raw raw))))))

(defun make-lsm-frontmatter-extension (raw)
  (make-opaque-extension
   :namespace +lsm-frontmatter-extension-namespace+
   :media-type "application/yaml"
   :raw-value (validate-lsm-extra-frontmatter-raw raw)
   :ordering-anchor :frontmatter
   :provenance :local))

(defun lsm-frontmatter-extension-p (extension)
  (and (opaque-extension-p extension)
       (string= +lsm-frontmatter-extension-namespace+
                (opaque-extension-namespace extension))
       (equal "application/yaml"
              (opaque-extension-media-type extension))
       (null (opaque-extension-owner-id extension))
       (stringp (opaque-extension-raw-value extension))
       (eq :frontmatter (opaque-extension-ordering-anchor extension))
       (eq :local (opaque-extension-provenance extension))))

(defun directive-opening-spec (line)
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
         (colons (or (position-if-not (lambda (character)
                                        (char= character #\:))
                                      trimmed)
                     (length trimmed))))
    (when (and (>= colons 3)
               (< colons (length trimmed))
               (char= (char trimmed colons) #\{))
      (let ((close (position #\} trimmed :start (1+ colons))))
        (when close
          (let ((name (trim-source-space
                       (subseq trimmed (1+ colons) close)))
                (argument (trim-source-space (subseq trimmed (1+ close)))))
            (when (and (plusp (length name))
                       (not (find-if #'whitespace-character-p name)))
              (values colons name
                      (and (plusp (length argument)) argument)))))))))

(defun directive-closing-width (line)
  (let ((trimmed (trim-source-space line)))
    (when (and (>= (length trimmed) 3)
               (every (lambda (character) (char= character #\:)) trimmed))
      (length trimmed))))

(defun find-directive-end (lines start-index &key literal-body-p)
  (multiple-value-bind (opening-width ignored-name)
      (directive-opening-spec (source-line-text (nth start-index lines)))
    (declare (ignore ignored-name))
    (let ((widths (list opening-width)))
      (loop :for index :from (1+ start-index) :below (length lines)
            :for text := (source-line-text (nth index lines))
            :do
               (if literal-body-p
                   (alexandria:when-let ((width (directive-closing-width text)))
                     (when (>= width opening-width)
                       (return (values index t))))
                   (multiple-value-bind (nested-width nested-name)
                       (directive-opening-spec text)
                     (declare (ignore nested-name))
                     (cond
                       (nested-width
                        (push nested-width widths)
                        (when (> (length widths) +lsm-directive-max-depth+)
                          (model-error
                           :lsm-directive-depth-limit-exceeded (length widths)
                           "LSM directive nesting exceeds the configured depth limit")))
                       ((alexandria:when-let
                            ((width (directive-closing-width text)))
                          (when (>= width (first widths))
                            (pop widths)
                            t))
                        (when (null widths)
                          (return (values index t)))))))
            :finally (return (values (1- (length lines)) nil))))))

(defun fence-opening-spec (line)
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
         (indent (- (length line) (length trimmed))))
    (when (and (<= indent 3) (plusp (length trimmed))
               (member (char trimmed 0) '(#\` #\~)))
      (let* ((marker (char trimmed 0))
             (width (or (position-if-not
                         (lambda (character) (char= character marker))
                         trimmed)
                        (length trimmed))))
        (when (>= width 3)
          (values marker width))))))

(defun fence-closing-p (line marker minimum-width)
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
         (width (or (position-if-not
                     (lambda (character) (char= character marker))
                     trimmed)
                    (length trimmed))))
    (and (>= width minimum-width)
         (every #'whitespace-character-p (subseq trimmed width)))))

(defun find-fence-end (lines start-index marker width)
  (loop :for index :from (1+ start-index) :below (length lines)
        :when (fence-closing-p (source-line-text (nth index lines))
                               marker width)
          :return (values index t)
        :finally (return (values (1- (length lines)) nil))))

(defun atx-heading-spec (line)
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
         (indent (- (length line) (length trimmed)))
         (level (or (position-if-not (lambda (character)
                                       (char= character #\#))
                                     trimmed)
                    (length trimmed))))
    (when (and (<= indent 3) (<= 1 level 6)
               (or (= level (length trimmed))
                   (member (char trimmed level) '(#\Space #\Tab))))
      (let* ((body (trim-source-space (subseq trimmed level)))
             (hash-start
               (position-if-not (lambda (character)
                                  (char= character #\#))
                                body :from-end t))
             (title
               (if (and hash-start
                        (< hash-start (1- (length body)))
                        (whitespace-character-p (char body hash-start)))
                   (string-right-trim '(#\Space #\Tab)
                                      (subseq body 0 (1+ hash-start)))
                   body)))
        (values level title)))))

(defun parse-directive-fields
    (lines start-index end-index &key preserve-key-case-p)
  (loop :for line :in (subseq lines (1+ start-index) end-index)
        :for trimmed := (trim-source-space (source-line-text line))
        :unless (or (zerop (length trimmed))
                    (char= (char trimmed 0) #\#))
          :append
          (multiple-value-bind (key value)
              (if (and (> (length trimmed) 2)
                       (char= (char trimmed 0) #\:))
                  (let ((close (position #\: trimmed :start 1)))
                    (when close
                      (let ((name (subseq trimmed 1 close)))
                        (when (and (plusp (length name))
                                   (alpha-char-p (char name 0))
                                   (every
                                    (lambda (character)
                                      (or (alphanumericp character)
                                          (member character '(#\- #\_))))
                                    name))
                          (values
                           (funcall (if preserve-key-case-p
                                        #'identity #'string-downcase)
                                    name)
                           (trim-source-space
                            (subseq trimmed (1+ close))))))))
                  (simple-field
                   trimmed :preserve-key-case-p preserve-key-case-p))
            (if key (list (cons key value)) nil))))

(defun parse-myst-directive-options (lines start-index end-index)
  (loop :for line :in (subseq lines (1+ start-index) end-index)
        :for trimmed := (trim-source-space (source-line-text line))
        :until (zerop (length trimmed))
        :for close := (and (> (length trimmed) 2)
                           (char= (char trimmed 0) #\:)
                           (position #\: trimmed :start 1))
        :while close
        :for name := (subseq trimmed 1 close)
        :while (and (plusp (length name))
                    (alpha-char-p (char name 0))
                    (every
                     (lambda (character)
                       (or (alphanumericp character)
                           (member character '(#\- #\_))))
                     name))
        :collect
        (cons (string-downcase name)
              (trim-source-space (subseq trimmed (1+ close))))))

(defun split-lsm-scalar-list (body)
  (let ((parts nil)
        (start 0)
        (quote nil)
        (escaped-p nil))
    (loop :for index :from 0 :below (length body)
          :for character := (char body index)
          :do
             (cond
               (escaped-p (setf escaped-p nil))
               ((and quote (char= quote #\") (char= character #\\))
                (setf escaped-p t))
               ((and quote (char= character quote))
                (setf quote nil))
               ((and (null quote) (member character '(#\" #\')))
                (setf quote character))
               ((and (null quote) (char= character #\,))
                (push (subseq body start index) parts)
                (setf start (1+ index)))))
    (when quote
      (model-error :invalid-scalar-list body
                   "LSM scalar list contains an unclosed quote"))
    (push (subseq body start) parts)
    (nreverse parts)))

(defun comma-separated-scalars (value)
  (let* ((value (trim-source-space value))
         (length (length value))
         (body (if (and (>= length 2)
                        (char= (char value 0) #\[)
                        (char= (char value (1- length)) #\]))
                   (subseq value 1 (1- length))
                   value)))
    (loop :for part :in (split-lsm-scalar-list body)
          :for scalar := (strip-scalar-quotes part)
          :when (plusp (length scalar)) :collect scalar)))

(defun field-value (name fields)
  (cdr (assoc name fields :test #'string=)))

(defun lsm-temporal-precision (local-value)
  (let* ((length (length local-value))
         (end (if (and (plusp length)
                       (char-equal (char local-value (1- length)) #\Z))
                  (1- length)
                  length))
         (time-start (position #\T local-value)))
    (cond
      ((null time-start) :second)
      ((position #\. local-value :start (1+ time-start) :end end)
       :subsecond)
      ((= (- end time-start) 6) :minute)
      (t :second))))

(defun lsm-normalize-temporal-local-value (local-value precision)
  (if (eq precision :minute)
      (let ((length (length local-value)))
        (if (and (plusp length)
                 (char-equal (char local-value (1- length)) #\Z))
            (concatenate 'string (subseq local-value 0 (1- length)) ":00Z")
            (concatenate 'string local-value ":00")))
      local-value))

(defun parse-lsm-temporal (value)
  (when value
    (let* ((lexeme (strip-scalar-quotes value))
           (length (length lexeme))
           (zone-start (and (plusp length)
                            (char= (char lexeme (1- length)) #\])
                            (position #\[ lexeme :from-end t))))
      (cond
        (zone-start
         (let* ((local (subseq lexeme 0 zone-start))
                (precision (lsm-temporal-precision local)))
           (make-temporal-value
            :kind :zoned
            :local-value
            (lsm-normalize-temporal-local-value local precision)
            :timezone-id (subseq lexeme (1+ zone-start) (1- length))
            :gap-policy :reject :precision precision
            :original-lexeme lexeme)))
        ((and (= length 10)
              (char= (char lexeme 4) #\-)
              (char= (char lexeme 7) #\-))
         (make-temporal-value :kind :date :local-value lexeme
                              :original-lexeme lexeme))
        ((and (plusp length) (char-equal (char lexeme (1- length)) #\Z))
         (let ((precision (lsm-temporal-precision lexeme)))
           (make-temporal-value
            :kind :utc
            :local-value
            (lsm-normalize-temporal-local-value lexeme precision)
            :precision precision :original-lexeme lexeme)))
        (t
         (let ((precision (lsm-temporal-precision lexeme)))
           (make-temporal-value
            :kind :floating
            :local-value
            (lsm-normalize-temporal-local-value lexeme precision)
            :precision precision :original-lexeme lexeme)))))))

(defun parse-progress (value)
  (when value
    (let ((integer (ignore-errors
                     (parse-integer (strip-scalar-quotes value)
                                    :junk-allowed nil))))
      (unless (and integer (<= 0 integer 100))
        (model-error :invalid-progress value
                     "LSM task progress must be an integer from 0 through 100"))
      integer)))

(defun parse-lsm-priority (value)
  (when value
    (let* ((trimmed (trim-source-space value))
           (quoted-p
             (and (plusp (length trimmed))
                  (member (char trimmed 0) '(#\" #\'))))
           (scalar (strip-scalar-quotes trimmed))
           (integer (and (not quoted-p)
                         (ignore-errors
                           (parse-integer scalar :junk-allowed nil)))))
      (or integer scalar))))

(defun parse-task-done-p (value state)
  (if value
      (let ((normalized
              (string-downcase (strip-scalar-quotes value))))
        (cond
          ((string= normalized "true") t)
          ((string= normalized "false") nil)
          (t
           (model-error :invalid-done-flag value
                        "LSM task done must be true or false"))))
      ;; Compatibility for LSM/1 documents written before DONE was explicit.
      (not (null (member (string-upcase state) '("DONE" "CANCELLED")
                         :test #'string=)))))

(defparameter +lsm-task-clock-limit+ 4096)

(defun lsm-task-clock-separator (lexeme)
  (let ((inside-zone-p nil)
        (separator nil))
    (loop :for index :from 0 :below (length lexeme)
          :for character := (char lexeme index)
          :do (cond
                ((char= character #\[) (setf inside-zone-p t))
                ((char= character #\]) (setf inside-zone-p nil))
                ((and (char= character #\/) (not inside-zone-p))
                 (when separator
                   (model-error :invalid-lsm-task-clock lexeme
                                "task clock must contain exactly one interval separator"))
                 (setf separator index))))
    (or separator
        (model-error :invalid-lsm-task-clock lexeme
                     "task clock requires one interval separator"))))

(defun parse-lsm-task-clock (lexeme)
  (let* ((separator (lsm-task-clock-separator lexeme))
         (start-text (subseq lexeme 0 separator))
         (end-text (subseq lexeme (1+ separator))))
    (when (zerop (length start-text))
      (model-error :invalid-lsm-task-clock lexeme
                   "task clock requires a start"))
    (make-task-clock
     :start (parse-lsm-temporal start-text)
     :end (and (plusp (length end-text))
               (parse-lsm-temporal end-text)))))

(defun parse-lsm-task-clocks (value)
  (let ((values (if value (comma-separated-scalars value) nil)))
    (when (> (length values) +lsm-task-clock-limit+)
      (model-error :lsm-task-clock-limit-exceeded (length values)
                   "task clock list exceeds its bounded limit"))
    (mapcar #'parse-lsm-task-clock values)))

(defun parse-lsm-recurrence-policy (value default)
  (if (null value)
      default
      (let* ((normalized (string-upcase (strip-scalar-quotes value)))
             (policy
               (find normalized '(:none :fixed :catch-up :completion-relative)
                     :key #'symbol-name :test #'string=)))
        (or policy
            (model-error :invalid-recurrence-policy value
                         "invalid LSM recurrence policy")))))

(defun parse-lsm-temporal-list (value)
  (mapcar #'parse-lsm-temporal (comma-separated-scalars value)))

(defun lsm-recurrence-period-separator (lexeme)
  (let ((inside-zone-p nil)
        (separator nil))
    (loop :for index :from 0 :below (length lexeme)
          :for character := (char lexeme index)
          :do (cond
                ((char= character #\[)
                 (setf inside-zone-p t))
                ((char= character #\])
                 (setf inside-zone-p nil))
                ((and (char= character #\/) (not inside-zone-p))
                 (when separator
                   (model-error :invalid-lsm-recurrence-period lexeme
                                "recurrence period contains multiple separators"))
                 (setf separator index))))
    separator))

(defun parse-lsm-recurrence-date (value)
  (let* ((lexeme (strip-scalar-quotes value))
         (separator (lsm-recurrence-period-separator lexeme)))
    (if (null separator)
        (parse-lsm-temporal lexeme)
        (let ((start-text (subseq lexeme 0 separator))
              (finish-text (subseq lexeme (1+ separator))))
          (when (or (zerop (length start-text))
                    (zerop (length finish-text)))
            (model-error :invalid-lsm-recurrence-period lexeme
                         "recurrence period separator cannot be at an edge"))
          (let ((start (parse-lsm-temporal start-text))
                (duration-looking-p
                  (or (char= (char finish-text 0) #\P)
                      (and (> (length finish-text) 1)
                           (member (char finish-text 0) '(#\+ #\-))
                           (char= (char finish-text 1) #\P)))))
            (if duration-looking-p
                (multiple-value-bind (duration valid-p message)
                    (decode-ical-duration finish-text)
                  (unless (and valid-p (ical-duration-positive-p duration))
                    (model-error :invalid-lsm-recurrence-period-duration
                                 finish-text
                                 "invalid positive recurrence period duration: ~a"
                                 (or message
                                     "duration must be positive and non-zero")))
                  (make-recurrence-period
                   :start start :duration finish-text
                   :original-lexeme lexeme))
                (make-recurrence-period
                 :start start :end (parse-lsm-temporal finish-text)
                 :original-lexeme lexeme)))))))

(defun parse-lsm-recurrence-date-list (value)
  (mapcar #'parse-lsm-recurrence-date (comma-separated-scalars value)))

(defun recurrence-from-fields (fields)
  (let* ((repeater
           (and (field-value "repeater" fields)
                (strip-scalar-quotes (field-value "repeater" fields))))
         (rules-value (field-value "recurrence-rules" fields))
         (dates-value (field-value "recurrence-dates" fields))
         (exceptions-value
           (field-value "recurrence-exception-dates" fields))
         (policy-value (field-value "recurrence-policy" fields))
         (original-value (field-value "recurrence-original" fields))
         (structured-p
           (or rules-value dates-value exceptions-value policy-value
               original-value)))
    (when (and repeater structured-p)
      (model-error :conflicting-recurrence-fields fields
                   "repeater cannot be combined with structured recurrence fields"))
    (cond
      (repeater
       (make-recurrence
        :policy (cond
                  ((search ".+" repeater) :completion-relative)
                  ((search "++" repeater) :catch-up)
                  (t :fixed))
        :original-lexeme repeater))
      (structured-p
       (make-recurrence
        :rules (if rules-value
                   (comma-separated-scalars rules-value)
                   nil)
        :dates (if dates-value
                   (parse-lsm-recurrence-date-list dates-value)
                   nil)
        :exception-dates
        (if exceptions-value
            (parse-lsm-temporal-list exceptions-value)
            nil)
        :policy (parse-lsm-recurrence-policy policy-value :fixed)
        :original-lexeme
        (and original-value (strip-scalar-quotes original-value)))))))

(defun task-from-fields (fields)
  (let ((state (and (field-value "state" fields)
                    (strip-scalar-quotes (field-value "state" fields)))))
    (unless (non-empty-string-p state)
      (model-error :missing-task-state fields
                   "lem-task directive requires a state"))
    (make-task-facet
     :workflow-id (or (and (field-value "workflow" fields)
                           (strip-scalar-quotes
                            (field-value "workflow" fields)))
                      "lsm/default")
     :state state
     :done-p (parse-task-done-p (field-value "done" fields) state)
     :priority (parse-lsm-priority (field-value "priority" fields))
     :progress (parse-progress (field-value "progress" fields))
     :effort (and (field-value "effort" fields)
                  (strip-scalar-quotes (field-value "effort" fields)))
     :scheduled (parse-lsm-temporal (field-value "scheduled" fields))
     :scheduled-delay
     (and (field-value "scheduled-delay" fields)
          (strip-scalar-quotes (field-value "scheduled-delay" fields)))
     :deadline (parse-lsm-temporal (field-value "deadline" fields))
     :closed (parse-lsm-temporal (field-value "closed" fields))
     :deadline-warning
     (and (field-value "deadline-warning" fields)
          (strip-scalar-quotes (field-value "deadline-warning" fields)))
     :recurrence (recurrence-from-fields fields)
     :logs (parse-lsm-task-clocks (field-value "clocks" fields)))))

(defun lsm-enum-field (name fields allowed default)
  (let* ((raw (field-value name fields))
         (normalized (and raw
                          (string-upcase (strip-scalar-quotes raw))))
         (value (and normalized
                     (find normalized allowed
                           :key #'symbol-name :test #'string=)))
         (result (or value default)))
    (when (and raw (null value))
      (model-error :invalid-calendar-binding-field raw
                   "invalid lem-calendar-binding ~a" name))
    result))

(defun calendar-binding-from-fields (fields node-id)
  (let ((id (and (field-value "id" fields)
                 (strip-scalar-quotes (field-value "id" fields)))))
    (unless (non-empty-string-p id)
      (model-error :missing-calendar-binding-id fields
                   "lem-calendar-binding requires an ID"))
    (make-calendar-binding
     :id id
     :node-id node-id
     :projection-kind
     (lsm-enum-field "projection" fields
                     '(:event :task :journal :availability) :event)
     :account-id
     (and (field-value "account" fields)
          (strip-scalar-quotes (field-value "account" fields)))
     :calendar-id
     (and (field-value "calendar" fields)
          (strip-scalar-quotes (field-value "calendar" fields)))
     :uid
     (and (field-value "uid" fields)
          (strip-scalar-quotes (field-value "uid" fields)))
     :recurrence-id
     (parse-lsm-temporal (field-value "recurrence-id" fields))
     :ownership
     (lsm-enum-field "ownership" fields
                     '(:local :organizer :attendee :server) :local)
     :write-policy
     (lsm-enum-field "write-policy" fields
                     '(:bidirectional :local-only :remote-only :read-only)
                     :local-only))))

(defun event-from-fields (fields)
  (make-event-facet
   :start (parse-lsm-temporal (field-value "start" fields))
   :end (parse-lsm-temporal (field-value "end" fields))
   :duration
   (and (field-value "duration" fields)
        (strip-scalar-quotes (field-value "duration" fields)))
   :status
   (and (field-value "status" fields)
        (strip-scalar-quotes (field-value "status" fields)))
   :location
   (and (field-value "location" fields)
        (strip-scalar-quotes (field-value "location" fields)))
   :url
   (and (field-value "url" fields)
        (strip-scalar-quotes (field-value "url" fields)))
   :transparency
   (lsm-enum-field "transparency" fields '(:opaque :transparent) nil)
   :recurrence (recurrence-from-fields fields)))

(defun lsm-content-kind (value)
  (let ((name (and value (string-downcase (strip-scalar-quotes value)))))
    (or (cdr (assoc name
                    '(("blank" . :blank)
                      ("paragraph" . :paragraph)
                      ("quote" . :quote)
                      ("list" . :list)
                      ("table" . :table)
                      ("source-block" . :source-block)
                      ("block" . :block)
                      ("drawer" . :drawer)
                      ("comment" . :comment)
                      ("keyword" . :keyword)
                      ("opaque" . :opaque))
                    :test #'string=))
        (model-error :invalid-content-kind value
                     "lem-org-opaque requires a known content kind"))))

(defun native-myst-drawer-content-node-from-cst (cst source-id)
  (when (and (eq (cst-node-kind cst) :directive)
             (string= (or (cst-node-name cst) "") "lem-drawer"))
    (multiple-value-bind (name inlines valid-p)
        (parse-myst-drawer-inlines
         (cst-node-raw cst) :source-id source-id
         :character-base (cst-node-character-start cst)
         :byte-base (cst-node-byte-start cst))
      (when valid-p
        (make-content-node
         :kind :drawer :source-format :myst :raw (cst-node-raw cst)
         :name name :inlines inlines
         :span
         (make-source-span
          :source-id source-id
          :character-start (cst-node-character-start cst)
          :character-end (cst-node-character-end cst)
          :byte-start (cst-node-byte-start cst)
          :byte-end (cst-node-byte-end cst)))))))

(defun opaque-source-format (value)
  (let ((name (and value
                   (string-downcase (strip-scalar-quotes value)))))
    (or (cdr (assoc name
                    '(("commonmark" . :commonmark)
                      ("myst" . :myst))
                    :test #'string=))
        (model-error :invalid-opaque-source-format value
                     "lem-source-opaque requires CommonMark or MyST source"))))

(defun opaque-source-content-node-from-cst (cst source-id)
  (when (and (eq (cst-node-kind cst) :directive)
             (string= (or (cst-node-name cst) "") "lem-source-opaque"))
    (let* ((fields (cst-node-fields cst))
           (raw-value (field-value "raw" fields))
           (kind (lsm-content-kind (field-value "kind" fields))))
      (unless (eq :opaque kind)
        (model-error :invalid-opaque-source-kind kind
                     "lem-source-opaque only carries semantically opaque source"))
      (unless raw-value
        (model-error :missing-content-raw fields
                     "lem-source-opaque requires a raw field"))
      (make-content-node
       :kind :opaque
       :source-format (opaque-source-format (field-value "format" fields))
       :raw (strip-scalar-quotes raw-value)
       :span
       (make-source-span
        :source-id source-id
        :character-start (cst-node-character-start cst)
        :character-end (cst-node-character-end cst)
        :byte-start (cst-node-byte-start cst)
        :byte-end (cst-node-byte-end cst))))))

(defun lsm-content-node-from-cst
    (cst source-id &key (allow-native-quote-p t)
                        (allow-native-paragraph-p t))
  (or
   (native-myst-drawer-content-node-from-cst cst source-id)
   (opaque-source-content-node-from-cst cst source-id)
   (if (and (eq (cst-node-kind cst) :directive)
           (string= (or (cst-node-name cst) "") "lem-org-opaque"))
      (let* ((fields (cst-node-fields cst))
             (raw-value (field-value "raw" fields)))
        (unless raw-value
          (model-error :missing-content-raw fields
                       "lem-org-opaque requires a raw field"))
        (make-content-node
         :kind (lsm-content-kind (field-value "kind" fields))
         :source-format :org
         :raw (strip-scalar-quotes raw-value)
         :text (and (field-value "text" fields)
                    (strip-scalar-quotes (field-value "text" fields)))
         :name (and (field-value "name" fields)
                    (strip-scalar-quotes (field-value "name" fields)))
         :span
         (make-source-span
          :source-id source-id
          :character-start (cst-node-character-start cst)
          :character-end (cst-node-character-end cst)
          :byte-start (cst-node-byte-start cst)
          :byte-end (cst-node-byte-end cst))))
      (let* ((raw (cst-node-raw cst))
             (raw-node-p (eq (cst-node-kind cst) :raw))
             (quote-inlines
               (and allow-native-quote-p raw-node-p
                    (multiple-value-bind (inlines valid-p)
                        (parse-commonmark-quote-inlines
                         raw :source-id source-id
                         :character-base (cst-node-character-start cst)
                         :byte-base (cst-node-byte-start cst))
                      (and valid-p inlines))))
             (comment-text (and raw-node-p
                                (null quote-inlines)
                                (native-myst-comment-text raw)))
             (code-block
               (cond
                 ((eq (cst-node-kind cst) :fence)
                  (multiple-value-bind (data valid-p)
                      (parse-commonmark-fenced-code-data
                       raw :source-id source-id
                       :character-base (cst-node-character-start cst)
                       :byte-base (cst-node-byte-start cst))
                    (and valid-p data)))
                 ((and (eq (cst-node-kind cst) :directive)
                       (string= "code-cell" (or (cst-node-name cst) "")))
                  (multiple-value-bind (data valid-p)
                      (parse-myst-code-cell-data
                       raw :source-id source-id
                       :character-base (cst-node-character-start cst)
                       :byte-base (cst-node-byte-start cst))
                    (and valid-p data))))))
        (multiple-value-bind (inlines paragraph-p)
            (if (and allow-native-paragraph-p raw-node-p
                     (null quote-inlines) (null comment-text))
                (parse-commonmark-paragraph-inlines
                 raw :source-id source-id
                 :character-base (cst-node-character-start cst)
                 :byte-base (cst-node-byte-start cst))
                (values nil nil))
          (make-content-node
           :kind (cond
                   (quote-inlines :quote)
                   (paragraph-p :paragraph)
                   (comment-text :comment)
                   (code-block :source-block)
                   ((eq (cst-node-kind cst) :fence) :block)
                   (t :opaque))
           :source-format (cond
                            (quote-inlines :commonmark)
                            (paragraph-p :commonmark)
                            (comment-text :myst)
                            (code-block
                             (code-block-data-source-format code-block))
                            (t :lsm))
           :raw raw
           :text comment-text
           :inlines (or quote-inlines inlines)
           :code-block code-block
           :name (cond
                   ((and code-block
                         (eq :myst
                             (code-block-data-source-format code-block)))
                    "code-cell")
                   ((null code-block) (cst-node-name cst)))
           :span
           (make-source-span
            :source-id source-id
            :character-start (cst-node-character-start cst)
            :character-end (cst-node-character-end cst)
            :byte-start (cst-node-byte-start cst)
            :byte-end (cst-node-byte-end cst))))))))

(defun commonmark-quote-cst-line-p (cst)
  (and cst
       (eq (cst-node-kind cst) :raw)
       (multiple-value-bind (inlines valid-p)
           (parse-commonmark-quote-inlines (cst-node-raw cst))
         (declare (ignore inlines))
         valid-p)))

(defun lsm-cst-content-boundary-p (cst)
  (or (null cst)
      (not (eq :raw (cst-node-kind cst)))
      (every #'whitespace-character-p (cst-node-raw cst))))

(defun unsupported-commonmark-quote-run-at (remaining previous)
  "Return a quote-started raw run that exceeds the one-line LSM profile."
  (unless (commonmark-quote-cst-line-p (first remaining))
    (return-from unsupported-commonmark-quote-run-at (values nil nil)))
  (let ((cursor remaining)
        (run nil))
    (loop :while (and cursor
                      (not (lsm-cst-content-boundary-p (first cursor))))
          :do (push (pop cursor) run))
    (setf run (nreverse run))
    (if (or (> (length run) 1)
            (not (lsm-cst-content-boundary-p previous)))
        (values run cursor)
        (values nil nil))))

(defun commonmark-list-cst-spec (cst)
  (if (eq (cst-node-kind cst) :raw)
      (multiple-value-bind (items valid-p)
          (parse-commonmark-list-items (cst-node-raw cst))
        (if (and valid-p (= 1 (length items)))
            (values t (list-item-ordered-p (first items)))
            (values nil nil)))
      (values nil nil)))

(defun lsm-list-content-node-from-csts (csts source-id)
  (let* ((first (first csts))
         (last (car (last csts)))
         (raw (with-output-to-string (stream)
                (dolist (cst csts)
                  (write-string (cst-node-raw cst) stream)))))
    (multiple-value-bind (items valid-p)
        (parse-commonmark-list-items
         raw :source-id source-id
         :character-base (cst-node-character-start first)
         :byte-base (cst-node-byte-start first))
      (unless valid-p
        (model-error :invalid-native-list raw
                     "grouped CommonMark list lines failed list projection"))
      (make-content-node
       :kind :list :source-format :commonmark :raw raw :items items
       :span (make-source-span
              :source-id source-id
              :character-start (cst-node-character-start first)
              :character-end (cst-node-character-end last)
              :byte-start (cst-node-byte-start first)
              :byte-end (cst-node-byte-end last))))))

(defun commonmark-table-cst-line-p (cst)
  (and (eq (cst-node-kind cst) :raw)
       (let ((text (source-single-line-text (cst-node-raw cst))))
         (and text (table-cell-ranges text)))))

(defun lsm-table-run-at (remaining previous)
  (unless (and (commonmark-table-cst-line-p (first remaining))
               (or (null previous)
                   (not (eq :raw (cst-node-kind previous)))
                   (every #'whitespace-character-p
                          (cst-node-raw previous))))
    (return-from lsm-table-run-at (values nil nil)))
  (let ((cursor remaining)
        (run nil))
    (loop :while (and cursor
                      (commonmark-table-cst-line-p (first cursor)))
          :do (push (pop cursor) run))
    (setf run (nreverse run))
    (unless (and (>= (length run) 2)
                 (or (null cursor)
                     (not (eq :raw (cst-node-kind (first cursor))))
                     (every #'whitespace-character-p
                            (cst-node-raw (first cursor)))))
      (return-from lsm-table-run-at (values nil nil)))
    (let ((raw (with-output-to-string (stream)
                 (dolist (cst run)
                   (write-string (cst-node-raw cst) stream)))))
      (multiple-value-bind (table valid-p) (parse-gfm-table-data raw)
        (declare (ignore table))
        (if valid-p (values run cursor) (values nil nil))))))

(defun lsm-table-content-node-from-csts (csts source-id)
  (let* ((first (first csts))
         (last (car (last csts)))
         (raw (with-output-to-string (stream)
                (dolist (cst csts)
                  (write-string (cst-node-raw cst) stream)))))
    (multiple-value-bind (table valid-p)
        (parse-gfm-table-data
         raw :source-id source-id
         :character-base (cst-node-character-start first)
         :byte-base (cst-node-byte-start first))
      (unless valid-p
        (model-error :invalid-native-table raw
                     "grouped GFM table lines failed table projection"))
      (make-content-node
       :kind :table :source-format :commonmark :raw raw :table table
       :span (make-source-span
              :source-id source-id
              :character-start (cst-node-character-start first)
              :character-end (cst-node-character-end last)
              :byte-start (cst-node-byte-start first)
              :byte-end (cst-node-byte-end last))))))

(defun lsm-list-run-at (remaining previous)
  (multiple-value-bind (list-line-p ordered-p)
      (commonmark-list-cst-spec (first remaining))
    (unless (and list-line-p (lsm-cst-content-boundary-p previous))
      (return-from lsm-list-run-at (values nil nil)))
    (let ((cursor remaining)
          (run nil))
      (loop :while cursor
            :do
               (multiple-value-bind (candidate-p candidate-ordered-p)
                   (commonmark-list-cst-spec (first cursor))
                 (unless (and candidate-p
                              (eq ordered-p candidate-ordered-p))
                   (return))
                 (push (pop cursor) run)))
      (if (lsm-cst-content-boundary-p (first cursor))
          (values (nreverse run) cursor)
          (values nil nil)))))

(defun lsm-content-nodes-from-csts (csts source-id)
  "Project CSTS while coalescing supported native block line runs."
  (let ((remaining csts)
        (content nil)
        (previous nil))
    (loop :while remaining
          :for cst := (first remaining)
          :do
             (multiple-value-bind (quote-run quote-rest)
                 (unsupported-commonmark-quote-run-at remaining previous)
               (cond
                 (quote-run
                  (setf remaining quote-rest
                        previous (car (last quote-run)))
                  (dolist (quote-cst quote-run)
                    (push (lsm-content-node-from-cst
                           quote-cst source-id
                           :allow-native-quote-p nil
                           :allow-native-paragraph-p nil)
                          content)))
                 (t
                  (multiple-value-bind (table-run table-rest)
                      (lsm-table-run-at remaining previous)
                    (cond
                      (table-run
                       (setf remaining table-rest
                             previous (car (last table-run)))
                       (push (lsm-table-content-node-from-csts
                              table-run source-id)
                             content))
                      (t
                       (multiple-value-bind (list-run list-rest)
                           (lsm-list-run-at remaining previous)
                         (cond
                           (list-run
                            (setf remaining list-rest
                                  previous (car (last list-run)))
                            (push (lsm-list-content-node-from-csts
                                   list-run source-id)
                                  content))
                           (t
                            (pop remaining)
                            (unless (every #'whitespace-character-p
                                           (cst-node-raw cst))
                              (push (lsm-content-node-from-cst
                                     cst source-id)
                                    content))
                            (setf previous cst)))))))))))
    (nreverse content)))

(defun diagnostic-for-range
    (source-id byte-prefixes severity code message start end &key remediation
                                                               loss-risk)
  (make-diagnostic
   :severity severity
   :code code
   :message message
   :span (make-source-span :source-id source-id
                           :character-start start :character-end end
                           :byte-start (aref byte-prefixes start)
                           :byte-end (aref byte-prefixes end))
   :remediation remediation
   :loss-risk (or loss-risk :none)))

(defun parse-lsm-cst (source source-id)
  (unless (stringp source)
    (model-error :invalid-lsm-source source
                 "LSM CST source must be a string"))
  (when (> (length source) +lsm-source-max-characters+)
    (model-error :lsm-source-limit-exceeded (length source)
                 "LSM source exceeds the configured character limit"))
  (let* ((lines (scan-source-lines source))
         (byte-prefixes (source-byte-prefixes source))
         (frontmatter-end (frontmatter-end-index lines))
         (profile nil)
         (document-id nil)
         (nodes nil)
         (headings nil)
         (diagnostics nil)
         (last-heading nil)
         (adjacent-heading-p nil)
         (index 0))
    (when (> (length lines) +lsm-source-max-lines+)
      (model-error :lsm-line-limit-exceeded (length lines)
                   "LSM source exceeds the configured line limit"))
    (unless frontmatter-end
      (model-error :missing-lsm-frontmatter source-id
                   "LSM/1 requires a leading YAML frontmatter block"))
    (multiple-value-setq (profile document-id)
      (parse-lsm-frontmatter lines frontmatter-end))
    (unless (string= (or profile "") "lsm/1")
      (model-error :unsupported-profile profile
                   "LSM provider requires an explicit lsm/1 profile"))
    (require-non-empty-string document-id :missing-document-id
                              "LSM document ID")
    (labels ((block-end (end-index)
               (source-line-character-end (nth end-index lines)))
             (emit-node (kind start-index end-index &key name fields)
               (let ((node
                       (make-cst-node-from-source
                        source byte-prefixes kind
                        (source-line-character-start (nth start-index lines))
                        (block-end end-index)
                        :name name :fields fields)))
                 (push node nodes)
                 node)))
      (emit-node :frontmatter 0 frontmatter-end
                 :name "lem"
                 :fields (list (cons "profile" profile)
                               (cons "document-id" document-id)))
      (setf index (1+ frontmatter-end))
      (loop :while (< index (length lines))
            :for line := (nth index lines)
            :for text := (source-line-text line)
            :do
               (multiple-value-bind
                     (directive-width directive-name directive-argument)
                   (directive-opening-spec text)
                 (declare (ignore directive-width directive-argument))
                 (multiple-value-bind (fence-marker fence-width)
                     (fence-opening-spec text)
                   (multiple-value-bind (heading-level heading-title)
                       (atx-heading-spec text)
                     (cond
                       (directive-name
                        (multiple-value-bind (end-index closed-p)
                            (find-directive-end
                             lines index
                             :literal-body-p
                             (member directive-name
                                     '("code-cell" "code" "code-block")
                                     :test #'string=))
                          (let* ((fields
                                   (if (member
                                        directive-name
                                        '("code-cell" "code" "code-block"
                                          "table")
                                        :test #'string=)
                                       (parse-myst-directive-options
                                        lines index end-index)
                                       (parse-directive-fields
                                        lines index end-index
                                        :preserve-key-case-p
                                        (string= directive-name
                                                 "lem-properties"))))
                                 (node (emit-node :directive index end-index
                                                  :name directive-name
                                                  :fields fields)))
                            (unless closed-p
                              (push
                               (diagnostic-for-range
                                source-id byte-prefixes :error
                                :unclosed-directive
                                (format nil "Unclosed MyST directive ~a"
                                        directive-name)
                                (cst-node-character-start node)
                                (cst-node-character-end node)
                                :loss-risk :loss)
                               diagnostics))
                            (cond
                              ((and adjacent-heading-p last-heading
                                    (string= directive-name "lem-node"))
                               (setf (parsed-heading-node-fields last-heading)
                                     fields
                                     (parsed-heading-node-raw last-heading)
                                     (cst-node-raw node)))
                              ((and adjacent-heading-p last-heading
                                    (string= directive-name "lem-task"))
                               (setf (parsed-heading-task-fields last-heading)
                                     fields
                                     (parsed-heading-task-raw last-heading)
                                     (cst-node-raw node)))
                              ((and adjacent-heading-p last-heading
                                    (string= directive-name "lem-event"))
                               (setf (parsed-heading-event-fields last-heading)
                                     fields
                                     (parsed-heading-event-raw last-heading)
                                     (cst-node-raw node)))
                              ((and adjacent-heading-p last-heading
                                    (string= directive-name "lem-properties"))
                               (setf
                                (parsed-heading-properties-fields last-heading)
                                fields
                                (parsed-heading-properties-raw last-heading)
                                (cst-node-raw node)))
                              ((and adjacent-heading-p last-heading
                                    (string= directive-name
                                             "lem-calendar-binding"))
                               (push fields
                                     (parsed-heading-calendar-binding-fields
                                      last-heading))
                               (push (cst-node-raw node)
                                     (parsed-heading-calendar-binding-raw
                                      last-heading)))
                              (t
                               (when last-heading
                                 (push node
                                       (parsed-heading-body-nodes
                                        last-heading)))
                               (setf adjacent-heading-p nil)))
                            (setf index (1+ end-index)))))
                       (fence-marker
                        (multiple-value-bind (end-index closed-p)
                            (find-fence-end lines index fence-marker fence-width)
                          (let ((node (emit-node :fence index end-index)))
                            (when last-heading
                              (push node (parsed-heading-body-nodes last-heading)))
                            (unless closed-p
                              (push
                               (diagnostic-for-range
                                source-id byte-prefixes :error :unclosed-fence
                                "Unclosed Markdown code fence"
                                (cst-node-character-start node)
                                (cst-node-character-end node)
                                :loss-risk :loss)
                               diagnostics))
                            (setf adjacent-heading-p nil
                                  index (1+ end-index)))))
                       (heading-level
                        (let* ((node (emit-node :heading index index
                                                :fields
                                                (list
                                                 (cons "level" heading-level)
                                                 (cons "title" heading-title))))
                               (span
                                 (make-source-span
                                  :source-id source-id
                                  :character-start
                                  (cst-node-character-start node)
                                  :character-end (cst-node-character-end node)
                                  :byte-start (cst-node-byte-start node)
                                  :byte-end (cst-node-byte-end node)))
                               (heading
                                 (make-parsed-heading
                                  (cst-node-character-start node)
                                  (cst-node-character-end node)
                                  heading-level heading-title span)))
                          (push heading headings)
                          (setf last-heading heading
                                adjacent-heading-p t)
                          (incf index)))
                       (t
                        (let ((node (emit-node :raw index index)))
                          (when last-heading
                            (push node (parsed-heading-body-nodes last-heading)))
                          (unless (whitespace-string-p (cst-node-raw node))
                            (setf adjacent-heading-p nil))
                          (incf index))))))))
      (values
       (make-lsm-syntax-document
        :source source
        :newline (source-newline-style source)
        :nodes (nreverse nodes)
        :profile profile
        :document-id document-id
        :diagnostics (nreverse diagnostics))
       (nreverse headings)
       byte-prefixes))))

(defun semantic-nodes-from-lsm
    (headings source-id byte-prefixes diagnostics)
  (let ((stack nil)
        (roots nil)
        (nodes nil))
    (dolist (heading headings)
      (let* ((fields (parsed-heading-task-fields heading))
             (node-fields (parsed-heading-node-fields heading))
             (depth-value
               (and node-fields (field-value "depth" node-fields)
                    (ignore-errors
                      (parse-integer
                       (strip-scalar-quotes
                        (field-value "depth" node-fields))
                       :junk-allowed nil))))
             (declared-id
               (or (and node-fields (field-value "id" node-fields)
                        (strip-scalar-quotes
                         (field-value "id" node-fields)))
                   (and fields (field-value "id" fields)
                        (strip-scalar-quotes (field-value "id" fields)))))
             (id
               (if (non-empty-string-p declared-id)
                   declared-id
                   (format nil "~a#heading-~d"
                           source-id (parsed-heading-start heading)))))
        (when depth-value
          (unless (>= depth-value (parsed-heading-level heading))
            (model-error :invalid-node-depth depth-value
                         "lem-node depth cannot be shallower than its heading"))
          (setf (parsed-heading-level heading) depth-value))
        (setf (parsed-heading-id heading) id)
        (unless declared-id
          (push
           (diagnostic-for-range
            source-id byte-prefixes :warning :derived-node-id
            "Heading has no persistent LSM node ID; using a source-derived ID"
            (parsed-heading-start heading) (parsed-heading-end heading)
            :remediation "Attach a namespaced metadata directive with an ID."
            :loss-risk :approximation)
           diagnostics))
        (loop :while (and stack
                          (>= (parsed-heading-level (first stack))
                              (parsed-heading-level heading)))
              :do (pop stack))
        (if stack
            (progn
              (setf (parsed-heading-parent-id heading)
                    (parsed-heading-id (first stack)))
              (push id (parsed-heading-child-ids (first stack))))
            (push id roots))
        (push heading stack)))
    (dolist (heading headings)
      (let* ((fields (parsed-heading-task-fields heading))
             (node-fields (parsed-heading-node-fields heading))
             (event-fields (parsed-heading-event-fields heading))
             (property-fields (parsed-heading-properties-fields heading))
             (id (parsed-heading-id heading))
             (tag-value (or (and node-fields
                                 (field-value "tags" node-fields))
                            (and fields (field-value "tags" fields))))
             (alias-value (and node-fields
                               (field-value "aliases" node-fields)))
             (aliases (if alias-value
                          (comma-separated-scalars alias-value)
                          nil))
             (references
               (append
                (mapcar
                 (lambda (value)
                   (make-node-reference :kind :citation :value value))
                 (let ((value (and node-fields
                                   (field-value "citation-refs" node-fields))))
                   (if value (comma-separated-scalars value) nil)))
                (mapcar
                 (lambda (value)
                   (make-node-reference :kind :url :value value))
                 (let ((value (and node-fields
                                   (field-value "url-refs" node-fields))))
                   (if value (comma-separated-scalars value) nil)))))
             (tags (if tag-value
                       (comma-separated-scalars tag-value)
                       nil))
             (properties
               (mapcar (lambda (entry)
                         (cons (car entry)
                               (strip-scalar-quotes (cdr entry))))
                       property-fields))
             (calendar-bindings
               (mapcar (lambda (binding-fields)
                         (calendar-binding-from-fields binding-fields id))
                       (nreverse
                        (parsed-heading-calendar-binding-fields heading))))
             (extensions
               (loop :for (name raw) :in
                       (append
                        (list
                         (list "lem-node"
                               (parsed-heading-node-raw heading))
                         (list "lem-task"
                               (parsed-heading-task-raw heading))
                         (list "lem-event"
                               (parsed-heading-event-raw heading))
                         (list "lem-properties"
                               (parsed-heading-properties-raw heading)))
                        (mapcar
                         (lambda (raw)
                           (list "lem-calendar-binding" raw))
                         (nreverse
                          (parsed-heading-calendar-binding-raw heading))))
                     :when raw
                       :collect
                       (make-opaque-extension
                        :namespace (format nil
                                           "urn:lem:lsm:directive:~a" name)
                        :media-type "text/vnd.myst"
                        :owner-id id
                        :raw-value raw
                        :ordering-anchor :after-heading
                        :provenance :local))))
        (push
         (make-semantic-node
          :id id
          :level (parsed-heading-level heading)
          :title (parsed-heading-title heading)
          :body
          (lsm-content-nodes-from-csts
           (nreverse (parsed-heading-body-nodes heading)) source-id)
          :parent-id (parsed-heading-parent-id heading)
          :child-ids (nreverse (parsed-heading-child-ids heading))
          :aliases aliases
          :references references
          :tags tags
          :properties properties
          :event (and event-fields (event-from-fields event-fields))
          :task (and fields (task-from-fields fields))
          :inactive-dates
          (let ((value (and node-fields
                            (field-value "inactive-dates" node-fields))))
            (if value (parse-lsm-recurrence-date-list value) nil))
          :calendar-bindings calendar-bindings
          :span (parsed-heading-span heading)
          :extensions extensions)
         nodes)))
    (values (nreverse nodes) (nreverse roots) diagnostics)))

(defun lsm-document-preamble-content (syntax headings source-id)
  (let ((end (if headings
                 (parsed-heading-start (first headings))
                 (length (lsm-syntax-document-source syntax)))))
    (lsm-content-nodes-from-csts
     (loop :for cst :in (lsm-syntax-document-nodes syntax)
           :when (and (not (eq (cst-node-kind cst) :frontmatter))
                      (<= (cst-node-character-end cst) end))
             :collect cst)
     source-id)))

(defmethod parse-source ((provider lsm-provider) source
                         &key source-id revision)
  (unless (stringp source)
    (model-error :invalid-lsm-source source
                 "LSM provider parses string sources"))
  (require-non-empty-string source-id :invalid-source-id "LSM source ID")
  (require-non-empty-string revision :invalid-source-revision
                            "LSM source revision")
  (multiple-value-bind (syntax headings byte-prefixes)
      (parse-lsm-cst source source-id)
    (multiple-value-bind (nodes roots diagnostics)
        (semantic-nodes-from-lsm
         headings source-id byte-prefixes
         (copy-list (lsm-syntax-document-diagnostics syntax)))
      (let ((document
              (make-semantic-document
               :id (lsm-syntax-document-document-id syntax)
               :source-uri source-id
               :format :lsm
               :profile (lsm-syntax-document-profile syntax)
               :preamble
               (lsm-document-preamble-content syntax headings source-id)
               :nodes nodes
               :root-ids roots
               :newline (lsm-syntax-document-newline syntax)
               :source-revision revision
               :diagnostics diagnostics
               :extensions
               (let ((raw (lsm-extra-frontmatter-raw source)))
                 (if raw (list (make-lsm-frontmatter-extension raw)) nil)))))
        (make-source-snapshot
         :provider provider
         :source-id source-id
         :revision revision
         :document document
         :syntax-tree syntax
         :content-fingerprint (source-content-fingerprint provider source)
         :metadata-fingerprint (source-metadata-fingerprint provider source)
         :diagnostics diagnostics)))))

(defun safe-task-state-p (state)
  (and (non-empty-string-p state)
       (every (lambda (character)
                (or (alphanumericp character)
                    (member character '(#\_ #\- #\+ #\@ #\# #\%))))
              state)))

(defparameter *agenda-note-max-characters* (* 1024 1024))

(defun agenda-note-inactive-timestamp-p (value)
  (and (stringp value)
       (= (length value) 22)
       (char= (char value 0) #\[)
       (char= (char value 5) #\-)
       (char= (char value 8) #\-)
       (char= (char value 11) #\Space)
       (char= (char value 15) #\Space)
       (char= (char value 18) #\:)
       (char= (char value 21) #\])
       (every #'digit-char-p
              (map 'list (lambda (index) (char value index))
                   '(1 2 3 4 6 7 9 10 16 17 19 20)))
       (member (subseq value 12 15)
               '("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
               :test #'string=)
       (handler-case
           (let* ((year (parse-integer value :start 1 :end 5))
                  (month (parse-integer value :start 6 :end 8))
                  (day (parse-integer value :start 9 :end 11))
                  (hour (parse-integer value :start 16 :end 18))
                  (minute (parse-integer value :start 19 :end 21)))
             (and (<= 1 month 12)
                  (<= 1 day (ical-days-in-month year month))
                  (<= 0 hour 23)
                  (<= 0 minute 59)
                  (multiple-value-bind
                        (second decoded-minute decoded-hour decoded-day
                         decoded-month decoded-year weekday)
                      (decode-universal-time
                       (encode-universal-time
                        0 minute hour day month year 0)
                       0)
                    (declare (ignore second decoded-minute decoded-hour))
                    (and (= day decoded-day)
                         (= month decoded-month)
                         (= year decoded-year)
                         (string=
                          (subseq value 12 15)
                          (elt #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
                               weekday))))))
         (error () nil))))

(defun agenda-note-payload-values (payload)
  (unless (and (proper-list-p payload)
               (= (length payload) 4)
               (evenp (length payload))
               (let ((keys (loop :for tail :on payload :by #'cddr
                                 :collect (first tail))))
                 (and (= (length keys) (length (remove-duplicates keys)))
                      (every (lambda (key)
                               (member key '(:timestamp :text)))
                             keys))))
    (model-error :invalid-agenda-note-payload payload
                 "agenda note payload must contain timestamp and text once"))
  (let ((timestamp (getf payload :timestamp))
        (text (getf payload :text)))
    (unless (agenda-note-inactive-timestamp-p timestamp)
      (model-error :invalid-agenda-note-timestamp timestamp
                   "agenda note timestamp must be a real minute-precision inactive timestamp"))
    (unless (and (stringp text)
                 (<= (length text) *agenda-note-max-characters*)
                 (not (find-if (lambda (character)
                                 (or (char= character #\Null)
                                     (char= character #\Return)))
                               text)))
      (model-error :invalid-agenda-note-text :unsafe-text
                   "agenda note text must be bounded LF-only text without NUL"))
    (values (copy-seq timestamp)
            (string-right-trim '(#\Space #\Tab #\Newline) text))))

(defun agenda-note-text-lines (text)
  (if (zerop (length text))
      nil
      (loop :with start = 0
            :for newline = (position #\Newline text :start start)
            :collect (subseq text start (or newline (length text)))
            :while newline
            :do (setf start (1+ newline)))))

(defun render-agenda-note (format timestamp text newline)
  (unless (member format '(:org :lsm))
    (model-error :invalid-agenda-note-format format
                 "agenda note format must be Org or LSM"))
  (let ((lines (agenda-note-text-lines text)))
    (with-output-to-string (stream)
      (format stream "- Note taken on ~a" timestamp)
      (when lines
        (write-string (if (eq format :org) " \\\\" "  ") stream))
      (write-string newline stream)
      (dolist (line lines)
        (write-string "  " stream)
        (write-string line stream)
        (write-string newline stream)))))

(defun lsm-agenda-note-insertion-position (snapshot node)
  (let* ((syntax (source-snapshot-syntax-tree snapshot))
         (source (lsm-syntax-document-source syntax))
         (nodes (lsm-syntax-document-nodes syntax))
         (heading
           (find (source-span-character-start (semantic-node-span node)) nodes
                 :key #'cst-node-character-start :test #'=))
         (known '("lem-node" "lem-event" "lem-task" "lem-properties"
                  "lem-calendar-binding")))
    (unless (and heading (eq :heading (cst-node-kind heading)))
      (model-error :missing-lsm-agenda-note-heading node
                   "LSM agenda note target has no exact heading CST"))
    (loop :for cst :in (rest (member heading nodes :test #'eq))
          :for metadata-p =
            (or (and (eq :raw (cst-node-kind cst))
                     (whitespace-string-p (cst-node-raw cst)))
                (and (eq :directive (cst-node-kind cst))
                     (member (cst-node-name cst) known :test #'string=)))
          :unless metadata-p
            :do (return (cst-node-character-start cst))
          :finally (return (length source)))))

(defun lsm-task-state-edit-plist-p (payload)
  (and (proper-list-p payload)
       (evenp (length payload))
       (let ((keys (loop :for tail :on payload :by #'cddr
                         :collect (first tail))))
         (and (= (length keys)
                 (length (remove-duplicates keys)))
              (every (lambda (key)
                       (member key '(:state :done-p)))
                     keys)))
       (stringp (getf payload :state))))

(defun lsm-task-state-edit-values (payload)
  (cond
    ((stringp payload)
     (values payload nil nil))
    ((lsm-task-state-edit-plist-p payload)
     (let ((done-entry (member :done-p payload)))
       (unless (or (null done-entry)
                   (eq (second done-entry) t)
                   (null (second done-entry)))
         (model-error :invalid-task-completion (second done-entry)
                      "task completion must be boolean"))
       (values (getf payload :state)
               (not (null done-entry))
               (and done-entry (second done-entry)))))
    (t
     (model-error :invalid-task-state-edit payload
                  "task state edit must be a state or state/completion plist"))))

(defun lsm-task-cst-for-node (snapshot node)
  (multiple-value-bind (heading directives)
      (lsm-node-adjacent-metadata snapshot node)
    (declare (ignore heading))
    (find "lem-task" directives :key #'cst-node-name :test #'string=)))

(defun lsm-agenda-planning-date-p (value)
  (and (stringp value)
       (= 10 (length value))
       (char= #\- (char value 4))
       (char= #\- (char value 7))
       (every #'digit-char-p
              (concatenate 'string (subseq value 0 4)
                           (subseq value 5 7) (subseq value 8 10)))
       (let ((year (parse-integer value :start 0 :end 4))
             (month (parse-integer value :start 5 :end 7))
             (day (parse-integer value :start 8 :end 10)))
         (and (plusp year)
              (<= 1 month 12)
              (<= 1 day (ical-days-in-month year month))))))

(defun lsm-agenda-planning-temporal-p (value)
  (or
   (null value)
   (and (temporal-value-p value)
        (let ((local (temporal-value-local-value value)))
          (and (>= (length local) 10)
               (lsm-agenda-planning-date-p (subseq local 0 10))
               (if (eq :date (temporal-value-kind value))
                   (and (eq :date (temporal-value-precision value))
                        (= 10 (length local)))
                   (and (not (eq :date (temporal-value-precision value)))
                        (> (length local) 10)
                        (char= #\T (char local 10)))))))))

(defun lsm-agenda-planning-field (operation-kind)
  (ecase operation-kind
    (:set-task-scheduled "scheduled")
    (:set-task-deadline "deadline")))

(defun lsm-agenda-planning-cookie-field (operation-kind)
  (ecase operation-kind
    (:set-task-scheduled-delay "scheduled-delay")
    (:set-task-deadline-warning "deadline-warning")))

(defun lsm-agenda-planning-cookie-p (value)
  (and (stringp value)
       (> (length value) 2)
       (char= #\- (char value 0))
       (char= #\d (char value (1- (length value))))
       (every #'digit-char-p (subseq value 1 (1- (length value))))))

(defun lsm-task-clock-list-p (value)
  (and (proper-list-p value)
       (<= (length value) +lsm-task-clock-limit+)
       (every #'task-clock-p value)))

(defun lsm-agenda-priority-p (value)
  (or (null value)
      (member value '("A" "B" "C") :test #'string=)))

(defun lsm-agenda-effort-p (value)
  (task-effort-duration-p value))

(defun lsm-agenda-task-planning-value (task operation-kind)
  (ecase operation-kind
    (:set-task-scheduled (task-facet-scheduled task))
    (:set-task-deadline (task-facet-deadline task))))

(defun lsm-agenda-task-planning-cookie (task operation-kind)
  (ecase operation-kind
    (:set-task-scheduled-delay (task-facet-scheduled-delay task))
    (:set-task-deadline-warning (task-facet-deadline-warning task))))

(defun lsm-node-tags-edit-p (tags)
  "Return true when TAGS is a bounded ordered unique LSM tag list."
  (and (proper-list-p tags)
       (<= (length tags) 64)
       (every
        (lambda (tag)
          (and (stringp tag)
               (plusp (length tag))
               (<= (length tag) 128)
               (not
                (find-if
                 (lambda (character)
                   (or (char= character #\Null)
                       (char= character #\Newline)
                       (char= character #\Return)))
                 tag))))
        tags)
       (= (length tags) (length (remove-duplicates tags :test #'string=)))))

(defun lsm-node-tags-directive (snapshot node)
  "Return NODE's authoritative adjacent directive for a tag edit."
  (multiple-value-bind (heading directives)
      (lsm-node-adjacent-metadata snapshot node)
    (declare (ignore heading))
    (let ((eligible
            (remove-if-not
             (lambda (directive)
               (member (cst-node-name directive) '("lem-node" "lem-task")
                       :test #'string=))
             directives)))
      (or
       (find-if
        (lambda (directive)
          (assoc "tags" (cst-node-fields directive) :test #'string=))
        eligible)
       (find "lem-node" eligible :key #'cst-node-name :test #'string=)
       (find "lem-task" eligible :key #'cst-node-name :test #'string=)))))

(defun lsm-node-flagging-removal-patches (snapshot node)
  "Return exact patches removing NODE's local flag and immediate note."
  (multiple-value-bind (heading directives)
      (lsm-node-adjacent-metadata snapshot node)
    (declare (ignore heading))
    (let* ((tags (semantic-node-tags node))
           (properties (semantic-node-properties node))
           (note-entry
             (assoc "THEFLAGGINGNOTE" properties :test #'string-equal))
           (tag-directive (lsm-node-tags-directive snapshot node))
           (property-directives
             (remove-if-not
              (lambda (directive)
                (string= "lem-properties" (cst-node-name directive)))
              directives)))
      (unless (member "FLAGGED" tags :test #'string-equal)
        (model-error :missing-lsm-local-flag (semantic-node-id node)
                     "LSM unflagging requires one local FLAGGED tag"))
      (unless (and note-entry (stringp (cdr note-entry))
                   (plusp (length (cdr note-entry))))
        (model-error :missing-lsm-flagging-note (semantic-node-id node)
                     "LSM unflagging requires an immediate flagging note"))
      (unless (= 1 (length property-directives))
        (model-error :invalid-lsm-flagging-properties property-directives
                     "LSM unflagging requires one adjacent properties directive"))
      (unless tag-directive
        (model-error :missing-lsm-flagging-tag-directive node
                     "LSM unflagging requires an adjacent tag directive"))
      (let* ((property-directive (first property-directives))
             (note-fields
               (remove-if-not
                (lambda (field)
                  (string-equal "THEFLAGGINGNOTE" (car field)))
                (cst-node-fields property-directive)))
             (other-fields
               (remove-if
                (lambda (field)
                  (string-equal "THEFLAGGINGNOTE" (car field)))
                (cst-node-fields property-directive))))
        (unless (= 1 (length note-fields))
          (model-error :duplicate-lsm-flagging-note-fields note-fields
                       "LSM unflagging requires exactly one note field"))
        (sort
         (list
          (list
           (cst-node-character-start tag-directive)
           (cst-node-character-end tag-directive)
           (lsm-transform-directive-fields
            tag-directive
            (list
             (cons "tags"
                   (alexandria:when-let
                       ((remaining
                         (remove "FLAGGED" tags :test #'string-equal)))
                     (render-lsm-string-list remaining))))))
          (list
           (cst-node-character-start property-directive)
           (cst-node-character-end property-directive)
           (if other-fields
               (lsm-transform-directive-fields
                property-directive
                (list (cons (caar note-fields) nil)))
               "")))
         #'< :key #'first)))))

(defun lsm-task-state-patch (directive replacement-state)
  (let ((raw (cst-node-raw directive)))
    (dolist (line (scan-source-lines raw))
      (multiple-value-bind (key value) (simple-field (source-line-text line))
        (when (and key (string= key "state"))
          (let* ((text (source-line-text line))
                 (colon (position #\: text))
                 (value-region (subseq text (1+ colon)))
                 (leading (or (position-if-not #'whitespace-character-p
                                               value-region)
                              (length value-region)))
                 (trailing-end
                   (or (position-if-not #'whitespace-character-p value-region
                                        :from-end t)
                       -1))
                 (local-start (+ (source-line-character-start line)
                                 (1+ colon) leading))
                 (local-end (+ (source-line-character-start line)
                               (1+ colon) (1+ trailing-end)))
                 (old-value (trim-source-space value))
                 (quoted-p
                   (and (>= (length old-value) 2)
                        (member (char old-value 0) '(#\" #\'))
                        (char= (char old-value 0)
                               (char old-value (1- (length old-value))))))
                 (replacement
                   (if quoted-p
                       (format nil "~c~a~c"
                               (char old-value 0) replacement-state
                               (char old-value 0))
                       replacement-state)))
            (when (> local-start local-end)
              (model-error :missing-task-state-value value
                           "lem-task state field has no value"))
            (return-from lsm-task-state-patch
              (values (+ (cst-node-character-start directive) local-start)
                      (+ (cst-node-character-start directive) local-end)
                      replacement))))))
    (model-error :missing-task-state (cst-node-raw directive)
                 "lem-task directive has no state field")))

(defun lsm-new-task-directive-patch (snapshot node state done-p)
  "Return one insertion patch that gives NODE an org/default task facet."
  (let* ((source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree snapshot)))
         (newline (lsm-newline-string (source-newline-style source)))
         (position (lsm-agenda-note-insertion-position snapshot node))
         (prefix
           (if (or (zerop position)
                   (member (char source (1- position))
                           '(#\Newline #\Return)))
               ""
               newline))
         (replacement
           (format nil
                   "~a:::{lem-task}~aworkflow: ~a~astate: ~a~adone: ~:[false~;true~]~a:::~a~a"
                   prefix newline (lsm-quoted-scalar "org/default")
                   newline (lsm-quoted-scalar state) newline done-p
                   newline newline newline)))
    (list position position replacement)))

(defun plan-lsm-ensured-task-state-edit
    (provider snapshot operation node state done-p)
  (let ((directive (lsm-task-cst-for-node snapshot node)))
    (if directive
        (progn
          (unless
              (string= "org/default"
                       (task-facet-workflow-id (semantic-node-task node)))
            (model-error :unsupported-ensured-task-workflow
                         (task-facet-workflow-id (semantic-node-task node))
                         "ensured task state supports only org/default"))
          (plan-source-edit
           provider snapshot
           (make-edit-operation
            :kind :set-task-state
            :target-id (edit-operation-target-id operation)
            :payload (list :state state :done-p done-p))))
        (make-edit-plan
         :provider provider
         :source-id (source-snapshot-source-id snapshot)
         :base-revision (source-snapshot-revision snapshot)
         :base-content-fingerprint
         (source-snapshot-content-fingerprint snapshot)
         :base-metadata-fingerprint
         (source-snapshot-metadata-fingerprint snapshot)
         :operations (list operation)
         :metadata
         (list :patches
               (list
                (lsm-new-task-directive-patch
                 snapshot node state done-p)))))))

(defun lsm-edit-plan-patches (plan)
  (let* ((metadata (edit-plan-metadata plan))
         (patches (getf metadata :patches)))
    (or (and patches (copy-tree patches))
        (let ((start (getf metadata :patch-start))
              (end (getf metadata :patch-end))
              (replacement (getf metadata :replacement)))
          (and (integerp start) (integerp end) (stringp replacement)
               (list (list start end replacement)))))))

(defun plan-lsm-task-state-batch
    (snapshot target-node-ids state &key done-p)
  "Plan one atomic ensured task-state edit for every selected LSM node."
  (unless (and (source-snapshot-p snapshot)
               (typep (source-snapshot-provider snapshot) 'lsm-provider))
    (model-error :invalid-lsm-task-state-batch-snapshot snapshot
                 "task-state batch planning requires an LSM snapshot"))
  (unless (and (proper-list-p target-node-ids) target-node-ids
               (every #'non-empty-string-p target-node-ids))
    (model-error :invalid-lsm-task-state-batch-targets target-node-ids
                 "task-state batch requires a nonempty proper list of node IDs"))
  (unless (= (length target-node-ids)
             (length (remove-duplicates target-node-ids :test #'string=)))
    (model-error :duplicate-lsm-task-state-batch-target target-node-ids
                 "task-state batch must identify each node once"))
  (unless (safe-task-state-p state)
    (model-error :invalid-task-state state
                 "task state must be a safe non-empty workflow token"))
  (unless (or (eq done-p t) (null done-p))
    (model-error :invalid-task-completion done-p
                 "task completion must be boolean"))
  (let ((provider (source-snapshot-provider snapshot))
        (document (source-snapshot-document snapshot))
        (operations nil)
        (patches nil)
        (expected-nodes nil))
    (dolist (target-node-id target-node-ids)
      (let ((node (find-semantic-node document target-node-id)))
        (unless node
          (model-error :missing-lsm-task-state-batch-node target-node-id
                       "task-state batch target does not exist"))
        (let ((task (semantic-node-task node)))
          (when task
            (unless (string= "org/default" (task-facet-workflow-id task))
              (model-error :unsupported-lsm-task-state-batch-workflow
                           (task-facet-workflow-id task)
                           "task-state batch supports only org/default"))))
        (let* ((operation
                 (make-edit-operation
                  :kind :ensure-task-state :target-id target-node-id
                  :payload (list :state state :done-p done-p)))
               (individual
                 (plan-source-edit provider snapshot operation))
               (individual-patches (lsm-edit-plan-patches individual))
               (updated
                 (apply-source-edit
                  provider individual snapshot
                  :new-revision "lsm-task-state-batch/verification"))
               (expected
                 (find-semantic-node
                  (source-snapshot-document updated) target-node-id)))
          (unless (and individual-patches expected)
            (model-error :invalid-lsm-task-state-batch-plan individual
                         "individual task-state edit lacks verified evidence"))
          (push operation operations)
          (setf patches (nconc individual-patches patches))
          (push expected expected-nodes))))
    (setf patches (sort patches #'< :key #'first))
    (let ((cursor 0))
      (dolist (patch patches)
        (destructuring-bind (start end replacement) patch
          (declare (ignore replacement))
          (unless (<= cursor start end)
            (model-error :overlapping-lsm-task-state-batch-patches patches
                         "task-state batch contains overlapping patches"))
          (setf cursor end))))
    (make-edit-plan
     :provider provider
     :source-id (source-snapshot-source-id snapshot)
     :base-revision (source-snapshot-revision snapshot)
     :base-content-fingerprint
     (source-snapshot-content-fingerprint snapshot)
     :base-metadata-fingerprint
     (source-snapshot-metadata-fingerprint snapshot)
     :operations (nreverse operations)
     :metadata (list :patches patches
                     :expected-nodes (nreverse expected-nodes)))))

(defun plan-lsm-task-planning-batch (snapshot operation-kind target-values)
  "Plan one atomic planning-field edit for selected native LSM tasks.

TARGET-VALUES is a nonempty proper list of two-element lists containing a
semantic node ID and the payload for OPERATION-KIND.  Each target must be
unique.  The four supported operation kinds are the existing scheduled,
deadline, scheduled-delay, and deadline-warning source operations."
  (unless (and (source-snapshot-p snapshot)
               (typep (source-snapshot-provider snapshot) 'lsm-provider))
    (model-error :invalid-lsm-task-planning-batch-snapshot snapshot
                 "task planning batch requires an LSM snapshot"))
  (unless (member operation-kind
                  '(:set-task-scheduled :set-task-deadline
                    :set-task-scheduled-delay
                    :set-task-deadline-warning))
    (model-error :invalid-lsm-task-planning-batch-kind operation-kind
                 "task planning batch kind is unsupported"))
  (unless (and (proper-list-p target-values) target-values
               (every
                (lambda (target-value)
                  (and (proper-list-p target-value)
                       (= 2 (length target-value))
                       (non-empty-string-p (first target-value))))
                target-values))
    (model-error :invalid-lsm-task-planning-batch-targets target-values
                 "task planning batch requires node and value pairs"))
  (let ((target-node-ids (mapcar #'first target-values)))
    (unless (= (length target-node-ids)
               (length (remove-duplicates target-node-ids :test #'string=)))
      (model-error :duplicate-lsm-task-planning-batch-target target-node-ids
                   "task planning batch must identify each node once")))
  ;; Retain the provider's exact single-operation plan shape.  Besides being
  ;; smaller, this lets APPLY-SOURCE-EDIT repeat its canonical-plan check for
  ;; ordinary Normal-state edits; only a true multi-target batch needs the
  ;; composed patch and expected-node metadata below.
  (when (null (rest target-values))
    (destructuring-bind (target-node-id value) (first target-values)
      (let ((node
              (find-semantic-node
               (source-snapshot-document snapshot) target-node-id)))
        (unless (and node (semantic-node-task node))
          (model-error :missing-lsm-task-planning-batch-task
                       target-node-id
                       "task planning batch target must identify a task"))
        (return-from plan-lsm-task-planning-batch
          (plan-source-edit
           (source-snapshot-provider snapshot) snapshot
           (make-edit-operation
            :kind operation-kind :target-id target-node-id
            :payload value))))))
  (let ((provider (source-snapshot-provider snapshot))
        (document (source-snapshot-document snapshot))
        (operations nil)
        (patches nil)
        (expected-nodes nil))
    (dolist (target-value target-values)
      (destructuring-bind (target-node-id value) target-value
        (let ((node (find-semantic-node document target-node-id)))
          (unless (and node (semantic-node-task node))
            (model-error :missing-lsm-task-planning-batch-task
                         target-node-id
                         "task planning batch target must identify a task"))
          (let* ((operation
                   (make-edit-operation
                    :kind operation-kind
                    :target-id target-node-id
                    :payload value))
                 (individual
                   (plan-source-edit provider snapshot operation))
                 (individual-patches (lsm-edit-plan-patches individual))
                 (updated
                   (apply-source-edit
                    provider individual snapshot
                    :new-revision "lsm-task-planning-batch/verification"))
                 (expected
                   (find-semantic-node
                    (source-snapshot-document updated) target-node-id)))
            (unless (and individual-patches expected)
              (model-error :invalid-lsm-task-planning-batch-plan individual
                           "individual planning edit lacks verified evidence"))
            (push operation operations)
            (setf patches (nconc individual-patches patches))
            (push expected expected-nodes)))))
    (setf patches (sort patches #'< :key #'first))
    (let ((cursor 0))
      (dolist (patch patches)
        (destructuring-bind (start end replacement) patch
          (declare (ignore replacement))
          (unless (<= cursor start end)
            (model-error :overlapping-lsm-task-planning-batch-patches patches
                         "task planning batch contains overlapping patches"))
          (setf cursor end))))
    (make-edit-plan
     :provider provider
     :source-id (source-snapshot-source-id snapshot)
     :base-revision (source-snapshot-revision snapshot)
     :base-content-fingerprint
     (source-snapshot-content-fingerprint snapshot)
     :base-metadata-fingerprint
     (source-snapshot-metadata-fingerprint snapshot)
     :operations (nreverse operations)
     :metadata (list :patches patches
                     :expected-nodes (nreverse expected-nodes)))))

(defun lsm-node-adjacent-metadata (snapshot node)
  (let* ((nodes
           (lsm-syntax-document-nodes
            (source-snapshot-syntax-tree snapshot)))
         (heading
           (find (source-span-character-start (semantic-node-span node)) nodes
                 :key #'cst-node-character-start :test #'=))
         (known '("lem-node" "lem-event" "lem-task" "lem-properties"
                  "lem-calendar-binding"))
         (directives nil))
    (unless (and heading (eq :heading (cst-node-kind heading)))
      (model-error :missing-lsm-caldav-merge-heading node
                   "LSM merge target has no exact heading CST"))
    (dolist (cst (rest (member heading nodes)))
      (cond
        ((and (eq :raw (cst-node-kind cst))
              (whitespace-string-p (cst-node-raw cst))))
        ((and (eq :directive (cst-node-kind cst))
              (member (cst-node-name cst) known :test #'string=))
         (push cst directives))
        (t (return))))
    (values heading (nreverse directives))))

(defun lsm-event-cst-for-node (snapshot node)
  "Return NODE's sole adjacent lem-event directive."
  (multiple-value-bind (heading directives)
      (lsm-node-adjacent-metadata snapshot node)
    (declare (ignore heading))
    (let ((events
            (remove-if-not
             (lambda (directive)
               (string= "lem-event" (cst-node-name directive)))
             directives)))
      (unless (= 1 (length events))
        (model-error :missing-or-ambiguous-lsm-event-directive
                     (semantic-node-id node)
                     "event interval edit requires one exact lem-event directive"))
      (first events))))

(defun lsm-event-interval-valid-p (start end)
  "Return true for one normalized, compatible, forward event interval."
  (handler-case
      (and
       (temporal-value-p start)
       (progn (ical-recurrence-temporal-key start) t)
       (or
        (null end)
        (and
         (temporal-value-p end)
         (ical-recurrence-compatible-temporal-p start end)
         (< (ical-recurrence-temporal-key start)
            (ical-recurrence-temporal-key end)))))
    (semantic-model-error () nil)))

(defun lsm-event-interval-replacement-p (current replacement)
  "Return true when REPLACEMENT changes only CURRENT's exact interval."
  (and
   (event-facet-p current)
   (event-facet-p replacement)
   (lsm-event-interval-valid-p
    (event-facet-start replacement)
    (event-facet-end replacement))
   (equal (event-facet-duration current)
          (event-facet-duration replacement))
   (equal (event-facet-status current) (event-facet-status replacement))
   (equal (event-facet-location current) (event-facet-location replacement))
   (equal (event-facet-url current) (event-facet-url replacement))
   (eq (event-facet-transparency current)
       (event-facet-transparency replacement))
   (equalp (event-facet-recurrence current)
           (event-facet-recurrence replacement))))

(defun lsm-new-event-interval-p (replacement)
  "Return true for one bounded event created by a timestamp command."
  (and
   (event-facet-p replacement)
   (lsm-event-interval-valid-p
    (event-facet-start replacement)
    (event-facet-end replacement))
   (null (event-facet-duration replacement))
   (null (event-facet-status replacement))
   (null (event-facet-location replacement))
   (null (event-facet-url replacement))
   (null (event-facet-transparency replacement))
   (null (event-facet-recurrence replacement))))

(defun lsm-render-event-directive-source (event newline)
  (with-output-to-string (stream)
    (flet ((emit-line (control &rest arguments)
             (apply #'format stream control arguments)
             (write-string newline stream)))
      (render-lsm-event event #'emit-line))))

(defun lsm-directive-insertion-patch
    (snapshot node directive-source before-names)
  "Return one source-preserving patch for a missing adjacent directive."
  (multiple-value-bind (heading directives)
      (lsm-node-adjacent-metadata snapshot node)
    (let* ((newline
             (lsm-newline-string
              (lsm-syntax-document-newline
               (source-snapshot-syntax-tree snapshot))))
           (before
             (find-if
              (lambda (directive)
                (member (cst-node-name directive) before-names
                        :test #'string=))
              directives))
           (position
             (cond
               (before (cst-node-character-start before))
               (directives (cst-node-character-end (car (last directives))))
               (t (cst-node-character-end heading))))
           (replacement
             (if before
                 (concatenate 'string directive-source newline)
                 (concatenate 'string newline directive-source))))
      (list position position replacement))))

(defun lsm-inactive-date-value-equal-p (left right)
  (or
   (lsm-calendar-temporal-equal-p left right)
   (and
    (recurrence-period-p left)
    (recurrence-period-p right)
    (lsm-calendar-temporal-equal-p
     (recurrence-period-start left) (recurrence-period-start right))
    (lsm-calendar-temporal-equal-p
     (recurrence-period-end left) (recurrence-period-end right))
    (equal (recurrence-period-duration left)
           (recurrence-period-duration right)))))

(defun lsm-inactive-dates-single-edit-p (current replacement)
  "Accept one append or one positional replacement, never a bulk rewrite."
  (and
   (proper-list-p replacement)
   (<= (length replacement) 4096)
   (every (lambda (value)
            (or (temporal-value-p value) (recurrence-period-p value)))
          replacement)
   (cond
     ((= (1+ (length current)) (length replacement))
      (every #'lsm-inactive-date-value-equal-p current replacement))
     ((= (length current) (length replacement))
      (= 1
         (count nil
                (mapcar #'lsm-inactive-date-value-equal-p
                        current replacement))))
     (t nil))))

(defun lsm-heading-insertion-payload-values (payload)
  "Return the persistent ID and task flag from one exact insertion payload."
  (unless (and (proper-list-p payload)
               (= 4 (length payload))
               (let ((keys (loop :for tail :on payload :by #'cddr
                                 :collect (first tail))))
                 (and (= 2 (length (remove-duplicates keys)))
                      (every (lambda (key)
                               (member key '(:new-node-id :task-p)))
                             keys)))
               (member (getf payload :task-p) '(nil t)))
    (model-error :invalid-lsm-heading-insertion-payload payload
                 "heading insertion requires one node ID and boolean task flag"))
  (let ((node-id (getf payload :new-node-id)))
    (unless (safe-persistent-lsm-node-id-p node-id)
      (model-error :invalid-persistent-lsm-node-id node-id
                   "inserted heading ID must be safe bounded single-line text"))
    (values node-id (getf payload :task-p))))

(defun lsm-heading-after-subtree-position (snapshot node)
  "Return the exact source position immediately following NODE's subtree."
  (let* ((document (source-snapshot-document snapshot))
         (nodes (semantic-document-nodes document))
         (tail (member node nodes :test #'eq))
         (level (semantic-node-level node)))
    (unless tail
      (model-error :missing-lsm-heading-insertion-node
                   (semantic-node-id node)
                   "heading insertion target is outside the semantic document"))
    (or (loop :for candidate :in (rest tail)
              :when (<= (semantic-node-level candidate) level)
                :return
                (source-span-character-start (semantic-node-span candidate)))
        (length
         (lsm-syntax-document-source
          (source-snapshot-syntax-tree snapshot))))))

(defun lsm-inserted-heading-node (target node-id task-p)
  (make-semantic-node
   :id node-id
   :level (semantic-node-level target)
   :title ""
   :parent-id (semantic-node-parent-id target)
   :task (and task-p
              (make-task-facet
               :workflow-id "org/default" :state "TODO" :done-p nil))))

(defun lsm-context-edit-payload-values (payload)
  "Return the structural kind, source anchor, and above flag from PAYLOAD."
  (unless (and (proper-list-p payload)
               (= 6 (length payload))
               (let ((keys (loop :for tail :on payload :by #'cddr
                                 :collect (first tail))))
                 (and (= 3 (length (remove-duplicates keys)))
                      (every (lambda (key)
                               (member key '(:kind :anchor-start :above-p)))
                             keys)))
               (member (getf payload :kind) '(:list :table))
               (typep (getf payload :anchor-start) '(integer 0))
               (member (getf payload :above-p) '(nil t)))
    (model-error :invalid-lsm-context-edit-payload payload
                 "context insertion requires kind, source anchor, and boolean above flag"))
  (values (getf payload :kind)
          (getf payload :anchor-start)
          (getf payload :above-p)))

(defun lsm-node-content-nodes (node)
  (remove-if-not #'content-node-p (semantic-node-body node)))

(defun lsm-list-item-at-source-start (node source-start)
  (dolist (content (lsm-node-content-nodes node))
    (when (eq :list (content-node-kind content))
      (dolist (item (content-node-items content))
        (when (= source-start
                 (source-span-character-start (list-item-span item)))
          (return-from lsm-list-item-at-source-start
            (values content item))))))
  (values nil nil))

(defun lsm-table-content-at-source-line (node source-start)
  (find-if
   (lambda (content)
     (and (eq :table (content-node-kind content))
          (let ((span (content-node-span content)))
            (<= (source-span-character-start span)
                source-start
                (source-span-character-end span)))))
   (lsm-node-content-nodes node)))

(defun lsm-source-line-at-start (source source-start)
  (find source-start (scan-source-lines source)
        :key #'source-line-character-start :test #'=))

(defun lsm-list-item-empty-prefix (item)
  (concatenate
   'string
   (if (list-item-ordered-p item)
       (format nil "~d. " (list-item-ordinal item))
       "- ")
   (if (list-item-checkbox item) "[ ] " "")))

(defun lsm-context-list-insertion-spec
    (source node anchor-start above-p newline)
  (multiple-value-bind (content item)
      (lsm-list-item-at-source-start node anchor-start)
    (unless (and content item)
      (model-error :invalid-lsm-list-insertion-anchor anchor-start
                   "list insertion anchor must identify one typed list item"))
    (let* ((span (list-item-span item))
           (line (lsm-source-line-at-start source anchor-start))
           (content-end (and line (source-line-content-end line)))
           (prefix (lsm-list-item-empty-prefix item))
           (position (if above-p anchor-start content-end))
           (replacement (if above-p
                            (concatenate 'string prefix newline)
                            (concatenate 'string newline prefix)))
           (inserted-start (if above-p
                               anchor-start
                               (+ content-end (length newline))))
           (focus-position (+ inserted-start (length prefix))))
      (unless (and line
                   (<= anchor-start content-end (length source)))
        (model-error :invalid-lsm-list-insertion-span span
                     "list insertion anchor has no exact source line"))
      (values position replacement focus-position inserted-start
              (1+ (length (content-node-items content)))
              (if (list-item-checkbox item) :unchecked nil)))))

(defun lsm-table-line-index (content source anchor-start)
  (let* ((span (content-node-span content))
         (lines (scan-source-lines
                 (subseq source
                         (source-span-character-start span)
                         (source-span-character-end span))))
         (relative (- anchor-start
                      (source-span-character-start span))))
    (position relative lines :key #'source-line-character-start :test #'=)))

(defun lsm-table-blank-row (table)
  (format nil "| ~{~a~^ | ~} |"
          (make-list (length (table-data-alignments table))
                     :initial-element "")))

(defun lsm-context-table-insertion-spec
    (source node anchor-start above-p newline)
  (let* ((content (lsm-table-content-at-source-line node anchor-start))
         (table (and content (content-node-table content)))
         (line-index (and content
                          (lsm-table-line-index content source anchor-start))))
    (unless (and table line-index)
      (model-error :invalid-lsm-table-insertion-anchor anchor-start
                   "table insertion anchor must identify one typed GFM table line"))
    (when (and above-p (< line-index 2))
      (model-error :unsupported-lsm-table-schema-insertion anchor-start
                   "GFM cannot insert a data row above its header or delimiter"))
    (let* ((content-span (content-node-span content))
           (table-source
             (subseq source
                     (source-span-character-start content-span)
                     (source-span-character-end content-span)))
           (lines (scan-source-lines table-source))
           (effective-index (if (and (not above-p) (< line-index 2))
                                1
                                line-index))
           (line (nth effective-index lines))
           (line-start (+ (source-span-character-start content-span)
                          (source-line-character-start line)))
           (line-end (+ (source-span-character-start content-span)
                        (source-line-content-end line)))
           (blank (lsm-table-blank-row table))
           (position (if above-p line-start line-end))
           (replacement (if above-p
                            (concatenate 'string blank newline)
                            (concatenate 'string newline blank)))
           (inserted-start (if above-p
                               line-start
                               (+ line-end (length newline)))))
      (values position replacement (+ inserted-start 2) inserted-start
              (1+ (length (table-data-rows table))) nil))))

(defun lsm-checkbox-edit-payload-start (payload)
  (unless (and (proper-list-p payload)
               (= 2 (length payload))
               (eq :item-start (first payload))
               (typep (second payload) '(integer 0)))
    (model-error :invalid-lsm-checkbox-edit-payload payload
                 "checkbox edit requires one exact list-item source start"))
  (second payload))

(defun lsm-context-checkbox-patch (source node item-start)
  (multiple-value-bind (content item)
      (lsm-list-item-at-source-start node item-start)
    (declare (ignore content))
    (unless (and item (member (list-item-checkbox item)
                              '(:unchecked :checked)))
      (model-error :missing-lsm-list-checkbox item-start
                   "checkbox toggle requires a checked or unchecked GFM task item"))
    (let* ((raw (list-item-raw item))
           (opening (search "[" raw))
           (position (and opening (+ item-start opening 1)))
           (expected (if (eq :checked (list-item-checkbox item))
                         :unchecked
                         :checked))
           (replacement (if (eq expected :checked) "x" " ")))
      (unless (and position (< position (length source))
                   (char= #\] (char source (+ position 1))))
        (model-error :invalid-lsm-list-checkbox-source raw
                     "typed checkbox does not retain its exact source cookie"))
      (values position replacement expected))))

(defun lsm-heading-level-shift-payload-values (payload)
  "Return the exact heading starts and direction encoded by PAYLOAD."
  (unless (and (proper-list-p payload)
               (= 4 (length payload))
               (let ((keys (loop :for tail :on payload :by #'cddr
                                 :collect (first tail))))
                 (and (= 2 (length (remove-duplicates keys)))
                      (every (lambda (key)
                               (member key '(:heading-starts :direction)))
                             keys)))
               (proper-list-p (getf payload :heading-starts))
               (getf payload :heading-starts)
               (every (lambda (start) (typep start '(integer 0)))
                      (getf payload :heading-starts))
               (member (getf payload :direction) '(-1 1)))
    (model-error :invalid-lsm-heading-level-shift-payload payload
                 "heading level shift requires exact starts and direction"))
  (let ((starts (getf payload :heading-starts)))
    (unless (and (equal starts (sort (copy-list starts) #'<))
                 (= (length starts)
                    (length (remove-duplicates starts :test #'=))))
      (model-error :invalid-lsm-heading-level-shift-order starts
                   "heading starts must be unique and strictly source ordered"))
    (values starts (getf payload :direction))))

(defun lsm-heading-outline-shape (document)
  "Return the complete source-positioned heading outline of DOCUMENT."
  (mapcar
   (lambda (node)
     (list (source-span-character-start (semantic-node-span node))
           (semantic-node-level node)
           (semantic-node-title node)))
   (semantic-document-nodes document)))

(defun lsm-heading-level-shift-patches
    (snapshot node heading-starts direction)
  "Return exact marker patches and the reparsed outline after a level shift."
  (let* ((document (source-snapshot-document snapshot))
         (source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree snapshot)))
         (nodes
           (mapcar
            (lambda (start)
              (or (find start (semantic-document-nodes document)
                        :key (lambda (candidate)
                               (source-span-character-start
                                (semantic-node-span candidate)))
                        :test #'=)
                  (model-error :missing-lsm-heading-level-shift-target start
                               "heading start does not identify a semantic heading")))
            heading-starts))
         (target-start
           (source-span-character-start (semantic-node-span node))))
    (unless (member target-start heading-starts :test #'=)
      (model-error :invalid-lsm-heading-level-shift-anchor target-start
                   "operation target must be one of the shifted headings"))
    (dolist (candidate nodes)
      (let ((level (semantic-node-level candidate)))
        (unless (if (minusp direction) (> level 1) (< level 6))
          (model-error :unrepresentable-lsm-heading-level-shift
                       (list (semantic-node-id candidate) level direction)
                       "CommonMark heading level must remain between one and six"))))
    (let* ((patches
             (mapcar
              (lambda (candidate)
                (let ((start
                        (source-span-character-start
                         (semantic-node-span candidate))))
                  (unless (and (< start (length source))
                               (char= #\# (char source start)))
                    (model-error :invalid-lsm-heading-marker start
                                 "semantic heading lacks its exact source marker"))
                  (if (plusp direction)
                      (list start start "#")
                      (list start (1+ start) ""))))
              nodes))
           (updated-source (lsm-apply-source-patches source patches))
           (updated
             (parse-source
              (source-snapshot-provider snapshot) updated-source
              :source-id (source-snapshot-source-id snapshot)
              :revision (source-snapshot-revision snapshot))))
      (values patches
              (lsm-heading-outline-shape
               (source-snapshot-document updated))))))

(defun lsm-table-column-shift-payload-values (payload)
  "Return the exact table start, zero-based column, and direction in PAYLOAD."
  (unless (and (proper-list-p payload)
               (= 6 (length payload))
               (let ((keys (loop :for tail :on payload :by #'cddr
                                 :collect (first tail))))
                 (and (= 3 (length (remove-duplicates keys)))
                      (every (lambda (key)
                               (member key '(:table-start :column :direction)))
                             keys)))
               (typep (getf payload :table-start) '(integer 0))
               (typep (getf payload :column) '(integer 0))
               (member (getf payload :direction) '(-1 1)))
    (model-error :invalid-lsm-table-column-shift-payload payload
                 "table column shift requires exact table, column, and direction"))
  (values (getf payload :table-start)
          (getf payload :column)
          (getf payload :direction)))

(defun lsm-table-content-at-source-start (node table-start)
  (find table-start (lsm-node-content-nodes node)
        :key (lambda (content)
               (and (eq :table (content-node-kind content))
                    (source-span-character-start (content-node-span content))))
        :test #'eql))

(defun lsm-table-column-shape (table)
  (list (copy-list (table-data-alignments table))
        (mapcar
         (lambda (row)
           (mapcar #'table-cell-raw (table-row-cells row)))
         (table-data-rows table))))

(defun lsm-swapped-list (values first second)
  (let ((copy (copy-list values)))
    (rotatef (nth first copy) (nth second copy))
    copy))

(defun lsm-table-column-shift-patches
    (source content column direction)
  "Return exact cell patches and expected typed shape for one column move."
  (let* ((table (content-node-table content))
         (columns (length (table-data-alignments table)))
         (target (+ column direction))
         (span (content-node-span content))
         (table-start (source-span-character-start span))
         (table-end (source-span-character-end span)))
    (unless (and (< column columns) (<= 0 target) (< target columns))
      (model-error :unrepresentable-lsm-table-column-shift
                   (list column direction columns)
                   "table column cannot move beyond the GFM schema"))
    (let* ((table-source (subseq source table-start table-end))
           (lines (scan-source-lines table-source))
           (patches nil))
      (unless (= (length lines)
                 (1+ (length (table-data-rows table))))
        (model-error :invalid-lsm-table-column-source table-start
                     "typed GFM table lines do not match their semantic rows"))
      (dolist (line lines)
        (let* ((text (source-line-text line))
               (ranges (table-cell-ranges text)))
          (unless (= columns (length ranges))
            (model-error :invalid-lsm-table-column-source text
                         "GFM table line does not match its schema width"))
          (let* ((left-column (min column target))
                 (right-column (max column target))
                 (left-range (nth left-column ranges))
                 (right-range (nth right-column ranges))
                 (line-start (+ table-start
                                (source-line-character-start line)))
                 (left-start (+ line-start (car left-range)))
                 (left-end (+ line-start (cdr left-range)))
                 (right-start (+ line-start (car right-range)))
                 (right-end (+ line-start (cdr right-range)))
                 (left (subseq source left-start left-end))
                 (right (subseq source right-start right-end)))
            (push (list left-start left-end right) patches)
            (push (list right-start right-end left) patches))))
      (values
       (sort patches #'< :key #'first)
       (list
        (lsm-swapped-list (table-data-alignments table) column target)
        (mapcar
         (lambda (row)
           (lsm-swapped-list
            (mapcar #'table-cell-raw (table-row-cells row)) column target))
         (table-data-rows table)))))))

(defun lsm-table-structure-payload-values (payload)
  "Return the exact table START, AXIS, ACTION, and zero-based INDEX."
  (unless (and (proper-list-p payload)
               (= 8 (length payload))
               (let ((keys (loop :for tail :on payload :by #'cddr
                                 :collect (first tail))))
                 (and (= 4 (length (remove-duplicates keys)))
                      (every (lambda (key)
                               (member key
                                       '(:table-start :axis :action :index)))
                             keys)))
               (typep (getf payload :table-start) '(integer 0))
               (member (getf payload :axis) '(:row :column))
               (member (getf payload :action) '(:insert :delete))
               (typep (getf payload :index) '(integer 0)))
    (model-error :invalid-lsm-table-structure-payload payload
                 "table mutation requires exact table, axis, action, and index"))
  (values (getf payload :table-start)
          (getf payload :axis)
          (getf payload :action)
          (getf payload :index)))

(defun lsm-list-insert-at (values index value)
  (append (subseq values 0 index) (list value) (subseq values index)))

(defun lsm-list-delete-at (values index)
  (append (subseq values 0 index) (subseq values (1+ index))))

(defun lsm-table-pipe-positions (text)
  (loop :for character :across text
        :for index :from 0
        :when (and (char= character #\|)
                   (not (escaped-character-p text index)))
          :collect index))

(defun lsm-table-column-structure-patches
    (source content action index)
  "Return exact column mutation patches and the expected typed table shape."
  (let* ((table (content-node-table content))
         (alignments (table-data-alignments table))
         (columns (length alignments))
         (span (content-node-span content))
         (table-start (source-span-character-start span))
         (table-source
           (subseq source table-start (source-span-character-end span)))
         (lines (scan-source-lines table-source)))
    (unless (and (< index columns)
                 (= (length lines)
                    (1+ (length (table-data-rows table)))))
      (model-error :invalid-lsm-table-column-structure-target
                   (list index columns)
                   "table column mutation requires one existing typed column"))
    (when (and (eq action :delete) (= columns 1))
      (model-error :unrepresentable-lsm-table-column-deletion index
                   "GFM table mutation cannot delete its only column"))
    (let ((patches nil))
      (loop :for line :in lines
            :for line-index :from 0
            :for text = (source-line-text line)
            :for pipes = (lsm-table-pipe-positions text)
            :do
               (unless (= (1+ columns) (length pipes))
                 (model-error :invalid-lsm-table-column-source text
                              "GFM table line does not match its typed schema"))
               (let ((line-start
                       (+ table-start (source-line-character-start line))))
                 (ecase action
                   (:insert
                    (let ((position
                            (+ line-start 1 (nth index pipes))))
                      (push
                       (list position position
                             (if (= line-index 1) " --- |" "  |"))
                       patches)))
                   (:delete
                    (let* ((last-p (= index (1- columns)))
                           (start
                             (+ line-start
                                (if last-p
                                    (nth index pipes)
                                    (1+ (nth index pipes)))))
                           (end
                             (+ line-start
                                (if last-p
                                    (nth (1+ index) pipes)
                                    (1+ (nth (1+ index) pipes))))))
                      (push (list start end "") patches))))))
      (let ((transform
              (if (eq action :insert)
                  (lambda (values value)
                    (lsm-list-insert-at values index value))
                  (lambda (values ignored)
                    (declare (ignore ignored))
                    (lsm-list-delete-at values index)))))
        (values
         (sort patches #'< :key #'first)
         (list
          (funcall transform alignments :default)
          (mapcar
           (lambda (row)
             (funcall transform
                      (mapcar #'table-cell-raw (table-row-cells row)) ""))
           (table-data-rows table))))))))

(defun lsm-table-row-structure-patches
    (source content action index newline)
  "Return one exact data-row mutation patch and the expected table shape."
  (let* ((table (content-node-table content))
         (rows (table-data-rows table))
         (span (content-node-span content))
         (table-start (source-span-character-start span))
         (table-source
           (subseq source table-start (source-span-character-end span)))
         (lines (scan-source-lines table-source)))
    (unless (and (plusp index) (< index (length rows))
                 (= (length lines) (1+ (length rows))))
      (model-error :unrepresentable-lsm-table-row-structure-target index
                   "GFM row mutation requires an existing data row"))
    (let* ((line (nth (1+ index) lines))
           (start (+ table-start (source-line-character-start line)))
           (end (+ table-start (source-line-character-end line)))
           (blank
             (make-list (length (table-data-alignments table))
                        :initial-element ""))
           (expected-rows
             (mapcar
              (lambda (row)
                (mapcar #'table-cell-raw (table-row-cells row)))
              rows)))
      (ecase action
        (:insert
         (values
          (list (list start start
                      (concatenate 'string (lsm-table-blank-row table)
                                   newline)))
          (list (copy-list (table-data-alignments table))
                (lsm-list-insert-at expected-rows index blank))))
        (:delete
         (values
          (list (list start end ""))
          (list (copy-list (table-data-alignments table))
                (lsm-list-delete-at expected-rows index))))))))

(defun lsm-table-structure-patches
    (snapshot content axis action index)
  (let* ((source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree snapshot)))
         (newline
           (lsm-newline-string
            (lsm-syntax-document-newline
             (source-snapshot-syntax-tree snapshot)))))
    (ecase axis
      (:column
       (lsm-table-column-structure-patches source content action index))
      (:row
       (lsm-table-row-structure-patches
        source content action index newline)))))

(defun lsm-structural-move-payload-values (payload)
  "Return the typed structural KIND, source STARTS, and DIRECTION."
  (unless (and (proper-list-p payload)
               (= 6 (length payload))
               (let ((keys (loop :for tail :on payload :by #'cddr
                                 :collect (first tail))))
                 (and (= 3 (length (remove-duplicates keys)))
                      (every (lambda (key)
                               (member key '(:kind :starts :direction)))
                             keys)))
               (member (getf payload :kind) '(:heading :list :table))
               (proper-list-p (getf payload :starts))
               (getf payload :starts)
               (every (lambda (start) (typep start '(integer 0)))
                      (getf payload :starts))
               (member (getf payload :direction) '(-1 1)))
    (model-error :invalid-lsm-structural-move-payload payload
                 "structural move requires a typed kind, source starts, and direction"))
  (let ((starts (getf payload :starts)))
    (unless (and (equal starts (sort (copy-list starts) #'<))
                 (= (length starts)
                    (length (remove-duplicates starts :test #'=))))
      (model-error :invalid-lsm-structural-move-order starts
                   "structural starts must be unique and source ordered"))
    (values (getf payload :kind) starts (getf payload :direction))))

(defun lsm-node-structural-shape (node)
  (list
   (semantic-node-id node)
   (semantic-node-level node)
   (semantic-node-parent-id node)
   (semantic-node-title node)
   (loop :for content :in (lsm-node-content-nodes node)
         :collect
         (case (content-node-kind content)
           (:list
            (list
             :list
             (loop :for item :in (content-node-items content)
                   :collect
                   (list (list-item-raw item)
                         (list-item-ordered-p item)
                         (list-item-ordinal item)
                         (list-item-checkbox item)))))
           (:table
            (list :table
                  (lsm-table-column-shape (content-node-table content))))
           (otherwise
            (list (content-node-kind content) (content-node-raw content)))))))

(defun lsm-document-structural-shape (document)
  (mapcar #'lsm-node-structural-shape
          (semantic-document-nodes document)))

(defun lsm-source-unit-end (starts index fallback)
  (or (nth (1+ index) starts) fallback))

(defun lsm-swap-source-ranges
    (source first-start first-end second-start second-end)
  (unless (and (<= 0 first-start first-end second-start second-end
                   (length source))
               (= first-end second-start))
    (model-error :nonadjacent-lsm-structural-move
                 (list first-start first-end second-start second-end)
                 "structural move ranges must be exact and adjacent"))
  (concatenate
   'string
   (subseq source 0 first-start)
   (subseq source second-start second-end)
   (subseq source first-start first-end)
   (subseq source second-end)))

(defun lsm-selected-consecutive-indices (all-starts selected-starts)
  (let ((indices
          (mapcar
           (lambda (start)
             (or (position start all-starts :test #'=)
                 (model-error :missing-lsm-structural-move-start start
                              "structural start does not identify a typed unit")))
           selected-starts)))
    (unless (loop :for (left right) :on indices
                  :while right
                  :always (= (1+ left) right))
      (model-error :noncontiguous-lsm-structural-move selected-starts
                   "structural move selection must be contiguous"))
    indices))

(defun lsm-heading-structural-move-source
    (snapshot node starts direction source)
  (let* ((document (source-snapshot-document snapshot))
         (nodes (semantic-document-nodes document))
         (selected
           (mapcar
            (lambda (start)
              (or (find start nodes
                        :key (lambda (candidate)
                               (source-span-character-start
                                (semantic-node-span candidate)))
                        :test #'=)
                  (model-error :missing-lsm-heading-move-start start
                               "heading move start is not a semantic heading")))
            starts))
         (level (semantic-node-level (first selected)))
         (parent (semantic-node-parent-id (first selected)))
         (siblings
           (remove-if-not
            (lambda (candidate)
              (and (= level (semantic-node-level candidate))
                   (equal parent (semantic-node-parent-id candidate))))
            nodes))
         (sibling-starts
           (mapcar (lambda (candidate)
                     (source-span-character-start
                      (semantic-node-span candidate)))
                   siblings))
         (indices (lsm-selected-consecutive-indices sibling-starts starts))
         (first-index (first indices))
         (last-index (car (last indices)))
         (neighbor-index (if (minusp direction)
                             (1- first-index)
                             (1+ last-index)))
         (neighbor (and (<= 0 neighbor-index)
                        (nth neighbor-index siblings))))
    (unless (and (member node selected :test #'eq)
                 (every (lambda (candidate)
                          (and (= level (semantic-node-level candidate))
                               (equal parent
                                      (semantic-node-parent-id candidate))))
                        selected))
      (model-error :mixed-lsm-heading-move-selection starts
                   "heading move selection must contain the target and only siblings"))
    (unless neighbor
      (model-error :unrepresentable-lsm-heading-move starts
                   "heading selection cannot move beyond its sibling boundary"))
    (multiple-value-bind (selected-start ignored-first-end)
        (semantic-node-subtree-character-range
         document (first selected) (length source))
      (declare (ignore ignored-first-end))
      (multiple-value-bind (ignored-last-start selected-end)
          (semantic-node-subtree-character-range
           document (car (last selected)) (length source))
        (declare (ignore ignored-last-start))
        (multiple-value-bind (neighbor-start neighbor-end)
            (semantic-node-subtree-character-range
             document neighbor (length source))
          (if (minusp direction)
              (lsm-swap-source-ranges
               source neighbor-start neighbor-end selected-start selected-end)
              (lsm-swap-source-ranges
               source selected-start selected-end neighbor-start neighbor-end)))))))

(defun lsm-content-structural-move-source
    (node kind starts direction source)
  (let* ((content
           (find-if
            (lambda (candidate)
              (and (eq kind (content-node-kind candidate))
                   (member (first starts)
                           (case kind
                             (:list
                              (mapcar
                               (lambda (item)
                                 (source-span-character-start
                                  (list-item-span item)))
                               (content-node-items candidate)))
                             (:table
                              (mapcar
                               (lambda (row)
                                 (source-span-character-start
                                  (table-row-span row)))
                               (table-data-rows
                                (content-node-table candidate)))))
                           :test #'=)))
            (lsm-node-content-nodes node)))
         (units
           (and content
                (ecase kind
                  (:list (content-node-items content))
                  (:table
                   (table-data-rows (content-node-table content))))))
         (all-starts
           (and units
                (mapcar
                 (lambda (unit)
                   (source-span-character-start
                    (ecase kind
                      (:list (list-item-span unit))
                      (:table (table-row-span unit)))))
                 units))))
    (unless content
      (model-error :missing-lsm-content-move-target starts
                   "structural starts do not identify one typed content block"))
    (let* ((indices (lsm-selected-consecutive-indices all-starts starts))
           (first-index (first indices))
           (last-index (car (last indices)))
           (neighbor-index (if (minusp direction)
                               (1- first-index)
                               (1+ last-index))))
      (when (and (eq kind :table)
                 (or (zerop first-index) (zerop neighbor-index)))
        (model-error :unrepresentable-lsm-table-header-move starts
                     "GFM header rows cannot cross the delimiter row"))
      (unless (and (<= 0 neighbor-index) (< neighbor-index (length units)))
        (model-error :unrepresentable-lsm-content-move starts
                     "structural selection cannot move beyond its content boundary"))
      (let* ((content-end
               (source-span-character-end (content-node-span content)))
             (selected-start (nth first-index all-starts))
             (selected-end
               (lsm-source-unit-end all-starts last-index content-end))
             (neighbor-start (nth neighbor-index all-starts))
             (neighbor-end
               (lsm-source-unit-end all-starts neighbor-index content-end)))
        (if (minusp direction)
            (lsm-swap-source-ranges
             source neighbor-start neighbor-end selected-start selected-end)
            (lsm-swap-source-ranges
             source selected-start selected-end neighbor-start neighbor-end))))))

(defun lsm-structural-move-spec
    (snapshot node kind starts direction)
  (let* ((source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree snapshot)))
         (updated-source
           (if (eq kind :heading)
               (lsm-heading-structural-move-source
                snapshot node starts direction source)
               (lsm-content-structural-move-source
                node kind starts direction source)))
         (updated
           (parse-source
            (source-snapshot-provider snapshot) updated-source
            :source-id (source-snapshot-source-id snapshot)
            :revision (source-snapshot-revision snapshot))))
    (multiple-value-bind (start end replacement)
        (minimal-source-replacement source updated-source)
      (values start end replacement
              (lsm-document-structural-shape
               (source-snapshot-document updated))))))

(defun lsm-render-field-value (value kind)
  (ecase kind
    (:quoted (and value (lsm-quoted-scalar value)))
    (:integer (and value (format nil "~d" value)))
    (:boolean (if value "true" "false"))
    (:keyword (and value (string-downcase (symbol-name value))))
    (:temporal
     (and value (lsm-quoted-scalar (render-lsm-temporal value))))
    (:list (and value (render-lsm-string-list value)))))

(defun render-lsm-task-clock (clock)
  (format nil "~a/~a"
          (render-lsm-temporal (task-clock-start clock))
          (or (and (task-clock-end clock)
                   (render-lsm-temporal (task-clock-end clock)))
              "")))

(defun lsm-transform-directive-fields (directive desired)
  "Replace, delete, or insert known fields while retaining unknown raw lines."
  (let* ((raw (cst-node-raw directive))
         (seen (make-hash-table :test #'equal))
         (cursor 0)
         (closing nil))
    (with-output-to-string (stream)
      (dolist (line (scan-source-lines raw))
        (let ((text (source-line-text line)))
          (when (string= (trim-source-space text) ":::")
            (setf closing line))
          (multiple-value-bind (key old-value) (simple-field text)
            (declare (ignore old-value))
            (let ((entry (and key (assoc key desired :test #'string=))))
              (when entry
                (write-string raw stream :start cursor
                              :end (source-line-character-start line))
                (when (cdr entry)
                  (format stream "~a: ~a" key (cdr entry))
                  (write-string raw stream
                                :start (source-line-content-end line)
                                :end (source-line-character-end line)))
                (setf cursor (source-line-character-end line)
                      (gethash key seen) t))))))
      (unless closing
        (model-error :unclosed-lsm-caldav-merge-directive directive
                     "cannot patch an unclosed LSM directive"))
      (write-string raw stream :start cursor
                    :end (source-line-character-start closing))
      (let ((newline (lsm-newline-string (source-newline-style raw))))
        (dolist (entry desired)
          (when (and (cdr entry) (not (gethash (car entry) seen)))
            (format stream "~a: ~a~a" (car entry) (cdr entry) newline))))
      (write-string raw stream :start (source-line-character-start closing)))))

(defun lsm-calendar-directive-desired-fields (name node)
  (cond
    ((string= name "lem-node")
     (list
      (cons "aliases"
            (lsm-render-field-value (semantic-node-aliases node) :list))
      (cons "citation-refs"
            (lsm-render-field-value
             (loop :for reference :in (semantic-node-references node)
                   :when (eq :citation (node-reference-kind reference))
                     :collect (node-reference-value reference))
             :list))
      (cons "url-refs"
            (lsm-render-field-value
             (loop :for reference :in (semantic-node-references node)
                   :when (eq :url (node-reference-kind reference))
                     :collect (node-reference-value reference))
             :list))
      (cons "tags"
            (lsm-render-field-value (semantic-node-tags node) :list))
      (cons "inactive-dates"
            (and (semantic-node-inactive-dates node)
                 (render-lsm-recurrence-date-list
                  (semantic-node-inactive-dates node))))))
    ((string= name "lem-event")
     (let ((event (semantic-node-event node)))
       (list
        (cons "start" (lsm-render-field-value
                       (event-facet-start event) :temporal))
        (cons "end" (lsm-render-field-value
                     (event-facet-end event) :temporal))
        (cons "duration" (lsm-render-field-value
                          (event-facet-duration event) :quoted))
        (cons "status" (lsm-render-field-value
                        (event-facet-status event) :quoted))
        (cons "location" (lsm-render-field-value
                          (event-facet-location event) :quoted))
        (cons "url" (lsm-render-field-value
                     (event-facet-url event) :quoted))
        (cons "transparency" (lsm-render-field-value
                              (event-facet-transparency event) :keyword)))))
    ((string= name "lem-task")
     (let ((task (semantic-node-task node)))
       (list
        (cons "state" (lsm-render-field-value
                       (task-facet-state task) :quoted))
        (cons "done" (lsm-render-field-value
                      (task-facet-done-p task) :boolean))
        (cons "priority" (if (integerp (task-facet-priority task))
                              (lsm-render-field-value
                               (task-facet-priority task) :integer)
                              (lsm-render-field-value
                               (task-facet-priority task) :quoted)))
        (cons "progress" (lsm-render-field-value
                          (task-facet-progress task) :integer))
        (cons "scheduled" (lsm-render-field-value
                           (task-facet-scheduled task) :temporal))
        (cons "deadline" (lsm-render-field-value
                          (task-facet-deadline task) :temporal))
        (cons "closed" (lsm-render-field-value
                        (task-facet-closed task) :temporal))
        (cons "clocks"
              (lsm-render-field-value
               (mapcar #'render-lsm-task-clock (task-facet-logs task))
               :list)))))
    ((string= name "lem-properties")
     (mapcar (lambda (name)
               (cons name
                     (lsm-render-field-value
                      (cdr (assoc name (semantic-node-properties node)
                                  :test #'string=))
                      :quoted)))
             '("icalendar.description" "icalendar.duration"
               "icalendar.location" "icalendar.url")))))

(defun lsm-calendar-projection-patches (snapshot old-node updated-node)
  (multiple-value-bind (heading directives)
      (lsm-node-adjacent-metadata snapshot old-node)
    (let* ((raw (cst-node-raw heading))
           (line (first (scan-source-lines raw)))
           (newline (subseq raw (source-line-content-end line)))
           (heading-replacement
             (format nil "~a ~a~a"
                     (make-string (min 6 (semantic-node-level updated-node))
                                  :initial-element #\#)
                     (semantic-node-title updated-node) newline))
           (patches
             (list (list (cst-node-character-start heading)
                         (cst-node-character-end heading)
                         heading-replacement)))
           (properties nil)
           (last-end (cst-node-character-end heading)))
      (dolist (directive directives)
        (setf last-end (cst-node-character-end directive))
        (let ((desired
                (lsm-calendar-directive-desired-fields
                 (cst-node-name directive) updated-node)))
          (when (string= (cst-node-name directive) "lem-properties")
            (setf properties t))
          (when desired
            (push (list (cst-node-character-start directive)
                        (cst-node-character-end directive)
                        (lsm-transform-directive-fields directive desired))
                  patches))))
      (when (and (not properties) (semantic-node-properties updated-node))
        (let ((newline
                (lsm-newline-string
                 (lsm-syntax-document-newline
                  (source-snapshot-syntax-tree snapshot)))))
          (push
           (list last-end last-end
                 (with-output-to-string (stream)
                   (format stream "~a:::{lem-properties}~a" newline newline)
                   (dolist (property (semantic-node-properties updated-node))
                     (format stream "~a: ~a~a" (car property)
                             (lsm-quoted-scalar (cdr property)) newline))
                   (format stream ":::~a" newline)))
           patches)))
      (sort patches #'< :key #'first))))

(defun make-lsm-calendar-projection-edit-operation (node-id updated-node)
  (unless (and (semantic-node-p updated-node)
               (string= node-id (semantic-node-id updated-node)))
    (model-error :invalid-lsm-calendar-projection updated-node
                 "replacement projection must retain the target node ID"))
  (make-edit-operation
   :kind :replace-calendar-projection :target-id node-id
   :payload updated-node))

(defun lsm-calendar-binding-directive-id (directive)
  (let ((ids nil))
    (dolist (line (scan-source-lines (cst-node-raw directive)))
      (multiple-value-bind (key value)
          (simple-field (source-line-text line))
        (when (and key (string= key "id"))
          (push (strip-scalar-quotes value) ids))))
    (unless (= 1 (length ids))
      (model-error :invalid-lsm-calendar-binding-directive directive
                   "calendar binding directive requires exactly one ID"))
    (first ids)))

(defun lsm-detached-calendar-binding-id (old-node updated-node)
  (let* ((old (semantic-node-calendar-bindings old-node))
         (updated (semantic-node-calendar-bindings updated-node))
         (removed
           (remove-if
            (lambda (binding)
              (find (calendar-binding-id binding) updated
                    :key #'calendar-binding-id :test #'string=))
            old)))
    (unless (and (= 1 (length removed))
                 (= (1- (length old)) (length updated))
                 (every
                  (lambda (binding)
                    (let ((prior
                            (find (calendar-binding-id binding) old
                                  :key #'calendar-binding-id :test #'string=)))
                      (and prior (equalp prior binding))))
                  updated))
      (model-error :invalid-lsm-calendar-binding-detachment updated-node
                   "detachment must remove exactly one unchanged binding"))
    (calendar-binding-id (first removed))))

(defun lsm-calendar-binding-detach-patches (snapshot old-node updated-node)
  (multiple-value-bind (heading directives)
      (lsm-node-adjacent-metadata snapshot old-node)
    (declare (ignore heading))
    (let* ((binding-id
             (lsm-detached-calendar-binding-id old-node updated-node))
           (matches
             (remove-if-not
              (lambda (directive)
                (and (string= (cst-node-name directive)
                              "lem-calendar-binding")
                     (string= (lsm-calendar-binding-directive-id directive)
                              binding-id)))
              directives)))
      (unless (= 1 (length matches))
        (model-error :missing-or-ambiguous-lsm-calendar-binding-directive
                     binding-id
                     "detachment requires one exact binding directive"))
      (let ((directive (first matches)))
        (list (list (cst-node-character-start directive)
                    (cst-node-character-end directive) ""))))))

(defun make-lsm-calendar-binding-detach-operation (node-id updated-node)
  (unless (and (semantic-node-p updated-node)
               (string= node-id (semantic-node-id updated-node)))
    (model-error :invalid-lsm-calendar-binding-detachment updated-node
                 "detached node must retain the target node ID"))
  (make-edit-operation
   :kind :detach-calendar-binding :target-id node-id :payload updated-node))

(defun plan-lsm-calendar-binding-detach (provider snapshot operation node)
  (let ((updated (edit-operation-payload operation)))
    (unless (and (semantic-node-p updated)
                 (string= (semantic-node-id node)
                          (semantic-node-id updated)))
      (model-error :invalid-lsm-calendar-binding-detachment updated
                   "detached replacement does not match its target"))
    (make-edit-plan
     :provider provider :source-id (source-snapshot-source-id snapshot)
     :base-revision (source-snapshot-revision snapshot)
     :base-content-fingerprint (source-snapshot-content-fingerprint snapshot)
     :base-metadata-fingerprint
     (source-snapshot-metadata-fingerprint snapshot)
     :operations (list operation)
     :metadata (list :patches
                     (lsm-calendar-binding-detach-patches
                      snapshot node updated)
                     :expected-node updated))))

(defun plan-lsm-calendar-projection-edit (provider snapshot operation node)
  (let ((updated (edit-operation-payload operation)))
    (unless (and (semantic-node-p updated)
                 (string= (semantic-node-id node)
                          (semantic-node-id updated)))
      (model-error :invalid-lsm-calendar-projection updated
                   "replacement projection does not match its target"))
    (make-edit-plan
     :provider provider :source-id (source-snapshot-source-id snapshot)
     :base-revision (source-snapshot-revision snapshot)
     :base-content-fingerprint (source-snapshot-content-fingerprint snapshot)
     :base-metadata-fingerprint
     (source-snapshot-metadata-fingerprint snapshot)
     :operations (list operation)
     :metadata (list :patches
                     (lsm-calendar-projection-patches snapshot node updated)
                     :expected-node updated))))

(defun plan-lsm-calendar-projection-edits (provider snapshot operations)
  "Compose several independent calendar projection edits against one source."
  (unless (and (typep provider 'lsm-provider)
               (source-snapshot-p snapshot)
               (eq provider (source-snapshot-provider snapshot)))
    (model-error :invalid-lsm-calendar-projection-batch snapshot
                 "calendar projection batch requires its LSM source snapshot"))
  (unless (and (proper-list-p operations) operations
               (every #'edit-operation-p operations))
    (model-error :invalid-lsm-calendar-projection-operations operations
                 "calendar projection batch requires typed operations"))
  (let ((seen (make-hash-table :test #'equal))
        (patches nil)
        (expected-nodes nil))
    (dolist (operation operations)
      (unless (member (edit-operation-kind operation)
                      '(:replace-calendar-projection
                        :detach-calendar-binding))
        (model-error :unsupported-lsm-calendar-projection-operation operation
                     "calendar projection batch contains another edit kind"))
      (let ((target-id (edit-operation-target-id operation)))
        (when (gethash target-id seen)
          (model-error :duplicate-lsm-calendar-projection-target target-id
                       "calendar projection batch edits one node twice"))
        (setf (gethash target-id seen) t))
      (let* ((individual (plan-source-edit provider snapshot operation))
             (metadata (edit-plan-metadata individual))
             (individual-patches (getf metadata :patches))
             (expected (getf metadata :expected-node)))
        (unless (and individual-patches expected)
          (model-error :invalid-lsm-calendar-projection-plan individual
                       "calendar projection operation lacks verified patch evidence"))
        (setf patches (nconc (copy-tree individual-patches) patches))
        (push expected expected-nodes)))
    (setf patches (sort patches #'< :key #'first))
    (let ((cursor 0))
      (dolist (patch patches)
        (destructuring-bind (start end replacement) patch
          (declare (ignore replacement))
          (unless (<= cursor start end)
            (model-error :overlapping-lsm-calendar-projection-patches patches
                         "calendar projection batch contains overlapping patches"))
          (setf cursor end))))
    (make-edit-plan
     :provider provider :source-id (source-snapshot-source-id snapshot)
     :base-revision (source-snapshot-revision snapshot)
     :base-content-fingerprint (source-snapshot-content-fingerprint snapshot)
     :base-metadata-fingerprint
     (source-snapshot-metadata-fingerprint snapshot)
     :operations operations
     :metadata (list :patches patches
                     :expected-nodes (nreverse expected-nodes)))))

(defun lsm-declared-node-id (directive)
  (when directive
    (let ((value (field-value "id" (cst-node-fields directive))))
      (and value (strip-scalar-quotes value)))))

(defun safe-persistent-lsm-node-id-p (value)
  (and (stringp value)
       (plusp (length value))
       (<= (length value) 1024)
       (not (find-if (lambda (character)
                       (or (char= character #\Null)
                           (char= character #\Newline)
                           (char= character #\Return)))
                     value))))

(defun plan-lsm-node-id (snapshot target-node-id &key proposed-id)
  "Return the persistent ID and an optional stale-safe plan that creates it."
  (unless (source-snapshot-p snapshot)
    (model-error :invalid-lsm-snapshot snapshot
                 "node identity planning requires a source snapshot"))
  (let* ((provider (source-snapshot-provider snapshot))
         (document (source-snapshot-document snapshot))
         (node (find-semantic-node document target-node-id)))
    (unless (typep provider 'lsm-provider)
      (model-error :invalid-lsm-provider provider
                   "node identity planning requires an LSM provider"))
    (unless node
      (model-error :missing-lsm-node target-node-id
                   "node identity target does not exist"))
    (multiple-value-bind (heading directives)
        (lsm-node-adjacent-metadata snapshot node)
      (let* ((node-directive
               (find "lem-node" directives :key #'cst-node-name
                     :test #'string=))
             (declared-id (lsm-declared-node-id node-directive)))
        (when (and declared-id (plusp (length declared-id)))
          (return-from plan-lsm-node-id (values declared-id nil)))
        (unless (safe-persistent-lsm-node-id-p proposed-id)
          (model-error :invalid-persistent-lsm-node-id proposed-id
                       "a new node ID must be safe nonempty single-line text of at most 1024 characters"))
        (let ((collision (find-semantic-node document proposed-id)))
          (when (and collision (not (eq collision node)))
            (model-error :duplicate-persistent-lsm-node-id proposed-id
                         "proposed node ID already identifies another node")))
        (let* ((source
                 (lsm-syntax-document-source
                  (source-snapshot-syntax-tree snapshot)))
               (newline
                 (lsm-newline-string (source-newline-style source)))
               (start
                 (if node-directive
                     (cst-node-character-start node-directive)
                     (cst-node-character-end heading)))
               (end
                 (if node-directive
                     (cst-node-character-end node-directive)
                     start))
               (replacement
                 (if node-directive
                     (lsm-transform-directive-fields
                      node-directive
                      (list (cons "id" (lsm-quoted-scalar proposed-id))))
                     (format nil "~a:::{lem-node}~aid: ~a~a:::~a"
                             newline newline (lsm-quoted-scalar proposed-id)
                             newline newline)))
               (operation
                 (make-edit-operation
                  :kind :assign-node-id :target-id target-node-id
                  :payload proposed-id))
               (plan
                 (make-edit-plan
                  :provider provider
                  :source-id (source-snapshot-source-id snapshot)
                  :base-revision (source-snapshot-revision snapshot)
                  :base-content-fingerprint
                  (source-snapshot-content-fingerprint snapshot)
                  :base-metadata-fingerprint
                  (source-snapshot-metadata-fingerprint snapshot)
                  :operations (list operation)
                  :metadata
                  (list :patch-start start :patch-end end
                        :replacement replacement
                        :expected-assigned-id proposed-id
                        :expected-assigned-title
                        (semantic-node-title node)))))
          (values proposed-id plan))))))

(defun plan-lsm-node-id-batch (snapshot target-node-ids proposed-ids)
  "Return persistent IDs and one optional atomic plan for TARGET-NODE-IDS.

PROPOSED-IDS must have one safe, unique candidate for every missing identity;
NIL is accepted only when the corresponding target already carries a
persistent ID.  The returned plan contains only missing-ID insertions, all
computed against the same immutable snapshot."
  (unless (and (source-snapshot-p snapshot)
               (typep (source-snapshot-provider snapshot) 'lsm-provider))
    (model-error :invalid-lsm-node-id-batch-snapshot snapshot
                 "node-ID batch planning requires an LSM snapshot"))
  (unless (and (proper-list-p target-node-ids) target-node-ids
               (every #'non-empty-string-p target-node-ids))
    (model-error :invalid-lsm-node-id-batch-targets target-node-ids
                 "node-ID batch requires a nonempty proper list of node IDs"))
  (unless (and (proper-list-p proposed-ids)
               (= (length target-node-ids) (length proposed-ids))
               (every (lambda (value)
                        (or (null value)
                            (safe-persistent-lsm-node-id-p value)))
                      proposed-ids))
    (model-error :invalid-lsm-node-id-batch-proposals proposed-ids
                 "node-ID batch proposals must be NIL or safe persistent IDs"))
  (unless (= (length target-node-ids)
             (length (remove-duplicates target-node-ids :test #'string=)))
    (model-error :duplicate-lsm-node-id-batch-target target-node-ids
                 "node-ID batch must identify each target once"))
  (let ((non-null-proposals (remove nil proposed-ids)))
    (unless (= (length non-null-proposals)
               (length (remove-duplicates non-null-proposals
                                          :test #'string=)))
      (model-error :duplicate-lsm-node-id-batch-proposal proposed-ids
                   "node-ID batch proposed IDs must be unique")))
  (let ((provider (source-snapshot-provider snapshot))
        (persistent-ids nil)
        (operations nil)
        (patches nil)
        (assigned-identities nil))
    (mapc
     (lambda (target-node-id proposed-id)
       (multiple-value-bind (persistent-id individual)
           (plan-lsm-node-id snapshot target-node-id
                             :proposed-id proposed-id)
         (push persistent-id persistent-ids)
         (when individual
           (let ((individual-patches (lsm-edit-plan-patches individual))
                 (operation (first (edit-plan-operations individual))))
             (unless (and individual-patches operation)
               (model-error :invalid-lsm-node-id-batch-plan individual
                            "individual node-ID edit lacks patch evidence"))
             (setf patches (nconc individual-patches patches))
             (push operation operations)
             (push (cons persistent-id
                         (getf (edit-plan-metadata individual)
                               :expected-assigned-title))
                   assigned-identities)))))
     target-node-ids proposed-ids)
    (setf persistent-ids (nreverse persistent-ids))
    (unless patches
      (return-from plan-lsm-node-id-batch
        (values persistent-ids nil)))
    (setf patches (sort patches #'< :key #'first))
    (let ((cursor 0))
      (dolist (patch patches)
        (destructuring-bind (start end replacement) patch
          (declare (ignore replacement))
          (unless (<= cursor start end)
            (model-error :overlapping-lsm-node-id-batch-patches patches
                         "node-ID batch contains overlapping patches"))
          (setf cursor end))))
    (values
     persistent-ids
     (make-edit-plan
      :provider provider
      :source-id (source-snapshot-source-id snapshot)
      :base-revision (source-snapshot-revision snapshot)
      :base-content-fingerprint
      (source-snapshot-content-fingerprint snapshot)
      :base-metadata-fingerprint
      (source-snapshot-metadata-fingerprint snapshot)
      :operations (nreverse operations)
      :metadata (list :patches patches
                      :expected-assigned-identities
                      (nreverse assigned-identities))))))

(defmethod plan-source-edit ((provider lsm-provider) snapshot operation
                             &key &allow-other-keys)
  (unless (and (source-snapshot-p snapshot)
               (eq provider (source-snapshot-provider snapshot)))
    (error 'source-adapter-error
           :provider provider
           :message "LSM snapshot belongs to a different provider"))
  (unless (edit-operation-p operation)
    (model-error :invalid-edit-operation operation
                 "LSM edit must be an edit operation"))
  (let ((node (find-semantic-node (source-snapshot-document snapshot)
                                  (edit-operation-target-id operation))))
    (case (edit-operation-kind operation)
      (:append-archived-subtree
       (make-archive-destination-plan
        provider snapshot operation
        (lsm-syntax-document-source
         (source-snapshot-syntax-tree snapshot))))
      (:move-node-subtree
       (let* ((document (source-snapshot-document snapshot))
              (target-id (edit-operation-payload operation))
              (target (and (stringp target-id)
                           (find-semantic-node document target-id)))
              (source
                (lsm-syntax-document-source
                 (source-snapshot-syntax-tree snapshot))))
         (unless (and node target)
           (model-error :invalid-lsm-subtree-move
                        (list (edit-operation-target-id operation) target-id)
                        "LSM subtree move requires existing source and target nodes"))
         (multiple-value-bind (updated-source source-start source-end
                               target-start target-end)
             (move-semantic-subtree-source
              document source node target #\# :max-level 6)
           (multiple-value-bind (patch-start patch-end replacement)
               (minimal-source-replacement source updated-source)
             (let ((delta (- 2 (semantic-node-level node))))
               (make-edit-plan
                :provider provider
                :source-id (source-snapshot-source-id snapshot)
                :base-revision (source-snapshot-revision snapshot)
                :base-content-fingerprint
                (source-snapshot-content-fingerprint snapshot)
                :base-metadata-fingerprint
                (source-snapshot-metadata-fingerprint snapshot)
                :operations (list operation)
                :metadata
                (list
                 :patch-start patch-start :patch-end patch-end
                 :replacement replacement
                 :source-subtree-start source-start
                 :source-subtree-end source-end
                 :target-subtree-start target-start
                 :target-subtree-end target-end
                 :expected-moved-nodes
                 (loop :for candidate :in
                         (semantic-node-subtree-nodes document node)
                       :collect
                       (list (semantic-node-id candidate)
                             (+ delta (semantic-node-level candidate))
                             (if (eq candidate node)
                                 target-id
                                 (semantic-node-parent-id candidate)))))))))))
      (:delete-node-subtree
       (unless (and node (null (edit-operation-payload operation)))
         (model-error :invalid-lsm-subtree-deletion
                      (edit-operation-target-id operation)
                      "LSM subtree deletion requires an existing node and NIL payload"))
       (let* ((document (source-snapshot-document snapshot))
              (source
                (lsm-syntax-document-source
                 (source-snapshot-syntax-tree snapshot))))
         (multiple-value-bind (start end)
             (semantic-node-subtree-character-range
              document node (length source))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start start :patch-end end :replacement ""
             :deleted-source (subseq source start end)
             :expected-deleted-node-ids
             (loop :for candidate :in (semantic-document-nodes document)
                   :for candidate-start :=
                     (source-span-character-start
                      (semantic-node-span candidate))
                   :when (<= start candidate-start (1- end))
                     :collect (semantic-node-id candidate)))))))
      (:insert-heading-after-subtree
       (unless node
         (model-error :missing-lsm-heading-insertion-target
                      (edit-operation-target-id operation)
                      "heading insertion target must identify an LSM node"))
       (multiple-value-bind (node-id task-p)
           (lsm-heading-insertion-payload-values
            (edit-operation-payload operation))
         (when (find-semantic-node
                (source-snapshot-document snapshot) node-id)
           (model-error :duplicate-persistent-lsm-node-id node-id
                        "inserted heading ID already identifies a node"))
         (let* ((source
                  (lsm-syntax-document-source
                   (source-snapshot-syntax-tree snapshot)))
                (newline-style
                  (lsm-syntax-document-newline
                   (source-snapshot-syntax-tree snapshot)))
                (newline (lsm-newline-string newline-style))
                (inserted (lsm-inserted-heading-node node node-id task-p))
                (position
                  (lsm-heading-after-subtree-position snapshot node))
                (rendered
                  (render-lsm-node
                   inserted :newline newline-style))
                (replacement
                  (if (or (zerop position)
                          (char= #\Newline (char source (1- position))))
                      rendered
                      (concatenate 'string newline rendered))))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list :patch-start position :patch-end position
                  :replacement replacement
                  :expected-inserted-heading
                  (list node-id
                        (semantic-node-level inserted)
                        (semantic-node-parent-id inserted)
                        task-p))))))
      (:insert-context-line
       (unless node
         (model-error :missing-lsm-context-edit-target
                      (edit-operation-target-id operation)
                      "context insertion target must identify an LSM node"))
       (multiple-value-bind (kind anchor-start above-p)
           (lsm-context-edit-payload-values
            (edit-operation-payload operation))
         (let* ((source
                  (lsm-syntax-document-source
                   (source-snapshot-syntax-tree snapshot)))
                (newline
                  (lsm-newline-string
                   (lsm-syntax-document-newline
                    (source-snapshot-syntax-tree snapshot)))))
           (multiple-value-bind
                 (patch-start replacement focus-position inserted-start
                  expected-count expected-checkbox)
               (ecase kind
                 (:list
                  (lsm-context-list-insertion-spec
                   source node anchor-start above-p newline))
                 (:table
                  (lsm-context-table-insertion-spec
                   source node anchor-start above-p newline)))
             (make-edit-plan
              :provider provider
              :source-id (source-snapshot-source-id snapshot)
              :base-revision (source-snapshot-revision snapshot)
              :base-content-fingerprint
              (source-snapshot-content-fingerprint snapshot)
              :base-metadata-fingerprint
              (source-snapshot-metadata-fingerprint snapshot)
              :operations (list operation)
              :metadata
              (list :patch-start patch-start :patch-end patch-start
                    :replacement replacement
                    :focus-position focus-position
                    :expected-context-line
                    (list kind inserted-start expected-count
                          expected-checkbox)))))))
      (:toggle-list-checkbox
       (unless node
         (model-error :missing-lsm-checkbox-edit-target
                      (edit-operation-target-id operation)
                      "checkbox toggle target must identify an LSM node"))
       (let* ((source
                (lsm-syntax-document-source
                 (source-snapshot-syntax-tree snapshot)))
              (item-start
                (lsm-checkbox-edit-payload-start
                 (edit-operation-payload operation))))
         (multiple-value-bind (position replacement expected)
             (lsm-context-checkbox-patch source node item-start)
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list :patch-start position :patch-end (1+ position)
                  :replacement replacement
                  :focus-position item-start
                  :expected-checkbox (list item-start expected))))))
      (:shift-heading-levels
       (unless node
         (model-error :missing-lsm-heading-level-shift-node
                      (edit-operation-target-id operation)
                      "heading level shift target must identify an LSM node"))
       (multiple-value-bind (heading-starts direction)
           (lsm-heading-level-shift-payload-values
            (edit-operation-payload operation))
         (multiple-value-bind (patches expected-outline)
             (lsm-heading-level-shift-patches
              snapshot node heading-starts direction)
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list :patches patches
                  :expected-heading-outline expected-outline)))))
      (:move-table-column
       (unless node
         (model-error :missing-lsm-table-column-shift-node
                      (edit-operation-target-id operation)
                      "table column shift target must identify an LSM node"))
       (multiple-value-bind (table-start column direction)
           (lsm-table-column-shift-payload-values
            (edit-operation-payload operation))
         (let* ((content
                  (lsm-table-content-at-source-start node table-start))
                (source
                  (lsm-syntax-document-source
                   (source-snapshot-syntax-tree snapshot))))
           (unless content
             (model-error :missing-lsm-table-column-shift-target table-start
                          "table start does not identify a typed GFM table"))
           (multiple-value-bind (patches expected-shape)
               (lsm-table-column-shift-patches
                source content column direction)
             (make-edit-plan
              :provider provider
              :source-id (source-snapshot-source-id snapshot)
              :base-revision (source-snapshot-revision snapshot)
              :base-content-fingerprint
              (source-snapshot-content-fingerprint snapshot)
              :base-metadata-fingerprint
              (source-snapshot-metadata-fingerprint snapshot)
              :operations (list operation)
              :metadata
              (list :patches patches
                    :expected-table-column-shape
                    (list table-start expected-shape)))))))
      (:mutate-table-structure
       (unless node
         (model-error :missing-lsm-table-structure-node
                      (edit-operation-target-id operation)
                      "table mutation target must identify an LSM node"))
       (multiple-value-bind (table-start axis action index)
           (lsm-table-structure-payload-values
            (edit-operation-payload operation))
         (let ((content
                 (lsm-table-content-at-source-start node table-start)))
           (unless content
             (model-error :missing-lsm-table-structure-target table-start
                          "table start does not identify a typed GFM table"))
           (multiple-value-bind (patches expected-shape)
               (lsm-table-structure-patches
                snapshot content axis action index)
             (make-edit-plan
              :provider provider
              :source-id (source-snapshot-source-id snapshot)
              :base-revision (source-snapshot-revision snapshot)
              :base-content-fingerprint
              (source-snapshot-content-fingerprint snapshot)
              :base-metadata-fingerprint
              (source-snapshot-metadata-fingerprint snapshot)
              :operations (list operation)
              :metadata
              (list :patches patches
                    :expected-table-structure-shape
                    (list table-start expected-shape)))))))
      (:move-structural-unit
       (unless node
         (model-error :missing-lsm-structural-move-node
                      (edit-operation-target-id operation)
                      "structural move target must identify an LSM node"))
       (multiple-value-bind (kind starts direction)
           (lsm-structural-move-payload-values
            (edit-operation-payload operation))
         (multiple-value-bind (start end replacement expected-shape)
             (lsm-structural-move-spec
              snapshot node kind starts direction)
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list :patch-start start :patch-end end
                  :replacement replacement
                  :expected-structural-shape expected-shape)))))
      (:set-event-interval
       (let ((replacement (edit-operation-payload operation))
             (current (and node (semantic-node-event node))))
         (unless node
           (model-error :missing-lsm-event-node
                        (edit-operation-target-id operation)
                        "LSM event interval target must identify a node"))
         (unless (if current
                     (lsm-event-interval-replacement-p current replacement)
                     (lsm-new-event-interval-p replacement))
           (model-error :invalid-lsm-event-interval-replacement replacement
                        "LSM event interval edit may change only start and end"))
         (let* ((directive (and current (lsm-event-cst-for-node snapshot node)))
                (patch
                  (if directive
                      (list
                       (cst-node-character-start directive)
                       (cst-node-character-end directive)
                       (lsm-transform-directive-fields
                        directive
                        (list
                         (cons "start"
                               (lsm-render-field-value
                                (event-facet-start replacement) :temporal))
                         (cons "end"
                               (lsm-render-field-value
                                (event-facet-end replacement) :temporal)))))
                      (let ((newline
                              (lsm-newline-string
                               (lsm-syntax-document-newline
                                (source-snapshot-syntax-tree snapshot)))))
                        (lsm-directive-insertion-patch
                         snapshot node
                         (lsm-render-event-directive-source replacement newline)
                         '("lem-task" "lem-properties"
                           "lem-calendar-binding"))))))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start (first patch)
             :patch-end (second patch)
             :replacement (third patch)
             :expected-event-interval-present t
             :expected-event replacement)))))
      (:set-inactive-dates
       (let ((replacement (edit-operation-payload operation)))
         (unless node
           (model-error :missing-lsm-inactive-date-node
                        (edit-operation-target-id operation)
                        "LSM inactive-date target must identify a node"))
         (unless (lsm-inactive-dates-single-edit-p
                  (semantic-node-inactive-dates node) replacement)
           (model-error :invalid-lsm-inactive-date-replacement replacement
                        "LSM inactive-date edit must append or replace one typed value"))
         (multiple-value-bind (heading directives)
             (lsm-node-adjacent-metadata snapshot node)
           (declare (ignore heading))
           (let* ((directive
                    (find "lem-node" directives :key #'cst-node-name
                          :test #'string=))
                  (rendered
                    (render-lsm-recurrence-date-list replacement))
                  (patch
                    (if directive
                        (list
                         (cst-node-character-start directive)
                         (cst-node-character-end directive)
                         (lsm-transform-directive-fields
                          directive (list (cons "inactive-dates" rendered))))
                        (let* ((newline
                                 (lsm-newline-string
                                  (lsm-syntax-document-newline
                                   (source-snapshot-syntax-tree snapshot))))
                               (source
                                 (format nil
                                         ":::{lem-node}~ainactive-dates: ~a~a:::~a"
                                         newline rendered newline newline)))
                          (lsm-directive-insertion-patch
                           snapshot node source
                           '("lem-event" "lem-task" "lem-properties"
                             "lem-calendar-binding"))))))
             (make-edit-plan
              :provider provider
              :source-id (source-snapshot-source-id snapshot)
              :base-revision (source-snapshot-revision snapshot)
              :base-content-fingerprint
              (source-snapshot-content-fingerprint snapshot)
              :base-metadata-fingerprint
              (source-snapshot-metadata-fingerprint snapshot)
              :operations (list operation)
              :metadata
              (list
               :patch-start (first patch)
               :patch-end (second patch)
               :replacement (third patch)
               :expected-inactive-dates-present t
               :expected-inactive-dates replacement))))))
      (:replace-calendar-projection
       (unless node
         (model-error :missing-lsm-caldav-merge-node
                      (edit-operation-target-id operation)
                      "CalDAV merge target does not exist"))
       (plan-lsm-calendar-projection-edit provider snapshot operation node))
      (:detach-calendar-binding
       (unless node
         (model-error :missing-lsm-caldav-merge-node
                      (edit-operation-target-id operation)
                      "CalDAV detachment target does not exist"))
       (plan-lsm-calendar-binding-detach
        provider snapshot operation node))
      (:set-task-state
       (multiple-value-bind (state done-present-p done-p)
           (lsm-task-state-edit-values (edit-operation-payload operation))
         (unless (safe-task-state-p state)
           (model-error :invalid-task-state state
                        "task state must be a safe non-empty workflow token"))
         (unless (and node (semantic-node-task node))
           (model-error :missing-task-node (edit-operation-target-id operation)
                        "edit target must identify an LSM task node"))
         (let ((directive (lsm-task-cst-for-node snapshot node)))
           (unless directive
             (model-error :missing-task-directive (semantic-node-id node)
                          "task node has no adjacent lem-task directive"))
           (let ((metadata
                   (if done-present-p
                       (list
                        :patches
                        (list
                         (list
                          (cst-node-character-start directive)
                          (cst-node-character-end directive)
                          (lsm-transform-directive-fields
                           directive
                           (list
                            (cons "state" state)
                            (cons "done" (if done-p "true" "false"))))))
                        :expected-task-state state
                        :expected-task-done-p done-p
                        :expected-task-done-p-present t)
                       (multiple-value-bind
                             (patch-start patch-end replacement)
                           (lsm-task-state-patch directive state)
                         (list :patch-start patch-start
                               :patch-end patch-end
                               :replacement replacement
                               :expected-task-state state)))))
             (make-edit-plan
              :provider provider
              :source-id (source-snapshot-source-id snapshot)
              :base-revision (source-snapshot-revision snapshot)
              :base-content-fingerprint
              (source-snapshot-content-fingerprint snapshot)
              :base-metadata-fingerprint
              (source-snapshot-metadata-fingerprint snapshot)
              :operations (list operation)
              :metadata metadata)))))
      (:set-task-priority
       (let ((priority (edit-operation-payload operation)))
         (unless (lsm-agenda-priority-p priority)
           (model-error :invalid-lsm-agenda-priority priority
                        "LSM agenda priority must be A B C or NIL"))
         (unless (and node (semantic-node-task node))
           (model-error :missing-lsm-agenda-priority-task
                        (edit-operation-target-id operation)
                        "LSM priority target must identify a task"))
         (let ((directive (lsm-task-cst-for-node snapshot node)))
           (unless directive
             (model-error :missing-task-directive (semantic-node-id node)
                          "task node has no adjacent lem-task directive"))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start (cst-node-character-start directive)
             :patch-end (cst-node-character-end directive)
             :replacement
             (lsm-transform-directive-fields
              directive
              (list
               (cons "priority"
                     (and priority
                          (lsm-render-field-value priority :quoted)))))
             :expected-priority-present t
             :expected-priority priority)))))
      (:set-task-effort
       (let ((effort (edit-operation-payload operation)))
         (unless (lsm-agenda-effort-p effort)
           (model-error :invalid-lsm-agenda-effort effort
                        "LSM agenda Effort must use one frozen duration form"))
         (unless (and node (semantic-node-task node))
           (model-error :missing-lsm-agenda-effort-task
                        (edit-operation-target-id operation)
                        "LSM Effort target must identify a task"))
         (let ((directive (lsm-task-cst-for-node snapshot node)))
           (unless directive
             (model-error :missing-task-directive (semantic-node-id node)
                          "task node has no adjacent lem-task directive"))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start (cst-node-character-start directive)
             :patch-end (cst-node-character-end directive)
             :replacement
             (lsm-transform-directive-fields
              directive
              (list
               (cons "effort" (lsm-render-field-value effort :quoted))))
             :expected-effort-present t
             :expected-effort effort)))))
      (:set-task-clocks
       (let ((clocks (edit-operation-payload operation)))
         (unless (lsm-task-clock-list-p clocks)
           (model-error :invalid-lsm-task-clocks clocks
                        "LSM task clocks must be a bounded typed list"))
         (unless (and node (semantic-node-task node))
           (model-error :missing-lsm-task-clock-task
                        (edit-operation-target-id operation)
                        "LSM clock target must identify a task"))
         (let ((directive (lsm-task-cst-for-node snapshot node)))
           (unless directive
             (model-error :missing-task-directive (semantic-node-id node)
                          "clock target has no adjacent lem-task directive"))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start (cst-node-character-start directive)
             :patch-end (cst-node-character-end directive)
             :replacement
             (lsm-transform-directive-fields
              directive
              (list
               (cons
                "clocks"
                (lsm-render-field-value
                 (mapcar #'render-lsm-task-clock clocks) :list))))
             :expected-task-clocks-present t
             :expected-task-clocks (copy-list clocks))))))
      ((:set-task-scheduled :set-task-deadline)
       (let* ((kind (edit-operation-kind operation))
              (temporal (edit-operation-payload operation)))
         (unless (lsm-agenda-planning-temporal-p temporal)
           (model-error :invalid-lsm-agenda-planning-value temporal
                        "LSM agenda planning requires a real all-day date or NIL"))
         (unless (and node (semantic-node-task node))
           (model-error :missing-lsm-agenda-planning-task
                        (edit-operation-target-id operation)
                        "LSM agenda planning target must identify a task"))
         (let ((directive (lsm-task-cst-for-node snapshot node))
               (field (lsm-agenda-planning-field kind))
               (cookie-field
                 (ecase kind
                   (:set-task-scheduled "scheduled-delay")
                   (:set-task-deadline "deadline-warning"))))
           (unless directive
             (model-error :missing-task-directive (semantic-node-id node)
                          "task node has no adjacent lem-task directive"))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start (cst-node-character-start directive)
             :patch-end (cst-node-character-end directive)
             :replacement
             (lsm-transform-directive-fields
              directive
              (if temporal
                  (list
                   (cons field
                         (lsm-render-field-value temporal :temporal)))
                  ;; A delay/warning has no meaning without its planning
                  ;; temporal.  Removing the field therefore removes its
                  ;; dependent cookie in the same exact source patch.
                  (list (cons field nil) (cons cookie-field nil))))
             :expected-planning-present t
             :expected-planning-kind kind
             :expected-planning-value temporal)))))
      ((:set-task-scheduled-delay :set-task-deadline-warning)
       (let* ((kind (edit-operation-kind operation))
              (cookie (edit-operation-payload operation)))
         (unless (lsm-agenda-planning-cookie-p cookie)
           (model-error :invalid-lsm-agenda-planning-cookie cookie
                        "LSM planning cookie requires a non-negative day offset"))
         (unless (and node (semantic-node-task node)
                      (lsm-agenda-task-planning-value
                       (semantic-node-task node)
                       (ecase kind
                         (:set-task-scheduled-delay :set-task-scheduled)
                         (:set-task-deadline-warning :set-task-deadline))))
           (model-error :missing-lsm-agenda-planning-cookie-task
                        (edit-operation-target-id operation)
                        "LSM planning cookie requires an existing planning date"))
         (let ((directive (lsm-task-cst-for-node snapshot node))
               (field (lsm-agenda-planning-cookie-field kind)))
           (unless directive
             (model-error :missing-task-directive (semantic-node-id node)
                          "task node has no adjacent lem-task directive"))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start (cst-node-character-start directive)
             :patch-end (cst-node-character-end directive)
             :replacement
             (lsm-transform-directive-fields
              directive (list (cons field cookie)))
             :expected-planning-cookie-present t
             :expected-planning-cookie-kind kind
             :expected-planning-cookie cookie)))))
      (:set-node-tags
       (let ((tags (edit-operation-payload operation)))
         (unless (lsm-node-tags-edit-p tags)
           (model-error :invalid-lsm-node-tags tags
                        "LSM tag edit requires bounded ordered unique tags"))
         (unless node
           (model-error :missing-lsm-tag-node
                        (edit-operation-target-id operation)
                        "LSM tag target does not exist"))
         (let ((directive (lsm-node-tags-directive snapshot node)))
           (unless directive
             (model-error :missing-lsm-tag-directive
                          (semantic-node-id node)
                          "LSM tag target has no adjacent lem-node or lem-task directive"))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list
             :patch-start (cst-node-character-start directive)
             :patch-end (cst-node-character-end directive)
             :replacement
             (lsm-transform-directive-fields
              directive
              (list
               (cons "tags"
                     (and tags (render-lsm-string-list tags)))))
             :expected-node-tags-present t
             :expected-node-tags (mapcar #'copy-seq tags))))))
      (:remove-node-flagging
       (unless (and node (null (edit-operation-payload operation)))
         (model-error :invalid-lsm-flagging-removal operation
                      "LSM unflagging requires an existing node and NIL payload"))
       (make-edit-plan
        :provider provider
        :source-id (source-snapshot-source-id snapshot)
        :base-revision (source-snapshot-revision snapshot)
        :base-content-fingerprint
        (source-snapshot-content-fingerprint snapshot)
        :base-metadata-fingerprint
        (source-snapshot-metadata-fingerprint snapshot)
        :operations (list operation)
        :metadata
        (list :patches (lsm-node-flagging-removal-patches snapshot node)
              :expected-flagging-removed t)))
      (:ensure-task-state
       (multiple-value-bind (state done-present-p done-p)
           (lsm-task-state-edit-values (edit-operation-payload operation))
         (unless (and done-present-p (safe-task-state-p state))
           (model-error :invalid-ensured-task-state
                        (edit-operation-payload operation)
                        "ensured task state requires a safe state and explicit completion"))
         (unless node
           (model-error :missing-task-node (edit-operation-target-id operation)
                        "ensured task target must identify an LSM heading"))
         (plan-lsm-ensured-task-state-edit
          provider snapshot operation node state done-p)))
      (:add-agenda-note
       (unless node
         (model-error :missing-lsm-agenda-note-node
                      (edit-operation-target-id operation)
                      "agenda note target must identify an LSM heading"))
       (multiple-value-bind (timestamp text)
           (agenda-note-payload-values (edit-operation-payload operation))
         (let* ((source
                  (lsm-syntax-document-source
                   (source-snapshot-syntax-tree snapshot)))
                (newline (lsm-newline-string (source-newline-style source)))
                (position (lsm-agenda-note-insertion-position snapshot node))
                (prefix
                  (if (or (zerop position)
                          (member (char source (1- position))
                                  '(#\Newline #\Return)))
                      ""
                      newline))
                (replacement
                  (concatenate
                   'string prefix
                   (render-agenda-note :lsm timestamp text newline))))
           (make-edit-plan
            :provider provider
            :source-id (source-snapshot-source-id snapshot)
            :base-revision (source-snapshot-revision snapshot)
            :base-content-fingerprint
            (source-snapshot-content-fingerprint snapshot)
            :base-metadata-fingerprint
            (source-snapshot-metadata-fingerprint snapshot)
            :operations (list operation)
            :metadata
            (list :patch-start position :patch-end position
                  :replacement replacement
                  :expected-agenda-note-title (semantic-node-title node))))))
      (otherwise
       (error 'unsupported-source-operation
              :provider provider
              :operation (edit-operation-kind operation)
              :message "LSM provider does not implement this edit kind")))))

(defun lsm-apply-source-patches (source patches)
  (unless (and (proper-list-p patches) patches)
    (error 'source-adapter-error :provider nil
           :message "LSM edit plan requires a nonempty patch list"))
  (let ((cursor 0))
    (with-output-to-string (stream)
      (dolist (patch patches)
        (destructuring-bind (start end replacement) patch
          (unless (and (integerp start) (integerp end)
                       (<= cursor start end (length source))
                       (stringp replacement))
            (error 'source-adapter-error :provider nil
                   :message "LSM edit plan contains overlapping or invalid patches"))
          (write-string source stream :start cursor :end start)
          (write-string replacement stream)
          (setf cursor end)))
      (write-string source stream :start cursor))))

(defun lsm-calendar-temporal-equal-p (left right)
  (or (and (null left) (null right))
      (and (temporal-value-p left) (temporal-value-p right)
           (eq (temporal-value-kind left) (temporal-value-kind right))
           (string= (temporal-value-local-value left)
                    (temporal-value-local-value right))
           (equal (temporal-value-timezone-id left)
                  (temporal-value-timezone-id right))
           (equal (temporal-value-fold left) (temporal-value-fold right))
           (equal (temporal-value-gap-policy left)
                  (temporal-value-gap-policy right))
           (eq (temporal-value-precision left)
               (temporal-value-precision right)))))

(defun lsm-task-clock-equal-p (left right)
  "Compare clock semantics without treating source spelling as identity."
  (and (task-clock-p left)
       (task-clock-p right)
       (lsm-calendar-temporal-equal-p (task-clock-start left)
                                      (task-clock-start right))
       (lsm-calendar-temporal-equal-p (task-clock-end left)
                                      (task-clock-end right))))

(defun lsm-task-clock-list-equal-p (left right)
  (and (= (length left) (length right))
       (every #'lsm-task-clock-equal-p left right)))

(defun lsm-calendar-event-equal-p (left right)
  (or (and (null left) (null right))
      (and (event-facet-p left) (event-facet-p right)
           (lsm-calendar-temporal-equal-p (event-facet-start left)
                                          (event-facet-start right))
           (lsm-calendar-temporal-equal-p (event-facet-end left)
                                          (event-facet-end right))
           (equal (event-facet-duration left) (event-facet-duration right))
           (equal (event-facet-status left) (event-facet-status right))
           (equal (event-facet-location left) (event-facet-location right))
           (equal (event-facet-url left) (event-facet-url right))
           (eq (event-facet-transparency left)
               (event-facet-transparency right))
           (equalp (event-facet-recurrence left)
                   (event-facet-recurrence right)))))

(defun lsm-calendar-task-equal-p (left right)
  (or (and (null left) (null right))
      (and (task-facet-p left) (task-facet-p right)
           (string= (task-facet-workflow-id left)
                    (task-facet-workflow-id right))
           (string= (task-facet-state left) (task-facet-state right))
           (eq (task-facet-done-p left) (task-facet-done-p right))
           (equal (task-facet-priority left) (task-facet-priority right))
           (equal (task-facet-progress left) (task-facet-progress right))
           (equal (task-facet-effort left) (task-facet-effort right))
           (lsm-calendar-temporal-equal-p (task-facet-scheduled left)
                                          (task-facet-scheduled right))
           (equal (task-facet-scheduled-delay left)
                  (task-facet-scheduled-delay right))
           (lsm-calendar-temporal-equal-p (task-facet-deadline left)
                                          (task-facet-deadline right))
           (lsm-calendar-temporal-equal-p (task-facet-closed left)
                                          (task-facet-closed right))
           (equal (task-facet-deadline-warning left)
                  (task-facet-deadline-warning right))
           (equalp (task-facet-recurrence left)
                   (task-facet-recurrence right))
           (equalp (task-facet-dependencies left)
                   (task-facet-dependencies right))
           (equalp (task-facet-logs left) (task-facet-logs right)))))

(defun lsm-inactive-dates-equal-p (left right)
  (and (= (length left) (length right))
       (every
        (lambda (first second)
          (or (lsm-calendar-temporal-equal-p first second)
              (and (recurrence-period-p first)
                   (recurrence-period-p second)
                   (lsm-calendar-temporal-equal-p
                    (recurrence-period-start first)
                    (recurrence-period-start second))
                   (lsm-calendar-temporal-equal-p
                    (recurrence-period-end first)
                    (recurrence-period-end second))
                   (equal (recurrence-period-duration first)
                          (recurrence-period-duration second)))))
        left right)))

(defmethod apply-source-edit ((provider lsm-provider) plan current-snapshot
                              &key new-revision &allow-other-keys)
  (assert-edit-plan-current plan current-snapshot)
  (require-non-empty-string new-revision :invalid-source-revision
                            "new LSM source revision")
  (let* ((operations (edit-plan-operations plan))
         (operation
           (and (consp operations) (null (cdr operations))
                (first operations))))
    (when (and (edit-operation-p operation)
               (member (edit-operation-kind operation)
                       '(:append-archived-subtree :move-node-subtree
                         :delete-node-subtree
                         :insert-heading-after-subtree
                         :insert-context-line :toggle-list-checkbox
                         :shift-heading-levels :move-table-column
                         :mutate-table-structure
                         :move-structural-unit
                         :set-event-interval
                         :set-inactive-dates
                         :set-node-tags :remove-node-flagging :add-agenda-note
                         :set-task-priority
                         :set-task-effort
                         :set-task-clocks
                         :set-task-scheduled :set-task-deadline
                         :set-task-scheduled-delay
                         :set-task-deadline-warning)))
      (let ((canonical
              (plan-source-edit provider current-snapshot operation)))
        (unless (equal (edit-plan-metadata plan)
                       (edit-plan-metadata canonical))
          (model-error
                       (case (edit-operation-kind operation)
                         (:add-agenda-note :invalid-lsm-agenda-note-plan)
                         (:insert-heading-after-subtree
                          :invalid-lsm-heading-insertion-plan)
                         ((:insert-context-line :toggle-list-checkbox)
                          :invalid-lsm-context-edit-plan)
                         ((:shift-heading-levels :move-table-column
                           :mutate-table-structure
                           :move-structural-unit)
                          :invalid-lsm-structural-edit-plan)
                         (otherwise :invalid-lsm-agenda-edit-plan))
                       (edit-plan-metadata plan)
                       "LSM agenda edit plan does not match its exact base operation")))))
  (let* ((metadata (edit-plan-metadata plan))
         (start (getf metadata :patch-start))
         (end (getf metadata :patch-end))
         (replacement (getf metadata :replacement))
         (patches (getf metadata :patches))
         (syntax (source-snapshot-syntax-tree current-snapshot))
         (source (lsm-syntax-document-source syntax))
         (updated-source
           (if patches
               (lsm-apply-source-patches source patches)
               (progn
                 (unless (and (integerp start) (integerp end)
                              (<= 0 start end (length source))
                              (stringp replacement))
                   (error 'source-adapter-error
                          :provider provider
                          :message "LSM edit plan contains an invalid source patch"))
                 (concatenate 'string (subseq source 0 start) replacement
                              (subseq source end)))))
         (updated
           (parse-source
            provider updated-source
            :source-id (source-snapshot-source-id current-snapshot)
            :revision new-revision)))
    (dolist (node-id (getf metadata :expected-deleted-node-ids))
      (when (find-semantic-node (source-snapshot-document updated) node-id)
        (model-error :inconsistent-lsm-subtree-deletion node-id
                     "reparsed LSM source retained a planned deleted node")))
    (when (getf metadata :expected-flagging-removed)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation))))
        (unless (and actual
                     (not (member "FLAGGED" (semantic-node-tags actual)
                                  :test #'string-equal))
                     (null (assoc "THEFLAGGINGNOTE"
                                  (semantic-node-properties actual)
                                  :test #'string-equal)))
          (model-error :inconsistent-lsm-flagging-removal actual
                       "reparsed LSM node retained flagging metadata"))))
    (dolist (expected (getf metadata :expected-moved-nodes))
      (destructuring-bind (node-id level parent-id) expected
        (let ((actual
                (find-semantic-node
                 (source-snapshot-document updated) node-id)))
          (unless (and actual
                       (= level (semantic-node-level actual))
                       (equal parent-id (semantic-node-parent-id actual)))
            (model-error :inconsistent-lsm-subtree-move expected
                         "reparsed LSM subtree does not have its planned hierarchy")))))
    (let ((shape (getf metadata :expected-archived-nodes)))
      (when (and shape (not (archived-node-shape-present-p updated shape)))
        (model-error :inconsistent-lsm-archive-append shape
                     "reparsed LSM archive lost the appended hierarchy")))
    (let ((shape (getf metadata :expected-inserted-heading)))
      (when shape
        (destructuring-bind (node-id level parent-id task-p) shape
          (let* ((document (source-snapshot-document updated))
                 (actual (find-semantic-node document node-id))
                 (task (and actual (semantic-node-task actual)))
                 (target
                   (find-semantic-node
                    document
                    (edit-operation-target-id
                     (first (edit-plan-operations plan)))))
                 (tail
                   (and target
                        (member target (semantic-document-nodes document)
                                :test #'eq)))
                 (before
                   (and tail (member actual (rest tail) :test #'eq))))
            (unless
                (and actual target before
                     (every
                      (lambda (candidate)
                        (> (semantic-node-level candidate)
                           (semantic-node-level target)))
                      (ldiff (rest tail) before))
                     (= level (semantic-node-level actual))
                     (equal parent-id (semantic-node-parent-id actual))
                     (string= "" (semantic-node-title actual))
                     (null (semantic-node-child-ids actual))
                     (if task-p
                         (and task
                              (string= "org/default"
                                       (task-facet-workflow-id task))
                              (string= "TODO" (task-facet-state task))
                              (not (task-facet-done-p task)))
                         (null task)))
              (model-error :inconsistent-lsm-heading-insertion shape
                           "reparsed LSM heading insertion changed its exact sibling shape"))))))
    (let ((shape (getf metadata :expected-context-line)))
      (when shape
        (destructuring-bind (kind inserted-start expected-count
                             expected-checkbox)
            shape
          (let ((target
                  (find-semantic-node
                   (source-snapshot-document updated)
                   (edit-operation-target-id
                    (first (edit-plan-operations plan))))))
            (unless target
              (model-error :inconsistent-lsm-context-insertion shape
                           "reparsed context insertion lost its target node"))
            (ecase kind
              (:list
               (multiple-value-bind (content item)
                   (lsm-list-item-at-source-start target inserted-start)
                 (unless (and content item
                              (= expected-count
                                 (length (content-node-items content)))
                              (eq expected-checkbox
                                  (list-item-checkbox item))
                              (null (list-item-inlines item)))
                   (model-error :inconsistent-lsm-list-insertion shape
                                "reparsed list insertion changed its empty item shape"))))
              (:table
               (let* ((content
                        (lsm-table-content-at-source-line
                         target inserted-start))
                      (table (and content (content-node-table content)))
                      (row
                        (and table
                             (find inserted-start (table-data-rows table)
                                   :key
                                   (lambda (candidate)
                                     (source-span-character-start
                                      (table-row-span candidate)))
                                   :test #'=))))
                 (unless (and table row
                              (= expected-count
                                 (length (table-data-rows table)))
                              (every
                               (lambda (cell)
                                 (null (table-cell-inlines cell)))
                               (table-row-cells row)))
                   (model-error :inconsistent-lsm-table-insertion shape
                                "reparsed table insertion changed its empty row shape")))))))))
    (let ((expected (getf metadata :expected-checkbox)))
      (when expected
        (destructuring-bind (item-start checkbox) expected
          (let ((target
                  (find-semantic-node
                   (source-snapshot-document updated)
                   (edit-operation-target-id
                    (first (edit-plan-operations plan))))))
            (multiple-value-bind (content item)
                (and target
                     (lsm-list-item-at-source-start target item-start))
              (declare (ignore content))
              (unless (and item (eq checkbox (list-item-checkbox item)))
                (model-error :inconsistent-lsm-checkbox-edit expected
                             "reparsed checkbox did not retain its planned state")))))))
    (let ((expected (getf metadata :expected-heading-outline)))
      (when expected
        (let ((actual
                (lsm-heading-outline-shape
                 (source-snapshot-document updated))))
          (unless (equal expected actual)
            (model-error :inconsistent-lsm-heading-level-shift actual
                         "reparsed heading outline differs from the planned shift")))))
    (let ((expected (getf metadata :expected-table-column-shape)))
      (when expected
        (destructuring-bind (table-start shape) expected
          (let* ((operation (first (edit-plan-operations plan)))
                 (target
                   (find-semantic-node
                    (source-snapshot-document updated)
                    (edit-operation-target-id operation)))
                 (content
                   (and target
                        (lsm-table-content-at-source-start
                         target table-start)))
                 (actual
                   (and content
                        (lsm-table-column-shape
                         (content-node-table content)))))
            (unless (equal shape actual)
              (model-error :inconsistent-lsm-table-column-shift actual
                           "reparsed GFM table differs from the planned column move"))))))
    (let ((expected (getf metadata :expected-table-structure-shape)))
      (when expected
        (destructuring-bind (table-start shape) expected
          (let* ((operation (first (edit-plan-operations plan)))
                 (target
                   (find-semantic-node
                    (source-snapshot-document updated)
                    (edit-operation-target-id operation)))
                 (content
                   (and target
                        (lsm-table-content-at-source-start
                         target table-start)))
                 (actual
                   (and content
                        (lsm-table-column-shape
                         (content-node-table content)))))
            (unless (equal shape actual)
              (model-error :inconsistent-lsm-table-structure-mutation actual
                           "reparsed GFM table differs from the planned mutation"))))))
    (let ((expected (getf metadata :expected-structural-shape)))
      (when expected
        (let ((actual
                (lsm-document-structural-shape
                 (source-snapshot-document updated))))
          (unless (equal expected actual)
            (model-error :inconsistent-lsm-structural-move actual
                         "reparsed LSM structure differs from the planned move")))))
    (let ((expected-nodes
            (or (getf metadata :expected-nodes)
                (let ((expected (getf metadata :expected-node)))
                  (and expected (list expected))))))
      (dolist (expected expected-nodes)
        (let ((actual
                (find-semantic-node
                 (source-snapshot-document updated)
                 (semantic-node-id expected))))
          (unless (and actual
                       (string= (semantic-node-title expected)
                                (semantic-node-title actual))
                       (equal (semantic-node-tags expected)
                              (semantic-node-tags actual))
                       (equal (semantic-node-aliases expected)
                              (semantic-node-aliases actual))
                       (equalp (semantic-node-references expected)
                               (semantic-node-references actual))
                       (equalp (semantic-node-properties expected)
                               (semantic-node-properties actual))
                       (equalp (semantic-node-calendar-bindings expected)
                               (semantic-node-calendar-bindings actual))
                       (lsm-calendar-event-equal-p
                        (semantic-node-event expected)
                        (semantic-node-event actual))
                       (lsm-calendar-task-equal-p
                        (semantic-node-task expected)
                        (semantic-node-task actual))
                       (lsm-inactive-dates-equal-p
                        (semantic-node-inactive-dates expected)
                        (semantic-node-inactive-dates actual)))
            (model-error :inconsistent-lsm-caldav-merge-edit actual
                         "reparsed LSM node does not match the merge result"))))
    (let ((assigned-id (getf metadata :expected-assigned-id))
          (assigned-title (getf metadata :expected-assigned-title)))
      (when assigned-id
        (let ((actual
                (find-semantic-node
                 (source-snapshot-document updated) assigned-id)))
          (unless (and actual
                       (string= assigned-title
                                (semantic-node-title actual)))
            (model-error :inconsistent-lsm-node-id-edit assigned-id
                         "reparsed LSM node does not carry the planned persistent identity")))))
    (dolist (identity (getf metadata :expected-assigned-identities))
      (let ((actual
              (find-semantic-node
               (source-snapshot-document updated) (car identity))))
        (unless (and actual
                     (string= (cdr identity) (semantic-node-title actual)))
          (model-error :inconsistent-lsm-node-id-batch-edit identity
                       "reparsed LSM node does not carry its planned persistent identity"))))
    (let ((expected-state (getf metadata :expected-task-state)))
      (when expected-state
        (let* ((operation (first (edit-plan-operations plan)))
               (actual
                 (find-semantic-node
                  (source-snapshot-document updated)
                  (edit-operation-target-id operation)))
               (task (and actual (semantic-node-task actual))))
          (unless (and task
                       (string= expected-state (task-facet-state task))
                       (or
                        (null (getf metadata :expected-task-done-p-present))
                        (eq (getf metadata :expected-task-done-p)
                            (task-facet-done-p task))))
            (model-error :inconsistent-lsm-task-state-edit expected-state
                         "reparsed LSM task does not carry its planned state")))))
    (let ((expected-title (getf metadata :expected-agenda-note-title)))
      (when expected-title
        (let* ((operation (first (edit-plan-operations plan)))
               (actual
                 (find-semantic-node
                  (source-snapshot-document updated)
                  (edit-operation-target-id operation))))
          (unless (and actual
                       (string= expected-title (semantic-node-title actual)))
            (model-error :inconsistent-lsm-agenda-note-edit expected-title
                         "reparsed LSM agenda-note target changed identity or title")))))
    (when (getf metadata :expected-event-interval-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (event (and actual (semantic-node-event actual))))
        (unless (lsm-calendar-event-equal-p
                 (getf metadata :expected-event) event)
          (model-error :inconsistent-lsm-event-interval-edit event
                       "reparsed LSM event does not carry the planned interval"))))
    (when (getf metadata :expected-inactive-dates-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (inactive-dates
               (and actual (semantic-node-inactive-dates actual))))
        (unless (lsm-inactive-dates-equal-p
                 (getf metadata :expected-inactive-dates) inactive-dates)
          (model-error :inconsistent-lsm-inactive-date-edit inactive-dates
                       "reparsed LSM node does not carry the planned inactive dates"))))
    (when (getf metadata :expected-node-tags-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (expected-tags (getf metadata :expected-node-tags)))
        (unless (and actual
                     (equal expected-tags (semantic-node-tags actual)))
          (model-error :inconsistent-lsm-node-tags-edit expected-tags
                       "reparsed LSM node does not carry the planned tags"))))
    (when (getf metadata :expected-priority-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (task (and actual (semantic-node-task actual)))
             (priority (and task (task-facet-priority task))))
        (unless (equal (getf metadata :expected-priority) priority)
          (model-error :inconsistent-lsm-agenda-priority-edit priority
                       "reparsed LSM task does not carry the planned priority"))))
    (when (getf metadata :expected-effort-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (task (and actual (semantic-node-task actual)))
             (effort (and task (task-facet-effort task))))
        (unless (and (stringp effort)
                     (string= (getf metadata :expected-effort) effort))
          (model-error :inconsistent-lsm-agenda-effort-edit effort
                       "reparsed LSM task does not carry the planned Effort"))))
    (when (getf metadata :expected-task-clocks-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (task (and actual (semantic-node-task actual)))
             (clocks (and task (task-facet-logs task))))
        (unless (and task
                     (lsm-task-clock-list-equal-p
                      (getf metadata :expected-task-clocks) clocks))
          (model-error :inconsistent-lsm-task-clock-edit clocks
                       "reparsed LSM task does not carry the planned clocks"))))
    (when (getf metadata :expected-planning-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (task (and actual (semantic-node-task actual)))
             (expected (getf metadata :expected-planning-value))
             (planning
               (and task
                    (lsm-agenda-task-planning-value
                     task (getf metadata :expected-planning-kind)))))
        (unless (lsm-calendar-temporal-equal-p expected planning)
          (model-error :inconsistent-lsm-agenda-planning-edit expected
                       "reparsed LSM task does not carry the planned date"))))
    (when (getf metadata :expected-planning-cookie-present)
      (let* ((operation (first (edit-plan-operations plan)))
             (actual
               (find-semantic-node
                (source-snapshot-document updated)
                (edit-operation-target-id operation)))
             (task (and actual (semantic-node-task actual)))
             (expected (getf metadata :expected-planning-cookie))
             (cookie
               (and task
                    (lsm-agenda-task-planning-cookie
                     task (getf metadata :expected-planning-cookie-kind)))))
        (unless (equal expected cookie)
          (model-error :inconsistent-lsm-agenda-planning-cookie-edit expected
                       "reparsed LSM task does not carry the planned cookie"))))
    updated)))

(defun lsm-archive-context-fields (context)
  (list
   (cons "archive-time"
         (lsm-quoted-scalar (archive-context-timestamp context)))
   (cons "archive-file"
         (lsm-quoted-scalar (archive-context-source-id context)))
   (cons "archive-olpath"
         (and (plusp (length (archive-context-outline-path context)))
              (lsm-quoted-scalar
               (archive-context-outline-path context))))
   (cons "archive-category"
         (and (plusp (length (archive-context-category context)))
              (lsm-quoted-scalar (archive-context-category context))))
   (cons "archive-todo"
         (and (archive-context-task-state context)
              (lsm-quoted-scalar (archive-context-task-state context))))
   (cons "archive-itags"
         (and (archive-context-inherited-tags context)
              (render-lsm-string-list
               (archive-context-inherited-tags context))))))

(defun lsm-archive-entry-source (snapshot node context)
  "Return NODE's top-level LSM subtree carrying exact archive provenance."
  (let* ((document (source-snapshot-document snapshot))
         (source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree snapshot))))
    (multiple-value-bind (start end)
        (semantic-node-subtree-character-range document node (length source))
      (let* ((delta (- 1 (semantic-node-level node)))
             (entry
               (rewrite-semantic-subtree-heading-levels
                document node source start end #\# 1 :max-level 6)))
        (multiple-value-bind (heading directives)
            (lsm-node-adjacent-metadata snapshot node)
          (let* ((node-directive
                   (find "lem-node" directives :key #'cst-node-name
                         :test #'string=))
                 (newline
                   (lsm-newline-string (source-newline-style source)))
                 (fields (lsm-archive-context-fields context)))
            (if node-directive
                (let ((relative-start
                        (+ (- (cst-node-character-start node-directive) start)
                           delta))
                      (relative-end
                        (+ (- (cst-node-character-end node-directive) start)
                           delta)))
                  (concatenate
                   'string (subseq entry 0 relative-start)
                   (lsm-transform-directive-fields node-directive fields)
                   (subseq entry relative-end)))
                (let* ((position
                         (+ (- (cst-node-character-end heading) start) delta))
                       (directive
                         (with-output-to-string (stream)
                           (format stream "~a:::{lem-node}~a" newline newline)
                           (format stream "id: ~a~a"
                                   (lsm-quoted-scalar (semantic-node-id node))
                                   newline)
                           (dolist (field fields)
                             (when (cdr field)
                               (format stream "~a: ~a~a"
                                       (car field) (cdr field) newline)))
                           (format stream ":::~a" newline))))
                  (concatenate 'string (subseq entry 0 position) directive
                               (subseq entry position))))))))))

(defmethod plan-source-archive
    ((provider lsm-provider) source-snapshot source-node-id
     destination-snapshot context &key destination-created-p
                                  &allow-other-keys)
  (unless (and (eq provider (source-snapshot-provider source-snapshot))
               (eq provider (source-snapshot-provider destination-snapshot))
               (archive-context-p context))
    (model-error :invalid-lsm-archive-snapshots
                 (list source-snapshot destination-snapshot context)
                 "LSM archive requires two exact provider snapshots and context"))
  (let ((node
          (find-semantic-node
           (source-snapshot-document source-snapshot) source-node-id)))
    (unless node
      (model-error :missing-lsm-archive-node source-node-id
                   "LSM archive source node does not exist"))
    (make-provider-source-archive-plan
     provider source-snapshot node destination-snapshot context
     (lsm-archive-entry-source source-snapshot node context)
     (lsm-syntax-document-source
      (source-snapshot-syntax-tree destination-snapshot))
     :destination-created-p destination-created-p)))
