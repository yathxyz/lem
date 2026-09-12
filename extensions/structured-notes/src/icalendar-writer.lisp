(in-package #:lem-structured-notes)

(defstruct (ical-property-output
            (:constructor %make-ical-property-output
                (name value value-type group parameters)))
  (name "" :type string :read-only t)
  value
  (value-type nil :type (or null keyword) :read-only t)
  (group nil :type (or null string) :read-only t)
  (parameters nil :type list :read-only t))

(defun make-ical-property-output
    (&key name value value-type group (parameters nil))
  "Describe one typed property for canonical component generation."
  (unless (and (stringp name) (ical-token-p name))
    (model-error :invalid-icalendar-output-property-name name
                 "output property name must be an iCalendar token"))
  (unless (or (null value-type) (keywordp value-type))
    (model-error :invalid-icalendar-output-value-type value-type
                 "output property value type must be a keyword or NIL"))
  (unless (or (null group) (and (stringp group) (ical-token-p group)))
    (model-error :invalid-icalendar-output-property-group group
                 "output property group must be an iCalendar token or NIL"))
  (let ((parameters
          (copy-proper-list parameters :invalid-icalendar-output-parameters
                            "output property parameters")))
    (%make-ical-property-output
     (string-upcase name) value value-type group (copy-tree parameters))))

(defstruct (ical-component-output
            (:constructor %make-ical-component-output
                (name properties children)))
  (name "" :type string :read-only t)
  (properties nil :type list :read-only t)
  (children nil :type list :read-only t))

(defparameter *ical-generated-component-names*
  '("VCALENDAR" "VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY" "VALARM"
    "VAVAILABILITY" "AVAILABLE"))

(defun make-ical-component-output
    (&key name (properties nil) (children nil))
  "Describe one supported component for verified canonical generation."
  (unless (and (stringp name) (ical-token-p name))
    (model-error :invalid-icalendar-output-component-name name
                 "output component name must be an iCalendar token"))
  (let ((normalized-name (string-upcase name))
        (properties
          (copy-proper-list properties :invalid-icalendar-output-properties
                            "output component properties"))
        (children
          (copy-proper-list children :invalid-icalendar-output-children
                            "output component children")))
    (unless (member normalized-name *ical-generated-component-names*
                    :test #'string=)
      (model-error :unsupported-icalendar-output-component normalized-name
                   "new component generation does not support the requested component"))
    (unless (every #'ical-property-output-p properties)
      (model-error :invalid-icalendar-output-property properties
                   "every output property must be a typed property output"))
    (unless (every #'ical-component-output-p children)
      (model-error :invalid-icalendar-output-child children
                   "every output child must be a component output"))
    (%make-ical-component-output
     normalized-name (copy-list properties) (copy-list children))))

(defun assert-ical-output-component-placement (component)
  (let* ((name (ical-component-output-name component))
         (rule (assoc name *ical-known-component-child-rules* :test #'string=))
         (allowed (rest rule)))
    (dolist (child (ical-component-output-children component))
      (unless (member (ical-component-output-name child) allowed :test #'string=)
        (model-error :misplaced-icalendar-output-component child
                     "component is not permitted beneath its requested parent"))
      (assert-ical-output-component-placement child)))
  component)

(defun render-ical-property-output
    (property component-name max-unfolded-octets max-binary-octets)
  (generate-ical-property-line
   (ical-property-output-name property)
   (ical-property-output-value property)
   :value-type (ical-property-output-value-type property)
   :group (ical-property-output-group property)
   :parameters (ical-property-output-parameters property)
   :component-name component-name
   :max-unfolded-octets max-unfolded-octets
   :max-binary-octets max-binary-octets))

(defun ical-output-duration-seconds (duration)
  (* (ical-duration-value-sign duration)
     (+ (* (ical-duration-value-weeks duration) 7 86400)
        (* (ical-duration-value-days duration) 86400)
        (* (ical-duration-value-hours duration) 3600)
        (* (ical-duration-value-minutes duration) 60)
        (ical-duration-value-seconds duration))))

(defun ical-output-freebusy-period-bounds (period)
  (unless (ical-period-value-p period)
    (model-error :invalid-icalendar-output-freebusy-period period
                 "VFREEBUSY output requires typed PERIOD values"))
  (let* ((start (ical-period-value-start period))
         (end (ical-period-value-end period))
         (duration (ical-period-value-duration period))
         (start-seconds
           (ical-utc-temporal-seconds
            (ical-recurrence-normalize-explicit-leap-second start))))
    (values start-seconds
            (if end
                (ical-utc-temporal-seconds
                 (ical-recurrence-normalize-explicit-leap-second end))
                (+ start-seconds (ical-output-duration-seconds duration))))))

(defun ical-output-freebusy-period-less-p (left right)
  (multiple-value-bind (left-start left-end)
      (ical-output-freebusy-period-bounds left)
    (multiple-value-bind (right-start right-end)
        (ical-output-freebusy-period-bounds right)
      (or (< left-start right-start)
          (and (= left-start right-start) (< left-end right-end))))))

(defun ical-canonical-vfreebusy-output-properties (properties)
  (let ((ordinary nil)
        (period-properties nil))
    (dolist (property properties)
      (if (string= "FREEBUSY" (ical-property-output-name property))
          (progn
            (unless (and (proper-list-p (ical-property-output-value property))
                         (ical-property-output-value property))
              (model-error :invalid-icalendar-output-freebusy-list property
                           "FREEBUSY output requires a non-empty PERIOD list"))
            (dolist (period (ical-property-output-value property))
              ;; One canonical line per period permits a global chronological
              ;; ordering without merging distinct FBTYPE or extension metadata.
              (push (make-ical-property-output
                     :name "FREEBUSY" :value (list period)
                     :value-type (ical-property-output-value-type property)
                     :group (ical-property-output-group property)
                     :parameters (ical-property-output-parameters property))
                    period-properties)))
          (push property ordinary)))
    (nconc
     (nreverse ordinary)
     (stable-sort
      (nreverse period-properties)
      (lambda (left right)
        (ical-output-freebusy-period-less-p
         (first (ical-property-output-value left))
         (first (ical-property-output-value right))))))))

(defun ical-canonical-output-properties (component)
  (let ((properties (ical-component-output-properties component)))
    (if (string= "VFREEBUSY" (ical-component-output-name component))
        (ical-canonical-vfreebusy-output-properties properties)
        properties)))

(defun render-ical-component-output
    (component max-unfolded-octets max-binary-octets)
  (with-output-to-string (stream)
    (write-string
     (generate-ical-content-line
      "BEGIN" (ical-component-output-name component)
      :max-unfolded-octets max-unfolded-octets)
     stream)
    (dolist (property (ical-canonical-output-properties component))
      (write-string
       (render-ical-property-output
        property (ical-component-output-name component)
        max-unfolded-octets max-binary-octets)
       stream))
    (dolist (child (ical-component-output-children component))
      (write-string
       (render-ical-component-output
        child max-unfolded-octets max-binary-octets)
       stream))
    (write-string
     (generate-ical-content-line
      "END" (ical-component-output-name component)
      :max-unfolded-octets max-unfolded-octets)
     stream)))

(defun verify-generated-icalendar-document (source source-id)
  (let* ((document (parse-icalendar-cst source :source-id source-id))
         (components (ical-document-components document)))
    (when (or (ical-document-diagnostics document)
              (/= 1 (length components)))
      (model-error :invalid-generated-icalendar-document
                   (ical-document-diagnostics document)
                   "generated source did not reparse as one clean VCALENDAR"))
    (let* ((calendar (first components))
           (envelope (project-ical-calendar-envelope calendar)))
      (unless (ical-calendar-envelope-valid-p envelope)
        (model-error :invalid-generated-icalendar-envelope
                     (ical-calendar-envelope-diagnostics envelope)
                     "generated VCALENDAR failed semantic envelope validation"))
      (unless (non-empty-string-p (ical-calendar-envelope-prodid envelope))
        (model-error :invalid-generated-icalendar-prodid
                     (ical-calendar-envelope-prodid envelope)
                     "generated VCALENDAR requires a non-empty PRODID"))
      (unless (string= "2.0" (ical-calendar-envelope-version envelope))
        (model-error :unsupported-generated-icalendar-version
                     (ical-calendar-envelope-version envelope)
                     "generated VCALENDAR supports exactly VERSION 2.0"))
      (when (and (ical-calendar-envelope-calscale envelope)
                 (not (string-equal
                       "GREGORIAN"
                       (ical-calendar-envelope-calscale envelope))))
        (model-error :unsupported-generated-icalendar-scale
                     (ical-calendar-envelope-calscale envelope)
                     "generated VCALENDAR currently supports only GREGORIAN"))
      (when (and (ical-calendar-envelope-method envelope)
                 (not (ical-token-p
                       (ical-calendar-envelope-method envelope))))
        (model-error :invalid-generated-icalendar-method
                     (ical-calendar-envelope-method envelope)
                     "generated VCALENDAR METHOD must be an iCalendar token"))
      (dolist (component (ical-calendar-envelope-components envelope))
        (let ((name (ical-component-normalized-name component)))
          (cond
            ((member name '("VEVENT" "VTODO" "VJOURNAL") :test #'string=)
             (let ((item
                     (project-ical-component
                      component
                      :method-present-p
                      (not (null (ical-calendar-envelope-method envelope))))))
               (unless (ical-calendar-item-valid-p item)
                 (model-error :invalid-generated-icalendar-item
                              (ical-calendar-item-diagnostics item)
                              "generated calendar item failed semantic validation"))))
            ((string= name "VFREEBUSY")
             (let ((freebusy (project-ical-freebusy-component component)))
               (unless (ical-freebusy-valid-p freebusy)
                 (model-error :invalid-generated-icalendar-freebusy
                              (ical-freebusy-diagnostics freebusy)
                              "generated VFREEBUSY failed semantic validation"))))
            ((string= name "VAVAILABILITY")
             (let ((availability
                     (project-ical-availability-component component)))
               (unless (ical-availability-valid-p availability)
                 (model-error :invalid-generated-icalendar-availability
                              (ical-availability-diagnostics availability)
                              "generated availability failed semantic validation"))))
            (t
             (model-error :unsupported-generated-icalendar-component name
                          "generated document contains an unsupported component")))))
      document)))

(defun generate-icalendar-document
    (calendar &key (source-id "generated.ics")
                   (max-unfolded-octets 1048576)
                   (max-binary-octets 8388608)
                   (max-output-octets 16777216))
  "Render and verify one canonical VCALENDAR from typed output specs.

Only new VCALENDAR documents containing VEVENT, VTODO, VJOURNAL, VFREEBUSY,
or VAVAILABILITY items and their supported children are accepted.  The complete
result is reparsed and projected;
no source is returned unless all currently implemented envelope, item, and
alarm invariants hold."
  (unless (and (ical-component-output-p calendar)
               (string= "VCALENDAR"
                        (ical-component-output-name calendar)))
    (model-error :invalid-icalendar-output-root calendar
                 "document generation requires one VCALENDAR output"))
  (require-non-empty-string source-id :invalid-source-id
                            "generated iCalendar source ID")
  (ical-require-limit max-output-octets
                      "maximum generated iCalendar entity size")
  (assert-ical-output-component-placement calendar)
  (let ((source
          (render-ical-component-output
           calendar max-unfolded-octets max-binary-octets)))
    (let ((octets (ical-string-utf8-octets source)))
      (when (> octets max-output-octets)
        (model-error :icalendar-output-entity-limit octets
                     "generated iCalendar entity exceeds the configured octet limit")))
    (verify-generated-icalendar-document source source-id)
    source))
