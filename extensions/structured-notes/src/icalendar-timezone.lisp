(in-package #:lem-structured-notes)

(defstruct (ical-timezone-observance
            (:constructor %make-ical-timezone-observance
                (kind component start offset-from offset-to names
                 recurrence-rule recurrence-dates comments properties
                 diagnostics valid-p)))
  (kind :standard :type keyword :read-only t)
  (component nil :type ical-component :read-only t)
  (start nil :type (or null temporal-value) :read-only t)
  (offset-from nil :type (or null integer) :read-only t)
  (offset-to nil :type (or null integer) :read-only t)
  (names nil :type list :read-only t)
  (recurrence-rule nil :type (or null ical-recur-value) :read-only t)
  (recurrence-dates nil :type list :read-only t)
  (comments nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-timezone-definition
            (:constructor %make-ical-timezone-definition
                (component timezone-id last-modified url observances
                 properties diagnostics valid-p)))
  (component nil :type ical-component :read-only t)
  (timezone-id nil :type (or null string) :read-only t)
  (last-modified nil :type (or null temporal-value) :read-only t)
  (url nil :type (or null ical-uri-value) :read-only t)
  (observances nil :type list :read-only t)
  (properties nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defun ical-timezone-property-values (index name)
  (mapcan
   (lambda (property)
     (mapcar #'ical-value-decoded
             (remove-if-not #'ical-value-valid-p
                            (ical-property-value-values property))))
   (ical-index-properties index name)))

(defun ical-timezone-invalid-content-diagnostics (component diagnostics)
  (dolist (item (ical-component-items component) diagnostics)
    (when (and (ical-content-line-p item)
               (not (ical-content-line-valid-p item)))
      (push (ical-projection-diagnostic
             component :invalid-icalendar-timezone-content
             "invalid retained content prevents safe timezone projection"
             item)
            diagnostics))))

(defun project-ical-timezone-observance (component)
  (let* ((name (ical-component-normalized-name component))
         (kind (cond ((string= name "STANDARD") :standard)
                     ((string= name "DAYLIGHT") :daylight)
                     (t nil))))
    (unless kind
      (model-error :unsupported-icalendar-timezone-observance name
                   "timezone observance must be STANDARD or DAYLIGHT"))
    (multiple-value-bind (index properties property-diagnostics)
        (ical-property-index component)
      (let ((diagnostics
              (ical-timezone-invalid-content-diagnostics
               component property-diagnostics)))
        (dolist (property-name '("DTSTART" "TZOFFSETFROM" "TZOFFSETTO"))
          (setf diagnostics
                (ical-required-singleton
                 component index property-name diagnostics :required-p t)))
        (setf diagnostics
              (ical-required-singleton component index "RRULE" diagnostics))
        (let* ((start (ical-first-decoded-value index "DTSTART"))
               (offset-from
                 (ical-first-decoded-value index "TZOFFSETFROM"))
               (offset-to (ical-first-decoded-value index "TZOFFSETTO"))
               (rule (ical-first-decoded-value index "RRULE"))
               (dates (ical-timezone-property-values index "RDATE"))
               (names (ical-timezone-property-values index "TZNAME"))
               (comments (ical-timezone-property-values index "COMMENT")))
          (unless (and start (eq :floating (temporal-value-kind start)))
            (push (ical-projection-diagnostic
                   component :invalid-timezone-observance-start
                   "observance DTSTART must be a local DATE-TIME without TZID")
                  diagnostics))
          (unless (integerp offset-from)
            (push (ical-projection-diagnostic
                   component :invalid-timezone-offset-from
                   "observance TZOFFSETFROM must be a valid UTC-OFFSET")
                  diagnostics))
          (unless (integerp offset-to)
            (push (ical-projection-diagnostic
                   component :invalid-timezone-offset-to
                   "observance TZOFFSETTO must be a valid UTC-OFFSET")
                  diagnostics))
          (when (and rule (ical-recur-value-until rule)
                     (not (eq :utc
                              (temporal-value-kind
                               (ical-recur-value-until rule)))))
            (push (ical-projection-diagnostic
                   component :invalid-timezone-recur-until
                   "observance RRULE UNTIL must be a UTC DATE-TIME")
                  diagnostics))
          (unless (every (lambda (date)
                           (and (temporal-value-p date)
                                (eq :floating (temporal-value-kind date))))
                         dates)
            (push (ical-projection-diagnostic
                   component :invalid-timezone-recurrence-date
                   "observance RDATE values must be local DATE-TIME values without TZID")
                  diagnostics))
          (dolist (child (ical-component-children component))
            (push (ical-projection-diagnostic
                   component :invalid-nested-timezone-component
                   "STANDARD and DAYLIGHT cannot contain child components"
                   (ical-component-begin-line child))
                  diagnostics))
          (setf diagnostics (nreverse diagnostics))
          (%make-ical-timezone-observance
           kind component start offset-from offset-to names rule dates comments
           properties diagnostics (null diagnostics)))))))

(defun project-ical-timezone-component (component)
  "Project one retained VTIMEZONE through RFC 5545 core invariants."
  (unless (and (ical-component-p component)
               (string= "VTIMEZONE"
                        (ical-component-normalized-name component)))
    (model-error :invalid-icalendar-timezone-component component
                 "value must be a VTIMEZONE component"))
  (multiple-value-bind (index properties property-diagnostics)
      (ical-property-index component)
    (let ((diagnostics
            (ical-timezone-invalid-content-diagnostics
             component property-diagnostics)))
      (setf diagnostics
            (ical-required-singleton
             component index "TZID" diagnostics :required-p t))
      (dolist (name '("LAST-MODIFIED" "TZURL"))
        (setf diagnostics
              (ical-required-singleton component index name diagnostics)))
      (let* ((timezone-id (ical-first-decoded-value index "TZID"))
             (last-modified
               (ical-first-decoded-value index "LAST-MODIFIED"))
             (url (ical-first-decoded-value index "TZURL"))
             (observances nil))
        (unless (non-empty-string-p timezone-id)
          (push (ical-projection-diagnostic
                 component :invalid-icalendar-timezone-id
                 "VTIMEZONE TZID must be non-empty TEXT")
                diagnostics))
        (when (and last-modified
                   (not (eq :utc (temporal-value-kind last-modified))))
          (push (ical-projection-diagnostic
                 component :invalid-timezone-last-modified
                 "VTIMEZONE LAST-MODIFIED must be a UTC DATE-TIME")
                diagnostics))
        (dolist (child (ical-component-children component))
          (let ((child-name (ical-component-normalized-name child)))
            (if (member child-name '("STANDARD" "DAYLIGHT") :test #'string=)
                (let ((observance (project-ical-timezone-observance child)))
                  (push observance observances)
                  (setf diagnostics
                        (nconc diagnostics
                               (copy-list
                                (ical-timezone-observance-diagnostics
                                 observance)))))
                (push (ical-projection-diagnostic
                       component :invalid-timezone-child-component
                       "VTIMEZONE may contain only STANDARD or DAYLIGHT components"
                       (ical-component-begin-line child))
                      diagnostics))))
        (setf observances (nreverse observances))
        (unless observances
          (push (ical-projection-diagnostic
                 component :missing-timezone-observance
                 "VTIMEZONE requires at least one STANDARD or DAYLIGHT component")
                diagnostics))
        (setf diagnostics (nreverse diagnostics))
        (%make-ical-timezone-definition
         component timezone-id last-modified url observances properties
         diagnostics (null diagnostics))))))

(defclass timezone-provider () ())

(defgeneric timezone-provider-version (provider))
(defgeneric find-timezone-definition (provider timezone-id))
(defgeneric resolve-zoned-local-time (provider temporal))
(defgeneric project-utc-time-to-zoned-local-time
    (provider utc-temporal timezone-id))

(defmethod timezone-provider-version ((provider timezone-provider))
  (declare (ignore provider))
  (model-error :abstract-timezone-provider nil
               "timezone provider version is not implemented"))

(defmethod find-timezone-definition
    ((provider timezone-provider) timezone-id)
  (declare (ignore provider timezone-id))
  (model-error :abstract-timezone-provider nil
               "timezone lookup is not implemented"))

(defmethod resolve-zoned-local-time ((provider timezone-provider) temporal)
  (declare (ignore provider temporal))
  (model-error :abstract-timezone-provider nil
               "timezone resolution is not implemented"))

(defmethod project-utc-time-to-zoned-local-time
    ((provider timezone-provider) utc-temporal timezone-id)
  (declare (ignore provider utc-temporal timezone-id))
  (model-error :abstract-timezone-provider nil
               "inverse timezone resolution is not implemented"))

(defclass embedded-timezone-provider (timezone-provider)
  ((version :initarg :version :reader timezone-provider-version)
   (definitions :initarg :definitions :reader embedded-timezone-definitions)
   (max-transition-periods
    :initarg :max-transition-periods
    :reader embedded-timezone-max-transition-periods)
   (max-transition-candidates
    :initarg :max-transition-candidates
    :reader embedded-timezone-max-transition-candidates)
   (max-transitions
    :initarg :max-transitions
    :reader embedded-timezone-max-transitions)))

(defun make-embedded-timezone-provider
    (definitions &key (version "embedded/1")
                 (max-transition-periods 10000)
                 (max-transition-candidates 100000)
                 (max-transitions 10000))
  (require-non-empty-string version :invalid-timezone-provider-version
                            "timezone provider version")
  (dolist (entry
           (list (cons max-transition-periods "transition period ceiling")
                 (cons max-transition-candidates
                       "transition candidate ceiling")
                 (cons max-transitions "transition instance ceiling")))
    (unless (and (integerp (car entry)) (plusp (car entry)))
      (model-error :invalid-timezone-transition-limit (car entry)
                   "~a must be a positive integer" (cdr entry))))
  (let ((table (make-hash-table :test #'equal)))
    (dolist (definition
             (copy-proper-list definitions :invalid-timezone-definitions
                               "timezone definitions"))
      (unless (and (ical-timezone-definition-p definition)
                   (ical-timezone-definition-valid-p definition))
        (model-error :invalid-timezone-definition definition
                     "embedded providers require valid timezone definitions"))
      (let ((id (ical-timezone-definition-timezone-id definition)))
        (when (gethash id table)
          (model-error :duplicate-timezone-definition id
                       "embedded timezone IDs must be unique"))
        (setf (gethash id table) definition)))
    (make-instance 'embedded-timezone-provider
                   :version version :definitions table
                   :max-transition-periods max-transition-periods
                   :max-transition-candidates max-transition-candidates
                   :max-transitions max-transitions)))

(defmethod find-timezone-definition
    ((provider embedded-timezone-provider) timezone-id)
  (gethash timezone-id (embedded-timezone-definitions provider)))

(defstruct (timezone-resolution-candidate
            (:constructor make-timezone-resolution-candidate
                (utc-seconds offset-seconds fold)))
  (utc-seconds 0 :type integer :read-only t)
  (offset-seconds 0 :type integer :read-only t)
  (fold 0 :type (integer 0) :read-only t))

(defstruct (timezone-local-resolution
            (:constructor make-timezone-local-resolution
                (&key status timezone-id local candidates)))
  (status :uncovered :type keyword :read-only t)
  (timezone-id "" :type string :read-only t)
  (local nil :type temporal-value :read-only t)
  (candidates nil :type list :read-only t))

(defstruct (ical-timezone-transition
            (:constructor make-ical-timezone-transition
                (utc-seconds local-seconds offset-from offset-to)))
  utc-seconds local-seconds offset-from offset-to)

(defgeneric expand-recurring-timezone-observance-onsets
    (observance local-limit max-periods max-candidates max-instances))

(defmethod expand-recurring-timezone-observance-onsets
    ((observance t) local-limit max-periods max-candidates max-instances)
  (declare (ignore observance local-limit max-periods max-candidates
                   max-instances))
  (values nil t 0 0))

(defun ical-civil-days (year month day)
  (let* ((adjusted-year (if (<= month 2) (1- year) year))
         (era (floor adjusted-year 400))
         (year-of-era (- adjusted-year (* era 400)))
         (adjusted-month (+ month (if (> month 2) -3 9)))
         (day-of-year
           (+ (floor (+ (* 153 adjusted-month) 2) 5) day -1))
         (day-of-era
           (+ (* year-of-era 365) (floor year-of-era 4)
              (- (floor year-of-era 100)) day-of-year)))
    (- (+ (* era 146097) day-of-era) 719468)))

(defun ical-local-temporal-seconds (temporal)
  (unless (and (temporal-value-p temporal)
               (member (temporal-value-kind temporal) '(:floating :zoned)))
    (model-error :invalid-timezone-local-value temporal
                 "timezone resolution requires a local DATE-TIME"))
  (let ((text (temporal-value-local-value temporal)))
    (unless (and (= (length text) 19)
                 (char= (char text 4) #\-)
                 (char= (char text 7) #\-)
                 (char= (char text 10) #\T)
                 (char= (char text 13) #\:)
                 (char= (char text 16) #\:))
      (model-error :invalid-timezone-local-lexeme text
                   "local DATE-TIME must use YYYY-MM-DDTHH:MM:SS"))
    (labels ((number (start end)
               (or (ignore-errors
                     (parse-integer text :start start :end end
                                        :junk-allowed nil))
                   (model-error :invalid-timezone-local-lexeme text
                                "local DATE-TIME contains a non-digit field"))))
      (let ((year (number 0 4))
            (month (number 5 7))
            (day (number 8 10))
            (hour (number 11 13))
            (minute (number 14 16))
            (second (number 17 19)))
        (unless (and (<= 1 month 12)
                     (<= 1 day (ical-days-in-month year month))
                     (<= 0 hour 23) (<= 0 minute 59) (<= 0 second 59))
          (model-error :invalid-timezone-local-value text
                       "local DATE-TIME contains an out-of-range field"))
        (+ (* (ical-civil-days year month day) 86400)
           (* hour 3600) (* minute 60) second)))))

(defun ical-utc-temporal-seconds (temporal)
  (unless (and (temporal-value-p temporal)
               (eq :utc (temporal-value-kind temporal)))
    (model-error :invalid-timezone-utc-value temporal
                 "inverse timezone resolution requires a UTC DATE-TIME"))
  (let ((text (temporal-value-local-value temporal)))
    (unless (and (= (length text) 20) (char= (char text 19) #\Z))
      (model-error :invalid-timezone-utc-lexeme text
                   "UTC DATE-TIME must use YYYY-MM-DDTHH:MM:SSZ"))
    (ical-local-temporal-seconds
     (make-temporal-value
      :kind :floating :local-value (subseq text 0 19) :precision :second))))

(defun ical-civil-from-days (days)
  (let* ((shifted (+ days 719468))
         (era (floor shifted 146097))
         (day-of-era (- shifted (* era 146097)))
         (year-of-era
           (floor (- day-of-era (floor day-of-era 1460)
                     (- (floor day-of-era 36524))
                     (floor day-of-era 146096))
                  365))
         (year (+ year-of-era (* era 400)))
         (day-of-year
           (- day-of-era
              (+ (* 365 year-of-era) (floor year-of-era 4)
                 (- (floor year-of-era 100)))))
         (month-prime (floor (+ (* 5 day-of-year) 2) 153))
         (day (1+ (- day-of-year
                     (floor (+ (* 153 month-prime) 2) 5))))
         (month (+ month-prime (if (< month-prime 10) 3 -9))))
    (values (+ year (if (<= month 2) 1 0)) month day)))

(defun ical-local-string-from-seconds (seconds)
  (multiple-value-bind (days second-of-day) (floor seconds 86400)
    (multiple-value-bind (year month day) (ical-civil-from-days days)
      (unless (<= 0 year 9999)
        (model-error :inverse-timezone-year-overflow year
                     "inverse timezone result exceeds the supported year range"))
      (multiple-value-bind (hour rest) (floor second-of-day 3600)
        (multiple-value-bind (minute second) (floor rest 60)
          (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d"
                  year month day hour minute second))))))

(defun ical-timezone-transitions
    (definition local-limit max-periods max-candidates max-instances)
  (let ((transitions nil)
        (periods-used 0)
        (candidates-used 0))
    (dolist (observance (ical-timezone-definition-observances definition))
      (when (and (ical-timezone-observance-recurrence-rule observance)
                 (or (>= periods-used max-periods)
                     (>= candidates-used max-candidates)))
        (model-error :timezone-transition-limit-exceeded definition
                     "aggregate timezone transition expansion ceiling was exhausted"))
      (multiple-value-bind
            (onsets recurrence-required-p periods-examined candidates-examined)
          (if (ical-timezone-observance-recurrence-rule observance)
              (expand-recurring-timezone-observance-onsets
               observance local-limit
               (- max-periods periods-used)
               (- max-candidates candidates-used)
               max-instances)
              (let ((explicit
                      (remove-if
                       (lambda (onset)
                         (> (ical-local-temporal-seconds onset) local-limit))
                       (cons
                        (ical-timezone-observance-start observance)
                        (ical-timezone-observance-recurrence-dates
                         observance)))))
                (values explicit nil 0 (length explicit))))
        (when recurrence-required-p
          (return-from ical-timezone-transitions (values nil t)))
        (incf periods-used periods-examined)
        (incf candidates-used candidates-examined)
        (when (> candidates-used max-candidates)
          (model-error :timezone-transition-candidate-limit-exceeded
                       max-candidates
                       "aggregate timezone transition candidate ceiling was exceeded"))
        (dolist (onset onsets)
          (let* ((local (ical-local-temporal-seconds onset))
                 (from (ical-timezone-observance-offset-from observance))
                 (transition
                   (make-ical-timezone-transition
                    (- local from) local from
                    (ical-timezone-observance-offset-to observance))))
            (pushnew
             transition transitions
             :test (lambda (left right)
                     (and (= (ical-timezone-transition-utc-seconds left)
                             (ical-timezone-transition-utc-seconds right))
                          (= (ical-timezone-transition-offset-from left)
                             (ical-timezone-transition-offset-from right))
                          (= (ical-timezone-transition-offset-to left)
                             (ical-timezone-transition-offset-to right)))))
            (when (> (length transitions) max-instances)
              (model-error :timezone-transition-instance-limit-exceeded
                           max-instances
                           "aggregate timezone transition instance ceiling was exceeded"))))))
    (let ((ordered
            (sort transitions #'<
                  :key #'ical-timezone-transition-utc-seconds)))
      (loop :for left :on ordered
            :for right := (second left)
            :while right
            :when (= (ical-timezone-transition-utc-seconds (first left))
                     (ical-timezone-transition-utc-seconds right))
              :do (model-error
                   :conflicting-timezone-transition
                   (ical-timezone-transition-utc-seconds right)
                   "embedded observances define conflicting transitions at one UTC instant"))
      (values ordered nil))))

(defun ical-timezone-earliest-onset-local (definition)
  (reduce
   #'min
   (mapcan
    (lambda (observance)
      (mapcar #'ical-local-temporal-seconds
              (cons (ical-timezone-observance-start observance)
                    (ical-timezone-observance-recurrence-dates observance))))
    (ical-timezone-definition-observances definition))))

(defun ical-offset-at-utc (transitions utc-seconds)
  (let ((selected nil))
    (dolist (transition transitions)
      (if (<= (ical-timezone-transition-utc-seconds transition) utc-seconds)
          (setf selected transition)
          (return)))
    (and selected (ical-timezone-transition-offset-to selected))))

(defun ical-rfc5545-gap-resolution-candidate (transitions local-seconds)
  (let ((candidates
          (loop :for transition :in transitions
                :for offset-from :=
                  (ical-timezone-transition-offset-from transition)
                :for offset-to :=
                  (ical-timezone-transition-offset-to transition)
                :for gap-start :=
                  (ical-timezone-transition-local-seconds transition)
                :for gap-end := (+ gap-start (- offset-to offset-from))
                :when (and (> offset-to offset-from)
                           (<= gap-start local-seconds)
                           (< local-seconds gap-end))
                  :collect
                  (make-timezone-resolution-candidate
                   (- local-seconds offset-from) offset-from 0))))
    (case (length candidates)
      (0 nil)
      (1 (first candidates))
      (otherwise
       (model-error :ambiguous-timezone-gap transitions
                    "more than one transition claims the same local-time gap")))))

(defmethod resolve-zoned-local-time
    ((provider embedded-timezone-provider) temporal)
  (unless (and (temporal-value-p temporal)
               (eq :zoned (temporal-value-kind temporal)))
    (model-error :invalid-zoned-time temporal
                 "timezone resolution requires a zoned temporal value"))
  (let* ((timezone-id (temporal-value-timezone-id temporal))
         (definition (find-timezone-definition provider timezone-id))
         (local-seconds (ical-local-temporal-seconds temporal)))
    (unless definition
      (return-from resolve-zoned-local-time
        (make-timezone-local-resolution
         :status :unknown-timezone :timezone-id timezone-id
         :local temporal :candidates nil)))
    (multiple-value-bind (transitions recurrence-required-p)
        (ical-timezone-transitions
         definition (+ local-seconds 172800)
         (embedded-timezone-max-transition-periods provider)
         (embedded-timezone-max-transition-candidates provider)
         (embedded-timezone-max-transitions provider))
      (when recurrence-required-p
        (return-from resolve-zoned-local-time
          (make-timezone-local-resolution
           :status :requires-expansion :timezone-id timezone-id
           :local temporal :candidates nil)))
      (let* ((offsets
               (remove-duplicates
                (mapcan
                 (lambda (transition)
                   (list (ical-timezone-transition-offset-from transition)
                         (ical-timezone-transition-offset-to transition)))
                 transitions)))
             (raw-candidates
               (loop :for offset :in offsets
                     :for utc := (- local-seconds offset)
                     :when (eql offset (ical-offset-at-utc transitions utc))
                       :collect (cons utc offset)))
             (ordered
               (sort (remove-duplicates raw-candidates :test #'equal)
                     #'< :key #'car))
             (ordinary-candidates
               (loop :for (utc . offset) :in ordered
                     :for fold :from 0
                     :collect (make-timezone-resolution-candidate
                               utc offset fold)))
             (status
               (case (length ordinary-candidates)
                 (0 (if (< local-seconds
                            (ical-timezone-earliest-onset-local definition))
                        :uncovered
                        :gap))
                 (1 :unique)
                 (2 :fold)
                 (otherwise :ambiguous)))
             (candidates
               (if (eq status :gap)
                   (let ((candidate
                           (ical-rfc5545-gap-resolution-candidate
                            transitions local-seconds)))
                     (and candidate (list candidate)))
                   ordinary-candidates)))
        (make-timezone-local-resolution
         :status status :timezone-id timezone-id
         :local temporal :candidates candidates)))))

(defmethod project-utc-time-to-zoned-local-time
    ((provider embedded-timezone-provider) utc-temporal timezone-id)
  (require-non-empty-string timezone-id :invalid-timezone-id "timezone ID")
  (let* ((definition (find-timezone-definition provider timezone-id))
         (utc-seconds (ical-utc-temporal-seconds utc-temporal)))
    (unless definition
      (model-error :unknown-inverse-timezone timezone-id
                   "inverse timezone resolution requires a known timezone"))
    (multiple-value-bind (transitions recurrence-required-p)
        (ical-timezone-transitions
         definition (+ utc-seconds 172800)
         (embedded-timezone-max-transition-periods provider)
         (embedded-timezone-max-transition-candidates provider)
         (embedded-timezone-max-transitions provider))
      (when recurrence-required-p
        (model-error :inverse-timezone-requires-expansion timezone-id
                     "inverse timezone resolution requires recurring transition expansion"))
      (let ((offset (ical-offset-at-utc transitions utc-seconds)))
        (unless offset
          (model-error :uncovered-inverse-timezone-instant utc-temporal
                       "UTC instant precedes the provider's first transition"))
        (let* ((local
                 (make-temporal-value
                  :kind :zoned
                  :local-value
                  (ical-local-string-from-seconds (+ utc-seconds offset))
                  :timezone-id timezone-id :precision :second))
               (resolution (resolve-zoned-local-time provider local))
               (candidate-position
                 (position
                  utc-seconds
                  (timezone-local-resolution-candidates resolution)
                  :key #'timezone-resolution-candidate-utc-seconds
                  :test #'=)))
          (unless candidate-position
            (model-error :inconsistent-inverse-timezone-resolution local
                         "inverse projection did not round-trip to its UTC instant"))
          (make-temporal-value
           :kind :zoned :local-value (temporal-value-local-value local)
           :timezone-id timezone-id
           :fold (and (eq :fold (timezone-local-resolution-status resolution))
                      candidate-position)
           :precision :second))))))

(defun select-timezone-resolution (resolution &key fold (gap-policy :reject))
  "Select an instant only when ambiguity policy is explicit."
  (unless (timezone-local-resolution-p resolution)
    (model-error :invalid-timezone-resolution resolution
                 "value must be a timezone local resolution"))
  (case (timezone-local-resolution-status resolution)
    (:unique (first (timezone-local-resolution-candidates resolution)))
    (:fold
     (unless (member fold '(0 1))
       (model-error :missing-timezone-fold fold
                    "ambiguous local time requires fold 0 or 1"))
     (nth fold (timezone-local-resolution-candidates resolution)))
    (:gap
     (case gap-policy
       (:reject
        (model-error :nonexistent-timezone-local-time
                     (timezone-local-resolution-local resolution)
                     "local time falls in a timezone gap"))
       (:rfc5545
        (or (first (timezone-local-resolution-candidates resolution))
            (model-error :unresolved-timezone-gap resolution
                         "no pre-gap offset applies to this local time")))
       (otherwise
        (model-error :unsupported-timezone-gap-policy gap-policy
                     "the requested gap policy is not implemented"))))
    (otherwise
     (model-error :unresolved-timezone-local-time
                  (timezone-local-resolution-status resolution)
                  "timezone local time cannot be resolved"))))

(defun ical-positive-leap-second-predecessor-p (utc-seconds)
  (let ((utc-local (ical-local-string-from-seconds utc-seconds)))
    (and (string= "23:59:59" (subseq utc-local 11))
         (member (subseq utc-local 0 10)
                 +ical-positive-leap-second-utc-dates+ :test #'string=))))

(defun validate-ical-time-value-timezone-context
    (time date provider &key floating-timezone-id)
  "Validate a local standalone TIME with explicit date and timezone authority.

For second 60, the ordinary preceding local second is resolved through
PROVIDER.  The claim is accepted only when that local instant has one unique
mapping and maps to 23:59:59 immediately before a positive UTC leap second in
the pinned table.  Floating TIME requires FLOATING-TIMEZONE-ID.  Folds, gaps,
unknown zones, incomplete providers, and missing reference zones fail closed."
  (unless (ical-time-value-p time)
    (model-error :invalid-icalendar-time-timezone-context time
                 "timezone-context validation requires a typed TIME value"))
  (ical-date-context-components date)
  (unless (typep provider 'timezone-provider)
    (model-error :invalid-icalendar-time-timezone-provider provider
                 "timezone-context validation requires a timezone provider"))
  (unless (or (null floating-timezone-id)
              (non-empty-string-p floating-timezone-id))
    (model-error :invalid-icalendar-floating-timezone-id floating-timezone-id
                 "floating reference timezone ID must be non-empty or NIL"))
  (when (ical-time-value-utc-p time)
    (when floating-timezone-id
      (model-error :unexpected-icalendar-floating-timezone-id
                   floating-timezone-id
                   "UTC TIME cannot use a floating reference timezone"))
    (return-from validate-ical-time-value-timezone-context
      (validate-ical-time-value-date-context time date)))
  (let ((embedded-timezone-id (ical-time-value-timezone-id time)))
    (when (and embedded-timezone-id floating-timezone-id)
      (model-error :unexpected-icalendar-floating-timezone-id
                   floating-timezone-id
                   "TZID-qualified TIME cannot use a floating reference timezone"))
    (when (= 60 (ical-time-value-second time))
      (let ((timezone-id (or embedded-timezone-id floating-timezone-id)))
        (unless timezone-id
          (model-error :unresolved-icalendar-local-leap-second time
                       "floating leap second requires an explicit reference timezone"))
        (let* ((date-local (temporal-value-local-value date))
               (predecessor
                 (make-temporal-value
                  :kind :zoned
                  :local-value
                  (format nil "~aT~2,'0d:~2,'0d:59"
                          date-local (ical-time-value-hour time)
                          (ical-time-value-minute time))
                  :timezone-id timezone-id :gap-policy :reject
                  :precision :second))
               (resolution (resolve-zoned-local-time provider predecessor)))
          (unless (and (timezone-local-resolution-p resolution)
                       (eq :unique
                           (timezone-local-resolution-status resolution))
                       (= 1 (length
                             (timezone-local-resolution-candidates resolution))))
            (model-error :unresolved-icalendar-local-leap-second
                         (list time date timezone-id resolution)
                         "local leap second requires one unique timezone mapping"))
          (let ((candidate
                  (first (timezone-local-resolution-candidates resolution))))
            (unless (and (timezone-resolution-candidate-p candidate)
                         (ical-positive-leap-second-predecessor-p
                          (timezone-resolution-candidate-utc-seconds candidate)))
              (model-error :invalid-icalendar-positive-leap-second
                           (list time date timezone-id)
                           "local TIME second 60 does not map to a pinned positive UTC leap second")))))))
  time)

(defun validate-ical-date-time-leap-second-context
    (temporal provider &key floating-timezone-id)
  "Validate DATE-TIME leap-second context without normalizing second 60.

The typed DATE-TIME is split into exact DATE and TIME scalars, then validated
through `VALIDATE-ICAL-TIME-VALUE-TIMEZONE-CONTEXT'.  This preserves the
original temporal kind and uses provider arithmetic only for the ordinary
second immediately preceding a local positive leap second."
  (unless (and (temporal-value-p temporal)
               (member (temporal-value-kind temporal)
                       '(:floating :utc :zoned))
               (eq :second (temporal-value-precision temporal)))
    (model-error :invalid-icalendar-date-time-timezone-context temporal
                 "leap validation requires a second-precision DATE-TIME"))
  (let* ((kind (temporal-value-kind temporal))
         (text (temporal-value-local-value temporal))
         (utc-p (eq :utc kind))
         (expected-length (if utc-p 20 19)))
    (unless (and (= expected-length (length text))
                 (char= #\- (char text 4))
                 (char= #\- (char text 7))
                 (char= #\T (char text 10))
                 (char= #\: (char text 13))
                 (char= #\: (char text 16))
                 (or (not utc-p) (char= #\Z (char text 19))))
      (model-error :invalid-icalendar-date-time-timezone-context temporal
                   "DATE-TIME must use canonical Gregorian second precision"))
    (let ((date-raw
            (concatenate 'string (subseq text 0 4)
                         (subseq text 5 7) (subseq text 8 10)))
          (time-raw
            (concatenate 'string (subseq text 11 13)
                         (subseq text 14 16) (subseq text 17 19)
                         (if utc-p "Z" ""))))
      (multiple-value-bind (date date-valid-p date-message)
          (decode-ical-date date-raw)
        (unless date-valid-p
          (model-error :invalid-icalendar-date-time-timezone-context temporal
                       "DATE-TIME date is invalid: ~a" date-message))
        (multiple-value-bind (time time-valid-p time-message)
            (decode-ical-time
             time-raw (and (eq :zoned kind)
                           (temporal-value-timezone-id temporal)))
          (unless time-valid-p
            (model-error :invalid-icalendar-date-time-timezone-context temporal
                         "DATE-TIME time is invalid: ~a" time-message))
          (if (or (ical-time-value-utc-p time)
                  (< (ical-time-value-second time) 60))
              (validate-ical-time-value-date-context time date)
              (validate-ical-time-value-timezone-context
               time date provider
               :floating-timezone-id floating-timezone-id))))))
  temporal)
