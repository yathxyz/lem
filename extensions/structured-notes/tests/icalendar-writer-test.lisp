(in-package #:lem-structured-notes/tests)

(defun ical-output-property (name value &key value-type parameters)
  (make-ical-property-output
   :name name :value value :value-type value-type :parameters parameters))

(defun ical-output-component (name properties &optional children)
  (make-ical-component-output
   :name name :properties properties :children children))

(defun fixture-generated-calendar (&key event-properties event-children)
  (ical-output-component
   "VCALENDAR"
   (list (ical-output-property "PRODID" "-//Lem Test//EN")
         (ical-output-property "VERSION" "2.0"))
   (list (ical-output-component "VEVENT" event-properties event-children))))

(define-foundation-test canonical-icalendar-document-generation-is-verified
  (let* ((dtstamp
           (make-temporal-value
            :kind :utc :local-value "2026-07-24T09:00:00Z"))
         (start
           (make-temporal-value
            :kind :zoned :local-value "2026-07-24T10:00:00"
            :timezone-id "Europe/Dublin"))
         (end
           (make-temporal-value
            :kind :zoned :local-value "2026-07-24T11:00:00"
            :timezone-id "Europe/Dublin"))
         (alarm
           (ical-output-component
            "VALARM"
            (list
             (ical-output-property "ACTION" "DISPLAY")
             (ical-output-property
              "TRIGGER"
              (make-ical-duration-value :sign -1 :minutes 15))
             (ical-output-property "DESCRIPTION" "Upcoming event"))))
         (calendar
           (fixture-generated-calendar
            :event-properties
            (list
             (ical-output-property "UID" "generated-1")
             (ical-output-property "DTSTAMP" dtstamp)
             (ical-output-property "DTSTART" start)
             (ical-output-property "DTEND" end)
             (ical-output-property "SUMMARY" "Generated, safely")
             (ical-output-property
              "CATEGORIES" '("Deep, Work" "Calendar")))
            :event-children (list alarm)))
         (source (generate-icalendar-document calendar))
         (expected
           (ical-crlf-lines
            "BEGIN:VCALENDAR"
            "PRODID:-//Lem Test//EN"
            "VERSION:2.0"
            "BEGIN:VEVENT"
            "UID:generated-1"
            "DTSTAMP:20260724T090000Z"
            "DTSTART;TZID=Europe/Dublin:20260724T100000"
            "DTEND;TZID=Europe/Dublin:20260724T110000"
            "SUMMARY:Generated\\, safely"
            "CATEGORIES:Deep\\, Work,Calendar"
            "BEGIN:VALARM"
            "ACTION:DISPLAY"
            "TRIGGER:-PT15M"
            "DESCRIPTION:Upcoming event"
            "END:VALARM"
            "END:VEVENT"
            "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "verified.ics"))
         (envelope
           (project-ical-calendar-envelope
            (first (ical-document-components document))))
         (item
           (project-ical-component
            (first (ical-calendar-envelope-components envelope)))))
    (assert-equal expected source :test #'string=)
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal 1 (length (ical-calendar-item-alarms item)))
    (assert-true (ical-alarm-valid-p
                  (first (ical-calendar-item-alarms item))))))

(define-foundation-test canonical-rfc7953-availability-generation-is-verified
  (let* ((stamp
           (make-temporal-value
            :kind :utc :local-value "2026-07-25T10:00:00Z"))
         (start
           (make-temporal-value
            :kind :utc :local-value "2026-07-27T09:00:00Z"))
         (available
           (ical-output-component
            "AVAILABLE"
            (list (ical-output-property "UID" "slot")
                  (ical-output-property "DTSTAMP" stamp)
                  (ical-output-property "DTSTART" start)
                  (ical-output-property
                   "DURATION"
                   (make-ical-duration-value :sign 1 :hours 8)))))
         (availability
           (ical-output-component
            "VAVAILABILITY"
            (list (ical-output-property "UID" "availability")
                  (ical-output-property "DTSTAMP" stamp)
                  (ical-output-property "BUSYTYPE" "BUSY-UNAVAILABLE"))
            (list available)))
         (calendar
           (ical-output-component
            "VCALENDAR"
            (list (ical-output-property "PRODID" "-//Lem RFC7953 Test//EN")
                  (ical-output-property "VERSION" "2.0"))
            (list availability)))
         (source (generate-icalendar-document calendar))
         (document (parse-icalendar-cst source :source-id "availability.ics"))
         (projection
           (project-ical-availability-component
            (first
             (ical-component-children
              (first (ical-document-components document)))))))
    (assert-true (search "BEGIN:VAVAILABILITY" source))
    (assert-true (search "BEGIN:AVAILABLE" source))
    (assert-true (ical-availability-valid-p projection))))

(define-foundation-test invalid-canonical-icalendar-documents-fail-closed
  (let* ((utc
           (make-temporal-value
            :kind :utc :local-value "2026-07-24T09:00:00Z"))
         (floating
           (make-temporal-value
            :kind :floating :local-value "2026-07-24T09:00:00"))
         (start
           (make-temporal-value
            :kind :floating :local-value "2026-07-24T10:00:00"))
         (base-properties
           (list (ical-output-property "UID" "invalid-1")
                 (ical-output-property "DTSTAMP" utc)
                 (ical-output-property "DTSTART" start))))
    (dolist
        (thunk
         (list
          (lambda ()
            (make-ical-component-output :name "X-FUTURE"))
          (lambda ()
            (generate-icalendar-document
             (ical-output-component "VEVENT" base-properties)))
          (lambda ()
            (generate-icalendar-document
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "-//Test//EN")
                    (ical-output-property "VERSION" "2.0")))))
          (lambda ()
            (generate-icalendar-document
             (fixture-generated-calendar
              :event-properties
              (list (ical-output-property "UID" "invalid-2")
                    (ical-output-property "DTSTAMP" utc)))))
          (lambda ()
            (generate-icalendar-document
             (fixture-generated-calendar
              :event-properties
              (list (ical-output-property "UID" "invalid-3")
                    (ical-output-property "UID" "duplicate")
                    (ical-output-property "DTSTAMP" utc)
                    (ical-output-property "DTSTART" start)))))
          (lambda ()
            (generate-icalendar-document
             (fixture-generated-calendar
              :event-properties
              (list (ical-output-property "UID" "invalid-4")
                    (ical-output-property "DTSTAMP" floating)
                    (ical-output-property "DTSTART" start)))))
          (lambda ()
            (generate-icalendar-document
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "-//Test//EN")
                    (ical-output-property "VERSION" "2.0"))
              (list
               (ical-output-component
                "VALARM"
                (list (ical-output-property "ACTION" "DISPLAY")))))))
          (lambda ()
            (generate-icalendar-document
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "")
                    (ical-output-property "VERSION" "2.0"))
              (list (ical-output-component "VEVENT" base-properties)))))
          (lambda ()
            (generate-icalendar-document
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "-//Test//EN")
                    (ical-output-property "VERSION" "3.0"))
              (list (ical-output-component "VEVENT" base-properties)))))
          (lambda ()
            (generate-icalendar-document
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "-//Test//EN")
                    (ical-output-property "VERSION" "2.0")
                    (ical-output-property "CALSCALE" "NOT-SUPPORTED"))
              (list (ical-output-component "VEVENT" base-properties)))))
          (lambda ()
            (generate-icalendar-document
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "-//Test//EN")
                    (ical-output-property "VERSION" "2.0")
                    (ical-output-property "METHOD" "bad method"))
              (list (ical-output-component "VEVENT" base-properties)))))
          (lambda ()
            (generate-icalendar-document
             (fixture-generated-calendar
              :event-properties
              (append base-properties
                      (list (ical-output-property "X-UNKNOWN" "opaque"))))))
          (lambda ()
            (generate-icalendar-document
             (fixture-generated-calendar
              :event-properties
              (append
               base-properties
               (list
                (ical-output-property
                 "ATTENDEE" "mailto:jane@example.test"
                 :parameters '(("PARTSTAT" "COMPLETED"))))))))
          (lambda ()
            (generate-icalendar-document
             (fixture-generated-calendar
              :event-properties base-properties)
             :max-output-octets 1))))
      (assert-signals 'semantic-model-error thunk))))

(define-foundation-test canonical-vjournal-generation-reparses-and-projects
  (let* ((stamp
           (make-temporal-value
            :kind :utc :local-value "2026-07-28T09:00:00Z"))
         (date
           (make-temporal-value
            :kind :date :local-value "2026-07-28"))
         (journal
           (ical-output-component
            "VJOURNAL"
            (list (ical-output-property "UID" "generated-journal-1")
                  (ical-output-property "DTSTAMP" stamp)
                  (ical-output-property "DTSTART" date :value-type :date)
                  (ical-output-property "STATUS" "FINAL")
                  (ical-output-property "SUMMARY" "Daily record")
                  (ical-output-property
                   "ATTENDEE" "mailto:jane@example.test"
                   :parameters '(("PARTSTAT" "ACCEPTED")))
                  (ical-output-property
                   "REQUEST-STATUS"
                   (make-ical-request-status-value
                    :code "2.0" :description "Success"))
                  (ical-output-property "DESCRIPTION" "First note")
                  (ical-output-property "DESCRIPTION" "Second note"))))
         (calendar
           (ical-output-component
            "VCALENDAR"
            (list (ical-output-property "PRODID" "-//Lem Journal Test//EN")
                  (ical-output-property "VERSION" "2.0"))
            (list journal)))
         (source (generate-icalendar-document calendar))
         (document (parse-icalendar-cst source :source-id "journal.ics"))
         (item
           (project-ical-component
            (first
             (ical-component-children
              (first (ical-document-components document)))))))
    (assert-true (search "BEGIN:VJOURNAL" source))
    (assert-true (search "ATTENDEE;PARTSTAT=ACCEPTED" source))
    (assert-true (search "REQUEST-STATUS:2.0;Success" source))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal '("First note" "Second note")
                  (ical-calendar-item-descriptions item))))

(define-foundation-test canonical-vfreebusy-generation-is-sorted-and-verified
  (flet ((period (text)
           (let ((value (decode-ical-value text :period)))
             (assert-true (ical-value-valid-p value))
             (ical-value-decoded value))))
    (let* ((stamp
             (make-temporal-value
              :kind :utc :local-value "2026-07-28T09:00:00Z"))
           (start
             (make-temporal-value
              :kind :utc :local-value "2026-07-29T00:00:00Z"))
           (end
             (make-temporal-value
              :kind :utc :local-value "2026-07-30T00:00:00Z"))
           (freebusy
             (ical-output-component
              "VFREEBUSY"
              (list
               (ical-output-property
                "FREEBUSY"
                (list (period "20260729T120000Z/PT1H"))
                :parameters '(("FBTYPE" "BUSY-TENTATIVE")))
               (ical-output-property "UID" "generated-freebusy-1")
               (ical-output-property "DTSTAMP" stamp)
               (ical-output-property "DTSTART" start)
               (ical-output-property "DTEND" end)
               (ical-output-property "ATTENDEE" "mailto:guest@example.test")
               (ical-output-property
                "FREEBUSY"
                (list (period "20260729T100000Z/PT2H")
                      (period "20260729T090000Z/20260729T093000Z")))
               (ical-output-property
                "REQUEST-STATUS"
                (make-ical-request-status-value
                 :code "2.0" :description "Success")))))
           (calendar
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "-//Lem Freebusy Test//EN")
                    (ical-output-property "VERSION" "2.0"))
              (list freebusy)))
           (source (generate-icalendar-document calendar))
           (component
             (first
              (ical-component-children
               (first
                (ical-document-components
                 (parse-icalendar-cst source :source-id "freebusy.ics"))))))
           (projected (project-ical-freebusy-component component))
           (start-position (search "DTSTART:" source))
           (end-position (search "DTEND:" source))
           (first-period-position
             (search "FREEBUSY:20260729T090000Z/20260729T093000Z" source))
           (second-period-position
             (search "FREEBUSY:20260729T100000Z/PT2H" source))
           (third-period-position
             (search "FREEBUSY;FBTYPE=BUSY-TENTATIVE:20260729T120000Z/PT1H"
                     source)))
      (assert-true (ical-freebusy-valid-p projected))
      (assert-equal 3 (length (ical-freebusy-periods projected)))
      (assert-true (< start-position first-period-position))
      (assert-true (< end-position first-period-position))
      (assert-true (< first-period-position second-period-position))
      (assert-true (< second-period-position third-period-position)))))

(define-foundation-test canonical-vfreebusy-sorts-pinned-leap-periods
  (flet ((period (text)
           (let ((value (decode-ical-value text :period)))
             (assert-true (ical-value-valid-p value))
             (ical-value-decoded value))))
    (let* ((freebusy
             (ical-output-component
              "VFREEBUSY"
              (list
               (ical-output-property "UID" "generated-freebusy-leap")
               (ical-output-property
                "DTSTAMP"
                (make-temporal-value
                 :kind :utc :local-value "2016-12-01T00:00:00Z"))
               (ical-output-property
                "FREEBUSY"
                (list (period "20170101T000001Z/PT1S")
                      (period "20161231T235960Z/PT2S"))))))
           (calendar
             (ical-output-component
              "VCALENDAR"
              (list (ical-output-property "PRODID" "-//Leap Writer Test//EN")
                    (ical-output-property "VERSION" "2.0"))
              (list freebusy)))
           (source (generate-icalendar-document calendar)))
      (assert-true
       (< (search "FREEBUSY:20161231T235960Z/PT2S" source)
          (search "FREEBUSY:20170101T000001Z/PT1S" source))))))

(define-foundation-test canonical-rfc7986-calendar-properties-are-verified
  (flet ((decoded (text type)
           (let ((value (decode-ical-value text type)))
             (assert-true (ical-value-valid-p value))
             (ical-value-decoded value))))
    (let* ((modified
             (make-temporal-value
              :kind :utc :local-value "2026-07-28T12:00:00Z"))
           (stamp
             (make-temporal-value
              :kind :utc :local-value "2026-07-28T12:00:00Z"))
           (journal
             (ical-output-component
              "VJOURNAL"
              (list (ical-output-property "UID" "rfc7986-journal")
                    (ical-output-property "DTSTAMP" stamp))))
           (calendar
             (ical-output-component
              "VCALENDAR"
              (list
               (ical-output-property "PRODID" "-//RFC 7986 Writer Test//EN")
               (ical-output-property "VERSION" "2.0")
               (ical-output-property "NAME" "Team Calendar"
                                     :parameters '(("LANGUAGE" "en")))
               (ical-output-property "DESCRIPTION" "Shared planning"
                                     :parameters '(("LANGUAGE" "en")))
               (ical-output-property "UID" (generate-icalendar-uid))
               (ical-output-property "LAST-MODIFIED" modified)
               (ical-output-property
                "URL" (decoded "https://calendar.example.test/rendered" :uri))
               (ical-output-property "CATEGORIES" '("Work" "Planning"))
               (ical-output-property
                "REFRESH-INTERVAL" (decoded "P1D" :duration))
               (ical-output-property
                "SOURCE"
                (decoded "https://calendar.example.test/source.ics" :uri)))
              (list journal)))
           (source (generate-icalendar-document calendar))
           (document (parse-icalendar-cst source :source-id "rfc7986.ics"))
           (envelope
             (project-ical-calendar-envelope
              (first (ical-document-components document)))))
      (assert-true
       (search "REFRESH-INTERVAL;VALUE=DURATION:P1D" source))
      (assert-true
       (search "SOURCE;VALUE=URI:https://calendar.example.test/source.ics"
               source))
      (assert-true (ical-calendar-envelope-valid-p envelope))
      (assert-equal '("Team Calendar")
                    (ical-calendar-envelope-names envelope) :test #'equal))))

(define-foundation-test canonical-rfc7986-colors-are-verified
  (let* ((journal
           (ical-output-component
            "VJOURNAL"
            (list (ical-output-property "UID" "colored-journal")
                  (ical-output-property
                   "DTSTAMP"
                   (make-temporal-value
                    :kind :utc :local-value "2026-07-28T12:00:00Z"))
                  (ical-output-property "COLOR" "DarkSlateGrey"))))
         (calendar
           (ical-output-component
            "VCALENDAR"
            (list (ical-output-property "PRODID" "-//Color Writer Test//EN")
                  (ical-output-property "VERSION" "2.0")
                  (ical-output-property "COLOR" "turquoise"))
            (list journal)))
         (source (generate-icalendar-document calendar))
         (document (parse-icalendar-cst source :source-id "colors.ics"))
         (envelope
           (project-ical-calendar-envelope
            (first (ical-document-components document))))
         (item
           (project-ical-component
            (first (ical-calendar-envelope-components envelope)))))
    (assert-true (search "COLOR:turquoise" source))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-equal "turquoise" (ical-calendar-envelope-color envelope)
                  :test #'string=)
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal "DarkSlateGrey" (ical-calendar-item-color item)
                  :test #'string=)))

(define-foundation-test canonical-rfc7986-images-are-verified
  (let* ((uri-value (decode-ical-value "https://example.test/calendar.png" :uri))
         (image-uri (ical-value-decoded uri-value))
         (journal
           (ical-output-component
            "VJOURNAL"
            (list (ical-output-property "UID" "image-journal")
                  (ical-output-property
                   "DTSTAMP"
                   (make-temporal-value
                    :kind :utc :local-value "2026-07-28T12:00:00Z"))
                  (ical-output-property
                   "IMAGE" #(102 111 111) :value-type :binary
                   :parameters '(("FMTTYPE" "image/png"))))))
         (calendar
           (ical-output-component
            "VCALENDAR"
            (list (ical-output-property "PRODID" "-//Image Writer Test//EN")
                  (ical-output-property "VERSION" "2.0")
                  (ical-output-property
                   "IMAGE" image-uri
                   :parameters '(("DISPLAY" "BADGE")
                                 ("FMTTYPE" "image/png"))))
            (list journal)))
         (source (generate-icalendar-document calendar))
         (document (parse-icalendar-cst source :source-id "images.ics"))
         (envelope
           (project-ical-calendar-envelope
            (first (ical-document-components document))))
         (item
           (project-ical-component
            (first (ical-calendar-envelope-components envelope)))))
    (assert-true (ical-value-valid-p uri-value))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-equal 1 (length (ical-calendar-envelope-images envelope)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal :binary
                  (ical-image-kind (first (ical-calendar-item-images item))))
    (assert-true (search "IMAGE;VALUE=BINARY;ENCODING=BASE64" source))))

(define-foundation-test canonical-rfc7986-conferences-are-verified
  (let* ((uri-value (decode-ical-value "https://meet.example.test/room" :uri))
         (conference-uri (ical-value-decoded uri-value))
         (event
           (ical-output-component
            "VEVENT"
            (list (ical-output-property "UID" "conference-writer-event")
                  (ical-output-property
                   "DTSTAMP"
                   (make-temporal-value
                    :kind :utc :local-value "2026-07-28T12:00:00Z"))
                  (ical-output-property
                   "DTSTART"
                   (make-temporal-value
                    :kind :utc :local-value "2026-07-28T13:00:00Z"))
                  (ical-output-property
                   "CONFERENCE" conference-uri
                   :parameters '(("FEATURE" "AUDIO" "VIDEO")
                                 ("LABEL" "Team room")
                                 ("LANGUAGE" "en"))))))
         (calendar
           (ical-output-component
            "VCALENDAR"
            (list (ical-output-property "PRODID" "-//Conference Writer Test//EN")
                  (ical-output-property "VERSION" "2.0"))
            (list event)))
         (source (generate-icalendar-document calendar))
         (document (parse-icalendar-cst source :source-id "conference.ics"))
         (envelope
           (project-ical-calendar-envelope
            (first (ical-document-components document))))
         (item
           (project-ical-component
            (first (ical-calendar-envelope-components envelope)))))
    (assert-true (ical-value-valid-p uri-value))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal 1 (length (ical-calendar-item-conferences item)))
    (assert-true (search "CONFERENCE;VALUE=URI;FEATURE=AUDIO,VIDEO" source))
    (assert-true (assert-ical-conference-egress-safe item :attendees))))
