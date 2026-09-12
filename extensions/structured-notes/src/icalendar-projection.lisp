(in-package #:lem-structured-notes)

(defstruct (ical-calendar-item
            (:constructor %make-ical-calendar-item
                (kind component uid dtstamp summary description status location url
                 transparency categories color images conferences start end due duration completed
                 percent-complete priority sequence recurrence-id
                 recurrence-range recurrence-rule recurrence-dates
                 recurrence-exception-dates
                 alarms properties diagnostics valid-p descriptions
                 request-statuses extensions)))
  (kind :event :type keyword :read-only t)
  (component nil :type ical-component :read-only t)
  (uid nil :type (or null string) :read-only t)
  (dtstamp nil :type (or null temporal-value) :read-only t)
  (summary nil :type (or null string) :read-only t)
  (description nil :type (or null string) :read-only t)
  (status nil :type (or null string) :read-only t)
  (location nil :type (or null string) :read-only t)
  (url nil :type (or null ical-uri-value) :read-only t)
  (transparency nil :type (or null string) :read-only t)
  (categories nil :type list :read-only t)
  (color nil :type (or null string) :read-only t)
  (images nil :type list :read-only t)
  (conferences nil :type list :read-only t)
  (start nil :type (or null temporal-value) :read-only t)
  (end nil :type (or null temporal-value) :read-only t)
  (due nil :type (or null temporal-value) :read-only t)
  (duration nil :type (or null ical-duration-value) :read-only t)
  (completed nil :type (or null temporal-value) :read-only t)
  (percent-complete nil :type (or null integer) :read-only t)
  (priority nil :type (or null integer) :read-only t)
  (sequence nil :type (or null integer) :read-only t)
  (recurrence-id nil :type (or null temporal-value) :read-only t)
  (recurrence-range :this :type keyword :read-only t)
  (recurrence-rule nil :type (or null ical-recur-value) :read-only t)
  (recurrence-dates nil :type list :read-only t)
  (recurrence-exception-dates nil :type list :read-only t)
  (alarms nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t)
  ;; VJOURNAL permits repeated DESCRIPTION properties.  DESCRIPTION remains
  ;; the first value for the established VEVENT/VTODO-compatible accessor.
  (descriptions nil :type list :read-only t)
  ;; REQUEST-STATUS is repeatable and remains inert typed response evidence.
  (request-statuses nil :type list :read-only t)
  (extensions nil :type ical-rfc-extension-set :read-only t))

(defstruct (ical-freebusy-period-entry
            (:constructor %make-ical-freebusy-period-entry
                (property period type raw-type resolution)))
  (property nil :type ical-property-value :read-only t)
  (period nil :type ical-period-value :read-only t)
  (type "BUSY" :type string :read-only t)
  (raw-type nil :type (or null string) :read-only t)
  (resolution :default :type keyword :read-only t))

(defstruct (ical-freebusy
            (:constructor %make-ical-freebusy
                 (component uid dtstamp contact start end organizer url attendees
                 comments periods request-statuses properties diagnostics valid-p
                 extensions)))
  (component nil :type ical-component :read-only t)
  (uid nil :type (or null string) :read-only t)
  (dtstamp nil :type (or null temporal-value) :read-only t)
  (contact nil :type (or null string) :read-only t)
  (start nil :type (or null temporal-value) :read-only t)
  (end nil :type (or null temporal-value) :read-only t)
  (organizer nil :type (or null ical-uri-value) :read-only t)
  (url nil :type (or null ical-uri-value) :read-only t)
  (attendees nil :type list :read-only t)
  (comments nil :type list :read-only t)
  (periods nil :type list :read-only t)
  (request-statuses nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t)
  (extensions nil :type ical-rfc-extension-set :read-only t))

(defstruct (ical-calendar-envelope
            (:constructor %make-ical-calendar-envelope
                (component prodid version calscale method names descriptions uid
                 last-modified url categories refresh-interval source color images components
                 properties diagnostics valid-p)))
  (component nil :type ical-component :read-only t)
  (prodid nil :type (or null string) :read-only t)
  (version nil :type (or null string) :read-only t)
  (calscale nil :type (or null string) :read-only t)
  (method nil :type (or null string) :read-only t)
  (names nil :type list :read-only t)
  (descriptions nil :type list :read-only t)
  (uid nil :type (or null string) :read-only t)
  (last-modified nil :type (or null temporal-value) :read-only t)
  (url nil :type (or null ical-uri-value) :read-only t)
  (categories nil :type list :read-only t)
  (refresh-interval nil :type (or null ical-duration-value) :read-only t)
  (source nil :type (or null ical-uri-value) :read-only t)
  (color nil :type (or null string) :read-only t)
  (images nil :type list :read-only t)
  (components nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-alarm
            (:constructor %make-ical-alarm
                 (component action supported-p trigger trigger-related repeat
                 duration description summary attendees attachments properties
                 diagnostics valid-p extensions)))
  (component nil :type ical-component :read-only t)
  (action nil :type (or null string) :read-only t)
  (supported-p nil :type boolean :read-only t)
  trigger
  (trigger-related nil :type (member nil :start :end) :read-only t)
  (repeat nil :type (or null integer) :read-only t)
  (duration nil :type (or null ical-duration-value) :read-only t)
  (description nil :type (or null string) :read-only t)
  (summary nil :type (or null string) :read-only t)
  (attendees nil :type list :read-only t)
  (attachments nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t)
  (extensions nil :type ical-rfc-extension-set :read-only t))

(defparameter *ical-item-singleton-properties*
  '("CLASS" "COMPLETED" "CREATED" "DESCRIPTION" "DTEND"
    "DUE" "DURATION" "GEO" "LAST-MODIFIED" "LOCATION"
    "ORGANIZER" "PERCENT-COMPLETE" "PRIORITY" "RECURRENCE-ID" "SEQUENCE"
    "STATUS" "SUMMARY" "TRANSP" "URL" "RRULE" "COLOR"))

(defparameter *ical-journal-singleton-properties*
  '("CLASS" "CREATED" "DTSTART" "LAST-MODIFIED" "ORGANIZER"
    "RECURRENCE-ID" "SEQUENCE" "STATUS" "SUMMARY" "URL" "RRULE" "COLOR"))

(defparameter *ical-rfc5545-property-names*
  '("CALSCALE" "METHOD" "PRODID" "VERSION" "ATTACH" "CATEGORIES"
    "CLASS" "COMMENT" "DESCRIPTION" "GEO" "LOCATION"
    "PERCENT-COMPLETE" "PRIORITY" "RESOURCES" "STATUS" "SUMMARY"
    "COMPLETED" "DTEND" "DUE" "DTSTART" "DURATION" "FREEBUSY"
    "TRANSP" "TZID" "TZNAME" "TZOFFSETFROM" "TZOFFSETTO" "TZURL"
    "ATTENDEE" "CONTACT" "ORGANIZER" "RECURRENCE-ID" "RELATED-TO"
    "URL" "UID" "EXDATE" "EXRULE" "RDATE" "RRULE" "ACTION"
    "REPEAT" "TRIGGER" "CREATED" "DTSTAMP" "LAST-MODIFIED" "SEQUENCE"
    "REQUEST-STATUS"))

(defparameter *ical-journal-property-names*
  '("DTSTAMP" "UID" "CLASS" "CREATED" "DTSTART" "LAST-MODIFIED"
    "ORGANIZER" "RECURRENCE-ID" "SEQUENCE" "STATUS" "SUMMARY" "URL"
    "RRULE" "ATTACH" "ATTENDEE" "CATEGORIES" "COMMENT" "CONTACT"
    "DESCRIPTION" "EXDATE" "RELATED-TO" "RDATE" "REQUEST-STATUS"))

(defparameter *ical-freebusy-singleton-properties*
  '("CONTACT" "DTEND" "DTSTART" "ORGANIZER" "URL"))

(defparameter *ical-freebusy-property-names*
  '("DTSTAMP" "UID" "CONTACT" "DTSTART" "DTEND" "ORGANIZER" "URL"
    "ATTENDEE" "COMMENT" "FREEBUSY" "REQUEST-STATUS"
    "STYLED-DESCRIPTION"))

(defparameter *ical-calendar-property-names*
  '("PRODID" "VERSION" "CALSCALE" "METHOD" "NAME" "DESCRIPTION" "UID"
    "LAST-MODIFIED" "URL" "CATEGORIES" "REFRESH-INTERVAL" "SOURCE" "COLOR"
    "IMAGE"))

(defparameter *ical-rfc7986-implemented-property-placement*
  '(("NAME" "VCALENDAR")
    ("REFRESH-INTERVAL" "VCALENDAR")
    ("SOURCE" "VCALENDAR")
    ("COLOR" "VCALENDAR" "VEVENT" "VTODO" "VJOURNAL")
    ("IMAGE" "VCALENDAR" "VEVENT" "VTODO" "VJOURNAL")
    ("CONFERENCE" "VEVENT" "VTODO")))

(defparameter *ical-rfc7986-css3-color-names*
  '("aliceblue" "antiquewhite" "aqua" "aquamarine" "azure" "beige"
    "bisque" "black" "blanchedalmond" "blue" "blueviolet" "brown"
    "burlywood" "cadetblue" "chartreuse" "chocolate" "coral"
    "cornflowerblue" "cornsilk" "crimson" "cyan" "darkblue" "darkcyan"
    "darkgoldenrod" "darkgray" "darkgreen" "darkgrey" "darkkhaki"
    "darkmagenta" "darkolivegreen" "darkorange" "darkorchid" "darkred"
    "darksalmon" "darkseagreen" "darkslateblue" "darkslategray"
    "darkslategrey" "darkturquoise" "darkviolet" "deeppink" "deepskyblue"
    "dimgray" "dimgrey" "dodgerblue" "firebrick" "floralwhite"
    "forestgreen" "fuchsia" "gainsboro" "ghostwhite" "gold" "goldenrod"
    "gray" "green" "greenyellow" "grey" "honeydew" "hotpink"
    "indianred" "indigo" "ivory" "khaki" "lavender" "lavenderblush"
    "lawngreen" "lemonchiffon" "lightblue" "lightcoral" "lightcyan"
    "lightgoldenrodyellow" "lightgray" "lightgreen" "lightgrey"
    "lightpink" "lightsalmon" "lightseagreen" "lightskyblue"
    "lightslategray" "lightslategrey" "lightsteelblue" "lightyellow" "lime"
    "limegreen" "linen" "magenta" "maroon" "mediumaquamarine"
    "mediumblue" "mediumorchid" "mediumpurple" "mediumseagreen"
    "mediumslateblue" "mediumspringgreen" "mediumturquoise"
    "mediumvioletred" "midnightblue" "mintcream" "mistyrose" "moccasin"
    "navajowhite" "navy" "oldlace" "olive" "olivedrab" "orange"
    "orangered" "orchid" "palegoldenrod" "palegreen" "paleturquoise"
    "palevioletred" "papayawhip" "peachpuff" "peru" "pink" "plum"
    "powderblue" "purple" "red" "rosybrown" "royalblue" "saddlebrown"
    "salmon" "sandybrown" "seagreen" "seashell" "sienna" "silver"
    "skyblue" "slateblue" "slategray" "slategrey" "snow" "springgreen"
    "steelblue" "tan" "teal" "thistle" "tomato" "turquoise" "violet"
    "wheat" "white" "whitesmoke" "yellow" "yellowgreen"))

(defun ical-rfc7986-css3-color-name-p (value)
  (and (stringp value)
       (member (string-downcase value) *ical-rfc7986-css3-color-names*
               :test #'string=)))

(defparameter *ical-known-component-child-rules*
  '(("VCALENDAR" "VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY" "VTIMEZONE"
                  "VAVAILABILITY")
    ("VEVENT" "VALARM" "PARTICIPANT" "VLOCATION" "VRESOURCE")
    ("VTODO" "VALARM" "PARTICIPANT" "VLOCATION" "VRESOURCE")
    ("VJOURNAL" "PARTICIPANT" "VLOCATION" "VRESOURCE")
    ("VFREEBUSY" "PARTICIPANT" "VLOCATION" "VRESOURCE")
    ("VAVAILABILITY" "AVAILABLE")
    ("AVAILABLE")
    ("VTIMEZONE" "STANDARD" "DAYLIGHT")
    ("VALARM" "VLOCATION")
    ("PARTICIPANT" "VLOCATION" "VRESOURCE")
    ("VLOCATION")
    ("VRESOURCE")
    ("STANDARD")
    ("DAYLIGHT")))

(defun ical-projection-diagnostic (component code message &optional line)
  (make-diagnostic
   :severity :error :code code :message message
   :span (if line
             (ical-content-line-span line)
             (ical-component-span component))
   :loss-risk :none))

(defun ical-property-index (component)
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
        (let* ((name (ical-content-line-normalized-name line))
               (placement
                 (assoc name *ical-rfc7986-implemented-property-placement*
                        :test #'string=)))
          (when (and placement
                     (not (member (ical-component-normalized-name component)
                                  (rest placement) :test #'string=)))
            (push (ical-projection-diagnostic
                   component :misplaced-rfc7986-property
                   (format nil "~a is not permitted on ~a"
                           name (ical-component-normalized-name component))
                   line)
                  diagnostics)))
        (setf diagnostics
              (nconc diagnostics
                     (copy-list (ical-property-value-diagnostics property))))))
    (values index (nreverse decoded) diagnostics)))

(defun ical-index-properties (index name)
  (nreverse (copy-list (gethash name index))))

(defun ical-first-property (index name)
  (first (ical-index-properties index name)))

(defun ical-first-property-value (index name)
  (let ((property (ical-first-property index name)))
    (and property (first (ical-property-value-values property)))))

(defun ical-first-decoded-value (index name)
  (let* ((property (ical-first-property index name))
         (value (and property (first (ical-property-value-values property)))))
    (and property
         (ical-property-value-valid-p property)
         value
         (ical-value-valid-p value)
         (ical-value-decoded value))))

(defun ical-decoded-property-values (index name)
  (mapcan
   (lambda (property)
     (mapcar #'ical-value-decoded
             (remove-if-not #'ical-value-valid-p
                            (ical-property-value-values property))))
   (ical-index-properties index name)))

(defun ical-projected-images (index)
  (mapcar #'project-ical-image (ical-index-properties index "IMAGE")))

(defun ical-projected-conferences (index)
  (mapcar #'project-ical-conference
          (ical-index-properties index "CONFERENCE")))

(defun ical-calendar-language-variant-diagnostics (component index name)
  (let ((seen (make-hash-table :test #'equal))
        (diagnostics nil))
    (dolist (property (ical-index-properties index name))
      (let* ((language (ical-property-value-language property))
             (key (if language (string-downcase language) :unspecified)))
        (if (gethash key seen)
            (push (ical-projection-diagnostic
                   component :duplicate-icalendar-calendar-language
                   (format nil
                           "VCALENDAR ~a properties require distinct LANGUAGE variants"
                           name)
                   (ical-property-value-line property))
                  diagnostics)
            (setf (gethash key seen) t))))
    (nreverse diagnostics)))

(defun ical-calendar-envelope-cardinality-diagnostics (component index)
  (let ((diagnostics nil))
    (dolist (specification
             '(("PRODID" t) ("VERSION" t) ("CALSCALE" nil) ("METHOD" nil)
               ("UID" nil) ("LAST-MODIFIED" nil) ("URL" nil)
               ("REFRESH-INTERVAL" nil) ("SOURCE" nil) ("COLOR" nil)))
      (destructuring-bind (name required-p) specification
        (let ((properties (ical-index-properties index name)))
          (when (and required-p (null properties))
            (push (ical-projection-diagnostic
                   component :missing-icalendar-calendar-property
                   (format nil "VCALENDAR requires exactly one ~a property"
                           name))
                  diagnostics))
          (when (rest properties)
            (push (ical-projection-diagnostic
                   component :duplicate-icalendar-calendar-property
                   (format nil "VCALENDAR must not contain more than one ~a property"
                           name)
                   (ical-property-value-line (second properties)))
                  diagnostics)))))
    (nreverse diagnostics)))

(defun ical-calendar-envelope-property-diagnostics (component)
  (let ((diagnostics nil))
    (dolist (item (ical-component-items component))
      (when (ical-content-line-p item)
        (cond
          ((not (ical-content-line-valid-p item))
           (push (ical-projection-diagnostic
                  component :invalid-icalendar-calendar-content
                  "invalid retained content prevents safe calendar projection"
                  item)
                 diagnostics))
          ((let ((name (ical-content-line-normalized-name item)))
             (and (find-ical-property-profile name)
                  (not (member name *ical-calendar-property-names*
                               :test #'string=))))
           (push (ical-projection-diagnostic
                  component :misplaced-icalendar-calendar-property
                  (format nil "~a is not a VCALENDAR property"
                          (ical-content-line-normalized-name item))
                  item)
                 diagnostics)))))
    (nreverse diagnostics)))

(defun ical-known-component-placement-diagnostics (component)
  (let* ((parent-name (ical-component-normalized-name component))
         (rule (assoc parent-name *ical-known-component-child-rules*
                      :test #'string=))
         (allowed (rest rule))
         (diagnostics nil))
    (unless (ical-component-closed-p component)
      (push (ical-projection-diagnostic
             component :unclosed-icalendar-semantic-component
             (format nil "~a must have a matching END delimiter" parent-name))
            diagnostics))
    (when rule
      (dolist (child (ical-component-children component))
        (let ((child-name (ical-component-normalized-name child)))
          (when (and (assoc child-name *ical-known-component-child-rules*
                            :test #'string=)
                     (not (member child-name allowed :test #'string=)))
            (push (ical-projection-diagnostic
                   component :misplaced-icalendar-component
                   (format nil "~a cannot be nested directly in ~a"
                           child-name parent-name)
                   (ical-component-begin-line child))
                  diagnostics))
          (when (member child-name allowed :test #'string=)
            (setf diagnostics
                  (nconc diagnostics
                         (ical-known-component-placement-diagnostics child)))))))
    diagnostics))

(defun project-ical-calendar-envelope (component)
  "Validate and project one retained VCALENDAR envelope without changing its CST."
  (unless (and (ical-component-p component)
               (string= "VCALENDAR"
                        (ical-component-normalized-name component)))
    (model-error :invalid-icalendar-calendar-component component
                 "calendar envelope projection requires a VCALENDAR component"))
  (multiple-value-bind (index decoded-properties property-diagnostics)
      (ical-property-index component)
    (let* ((components (ical-component-children component))
           (uid (ical-first-decoded-value index "UID"))
           (last-modified
             (ical-first-decoded-value index "LAST-MODIFIED"))
           (refresh-interval
             (ical-first-decoded-value index "REFRESH-INTERVAL"))
           (color (ical-first-decoded-value index "COLOR"))
           (images (ical-projected-images index))
           (diagnostics
             (nconc property-diagnostics
                    (ical-calendar-envelope-cardinality-diagnostics
                     component index)
                    (ical-calendar-language-variant-diagnostics
                     component index "NAME")
                    (ical-calendar-language-variant-diagnostics
                     component index "DESCRIPTION")
                    (ical-calendar-envelope-property-diagnostics component)
                    (ical-known-component-placement-diagnostics component))))
      (when (and (ical-index-properties index "UID")
                 (not (non-empty-string-p uid)))
        (push (ical-projection-diagnostic
               component :invalid-icalendar-calendar-uid
               "VCALENDAR UID must contain non-empty TEXT")
              diagnostics))
      (when (and last-modified
                 (not (eq :utc (temporal-value-kind last-modified))))
        (push (ical-projection-diagnostic
               component :non-utc-icalendar-calendar-last-modified
               "VCALENDAR LAST-MODIFIED must use UTC DATE-TIME")
              diagnostics))
      (when (and refresh-interval
                 (not (ical-duration-positive-p refresh-interval)))
        (push (ical-projection-diagnostic
               component :non-positive-icalendar-calendar-refresh-interval
               "VCALENDAR REFRESH-INTERVAL must be a positive DURATION")
              diagnostics))
      (when (and color (not (ical-rfc7986-css3-color-name-p color)))
        (push (ical-projection-diagnostic
               component :invalid-rfc7986-color
               "COLOR must be a case-insensitive CSS3 color name")
              diagnostics))
      (unless components
        (setf diagnostics
              (nconc diagnostics
                     (list
                      (ical-projection-diagnostic
                       component :missing-icalendar-calendar-component
                       "VCALENDAR requires at least one calendar component")))))
      (%make-ical-calendar-envelope
       component
       (ical-first-decoded-value index "PRODID")
       (ical-first-decoded-value index "VERSION")
       (ical-first-decoded-value index "CALSCALE")
       (ical-first-decoded-value index "METHOD")
       (ical-decoded-property-values index "NAME")
       (ical-decoded-property-values index "DESCRIPTION")
       uid last-modified
       (ical-first-decoded-value index "URL")
       (ical-decoded-property-values index "CATEGORIES")
       refresh-interval
       (ical-first-decoded-value index "SOURCE")
       color
       images
       components decoded-properties diagnostics (null diagnostics)))))

(defun ical-property-value-type-in-index (index name)
  (let ((property (ical-first-property index name)))
    (and property (ical-property-value-value-type property))))

(defun ical-required-singleton
    (component index name diagnostics &key required-p)
  (let ((properties (ical-index-properties index name)))
    (when (and required-p (null properties))
      (push (ical-projection-diagnostic
             component :missing-icalendar-item-property
             (format nil "~a requires exactly one ~a property"
                     (ical-component-normalized-name component) name))
            diagnostics))
    (when (rest properties)
      (push (ical-projection-diagnostic
             component :duplicate-icalendar-item-property
             (format nil "~a must not occur more than once" name)
             (ical-property-value-line (second properties)))
            diagnostics))
    diagnostics))

(defun ical-journal-property-matrix-diagnostics (component)
  (let ((diagnostics nil))
    (dolist (line (ical-component-properties component))
      (let ((name (ical-content-line-normalized-name line)))
        (when (and (member name *ical-rfc5545-property-names* :test #'string=)
                   (not (member name *ical-journal-property-names*
                                :test #'string=)))
          (push (ical-projection-diagnostic
                 component :misplaced-icalendar-journal-property
                 (format nil
                         "~a is not permitted by the RFC 5545 VJOURNAL property matrix"
                         name)
                 line)
                diagnostics))))
    (dolist (child (ical-component-children component))
      (push (ical-projection-diagnostic
             component :nested-icalendar-journal-component
             "VJOURNAL cannot contain a nested calendar component"
             (ical-component-begin-line child))
            diagnostics))
    (nreverse diagnostics)))

(defun ical-freebusy-property-matrix-diagnostics (component)
  (let ((diagnostics nil))
    (dolist (line (ical-component-properties component))
      (let ((name (ical-content-line-normalized-name line)))
        (when (and (member name *ical-rfc5545-property-names* :test #'string=)
                   (not (member name *ical-freebusy-property-names*
                                :test #'string=)))
          (push (ical-projection-diagnostic
                 component :misplaced-icalendar-freebusy-property
                 (format nil
                         "~a is not permitted by the RFC 5545 VFREEBUSY property matrix"
                         name)
                 line)
                diagnostics))))
    (dolist (child (ical-component-children component))
      (unless (member (ical-component-normalized-name child)
                      '("PARTICIPANT" "VLOCATION" "VRESOURCE")
                      :test #'string=)
        (push (ical-projection-diagnostic
               component :nested-icalendar-freebusy-component
               "VFREEBUSY only permits RFC 9073 publishing subcomponents"
               (ical-component-begin-line child))
              diagnostics)))
    (nreverse diagnostics)))

(defun project-ical-freebusy-component (component)
  "Project one RFC 5545 VFREEBUSY component without assigning scheduling intent."
  (unless (and (ical-component-p component)
               (string= "VFREEBUSY"
                        (ical-component-normalized-name component)))
    (model-error :invalid-icalendar-freebusy-component component
                 "free-busy projection requires a VFREEBUSY component"))
  (multiple-value-bind (index decoded-properties property-diagnostics)
      (ical-property-index component)
    (let ((diagnostics property-diagnostics))
      (dolist (item (ical-component-items component))
        (when (and (ical-content-line-p item)
                   (not (ical-content-line-valid-p item)))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-freebusy-content
                 "invalid retained content prevents safe VFREEBUSY projection"
                 item)
                diagnostics)))
      (dolist (name *ical-freebusy-singleton-properties*)
        (setf diagnostics
              (ical-required-singleton component index name diagnostics)))
      (dolist (name '("UID" "DTSTAMP"))
        (setf diagnostics
              (ical-required-singleton
               component index name diagnostics :required-p t)))
      (setf diagnostics
            (nconc diagnostics
                   (ical-freebusy-property-matrix-diagnostics component)))
      (let* ((uid (ical-first-decoded-value index "UID"))
             (dtstamp (ical-first-decoded-value index "DTSTAMP"))
             (contact (ical-first-decoded-value index "CONTACT"))
             (start (ical-first-decoded-value index "DTSTART"))
             (end (ical-first-decoded-value index "DTEND"))
             (organizer (ical-first-decoded-value index "ORGANIZER"))
             (url (ical-first-decoded-value index "URL"))
             (attendees (ical-decoded-property-values index "ATTENDEE"))
             (comments (ical-decoded-property-values index "COMMENT"))
             (request-statuses
               (ical-decoded-property-values index "REQUEST-STATUS"))
             (extensions (project-ical-rfc-extensions component))
             (periods nil))
        (setf diagnostics
              (nconc diagnostics
                     (copy-list
                      (ical-rfc-extension-set-diagnostics extensions))))
        (unless (non-empty-string-p uid)
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-freebusy-uid
                 "VFREEBUSY UID must contain non-empty TEXT")
                diagnostics))
        (unless (and dtstamp (eq :utc (temporal-value-kind dtstamp)))
          (push (ical-projection-diagnostic
                 component :non-utc-icalendar-freebusy-dtstamp
                 "VFREEBUSY DTSTAMP must be one UTC DATE-TIME value")
                diagnostics))
        (when (and start (not (eq :utc (temporal-value-kind start))))
          (push (ical-projection-diagnostic
                 component :non-utc-icalendar-freebusy-start
                 "VFREEBUSY DTSTART must use UTC DATE-TIME")
                diagnostics))
        (when (and end (not (eq :utc (temporal-value-kind end))))
          (push (ical-projection-diagnostic
                 component :non-utc-icalendar-freebusy-end
                 "VFREEBUSY DTEND must use UTC DATE-TIME")
                diagnostics))
        (when (and end (null start))
          (push (ical-projection-diagnostic
                 component :icalendar-freebusy-end-without-start
                 "VFREEBUSY DTEND requires DTSTART for its increasing bound")
                diagnostics))
        (when (and start end (not (ical-temporal-after-p start end)))
          (push (ical-projection-diagnostic
                 component :non-increasing-icalendar-freebusy-range
                 "VFREEBUSY DTEND must be later than DTSTART")
                diagnostics))
        (dolist (property (ical-index-properties index "FREEBUSY"))
          (when (ical-property-value-valid-p property)
            (multiple-value-bind (type raw-type resolution)
                (ical-property-effective-free-busy-type property)
              (dolist (value (ical-property-value-values property))
                (when (ical-value-valid-p value)
                  (let* ((period (ical-value-decoded value))
                         (period-start (ical-period-value-start period))
                         (period-end (ical-period-value-end period)))
                    (unless (and (eq :utc (temporal-value-kind period-start))
                                 (or (null period-end)
                                     (eq :utc
                                         (temporal-value-kind period-end))))
                      (push (ical-projection-diagnostic
                             component :non-utc-icalendar-freebusy-period
                             "VFREEBUSY FREEBUSY periods must use UTC DATE-TIME values"
                             (ical-property-value-line property))
                            diagnostics))
                    (push (%make-ical-freebusy-period-entry
                           property period type raw-type resolution)
                          periods)))))))
        (setf diagnostics (nreverse diagnostics))
        (%make-ical-freebusy
         component uid dtstamp contact start end organizer url attendees comments
         (nreverse periods) request-statuses decoded-properties diagnostics
         (null diagnostics) extensions)))))

(defun ical-compatible-temporal-property-types-p (index first-name second-name)
  (let ((first-type (ical-property-value-type-in-index index first-name))
        (second-type (ical-property-value-type-in-index index second-name)))
    (or (null first-type) (null second-type) (eq first-type second-type))))

(defun ical-temporal-after-p (start finish)
  (and start finish
       (eq (temporal-value-kind start) (temporal-value-kind finish))
       (equal (temporal-value-timezone-id start)
              (temporal-value-timezone-id finish))
       (string< (temporal-value-local-value start)
                (temporal-value-local-value finish))))

(defun ical-duration-date-only-p (duration)
  (and duration
       (zerop (ical-duration-value-hours duration))
       (zerop (ical-duration-value-minutes duration))
       (zerop (ical-duration-value-seconds duration))))

(defun ical-recur-until-compatible-with-start-p (recur start)
  (let ((until (and recur (ical-recur-value-until recur))))
    (or (null until)
        (null start)
        (case (temporal-value-kind start)
          (:date (eq :date (temporal-value-kind until)))
          (:floating (eq :floating (temporal-value-kind until)))
          ((:utc :zoned) (eq :utc (temporal-value-kind until)))
          (otherwise nil)))))

(defun ical-component-has-property-p (component name)
  (find name (ical-component-properties component)
        :key #'ical-content-line-normalized-name :test #'string=))

(defun ical-alarm-cardinality-diagnostics
    (component index name &key required-p minimum (maximum 1))
  (let* ((properties (ical-index-properties index name))
         (count (length properties))
         (minimum (or minimum (if required-p 1 0)))
         (diagnostics nil))
    (when (< count minimum)
      (push (ical-projection-diagnostic
             component :missing-icalendar-alarm-property
             (format nil "VALARM requires at least ~d ~a propert~a"
                     minimum name (if (= minimum 1) "y" "ies")))
            diagnostics))
    (when (and maximum (> count maximum))
      (push (ical-projection-diagnostic
             component :duplicate-icalendar-alarm-property
             (format nil "VALARM permits at most ~d ~a propert~a"
                     maximum name (if (= maximum 1) "y" "ies"))
             (ical-property-value-line (nth maximum properties)))
            diagnostics))
    (nreverse diagnostics)))

(defun ical-alarm-forbidden-property-diagnostics
    (component index action names)
  (let ((diagnostics nil))
    (dolist (name names (nreverse diagnostics))
      (let ((property (ical-first-property index name)))
        (when property
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-alarm-action-property
                 (format nil "~a is not valid for ACTION=~a" name action)
                 (ical-property-value-line property))
                diagnostics))))))

(defun ical-alarm-action-property-diagnostics (component index action)
  (cond
    ((string= action "AUDIO")
     (nconc
      (ical-alarm-cardinality-diagnostics
       component index "ATTACH" :maximum 1)
      (ical-alarm-forbidden-property-diagnostics
       component index action '("DESCRIPTION" "SUMMARY" "ATTENDEE"))))
    ((string= action "DISPLAY")
     (nconc
      (ical-alarm-cardinality-diagnostics
       component index "DESCRIPTION" :required-p t)
      (ical-alarm-forbidden-property-diagnostics
       component index action '("SUMMARY" "ATTENDEE" "ATTACH"))))
    ((string= action "EMAIL")
     (nconc
      (ical-alarm-cardinality-diagnostics
       component index "DESCRIPTION" :required-p t)
      (ical-alarm-cardinality-diagnostics
       component index "SUMMARY" :required-p t)
      (ical-alarm-cardinality-diagnostics
       component index "ATTENDEE" :minimum 1 :maximum nil)))
    (t nil)))

(defun ical-alarm-trigger-anchor-available-p (parent trigger-related)
  (case trigger-related
    (:start (ical-component-has-property-p parent "DTSTART"))
    (:end
     (if (string= "VEVENT" (ical-component-normalized-name parent))
         (or (ical-component-has-property-p parent "DTEND")
             (and (ical-component-has-property-p parent "DTSTART")
                  (ical-component-has-property-p parent "DURATION")))
         (or (ical-component-has-property-p parent "DUE")
             (and (ical-component-has-property-p parent "DTSTART")
                  (ical-component-has-property-p parent "DURATION")))))
    (otherwise t)))

(defun project-ical-alarm (component parent)
  "Project a VALARM as inert data; this function never executes its action."
  (unless (and (ical-component-p component)
               (string= "VALARM" (ical-component-normalized-name component)))
    (model-error :invalid-icalendar-alarm-component component
                 "alarm projection requires a VALARM component"))
  (unless (and (ical-component-p parent)
               (member (ical-component-normalized-name parent)
                       '("VEVENT" "VTODO") :test #'string=))
    (model-error :invalid-icalendar-alarm-parent parent
                 "VALARM parent must be VEVENT or VTODO"))
  (multiple-value-bind (index decoded-properties property-diagnostics)
      (ical-property-index component)
    (let ((diagnostics property-diagnostics))
      (dolist (item (ical-component-items component))
        (when (and (ical-content-line-p item)
                   (not (ical-content-line-valid-p item)))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-alarm-content
                 "invalid retained content prevents safe alarm projection" item)
                diagnostics)))
      (dolist (name '("ACTION" "TRIGGER" "DURATION" "REPEAT"))
        (setf diagnostics
              (nconc diagnostics
                     (ical-alarm-cardinality-diagnostics
                      component index name
                      :required-p (member name '("ACTION" "TRIGGER")
                                          :test #'string=)))))
      (let* ((action-value (ical-first-decoded-value index "ACTION"))
             (action (and action-value (string-upcase action-value)))
             (supported-p
               (not (null (and action
                               (member action '("AUDIO" "DISPLAY" "EMAIL")
                                       :test #'string=)))))
             (trigger-property (ical-first-property index "TRIGGER"))
             (trigger-type
               (and trigger-property
                    (ical-property-value-value-type trigger-property)))
             (trigger (ical-first-decoded-value index "TRIGGER"))
             (related-result
               (and trigger-property
                    (multiple-value-list
                     (ical-single-parameter-text
                      (ical-property-value-line trigger-property) "RELATED"))))
             (related-text (first related-result))
             (related-valid-p (if related-result (second related-result) t))
             (trigger-related
               (and (eq trigger-type :duration)
                    (if (and related-text (string-equal related-text "END"))
                        :end
                        :start)))
             (repeat (ical-first-decoded-value index "REPEAT"))
             (duration (ical-first-decoded-value index "DURATION"))
             (description (ical-first-decoded-value index "DESCRIPTION"))
             (summary (ical-first-decoded-value index "SUMMARY"))
             (attendees
               (mapcar (lambda (property)
                         (ical-value-decoded
                          (first (ical-property-value-values property))))
                       (remove-if-not #'ical-property-value-valid-p
                                      (ical-index-properties index "ATTENDEE"))))
             (attachments
               (mapcar (lambda (property)
                         (ical-value-decoded
                          (first (ical-property-value-values property))))
                       (remove-if-not #'ical-property-value-valid-p
                                      (ical-index-properties index "ATTACH"))))
             (proximity-p (ical-first-property index "PROXIMITY"))
             (extensions (project-ical-rfc-extensions component)))
        (setf diagnostics
              (nconc diagnostics
                     (copy-list (ical-rfc-extension-set-diagnostics
                                 extensions))))
        (unless related-valid-p
          (push (third related-result) diagnostics))
        (when (and related-text (not (eq trigger-type :duration)))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-alarm-trigger-related
                 "TRIGGER RELATED is only valid with a DURATION value")
                diagnostics))
        (when (and related-text
                   (not (member (string-upcase related-text) '("START" "END")
                                :test #'string=)))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-alarm-trigger-related
                 "TRIGGER RELATED must be START or END")
                diagnostics))
        (when (and (eq trigger-type :date-time) trigger
                   (not (eq :utc (temporal-value-kind trigger))))
          (push (ical-projection-diagnostic
                 component :non-utc-icalendar-alarm-trigger
                 "absolute VALARM TRIGGER must be a UTC DATE-TIME")
                diagnostics))
        (when (and trigger-related (not proximity-p)
                   (not (ical-alarm-trigger-anchor-available-p
                         parent trigger-related)))
          (push (ical-projection-diagnostic
                 component :missing-icalendar-alarm-trigger-anchor
                 (format nil "relative ~a trigger has no corresponding parent boundary"
                         (string-downcase (symbol-name trigger-related))))
                diagnostics))
        (when (not (eq (null repeat) (null duration)))
          (push (ical-projection-diagnostic
                 component :incomplete-icalendar-alarm-repeat
                 "VALARM DURATION and REPEAT must occur together")
                diagnostics))
        (when (and repeat (minusp repeat))
          (push (ical-projection-diagnostic
                 component :negative-icalendar-alarm-repeat
                 "VALARM REPEAT must be non-negative")
                diagnostics))
        (when (and duration (not (ical-duration-positive-p duration)))
          (push (ical-projection-diagnostic
                 component :non-positive-icalendar-alarm-duration
                 "repeating VALARM DURATION must be positive and non-zero")
                diagnostics))
        (when supported-p
          (setf diagnostics
                (nconc diagnostics
                       (ical-alarm-action-property-diagnostics
                        component index action))))
        (setf diagnostics (nreverse diagnostics))
        (%make-ical-alarm
         component action supported-p trigger trigger-related repeat duration
         description summary attendees attachments decoded-properties diagnostics
         (null diagnostics) extensions)))))

(defun project-ical-component (component &key method-present-p)
  "Project one retained VEVENT, VTODO, or VJOURNAL through core invariants."
  (unless (ical-component-p component)
    (model-error :invalid-icalendar-component-object component
                 "value must be an iCalendar component"))
  (let* ((component-name (ical-component-normalized-name component))
         (kind (cond ((string= component-name "VEVENT") :event)
                     ((string= component-name "VTODO") :todo)
                     ((string= component-name "VJOURNAL") :journal)
                     (t nil))))
    (unless kind
      (model-error :unsupported-icalendar-projection component-name
                   "only VEVENT, VTODO, and VJOURNAL projection is supported"))
    (multiple-value-bind (index decoded-properties property-diagnostics)
        (ical-property-index component)
      (let ((diagnostics property-diagnostics))
        (dolist (property (ical-index-properties index "ATTACH"))
          (let ((attachment (project-ical-managed-attachment property)))
            (setf diagnostics
                  (nconc diagnostics
                         (copy-list
                          (ical-managed-attachment-diagnostics attachment))))))
        (dolist (item (ical-component-items component))
          (when (and (ical-content-line-p item)
                     (not (ical-content-line-valid-p item)))
            (push (ical-projection-diagnostic
                   component :invalid-icalendar-item-content
                   "invalid retained content prevents safe item projection" item)
                  diagnostics)))
        (dolist (name (if (eq kind :journal)
                          *ical-journal-singleton-properties*
                          *ical-item-singleton-properties*))
          (setf diagnostics
                (ical-required-singleton component index name diagnostics)))
        (when (eq kind :journal)
          (setf diagnostics
                (nconc diagnostics
                       (ical-journal-property-matrix-diagnostics component))))
        (setf diagnostics
              (ical-required-singleton
               component index "UID" diagnostics :required-p t))
        (setf diagnostics
              (ical-required-singleton
               component index "DTSTAMP" diagnostics :required-p t))
        (setf diagnostics
              (ical-required-singleton
               component index "DTSTART" diagnostics
               :required-p (and (eq kind :event) (not method-present-p))))
        (let* ((uid (ical-first-decoded-value index "UID"))
               (dtstamp (ical-first-decoded-value index "DTSTAMP"))
               (summary (ical-first-decoded-value index "SUMMARY"))
               (descriptions
                 (mapcan
                  (lambda (property)
                    (mapcar #'ical-value-decoded
                            (remove-if-not
                             #'ical-value-valid-p
                             (ical-property-value-values property))))
                  (ical-index-properties index "DESCRIPTION")))
               (description (first descriptions))
               (request-statuses
                 (mapcan
                  (lambda (property)
                    (mapcar #'ical-value-decoded
                            (remove-if-not
                             #'ical-value-valid-p
                             (ical-property-value-values property))))
                  (ical-index-properties index "REQUEST-STATUS")))
               (status (ical-first-decoded-value index "STATUS"))
               (location (ical-first-decoded-value index "LOCATION"))
               (url (ical-first-decoded-value index "URL"))
               (transparency (ical-first-decoded-value index "TRANSP"))
               (start (ical-first-decoded-value index "DTSTART"))
               (end (ical-first-decoded-value index "DTEND"))
               (due (ical-first-decoded-value index "DUE"))
               (duration (ical-first-decoded-value index "DURATION"))
               (completed (ical-first-decoded-value index "COMPLETED"))
               (percent (ical-first-decoded-value index "PERCENT-COMPLETE"))
               (priority (ical-first-decoded-value index "PRIORITY"))
               (sequence (ical-first-decoded-value index "SEQUENCE"))
               (recurrence-id
                 (ical-first-decoded-value index "RECURRENCE-ID"))
               (recurrence-id-property
                 (ical-first-property index "RECURRENCE-ID"))
               (recurrence-range-result
                 (and recurrence-id-property
                      (multiple-value-list
                       (ical-single-parameter-text
                        (ical-property-value-line recurrence-id-property)
                        "RANGE"))))
               (recurrence-range-text (first recurrence-range-result))
               (recurrence-range-valid-p
                 (if recurrence-range-result
                     (second recurrence-range-result)
                     t))
               (recurrence-range
                 (if recurrence-range-text :this-and-future :this))
               (recurrence-rule
                 (ical-first-decoded-value index "RRULE"))
               (recurrence-dates
                 (mapcan
                  (lambda (property)
                    (mapcar #'ical-value-decoded
                            (remove-if-not
                             #'ical-value-valid-p
                             (ical-property-value-values property))))
                  (ical-index-properties index "RDATE")))
               (recurrence-exception-dates
                 (mapcan
                  (lambda (property)
                    (mapcar #'ical-value-decoded
                            (remove-if-not
                             #'ical-value-valid-p
                             (ical-property-value-values property))))
                  (ical-index-properties index "EXDATE")))
               (categories
                 (mapcan
                  (lambda (property)
                    (mapcar #'ical-value-decoded
                            (remove-if-not
                             #'ical-value-valid-p
                             (ical-property-value-values property))))
                  (ical-index-properties index "CATEGORIES")))
               (color (ical-first-decoded-value index "COLOR"))
               (images (ical-projected-images index))
               (conferences (ical-projected-conferences index))
               (extensions (project-ical-rfc-extensions component))
               (alarms
                 (mapcar
                  (lambda (alarm) (project-ical-alarm alarm component))
                  (remove-if-not
                   (lambda (child)
                     (string= "VALARM"
                              (ical-component-normalized-name child)))
                   (ical-component-children component)))))
          (dolist (alarm alarms)
            (setf diagnostics
                  (nconc diagnostics
                         (copy-list (ical-alarm-diagnostics alarm)))))
          (setf diagnostics
                (nconc diagnostics
                       (copy-list
                        (ical-rfc-extension-set-diagnostics extensions))))
          (when (or (null uid) (zerop (length uid)))
            (push (ical-projection-diagnostic
                   component :invalid-icalendar-item-uid
                   "UID must contain non-empty TEXT")
                  diagnostics))
          (when (and dtstamp (not (eq :utc (temporal-value-kind dtstamp))))
            (push (ical-projection-diagnostic
                   component :non-utc-icalendar-item-dtstamp
                   "DTSTAMP must be a UTC DATE-TIME value")
                  diagnostics))
          (when (and sequence (minusp sequence))
            (push (ical-projection-diagnostic
                   component :negative-icalendar-item-sequence
                   "SEQUENCE must be a non-negative integer")
                  diagnostics))
          (when (and (eq kind :journal)
                     (or recurrence-id recurrence-rule recurrence-dates
                         recurrence-exception-dates)
                     (null start))
            (push (ical-projection-diagnostic
                   component :journal-recurrence-without-start
                   "recurring VJOURNAL content requires DTSTART")
                  diagnostics))
          (when (and (eq kind :journal) recurrence-id start
                     (not (ical-compatible-temporal-property-types-p
                           index "DTSTART" "RECURRENCE-ID")))
            (push (ical-projection-diagnostic
                   component :mismatched-icalendar-journal-recurrence-id-type
                   "VJOURNAL RECURRENCE-ID must have the same value type as DTSTART")
                  diagnostics))
          (when (and (eq kind :event)
                     (ical-first-property index "DTEND")
                     (ical-first-property index "DURATION"))
            (push (ical-projection-diagnostic
                   component :conflicting-icalendar-event-end
                   "VEVENT cannot contain both DTEND and DURATION")
                  diagnostics))
          (when (and (eq kind :todo)
                     (ical-first-property index "DUE")
                     (ical-first-property index "DURATION"))
            (push (ical-projection-diagnostic
                   component :conflicting-icalendar-todo-end
                   "VTODO cannot contain both DUE and DURATION")
                  diagnostics))
          (when (and (eq kind :todo) duration (null start))
            (push (ical-projection-diagnostic
                   component :todo-duration-without-start
                   "VTODO DURATION requires DTSTART")
                  diagnostics))
          (when (and duration (not (ical-duration-positive-p duration)))
            (push (ical-projection-diagnostic
                   component :non-positive-icalendar-item-duration
                   "VEVENT and VTODO DURATION must be positive and non-zero")
                  diagnostics))
          (when (and end
                     (not (ical-compatible-temporal-property-types-p
                           index "DTSTART" "DTEND")))
            (push (ical-projection-diagnostic
                   component :mismatched-icalendar-event-time-types
                   "DTSTART and DTEND must use the same value type")
                  diagnostics))
          (when (and due start
                     (not (ical-compatible-temporal-property-types-p
                           index "DTSTART" "DUE")))
            (push (ical-projection-diagnostic
                   component :mismatched-icalendar-todo-time-types
                   "DTSTART and DUE must use the same value type")
                  diagnostics))
          (when (and start end (not (ical-temporal-after-p start end)))
            (push (ical-projection-diagnostic
                   component :non-increasing-icalendar-event-time
                   "DTEND must be later than DTSTART")
                  diagnostics))
          (when (and start due (not (ical-temporal-after-p start due)))
            (push (ical-projection-diagnostic
                   component :non-increasing-icalendar-todo-time
                   "DUE must be later than DTSTART")
                  diagnostics))
          (when (and (eq kind :event) duration
                     (eq :date
                         (ical-property-value-type-in-index index "DTSTART"))
                     (not (ical-duration-date-only-p duration)))
            (push (ical-projection-diagnostic
                   component :timed-duration-on-all-day-event
                   "DATE-valued VEVENT duration can only use weeks or days")
                  diagnostics))
          (when (not (ical-recur-until-compatible-with-start-p
                      recurrence-rule start))
            (push (ical-projection-diagnostic
                   component :mismatched-icalendar-recur-until-type
                   "RRULE UNTIL must match DTSTART: DATE and floating forms match; UTC or TZID-qualified DTSTART requires UTC UNTIL")
                  diagnostics))
          (unless recurrence-range-valid-p
            (push (third recurrence-range-result) diagnostics))
          (when (and recurrence-range-text
                     (not (string-equal recurrence-range-text
                                        "THISANDFUTURE")))
            (push (ical-projection-diagnostic
                   component :invalid-icalendar-recurrence-range
                   "RECURRENCE-ID RANGE must be THISANDFUTURE")
                  diagnostics))
          (when (and percent (not (<= 0 percent 100)))
            (push (ical-projection-diagnostic
                   component :invalid-vtodo-percent-complete
                   "PERCENT-COMPLETE must be from 0 through 100")
                  diagnostics))
          (when (and priority (not (<= 0 priority 9)))
            (push (ical-projection-diagnostic
                   component :invalid-icalendar-priority
                   "PRIORITY must be from 0 through 9")
                  diagnostics))
          (when (and color (not (ical-rfc7986-css3-color-name-p color)))
            (push (ical-projection-diagnostic
                   component :invalid-rfc7986-color
                   "COLOR must be a case-insensitive CSS3 color name")
                  diagnostics))
          (let ((allowed-statuses
                  (case kind
                    (:event '("TENTATIVE" "CONFIRMED" "CANCELLED"))
                    (:todo '("NEEDS-ACTION" "COMPLETED" "IN-PROCESS"
                             "CANCELLED"))
                    (:journal '("DRAFT" "FINAL" "CANCELLED")))))
            (when (and status
                       (not (member (string-upcase status) allowed-statuses
                                    :test #'string=)))
              (push (ical-projection-diagnostic
                     component :invalid-icalendar-item-status
                     (format nil "~a is not valid for ~a" status component-name))
                    diagnostics)))
          (when (and transparency
                     (or (not (eq kind :event))
                         (not (member (string-upcase transparency)
                                      '("OPAQUE" "TRANSPARENT")
                                      :test #'string=))))
            (push (ical-projection-diagnostic
                   component :invalid-icalendar-transparency
                   "TRANSP is only valid on VEVENT and must be OPAQUE or TRANSPARENT")
                  diagnostics))
          (setf diagnostics (nreverse diagnostics))
          (%make-ical-calendar-item
           kind component uid dtstamp summary description status location url
           transparency categories color images conferences start end due duration completed percent
           priority sequence recurrence-id recurrence-range recurrence-rule
           recurrence-dates recurrence-exception-dates alarms
           decoded-properties diagnostics (null diagnostics) descriptions
           request-statuses extensions))))))

(defun assert-ical-conference-egress-safe (item audience)
  "Reject attendee egress when ITEM contains a moderator-only conference URI."
  (unless (ical-calendar-item-p item)
    (model-error :invalid-icalendar-conference-egress-item item
                 "conference egress requires a projected calendar item"))
  (unless (ical-calendar-item-valid-p item)
    (model-error :invalid-icalendar-conference-egress-item
                 (ical-calendar-item-diagnostics item)
                 "conference egress requires a semantically valid item"))
  (unless (member audience '(:owner :attendees))
    (model-error :invalid-icalendar-conference-egress-audience audience
                 "conference egress audience must be OWNER or ATTENDEES"))
  (when (and (eq audience :attendees)
             (find-if #'ical-conference-moderator-p
                      (ical-calendar-item-conferences item)))
    (model-error :moderator-conference-attendee-egress
                 (ical-calendar-item-uid item)
                 "MODERATOR conference access must not be sent to attendees"))
  t)
