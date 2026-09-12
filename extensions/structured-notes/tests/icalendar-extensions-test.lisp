(in-package #:lem-structured-notes/tests)

(define-foundation-test rfc9073-publishing-extensions-project-semantically
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:published-event"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "ATTENDEE:mailto:performer@example.test"
            "STYLED-DESCRIPTION;VALUE=TEXT;FMTTYPE=text/html:<p>Concert</p>"
            "STYLED-DESCRIPTION;VALUE=URI;FMTTYPE=text/html;DERIVED=TRUE:https://example.test/concert.html"
            "STRUCTURED-DATA;VALUE=TEXT;FMTTYPE=application/ld+json;SCHEMA=\"https://schema.org/Event\":{}"
            "BEGIN:PARTICIPANT"
            "UID:performer-1"
            "PARTICIPANT-TYPE;ORDER=1:PERFORMER"
            "CALENDAR-ADDRESS:mailto:performer@example.test"
            "BEGIN:VLOCATION"
            "UID:performer-location"
            "LOCATION-TYPE:office,remote"
            "NAME:Performer location"
            "END:VLOCATION"
            "BEGIN:VRESOURCE"
            "UID:performer-resource"
            "RESOURCE-TYPE:PROJECTOR"
            "NAME:Projector"
            "END:VRESOURCE"
            "END:PARTICIPANT"
            "END:VEVENT"))
         (item (project-ical-component component))
         (extensions (ical-calendar-item-extensions item))
         (publishing
           (ical-rfc-extension-set-publishing-components extensions))
         (participant
           (find :participant publishing
                 :key #'ical-publishing-component-kind)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-true (ical-rfc-extension-set-valid-p extensions))
    (assert-equal 3 (length publishing))
    (assert-equal "performer-1" (ical-publishing-component-uid participant)
                  :test #'string=)
    (assert-equal "PERFORMER" (ical-publishing-component-type participant)
                  :test #'string=)
    (assert-equal 2 (length (ical-publishing-component-children participant)))
    (assert-true (ical-publishing-component-schedulable-p participant))
    (assert-equal 2
                  (length
                   (ical-rfc-extension-set-styled-descriptions extensions)))
    (assert-equal :text
                  (ical-structured-data-value-type
                   (first
                    (ical-rfc-extension-set-structured-data extensions))))))

(define-foundation-test rfc9073-invalid-extension-matrices-fail-closed
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:bad-published-event"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "PARTICIPANT-TYPE:SPEAKER"
            "STYLED-DESCRIPTION;VALUE=TEXT;DERIVED=TRUE:first"
            "STYLED-DESCRIPTION;VALUE=TEXT;DERIVED=TRUE:second"
            "STRUCTURED-DATA;VALUE=TEXT:{}"
            "BEGIN:PARTICIPANT"
            "UID:first"
            "UID:second"
            "END:PARTICIPANT"
            "END:VEVENT"))
         (item (project-ical-component component))
         (codes (mapcar #'diagnostic-code
                        (ical-calendar-item-diagnostics item))))
    (assert-false (ical-calendar-item-valid-p item))
    (dolist (code '(:misplaced-icalendar-extension-property
                    :invalid-styled-description-derived-set
                    :missing-structured-data-format-type
                    :missing-structured-data-schema
                    :missing-icalendar-extension-property
                    :duplicate-icalendar-extension-property))
      (assert-true (member code codes)))))

(define-foundation-test rfc9073-freebusy-publishing-extensions-are-valid
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VFREEBUSY"
            "UID:published-freebusy"
            "DTSTAMP:20260731T090000Z"
            "STYLED-DESCRIPTION;VALUE=TEXT:Availability details"
            "BEGIN:PARTICIPANT"
            "UID:freebusy-participant"
            "PARTICIPANT-TYPE:CONTACT"
            "END:PARTICIPANT"
            "END:VFREEBUSY"))
         (freebusy (project-ical-freebusy-component component))
         (extensions (ical-freebusy-extensions freebusy)))
    (assert-true (ical-freebusy-valid-p freebusy))
    (assert-true (ical-rfc-extension-set-valid-p extensions))
    (assert-equal 1
                  (length
                   (ical-rfc-extension-set-publishing-components extensions)))
    (assert-equal 1
                  (length
                   (ical-rfc-extension-set-styled-descriptions extensions)))))

(define-foundation-test rfc9074-alarm-identity-proximity-and-snooze-are-typed
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:alarm-event"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "BEGIN:VALARM"
            "UID:original-alarm"
            "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:19760401T005545Z"
            "DESCRIPTION:Leave the office"
            "ACKNOWLEDGED:20260731T094500Z"
            "PROXIMITY:DEPART"
            "BEGIN:VLOCATION"
            "UID:office-location"
            "NAME:Office"
            "URL:geo:53.3498,-6.2603;u=10"
            "END:VLOCATION"
            "END:VALARM"
            "BEGIN:VALARM"
            "UID:snooze-alarm"
            "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:20260731T095000Z"
            "DESCRIPTION:Snoozed reminder"
            "RELATED-TO;RELTYPE=SNOOZE:original-alarm"
            "END:VALARM"
            "END:VEVENT"))
         (item (project-ical-component component))
         (extensions (ical-calendar-item-extensions item))
         (alarms (ical-calendar-item-alarms item)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-true (ical-rfc-extension-set-valid-p extensions))
    (assert-equal 2 (length alarms))
    (assert-equal 1
                  (length
                   (ical-rfc-extension-set-publishing-components extensions)))
    (assert-true
     (every (lambda (alarm)
              (ical-rfc-extension-set-valid-p
               (ical-alarm-extensions alarm)))
            alarms))))

(define-foundation-test rfc9074-invalid-alarm-extension-state-fails-closed
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:bad-alarm-event"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "BEGIN:VALARM"
            "UID:duplicate-alarm"
            "ACTION:DISPLAY"
            "TRIGGER:-PT15M"
            "DESCRIPTION:First"
            "ACKNOWLEDGED:20260731T094500"
            "PROXIMITY:ARRIVE"
            "END:VALARM"
            "BEGIN:VALARM"
            "UID:duplicate-alarm"
            "ACTION:DISPLAY"
            "TRIGGER:-PT5M"
            "DESCRIPTION:Second"
            "RELATED-TO;RELTYPE=SNOOZE:missing-alarm"
            "BEGIN:VLOCATION"
            "UID:orphan-location"
            "END:VLOCATION"
            "END:VALARM"
            "END:VEVENT"))
         (item (project-ical-component component))
         (codes (mapcar #'diagnostic-code
                        (ical-calendar-item-diagnostics item))))
    (assert-false (ical-calendar-item-valid-p item))
    (dolist (code '(:non-utc-icalendar-alarm-acknowledged
                    :missing-icalendar-alarm-proximity-location
                    :orphan-icalendar-alarm-location
                    :duplicate-icalendar-alarm-uid
                    :dangling-icalendar-alarm-snooze))
      (assert-true (member code codes)))))

(define-foundation-test rfc9074-proximity-and-snooze-couplings-fail-closed
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:bad-coupling-event"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "BEGIN:VALARM"
            "UID:unacknowledged-original"
            "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:19760401T005545Z"
            "DESCRIPTION:Bad location"
            "PROXIMITY:ARRIVE"
            "BEGIN:VLOCATION"
            "UID:not-geo"
            "URL:https://example.test/not-a-geo-uri"
            "END:VLOCATION"
            "END:VALARM"
            "BEGIN:VALARM"
            "UID:coupled-snooze"
            "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:20260731T095000Z"
            "DESCRIPTION:Snooze"
            "RELATED-TO;RELTYPE=SNOOZE:unacknowledged-original"
            "END:VALARM"
            "END:VEVENT"))
         (item (project-ical-component component))
         (codes (mapcar #'diagnostic-code
                        (ical-calendar-item-diagnostics item))))
    (assert-false (ical-calendar-item-valid-p item))
    (assert-true
     (member :invalid-icalendar-alarm-proximity-location codes))
    (assert-true
     (member :unacknowledged-icalendar-alarm-snooze-target codes))))

(define-foundation-test rfc9253-links-concepts-and-relationships-are-typed
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:related-event"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "CONCEPT:https://example.test/concepts/concert"
            "REFID:tour-2026"
            "LINK;VALUE=URI;LINKREL=describedby;FMTTYPE=text/html;LABEL=Details;LANGUAGE=en:https://example.test/events/related"
            "RELATED-TO;VALUE=URI;RELTYPE=STARTTOSTART;GAP=PT1H:https://example.test/tasks/predecessor"
            "RELATED-TO;VALUE=TEXT;RELTYPE=REFID:tour-2026"
            "END:VEVENT"))
         (item (project-ical-component component))
         (extensions (ical-calendar-item-extensions item))
         (link (first (ical-rfc-extension-set-links extensions))))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-true (ical-rfc-extension-set-valid-p extensions))
    (assert-equal 1 (length (ical-rfc-extension-set-concepts extensions)))
    (assert-equal 1 (length (ical-rfc-extension-set-refids extensions)))
    (assert-equal 2 (length (ical-rfc-extension-set-relationships extensions)))
    (assert-equal "STARTTOSTART"
                  (ical-calendar-relationship-type
                   (first
                    (ical-rfc-extension-set-relationships extensions)))
                  :test #'string=)
    (assert-true
     (ical-duration-value-p
      (ical-calendar-relationship-gap
       (first (ical-rfc-extension-set-relationships extensions)))))
    (assert-equal :uri (ical-calendar-link-value-type link))
    (assert-equal '("describedby")
                  (ical-calendar-link-link-relations link))
    (assert-equal "Details" (ical-calendar-link-label link) :test #'string=)
    (assert-true (ical-calendar-link-retrieval-safe-p link))))

(define-foundation-test rfc9253-invalid-link-and-relationship-state-fails-closed
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:bad-related-event"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "REFID:"
            "LINK;VALUE=URI:https://example.test/no-relation"
            "LINK;VALUE=UID;LINKREL=item:"
            "LINK;VALUE=XML-REFERENCE;LINKREL=item:https://example.test/document.xml"
            "RELATED-TO;VALUE=URI;RELTYPE=PARENT:https://example.test/parent"
            "RELATED-TO;RELTYPE=CHILD;GAP=PT1H:child-uid"
            "RELATED-TO;VALUE=TEXT;RELTYPE=CONCEPT:not-a-uri"
            "END:VEVENT"))
         (item (project-ical-component component))
         (codes (mapcar #'diagnostic-code
                        (ical-calendar-item-diagnostics item))))
    (assert-false (ical-calendar-item-valid-p item))
    (dolist (code '(:invalid-icalendar-refid
                    :missing-icalendar-link-relation
                    :invalid-icalendar-link-uid
                    :invalid-icalendar-link-xml-reference
                    :invalid-icalendar-relationship-value-type
                    :invalid-icalendar-relationship-gap
                    :invalid-icalendar-concept-relationship-value))
      (assert-true (member code codes)))))

(define-foundation-test rfc-extension-property-writer-round-trips-types
  (dolist (specification
           '(("STYLED-DESCRIPTION" "<p>Text</p>" :text
              (("FMTTYPE" "text/html")))
             ("STRUCTURED-DATA" "{}" :text
              (("FMTTYPE" "application/ld+json")
               ("SCHEMA" "https://schema.org/Event")))
             ("LINK" "https://example.test/item" :uri
              (("LINKREL" "describedby")))
             ("LINK" "https://example.test/document.xml#xpointer(/event)"
              :xml-reference (("LINKREL" "item")))
             ("RELATED-TO" "parent-uid" :uid
              (("RELTYPE" "PARENT")))))
    (destructuring-bind (name value type parameters) specification
      (let* ((raw
               (generate-ical-property-line
                name value :value-type type :parameters parameters))
             (document (parse-icalendar-cst raw))
             (line (first (ical-document-content-lines document)))
             (property (decode-ical-content-line-value line)))
        (assert-true (ical-property-value-valid-p property))
        (assert-equal type (ical-property-value-value-type property))))))

(define-foundation-test rfc9073-derived-properties-are-read-only
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR"
            "PRODID:-//example.test//derived//EN"
            "VERSION:2.0"
            "BEGIN:VEVENT"
            "UID:derived-description"
            "DTSTAMP:20260731T090000Z"
            "DTSTART:20260731T100000Z"
            "DESCRIPTION;DERIVED=TRUE:Generated"
            "END:VEVENT"
            "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "derived.ics"))
         (calendar (first (ical-document-components document)))
         (event (first (ical-component-children calendar)))
         (change
           (make-ical-property-change
            :name "DESCRIPTION" :operation :set :value "Changed")))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (plan-ical-semantic-property-changes document event (list change))))))
