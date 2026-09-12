(in-package #:lem-structured-notes/tests)

(defun parse-first-ical-item-component (&rest lines)
  (let* ((source
           (apply #'ical-crlf-lines
                  (append '("BEGIN:VCALENDAR" "VERSION:2.0" "PRODID:-//Test//EN")
                          lines '("END:VCALENDAR"))))
         (document (parse-icalendar-cst source :source-id "item.ics"))
         (calendar (first (ical-document-components document))))
    (first (ical-component-children calendar))))

(defun project-ical-calendar-envelope-from-lines (&rest lines)
  (let* ((source
           (apply #'ical-crlf-lines
                  (append '("BEGIN:VCALENDAR") lines '("END:VCALENDAR"))))
         (document (parse-icalendar-cst source :source-id "calendar.ics")))
    (project-ical-calendar-envelope
     (first (ical-document-components document)))))

(define-foundation-test vcalendar-envelope-projects-required-metadata
  (let ((envelope
          (project-ical-calendar-envelope-from-lines
           "PRODID:-//Envelope Test//EN"
           "VERSION:2.0"
           "CALSCALE:GREGORIAN"
           "METHOD:PUBLISH"
           "X-CALENDAR-COLOR:blue"
           "BEGIN:VEVENT"
           "BEGIN:VALARM"
           "END:VALARM"
           "END:VEVENT")))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-equal "-//Envelope Test//EN"
                  (ical-calendar-envelope-prodid envelope) :test #'string=)
    (assert-equal "2.0" (ical-calendar-envelope-version envelope)
                  :test #'string=)
    (assert-equal "GREGORIAN" (ical-calendar-envelope-calscale envelope)
                  :test #'string=)
    (assert-equal "PUBLISH" (ical-calendar-envelope-method envelope)
                  :test #'string=)
    (assert-equal 1 (length (ical-calendar-envelope-components envelope)))))

(define-foundation-test rfc7986-calendar-properties-are-typed-and-projected
  (let ((envelope
          (project-ical-calendar-envelope-from-lines
           "PRODID:-//RFC 7986 Test//EN"
           "VERSION:2.0"
           "NAME;LANGUAGE=en:Team Calendar"
           "NAME;LANGUAGE=fr:Calendrier de l'equipe"
           "DESCRIPTION;LANGUAGE=en:Shared planning"
           "UID:00010203-0405-4607-8809-0a0b0c0d0e0f"
           "LAST-MODIFIED:20260728T120000Z"
           "URL:https://calendar.example.test/rendered"
           "CATEGORIES:Work,Shared"
           "CATEGORIES:Planning"
           "REFRESH-INTERVAL;VALUE=DURATION:P1D"
           "SOURCE;VALUE=URI:https://calendar.example.test/source.ics"
           "BEGIN:VEVENT" "END:VEVENT")))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-equal '("Team Calendar" "Calendrier de l'equipe")
                  (ical-calendar-envelope-names envelope) :test #'equal)
    (assert-equal '("Shared planning")
                  (ical-calendar-envelope-descriptions envelope) :test #'equal)
    (assert-equal "00010203-0405-4607-8809-0a0b0c0d0e0f"
                  (ical-calendar-envelope-uid envelope) :test #'string=)
    (assert-equal :utc
                  (temporal-value-kind
                   (ical-calendar-envelope-last-modified envelope)))
    (assert-equal '("Work" "Shared" "Planning")
                  (ical-calendar-envelope-categories envelope) :test #'equal)
    (assert-true
     (ical-duration-value-p
      (ical-calendar-envelope-refresh-interval envelope)))
    (assert-equal "https://calendar.example.test/source.ics"
                  (ical-uri-value-original-lexeme
                   (ical-calendar-envelope-source envelope))
                  :test #'string=)))

(define-foundation-test invalid-rfc7986-calendar-properties-fail-closed
  (dolist
      (extension-lines
       '(("NAME:First" "NAME:Second")
         ("DESCRIPTION;LANGUAGE=en:First"
          "DESCRIPTION;LANGUAGE=EN:Second")
         ("UID:first" "UID:second")
         ("UID:")
         ("LAST-MODIFIED:20260728T120000")
         ("REFRESH-INTERVAL:P1D")
         ("REFRESH-INTERVAL;VALUE=DURATION:P0D")
         ("REFRESH-INTERVAL;VALUE=DURATION:-P1D")
         ("SOURCE:https://calendar.example.test/source.ics")
         ("SOURCE;VALUE=URI:https://calendar.example.test/one.ics"
          "SOURCE;VALUE=URI:https://calendar.example.test/two.ics")))
    (let ((envelope
            (apply #'project-ical-calendar-envelope-from-lines
                   (append
                    '("PRODID:-//Invalid RFC 7986 Test//EN" "VERSION:2.0")
                    extension-lines
                    '("BEGIN:VEVENT" "END:VEVENT")))))
      (assert-false (ical-calendar-envelope-valid-p envelope))
      (assert-true (ical-calendar-envelope-diagnostics envelope)))))

(define-foundation-test rfc7986-colors-project-in-every-allowed-context
  (let* ((envelope
           (project-ical-calendar-envelope-from-lines
            "PRODID:-//RFC 7986 Color Test//EN" "VERSION:2.0"
            "COLOR:DarkSlateGrey"
            "BEGIN:VEVENT" "UID:colored-event" "DTSTAMP:20260728T120000Z"
            "DTSTART:20260728T130000Z" "COLOR:turquoise" "END:VEVENT"))
         (event
           (project-ical-component
            (first (ical-calendar-envelope-components envelope)))))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-equal "DarkSlateGrey" (ical-calendar-envelope-color envelope)
                  :test #'string=)
    (assert-true (ical-calendar-item-valid-p event))
    (assert-equal "turquoise" (ical-calendar-item-color event) :test #'string=))
  (dolist (specification
           '(("BEGIN:VTODO" "UID:colored-todo" "DTSTAMP:20260728T120000Z"
              "COLOR:AliceBlue" "END:VTODO")
             ("BEGIN:VJOURNAL" "UID:colored-journal"
              "DTSTAMP:20260728T120000Z" "COLOR:yellowgreen"
              "END:VJOURNAL")))
    (let ((item
            (project-ical-component
             (apply #'parse-first-ical-item-component specification))))
      (assert-true (ical-calendar-item-valid-p item))
      (assert-true (ical-calendar-item-color item)))))

(define-foundation-test invalid-or-misplaced-rfc7986-colors-fail-closed
  (dolist (color '("rebeccapurple" "rgb(1\\,2\\,3)" "transparent" ""))
    (let ((envelope
            (project-ical-calendar-envelope-from-lines
             "PRODID:-//Invalid Color Test//EN" "VERSION:2.0"
             (format nil "COLOR:~a" color) "BEGIN:VEVENT" "END:VEVENT")))
      (assert-false (ical-calendar-envelope-valid-p envelope))))
  (let ((duplicate
          (project-ical-calendar-envelope-from-lines
           "PRODID:-//Duplicate Color Test//EN" "VERSION:2.0"
           "COLOR:red" "COLOR:blue" "BEGIN:VEVENT" "END:VEVENT"))
        (misplaced-name
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:misplaced-name" "DTSTAMP:20260728T120000Z"
            "DTSTART:20260728T130000Z" "NAME:Not an event name" "END:VEVENT")))
        (misplaced-color
          (project-ical-freebusy-component
           (parse-first-ical-item-component
            "BEGIN:VFREEBUSY" "UID:misplaced-color"
            "DTSTAMP:20260728T120000Z" "COLOR:red" "END:VFREEBUSY"))))
    (assert-false (ical-calendar-envelope-valid-p duplicate))
    (assert-false (ical-calendar-item-valid-p misplaced-name))
    (assert-false (ical-freebusy-valid-p misplaced-color))))

(define-foundation-test rfc7986-images-project-as-ordered-inert-data
  (let* ((envelope
           (project-ical-calendar-envelope-from-lines
            "PRODID:-//RFC 7986 Image Test//EN" "VERSION:2.0"
            "IMAGE;VALUE=URI;DISPLAY=BADGE;FMTTYPE=image/png:https://example.test/badge.png"
            "IMAGE;VALUE=URI;DISPLAY=X-FUTURE:http://tracker.example.test/image.png"
            "BEGIN:VEVENT" "UID:image-event" "DTSTAMP:20260728T120000Z"
            "DTSTART:20260728T130000Z"
            "IMAGE;VALUE=BINARY;ENCODING=BASE64;FMTTYPE=image/png;ALTREP=\"https://example.test/page\":Zm9v"
            "END:VEVENT"))
         (calendar-images (ical-calendar-envelope-images envelope))
         (item
           (project-ical-component
            (first (ical-calendar-envelope-components envelope))))
         (item-image (first (ical-calendar-item-images item))))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-equal 2 (length calendar-images))
    (assert-equal :uri (ical-image-kind (first calendar-images)))
    (assert-true (ical-image-retrieval-safe-p (first calendar-images)))
    (assert-false (ical-image-retrieval-safe-p (second calendar-images)))
    (assert-equal :unsupported
                  (ical-image-display-resolution (second calendar-images)))
    (assert-false (ical-image-displays (second calendar-images)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal :binary (ical-image-kind item-image))
    (assert-equal #(102 111 111) (ical-image-binary item-image) :test #'equalp)
    (assert-equal "image/png" (ical-image-media-type item-image) :test #'string=)
    (assert-true (ical-image-alternate-uri item-image))))

(define-foundation-test misplaced-rfc7986-images-fail-closed
  (let ((freebusy
          (project-ical-freebusy-component
           (parse-first-ical-item-component
            "BEGIN:VFREEBUSY" "UID:image-freebusy"
            "DTSTAMP:20260728T120000Z"
            "IMAGE;VALUE=URI:https://example.test/not-allowed.png"
            "END:VFREEBUSY"))))
    (assert-false (ical-freebusy-valid-p freebusy))
    (assert-true
     (member :misplaced-rfc7986-property
             (mapcar #'diagnostic-code (ical-freebusy-diagnostics freebusy))))))

(define-foundation-test rfc7986-conferences-project-as-inert-audience-bound-data
  (let* ((item
           (project-ical-component
            (parse-first-ical-item-component
             "BEGIN:VEVENT" "UID:conference-event"
             "DTSTAMP:20260728T120000Z" "DTSTART:20260728T130000Z"
             "CONFERENCE;VALUE=URI;FEATURE=AUDIO,VIDEO;LABEL=Attendee room;LANGUAGE=en:https://meet.example.test/attendee"
             "CONFERENCE;VALUE=URI;FEATURE=PHONE,MODERATOR;LABEL=Owner code:tel:+1-555-0100,,,1234"
             "END:VEVENT")))
         (conferences (ical-calendar-item-conferences item))
         (attendee (first conferences))
         (moderator (second conferences)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal 2 (length conferences))
    (assert-equal '("AUDIO" "VIDEO")
                  (ical-conference-features attendee) :test #'equal)
    (assert-equal "Attendee room" (ical-conference-label attendee)
                  :test #'string=)
    (assert-equal "en" (ical-conference-language attendee) :test #'string=)
    (assert-true (ical-conference-retrieval-safe-p attendee))
    (assert-false (ical-conference-moderator-p attendee))
    (assert-true (ical-conference-moderator-p moderator))
    (assert-false (ical-conference-retrieval-safe-p moderator))
    (assert-true (assert-ical-conference-egress-safe item :owner))
    (assert-signals
     'semantic-model-error
     (lambda () (assert-ical-conference-egress-safe item :public)))
    (assert-signals
     'semantic-model-error
     (lambda () (assert-ical-conference-egress-safe item :attendees)))))

(define-foundation-test rfc7986-conference-placement-fails-closed
  (let ((todo
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VTODO" "UID:conference-todo" "DTSTAMP:20260728T120000Z"
            "CONFERENCE;VALUE=URI:https://meet.example.test/task"
            "END:VTODO")))
        (journal
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VJOURNAL" "UID:conference-journal"
            "DTSTAMP:20260728T120000Z"
            "CONFERENCE;VALUE=URI:https://meet.example.test/not-allowed"
            "END:VJOURNAL"))))
    (assert-true (ical-calendar-item-valid-p todo))
    (assert-equal 1 (length (ical-calendar-item-conferences todo)))
    (assert-false (ical-calendar-item-valid-p journal))
    (assert-signals
     'semantic-model-error
     (lambda () (assert-ical-conference-egress-safe journal :owner)))))

(define-foundation-test rfc8607-invalid-attachment-quarantines-calendar-item
  (let ((item
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:managed-attachment"
            "DTSTAMP:20260725T120000Z" "DTSTART:20260726T120000Z"
            "ATTACH;MANAGED-ID=server-1;SIZE=0:https://example.test/a"
            "END:VEVENT"))))
    (assert-false (ical-calendar-item-valid-p item))
    (assert-true
     (find :invalid-icalendar-attachment-size
           (mapcar #'diagnostic-code
                   (ical-calendar-item-diagnostics item))))))

(define-foundation-test vcalendar-stream-retains-multiple-calendar-objects
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "PRODID:-//One//EN" "VERSION:2.0"
            "BEGIN:VEVENT" "END:VEVENT" "END:VCALENDAR"
            "BEGIN:VCALENDAR" "PRODID:-//Two//EN" "VERSION:2.0"
            "BEGIN:VTODO" "END:VTODO" "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "stream.ics"))
         (envelopes
           (mapcar #'project-ical-calendar-envelope
                   (ical-document-components document))))
    (assert-equal 2 (length envelopes))
    (assert-true (every #'ical-calendar-envelope-valid-p envelopes))
    (assert-equal '("-//One//EN" "-//Two//EN")
                  (mapcar #'ical-calendar-envelope-prodid envelopes)
                  :test #'equal)))

(define-foundation-test invalid-vcalendar-envelope-cardinality-fails-closed
  (dolist
      (lines
       '(("VERSION:2.0" "BEGIN:VEVENT" "END:VEVENT")
         ("PRODID:-//Missing Version//EN" "BEGIN:VEVENT" "END:VEVENT")
         ("PRODID:-//Duplicate//EN" "VERSION:2.0" "VERSION:2.0"
          "BEGIN:VEVENT" "END:VEVENT")
         ("PRODID:-//Duplicate//EN" "PRODID:-//Duplicate Two//EN"
          "VERSION:2.0" "BEGIN:VEVENT" "END:VEVENT")
         ("PRODID:-//Duplicate Optional//EN" "VERSION:2.0"
          "CALSCALE:GREGORIAN" "CALSCALE:GREGORIAN"
          "METHOD:PUBLISH" "METHOD:PUBLISH"
          "BEGIN:VEVENT" "END:VEVENT")
         ("PRODID:-//No Component//EN" "VERSION:2.0")
         ("PRODID:-//Misplaced//EN" "VERSION:2.0" "SUMMARY:Not global"
          "BEGIN:VEVENT" "END:VEVENT")))
    (let ((envelope
            (apply #'project-ical-calendar-envelope-from-lines lines)))
      (assert-false (ical-calendar-envelope-valid-p envelope))
      (assert-true (ical-calendar-envelope-diagnostics envelope)))))

(define-foundation-test known-icalendar-component-placement-fails-closed
  (dolist
      (lines
       '(("PRODID:-//Alarm Root//EN" "VERSION:2.0"
          "BEGIN:VALARM" "END:VALARM")
         ("PRODID:-//Observance Root//EN" "VERSION:2.0"
          "BEGIN:STANDARD" "END:STANDARD")
         ("PRODID:-//Nested Event//EN" "VERSION:2.0"
          "BEGIN:VEVENT" "BEGIN:VEVENT" "END:VEVENT" "END:VEVENT")
         ("PRODID:-//Journal Alarm//EN" "VERSION:2.0"
          "BEGIN:VJOURNAL" "BEGIN:VALARM" "END:VALARM" "END:VJOURNAL")))
    (let ((envelope
            (apply #'project-ical-calendar-envelope-from-lines lines)))
      (assert-false (ical-calendar-envelope-valid-p envelope))
      (assert-true
       (member :misplaced-icalendar-component
               (mapcar #'diagnostic-code
                       (ical-calendar-envelope-diagnostics envelope)))))))

(define-foundation-test unknown-icalendar-components-remain-preserved
  (let ((envelope
          (project-ical-calendar-envelope-from-lines
           "PRODID:-//Extensions//EN" "VERSION:2.0"
           "BEGIN:VEVENT"
           "BEGIN:X-NESTED" "X-DATA:opaque" "END:X-NESTED"
           "END:VEVENT"
           "BEGIN:X-CALENDAR-COMPONENT" "X-DATA:opaque"
           "END:X-CALENDAR-COMPONENT")))
    (assert-true (ical-calendar-envelope-valid-p envelope))
    (assert-equal 2 (length (ical-calendar-envelope-components envelope)))))

(define-foundation-test vevent-projects-core-calendar-semantics
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:event-1"
            "DTSTAMP:20260724T090000Z"
            "SEQUENCE:3"
            "DTSTART:20260724T100000Z"
            "DTEND:20260724T110000Z"
            "SUMMARY:Review"
            "CATEGORIES:Work,Deep\\, Focus"
            "X-FUTURE:opaque"
            "BEGIN:VALARM"
            "ACTION:DISPLAY"
            "TRIGGER:-PT15M"
            "DESCRIPTION:Review reminder"
            "END:VALARM"
            "END:VEVENT"))
         (item (project-ical-component component)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal :event (ical-calendar-item-kind item))
    (assert-equal "event-1" (ical-calendar-item-uid item) :test #'string=)
    (assert-equal :utc
                  (temporal-value-kind (ical-calendar-item-dtstamp item)))
    (assert-equal 3 (ical-calendar-item-sequence item))
    (assert-equal "Review" (ical-calendar-item-summary item) :test #'string=)
    (assert-equal '("Work" "Deep, Focus")
                  (ical-calendar-item-categories item))
    (assert-equal 1 (length (ical-calendar-item-alarms item)))
    (assert-true (ical-alarm-p (first (ical-calendar-item-alarms item))))
    (assert-true (ical-alarm-valid-p
                  (first (ical-calendar-item-alarms item))))
    (assert-equal :utc (temporal-value-kind (ical-calendar-item-start item)))))

(define-foundation-test valarm-actions-project-as-inert-data
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:alarm-actions"
            "DTSTAMP:20260724T090000Z"
            "DTSTART:20260724T100000Z"
            "DTEND:20260724T110000Z"
            "BEGIN:VALARM"
            "ACTION:AUDIO"
            "TRIGGER:-PT15M"
            "ATTACH;FMTTYPE=audio/basic:https://example.test/bell.au"
            "END:VALARM"
            "BEGIN:VALARM"
            "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:20260724T094500Z"
            "DESCRIPTION:Meeting soon"
            "DURATION:PT5M"
            "REPEAT:2"
            "END:VALARM"
            "BEGIN:VALARM"
            "ACTION:EMAIL"
            "TRIGGER;RELATED=END:-PT5M"
            "DESCRIPTION:Meeting finished"
            "SUMMARY:Follow up"
            "ATTENDEE:mailto:first@example.test"
            "ATTENDEE:mailto:second@example.test"
            "ATTACH:https://example.test/notes"
            "END:VALARM"
            "END:VEVENT"))
         (item (project-ical-component component))
         (alarms (ical-calendar-item-alarms item))
         (audio (first alarms))
         (display (second alarms))
         (email (third alarms)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal 3 (length alarms))
    (assert-true (every #'ical-alarm-valid-p alarms))
    (assert-true (every #'ical-alarm-supported-p alarms))
    (assert-equal "AUDIO" (ical-alarm-action audio) :test #'string=)
    (assert-equal 1 (length (ical-alarm-attachments audio)))
    (assert-equal :utc
                  (temporal-value-kind (ical-alarm-trigger display)))
    (assert-equal 2 (ical-alarm-repeat display))
    (assert-equal :end (ical-alarm-trigger-related email))
    (assert-equal 2 (length (ical-alarm-attendees email)))))

(define-foundation-test invalid-valarm-matrices-fail-closed
  (dolist
      (alarm-lines
       '(("TRIGGER:-PT15M")
         ("ACTION:DISPLAY")
         ("ACTION:DISPLAY" "TRIGGER:-PT15M")
         ("ACTION:AUDIO" "TRIGGER:-PT15M" "DESCRIPTION:Not audio")
         ("ACTION:EMAIL" "TRIGGER:-PT15M" "DESCRIPTION:Body"
          "SUMMARY:Subject")
         ("ACTION:DISPLAY" "TRIGGER:-PT15M" "DESCRIPTION:Reminder"
          "ATTACH:https://example.test/not-display")
         ("ACTION:AUDIO" "TRIGGER:-PT15M"
          "ATTACH:https://example.test/one"
          "ATTACH:https://example.test/two")
         ("ACTION:DISPLAY" "TRIGGER:-PT15M" "DESCRIPTION:Reminder"
          "DURATION:PT5M")
         ("ACTION:DISPLAY" "TRIGGER:-PT15M" "DESCRIPTION:Reminder"
          "REPEAT:2")
         ("ACTION:DISPLAY" "TRIGGER:-PT15M" "DESCRIPTION:Reminder"
          "DURATION:PT5M" "REPEAT:-1")
         ("ACTION:DISPLAY" "TRIGGER:-PT15M" "DESCRIPTION:Reminder"
          "DURATION:-PT5M" "REPEAT:2")
         ("ACTION:DISPLAY" "TRIGGER;VALUE=DATE-TIME:20260724T094500"
          "DESCRIPTION:Reminder")
         ("ACTION:DISPLAY"
          "TRIGGER;VALUE=DATE-TIME;RELATED=END:20260724T094500Z"
          "DESCRIPTION:Reminder")
         ("ACTION:DISPLAY" "TRIGGER;RELATED=SIDEWAYS:-PT15M"
          "DESCRIPTION:Reminder")
         ("ACTION:DISPLAY" "ACTION:DISPLAY" "TRIGGER:-PT15M"
          "DESCRIPTION:Reminder")))
    (let* ((component
             (apply #'parse-first-ical-item-component
                    (append
                     '("BEGIN:VEVENT" "UID:invalid-alarm"
                       "DTSTAMP:20260724T090000Z"
                       "DTSTART:20260724T100000Z"
                       "DTEND:20260724T110000Z" "BEGIN:VALARM")
                     alarm-lines
                     '("END:VALARM" "END:VEVENT"))))
           (item (project-ical-component component))
           (alarm (first (ical-calendar-item-alarms item))))
      (assert-false (ical-calendar-item-valid-p item))
      (assert-false (ical-alarm-valid-p alarm))
      (assert-true (ical-alarm-diagnostics alarm)))))

(define-foundation-test valarm-relative-trigger-requires-parent-boundary
  (let* ((relative-component
           (parse-first-ical-item-component
            "BEGIN:VTODO" "UID:no-start" "DTSTAMP:20260724T090000Z"
            "BEGIN:VALARM" "ACTION:DISPLAY" "TRIGGER:-PT15M"
            "DESCRIPTION:Needs a start" "END:VALARM" "END:VTODO"))
         (absolute-component
           (parse-first-ical-item-component
            "BEGIN:VTODO" "UID:absolute" "DTSTAMP:20260724T090000Z"
            "BEGIN:VALARM" "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:20260724T094500Z"
            "DESCRIPTION:No parent boundary needed"
            "END:VALARM" "END:VTODO"))
         (relative (project-ical-component relative-component))
         (absolute (project-ical-component absolute-component)))
    (assert-false (ical-calendar-item-valid-p relative))
    (assert-true
     (member :missing-icalendar-alarm-trigger-anchor
             (mapcar #'diagnostic-code
                     (ical-alarm-diagnostics
                      (first (ical-calendar-item-alarms relative))))))
    (assert-true (ical-calendar-item-valid-p absolute))))

(define-foundation-test unknown-valarm-actions-remain-inert-and-unsupported
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:unknown-action"
            "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
            "BEGIN:VALARM" "ACTION:X-BLINK" "TRIGGER:-PT15M"
            "X-PAYLOAD:opaque" "END:VALARM" "END:VEVENT"))
         (item (project-ical-component component))
         (alarm (first (ical-calendar-item-alarms item))))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-true (ical-alarm-valid-p alarm))
    (assert-false (ical-alarm-supported-p alarm))
    (assert-equal "X-BLINK" (ical-alarm-action alarm) :test #'string=)))

(define-foundation-test rfc9074-valarm-extensions-remain-preserved
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:extended-alarm"
            "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
            "BEGIN:VALARM"
            "UID:alarm-uid"
            "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:20260724T094500Z"
            "DESCRIPTION:Extended reminder"
            "ACKNOWLEDGED:20260724T090000Z"
            "RELATED-TO;RELTYPE=SNOOZE:original-alarm"
            "PROXIMITY:ARRIVE"
            "BEGIN:VLOCATION" "UID:location-1"
            "URL:geo:53.3498,-6.2603;u=10" "END:VLOCATION"
            "END:VALARM"
            "BEGIN:VALARM"
            "UID:original-alarm"
            "ACTION:DISPLAY"
            "TRIGGER;VALUE=DATE-TIME:20260724T093000Z"
            "DESCRIPTION:Original reminder"
            "ACKNOWLEDGED:20260724T092900Z"
            "END:VALARM"
            "END:VEVENT"))
         (item (project-ical-component component))
         (alarm (first (ical-calendar-item-alarms item)))
         (property-names
           (mapcar (lambda (property)
                     (ical-content-line-normalized-name
                      (ical-property-value-line property)))
                   (ical-alarm-properties alarm))))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-true (ical-alarm-valid-p alarm))
    (assert-true (member "UID" property-names :test #'string=))
    (assert-true (member "ACKNOWLEDGED" property-names :test #'string=))
    (assert-true (member "PROXIMITY" property-names :test #'string=))
    (assert-equal 1
                  (length (ical-component-children
                           (ical-alarm-component alarm))))))

(define-foundation-test vtodo-projects-task-specific-calendar-semantics
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VTODO"
            "UID:todo-1"
            "DTSTAMP:20260724T090000Z"
            "DTSTART;VALUE=DATE:20260724"
            "DUE;VALUE=DATE:20260725"
            "SUMMARY:Submit report"
            "STATUS:IN-PROCESS"
            "PERCENT-COMPLETE:40"
            "PRIORITY:3"
            "END:VTODO"))
         (item (project-ical-component component)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal :todo (ical-calendar-item-kind item))
    (assert-equal "todo-1" (ical-calendar-item-uid item) :test #'string=)
    (assert-equal 40 (ical-calendar-item-percent-complete item))
    (assert-equal 3 (ical-calendar-item-priority item))
    (assert-equal :date (temporal-value-kind (ical-calendar-item-due item)))))

(define-foundation-test invalid-icalendar-item-cross-constraints-fail-closed
  (dolist
      (lines
       '(("BEGIN:VEVENT" "UID:event-1" "DTSTAMP:20260724T090000Z"
          "DTSTART:20260724T100000Z" "DTEND:20260724T110000Z"
          "DURATION:PT1H" "END:VEVENT")
         ("BEGIN:VEVENT" "UID:event-2" "DTSTAMP:20260724T090000Z"
          "DTSTART;VALUE=DATE:20260724" "DTEND:20260724T110000Z"
          "END:VEVENT")
         ("BEGIN:VTODO" "UID:todo-1" "DTSTAMP:20260724T090000Z"
          "DTSTART:20260724T100000Z" "DUE:20260724T110000Z"
          "DURATION:PT1H" "END:VTODO")
         ("BEGIN:VTODO" "UID:todo-2" "DTSTAMP:20260724T090000Z"
          "DURATION:PT1H" "END:VTODO")
         ("BEGIN:VEVENT" "UID:duplicate" "UID:duplicate-2"
          "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
          "END:VEVENT")
         ("BEGIN:VEVENT" "UID:bad-transparency"
          "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
          "TRANSP:INVISIBLE" "END:VEVENT")
         ("BEGIN:VTODO" "UID:todo-transparency"
          "DTSTAMP:20260724T090000Z" "TRANSP:OPAQUE" "END:VTODO")))
    (let ((item (project-ical-component
                 (apply #'parse-first-ical-item-component lines))))
      (assert-false (ical-calendar-item-valid-p item))
      (assert-true (ical-calendar-item-diagnostics item)))))

(define-foundation-test projected-participation-status-uses-component-domain
  (let ((event
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:partstat-event"
            "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
            "ATTENDEE;PARTSTAT=COMPLETED:mailto:jane@example.test"
            "END:VEVENT")))
        (todo
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VTODO" "UID:partstat-todo"
            "DTSTAMP:20260724T090000Z"
            "ATTENDEE;PARTSTAT=COMPLETED:mailto:jane@example.test"
            "END:VTODO"))))
    (assert-false (ical-calendar-item-valid-p event))
    (assert-true
     (find :invalid-icalendar-partstat-component
           (ical-calendar-item-diagnostics event) :key #'diagnostic-code))
    (assert-true (ical-calendar-item-valid-p todo))))

(define-foundation-test revision-ordering-properties-fail-closed
  (dolist
      (lines
       '(("BEGIN:VEVENT" "UID:floating-stamp"
          "DTSTAMP:20260724T090000" "DTSTART:20260724T100000Z"
          "END:VEVENT")
         ("BEGIN:VEVENT" "UID:negative-sequence"
          "DTSTAMP:20260724T090000Z" "SEQUENCE:-1"
          "DTSTART:20260724T100000Z" "END:VEVENT")))
    (let ((item
            (project-ical-component
             (apply #'parse-first-ical-item-component lines))))
      (assert-false (ical-calendar-item-valid-p item))
      (assert-true (ical-calendar-item-diagnostics item)))))

(define-foundation-test recurrence-id-range-is-typed-and-validated
  (let ((ranged
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:range-test"
            "DTSTAMP:20260724T000000Z" "DTSTART:20260725T100000Z"
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260725T090000Z"
            "END:VEVENT")))
        (single
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:single-test"
            "DTSTAMP:20260724T000000Z" "DTSTART:20260725T100000Z"
            "RECURRENCE-ID:20260725T090000Z" "END:VEVENT"))))
    (assert-true (ical-calendar-item-valid-p ranged))
    (assert-equal :this-and-future
                  (ical-calendar-item-recurrence-range ranged))
    (assert-equal :this (ical-calendar-item-recurrence-range single)))
  (dolist (line
           '("RECURRENCE-ID;RANGE=THISANDPRIOR:20260725T090000Z"
             "RECURRENCE-ID;RANGE=THISANDFUTURE;RANGE=THISANDFUTURE:20260725T090000Z"))
    (let ((item
            (project-ical-component
             (parse-first-ical-item-component
              "BEGIN:VEVENT" "UID:bad-range"
              "DTSTAMP:20260724T000000Z" "DTSTART:20260725T100000Z"
              line "END:VEVENT"))))
      (assert-false (ical-calendar-item-valid-p item))
      (assert-true (ical-calendar-item-diagnostics item)))))

(define-foundation-test vevent-method-context-controls-dtstart-requirement
  (let ((component
          (parse-first-ical-item-component
           "BEGIN:VEVENT" "UID:method-event" "DTSTAMP:20260724T090000Z"
           "END:VEVENT")))
    (assert-false
     (ical-calendar-item-valid-p (project-ical-component component)))
    (assert-true
     (ical-calendar-item-valid-p
     (project-ical-component component :method-present-p t)))))

(define-foundation-test recurrence-until-matches-component-start-kind
  (let* ((valid-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:recur-1" "DTSTAMP:20260724T090000Z"
            "DTSTART;TZID=Europe/Dublin:20260724T100000"
            "RRULE:FREQ=DAILY;UNTIL=20260731T090000Z" "END:VEVENT"))
         (valid (project-ical-component valid-component))
         (rule (ical-calendar-item-recurrence-rule valid)))
    (assert-true (ical-calendar-item-valid-p valid))
    (assert-equal :daily (ical-recur-value-frequency rule))
    (assert-equal :utc
                  (temporal-value-kind (ical-recur-value-until rule))))
  (dolist
      (lines
       '(("BEGIN:VEVENT" "UID:recur-2" "DTSTAMP:20260724T090000Z"
          "DTSTART;VALUE=DATE:20260724"
          "RRULE:FREQ=DAILY;UNTIL=20260731T090000Z" "END:VEVENT")
         ("BEGIN:VEVENT" "UID:recur-3" "DTSTAMP:20260724T090000Z"
          "DTSTART:20260724T100000Z"
          "RRULE:FREQ=DAILY;UNTIL=20260731T100000" "END:VEVENT")
         ("BEGIN:VTODO" "UID:recur-4" "DTSTAMP:20260724T090000Z"
          "DTSTART:20260724T100000" "RRULE:FREQ=DAILY;UNTIL=20260731"
          "END:VTODO")
         ("BEGIN:VTODO" "UID:recur-5" "DTSTAMP:20260724T090000Z"
          "RRULE:FREQ=DAILY" "RRULE:FREQ=WEEKLY" "END:VTODO")))
    (let ((item (project-ical-component
                 (apply #'parse-first-ical-item-component lines))))
      (assert-false (ical-calendar-item-valid-p item))
      (assert-true (ical-calendar-item-diagnostics item)))))

(define-foundation-test vjournal-projects-its-rfc5545-core-matrix
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VJOURNAL"
            "UID:journal-1"
            "DTSTAMP:20260728T090000Z"
            "DTSTART;VALUE=DATE:20260728"
            "STATUS:FINAL"
            "SUMMARY:Daily record"
            "DESCRIPTION:First note"
            "DESCRIPTION;LANGUAGE=en:Second note"
            "REQUEST-STATUS:2.0;Success"
            "REQUEST-STATUS;LANGUAGE=en:3.1;Invalid property value;DTSTART:bad"
            "ATTENDEE;PARTSTAT=ACCEPTED:mailto:jane@example.test"
            "RRULE:FREQ=DAILY;COUNT=2"
            "X-FUTURE:preserved"
            "END:VJOURNAL"))
         (item (project-ical-component component)))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal :journal (ical-calendar-item-kind item))
    (assert-equal "First note" (ical-calendar-item-description item)
                  :test #'string=)
    (assert-equal '("First note" "Second note")
                  (ical-calendar-item-descriptions item))
    (assert-equal "FINAL" (ical-calendar-item-status item) :test #'string=)
    (assert-equal 2 (length (ical-calendar-item-request-statuses item)))
    (assert-equal '("2.0" "3.1")
                  (mapcar #'ical-request-status-value-code
                          (ical-calendar-item-request-statuses item)))
    (assert-equal :date (temporal-value-kind
                         (ical-calendar-item-start item)))
    (assert-equal :daily
                  (ical-recur-value-frequency
                   (ical-calendar-item-recurrence-rule item)))))

(define-foundation-test invalid-vjournal-core-matrices-fail-closed
  (dolist
      (lines
       '(("BEGIN:VJOURNAL" "DTSTAMP:20260728T090000Z" "END:VJOURNAL")
         ("BEGIN:VJOURNAL" "UID:no-stamp" "END:VJOURNAL")
         ("BEGIN:VJOURNAL" "UID:duplicate-summary"
          "DTSTAMP:20260728T090000Z" "SUMMARY:One" "SUMMARY:Two"
          "END:VJOURNAL")
         ("BEGIN:VJOURNAL" "UID:misplaced"
          "DTSTAMP:20260728T090000Z" "DTEND:20260728T100000Z"
          "END:VJOURNAL")
         ("BEGIN:VJOURNAL" "UID:bad-status"
          "DTSTAMP:20260728T090000Z" "STATUS:CONFIRMED" "END:VJOURNAL")
         ("BEGIN:VJOURNAL" "UID:bad-request-status"
          "DTSTAMP:20260728T090000Z" "REQUEST-STATUS:bad"
          "END:VJOURNAL")
         ("BEGIN:VJOURNAL" "UID:no-recurrence-start"
          "DTSTAMP:20260728T090000Z" "RRULE:FREQ=DAILY" "END:VJOURNAL")
         ("BEGIN:VJOURNAL" "UID:nested"
          "DTSTAMP:20260728T090000Z" "BEGIN:X-CHILD" "END:X-CHILD"
          "END:VJOURNAL")))
    (let ((item
            (project-ical-component
             (apply #'parse-first-ical-item-component lines))))
      (assert-false (ical-calendar-item-valid-p item))
      (assert-true (ical-calendar-item-diagnostics item)))))

(define-foundation-test vfreebusy-projects-its-rfc5545-core-matrix
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VFREEBUSY"
            "UID:freebusy-1"
            "DTSTAMP:20260728T090000Z"
            "CONTACT;LANGUAGE=en:Calendar service"
            "DTSTART:20260729T000000Z"
            "DTEND:20260730T000000Z"
            "ORGANIZER:mailto:owner@example.test"
            "URL:https://calendar.example.test/freebusy-1"
            "ATTENDEE:mailto:guest@example.test"
            "COMMENT;LANGUAGE=en:Published availability"
            "FREEBUSY;FBTYPE=BUSY-TENTATIVE:20260729T100000Z/PT1H"
            "FREEBUSY;FBTYPE=X-FOCUS:20260729T120000Z/20260729T130000Z"
            "REQUEST-STATUS:2.0;Success"
            "X-FUTURE:preserved"
            "END:VFREEBUSY"))
         (freebusy (project-ical-freebusy-component component)))
    (assert-true (ical-freebusy-valid-p freebusy))
    (assert-equal "freebusy-1" (ical-freebusy-uid freebusy) :test #'string=)
    (assert-equal 1 (length (ical-freebusy-attendees freebusy)))
    (assert-equal '("BUSY-TENTATIVE" "BUSY")
                  (mapcar #'ical-freebusy-period-entry-type
                          (ical-freebusy-periods freebusy))
                  :test #'equal)
    (assert-equal '(:registered :fallback)
                  (mapcar #'ical-freebusy-period-entry-resolution
                          (ical-freebusy-periods freebusy)))
    (assert-equal "2.0"
                  (ical-request-status-value-code
                   (first (ical-freebusy-request-statuses freebusy)))
                  :test #'string=)))

(define-foundation-test invalid-vfreebusy-core-matrices-fail-closed
  (dolist
      (lines
       '(("BEGIN:VFREEBUSY" "DTSTAMP:20260728T090000Z" "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:no-stamp" "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:duplicate-start"
          "DTSTAMP:20260728T090000Z" "DTSTART:20260729T000000Z"
          "DTSTART:20260729T010000Z" "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:local-start"
          "DTSTAMP:20260728T090000Z" "DTSTART:20260729T000000"
          "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:end-without-start"
          "DTSTAMP:20260728T090000Z" "DTEND:20260730T000000Z"
          "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:backwards"
          "DTSTAMP:20260728T090000Z" "DTSTART:20260730T000000Z"
          "DTEND:20260729T000000Z" "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:local-period"
          "DTSTAMP:20260728T090000Z"
          "FREEBUSY:20260729T100000/PT1H" "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:misplaced"
          "DTSTAMP:20260728T090000Z" "SUMMARY:Not allowed"
          "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:participant-parameter"
          "DTSTAMP:20260728T090000Z"
          "ATTENDEE;ROLE=REQ-PARTICIPANT:mailto:guest@example.test"
          "END:VFREEBUSY")
         ("BEGIN:VFREEBUSY" "UID:nested"
          "DTSTAMP:20260728T090000Z" "BEGIN:X-CHILD" "END:X-CHILD"
          "END:VFREEBUSY")))
    (let ((freebusy
            (project-ical-freebusy-component
             (apply #'parse-first-ical-item-component lines))))
      (assert-false (ical-freebusy-valid-p freebusy))
      (assert-true (ical-freebusy-diagnostics freebusy)))))
