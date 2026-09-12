(in-package #:lem-structured-notes/tests)

(defun assert-valid-ical-value (kind raw &key timezone-id)
  (let ((value (decode-ical-value raw kind :timezone-id timezone-id)))
    (assert-true (ical-value-valid-p value))
    (assert-false (ical-value-diagnostics value))
    value))

(defun assert-invalid-ical-value (kind raw &key timezone-id)
  (let ((value (decode-ical-value raw kind :timezone-id timezone-id)))
    (assert-false (ical-value-valid-p value))
    (assert-equal raw (ical-value-raw value) :test #'string=)
    (assert-true (ical-value-diagnostics value))
    value))

(define-foundation-test icalendar-boolean-integer-and-float-values-are-typed
  (assert-true
   (ical-value-decoded (assert-valid-ical-value :boolean "true")))
  (assert-false
   (ical-value-decoded (assert-valid-ical-value :boolean "FALSE")))
  (assert-equal -2147483648
                (ical-value-decoded
                 (assert-valid-ical-value :integer "-2147483648")))
  (assert-equal 5/4
                (ical-value-decoded
                 (assert-valid-ical-value :float "+1.25")))
  (assert-equal -157/50
                (ical-value-decoded
                 (assert-valid-ical-value :float "-3.14")))
  (assert-invalid-ical-value :boolean "yes")
  (assert-invalid-ical-value :integer "2147483648")
  (assert-invalid-ical-value :integer "1.0")
  (assert-invalid-ical-value :boolean "TRUE" :timezone-id "Europe/Dublin")
  (assert-invalid-ical-value :float "1.")
  (assert-invalid-ical-value :float "NaN")
  (assert-signals
   'semantic-model-error
   (lambda ()
     (decode-ical-value "1234" :integer :max-value-characters 3))))

(define-foundation-test icalendar-binary-codec-is-canonical-and-bounded
  (dolist (example '(("" #())
                     ("Zg==" #(102))
                     ("Zm8=" #(102 111))
                     ("Zm9v" #(102 111 111))
                     ("Zm9vYg==" #(102 111 111 98))))
    (destructuring-bind (encoded expected) example
      (let ((decoded
              (ical-value-decoded
               (assert-valid-ical-value :binary encoded))))
        (assert-equal expected decoded :test #'equalp)
        (assert-equal encoded (encode-ical-binary decoded) :test #'string=))))
  (dolist (raw '("Zg=" "Zg===" "Z=g=" "Z g=" "Zh==" "Zm9="))
    (assert-invalid-ical-value :binary raw))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (decode-ical-value "Zm9v" :binary :max-binary-octets 2)))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (encode-ical-binary #(1 2 3) :max-decoded-octets 2))))

(define-foundation-test icalendar-date-time-kinds-remain-distinct
  (let* ((date
           (ical-value-decoded
            (assert-valid-ical-value :date "20240229")))
         (floating
           (ical-value-decoded
            (assert-valid-ical-value :date-time "20240724T102030")))
         (utc
           (ical-value-decoded
            (assert-valid-ical-value :date-time "20240724T102030Z")))
         (zoned
           (ical-value-decoded
            (assert-valid-ical-value
             :date-time "20240724T102030" :timezone-id "Europe/Dublin")))
         (time
           (ical-value-decoded
            (assert-valid-ical-value :time "235960Z"))))
    (assert-equal :date (temporal-value-kind date))
    (assert-equal :floating (temporal-value-kind floating))
    (assert-equal :utc (temporal-value-kind utc))
    (assert-equal :zoned (temporal-value-kind zoned))
    (assert-equal "Europe/Dublin" (temporal-value-timezone-id zoned)
                  :test #'string=)
    (assert-equal :rfc5545 (temporal-value-gap-policy zoned))
    (assert-true (ical-time-value-utc-p time))
    (assert-equal 60 (ical-time-value-second time))
    (assert-invalid-ical-value :date "20230229")
    (assert-invalid-ical-value :date-time "20240724T240000")
    (assert-invalid-ical-value
     :date-time "20240724T102030Z" :timezone-id "Europe/Dublin")
    (assert-invalid-ical-value :time "102030z")))

(define-foundation-test icalendar-utc-leap-seconds-require-pinned-history
  (multiple-value-bind (header rows)
      (read-tabular-specification "leap-second-snapshot.tsv")
    (declare (ignore header))
    (assert-equal 27 (length rows))
    (assert-equal
     (mapcar (lambda (row) (row-value "insertion_date_utc" row)) rows)
     (ical-positive-leap-second-utc-dates)
     :test #'equal)
    (assert-true
     (every (lambda (row)
              (and (string= "IERS-BULLETIN-C"
                            (row-value "source_bulletin" row))
                   (string= "2026-07-27" (row-value "snapshot_date" row))
                   (string= "2027-06-28" (row-value "expires_on" row))
                   (string= "https://data.iana.org/time-zones/tzdb/leap-seconds.list"
                            (row-value "source_uri" row))))
            rows)))
  (dolist (raw '("19720630T235960Z" "19970630T235960Z"
                 "20161231T235960Z"))
    (assert-valid-ical-value :date-time raw))
  (dolist (raw '("19970629T235960Z" "19970630T125960Z"
                 "20261231T235960Z"))
    (assert-invalid-ical-value :date-time raw))
  ;; These remain syntactically valid but need a date/timezone context before
  ;; a positive leap-second claim can be made.
  (assert-valid-ical-value :date-time "19970630T235960")
  (assert-valid-ical-value :date-time "19970630T195960"
                           :timezone-id "America/New_York")
  (assert-valid-ical-value :time "235960Z"))

(define-foundation-test standalone-icalendar-time-validates-explicit-leap-date
  (let ((leap-time
          (ical-value-decoded
           (assert-valid-ical-value :time "235960Z")))
        (ordinary-time
          (ical-value-decoded
           (assert-valid-ical-value :time "125959Z")))
        (wrong-clock-time
          (ical-value-decoded
           (assert-valid-ical-value :time "125960Z")))
        (floating-time
          (ical-value-decoded
           (assert-valid-ical-value :time "235960")))
        (leap-date
          (ical-value-decoded
           (assert-valid-ical-value :date "20161231")))
        (ordinary-date
          (ical-value-decoded
           (assert-valid-ical-value :date "20161230"))))
    (assert-equal
     leap-time
     (validate-ical-time-value-date-context leap-time leap-date))
    (assert-equal
     ordinary-time
     (validate-ical-time-value-date-context ordinary-time ordinary-date))
    (assert-equal
     :invalid-icalendar-positive-leap-second
     (signaled-model-code
      (lambda ()
        (validate-ical-time-value-date-context leap-time ordinary-date))))
    (assert-equal
     :invalid-icalendar-positive-leap-second
     (signaled-model-code
      (lambda ()
        (validate-ical-time-value-date-context wrong-clock-time leap-date))))
    (assert-equal
     :unresolved-icalendar-local-leap-second
     (signaled-model-code
      (lambda ()
        (validate-ical-time-value-date-context floating-time leap-date))))))

(define-foundation-test icalendar-text-value-codec-is-invertible
  (let* ((decoded (format nil "one, two; three: four~%five\\six"))
         (encoded "one\\, two\\; three: four\\nfive\\\\six")
         (value (assert-valid-ical-value :text encoded)))
    (assert-equal decoded (ical-value-decoded value) :test #'string=)
    (assert-equal encoded (encode-ical-text decoded) :test #'string=)
    (assert-invalid-ical-value :text "bad\\xescape")
    (assert-invalid-ical-value :text "bad\\")
    (assert-signals
     'semantic-model-error
     (lambda () (encode-ical-text (format nil "bad~c" #\Return))))))

(define-foundation-test icalendar-utc-offset-values-enforce-ranges
  (assert-equal -18000
                (ical-value-decoded
                 (assert-valid-ical-value :utc-offset "-0500")))
  (assert-equal 3661
                (ical-value-decoded
                 (assert-valid-ical-value :utc-offset "+010101")))
  (dolist (raw '("0500" "-0000" "-000000" "+2400" "+0160" "+010160"))
    (assert-invalid-ical-value :utc-offset raw)))

(define-foundation-test icalendar-uri-values-enforce-rfc3986-absolute-grammar
  (dolist (raw '("ftp://ftp.is.co.za/rfc/rfc1808.txt"
                 "http://www.ietf.org/rfc/rfc2396.txt"
                 "ldap://[2001:db8::7]/c=GB?objectClass?one"
                 "mailto:John.Doe@example.com"
                 "news:comp.infosystems.www.servers.unix"
                 "tel:+1-816-555-1212"
                 "telnet://192.0.2.16:80/"
                 "urn:oasis:names:specification:docbook:dtd:xml:4.1.2"
                 "example://user:pass@[::ffff:192.0.2.128]:8042/a%20b?q=?#f"
                 "example://[v1.a:b]/"
                 "example:"
                 "example:///path"
                 "example://"
                 "example:/"
                 "example:rootless/with:colon"
                 "example:?"
                 "example:#"))
    (assert-valid-ical-value :uri raw))
  (dolist (raw '("relative/path"
                 "1bad:value"
                 "http://[:::]/"
                 "http://[v.foo]/"
                 "http://[192.0.2.1]/"
                 "http://[2001:db8::1]suffix/"
                 "http://a@b@c/"
                 "http://host:abc/"
                 "http://host/%GG"
                 "http://host/%2G"
                 "http://host/%"
                 "http://host/a b"
                 "http://host/<"
                 "http://host/é"))
    (assert-invalid-ical-value :uri raw))
  (dolist (address '("::"
                     "::1"
                     "1::"
                     "1:2:3:4:5:6:7:8"
                     "1:2:3:4:5:6:192.0.2.1"
                     "2001:db8:0:1::1"
                     "2001:db8::192.0.2.1"))
    (assert-valid-ical-value :uri (format nil "example://[~a]/" address)))
  (dolist (address '(":"
                     ":::"
                     "1:2:3:4:5:6:7"
                     "1:2:3:4:5:6:7:8:9"
                     "1::2::3"
                     "1:2:3:4:5:6:192.0.2.01"
                     "1:2:3:4:5:6:256.0.0.1"
                     "gggg::1"))
    (assert-invalid-ical-value :uri (format nil "example://[~a]/" address)))
  ;; RFC 3986 host disambiguation treats a dotted numeric token that does not
  ;; match IPv4address as a reg-name, so this is syntactically valid.
  (assert-equal
   :reg-name
   (ical-uri-value-host-kind
    (ical-value-decoded
     (assert-valid-ical-value :uri "http://999.999.999.999/"))))
  (let* ((value
           (assert-valid-ical-value
            :cal-address "mailto:jsmith@example.com"))
         (uri (ical-value-decoded value)))
    (assert-equal :cal-address (ical-value-kind value))
    (assert-equal "mailto" (ical-uri-value-scheme uri) :test #'string=)
    (assert-equal "jsmith@example.com" (ical-uri-value-path uri)
                  :test #'string=)
    (assert-equal "mailto:jsmith@example.com"
                  (ical-uri-value-original-lexeme uri) :test #'string=))
  (let ((uri
          (ical-value-decoded
           (assert-valid-ical-value
            :uri "EXAMPLE://user@host.example:0042/path?query#fragment"))))
    (assert-equal "example" (ical-uri-value-scheme uri) :test #'string=)
    (assert-equal "user" (ical-uri-value-userinfo uri) :test #'string=)
    (assert-equal "host.example" (ical-uri-value-host uri) :test #'string=)
    (assert-equal :reg-name (ical-uri-value-host-kind uri))
    (assert-equal "0042" (ical-uri-value-port uri) :test #'string=)
    (assert-equal "/path" (ical-uri-value-path uri) :test #'string=)
    (assert-equal "query" (ical-uri-value-query uri) :test #'string=)
    (assert-equal "fragment" (ical-uri-value-fragment uri) :test #'string=)))

(define-foundation-test icalendar-duration-values-enforce-rfc5545-grammar
  (let ((combined
          (ical-value-decoded
           (assert-valid-ical-value :duration "P15DT5H0M20S")))
        (weeks
          (ical-value-decoded
           (assert-valid-ical-value :duration "+P7W")))
        (alarm
          (ical-value-decoded
           (assert-valid-ical-value :duration "-PT15M"))))
    (assert-equal 15 (ical-duration-value-days combined))
    (assert-equal 5 (ical-duration-value-hours combined))
    (assert-equal 0 (ical-duration-value-minutes combined))
    (assert-equal 20 (ical-duration-value-seconds combined))
    (assert-equal 7 (ical-duration-value-weeks weeks))
    (assert-equal -1 (ical-duration-value-sign alarm))
    (assert-equal 15 (ical-duration-value-minutes alarm)))
  (dolist (raw '("P" "PT" "P1Y" "P1WT1H" "P1DT" "PT1H20S"
                 "PT1M2H" "p1d"))
    (assert-invalid-ical-value :duration raw)))

(define-foundation-test icalendar-period-values-require-increasing-bounds
  (let* ((explicit
           (ical-value-decoded
            (assert-valid-ical-value
             :period "19970101T180000Z/19970102T070000Z")))
         (bounded
           (ical-value-decoded
            (assert-valid-ical-value
             :period "19970101T180000Z/PT5H30M")))
         (zoned
           (ical-value-decoded
            (assert-valid-ical-value
             :period "19970101T180000/19970102T070000"
             :timezone-id "Europe/Dublin"))))
    (assert-true (ical-period-value-end explicit))
    (assert-false (ical-period-value-duration explicit))
    (assert-false (ical-period-value-end bounded))
    (assert-equal :zoned
                  (temporal-value-kind (ical-period-value-start zoned)))
    (assert-equal 5
                  (ical-duration-value-hours
                   (ical-period-value-duration bounded))))
  (dolist (raw '("19970102T070000Z/19970101T180000Z"
                 "19970101T180000Z/-PT5H"
                 "19970101T180000Z/PT0S"
                 "19970101T180000Z/19970101T180000Z"
                 "19970101T180000Z//PT1H"))
    (assert-invalid-ical-value :period raw)))

(define-foundation-test icalendar-recur-values-enforce-intrinsic-constraints
  (let* ((raw
           "BYMINUTE=30;freq=yearly;INTERVAL=2;BYMONTH=1;BYDAY=SU;BYHOUR=8,9")
         (value (assert-valid-ical-value :recur raw))
         (recur (ical-value-decoded value)))
    (assert-equal :yearly (ical-recur-value-frequency recur))
    (assert-equal 2 (ical-recur-value-interval recur))
    (assert-equal '(1) (ical-recur-value-by-month recur))
    (assert-equal '(8 9) (ical-recur-value-by-hour recur))
    (assert-equal :su
                  (ical-recur-weekday-weekday
                   (first (ical-recur-value-by-day recur))))
    (assert-equal
     "FREQ=YEARLY;INTERVAL=2;BYMONTH=1;BYDAY=SU;BYHOUR=8,9;BYMINUTE=30"
     (encode-ical-recur recur) :test #'string=))
  (let ((recur
          (ical-value-decoded
           (assert-valid-ical-value
            :recur "FREQ=MONTHLY;UNTIL=20261231;BYDAY=+1MO,-1FR;WKST=SU"))))
    (assert-equal :date (temporal-value-kind (ical-recur-value-until recur)))
    (assert-equal '(1 -1)
                  (mapcar #'ical-recur-weekday-ordinal
                          (ical-recur-value-by-day recur)))
    (assert-equal :su (ical-recur-value-week-start recur))
    (assert-equal
     "FREQ=MONTHLY;UNTIL=20261231;BYDAY=+1MO,-1FR;WKST=SU"
     (encode-ical-recur recur) :test #'string=))
  (dolist (raw '("COUNT=2"
                 "FREQ=DAILY;FREQ=WEEKLY"
                 "FREQ=DAILY;COUNT=2;UNTIL=20261231"
                 "FREQ=DAILY;COUNT=0"
                 "FREQ=DAILY;INTERVAL=0"
                 "FREQ=DAILY;BYSECOND=61"
                 "FREQ=DAILY;BYMINUTE=-1"
                 "FREQ=WEEKLY;BYDAY=1MO"
                 "FREQ=YEARLY;BYWEEKNO=1;BYDAY=-1MO"
                 "FREQ=WEEKLY;BYMONTHDAY=1"
                 "FREQ=MONTHLY;BYYEARDAY=1"
                 "FREQ=MONTHLY;BYWEEKNO=1"
                 "FREQ=DAILY;BYSETPOS=1"
                 "FREQ=DAILY;BYMONTHDAY=0"
                 "FREQ=DAILY;BYMONTH=13"
                 "FREQ=DAILY;BYDAY=54MO"
                 "FREQ=DAILY;BYDAY=MO,"
                 "FREQ=DAILY;X-PART=future"
                 "FREQ=DAILY;BYMONTH=001"))
    (assert-invalid-ical-value :recur raw)))

(define-foundation-test rfc7529-recur-extensions-are-typed-but-preserve-only
  (let* ((value
           (assert-valid-ical-value
            :recur
            "FREQ=YEARLY;RSCALE=hebrew;SKIP=forward;BYMONTH=5l,13;BYYEARDAY=400"))
         (recur (ical-value-decoded value)))
    (assert-equal "HEBREW" (ical-recur-value-recurrence-scale recur)
                  :test #'string=)
    (assert-equal :forward (ical-recur-value-skip recur))
    (assert-equal '("5L" 13) (ical-recur-value-by-month recur) :test #'equal)
    (assert-equal '(400) (ical-recur-value-by-year-day recur))
    (assert-equal
     "FREQ=YEARLY;RSCALE=HEBREW;SKIP=FORWARD;BYMONTH=5L,13;BYYEARDAY=400"
     (encode-ical-recur recur) :test #'string=))
  (dolist (raw '("FREQ=YEARLY;SKIP=OMIT"
                 "FREQ=YEARLY;RSCALE=bad_name"
                 "FREQ=YEARLY;RSCALE=HEBREW;SKIP=SIDEWAYS"
                 "FREQ=YEARLY;BYMONTH=5L"
                 "FREQ=YEARLY;RSCALE=HEBREW;BYMONTH=0L"))
    (assert-invalid-ical-value :recur raw)))

(define-foundation-test typed-icalendar-values-generate-canonically
  (flet ((assert-encoding (expected value kind &optional expected-timezone-id)
           (multiple-value-bind (raw timezone-id)
               (encode-ical-value value kind)
             (assert-equal expected raw :test #'string=)
             (assert-equal expected-timezone-id timezone-id :test #'equal))))
    (let ((date
            (make-temporal-value
             :kind :date :local-value "2026-07-24"))
          (floating
            (make-temporal-value
             :kind :floating :local-value "2026-07-24T10:20:30"))
          (utc
            (make-temporal-value
             :kind :utc :local-value "2026-07-24T10:20:30Z"))
          (zoned
            (make-temporal-value
             :kind :zoned :local-value "2026-07-24T10:20:30"
             :timezone-id "Europe/Dublin")))
      (assert-encoding "20260724" date :date)
      (assert-encoding "20260724T102030" floating :date-time)
      (assert-encoding "20260724T102030Z" utc :date-time)
      (assert-encoding "20260724T102030" zoned :date-time
                       "Europe/Dublin"))
    (assert-encoding "TRUE" t :boolean)
    (assert-encoding "FALSE" nil :boolean)
    (assert-encoding "-2147483648" -2147483648 :integer)
    (assert-encoding "1.25" 5/4 :float)
    (assert-encoding "-0.001" -1/1000 :float)
    (assert-encoding
     "102030Z"
     (make-ical-time-value
      :hour 10 :minute 20 :second 30 :utc-p t)
     :time)
    (assert-encoding
     "-P2DT3H0M4S"
     (make-ical-duration-value
      :sign -1 :days 2 :hours 3 :seconds 4)
     :duration)
    (assert-encoding
     "P2W" (make-ical-duration-value :weeks 2) :duration)
    (assert-encoding
     "P0D" (make-ical-duration-value) :duration)
    (assert-encoding
     "FREQ=DAILY;COUNT=3" "count=3;freq=daily" :recur)
    (assert-encoding
     "https://example.test/events/42" "https://example.test/events/42"
     :uri)
    (assert-encoding
     "mailto:person@example.test" "mailto:person@example.test" :cal-address)
    (assert-encoding "+010101" 3661 :utc-offset)
    (assert-encoding "-0100" -3600 :utc-offset)
    (assert-encoding "one\\, two" "one, two" :text)
    (let* ((start
             (make-temporal-value
              :kind :zoned :local-value "2026-07-24T10:20:30"
              :timezone-id "Europe/Dublin"))
           (period
             (make-recurrence-period :start start :duration "PT90M")))
      (assert-encoding
       "20260724T102030/PT90M" period :period "Europe/Dublin"))))

(define-foundation-test typed-icalendar-value-generation-fails-closed
  (dolist (thunk
           (list
            (lambda () (encode-ical-value 1/3 :float))
            (lambda () (encode-ical-value 1.0 :float))
            (lambda () (encode-ical-value 2147483648 :integer))
            (lambda () (encode-ical-value "relative/path" :uri))
            (lambda () (encode-ical-value 86400 :utc-offset))
            (lambda ()
              (encode-ical-value
               (make-temporal-value
                :kind :floating :local-value "2026-07-24T10:20"
                :precision :minute)
               :date-time))
            (lambda ()
              (make-ical-time-value
               :hour 10 :minute 20 :second 30 :utc-p t
               :timezone-id "Europe/Dublin"))
            (lambda ()
              (make-ical-duration-value :weeks 1 :days 1))))
    (assert-signals 'semantic-model-error thunk)))

(define-foundation-test request-status-values-are-structured-and-invertible
  (let* ((raw
           "2.8; Success\\, repeating event ignored.;RRULE:FREQ=WEEKLY\\;INTERVAL=2")
         (value (assert-valid-ical-value :request-status raw))
         (status (ical-value-decoded value)))
    (assert-true (ical-request-status-value-p status))
    (assert-equal "2.8" (ical-request-status-value-code status)
                  :test #'string=)
    (assert-equal '("2" "8")
                  (ical-request-status-value-components status))
    (assert-equal :success (ical-request-status-value-class status))
    (assert-equal " Success, repeating event ignored."
                  (ical-request-status-value-description status)
                  :test #'string=)
    (assert-equal "RRULE:FREQ=WEEKLY;INTERVAL=2"
                  (ical-request-status-value-exception-data status)
                  :test #'string=)
    (assert-equal raw (encode-ical-request-status status) :test #'string=)
    (assert-equal raw
                  (nth-value 0 (encode-ical-value status :request-status))
                  :test #'string=))
  (dolist (case '(("01.002.0003;Pending" :preliminary-success)
                  ("3.7;Invalid calendar user" :client-error)
                  ("4.1;Event conflict" :scheduling-error)
                  ("5.1;Service-specific status" :unknown)))
    (destructuring-bind (raw expected-class) case
      (assert-equal
       expected-class
       (ical-request-status-value-class
        (ical-value-decoded
         (assert-valid-ical-value :request-status raw))))))
  (dolist (raw '("2" "2.;Missing minor" ".2;Missing major"
                 "2.a;Non-numeric" "2.0.1.3;Too deep"
                 "2.0" "2.0;Description;Exception;Extra"
                 "2.0;Bad\\qescape"))
    (assert-invalid-ical-value :request-status raw))
  (let ((empty-exception
          (make-ical-request-status-value
           :code "2.0" :description "Success" :exception-data "")))
    (assert-equal "2.0;Success;"
                  (encode-ical-request-status empty-exception)
                  :test #'string=))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-ical-request-status-value
      :code "invalid" :description "Failure"))))

(define-foundation-test unsupported-icalendar-value-types-remain-raw
  (let ((value (decode-ical-value "opaque" :future-value)))
    (assert-false (ical-value-valid-p value))
    (assert-equal "opaque" (ical-value-raw value) :test #'string=)
    (assert-equal "opaque" (ical-value-decoded value) :test #'string=)
    (assert-equal :unsupported-icalendar-value-type
                  (diagnostic-code (first (ical-value-diagnostics value))))))
