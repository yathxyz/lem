(in-package #:lem-structured-notes/tests)

(defun parse-single-ical-property (property)
  (let* ((source (ical-crlf-lines "BEGIN:VCALENDAR" property "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "property.ics"))
         (calendar (first (ical-document-components document))))
    (first (ical-component-properties calendar))))

(defun decode-single-ical-property (property)
  (decode-ical-content-line-value (parse-single-ical-property property)))

(defun decode-single-ical-property-in-component (property component-name)
  (decode-ical-content-line-value
   (parse-single-ical-property property) :component-name component-name))

(defun decode-generated-ical-property (property-line)
  (let* ((source
           (concatenate 'string
                        (ical-crlf-lines "BEGIN:VCALENDAR")
                        property-line
                        (ical-crlf-lines "END:VCALENDAR")))
         (document (parse-icalendar-cst source :source-id "generated.ics"))
         (calendar (first (ical-document-components document))))
    (decode-ical-content-line-value
     (first (ical-component-properties calendar)))))

(defun parse-ical-presentation-component (&rest properties)
  (let* ((source
           (apply #'ical-crlf-lines
                  (append '("BEGIN:VCALENDAR" "BEGIN:VJOURNAL")
                          properties
                          '("END:VJOURNAL" "END:VCALENDAR"))))
         (document
           (parse-icalendar-cst source :source-id "presentation.ics"))
         (calendar (first (ical-document-components document))))
    (first (ical-component-children calendar))))

(define-foundation-test core-icalendar-property-defaults-select-value-types
  (let* ((summary (decode-single-ical-property "SUMMARY:Hello\\, world"))
         (priority (decode-single-ical-property "PRIORITY:5"))
         (start
           (decode-single-ical-property
            "DTSTART;TZID=Europe/Dublin:20260724T103000")))
    (assert-equal :text (ical-property-value-value-type summary))
    (assert-equal "Hello, world"
                  (ical-value-decoded
                   (first (ical-property-value-values summary)))
                  :test #'string=)
    (assert-equal 5
                  (ical-value-decoded
                   (first (ical-property-value-values priority))))
    (assert-equal :zoned
                  (temporal-value-kind
                   (ical-value-decoded
                    (first (ical-property-value-values start)))))
    (assert-true (every #'ical-property-value-valid-p
                        (list summary priority start)))))

(define-foundation-test icalendar-property-value-overrides-are-conservative
  (let ((due (decode-single-ical-property "DUE;VALUE=DATE:20260724"))
        (custom
          (decode-single-ical-property "X-COUNT;VALUE=INTEGER:42"))
        (unknown (decode-single-ical-property "X-OPAQUE:future"))
        (disallowed
          (decode-single-ical-property "DTSTART;VALUE=INTEGER:42")))
    (assert-equal :date (ical-property-value-value-type due))
    (assert-equal 42
                  (ical-value-decoded
                   (first (ical-property-value-values custom))))
    (assert-true (ical-property-value-typed-p custom))
    (assert-false (ical-property-value-typed-p unknown))
    (assert-true (ical-property-value-valid-p unknown))
    (assert-false (ical-property-value-valid-p disallowed))
    (assert-equal :disallowed-icalendar-property-value-type
                  (diagnostic-code
                   (first (ical-property-value-diagnostics disallowed))))))

(define-foundation-test icalendar-property-lists-split-after-escape-analysis
  (let* ((categories
           (decode-single-ical-property
            "CATEGORIES:Deep\\, Work,Home"))
         (values (ical-property-value-values categories)))
    (assert-true (ical-property-value-valid-p categories))
    (assert-equal 2 (length values))
    (assert-equal '("Deep, Work" "Home")
                  (mapcar #'ical-value-decoded values))))

(define-foundation-test binary-properties-require-explicit-base64-encoding
  (let ((valid
          (decode-single-ical-property
           "ATTACH;FMTTYPE=text/plain;VALUE=BINARY;ENCODING=BASE64:Zm9v"))
        (unknown-media
          (decode-single-ical-property
           "ATTACH;VALUE=BINARY;ENCODING=BASE64:YmFy"))
        (external
          (decode-single-ical-property
           "ATTACH;FMTTYPE=application/pdf:https://example.test/file.pdf"))
        (missing
          (decode-single-ical-property "ATTACH;VALUE=BINARY:Zm9v")))
    (assert-true (ical-property-value-valid-p valid))
    (assert-equal "text/plain" (ical-property-value-media-type valid)
                  :test #'string=)
    (assert-equal "text/plain" (ical-property-effective-media-type valid)
                  :test #'string=)
    (assert-equal #(102 111 111)
                  (ical-value-decoded
                   (first (ical-property-value-values valid)))
                  :test #'equalp)
    (assert-true (ical-property-value-valid-p unknown-media))
    (assert-equal "application/octet-stream"
                  (ical-property-effective-media-type unknown-media)
                  :test #'string=)
    (assert-true (ical-property-value-valid-p external))
    (assert-equal "application/pdf"
                  (ical-property-effective-media-type external)
                  :test #'string=)
    (assert-false (ical-property-value-valid-p missing))
    (assert-false (ical-property-effective-media-type missing))
    (assert-equal :missing-icalendar-binary-encoding
                  (diagnostic-code
                   (first (ical-property-value-diagnostics missing))))))

(define-foundation-test encoding-and-format-type-parameters-are-exact
  (let ((extension
          (decode-single-ical-property
           "X-TEXT;VALUE=TEXT;ENCODING=8BIT:plain"))
        (maximum-name
          (decode-single-ical-property
           (format nil "ATTACH;FMTTYPE=text/~a:https://example.test/file"
                   (make-string 127 :initial-element #\a))))
        (overlong-name
          (decode-single-ical-property
           (format nil "ATTACH;FMTTYPE=text/~a:https://example.test/file"
                   (make-string 128 :initial-element #\a)))))
    (assert-true (ical-property-value-valid-p extension))
    (assert-equal "plain"
                  (ical-value-decoded
                   (first (ical-property-value-values extension)))
                  :test #'string=)
    (assert-true (ical-property-value-valid-p maximum-name))
    (assert-false (ical-property-value-valid-p overlong-name)))
  (dolist
      (line
       '("X-TEXT;VALUE=TEXT;ENCODING=BASE64:plain"
         "X-TEXT;VALUE=TEXT;ENCODING=ROT13:plain"
         "X-OPAQUE;ENCODING=BASE64:plain"
         "X-OPAQUE;ENCODING=ROT13:plain"
         "X-TEXT;VALUE=\"TEXT\";ENCODING=8BIT:plain"
         "X-TEXT;VALUE=TEXT;ENCODING=\"8BIT\":plain"
         "ATTACH;ENCODING=8BIT:https://example.test/file"
         "ATTACH;FMTTYPE=text/plain;FMTTYPE=text/html:https://example.test/file"
         "ATTACH;FMTTYPE=not-a-media-type:https://example.test/file"
         "ATTACH;FMTTYPE=\"text/plain\":https://example.test/file"
         "ATTACH;FMTTYPE=-text/plain:https://example.test/file"
         "ATTACH;FMTTYPE=text/pl~ain:https://example.test/file"
         "SUMMARY;FMTTYPE=text/plain:Not an attachment"))
    (let ((property (decode-single-ical-property line)))
      (assert-false (ical-property-value-valid-p property))
      (assert-true (ical-property-value-diagnostics property)))))

(define-foundation-test rfc8607-managed-attachment-parameters-are-typed
  (let* ((property
           (decode-single-ical-property
            "ATTACH;MANAGED-ID=server-42;FMTTYPE=application/pdf;SIZE=1234;FILENAME=agenda.pdf:https://attachments.example.test/a/42"))
         (attachment (project-ical-managed-attachment property))
         (unmanaged
           (project-ical-managed-attachment
            (decode-single-ical-property
             "ATTACH:https://example.test/public.txt")))
         (insecure
           (project-ical-managed-attachment
            (decode-single-ical-property
             "ATTACH;MANAGED-ID=legacy:http://attachments.example.test/a/1"))))
    (assert-true (ical-managed-attachment-valid-p attachment))
    (assert-equal :managed (ical-managed-attachment-kind attachment))
    (assert-equal "server-42"
                  (ical-managed-attachment-managed-id attachment)
                  :test #'string=)
    (assert-equal "application/pdf"
                  (ical-managed-attachment-media-type attachment)
                  :test #'string=)
    (assert-equal "agenda.pdf"
                  (ical-managed-attachment-filename attachment)
                  :test #'string=)
    (assert-equal 1234 (ical-managed-attachment-size attachment))
    (assert-true (ical-managed-attachment-retrieval-safe-p attachment))
    (assert-equal :unmanaged (ical-managed-attachment-kind unmanaged))
    (assert-true (ical-managed-attachment-valid-p insecure))
    (assert-false (ical-managed-attachment-retrieval-safe-p insecure))))

(define-foundation-test rfc8607-invalid-managed-attachment-state-fails-closed
  (dolist
      (line
       '("ATTACH;MANAGED-ID=one;MANAGED-ID=two:https://example.test/a"
         "ATTACH;MANAGED-ID=one;VALUE=BINARY;ENCODING=BASE64:Zm9v"
         "ATTACH;MANAGED-ID=one:mailto:alice@example.test"
         "ATTACH;FILENAME=agenda.pdf:https://example.test/a"
         "ATTACH;MANAGED-ID=one;FMTTYPE=not-a-type:https://example.test/a"
         "ATTACH;MANAGED-ID=one;SIZE=0:https://example.test/a"
         "ATTACH;MANAGED-ID=one;SIZE=12x:https://example.test/a"))
    (let ((attachment
            (project-ical-managed-attachment
             (decode-single-ical-property line))))
      (assert-equal :invalid (ical-managed-attachment-kind attachment))
      (assert-false (ical-managed-attachment-valid-p attachment))
      (assert-true (ical-managed-attachment-diagnostics attachment)))))

(define-foundation-test uri-and-calendar-address-properties-are-typed
  (let ((url (decode-single-ical-property
              "URL:https://example.test/events/42"))
        (attendee (decode-single-ical-property
                   "ATTENDEE:mailto:jsmith@example.com"))
        (invalid (decode-single-ical-property
                  "ORGANIZER:not-a-relative-reference")))
    (assert-true (ical-property-value-valid-p url))
    (assert-equal :uri (ical-property-value-value-type url))
    (assert-equal "https"
                  (ical-uri-value-scheme
                   (ical-value-decoded
                    (first (ical-property-value-values url))))
                  :test #'string=)
    (assert-true (ical-property-value-valid-p attendee))
    (assert-equal :cal-address
                  (ical-property-value-value-type attendee))
    (assert-false (ical-property-value-valid-p invalid))))

(define-foundation-test recurrence-rule-properties-are-typed
  (let ((valid
          (decode-single-ical-property
           "RRULE:FREQ=DAILY;COUNT=10;INTERVAL=2"))
        (invalid
          (decode-single-ical-property
           "RRULE:FREQ=WEEKLY;BYMONTHDAY=1")))
    (assert-true (ical-property-value-valid-p valid))
    (assert-equal :recur (ical-property-value-value-type valid))
    (assert-equal 10
                  (ical-recur-value-count
                   (ical-value-decoded
                    (first (ical-property-value-values valid)))))
    (assert-false (ical-property-value-valid-p invalid))))

(define-foundation-test invalid-icalendar-property-parameters-fail-closed
  (dolist (property
           '("DTSTART;TZID=Europe/Dublin:20260724T103000Z"
             "DTSTART;VALUE=DATE;VALUE=DATE:20260724"
             "DTSTART;TZID=One,Two:20260724T103000"))
    (let ((value (decode-single-ical-property property)))
      (assert-false (ical-property-value-valid-p value))
      (assert-true (ical-property-value-diagnostics value)))))

(define-foundation-test registered-control-parameters-enforce-applicability
  (let ((date-start
          (decode-single-ical-property
           "DTSTART;VALUE=DATE:20260724"))
        (binary-attachment
          (decode-single-ical-property
           "ATTACH;VALUE=BINARY;ENCODING=BASE64:Zm9v"))
        (fixed-value
          (decode-single-ical-property
           "SUMMARY;VALUE=TEXT:Explicit but forbidden"))
        (wrong-property
          (decode-single-ical-property
           "DTSTART;ENCODING=BASE64:20260724T103000")))
    (assert-true (ical-property-value-valid-p date-start))
    (assert-true (ical-property-value-valid-p binary-attachment))
    (dolist (value (list fixed-value wrong-property))
      (assert-false (ical-property-value-valid-p value))
      (assert-true
       (member :disallowed-icalendar-property-parameter
               (mapcar #'diagnostic-code
                       (ical-property-value-diagnostics value)))))))

(define-foundation-test registered-control-parameter-coupling-fails-closed
  (dolist (property
           '("ATTACH;ENCODING=BASE64:https://example.test/manual.pdf"
             "ATTACH;VALUE=BINARY;ENCODING=BASE64;ENCODING=BASE64:Zm9v"
             "RDATE;VALUE=DATE;TZID=Europe/Dublin:20260724"
             "X-COUNT;VALUE=INTEGER;TZID=Europe/Dublin:42"))
    (let ((value (decode-single-ical-property property)))
      (assert-false (ical-property-value-valid-p value))
      (assert-true (ical-property-value-diagnostics value)))))

(define-foundation-test extension-property-parameters-remain-forward-compatible
  (let ((known
          (decode-single-ical-property
           "SUMMARY;LANGUAGE=en;X-LABEL=future:Hello"))
        (typed-extension
          (decode-single-ical-property
           "X-COUNT;VALUE=INTEGER;X-LABEL=future:42"))
        (unknown-value
          (decode-single-ical-property
           "X-FUTURE;VALUE=X-THING;X-LABEL=future:opaque")))
    (assert-true (ical-property-value-valid-p known))
    (assert-true (ical-property-value-valid-p typed-extension))
    (assert-equal 42
                  (ical-value-decoded
                   (first (ical-property-value-values typed-extension))))
    (assert-true (ical-property-value-valid-p unknown-value))
    (assert-false (ical-property-value-typed-p unknown-value))
    (assert-equal "opaque"
                  (ical-content-line-value
                   (ical-property-value-line unknown-value))
                  :test #'string=)))

(define-foundation-test rfc5646-language-tags-are-well-formed
  (dolist (tag '("en" "en-US" "zh-cmn-Hans-CN" "sl-rozaj-biske-1994"
                 "en-a-myext-b-another" "x-private" "en-GB-oed"))
    (assert-true (ical-well-formed-language-tag-p tag)))
  (let ((long-private-use
          (with-output-to-string (stream)
            (write-string "en-x" stream)
            (dotimes (index 40)
              (declare (ignore index))
              (write-string "-abcdefgh" stream)))))
    (assert-true (> (length long-private-use) 255))
    (assert-true (ical-well-formed-language-tag-p long-private-use)))
  (dolist (tag '("" "x" "en--US" "en-a" "en-a-foo-a-bar"
                 "de-1901-1901" "abcd-efg" "en_US"))
    (assert-false (ical-well-formed-language-tag-p tag))))

(define-foundation-test icalendar-language-parameters-are-typed-and-bounded
  (let ((summary
          (decode-single-ical-property
           "SUMMARY;LANGUAGE=EN-us:Hello"))
        (extension
          (decode-single-ical-property
           "X-LABEL;LANGUAGE=x-private:Opaque")))
    (assert-true (ical-property-value-valid-p summary))
    (assert-equal "EN-us" (ical-property-value-language summary)
                  :test #'string=)
    (assert-true (ical-property-value-valid-p extension))
    (assert-equal "x-private" (ical-property-value-language extension)
                  :test #'string=))
  (dolist (line '("SUMMARY;LANGUAGE=en--US:Broken"
                  "SUMMARY;LANGUAGE=\"en-US\":Broken"
                  "SUMMARY;LANGUAGE=en;LANGUAGE=no:Broken"
                  "SUMMARY;LANGUAGE=en,no:Broken"
                  "DTSTART;LANGUAGE=en:20260724T100000Z"))
    (let ((property (decode-single-ical-property line)))
      (assert-false (ical-property-value-valid-p property))
      (assert-true (ical-property-value-diagnostics property)))))

(define-foundation-test repeated-icalendar-values-project-without-language-collapse
  (let* ((component
           (parse-ical-presentation-component
            "COMMENT;LANGUAGE=en:First note"
            "COMMENT;LANGUAGE=no:Andre merknad"
            "CATEGORIES;LANGUAGE=en:Deep\\, Work,Home"))
         (set (project-ical-property-presentations component))
         (presentations (ical-property-presentation-set-values set)))
    (assert-true (ical-property-presentation-set-valid-p set))
    (assert-equal 4 (length presentations))
    (assert-equal '(1 2 3 4)
                  (mapcar #'ical-property-presentation-ordinal presentations))
    (assert-equal '("First note" "Andre merknad" "Deep, Work" "Home")
                  (mapcar
                   (lambda (presentation)
                     (ical-value-decoded
                      (ical-property-presentation-value presentation)))
                   presentations))
    (assert-equal '("en" "no" "en" "en")
                  (mapcar #'ical-property-presentation-language presentations)
                  :test #'equal)
    (assert-equal '("COMMENT" "COMMENT" "CATEGORIES" "CATEGORIES")
                  (mapcar
                   (lambda (presentation)
                     (ical-content-line-normalized-name
                      (ical-property-value-line
                       (ical-property-presentation-property presentation))))
                   presentations)
                  :test #'equal)))

(define-foundation-test typed-icalendar-language-output-is-line-scoped
  (let* ((summary
           (generate-ical-property-line
            "SUMMARY" "Hei" :parameters '(("LANGUAGE" "nb-NO"))))
         (categories
           (generate-ical-property-line
            "CATEGORIES" '("Arbeid" "Hjem")
            :parameters '(("LANGUAGE" "nb-NO")))))
    (assert-equal (ical-crlf-lines "SUMMARY;LANGUAGE=nb-NO:Hei")
                  summary :test #'string=)
    (assert-equal
     (ical-crlf-lines "CATEGORIES;LANGUAGE=nb-NO:Arbeid,Hjem")
     categories :test #'string=)
    (dolist (line (list summary categories))
      (assert-true
       (ical-property-value-valid-p
        (decode-generated-ical-property line)))))
  (dolist
      (thunk
       (list
        (lambda ()
          (generate-ical-property-line
           "SUMMARY" "Bad" :parameters '(("LANGUAGE" "en--US"))))
        (lambda ()
          (generate-ical-property-line
           "SUMMARY" "Bad"
           :parameters '(("LANGUAGE" "en") ("LANGUAGE" "no"))))
        (lambda ()
          (generate-ical-property-line
           "DTSTART"
           (make-temporal-value
            :kind :utc :local-value "2026-07-24T10:00:00Z")
           :parameters '(("LANGUAGE" "en"))))))
    (assert-signals 'semantic-model-error thunk)))

(define-foundation-test registered-metadata-parameters-are-exact
  (dolist
      (line
       '("DESCRIPTION;ALTREP=\"https://example.test/description.html\":Plain text"
         "ATTENDEE;CN=Jane;CUTYPE=INDIVIDUAL;DELEGATED-FROM=\"mailto:delegator@example.test\";DELEGATED-TO=\"mailto:delegate@example.test\";DIR=\"ldap://directory.example.test/cn=Jane\";MEMBER=\"mailto:team@example.test\",\"urn:uuid:group\";PARTSTAT=ACCEPTED;ROLE=CHAIR;RSVP=TRUE;SENT-BY=\"mailto:agent@example.test\":mailto:jane@example.test"
         "ORGANIZER;CN=Jane;DIR=\"https://example.test/people/jane\";SENT-BY=\"mailto:agent@example.test\":mailto:jane@example.test"
         "FREEBUSY;FBTYPE=BUSY-TENTATIVE:20260724T100000Z/20260724T110000Z"
         "RECURRENCE-ID;RANGE=THISANDFUTURE:20260724T100000Z"
         "TRIGGER;RELATED=END:-PT15M"
         "RELATED-TO;RELTYPE=SIBLING:parent-uid"
         "X-FUTURE;ALTREP=\"https://example.test/future\":opaque"))
    (let ((property (decode-single-ical-property line)))
      (assert-true (ical-property-value-valid-p property))))
  (dolist
      (line
       '("DESCRIPTION;ALTREP=\"relative/path\":Plain text"
         "DESCRIPTION;ALTREP=\"https://example.test/one\";ALTREP=\"https://example.test/two\":Plain text"
         "SUMMARY;CN=Jane:Wrong property"
         "ATTENDEE;CN=Jane,John:mailto:jane@example.test"
         "ATTENDEE;CUTYPE=\"GROUP\":mailto:jane@example.test"
         "ATTENDEE;CUTYPE=invalid.token:mailto:jane@example.test"
         "ORGANIZER;DELEGATED-TO=\"mailto:jane@example.test\":mailto:boss@example.test"
         "ATTENDEE;DIR=\"relative/path\":mailto:jane@example.test"
         "FREEBUSY;FBTYPE=\"BUSY\":20260724T100000Z/20260724T110000Z"
         "SUMMARY;FBTYPE=BUSY:Wrong property"
         "ATTENDEE;MEMBER=mailto:team@example.test:mailto:jane@example.test"
         "ATTENDEE;PARTSTAT=\"ACCEPTED\":mailto:jane@example.test"
         "RECURRENCE-ID;RANGE=THISANDPRIOR:20260724T100000Z"
         "TRIGGER;VALUE=DATE-TIME;RELATED=START:20260724T100000Z"
         "RELATED-TO;RELTYPE=\"PARENT\":parent-uid"
         "ATTENDEE;ROLE=invalid.token:mailto:jane@example.test"
         "ATTENDEE;RSVP=YES:mailto:jane@example.test"
         "ATTENDEE;RSVP=\"TRUE\":mailto:jane@example.test"
         "ORGANIZER;SENT-BY=\"https://example.test/agent\":mailto:jane@example.test"))
    (let ((property (decode-single-ical-property line)))
      (assert-false (ical-property-value-valid-p property))
      (assert-true (ical-property-value-diagnostics property)))))

(define-foundation-test typed-registered-metadata-output-is-validated
  (let ((description
          (generate-ical-property-line
           "DESCRIPTION" "Plain text"
           :parameters
           '(("ALTREP" "https://example.test/description.html"))))
        (attendee
          (generate-ical-property-line
           "ATTENDEE" "mailto:jane@example.test"
           :component-name "VEVENT"
           :parameters
           '(("CN" "Doe, Jane")
             ("CUTYPE" "INDIVIDUAL")
             ("MEMBER" "mailto:team@example.test" "urn:uuid:group")
             ("PARTSTAT" "ACCEPTED")
             ("ROLE" "REQ-PARTICIPANT")
             ("RSVP" "TRUE")
             ("SENT-BY" "mailto:agent@example.test"))))
        (related
          (generate-ical-property-line
           "RELATED-TO" "parent-uid"
           :parameters '(("RELTYPE" "PARENT")))))
    (assert-equal
     (ical-crlf-lines
      "DESCRIPTION;ALTREP=\"https://example.test/description.html\":Plain text")
     description :test #'string=)
    (assert-equal
     "ATTENDEE;CN=\"Doe, Jane\";CUTYPE=INDIVIDUAL;MEMBER=\"mailto:team@example.test\",\"urn:uuid:group\";PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;RSVP=TRUE;SENT-BY=\"mailto:agent@example.test\":mailto:jane@example.test"
     (ical-content-line-unfolded
      (ical-property-value-line
       (decode-generated-ical-property attendee)))
     :test #'string=)
    (assert-equal
     (ical-crlf-lines "RELATED-TO;RELTYPE=PARENT:parent-uid")
     related :test #'string=)
    (dolist (line (list description attendee related))
      (assert-true
       (ical-property-value-valid-p
        (decode-generated-ical-property line)))))
  (dolist
      (thunk
       (list
        (lambda ()
          (generate-ical-property-line
           "DESCRIPTION" "Plain"
           :parameters '(("ALTREP" "relative/path"))))
        (lambda ()
          (generate-ical-property-line
           "SUMMARY" "Wrong" :parameters '(("CN" "Jane"))))
        (lambda ()
          (generate-ical-property-line
           "ATTENDEE" "mailto:jane@example.test"
           :parameters '(("CN" "Jane") ("CN" "Janet"))))
        (lambda ()
          (generate-ical-property-line
           "ATTENDEE" "mailto:jane@example.test"
           :parameters '(("CUTYPE" "invalid.token"))))
        (lambda ()
          (generate-ical-property-line
           "ATTENDEE" "mailto:jane@example.test"
           :parameters '(("RSVP" "YES"))))
        (lambda ()
          (generate-ical-property-line
           "ORGANIZER" "mailto:jane@example.test"
           :parameters '(("SENT-BY" "https://example.test/agent"))))
        (lambda ()
          (generate-ical-property-line
           "TRIGGER"
           (make-temporal-value
            :kind :utc :local-value "2026-07-24T10:00:00Z")
           :value-type :date-time :parameters '(("RELATED" "START"))))))
    (assert-signals 'semantic-model-error thunk)))

(define-foundation-test registered-parameter-effective-defaults-and-fallbacks
  (let ((defaults
          (decode-single-ical-property
           "ATTENDEE:mailto:jane@example.test"))
        (registered
          (decode-single-ical-property
           "ATTENDEE;CUTYPE=GROUP;PARTSTAT=ACCEPTED;ROLE=CHAIR;RSVP=TRUE:mailto:jane@example.test"))
        (extensions
          (decode-single-ical-property
           "ATTENDEE;CUTYPE=X-ROBOT;PARTSTAT=X-WAITING;ROLE=X-OBSERVER:mailto:jane@example.test"))
        (freebusy-default
          (decode-single-ical-property
           "FREEBUSY:20260724T100000Z/20260724T110000Z"))
        (freebusy-extension
          (decode-single-ical-property
           "FREEBUSY;FBTYPE=X-FOCUS:20260724T100000Z/20260724T110000Z"))
        (relationship-default
          (decode-single-ical-property "RELATED-TO:parent-uid"))
        (relationship-extension
          (decode-single-ical-property
           "RELATED-TO;RELTYPE=X-FUTURE:parent-uid")))
    (dolist (property
             (list defaults registered extensions freebusy-default
                   freebusy-extension relationship-default
                   relationship-extension))
      (assert-true (ical-property-value-valid-p property)))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-calendar-user-type defaults)
      (assert-equal "INDIVIDUAL" effective :test #'string=)
      (assert-false raw)
      (assert-equal :default resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-calendar-user-type registered)
      (assert-equal "GROUP" effective :test #'string=)
      (assert-equal "GROUP" raw :test #'string=)
      (assert-equal :registered resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-calendar-user-type extensions)
      (assert-equal "UNKNOWN" effective :test #'string=)
      (assert-equal "X-ROBOT" raw :test #'string=)
      (assert-equal :fallback resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-participation-status defaults "VEVENT")
      (assert-equal "NEEDS-ACTION" effective :test #'string=)
      (assert-false raw)
      (assert-equal :default resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-participation-status extensions "VEVENT")
      (assert-equal "NEEDS-ACTION" effective :test #'string=)
      (assert-equal "X-WAITING" raw :test #'string=)
      (assert-equal :fallback resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-role extensions)
      (assert-equal "REQ-PARTICIPANT" effective :test #'string=)
      (assert-equal "X-OBSERVER" raw :test #'string=)
      (assert-equal :fallback resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-rsvp-p defaults)
      (assert-false effective)
      (assert-false raw)
      (assert-equal :default resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-rsvp-p registered)
      (assert-true effective)
      (assert-equal "TRUE" raw :test #'string=)
      (assert-equal :registered resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-free-busy-type freebusy-default)
      (assert-equal "BUSY" effective :test #'string=)
      (assert-false raw)
      (assert-equal :default resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-free-busy-type freebusy-extension)
      (assert-equal "BUSY" effective :test #'string=)
      (assert-equal "X-FOCUS" raw :test #'string=)
      (assert-equal :fallback resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-relationship-type relationship-default)
      (assert-equal "PARENT" effective :test #'string=)
      (assert-false raw)
      (assert-equal :default resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-relationship-type relationship-extension)
      (assert-equal "PARENT" effective :test #'string=)
      (assert-equal "X-FUTURE" raw :test #'string=)
      (assert-equal :fallback resolution))))

(define-foundation-test participation-status-is-component-dependent
  (dolist (case
           '(("VEVENT" "TENTATIVE")
             ("VEVENT" "DELEGATED")
             ("VTODO" "COMPLETED")
             ("VTODO" "IN-PROCESS")
             ("VJOURNAL" "DECLINED")
             ("VJOURNAL" "X-FUTURE")))
    (destructuring-bind (component-name status) case
      (let ((property
              (decode-single-ical-property-in-component
               (format nil
                       "ATTENDEE;PARTSTAT=~a:mailto:jane@example.test"
                       status)
               component-name)))
        (assert-true (ical-property-value-valid-p property))
        (multiple-value-bind (effective raw resolution)
            (ical-property-effective-participation-status
             property component-name)
          (assert-equal
           (if (string= status "X-FUTURE") "NEEDS-ACTION" status)
           effective :test #'string=)
          (assert-equal status raw :test #'string=)
          (assert-equal
           (if (string= status "X-FUTURE") :fallback :registered)
           resolution)))))
  (dolist (case
           '(("VEVENT" "COMPLETED")
             ("VEVENT" "IN-PROCESS")
             ("VJOURNAL" "TENTATIVE")
             ("VJOURNAL" "DELEGATED")
             ("VFREEBUSY" "ACCEPTED")))
    (destructuring-bind (component-name status) case
      (let ((property
              (decode-single-ical-property-in-component
               (format nil
                       "ATTENDEE;PARTSTAT=~a:mailto:jane@example.test"
                       status)
               component-name)))
        (assert-false (ical-property-value-valid-p property))
        (assert-true
         (find :invalid-icalendar-partstat-component
               (ical-property-value-diagnostics property)
               :key #'diagnostic-code))))))

(define-foundation-test typed-attachment-format-output-is-validated
  (let ((uri-line
          (generate-ical-property-line
           "ATTACH" "https://example.test/file.pdf"
           :parameters '(("FMTTYPE" "application/pdf"))))
        (binary-line
          (generate-ical-property-line
           "ATTACH" #(102 111 111) :value-type :binary
           :parameters '(("FMTTYPE" "text/plain")))))
    (assert-equal
     (ical-crlf-lines
      "ATTACH;FMTTYPE=application/pdf:https://example.test/file.pdf")
     uri-line :test #'string=)
    (assert-equal
     (ical-crlf-lines
      "ATTACH;VALUE=BINARY;ENCODING=BASE64;FMTTYPE=text/plain:Zm9v")
     binary-line :test #'string=)
    (dolist (line (list uri-line binary-line))
      (assert-true
       (ical-property-value-valid-p
        (decode-generated-ical-property line)))))
  (dolist
      (thunk
       (list
        (lambda ()
          (generate-ical-property-line
           "ATTACH" "https://example.test/file"
           :parameters '(("FMTTYPE" "not-a-media-type"))))
        (lambda ()
          (generate-ical-property-line
           "ATTACH" "https://example.test/file"
           :parameters '(("FMTTYPE" "text/plain")
                         ("FMTTYPE" "text/html"))))
        (lambda ()
          (generate-ical-property-line
           "SUMMARY" "Not an attachment"
           :parameters '(("FMTTYPE" "text/plain"))))))
    (assert-signals 'semantic-model-error thunk)))

(define-foundation-test typed-partstat-output-requires-component-context
  (dolist (case
           '(("VEVENT" "TENTATIVE")
             ("VTODO" "COMPLETED")
             ("VJOURNAL" "ACCEPTED")
             ("VJOURNAL" "X-FUTURE")))
    (destructuring-bind (component-name status) case
      (let ((line
              (generate-ical-property-line
               "ATTENDEE" "mailto:jane@example.test"
               :component-name component-name
               :parameters (list (list "PARTSTAT" status)))))
        (assert-true
         (search (format nil ";PARTSTAT=~a:" status)
                 (ical-content-line-unfolded
                  (ical-property-value-line
                   (decode-generated-ical-property line))))))))
  (dolist (case
           '((nil "ACCEPTED")
             (42 "ACCEPTED")
             ("VEVENT" "COMPLETED")
             ("VJOURNAL" "TENTATIVE")
             ("VFREEBUSY" "ACCEPTED")))
    (destructuring-bind (component-name status) case
      (assert-signals
       'semantic-model-error
       (lambda ()
         (generate-ical-property-line
          "ATTENDEE" "mailto:jane@example.test"
          :component-name component-name
          :parameters (list (list "PARTSTAT" status))))))))

(define-foundation-test freebusy-and-alarm-attendees-forbid-participant-parameters
  (dolist (component-name '("VFREEBUSY" "VALARM"))
    (dolist (parameter '("CN" "CUTYPE" "DELEGATED-FROM" "DELEGATED-TO"
                         "DIR" "LANGUAGE" "MEMBER" "PARTSTAT" "ROLE"
                         "RSVP" "SENT-BY"))
      (let* ((value
               (cond ((member parameter '("DELEGATED-FROM" "DELEGATED-TO"
                                           "MEMBER") :test #'string=)
                      "\"mailto:other@example.test\"")
                     ((member parameter '("DIR") :test #'string=)
                      "\"https://directory.example.test/user\"")
                     ((string= parameter "SENT-BY")
                      "\"mailto:sender@example.test\"")
                     ((string= parameter "RSVP") "TRUE")
                     ((string= parameter "LANGUAGE") "en")
                     ((string= parameter "PARTSTAT") "ACCEPTED")
                     ((string= parameter "ROLE") "REQ-PARTICIPANT")
                     ((string= parameter "CUTYPE") "INDIVIDUAL")
                     (t "Jane")))
             (line
               (format nil "ATTENDEE;~a=~a:mailto:jane@example.test"
                       parameter value))
             (property
               (decode-single-ical-property-in-component line component-name)))
        (assert-false (ical-property-value-valid-p property))
        (assert-true
         (find :disallowed-icalendar-attendee-context-parameter
               (ical-property-value-diagnostics property)
               :key #'diagnostic-code)))))
  (dolist (component-name '("VFREEBUSY" "VALARM"))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (generate-ical-property-line
        "ATTENDEE" "mailto:jane@example.test"
        :component-name component-name
        :parameters '(("ROLE" "REQ-PARTICIPANT"))))))
  (let ((property
          (decode-single-ical-property-in-component
           "ATTENDEE;X-VENDOR=opaque:mailto:jane@example.test"
           "VFREEBUSY")))
    (assert-true (ical-property-value-valid-p property))))

(define-foundation-test request-status-properties-require-component-context
  (dolist (component-name '("VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY"))
    (let* ((property
             (decode-single-ical-property-in-component
              "REQUEST-STATUS;LANGUAGE=en:3.1;Invalid property value;DTSTART:bad"
              component-name))
           (status
             (ical-value-decoded
              (first (ical-property-value-values property)))))
      (assert-true (ical-property-value-valid-p property))
      (assert-equal :request-status
                    (ical-property-value-value-type property))
      (assert-equal "en" (ical-property-value-language property)
                    :test #'string=)
      (assert-equal :client-error
                    (ical-request-status-value-class status))
      (assert-equal "DTSTART:bad"
                    (ical-request-status-value-exception-data status)
                    :test #'string=)))
  (dolist (component-name '(nil "VCALENDAR" "VALARM" "VTIMEZONE"))
    (let ((property
            (decode-single-ical-property-in-component
             "REQUEST-STATUS:2.0;Success" component-name)))
      (assert-false (ical-property-value-valid-p property))
      (assert-true
       (find :invalid-icalendar-request-status-component
             (ical-property-value-diagnostics property)
             :key #'diagnostic-code))))
  (let* ((status
           (make-ical-request-status-value
            :code "2.8" :description "Fallback, applied"
            :exception-data "RRULE:FREQ=WEEKLY;INTERVAL=2"))
         (line
           (generate-ical-property-line
            "REQUEST-STATUS" status :component-name "VTODO"
            :parameters '(("LANGUAGE" "en")))))
    (assert-equal
     "REQUEST-STATUS;LANGUAGE=en:2.8;Fallback\\, applied;RRULE:FREQ=WEEKLY\\;INTERVAL=2"
     (ical-content-line-unfolded
      (ical-property-value-line (decode-generated-ical-property line)))
     :test #'string=)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (generate-ical-property-line "REQUEST-STATUS" status)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (generate-ical-property-line
        "REQUEST-STATUS" status :component-name "VALARM")))))

(define-foundation-test attachment-generation-prefers-uri-and-labels-inline-binary
  (let ((uri-line
          (generate-ical-property-line
           "ATTACH" "https://example.test/file"))
        (inline-line
          (generate-ical-property-line
           "ATTACH" #(102 111 111) :value-type :binary)))
    (assert-equal
     (ical-crlf-lines "ATTACH:https://example.test/file")
     uri-line :test #'string=)
    (assert-equal
     (ical-crlf-lines
      "ATTACH;VALUE=BINARY;ENCODING=BASE64;FMTTYPE=application/octet-stream:Zm9v")
     inline-line :test #'string=)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (generate-ical-property-line "ATTACH" #(102 111 111))))))

(define-foundation-test typed-icalendar-properties-generate-control-parameters
  (let* ((date
           (make-temporal-value
            :kind :date :local-value "2026-07-24"))
         (zoned
           (make-temporal-value
            :kind :zoned :local-value "2026-07-24T10:20:30"
            :timezone-id "Europe/Dublin"))
         (date-line
           (generate-ical-property-line
            "dtstart" date :value-type :date))
         (zoned-line
           (generate-ical-property-line "DTSTART" zoned))
         (binary-line
           (generate-ical-property-line "ATTACH" #(102 111 111)
                                        :value-type :binary))
         (categories-line
           (generate-ical-property-line
            "CATEGORIES" '("Deep, Work" "Home")))
         (attendee-line
           (generate-ical-property-line
            "ATTENDEE" "mailto:jane@example.test"
            :parameters '(("CN" "Doe, Jane")))))
    (assert-equal
     (ical-crlf-lines "DTSTART;VALUE=DATE:20260724")
     date-line :test #'string=)
    (assert-equal
     (ical-crlf-lines
      "DTSTART;TZID=Europe/Dublin:20260724T102030")
     zoned-line :test #'string=)
    (assert-equal
     (ical-crlf-lines
      "ATTACH;VALUE=BINARY;ENCODING=BASE64;FMTTYPE=application/octet-stream:Zm9v")
     binary-line :test #'string=)
    (assert-equal
     (ical-crlf-lines "CATEGORIES:Deep\\, Work,Home")
     categories-line :test #'string=)
    (assert-equal
     (ical-crlf-lines
      "ATTENDEE;CN=\"Doe, Jane\":mailto:jane@example.test")
     attendee-line :test #'string=)
    (dolist (line (list date-line zoned-line binary-line
                        categories-line attendee-line))
      (assert-true
       (ical-property-value-valid-p
        (decode-generated-ical-property line))))))

(define-foundation-test typed-icalendar-property-generation-fails-closed
  (let ((zoned
          (make-temporal-value
           :kind :zoned :local-value "2026-07-24T10:20:30"
           :timezone-id "Europe/Dublin"))
        (utc
          (make-temporal-value
           :kind :utc :local-value "2026-07-24T09:20:30Z")))
    (dolist
        (thunk
         (list
          (lambda ()
            (generate-ical-property-line "X-UNKNOWN" "opaque"))
          (lambda ()
            (generate-ical-property-line
             "SUMMARY" 42 :value-type :integer))
          (lambda ()
            (generate-ical-property-line "DTSTAMP" zoned))
          (lambda ()
            (generate-ical-property-line
             "DTSTART" zoned
             :parameters '(("VALUE" "DATE-TIME"))))
          (lambda ()
            (generate-ical-property-line "CATEGORIES" nil))
          (lambda ()
            (generate-ical-property-line "EXDATE" (list zoned utc)))))
      (assert-signals 'semantic-model-error thunk))))

(define-foundation-test rfc7986-image-properties-and-display-modes-are-typed
  (let* ((property
           (decode-single-ical-property
            "IMAGE;VALUE=URI;DISPLAY=BADGE,THUMBNAIL;FMTTYPE=image/png;ALTREP=\"https://example.test/page\":https://example.test/image.png"))
         (default
           (decode-single-ical-property
            "IMAGE;VALUE=URI:https://example.test/default.png"))
         (unknown
           (decode-single-ical-property
            "IMAGE;VALUE=URI;DISPLAY=X-FUTURE:https://example.test/future.png")))
    (assert-true (ical-property-value-valid-p property))
    (assert-equal "image/png" (ical-property-effective-media-type property)
                  :test #'string=)
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-image-displays property)
      (assert-equal '("BADGE" "THUMBNAIL") effective :test #'equal)
      (assert-equal effective raw :test #'equal)
      (assert-equal :registered resolution))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-image-displays default)
      (assert-equal '("BADGE") effective :test #'equal)
      (assert-false raw)
      (assert-equal :default resolution))
    (assert-false (ical-property-effective-media-type default))
    (assert-true (ical-property-value-valid-p unknown))
    (multiple-value-bind (effective raw resolution)
        (ical-property-effective-image-displays unknown)
      (assert-false effective)
      (assert-equal '("X-FUTURE") raw :test #'equal)
      (assert-equal :unsupported resolution))))

(define-foundation-test rfc7986-image-property-generation-is-explicit-and-safe
  (let* ((uri-value (decode-ical-value "https://example.test/image.png" :uri))
         (uri (ical-value-decoded uri-value))
         (uri-line
           (generate-ical-property-line
            "IMAGE" uri
            :parameters '(("DISPLAY" "GRAPHIC" "FULLSIZE")
                          ("FMTTYPE" "image/png"))))
         (binary-line
           (generate-ical-property-line
            "IMAGE" #(102 111 111) :value-type :binary)))
    (assert-true (ical-value-valid-p uri-value))
    (assert-true
     (search
      "IMAGE;VALUE=URI;DISPLAY=GRAPHIC,FULLSIZE;FMTTYPE=image/png:https://example."
      uri-line))
    (assert-true (search (concatenate 'string (string #\Return)
                                     (string #\Newline) " test/image.png")
                         uri-line))
    (assert-equal
     (ical-crlf-lines "IMAGE;VALUE=BINARY;ENCODING=BASE64:Zm9v")
     binary-line :test #'string=)
    (assert-true
     (ical-property-value-valid-p (decode-generated-ical-property uri-line)))
    (let ((binary-property (decode-generated-ical-property binary-line)))
      (assert-true (ical-property-value-valid-p binary-property))
      (assert-false (ical-property-effective-media-type binary-property)))
    (dolist (source
             '("IMAGE:https://example.test/no-value.png"
               "IMAGE;VALUE=URI;FMTTYPE=text/plain:https://example.test/not-image"
               "IMAGE;VALUE=URI;DISPLAY=\"BADGE\":https://example.test/quoted.png"
               "IMAGE;VALUE=URI;DISPLAY=BADGE;DISPLAY=THUMBNAIL:https://example.test/duplicate.png"))
      (assert-false
       (ical-property-value-valid-p (decode-single-ical-property source))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (generate-ical-property-line
        "IMAGE" uri :parameters '(("FMTTYPE" "text/plain")))))))

(define-foundation-test rfc7986-conference-and-contact-parameters-are-typed
  (let* ((conference
           (decode-single-ical-property-in-component
            "CONFERENCE;VALUE=URI;FEATURE=AUDIO,VIDEO;LABEL=Web video;LANGUAGE=en:https://meet.example.test/room"
            "VEVENT"))
         (extended
           (decode-single-ical-property-in-component
            "CONFERENCE;VALUE=URI;FEATURE=X-HOLOGRAM:https://meet.example.test/future"
            "VTODO"))
         (attendee
           (decode-single-ical-property-in-component
            "ATTENDEE;EMAIL=person@example.test:urn:uuid:attendee-1"
            "VEVENT")))
    (assert-true (ical-property-value-valid-p conference))
    (multiple-value-bind (features resolution)
        (ical-property-effective-conference-features conference)
      (assert-equal '("AUDIO" "VIDEO") features :test #'equal)
      (assert-equal :registered resolution))
    (multiple-value-bind (label valid-p)
        (ical-property-conference-label conference)
      (assert-true valid-p)
      (assert-equal "Web video" label :test #'string=))
    (assert-true (ical-property-value-valid-p extended))
    (multiple-value-bind (features resolution)
        (ical-property-effective-conference-features extended)
      (assert-equal '("X-HOLOGRAM") features :test #'equal)
      (assert-equal :extended resolution))
    (assert-true (ical-property-value-valid-p attendee))
    (multiple-value-bind (email valid-p)
        (ical-property-calendar-user-email attendee)
      (assert-true valid-p)
      (assert-equal "person@example.test" email :test #'string=))))

(define-foundation-test rfc7986-conference-property-generation-is-context-safe
  (let* ((uri-value (decode-ical-value "https://meet.example.test/room" :uri))
         (uri (ical-value-decoded uri-value))
         (attendee-value (decode-ical-value "urn:uuid:attendee-1" :cal-address))
         (line
           (generate-ical-property-line
            "CONFERENCE" uri :component-name "VEVENT"
            :parameters '(("FEATURE" "AUDIO" "VIDEO")
                          ("LABEL" "Web video")
                          ("LANGUAGE" "en"))))
         (attendee-line
           (generate-ical-property-line
            "ATTENDEE" (ical-value-decoded attendee-value)
            :component-name "VEVENT"
            :parameters '(("EMAIL" "person@example.test")))))
    (assert-true (ical-value-valid-p uri-value))
    (assert-true (ical-value-valid-p attendee-value))
    (assert-true (search "CONFERENCE;VALUE=URI;FEATURE=AUDIO,VIDEO" line))
    (assert-true
     (ical-property-value-valid-p
      (decode-ical-content-line-value
       (parse-single-ical-property (subseq line 0 (- (length line) 2)))
       :component-name "VEVENT")))
    (assert-true (search "ATTENDEE;EMAIL=person@example.test:" attendee-line))
    (assert-true
     (ical-property-value-valid-p
      (decode-ical-content-line-value
       (parse-single-ical-property
        (subseq attendee-line 0 (- (length attendee-line) 2)))
       :component-name "VEVENT")))
    (dolist (property
             '("CONFERENCE:https://meet.example.test/no-value"
               "CONFERENCE;VALUE=URI;FEATURE=\"AUDIO\":https://meet.example.test/quoted"
               "CONFERENCE;VALUE=URI;FEATURE=AUDIO;FEATURE=VIDEO:https://meet.example.test/duplicate"
               "CONFERENCE;VALUE=URI;LABEL=One;LABEL=Two:https://meet.example.test/duplicate"
               "SUMMARY;EMAIL=person@example.test:Wrong property"))
      (assert-false
       (ical-property-value-valid-p
        (decode-single-ical-property-in-component property "VEVENT"))))
    (assert-false
     (ical-property-value-valid-p
      (decode-single-ical-property-in-component
       "CONFERENCE;VALUE=URI:https://meet.example.test/wrong-context"
       "VJOURNAL")))
    (dolist (component-name '(nil "VJOURNAL"))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (generate-ical-property-line
          "CONFERENCE" uri :component-name component-name))))))
