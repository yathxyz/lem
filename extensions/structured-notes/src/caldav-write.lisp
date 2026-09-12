(in-package #:lem-structured-notes)

(defstruct (http-entity-tag
            (:constructor %make-http-entity-tag (raw opaque weak-p)))
  (raw "" :type string :read-only t)
  (opaque "" :type string :read-only t)
  (weak-p nil :type boolean :read-only t))

(defun http-etag-character-p (character)
  (let ((code (char-code character)))
    (or (= code #x21) (<= #x23 code #x7e) (<= #x80 code #xff))))

(defun parse-http-entity-tag (raw)
  "Parse one RFC 9110 entity-tag field value without interpreting its opacity."
  (unless (stringp raw)
    (model-error :invalid-http-entity-tag raw
                 "HTTP entity tag must be a string"))
  (let* ((weak-p (and (>= (length raw) 2)
                      (string= "W/" raw :end2 2)))
         (quoted (if weak-p (subseq raw 2) raw)))
    (unless (and (>= (length quoted) 2)
                 (char= #\" (char quoted 0))
                 (char= #\" (char quoted (1- (length quoted))))
                 (every #'http-etag-character-p
                        (subseq quoted 1 (1- (length quoted)))))
      (model-error :invalid-http-entity-tag raw
                   "HTTP entity tag must match RFC 9110 entity-tag grammar"))
    (%make-http-entity-tag
     (copy-seq raw) (subseq quoted 1 (1- (length quoted))) weak-p)))

(defun strong-http-entity-tag-p (value)
  (and (http-entity-tag-p value) (not (http-entity-tag-weak-p value))))

(defun require-strong-http-entity-tag (value label)
  (let ((tag (if (http-entity-tag-p value)
                 value
                 (parse-http-entity-tag value))))
    (unless (strong-http-entity-tag-p tag)
      (model-error :weak-http-entity-tag value
                   "~a requires a strong entity tag" label))
    tag))

(defstruct (caldav-schedule-tag
            (:constructor %make-caldav-schedule-tag (raw opaque)))
  (raw "" :type string :read-only t)
  (opaque "" :type string :read-only t))

(defun parse-caldav-schedule-tag (raw)
  "Parse one RFC 6638 opaque schedule tag without treating it as an ETag."
  (let ((entity-tag (require-strong-http-entity-tag raw "CalDAV Schedule-Tag")))
    (%make-caldav-schedule-tag
     (copy-seq (http-entity-tag-raw entity-tag))
     (copy-seq (http-entity-tag-opaque entity-tag)))))

(defstruct (caldav-rscale-write-proof
            (:constructor %make-caldav-rscale-write-proof
                (collection-href kind supported-rscales property-status)))
  (collection-href "" :type string :read-only t)
  (kind :any :type (member :any :explicit) :read-only t)
  (supported-rscales nil :type list :read-only t)
  (property-status 200 :type (integer 200 299) :read-only t))

(defun make-caldav-rscale-write-proof
    (collection-href kind supported-rscales property-status)
  (validate-caldav-resource-href collection-href)
  (unless (member kind '(:any :explicit))
    (model-error :invalid-caldav-rscale-write-proof-kind kind
                 "RSCALE write proof must be ANY or EXPLICIT"))
  (unless (<= 200 property-status 299)
    (model-error :invalid-caldav-rscale-write-proof-status property-status
                 "RSCALE write proof requires a successful property status"))
  (let ((scales
          (copy-proper-list supported-rscales
                            :invalid-caldav-rscale-write-proof
                            "supported RSCALE values")))
    (dolist (scale scales)
      (unless (and (stringp scale) (<= (length scale) 1024)
                   (ical-token-p scale))
        (model-error :invalid-caldav-rscale-write-proof-value scale
                     "RSCALE write proof values must be bounded tokens")))
    (when (/= (length scales)
              (length (remove-duplicates scales :test #'string-equal)))
      (model-error :duplicate-caldav-rscale-write-proof-value scales
                   "RSCALE write proof values must be unique"))
    (when (and (eq kind :explicit) (null scales))
      (model-error :empty-caldav-rscale-write-proof scales
                   "explicit RSCALE write proof requires at least one value"))
    (when (and (eq kind :any) scales)
      (model-error :unexpected-caldav-rscale-write-proof-values scales
                   "ANY RSCALE write proof cannot carry explicit values"))
    (%make-caldav-rscale-write-proof
     (copy-seq collection-href) kind
     (mapcar (lambda (scale) (string-upcase (copy-seq scale))) scales)
     property-status)))

(defun require-caldav-schedule-tag (value)
  (if (caldav-schedule-tag-p value)
      (parse-caldav-schedule-tag (caldav-schedule-tag-raw value))
      (parse-caldav-schedule-tag value)))

(defun validate-caldav-resource-href (href)
  (unless (stringp href)
    (model-error :invalid-caldav-resource-href href
                 "CalDAV resource target must be an HTTPS URI string"))
  (let ((decoded (decode-ical-value href :uri)))
    (unless (ical-value-valid-p decoded)
      (model-error :invalid-caldav-resource-href href
                   "CalDAV resource target is not an absolute URI"))
    (let ((uri (ical-value-decoded decoded)))
      (unless (and (string-equal "https" (ical-uri-value-scheme uri))
                   (ical-uri-value-authority uri)
                   (non-empty-string-p (ical-uri-value-host uri))
                   (null (ical-uri-value-userinfo uri))
                   (null (ical-uri-value-fragment uri)))
        (model-error :unsafe-caldav-resource-href href
                     "CalDAV resources require HTTPS authority without userinfo or fragment"))))
  href)

(defstruct (caldav-timezone-reference-write-proof
            (:constructor %make-caldav-timezone-reference-write-proof
                (service-uri cache-sha256 admitted-at expires-at
                 timezone-ids timezone-sources)))
  (service-uri "" :type string :read-only t)
  (cache-sha256 "" :type string :read-only t)
  (admitted-at 0 :type (integer 0 *) :read-only t)
  (expires-at 0 :type (integer 0 *) :read-only t)
  (timezone-ids nil :type list :read-only t)
  (timezone-sources nil :type list :read-only t))

(defstruct (caldav-write-intent
            (:constructor %make-caldav-write-intent
                (operation method href entity-tag schedule-tag schedule-reply
                 return-preference validation-profile body headers
                 rscale-write-proof timezone-reference-write-proof)))
  (operation :update :type keyword :read-only t)
  (method "PUT" :type string :read-only t)
  (href "" :type string :read-only t)
  (entity-tag nil :type (or null http-entity-tag) :read-only t)
  (schedule-tag nil :type (or null caldav-schedule-tag) :read-only t)
  (schedule-reply nil :type (member nil :notify :suppress) :read-only t)
  (return-preference nil
                     :type (member nil :minimal :representation)
                     :read-only t)
  (validation-profile :calendar-object
                      :type (member :calendar-object
                                    :availability-resource)
                      :read-only t)
  (body nil :type (or null string) :read-only t)
  (headers nil :type list :read-only t)
  (rscale-write-proof nil
                      :type (or null caldav-rscale-write-proof)
                      :read-only t)
  (timezone-reference-write-proof nil
                                  :type (or null
                                            caldav-timezone-reference-write-proof)
                                  :read-only t))

(defun caldav-component-timezone-references (component)
  (labels ((walk (current)
             (nconc
              (loop :for line :in (ical-component-properties current)
                    :nconc
                    (loop :for parameter
                            :in (ical-content-line-parameters line)
                          :when (string= "TZID"
                                         (ical-parameter-normalized-name
                                          parameter))
                            :nconc
                            (mapcar #'ical-parameter-value-decoded-text
                                    (ical-parameter-values parameter))))
              (loop :for child :in (ical-component-children current)
                    :nconc (walk child)))))
    (walk component)))

(defun caldav-timezone-reference-proof-definition (source source-id)
  (unless (and (stringp source) (plusp (length source)))
    (model-error :invalid-caldav-timezone-reference-proof-source source
                 "timezone omission proof source must be nonempty text"))
  (let* ((document (parse-icalendar-cst source :source-id source-id))
         (roots (ical-document-components document)))
    (unless (and (= 1 (length roots))
                 (string= "VTIMEZONE"
                          (ical-component-normalized-name (first roots))))
      (model-error :invalid-caldav-timezone-reference-proof-source source
                   "timezone omission proof source must be one VTIMEZONE"))
    (let ((definition (project-ical-timezone-component (first roots))))
      (unless (ical-timezone-definition-valid-p definition)
        (model-error :invalid-caldav-timezone-reference-proof-source source
                     "timezone omission proof requires a valid VTIMEZONE"))
      definition)))

(defun make-caldav-timezone-reference-write-proof
    (&key service-uri cache-sha256 admitted-at expires-at
          timezone-ids timezone-sources)
  "Freeze the exact timezone definitions that validated one omitted-zone PUT."
  (validate-caldav-resource-href service-uri)
  (multiple-value-bind (service valid-p message)
      (decode-ical-uri service-uri)
    (declare (ignore message))
    (unless (and valid-p (null (ical-uri-value-query service)))
      (model-error :invalid-caldav-timezone-reference-proof-service
                   service-uri
                   "timezone omission proof service URI cannot contain a query")))
  (unless (and (stringp cache-sha256) (= 64 (length cache-sha256))
               (every (lambda (character)
                        (or (digit-char-p character)
                            (find character "abcdef" :test #'char=)))
                      cache-sha256))
    (model-error :invalid-caldav-timezone-reference-proof-digest cache-sha256
                 "timezone omission proof requires lowercase SHA-256"))
  (unless (and (integerp admitted-at) (<= 0 admitted-at)
               (integerp expires-at) (< admitted-at expires-at))
    (model-error :invalid-caldav-timezone-reference-proof-time
                 (list admitted-at expires-at)
                 "timezone omission proof requires a fresh admission interval"))
  (unless (and (proper-list-p timezone-ids) timezone-ids
               (proper-list-p timezone-sources)
               (= (length timezone-ids) (length timezone-sources))
               (<= (length timezone-ids) 65535)
               (= (length timezone-ids)
                  (length (remove-duplicates timezone-ids :test #'string=))))
    (model-error :invalid-caldav-timezone-reference-proof-set
                 (list timezone-ids timezone-sources)
                 "timezone omission proof requires distinct paired IDs and definitions"))
  (loop :for timezone-id :in timezone-ids
        :for source :in timezone-sources
        :for index :from 1
        :for definition :=
          (caldav-timezone-reference-proof-definition
           source (format nil "timezone-omission-proof-~d.ics" index))
        :unless (and (non-empty-string-p timezone-id)
                     (string= timezone-id
                              (ical-timezone-definition-timezone-id definition)))
          :do (model-error :mismatched-caldav-timezone-reference-proof
                           (list timezone-id source)
                           "timezone omission proof ID differs from its VTIMEZONE"))
  (%make-caldav-timezone-reference-write-proof
   (copy-seq service-uri) (copy-seq cache-sha256) admitted-at expires-at
   (mapcar #'copy-seq timezone-ids) (mapcar #'copy-seq timezone-sources)))

(defun caldav-timezone-reference-proof-provider (proof href body)
  (unless (caldav-timezone-reference-write-proof-p proof)
    (model-error :invalid-caldav-timezone-reference-write-proof proof
                 "timezone omission requires a typed immutable proof"))
  (validate-caldav-resource-href href)
  (let* ((validated
           (make-caldav-timezone-reference-write-proof
            :service-uri
            (caldav-timezone-reference-write-proof-service-uri proof)
            :cache-sha256
            (caldav-timezone-reference-write-proof-cache-sha256 proof)
            :admitted-at
            (caldav-timezone-reference-write-proof-admitted-at proof)
            :expires-at
            (caldav-timezone-reference-write-proof-expires-at proof)
            :timezone-ids
            (caldav-timezone-reference-write-proof-timezone-ids proof)
            :timezone-sources
            (caldav-timezone-reference-write-proof-timezone-sources proof)))
         (document (parse-icalendar-cst body :source-id "timezone-reference-write.ics"))
         (roots (ical-document-components document))
         (calendar (and (= 1 (length roots)) (first roots)))
         (embedded
           (and calendar
                (loop :for component :in (ical-component-children calendar)
                      :when (string= "VTIMEZONE"
                                     (ical-component-normalized-name component))
                        :collect
                        (ical-timezone-definition-timezone-id
                         (project-ical-timezone-component component)))))
         (referenced
           (and calendar
                (remove-duplicates
                 (caldav-component-timezone-references calendar)
                 :test #'string=)))
         (proof-ids
           (caldav-timezone-reference-write-proof-timezone-ids validated)))
    (unless (and calendar
                 (every (lambda (timezone-id)
                          (and (member timezone-id referenced :test #'string=)
                               (not (member timezone-id embedded :test #'string=))))
                        proof-ids))
      (model-error :unbound-caldav-timezone-reference-write-proof proof
                   "timezone omission proof must cover referenced definitions absent from the body"))
    (make-embedded-timezone-provider
     (loop :for source
             :in (caldav-timezone-reference-write-proof-timezone-sources
                  validated)
           :for index :from 1
           :collect
           (caldav-timezone-reference-proof-definition
            source (format nil "timezone-omission-provider-~d.ics" index)))
     :version
     (format nil "rfc7809/~a"
             (caldav-timezone-reference-write-proof-cache-sha256 validated)))))

(defun validate-caldav-write-intent-body (intent)
  "Revalidate an intent body with every typed capability proof it carries."
  (unless (and (caldav-write-intent-p intent)
               (caldav-write-intent-body intent))
    (model-error :invalid-caldav-write-intent-body intent
                 "write intent body validation requires a body-bearing intent"))
  (let ((proof (caldav-write-intent-timezone-reference-write-proof intent)))
    (validate-caldav-write-body
     (caldav-write-intent-body intent)
     :timezone-provider
     (and proof
          (caldav-timezone-reference-proof-provider
           proof (caldav-write-intent-href intent)
           (caldav-write-intent-body intent))))))

(defun caldav-component-rscales (component)
  (labels ((walk (current)
             (nconc
              (loop :for line :in (ical-component-properties current)
                    :when (string= "RRULE"
                                   (ical-content-line-normalized-name line))
                      :nconc
                      (multiple-value-bind (rule valid-p message)
                          (decode-ical-recur (ical-content-line-value line))
                        (unless valid-p
                          (model-error :invalid-caldav-write-rscale-rule
                                       line "invalid RRULE in write body: ~a"
                                       message))
                        (let ((scale
                                (ical-recur-value-recurrence-scale rule)))
                          (if scale (list scale) nil))))
              (loop :for child :in (ical-component-children current)
                    :nconc (walk child)))))
    (remove-duplicates (walk component) :test #'string-equal)))

(defun validate-caldav-write-body (source &key timezone-provider)
  "Validate one stored calendar body, optionally resolving omitted TZIDs.

TIMEZONE-PROVIDER is closed caller-supplied authority.  It does not relax
calendar syntax or component validation; it only satisfies a TZID reference
whose VTIMEZONE is absent from SOURCE."
  (unless (stringp source)
    (model-error :invalid-caldav-write-body source
                 "CalDAV write body must be an iCalendar string"))
  (unless (or (null timezone-provider)
              (typep timezone-provider 'timezone-provider))
    (model-error :invalid-caldav-write-timezone-provider timezone-provider
                 "external timezone authority must be a typed provider"))
  (let* ((document
           (parse-icalendar-cst source :source-id "caldav-write-body.ics"))
         (roots (ical-document-components document)))
    (when (or (ical-document-diagnostics document) (/= 1 (length roots)))
      (model-error :invalid-caldav-write-body
                   (ical-document-diagnostics document)
                   "CalDAV body must be one structurally valid VCALENDAR"))
    (let* ((envelope (project-ical-calendar-envelope (first roots)))
           (method-present-p
             (not (null (ical-calendar-envelope-method envelope))))
           (item-kinds nil)
           (item-uids nil)
           (timezone-identifiers nil)
           (timezone-references nil))
      (unless (ical-calendar-envelope-valid-p envelope)
        (model-error :invalid-caldav-write-envelope
                     (ical-calendar-envelope-diagnostics envelope)
                     "CalDAV body has an invalid VCALENDAR envelope"))
      (when method-present-p
        (model-error :caldav-write-method-property
                     (ical-calendar-envelope-method envelope)
                     "CalDAV calendar object resources must not contain METHOD"))
      (dolist (component (ical-calendar-envelope-components envelope))
        (let ((name (ical-component-normalized-name component)))
          (cond
            ((member name '("VEVENT" "VTODO" "VJOURNAL") :test #'string=)
             (let ((item
                     (project-ical-component
                      component :method-present-p method-present-p)))
               (unless (ical-calendar-item-valid-p item)
                 (model-error :invalid-caldav-write-item
                              (ical-calendar-item-diagnostics item)
                              "CalDAV body contains an invalid calendar item"))
               (push name item-kinds)
               (push (ical-calendar-item-uid item) item-uids)
               (setf timezone-references
                     (nconc timezone-references
                            (caldav-component-timezone-references
                             component)))))
            ((string= name "VFREEBUSY")
             (let ((freebusy (project-ical-freebusy-component component)))
               (unless (ical-freebusy-valid-p freebusy)
                 (model-error
                  :invalid-caldav-write-freebusy
                  (ical-freebusy-diagnostics freebusy)
                  "CalDAV body contains an invalid VFREEBUSY"))
               (push name item-kinds)
               (push (ical-freebusy-uid freebusy) item-uids)))
            ((string= name "VAVAILABILITY")
             (let ((availability
                     (project-ical-availability-component component)))
               (unless (ical-availability-valid-p availability)
                 (model-error
                  :invalid-caldav-write-availability
                  (ical-availability-diagnostics availability)
                  "CalDAV body contains an invalid VAVAILABILITY"))
               (push name item-kinds)
               (push (ical-availability-uid availability) item-uids)
               (setf timezone-references
                     (nconc timezone-references
                            (caldav-component-timezone-references
                             component)))))
            ((string= name "VTIMEZONE")
             (let ((timezone (project-ical-timezone-component component)))
               (unless (ical-timezone-definition-valid-p timezone)
                 (model-error
                  :invalid-caldav-write-timezone
                  (ical-timezone-definition-diagnostics timezone)
                  "CalDAV body contains an invalid VTIMEZONE"))
               (push (ical-timezone-definition-timezone-id timezone)
                     timezone-identifiers)))
            (t
             (model-error :unsupported-caldav-write-component name
                          "top-level component has no complete CalDAV write validator")))))
      (unless item-kinds
        (model-error :missing-caldav-write-calendar-component nil
                     "CalDAV body requires one supported calendar component type"))
      (unless (= 1 (length (remove-duplicates item-kinds :test #'string=)))
        (model-error :mixed-caldav-write-component-types item-kinds
                     "one CalDAV resource cannot mix calendar component types"))
      (unless (= 1 (length (remove-duplicates item-uids :test #'string=)))
        (model-error :mixed-caldav-write-component-uids item-uids
                     "all components in one CalDAV resource require one UID"))
      (unless (= (length timezone-identifiers)
                 (length (remove-duplicates timezone-identifiers
                                            :test #'string=)))
        (model-error :duplicate-caldav-write-timezone timezone-identifiers
                     "CalDAV body contains duplicate VTIMEZONE identifiers"))
      (dolist (reference
               (remove-duplicates timezone-references :test #'string=))
        (unless (or
                 (member reference timezone-identifiers :test #'string=)
                 (and timezone-provider
                      (find-timezone-definition timezone-provider reference)))
          (model-error :missing-caldav-write-timezone reference
                       "CalDAV body lacks VTIMEZONE for a referenced TZID")))
      (values source (first item-kinds) (first item-uids)
              (caldav-component-rscales (first roots)) document))))

(defun caldav-cyrus-defaultalerts-preservation-header (document)
  "Preserve Cyrus's X-JMAP-USEDEFAULTALERTS extension when it is present.

Cyrus otherwise rewrites a true value during some CalDAV PUTs.  Its extension
header is safe for other HTTP servers to ignore and is emitted only when the
validated request body actually carries the matching extension property."
  (labels ((contains-property-p (component)
             (or
              (find "X-JMAP-USEDEFAULTALERTS"
                    (ical-component-properties component)
                    :key #'ical-content-line-normalized-name
                    :test #'string=)
              (some #'contains-property-p
                    (ical-component-children component)))))
    (when (some #'contains-property-p (ical-document-components document))
      '(("X-Cyrus-rewrite-usedefaultalerts" "false")))))

(defun caldav-rscale-direct-member-p (collection-href resource-href)
  (multiple-value-bind (collection collection-valid-p collection-message)
      (decode-ical-uri collection-href)
    (declare (ignore collection-message))
    (multiple-value-bind (resource resource-valid-p resource-message)
        (decode-ical-uri resource-href)
      (declare (ignore resource-message))
      (and collection-valid-p resource-valid-p
           (dav-uri-same-origin-p collection resource)
           (null (ical-uri-value-query collection))
           (null (ical-uri-value-query resource))
           (let* ((path (ical-uri-value-path collection))
                  (prefix
                    (if (and (plusp (length path))
                             (char= #\/ (char path (1- (length path)))))
                        path (concatenate 'string path "/")))
                  (resource-path (ical-uri-value-path resource)))
             (and (> (length resource-path) (length prefix))
                  (string= prefix resource-path :end2 (length prefix))
                  (null (position #\/ resource-path
                                  :start (length prefix)))))))))

(defun validate-caldav-rscale-write-proof (href rscales proof)
  (cond
    ((null rscales)
     (when proof
       (model-error :unexpected-caldav-rscale-write-proof proof
                    "non-RSCALE write cannot carry RSCALE capability proof")))
    ((not (caldav-rscale-write-proof-p proof))
     (model-error :missing-caldav-rscale-write-proof rscales
                  "RSCALE write requires exact successful collection capability evidence"))
    ((not (caldav-rscale-direct-member-p
           (caldav-rscale-write-proof-collection-href proof) href))
     (model-error :mismatched-caldav-rscale-write-collection proof
                  "RSCALE proof collection does not directly contain the resource"))
    ((and (eq :explicit (caldav-rscale-write-proof-kind proof))
          (find-if-not
           (lambda (scale)
             (member scale
                     (caldav-rscale-write-proof-supported-rscales proof)
                     :test #'string-equal))
           rscales))
     (model-error :unsupported-caldav-rscale-write rscales
                  "RSCALE write contains a value absent from exact server capability")))
  t)

(defun make-caldav-write-intent
    (&key operation href body entity-tag schedule-tag schedule-reply
          return-preference rscale-write-proof
          timezone-reference-write-proof)
  "Create a transport-neutral conditional CalDAV write request.

CREATE uses If-None-Match: *.  UPDATE and DELETE retain one strong observed
ETag for reconciliation.  When SCHEDULE-TAG is supplied they use
If-Schedule-Tag-Match instead of If-Match.  This object performs no network
operation."
  (unless (member operation '(:create :update :delete))
    (model-error :invalid-caldav-write-operation operation
                 "CalDAV write operation must be CREATE, UPDATE, or DELETE"))
  (unless (member schedule-reply '(nil :notify :suppress))
    (model-error :invalid-caldav-schedule-reply schedule-reply
                 "Schedule-Reply choice must be NOTIFY, SUPPRESS, or absent"))
  (normalize-caldav-return-preference return-preference)
  (when (and (eq operation :delete)
             (eq return-preference :representation))
    (model-error :unsupported-caldav-delete-return-representation
                 return-preference
                 "DELETE cannot return the current representation of a deleted resource"))
  (validate-caldav-resource-href href)
  (let ((timezone-provider
          (and timezone-reference-write-proof
               (caldav-timezone-reference-proof-provider
                timezone-reference-write-proof href body)))
        (compatibility-headers nil))
  (ecase operation
    (:create
     (multiple-value-bind (validated component-kind uid rscales document)
         (validate-caldav-write-body body :timezone-provider timezone-provider)
       (declare (ignore validated uid))
       (setf compatibility-headers
             (caldav-cyrus-defaultalerts-preservation-header document))
       (validate-caldav-rscale-write-proof href rscales rscale-write-proof)
       (when (string= "VAVAILABILITY" component-kind)
         (model-error :caldav-availability-write-requires-collection-evidence
                      component-kind
                      "VAVAILABILITY PUT requires the collection-gated constructor")))
     (when entity-tag
       (model-error :unexpected-caldav-create-entity-tag entity-tag
                    "CalDAV creation uses If-None-Match instead of an ETag"))
     (when schedule-tag
       (model-error :unexpected-caldav-create-schedule-tag schedule-tag
                    "CalDAV creation has no prior scheduling object tag"))
     (when schedule-reply
       (model-error :unexpected-caldav-create-schedule-reply schedule-reply
                    "Schedule-Reply applies only to scheduling removal"))
     (%make-caldav-write-intent
      operation "PUT" href nil nil nil return-preference :calendar-object body
      (append
       '(("If-None-Match" "*")
         ("Content-Type" "text/calendar; charset=utf-8"))
       compatibility-headers
       (caldav-return-preference-header return-preference))
      rscale-write-proof timezone-reference-write-proof))
    (:update
     (multiple-value-bind (validated component-kind uid rscales document)
         (validate-caldav-write-body body :timezone-provider timezone-provider)
       (declare (ignore validated uid))
       (setf compatibility-headers
             (caldav-cyrus-defaultalerts-preservation-header document))
       (validate-caldav-rscale-write-proof href rscales rscale-write-proof)
       (when (string= "VAVAILABILITY" component-kind)
         (model-error :caldav-availability-write-requires-collection-evidence
                      component-kind
                      "VAVAILABILITY PUT requires the collection-gated constructor")))
     (when schedule-reply
       (model-error :unexpected-caldav-update-schedule-reply schedule-reply
                    "Schedule-Reply applies only to scheduling removal"))
     (let ((tag (require-strong-http-entity-tag entity-tag "CalDAV update"))
           (scheduling-tag
             (and schedule-tag (require-caldav-schedule-tag schedule-tag))))
       (%make-caldav-write-intent
        operation "PUT" href tag scheduling-tag nil return-preference
        :calendar-object body
        (append
         (list (list (if scheduling-tag
                         "If-Schedule-Tag-Match"
                         "If-Match")
                     (if scheduling-tag
                         (caldav-schedule-tag-raw scheduling-tag)
                         (http-entity-tag-raw tag)))
               '("Content-Type" "text/calendar; charset=utf-8"))
         compatibility-headers
         (caldav-return-preference-header return-preference))
        rscale-write-proof timezone-reference-write-proof)))
    (:delete
     (when rscale-write-proof
       (model-error :unexpected-caldav-delete-rscale-proof rscale-write-proof
                    "DELETE cannot carry RSCALE write capability proof"))
     (when body
       (model-error :unexpected-caldav-delete-body body
                    "CalDAV deletion cannot carry a representation body"))
     (when timezone-reference-write-proof
       (model-error :unexpected-caldav-delete-timezone-reference-proof
                    timezone-reference-write-proof
                    "DELETE cannot carry timezone omission proof"))
     (let ((tag (require-strong-http-entity-tag entity-tag "CalDAV delete"))
           (scheduling-tag
             (and schedule-tag (require-caldav-schedule-tag schedule-tag))))
       (when (and schedule-reply (null scheduling-tag))
         (model-error :schedule-reply-without-scheduling-validator
                      schedule-reply
                      "Schedule-Reply requires a scheduling resource tag"))
       (%make-caldav-write-intent
        operation "DELETE" href tag scheduling-tag schedule-reply
        return-preference :calendar-object nil
        (append
         (list
          (list (if scheduling-tag "If-Schedule-Tag-Match" "If-Match")
                (if scheduling-tag
                    (caldav-schedule-tag-raw scheduling-tag)
                    (http-entity-tag-raw tag))))
         (when schedule-reply
           (list
            (list "Schedule-Reply"
                  (if (eq schedule-reply :notify) "T" "F"))))
        (caldav-return-preference-header return-preference))
        nil nil))))))

(defun make-caldav-update-intent-from-plan
    (plan current-document &key href entity-tag schedule-tag
                           return-preference
                           (max-output-octets 16777216))
  "Bind a verified semantic edit plan to a strong remote update precondition."
  (make-caldav-write-intent
   :operation :update :href href :entity-tag entity-tag
   :schedule-tag schedule-tag :return-preference return-preference
   :body (apply-ical-semantic-edit-plan
          plan current-document :max-output-octets max-output-octets)))

(defstruct (caldav-write-conflict
            (:constructor %make-caldav-write-conflict
                (operation href status base-entity-tag reason)))
  (operation :update :type keyword :read-only t)
  (href "" :type string :read-only t)
  (status 412 :type (integer 100 599) :read-only t)
  (base-entity-tag nil :type (or null http-entity-tag) :read-only t)
  (reason :precondition-failed :type keyword :read-only t))

(defstruct (caldav-write-outcome
            (:constructor %make-caldav-write-outcome
                (kind status entity-tag schedule-tag location
                 refetch-required-p conflict)))
  (kind :failure :type keyword :read-only t)
  (status 500 :type (integer 100 599) :read-only t)
  (entity-tag nil :type (or null http-entity-tag) :read-only t)
  (schedule-tag nil :type (or null caldav-schedule-tag) :read-only t)
  (location nil :type (or null string) :read-only t)
  (refetch-required-p nil :type boolean :read-only t)
  (conflict nil :type (or null caldav-write-conflict) :read-only t))

(defun http-field-name-character-p (character)
  (let ((code (char-code character)))
    (or (<= (char-code #\A) code (char-code #\Z))
        (<= (char-code #\a) code (char-code #\z))
        (<= (char-code #\0) code (char-code #\9))
        (find character "!#$%&'*+-.^_`|~" :test #'char=))))

(defun http-field-value-character-p (character)
  (let ((code (char-code character)))
    (or (= code #x09)
        (<= #x20 code #x7e)
        (<= #x80 code #xff))))

(defun validate-http-response-headers
    (headers &key (max-header-count 256) (max-header-octets 65536))
  (unless (and (integerp max-header-count) (plusp max-header-count)
               (integerp max-header-octets) (plusp max-header-octets))
    (model-error :invalid-http-response-header-limits
                 (list max-header-count max-header-octets)
                 "HTTP response header limits must be positive integers"))
  (unless (proper-list-p headers)
    (model-error :invalid-caldav-response-headers headers
                 "response headers must be a finite list"))
  (when (> (length headers) max-header-count)
    (model-error :caldav-response-header-count-limit headers
                 "response contains more than ~d header fields"
                 max-header-count))
  (let ((total-octets 0))
    (dolist (header headers)
      (unless (and (consp header) (proper-list-p header)
                   (= 2 (length header))
                   (stringp (first header)) (stringp (second header)))
        (model-error :invalid-caldav-response-header header
                     "each response header must be a name and string value"))
      (unless (and (plusp (length (first header)))
                   (every #'http-field-name-character-p (first header))
                   (every #'http-field-value-character-p (second header)))
        (model-error :unsafe-caldav-response-header header
                     "response header contains invalid or unsafe characters"))
      (incf total-octets
            (+ (length (first header)) (length (second header)) 4))
      (when (> total-octets max-header-octets)
        (model-error :caldav-response-header-octet-limit total-octets
                     "response headers exceed the configured byte limit"))))
  headers)

(defun caldav-single-response-header (headers name &key validated-p)
  (unless validated-p
    (validate-http-response-headers headers))
  (let ((matches
          (remove-if-not
           (lambda (header)
             (string-equal name (first header)))
           headers)))
    (when (rest matches)
      (model-error :duplicate-caldav-response-header matches
                   "security-relevant response header occurs more than once"))
    (and matches (second (first matches)))))

(defun %classify-caldav-write-response (intent status headers)
  "Classify a write response without retrying, redirecting, or mutating state."
  (unless (caldav-write-intent-p intent)
    (model-error :invalid-caldav-write-intent intent
                 "response classification requires a write intent"))
  (unless (and (integerp status) (<= 100 status 599))
    (model-error :invalid-http-status status
                 "HTTP response status must be from 100 through 599"))
  (let* ((etag-text (caldav-single-response-header headers "ETag"))
         (schedule-tag-text
           (caldav-single-response-header headers "Schedule-Tag"))
         (location (caldav-single-response-header headers "Location"))
         (tag (and etag-text (parse-http-entity-tag etag-text)))
         (schedule-tag
           (and schedule-tag-text
                (parse-caldav-schedule-tag schedule-tag-text))))
    (cond
      ((member status '(409 412))
       (let ((conflict
               (%make-caldav-write-conflict
                (caldav-write-intent-operation intent)
                (caldav-write-intent-href intent) status
                (caldav-write-intent-entity-tag intent)
                (if (= status 412) :precondition-failed :resource-conflict))))
         (%make-caldav-write-outcome
          :conflict status tag schedule-tag location nil conflict)))
      ((= status 428)
       (%make-caldav-write-outcome
        :precondition-required status tag schedule-tag location nil nil))
      ((= status 202)
       ;; RFC 9110 Section 15.3.3 is deliberately noncommittal: acceptance
       ;; does not prove that the requested mutation has happened or ever
       ;; will happen.  Preserve the response for review without advancing
       ;; local state or issuing an unsafe retry.
       (%make-caldav-write-outcome
        :accepted status tag schedule-tag location nil nil))
      ((<= 200 status 299)
       (let ((refetch-p
               (or
                (and (member (caldav-write-intent-operation intent)
                             '(:create :update))
                     (not (strong-http-entity-tag-p tag)))
                (and (eq :update (caldav-write-intent-operation intent))
                     (not (null
                           (caldav-write-intent-schedule-tag intent)))))))
         (%make-caldav-write-outcome
          :success status tag schedule-tag location refetch-p nil)))
      ((<= 300 status 399)
       (%make-caldav-write-outcome
        :redirect status tag schedule-tag location nil nil))
      (t
       (%make-caldav-write-outcome
        :failure status tag schedule-tag location nil nil)))))
