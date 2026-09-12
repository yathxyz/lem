(in-package #:lem-structured-notes)

(define-condition semantic-model-error (error)
  ((code
    :initarg :code
    :reader semantic-model-error-code)
   (value
    :initarg :value
    :reader semantic-model-error-value)
   (message
    :initarg :message
    :reader semantic-model-error-message))
  (:report
   (lambda (condition stream)
     (format stream "Semantic model error ~a: ~a~@[ (~s)~]"
             (semantic-model-error-code condition)
             (semantic-model-error-message condition)
             (semantic-model-error-value condition)))))

(defun model-error (code value control &rest arguments)
  (error 'semantic-model-error
         :code code
         :value value
         :message (apply #'format nil control arguments)))

(defun non-empty-string-p (value)
  (and (stringp value) (plusp (length value))))

(defun require-non-empty-string (value code label)
  (unless (non-empty-string-p value)
    (model-error code value "~a must be a non-empty string" label))
  value)

(defun proper-list-p (value)
  (and (listp value)
       (handler-case
           (integerp (list-length value))
         (type-error () nil))))

(defun copy-proper-list (value code label)
  (unless (proper-list-p value)
    (model-error code value "~a must be a finite proper list" label))
  (copy-list value))

(defun require-membership (value choices code label)
  (unless (member value choices)
    (model-error code value "~a must be one of ~{~s~^, ~}" label choices))
  value)

(defstruct (source-span
            (:constructor %make-source-span
                (source-id character-start character-end byte-start byte-end)))
  (source-id "" :type string :read-only t)
  (character-start 0 :type (integer 0) :read-only t)
  (character-end 0 :type (integer 0) :read-only t)
  (byte-start nil :type (or null (integer 0)) :read-only t)
  (byte-end nil :type (or null (integer 0)) :read-only t))

(defun make-source-span
    (&key source-id character-start character-end byte-start byte-end)
  "Create a half-open source span after validating character and byte bounds."
  (require-non-empty-string source-id :invalid-source-id "source ID")
  (unless (and (integerp character-start) (not (minusp character-start)))
    (model-error :invalid-character-start character-start
                 "character start must be a non-negative integer"))
  (unless (and (integerp character-end) (>= character-end character-start))
    (model-error :invalid-character-end character-end
                 "character end must be an integer at or after the start"))
  (unless (or (and (null byte-start) (null byte-end))
              (and (integerp byte-start)
                   (not (minusp byte-start))
                   (integerp byte-end)
                   (>= byte-end byte-start)))
    (model-error :invalid-byte-span (cons byte-start byte-end)
                 "byte bounds must both be absent or form a non-negative span"))
  (%make-source-span source-id character-start character-end
                     byte-start byte-end))

(defstruct (diagnostic
            (:constructor %make-diagnostic
                (severity code message span remediation loss-risk)))
  (severity :info :type keyword :read-only t)
  code
  (message "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (remediation nil :type (or null string) :read-only t)
  (loss-risk :none :type keyword :read-only t))

(defun make-diagnostic
    (&key severity code message span remediation (loss-risk :none))
  (require-membership severity '(:info :warning :error :fatal)
                      :invalid-diagnostic-severity "diagnostic severity")
  (unless (or (keywordp code) (non-empty-string-p code))
    (model-error :invalid-diagnostic-code code
                 "diagnostic code must be a keyword or non-empty string"))
  (require-non-empty-string message :invalid-diagnostic-message
                            "diagnostic message")
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-diagnostic-span span
                 "diagnostic span must be a source span or NIL"))
  (unless (or (null remediation) (stringp remediation))
    (model-error :invalid-remediation remediation
                 "diagnostic remediation must be a string or NIL"))
  (require-membership loss-risk '(:none :approximation :loss :security)
                      :invalid-loss-risk "diagnostic loss risk")
  (%make-diagnostic severity code message span remediation loss-risk))

(defstruct (temporal-value
            (:constructor %make-temporal-value
                (kind local-value timezone-id fold gap-policy precision
                 original-lexeme)))
  (kind :date :type keyword :read-only t)
  (local-value "" :type string :read-only t)
  (timezone-id nil :type (or null string) :read-only t)
  (fold nil :type (or null (integer 0 1)) :read-only t)
  (gap-policy nil :type (or null keyword) :read-only t)
  (precision :date :type keyword :read-only t)
  (original-lexeme nil :type (or null string) :read-only t))

(defun make-temporal-value
    (&key kind local-value timezone-id fold gap-policy precision
          original-lexeme)
  "Create a temporal value without collapsing date, floating, UTC, or TZID."
  (require-membership kind '(:date :floating :utc :zoned)
                      :invalid-temporal-kind "temporal kind")
  (require-non-empty-string local-value :invalid-temporal-value
                            "temporal local value")
  (let ((precision (or precision (if (eq kind :date) :date :second))))
    (require-membership precision '(:date :minute :second :subsecond)
                        :invalid-temporal-precision "temporal precision")
    (when (and (eq kind :date) (not (eq precision :date)))
      (model-error :date-has-time-precision precision
                   "an all-day date must have date precision"))
    (when (and (not (eq kind :date)) (eq precision :date))
      (model-error :datetime-has-date-precision precision
                   "a date-time cannot have date-only precision"))
    (if (eq kind :zoned)
        (require-non-empty-string timezone-id :missing-timezone-id
                                  "zoned temporal timezone ID")
        (when timezone-id
          (model-error :unexpected-timezone-id timezone-id
                       "only a zoned temporal value carries a timezone ID")))
    (when (and fold (not (eq kind :zoned)))
      (model-error :unexpected-fold fold
                   "only a zoned temporal value can select a DST fold"))
    (unless (member fold '(nil 0 1))
      (model-error :invalid-fold fold "fold must be NIL, 0, or 1"))
    (unless (member gap-policy
                    '(nil :reject :rfc5545 :earlier :later :shift-forward
                      :shift-backward))
      (model-error :invalid-gap-policy gap-policy
                   "invalid local-time gap policy"))
    (when (and gap-policy (not (eq kind :zoned)))
      (model-error :unexpected-gap-policy gap-policy
                   "only a zoned temporal value can have a gap policy"))
    (unless (or (null original-lexeme) (stringp original-lexeme))
      (model-error :invalid-temporal-lexeme original-lexeme
                   "original temporal lexeme must be a string or NIL"))
    (%make-temporal-value kind local-value timezone-id fold gap-policy
                          precision original-lexeme)))

(defstruct (recurrence-period
            (:constructor %make-recurrence-period
                (start end duration original-lexeme)))
  (start nil :type temporal-value :read-only t)
  (end nil :type (or null temporal-value) :read-only t)
  (duration nil :type (or null string) :read-only t)
  (original-lexeme nil :type (or null string) :read-only t))

(defun positive-duration-lexeme-p (value)
  (when (non-empty-string-p value)
    (labels
        ((read-number (index)
           (let ((start index))
             (loop :while (and (< index (length value))
                               (digit-char-p (char value index)))
                   :do (incf index))
             (if (= start index)
                 (values nil index)
                 (values (parse-integer value :start start :end index)
                         index))))
         (read-final-seconds (index total)
           (multiple-value-bind (seconds next) (read-number index)
             (and seconds (< next (length value))
                  (char= (char value next) #\S)
                  (= (1+ next) (length value))
                  (plusp (+ total seconds)))))
         (read-minutes (index total)
           (multiple-value-bind (minutes next) (read-number index)
             (and minutes (< next (length value))
                  (char= (char value next) #\M)
                  (let ((sum (+ total (* minutes 60)))
                        (after (1+ next)))
                    (if (= after (length value))
                        (plusp sum)
                        (read-final-seconds after sum))))))
         (read-time (index total)
           (multiple-value-bind (amount next) (read-number index)
             (when (and amount (< next (length value)))
               (case (char value next)
                 (#\H
                  (let ((sum (+ total (* amount 3600)))
                        (after (1+ next)))
                    (if (= after (length value))
                        (plusp sum)
                        (read-minutes after sum))))
                 (#\M
                  (let ((sum (+ total (* amount 60)))
                        (after (1+ next)))
                    (if (= after (length value))
                        (plusp sum)
                        (read-final-seconds after sum))))
                 (#\S
                  (and (= (1+ next) (length value))
                       (plusp (+ total amount))))
                 (otherwise nil))))))
      (let* ((position (if (char= (char value 0) #\+) 1 0))
             (length (length value)))
        (when (and (< position length)
                   (char= (char value position) #\P))
          (incf position)
          (when (< position length)
            (if (char= (char value position) #\T)
                (read-time (1+ position) 0)
                (multiple-value-bind (amount next) (read-number position)
                  (when (and amount (< next length))
                    (case (char value next)
                      (#\W
                       (and (= (1+ next) length) (plusp amount)))
                      (#\D
                       (let ((days (* amount 86400))
                             (after (1+ next)))
                         (cond
                           ((= after length) (plusp days))
                           ((char= (char value after) #\T)
                            (read-time (1+ after) days))
                           (t nil))))
                      (otherwise nil)))))))))))

(defun make-recurrence-period
    (&key start end duration original-lexeme)
  (unless (and (temporal-value-p start)
               (not (eq :date (temporal-value-kind start))))
    (model-error :invalid-recurrence-period-start start
                 "recurrence period start must be a DATE-TIME temporal value"))
  (unless (not (eq (null end) (null duration)))
    (model-error :invalid-recurrence-period-finish (cons end duration)
                 "recurrence period requires exactly one of end or duration"))
  (when end
    (unless (and (temporal-value-p end)
                 (eq (temporal-value-kind start)
                     (temporal-value-kind end))
                 (equal (temporal-value-timezone-id start)
                        (temporal-value-timezone-id end))
                 (string< (temporal-value-local-value start)
                          (temporal-value-local-value end)))
      (model-error :invalid-recurrence-period-end end
                   "recurrence period end must be a later compatible DATE-TIME")))
  (when (and duration (not (positive-duration-lexeme-p duration)))
    (model-error :invalid-recurrence-period-duration duration
                 "recurrence period duration must use positive RFC 5545 DURATION grammar"))
  (unless (or (null original-lexeme) (stringp original-lexeme))
    (model-error :invalid-recurrence-period-lexeme original-lexeme
                 "recurrence period original lexeme must be a string or NIL"))
  (%make-recurrence-period start end duration original-lexeme))

(defstruct (recurrence
            (:constructor %make-recurrence
                (rules dates exception-dates policy original-lexeme)))
  (rules nil :type list :read-only t)
  (dates nil :type list :read-only t)
  (exception-dates nil :type list :read-only t)
  (policy :none :type keyword :read-only t)
  (original-lexeme nil :type (or null string) :read-only t))

(defun make-recurrence
    (&key (rules nil) (dates nil) (exception-dates nil) (policy :none)
          original-lexeme)
  (let ((rules (copy-proper-list rules :invalid-recurrence-rules
                                 "recurrence rules"))
        (dates (copy-proper-list dates :invalid-recurrence-dates
                                 "recurrence dates"))
        (exception-dates
          (copy-proper-list exception-dates :invalid-recurrence-exceptions
                            "recurrence exception dates")))
    (unless (every #'non-empty-string-p rules)
      (model-error :invalid-recurrence-rule rules
                   "each recurrence rule must be a non-empty string"))
    (unless (every (lambda (value)
                     (or (temporal-value-p value)
                         (recurrence-period-p value)))
                   dates)
      (model-error :invalid-recurrence-date dates
                   "each recurrence date must be a temporal value or recurrence period"))
    (unless (every #'temporal-value-p exception-dates)
      (model-error :invalid-recurrence-exception exception-dates
                   "each recurrence exception must be a temporal value"))
    (require-membership policy '(:none :fixed :catch-up :completion-relative)
                        :invalid-recurrence-policy "recurrence policy")
    (unless (or (null original-lexeme) (stringp original-lexeme))
      (model-error :invalid-recurrence-lexeme original-lexeme
                   "original recurrence lexeme must be a string or NIL"))
    (%make-recurrence rules dates exception-dates policy original-lexeme)))

(defstruct (opaque-extension
            (:constructor %make-opaque-extension
                (namespace media-type owner-id raw-value ordering-anchor
                 provenance)))
  (namespace "" :type string :read-only t)
  (media-type nil :type (or null string) :read-only t)
  (owner-id nil :type (or null string) :read-only t)
  raw-value
  ordering-anchor
  provenance)

(defun make-opaque-extension
    (&key namespace media-type owner-id raw-value ordering-anchor provenance)
  (require-non-empty-string namespace :invalid-extension-namespace
                            "extension namespace")
  (unless (or (null media-type) (non-empty-string-p media-type))
    (model-error :invalid-extension-media-type media-type
                 "extension media type must be a non-empty string or NIL"))
  (unless (or (null owner-id) (non-empty-string-p owner-id))
    (model-error :invalid-extension-owner owner-id
                 "extension owner ID must be a non-empty string or NIL"))
  (%make-opaque-extension namespace media-type owner-id raw-value
                          ordering-anchor provenance))

(defstruct (calendar-binding
            (:constructor %make-calendar-binding
                (id node-id projection-kind account-id calendar-id uid
                 recurrence-id ownership write-policy)))
  (id "" :type string :read-only t)
  (node-id "" :type string :read-only t)
  (projection-kind :event :type keyword :read-only t)
  (account-id nil :type (or null string) :read-only t)
  (calendar-id nil :type (or null string) :read-only t)
  (uid nil :type (or null string) :read-only t)
  (recurrence-id nil :type (or null temporal-value) :read-only t)
  (ownership :local :type keyword :read-only t)
  (write-policy :local-only :type keyword :read-only t))

(defun make-calendar-binding
    (&key id node-id projection-kind account-id calendar-id uid recurrence-id
          (ownership :local) (write-policy :local-only))
  (require-non-empty-string id :invalid-binding-id "calendar binding ID")
  (require-non-empty-string node-id :invalid-binding-node-id
                            "calendar binding node ID")
  (require-membership projection-kind '(:event :task :journal :availability)
                      :invalid-projection-kind "calendar projection kind")
  (dolist (entry (list (cons account-id "account ID")
                       (cons calendar-id "calendar ID")
                       (cons uid "calendar UID")))
    (unless (or (null (car entry)) (non-empty-string-p (car entry)))
      (model-error :invalid-binding-reference (car entry)
                   "~a must be a non-empty string or NIL" (cdr entry))))
  (unless (or (null recurrence-id) (temporal-value-p recurrence-id))
    (model-error :invalid-recurrence-id recurrence-id
                 "recurrence ID must be a temporal value or NIL"))
  (require-membership ownership '(:local :organizer :attendee :server)
                      :invalid-binding-ownership "calendar binding ownership")
  (require-membership write-policy
                      '(:bidirectional :local-only :remote-only :read-only)
                      :invalid-write-policy "calendar binding write policy")
  (%make-calendar-binding id node-id projection-kind account-id calendar-id
                          uid recurrence-id ownership write-policy))

(defun calendar-write-policy-allows-inbound-sync-p (write-policy)
  "Return true when remote state may update the local projection."
  (not (null (member write-policy
                     '(:bidirectional :remote-only :read-only)))))

(defun calendar-write-policy-allows-outbound-sync-p (write-policy)
  "Return true when local state may update the remote calendar resource."
  (not (null (member write-policy '(:bidirectional :local-only)))))

(defstruct (event-facet
            (:constructor %make-event-facet
                (start end duration status location url transparency
                 recurrence)))
  (start nil :type (or null temporal-value) :read-only t)
  (end nil :type (or null temporal-value) :read-only t)
  (duration nil :type (or null string) :read-only t)
  (status nil :type (or null string) :read-only t)
  (location nil :type (or null string) :read-only t)
  (url nil :type (or null string) :read-only t)
  (transparency nil :type (or null keyword) :read-only t)
  (recurrence nil :type (or null recurrence) :read-only t))

(defun make-event-facet
    (&key start end duration status location url transparency recurrence)
  (dolist (entry (list (cons start "start") (cons end "end")))
    (unless (or (null (car entry)) (temporal-value-p (car entry)))
      (model-error :invalid-event-temporal (car entry)
                   "event ~a must be a temporal value or NIL" (cdr entry))))
  (when (and end duration)
    (model-error :conflicting-event-end (list end duration)
                 "event end and duration are mutually exclusive"))
  (dolist (entry (list (cons duration "duration") (cons status "status")
                       (cons location "location") (cons url "URL")))
    (unless (or (null (car entry)) (stringp (car entry)))
      (model-error :invalid-event-text (car entry)
                   "event ~a must be a string or NIL" (cdr entry))))
  (unless (member transparency '(nil :opaque :transparent))
    (model-error :invalid-event-transparency transparency
                 "event transparency must be OPAQUE, TRANSPARENT, or NIL"))
  (unless (or (null recurrence) (recurrence-p recurrence))
    (model-error :invalid-event-recurrence recurrence
                 "event recurrence must be a recurrence value or NIL"))
  (%make-event-facet start end duration status location url transparency
                     recurrence))

(defstruct (task-clock
            (:constructor %make-task-clock (start end)))
  "One format-neutral task clock interval.  NIL END denotes an open clock."
  (start nil :type temporal-value :read-only t)
  (end nil :type (or null temporal-value) :read-only t))

(defun task-clock-temporal-p (value)
  (and (temporal-value-p value)
       (member (temporal-value-kind value) '(:floating :utc :zoned))))

(defun make-task-clock (&key start end)
  (unless (task-clock-temporal-p start)
    (model-error :invalid-task-clock-start start
                 "task clock start must be a date-time temporal value"))
  (unless (or (null end) (task-clock-temporal-p end))
    (model-error :invalid-task-clock-end end
                 "task clock end must be a date-time temporal value or NIL"))
  (when (and end
             (not (eq (temporal-value-kind start)
                      (temporal-value-kind end))))
    (model-error :incompatible-task-clock-kinds (list start end)
                 "task clock start and end must use the same temporal kind"))
  (when (and end
             (not (equal (temporal-value-timezone-id start)
                         (temporal-value-timezone-id end))))
    (model-error :incompatible-task-clock-timezones (list start end)
                 "task clock start and end must use the same timezone"))
  (when (and end
             (string< (temporal-value-local-value end)
                      (temporal-value-local-value start)))
    (model-error :reversed-task-clock (list start end)
                 "task clock end cannot precede its start"))
  (%make-task-clock start end))

(defstruct (task-facet
            (:constructor %make-task-facet
                (workflow-id state done-p priority progress effort scheduled
                 scheduled-delay deadline closed deadline-warning recurrence
                 dependencies logs)))
  (workflow-id "" :type string :read-only t)
  (state "" :type string :read-only t)
  (done-p nil :type boolean :read-only t)
  priority
  (progress nil :type (or null (integer 0 100)) :read-only t)
  (effort nil :type (or null string) :read-only t)
  (scheduled nil :type (or null temporal-value) :read-only t)
  (scheduled-delay nil :type (or null string) :read-only t)
  (deadline nil :type (or null temporal-value) :read-only t)
  (closed nil :type (or null temporal-value) :read-only t)
  (deadline-warning nil :type (or null string) :read-only t)
  (recurrence nil :type (or null recurrence) :read-only t)
  (dependencies nil :type list :read-only t)
  (logs nil :type list :read-only t))

(defun task-effort-duration-p (value)
  "Return true when VALUE is in the frozen agenda Effort input domain."
  (and
   (stringp value)
   (labels ((space-p (character)
              (member character
                      '(#\Space #\Tab #\Newline #\Return #\Page)))
            (skip-space (position limit)
              (loop :while (and (< position limit)
                                (space-p (char value position)))
                    :do (incf position)
                    :finally (return position)))
            (digits-end (position limit)
              (let ((start position))
                (loop :while (and (< position limit)
                                  (digit-char-p (char value position)))
                      :do (incf position))
                (and (> position start) position)))
            (decimal-end (position limit)
              (let ((end (digits-end position limit)))
                (when end
                  (if (and (< end limit) (char= #\. (char value end)))
                      (or (digits-end (1+ end) limit) (1+ end))
                      end))))
            (two-digits-end (position limit)
              (and (< (1+ position) limit)
                   (digit-char-p (char value position))
                   (digit-char-p (char value (1+ position)))
                   (+ position 2)))
            (time-end (position limit)
              (let ((end (digits-end position limit)))
                (when (and end (< end limit)
                           (char= #\: (char value end)))
                  (let ((minutes (two-digits-end (1+ end) limit)))
                    (when minutes
                      (if (and (< minutes limit)
                               (char= #\: (char value minutes)))
                          (two-digits-end (1+ minutes) limit)
                          minutes))))))
            (unit-end (position limit)
              (find-if
               (lambda (unit)
                 (and (<= (+ position (length unit)) limit)
                      (string= unit value :start2 position
                                          :end2 (+ position (length unit)))))
               '("min" "h" "d" "w" "m" "y")))
            (units-end (position limit)
              (let ((count 0))
                (loop
                  (let* ((number-start position)
                         (number-end (decimal-end position limit))
                         (after-number
                           (and number-end (skip-space number-end limit)))
                         (unit
                           (and after-number (unit-end after-number limit))))
                    (unless unit
                      (return
                        (and (plusp count)
                             (time-end number-start limit))))
                    (incf count)
                    (setf position
                          (skip-space (+ after-number (length unit)) limit))
                    (when (= position limit) (return position)))))))
     (let* ((length (length value))
            (start (skip-space 0 length))
            (end
              (loop :for position :downfrom length :above start
                    :while (space-p (char value (1- position)))
                    :finally (return position))))
       (or (zerop length)
           (and (< start end)
                (or (= (or (decimal-end start end) -1) end)
                    (= (or (time-end start end) -1) end)
                    (= (or (units-end start end) -1) end))))))))

(defun make-task-facet
    (&key workflow-id state (done-p nil) priority progress effort scheduled
          scheduled-delay deadline closed deadline-warning recurrence
          (dependencies nil) (logs nil))
  (require-non-empty-string workflow-id :invalid-workflow-id "workflow ID")
  (require-non-empty-string state :invalid-task-state "task state")
  (unless (typep done-p 'boolean)
    (model-error :invalid-done-flag done-p "done flag must be boolean"))
  (unless (or (null priority) (stringp priority) (integerp priority))
    (model-error :invalid-priority priority
                 "priority must be a string, integer, or NIL"))
  (unless (or (null progress)
              (and (integerp progress) (<= 0 progress 100)))
    (model-error :invalid-progress progress
                 "task progress must be an integer from 0 through 100 or NIL"))
  (dolist (entry (list (cons effort "effort")
                       (cons scheduled-delay "scheduled delay")
                       (cons deadline-warning "deadline warning")))
    (unless (or (null (car entry)) (stringp (car entry)))
      (model-error :invalid-task-text (car entry)
                   "task ~a must be a string or NIL" (cdr entry))))
  (dolist (entry (list (cons scheduled "scheduled")
                       (cons deadline "deadline")
                       (cons closed "closed")))
    (unless (or (null (car entry)) (temporal-value-p (car entry)))
      (model-error :invalid-task-temporal (car entry)
                   "task ~a must be a temporal value or NIL" (cdr entry))))
  (unless (or (null recurrence) (recurrence-p recurrence))
    (model-error :invalid-task-recurrence recurrence
                 "task recurrence must be a recurrence value or NIL"))
  (let ((logs (copy-proper-list logs :invalid-task-logs "task logs")))
    (unless (every #'task-clock-p logs)
      (model-error :invalid-task-logs logs
                   "task logs must contain only typed task clocks"))
    (%make-task-facet workflow-id state done-p priority progress effort
                      scheduled scheduled-delay deadline closed deadline-warning
                      recurrence
                      (copy-proper-list dependencies :invalid-dependencies
                                        "task dependencies")
                      logs)))

(defparameter *content-node-kinds*
  '(:blank :paragraph :quote :list :table :source-block :block :drawer :comment
    :keyword :opaque)
  "Block-level content kinds in the initial neutral content schema.")

(defparameter *inline-node-kinds*
  '(:text :emphasis :strong :code :link)
  "Inline semantic kinds implemented by the initial Org/CommonMark profile.")

(defstruct (node-reference
            (:constructor %make-node-reference (kind value)))
  (kind :citation :type keyword :read-only t)
  (value "" :type string :read-only t))

(defun node-citation-key-character-p (character)
  (or (alphanumericp character)
      (member character '(#\- #\_ #\+ #\: #\. #\/))))

(defun make-node-reference (&key kind value)
  (require-membership kind '(:citation :url)
                      :invalid-node-reference-kind "node reference kind")
  (require-non-empty-string value :invalid-node-reference-value
                            "node reference value")
  (ecase kind
    (:citation
     (unless (every #'node-citation-key-character-p value)
       (model-error :invalid-node-citation-key value
                    "citation keys contain unsupported characters")))
    (:url
     (unless (and (or (and (>= (length value) 7)
                           (string-equal "http://" value :end2 7))
                      (and (>= (length value) 8)
                           (string-equal "https://" value :end2 8)))
                  (every (lambda (character)
                           (and (graphic-char-p character)
                                (not (member character
                                             '(#\Space #\Tab #\Newline
                                               #\Return)))))
                         value))
       (model-error :invalid-node-reference-url value
                    "URL references require bounded HTTP(S) text"))))
  (%make-node-reference kind value))

(defstruct (inline-node
            (:constructor %make-inline-node
                (kind source-format raw span text destination children
                 attributes)))
  (kind :text :type keyword :read-only t)
  (source-format :org :type keyword :read-only t)
  (raw "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (text nil :type (or null string) :read-only t)
  (destination nil :type (or null string) :read-only t)
  (children nil :type list :read-only t)
  (attributes nil :type list :read-only t))

(defun make-inline-node
    (&key kind source-format raw span text destination (children nil)
          (attributes nil))
  (require-membership kind *inline-node-kinds*
                      :invalid-inline-kind "inline kind")
  (require-membership source-format '(:org :lsm :commonmark :myst)
                      :invalid-inline-format "inline source format")
  (unless (stringp raw)
    (model-error :invalid-inline-raw raw
                 "inline raw source must be a string"))
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-inline-span span
                 "inline span must be a source span or NIL"))
  (let ((children (copy-proper-list children :invalid-inline-children
                                    "inline children"))
        (attributes (copy-proper-list attributes :invalid-inline-attributes
                                      "inline attributes")))
    (unless (every #'inline-node-p children)
      (model-error :invalid-inline-child children
                   "every inline child must be an inline node"))
    (unless (every #'consp attributes)
      (model-error :invalid-inline-attribute attributes
                   "inline attributes must be an association list"))
    (ecase kind
      ((:text :code)
       (unless (and (stringp text) (plusp (length text))
                    (null destination) (null children))
         (model-error :invalid-inline-leaf kind
                      "text and code nodes require non-empty text only")))
      ((:emphasis :strong)
       (unless (and children (null text) (null destination))
         (model-error :invalid-inline-container kind
                      "emphasis and strong nodes require children only")))
      (:link
       (unless (and children (null text)
                    (non-empty-string-p destination))
         (model-error :invalid-inline-link destination
                      "link nodes require children and a destination"))))
    (%make-inline-node kind source-format raw span text destination
                       children attributes)))

(defstruct (list-item
            (:constructor %make-list-item
                (source-format raw span ordered-p ordinal checkbox inlines
                 attributes)))
  (source-format :org :type keyword :read-only t)
  (raw "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (ordered-p nil :type boolean :read-only t)
  (ordinal nil :type (or null (integer 1)) :read-only t)
  (checkbox nil :type (or null keyword) :read-only t)
  (inlines nil :type list :read-only t)
  (attributes nil :type list :read-only t))

(defun make-list-item
    (&key source-format raw span (ordered-p nil) ordinal checkbox inlines
          (attributes nil))
  (require-membership source-format '(:org :lsm :commonmark :myst)
                      :invalid-list-item-format "list item source format")
  (unless (stringp raw)
    (model-error :invalid-list-item-raw raw
                 "list item raw source must be a string"))
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-list-item-span span
                 "list item span must be a source span or NIL"))
  (unless (typep ordered-p 'boolean)
    (model-error :invalid-list-order ordered-p
                 "list item ordered flag must be boolean"))
  (unless (if ordered-p
              (and (integerp ordinal) (plusp ordinal))
              (null ordinal))
    (model-error :invalid-list-ordinal ordinal
                 "ordered items require a positive ordinal; unordered items require NIL"))
  (unless (member checkbox '(nil :unchecked :checked :partial))
    (model-error :invalid-list-checkbox checkbox
                 "list checkbox must be unchecked, checked, partial, or NIL"))
  (let ((inlines (copy-proper-list inlines :invalid-list-item-inlines
                                   "list item inlines"))
        (attributes (copy-proper-list attributes
                                      :invalid-list-item-attributes
                                      "list item attributes")))
    (unless (every #'inline-node-p inlines)
      (model-error :invalid-list-item-inline inlines
                   "every list item inline must be an inline node"))
    (unless (every #'consp attributes)
      (model-error :invalid-list-item-attribute attributes
                   "list item attributes must be an association list"))
    (%make-list-item source-format raw span ordered-p ordinal checkbox
                     inlines attributes)))

(defstruct (table-cell
            (:constructor %make-table-cell
                (source-format raw span inlines attributes)))
  (source-format :org :type keyword :read-only t)
  (raw "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (inlines nil :type list :read-only t)
  (attributes nil :type list :read-only t))

(defun make-table-cell
    (&key source-format raw span (inlines nil) (attributes nil))
  (require-membership source-format '(:org :lsm :commonmark :myst)
                      :invalid-table-cell-format "table cell source format")
  (unless (stringp raw)
    (model-error :invalid-table-cell-raw raw
                 "table cell raw source must be a string"))
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-table-cell-span span
                 "table cell span must be a source span or NIL"))
  (let ((inlines (copy-proper-list inlines :invalid-table-cell-inlines
                                   "table cell inlines"))
        (attributes (copy-proper-list attributes
                                      :invalid-table-cell-attributes
                                      "table cell attributes")))
    (unless (every #'inline-node-p inlines)
      (model-error :invalid-table-cell-inline inlines
                   "every table cell inline must be an inline node"))
    (unless (every #'consp attributes)
      (model-error :invalid-table-cell-attribute attributes
                   "table cell attributes must be an association list"))
    (%make-table-cell source-format raw span inlines attributes)))

(defstruct (table-row
            (:constructor %make-table-row
                (source-format raw span cells attributes)))
  (source-format :org :type keyword :read-only t)
  (raw "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (cells nil :type list :read-only t)
  (attributes nil :type list :read-only t))

(defun make-table-row
    (&key source-format raw span cells (attributes nil))
  (require-membership source-format '(:org :lsm :commonmark :myst)
                      :invalid-table-row-format "table row source format")
  (unless (stringp raw)
    (model-error :invalid-table-row-raw raw
                 "table row raw source must be a string"))
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-table-row-span span
                 "table row span must be a source span or NIL"))
  (let ((cells (copy-proper-list cells :invalid-table-row-cells
                                 "table row cells"))
        (attributes (copy-proper-list attributes
                                      :invalid-table-row-attributes
                                      "table row attributes")))
    (unless (and cells (every #'table-cell-p cells))
      (model-error :invalid-table-row-cell cells
                   "table rows require one or more table cells"))
    (unless (every #'consp attributes)
      (model-error :invalid-table-row-attribute attributes
                   "table row attributes must be an association list"))
    (%make-table-row source-format raw span cells attributes)))

(defstruct (table-data
            (:constructor %make-table-data (alignments rows attributes)))
  (alignments nil :type list :read-only t)
  (rows nil :type list :read-only t)
  (attributes nil :type list :read-only t))

(defun make-table-data (&key alignments rows (attributes nil))
  (let ((alignments (copy-proper-list alignments
                                      :invalid-table-alignments
                                      "table alignments"))
        (rows (copy-proper-list rows :invalid-table-rows "table rows"))
        (attributes (copy-proper-list attributes :invalid-table-attributes
                                      "table attributes")))
    (unless (and alignments
                 (every (lambda (alignment)
                          (member alignment '(:default :left :center :right)))
                        alignments))
      (model-error :invalid-table-alignment alignments
                   "table alignments must use default, left, center, or right"))
    (unless (and rows (every #'table-row-p rows))
      (model-error :invalid-table-row rows
                   "tables require one or more table rows"))
    (unless (every (lambda (row)
                     (= (length alignments)
                        (length (table-row-cells row))))
                   rows)
      (model-error :ragged-table rows
                   "every table row must match the alignment column count"))
    (unless (every #'consp attributes)
      (model-error :invalid-table-attribute attributes
                   "table attributes must be an association list"))
    (%make-table-data alignments rows attributes)))

(defstruct (code-block-data
            (:constructor %make-code-block-data
                (source-format raw span language code attributes)))
  (source-format :org :type keyword :read-only t)
  (raw "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (language nil :type (or null string) :read-only t)
  (code "" :type string :read-only t)
  (attributes nil :type list :read-only t))

(defun make-code-block-data
    (&key source-format raw span language code (attributes nil))
  (require-membership source-format '(:org :lsm :commonmark :myst)
                      :invalid-code-block-format "code block source format")
  (unless (stringp raw)
    (model-error :invalid-code-block-raw raw
                 "code block raw source must be a string"))
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-code-block-span span
                 "code block span must be a source span or NIL"))
  (unless (or (null language)
              (and (non-empty-string-p language)
                   (not (find-if (lambda (character)
                                   (member character '(#\Newline #\Return)))
                                 language))))
    (model-error :invalid-code-language language
                 "code language must be a non-empty single-line string or NIL"))
  (unless (and (stringp code)
               (not (find #\Return code))
               (or (zerop (length code))
                   (char= (char code (1- (length code))) #\Newline)))
    (model-error :invalid-code-text code
                 "normalized code must be empty or LF-terminated and contain no CR"))
  (let ((attributes (copy-proper-list attributes
                                      :invalid-code-block-attributes
                                      "code block attributes")))
    (unless (every #'consp attributes)
      (model-error :invalid-code-block-attribute attributes
                   "code block attributes must be an association list"))
    (%make-code-block-data source-format raw span language code attributes)))

(defstruct (content-node
            (:constructor %make-content-node
                (kind source-format raw span name attributes text inlines
                 items table code-block)))
  (kind :opaque :type keyword :read-only t)
  (source-format :org :type keyword :read-only t)
  (raw "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (name nil :type (or null string) :read-only t)
  (attributes nil :type list :read-only t)
  (text nil :type (or null string) :read-only t)
  (inlines nil :type list :read-only t)
  (items nil :type list :read-only t)
  (table nil :type (or null table-data) :read-only t)
  (code-block nil :type (or null code-block-data) :read-only t))

(defun source-single-line-text (raw)
  (let* ((length (length raw))
         (content-end
           (cond
             ((and (>= length 2)
                   (char= (char raw (- length 2)) #\Return)
                   (char= (char raw (1- length)) #\Newline))
              (- length 2))
             ((and (plusp length)
                   (member (char raw (1- length))
                           '(#\Return #\Newline)))
              (1- length))
             (t length)))
         (text (subseq raw 0 content-end)))
    (when (and (plusp (length text))
               (not (find-if (lambda (character)
                               (member character '(#\Return #\Newline)))
                             text)))
      text)))

(defun native-org-comment-text (raw)
  (let ((line (source-single-line-text raw)))
    (when (and line
               (> (length line) 2)
               (char= (char line 0) #\#)
               (char= (char line 1) #\Space))
      (subseq line 2))))

(defun native-myst-comment-text (raw)
  (let ((line (source-single-line-text raw)))
    (when (and line
               (> (length line) 2)
               (char= (char line 0) #\%)
               (char= (char line 1) #\Space))
      (subseq line 2))))

(defun content-node-native-myst-comment-p (content)
  (and (content-node-p content)
       (eq :comment (content-node-kind content))
       (content-node-text content)
       (null (content-node-name content))
       (null (content-node-attributes content))
       (let ((source-text
               (case (content-node-source-format content)
                 (:org (native-org-comment-text (content-node-raw content)))
                 (:myst (native-myst-comment-text (content-node-raw content)))
                 (otherwise nil))))
         (and source-text
              (string= source-text (content-node-text content))))))

(defun make-content-node
    (&key kind source-format raw span name (attributes nil) text
          (inlines nil) (items nil) table code-block)
  "Create a source-backed block-level semantic content node.

RAW remains mandatory as source evidence even when typed inline semantics exist."
  (require-membership kind *content-node-kinds*
                      :invalid-content-kind "content kind")
  (require-membership source-format '(:org :lsm :commonmark :myst)
                      :invalid-content-format "content source format")
  (unless (stringp raw)
    (model-error :invalid-content-raw raw
                 "content raw source must be a string"))
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-content-span span
                 "content span must be a source span or NIL"))
  (unless (or (null name) (non-empty-string-p name))
    (model-error :invalid-content-name name
                 "content name must be a non-empty string or NIL"))
  (unless (or (null text)
              (and (eq kind :comment) (non-empty-string-p text)))
    (model-error :invalid-content-text text
                 "content text must be a non-empty comment string or NIL"))
  (let ((attributes
          (copy-proper-list attributes :invalid-content-attributes
                            "content attributes"))
        (inlines (copy-proper-list inlines :invalid-content-inlines
                                   "content inlines"))
        (items (copy-proper-list items :invalid-content-items
                                 "content list items")))
    (unless (every #'consp attributes)
      (model-error :invalid-content-attribute attributes
                   "content attributes must be an association list"))
    (unless (every #'inline-node-p inlines)
      (model-error :invalid-content-inline inlines
                   "every content inline must be an inline node"))
    (when (and inlines (not (member kind '(:paragraph :quote :drawer))))
      (model-error :unexpected-content-inlines kind
                   "only paragraph quote or drawer content can carry inline nodes"))
    (unless (every #'list-item-p items)
      (model-error :invalid-content-item items
                   "every content item must be a list item"))
    (when (and items (not (eq kind :list)))
      (model-error :unexpected-content-items kind
                   "only list content can carry list items"))
    (unless (or (null table) (table-data-p table))
      (model-error :invalid-content-table table
                   "content table must be table data or NIL"))
    (when (and table (not (eq kind :table)))
      (model-error :unexpected-content-table kind
                   "only table content can carry table data"))
    (unless (or (null code-block) (code-block-data-p code-block))
      (model-error :invalid-content-code-block code-block
                   "content code block must be code block data or NIL"))
    (when (and code-block (not (eq kind :source-block)))
      (model-error :unexpected-content-code-block kind
                   "only source-block content can carry code block data"))
    (%make-content-node kind source-format raw span name attributes text
                        inlines items table code-block)))

(defstruct (semantic-node
            (:constructor %make-semantic-node
                (id level title body parent-id child-ids aliases references tags
                 properties event task inactive-dates calendar-bindings span
                 extensions)))
  (id "" :type string :read-only t)
  (level 1 :type (integer 1) :read-only t)
  (title "" :type string :read-only t)
  (body nil :type list :read-only t)
  (parent-id nil :type (or null string) :read-only t)
  (child-ids nil :type list :read-only t)
  (aliases nil :type list :read-only t)
  (references nil :type list :read-only t)
  (tags nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (event nil :type (or null event-facet) :read-only t)
  (task nil :type (or null task-facet) :read-only t)
  (inactive-dates nil :type list :read-only t)
  (calendar-bindings nil :type list :read-only t)
  (span nil :type (or null source-span) :read-only t)
  (extensions nil :type list :read-only t))

(defun make-semantic-node
    (&key id level title (body nil) parent-id (child-ids nil) (tags nil)
          (aliases nil) (references nil) (properties nil) event task
          (calendar-bindings nil) span (inactive-dates nil) (extensions nil))
  (require-non-empty-string id :invalid-node-id "node ID")
  (unless (and (integerp level) (plusp level))
    (model-error :invalid-node-level level
                 "node level must be a positive integer"))
  (unless (stringp title)
    (model-error :invalid-node-title title "node title must be a string"))
  (unless (or (null parent-id) (non-empty-string-p parent-id))
    (model-error :invalid-parent-id parent-id
                 "parent ID must be a non-empty string or NIL"))
  (let ((body (copy-proper-list body :invalid-node-body "node body"))
        (child-ids (copy-proper-list child-ids :invalid-child-ids
                                     "node child IDs"))
        (aliases (copy-proper-list aliases :invalid-aliases "node aliases"))
        (references
          (copy-proper-list references :invalid-node-references
                            "node references"))
        (tags (copy-proper-list tags :invalid-tags "node tags"))
        (properties (copy-proper-list properties :invalid-properties
                                      "node properties"))
        (inactive-dates
          (copy-proper-list inactive-dates :invalid-inactive-dates
                            "node inactive dates"))
        (bindings (copy-proper-list calendar-bindings
                                    :invalid-calendar-bindings
                                    "node calendar bindings"))
        (extensions (copy-proper-list extensions :invalid-node-extensions
                                      "node extensions")))
    (unless (every #'non-empty-string-p child-ids)
      (model-error :invalid-child-id child-ids
                   "every child ID must be a non-empty string"))
    (unless (every #'non-empty-string-p aliases)
      (model-error :invalid-alias aliases
                   "every node alias must be a non-empty string"))
    (unless (every #'node-reference-p references)
      (model-error :invalid-node-reference references
                   "every node reference must be typed reference data"))
    (unless (every #'non-empty-string-p tags)
      (model-error :invalid-tag tags
                   "every tag must be a non-empty string"))
    (unless (every #'content-node-p body)
      (model-error :invalid-node-body body
                   "every node body value must be a content node"))
    (unless (every #'consp properties)
      (model-error :invalid-property properties
                   "node properties must be an association list"))
    (unless (or (null task) (task-facet-p task))
      (model-error :invalid-task-facet task
                   "node task must be a task facet or NIL"))
    (unless (or (null event) (event-facet-p event))
      (model-error :invalid-event-facet event
                   "node event must be an event facet or NIL"))
    (unless (every (lambda (value)
                     (or (temporal-value-p value)
                         (recurrence-period-p value)))
                   inactive-dates)
      (model-error :invalid-inactive-date inactive-dates
                   "every inactive date must be a temporal value or period"))
    (unless (every #'calendar-binding-p bindings)
      (model-error :invalid-calendar-binding bindings
                   "every calendar binding must be a calendar binding"))
    (unless (or (null span) (source-span-p span))
      (model-error :invalid-node-span span
                   "node span must be a source span or NIL"))
    (unless (every #'opaque-extension-p extensions)
      (model-error :invalid-node-extension extensions
                   "every node extension must be opaque extension data"))
    (%make-semantic-node id level title body parent-id child-ids aliases
                         references tags properties event task inactive-dates
                         bindings span extensions)))

(defstruct (semantic-document
            (:constructor %make-semantic-document
                (id source-uri format profile preamble metadata nodes root-ids
                 newline encoding source-revision diagnostics extensions)))
  (id "" :type string :read-only t)
  (source-uri "" :type string :read-only t)
  (format :org :type keyword :read-only t)
  (profile "" :type string :read-only t)
  (preamble nil :type list :read-only t)
  (metadata nil :type list :read-only t)
  (nodes nil :type list :read-only t)
  (root-ids nil :type list :read-only t)
  (newline :lf :type keyword :read-only t)
  (encoding :utf-8 :type keyword :read-only t)
  (source-revision "" :type string :read-only t)
  (diagnostics nil :type list :read-only t)
  (extensions nil :type list :read-only t))

(defun find-semantic-node (document node-id)
  "Return the node identified by NODE-ID in DOCUMENT, or NIL."
  (find node-id (semantic-document-nodes document)
        :key #'semantic-node-id :test #'string=))

(defun semantic-node-subtree-character-range (document node source-length)
  "Return NODE's complete source subtree as half-open character bounds.

The semantic node list is in source order.  A subtree therefore ends at the
next heading whose level is not deeper than NODE, or at SOURCE-LENGTH."
  (unless (and (semantic-document-p document)
               (semantic-node-p node)
               (eq node (find-semantic-node document (semantic-node-id node)))
               (integerp source-length)
               (not (minusp source-length)))
    (model-error :invalid-semantic-subtree-range
                 (list document node source-length)
                 "subtree range requires a document-owned node and source length"))
  (let* ((span (semantic-node-span node))
         (start (and span (source-span-character-start span)))
         (following (rest (member node (semantic-document-nodes document)
                                  :test #'eq)))
         (next
           (find-if (lambda (candidate)
                      (<= (semantic-node-level candidate)
                          (semantic-node-level node)))
                    following))
         (end
           (if next
               (let ((next-span (semantic-node-span next)))
                 (and next-span
                      (source-span-character-start next-span)))
               source-length)))
    (unless (and (integerp start) (integerp end)
                 (<= 0 start end source-length)
                 (<= (source-span-character-end span) end))
      (model-error :invalid-semantic-subtree-span
                   (list (semantic-node-id node) start end source-length)
                   "semantic subtree bounds are absent or outside the source"))
    (values start end)))

(defun semantic-node-subtree-nodes (document node)
  "Return NODE and its descendants in source order."
  (unless (and (semantic-document-p document)
               (semantic-node-p node)
               (eq node (find-semantic-node document (semantic-node-id node))))
    (model-error :invalid-semantic-subtree
                 (list document node)
                 "subtree enumeration requires a document-owned node"))
  (let ((level (semantic-node-level node)))
    (loop :for candidate :in
            (member node (semantic-document-nodes document) :test #'eq)
          :while (or (eq candidate node)
                     (> (semantic-node-level candidate) level))
          :collect candidate)))

(defun rewrite-semantic-subtree-heading-levels
    (document node source start end marker new-root-level &key max-level)
  "Return SOURCE's bounded subtree with only semantic heading markers shifted."
  (unless (and (characterp marker)
               (integerp new-root-level) (plusp new-root-level)
               (or (null max-level)
                   (and (integerp max-level) (plusp max-level)))
               (stringp source) (<= 0 start end (length source)))
    (model-error :invalid-semantic-subtree-reheading
                 (list start end marker new-root-level max-level)
                 "subtree reheading requires exact source bounds and levels"))
  (let* ((root-level (semantic-node-level node))
         (delta (- new-root-level root-level))
         (rewritten (subseq source start end)))
    (dolist (candidate
             (reverse (semantic-node-subtree-nodes document node)) rewritten)
      (let* ((old-level (semantic-node-level candidate))
             (new-level (+ old-level delta))
             (span (semantic-node-span candidate))
             (relative (- (source-span-character-start span) start)))
        (unless (and (plusp new-level)
                     (or (null max-level) (<= new-level max-level))
                     (<= 0 relative (+ relative old-level)
                         (length rewritten))
                     (every (lambda (character) (char= marker character))
                            (subseq rewritten relative
                                    (+ relative old-level)))
                     (< (+ relative old-level) (length rewritten))
                     (member (char rewritten (+ relative old-level))
                             '(#\Space #\Tab)))
          (model-error :unrepresentable-semantic-subtree-level
                       (list (semantic-node-id candidate) old-level new-level)
                       "subtree heading level cannot be represented exactly"))
        (setf rewritten
              (concatenate
               'string
               (subseq rewritten 0 relative)
               (make-string new-level :initial-element marker)
               (subseq rewritten (+ relative old-level))))))))

(defun minimal-source-replacement (source replacement-source)
  "Return the single minimal half-open patch from SOURCE to REPLACEMENT-SOURCE."
  (unless (and (stringp source) (stringp replacement-source))
    (model-error :invalid-source-replacement
                 (list source replacement-source)
                 "minimal source replacement requires two strings"))
  (let* ((source-length (length source))
         (replacement-length (length replacement-source))
         (prefix
           (loop :for index :below (min source-length replacement-length)
                 :while (char= (char source index)
                               (char replacement-source index))
                 :finally (return index)))
         (suffix
           (loop :for offset :from 0
                 :while (and (< offset (- source-length prefix))
                             (< offset (- replacement-length prefix))
                             (char= (char source (- source-length offset 1))
                                    (char replacement-source
                                          (- replacement-length offset 1))))
                 :finally (return offset))))
    (values prefix
            (- source-length suffix)
            (subseq replacement-source prefix (- replacement-length suffix)))))

(defun move-semantic-subtree-source
    (document source node target marker &key max-level)
  "Return SOURCE with NODE moved to the end of level-one TARGET as its child."
  (unless (and (semantic-document-p document) (stringp source)
               (semantic-node-p node) (semantic-node-p target)
               (eq node (find-semantic-node document (semantic-node-id node)))
               (eq target
                   (find-semantic-node document (semantic-node-id target)))
               (= 1 (semantic-node-level target)))
    (model-error :invalid-semantic-subtree-move
                 (list node target)
                 "subtree move requires owned nodes and a level-one target"))
  (multiple-value-bind (start end)
      (semantic-node-subtree-character-range document node (length source))
    (multiple-value-bind (target-start target-end)
        (semantic-node-subtree-character-range
         document target (length source))
      (when (<= start target-start (1- end))
        (model-error :recursive-semantic-subtree-move
                     (list (semantic-node-id node) (semantic-node-id target))
                     "subtree cannot move into itself or one of its descendants"))
      (let* ((moved
               (rewrite-semantic-subtree-heading-levels
                document node source start end marker 2 :max-level max-level))
             (removed
               (concatenate 'string (subseq source 0 start)
                            (subseq source end)))
             (removed-length (- end start))
             (position
               (if (<= end target-end)
                   (- target-end removed-length)
                   target-end))
             (leading-newline-p
               (and (plusp position)
                    (not (member (char removed (1- position))
                                 '(#\Newline #\Return)))))
             (trailing-newline-p
               (and (< position (length removed))
                    (plusp (length moved))
                    (not (member (char moved (1- (length moved)))
                                 '(#\Newline #\Return)))))
             (insertion
               (concatenate 'string
                            (if leading-newline-p (string #\Newline) "")
                            moved
                            (if trailing-newline-p (string #\Newline) ""))))
        (values
         (concatenate 'string (subseq removed 0 position) insertion
                      (subseq removed position))
         start end target-start target-end)))))

(defun validate-document (document)
  "Validate identity, hierarchy, projection, and extension invariants."
  (unless (semantic-document-p document)
    (model-error :invalid-document document
                 "value is not a semantic document"))
  (let ((index (make-hash-table :test #'equal))
        (visiting (make-hash-table :test #'equal)))
    (dolist (node (semantic-document-nodes document))
      (let ((id (semantic-node-id node)))
        (when (gethash id index)
          (model-error :duplicate-node-id id
                       "document node IDs must be unique"))
        (setf (gethash id index) node)))
    (dolist (root-id (semantic-document-root-ids document))
      (let ((root (gethash root-id index)))
        (unless root
          (model-error :missing-root root-id
                       "document root must identify an existing node"))
        (when (semantic-node-parent-id root)
          (model-error :root-has-parent root-id
                       "a root node cannot also have a parent"))))
    (dolist (node (semantic-document-nodes document))
      (let ((node-id (semantic-node-id node))
            (parent-id (semantic-node-parent-id node)))
        (if parent-id
            (let ((parent (gethash parent-id index)))
              (unless parent
                (model-error :missing-parent parent-id
                             "node ~a refers to a missing parent" node-id))
              (unless (member node-id (semantic-node-child-ids parent)
                              :test #'string=)
                (model-error :parent-missing-child node-id
                             "parent ~a does not list node as a child"
                             parent-id))
              (unless (> (semantic-node-level node)
                         (semantic-node-level parent))
                (model-error :invalid-child-level node-id
                             "child level must be greater than parent level")))
            (unless (member node-id (semantic-document-root-ids document)
                            :test #'string=)
              (model-error :unlisted-root node-id
                           "a parentless node must appear in document roots")))
        (dolist (child-id (semantic-node-child-ids node))
          (let ((child (gethash child-id index)))
            (unless child
              (model-error :missing-child child-id
                           "node ~a refers to a missing child" node-id))
            (unless (equal node-id (semantic-node-parent-id child))
              (model-error :child-parent-mismatch child-id
                           "child does not refer back to parent ~a" node-id))))
        (dolist (binding (semantic-node-calendar-bindings node))
          (unless (string= node-id (calendar-binding-node-id binding))
            (model-error :binding-node-mismatch (calendar-binding-id binding)
                         "calendar binding owner differs from containing node")))
        (dolist (extension (semantic-node-extensions node))
          (let ((owner-id (opaque-extension-owner-id extension)))
            (when (and owner-id (not (string= owner-id node-id)))
              (model-error :extension-owner-mismatch owner-id
                           "node extension owner differs from containing node"))))))
    (labels ((visit (node-id)
               (case (gethash node-id visiting)
                 (:done nil)
                 (:active
                  (model-error :hierarchy-cycle node-id
                               "document hierarchy contains a cycle"))
                 (otherwise
                  (setf (gethash node-id visiting) :active)
                  (dolist (child-id
                           (semantic-node-child-ids (gethash node-id index)))
                    (visit child-id))
                  (setf (gethash node-id visiting) :done)))))
      (dolist (root-id (semantic-document-root-ids document))
        (visit root-id)))
    (unless (= (hash-table-count visiting) (hash-table-count index))
      (model-error :unreachable-node document
                   "every node must be reachable from a document root")))
  document)

(defun make-semantic-document
    (&key id source-uri format profile (preamble nil) (metadata nil) (nodes nil)
          (root-ids nil) (newline :lf) (encoding :utf-8) source-revision
          (diagnostics nil) (extensions nil))
  (require-non-empty-string id :invalid-document-id "document ID")
  (require-non-empty-string source-uri :invalid-source-uri "source URI")
  (require-membership format '(:org :markdown :lsm :icalendar :virtual)
                      :invalid-document-format "document format")
  (require-non-empty-string profile :invalid-profile "document profile")
  (require-membership newline '(:lf :crlf :cr)
                      :invalid-newline "document newline style")
  (unless (keywordp encoding)
    (model-error :invalid-encoding encoding
                 "document encoding must be a keyword"))
  (require-non-empty-string source-revision :invalid-source-revision
                            "source revision")
  (let ((preamble (copy-proper-list preamble :invalid-preamble
                                    "document preamble"))
        (metadata (copy-proper-list metadata :invalid-metadata
                                    "document metadata"))
        (nodes (copy-proper-list nodes :invalid-nodes "document nodes"))
        (root-ids (copy-proper-list root-ids :invalid-root-ids
                                    "document root IDs"))
        (diagnostics (copy-proper-list diagnostics :invalid-diagnostics
                                       "document diagnostics"))
        (extensions (copy-proper-list extensions :invalid-extensions
                                      "document extensions")))
    (unless (every #'content-node-p preamble)
      (model-error :invalid-preamble preamble
                   "every document preamble value must be a content node"))
    (unless (every #'semantic-node-p nodes)
      (model-error :invalid-node nodes
                   "every document node must be a semantic node"))
    (unless (every #'non-empty-string-p root-ids)
      (model-error :invalid-root-id root-ids
                   "every document root ID must be a non-empty string"))
    (unless (every #'diagnostic-p diagnostics)
      (model-error :invalid-diagnostic diagnostics
                   "every document diagnostic must be a diagnostic"))
    (unless (every #'opaque-extension-p extensions)
      (model-error :invalid-extension extensions
                   "every document extension must be opaque extension data"))
    (validate-document
     (%make-semantic-document id source-uri format profile preamble metadata
                              nodes root-ids newline encoding source-revision
                              diagnostics extensions))))
