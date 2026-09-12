(in-package #:lem-structured-notes)

(defun ical-semantic-recurrence-date (value)
  (cond
    ((temporal-value-p value) value)
    ((ical-period-value-p value)
     (make-recurrence-period
      :start (ical-period-value-start value)
      :end (ical-period-value-end value)
      :duration
      (and (ical-period-value-duration value)
           (ical-duration-value-original-lexeme
            (ical-period-value-duration value)))
      :original-lexeme (ical-period-value-original-lexeme value)))
    (t
     (model-error :unsupported-icalendar-recurrence-date value
                  "RDATE must decode to DATE DATE-TIME or PERIOD"))))

(defun ical-semantic-recurrence (item)
  (let ((dates (ical-calendar-item-recurrence-dates item))
        (exceptions (ical-calendar-item-recurrence-exception-dates item))
        (rule (ical-calendar-item-recurrence-rule item)))
    (unless (every #'temporal-value-p exceptions)
      (model-error
       :unsupported-icalendar-recurrence-exception exceptions
       "neutral recurrence exceptions must be DATE or DATE-TIME values"))
    (when (or rule dates exceptions)
      (make-recurrence
       :rules (if rule (list (encode-ical-recur rule)) nil)
       :dates (mapcar #'ical-semantic-recurrence-date dates)
       :exception-dates exceptions
       :policy :fixed
       :original-lexeme
       (and rule (ical-recur-value-original-lexeme rule))))))

(defun ical-semantic-url (item)
  (let ((url (ical-calendar-item-url item)))
    (and url (ical-uri-value-original-lexeme url))))

(defun ical-semantic-transparency (item)
  (let ((value (ical-calendar-item-transparency item)))
    (and value
         (if (string= "OPAQUE" (string-upcase value))
             :opaque
             :transparent))))

(defun ical-semantic-properties (item)
  (let ((properties nil))
    ;; DESCRIPTION is RFC 5545 TEXT, not Markdown.  Store the decoded plain
    ;; string explicitly; the retained source component remains authoritative
    ;; for its exact iCalendar representation.
    (dolist (description (ical-calendar-item-descriptions item))
      (push (cons "icalendar.description" description) properties))
    (when (and (eq :todo (ical-calendar-item-kind item))
               (ical-calendar-item-location item))
      (push (cons "icalendar.location"
                  (ical-calendar-item-location item))
            properties))
    (when (and (eq :todo (ical-calendar-item-kind item))
               (ical-calendar-item-url item))
      (push (cons "icalendar.url" (ical-semantic-url item)) properties))
    (when (and (eq :todo (ical-calendar-item-kind item))
               (ical-calendar-item-duration item))
      (push (cons "icalendar.duration"
                  (ical-duration-value-original-lexeme
                   (ical-calendar-item-duration item)))
            properties))
    (nreverse properties)))

(defun ical-semantic-event (item recurrence)
  (make-event-facet
   :start (ical-calendar-item-start item)
   :end (ical-calendar-item-end item)
   :duration
   (and (ical-calendar-item-duration item)
        (ical-duration-value-original-lexeme
         (ical-calendar-item-duration item)))
   :status (ical-calendar-item-status item)
   :location (ical-calendar-item-location item)
   :url (ical-semantic-url item)
   :transparency (ical-semantic-transparency item)
   :recurrence recurrence))

(defun ical-semantic-task (item recurrence)
  (let* ((status (or (ical-calendar-item-status item) "NEEDS-ACTION"))
         (normalized (string-upcase status)))
    (make-task-facet
     :workflow-id "icalendar/vtodo"
     :state status
     :done-p (not (null (member normalized '("COMPLETED" "CANCELLED")
                                :test #'string=)))
     :priority (ical-calendar-item-priority item)
     :progress (ical-calendar-item-percent-complete item)
     :scheduled (ical-calendar-item-start item)
     :deadline (ical-calendar-item-due item)
     :closed (ical-calendar-item-completed item)
     :recurrence recurrence)))

(defun project-ical-item-to-semantic-node
    (item &key node-id binding-id account-id calendar-id ownership write-policy
               (level 1) parent-id)
  "Build a source-backed neutral view of one validated iCalendar item.

The caller must retain ITEM (and therefore its component CST) as the
authoritative lossless iCalendar source.  NODE-ID and BINDING-ID are local
identities.  OWNERSHIP and WRITE-POLICY are deliberately mandatory because
neither can be inferred safely from VEVENT, VTODO, or VJOURNAL content."
  (unless (ical-calendar-item-p item)
    (model-error :invalid-icalendar-item item
                 "value must be a projected iCalendar item"))
  (unless (ical-calendar-item-valid-p item)
    (model-error :invalid-icalendar-semantic-projection
                 (ical-calendar-item-diagnostics item)
                 "invalid iCalendar items cannot be projected into notes"))
  (unless ownership
    (model-error :missing-calendar-ownership item
                 "semantic projection requires explicit calendar ownership"))
  (unless write-policy
    (model-error :missing-calendar-write-policy item
                 "semantic projection requires an explicit write policy"))
  (let* ((kind (ical-calendar-item-kind item))
         (recurrence (ical-semantic-recurrence item))
         (binding
           (make-calendar-binding
            :id binding-id :node-id node-id
            :projection-kind
            (ecase kind (:event :event) (:todo :task) (:journal :journal))
            :account-id account-id :calendar-id calendar-id
            :uid (ical-calendar-item-uid item)
            :recurrence-id (ical-calendar-item-recurrence-id item)
            :ownership ownership :write-policy write-policy)))
    (make-semantic-node
     :id node-id :level level :title (or (ical-calendar-item-summary item) "")
     :parent-id parent-id
     :tags (remove-if-not #'non-empty-string-p
                          (ical-calendar-item-categories item))
     :properties (ical-semantic-properties item)
     :event (and (eq kind :event) (ical-semantic-event item recurrence))
     :task (and (eq kind :todo) (ical-semantic-task item recurrence))
     :calendar-bindings (list binding))))
