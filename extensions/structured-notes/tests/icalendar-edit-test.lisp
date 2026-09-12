(in-package #:lem-structured-notes/tests)

(defun parse-editable-icalendar (source &optional (source-id "semantic-edit.ics"))
  (let* ((document (parse-icalendar-cst source :source-id source-id))
         (calendar (first (ical-document-components document)))
         (item (first (ical-component-children calendar))))
    (values document item)))

(define-foundation-test semantic-icalendar-property-edits-preserve-evidence
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR"
            "PRODID:-//Semantic Edit Test//EN"
            "VERSION:2.0"
            "BEGIN:VEVENT"
            "UID:semantic-edit-1"
            "DTSTAMP:20260724T090000Z"
            "DTSTART;TZID=Europe/Dublin:20260724T100000"
            "DTEND;TZID=Europe/Dublin:20260724T110000"
            "SUMMARY;LANGUAGE=en;X-LABEL=keep:Old"
            "DESCRIPTION:Remove me"
            "CATEGORIES:Work"
            "CATEGORIES:Home"
            "X-UNKNOWN;X-ORDER=keep:opaque"
            "BEGIN:VALARM"
            "ACTION:DISPLAY"
            "TRIGGER:-PT10M"
            "DESCRIPTION:Alarm stays exact"
            "END:VALARM"
            "END:VEVENT"
            "END:VCALENDAR"))
         (document nil)
         (component nil))
    (multiple-value-setq (document component)
      (parse-editable-icalendar source))
    (let* ((changes
             (list
              (make-ical-property-change
               :name "SUMMARY" :value "New, title")
              (make-ical-property-change
               :name "CATEGORIES" :value '("Deep, Work" "Home"))
              (make-ical-property-change
               :name "DESCRIPTION" :operation :delete)
              (make-ical-property-change
               :name "LOCATION" :value "Main room")
              (make-ical-property-change
               :name "URL" :value "https://example.test/events/1")))
           (plan
             (plan-ical-semantic-property-changes
              document component changes))
           (current (parse-icalendar-cst (copy-seq source)
                                         :source-id "semantic-edit.ics"))
           (result (apply-ical-semantic-edit-plan plan current))
           (reparsed nil)
           (reparsed-component nil))
      (multiple-value-setq (reparsed reparsed-component)
        (parse-editable-icalendar result))
      (assert-true
       (search
        "SUMMARY;LANGUAGE=en;X-LABEL=keep:New\\, title" result))
      (assert-true (search "CATEGORIES:Deep\\, Work,Home" result))
      (assert-equal 1
                    (length
                     (remove-if-not
                      (lambda (line)
                        (string= "CATEGORIES"
                                 (ical-content-line-normalized-name line)))
                      (ical-component-properties reparsed-component))))
      (assert-false (find-ical-property reparsed-component "DESCRIPTION"))
      (assert-equal "Main room"
                    (ical-content-line-value
                     (find-ical-property reparsed-component "LOCATION"))
                    :test #'string=)
      (assert-true
       (search "URL:https://example.test/events/1" result))
      (assert-true
       (search "X-UNKNOWN;X-ORDER=keep:opaque" result))
      (assert-true
       (search
        (ical-crlf-lines
         "BEGIN:VALARM" "ACTION:DISPLAY" "TRIGGER:-PT10M"
         "DESCRIPTION:Alarm stays exact" "END:VALARM")
        result))
      (let* ((calendar (first (ical-document-components reparsed)))
             (envelope (project-ical-calendar-envelope calendar))
             (item (project-ical-component reparsed-component)))
        (assert-true (ical-calendar-envelope-valid-p envelope))
        (assert-true (ical-calendar-item-valid-p item))))))

(define-foundation-test invalid-or-stale-semantic-icalendar-edits-fail-closed
  (let* ((source
           (ical-crlf-lines
            "BEGIN:VCALENDAR" "PRODID:-//Edit Test//EN" "VERSION:2.0"
            "BEGIN:VEVENT" "UID:semantic-edit-2"
            "DTSTAMP:20260724T090000Z"
            "DTSTART:20260724T100000Z" "DTEND:20260724T110000Z"
            "SUMMARY:Original" "END:VEVENT" "END:VCALENDAR"))
         (document nil)
         (component nil))
    (multiple-value-setq (document component)
      (parse-editable-icalendar source "stale-edit.ics"))
    (let* ((valid-change
             (make-ical-property-change :name "SUMMARY" :value "Changed"))
           (plan
             (plan-ical-semantic-property-changes
              document component (list valid-change)))
           (stale-source (copy-seq source)))
      (setf (char stale-source 0) #\X)
      (dolist
          (thunk
           (list
            (lambda ()
              (make-ical-property-change :name "X-UNKNOWN" :value "opaque"))
            (lambda ()
              (make-ical-property-change
               :name "SUMMARY" :value "Changed"
               :parameters '(("LANGUAGE" "en"))))
            (lambda ()
              (plan-ical-semantic-property-changes
               document component (list valid-change valid-change)))
            (lambda ()
              (plan-ical-semantic-property-changes
               document component
               (list (make-ical-property-change
                      :name "UID" :operation :delete))))
            (lambda ()
              (plan-ical-semantic-property-changes
               document component
               (list (make-ical-property-change
                      :name "DTSTAMP"
                      :value
                      (make-temporal-value
                       :kind :floating
                       :local-value "2026-07-24T09:00:00")))))
            (lambda ()
              (plan-ical-semantic-property-changes
               document component
               (list (make-ical-property-change
                      :name "LOCATION" :operation :delete))))
            (lambda ()
              (apply-ical-semantic-edit-plan
               plan
               (parse-icalendar-cst stale-source
                                    :source-id "stale-edit.ics")))))
        (assert-signals 'semantic-model-error thunk)))))
