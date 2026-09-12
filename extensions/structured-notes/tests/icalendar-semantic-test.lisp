(in-package #:lem-structured-notes/tests)

(defun round-trip-ical-semantic-node (node)
  (let* ((document
           (make-semantic-document
            :id "document:icalendar-projection"
            :source-uri "generated" :format :lsm :profile "lsm/1"
            :nodes (list node) :root-ids (list (semantic-node-id node))
            :source-revision "revision:1"))
         (source (render-lsm-document document))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "event.md"
                         :revision "revision:2")))
    (find-semantic-node (source-snapshot-document snapshot)
                        (semantic-node-id node))))

(define-foundation-test validated-vevent-projects-to-source-backed-lsm-event
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VEVENT"
            "UID:event-semantic-1"
            "DTSTAMP:20260724T090000Z"
            "DTSTART;TZID=Europe/Dublin:20260727T100000"
            "DTEND;TZID=Europe/Dublin:20260727T110000"
            "RECURRENCE-ID;TZID=Europe/Dublin:20260727T100000"
            "SUMMARY:Review"
            "DESCRIPTION:Line one\\n* plain iCalendar text"
            "LOCATION:Room 4"
            "URL:https://example.test/events/1"
            "TRANSP:OPAQUE"
            "CATEGORIES:Work,Planning"
            "RRULE:FREQ=WEEKLY;BYDAY=MO,TU"
            "RDATE;TZID=Europe/Dublin:20260729T100000"
            "EXDATE;TZID=Europe/Dublin:20260803T100000"
            "END:VEVENT"))
         (item (project-ical-component component))
         (node
           (project-ical-item-to-semantic-node
            item :node-id "node:event-1" :binding-id "binding:event-1"
            :account-id "account:work" :calendar-id "calendar:team"
            :ownership :server :write-policy :remote-only))
         (parsed (round-trip-ical-semantic-node node))
         (event (semantic-node-event parsed))
         (recurrence (event-facet-recurrence event))
         (binding (first (semantic-node-calendar-bindings parsed))))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal "Review" (semantic-node-title parsed) :test #'string=)
    (assert-equal '("Work" "Planning") (semantic-node-tags parsed))
    (assert-equal (format nil "Line one~%* plain iCalendar text")
                  (cdr (assoc "icalendar.description"
                              (semantic-node-properties parsed)
                              :test #'string=))
                  :test #'string=)
    (assert-equal "Room 4" (event-facet-location event) :test #'string=)
    (assert-equal :opaque (event-facet-transparency event))
    (assert-equal '("FREQ=WEEKLY;BYDAY=MO,TU")
                  (recurrence-rules recurrence))
    (assert-equal 1 (length (recurrence-dates recurrence)))
    (assert-equal 1 (length (recurrence-exception-dates recurrence)))
    (assert-equal "event-semantic-1" (calendar-binding-uid binding)
                  :test #'string=)
    (assert-equal :zoned
                  (temporal-value-kind
                   (calendar-binding-recurrence-id binding)))))

(define-foundation-test validated-vtodo-projects-to-source-backed-lsm-task
  (let* ((component
           (parse-first-ical-item-component
            "BEGIN:VTODO"
            "UID:todo-semantic-1"
            "DTSTAMP:20260724T090000Z"
            "DTSTART;VALUE=DATE:20260724"
            "DUE;VALUE=DATE:20260725"
            "COMPLETED:20260725T120000Z"
            "SUMMARY:Submit report"
            "DESCRIPTION:Exact plain text"
            "LOCATION:Remote"
            "URL:https://example.test/tasks/1"
            "STATUS:COMPLETED"
            "PERCENT-COMPLETE:100"
            "PRIORITY:3"
            "END:VTODO"))
         (item (project-ical-component component))
         (node
           (project-ical-item-to-semantic-node
            item :node-id "node:todo-1" :binding-id "binding:todo-1"
            :ownership :organizer :write-policy :bidirectional))
         (parsed (round-trip-ical-semantic-node node))
         (task (semantic-node-task parsed)))
    (assert-true (task-facet-done-p task))
    (assert-equal "icalendar/vtodo" (task-facet-workflow-id task)
                  :test #'string=)
    (assert-equal 100 (task-facet-progress task))
    (assert-equal 3 (task-facet-priority task))
    (assert-equal :utc (temporal-value-kind (task-facet-closed task)))
    (assert-equal "Remote"
                  (cdr (assoc "icalendar.location"
                              (semantic-node-properties parsed)
                              :test #'string=))
                  :test #'string=)))

(define-foundation-test semantic-projection-refuses-invalid-or-ambiguous-items
  (let* ((invalid-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:invalid" "END:VEVENT"))
         (invalid (project-ical-component invalid-component :method-present-p t))
         (period-component
           (parse-first-ical-item-component
            "BEGIN:VEVENT" "UID:period" "DTSTAMP:20260724T090000Z"
            "DTSTART:20260724T100000Z"
            "RDATE;VALUE=PERIOD:20260725T100000Z/20260725T110000Z,20260726T100000Z/PT2H"
            "END:VEVENT"))
         (period (project-ical-component period-component))
         (period-node
           (project-ical-item-to-semantic-node
            period :node-id "node:period" :binding-id "binding:period"
            :ownership :server :write-policy :read-only)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (project-ical-item-to-semantic-node
        invalid :node-id "node:invalid" :binding-id "binding:invalid"
        :ownership :server :write-policy :read-only)))
    (let* ((recurrence
             (event-facet-recurrence (semantic-node-event period-node)))
           (date (first (recurrence-dates recurrence)))
           (duration-date (second (recurrence-dates recurrence))))
      (assert-true (recurrence-period-p date))
      (assert-equal
       "2026-07-25T10:00:00Z"
       (temporal-value-local-value (recurrence-period-start date))
       :test #'string=)
      (assert-equal
       "2026-07-25T11:00:00Z"
       (temporal-value-local-value (recurrence-period-end date))
       :test #'string=)
      (assert-equal "PT2H"
                    (recurrence-period-duration duration-date)
                    :test #'string=))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (project-ical-item-to-semantic-node
        (project-ical-component
         (parse-first-ical-item-component
          "BEGIN:VEVENT" "UID:ownership" "DTSTAMP:20260724T090000Z"
          "DTSTART:20260724T100000Z" "END:VEVENT"))
        :node-id "node:ownership" :binding-id "binding:ownership")))))

(define-foundation-test validated-vjournal-projects-to-neutral-journal-binding
  (let* ((item
           (project-ical-component
            (parse-first-ical-item-component
             "BEGIN:VJOURNAL" "UID:journal-semantic-1"
             "DTSTAMP:20260728T090000Z" "DTSTART;VALUE=DATE:20260728"
             "SUMMARY:Daily record" "DESCRIPTION:First note"
             "DESCRIPTION:Second note" "END:VJOURNAL")))
         (node
           (project-ical-item-to-semantic-node
            item :node-id "node:journal-1" :binding-id "binding:journal-1"
            :ownership :server :write-policy :read-only))
         (binding (first (semantic-node-calendar-bindings node))))
    (assert-true (ical-calendar-item-valid-p item))
    (assert-equal :journal (calendar-binding-projection-kind binding))
    (assert-false (semantic-node-event node))
    (assert-false (semantic-node-task node))
    (assert-equal '("First note" "Second note")
                  (mapcar #'cdr
                          (remove-if-not
                           (lambda (property)
                             (string= "icalendar.description" (car property)))
                           (semantic-node-properties node))))))
