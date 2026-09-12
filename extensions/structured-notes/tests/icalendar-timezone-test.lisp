(in-package #:lem-structured-notes/tests)

(defun parse-timezone-component (&rest body)
  (apply #'parse-first-ical-item-component
         (append '("BEGIN:VTIMEZONE") body '("END:VTIMEZONE"))))

(defun test-zoned-temporal (timezone-id local)
  (make-temporal-value :kind :zoned :local-value local
                       :timezone-id timezone-id))

(define-foundation-test standalone-local-time-leap-second-requires-exact-zone
  (flet ((definition (timezone-id &rest observance-lines)
           (project-ical-timezone-component
            (apply #'parse-timezone-component
                   (format nil "TZID:~a" timezone-id)
                   observance-lines)))
         (decoded-time (raw &optional timezone-id)
           (ical-value-decoded
            (assert-valid-ical-value :time raw :timezone-id timezone-id)))
         (date (raw)
           (ical-value-decoded (assert-valid-ical-value :date raw))))
    (let* ((plus-one
             (definition
              "Leap/Plus-One"
              "BEGIN:STANDARD" "DTSTART:20000101T000000"
              "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"))
           (fold
             (definition
              "Leap/Fold"
              "BEGIN:STANDARD" "DTSTART:20000101T000000"
              "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
              "BEGIN:STANDARD" "DTSTART:20170101T010000"
              "TZOFFSETFROM:+0100" "TZOFFSETTO:+0000" "END:STANDARD"))
           (gap
             (definition
              "Leap/Gap"
              "BEGIN:STANDARD" "DTSTART:20000101T000000"
              "TZOFFSETFROM:+0000" "TZOFFSETTO:+0000" "END:STANDARD"
              "BEGIN:STANDARD" "DTSTART:20170101T000000"
              "TZOFFSETFROM:+0000" "TZOFFSETTO:+0100" "END:STANDARD"))
           (provider
             (make-embedded-timezone-provider
              (list plus-one fold gap) :version "leap-fixture/1"))
           (local-date (date "20170101"))
           (utc-date (date "20161231"))
           (wrong-date (date "20161230"))
           (zoned (decoded-time "005960" "Leap/Plus-One"))
           (floating (decoded-time "005960"))
           (utc (decoded-time "235960Z"))
           (ordinary (decoded-time "005959"))
           (wrong-clock (decoded-time "015960" "Leap/Plus-One")))
      (assert-equal
       zoned
       (validate-ical-time-value-timezone-context zoned local-date provider))
      (assert-equal
       floating
       (validate-ical-time-value-timezone-context
        floating local-date provider :floating-timezone-id "Leap/Plus-One"))
      (assert-equal
       utc
       (validate-ical-time-value-timezone-context utc utc-date provider))
      (assert-equal
       ordinary
       (validate-ical-time-value-timezone-context
        ordinary wrong-date provider))
      (assert-equal
       :invalid-icalendar-positive-leap-second
       (signaled-model-code
        (lambda ()
          (validate-ical-time-value-timezone-context
           wrong-clock local-date provider))))
      (assert-equal
       :invalid-icalendar-positive-leap-second
       (signaled-model-code
        (lambda ()
          (validate-ical-time-value-timezone-context
           zoned wrong-date provider))))
      (dolist (timezone-id '("Leap/Fold" "Leap/Gap" "Leap/Unknown"))
        (assert-equal
         :unresolved-icalendar-local-leap-second
         (signaled-model-code
          (lambda ()
            (validate-ical-time-value-timezone-context
             (decoded-time "005960" timezone-id) local-date provider)))))
      (assert-equal
       :unresolved-icalendar-local-leap-second
       (signaled-model-code
        (lambda ()
          (validate-ical-time-value-timezone-context
           floating local-date provider))))
      (assert-equal
       :unexpected-icalendar-floating-timezone-id
       (signaled-model-code
        (lambda ()
          (validate-ical-time-value-timezone-context
           zoned local-date provider
           :floating-timezone-id "Leap/Plus-One"))))
      (assert-equal
       :invalid-icalendar-time-timezone-provider
       (signaled-model-code
        (lambda ()
          (validate-ical-time-value-timezone-context
           zoned local-date nil)))))))

(define-foundation-test local-date-time-leap-second-reuses-exact-zone-proof
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "date-time-leap-fixture/1"))
         (zoned
           (ical-value-decoded
            (assert-valid-ical-value
             :date-time "20170101T005960"
             :timezone-id "Leap/Plus-One")))
         (floating
           (ical-value-decoded
            (assert-valid-ical-value :date-time "20170101T005960")))
         (utc
           (ical-value-decoded
            (assert-valid-ical-value :date-time "20161231T235960Z")))
         (ordinary
           (ical-value-decoded
            (assert-valid-ical-value :date-time "20161230T005959")))
         (wrong-clock
           (ical-value-decoded
            (assert-valid-ical-value
             :date-time "20170101T015960"
             :timezone-id "Leap/Plus-One")))
         (unknown-zone
           (ical-value-decoded
            (assert-valid-ical-value
             :date-time "20170101T005960"
             :timezone-id "Leap/Unknown"))))
    (assert-equal
     zoned
     (validate-ical-date-time-leap-second-context zoned provider))
    (assert-equal
     floating
     (validate-ical-date-time-leap-second-context
      floating provider :floating-timezone-id "Leap/Plus-One"))
    (assert-equal
     utc
     (validate-ical-date-time-leap-second-context utc nil))
    (assert-equal
     ordinary
     (validate-ical-date-time-leap-second-context ordinary nil))
    (assert-equal
     :invalid-icalendar-positive-leap-second
     (signaled-model-code
      (lambda ()
        (validate-ical-date-time-leap-second-context wrong-clock provider))))
    (dolist (value (list floating unknown-zone))
      (assert-equal
       :unresolved-icalendar-local-leap-second
       (signaled-model-code
        (lambda ()
          (validate-ical-date-time-leap-second-context value provider)))))
    (assert-equal
     :invalid-icalendar-date-time-timezone-context
     (signaled-model-code
      (lambda ()
        (validate-ical-date-time-leap-second-context
         (make-temporal-value
          :kind :floating :local-value "2017-01-01T00:59:60"
          :precision :minute)
         provider))))))

(define-foundation-test vtimezone-projects-required-observance-semantics
  (let* ((component
           (parse-timezone-component
            "TZID:America/New_York"
            "LAST-MODIFIED:20260101T000000Z"
            "TZURL:https://example.test/zones/new-york.ics"
            "BEGIN:DAYLIGHT"
            "DTSTART:20260308T020000"
            "TZOFFSETFROM:-0500"
            "TZOFFSETTO:-0400"
            "TZNAME:EDT"
            "COMMENT:Summer time"
            "END:DAYLIGHT"
            "BEGIN:STANDARD"
            "DTSTART:20261101T020000"
            "TZOFFSETFROM:-0400"
            "TZOFFSETTO:-0500"
            "TZNAME:EST"
            "END:STANDARD"))
         (definition (project-ical-timezone-component component))
         (daylight (first (ical-timezone-definition-observances definition))))
    (assert-true (ical-timezone-definition-valid-p definition))
    (assert-equal "America/New_York"
                  (ical-timezone-definition-timezone-id definition)
                  :test #'string=)
    (assert-equal :utc
                  (temporal-value-kind
                   (ical-timezone-definition-last-modified definition)))
    (assert-equal "https://example.test/zones/new-york.ics"
                  (ical-uri-value-original-lexeme
                   (ical-timezone-definition-url definition))
                  :test #'string=)
    (assert-equal 2 (length (ical-timezone-definition-observances definition)))
    (assert-equal :daylight (ical-timezone-observance-kind daylight))
    (assert-equal -18000 (ical-timezone-observance-offset-from daylight))
    (assert-equal -14400 (ical-timezone-observance-offset-to daylight))
    (assert-equal '("EDT") (ical-timezone-observance-names daylight))
    (assert-equal '("Summer time")
                  (ical-timezone-observance-comments daylight))))

(define-foundation-test embedded-vtimezone-resolver-detects-gaps-and-folds
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:America/New_York"
             "BEGIN:DAYLIGHT"
             "DTSTART:20260308T020000"
             "TZOFFSETFROM:-0500"
             "TZOFFSETTO:-0400"
             "END:DAYLIGHT"
             "BEGIN:STANDARD"
             "DTSTART:20261101T020000"
             "TZOFFSETFROM:-0400"
             "TZOFFSETTO:-0500"
             "END:STANDARD")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "fixture/2026a"))
         (summer
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "America/New_York" "2026-07-01T12:00:00")))
         (gap
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "America/New_York" "2026-03-08T02:30:00")))
         (fold
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "America/New_York" "2026-11-01T01:30:00"))))
    (assert-equal "fixture/2026a" (timezone-provider-version provider)
                  :test #'string=)
    (assert-equal :unique (timezone-local-resolution-status summer))
    (assert-equal -14400
                  (timezone-resolution-candidate-offset-seconds
                   (select-timezone-resolution summer)))
    (assert-equal :gap (timezone-local-resolution-status gap))
    (assert-signals 'semantic-model-error
                    (lambda () (select-timezone-resolution gap)))
    (let ((selected
            (select-timezone-resolution gap :gap-policy :rfc5545)))
      (assert-equal -18000
                    (timezone-resolution-candidate-offset-seconds selected))
      (assert-equal
       (lem-structured-notes::ical-utc-temporal-seconds
        (recurrence-test-temporal "20260308T073000Z"))
       (timezone-resolution-candidate-utc-seconds selected)))
    (assert-equal :fold (timezone-local-resolution-status fold))
    (assert-equal 2 (length (timezone-local-resolution-candidates fold)))
    (assert-signals 'semantic-model-error
                    (lambda () (select-timezone-resolution fold)))
    (assert-equal -14400
                  (timezone-resolution-candidate-offset-seconds
                   (select-timezone-resolution fold :fold 0)))
    (assert-equal -18000
                  (timezone-resolution-candidate-offset-seconds
                   (select-timezone-resolution fold :fold 1)))
    (assert-equal
     :uncovered
     (timezone-local-resolution-status
      (resolve-zoned-local-time
       provider (test-zoned-temporal
                 "America/New_York" "2026-01-01T12:00:00"))))
    (assert-equal
     :unknown-timezone
     (timezone-local-resolution-status
      (resolve-zoned-local-time
       provider (test-zoned-temporal "Unknown/Zone"
                                     "2026-07-01T12:00:00"))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (resolve-zoned-local-time
        provider (test-zoned-temporal "America/New_York"
                                      "2026-02-30T12:00:00"))))))

(define-foundation-test embedded-timezone-inverse-round-trips-folds-and-offsets
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Inverse/Zone"
             "BEGIN:STANDARD" "DTSTART:20251102T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD"
             "BEGIN:DAYLIGHT" "DTSTART:20260308T020000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0400" "END:DAYLIGHT"
             "BEGIN:STANDARD" "DTSTART:20261101T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "inverse-fixture/2026"))
         (before-gap
           (project-utc-time-to-zoned-local-time
            provider (recurrence-test-temporal "20260308T063000Z")
            "Inverse/Zone"))
         (after-gap
           (project-utc-time-to-zoned-local-time
            provider (recurrence-test-temporal "20260308T073000Z")
            "Inverse/Zone"))
         (first-fold
           (project-utc-time-to-zoned-local-time
            provider (recurrence-test-temporal "20261101T053000Z")
            "Inverse/Zone"))
         (second-fold
           (project-utc-time-to-zoned-local-time
            provider (recurrence-test-temporal "20261101T063000Z")
            "Inverse/Zone")))
    (assert-equal "2026-03-08T01:30:00"
                  (temporal-value-local-value before-gap) :test #'string=)
    (assert-equal "2026-03-08T03:30:00"
                  (temporal-value-local-value after-gap) :test #'string=)
    (assert-equal "2026-11-01T01:30:00"
                  (temporal-value-local-value first-fold) :test #'string=)
    (assert-equal 0 (temporal-value-fold first-fold))
    (assert-equal "2026-11-01T01:30:00"
                  (temporal-value-local-value second-fold) :test #'string=)
    (assert-equal 1 (temporal-value-fold second-fold))
    (dolist
        (pair
         (list
          (cons before-gap (recurrence-test-temporal "20260308T063000Z"))
          (cons after-gap (recurrence-test-temporal "20260308T073000Z"))
          (cons first-fold (recurrence-test-temporal "20261101T053000Z"))
          (cons second-fold (recurrence-test-temporal "20261101T063000Z"))))
      (let* ((temporal (car pair))
             (selected
               (select-timezone-resolution
                (resolve-zoned-local-time provider temporal)
                :fold (or (temporal-value-fold temporal) 0))))
        (assert-equal
         (lem-structured-notes::ical-utc-temporal-seconds (cdr pair))
         (timezone-resolution-candidate-utc-seconds selected))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (project-utc-time-to-zoned-local-time
        provider (recurrence-test-temporal "20250101T000000Z")
        "Inverse/Zone")))))

(define-foundation-test embedded-timezone-inverse-supports-non-hour-offset
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Asia/Kathmandu" "BEGIN:STANDARD"
             "DTSTART:20000101T000000" "TZOFFSETFROM:+0545"
             "TZOFFSETTO:+0545" "END:STANDARD")))
         (provider (make-embedded-timezone-provider (list definition)))
         (local
           (project-utc-time-to-zoned-local-time
            provider (recurrence-test-temporal "20000101T000000Z")
            "Asia/Kathmandu")))
    (assert-equal "2000-01-01T05:45:00"
                  (temporal-value-local-value local) :test #'string=)))

(define-foundation-test vtimezone-supports-non-hour-offsets
  (dolist (specification
           '(("Asia/Kathmandu" "+0545" 20700)
             ("Australia/Darwin" "+0930" 34200)))
    (destructuring-bind (timezone-id offset seconds) specification
      (let* ((definition
               (project-ical-timezone-component
                (parse-timezone-component
                 (format nil "TZID:~a" timezone-id)
                 "BEGIN:STANDARD"
                 "DTSTART:20000101T000000"
                 (format nil "TZOFFSETFROM:~a" offset)
                 (format nil "TZOFFSETTO:~a" offset)
                 "END:STANDARD")))
             (observance
               (first (ical-timezone-definition-observances definition))))
        (assert-true (ical-timezone-definition-valid-p definition))
        (assert-equal seconds
                      (ical-timezone-observance-offset-to observance))))))

(define-foundation-test recurring-vtimezone-observances-expand-boundedly
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Recurring/Test"
             "BEGIN:STANDARD"
             "DTSTART:20261025T020000"
             "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"
             "TZOFFSETFROM:+0100"
             "TZOFFSETTO:+0000"
             "END:STANDARD")))
         (provider (make-embedded-timezone-provider (list definition)))
         (resolution
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "Recurring/Test" "2026-12-01T12:00:00"))))
    (assert-equal :unique
                  (timezone-local-resolution-status resolution))
    (assert-equal 0
                  (timezone-resolution-candidate-offset-seconds
                   (select-timezone-resolution resolution))))
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Future-Observance/Test"
             "BEGIN:STANDARD" "DTSTART:20261025T020000"
             "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0000" "END:STANDARD"
             "BEGIN:DAYLIGHT" "DTSTART:20260329T010000"
             "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"
             "TZOFFSETFROM:+0000" "TZOFFSETTO:+0100" "END:DAYLIGHT")))
         (provider (make-embedded-timezone-provider (list definition)))
         (resolution
           (resolve-zoned-local-time
            provider
            (test-zoned-temporal
             "Future-Observance/Test" "2026-07-01T12:00:00"))))
    (assert-equal :unique (timezone-local-resolution-status resolution))
    (assert-equal
     3600
     (timezone-resolution-candidate-offset-seconds
      (select-timezone-resolution resolution)))))

(define-foundation-test recurring-vtimezone-resolves-annual-gaps-and-folds
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Annual/Test"
             "BEGIN:DAYLIGHT" "DTSTART:19700329T020000"
             "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"
             "TZOFFSETFROM:+0000" "TZOFFSETTO:+0100" "END:DAYLIGHT"
             "BEGIN:STANDARD" "DTSTART:19701025T030000"
             "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0000" "END:STANDARD")))
         (provider (make-embedded-timezone-provider (list definition)))
         (summer
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "Annual/Test" "2026-07-01T12:00:00")))
         (gap
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "Annual/Test" "2026-03-29T02:30:00")))
         (fold
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "Annual/Test" "2026-10-25T02:30:00"))))
    (assert-equal 3600
                  (timezone-resolution-candidate-offset-seconds
                   (select-timezone-resolution summer)))
    (assert-equal :gap (timezone-local-resolution-status gap))
    (assert-equal :fold (timezone-local-resolution-status fold))
    (assert-equal 3600
                  (timezone-resolution-candidate-offset-seconds
                   (select-timezone-resolution fold :fold 0)))
    (assert-equal 0
                  (timezone-resolution-candidate-offset-seconds
                   (select-timezone-resolution fold :fold 1)))))

(define-foundation-test recurring-vtimezone-enforces-transition-limits
  (let ((definition
          (project-ical-timezone-component
           (parse-timezone-component
            "TZID:Bounded/Test"
            "BEGIN:STANDARD" "DTSTART:20000101T000000"
            "RRULE:FREQ=YEARLY"
            "TZOFFSETFROM:+0000" "TZOFFSETTO:+0000" "END:STANDARD"))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (let ((provider
               (make-embedded-timezone-provider
                (list definition) :max-transition-periods 2)))
         (resolve-zoned-local-time
          provider (test-zoned-temporal
                    "Bounded/Test" "2030-01-02T00:00:00")))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (make-embedded-timezone-provider
        (list definition) :max-transition-candidates 0))))
  (let ((definition
          (project-ical-timezone-component
           (parse-timezone-component
            "TZID:Aggregate/Test"
            "BEGIN:STANDARD" "DTSTART:20200101T000000"
            "RDATE:20210101T000000"
            "TZOFFSETFROM:+0000" "TZOFFSETTO:+0000" "END:STANDARD"
            "BEGIN:DAYLIGHT" "DTSTART:20200601T000000"
            "RDATE:20210601T000000"
            "TZOFFSETFROM:+0000" "TZOFFSETTO:+0100" "END:DAYLIGHT"))))
    (dolist (arguments
             '((:max-transition-candidates 3)
               (:max-transitions 3)))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (let ((provider
                 (apply #'make-embedded-timezone-provider
                        (list definition) arguments)))
           (resolve-zoned-local-time
            provider (test-zoned-temporal
                      "Aggregate/Test" "2022-01-01T00:00:00"))))))))

(define-foundation-test recurring-vtimezone-until-is-compared-in-utc
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Until/Test"
             "BEGIN:STANDARD" "DTSTART:20200101T000000"
             "RRULE:FREQ=YEARLY;UNTIL=20201231T230000Z"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0000" "END:STANDARD")))
         (limit
           (lem-structured-notes::ical-local-temporal-seconds
            (test-zoned-temporal "Until/Test" "2025-01-01T00:00:00"))))
    (multiple-value-bind (transitions recurrence-required-p)
        (lem-structured-notes::ical-timezone-transitions
         definition limit 100 10000 100)
      (assert-false recurrence-required-p)
      (assert-equal 2 (length transitions)))))

(define-foundation-test invalid-vtimezone-invariants-fail-closed
  (dolist
      (body
       '(("BEGIN:STANDARD" "DTSTART:20260101T000000"
          "TZOFFSETFROM:+0000" "TZOFFSETTO:+0000" "END:STANDARD")
         ("TZID:No-Observance")
         ("TZID:Missing-Offset" "BEGIN:STANDARD"
          "DTSTART:20260101T000000" "TZOFFSETTO:+0000" "END:STANDARD")
         ("TZID:UTC-Start" "BEGIN:STANDARD"
          "DTSTART:20260101T000000Z" "TZOFFSETFROM:+0000"
          "TZOFFSETTO:+0100" "END:STANDARD")
         ("TZID:Bad-Modified" "LAST-MODIFIED:20260101T000000"
          "BEGIN:STANDARD" "DTSTART:20260101T000000"
          "TZOFFSETFROM:+0000" "TZOFFSETTO:+0000" "END:STANDARD")
         ("TZID:UTC-Rdate" "BEGIN:STANDARD"
          "DTSTART:20260101T000000" "RDATE:20270101T000000Z"
          "TZOFFSETFROM:+0000" "TZOFFSETTO:+0000" "END:STANDARD")
         ("TZID:Duplicate-Rule" "BEGIN:STANDARD"
          "DTSTART:20260101T000000" "RRULE:FREQ=YEARLY"
          "RRULE:FREQ=MONTHLY" "TZOFFSETFROM:+0000"
          "TZOFFSETTO:+0000" "END:STANDARD")))
    (let ((definition
            (project-ical-timezone-component
             (apply #'parse-timezone-component body))))
      (assert-false (ical-timezone-definition-valid-p definition))
      (assert-true (ical-timezone-definition-diagnostics definition)))))

(define-foundation-test embedded-timezone-provider-fails-closed-on-ambiguity
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Conflict/Test"
             "BEGIN:STANDARD" "DTSTART:20260101T000000"
             "TZOFFSETFROM:+0000" "TZOFFSETTO:+0100" "END:STANDARD"
             "BEGIN:DAYLIGHT" "DTSTART:20260101T000000"
             "TZOFFSETFROM:+0000" "TZOFFSETTO:+0200" "END:DAYLIGHT")))
         (provider (make-embedded-timezone-provider (list definition))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (make-embedded-timezone-provider (list definition definition))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (resolve-zoned-local-time
        provider (test-zoned-temporal "Conflict/Test"
                                      "2026-02-01T12:00:00"))))))
