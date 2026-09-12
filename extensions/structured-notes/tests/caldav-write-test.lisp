(in-package #:lem-structured-notes/tests)

(defun fixture-caldav-write-source ()
  (ical-crlf-lines
   "BEGIN:VCALENDAR" "PRODID:-//CalDAV Write Test//EN" "VERSION:2.0"
   "BEGIN:VEVENT" "UID:caldav-write-1" "DTSTAMP:20260724T090000Z"
   "DTSTART:20260724T100000Z" "DTEND:20260724T110000Z"
   "SUMMARY:Original" "END:VEVENT" "END:VCALENDAR"))

(define-foundation-test caldav-write-admits-validated-vjournal-resources
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "PRODID:-//CalDAV Journal Test//EN"
            "VERSION:2.0" "BEGIN:VJOURNAL" "UID:caldav-journal-1"
            "DTSTAMP:20260728T090000Z" "DTSTART;VALUE=DATE:20260728"
            "DESCRIPTION:First note" "DESCRIPTION:Second note"
            "END:VJOURNAL" "END:VCALENDAR"))
         (intent
           (make-caldav-write-intent
            :operation :create
            :href "https://calendar.example.test/cal/journal.ics"
            :body source)))
    (assert-equal :create (caldav-write-intent-operation intent))
    (assert-equal source (caldav-write-intent-body intent) :test #'string=)))

(define-foundation-test caldav-write-admits-only-validated-vfreebusy-resources
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "PRODID:-//CalDAV Freebusy Test//EN"
            "VERSION:2.0" "BEGIN:VFREEBUSY" "UID:caldav-freebusy-1"
            "DTSTAMP:20260728T090000Z" "DTSTART:20260729T000000Z"
            "DTEND:20260730T000000Z"
            "FREEBUSY;FBTYPE=BUSY:20260729T100000Z/PT1H"
            "END:VFREEBUSY" "END:VCALENDAR"))
         (intent
           (make-caldav-write-intent
            :operation :create
            :href "https://calendar.example.test/cal/freebusy.ics"
            :body source)))
    (assert-equal :create (caldav-write-intent-operation intent))
    (assert-equal source (caldav-write-intent-body intent) :test #'string=))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-caldav-write-intent
      :operation :create
      :href "https://calendar.example.test/cal/invalid-freebusy.ics"
      :body
      (ical-crlf-lines
       "BEGIN:VCALENDAR" "PRODID:-//CalDAV Freebusy Test//EN"
       "VERSION:2.0" "BEGIN:VFREEBUSY" "UID:caldav-freebusy-invalid"
       "DTSTAMP:20260728T090000Z"
       "ATTENDEE;ROLE=CHAIR:mailto:guest@example.test"
       "END:VFREEBUSY" "END:VCALENDAR")))))

(define-foundation-test caldav-write-preserves-cyrus-defaultalerts-extension
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "PRODID:-//CalDAV Cyrus Extension Test//EN"
            "VERSION:2.0" "BEGIN:VEVENT" "UID:caldav-cyrus-extension-1"
            "DTSTAMP:20260801T090000Z" "DTSTART:20260801T100000Z"
            "X-JMAP-USEDEFAULTALERTS;VALUE=BOOLEAN:TRUE"
            "END:VEVENT" "END:VCALENDAR"))
         (create
           (make-caldav-write-intent
            :operation :create
            :href "https://calendar.example.test/cal/cyrus-create.ics"
            :body source))
         (update
           (make-caldav-write-intent
            :operation :update
            :href "https://calendar.example.test/cal/cyrus-update.ics"
            :entity-tag "\"revision-1\"" :schedule-tag "\"schedule-1\""
            :body source)))
    (dolist (intent (list create update))
      (assert-equal
       '("X-Cyrus-rewrite-usedefaultalerts" "false")
       (find "X-Cyrus-rewrite-usedefaultalerts"
             (caldav-write-intent-headers intent)
             :key #'first :test #'string-equal)))))

(define-foundation-test http-entity-tags-and-caldav-write-preconditions-are-exact
  (let ((strong (parse-http-entity-tag "\"revision-1\""))
        (weak (parse-http-entity-tag "W/\"revision-1\""))
        (empty (parse-http-entity-tag "\"\"")))
    (assert-true (strong-http-entity-tag-p strong))
    (assert-false (http-entity-tag-weak-p strong))
    (assert-equal "revision-1" (http-entity-tag-opaque strong)
                  :test #'string=)
    (assert-false (strong-http-entity-tag-p weak))
    (assert-true (http-entity-tag-weak-p weak))
    (assert-equal "" (http-entity-tag-opaque empty) :test #'string=))
  (let* ((source (fixture-caldav-write-source))
         (create
           (make-caldav-write-intent
            :operation :create
            :href "https://calendar.example.test/cal/new.ics"
            :body source))
         (zoned-create
           (make-caldav-write-intent
            :operation :create
            :href "https://calendar.example.test/cal/zoned.ics"
            :body
            (ical-crlf-lines
             "BEGIN:VCALENDAR" "PRODID:-//CalDAV Write Test//EN"
             "VERSION:2.0" "BEGIN:VTIMEZONE" "TZID:Europe/Dublin"
             "BEGIN:STANDARD" "DTSTART:20261025T020000"
             "TZOFFSETFROM:+0100" "TZOFFSETTO:+0000"
             "END:STANDARD" "END:VTIMEZONE" "BEGIN:VEVENT"
             "UID:caldav-write-zoned" "DTSTAMP:20260724T090000Z"
             "DTSTART;TZID=Europe/Dublin:20260724T100000"
             "END:VEVENT" "END:VCALENDAR")))
         (update
           (make-caldav-write-intent
            :operation :update
            :href "https://calendar.example.test/cal/existing.ics"
            :entity-tag "\"revision-1\"" :body source))
         (delete
           (make-caldav-write-intent
            :operation :delete
            :href "https://calendar.example.test/cal/existing.ics"
            :entity-tag "\"revision-1\""))
         (scheduling-update
           (make-caldav-write-intent
            :operation :update
            :href "https://calendar.example.test/cal/scheduled.ics"
            :entity-tag "\"revision-2\""
            :schedule-tag "\"schedule-2\"" :body source))
         (scheduling-delete
           (make-caldav-write-intent
            :operation :delete
            :href "https://calendar.example.test/cal/scheduled.ics"
            :entity-tag "\"revision-2\""
            :schedule-tag "\"schedule-2\""
            :schedule-reply :suppress)))
    (assert-equal "PUT" (caldav-write-intent-method create) :test #'string=)
    (assert-equal '(("If-None-Match" "*")
                    ("Content-Type" "text/calendar; charset=utf-8"))
                  (caldav-write-intent-headers create))
    (assert-equal :create (caldav-write-intent-operation zoned-create))
    (assert-equal '(("If-Match" "\"revision-1\"")
                    ("Content-Type" "text/calendar; charset=utf-8"))
                  (caldav-write-intent-headers update))
    (assert-equal "DELETE" (caldav-write-intent-method delete) :test #'string=)
    (assert-false (caldav-write-intent-body delete))
    (assert-equal '(("If-Match" "\"revision-1\""))
                  (caldav-write-intent-headers delete))
    (assert-equal
     '(("If-Schedule-Tag-Match" "\"schedule-2\"")
       ("Content-Type" "text/calendar; charset=utf-8"))
     (caldav-write-intent-headers scheduling-update))
    (assert-equal '(("If-Schedule-Tag-Match" "\"schedule-2\"")
                    ("Schedule-Reply" "F"))
                  (caldav-write-intent-headers scheduling-delete))
    (assert-equal :suppress
                  (caldav-write-intent-schedule-reply scheduling-delete))
    (assert-equal "schedule-2"
                  (caldav-schedule-tag-opaque
                   (caldav-write-intent-schedule-tag scheduling-update)))
    (assert-equal "\"revision-2\""
                  (http-entity-tag-raw
                   (caldav-write-intent-entity-tag scheduling-update)))))

(define-foundation-test semantic-edit-plans-bind-to-conditional-caldav-updates
  (let* ((source (fixture-caldav-write-source))
         (document nil)
         (component nil))
    (multiple-value-setq (document component)
      (parse-editable-icalendar source "caldav-plan.ics"))
    (let* ((plan
             (plan-ical-semantic-property-changes
              document component
              (list
               (make-ical-property-change
                :name "SUMMARY" :value "Conditionally changed"))))
           (current
             (parse-icalendar-cst (copy-seq source)
                                  :source-id "caldav-plan.ics"))
           (intent
             (make-caldav-update-intent-from-plan
              plan current
              :href "https://calendar.example.test/cal/existing.ics"
              :entity-tag "\"revision-2\"")))
      (assert-equal (ical-semantic-edit-plan-proposed-source plan)
                    (caldav-write-intent-body intent) :test #'string=)
      (assert-true
       (search "SUMMARY:Conditionally changed"
               (caldav-write-intent-body intent)))
      (assert-equal "\"revision-2\""
                    (http-entity-tag-raw
                     (caldav-write-intent-entity-tag intent))
                    :test #'string=))))

(define-foundation-test caldav-write-responses-never-hide-conflicts
  (let* ((source (fixture-caldav-write-source))
         (update
           (make-caldav-write-intent
            :operation :update
            :href "https://calendar.example.test/cal/existing.ics"
            :entity-tag "\"base\"" :body source))
         (success
           (classify-caldav-write-response
            update 204 '(("ETag" "\"next\""))))
         (missing-validator
           (classify-caldav-write-response update 204 nil))
         (weak-validator
           (classify-caldav-write-response
            update 200 '(("ETag" "W/\"next\""))))
         (accepted
           (classify-caldav-write-response
            update 202 '(("ETag" "\"uncommitted\""))))
         (precondition
           (classify-caldav-write-response update 412 nil))
         (resource-conflict
           (classify-caldav-write-response update 409 nil))
         (redirect
           (classify-caldav-write-response
            update 301 '(("Location" "https://other.example.test/e.ics")))))
    (assert-equal :success (caldav-write-outcome-kind success))
    (assert-false (caldav-write-outcome-refetch-required-p success))
    (assert-true (caldav-write-outcome-refetch-required-p missing-validator))
    (assert-true (caldav-write-outcome-refetch-required-p weak-validator))
    (assert-equal :accepted (caldav-write-outcome-kind accepted))
    (assert-false (caldav-write-outcome-refetch-required-p accepted))
    (dolist (outcome (list precondition resource-conflict))
      (assert-equal :conflict (caldav-write-outcome-kind outcome))
      (assert-true (caldav-write-outcome-conflict outcome)))
    (assert-equal :precondition-failed
                  (caldav-write-conflict-reason
                   (caldav-write-outcome-conflict precondition)))
    (assert-equal :resource-conflict
                  (caldav-write-conflict-reason
                   (caldav-write-outcome-conflict resource-conflict)))
    (assert-equal :redirect (caldav-write-outcome-kind redirect))
    (assert-equal "https://other.example.test/e.ics"
                  (caldav-write-outcome-location redirect) :test #'string=)))

(define-foundation-test caldav-scheduling-write-response-always-requires-refetch
  (let* ((source (fixture-caldav-write-source))
         (intent
           (make-caldav-write-intent
            :operation :update
            :href "https://calendar.example.test/cal/scheduled.ics"
            :entity-tag "\"base-etag\""
            :schedule-tag "\"base-schedule\"" :body source))
         (complete
           (classify-caldav-write-response
            intent 204
            '(("ETag" "\"next-etag\"")
              ("Schedule-Tag" "\"next-schedule\""))))
         (missing
           (classify-caldav-write-response
            intent 204 '(("ETag" "\"next-etag\"")))))
    (assert-equal :success (caldav-write-outcome-kind complete))
    (assert-true (caldav-write-outcome-refetch-required-p complete))
    (assert-equal "next-schedule"
                  (caldav-schedule-tag-opaque
                   (caldav-write-outcome-schedule-tag complete)))
    (assert-equal :success (caldav-write-outcome-kind missing))
    (assert-true (caldav-write-outcome-refetch-required-p missing))
    (assert-equal nil (caldav-write-outcome-schedule-tag missing))))

(define-foundation-test caldav-write-returned-representation-is-validated-atomically
  (let* ((href "https://calendar.example.test/cal/existing.ics")
         (sent (fixture-caldav-write-source))
         (returned
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "PRODID:-//CalDAV Write Test//EN"
            "VERSION:2.0" "BEGIN:VEVENT" "UID:caldav-write-1"
            "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
            "DTEND:20260724T110000Z" "SUMMARY:Server normalized"
            "END:VEVENT" "END:VCALENDAR"))
         (intent
           (make-caldav-write-intent
            :operation :update :href href :entity-tag "\"base\""
            :body sent :return-preference :representation))
         (headers
           '(("ETag" "\"next\"")
             ("Content-Type" "text/calendar; charset=utf-8")
             ("Content-Location" "existing.ics")
             ("Preference-Applied" "return=representation")))
         (evidence
           (classify-caldav-write-representation
            intent 200 headers
            (ascii-octets returned)))
         (valid
           (classify-caldav-write-response
            intent 200 headers
            (ascii-octets returned)))
         (ignored
           (classify-caldav-write-response
            intent 200 '(("ETag" "\"next\"")) #()))
         (invalid
           (classify-caldav-write-response
            intent 200 headers (ascii-octets "not a calendar")))
         (wrong-location
           (classify-caldav-write-representation
            intent 200
            '(("ETag" "\"next\"")
              ("Content-Type" "text/calendar")
              ("Content-Location"
               "https://calendar.example.test/cal/other.ics")
              ("Preference-Applied" "return=representation"))
            (ascii-octets returned))))
    (assert-equal :representation
                  (caldav-write-intent-return-preference intent))
    (assert-equal
     "return=representation"
     (second (find "Prefer" (caldav-write-intent-headers intent)
                   :key #'first :test #'string-equal))
     :test #'string=)
    (assert-equal :resource
                  (caldav-write-representation-evidence-kind evidence))
    (assert-true
     (search "SUMMARY:Server normalized"
             (ical-octet-input-decoded-source
              (caldav-read-outcome-calendar-input
               (caldav-write-representation-evidence-read-outcome evidence)))))
    (assert-false (caldav-write-outcome-refetch-required-p valid))
    ;; Ignoring Prefer is legal, but an explicit representation request means
    ;; the caller needs one GET before trusting server-normalized bytes.
    (assert-true (caldav-write-outcome-refetch-required-p ignored))
    ;; Claiming application with an unusable representation never skips GET.
    (assert-true (caldav-write-outcome-refetch-required-p invalid))
    (assert-equal :invalid
                  (caldav-write-representation-evidence-kind wrong-location))
    (assert-equal
     :unsupported-caldav-delete-return-representation
     (signaled-model-code
      (lambda ()
        (make-caldav-write-intent
         :operation :delete :href href :entity-tag "\"base\""
         :return-preference :representation))))))

(define-foundation-test caldav-write-412-representation-preserves-conflict
  (let* ((href "https://calendar.example.test/cal/existing.ics")
         (returned
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "PRODID:-//CalDAV Write Test//EN"
            "VERSION:2.0" "BEGIN:VEVENT" "UID:caldav-write-1"
            "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
            "DTEND:20260724T110000Z" "SUMMARY:Concurrent server state"
            "END:VEVENT" "END:VCALENDAR"))
         (octets
           (ascii-octets returned))
         (intent
           (make-caldav-write-intent
            :operation :update :href href :entity-tag "\"base\""
            :body (fixture-caldav-write-source)
            :return-preference :representation))
         (headers
           '(("ETag" "\"current\"")
             ("Content-Type" "text/calendar; charset=utf-8")
             ("Content-Location" "existing.ics")
             ("Preference-Applied" "return=representation")))
         (evidence
           (classify-caldav-write-representation
            intent 412 headers octets))
         (outcome
           (classify-caldav-write-response intent 412 headers octets)))
    (assert-equal :resource
                  (caldav-write-representation-evidence-kind evidence))
    (assert-equal :conflict (caldav-write-outcome-kind outcome))
    (assert-equal
     :precondition-failed
     (caldav-write-conflict-reason (caldav-write-outcome-conflict outcome)))
    (assert-equal "\"current\""
                  (http-entity-tag-raw
                   (caldav-write-outcome-entity-tag outcome))
                  :test #'string=)
    (assert-true
     (search
      "SUMMARY:Concurrent server state"
      (ical-octet-input-decoded-source
       (caldav-read-outcome-calendar-input
        (caldav-write-representation-evidence-read-outcome evidence)))))
    (assert-equal
     :ignored
     (caldav-write-representation-evidence-kind
      (classify-caldav-write-representation
       intent 412 '(("ETag" "\"current\"")) #())))))

(define-foundation-test unsafe-caldav-write-intents-fail-closed
  (let ((source (fixture-caldav-write-source)))
    (dolist
        (thunk
         (list
          (lambda () (parse-http-entity-tag "unquoted"))
          (lambda () (parse-http-entity-tag "w/\"lowercase\""))
          (lambda () (parse-http-entity-tag "\"bad quote\"inside\""))
          (lambda ()
            (make-caldav-write-intent
             :operation :update
             :href "https://calendar.example.test/e.ics"
             :entity-tag "W/\"weak\"" :body source))
          (lambda ()
            (make-caldav-write-intent
             :operation :delete
             :href "https://calendar.example.test/e.ics"))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics"
             :entity-tag "\"unexpected\"" :body source))
          (lambda ()
            (make-caldav-write-intent
             :operation :delete
             :href "https://calendar.example.test/e.ics"
             :entity-tag "\"base\"" :body source))
          (lambda ()
            (make-caldav-write-intent
             :operation :delete
             :href "https://calendar.example.test/e.ics"
             :entity-tag "\"base\"" :schedule-reply :notify))
          (lambda ()
            (make-caldav-write-intent
             :operation :update
             :href "https://calendar.example.test/e.ics"
             :entity-tag "\"base\"" :schedule-reply :suppress
             :body source))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "http://calendar.example.test/e.ics" :body source))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://user@calendar.example.test/e.ics" :body source))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics#fragment" :body source))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics"
             :body (ical-crlf-lines "BEGIN:VCALENDAR" "END:VCALENDAR")))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics"
             :body
             (ical-crlf-lines
              "BEGIN:VCALENDAR" "PRODID:-//Write Test//EN" "VERSION:2.0"
              "METHOD:PUBLISH" "BEGIN:VEVENT" "UID:one"
              "DTSTAMP:20260724T090000Z" "DTSTART:20260724T100000Z"
              "END:VEVENT" "END:VCALENDAR")))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics"
             :body
             (ical-crlf-lines
              "BEGIN:VCALENDAR" "PRODID:-//Write Test//EN" "VERSION:2.0"
              "BEGIN:VEVENT" "UID:one" "DTSTAMP:20260724T090000Z"
              "DTSTART:20260724T100000Z" "END:VEVENT"
              "BEGIN:VTODO" "UID:one" "DTSTAMP:20260724T090000Z"
              "DTSTART:20260724T100000Z" "END:VTODO" "END:VCALENDAR")))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics"
             :body
             (ical-crlf-lines
              "BEGIN:VCALENDAR" "PRODID:-//Write Test//EN" "VERSION:2.0"
              "BEGIN:VEVENT" "UID:one" "DTSTAMP:20260724T090000Z"
              "DTSTART:20260724T100000Z" "END:VEVENT"
              "BEGIN:VEVENT" "UID:two" "DTSTAMP:20260724T090000Z"
              "DTSTART:20260725T100000Z" "END:VEVENT" "END:VCALENDAR")))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics"
             :body
             (ical-crlf-lines
              "BEGIN:VCALENDAR" "PRODID:-//Write Test//EN" "VERSION:2.0"
              "BEGIN:VEVENT" "UID:one" "DTSTAMP:20260724T090000Z"
              "DTSTART;TZID=Europe/Dublin:20260724T100000"
              "END:VEVENT" "END:VCALENDAR")))
          (lambda ()
            (make-caldav-write-intent
             :operation :create
             :href "https://calendar.example.test/e.ics"
             :body
             (ical-crlf-lines
              "BEGIN:VCALENDAR" "PRODID:-//Write Test//EN" "VERSION:2.0"
              "BEGIN:X-UNVALIDATED" "END:X-UNVALIDATED"
              "END:VCALENDAR")))
          (lambda ()
            (let ((intent
                    (make-caldav-write-intent
                     :operation :update
                     :href "https://calendar.example.test/e.ics"
                     :entity-tag "\"base\"" :body source)))
              (classify-caldav-write-response
               intent 204 '(("ETag" "\"one\"")
                            ("etag" "\"two\"")))))
          (lambda ()
            (let ((intent
                    (make-caldav-write-intent
                     :operation :update
                     :href "https://calendar.example.test/e.ics"
                     :entity-tag "\"base\"" :body source)))
              (classify-caldav-write-response
               intent 204
               (list (list "Location"
                           (format nil "safe~c~cInjected: yes"
                                   #\Return #\Linefeed))))))
          (lambda ()
            (let ((intent
                    (make-caldav-write-intent
                     :operation :update
                     :href "https://calendar.example.test/e.ics"
                     :entity-tag "\"base\"" :body source)))
              (classify-caldav-write-response
               intent 204 '(("Bad Header" "value")))))))
      (assert-signals 'semantic-model-error thunk))))
