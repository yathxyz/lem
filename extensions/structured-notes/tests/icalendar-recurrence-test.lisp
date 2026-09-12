(in-package #:lem-structured-notes/tests)

(defun recurrence-test-temporal (raw &optional timezone-id)
  (multiple-value-bind (value valid-p message)
      (if (= (length raw) 8)
          (lem-structured-notes::decode-ical-date raw)
          (lem-structured-notes::decode-ical-date-time raw timezone-id))
    (unless valid-p (error "invalid recurrence test temporal: ~a" message))
    value))

(defun recurrence-test-rule (raw)
  (multiple-value-bind (value valid-p message)
      (lem-structured-notes::decode-ical-recur raw)
    (unless valid-p (error "invalid recurrence test rule: ~a" message))
    value))

(defun recurrence-test-values (expansion)
  (mapcar #'temporal-value-local-value
          (ical-recurrence-expansion-instances expansion)))

(defun recurrence-test-expand
    (start rule window-start window-end &rest arguments)
  (apply #'expand-ical-recurrence-set
         (recurrence-test-temporal start)
         :rule (and rule (recurrence-test-rule rule))
         :window-start (recurrence-test-temporal window-start)
         :window-end (recurrence-test-temporal window-end)
         arguments))

(define-foundation-test rfc7529-recurrence-never-runs-as-gregorian
  (assert-signals
   'semantic-model-error
   (lambda ()
     (recurrence-test-expand
      "20260724T090000Z" "FREQ=YEARLY;RSCALE=GREGORIAN;COUNT=2"
      "20260101T000000Z" "20290101T000000Z"))))

(define-foundation-test bounded-recurrence-expands-all-core-frequencies
  (dolist
      (specification
       '(("20260724T090000Z" "FREQ=SECONDLY;INTERVAL=10;COUNT=3"
          "2026-07-24T09:00:00Z" "2026-07-24T09:00:10Z"
          "2026-07-24T09:00:20Z")
         ("20260724T090000Z" "FREQ=MINUTELY;INTERVAL=15;COUNT=3"
          "2026-07-24T09:00:00Z" "2026-07-24T09:15:00Z"
          "2026-07-24T09:30:00Z")
         ("20260724T091500Z" "FREQ=HOURLY;COUNT=3;BYMINUTE=15"
          "2026-07-24T09:15:00Z" "2026-07-24T10:15:00Z"
          "2026-07-24T11:15:00Z")
         ("20260724T090000Z" "FREQ=DAILY;COUNT=3"
          "2026-07-24T09:00:00Z" "2026-07-25T09:00:00Z"
          "2026-07-26T09:00:00Z")
         ("20260720T090000Z" "FREQ=WEEKLY;COUNT=3;BYDAY=MO"
          "2026-07-20T09:00:00Z" "2026-07-27T09:00:00Z"
          "2026-08-03T09:00:00Z")
         ("20260131T090000Z" "FREQ=MONTHLY;COUNT=3"
          "2026-01-31T09:00:00Z" "2026-03-31T09:00:00Z"
          "2026-05-31T09:00:00Z")
         ("20260308T090000Z" "FREQ=YEARLY;COUNT=3;BYMONTH=3;BYDAY=2SU"
          "2026-03-08T09:00:00Z" "2027-03-14T09:00:00Z"
          "2028-03-12T09:00:00Z")))
    (destructuring-bind (start rule &rest expected) specification
      (assert-equal
       expected
       (recurrence-test-values
        (recurrence-test-expand
         start rule start "20300101T000000Z"))))))

(define-foundation-test recurrence-applies-expand-limit-and-setpos-order
  (assert-equal
   '("2026-01-30T09:00:00Z" "2026-02-27T09:00:00Z"
     "2026-03-31T09:00:00Z" "2026-04-30T09:00:00Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20260130T090000Z"
     "FREQ=MONTHLY;COUNT=4;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"
     "20260101T000000Z" "20260501T000000Z")))
  (assert-equal
   '("2021-01-04T09:00:00Z" "2022-01-03T09:00:00Z"
     "2023-01-02T09:00:00Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20210104T090000Z" "FREQ=YEARLY;COUNT=3;BYWEEKNO=1;BYDAY=MO"
     "20200101T000000Z" "20240101T000000Z")))
  (assert-equal
   '("2018-01-01T09:00:00Z" "2018-12-31T09:00:00Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20180101T090000Z" "FREQ=YEARLY;COUNT=3;BYWEEKNO=1;BYDAY=MO"
     "20180101T000000Z" "20190101T000000Z")))
  (assert-equal
   '("2020-12-31T09:00:00Z" "2021-12-31T09:00:00Z"
     "2022-12-31T09:00:00Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20201231T090000Z" "FREQ=YEARLY;COUNT=3;BYYEARDAY=-1"
     "20200101T000000Z" "20230101T000000Z"))))

(define-foundation-test recurrence-bysecond-60-aliases-second-59
  (assert-equal
   '("2026-07-24T09:00:59Z" "2026-07-25T09:00:59Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20260724T090059Z" "FREQ=DAILY;COUNT=2;BYSECOND=60"
     "20260724T000000Z" "20260727T000000Z")))
  (assert-equal
   '("2026-07-24T09:00:59Z" "2026-07-25T09:00:59Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20260724T090059Z" "FREQ=DAILY;COUNT=2;BYSECOND=59,60"
     "20260724T000000Z" "20260727T000000Z")))
  (assert-equal
   '("2026-07-24T09:00:59Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20260724T090059Z"
     "FREQ=DAILY;COUNT=1;BYSECOND=58,59,60;BYSETPOS=2"
     "20260724T000000Z" "20260725T000000Z"
     :limits (make-ical-recurrence-limits :max-candidates 2)))))

(define-foundation-test recurrence-normalizes-explicit-utc-leap-identities
  (assert-equal
   '("2016-12-31T23:59:59Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20161231T235960Z" nil
     "20161231T000000Z" "20170101T000000Z")))
  (assert-equal
   '("2016-12-31T23:59:59Z" "2017-01-01T23:59:59Z")
   (recurrence-test-values
    (recurrence-test-expand
     "20161231T235960Z" "FREQ=DAILY;COUNT=2"
     "20161231T000000Z" "20170102T000000Z")))
  (let ((ordinary (recurrence-test-temporal "20161230T235959Z"))
        (leap (recurrence-test-temporal "20161231T235960Z")))
    (assert-equal
     '("2016-12-30T23:59:59Z" "2016-12-31T23:59:59Z")
     (recurrence-test-values
      (expand-ical-recurrence-set
       ordinary :recurrence-dates (list leap)
       :window-start (recurrence-test-temporal "20161230T000000Z")
       :window-end (recurrence-test-temporal "20170101T000000Z"))))
    (assert-equal
     '("2016-12-30T23:59:59Z" "2017-01-01T23:59:59Z")
     (recurrence-test-values
      (expand-ical-recurrence-set
       ordinary :rule (recurrence-test-rule "FREQ=DAILY;COUNT=3")
       :exception-dates (list leap)
       :window-start (recurrence-test-temporal "20161230T000000Z")
       :window-end (recurrence-test-temporal "20170102T000000Z")))))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (recurrence-test-expand
      "20161231T235960" nil
      "20161231T000000" "20170101T000000")))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (expand-ical-recurrence-set
      (make-temporal-value
       :kind :utc :local-value "2016-12-30T23:59:60Z"
       :precision :second)
      :window-start (recurrence-test-temporal "20161230T000000Z")
      :window-end (recurrence-test-temporal "20161231T000000Z")))))

(define-foundation-test recurrence-normalizes-proven-local-leap-identities
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "recurrence-leap-fixture/1"))
         (zoned-leap
           (recurrence-test-temporal "20170101T005960" "Leap/Plus-One"))
         (zoned-window-start
           (recurrence-test-temporal "20170101T000000" "Leap/Plus-One"))
         (zoned-window-end
           (recurrence-test-temporal "20170102T000000" "Leap/Plus-One"))
         (floating-leap (recurrence-test-temporal "20170101T005960"))
         (floating-window-start (recurrence-test-temporal "20170101T000000"))
         (floating-window-end (recurrence-test-temporal "20170102T000000")))
    (assert-equal
     '("2017-01-01T00:59:59")
     (recurrence-test-values
      (expand-ical-recurrence-set
       zoned-leap :window-start zoned-window-start
       :window-end zoned-window-end :timezone-provider provider)))
    (assert-equal
     '("2017-01-01T00:59:59")
     (recurrence-test-values
      (expand-ical-recurrence-set
       floating-leap :window-start floating-window-start
       :window-end floating-window-end :timezone-provider provider
       :floating-timezone-id "Leap/Plus-One")))
    (let ((ordinary
            (recurrence-test-temporal
             "20161231T005959" "Leap/Plus-One")))
      (assert-equal
       '("2016-12-31T00:59:59" "2017-01-01T00:59:59")
       (recurrence-test-values
        (expand-ical-recurrence-set
         ordinary :recurrence-dates (list zoned-leap)
         :window-start
         (recurrence-test-temporal "20161231T000000" "Leap/Plus-One")
         :window-end zoned-window-end :timezone-provider provider)))
      (assert-equal
       '("2016-12-31T00:59:59" "2017-01-02T00:59:59")
       (recurrence-test-values
        (expand-ical-recurrence-set
         ordinary :rule (recurrence-test-rule "FREQ=DAILY;COUNT=3")
         :exception-dates (list zoned-leap)
         :window-start
         (recurrence-test-temporal "20161231T000000" "Leap/Plus-One")
         :window-end
         (recurrence-test-temporal "20170103T000000" "Leap/Plus-One")
         :timezone-provider provider))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-recurrence-set
        zoned-leap :window-start zoned-window-start
        :window-end zoned-window-end)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-recurrence-set
        floating-leap :window-start floating-window-start
        :window-end floating-window-end :timezone-provider provider)))))

(define-foundation-test recurrence-set-unions-deduplicates-and-excludes
  (let* ((start (recurrence-test-temporal "20260724T090000Z"))
         (expansion
           (expand-ical-recurrence-set
            start
            :rule (recurrence-test-rule "FREQ=DAILY;COUNT=4")
            :recurrence-dates
            (list (recurrence-test-temporal "20260725T090000Z")
                  (recurrence-test-temporal "20260730T090000Z"))
            :exception-dates
            (list start (recurrence-test-temporal "20260726T090000Z"))
            :window-start (recurrence-test-temporal "20260724T000000Z")
            :window-end (recurrence-test-temporal "20260801T000000Z"))))
    (assert-equal
     '("2026-07-25T09:00:00Z" "2026-07-27T09:00:00Z"
       "2026-07-30T09:00:00Z")
     (recurrence-test-values expansion))))

(define-foundation-test projected-calendar-master-expands-its-recurrence-set
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:recurrence-master"
            "DTSTAMP:20260724T000000Z" "DTSTART:20260724T090000Z"
            "RRULE:FREQ=DAILY;COUNT=4" "RDATE:20260730T090000Z"
            "EXDATE:20260725T090000Z" "END:VEVENT"))
         (item (project-ical-component component))
         (expansion
           (expand-ical-calendar-item-recurrence
            item
            :window-start (recurrence-test-temporal "20260724T000000Z")
            :window-end (recurrence-test-temporal "20260801T000000Z"))))
    (assert-equal
     '("2026-07-24T09:00:00Z" "2026-07-26T09:00:00Z"
       "2026-07-27T09:00:00Z" "2026-07-30T09:00:00Z")
     (recurrence-test-values expansion))))

(define-foundation-test projected-vjournal-expands-its-recurrence-set
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VJOURNAL" "UID:journal-recurrence-master"
            "DTSTAMP:20260728T000000Z" "DTSTART;VALUE=DATE:20260728"
            "RRULE:FREQ=DAILY;COUNT=4" "RDATE;VALUE=DATE:20260803"
            "EXDATE;VALUE=DATE:20260729" "END:VJOURNAL"))
         (item (project-ical-component component))
         (expansion
           (expand-ical-calendar-item-recurrence
            item
            :window-start (recurrence-test-temporal "20260728")
            :window-end (recurrence-test-temporal "20260805"))))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal
     '("2026-07-28" "2026-07-30" "2026-07-31" "2026-08-03")
     (recurrence-test-values expansion))))

(define-foundation-test period-rdate-contributes-its-start-to-recurrence-set
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:period-recurrence"
            "DTSTAMP:20260724T000000Z" "DTSTART:20260724T090000Z"
            "RDATE;VALUE=PERIOD:20260725T090000Z/20260725T110000Z,20260726T090000Z/PT3H"
            "EXDATE:20260725T090000Z" "END:VEVENT"))
         (item (project-ical-component component))
         (expansion
           (expand-ical-calendar-item-recurrence
            item
            :window-start (recurrence-test-temporal "20260724T000000Z")
            :window-end (recurrence-test-temporal "20260727T000000Z"))))
    (assert-equal
     '("2026-07-24T09:00:00Z" "2026-07-26T09:00:00Z")
     (recurrence-test-values expansion))))

(define-foundation-test recurrence-window-is-half-open-and-until-is-inclusive
  (let ((expansion
          (recurrence-test-expand
           "20260724T090000Z" "FREQ=DAILY;UNTIL=20260728T090000Z"
           "20260726T090000Z" "20260728T090000Z")))
    (assert-equal
     '("2026-07-26T09:00:00Z" "2026-07-27T09:00:00Z")
     (recurrence-test-values expansion))))

(define-foundation-test date-recurrence-ignores-time-selectors
  (let ((expansion
          (recurrence-test-expand
           "20260724" "FREQ=DAILY;COUNT=3;BYHOUR=9;BYMINUTE=30"
           "20260724" "20260728")))
    (assert-equal '("2026-07-24" "2026-07-25" "2026-07-26")
                  (recurrence-test-values expansion))))

(define-foundation-test recurrence-expansion-is-deterministic
  (let* ((arguments
           (list "20260720T090000Z"
                 "FREQ=WEEKLY;COUNT=8;BYDAY=MO,WE,FR"
                 "20260701T000000Z" "20260831T000000Z"))
         (first (apply #'recurrence-test-expand arguments))
         (second (apply #'recurrence-test-expand arguments)))
    (assert-equal (recurrence-test-values first)
                  (recurrence-test-values second))
    (assert-equal (ical-recurrence-expansion-periods-examined first)
                  (ical-recurrence-expansion-periods-examined second))
    (assert-equal (ical-recurrence-expansion-candidates-examined first)
                  (ical-recurrence-expansion-candidates-examined second))))

(define-foundation-test
    zoned-recurrence-uses-pre-gap-offset-and-selects-first-fold
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Recurrence/Test"
             "BEGIN:STANDARD" "DTSTART:20260101T000000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0500" "END:STANDARD"
             "BEGIN:DAYLIGHT" "DTSTART:20260308T020000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0400" "END:DAYLIGHT"
             "BEGIN:STANDARD" "DTSTART:20261101T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider (make-embedded-timezone-provider (list definition)))
         (spring-start
           (recurrence-test-temporal "20260307T023000" "Recurrence/Test"))
         (spring
           (expand-ical-recurrence-set
            spring-start :rule (recurrence-test-rule "FREQ=DAILY;COUNT=3")
            :window-start spring-start
            :window-end
            (recurrence-test-temporal "20260312T000000" "Recurrence/Test")
            :timezone-provider provider))
         (autumn-start
           (recurrence-test-temporal "20261031T013000" "Recurrence/Test"))
         (autumn
           (expand-ical-recurrence-set
            autumn-start :rule (recurrence-test-rule "FREQ=DAILY;COUNT=3")
            :window-start autumn-start
            :window-end
            (recurrence-test-temporal "20261104T000000" "Recurrence/Test")
            :timezone-provider provider)))
    (assert-equal
     '("2026-03-07T02:30:00" "2026-03-08T02:30:00"
       "2026-03-09T02:30:00")
     (recurrence-test-values spring))
    (assert-equal
     :rfc5545
     (temporal-value-gap-policy
      (second (ical-recurrence-expansion-instances spring))))
    (assert-equal
     (lem-structured-notes::ical-utc-temporal-seconds
      (recurrence-test-temporal "20260308T073000Z"))
     (timezone-resolution-candidate-utc-seconds
      (select-timezone-resolution
       (resolve-zoned-local-time
        provider (second (ical-recurrence-expansion-instances spring)))
       :gap-policy :rfc5545)))
    (assert-equal
     '("2026-10-31T01:30:00" "2026-11-01T01:30:00"
       "2026-11-02T01:30:00")
     (recurrence-test-values autumn))
    (assert-equal
     0
     (temporal-value-fold
      (second (ical-recurrence-expansion-instances autumn))))))

(define-foundation-test recurrence-expansion-enforces-every-resource-limit
  (assert-signals
   'semantic-model-error
   (lambda ()
     (recurrence-test-expand
      "20260131T090000Z" "FREQ=MONTHLY;COUNT=4"
      "20260101T000000Z" "20270101T000000Z"
      :limits (make-ical-recurrence-limits :max-periods 2))))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (recurrence-test-expand
      "20260101T090000Z" "FREQ=YEARLY;COUNT=2;BYDAY=TH"
      "20260101T000000Z" "20280101T000000Z"
      :limits (make-ical-recurrence-limits :max-candidates 10))))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (recurrence-test-expand
      "20260724T090000Z" "FREQ=DAILY;COUNT=5"
      "20260724T000000Z" "20260801T000000Z"
      :limits (make-ical-recurrence-limits :max-instances 3)))))

(define-foundation-test unsupported-or-incoherent-recurrence-fails-closed
  (assert-signals
   'semantic-model-error
   (lambda ()
     (recurrence-test-expand
      "20260720T090000Z" "FREQ=WEEKLY;COUNT=2;BYDAY=TU"
      "20260701T000000Z" "20260801T000000Z")))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (expand-ical-recurrence-set
      (recurrence-test-temporal "20260724T090000Z")
      :recurrence-dates (list (recurrence-test-temporal "20260725"))
      :window-start (recurrence-test-temporal "20260724T000000Z")
      :window-end (recurrence-test-temporal "20260801T000000Z"))))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (let ((start
             (recurrence-test-temporal "20260724T090000" "Missing/Zone")))
       (expand-ical-recurrence-set
        start :rule (recurrence-test-rule "FREQ=DAILY;COUNT=2")
        :window-start start
        :window-end
        (recurrence-test-temporal "20260727T000000" "Missing/Zone")))))
  (let ((override
          (project-ical-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:detached"
            "DTSTAMP:20260724T000000Z" "DTSTART:20260725T090000Z"
            "RECURRENCE-ID:20260725T090000Z" "END:VEVENT"))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-calendar-item-recurrence
        override
        :window-start (recurrence-test-temporal "20260724T000000Z")
        :window-end (recurrence-test-temporal "20260801T000000Z"))))))
