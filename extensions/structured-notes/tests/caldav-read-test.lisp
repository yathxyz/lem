(in-package #:lem-structured-notes/tests)

(defun fixture-caldav-read-octets ()
  (ascii-octets
   (ical-crlf-lines
    "BEGIN:VCALENDAR" "PRODID:-//CalDAV Read Test//EN" "VERSION:2.0"
    "BEGIN:VEVENT" "UID:caldav-read-1" "DTSTAMP:20260724T090000Z"
    "DTSTART:20260724T100000Z" "DTEND:20260724T110000Z"
    "SUMMARY:Read boundary" "END:VEVENT" "END:VCALENDAR")))

(defun caldav-read-diagnostic-codes (outcome)
  (mapcar #'diagnostic-code (caldav-read-outcome-diagnostics outcome)))

(define-foundation-test caldav-read-validates-vjournal-resource-semantics
  (let* ((intent
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/journal.ics"))
         (body
           (ascii-octets
            (ical-crlf-lines
             "BEGIN:VCALENDAR" "PRODID:-//CalDAV Journal Test//EN"
             "VERSION:2.0" "BEGIN:VJOURNAL" "UID:caldav-journal-1"
             "DTSTAMP:20260728T090000Z" "DTSTART;VALUE=DATE:20260728"
             "STATUS:FINAL" "DESCRIPTION:Daily record"
             "END:VJOURNAL" "END:VCALENDAR")))
         (outcome
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; charset=utf-8")
              ("ETag" "\"journal-1\""))
            body)))
    (assert-equal :resource (caldav-read-outcome-kind outcome))
    (assert-false (caldav-read-outcome-diagnostics outcome))))

(define-foundation-test caldav-read-validates-vfreebusy-resource-semantics
  (let* ((intent
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/freebusy.ics"))
         (valid-body
           (ascii-octets
            (ical-crlf-lines
             "BEGIN:VCALENDAR" "PRODID:-//CalDAV Freebusy Test//EN"
             "VERSION:2.0" "BEGIN:VFREEBUSY" "UID:caldav-freebusy-1"
             "DTSTAMP:20260728T090000Z" "DTSTART:20260729T000000Z"
             "DTEND:20260730T000000Z"
             "FREEBUSY:20260729T100000Z/PT1H"
             "END:VFREEBUSY" "END:VCALENDAR")))
         (invalid-body
           (ascii-octets
            (ical-crlf-lines
             "BEGIN:VCALENDAR" "PRODID:-//CalDAV Freebusy Test//EN"
             "VERSION:2.0" "BEGIN:VFREEBUSY" "UID:caldav-freebusy-2"
             "DTSTAMP:20260728T090000Z"
             "FREEBUSY:20260729T100000/PT1H"
             "END:VFREEBUSY" "END:VCALENDAR")))
         (valid
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; charset=utf-8")
              ("ETag" "\"freebusy-1\""))
            valid-body))
         (invalid
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; charset=utf-8")
              ("ETag" "\"freebusy-2\""))
            invalid-body)))
    (assert-equal :resource (caldav-read-outcome-kind valid))
    (assert-false (caldav-read-outcome-diagnostics valid))
    (assert-true (caldav-read-outcome-diagnostics invalid))))

(define-foundation-test caldav-get-intents-and-resource-responses-are-conditional
  (let* ((body (fixture-caldav-read-octets))
         (expected-body (copy-seq body))
         (intent
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/event.ics"))
         (conditional
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/event.ics"
            :entity-tag "W/\"cached\""))
         (content-type
           "Text/Calendar; charset=\"UTF-8\"; x-note=\"semi;colon\"")
         (resource
           (classify-caldav-get-response
            intent 200
            (list (list "Content-Type" content-type)
                  (list "ETag" "\"current\"")
                  (list "Schedule-Tag" "\"schedule-current\"")
                  (list "Content-Length" (write-to-string (length body))))
            body))
         (not-modified
           (classify-caldav-get-response
            conditional 304
            '(("ETag" "\"cached\"") ("Content-Length" "4096")) #())))
    (setf (aref body 0) 0)
    (assert-equal "GET" (caldav-read-intent-method intent) :test #'string=)
    (assert-equal
     '(("Accept" "text/calendar") ("Accept-Encoding" "identity"))
     (caldav-read-intent-headers intent))
    (assert-equal
     '(("Accept" "text/calendar") ("Accept-Encoding" "identity")
       ("If-None-Match" "W/\"cached\""))
     (caldav-read-intent-headers conditional))
    (assert-equal :resource (caldav-read-outcome-kind resource))
    (assert-equal "text" (http-media-type-type
                           (caldav-read-outcome-media-type resource))
                  :test #'string=)
    (assert-equal "calendar" (http-media-type-subtype
                               (caldav-read-outcome-media-type resource))
                  :test #'string=)
    (assert-equal "UTF-8"
                  (http-media-type-parameter
                   (caldav-read-outcome-media-type resource) "charset")
                  :test #'string=)
    (assert-equal "semi;colon"
                  (http-media-type-parameter
                   (caldav-read-outcome-media-type resource) "X-NOTE")
                  :test #'string=)
    (assert-equal expected-body (caldav-read-outcome-body-octets resource)
                  :test #'equalp)
    (assert-true (ical-octet-input-document
                  (caldav-read-outcome-calendar-input resource)))
    (assert-equal "schedule-current"
                  (caldav-schedule-tag-opaque
                   (caldav-read-outcome-schedule-tag resource)))
    (assert-equal :not-modified
                  (caldav-read-outcome-kind not-modified))
    (assert-equal "cached"
                  (http-entity-tag-opaque
                   (caldav-read-outcome-entity-tag not-modified))
                  :test #'string=)))

(define-foundation-test caldav-resource-responses-enforce-media-and-byte-boundaries
  (let* ((body (fixture-caldav-read-octets))
         (intent
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/event.ics"))
         (ascii
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; charset=US-ASCII")
              ("ETag" "\"ascii\""))
            body))
         (missing-type
           (classify-caldav-get-response
            intent 200 '(("ETag" "\"missing-type\"")) body))
         (wrong-type
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "application/octet-stream")
              ("ETag" "\"wrong-type\""))
            body))
         (wrong-charset
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; charset=iso-8859-1")
              ("ETag" "\"wrong-charset\""))
            body))
         (method-parameter
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; method=PUBLISH")
              ("ETag" "\"method\""))
            body))
         (invalid-root
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar")
              ("ETag" "\"invalid-root\""))
            (ascii-octets "not a calendar")))
         (non-ascii
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; charset=us-ascii")
              ("ETag" "\"non-ascii\""))
            #(#xc3 #xa9)))
         (invalid-utf8
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar; charset=utf-8")
              ("ETag" "\"invalid-utf8\""))
            #(#xc3 #x28)))
         (coded
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar")
              ("Content-Encoding" "gzip")
              ("ETag" "\"coded\""))
            body))
         (truncated
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar")
              ("Content-Length" "1") ("ETag" "\"truncated\""))
            body))
         (oversized
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar")
              ("ETag" "\"oversized\""))
            body :max-body-octets 8)))
    (assert-equal :resource (caldav-read-outcome-kind ascii))
    (dolist (outcome
             (list missing-type wrong-type wrong-charset method-parameter
                   invalid-root non-ascii invalid-utf8 coded truncated
                   oversized))
      (assert-equal :quarantined (caldav-read-outcome-kind outcome)))
    (assert-true
     (member :missing-caldav-calendar-content-type
             (caldav-read-diagnostic-codes missing-type)))
    (assert-true
     (member :unsupported-caldav-calendar-media-type
             (caldav-read-diagnostic-codes wrong-type)))
    (assert-true
     (member :unsupported-caldav-calendar-charset
             (caldav-read-diagnostic-codes wrong-charset)))
    (assert-true
     (member :caldav-resource-content-type-method
             (caldav-read-diagnostic-codes method-parameter)))
    (assert-true
     (member :invalid-caldav-resource-root
             (caldav-read-diagnostic-codes invalid-root)))
    (assert-true
     (member :invalid-caldav-us-ascii-body
             (caldav-read-diagnostic-codes non-ascii)))
    (assert-true
     (member :invalid-icalendar-utf8
             (caldav-read-diagnostic-codes invalid-utf8)))
    (assert-equal #(#xc3 #x28)
                  (caldav-read-outcome-body-octets invalid-utf8)
                  :test #'equalp)
    (assert-true
     (member :unsupported-caldav-content-encoding
             (caldav-read-diagnostic-codes coded)))
    (assert-true
     (member :caldav-response-content-length-mismatch
             (caldav-read-diagnostic-codes truncated)))
    (assert-true
     (member :caldav-response-body-limit-exceeded
             (caldav-read-diagnostic-codes oversized)))
    (assert-false (caldav-read-outcome-body-octets oversized))))

(define-foundation-test caldav-read-response-statuses-never-trigger-hidden-network-actions
  (let* ((body (fixture-caldav-read-octets))
         (intent
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/event.ics"))
         (conditional
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/event.ics"
            :entity-tag "\"base\""))
         (missing-validator
           (classify-caldav-get-response
            intent 200 '(("Content-Type" "text/calendar")) body))
         (weak-validator
           (classify-caldav-get-response
            intent 200
            '(("Content-Type" "text/calendar")
              ("ETag" "W/\"weak\""))
            body))
         (redirect
           (classify-caldav-get-response
            intent 302
            '(("Location" "https://other.example.test/event.ics")) #()))
         (missing
           (classify-caldav-get-response intent 404 nil #()))
         (failure
           (classify-caldav-get-response intent 503 nil #())))
    (assert-equal :quarantined
                  (caldav-read-outcome-kind missing-validator))
    (assert-equal :quarantined
                  (caldav-read-outcome-kind weak-validator))
    (assert-true
     (member :caldav-get-requires-strong-etag
             (caldav-read-diagnostic-codes missing-validator)))
    (assert-equal :redirect (caldav-read-outcome-kind redirect))
    (assert-equal "https://other.example.test/event.ics"
                  (caldav-read-outcome-location redirect) :test #'string=)
    (assert-equal :missing (caldav-read-outcome-kind missing))
    (assert-equal :failure (caldav-read-outcome-kind failure))
    (dolist
        (thunk
         (list
          (lambda ()
            (classify-caldav-get-response intent 304 nil #()))
          (lambda ()
            (classify-caldav-get-response conditional 304 nil #()))
          (lambda ()
            (classify-caldav-get-response
             conditional 304 '(("ETag" "W/\"base\"")) #()))
          (lambda ()
            (classify-caldav-get-response conditional 304 nil #(1)))
          (lambda ()
            (classify-caldav-get-response
             conditional 304 '(("ETag" "\"different\"")) #()))))
      (assert-signals 'semantic-model-error thunk))))

(define-foundation-test caldav-read-never-recombines-partial-responses
  (let* ((body (fixture-caldav-read-octets))
         (intent
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/event.ics"
            :entity-tag "\"base\""))
         (unknown-unit
           (classify-caldav-get-response
            intent 206
            '(("Content-Range" "events 0-1/10")
              ("Accept-Ranges" "events"))
            body))
         (invalid-byte-range
           (classify-caldav-get-response
            intent 206
            '(("Content-Range" "bytes 100-99/100")
              ("Accept-Ranges" "bytes"))
            body)))
    (dolist (outcome (list unknown-unit invalid-byte-range))
      (assert-equal :failure (caldav-read-outcome-kind outcome))
      (assert-false (caldav-read-outcome-calendar-input outcome))
      (assert-equal body (caldav-read-outcome-body-octets outcome)
                    :test #'equalp))
    (assert-equal
     '(("Accept" "text/calendar") ("Accept-Encoding" "identity")
       ("If-None-Match" "\"base\""))
     (caldav-read-intent-headers intent))))

(define-foundation-test unsafe-caldav-read-metadata-fails-closed
  (let* ((body (fixture-caldav-read-octets))
         (intent
           (make-caldav-get-intent
            :href "https://calendar.example.test/home/event.ics")))
    (dolist
        (thunk
         (list
          (lambda ()
            (make-caldav-get-intent
             :href "http://calendar.example.test/event.ics"))
          (lambda ()
            (make-caldav-get-intent
             :href "https://user@calendar.example.test/event.ics"))
          (lambda ()
            (make-caldav-get-intent
             :href "https://calendar.example.test/event.ics#fragment"))
          (lambda () (parse-http-media-type "text"))
          (lambda () (parse-http-media-type "text/calendar; charset"))
          (lambda ()
            (parse-http-media-type
             "text/calendar; charset=utf-8; CHARSET=us-ascii"))
          (lambda ()
            (parse-http-media-type "text/calendar; note=\"unterminated"))
          (lambda ()
            (parse-http-media-type "text/calendar" :max-characters 3))
          (lambda ()
            (classify-caldav-get-response
             intent 200
             '(("Content-Type" "text/calendar")
               ("ETag" "\"one\"") ("etag" "\"two\""))
             body))
          (lambda ()
            (classify-caldav-get-response
             intent 200
             (list (list "Location"
                         (format nil "safe~c~cInjected: yes"
                                 #\Return #\Linefeed)))
             body))
          (lambda ()
            (classify-caldav-get-response
             intent 200
             '(("Content-Type" "text/calendar") ("ETag" "\"tag\""))
             body :max-header-count 1))
          (lambda ()
            (classify-caldav-get-response
             intent 200 '(("X-Long" "123456789")) body
             :max-header-octets 8))
          (lambda ()
            (classify-caldav-get-response
             intent 200 '(("Content-Length" "1, 1")) body))
          (lambda ()
            (classify-caldav-get-response intent 200 nil "not octets"))
          (lambda ()
            (classify-caldav-get-response intent 500 nil #(0 256)))))
      (assert-signals 'semantic-model-error thunk))))
