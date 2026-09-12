(in-package #:lem-structured-notes/tests)

(defun test-project-ical-availabilities (&rest lines)
  (let* ((source
           (apply #'ical-crlf-lines
                  (append
                   '("BEGIN:VCALENDAR" "VERSION:2.0"
                     "PRODID:-//Availability Expansion Test//EN")
                   lines '("END:VCALENDAR"))))
         (document
           (parse-icalendar-cst source :source-id "availability-expansion.ics"))
         (calendar (first (ical-document-components document))))
    (mapcar #'project-ical-availability-component
            (ical-component-children calendar))))

(defun test-availability-utc (local)
  (make-temporal-value :kind :utc :local-value local))

(defun test-calculate-availability (availabilities start end)
  (calculate-ical-availability
   availabilities
   :window-start (test-availability-utc start)
   :window-end (test-availability-utc end)))

(defun test-availability-period-signatures (expansion)
  (mapcar
   (lambda (period)
     (list (ical-availability-period-type period)
           (temporal-value-local-value
            (ical-availability-period-start period))
           (temporal-value-local-value
            (ical-availability-period-end period))))
   (ical-availability-expansion-periods expansion)))

(define-foundation-test rfc7953-normalizes-pinned-leap-window-bounds
  (let* ((window-start (test-availability-utc "2016-12-31T23:59:60Z"))
         (window-end (test-availability-utc "2017-01-01T00:00:02Z"))
         (result
           (calculate-ical-availability
            nil :window-start window-start :window-end window-end)))
    (assert-equal window-start
                  (ical-availability-expansion-window-start result)
                  :test #'eq)
    (assert-equal window-end
                  (ical-availability-expansion-window-end result)
                  :test #'eq)
    (assert-equal nil (ical-availability-expansion-periods result)))
  (assert-equal
   :invalid-icalendar-availability-window
   (signaled-model-code
    (lambda ()
      (calculate-ical-availability
       nil
       :window-start (test-availability-utc "2016-12-31T23:59:59Z")
       :window-end (test-availability-utc "2016-12-31T23:59:60Z"))))))

(define-foundation-test rfc7953-calculation-marks-availability-gaps-busy
  (let* ((availabilities
           (test-project-ical-availabilities
            "BEGIN:VAVAILABILITY" "UID:work" "DTSTAMP:20260725T100000Z"
            "BEGIN:AVAILABLE" "UID:hours" "DTSTAMP:20260725T100000Z"
            "DTSTART:20260727T090000Z" "DTEND:20260727T170000Z"
            "END:AVAILABLE" "END:VAVAILABILITY"))
         (result
           (test-calculate-availability
            availabilities "2026-07-27T00:00:00Z" "2026-07-28T00:00:00Z")))
    (assert-equal
     '(("BUSY-UNAVAILABLE" "2026-07-27T00:00:00Z" "2026-07-27T09:00:00Z")
       ("BUSY-UNAVAILABLE" "2026-07-27T17:00:00Z" "2026-07-28T00:00:00Z"))
     (test-availability-period-signatures result)
     :test #'equal)))

(define-foundation-test rfc7953-higher-priority-partial-overlap-controls
  (let* ((availabilities
           (test-project-ical-availabilities
            "BEGIN:VAVAILABILITY" "UID:base" "DTSTAMP:20260725T100000Z"
            "BEGIN:AVAILABLE" "UID:base-hours" "DTSTAMP:20260725T100000Z"
            "DTSTART:20260727T080000Z" "DTEND:20260727T180000Z"
            "END:AVAILABLE" "END:VAVAILABILITY"
            "BEGIN:VAVAILABILITY" "UID:override" "DTSTAMP:20260725T100000Z"
            "PRIORITY:1" "BUSYTYPE:BUSY-TENTATIVE"
            "DTSTART:20260727T120000Z" "DTEND:20260727T160000Z"
            "BEGIN:AVAILABLE" "UID:override-hours"
            "DTSTAMP:20260725T100000Z"
            "DTSTART:20260727T130000Z" "DTEND:20260727T140000Z"
            "END:AVAILABLE" "END:VAVAILABILITY"))
         (result
           (test-calculate-availability
            availabilities "2026-07-27T00:00:00Z" "2026-07-28T00:00:00Z")))
    (assert-equal
     '(("BUSY-UNAVAILABLE" "2026-07-27T00:00:00Z" "2026-07-27T08:00:00Z")
       ("BUSY-TENTATIVE" "2026-07-27T12:00:00Z" "2026-07-27T13:00:00Z")
       ("BUSY-TENTATIVE" "2026-07-27T14:00:00Z" "2026-07-27T16:00:00Z")
       ("BUSY-UNAVAILABLE" "2026-07-27T18:00:00Z" "2026-07-28T00:00:00Z"))
     (test-availability-period-signatures result)
     :test #'equal)))

(define-foundation-test rfc7953-same-priority-busytype-precedence-is-exact
  (let* ((availabilities
           (test-project-ical-availabilities
            "BEGIN:VAVAILABILITY" "UID:tentative"
            "DTSTAMP:20260725T100000Z" "BUSYTYPE:BUSY-TENTATIVE"
            "END:VAVAILABILITY"
            "BEGIN:VAVAILABILITY" "UID:busy"
            "DTSTAMP:20260725T100000Z" "BUSYTYPE:BUSY"
            "END:VAVAILABILITY"))
         (result
           (test-calculate-availability
            availabilities "2026-07-27T00:00:00Z" "2026-07-28T00:00:00Z")))
    (assert-equal
     '(("BUSY" "2026-07-27T00:00:00Z" "2026-07-28T00:00:00Z"))
     (test-availability-period-signatures result)
     :test #'equal)))

(define-foundation-test rfc7953-available-recurrence-overrides-are-expanded
  (let* ((availabilities
           (test-project-ical-availabilities
            "BEGIN:VAVAILABILITY" "UID:work" "DTSTAMP:20260725T100000Z"
            "BEGIN:AVAILABLE" "UID:hours" "DTSTAMP:20260725T100000Z"
            "DTSTART:20260727T090000Z" "DURATION:PT8H"
            "RRULE:FREQ=DAILY;COUNT=2" "END:AVAILABLE"
            "BEGIN:AVAILABLE" "UID:hours" "DTSTAMP:20260725T110000Z"
            "RECURRENCE-ID:20260728T090000Z"
            "DTSTART:20260728T100000Z" "DURATION:PT4H"
            "END:AVAILABLE" "END:VAVAILABILITY"))
         (result
           (test-calculate-availability
            availabilities "2026-07-27T00:00:00Z" "2026-07-29T00:00:00Z")))
    (assert-equal
     '(("BUSY-UNAVAILABLE" "2026-07-27T00:00:00Z" "2026-07-27T09:00:00Z")
       ("BUSY-UNAVAILABLE" "2026-07-27T17:00:00Z" "2026-07-28T10:00:00Z")
       ("BUSY-UNAVAILABLE" "2026-07-28T14:00:00Z" "2026-07-29T00:00:00Z"))
     (test-availability-period-signatures result)
     :test #'equal)))

(define-foundation-test rfc7953-undefined-extension-precedence-fails-closed
  (let ((availabilities
          (test-project-ical-availabilities
           "BEGIN:VAVAILABILITY" "UID:a" "DTSTAMP:20260725T100000Z"
           "BUSYTYPE:X-FIRST" "END:VAVAILABILITY"
           "BEGIN:VAVAILABILITY" "UID:b" "DTSTAMP:20260725T100000Z"
           "BUSYTYPE:X-SECOND" "END:VAVAILABILITY")))
    (assert-equal
     :undefined-icalendar-availability-busy-precedence
     (signaled-model-code
      (lambda ()
        (test-calculate-availability
         availabilities "2026-07-27T00:00:00Z"
         "2026-07-28T00:00:00Z"))))))

(define-foundation-test rfc7953-time-range-overlap-table-is-exact
  (let ((window-start (test-availability-utc "2026-07-27T10:00:00Z"))
        (window-end (test-availability-utc "2026-07-27T20:00:00Z")))
    (flet ((overlap (&rest properties)
             (let ((availability
                     (first
                      (apply
                       #'test-project-ical-availabilities
                       (append
                        '("BEGIN:VAVAILABILITY" "UID:a"
                          "DTSTAMP:20260725T100000Z")
                        properties '("END:VAVAILABILITY"))))))
               (ical-availability-overlaps-window-p
                availability window-start window-end))))
      (assert-true
       (overlap "DTSTART:20260727T090000Z" "DTEND:20260727T110000Z"))
      (assert-false
       (overlap "DTSTART:20260727T090000Z" "DURATION:PT1H"))
      (assert-false (overlap "DTSTART:20260727T200000Z"))
      (assert-true (overlap "DTEND:20260727T110000Z"))
      (assert-true (overlap)))))

(define-foundation-test rfc7953-zoned-availability-resolves-through-vtimezone
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:America/New_York"
             "BEGIN:DAYLIGHT" "DTSTART:20260308T020000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0400" "END:DAYLIGHT"
             "BEGIN:STANDARD" "DTSTART:20261101T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "fixture/2026a"))
         (availabilities
           (test-project-ical-availabilities
            "BEGIN:VAVAILABILITY" "UID:work" "DTSTAMP:20260301T100000Z"
            "BEGIN:AVAILABLE" "UID:hours" "DTSTAMP:20260301T100000Z"
            "DTSTART;TZID=America/New_York:20260308T090000"
            "DTEND;TZID=America/New_York:20260308T170000"
            "END:AVAILABLE" "END:VAVAILABILITY"))
         (result
           (calculate-ical-availability
            availabilities
            :window-start (test-availability-utc "2026-03-08T00:00:00Z")
            :window-end (test-availability-utc "2026-03-09T00:00:00Z")
            :timezone-provider provider)))
    (assert-equal
     '(("BUSY-UNAVAILABLE" "2026-03-08T00:00:00Z" "2026-03-08T13:00:00Z")
       ("BUSY-UNAVAILABLE" "2026-03-08T21:00:00Z" "2026-03-09T00:00:00Z"))
     (test-availability-period-signatures result)
     :test #'equal)))

(define-foundation-test rfc7953-zoned-leap-availability-requires-exact-context
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "availability-leap/1"))
         (availabilities
           (test-project-ical-availabilities
            "BEGIN:VAVAILABILITY" "UID:leap-availability"
            "DTSTAMP:20161201T000000Z"
            "BEGIN:AVAILABLE" "UID:leap-slot" "DTSTAMP:20161201T000000Z"
            "DTSTART;TZID=Leap/Plus-One:20170101T005960"
            "DURATION:PT2S" "END:AVAILABLE" "END:VAVAILABILITY"))
         (window-start (test-availability-utc "2016-12-31T23:59:00Z"))
         (window-end (test-availability-utc "2017-01-01T00:01:00Z"))
         (result
           (calculate-ical-availability
            availabilities :window-start window-start :window-end window-end
            :timezone-provider provider)))
    (assert-equal
     '(("BUSY-UNAVAILABLE" "2016-12-31T23:59:00Z"
        "2016-12-31T23:59:59Z")
       ("BUSY-UNAVAILABLE" "2017-01-01T00:00:01Z"
        "2017-01-01T00:01:00Z"))
     (test-availability-period-signatures result)
     :test #'equal)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (calculate-ical-availability
        availabilities :window-start window-start :window-end window-end)))))
