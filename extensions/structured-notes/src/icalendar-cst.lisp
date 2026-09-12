(in-package #:lem-structured-notes)

(defstruct (ical-parameter-value
            (:constructor %make-ical-parameter-value
                (raw text decoded-text quoted-p)))
  (raw "" :type string :read-only t)
  (text "" :type string :read-only t)
  (decoded-text "" :type string :read-only t)
  (quoted-p nil :type boolean :read-only t))

(defstruct (ical-parameter
            (:constructor %make-ical-parameter
                (raw name normalized-name values)))
  (raw "" :type string :read-only t)
  (name "" :type string :read-only t)
  (normalized-name "" :type string :read-only t)
  (values nil :type list :read-only t))

(defstruct (ical-content-line
            (:constructor %make-ical-content-line
                (raw unfolded span group normalized-group name normalized-name
                 parameters value valid-p)))
  (raw "" :type string :read-only t)
  (unfolded "" :type string :read-only t)
  (span nil :type source-span :read-only t)
  (group nil :type (or null string) :read-only t)
  (normalized-group nil :type (or null string) :read-only t)
  (name nil :type (or null string) :read-only t)
  (normalized-name nil :type (or null string) :read-only t)
  (parameters nil :type list :read-only t)
  (value nil :type (or null string) :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-component
            (:constructor %make-ical-component
                (name normalized-name begin-line end-line items span
                 closed-p)))
  (name "" :type string :read-only t)
  (normalized-name "" :type string :read-only t)
  (begin-line nil :type ical-content-line :read-only t)
  (end-line nil :type (or null ical-content-line) :read-only t)
  (items nil :type list :read-only t)
  (span nil :type source-span :read-only t)
  (closed-p nil :type boolean :read-only t))

(defstruct (ical-document
            (:constructor %make-ical-document
                (source source-id newline content-lines components
                 diagnostics)))
  (source "" :type string :read-only t)
  (source-id "" :type string :read-only t)
  (newline :crlf :type keyword :read-only t)
  (content-lines nil :type list :read-only t)
  (components nil :type list :read-only t)
  (diagnostics nil :type list :read-only t))

(defstruct (ical-source-edit
            (:constructor %make-ical-source-edit
                (kind source-id character-start character-end
                 byte-start byte-end expected-source replacement)))
  (kind :replace :type keyword :read-only t)
  (source-id "" :type string :read-only t)
  (character-start 0 :type (integer 0) :read-only t)
  (character-end 0 :type (integer 0) :read-only t)
  (byte-start 0 :type (integer 0) :read-only t)
  (byte-end 0 :type (integer 0) :read-only t)
  (expected-source "" :type string :read-only t)
  (replacement "" :type string :read-only t))

(defstruct (ical-logical-line
            (:constructor make-ical-logical-line
                (start end raw unfolded)))
  (start 0 :type (integer 0) :read-only t)
  (end 0 :type (integer 0) :read-only t)
  (raw "" :type string :read-only t)
  (unfolded "" :type string :read-only t))

(defstruct (ical-component-builder
            (:constructor make-ical-component-builder
                (name normalized-name begin-line)))
  (name "" :type string)
  (normalized-name "" :type string)
  begin-line
  (items nil :type list))

(defun normalize-icalendar-line-endings-to-crlf (source)
  "Normalize only CR, LF, and CRLF boundaries to strict CRLF."
  (unless (stringp source)
    (model-error :invalid-icalendar-line-ending-source source
                 "iCalendar line-ending normalization requires text"))
  (with-output-to-string (stream)
    (loop :with length := (length source)
          :for index :from 0 :below length
          :for character := (char source index)
          :do
             (cond
               ((char= character #\Return)
                (write-char #\Return stream)
                (write-char #\Newline stream)
                (when (and (< (1+ index) length)
                           (char= #\Newline (char source (1+ index))))
                  (incf index)))
               ((char= character #\Newline)
                (write-char #\Return stream)
                (write-char #\Newline stream))
               (t (write-char character stream))))))

(defun ical-source-span (source-id byte-prefixes start end)
  (make-source-span
   :source-id source-id :character-start start :character-end end
   :byte-start (aref byte-prefixes start)
   :byte-end (aref byte-prefixes end)))

(defun ical-diagnostic
    (source-id byte-prefixes severity code message start end
     &key (loss-risk :none) remediation)
  (make-diagnostic
   :severity severity :code code :message message
   :span (ical-source-span source-id byte-prefixes start end)
   :loss-risk loss-risk :remediation remediation))

(defun ical-ascii-token-character-p (character)
  (let ((code (char-code character)))
    (or (<= (char-code #\A) code (char-code #\Z))
        (<= (char-code #\a) code (char-code #\z))
        (<= (char-code #\0) code (char-code #\9))
        (char= character #\-))))

(defun ical-token-p (text)
  (and (plusp (length text))
       (every #'ical-ascii-token-character-p text)))

(defun ical-control-character-p (character)
  (let ((code (char-code character)))
    (or (<= 0 code 8) (<= 10 code 31) (= code 127))))

(defun ical-safe-parameter-character-p (character)
  (and (not (ical-control-character-p character))
       (not (member character '(#\" #\; #\: #\,)))))

(defun ical-quoted-parameter-character-p (character)
  (and (not (ical-control-character-p character))
       (not (char= character #\"))))

(defun ical-value-character-p (character)
  (not (ical-control-character-p character)))

(defun ical-find-unquoted-character (character text &key (start 0))
  (let ((quoted-p nil))
    (loop :for index :from start :below (length text)
          :for candidate := (char text index)
          :do (cond
                ((char= candidate #\") (setf quoted-p (not quoted-p)))
                ((and (not quoted-p) (char= candidate character))
                 (return index))))))

(defun ical-balanced-quotes-p (text)
  (evenp (count #\" text)))

(defun ical-split-unquoted (character text)
  (let ((start 0)
        (parts nil)
        (quoted-p nil))
    (loop :for index :from 0 :below (length text)
          :for candidate := (char text index)
          :do (cond
                ((char= candidate #\") (setf quoted-p (not quoted-p)))
                ((and (not quoted-p) (char= candidate character))
                 (push (subseq text start index) parts)
                 (setf start (1+ index)))))
    (push (subseq text start) parts)
    (values (nreverse parts) (not quoted-p))))

(defun decode-ical-parameter-text (text)
  "Decode RFC 6868 caret escapes, using LF as the internal line break."
  (unless (stringp text)
    (model-error :invalid-icalendar-parameter-text text
                 "iCalendar parameter text must be a string"))
  (with-output-to-string (stream)
    (loop :with length := (length text)
          :for index :from 0 :below length
          :for character := (char text index)
          :do
             (if (and (char= character #\^) (< (1+ index) length))
                 (let ((escaped (char text (1+ index))))
                   (cond
                     ((char= escaped #\n)
                      (write-char #\Newline stream)
                      (incf index))
                     ((char= escaped #\^)
                      (write-char #\^ stream)
                      (incf index))
                     ((char= escaped #\')
                      (write-char #\" stream)
                      (incf index))
                     (t
                      (write-char character stream))))
                 (write-char character stream)))))

(defun encode-ical-parameter-text (text)
  "Encode a normalized parameter string using RFC 6868 caret escapes."
  (unless (stringp text)
    (model-error :invalid-icalendar-parameter-text text
                 "iCalendar parameter text must be a string"))
  (with-output-to-string (stream)
    (loop :for character :across text
          :do
             (cond
               ((char= character #\Newline) (write-string "^n" stream))
               ((char= character #\^) (write-string "^^" stream))
               ((char= character #\") (write-string "^'" stream))
               ((ical-control-character-p character)
                (model-error
                 :invalid-icalendar-parameter-control character
                 "parameter text contains an unsupported control character"))
               (t (write-char character stream))))))

(defun ical-utf8-scalar-octets (character)
  (let ((code (char-code character)))
    (cond
      ((<= code #x7F) 1)
      ((<= code #x7FF) 2)
      ((<= #xD800 code #xDFFF)
       (model-error :invalid-icalendar-unicode-scalar character
                    "iCalendar output contains a Unicode surrogate"))
      ((<= code #xFFFF) 3)
      ((<= code #x10FFFF) 4)
      (t
       (model-error :invalid-icalendar-unicode-scalar character
                    "iCalendar output contains a value outside Unicode")))))

(defun ical-output-parameter-value (text)
  (unless (stringp text)
    (model-error :invalid-icalendar-output-parameter-value text
                 "generated iCalendar parameter values must be strings"))
  (let ((encoded (encode-ical-parameter-text text)))
    (if (every #'ical-safe-parameter-character-p encoded)
        encoded
        (progn
          (unless (every #'ical-quoted-parameter-character-p encoded)
            (model-error :invalid-icalendar-output-parameter-value text
                         "parameter value cannot be represented safely"))
          (format nil "\"~a\"" encoded)))))

(defun ical-output-parameter (parameter)
  (unless (and (consp parameter) (proper-list-p parameter)
               (stringp (first parameter))
               (ical-token-p (first parameter))
               (rest parameter))
    (model-error :invalid-icalendar-output-parameter parameter
                 "output parameter must be (NAME VALUE...) with a valid token"))
  (format nil ";~a=~{~a~^,~}"
          (string-upcase (first parameter))
          (mapcar #'ical-output-parameter-value (rest parameter))))

(defun fold-ical-content-line
    (unfolded &key (max-unfolded-octets 1048576))
  "Fold one generated content line and terminate every physical line with CRLF.

UNFOLDED contains no line ending.  The first physical line is at most 75 UTF-8
octets.  Each continuation reserves one octet for its leading SPACE, so no
Unicode character is ever split across physical lines."
  (unless (and (stringp unfolded) (plusp (length unfolded)))
    (model-error :invalid-icalendar-output-line unfolded
                 "generated iCalendar content line must be a non-empty string"))
  (ical-require-limit max-unfolded-octets
                      "maximum generated unfolded line size")
  (unless (every (lambda (character)
                   (and (not (ical-control-character-p character))
                        (progn (ical-utf8-scalar-octets character) t)))
                 unfolded)
    (model-error :invalid-icalendar-output-line unfolded
                 "generated iCalendar content line contains a control character"))
  (let ((octets
          (loop :for character :across unfolded
                :sum (ical-utf8-scalar-octets character))))
    (when (> octets max-unfolded-octets)
      (model-error :icalendar-output-line-limit octets
                   "generated iCalendar content line exceeds the configured octet limit")))
  (with-output-to-string (stream)
    (loop :with start := 0
          :with first-line-p := t
          :while (< start (length unfolded))
          :for budget := (if first-line-p 75 74)
          :for end := start
          :for used := 0
          :do
             (loop :while (< end (length unfolded))
                   :for width := (ical-utf8-scalar-octets (char unfolded end))
                   :while (<= (+ used width) budget)
                   :do (incf used width) (incf end))
             (unless first-line-p (write-char #\Space stream))
             (write-string unfolded stream :start start :end end)
             (write-char #\Return stream)
             (write-char #\Newline stream)
             (setf start end first-line-p nil))))

(defun generate-ical-content-line
    (name value &key group (parameters nil)
                       (max-unfolded-octets 1048576))
  "Generate one canonical RFC 5545 content line from an already encoded VALUE.

PARAMETERS is an ordered list of (NAME DECODED-VALUE...).  Parameter values are
RFC 6868 encoded and quoted when required.  Property, group, and parameter
names are emitted in uppercase."
  (unless (and (stringp name) (ical-token-p name))
    (model-error :invalid-icalendar-output-name name
                 "generated property name must be an iCalendar token"))
  (unless (or (null group) (and (stringp group) (ical-token-p group)))
    (model-error :invalid-icalendar-output-group group
                 "generated property group must be NIL or an iCalendar token"))
  (unless (stringp value)
    (model-error :invalid-icalendar-output-value value
                 "generated property value must be an encoded string"))
  (unless (proper-list-p parameters)
    (model-error :invalid-icalendar-output-parameters parameters
                 "generated property parameters must be a finite ordered list"))
  (let ((unfolded
          (with-output-to-string (stream)
            (when group
              (write-string (string-upcase group) stream)
              (write-char #\. stream))
            (write-string (string-upcase name) stream)
            (dolist (parameter parameters)
              (write-string (ical-output-parameter parameter) stream))
            (write-char #\: stream)
            (write-string value stream))))
    (fold-ical-content-line
     unfolded :max-unfolded-octets max-unfolded-octets)))

(defun assert-ical-document-source-evidence-current (document)
  (let* ((source (ical-document-source document))
         (source-id (ical-document-source-id document))
         (byte-prefixes (source-byte-prefixes source))
         (cursor 0))
    (dolist (line (ical-document-content-lines document))
      (let* ((span (ical-content-line-span line))
             (start (source-span-character-start span))
             (end (source-span-character-end span)))
        (unless (and (= start cursor)
                     (string= source-id (source-span-source-id span))
                     (<= start end (length source))
                     (= (source-span-byte-start span)
                        (aref byte-prefixes start))
                     (= (source-span-byte-end span)
                        (aref byte-prefixes end))
                     (string= (ical-content-line-raw line)
                              (subseq source start end)))
          (model-error :stale-icalendar-document-source document
                       "document no longer matches its complete source evidence"))
        (setf cursor end)))
    (unless (= cursor (length source))
      (model-error :stale-icalendar-document-source document
                   "document source evidence is not contiguous and complete")))
  document)

(defun assert-editable-ical-document (document)
  (unless (ical-document-p document)
    (model-error :invalid-icalendar-document document
                 "source editing requires an iCalendar document"))
  (when (find-if (lambda (diagnostic)
                   (member (diagnostic-severity diagnostic) '(:error :fatal)))
                 (ical-document-diagnostics document))
    (model-error :invalid-icalendar-edit-document document
                 "source editing requires a structurally valid document"))
  (assert-ical-document-source-evidence-current document)
  document)

(defun ical-document-component-list (document)
  (labels ((collect (component)
             (cons component
                   (mapcan #'collect
                           (remove-if-not
                            #'ical-component-p
                            (ical-component-items component))))))
    (mapcan #'collect (ical-document-components document))))

(defun ical-owning-component (document line)
  (find-if (lambda (component)
             (find line (ical-component-items component) :test #'eq))
           (ical-document-component-list document)))

(defun assert-editable-ical-content-line (document line)
  (assert-editable-ical-document document)
  (unless (and (ical-content-line-p line)
               (ical-content-line-valid-p line)
               (find line (ical-document-content-lines document) :test #'eq)
               (ical-owning-component document line)
               (not (member (ical-content-line-normalized-name line)
                            '("BEGIN" "END") :test #'string=)))
    (model-error :invalid-icalendar-edit-target line
                 "edit target must be a direct property line owned by the document"))
  (let* ((source (ical-document-source document))
         (span (ical-content-line-span line))
         (start (source-span-character-start span))
         (end (source-span-character-end span))
         (raw (ical-content-line-raw line)))
    (unless (and (string= (ical-document-source-id document)
                          (source-span-source-id span))
                 (<= 0 start end (length source))
                 (string= raw (subseq source start end)))
      (model-error :stale-icalendar-edit-target line
                   "edit target no longer matches its source evidence")))
  line)

(defun ical-source-edit-for-span (kind document span expected replacement)
  (%make-ical-source-edit
   kind (ical-document-source-id document)
   (source-span-character-start span) (source-span-character-end span)
   (source-span-byte-start span) (source-span-byte-end span)
   expected replacement))

(defun plan-ical-content-line-replacement
    (document line name value
     &key group (parameters nil) (max-unfolded-octets 1048576))
  "Plan canonical replacement of one direct property line without mutation."
  (assert-editable-ical-content-line document line)
  (ical-source-edit-for-span
   :replace document (ical-content-line-span line) (ical-content-line-raw line)
   (generate-ical-content-line
    name value :group group :parameters parameters
    :max-unfolded-octets max-unfolded-octets)))

(defun plan-ical-content-line-deletion (document line)
  "Plan deletion of one direct property line without mutation."
  (assert-editable-ical-content-line document line)
  (ical-source-edit-for-span
   :delete document (ical-content-line-span line) (ical-content-line-raw line)
   ""))

(defun ical-component-default-insertion-line (component)
  (let ((child
          (find-if #'ical-component-p (ical-component-items component))))
    (if child
        (ical-component-begin-line child)
        (ical-component-end-line component))))

(defun plan-ical-content-line-insertion
    (document component name value
     &key before-line group (parameters nil)
          (max-unfolded-octets 1048576))
  "Plan insertion of one property before a safe direct component boundary.

By default the property is inserted before the first child component, or
before END when no child exists.  BEFORE-LINE may name a direct property or
the component END line."
  (assert-editable-ical-document document)
  (unless (and (ical-component-p component)
               (find component (ical-document-component-list document)
                     :test #'eq)
               (ical-component-closed-p component)
               (ical-component-end-line component))
    (model-error :invalid-icalendar-insertion-component component
                 "insertion requires a closed component owned by the document"))
  (let ((anchor (or before-line
                    (ical-component-default-insertion-line component))))
    (unless (and (ical-content-line-p anchor)
                 (or (eq anchor (ical-component-end-line component))
                     (and (null before-line)
                          (eq anchor
                              (ical-component-default-insertion-line
                               component)))
                     (and (find anchor (ical-component-items component)
                                :test #'eq)
                          (not (member
                                (ical-content-line-normalized-name anchor)
                                '("BEGIN" "END") :test #'string=)))))
      (model-error :invalid-icalendar-insertion-anchor before-line
                   "insertion anchor must be a direct property or component END"))
    (let* ((span (ical-content-line-span anchor))
           (character-position (source-span-character-start span))
           (byte-position (source-span-byte-start span)))
      (%make-ical-source-edit
       :insert (ical-document-source-id document)
       character-position character-position byte-position byte-position ""
       (generate-ical-content-line
        name value :group group :parameters parameters
        :max-unfolded-octets max-unfolded-octets)))))

(defun ical-source-edit-conflict-p (left right)
  (let ((left-start (ical-source-edit-character-start left))
        (left-end (ical-source-edit-character-end left))
        (right-start (ical-source-edit-character-start right))
        (right-end (ical-source-edit-character-end right)))
    (cond
      ((and (= left-start left-end) (= right-start right-end))
       (= left-start right-start))
      ((= left-start left-end)
       (< right-start left-start right-end))
      ((= right-start right-end)
       (< left-start right-start left-end))
      (t
       (< (max left-start right-start) (min left-end right-end))))))

(defun ical-string-utf8-octets (string)
  (loop :for character :across string
        :sum (ical-utf8-scalar-octets character)))

(defun apply-ical-source-edits
    (document edits &key (max-output-octets 16777216))
  "Atomically compose non-overlapping source edits against DOCUMENT.

Every edit is checked against its original source evidence before any result
is returned.  Duplicate insertion points, interior insertions, and overlapping
replacement ranges are refused so list order can never silently decide a
conflict.  Half-open boundary insertions retain their natural before/after
meaning."
  (assert-editable-ical-document document)
  (ical-require-limit max-output-octets
                      "maximum generated iCalendar entity size")
  (unless (and (proper-list-p edits) edits
               (every #'ical-source-edit-p edits))
    (model-error :invalid-icalendar-source-edits edits
                 "source edits must be a non-empty finite list"))
  (let* ((source (ical-document-source document))
         (source-length (length source))
         (source-octets (ical-string-utf8-octets source))
         (byte-prefixes (source-byte-prefixes source))
         (ordered
           (stable-sort
            (copy-list edits)
            (lambda (left right)
              (or (< (ical-source-edit-character-start left)
                     (ical-source-edit-character-start right))
                  (and (= (ical-source-edit-character-start left)
                          (ical-source-edit-character-start right))
                       (< (ical-source-edit-character-end left)
                          (ical-source-edit-character-end right))))))))
    (dolist (edit ordered)
      (let ((start (ical-source-edit-character-start edit))
            (end (ical-source-edit-character-end edit))
            (byte-start (ical-source-edit-byte-start edit))
            (byte-end (ical-source-edit-byte-end edit))
            (expected (ical-source-edit-expected-source edit)))
        (unless (and (member (ical-source-edit-kind edit)
                             '(:insert :replace :delete))
                     (string= (ical-source-edit-source-id edit)
                              (ical-document-source-id document))
                     (<= 0 start end source-length)
                     (<= 0 byte-start byte-end source-octets)
                     (= byte-start (aref byte-prefixes start))
                     (= byte-end (aref byte-prefixes end))
                     (= (- end start) (length expected))
                     (= (- byte-end byte-start)
                        (ical-string-utf8-octets expected))
                     (string= expected (subseq source start end)))
          (model-error :stale-or-invalid-icalendar-source-edit edit
                       "source edit does not match this document's evidence"))))
    (loop :for (left right) :on ordered
          :while right
          :when (ical-source-edit-conflict-p left right)
            :do (model-error :conflicting-icalendar-source-edits
                             (list left right)
                             "source edits overlap or share an insertion point"))
    (let ((result-octets
            (+ source-octets
               (loop :for edit :in ordered
                     :sum (- (ical-string-utf8-octets
                              (ical-source-edit-replacement edit))
                             (- (ical-source-edit-byte-end edit)
                                (ical-source-edit-byte-start edit)))))))
      (when (> result-octets max-output-octets)
        (model-error :icalendar-output-entity-limit result-octets
                     "generated iCalendar entity exceeds the configured octet limit")))
    (with-output-to-string (stream)
      (loop :with cursor := 0
            :for edit :in ordered
            :for start := (ical-source-edit-character-start edit)
            :for end := (ical-source-edit-character-end edit)
            :do
               (write-string source stream :start cursor :end start)
               (write-string (ical-source-edit-replacement edit) stream)
               (setf cursor end)
            :finally (write-string source stream :start cursor)))))

(defun replace-ical-content-line
    (document line name value
     &key group (parameters nil)
          (max-unfolded-octets 1048576)
          (max-output-octets 16777216))
  "Return source with exactly LINE's physical span canonically replaced.

LINE must be a valid direct property line owned by DOCUMENT.  This pure
operation performs no file or network write and preserves all source outside
the replaced span exactly."
  (apply-ical-source-edits
   document
   (list
    (plan-ical-content-line-replacement
     document line name value :group group :parameters parameters
     :max-unfolded-octets max-unfolded-octets))
   :max-output-octets max-output-octets))

(defun parse-ical-parameter-value (raw)
  (let* ((length (length raw))
         (starts-quoted-p (and (plusp length)
                               (char= (char raw 0) #\")))
         (ends-quoted-p (and (plusp length)
                             (char= (char raw (1- length)) #\"))))
    (cond
      ((or starts-quoted-p ends-quoted-p)
       (unless (and starts-quoted-p ends-quoted-p (>= length 2))
         (return-from parse-ical-parameter-value (values nil nil)))
       (let ((text (subseq raw 1 (1- length))))
         (if (every #'ical-quoted-parameter-character-p text)
             (values
              (%make-ical-parameter-value
               raw text (decode-ical-parameter-text text) t)
              t)
             (values nil nil))))
      ((every #'ical-safe-parameter-character-p raw)
       (values
        (%make-ical-parameter-value
         raw raw (decode-ical-parameter-text raw) nil)
        t))
      (t (values nil nil)))))

(defun parse-ical-parameter (raw)
  (let ((equals (ical-find-unquoted-character #\= raw)))
    (unless equals
      (return-from parse-ical-parameter (values nil nil)))
    (let ((name (subseq raw 0 equals))
          (raw-values (subseq raw (1+ equals))))
      (unless (ical-token-p name)
        (return-from parse-ical-parameter (values nil nil)))
      (multiple-value-bind (parts balanced-p)
          (ical-split-unquoted #\, raw-values)
        (unless balanced-p
          (return-from parse-ical-parameter (values nil nil)))
        (let ((values nil))
          (dolist (part parts)
            (multiple-value-bind (value valid-p)
                (parse-ical-parameter-value part)
              (unless valid-p
                (return-from parse-ical-parameter (values nil nil)))
              (push value values)))
          (values
           (%make-ical-parameter raw name (string-upcase name)
                                 (nreverse values))
           t))))))

(defun parse-ical-content-line
    (logical source-id byte-prefixes)
  (let* ((unfolded (ical-logical-line-unfolded logical))
         (start (ical-logical-line-start logical))
         (end (ical-logical-line-end logical))
         (raw (ical-logical-line-raw logical))
         (span (ical-source-span source-id byte-prefixes start end))
         (diagnostics nil)
         (colon (ical-find-unquoted-character #\: unfolded)))
    (labels ((invalid (message)
               (push (ical-diagnostic
                      source-id byte-prefixes :error
                      :invalid-icalendar-content-line message start end
                      :loss-risk :none)
                     diagnostics)
               (values
                (%make-ical-content-line
                 raw unfolded span nil nil nil nil nil nil nil)
                (nreverse diagnostics))))
      (unless (and colon (plusp colon)
                   (ical-balanced-quotes-p (subseq unfolded 0 colon)))
        (return-from parse-ical-content-line
          (invalid "Content line lacks a valid unquoted name/value colon")))
      (let ((head (subseq unfolded 0 colon))
            (value (subseq unfolded (1+ colon))))
        (unless (every #'ical-value-character-p value)
          (return-from parse-ical-content-line
            (invalid "Content-line value contains a forbidden control character")))
        (multiple-value-bind (parts balanced-p)
            (ical-split-unquoted #\; head)
          (unless balanced-p
            (return-from parse-ical-content-line
              (invalid "Content-line parameter quoting is unbalanced")))
          (let* ((grouped-name (first parts))
                 (dot (position #\. grouped-name))
                 (group (and dot (subseq grouped-name 0 dot)))
                 (name (if dot (subseq grouped-name (1+ dot)) grouped-name))
                 (parameters nil))
            (unless (and (ical-token-p name)
                         (or (null group)
                             (and (ical-token-p group)
                                  (null (position #\. grouped-name
                                                  :start (1+ dot))))))
              (return-from parse-ical-content-line
                (invalid "Content-line group or property name is not an iCalendar token")))
            (dolist (raw-parameter (rest parts))
              (multiple-value-bind (parameter valid-p)
                  (parse-ical-parameter raw-parameter)
                (unless valid-p
                  (return-from parse-ical-content-line
                    (invalid "Content line contains an invalid parameter")))
                (push parameter parameters)))
            (values
             (%make-ical-content-line
              raw unfolded span group (and group (string-upcase group))
              name (string-upcase name) (nreverse parameters) value t)
             (nreverse diagnostics))))))))

(defun ical-require-limit (value label)
  (unless (and (integerp value) (not (minusp value)))
    (model-error :invalid-icalendar-resource-limit value
                 (format nil "~a must be a non-negative integer" label)))
  value)

(defun ical-physical-line-ending (source line)
  (subseq source (source-line-content-end line)
          (source-line-character-end line)))

(defun ical-line-byte-length (byte-prefixes line)
  (- (aref byte-prefixes (source-line-content-end line))
     (aref byte-prefixes (source-line-character-start line))))

(defun unfold-icalendar-lines
    (source source-id byte-prefixes physical-lines
     max-physical-line-octets max-unfolded-line-octets)
  (let ((logical-lines nil)
        (diagnostics nil)
        (current-start nil)
        (current-end nil)
        (current-unfolded nil))
    (labels ((flush-current ()
               (when current-start
                 (let ((raw (subseq source current-start current-end)))
                   (when (> (aref (source-byte-prefixes current-unfolded)
                                  (length current-unfolded))
                            max-unfolded-line-octets)
                     (model-error :icalendar-unfolded-line-limit
                                  max-unfolded-line-octets
                                  "unfolded iCalendar content line exceeds the configured octet limit"))
                   (push (make-ical-logical-line
                          current-start current-end raw current-unfolded)
                         logical-lines)))
               (setf current-start nil current-end nil current-unfolded nil)))
      (dolist (line physical-lines)
        (let* ((start (source-line-character-start line))
               (end (source-line-character-end line))
               (text (source-line-text line))
               (ending (ical-physical-line-ending source line))
               (octets (ical-line-byte-length byte-prefixes line)))
          (when (> octets max-physical-line-octets)
            (model-error :icalendar-physical-line-limit octets
                         "physical iCalendar line exceeds the configured octet limit"))
          (when (> octets 75)
            (push (ical-diagnostic
                   source-id byte-prefixes :warning
                   :overlong-icalendar-line
                   "Physical iCalendar line exceeds the RFC 5545 75-octet recommendation"
                   start end)
                  diagnostics))
          (unless (string= ending (format nil "~c~c" #\Return #\Newline))
            (push (ical-diagnostic
                   source-id byte-prefixes
                   (if (zerop (length ending)) :error :warning)
                   (if (zerop (length ending))
                       :missing-icalendar-line-ending
                       :non-crlf-icalendar-line-ending)
                   (if (zerop (length ending))
                       "iCalendar content line is not terminated"
                       "iCalendar input uses a non-CRLF line ending")
                   start end)
                  diagnostics))
          (if (and (plusp (length text))
                   (member (char text 0) '(#\Space #\Tab)))
              (if current-start
                  (setf current-end end
                        current-unfolded
                        (concatenate 'string current-unfolded
                                     (subseq text 1)))
                  (progn
                    (push (ical-diagnostic
                           source-id byte-prefixes :error
                           :orphan-icalendar-fold
                           "Fold continuation has no preceding content line"
                           start end)
                          diagnostics)
                    (setf current-start start current-end end
                          current-unfolded text)))
              (progn
                (flush-current)
                (setf current-start start current-end end
                      current-unfolded text)))))
      (flush-current))
    (values (nreverse logical-lines) (nreverse diagnostics))))

(defun make-ical-component-from-builder
    (builder end-line source-id byte-prefixes source-length)
  (let* ((begin-line (ical-component-builder-begin-line builder))
         (start (source-span-character-start
                 (ical-content-line-span begin-line)))
         (end (if end-line
                  (source-span-character-end (ical-content-line-span end-line))
                  source-length)))
    (%make-ical-component
     (ical-component-builder-name builder)
     (ical-component-builder-normalized-name builder)
     begin-line end-line (nreverse (ical-component-builder-items builder))
     (ical-source-span source-id byte-prefixes start end)
     (not (null end-line)))))

(defun build-icalendar-components
    (content-lines source-id byte-prefixes source-length
     max-components max-nesting)
  (let ((stack nil)
        (roots nil)
        (diagnostics nil)
        (component-count 0))
    (labels ((line-range-diagnostic (line severity code message)
               (let ((span (ical-content-line-span line)))
                 (push (ical-diagnostic
                        source-id byte-prefixes severity code message
                        (source-span-character-start span)
                        (source-span-character-end span))
                       diagnostics)))
             (attach-component (component)
               (if stack
                   (push component
                         (ical-component-builder-items (first stack)))
                   (push component roots))))
      (dolist (line content-lines)
        (let ((name (ical-content-line-normalized-name line))
              (value (ical-content-line-value line)))
          (cond
            ((and (ical-content-line-valid-p line)
                  (string= name "BEGIN"))
             (unless (ical-token-p value)
               (line-range-diagnostic
                line :error :invalid-icalendar-component-name
                "BEGIN value is not an iCalendar component token")
               (when stack
                 (push line (ical-component-builder-items (first stack))))
               (go next-line))
             (incf component-count)
             (when (> component-count max-components)
               (model-error :icalendar-component-limit component-count
                            "iCalendar component count exceeds the configured limit"))
             (when (>= (length stack) max-nesting)
               (model-error :icalendar-nesting-limit (length stack)
                            "iCalendar component nesting exceeds the configured limit"))
             (push (make-ical-component-builder
                    value (string-upcase value) line)
                   stack))
            ((and (ical-content-line-valid-p line)
                  (string= name "END"))
             (if (and stack
                      (string= (string-upcase value)
                               (ical-component-builder-normalized-name
                                (first stack))))
                 (let* ((builder (pop stack))
                        (component
                          (make-ical-component-from-builder
                           builder line source-id byte-prefixes source-length)))
                   (attach-component component))
                 (progn
                   (line-range-diagnostic
                    line :error :mismatched-icalendar-component-end
                    "END does not match the currently open component")
                   (when stack
                     (push line
                           (ical-component-builder-items (first stack)))))))
            (stack
             (push line (ical-component-builder-items (first stack))))
            (t
             (line-range-diagnostic
              line :error :top-level-icalendar-content
              "Content line appears outside a calendar component"))))
        next-line)
      (loop :while stack
            :for builder := (pop stack)
            :for component :=
              (make-ical-component-from-builder
               builder nil source-id byte-prefixes source-length)
            :do
               (let ((begin-line (ical-component-begin-line component)))
                 (line-range-diagnostic
                  begin-line :error :unclosed-icalendar-component
                  "Calendar component is missing its matching END line"))
               (attach-component component))
      (dolist (root roots)
        (unless (string= "VCALENDAR" (ical-component-normalized-name root))
          (let ((line (ical-component-begin-line root)))
            (line-range-diagnostic
             line :error :invalid-icalendar-root-component
             "Top-level iCalendar component must be VCALENDAR"))))
      (unless roots
        (push (make-diagnostic
               :severity :error :code :missing-vcalendar
               :message "iCalendar stream contains no VCALENDAR component"
               :loss-risk :none)
              diagnostics)))
    (values (nreverse roots) (nreverse diagnostics))))

(defun parse-icalendar-cst
    (source &key (source-id "calendar.ics")
                 (max-physical-lines 100000)
                 (max-physical-line-octets 1048576)
                 (max-unfolded-line-octets 1048576)
                 (max-components 10000)
                 (max-nesting 64))
  "Parse an iCalendar stream without normalizing or discarding source data."
  (unless (stringp source)
    (model-error :invalid-icalendar-source source
                 "iCalendar source must be a string"))
  (require-non-empty-string source-id :invalid-source-id "source ID")
  (ical-require-limit max-physical-lines "maximum physical line count")
  (ical-require-limit max-physical-line-octets
                      "maximum physical line size")
  (ical-require-limit max-unfolded-line-octets
                      "maximum unfolded line size")
  (ical-require-limit max-components "maximum component count")
  (ical-require-limit max-nesting "maximum component nesting")
  (let* ((physical-lines (scan-source-lines source))
         (byte-prefixes (source-byte-prefixes source)))
    (when (> (length physical-lines) max-physical-lines)
      (model-error :icalendar-line-count-limit (length physical-lines)
                   "iCalendar physical line count exceeds the configured limit"))
    (multiple-value-bind (logical-lines lexical-diagnostics)
        (unfold-icalendar-lines
         source source-id byte-prefixes physical-lines
         max-physical-line-octets max-unfolded-line-octets)
      (let ((content-lines nil)
            (line-diagnostics nil))
        (dolist (logical logical-lines)
          (multiple-value-bind (line diagnostics)
              (parse-ical-content-line logical source-id byte-prefixes)
            (push line content-lines)
            (setf line-diagnostics
                  (nconc line-diagnostics diagnostics))))
        (setf content-lines (nreverse content-lines))
        (multiple-value-bind (components structural-diagnostics)
            (build-icalendar-components
             content-lines source-id byte-prefixes (length source)
             max-components max-nesting)
          (%make-ical-document
           source source-id (source-newline-style source) content-lines
           components
           (append lexical-diagnostics line-diagnostics
                   structural-diagnostics)))))))

(defun serialize-icalendar-cst (document)
  "Serialize the exact physical source evidence retained by DOCUMENT."
  (unless (ical-document-p document)
    (model-error :invalid-icalendar-document document
                 "value must be an iCalendar CST document"))
  (ical-document-source document))

(defun ical-component-properties (component)
  (remove-if-not
   (lambda (item)
     (and (ical-content-line-p item)
          (ical-content-line-valid-p item)
          (not (member (ical-content-line-normalized-name item)
                       '("BEGIN" "END") :test #'string=))))
   (ical-component-items component)))

(defun ical-component-children (component)
  (remove-if-not #'ical-component-p (ical-component-items component)))
