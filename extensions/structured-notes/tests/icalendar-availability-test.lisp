(in-package #:lem-structured-notes/tests)

(defun test-ical-availability-component (&rest body-lines)
  (apply #'parse-first-ical-item-component body-lines))

(define-foundation-test rfc7953-availability-components-project-semantically
  (let* ((component
           (test-ical-availability-component
            "BEGIN:VAVAILABILITY"
            "UID:availability-1"
            "DTSTAMP:20260725T100000Z"
            "BUSYTYPE:BUSY-TENTATIVE"
            "PRIORITY:5"
            "DTSTART:20260725T000000Z"
            "DTEND:20260727T000000Z"
            "BEGIN:AVAILABLE"
            "UID:available-1"
            "DTSTAMP:20260725T100000Z"
            "DTSTART:20260725T090000Z"
            "DURATION:PT8H"
            "RRULE:FREQ=DAILY;COUNT=2"
            "SUMMARY:Office hours"
            "LOCATION:Main Office"
            "END:AVAILABLE"
            "END:VAVAILABILITY"))
         (availability (project-ical-availability-component component))
         (available (first (ical-availability-available availability))))
    (assert-true (ical-availability-valid-p availability))
    (assert-equal "BUSY-TENTATIVE"
                  (ical-availability-busy-type availability) :test #'string=)
    (assert-equal 5 (ical-availability-priority availability))
    (assert-equal 5 (ical-availability-priority-rank 5))
    (assert-equal 3 (ical-availability-busy-type-rank "BUSY"))
    (assert-equal 1 (length (ical-availability-available availability)))
    (assert-true (ical-available-valid-p available))
    (assert-equal "Office hours" (ical-available-summary available)
                  :test #'string=)
    (assert-true
     (find-if #'ical-availability-sensitive-property-p
              (ical-available-properties available)))))

(define-foundation-test rfc7953-availability-defaults-are-explicit
  (let ((availability
          (project-ical-availability-component
           (test-ical-availability-component
            "BEGIN:VAVAILABILITY" "UID:a"
            "DTSTAMP:20260725T100000Z"
            "END:VAVAILABILITY"))))
    (assert-true (ical-availability-valid-p availability))
    (assert-equal "BUSY-UNAVAILABLE"
                  (ical-availability-busy-type availability) :test #'string=)
    (assert-equal 0 (ical-availability-priority availability))
    (assert-equal 0 (ical-availability-priority-rank 0))))

(define-foundation-test rfc7953-invalid-availability-fails-closed
  (dolist
      (lines
       '(("BEGIN:VAVAILABILITY" "DTSTAMP:20260725T100000Z"
          "END:VAVAILABILITY")
         ("BEGIN:VAVAILABILITY" "UID:a" "DTSTAMP:20260725T100000"
          "END:VAVAILABILITY")
         ("BEGIN:VAVAILABILITY" "UID:a" "DTSTAMP:20260725T100000Z"
          "BUSYTYPE:FREE" "END:VAVAILABILITY")
         ("BEGIN:VAVAILABILITY" "UID:a" "DTSTAMP:20260725T100000Z"
          "DTSTART;VALUE=DATE:20260725" "END:VAVAILABILITY")
         ("BEGIN:VAVAILABILITY" "UID:a" "DTSTAMP:20260725T100000Z"
          "DURATION:PT1H" "END:VAVAILABILITY")
         ("BEGIN:VAVAILABILITY" "UID:a" "DTSTAMP:20260725T100000Z"
          "BEGIN:VEVENT" "END:VEVENT" "END:VAVAILABILITY")))
    (let ((availability
            (project-ical-availability-component
             (apply #'test-ical-availability-component lines))))
      (assert-false (ical-availability-valid-p availability))
      (assert-true (ical-availability-diagnostics availability)))))

(define-foundation-test rfc7953-invalid-available-fails-closed
  (dolist
      (available-lines
       '(("UID:slot" "DTSTAMP:20260725T100000Z")
         ("UID:slot" "DTSTAMP:20260725T100000Z"
          "DTSTART:20260725T100000Z" "DTEND:20260725T090000Z")
         ("UID:slot" "DTSTAMP:20260725T100000Z"
          "DTSTART:20260725T100000" "DURATION:PT1H")
         ("UID:slot" "DTSTAMP:20260725T100000Z"
          "DTSTART:20260725T100000Z" "DURATION:PT1H" "DTEND:20260725T110000Z")))
    (let* ((component
             (apply #'test-ical-availability-component
                    (append
                     '("BEGIN:VAVAILABILITY" "UID:a"
                       "DTSTAMP:20260725T100000Z" "BEGIN:AVAILABLE")
                     available-lines
                     '("END:AVAILABLE" "END:VAVAILABILITY"))))
           (availability (project-ical-availability-component component)))
      (assert-false (ical-availability-valid-p availability)))))

(define-foundation-test rfc7953-availability-redaction-is-source-preserving
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "VERSION:2.0" "PRODID:-//Redaction//EN"
            "BEGIN:VAVAILABILITY" "UID:a" "DTSTAMP:20260725T100000Z"
            "SUMMARY:Private schedule" "LOCATION:Private base"
            "BEGIN:AVAILABLE" "UID:slot" "DTSTAMP:20260725T100000Z"
            "DTSTART:20260727T090000Z" "DURATION:PT1H"
            "DESCRIPTION:Private details" "X-PUBLIC:retained"
            "END:AVAILABLE" "END:VAVAILABILITY" "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "redact.ics"))
         (component
           (first
            (ical-component-children
             (first (ical-document-components document)))))
         (availability (project-ical-availability-component component))
         (edits (plan-ical-availability-redaction document availability))
         (redacted (apply-ical-source-edits document edits)))
    (assert-equal 3 (length edits))
    (assert-false (search "Private" redacted))
    (assert-true (search "UID:a" redacted))
    (assert-true (search "X-PUBLIC:retained" redacted))
    (assert-equal
     :protected-icalendar-availability-property
     (signaled-model-code
      (lambda ()
        (plan-ical-availability-redaction
         document availability :property-names '("DTSTART")))))))
