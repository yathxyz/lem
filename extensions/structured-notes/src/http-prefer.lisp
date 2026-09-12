(in-package #:lem-structured-notes)

(defstruct (http-applied-preference
            (:constructor %make-http-applied-preference (token value raw)))
  (token "" :type string :read-only t)
  (value nil :type (or null string) :read-only t)
  (raw "" :type string :read-only t))

(defstruct (http-preference-parameter
            (:constructor %make-http-preference-parameter (name value raw)))
  (name "" :type string :read-only t)
  (value nil :type (or null string) :read-only t)
  (raw "" :type string :read-only t))

(defstruct (http-request-preference
            (:constructor %make-http-request-preference
                (token value parameters raw)))
  (token "" :type string :read-only t)
  (value nil :type (or null string) :read-only t)
  (parameters nil :type list :read-only t)
  (raw "" :type string :read-only t))

(defstruct (caldav-return-preference-evidence
            (:constructor %make-caldav-return-preference-evidence
                (kind requested applied applied-preferences)))
  (kind :not-requested
        :type (member :not-requested :applied :ignored :mismatched
                      :ambiguous)
        :read-only t)
  (requested nil :type (member nil :minimal :representation) :read-only t)
  (applied nil :type (member nil :minimal :representation) :read-only t)
  (applied-preferences nil :type list :read-only t))

(defun normalize-caldav-return-preference (preference)
  (unless (member preference '(nil :minimal :representation))
    (model-error :invalid-caldav-return-preference preference
                 "CalDAV return preference must be MINIMAL, REPRESENTATION, or absent"))
  preference)

(defun caldav-return-preference-header (preference)
  "Return a fresh RFC 7240 Prefer header list for one optional return mode."
  (case (normalize-caldav-return-preference preference)
    (:minimal (list (list "Prefer" "return=minimal")))
    (:representation (list (list "Prefer" "return=representation")))
    (otherwise nil)))

(defun http-preference-optional-whitespace-p (character)
  (member character '(#\Space #\Tab)))

(defun http-preference-skip-optional-whitespace (text index)
  (loop :while (and (< index (length text))
                    (http-preference-optional-whitespace-p
                     (char text index)))
        :do (incf index)
        :finally (return index)))

(defun parse-http-preference-token-at (text index label)
  (let ((start index))
    (loop :while (and (< index (length text))
                      (http-field-name-character-p (char text index)))
          :do (incf index))
    (when (= start index)
      (model-error :invalid-http-preference-syntax text
                   "~a requires an HTTP token at character ~d" label index))
    (values (subseq text start index) index)))

(defun parse-http-preference-quoted-string-at (text index label)
  (unless (and (< index (length text)) (char= #\" (char text index)))
    (model-error :invalid-http-preference-syntax text
                 "~a requires a quoted string at character ~d" label index))
  (let ((start index)
        (value (make-array 16 :element-type 'character
                          :adjustable t :fill-pointer 0)))
    (incf index)
    (loop
      (when (= index (length text))
        (model-error :invalid-http-preference-syntax text
                     "~a contains an unterminated quoted string" label))
      (let ((character (char text index)))
        (incf index)
        (cond
          ((char= character #\")
           (return
             (values (coerce value 'string) index (subseq text start index))))
          ((char= character #\\)
           (when (= index (length text))
             (model-error :invalid-http-preference-syntax text
                          "~a ends inside a quoted-pair" label))
           (let ((escaped (char text index)))
             (unless (or (= (char-code escaped) #x09)
                         (<= #x20 (char-code escaped) #x7e)
                         (<= #x80 (char-code escaped) #xff))
               (model-error :invalid-http-preference-syntax text
                            "~a quoted-pair contains an invalid character" label))
             (vector-push-extend escaped value)
             (incf index)))
          ((or (= (char-code character) #x09)
               (= (char-code character) #x20)
               (= (char-code character) #x21)
               (<= #x23 (char-code character) #x5b)
               (<= #x5d (char-code character) #x7e)
               (<= #x80 (char-code character) #xff))
           (vector-push-extend character value))
          (t
           (model-error :invalid-http-preference-syntax text
                        "~a quoted string contains an invalid character" label)))))))

(defun parse-http-preference-word-at (text index label)
  (if (and (< index (length text)) (char= #\" (char text index)))
      (multiple-value-bind (value after-value raw)
          (parse-http-preference-quoted-string-at text index label)
        (declare (ignore raw))
        (values value after-value))
      (parse-http-preference-token-at text index label)))

(defun validate-http-preference-field-input
    (text max-characters field-name)
  (unless (and (integerp max-characters) (plusp max-characters))
    (model-error :invalid-http-preference-limit max-characters
                 "HTTP preference character limit must be positive"))
  (unless (and (stringp text) (plusp (length text)))
    (model-error :invalid-http-preference-syntax text
                 "~a must be a non-empty string" field-name))
  (when (> (length text) max-characters)
    (model-error :http-preference-limit-exceeded (length text)
                 "~a exceeds its character limit" field-name)))

(defun parse-http-prefer-field (text &key (max-characters 65536))
  "Parse one RFC 7240 Prefer request field-value, preserving all parameters."
  (validate-http-preference-field-input text max-characters "Prefer")
  (let ((index 0)
        (result nil))
    (loop
      (setf index (http-preference-skip-optional-whitespace text index))
      (multiple-value-bind (token after-token)
          (parse-http-preference-token-at text index "Prefer")
        (let ((value nil)
              (parameters nil)
              (item-start index))
          (setf index (http-preference-skip-optional-whitespace
                       text after-token))
          (when (and (< index (length text)) (char= #\= (char text index)))
            (incf index)
            (setf index (http-preference-skip-optional-whitespace text index))
            (multiple-value-setq (value index)
              (parse-http-preference-word-at text index "Prefer value")))
          (loop
            (setf index (http-preference-skip-optional-whitespace text index))
            (unless (and (< index (length text))
                         (char= #\; (char text index)))
              (return))
            (incf index)
            (setf index (http-preference-skip-optional-whitespace text index))
            ;; RFC 7240 deliberately admits an absent parameter after each
            ;; semicolon.  Preserve actual parameters and ignore empty slots.
            (unless (or (= index (length text))
                        (member (char text index) '(#\; #\,)))
              (let ((parameter-start index))
                (multiple-value-bind (name after-name)
                    (parse-http-preference-token-at text index
                                                    "Prefer parameter")
                  (let ((parameter-value nil))
                    (setf index (http-preference-skip-optional-whitespace
                                 text after-name))
                    (when (and (< index (length text))
                               (char= #\= (char text index)))
                      (incf index)
                      (setf index
                            (http-preference-skip-optional-whitespace
                             text index))
                      ;; An empty quoted string and no value are equivalent,
                      ;; so both normalize to NIL.
                      (multiple-value-bind (parsed after-value)
                          (parse-http-preference-word-at
                           text index "Prefer parameter value")
                        (setf parameter-value
                              (unless (string= parsed "") parsed)
                              index after-value)))
                    (push (%make-http-preference-parameter
                           (string-downcase name) parameter-value
                           (subseq text parameter-start index))
                          parameters))))))
          (setf index (http-preference-skip-optional-whitespace text index))
          (push (%make-http-request-preference
                 (string-downcase token)
                 (unless (and value (string= value "")) value)
                 (nreverse parameters)
                 (subseq text item-start index))
                result)))
      (cond
        ((= index (length text)) (return (nreverse result)))
        ((char= #\, (char text index))
         (incf index)
         (when (= (http-preference-skip-optional-whitespace text index)
                  (length text))
           (model-error :invalid-http-preference-syntax text
                        "Prefer cannot end with a comma")))
        (t
         (model-error :invalid-http-preference-syntax text
                      "Prefer has trailing syntax at character ~d" index))))))

(defun parse-http-applied-preference-field
    (text &key (max-characters 65536))
  "Parse one RFC 7240 Preference-Applied field-value with exact boundaries."
  (validate-http-preference-field-input
   text max-characters "Preference-Applied")
  (let ((index 0)
        (result nil))
    (loop
      (setf index (http-preference-skip-optional-whitespace text index))
      (multiple-value-bind (token after-token)
          (parse-http-preference-token-at text index "Preference-Applied")
        (let ((value nil)
              (item-start index))
          (setf index (http-preference-skip-optional-whitespace
                       text after-token))
          (when (and (< index (length text)) (char= #\= (char text index)))
            (incf index)
            (setf index (http-preference-skip-optional-whitespace text index))
            (multiple-value-setq (value index)
              (parse-http-preference-word-at
               text index "Preference-Applied value")))
          (setf index (http-preference-skip-optional-whitespace text index))
          (push (%make-http-applied-preference
                 (string-downcase token) value (subseq text item-start index))
                result)))
      (cond
        ((= index (length text)) (return (nreverse result)))
        ((char= #\, (char text index))
         (incf index)
         (when (= (http-preference-skip-optional-whitespace text index)
                  (length text))
           (model-error :invalid-http-preference-syntax text
                        "Preference-Applied cannot end with a comma")))
        (t
         (model-error :invalid-http-preference-syntax text
                      "Preference-Applied has trailing syntax at character ~d"
                      index))))))

(defun http-response-header-field-values (headers name)
  (validate-http-response-headers headers)
  (loop :for header :in headers
        :when (string-equal name (first header))
          :collect (second header)))

(defun parse-http-preference-applied-headers (headers)
  "Parse all list-valued Preference-Applied response fields in wire order."
  (loop :for value :in (http-response-header-field-values
                        headers "Preference-Applied")
        :nconc (parse-http-applied-preference-field value)))

(defun parse-http-prefer-headers (headers)
  "Parse all list-valued Prefer request fields in wire order."
  (loop :for value :in (http-response-header-field-values headers "Prefer")
        :nconc (parse-http-prefer-field value)))

(defun caldav-return-preference-from-request-headers (headers)
  "Recover the first RFC 7240 return preference from CalDAV request headers."
  (let ((return
          (find "return" (parse-http-prefer-headers headers)
                :key #'http-request-preference-token :test #'string=)))
    (when return
      (cond
        ((equal "minimal" (http-request-preference-value return)) :minimal)
        ((equal "representation" (http-request-preference-value return))
         :representation)
        ;; An unrecognized value is an unsupported preference, not a malformed
        ;; request.  RFC 7240 requires it to be ignored.
        (t nil)))))

(defun caldav-depth-noroot-from-request-headers (headers)
  "Return true when the first depth-noroot request preference is valueless."
  (let ((preference
          (find "depth-noroot" (parse-http-prefer-headers headers)
                :key #'http-request-preference-token :test #'string=)))
    (and preference (null (http-request-preference-value preference)))))

(defun classify-caldav-return-preference (request-headers response-headers)
  "Classify optional preference application without inferring it from a body.

An absent Preference-Applied field means IGNORED, even if the response happens
to have the requested shape.  This conservative rule prevents an optimization
from becoming implicit authority to omit a normal validation or refetch path."
  (let* ((requested
           (caldav-return-preference-from-request-headers request-headers))
         (applied-preferences
           (parse-http-preference-applied-headers response-headers))
         (returns
           (remove-if-not
            (lambda (preference)
              (string= "return" (http-applied-preference-token preference)))
            applied-preferences))
         (recognized
           (mapcar
            (lambda (preference)
              (cond
                ((equal "minimal" (http-applied-preference-value preference))
                 :minimal)
                ((equal "representation"
                        (http-applied-preference-value preference))
                 :representation)
                (t :unknown)))
            returns)))
    (cond
      ((null requested)
       (%make-caldav-return-preference-evidence
        (if returns :mismatched :not-requested) nil nil applied-preferences))
      ((null returns)
       (%make-caldav-return-preference-evidence
        :ignored requested nil applied-preferences))
      ((or (rest returns) (member :unknown recognized))
       (%make-caldav-return-preference-evidence
        :ambiguous requested nil applied-preferences))
      ((eq requested (first recognized))
       (%make-caldav-return-preference-evidence
        :applied requested requested applied-preferences))
      (t
       (%make-caldav-return-preference-evidence
        :mismatched requested (first recognized) applied-preferences)))))
