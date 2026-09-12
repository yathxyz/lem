(in-package #:lem-structured-notes)

(defstruct (http-media-type
            (:constructor %make-http-media-type
                (raw type subtype parameters)))
  (raw "" :type string :read-only t)
  (type "" :type string :read-only t)
  (subtype "" :type string :read-only t)
  (parameters nil :type list :read-only t))

(defun trim-http-optional-whitespace (text)
  (string-trim '(#\Space #\Tab) text))

(defun split-http-media-type-segments (raw)
  (let ((segments nil)
        (start 0)
        (quoted-p nil)
        (escaped-p nil))
    (loop :for index :from 0 :below (length raw)
          :for character := (char raw index)
          :do
             (cond
               (escaped-p (setf escaped-p nil))
               ((and quoted-p (char= character #\\))
                (setf escaped-p t))
               ((char= character #\")
                (setf quoted-p (not quoted-p)))
               ((and (not quoted-p) (char= character #\;))
                (push (subseq raw start index) segments)
                (setf start (1+ index)))))
    (when (or quoted-p escaped-p)
      (model-error :invalid-http-media-type raw
                   "media type contains an unterminated quoted string"))
    (push (subseq raw start) segments)
    (nreverse segments)))

(defun decode-http-quoted-string (text)
  (unless (and (>= (length text) 2)
               (char= #\" (char text 0))
               (char= #\" (char text (1- (length text)))))
    (model-error :invalid-http-media-type-quoted-string text
                 "media type quoted parameter is not closed"))
  (with-output-to-string (stream)
    (loop :with end := (1- (length text))
          :with index := 1
          :while (< index end)
          :for character := (char text index)
          :do
             (if (char= character #\\)
                 (progn
                   (incf index)
                   (when (>= index end)
                     (model-error :invalid-http-media-type-quoted-pair text
                                  "media type quoted-pair is incomplete"))
                   (let* ((quoted (char text index))
                          (code (char-code quoted)))
                     (unless (or (= code #x09)
                                 (<= #x20 code #x7e)
                                 (<= #x80 code #xff))
                       (model-error :invalid-http-media-type-quoted-pair text
                                    "media type quoted-pair is invalid"))
                     (write-char quoted stream)))
                 (let ((code (char-code character)))
                   (unless (or (= code #x09) (= code #x20) (= code #x21)
                               (<= #x23 code #x5b)
                               (<= #x5d code #x7e)
                               (<= #x80 code #xff))
                     (model-error :invalid-http-media-type-quoted-text text
                                  "media type quoted string contains an invalid character"))
                   (write-char character stream)))
             (incf index))))

(defun parse-http-media-type (raw &key (max-characters 8192))
  "Parse one RFC 9110 media type field value without MIME sniffing."
  (unless (and (integerp max-characters) (plusp max-characters))
    (model-error :invalid-http-media-type-limit max-characters
                 "media type limit must be a positive integer"))
  (unless (and (stringp raw)
               (every #'http-field-value-character-p raw))
    (model-error :invalid-http-media-type raw
                 "HTTP media type must contain valid field-value characters"))
  (when (> (length raw) max-characters)
    (model-error :http-media-type-limit-exceeded (length raw)
                 "media type exceeds the configured character limit"))
  (let* ((segments (split-http-media-type-segments raw))
         (essence (trim-http-optional-whitespace (first segments)))
         (slash (position #\/ essence)))
    (unless (and slash (plusp slash) (< slash (1- (length essence)))
                 (null (position #\/ essence :start (1+ slash))))
      (model-error :invalid-http-media-type raw
                   "media type requires one type/subtype pair"))
    (let ((type (subseq essence 0 slash))
          (subtype (subseq essence (1+ slash)))
          (parameters nil)
          (seen (make-hash-table :test #'equal)))
      (unless (and (every #'http-field-name-character-p type)
                   (every #'http-field-name-character-p subtype))
        (model-error :invalid-http-media-type raw
                     "media type and subtype must be HTTP tokens"))
      (dolist (segment (rest segments))
        (let* ((trimmed (trim-http-optional-whitespace segment))
               (equals (position #\= trimmed)))
          (unless (and equals (plusp equals)
                       (< equals (1- (length trimmed))))
            (model-error :invalid-http-media-type-parameter segment
                         "media type parameter requires name=value"))
          (let* ((name
                   (string-downcase
                    (trim-http-optional-whitespace
                     (subseq trimmed 0 equals))))
                 (encoded
                   (trim-http-optional-whitespace
                    (subseq trimmed (1+ equals))))
                 (value
                   (if (and (plusp (length encoded))
                            (char= #\" (char encoded 0)))
                       (decode-http-quoted-string encoded)
                       (progn
                         (unless (and (plusp (length encoded))
                                      (every #'http-field-name-character-p
                                             encoded))
                           (model-error :invalid-http-media-type-parameter
                                        segment
                                        "unquoted media parameter must be a token"))
                         encoded))))
            (unless (and (plusp (length name))
                         (every #'http-field-name-character-p name))
              (model-error :invalid-http-media-type-parameter-name name
                           "media parameter name must be an HTTP token"))
            (when (gethash name seen)
              (model-error :duplicate-http-media-type-parameter name
                           "media parameter occurs more than once"))
            (setf (gethash name seen) t)
            (push (cons name value) parameters))))
      (%make-http-media-type
       (copy-seq raw) (string-downcase type) (string-downcase subtype)
       (nreverse parameters)))))

(defun http-media-type-parameter (media-type name)
  (unless (http-media-type-p media-type)
    (model-error :invalid-http-media-type-object media-type
                 "value must be a parsed HTTP media type"))
  (unless (stringp name)
    (model-error :invalid-http-media-type-parameter-lookup name
                 "media parameter lookup name must be a string"))
  (cdr (assoc (string-downcase name)
              (http-media-type-parameters media-type) :test #'string=)))

(defstruct (caldav-read-intent
            (:constructor %make-caldav-read-intent
                (method href entity-tag headers)))
  (method "GET" :type string :read-only t)
  (href "" :type string :read-only t)
  (entity-tag nil :type (or null http-entity-tag) :read-only t)
  (headers nil :type list :read-only t))

(defun make-caldav-get-intent (&key href entity-tag)
  "Create a transport-neutral GET intent; no network action is performed."
  (validate-caldav-resource-href href)
  (let ((tag
          (and entity-tag
               (if (http-entity-tag-p entity-tag)
                   (parse-http-entity-tag (http-entity-tag-raw entity-tag))
                   (parse-http-entity-tag entity-tag)))))
    (%make-caldav-read-intent
     "GET" (copy-seq href) tag
     (append
      (list (list "Accept" "text/calendar")
            (list "Accept-Encoding" "identity"))
      (and tag
           (list (list "If-None-Match" (http-entity-tag-raw tag))))))))

(defstruct (caldav-read-outcome
            (:constructor %make-caldav-read-outcome
                (kind status href entity-tag media-type location body-octets
                 calendar-input diagnostics &optional schedule-tag)))
  (kind :failure :type keyword :read-only t)
  (status 500 :type (integer 100 599) :read-only t)
  (href "" :type string :read-only t)
  (entity-tag nil :type (or null http-entity-tag) :read-only t)
  (media-type nil :type (or null http-media-type) :read-only t)
  (location nil :type (or null string) :read-only t)
  (body-octets nil :type (or null vector) :read-only t)
  (calendar-input nil :type (or null ical-octet-input) :read-only t)
  (diagnostics nil :type list :read-only t)
  (schedule-tag nil :type (or null caldav-schedule-tag) :read-only t))

(defun caldav-read-diagnostic (code message body-length
                               &key (loss-risk :security))
  (make-diagnostic
   :severity :fatal :code code :message message :loss-risk loss-risk
   :span (make-source-span
          :source-id "caldav-resource-response"
          :character-start 0 :character-end 0
          :byte-start 0 :byte-end body-length)))

(defun caldav-component-read-diagnostic (component code message)
  (make-diagnostic :severity :error :code code :message message
                   :span (ical-component-span component) :loss-risk :loss))

(defun caldav-calendar-resource-shape-diagnostics (input)
  (let ((document (ical-octet-input-document input))
        (diagnostics nil))
    (unless document
      (return-from caldav-calendar-resource-shape-diagnostics nil))
    (let ((roots (ical-document-components document)))
      (unless (and (= 1 (length roots))
                   (string= "VCALENDAR"
                            (ical-component-normalized-name (first roots))))
        (return-from caldav-calendar-resource-shape-diagnostics
          (list
           (caldav-read-diagnostic
            :invalid-caldav-resource-root
            "calendar resource must contain exactly one VCALENDAR root"
            (length (ical-octet-input-octets input))
            :loss-risk :loss))))
      (let* ((calendar (first roots))
             (method-lines
               (ical-component-properties-named calendar "METHOD"))
             (items
               (remove-if
                (lambda (component)
                  (string= "VTIMEZONE"
                           (ical-component-normalized-name component)))
                (ical-component-children calendar)))
             (timezones
               (remove-if-not
                (lambda (component)
                  (string= "VTIMEZONE"
                           (ical-component-normalized-name component)))
                (ical-component-children calendar)))
             (item-kinds
               (remove-duplicates
                (mapcar #'ical-component-normalized-name items)
                :test #'string=))
             (item-uids nil)
             (timezone-identifiers nil)
             (timezone-references nil))
        (when method-lines
          (push (caldav-component-read-diagnostic
                 calendar :caldav-resource-method-property
                 "CalDAV calendar object resources must not contain METHOD")
                diagnostics))
        (unless items
          (push (caldav-component-read-diagnostic
                 calendar :missing-caldav-resource-component
                 "CalDAV resource requires a non-VTIMEZONE calendar component")
                diagnostics))
        (when (rest item-kinds)
          (push (caldav-component-read-diagnostic
                 calendar :mixed-caldav-resource-component-types
                 "CalDAV resource contains more than one calendar component type")
                diagnostics))
        (dolist (component items)
          (multiple-value-bind (index properties property-diagnostics)
              (ical-property-index component)
            (declare (ignore properties))
            (setf diagnostics (nconc diagnostics property-diagnostics))
            (let ((uids (ical-index-properties index "UID")))
              (if (= 1 (length uids))
                  (let ((uid (ical-first-decoded-value index "UID")))
                    (if (non-empty-string-p uid)
                        (push uid item-uids)
                        (push (caldav-component-read-diagnostic
                               component :invalid-caldav-resource-uid
                               "calendar component UID must be non-empty")
                              diagnostics)))
                  (push (caldav-component-read-diagnostic
                         component :invalid-caldav-resource-uid-cardinality
                         "calendar component requires exactly one UID")
                        diagnostics)))
            (let ((name (ical-component-normalized-name component)))
              (cond
                ((member name '("VEVENT" "VTODO" "VJOURNAL") :test #'string=)
                 (let ((item (project-ical-component component)))
                   (setf diagnostics
                         (nconc diagnostics
                                (copy-list
                                 (ical-calendar-item-diagnostics item))))))
                ((string= name "VFREEBUSY")
                 (let ((freebusy
                         (project-ical-freebusy-component component)))
                   (setf diagnostics
                         (nconc
                          diagnostics
                          (copy-list
                           (ical-freebusy-diagnostics freebusy))))))
                ((string= name "VAVAILABILITY")
                 (let ((availability
                         (project-ical-availability-component component)))
                   (setf diagnostics
                         (nconc
                          diagnostics
                          (copy-list
                           (ical-availability-diagnostics availability)))))))))
          (setf timezone-references
                (nconc timezone-references
                       (caldav-component-timezone-references component))))
        (when (and item-uids
                   (rest (remove-duplicates item-uids :test #'string=)))
          (push (caldav-component-read-diagnostic
                 calendar :mixed-caldav-resource-uids
                 "all calendar components in one resource require one UID")
                diagnostics))
        (dolist (component timezones)
          (let ((timezone (project-ical-timezone-component component)))
            (setf diagnostics
                  (nconc diagnostics
                         (copy-list
                          (ical-timezone-definition-diagnostics timezone))))
            (when (ical-timezone-definition-timezone-id timezone)
              (push (ical-timezone-definition-timezone-id timezone)
                    timezone-identifiers))))
        (when (/= (length timezone-identifiers)
                  (length (remove-duplicates timezone-identifiers
                                             :test #'string=)))
          (push (caldav-component-read-diagnostic
                 calendar :duplicate-caldav-resource-timezone
                 "calendar resource contains duplicate VTIMEZONE identifiers")
                diagnostics))
        (dolist (reference
                 (remove-duplicates timezone-references :test #'string=))
          (unless (member reference timezone-identifiers :test #'string=)
            (push (caldav-component-read-diagnostic
                   calendar :missing-caldav-resource-timezone
                   "calendar resource lacks VTIMEZONE for a referenced TZID")
                  diagnostics)))))
    (nreverse diagnostics)))

(defun caldav-calendar-resource-common-uid (input)
  "Return the one UID proven by a complete admitted calendar resource.

This extractor is deliberately component-neutral.  It relies on the shared
CalDAV resource-shape boundary, so registered extension components remain
source-preserved while the Section 4.1 one-kind and one-UID invariants still
apply."
  (unless (ical-octet-input-p input)
    (model-error :invalid-caldav-resource-input input
                 "calendar resource identity requires typed octet input"))
  (let ((diagnostics (caldav-calendar-resource-shape-diagnostics input)))
    (when diagnostics
      (model-error :invalid-caldav-resource-identity diagnostics
                   "calendar resource identity requires an admitted complete resource")))
  (let* ((document (ical-octet-input-document input))
         (calendar (first (ical-document-components document)))
         (component
           (find-if
            (lambda (candidate)
              (not (string= "VTIMEZONE"
                            (ical-component-normalized-name candidate))))
            (ical-component-children calendar))))
    (multiple-value-bind (index properties diagnostics)
        (ical-property-index component)
      (declare (ignore properties))
      (when diagnostics
        (model-error :invalid-caldav-resource-identity diagnostics
                     "calendar resource UID evidence is invalid"))
      (let ((uid (ical-first-decoded-value index "UID")))
        (unless (non-empty-string-p uid)
          (model-error :invalid-caldav-resource-identity uid
                       "calendar resource UID must be nonempty"))
        (copy-seq uid)))))

(defun parse-http-content-length (raw)
  (let ((trimmed (trim-http-optional-whitespace raw)))
    (unless (and (plusp (length trimmed))
                 (every #'digit-char-p trimmed))
      (model-error :invalid-http-content-length raw
                   "Content-Length must be one non-negative decimal integer"))
    (parse-integer trimmed)))

(defun http-entity-tags-weakly-equal-p (first second)
  (and first second
       (string= (http-entity-tag-opaque first)
                (http-entity-tag-opaque second))))

(defun classify-caldav-get-response
    (intent status headers body-octets
     &key (max-header-count 256) (max-header-octets 65536)
          (max-body-octets 16777216))
  "Validate one decoded GET response without retrying or following redirects."
  (unless (caldav-read-intent-p intent)
    (model-error :invalid-caldav-read-intent intent
                 "GET response classification requires a read intent"))
  (unless (and (integerp status) (<= 100 status 599))
    (model-error :invalid-http-status status
                 "HTTP response status must be from 100 through 599"))
  (unless (and (integerp max-body-octets) (not (minusp max-body-octets)))
    (model-error :invalid-caldav-response-body-limit max-body-octets
                 "response body limit must be a non-negative integer"))
  (unless (vectorp body-octets)
    (model-error :invalid-caldav-response-body body-octets
                 "response body must be an octet vector"))
  (validate-http-response-headers
   headers :max-header-count max-header-count
   :max-header-octets max-header-octets)
  (let* ((etag-text
           (caldav-single-response-header headers "ETag" :validated-p t))
         (etag (and etag-text (parse-http-entity-tag etag-text)))
         (schedule-tag-text
           (caldav-single-response-header
            headers "Schedule-Tag" :validated-p t))
         (schedule-tag
           (and schedule-tag-text
                (parse-caldav-schedule-tag schedule-tag-text)))
         (location
           (caldav-single-response-header headers "Location" :validated-p t))
         (content-type-text
           (caldav-single-response-header
            headers "Content-Type" :validated-p t))
         (content-encoding
           (caldav-single-response-header
            headers "Content-Encoding" :validated-p t))
         (content-length-text
           (caldav-single-response-header
            headers "Content-Length" :validated-p t))
         (body-length (length body-octets)))
    (when (> body-length max-body-octets)
      (return-from classify-caldav-get-response
        (%make-caldav-read-outcome
         :quarantined status (caldav-read-intent-href intent) etag nil
         location nil nil
         (list
          (caldav-read-diagnostic
           :caldav-response-body-limit-exceeded
           "calendar response exceeds the configured byte limit"
           body-length))
         schedule-tag)))
    (loop :for octet :across body-octets
          :for index :from 0
          :unless (typep octet '(unsigned-byte 8))
            :do (model-error :invalid-caldav-response-octet octet
                             "response byte ~d is not an unsigned octet"
                             index))
    (when (and (= status 200) content-length-text)
      (unless (= (parse-http-content-length content-length-text) body-length)
        (return-from classify-caldav-get-response
          (%make-caldav-read-outcome
           :quarantined status (caldav-read-intent-href intent) etag nil
           location (copy-ical-octets body-octets) nil
           (list
            (caldav-read-diagnostic
             :caldav-response-content-length-mismatch
             "Content-Length does not match the received representation"
             body-length))
           schedule-tag))))
    (cond
      ((= status 304)
       (unless (caldav-read-intent-entity-tag intent)
         (model-error :unexpected-caldav-not-modified status
                      "304 response requires a conditional GET intent"))
       (unless (strong-http-entity-tag-p etag)
         (model-error :caldav-not-modified-requires-strong-etag etag
                      "CalDAV 304 response requires the current strong ETag"))
       (unless (zerop body-length)
         (model-error :caldav-not-modified-response-body body-length
                      "304 response cannot contain content"))
       (when (not (http-entity-tags-weakly-equal-p
                   etag (caldav-read-intent-entity-tag intent)))
         (model-error :mismatched-caldav-not-modified-etag etag
                      "304 ETag differs from the conditional validator"))
       (%make-caldav-read-outcome
        :not-modified status (caldav-read-intent-href intent)
        etag nil location
        (copy-ical-octets body-octets) nil nil schedule-tag))
      ((= status 200)
       (let ((media-type nil)
             (diagnostics nil)
             (calendar-input nil)
             (raw-octets nil)
             (media-valid-p t))
         (unless (strong-http-entity-tag-p etag)
           (push (caldav-read-diagnostic
                  :caldav-get-requires-strong-etag
                  "CalDAV GET calendar resource requires a strong ETag"
                  body-length)
                 diagnostics))
         (if content-type-text
             (handler-case
                 (setf media-type (parse-http-media-type content-type-text))
               (semantic-model-error (condition)
                 (setf media-valid-p nil)
                 (push (caldav-read-diagnostic
                        :invalid-caldav-calendar-content-type
                        (semantic-model-error-message condition) body-length)
                       diagnostics)))
             (progn
               (setf media-valid-p nil)
               (push (caldav-read-diagnostic
                      :missing-caldav-calendar-content-type
                      "calendar resource response lacks Content-Type"
                      body-length)
                     diagnostics)))
         (when media-type
           (unless (and (string= "text" (http-media-type-type media-type))
                        (string= "calendar"
                                 (http-media-type-subtype media-type)))
             (setf media-valid-p nil)
             (push (caldav-read-diagnostic
                    :unsupported-caldav-calendar-media-type
                    "calendar resource response must be text/calendar"
                    body-length)
                   diagnostics))
           (let ((charset (http-media-type-parameter media-type "charset")))
             (unless (or (null charset)
                         (string-equal charset "utf-8")
                         (string-equal charset "us-ascii"))
               (setf media-valid-p nil)
               (push (caldav-read-diagnostic
                      :unsupported-caldav-calendar-charset
                      "calendar response charset must be UTF-8 or US-ASCII"
                      body-length)
                     diagnostics))
             (when (and charset (string-equal charset "us-ascii")
                        (not (every (lambda (octet) (<= octet #x7f))
                                    body-octets)))
               (setf media-valid-p nil)
               (push (caldav-read-diagnostic
                      :invalid-caldav-us-ascii-body
                      "US-ASCII calendar response contains a non-ASCII octet"
                      body-length)
                     diagnostics)))
           (when (http-media-type-parameter media-type "method")
             (setf media-valid-p nil)
             (push (caldav-read-diagnostic
                    :caldav-resource-content-type-method
                    "stored CalDAV resources cannot carry a method parameter"
                    body-length :loss-risk :loss)
                   diagnostics)))
         (when (and content-encoding
                    (not (string-equal
                          "identity"
                          (trim-http-optional-whitespace content-encoding))))
           (setf media-valid-p nil)
           (push (caldav-read-diagnostic
                  :unsupported-caldav-content-encoding
                  "calendar response uses an unsupported content coding"
                  body-length)
                 diagnostics))
         (if media-valid-p
             (progn
               (setf calendar-input
                     (parse-icalendar-octets
                      body-octets :source-id "caldav-resource-response.ics"
                      :max-input-octets max-body-octets)
                     raw-octets (ical-octet-input-octets calendar-input)
                     diagnostics
                     (nconc diagnostics
                            (copy-list
                             (ical-octet-input-diagnostics calendar-input))))
               (when (ical-octet-input-document calendar-input)
                 (setf diagnostics
                       (nconc diagnostics
                              (caldav-calendar-resource-shape-diagnostics
                               calendar-input)))))
             (setf raw-octets (copy-ical-octets body-octets)))
         (%make-caldav-read-outcome
          (if diagnostics :quarantined :resource)
          status (caldav-read-intent-href intent) etag media-type location
          raw-octets calendar-input diagnostics schedule-tag)))
      ((and (<= 300 status 399) (/= status 304))
       (%make-caldav-read-outcome
        :redirect status (caldav-read-intent-href intent) etag nil location
        (copy-ical-octets body-octets) nil nil schedule-tag))
      ((member status '(404 410))
       (%make-caldav-read-outcome
        :missing status (caldav-read-intent-href intent) etag nil location
        (copy-ical-octets body-octets) nil nil schedule-tag))
      (t
       (%make-caldav-read-outcome
        :failure status (caldav-read-intent-href intent) etag nil location
        (copy-ical-octets body-octets) nil nil schedule-tag)))))
