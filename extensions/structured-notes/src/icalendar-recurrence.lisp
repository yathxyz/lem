(in-package #:lem-structured-notes)

(defstruct (ical-recurrence-limits
            (:constructor %make-ical-recurrence-limits
                (max-periods max-candidates max-instances)))
  (max-periods 100000 :type (integer 1) :read-only t)
  (max-candidates 1000000 :type (integer 1) :read-only t)
  (max-instances 10000 :type (integer 1) :read-only t))

(defun make-ical-recurrence-limits
    (&key (max-periods 100000) (max-candidates 1000000)
          (max-instances 10000))
  "Create explicit resource ceilings for one recurrence expansion."
  (dolist (entry (list (cons max-periods "period ceiling")
                       (cons max-candidates "candidate ceiling")
                       (cons max-instances "instance ceiling")))
    (unless (and (integerp (car entry)) (plusp (car entry)))
      (model-error :invalid-recurrence-limit (car entry)
                   "~a must be a positive integer" (cdr entry))))
  (%make-ical-recurrence-limits
   max-periods max-candidates max-instances))

(defstruct (ical-recurrence-expansion
            (:constructor %make-ical-recurrence-expansion
                (instances periods-examined candidates-examined)))
  (instances nil :type list :read-only t)
  (periods-examined 0 :type (integer 0) :read-only t)
  (candidates-examined 0 :type (integer 0) :read-only t))

(defstruct (ical-recurrence-civil
            (:constructor make-ical-recurrence-civil
                (year month day hour minute second)))
  year month day hour minute second)

(defparameter *ical-recurrence-weekday-numbers*
  '((:mo . 0) (:tu . 1) (:we . 2) (:th . 3)
    (:fr . 4) (:sa . 5) (:su . 6)))

(defun ical-recurrence-positive-limit (value label)
  (unless (and (integerp value) (plusp value))
    (model-error :invalid-recurrence-limit value
                 "~a must be a positive integer" label))
  value)

(defun ical-recurrence-days-from-civil (year month day)
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

(defun ical-recurrence-civil-from-days (days)
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

(defun ical-recurrence-civil-seconds (civil)
  (+ (* (ical-recurrence-days-from-civil
         (ical-recurrence-civil-year civil)
         (ical-recurrence-civil-month civil)
         (ical-recurrence-civil-day civil))
        86400)
     (* (ical-recurrence-civil-hour civil) 3600)
     (* (ical-recurrence-civil-minute civil) 60)
     (ical-recurrence-civil-second civil)))

(defun ical-recurrence-civil-from-seconds (seconds)
  (multiple-value-bind (days second-of-day) (floor seconds 86400)
    (multiple-value-bind (year month day)
        (ical-recurrence-civil-from-days days)
      (multiple-value-bind (hour rest) (floor second-of-day 3600)
        (multiple-value-bind (minute second) (floor rest 60)
          (make-ical-recurrence-civil
           year month day hour minute second))))))

(defun ical-recurrence-read-decimal (text start end)
  (or (ignore-errors
        (parse-integer text :start start :end end :junk-allowed nil))
      (model-error :invalid-recurrence-temporal text
                   "temporal value contains a non-decimal field")))

(defun ical-recurrence-temporal-civil (temporal)
  (unless (temporal-value-p temporal)
    (model-error :invalid-recurrence-temporal temporal
                 "recurrence values must be temporal values"))
  (let* ((kind (temporal-value-kind temporal))
         (text (temporal-value-local-value temporal))
         (date-p (eq kind :date))
         (expected-length (cond (date-p 10) ((eq kind :utc) 20) (t 19))))
    (unless (and (= (length text) expected-length)
                 (char= (char text 4) #\-)
                 (char= (char text 7) #\-)
                 (or date-p
                     (and (char= (char text 10) #\T)
                          (char= (char text 13) #\:)
                          (char= (char text 16) #\:)
                          (or (not (eq kind :utc))
                              (char= (char text 19) #\Z)))))
      (model-error :invalid-recurrence-temporal text
                   "temporal value is not in the normalized calendar form"))
    (let ((year (ical-recurrence-read-decimal text 0 4))
          (month (ical-recurrence-read-decimal text 5 7))
          (day (ical-recurrence-read-decimal text 8 10))
          (hour (if date-p 0 (ical-recurrence-read-decimal text 11 13)))
          (minute (if date-p 0 (ical-recurrence-read-decimal text 14 16)))
          (second (if date-p 0 (ical-recurrence-read-decimal text 17 19))))
      (unless (and (<= 0 year 9999) (<= 1 month 12)
                   (<= 1 day (ical-days-in-month year month))
                   (<= 0 hour 23) (<= 0 minute 59) (<= 0 second 60))
        (model-error :unsupported-recurrence-temporal temporal
                     "recurrence expansion requires a valid Gregorian value"))
      (when (= second 60)
        (unless (eq :utc kind)
          (model-error :unsupported-local-recurrence-leap-second temporal
                       "local recurrence leap seconds require explicit timezone context"))
        (validate-ical-date-time-leap-second-context temporal nil))
      (make-ical-recurrence-civil
       year month day hour minute (if (= second 60) 59 second)))))

(defun ical-recurrence-explicit-leap-second-p (temporal)
  (and (temporal-value-p temporal)
       (not (eq :date (temporal-value-kind temporal)))
       (let ((text (temporal-value-local-value temporal)))
         (and (>= (length text) 19)
              (string= "60" text :start2 17 :end2 19)))))

(defun ical-recurrence-compatible-temporal-p (left right)
  (and (eq (temporal-value-kind left) (temporal-value-kind right))
       (equal (temporal-value-timezone-id left)
              (temporal-value-timezone-id right))))

(defun ical-recurrence-require-compatible (start temporal label)
  (unless (and (temporal-value-p temporal)
               (ical-recurrence-compatible-temporal-p start temporal))
    (model-error :incompatible-recurrence-temporal temporal
                 "~a must have DTSTART's value kind and TZID" label))
  (ical-recurrence-temporal-civil temporal))

(defun ical-recurrence-temporal-key (temporal)
  (ical-recurrence-civil-seconds
   (ical-recurrence-temporal-civil temporal)))

(defun ical-recurrence-civil-temporal
    (civil prototype
     &key (fold (temporal-value-fold prototype))
          (gap-policy (temporal-value-gap-policy prototype)))
  (let* ((kind (temporal-value-kind prototype))
         (date-p (eq kind :date))
         (base
           (if date-p
               (format nil "~4,'0d-~2,'0d-~2,'0d"
                       (ical-recurrence-civil-year civil)
                       (ical-recurrence-civil-month civil)
                       (ical-recurrence-civil-day civil))
               (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d"
                       (ical-recurrence-civil-year civil)
                       (ical-recurrence-civil-month civil)
                       (ical-recurrence-civil-day civil)
                       (ical-recurrence-civil-hour civil)
                       (ical-recurrence-civil-minute civil)
                       (ical-recurrence-civil-second civil))))
         (local (if (eq kind :utc) (concatenate 'string base "Z") base)))
    (make-temporal-value
     :kind kind :local-value local
     :timezone-id (temporal-value-timezone-id prototype)
     :fold fold
     :gap-policy gap-policy
     :precision (if date-p :date :second))))

(defun ical-recurrence-local-second-59-temporal (temporal)
  (let ((local (copy-seq (temporal-value-local-value temporal))))
    (setf (char local 17) #\5
          (char local 18) #\9)
    (make-temporal-value
     :kind (temporal-value-kind temporal) :local-value local
     :timezone-id (temporal-value-timezone-id temporal)
     :fold (temporal-value-fold temporal)
     :gap-policy (temporal-value-gap-policy temporal)
     :precision :second)))

(defun ical-recurrence-normalize-explicit-leap-second
    (temporal &key timezone-provider floating-timezone-id)
  (if (not (ical-recurrence-explicit-leap-second-p temporal))
      (progn (ical-recurrence-temporal-civil temporal) temporal)
      (progn
        (validate-ical-date-time-leap-second-context
         temporal timezone-provider
         :floating-timezone-id floating-timezone-id)
        (ical-recurrence-local-second-59-temporal temporal))))

(defun ical-recurrence-weekday-number (weekday)
  (or (cdr (assoc weekday *ical-recurrence-weekday-numbers*))
      (model-error :invalid-recurrence-weekday weekday
                   "weekday is not recognized")))

(defun ical-recurrence-day-weekday (days)
  ;; 1970-01-01 was Thursday, represented as Monday-based index 3.
  (mod (+ days 3) 7))

(defun ical-recurrence-week-one-start (year week-start)
  (let* ((january-fourth
           (ical-recurrence-days-from-civil year 1 4))
         (weekday (ical-recurrence-day-weekday january-fourth)))
    (- january-fourth (mod (- weekday week-start) 7))))

(defun ical-recurrence-weeks-in-year (year week-start)
  (/ (- (ical-recurrence-week-one-start (1+ year) week-start)
        (ical-recurrence-week-one-start year week-start))
     7))

(defun ical-recurrence-year-day (civil)
  (1+ (- (ical-recurrence-days-from-civil
          (ical-recurrence-civil-year civil)
          (ical-recurrence-civil-month civil)
          (ical-recurrence-civil-day civil))
         (ical-recurrence-days-from-civil
          (ical-recurrence-civil-year civil) 1 1))))

(defun ical-recurrence-value-matches-index-p (value size selectors)
  (some (lambda (selector)
          (= value (if (plusp selector)
                       selector
                       (+ size selector 1))))
        selectors))

(defun ical-recurrence-nth-weekday-in-month-p (civil ordinal weekday)
  (let* ((year (ical-recurrence-civil-year civil))
         (month (ical-recurrence-civil-month civil))
         (day (ical-recurrence-civil-day civil))
         (days-in-month (ical-days-in-month year month))
         (target (ical-recurrence-weekday-number weekday))
         (first-weekday
           (ical-recurrence-day-weekday
            (ical-recurrence-days-from-civil year month 1)))
         (last-weekday
           (ical-recurrence-day-weekday
            (ical-recurrence-days-from-civil year month days-in-month)))
         (expected
           (if (plusp ordinal)
               (+ 1 (mod (- target first-weekday) 7)
                  (* 7 (1- ordinal)))
               (- days-in-month (mod (- last-weekday target) 7)
                  (* 7 (1- (- ordinal)))))))
    (= day expected)))

(defun ical-recurrence-nth-weekday-in-year-p (civil ordinal weekday)
  (let* ((year (ical-recurrence-civil-year civil))
         (day-of-year (ical-recurrence-year-day civil))
         (days-in-year (if (ical-leap-year-p year) 366 365))
         (target (ical-recurrence-weekday-number weekday))
         (first-weekday
           (ical-recurrence-day-weekday
            (ical-recurrence-days-from-civil year 1 1)))
         (last-weekday
           (ical-recurrence-day-weekday
            (ical-recurrence-days-from-civil year 12 31)))
         (expected
           (if (plusp ordinal)
               (+ 1 (mod (- target first-weekday) 7)
                  (* 7 (1- ordinal)))
               (- days-in-year (mod (- last-weekday target) 7)
                  (* 7 (1- (- ordinal)))))))
    (= day-of-year expected)))

(defun ical-recurrence-by-day-match-p (civil rule)
  (let ((selectors (ical-recur-value-by-day rule)))
    (or (null selectors)
        (some
         (lambda (selector)
           (let ((ordinal (ical-recur-weekday-ordinal selector))
                 (weekday (ical-recur-weekday-weekday selector)))
             (if (null ordinal)
                 (= (ical-recurrence-day-weekday
                     (ical-recurrence-days-from-civil
                      (ical-recurrence-civil-year civil)
                      (ical-recurrence-civil-month civil)
                      (ical-recurrence-civil-day civil)))
                    (ical-recurrence-weekday-number weekday))
                 (if (or (eq :monthly (ical-recur-value-frequency rule))
                         (and (eq :yearly
                                  (ical-recur-value-frequency rule))
                              (ical-recur-value-by-month rule)))
                     (ical-recurrence-nth-weekday-in-month-p
                      civil ordinal weekday)
                     (ical-recurrence-nth-weekday-in-year-p
                      civil ordinal weekday)))))
         selectors))))

(defun ical-recurrence-explicit-date-match-p
    (civil rule recurrence-year week-start)
  (let* ((year (ical-recurrence-civil-year civil))
         (month (ical-recurrence-civil-month civil))
         (day (ical-recurrence-civil-day civil))
         (days-in-month (ical-days-in-month year month))
         (days-in-year (if (ical-leap-year-p year) 366 365))
         (absolute-day (ical-recurrence-days-from-civil year month day)))
    (and
     (or (null (ical-recur-value-by-month rule))
         (member month (ical-recur-value-by-month rule)))
     (or (null (ical-recur-value-by-month-day rule))
         (ical-recurrence-value-matches-index-p
          day days-in-month (ical-recur-value-by-month-day rule)))
     (or (null (ical-recur-value-by-year-day rule))
         (and (= year recurrence-year)
              (ical-recurrence-value-matches-index-p
               (ical-recurrence-year-day civil) days-in-year
               (ical-recur-value-by-year-day rule))))
     (or (null (ical-recur-value-by-week-number rule))
         (let* ((week-one
                  (ical-recurrence-week-one-start recurrence-year week-start))
                (week-count
                  (ical-recurrence-weeks-in-year recurrence-year week-start))
                (week (1+ (floor (- absolute-day week-one) 7))))
           (and (<= 1 week week-count)
                (ical-recurrence-value-matches-index-p
                 week week-count
                 (ical-recur-value-by-week-number rule)))))
     (ical-recurrence-by-day-match-p civil rule))))

(defun ical-recurrence-implicit-date-match-p (civil rule start-civil)
  (case (ical-recur-value-frequency rule)
    (:yearly
     (if (or (ical-recur-value-by-week-number rule)
             (ical-recur-value-by-year-day rule)
             (ical-recur-value-by-month-day rule)
             (ical-recur-value-by-day rule))
         t
         (and (= (ical-recurrence-civil-day civil)
                 (ical-recurrence-civil-day start-civil))
              (or (ical-recur-value-by-month rule)
                  (= (ical-recurrence-civil-month civil)
                     (ical-recurrence-civil-month start-civil))))))
    (:monthly
     (or (ical-recur-value-by-month-day rule)
         (ical-recur-value-by-day rule)
         (= (ical-recurrence-civil-day civil)
            (ical-recurrence-civil-day start-civil))))
    (:weekly
     (or (ical-recur-value-by-day rule)
         (= (ical-recurrence-day-weekday
             (ical-recurrence-days-from-civil
              (ical-recurrence-civil-year civil)
              (ical-recurrence-civil-month civil)
              (ical-recurrence-civil-day civil)))
            (ical-recurrence-day-weekday
             (ical-recurrence-days-from-civil
              (ical-recurrence-civil-year start-civil)
              (ical-recurrence-civil-month start-civil)
              (ical-recurrence-civil-day start-civil))))))
    (otherwise t)))

(defun ical-recurrence-effective-by-seconds (rule)
  "Return BYSECOND with RFC 5545's permitted 60-to-59 equivalence applied."
  (let ((seconds (ical-recur-value-by-second rule)))
    (and seconds
         (sort
          (remove-duplicates
           (mapcar (lambda (second) (if (= second 60) 59 second)) seconds)
           :test #'=)
          #'<))))

(defun ical-recurrence-time-match-p (civil rule date-p)
  (or date-p
      (and
       (or (null (ical-recur-value-by-hour rule))
           (member (ical-recurrence-civil-hour civil)
                   (ical-recur-value-by-hour rule)))
       (or (null (ical-recur-value-by-minute rule))
           (member (ical-recurrence-civil-minute civil)
                   (ical-recur-value-by-minute rule)))
       (or (null (ical-recur-value-by-second rule))
           (member (ical-recurrence-civil-second civil)
                   (ical-recurrence-effective-by-seconds rule))))))

(defun ical-recurrence-frequency-rank (frequency)
  (position frequency
            '(:yearly :monthly :weekly :daily :hourly :minutely :secondly)))

(defun ical-recurrence-period-anchor (start-civil frequency week-start)
  (let ((year (ical-recurrence-civil-year start-civil))
        (month (ical-recurrence-civil-month start-civil))
        (day (ical-recurrence-civil-day start-civil))
        (hour (ical-recurrence-civil-hour start-civil))
        (minute (ical-recurrence-civil-minute start-civil))
        (second (ical-recurrence-civil-second start-civil)))
    (case frequency
      (:yearly (make-ical-recurrence-civil year 1 1 0 0 0))
      (:monthly (make-ical-recurrence-civil year month 1 0 0 0))
      (:weekly
       (let* ((days (ical-recurrence-days-from-civil year month day))
              (anchor (- days
                         (mod (- (ical-recurrence-day-weekday days)
                                 week-start)
                              7))))
         (ical-recurrence-civil-from-seconds (* anchor 86400))))
      (:daily (make-ical-recurrence-civil year month day 0 0 0))
      (:hourly (make-ical-recurrence-civil year month day hour 0 0))
      (:minutely (make-ical-recurrence-civil year month day hour minute 0))
      (:secondly
       (make-ical-recurrence-civil year month day hour minute second)))))

(defun ical-recurrence-add-months (civil months)
  (let* ((absolute (+ (* (ical-recurrence-civil-year civil) 12)
                      (1- (ical-recurrence-civil-month civil)) months))
         (year (floor absolute 12))
         (month (1+ (mod absolute 12))))
    (make-ical-recurrence-civil
     year month 1 (ical-recurrence-civil-hour civil)
     (ical-recurrence-civil-minute civil)
     (ical-recurrence-civil-second civil))))

(defun ical-recurrence-next-period (anchor frequency interval)
  (case frequency
    (:yearly
     (make-ical-recurrence-civil
      (+ (ical-recurrence-civil-year anchor) interval) 1 1 0 0 0))
    (:monthly (ical-recurrence-add-months anchor interval))
    (:weekly
     (ical-recurrence-civil-from-seconds
      (+ (ical-recurrence-civil-seconds anchor) (* interval 7 86400))))
    (:daily
     (ical-recurrence-civil-from-seconds
      (+ (ical-recurrence-civil-seconds anchor) (* interval 86400))))
    (:hourly
     (ical-recurrence-civil-from-seconds
      (+ (ical-recurrence-civil-seconds anchor) (* interval 3600))))
    (:minutely
     (ical-recurrence-civil-from-seconds
      (+ (ical-recurrence-civil-seconds anchor) (* interval 60))))
    (:secondly
     (ical-recurrence-civil-from-seconds
      (+ (ical-recurrence-civil-seconds anchor) interval)))))

(defun ical-recurrence-period-day-range
    (anchor frequency recurrence-year week-start rule)
  (declare (ignore recurrence-year))
  (let* ((year (ical-recurrence-civil-year anchor))
         (month (ical-recurrence-civil-month anchor))
         (day (ical-recurrence-civil-day anchor))
         (start (ical-recurrence-days-from-civil year month day)))
    (case frequency
      (:yearly
       (if (ical-recur-value-by-week-number rule)
           (values (ical-recurrence-week-one-start year week-start)
                   (ical-recurrence-week-one-start (1+ year) week-start))
           (values start
                   (ical-recurrence-days-from-civil (1+ year) 1 1))))
      (:monthly
       (values start
               (ical-recurrence-days-from-civil
                (if (= month 12) (1+ year) year)
                (if (= month 12) 1 (1+ month)) 1)))
      (:weekly (values start (+ start 7)))
      (otherwise (values start (1+ start))))))

(defun ical-recurrence-period-time-values (anchor start-civil rule date-p)
  (if date-p
      (values '(0) '(0) '(0))
      (let ((rank (ical-recurrence-frequency-rank
                   (ical-recur-value-frequency rule))))
        (values
         (if (<= rank 3)
             (or (ical-recur-value-by-hour rule)
                 (list (ical-recurrence-civil-hour start-civil)))
             (list (ical-recurrence-civil-hour anchor)))
         (if (<= rank 4)
             (or (ical-recur-value-by-minute rule)
                 (list (ical-recurrence-civil-minute start-civil)))
             (list (ical-recurrence-civil-minute anchor)))
         (if (<= rank 5)
             (or (ical-recurrence-effective-by-seconds rule)
                 (list (ical-recurrence-civil-second start-civil)))
             (list (ical-recurrence-civil-second anchor)))))))

(defun ical-recurrence-period-earliest-key
    (anchor frequency rule week-start)
  (if (member frequency '(:hourly :minutely :secondly))
      (ical-recurrence-civil-seconds anchor)
      (multiple-value-bind (first-day end-day)
          (ical-recurrence-period-day-range
           anchor frequency (ical-recurrence-civil-year anchor)
           week-start rule)
        (declare (ignore end-day))
        (* first-day 86400))))

(defun ical-recurrence-apply-set-position (candidates positions)
  (if (null positions)
      candidates
      (let ((length (length candidates))
            (selected nil))
        (dolist (position positions)
          (let ((index (if (plusp position) (1- position)
                           (+ length position))))
            (when (<= 0 index (1- length))
              (pushnew (nth index candidates) selected :test #'=))))
        (sort selected #'<))))

(defun ical-recurrence-period-candidates
    (anchor start-civil rule date-p candidate-counter candidate-limit)
  (let* ((frequency (ical-recur-value-frequency rule))
         (recurrence-year (ical-recurrence-civil-year anchor))
         (week-start
           (ical-recurrence-weekday-number
            (or (ical-recur-value-week-start rule) :mo)))
         (results nil))
    (multiple-value-bind (first-day end-day)
        (ical-recurrence-period-day-range
         anchor frequency recurrence-year week-start rule)
      (multiple-value-bind (hours minutes seconds)
          (ical-recurrence-period-time-values
           anchor start-civil rule date-p)
        (loop :for absolute-day :from first-day :below end-day
              :do
                 (multiple-value-bind (year month day)
                     (ical-recurrence-civil-from-days absolute-day)
                   (dolist (hour hours)
                     (dolist (minute minutes)
                       (dolist (second seconds)
                         (incf (car candidate-counter))
                         (when (> (car candidate-counter) candidate-limit)
                           (model-error :recurrence-candidate-limit-exceeded
                                        candidate-limit
                                        "recurrence candidate ceiling was exceeded"))
                         (let ((civil (make-ical-recurrence-civil
                                       year month day hour minute second)))
                           (when (and
                                  (ical-recurrence-explicit-date-match-p
                                   civil rule recurrence-year week-start)
                                  (ical-recurrence-implicit-date-match-p
                                   civil rule start-civil)
                                  (ical-recurrence-time-match-p
                                   civil rule date-p))
                             (push (ical-recurrence-civil-seconds civil)
                                   results)))))))))
    (ical-recurrence-apply-set-position
     (sort (remove-duplicates results :test #'=) #'<)
     (ical-recur-value-by-set-position rule)))))

(defun ical-recurrence-until-key
    (start rule timezone-provider candidate-utc-function)
  (let ((until (ical-recur-value-until rule)))
    (when until
      (if candidate-utc-function
          (progn
            (unless (eq :utc (temporal-value-kind until))
              (model-error :incompatible-recurrence-until until
                           "custom UTC recurrence conversion requires UTC UNTIL"))
            (ical-recurrence-temporal-key until))
          (case (temporal-value-kind start)
            ((:date :floating :utc)
             (unless (ical-recurrence-compatible-temporal-p start until)
               (model-error :incompatible-recurrence-until until
                            "UNTIL must match DTSTART's temporal kind"))
             (ical-recurrence-temporal-key until))
            (:zoned
             (unless (eq :utc (temporal-value-kind until))
               (model-error :incompatible-recurrence-until until
                            "zoned DTSTART requires UTC UNTIL"))
             (unless timezone-provider
               (model-error :missing-recurrence-timezone-provider
                            (temporal-value-timezone-id start)
                            "zoned recurrence with UNTIL requires a timezone provider"))
             (ical-recurrence-temporal-key until)))))))

(defun ical-recurrence-candidate-until-key
    (candidate start timezone-provider candidate-utc-function)
  (cond
    (candidate-utc-function
     (let ((value (funcall candidate-utc-function candidate)))
       (unless (integerp value)
         (model-error :invalid-recurrence-utc-conversion value
                      "candidate UTC conversion must return integer seconds"))
       value))
    ((not (eq :zoned (temporal-value-kind start)))
     (ical-recurrence-temporal-key candidate))
    (t
     (let* ((resolution
              (resolve-zoned-local-time timezone-provider candidate))
            (selected
              (select-timezone-resolution
               resolution :fold (temporal-value-fold candidate)
               :gap-policy (or (temporal-value-gap-policy candidate)
                               :reject))))
       (timezone-resolution-candidate-utc-seconds selected)))))

(defun ical-recurrence-normalize-rule-candidate
    (candidate timezone-provider)
  (if (not (eq :zoned (temporal-value-kind candidate)))
      candidate
      (let ((resolution
              (resolve-zoned-local-time timezone-provider candidate)))
        (case (timezone-local-resolution-status resolution)
          (:unique candidate)
          (:fold
           ;; RFC 5545 DATE-TIME chooses the first occurrence in a fold.
           (ical-recurrence-civil-temporal
            (ical-recurrence-temporal-civil candidate) candidate :fold 0))
          (:gap
           ;; RFC 5545 Section 3.3.5, as clarified by verified erratum 4271,
           ;; interprets nonexistent local recurrence times with the UTC
           ;; offset before the gap.  They remain recurrence instances and
           ;; consume COUNT.
           (ical-recurrence-civil-temporal
            (ical-recurrence-temporal-civil candidate) candidate
            :gap-policy :rfc5545))
          (otherwise
           (model-error :unresolved-recurrence-timezone
                        (timezone-local-resolution-status resolution)
                        "zoned recurrence candidate cannot be resolved"))))))

(defun ical-recurrence-validate-rule-context
    (start rule timezone-provider)
  (unless (ical-recur-value-p rule)
    (model-error :invalid-recurrence-rule rule
                 "RRULE must be a parsed RFC 5545 RECUR value"))
  (when (ical-recur-value-recurrence-scale rule)
    (model-error :unsupported-rscale-recurrence-execution
                 (ical-recur-value-recurrence-scale rule)
                 "preserve-only RFC 7529 support does not execute RSCALE recurrence"))
  (when (and (eq :date (temporal-value-kind start))
             (member (ical-recur-value-frequency rule)
                     '(:secondly :minutely :hourly)))
    (model-error :unsupported-date-recurrence-frequency
                 (ical-recur-value-frequency rule)
                 "DATE recurrence cannot use a sub-daily frequency"))
  (when (and (eq :zoned (temporal-value-kind start))
             (null timezone-provider))
    (model-error :missing-recurrence-timezone-provider
                 (temporal-value-timezone-id start)
                 "zoned RRULE expansion requires a timezone provider")))

(defun ical-recurrence-normalize-input-list
    (values start label candidate-counter candidate-limit
     &key allow-period-p timezone-provider floating-timezone-id)
  (let ((copy (copy-proper-list values :invalid-recurrence-input label)))
    (mapcar
     (lambda (value)
       (incf (car candidate-counter))
       (when (> (car candidate-counter) candidate-limit)
         (model-error :recurrence-candidate-limit-exceeded candidate-limit
                      "recurrence input and generated candidate ceiling was exceeded"))
       (let ((temporal
               (cond
                 ((temporal-value-p value) value)
                 ((and allow-period-p (ical-period-value-p value))
                  (ical-period-value-start value))
                 (t
                  (model-error :invalid-recurrence-input-value value
                               "~a must contain DATE DATE-TIME~:[~; or PERIOD~] values"
                               label allow-period-p)))))
         (let ((normalized
                 (ical-recurrence-normalize-explicit-leap-second
                  temporal :timezone-provider timezone-provider
                  :floating-timezone-id floating-timezone-id)))
           (ical-recurrence-require-compatible start normalized label)
           normalized)))
     copy)))

(defun expand-ical-recurrence-set
    (start &key rule (recurrence-dates nil) (exception-dates nil)
            window-start window-end
            (limits (make-ical-recurrence-limits)) timezone-provider
            floating-timezone-id candidate-utc-function)
  "Expand one RFC 5545 Gregorian recurrence set within a half-open window.

The result is deterministic and fails rather than returning a truncated set
when any configured resource ceiling is reached.  Detached RECURRENCE-ID
overrides are intentionally outside this generator.  Explicit floating leap
seconds require both TIMEZONE-PROVIDER and FLOATING-TIMEZONE-ID; TZID values
reuse TIMEZONE-PROVIDER and no ambient timezone is consulted."
  (unless (ical-recurrence-limits-p limits)
    (model-error :invalid-recurrence-limits limits
                 "limits must be an ICAL-RECURRENCE-LIMITS value"))
  (setf start
        (ical-recurrence-normalize-explicit-leap-second
         start :timezone-provider timezone-provider
         :floating-timezone-id floating-timezone-id)
        window-start
        (ical-recurrence-normalize-explicit-leap-second
         window-start :timezone-provider timezone-provider
         :floating-timezone-id floating-timezone-id)
        window-end
        (ical-recurrence-normalize-explicit-leap-second
         window-end :timezone-provider timezone-provider
         :floating-timezone-id floating-timezone-id))
  (let* ((start-civil (ical-recurrence-temporal-civil start))
         (start-key (ical-recurrence-civil-seconds start-civil))
         (window-start-civil
           (ical-recurrence-require-compatible
            start window-start "window start"))
         (window-end-civil
           (ical-recurrence-require-compatible
            start window-end "window end"))
         (window-start-key
           (ical-recurrence-civil-seconds window-start-civil))
         (window-end-key
           (ical-recurrence-civil-seconds window-end-civil))
         (candidate-counter (list 0))
         (periods 0)
         (rule-instances nil))
    (unless (< window-start-key window-end-key)
      (model-error :invalid-recurrence-window
                   (cons window-start window-end)
                   "recurrence window must be non-empty and increasing"))
    (let ((rdates
            (ical-recurrence-normalize-input-list
             recurrence-dates start "RDATE"
             candidate-counter
             (ical-recurrence-limits-max-candidates limits)
             :allow-period-p t
             :timezone-provider timezone-provider
             :floating-timezone-id floating-timezone-id))
          (exdates
            (ical-recurrence-normalize-input-list
             exception-dates start "EXDATE"
             candidate-counter
             (ical-recurrence-limits-max-candidates limits)
             :timezone-provider timezone-provider
             :floating-timezone-id floating-timezone-id)))
      (when rule
        (ical-recurrence-validate-rule-context
         start rule timezone-provider)
        (let* ((frequency (ical-recur-value-frequency rule))
               (interval (or (ical-recur-value-interval rule) 1))
               (count (ical-recur-value-count rule))
               (until-key
                 (ical-recurrence-until-key
                  start rule timezone-provider candidate-utc-function))
               (date-p (eq :date (temporal-value-kind start)))
               (week-start
                 (ical-recurrence-weekday-number
                  (or (ical-recur-value-week-start rule) :mo)))
               (anchor
                 (ical-recurrence-period-anchor
                  start-civil frequency week-start))
               (generated-count 0)
               (finished-p nil)
               (start-seen-p nil))
          (loop :until finished-p
                :do
                   (incf periods)
                   (when (> periods
                            (ical-recurrence-limits-max-periods limits))
                     (model-error :recurrence-period-limit-exceeded
                                  (ical-recurrence-limits-max-periods limits)
                                  "recurrence period ceiling was exceeded"))
                   (let ((period-keys
                           (ical-recurrence-period-candidates
                            anchor start-civil rule date-p candidate-counter
                            (ical-recurrence-limits-max-candidates limits))))
                     (dolist (key period-keys)
                       (when (>= key start-key)
                         (when (and (not start-seen-p) (/= key start-key))
                           (model-error :unsynchronized-recurrence-start start
                                        "DTSTART must be the first occurrence generated by RRULE"))
                         (setf start-seen-p t)
                         (let* ((candidate
                                  (ical-recurrence-civil-temporal
                                   (ical-recurrence-civil-from-seconds key)
                                   start))
                                (normalized
                                  (ical-recurrence-normalize-rule-candidate
                                   candidate timezone-provider)))
                           (when normalized
                             (let ((candidate-until-key
                                     (and until-key
                                          (ical-recurrence-candidate-until-key
                                           normalized start
                                           timezone-provider
                                           candidate-utc-function))))
                               (when (and until-key
                                          (> candidate-until-key until-key))
                                 (setf finished-p t)
                                 (return))
                               (incf generated-count)
                               (push normalized rule-instances)
                               (when (and count
                                          (>= generated-count count))
                                 (setf finished-p t)
                                 (return))))))))
                   (unless finished-p
                     (setf anchor
                           (ical-recurrence-next-period
                            anchor frequency interval))
                     (when (or (> (ical-recurrence-civil-year anchor) 9999)
                               (>= (ical-recurrence-period-earliest-key
                                    anchor frequency rule week-start)
                                   window-end-key))
                       (setf finished-p t))))
          (unless start-seen-p
            (model-error :unsynchronized-recurrence-start start
                         "DTSTART is not generated by RRULE"))))
      (let* ((all
               (cons start
                     (append rule-instances rdates)))
             (excluded
               (mapcar #'ical-recurrence-temporal-key exdates))
             (filtered
               (remove-if
                (lambda (temporal)
                  (let ((key (ical-recurrence-temporal-key temporal)))
                    (or (< key window-start-key)
                        (>= key window-end-key)
                        (member key excluded :test #'=))))
                all))
             (ordered
               (sort
                (remove-duplicates filtered
                                   :test (lambda (left right)
                                           (= (ical-recurrence-temporal-key left)
                                              (ical-recurrence-temporal-key right))))
                #'< :key #'ical-recurrence-temporal-key)))
        (when (> (length ordered)
                 (ical-recurrence-limits-max-instances limits))
          (model-error :recurrence-instance-limit-exceeded
                       (ical-recurrence-limits-max-instances limits)
                       "recurrence instance ceiling was exceeded"))
        (%make-ical-recurrence-expansion
         ordered periods (car candidate-counter))))))

(defun expand-ical-calendar-item-recurrence
    (item &key window-start window-end
           (limits (make-ical-recurrence-limits)) timezone-provider
           floating-timezone-id)
  "Expand the master recurrence set retained by one projected calendar item."
  (unless (and (ical-calendar-item-p item)
               (ical-calendar-item-valid-p item))
    (model-error :invalid-recurrence-calendar-item item
                 "recurrence expansion requires a valid projected item"))
  (when (ical-calendar-item-recurrence-id item)
    (model-error :detached-recurrence-instance item
                 "a RECURRENCE-ID component is an override, not a recurrence master"))
  (unless (ical-calendar-item-start item)
    (model-error :missing-recurrence-start item
                 "calendar recurrence expansion requires DTSTART"))
  (expand-ical-recurrence-set
   (ical-calendar-item-start item)
   :rule (ical-calendar-item-recurrence-rule item)
   :recurrence-dates (ical-calendar-item-recurrence-dates item)
   :exception-dates (ical-calendar-item-recurrence-exception-dates item)
   :window-start window-start :window-end window-end
   :limits limits :timezone-provider timezone-provider
   :floating-timezone-id floating-timezone-id))
