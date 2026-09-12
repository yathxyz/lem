(in-package #:lem-structured-notes)

(defstruct (ical-available
            (:constructor %make-ical-available
                (component uid dtstamp start end duration recurrence-id
                 recurrence-range recurrence-rule recurrence-dates
                 recurrence-exception-dates
                 summary description location categories properties
                 diagnostics valid-p)))
  (component nil :type ical-component :read-only t)
  (uid nil :type (or null string) :read-only t)
  (dtstamp nil :type (or null temporal-value) :read-only t)
  (start nil :type (or null temporal-value) :read-only t)
  (end nil :type (or null temporal-value) :read-only t)
  (duration nil :type (or null ical-duration-value) :read-only t)
  (recurrence-id nil :type (or null temporal-value) :read-only t)
  (recurrence-range :this :type keyword :read-only t)
  (recurrence-rule nil :type (or null ical-recur-value) :read-only t)
  (recurrence-dates nil :type list :read-only t)
  (recurrence-exception-dates nil :type list :read-only t)
  (summary nil :type (or null string) :read-only t)
  (description nil :type (or null string) :read-only t)
  (location nil :type (or null string) :read-only t)
  (categories nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-availability
            (:constructor %make-ical-availability
                (component uid dtstamp busy-type start end duration priority
                 available properties diagnostics valid-p)))
  (component nil :type ical-component :read-only t)
  (uid nil :type (or null string) :read-only t)
  (dtstamp nil :type (or null temporal-value) :read-only t)
  (busy-type "BUSY-UNAVAILABLE" :type string :read-only t)
  (start nil :type (or null temporal-value) :read-only t)
  (end nil :type (or null temporal-value) :read-only t)
  (duration nil :type (or null ical-duration-value) :read-only t)
  (priority 0 :type integer :read-only t)
  (available nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defparameter *ical-availability-singleton-properties*
  '("BUSYTYPE" "CLASS" "CREATED" "DESCRIPTION" "DTSTART" "DTEND"
    "DURATION" "LAST-MODIFIED" "LOCATION" "ORGANIZER" "PRIORITY"
    "SEQUENCE" "SUMMARY" "URL"))

(defparameter *ical-availability-multiple-properties*
  '("CATEGORIES" "COMMENT" "CONTACT"))

(defparameter *ical-available-singleton-properties*
  '("CREATED" "DESCRIPTION" "DTEND" "DURATION"
    "LAST-MODIFIED" "LOCATION" "RECURRENCE-ID" "RRULE" "SUMMARY"))

(defparameter *ical-available-multiple-properties*
  '("CATEGORIES" "COMMENT" "CONTACT" "EXDATE" "RDATE"))

(defun ical-availability-property-values (index name)
  (mapcan
   (lambda (property)
     (mapcar #'ical-value-decoded
             (remove-if-not #'ical-value-valid-p
                            (ical-property-value-values property))))
   (ical-index-properties index name)))

(defun ical-availability-invalid-content-diagnostics (component diagnostics)
  (dolist (item (ical-component-items component) diagnostics)
    (when (and (ical-content-line-p item)
               (not (ical-content-line-valid-p item)))
      (push (ical-projection-diagnostic
             component :invalid-icalendar-availability-content
             "invalid retained content prevents safe availability projection"
             item)
            diagnostics))))

(defun ical-availability-property-placement-diagnostics
    (component allowed-singletons allowed-multiples)
  (let ((allowed (append '("UID" "DTSTAMP" "DTSTART")
                         allowed-singletons allowed-multiples))
        (diagnostics nil))
    (dolist (line (ical-component-properties component) (nreverse diagnostics))
      (let ((name (ical-content-line-normalized-name line)))
        (when (and (find-ical-property-profile name)
                   (not (member name allowed :test #'string=)))
          (push (ical-projection-diagnostic
                 component :misplaced-icalendar-availability-property
                 (format nil "~a is not permitted in ~a"
                         name (ical-component-normalized-name component))
                 line)
                diagnostics))))))

(defun ical-availability-date-time-p (value)
  (and (temporal-value-p value)
       (member (temporal-value-kind value) '(:utc :zoned))))

(defun ical-availability-same-time-form-p (first second)
  (and (temporal-value-p first)
       (temporal-value-p second)
       (eq (temporal-value-kind first) (temporal-value-kind second))
       (equal (temporal-value-timezone-id first)
              (temporal-value-timezone-id second))))

(defun ical-availability-utc-metadata-diagnostics
    (component index names diagnostics)
  (dolist (name names diagnostics)
    (let ((value (ical-first-decoded-value index name)))
      (when (and value (not (eq :utc (temporal-value-kind value))))
        (push (ical-projection-diagnostic
               component :non-utc-icalendar-availability-metadata
               (format nil "~a must be a UTC DATE-TIME" name))
              diagnostics)))))

(defun ical-availability-cardinality-diagnostics
    (component index singleton-names diagnostics)
  (dolist (name singleton-names diagnostics)
    (setf diagnostics
          (ical-required-singleton component index name diagnostics))))

(defun ical-availability-temporal-diagnostics
    (component index start end duration diagnostics &key start-required-p)
  (when (and start-required-p (null start))
    ;; Cardinality reports a missing DTSTART; this reports an invalid decoded
    ;; DTSTART only when a line was actually present.
    (when (ical-first-property index "DTSTART")
      (push (ical-projection-diagnostic
             component :invalid-icalendar-availability-start
             "DTSTART must decode as a DATE-TIME")
            diagnostics)))
  (dolist (entry (list (cons "DTSTART" start) (cons "DTEND" end)))
    (when (and (cdr entry) (not (ical-availability-date-time-p (cdr entry))))
      (push (ical-projection-diagnostic
             component :invalid-icalendar-availability-date-time
             (format nil "~a must be UTC or local DATE-TIME with TZID"
                     (car entry)))
            diagnostics)))
  (when (and (ical-first-property index "DTEND")
             (ical-first-property index "DURATION"))
    (push (ical-projection-diagnostic
           component :conflicting-icalendar-availability-end
           "DTEND and DURATION must not occur together")
          diagnostics))
  (when (and duration (not (ical-duration-positive-p duration)))
    (push (ical-projection-diagnostic
           component :non-positive-icalendar-availability-duration
           "availability DURATION must be positive and non-zero")
          diagnostics))
  diagnostics)

(defun ical-availability-valid-uid-diagnostic (component uid diagnostics)
  (when (or (null uid) (zerop (length uid)))
    (push (ical-projection-diagnostic
           component :invalid-icalendar-availability-uid
           "UID must contain non-empty TEXT")
          diagnostics))
  diagnostics)

(defun project-ical-available-component (component)
  "Project one RFC 7953 AVAILABLE component without altering retained source."
  (unless (and (ical-component-p component)
               (string= "AVAILABLE" (ical-component-normalized-name component)))
    (model-error :invalid-icalendar-available-component component
                 "AVAILABLE projection requires an AVAILABLE component"))
  (multiple-value-bind (index properties property-diagnostics)
      (ical-property-index component)
    (let ((diagnostics
            (ical-availability-invalid-content-diagnostics
             component property-diagnostics)))
      (dolist (name '("UID" "DTSTAMP" "DTSTART"))
        (setf diagnostics
              (ical-required-singleton
               component index name diagnostics :required-p t)))
      (setf diagnostics
            (ical-availability-cardinality-diagnostics
             component index *ical-available-singleton-properties*
             diagnostics))
      (setf diagnostics
            (nconc diagnostics
                   (ical-availability-property-placement-diagnostics
                    component *ical-available-singleton-properties*
                    *ical-available-multiple-properties*)))
      (let* ((uid (ical-first-decoded-value index "UID"))
             (dtstamp (ical-first-decoded-value index "DTSTAMP"))
             (start (ical-first-decoded-value index "DTSTART"))
             (end (ical-first-decoded-value index "DTEND"))
             (duration (ical-first-decoded-value index "DURATION"))
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
               (if recurrence-range-result (second recurrence-range-result) t))
             (recurrence-range
               (if recurrence-range-text :this-and-future :this))
             (recurrence-rule (ical-first-decoded-value index "RRULE"))
             (recurrence-dates
               (ical-availability-property-values index "RDATE"))
             (exception-dates
               (ical-availability-property-values index "EXDATE"))
             (summary (ical-first-decoded-value index "SUMMARY"))
             (description (ical-first-decoded-value index "DESCRIPTION"))
             (location (ical-first-decoded-value index "LOCATION"))
             (categories
               (ical-availability-property-values index "CATEGORIES")))
        (setf diagnostics
              (ical-availability-valid-uid-diagnostic
               component uid diagnostics))
        (setf diagnostics
              (ical-availability-utc-metadata-diagnostics
               component index '("DTSTAMP" "CREATED" "LAST-MODIFIED")
               diagnostics))
        (setf diagnostics
              (ical-availability-temporal-diagnostics
               component index start end duration diagnostics
               :start-required-p t))
        (when (and start end
                   (or (not (ical-availability-same-time-form-p start end))
                       (not (ical-temporal-after-p start end))))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-available-end
                 "AVAILABLE DTEND must be later than DTSTART in the same time form")
                diagnostics))
        (when (and recurrence-id start
                   (not (ical-availability-same-time-form-p
                         recurrence-id start)))
          (push (ical-projection-diagnostic
                 component :mismatched-icalendar-available-recurrence-id
                 "RECURRENCE-ID must match the DTSTART time form and TZID")
                diagnostics))
        (unless recurrence-range-valid-p
          (push (third recurrence-range-result) diagnostics))
        (when (and recurrence-range-text
                   (not (string-equal recurrence-range-text
                                      "THISANDFUTURE")))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-available-recurrence-range
                 "RECURRENCE-ID RANGE must be THISANDFUTURE")
                diagnostics))
        (when (not (ical-recur-until-compatible-with-start-p
                    recurrence-rule start))
          (push (ical-projection-diagnostic
                 component :mismatched-icalendar-available-recur-until
                 "RRULE UNTIL must match the DTSTART time form")
                diagnostics))
        (dolist (child (ical-component-children component))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-available-child
                 "AVAILABLE must not contain child components"
                 (ical-component-begin-line child))
                diagnostics))
        (setf diagnostics (nreverse diagnostics))
        (%make-ical-available
         component uid dtstamp start end duration recurrence-id recurrence-range
         recurrence-rule recurrence-dates exception-dates summary description
         location categories properties diagnostics (null diagnostics))))))

(defun ical-availability-priority-rank (priority)
  "Return the RFC 7953 processing rank, where larger means higher priority."
  (unless (and (integerp priority) (<= 0 priority 9))
    (model-error :invalid-icalendar-availability-priority priority
                 "availability priority must be from 0 through 9"))
  (if (zerop priority) 0 (- 10 priority)))

(defun ical-availability-busy-type-rank (busy-type)
  "Return the RFC 7953 same-priority BUSYTYPE precedence rank."
  (unless (stringp busy-type)
    (model-error :invalid-icalendar-availability-busy-type busy-type
                 "BUSYTYPE must be TEXT"))
  (cond ((string-equal busy-type "BUSY") 3)
        ((string-equal busy-type "BUSY-UNAVAILABLE") 2)
        ((string-equal busy-type "BUSY-TENTATIVE") 1)
        (t 0)))

(defun project-ical-availability-component (component)
  "Project one RFC 7953 VAVAILABILITY and each nested AVAILABLE component."
  (unless (and (ical-component-p component)
               (string= "VAVAILABILITY"
                        (ical-component-normalized-name component)))
    (model-error :invalid-icalendar-availability-component component
                 "availability projection requires VAVAILABILITY"))
  (multiple-value-bind (index properties property-diagnostics)
      (ical-property-index component)
    (let ((diagnostics
            (ical-availability-invalid-content-diagnostics
             component property-diagnostics)))
      (dolist (name '("UID" "DTSTAMP"))
        (setf diagnostics
              (ical-required-singleton
               component index name diagnostics :required-p t)))
      (setf diagnostics
            (ical-availability-cardinality-diagnostics
             component index *ical-availability-singleton-properties*
             diagnostics))
      (setf diagnostics
            (nconc diagnostics
                   (ical-availability-property-placement-diagnostics
                    component *ical-availability-singleton-properties*
                    *ical-availability-multiple-properties*)))
      (let* ((uid (ical-first-decoded-value index "UID"))
             (dtstamp (ical-first-decoded-value index "DTSTAMP"))
             (busy-type-value (ical-first-decoded-value index "BUSYTYPE"))
             (busy-type (if busy-type-value
                            (string-upcase busy-type-value)
                            "BUSY-UNAVAILABLE"))
             (start (ical-first-decoded-value index "DTSTART"))
             (end (ical-first-decoded-value index "DTEND"))
             (duration (ical-first-decoded-value index "DURATION"))
             (priority-value (ical-first-decoded-value index "PRIORITY"))
             (priority (or priority-value 0))
             (available nil))
        (setf diagnostics
              (ical-availability-valid-uid-diagnostic
               component uid diagnostics))
        (setf diagnostics
              (ical-availability-utc-metadata-diagnostics
               component index '("DTSTAMP" "CREATED" "LAST-MODIFIED")
               diagnostics))
        (setf diagnostics
              (ical-availability-temporal-diagnostics
               component index start end duration diagnostics))
        (when (and duration (null start))
          (push (ical-projection-diagnostic
                 component :icalendar-availability-duration-without-start
                 "VAVAILABILITY DURATION requires DTSTART")
                diagnostics))
        (when (and start end
                   (or (not (ical-availability-same-time-form-p start end))
                       (string< (temporal-value-local-value end)
                                (temporal-value-local-value start))))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-availability-end
                 "VAVAILABILITY DTEND must equal or follow DTSTART in the same time form")
                diagnostics))
        (unless (and (integerp priority) (<= 0 priority 9))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-availability-priority
                 "PRIORITY must be from 0 through 9")
                diagnostics))
        (when (and busy-type-value
                   (or (zerop (length busy-type))
                       (not (ical-token-p busy-type))
                       (string= busy-type "FREE")))
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-availability-busy-type
                 "BUSYTYPE must be BUSY, BUSY-UNAVAILABLE, BUSY-TENTATIVE, or an extension token; FREE is forbidden")
                diagnostics))
        (dolist (child (ical-component-children component))
          (if (string= "AVAILABLE" (ical-component-normalized-name child))
              (let ((projection (project-ical-available-component child)))
                (push projection available)
                (setf diagnostics
                      (nconc diagnostics
                             (copy-list (ical-available-diagnostics projection)))))
              (push (ical-projection-diagnostic
                     component :invalid-icalendar-availability-child
                     "VAVAILABILITY may contain only AVAILABLE components"
                     (ical-component-begin-line child))
                    diagnostics)))
        (setf available (nreverse available)
              diagnostics (nreverse diagnostics))
        (%make-ical-availability
         component uid dtstamp busy-type start end duration priority available
         properties diagnostics (null diagnostics))))))

(defun ical-availability-sensitive-property-p (property)
  "Identify RFC 7953 examples of nonessential data that needs redaction."
  (unless (ical-property-value-p property)
    (model-error :invalid-icalendar-availability-property property
                 "privacy classification requires a decoded property"))
  (member (ical-content-line-normalized-name
           (ical-property-value-line property))
          '("SUMMARY" "LOCATION" "DESCRIPTION") :test #'string=))

(defparameter *ical-availability-calculation-properties*
  '("UID" "DTSTAMP" "BUSYTYPE" "DTSTART" "DTEND" "DURATION" "PRIORITY"
    "SEQUENCE" "RECURRENCE-ID" "RRULE" "RDATE" "EXDATE"))

(defun plan-ical-availability-redaction
    (document availability
     &key (property-names '("SUMMARY" "LOCATION" "DESCRIPTION")))
  "Plan source-preserving deletion of non-calculation availability metadata."
  (unless (and (ical-document-p document)
               (ical-availability-p availability)
               (ical-availability-valid-p availability))
    (model-error :invalid-icalendar-availability-redaction-input
                 (list document availability)
                 "availability redaction requires a valid source-backed projection"))
  (let ((names
          (copy-proper-list
           property-names :invalid-icalendar-availability-redaction-properties
           "availability redaction properties")))
    (setf names
          (mapcar
           (lambda (name)
             (unless (and (stringp name) (ical-token-p name))
               (model-error :invalid-icalendar-availability-redaction-property
                            name
                            "redaction property names must be iCalendar tokens"))
             (let ((normalized (string-upcase name)))
               (when (member normalized
                             *ical-availability-calculation-properties*
                             :test #'string=)
                 (model-error :protected-icalendar-availability-property
                              normalized
                              "calculation and identity properties cannot be redacted"))
               normalized))
           names))
    (when (/= (length names)
              (length (remove-duplicates names :test #'string=)))
      (model-error :duplicate-icalendar-availability-redaction-property names
                   "redaction property names must be unique"))
    (let ((edits nil))
      (labels ((visit (component)
                 (dolist (line (ical-component-properties component))
                   (when (member (ical-content-line-normalized-name line)
                                 names :test #'string=)
                     (push (plan-ical-content-line-deletion document line)
                           edits)))
                 (dolist (child (ical-component-children component))
                   (when (string= "AVAILABLE"
                                  (ical-component-normalized-name child))
                     (visit child)))))
        (visit (ical-availability-component availability)))
      (nreverse edits))))
