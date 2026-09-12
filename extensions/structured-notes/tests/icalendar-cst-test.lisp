(in-package #:lem-structured-notes/tests)

(defun ical-crlf-lines (&rest lines)
  (with-output-to-string (stream)
    (dolist (line lines)
      (write-string line stream)
      (write-char #\Return stream)
      (write-char #\Newline stream))))

(defparameter *icalendar-cst-fixture*
  (ical-crlf-lines
   "BEGIN:VCALENDAR"
   "VERSION:2.0"
   "PRODID:-//Lem//Structured Notes//EN"
   "item1.X-GROUPED:grouped value"
   "X-TAB-FOLD:alpha"
   (format nil "~cbeta" #\Tab)
   "x-Custom;X-ORDER=first;X-LIST=one,\"two,three\":opaque:value"
   "BEGIN:VEVENT"
   "UID:event-1@example.test"
   "SUMMARY:Review \"quoted\" value"
   "DESCRIPTION:Folded λ descrip"
   " tion with unknown data"
   "BEGIN:VALARM"
   "ACTION:DISPLAY"
   "TRIGGER:-PT15M"
   "END:VALARM"
   "END:VEVENT"
   "BEGIN:VLOCATION"
   "UID:location-1"
   "X-UNKNOWN;P=one^ntwo^^three^'four^x;Q=\"quoted^'value,still-one\":preserved"
   "END:VLOCATION"
   "END:VCALENDAR"))

(defun find-ical-property (component name)
  (find name (ical-component-properties component)
        :key #'ical-content-line-normalized-name :test #'string=))

(define-foundation-test icalendar-cst-round-trips-folded-unknown-content
  (let* ((document
           (parse-icalendar-cst *icalendar-cst-fixture*
                                :source-id "fixture.ics"))
         (calendar (first (ical-document-components document)))
         (event (find "VEVENT" (ical-component-children calendar)
                      :key #'ical-component-normalized-name :test #'string=))
         (location (find "VLOCATION" (ical-component-children calendar)
                         :key #'ical-component-normalized-name
                         :test #'string=))
         (alarm (first (ical-component-children event)))
         (description (find-ical-property event "DESCRIPTION"))
         (unknown (find-ical-property location "X-UNKNOWN"))
         (grouped (find-ical-property calendar "X-GROUPED"))
         (tab-folded (find-ical-property calendar "X-TAB-FOLD"))
         (custom (find-ical-property calendar "X-CUSTOM")))
    (assert-equal *icalendar-cst-fixture*
                  (serialize-icalendar-cst document) :test #'string=)
    (assert-equal :crlf (ical-document-newline document))
    (assert-false (ical-document-diagnostics document))
    (assert-equal "VCALENDAR" (ical-component-normalized-name calendar)
                  :test #'string=)
    (assert-true (and event location alarm))
    (assert-equal "VALARM" (ical-component-normalized-name alarm)
                  :test #'string=)
    (assert-equal "x-Custom" (ical-content-line-name custom)
                  :test #'string=)
    (assert-equal "item1" (ical-content-line-group grouped) :test #'string=)
    (assert-equal "ITEM1" (ical-content-line-normalized-group grouped)
                  :test #'string=)
    (assert-equal "X-TAB-FOLD:alphabeta"
                  (ical-content-line-unfolded tab-folded) :test #'string=)
    (let* ((parameters (ical-content-line-parameters unknown))
           (p-value (first (ical-parameter-values (first parameters))))
           (q-value (first (ical-parameter-values (second parameters)))))
      (assert-equal (format nil "one~%two^three\"four^x")
                    (ical-parameter-value-decoded-text p-value)
                    :test #'string=)
      (assert-equal "quoted\"value,still-one"
                    (ical-parameter-value-decoded-text q-value)
                    :test #'string=))
    (assert-equal '("X-ORDER" "X-LIST")
                  (mapcar #'ical-parameter-normalized-name
                          (ical-content-line-parameters custom)))
    (let* ((list-parameter
             (second (ical-content-line-parameters custom)))
           (values (ical-parameter-values list-parameter)))
      (assert-equal 2 (length values))
      (assert-false (ical-parameter-value-quoted-p (first values)))
      (assert-true (ical-parameter-value-quoted-p (second values)))
      (assert-equal "two,three" (ical-parameter-value-text (second values))
                    :test #'string=))
    (assert-equal
     "DESCRIPTION:Folded λ description with unknown data"
     (ical-content-line-unfolded description) :test #'string=)
    (assert-true (search (format nil "~c~c " #\Return #\Newline)
                         (ical-content-line-raw description)))
    (let ((span (ical-content-line-span description)))
      (assert-true
       (> (- (source-span-byte-end span) (source-span-byte-start span))
          (- (source-span-character-end span)
             (source-span-character-start span)))))))

(define-foundation-test rfc6868-parameter-caret-codec-is-invertible
  (let ((decoded (format nil "line one~%\"quoted\" and ^ caret")))
    (assert-equal "line one^n^'quoted^' and ^^ caret"
                  (encode-ical-parameter-text decoded) :test #'string=)
    (assert-equal decoded
                  (decode-ical-parameter-text
                   (encode-ical-parameter-text decoded))
                  :test #'string=)
    (assert-equal "unchanged^xtrailing^"
                  (decode-ical-parameter-text "unchanged^xtrailing^")
                  :test #'string=)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (encode-ical-parameter-text
       (format nil "forbidden~ccontrol" #\Return))))))

(define-foundation-test canonical-icalendar-content-line-parameters-are-encoded
  (let* ((line
           (generate-ical-content-line
            "attendee" "mailto:jane@example.test"
            :group "item1"
            :parameters
            `(("cn" "Doe, Jane")
              ("x-note" ,(format nil "~%\"^")))))
         (expected
           (format nil
                   "ITEM1.ATTENDEE;CN=\"Doe, Jane\";X-NOTE=^n^'^^:mailto:jane@example.test~c~c"
                   #\Return #\Newline))
         (document
           (parse-icalendar-cst
            (concatenate
             'string
             (ical-crlf-lines "BEGIN:VCALENDAR" "BEGIN:VEVENT")
             line
             (ical-crlf-lines "END:VEVENT" "END:VCALENDAR"))))
         (event (first (ical-component-children
                        (first (ical-document-components document)))))
         (property (first (ical-component-properties event))))
    (assert-equal expected line :test #'string=)
    (assert-true (ical-content-line-valid-p property))
    (assert-equal "Doe, Jane"
                  (ical-parameter-value-decoded-text
                   (first (ical-parameter-values
                           (first (ical-content-line-parameters property)))))
                  :test #'string=)))

(define-foundation-test canonical-icalendar-folding-is-utf8-safe
  (let* ((value (concatenate 'string (make-string 62 :initial-element #\a)
                             "λ"))
         (line (generate-ical-content-line "description" value))
         (expected
           (format nil "DESCRIPTION:~a~c~c λ~c~c"
                   (make-string 62 :initial-element #\a)
                   #\Return #\Newline #\Return #\Newline))
         (document
           (parse-icalendar-cst
            (concatenate
             'string
             (ical-crlf-lines "BEGIN:VCALENDAR" "BEGIN:VEVENT")
             line
             (ical-crlf-lines "END:VEVENT" "END:VCALENDAR"))))
         (event (first (ical-component-children
                        (first (ical-document-components document)))))
         (property (first (ical-component-properties event))))
    (assert-equal expected line :test #'string=)
    (assert-equal (format nil "DESCRIPTION:~aλ"
                          (make-string 62 :initial-element #\a))
                  (ical-content-line-unfolded property) :test #'string=)
    (assert-false
     (find :overlong-icalendar-line (ical-document-diagnostics document)
           :key #'diagnostic-code))))

(define-foundation-test icalendar-physical-line-warning-starts-at-76-octets
  (flet ((document-with-width (width)
           (parse-icalendar-cst
            (ical-crlf-lines
             "BEGIN:VCALENDAR"
             (concatenate 'string "X:" (make-string (- width 2)
                                                      :initial-element #\a))
             "END:VCALENDAR"))))
    (let ((at-recommendation (document-with-width 75))
          (over-recommendation (document-with-width 76)))
      (assert-false
       (find :overlong-icalendar-line
             (ical-document-diagnostics at-recommendation)
             :key #'diagnostic-code))
      (assert-true
       (find :overlong-icalendar-line
             (ical-document-diagnostics over-recommendation)
             :key #'diagnostic-code)))))

(define-foundation-test canonical-icalendar-content-line-generation-fails-closed
  (dolist
      (thunk
       (list
        (lambda () (generate-ical-content-line "BAD_NAME" "value"))
        (lambda () (generate-ical-content-line "SUMMARY" "value"
                                               :group "bad.group"))
        (lambda () (generate-ical-content-line "SUMMARY" 42))
        (lambda () (generate-ical-content-line
                    "ATTENDEE" "mailto:a@example.test"
                    :parameters '(("CN"))))
        (lambda () (generate-ical-content-line
                    "ATTENDEE" "mailto:a@example.test"
                    :parameters '(("CN" "Alice" . "trailing"))))
        (lambda () (generate-ical-content-line
                    "ATTENDEE" "mailto:a@example.test"
                    :parameters '(("CN" "Alice") . "trailing")))
        (lambda () (generate-ical-content-line
                    "SUMMARY" (format nil "raw~%newline")))
        (lambda () (generate-ical-content-line
                    "SUMMARY" (make-string 10 :initial-element #\a)
                    :max-unfolded-octets 5))))
    (assert-signals 'semantic-model-error thunk)))

(define-foundation-test
    icalendar-content-line-character-classes-follow-corrected-rfc5545-grammar
  (let* ((tab (string #\Tab))
         (line
           (generate-ical-content-line
            "x-acme-prop" (concatenate 'string "quote\" and λ" tab)
            :parameters '(("p" "") ("q" "semi;colon,comma:colon"))))
         (source
           (concatenate
            'string
            (ical-crlf-lines "BEGIN:VCALENDAR")
            line
            (ical-crlf-lines "END:VCALENDAR")))
         (document (parse-icalendar-cst source :source-id "grammar.ics"))
         (property
           (first
            (ical-component-properties
             (first (ical-document-components document))))))
    (assert-false (ical-document-diagnostics document))
    (assert-true (ical-content-line-valid-p property))
    (let ((expected-prefix
            "X-ACME-PROP;P=;Q=\"semi;colon,comma:colon\":"))
      (assert-equal expected-prefix
                    (subseq line 0 (length expected-prefix))
                    :test #'string=))
    (assert-true (search "quote\" and λ" (ical-content-line-value property)))
    (assert-equal 2 (length (ical-content-line-parameters property)))
    (assert-equal ""
                  (ical-parameter-value-text
                   (first
                    (ical-parameter-values
                     (first (ical-content-line-parameters property)))))
                  :test #'string=))
  ;; Verified Errata 1911 and 2497 correct DQUOTE to decimal 34.  Decimal 22
  ;; remains a forbidden control in both parameter content and property value.
  (let ((control-22 (code-char 22)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (generate-ical-content-line
        "X-TEST" "value" :parameters `(("P" ,(string control-22))))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (generate-ical-content-line
        "X-TEST" (concatenate 'string "value" (string control-22)))))
    (let* ((source
             (ical-crlf-lines
              "BEGIN:VCALENDAR"
              (concatenate 'string "X-TEST;P=before" (string control-22)
                           "after:value")
              "END:VCALENDAR"))
           (document (parse-icalendar-cst source :source-id "control-22.ics"))
           (line (second (ical-document-content-lines document))))
      (assert-false (ical-content-line-valid-p line))
      (assert-true
       (find :invalid-icalendar-content-line
             (ical-document-diagnostics document) :key #'diagnostic-code)))))

(define-foundation-test source-backed-icalendar-line-replacement-is-local
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR"
            "VERSION:2.0"
            "PRODID:-//Writer Test//EN"
            "BEGIN:VEVENT"
            "UID:replace-1"
            "SUMMARY;X-ORDER=keep:Old summary"
            "X-UNKNOWN;P=one;Q=\"two,three\":opaque"
            "DESCRIPTION:Folded unknown"
            " continuation"
            "END:VEVENT"
            "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "replace.ics"))
         (calendar (first (ical-document-components document)))
         (event (first (ical-component-children calendar)))
         (summary (find-ical-property event "SUMMARY"))
         (span (ical-content-line-span summary))
         (replacement
           (generate-ical-content-line
            "summary" (encode-ical-text "New λ summary")
            :parameters '(("language" "en"))))
         (expected
           (concatenate
            'string
            (subseq source 0 (source-span-character-start span))
            replacement
            (subseq source (source-span-character-end span))))
         (result
           (replace-ical-content-line
            document summary "summary" (encode-ical-text "New λ summary")
            :parameters '(("language" "en"))))
         (reparsed (parse-icalendar-cst result :source-id "replace.ics"))
         (reparsed-event
           (first (ical-component-children
                   (first (ical-document-components reparsed)))))
         (reparsed-summary (find-ical-property reparsed-event "SUMMARY")))
    (assert-equal expected result :test #'string=)
    (assert-true (search "X-UNKNOWN;P=one;Q=\"two,three\":opaque" result))
    (assert-true (search (format nil "DESCRIPTION:Folded unknown~c~c continuation"
                                #\Return #\Newline)
                         result))
    (assert-equal "New λ summary"
                  (ical-value-decoded
                   (first (ical-property-value-values
                           (decode-ical-content-line-value
                            reparsed-summary))))
                  :test #'string=)))

(define-foundation-test source-backed-icalendar-line-replacement-fails-closed
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "VERSION:2.0" "PRODID:-//Test//EN"
            "BEGIN:VEVENT" "UID:replace-2" "SUMMARY:Owned"
            "END:VEVENT" "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "owner.ics"))
         (clone (parse-icalendar-cst source :source-id "owner.ics"))
         (event (first (ical-component-children
                        (first (ical-document-components document)))))
         (clone-event (first (ical-component-children
                              (first (ical-document-components clone)))))
         (line (find-ical-property event "SUMMARY"))
         (foreign-line (find-ical-property clone-event "SUMMARY"))
         (stale-source (copy-seq source))
         (stale-document
           (parse-icalendar-cst stale-source :source-id "stale.ics"))
         (stale-event
           (first (ical-component-children
                   (first (ical-document-components stale-document)))))
         (stale-line (find-ical-property stale-event "SUMMARY"))
         (invalid-document
           (parse-icalendar-cst
            (ical-crlf-lines "BEGIN:VCALENDAR" "SUMMARY:Unsafe")
            :source-id "invalid.ics"))
         (invalid-line
           (find-ical-property
            (first (ical-document-components invalid-document)) "SUMMARY")))
    (setf (char stale-source
                (source-span-character-start
                 (ical-content-line-span stale-line)))
          #\X)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (replace-ical-content-line document foreign-line "SUMMARY" "Foreign")))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (replace-ical-content-line document line "SUMMARY" "Too large"
                                  :max-output-octets 1)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (replace-ical-content-line
        stale-document stale-line "SUMMARY" "Stale")))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (replace-ical-content-line
        invalid-document invalid-line "SUMMARY" "Still unsafe")))))

(define-foundation-test icalendar-source-edits-compose-insert-replace-delete
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR"
            "VERSION:2.0"
            "PRODID:-//Writer Test//EN"
            "BEGIN:VEVENT"
            "UID:multi-1"
            "DESCRIPTION:Remove me"
            "BEGIN:VALARM"
            "ACTION:DISPLAY"
            "TRIGGER:-PT15M"
            "DESCRIPTION:Reminder"
            "END:VALARM"
            "END:VEVENT"
            "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "multi.ics"))
         (calendar (first (ical-document-components document)))
         (event (first (ical-component-children calendar)))
         (uid (find-ical-property event "UID"))
         (description (find-ical-property event "DESCRIPTION"))
         (result
           (apply-ical-source-edits
            document
            (list
             (plan-ical-content-line-insertion
              document event "SUMMARY" (encode-ical-text "New event"))
             (plan-ical-content-line-deletion document description)
             (plan-ical-content-line-insertion
              document calendar "CALSCALE" "GREGORIAN")
             (plan-ical-content-line-replacement
              document uid "UID" (encode-ical-text "multi-2")))))
         (expected
           (ical-crlf-lines
            "BEGIN:VCALENDAR"
            "VERSION:2.0"
            "PRODID:-//Writer Test//EN"
            "CALSCALE:GREGORIAN"
            "BEGIN:VEVENT"
            "UID:multi-2"
            "SUMMARY:New event"
            "BEGIN:VALARM"
            "ACTION:DISPLAY"
            "TRIGGER:-PT15M"
            "DESCRIPTION:Reminder"
            "END:VALARM"
            "END:VEVENT"
            "END:VCALENDAR"))
         (reparsed (parse-icalendar-cst result :source-id "multi.ics"))
         (reparsed-calendar (first (ical-document-components reparsed)))
         (reparsed-event (first (ical-component-children reparsed-calendar))))
    (assert-equal expected result :test #'string=)
    (assert-false (ical-document-diagnostics reparsed))
    (assert-equal "GREGORIAN"
                  (ical-content-line-value
                   (find-ical-property reparsed-calendar "CALSCALE"))
                  :test #'string=)
    (assert-equal "multi-2"
                  (ical-content-line-value
                   (find-ical-property reparsed-event "UID"))
                  :test #'string=)
    (assert-false (find-ical-property reparsed-event "DESCRIPTION"))
    (assert-true (search "BEGIN:VALARM" result))))

(define-foundation-test conflicting-or-stale-icalendar-source-edits-fail-closed
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "VERSION:2.0" "PRODID:-//Test//EN"
            "BEGIN:VEVENT" "UID:conflict-1" "SUMMARY:Owned"
            "BEGIN:VALARM" "ACTION:DISPLAY" "TRIGGER:-PT5M"
            "DESCRIPTION:Reminder" "END:VALARM"
            "END:VEVENT" "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "conflict.ics"))
         (clone (parse-icalendar-cst (copy-seq source)
                                     :source-id "conflict.ics"))
         (calendar (first (ical-document-components document)))
         (event (first (ical-component-children calendar)))
         (alarm (first (ical-component-children event)))
         (summary (find-ical-property event "SUMMARY"))
         (replacement
           (plan-ical-content-line-replacement
            document summary "SUMMARY" "Changed"))
         (insertion
           (plan-ical-content-line-insertion
            document event "LOCATION" "Somewhere")))
    (dolist
        (thunk
         (list
          (lambda ()
            (apply-ical-source-edits document (list replacement replacement)))
          (lambda ()
            (apply-ical-source-edits document (list insertion insertion)))
          (lambda ()
            (apply-ical-source-edits document nil))
          (lambda ()
            (apply-ical-source-edits document (list insertion)
                                     :max-output-octets 1))
          (lambda ()
            (plan-ical-content-line-deletion
             document (ical-component-begin-line event)))
          (lambda ()
            (plan-ical-content-line-insertion
             document event "LOCATION" "Somewhere"
             :before-line (ical-component-begin-line alarm)))
          (lambda ()
            (plan-ical-content-line-insertion
             document
             (first (ical-component-children
                     (first (ical-document-components clone))))
             "LOCATION" "Somewhere"))))
      (assert-signals 'semantic-model-error thunk))
    ;; Even an unrelated source mutation invalidates the whole edit set.
    (setf (char source 0) #\X)
    (assert-signals
     'semantic-model-error
     (lambda ()
       (apply-ical-source-edits document (list replacement))))))

(define-foundation-test icalendar-cst-tolerates-newlines-with-diagnostics
  (let* ((source
           (format nil
                   "BEGIN:VCALENDAR~%VERSION:2.0~%PRODID:-//Test//EN~%END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "lf.ics"))
         (codes (mapcar #'diagnostic-code
                        (ical-document-diagnostics document))))
    (assert-equal source (serialize-icalendar-cst document) :test #'string=)
    (assert-equal :lf (ical-document-newline document))
    (assert-true (member :non-crlf-icalendar-line-ending codes))
    (assert-true (member :missing-icalendar-line-ending codes))
    (assert-equal 1 (length (ical-document-components document)))))

(define-foundation-test icalendar-cst-diagnoses-malformed-structure
  (let* ((source
           (ical-crlf-lines
            " orphan"
            "BEGIN:VCALENDAR"
            "BEGIN:VEVENT"
            "SUMMARY broken"
            "END:VTODO"))
         (document (parse-icalendar-cst source :source-id "broken.ics"))
         (codes (mapcar #'diagnostic-code
                        (ical-document-diagnostics document))))
    (assert-equal source (serialize-icalendar-cst document) :test #'string=)
    (dolist (code '(:invalid-icalendar-content-line
                    :orphan-icalendar-fold
                    :mismatched-icalendar-component-end
                    :unclosed-icalendar-component))
      (assert-true (member code codes)
                   (format nil "missing iCalendar diagnostic ~s" code)))
    (let* ((calendar (first (ical-document-components document)))
           (event (first (ical-component-children calendar))))
      (assert-false (ical-component-closed-p calendar))
      (assert-false (ical-component-closed-p event)))))

(define-foundation-test icalendar-cst-diagnoses-orphan-fold
  (let* ((source
           (ical-crlf-lines
            " orphan"
            "BEGIN:VCALENDAR"
            "END:VCALENDAR"))
         (document (parse-icalendar-cst source :source-id "fold.ics")))
    (assert-equal source (serialize-icalendar-cst document) :test #'string=)
    (assert-true
     (find :orphan-icalendar-fold (ical-document-diagnostics document)
           :key #'diagnostic-code))))

(define-foundation-test icalendar-cst-enforces-resource-limits
  (let ((source
          (ical-crlf-lines
           "BEGIN:VCALENDAR"
           "BEGIN:VEVENT"
           "END:VEVENT"
           "END:VCALENDAR")))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (parse-icalendar-cst source :source-id "lines.ics"
                           :max-physical-lines 2)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (parse-icalendar-cst source :source-id "depth.ics"
                           :max-nesting 1)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (parse-icalendar-cst source :source-id "components.ics"
                           :max-components 1)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (parse-icalendar-cst source :source-id "physical-size.ics"
                           :max-physical-line-octets 5)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (parse-icalendar-cst source :source-id "unfolded-size.ics"
                           :max-unfolded-line-octets 5)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (parse-icalendar-cst source :source-id "invalid-limit.ics"
                           :max-nesting "unbounded")))))
