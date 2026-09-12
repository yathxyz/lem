(in-package #:lem-structured-notes/tests)

(defun series-test-item (&rest lines)
  (project-ical-component
   (apply #'parse-first-ical-item-component lines)
   :method-present-p t))

(defun series-test-master ()
  (series-test-item
   "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260701T000000Z"
   "DTSTART:20260724T090000Z" "DTEND:20260724T100000Z"
   "RRULE:FREQ=DAILY;COUNT=5"
   "EXDATE:20260727T090000Z" "END:VEVENT"))

(defun series-test-window-start ()
  (recurrence-test-temporal "20260724T000000Z"))

(defun series-test-window-end ()
  (recurrence-test-temporal "20260730T000000Z"))

(define-foundation-test rfc7529-rscale-family-is-rejected-coherently
  (let* ((master
           (series-test-item
            "BEGIN:VEVENT" "UID:rscale-family" "DTSTAMP:20260701T000000Z"
            "DTSTART:20260724T090000Z"
            "RRULE:FREQ=YEARLY;RSCALE=HEBREW;SKIP=FORWARD"
            "END:VEVENT"))
         (first-override
           (series-test-item
            "BEGIN:VEVENT" "UID:rscale-family" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID:20270713T090000Z"
            "DTSTART:20270714T090000Z" "END:VEVENT"))
         (second-override
           (series-test-item
            "BEGIN:VEVENT" "UID:rscale-family" "DTSTAMP:20260703T000000Z"
            "RECURRENCE-ID:20280702T090000Z" "STATUS:CANCELLED"
            "END:VEVENT"))
         (ordinary
           (series-test-item
            "BEGIN:VEVENT" "UID:ordinary" "DTSTAMP:20260701T000000Z"
            "DTSTART:20260725T090000Z" "SUMMARY:Still usable"
            "END:VEVENT")))
    (multiple-value-bind (accepted rejections)
        (classify-ical-rscale-component-families
         (list master first-override second-override ordinary))
      (assert-equal (list ordinary) accepted :test #'equal)
      (assert-equal 1 (length rejections))
      (let ((rejection (first rejections)))
        (assert-equal "rscale-family"
                      (ical-rscale-family-rejection-uid rejection)
                      :test #'string=)
        (assert-equal :event (ical-rscale-family-rejection-kind rejection))
        (assert-equal "HEBREW"
                      (ical-rscale-family-rejection-recurrence-scale rejection)
                      :test #'string=)
        (assert-equal (list master first-override second-override)
                      (ical-rscale-family-rejection-items rejection)
                      :test #'equal)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-recurrence-series
        master (list first-override second-override)
        :window-start (recurrence-test-temporal "20260101T000000Z")
        :window-end (recurrence-test-temporal "20290101T000000Z"))))))

(define-foundation-test detached-overrides-preserve-original-instance-identity
  (let* ((master (series-test-master))
         (moved
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID:20260725T090000Z"
            "DTSTART:20260725T150000Z" "SUMMARY:Moved" "END:VEVENT"))
         (cancelled
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260703T000000Z"
            "RECURRENCE-ID:20260726T090000Z" "STATUS:CANCELLED"
            "END:VEVENT"))
         (excluded-but-overridden
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260704T000000Z"
            "RECURRENCE-ID:20260727T090000Z"
            "DTSTART:20260727T120000Z" "END:VEVENT"))
         (series
           (expand-ical-recurrence-series
            master (list moved cancelled excluded-but-overridden)
            :window-start (series-test-window-start)
            :window-end (series-test-window-end)))
         (instances (ical-recurrence-series-expansion-instances series)))
    (assert-equal "series-1" (ical-recurrence-series-expansion-uid series)
                  :test #'string=)
    (assert-equal
     '(:generated :overridden :cancelled :overridden :generated)
     (mapcar #'ical-recurrence-instance-status instances))
    (assert-equal
     '("2026-07-24T09:00:00Z" "2026-07-25T09:00:00Z"
       "2026-07-26T09:00:00Z" "2026-07-27T09:00:00Z"
       "2026-07-28T09:00:00Z")
     (mapcar (lambda (instance)
               (temporal-value-local-value
                (ical-recurrence-instance-recurrence-id instance)))
             instances))
    (assert-equal "2026-07-25T15:00:00Z"
                  (temporal-value-local-value
                   (ical-recurrence-instance-actual-start
                    (second instances)))
                  :test #'string=)
    (assert-false
     (ical-recurrence-instance-actual-start (third instances)))
    (assert-equal "2026-07-27T12:00:00Z"
                  (temporal-value-local-value
                   (ical-recurrence-instance-actual-start
                    (fourth instances)))
                  :test #'string=)))

(define-foundation-test detached-recurrence-id-normalizes-proven-local-leap
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "series-recurrence-id-leap/1"))
         (zoned-master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-leap-override"
            "DTSTAMP:20161201T000000Z"
            "DTSTART;TZID=Leap/Plus-One:20161230T005959"
            "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
         (zoned-override
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-leap-override"
            "DTSTAMP:20161202T000000Z" "SEQUENCE:2"
            "RECURRENCE-ID;TZID=Leap/Plus-One:20170101T005960"
            "SUMMARY:Leap override" "END:VEVENT"))
         (zoned-older
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-leap-override"
            "DTSTAMP:20161201T120000Z" "SEQUENCE:1"
            "RECURRENCE-ID;TZID=Leap/Plus-One:20170101T005959"
            "SUMMARY:Superseded ordinary-second revision" "END:VEVENT"))
         (zoned-window-start
           (recurrence-test-temporal "20161230T000000" "Leap/Plus-One"))
         (zoned-window-end
           (recurrence-test-temporal "20170102T000000" "Leap/Plus-One"))
         (zoned-instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             zoned-master (list zoned-older zoned-override)
             :window-start zoned-window-start :window-end zoned-window-end
             :timezone-provider provider)))
         (floating-master
           (series-test-item
            "BEGIN:VEVENT" "UID:floating-leap-override"
            "DTSTAMP:20161201T000000Z" "DTSTART:20161230T005959"
            "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
         (floating-override
           (series-test-item
            "BEGIN:VEVENT" "UID:floating-leap-override"
            "DTSTAMP:20161202T000000Z"
            "RECURRENCE-ID:20170101T005960"
            "SUMMARY:Floating leap override" "END:VEVENT"))
         (floating-window-start
           (recurrence-test-temporal "20161230T000000"))
         (floating-window-end
           (recurrence-test-temporal "20170102T000000"))
         (floating-instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             floating-master (list floating-override)
             :window-start floating-window-start
             :window-end floating-window-end
             :timezone-provider provider
             :floating-timezone-id "Leap/Plus-One"))))
    (dolist (instances (list zoned-instances floating-instances))
      (assert-equal
       '(:generated :generated :overridden)
       (mapcar #'ical-recurrence-instance-status instances))
      (assert-equal
       "2017-01-01T00:59:59"
       (temporal-value-local-value
        (ical-recurrence-instance-recurrence-id (third instances)))
       :test #'string=)
      (assert-equal
       "2017-01-01T00:59:59"
       (temporal-value-local-value
        (ical-recurrence-instance-actual-start (third instances)))
       :test #'string=))
    (assert-equal
     "2017-01-01T00:59:60"
     (temporal-value-local-value
      (ical-calendar-item-recurrence-id zoned-override))
     :test #'string=)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-recurrence-series
        zoned-master (list zoned-older zoned-override)
        :window-start zoned-window-start :window-end zoned-window-end)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-recurrence-series
        floating-master (list floating-override)
        :window-start floating-window-start :window-end floating-window-end
        :timezone-provider provider)))))

(define-foundation-test series-exdate-normalizes-proven-local-leap
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "series-exdate-leap/1"))
         (master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-leap-exdate"
            "DTSTAMP:20161201T000000Z"
            "DTSTART;TZID=Leap/Plus-One:20161230T005959"
            "RRULE:FREQ=DAILY;COUNT=3"
            "EXDATE;TZID=Leap/Plus-One:20170101T005960"
            "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master nil
             :window-start
             (recurrence-test-temporal "20161230T000000" "Leap/Plus-One")
             :window-end
             (recurrence-test-temporal "20170102T000000" "Leap/Plus-One")
             :timezone-provider provider))))
    (assert-equal
     '("2016-12-30T00:59:59" "2016-12-31T00:59:59")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-recurrence-id instance)))
      instances))))

(define-foundation-test ranged-recurrence-id-normalizes-proven-local-leap
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "series-range-leap/1"))
         (master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-leap-range"
            "DTSTAMP:20161201T000000Z"
            "DTSTART;TZID=Leap/Plus-One:20161230T005959"
            "RRULE:FREQ=DAILY;COUNT=4" "END:VEVENT"))
         (range
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-leap-range"
            "DTSTAMP:20161202T000000Z"
            "RECURRENCE-ID;TZID=Leap/Plus-One;RANGE=THISANDFUTURE:20170101T005960"
            "DTSTART;TZID=Leap/Plus-One:20170101T015959"
            "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master (list range)
             :window-start
             (recurrence-test-temporal "20161230T000000" "Leap/Plus-One")
             :window-end
             (recurrence-test-temporal "20170103T000000" "Leap/Plus-One")
             :timezone-provider provider))))
    (assert-equal
     '(:generated :generated :overridden :range-overridden)
     (mapcar #'ical-recurrence-instance-status instances))
    (assert-equal
     '("2016-12-30T00:59:59" "2016-12-31T00:59:59"
       "2017-01-01T00:59:59" "2017-01-02T00:59:59")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-recurrence-id instance)))
      instances))
    (assert-equal
     '("2016-12-30T00:59:59" "2016-12-31T00:59:59"
       "2017-01-01T01:59:59" "2017-01-02T01:59:59")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-start instance)))
      instances))))

(define-foundation-test series-normalizes-leap-finish-before-duration-use
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "series-finish-leap/1"))
         (master
           (series-test-item
            "BEGIN:VEVENT" "UID:floating-leap-finish"
            "DTSTAMP:20161201T000000Z" "DTSTART:20170101T005959"
            "DTEND:20170101T005960" "END:VEVENT"))
         (window-start (recurrence-test-temporal "20170101T000000"))
         (window-end (recurrence-test-temporal "20170102T000000"))
         (instance
           (first
            (ical-recurrence-series-expansion-instances
             (expand-ical-recurrence-series
              master nil :window-start window-start :window-end window-end
              :timezone-provider provider
              :floating-timezone-id "Leap/Plus-One")))))
    (assert-equal
     0
     (ical-effective-duration-seconds
      (ical-recurrence-instance-effective-duration instance)))
    (assert-equal
     "2017-01-01T00:59:59"
     (temporal-value-local-value
      (ical-recurrence-instance-actual-finish instance))
     :test #'string=)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-recurrence-series
        master nil :window-start window-start :window-end window-end
        :timezone-provider provider)))))

(define-foundation-test series-normalizes-leap-actual-start-and-windows
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "series-window-leap/1"))
         (master
           (series-test-item
            "BEGIN:VEVENT" "UID:floating-leap-window"
            "DTSTAMP:20161201T000000Z" "DTSTART:20161230T005959"
            "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
         (override
           (series-test-item
            "BEGIN:VEVENT" "UID:floating-leap-window"
            "DTSTAMP:20161202T000000Z"
            "RECURRENCE-ID:20170101T005959"
            "DTSTART:20170101T005960" "END:VEVENT"))
         (leap-bound (recurrence-test-temporal "20170101T005960"))
         (end-bound (recurrence-test-temporal "20170102T000000"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master (list override)
             :window-start leap-bound :window-end end-bound
             :display-window-start leap-bound :display-window-end end-bound
             :timezone-provider provider
             :floating-timezone-id "Leap/Plus-One"))))
    (assert-equal 1 (length instances))
    (assert-equal :overridden
                  (ical-recurrence-instance-status (first instances)))
    (assert-equal
     "2017-01-01T00:59:59"
     (temporal-value-local-value
      (ical-recurrence-instance-actual-start (first instances)))
     :test #'string=)
    (assert-equal
     "2017-01-01T00:59:60"
     (temporal-value-local-value (ical-calendar-item-start override))
     :test #'string=)))

(define-foundation-test detached-override-window-uses-recurrence-identity
  (let* ((master (series-test-master))
         (moved
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID:20260725T090000Z"
            "DTSTART:20260820T150000Z" "END:VEVENT"))
         (series
           (expand-ical-recurrence-series
            master (list moved)
            :window-start (series-test-window-start)
            :window-end (series-test-window-end)))
         (instance
           (second (ical-recurrence-series-expansion-instances series))))
    (assert-equal :overridden (ical-recurrence-instance-status instance))
    (assert-equal "2026-08-20T15:00:00Z"
                  (temporal-value-local-value
                   (ical-recurrence-instance-actual-start instance))
                  :test #'string=)))

(define-foundation-test actual-start-display-window-includes-moved-instances
  (let* ((master
           (series-test-item
            "BEGIN:VEVENT" "UID:display-series" "DTSTAMP:20260701T000000Z"
            "DTSTART:20260724T090000Z" "DTEND:20260724T100000Z"
            "RRULE:FREQ=DAILY;COUNT=6" "END:VEVENT"))
         (moved-from-before
           (series-test-item
            "BEGIN:VEVENT" "UID:display-series" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID:20260724T090000Z"
            "DTSTART:20260726T000000Z" "END:VEVENT"))
         (moved-out
           (series-test-item
            "BEGIN:VEVENT" "UID:display-series" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID:20260725T090000Z"
            "DTSTART:20260727T000000Z" "END:VEVENT"))
         (moved-from-after
           (series-test-item
            "BEGIN:VEVENT" "UID:display-series" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID:20260728T090000Z"
            "DTSTART:20260726T080000Z" "END:VEVENT"))
         (cancelled
           (series-test-item
            "BEGIN:VEVENT" "UID:display-series" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID:20260729T090000Z" "STATUS:CANCELLED"
            "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master
             (list moved-from-before moved-out moved-from-after cancelled)
             :window-start (recurrence-test-temporal "20260724T000000Z")
             :window-end (recurrence-test-temporal "20260730T000000Z")
             :display-window-start
             (recurrence-test-temporal "20260726T000000Z")
             :display-window-end
             (recurrence-test-temporal "20260727T000000Z")))))
    (assert-equal
     '("2026-07-26T00:00:00Z" "2026-07-26T08:00:00Z"
       "2026-07-26T09:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-start instance)))
      instances))
    (assert-equal
     '("2026-07-24T09:00:00Z" "2026-07-28T09:00:00Z"
       "2026-07-26T09:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-recurrence-id instance)))
      instances))
    (assert-equal
     '(:overridden :overridden :generated)
     (mapcar #'ical-recurrence-instance-status instances))))

(define-foundation-test zoned-display-window-distinguishes-fold-instants
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Display/Zone"
             "BEGIN:DAYLIGHT" "DTSTART:20250309T020000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0400" "END:DAYLIGHT"
             "BEGIN:STANDARD" "DTSTART:20251102T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "display-fixture/2025"))
         (master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-display" "DTSTAMP:20251001T000000Z"
            "DTSTART;TZID=Display/Zone:20251031T013000"
            "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
         (range
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-display" "DTSTAMP:20251002T000000Z"
            "RECURRENCE-ID;TZID=Display/Zone;RANGE=THISANDFUTURE:20251101T013000"
            "DTSTART;TZID=Display/Zone:20251101T023000" "END:VEVENT"))
         (second-fold-start
           (project-utc-time-to-zoned-local-time
            provider (recurrence-test-temporal "20251102T063000Z")
            "Display/Zone"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master (list range)
             :window-start
             (recurrence-test-temporal "20251101T000000" "Display/Zone")
             :window-end
             (recurrence-test-temporal "20251103T000000" "Display/Zone")
             :display-window-start second-fold-start
             :display-window-end
             (recurrence-test-temporal "20251102T020000" "Display/Zone")
             :timezone-provider provider))))
    (assert-equal 1 (length instances))
    (assert-equal
     "2025-11-02T01:30:00"
     (temporal-value-local-value
      (ical-recurrence-instance-actual-start (first instances)))
     :test #'string=)
    (assert-equal
     1
     (temporal-value-fold
      (ical-recurrence-instance-actual-start (first instances))))))

(define-foundation-test invalid-series-display-window-fails-closed
  (let ((master (series-test-master)))
    (flet ((failure-code (&rest arguments)
             (semantic-model-error-code
              (assert-signals
               'semantic-model-error
               (lambda ()
                 (apply #'expand-ical-recurrence-series
                        master nil
                        :window-start (series-test-window-start)
                        :window-end (series-test-window-end)
                        arguments))))))
      (assert-equal
       :incomplete-series-display-window
       (failure-code
        :display-window-start
        (recurrence-test-temporal "20260725T000000Z")))
      (assert-equal
       :invalid-series-display-window
       (failure-code
        :display-window-start
        (recurrence-test-temporal "20260725T000000Z")
        :display-window-end
        (recurrence-test-temporal "20260725T000000Z")))
      (assert-equal
       :invalid-series-display-window
       (failure-code
        :display-window-start
        (recurrence-test-temporal "20260726T000000Z")
        :display-window-end
        (recurrence-test-temporal "20260725T000000Z")))
      (assert-equal
       :incompatible-recurrence-temporal
       (failure-code
        :display-window-start
        (recurrence-test-temporal "20260725T000000")
        :display-window-end
        (recurrence-test-temporal "20260726T000000"))))))

(define-foundation-test thisandfuture-propagates-by-recurrence-identity
  (let* ((master (series-test-master))
         (ranged
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260725T090000Z"
            "DTSTART:20260725T110000Z" "DTEND:20260725T130000Z"
            "END:VEVENT"))
         (exact
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260703T000000Z"
            "RECURRENCE-ID:20260727T090000Z"
            "DTSTART:20260727T160000Z" "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master (list ranged exact)
             :window-start (series-test-window-start)
             :window-end (series-test-window-end)))))
    (assert-equal
     '(:generated :overridden :range-overridden :overridden
       :range-overridden)
     (mapcar #'ical-recurrence-instance-status instances))
    (assert-equal
     '("2026-07-24T09:00:00Z" "2026-07-25T11:00:00Z"
       "2026-07-26T11:00:00Z" "2026-07-27T16:00:00Z"
       "2026-07-28T11:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-start instance)))
      instances))
    (assert-equal
     '(3600 7200 7200 3600 7200)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-seconds
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '(:exact :exact :exact :exact :exact)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-kind
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '("2026-07-24T10:00:00Z" "2026-07-25T13:00:00Z"
       "2026-07-26T13:00:00Z" "2026-07-27T17:00:00Z"
       "2026-07-28T13:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances)))
  ;; RFC 5545 treats second 60 as equivalent to second 59.  Normalizing both
  ;; endpoints therefore exposes this otherwise lexical-looking interval as
  ;; non-positive.
  (let ((collapsed
          (series-test-item
           "BEGIN:VEVENT" "UID:period-collapsed-leap-endpoint"
           "DTSTAMP:20161201T000000Z" "DTSTART:20161230T235959Z"
           "RDATE;VALUE=PERIOD:20161231T235959Z/20161231T235960Z"
           "END:VEVENT")))
    (assert-equal
     :non-positive-rdate-period-duration
     (semantic-model-error-code
      (assert-signals
       'semantic-model-error
       (lambda ()
         (expand-ical-recurrence-series
          collapsed nil
          :window-start (recurrence-test-temporal "20161230T000000Z")
          :window-end (recurrence-test-temporal "20170101T000000Z"))))))))

(define-foundation-test thisandfuture-cancellation-propagates-with-exact-exception
  (let* ((master (series-test-master))
         (ranged-cancellation
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260725T090000Z"
            "STATUS:CANCELLED" "END:VEVENT"))
         (exact
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260703T000000Z"
            "RECURRENCE-ID:20260727T090000Z"
            "DTSTART:20260727T160000Z" "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master (list ranged-cancellation exact)
             :window-start (series-test-window-start)
             :window-end (series-test-window-end)))))
    (assert-equal
     '(:generated :cancelled :cancelled :overridden :cancelled)
     (mapcar #'ical-recurrence-instance-status instances))))

(define-foundation-test thisandfuture-supports-date-and-floating-start-deltas
  (flet ((expanded-starts (master override window-start window-end)
           (mapcar
            (lambda (instance)
              (temporal-value-local-value
               (ical-recurrence-instance-actual-start instance)))
            (ical-recurrence-series-expansion-instances
             (expand-ical-recurrence-series
              master (list override)
              :window-start window-start :window-end window-end)))))
    (let ((date-master
            (series-test-item
             "BEGIN:VEVENT" "UID:date-series" "DTSTAMP:20260701T000000Z"
             "DTSTART;VALUE=DATE:20260724" "DTEND;VALUE=DATE:20260725"
             "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
          (date-override
            (series-test-item
             "BEGIN:VEVENT" "UID:date-series" "DTSTAMP:20260702T000000Z"
             "RECURRENCE-ID;VALUE=DATE;RANGE=THISANDFUTURE:20260725"
             "DTSTART;VALUE=DATE:20260727" "END:VEVENT")))
      (assert-equal
       '("2026-07-24" "2026-07-27" "2026-07-28")
       (expanded-starts
        date-master date-override
        (recurrence-test-temporal "20260724")
        (recurrence-test-temporal "20260727"))))
    (let ((floating-master
            (series-test-item
             "BEGIN:VEVENT" "UID:floating-series" "DTSTAMP:20260701T000000Z"
             "DTSTART:20260724T090000" "DTEND:20260724T100000"
             "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
          (floating-override
            (series-test-item
             "BEGIN:VEVENT" "UID:floating-series" "DTSTAMP:20260702T000000Z"
             "RECURRENCE-ID;RANGE=THISANDFUTURE:20260725T090000"
             "DTSTART:20260725T103000" "END:VEVENT")))
      (assert-equal
       '("2026-07-24T09:00:00" "2026-07-25T10:30:00"
         "2026-07-26T10:30:00")
       (expanded-starts
        floating-master floating-override
        (recurrence-test-temporal "20260724T000000")
        (recurrence-test-temporal "20260727T000000"))))))

(define-foundation-test thisandfuture-preserves-nominal-duration-kind
  (let* ((master
           (series-test-item
            "BEGIN:VEVENT" "UID:nominal-series" "DTSTAMP:20260701T000000Z"
            "DTSTART:20260724T090000" "DURATION:PT1H"
            "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
         (ranged
           (series-test-item
            "BEGIN:VEVENT" "UID:nominal-series" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260725T090000"
            "DTSTART:20260725T103000" "DURATION:PT2H" "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master (list ranged)
             :window-start (recurrence-test-temporal "20260724T000000")
             :window-end (recurrence-test-temporal "20260727T000000")))))
    (assert-equal
     '(:nominal :nominal :nominal)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-kind
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '(3600 7200 7200)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-seconds
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '("2026-07-24T10:00:00" "2026-07-25T12:30:00"
       "2026-07-26T12:30:00")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances))))

(define-foundation-test zoned-recurrence-distinguishes-exact-and-nominal-duration
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Duration/Zone"
             "BEGIN:STANDARD" "DTSTART:20251102T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD"
             "BEGIN:DAYLIGHT" "DTSTART:20260308T020000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0400" "END:DAYLIGHT")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "duration-fixture/2026"))
         (window-start
           (recurrence-test-temporal "20260307T000000" "Duration/Zone"))
         (window-end
           (recurrence-test-temporal "20260309T000000" "Duration/Zone"))
         (exact-master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-exact" "DTSTAMP:20260301T000000Z"
            "DTSTART;TZID=Duration/Zone:20260307T120000"
            "DTEND;TZID=Duration/Zone:20260308T120000"
            "RRULE:FREQ=DAILY;COUNT=2" "END:VEVENT"))
         (nominal-master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-nominal" "DTSTAMP:20260301T000000Z"
            "DTSTART;TZID=Duration/Zone:20260307T120000" "DURATION:P1D"
            "RRULE:FREQ=DAILY;COUNT=2" "END:VEVENT"))
         (elapsed-master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-elapsed" "DTSTAMP:20260301T000000Z"
            "DTSTART;TZID=Duration/Zone:20260307T120000" "DURATION:PT24H"
            "RRULE:FREQ=DAILY;COUNT=2" "END:VEVENT"))
         (exact-instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             exact-master nil :window-start window-start :window-end window-end
             :timezone-provider provider)))
         (nominal-instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             nominal-master nil
             :window-start window-start :window-end window-end
             :timezone-provider provider)))
         (elapsed-instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             elapsed-master nil
             :window-start window-start :window-end window-end
             :timezone-provider provider))))
    (dolist (instance exact-instances)
      (assert-equal
       :exact
       (ical-effective-duration-kind
        (ical-recurrence-instance-effective-duration instance)))
      (assert-equal
       82800
       (ical-effective-duration-seconds
        (ical-recurrence-instance-effective-duration instance))))
    (assert-equal
     '("2026-03-08T12:00:00" "2026-03-09T11:00:00")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      exact-instances))
    (dolist (instance nominal-instances)
      (assert-equal
       :nominal
       (ical-effective-duration-kind
        (ical-recurrence-instance-effective-duration instance)))
      (assert-equal
       86400
       (ical-effective-duration-seconds
        (ical-recurrence-instance-effective-duration instance)))
      (assert-equal
       1
       (ical-effective-duration-nominal-days
        (ical-recurrence-instance-effective-duration instance)))
      (assert-equal
       0
       (ical-effective-duration-nominal-subday-seconds
        (ical-recurrence-instance-effective-duration instance))))
    (assert-equal
     '("2026-03-08T12:00:00" "2026-03-09T12:00:00")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      nominal-instances))
    (dolist (instance elapsed-instances)
      (assert-equal
       :nominal
       (ical-effective-duration-kind
        (ical-recurrence-instance-effective-duration instance)))
      (assert-equal
       0
       (ical-effective-duration-nominal-days
        (ical-recurrence-instance-effective-duration instance)))
      (assert-equal
       86400
       (ical-effective-duration-nominal-subday-seconds
        (ical-recurrence-instance-effective-duration instance))))
    (assert-equal
     '("2026-03-08T13:00:00" "2026-03-09T12:00:00")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      elapsed-instances))))

(define-foundation-test period-rdate-overrides-one-instance-duration
  (let* ((master
           (series-test-item
            "BEGIN:VEVENT" "UID:period-series" "DTSTAMP:20260701T000000Z"
            "DTSTART:20260724T090000Z" "DTEND:20260724T100000Z"
            "RRULE:FREQ=DAILY;COUNT=2"
            "RDATE;VALUE=PERIOD:20260725T090000Z/20260725T110000Z,20260726T090000Z/20260726T120000Z,20260727T090000Z/PT4H"
            "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master nil
             :window-start (recurrence-test-temporal "20260724T000000Z")
             :window-end (recurrence-test-temporal "20260728T000000Z")))))
    (assert-equal
     '("2026-07-24T09:00:00Z" "2026-07-25T09:00:00Z"
       "2026-07-26T09:00:00Z" "2026-07-27T09:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-recurrence-id instance)))
      instances))
    (assert-equal
     '(:exact :exact :exact :nominal)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-kind
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '(3600 7200 10800 14400)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-seconds
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '("2026-07-24T10:00:00Z" "2026-07-25T11:00:00Z"
       "2026-07-26T12:00:00Z" "2026-07-27T13:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances))))

(define-foundation-test period-rdate-validates-and-normalizes-leap-endpoints
  (let* ((master
           (series-test-item
            "BEGIN:VEVENT" "UID:period-leap-endpoint"
            "DTSTAMP:20161201T000000Z" "DTSTART:20161230T235959Z"
            "RDATE;VALUE=PERIOD:20161231T235960Z/20170101T000000Z"
            "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master nil
             :window-start (recurrence-test-temporal "20161230T000000Z")
             :window-end (recurrence-test-temporal "20170102T000000Z")))))
    (assert-equal
     '("2016-12-30T23:59:59Z" "2016-12-31T23:59:59Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-recurrence-id instance)))
      instances))
    (assert-equal
     '(0 1)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-seconds
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '("2016-12-30T23:59:59Z" "2017-01-01T00:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances))))

(define-foundation-test period-rdate-floating-leap-start-requires-reference-zone
  (let* ((definition
           (project-ical-timezone-component
            (parse-first-ical-item-component
             "BEGIN:VTIMEZONE" "TZID:Leap/Plus-One"
             "BEGIN:STANDARD" "DTSTART:20000101T000000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0100" "END:STANDARD"
             "END:VTIMEZONE")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "series-period-leap-fixture/1"))
         (master
           (series-test-item
            "BEGIN:VEVENT" "UID:period-local-leap"
            "DTSTAMP:20161201T000000Z"
            "DTSTART:20161230T005959"
            "RDATE;VALUE=PERIOD:20170101T005960/PT2S"
            "END:VEVENT"))
         (window-start
           (recurrence-test-temporal "20161230T000000"))
         (window-end
           (recurrence-test-temporal "20170102T000000"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master nil :window-start window-start :window-end window-end
             :timezone-provider provider
             :floating-timezone-id "Leap/Plus-One"))))
    (assert-equal
     '("2016-12-30T00:59:59" "2017-01-01T00:59:59")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-recurrence-id instance)))
      instances))
    (assert-equal
     '(:exact :nominal)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-kind
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '("2016-12-30T00:59:59" "2017-01-01T01:00:01")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (expand-ical-recurrence-series
        master nil :window-start window-start :window-end window-end
        :timezone-provider provider)))))

(define-foundation-test zoned-period-rdate-preserves-exact-and-nominal-duration
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Period/Zone"
             "BEGIN:STANDARD" "DTSTART:20251102T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD"
             "BEGIN:DAYLIGHT" "DTSTART:20260308T020000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0400" "END:DAYLIGHT")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "period-fixture/2026"))
         (master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-period" "DTSTAMP:20260301T000000Z"
            "DTSTART;TZID=Period/Zone:20260306T120000"
            "DTEND;TZID=Period/Zone:20260306T130000"
            "RDATE;TZID=Period/Zone;VALUE=PERIOD:20260307T120000/20260308T120000,20260308T120000/P1D"
            "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master nil
             :window-start
             (recurrence-test-temporal "20260306T000000" "Period/Zone")
             :window-end
             (recurrence-test-temporal "20260309T000000" "Period/Zone")
             :timezone-provider provider))))
    (assert-equal
     '(:exact :exact :nominal)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-kind
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '(3600 82800 86400)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-seconds
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '("2026-03-06T13:00:00" "2026-03-08T12:00:00"
       "2026-03-09T12:00:00")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances))))

(define-foundation-test conflicting-period-rdate-durations-fail-closed
  (let ((master
          (series-test-item
           "BEGIN:VEVENT" "UID:conflicting-period" "DTSTAMP:20260701T000000Z"
           "DTSTART:20260724T090000Z"
           "RDATE;VALUE=PERIOD:20260725T090000Z/PT1H"
           "RDATE;VALUE=PERIOD:20260725T090000Z/PT2H"
           "END:VEVENT")))
    (assert-equal
     :conflicting-rdate-period-durations
     (semantic-model-error-code
      (assert-signals
       'semantic-model-error
       (lambda ()
         (expand-ical-recurrence-series
          master nil
          :window-start (recurrence-test-temporal "20260724T000000Z")
          :window-end (recurrence-test-temporal "20260726T000000Z"))))))))

(define-foundation-test recurring-vtodo-propagates-effective-due-duration
  (let* ((master
           (series-test-item
            "BEGIN:VTODO" "UID:todo-series" "DTSTAMP:20260701T000000Z"
            "DTSTART:20260724T090000Z" "DUE:20260724T100000Z"
            "RRULE:FREQ=DAILY;COUNT=3" "END:VTODO"))
         (ranged
           (series-test-item
            "BEGIN:VTODO" "UID:todo-series" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260725T090000Z"
            "DTSTART:20260725T110000Z" "DUE:20260725T130000Z"
            "END:VTODO"))
         (series
           (expand-ical-recurrence-series
            master (list ranged)
            :window-start (recurrence-test-temporal "20260724T000000Z")
            :window-end (recurrence-test-temporal "20260727T000000Z")))
         (instances (ical-recurrence-series-expansion-instances series)))
    (assert-equal :todo (ical-recurrence-series-expansion-kind series))
    (assert-equal
     '(3600 7200 7200)
     (mapcar
      (lambda (instance)
        (ical-effective-duration-seconds
         (ical-recurrence-instance-effective-duration instance)))
      instances))
    (assert-equal
     '("2026-07-24T10:00:00Z" "2026-07-25T13:00:00Z"
       "2026-07-26T13:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances))))

(define-foundation-test prior-thisandfuture-range-applies-inside-later-window
  (let* ((master (series-test-master))
         (ranged
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
            "RECURRENCE-ID;RANGE=THISANDFUTURE:20260725T090000Z"
            "DTSTART:20260725T110000Z" "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             master (list ranged)
             :window-start (recurrence-test-temporal "20260726T000000Z")
             :window-end (series-test-window-end)))))
    (assert-equal
     '("2026-07-26T11:00:00Z" "2026-07-28T11:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-start instance)))
      instances))))

(define-foundation-test revisions-select-sequence-before-dtstamp
  (let* ((lower-sequence-newer-stamp
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260705T000000Z"
            "SEQUENCE:1" "RECURRENCE-ID:20260725T090000Z"
            "DTSTART:20260725T140000Z" "END:VEVENT"))
         (higher-sequence
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
            "SEQUENCE:2" "RECURRENCE-ID:20260725T090000Z"
            "DTSTART:20260725T120000Z" "END:VEVENT"))
         (same-sequence-later-stamp
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260703T000000Z"
            "SEQUENCE:2" "RECURRENCE-ID:20260725T090000Z"
            "DTSTART:20260725T130000Z" "END:VEVENT"))
         (other-instance
           (series-test-item
            "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260704T000000Z"
            "RECURRENCE-ID:20260726T090000Z"
            "DTSTART:20260726T150000Z" "END:VEVENT"))
         (revisions
           (list lower-sequence-newer-stamp other-instance higher-sequence
                 same-sequence-later-stamp))
         (selected (select-ical-calendar-item-revisions revisions))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             (series-test-master) revisions
             :window-start (series-test-window-start)
             :window-end (series-test-window-end)))))
    (assert-equal 2 (length selected))
    (assert-equal
     '("2026-07-25T13:00:00Z" "2026-07-26T15:00:00Z")
     (mapcar
      (lambda (item)
        (temporal-value-local-value (ical-calendar-item-start item)))
      selected))
    (assert-equal
     '("2026-07-25T13:00:00Z" "2026-07-26T15:00:00Z")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-start instance)))
      (subseq instances 1 3)))
    (let* ((older-master
             (series-test-item
              "BEGIN:VEVENT" "UID:master-revision"
              "DTSTAMP:20260705T000000Z" "SEQUENCE:1"
              "DTSTART:20260724T090000Z" "END:VEVENT"))
           (newer-master
             (series-test-item
              "BEGIN:VEVENT" "UID:master-revision"
              "DTSTAMP:20260702T000000Z" "SEQUENCE:2"
              "DTSTART:20260724T110000Z" "END:VEVENT"))
           (selected-master
             (first
              (select-ical-calendar-item-revisions
               (list older-master newer-master)))))
      (assert-equal
       "2026-07-24T11:00:00Z"
       (temporal-value-local-value
        (ical-calendar-item-start selected-master))
       :test #'string=))))

(define-foundation-test irresolvable-revision-ties-fail-closed
  (let ((left
          (series-test-item
           "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260703T000000Z"
           "SEQUENCE:2" "RECURRENCE-ID:20260725T090000Z"
           "DTSTART:20260725T120000Z" "END:VEVENT"))
        (right
          (series-test-item
           "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260703T000000Z"
           "SEQUENCE:2" "RECURRENCE-ID:20260725T090000Z"
           "DTSTART:20260725T130000Z" "END:VEVENT")))
    (assert-equal
     :ambiguous-calendar-item-revision
     (semantic-model-error-code
      (assert-signals
       'semantic-model-error
       (lambda ()
         (select-ical-calendar-item-revisions (list left right))))))))

(define-foundation-test invalid-detached-series-input-fails-closed
  (let ((master (series-test-master)))
    (dolist
        (override
         (list
          (series-test-item
           "BEGIN:VEVENT" "UID:other-series" "DTSTAMP:20260702T000000Z"
           "RECURRENCE-ID:20260725T090000Z"
           "DTSTART:20260725T120000Z" "END:VEVENT")
          (series-test-item
           "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
           "RECURRENCE-ID:20260729T090000Z"
           "DTSTART:20260729T120000Z" "END:VEVENT")
          (series-test-item
           "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
           "RECURRENCE-ID;VALUE=DATE:20260725"
           "DTSTART:20260725T120000Z" "END:VEVENT")
          (series-test-item
           "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
           "RECURRENCE-ID:20260725T090000Z" "RRULE:FREQ=DAILY;COUNT=2"
           "DTSTART:20260725T120000Z" "END:VEVENT")))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (expand-ical-recurrence-series
          master (list override)
          :window-start (series-test-window-start)
          :window-end (series-test-window-end)))))
    (let ((duplicate
            (series-test-item
             "BEGIN:VEVENT" "UID:series-1" "DTSTAMP:20260702T000000Z"
             "RECURRENCE-ID:20260725T090000Z"
             "DTSTART:20260725T120000Z" "END:VEVENT")))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (expand-ical-recurrence-series
          master (list duplicate duplicate)
          :window-start (series-test-window-start)
          :window-end (series-test-window-end)))))))

(define-foundation-test zoned-thisandfuture-propagates-across-dst
  (let* ((definition
           (project-ical-timezone-component
            (parse-timezone-component
             "TZID:Range/Zone"
             "BEGIN:STANDARD" "DTSTART:20251102T020000"
             "TZOFFSETFROM:-0400" "TZOFFSETTO:-0500" "END:STANDARD"
             "BEGIN:DAYLIGHT" "DTSTART:20260308T020000"
             "TZOFFSETFROM:-0500" "TZOFFSETTO:-0400" "END:DAYLIGHT")))
         (provider
           (make-embedded-timezone-provider
            (list definition) :version "range-fixture/2026"))
         (zoned-master
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-series" "DTSTAMP:20260301T000000Z"
            "DTSTART;TZID=Range/Zone:20260307T090000"
            "DTEND;TZID=Range/Zone:20260307T100000"
            "RRULE:FREQ=DAILY;COUNT=3" "END:VEVENT"))
         (zoned-override
           (series-test-item
            "BEGIN:VEVENT" "UID:zoned-series" "DTSTAMP:20260302T000000Z"
            "RECURRENCE-ID;TZID=Range/Zone;RANGE=THISANDFUTURE:20260307T090000"
            "DTSTART;TZID=Range/Zone:20260308T090000"
            "DTEND;TZID=Range/Zone:20260308T100000" "END:VEVENT"))
         (instances
           (ical-recurrence-series-expansion-instances
            (expand-ical-recurrence-series
             zoned-master (list zoned-override)
             :window-start
             (recurrence-test-temporal "20260307T000000" "Range/Zone")
             :window-end
             (recurrence-test-temporal "20260310T000000" "Range/Zone")
             :timezone-provider provider))))
    (assert-equal
     '("2026-03-08T09:00:00" "2026-03-09T08:00:00"
       "2026-03-10T08:00:00")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-start instance)))
      instances))
    (assert-equal
     '("2026-03-08T10:00:00" "2026-03-09T09:00:00"
       "2026-03-10T09:00:00")
     (mapcar
      (lambda (instance)
        (temporal-value-local-value
         (ical-recurrence-instance-actual-finish instance)))
      instances))))

(define-foundation-test zoned-series-arithmetic-requires-timezone-provider
  (let ((zoned-master
          (series-test-item
           "BEGIN:VEVENT" "UID:zoned-provider" "DTSTAMP:20260301T000000Z"
           "DTSTART;TZID=Range/Zone:20260307T090000"
           "RRULE:FREQ=DAILY;COUNT=2" "END:VEVENT"))
        (zoned-override
          (series-test-item
           "BEGIN:VEVENT" "UID:zoned-provider" "DTSTAMP:20260302T000000Z"
           "RECURRENCE-ID;TZID=Range/Zone;RANGE=THISANDFUTURE:20260307T090000"
           "DTSTART;TZID=Range/Zone:20260308T090000" "END:VEVENT")))
    (assert-equal
     :missing-series-timezone-provider
     (semantic-model-error-code
      (assert-signals
       'semantic-model-error
       (lambda ()
         (expand-ical-recurrence-series
          zoned-master (list zoned-override)
          :window-start
          (recurrence-test-temporal "20260307T000000" "Range/Zone")
          :window-end
          (recurrence-test-temporal "20260309T000000" "Range/Zone"))))))))
