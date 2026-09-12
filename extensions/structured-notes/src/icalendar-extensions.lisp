(in-package #:lem-structured-notes)

(defstruct (ical-publishing-component
            (:constructor %make-ical-publishing-component
                (kind component uid type calendar-address url properties
                 children schedulable-p diagnostics valid-p)))
  (kind :participant :type (member :participant :location :resource)
        :read-only t)
  (component nil :type ical-component :read-only t)
  (uid nil :type (or null string) :read-only t)
  (type nil :read-only t)
  (calendar-address nil :type (or null ical-uri-value) :read-only t)
  (url nil :type (or null ical-uri-value) :read-only t)
  (properties nil :type list :read-only t)
  (children nil :type list :read-only t)
  (schedulable-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-styled-description
            (:constructor %make-ical-styled-description
                (property value-type value media-type language derived-p order
                 diagnostics valid-p)))
  (property nil :type ical-property-value :read-only t)
  (value-type :text :type keyword :read-only t)
  value
  (media-type nil :type (or null string) :read-only t)
  (language nil :type (or null string) :read-only t)
  (derived-p nil :type boolean :read-only t)
  (order nil :type (or null integer) :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-structured-data
            (:constructor %make-ical-structured-data
                (property value-type value media-type schema order
                 retrieval-safe-p diagnostics valid-p)))
  (property nil :type ical-property-value :read-only t)
  (value-type :text :type keyword :read-only t)
  value
  (media-type nil :type (or null string) :read-only t)
  (schema nil :type (or null ical-uri-value) :read-only t)
  (order nil :type (or null integer) :read-only t)
  (retrieval-safe-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-calendar-relationship
            (:constructor %make-ical-calendar-relationship
                (property type raw-type resolution value-type target gap
                 diagnostics valid-p)))
  (property nil :type ical-property-value :read-only t)
  (type "PARENT" :type string :read-only t)
  (raw-type nil :type (or null string) :read-only t)
  (resolution :default :type keyword :read-only t)
  (value-type :uid :type keyword :read-only t)
  target
  (gap nil :type (or null ical-duration-value) :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-calendar-link
            (:constructor %make-ical-calendar-link
                (property value-type target link-relations media-type label
                 language retrieval-safe-p diagnostics valid-p)))
  (property nil :type ical-property-value :read-only t)
  (value-type :uri :type keyword :read-only t)
  target
  (link-relations nil :type list :read-only t)
  (media-type nil :type (or null string) :read-only t)
  (label nil :type (or null string) :read-only t)
  (language nil :type (or null string) :read-only t)
  (retrieval-safe-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-rfc-extension-set
            (:constructor %make-ical-rfc-extension-set
                (component publishing-components styled-descriptions
                 structured-data relationships concepts links refids
                 diagnostics valid-p)))
  (component nil :type ical-component :read-only t)
  (publishing-components nil :type list :read-only t)
  (styled-descriptions nil :type list :read-only t)
  (structured-data nil :type list :read-only t)
  (relationships nil :type list :read-only t)
  (concepts nil :type list :read-only t)
  (links nil :type list :read-only t)
  (refids nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defparameter *ical-rfc-extension-property-placement*
  '(("LOCATION-TYPE" "VLOCATION")
    ("PARTICIPANT-TYPE" "PARTICIPANT")
    ("RESOURCE-TYPE" "VRESOURCE")
    ("CALENDAR-ADDRESS" "PARTICIPANT")
    ("STYLED-DESCRIPTION" "VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY"
                          "PARTICIPANT" "VALARM")
    ("STRUCTURED-DATA" :any)
    ("ACKNOWLEDGED" "VALARM")
    ("PROXIMITY" "VALARM")
    ("CONCEPT" :any)
    ("LINK" :any)
    ("REFID" :any)))

(defparameter *ical-publishing-component-parents*
  '(("PARTICIPANT" "VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY")
    ("VLOCATION" "VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY"
                 "PARTICIPANT" "VALARM")
    ("VRESOURCE" "VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY"
                 "PARTICIPANT")))

(defparameter *ical-rfc9253-temporal-relationship-types*
  '("FINISHTOSTART" "FINISHTOFINISH" "STARTTOFINISH" "STARTTOSTART"))

(defun ical-extension-component-diagnostic (component code message &optional line)
  (make-diagnostic
   :severity :error :code code :message message
   :span (if line
             (ical-content-line-span line)
             (ical-component-span component))
   :loss-risk :none))

(defun ical-extension-property-index (component)
  (let ((index (make-hash-table :test #'equal))
        (decoded nil)
        (diagnostics nil))
    (dolist (line (ical-component-properties component))
      (let ((property
              (decode-ical-content-line-value
               line :component-name
               (ical-component-normalized-name component))))
        (push property decoded)
        (push property
              (gethash (ical-content-line-normalized-name line) index))
        (setf diagnostics
              (nconc diagnostics
                     (copy-list (ical-property-value-diagnostics property))))))
    (values index (nreverse decoded) diagnostics)))

(defun ical-extension-index-properties (index name)
  (nreverse (copy-list (gethash name index))))

(defun ical-extension-first-property (index name)
  (first (ical-extension-index-properties index name)))

(defun ical-extension-first-value (index name)
  (let* ((property (ical-extension-first-property index name))
         (value (and property (first (ical-property-value-values property)))))
    (and property (ical-property-value-valid-p property)
         value (ical-value-valid-p value) (ical-value-decoded value))))

(defun ical-extension-parameter-texts (property name)
  (mapcan
   (lambda (parameter)
     (mapcar #'ical-parameter-value-decoded-text
             (ical-parameter-values parameter)))
   (ical-parameters-named (ical-property-value-line property) name)))

(defun ical-extension-derived-p (property)
  (let ((values (ical-extension-parameter-texts property "DERIVED")))
    (and values (string-equal "TRUE" (first values)))))

(defun ical-extension-order (property)
  (let ((text (first (ical-extension-parameter-texts property "ORDER"))))
    (and text (every #'ical-ascii-digit-p text) (parse-integer text))))

(defun project-ical-styled-description (component property)
  "Project RFC 9073 styled content without rendering or dereferencing it."
  (unless (and (ical-property-value-p property)
               (string= "STYLED-DESCRIPTION"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-styled-description-property property
                 "styled-description projection requires STYLED-DESCRIPTION"))
  (let* ((diagnostics (copy-list (ical-property-value-diagnostics property)))
         (value-object
           (and (ical-property-value-valid-p property)
                (first (ical-property-value-values property))))
         (value (and value-object (ical-value-valid-p value-object)
                     (ical-value-decoded value-object))))
    (declare (ignore component))
    (%make-ical-styled-description
     property (ical-property-value-value-type property) value
     (ical-property-value-media-type property)
     (ical-property-value-language property)
     (not (null (ical-extension-derived-p property)))
     (ical-extension-order property) diagnostics (null diagnostics))))

(defun project-ical-structured-data (component property)
  "Project RFC 9073 ancillary data while keeping all URI content inert."
  (unless (and (ical-property-value-p property)
               (string= "STRUCTURED-DATA"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-structured-data-property property
                 "structured-data projection requires STRUCTURED-DATA"))
  (let* ((diagnostics
           (nconc (copy-list (ical-property-value-diagnostics property))
                  (ical-extension-structured-data-diagnostics
                   component property)))
         (value-object
           (and (ical-property-value-valid-p property)
                (first (ical-property-value-values property))))
         (value (and value-object (ical-value-valid-p value-object)
                     (ical-value-decoded value-object)))
         (schema-text
           (first (ical-extension-parameter-texts property "SCHEMA")))
         (schema nil))
    (when schema-text
      (multiple-value-bind (uri valid-p message)
          (decode-ical-uri schema-text)
        (if valid-p
            (setf schema uri)
            (push (ical-extension-component-diagnostic
                   component :invalid-icalendar-structured-data-schema message
                   (ical-property-value-line property))
                  diagnostics))))
    (let ((uri (and (eq :uri (ical-property-value-value-type property))
                    (ical-uri-value-p value) value)))
      (%make-ical-structured-data
       property (ical-property-value-value-type property) value
       (ical-property-value-media-type property) schema
       (ical-extension-order property)
       (and uri (ical-managed-attachment-uri-retrieval-safe-p uri))
       diagnostics (null diagnostics)))))

(defun ical-extension-cardinality-diagnostics
    (component index specifications)
  (let ((diagnostics nil))
    (dolist (specification specifications (nreverse diagnostics))
      (destructuring-bind (name minimum maximum) specification
        (let* ((properties (ical-extension-index-properties index name))
               (count (length properties)))
          (when (< count minimum)
            (push (ical-extension-component-diagnostic
                   component :missing-icalendar-extension-property
                   (format nil "~a requires ~a" 
                           (ical-component-normalized-name component) name))
                  diagnostics))
          (when (and maximum (> count maximum))
            (push (ical-extension-component-diagnostic
                   component :duplicate-icalendar-extension-property
                   (format nil "~a permits at most ~d ~a propert~a"
                           (ical-component-normalized-name component)
                           maximum name (if (= maximum 1) "y" "ies"))
                   (ical-property-value-line (nth maximum properties)))
                  diagnostics)))))))

(defun ical-extension-property-placement-diagnostics (component index)
  (let ((component-name (ical-component-normalized-name component))
        (diagnostics nil))
    (dolist (placement *ical-rfc-extension-property-placement*
             (nreverse diagnostics))
      (let ((name (first placement))
            (allowed (rest placement)))
        (unless (or (member :any allowed)
                    (member component-name allowed :test #'string=))
          (dolist (property (ical-extension-index-properties index name))
            (push (ical-extension-component-diagnostic
                   component :misplaced-icalendar-extension-property
                   (format nil "~a is not permitted on ~a" name component-name)
                   (ical-property-value-line property))
                  diagnostics)))))))

(defun ical-extension-structured-data-diagnostics (component property)
  (let ((diagnostics nil)
        (type (ical-property-value-value-type property))
        (line (ical-property-value-line property)))
    (when (member type '(:text :binary))
      (unless (ical-parameters-named line "FMTTYPE")
        (push (ical-extension-component-diagnostic
               component :missing-structured-data-format-type
               "inline STRUCTURED-DATA requires FMTTYPE" line)
              diagnostics))
      (unless (ical-parameters-named line "SCHEMA")
        (push (ical-extension-component-diagnostic
               component :missing-structured-data-schema
               "inline STRUCTURED-DATA requires SCHEMA" line)
              diagnostics)))
    (nreverse diagnostics)))

(defun ical-extension-styled-description-diagnostics
    (component properties)
  (when (> (length properties) 1)
    (let ((source-count
            (count-if-not #'ical-extension-derived-p properties)))
      (unless (= source-count 1)
        (list
         (ical-extension-component-diagnostic
          component :invalid-styled-description-derived-set
          "multiple STYLED-DESCRIPTION properties require exactly one non-derived source"
          (ical-property-value-line (first properties))))))))

(defun ical-extension-link-relation-diagnostics (component property)
  (let* ((line (ical-property-value-line property))
         (parameters (ical-parameters-named line "LINKREL"))
         (diagnostics nil))
    (unless parameters
      (push (ical-extension-component-diagnostic
             component :missing-icalendar-link-relation
             "LINK requires at least one LINKREL parameter" line)
            diagnostics))
    (dolist (parameter parameters)
      (dolist (value (ical-parameter-values parameter))
        (let* ((text (ical-parameter-value-decoded-text value))
               (quoted-p (ical-parameter-value-quoted-p value))
               (uri-p (ical-valid-absolute-uri-parameter-p text))
               (token-p (ical-token-p text)))
          (cond
            ((and uri-p (not quoted-p))
             (push (ical-extension-component-diagnostic
                    component :unquoted-icalendar-link-relation-uri
                    "URI LINKREL values require quoted-string syntax" line)
                   diagnostics))
            ((and token-p quoted-p)
             (push (ical-extension-component-diagnostic
                    component :quoted-icalendar-link-relation-token
                    "registered LINKREL tokens require unquoted syntax" line)
                   diagnostics))))))
    (nreverse diagnostics)))

(defun ical-extension-related-to-diagnostics (component property)
  (let* ((line (ical-property-value-line property))
         (type (ical-property-value-value-type property))
         (relationship-result
           (multiple-value-list
            (ical-property-effective-relationship-type property)))
         (relationship (first relationship-result))
         (raw-relationship (second relationship-result))
         (resolution (third relationship-result))
         (diagnostics nil))
    (when (and raw-relationship (eq resolution :fallback))
      (push (ical-extension-component-diagnostic
             component :unsupported-icalendar-relationship-type
             "unknown RELTYPE remains preserved but cannot be applied semantically"
             line)
            diagnostics))
    (when (and (ical-parameters-named line "GAP")
               (not (member relationship
                            *ical-rfc9253-temporal-relationship-types*
                            :test #'string=)))
      (push (ical-extension-component-diagnostic
             component :invalid-icalendar-relationship-gap
             "GAP is valid only with an RFC 9253 temporal RELTYPE" line)
            diagnostics))
    (when (and relationship
               (member relationship '("PARENT" "CHILD" "SIBLING" "SNOOZE")
                       :test #'string=)
               (not (eq type :uid)))
      (push (ical-extension-component-diagnostic
             component :invalid-icalendar-relationship-value-type
             (format nil "RELTYPE=~a requires VALUE=UID" relationship) line)
            diagnostics))
    (when (and relationship (string= relationship "CONCEPT")
               (not (eq type :uri)))
      (push (ical-extension-component-diagnostic
             component :invalid-icalendar-concept-relationship-value
             "RELTYPE=CONCEPT requires VALUE=URI" line)
            diagnostics))
    (when (and relationship (string= relationship "REFID")
               (not (eq type :text)))
      (push (ical-extension-component-diagnostic
             component :invalid-icalendar-refid-relationship-value
             "RELTYPE=REFID requires VALUE=TEXT" line)
            diagnostics))
    (nreverse diagnostics)))

(defun project-ical-calendar-relationship (component property)
  "Project RFC 9074/9253 RELATED-TO semantics without applying side effects."
  (unless (and (ical-property-value-p property)
               (string= "RELATED-TO"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-relationship-property property
                 "relationship projection requires RELATED-TO"))
  (multiple-value-bind (type raw-type resolution)
      (ical-property-effective-relationship-type property)
    (let* ((diagnostics
             (nconc (copy-list (ical-property-value-diagnostics property))
                    (ical-extension-related-to-diagnostics
                     component property)))
           (value-object
             (and (ical-property-value-valid-p property)
                  (first (ical-property-value-values property))))
           (target (and value-object (ical-value-valid-p value-object)
                        (ical-value-decoded value-object)))
           (gap-text (first (ical-extension-parameter-texts property "GAP")))
           (gap (and gap-text
                     (multiple-value-bind (duration valid-p message)
                         (decode-ical-duration gap-text)
                       (declare (ignore message))
                       (and valid-p duration)))))
      (%make-ical-calendar-relationship
       property (or type "PARENT") raw-type resolution
       (ical-property-value-value-type property) target gap diagnostics
       (null diagnostics)))))

(defun project-ical-calendar-link (component property)
  "Project an RFC 9253 LINK without dereferencing its untrusted target."
  (unless (and (ical-property-value-p property)
               (string= "LINK"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-link-property property
                 "LINK projection requires a decoded LINK property"))
  (let* ((diagnostics
           (nconc (copy-list (ical-property-value-diagnostics property))
                  (ical-extension-link-relation-diagnostics component property)))
         (line (ical-property-value-line property))
         (value (and (ical-property-value-valid-p property)
                     (first (ical-property-value-values property))))
         (target (and value (ical-value-valid-p value)
                      (ical-value-decoded value)))
         (type (ical-property-value-value-type property))
         (relations (ical-extension-parameter-texts property "LINKREL"))
         (label (first (ical-extension-parameter-texts property "LABEL")))
         (uri (and (member type '(:uri :xml-reference))
                   (ical-uri-value-p target) target)))
    (when (and (eq type :uid)
               (not (and (stringp target) (plusp (length target)))))
      (push (ical-extension-component-diagnostic
             component :invalid-icalendar-link-uid
             "VALUE=UID LINK targets must be non-empty"
             (ical-property-value-line property))
            diagnostics))
    (when (and (eq type :xml-reference)
               (or (null uri)
                   (not (non-empty-string-p
                         (ical-uri-value-fragment uri)))))
      (push (ical-extension-component-diagnostic
             component :invalid-icalendar-link-xml-reference
             "VALUE=XML-REFERENCE LINK targets require an absolute URI with an XPointer fragment"
             (ical-property-value-line property))
            diagnostics))
    (%make-ical-calendar-link
     property type target relations (ical-property-value-media-type property)
     label (ical-property-value-language property)
     (and uri (ical-managed-attachment-uri-retrieval-safe-p uri))
     diagnostics (null diagnostics))))

(defun ical-extension-component-cardinality-specifications (name)
  (cond
    ((string= name "PARTICIPANT")
     '(("UID" 1 1) ("PARTICIPANT-TYPE" 1 1) ("CALENDAR-ADDRESS" 0 1)
       ("CREATED" 0 1) ("DESCRIPTION" 0 1) ("DTSTAMP" 0 1)
       ("GEO" 0 1) ("LAST-MODIFIED" 0 1) ("PRIORITY" 0 1)
       ("SEQUENCE" 0 1) ("STATUS" 0 1) ("SUMMARY" 0 1) ("URL" 0 1)))
    ((string= name "VLOCATION")
     '(("UID" 1 1) ("DESCRIPTION" 0 1) ("GEO" 0 1)
       ("LOCATION-TYPE" 0 1) ("NAME" 0 1) ("URL" 0 1)))
    ((string= name "VRESOURCE")
     '(("UID" 1 1) ("DESCRIPTION" 0 1) ("GEO" 0 1)
       ("NAME" 0 1) ("RESOURCE-TYPE" 0 1)))
    (t nil)))

(defun ical-extension-token-values-valid-p (values)
  (every (lambda (value)
           (and (stringp value) (plusp (length value)) (ical-token-p value)))
         (if (listp values) values (list values))))

(defun ical-publishing-component-kind-for-name (name)
  (cond ((string= name "PARTICIPANT") :participant)
        ((string= name "VLOCATION") :location)
        ((string= name "VRESOURCE") :resource)))

(defun ical-participant-schedulable-p (parent calendar-address)
  (and parent calendar-address
       (let ((expected (ical-uri-value-original-lexeme calendar-address)))
         (some
          (lambda (line)
            (when (string= "ATTENDEE"
                           (ical-content-line-normalized-name line))
              (let* ((property
                       (decode-ical-content-line-value
                        line :component-name
                        (ical-component-normalized-name parent)))
                     (value
                       (and (ical-property-value-valid-p property)
                            (first (ical-property-value-values property))))
                     (uri (and value (ical-value-valid-p value)
                               (ical-value-decoded value))))
                (and (ical-uri-value-p uri)
                     (string= expected
                              (ical-uri-value-original-lexeme uri))))))
          (ical-component-properties parent)))))

(defun project-ical-publishing-component (component parent)
  "Project one RFC 9073 component as inert typed metadata."
  (let* ((name (ical-component-normalized-name component))
         (kind (ical-publishing-component-kind-for-name name)))
    (unless kind
      (model-error :invalid-icalendar-publishing-component component
                   "publishing projection requires PARTICIPANT, VLOCATION, or VRESOURCE"))
    (multiple-value-bind (index properties property-diagnostics)
        (ical-extension-property-index component)
      (let* ((diagnostics property-diagnostics)
             (parent-name (and parent (ical-component-normalized-name parent)))
             (allowed-parents
               (rest (assoc name *ical-publishing-component-parents*
                            :test #'string=))))
        (unless (and parent-name (member parent-name allowed-parents :test #'string=))
          (push (ical-extension-component-diagnostic
                 component :misplaced-icalendar-publishing-component
                 (format nil "~a is not permitted in ~a" name (or parent-name "the root")))
                diagnostics))
        (setf diagnostics
              (nconc diagnostics
                     (ical-extension-cardinality-diagnostics
                      component index
                      (ical-extension-component-cardinality-specifications name))
                     (ical-extension-property-placement-diagnostics component index)))
        (let* ((uid (ical-extension-first-value index "UID"))
               (type
                 (case kind
                   (:participant
                    (ical-extension-first-value index "PARTICIPANT-TYPE"))
                   (:location
                    (mapcan (lambda (property)
                              (mapcar #'ical-value-decoded
                                      (ical-property-value-values property)))
                            (ical-extension-index-properties
                             index "LOCATION-TYPE")))
                   (:resource
                    (ical-extension-first-value index "RESOURCE-TYPE"))))
               (calendar-address
                 (ical-extension-first-value index "CALENDAR-ADDRESS"))
               (url (ical-extension-first-value index "URL"))
               (children
                 (loop :for child :in (ical-component-children component)
                       :when (ical-publishing-component-kind-for-name
                              (ical-component-normalized-name child))
                         :collect (project-ical-publishing-component
                                   child component))))
          (unless (and (stringp uid) (plusp (length uid)))
            (push (ical-extension-component-diagnostic
                   component :invalid-icalendar-publishing-uid
                   (format nil "~a UID must be non-empty" name))
                  diagnostics))
          (when (and type (not (ical-extension-token-values-valid-p type)))
            (push (ical-extension-component-diagnostic
                   component :invalid-icalendar-publishing-type
                   (format nil "~a type values must be registered or extension tokens"
                           name))
                  diagnostics))
          (dolist (child children)
            (setf diagnostics
                  (nconc diagnostics
                         (copy-list
                          (ical-publishing-component-diagnostics child)))))
          (setf diagnostics (nreverse diagnostics))
          (%make-ical-publishing-component
           kind component uid type calendar-address url properties children
           (and (eq kind :participant)
                (not (null
                      (ical-participant-schedulable-p
                       parent calendar-address))))
           diagnostics (null diagnostics)))))))

(defun ical-extension-current-component-diagnostics (component index)
  (let* ((name (ical-component-normalized-name component))
         (diagnostics
           (ical-extension-property-placement-diagnostics component index))
         (styled
           (ical-extension-index-properties index "STYLED-DESCRIPTION")))
    (setf diagnostics
          (nconc diagnostics
                 (ical-extension-styled-description-diagnostics
                  component styled)))
    (dolist (property (ical-extension-index-properties index "STRUCTURED-DATA"))
      (setf diagnostics
            (nconc diagnostics
                   (ical-extension-structured-data-diagnostics
                    component property))))
    (dolist (property (ical-extension-index-properties index "RELATED-TO"))
      (setf diagnostics
            (nconc diagnostics
                   (ical-extension-related-to-diagnostics component property))))
    (dolist (property (ical-extension-index-properties index "LINK"))
      (setf diagnostics
            (nconc diagnostics
                   (ical-extension-link-relation-diagnostics
                    component property))))
    (dolist (property (ical-extension-index-properties index "REFID"))
      (let ((value (and (ical-property-value-valid-p property)
                        (ical-value-decoded
                         (first (ical-property-value-values property))))))
        (unless (and (stringp value) (plusp (length value)))
          (push (ical-extension-component-diagnostic
                 component :invalid-icalendar-refid
                 "REFID must be non-empty TEXT"
                 (ical-property-value-line property))
                diagnostics))))
    (when (string= name "VALARM")
      (setf diagnostics
            (nconc diagnostics
                   (ical-extension-cardinality-diagnostics
                    component index
                    '(("UID" 0 1) ("ACKNOWLEDGED" 0 1)
                      ("PROXIMITY" 0 1)))))
      (let ((acknowledged
              (ical-extension-first-value index "ACKNOWLEDGED"))
            (uid (ical-extension-first-value index "UID"))
            (proximity
              (ical-extension-first-value index "PROXIMITY"))
            (locations
              (remove-if-not
               (lambda (child)
                 (string= "VLOCATION"
                          (ical-component-normalized-name child)))
               (ical-component-children component))))
        (when (and (ical-extension-first-property index "UID")
                   (not (and (stringp uid) (plusp (length uid)))))
          (push (ical-extension-component-diagnostic
                 component :invalid-icalendar-alarm-uid
                 "VALARM UID must be non-empty TEXT")
                diagnostics))
        (when (and acknowledged
                   (not (eq :utc (temporal-value-kind acknowledged))))
          (push (ical-extension-component-diagnostic
                 component :non-utc-icalendar-alarm-acknowledged
                 "VALARM ACKNOWLEDGED must be a UTC DATE-TIME")
                diagnostics))
        (when (and proximity
                   (not (ical-extension-token-values-valid-p proximity)))
          (push (ical-extension-component-diagnostic
                 component :invalid-icalendar-alarm-proximity
                 "PROXIMITY must be a registered or extension token")
                diagnostics))
        (when (and proximity
                   (member (string-upcase proximity) '("ARRIVE" "DEPART")
                           :test #'string=)
                   (null locations))
          (push (ical-extension-component-diagnostic
                 component :missing-icalendar-alarm-proximity-location
                 "ARRIVE and DEPART proximity alarms require VLOCATION")
                diagnostics))
        (when (and proximity
                   (member (string-upcase proximity) '("ARRIVE" "DEPART")
                           :test #'string=))
          (dolist (location locations)
            (let* ((projected
                     (project-ical-publishing-component location component))
                   (url (ical-publishing-component-url projected)))
              (unless (and url
                           (string-equal "geo" (ical-uri-value-scheme url)))
                (push (ical-extension-component-diagnostic
                       location :invalid-icalendar-alarm-proximity-location
                       "proximity VLOCATION requires a URL with a geo URI")
                      diagnostics)))))
        (when (and locations (null proximity))
          (push (ical-extension-component-diagnostic
                 component :orphan-icalendar-alarm-location
                 "VALARM VLOCATION requires PROXIMITY")
                diagnostics))))
    (nreverse diagnostics)))

(defun ical-extension-snooze-graph-diagnostics (component)
  (unless (member (ical-component-normalized-name component)
                  '("VEVENT" "VTODO") :test #'string=)
    (return-from ical-extension-snooze-graph-diagnostics nil))
  (let ((uids (make-hash-table :test #'equal))
        (diagnostics nil)
        (alarms
          (remove-if-not
           (lambda (child)
             (string= "VALARM" (ical-component-normalized-name child)))
           (ical-component-children component))))
    (dolist (alarm alarms)
      (multiple-value-bind (index properties property-diagnostics)
          (ical-extension-property-index alarm)
        (declare (ignore properties property-diagnostics))
        (let ((uid (ical-extension-first-value index "UID")))
          (when uid
            (if (gethash uid uids)
                (push (ical-extension-component-diagnostic
                       alarm :duplicate-icalendar-alarm-uid
                       "VALARM UIDs must be unique among sibling alarms")
                      diagnostics)
                (setf (gethash uid uids) alarm))))))
    (dolist (alarm alarms)
      (multiple-value-bind (index properties property-diagnostics)
          (ical-extension-property-index alarm)
        (declare (ignore properties property-diagnostics))
        (dolist (property (ical-extension-index-properties index "RELATED-TO"))
          (multiple-value-bind (relationship raw resolution)
              (ical-property-effective-relationship-type property)
            (declare (ignore raw resolution))
            (when (and relationship (string= relationship "SNOOZE"))
              (let ((target
                      (and (ical-property-value-valid-p property)
                           (ical-value-decoded
                            (first (ical-property-value-values property))))))
                (unless (and (stringp target) (gethash target uids))
                  (push (ical-extension-component-diagnostic
                         alarm :dangling-icalendar-alarm-snooze
                         "RELTYPE=SNOOZE must target a sibling VALARM UID"
                         (ical-property-value-line property))
                        diagnostics))
                (when (and (stringp target) (gethash target uids))
                  (multiple-value-bind
                        (target-index target-properties target-diagnostics)
                      (ical-extension-property-index (gethash target uids))
                    (declare (ignore target-properties target-diagnostics))
                    (unless (ical-extension-first-property
                             target-index "ACKNOWLEDGED")
                      (push (ical-extension-component-diagnostic
                             alarm :unacknowledged-icalendar-alarm-snooze-target
                             "RELTYPE=SNOOZE requires ACKNOWLEDGED on its target alarm"
                             (ical-property-value-line property))
                            diagnostics))))))))))
    (nreverse diagnostics)))

(defun project-ical-rfc-extensions (component)
  "Validate and expose RFC 9073, RFC 9074, and RFC 9253 content.

All URI-bearing values remain inert.  No link, schema, structured-data, or
proximity target is dereferenced by this projection."
  (unless (ical-component-p component)
    (model-error :invalid-icalendar-extension-component component
                 "extension projection requires an iCalendar component"))
  (let ((publishing nil)
        (styled nil)
        (structured nil)
        (relationships nil)
        (concepts nil)
        (links nil)
        (refids nil)
        (diagnostics nil))
    (labels ((walk (current parent)
               (multiple-value-bind (index properties property-diagnostics)
                   (ical-extension-property-index current)
                 (declare (ignore properties))
                 (setf diagnostics
                       (nconc diagnostics property-diagnostics
                              (ical-extension-current-component-diagnostics
                               current index)))
                 (let ((kind
                         (ical-publishing-component-kind-for-name
                          (ical-component-normalized-name current))))
                   (when kind
                     (let ((projected
                             (project-ical-publishing-component current parent)))
                       (push projected publishing)
                       (setf diagnostics
                             (nconc diagnostics
                                    (copy-list
                                     (ical-publishing-component-diagnostics
                                      projected)))))))
                 (dolist (property
                          (ical-extension-index-properties
                           index "STYLED-DESCRIPTION"))
                   (let ((projected
                           (project-ical-styled-description current property)))
                     (push projected styled)
                     (setf diagnostics
                           (nconc diagnostics
                                  (copy-list
                                   (ical-styled-description-diagnostics
                                    projected))))))
                 (dolist (property
                          (ical-extension-index-properties
                           index "STRUCTURED-DATA"))
                   (let ((projected
                           (project-ical-structured-data current property)))
                     (push projected structured)
                     (setf diagnostics
                           (nconc diagnostics
                                  (copy-list
                                   (ical-structured-data-diagnostics
                                    projected))))))
                 (dolist (property
                          (ical-extension-index-properties index "RELATED-TO"))
                   (let ((projected
                           (project-ical-calendar-relationship
                            current property)))
                     (push projected relationships)
                     (setf diagnostics
                           (nconc diagnostics
                                  (copy-list
                                   (ical-calendar-relationship-diagnostics
                                    projected))))))
                 (setf concepts
                       (nconc concepts
                              (ical-extension-index-properties index "CONCEPT"))
                       refids
                       (nconc refids
                              (ical-extension-index-properties index "REFID")))
                 (dolist (property (ical-extension-index-properties index "LINK"))
                   (let ((projected
                           (project-ical-calendar-link current property)))
                     (push projected links)
                     (setf diagnostics
                           (nconc diagnostics
                                  (copy-list
                                   (ical-calendar-link-diagnostics
                                    projected))))))
                 (dolist (child (ical-component-children current))
                   (walk child current)))))
      (walk component nil))
    (setf diagnostics
          (nconc diagnostics
                 (ical-extension-snooze-graph-diagnostics component)))
    (setf diagnostics (remove-duplicates diagnostics :test #'equalp))
    (%make-ical-rfc-extension-set
     component (nreverse publishing) (nreverse styled) (nreverse structured)
     (nreverse relationships) concepts
     (nreverse links) refids diagnostics (null diagnostics))))
