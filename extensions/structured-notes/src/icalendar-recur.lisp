(in-package #:lem-structured-notes)

(defstruct (ical-recur-weekday
            (:constructor %make-ical-recur-weekday (ordinal weekday)))
  (ordinal nil :type (or null integer) :read-only t)
  (weekday :mo :type keyword :read-only t))

(defstruct (ical-recur-value
            (:constructor %make-ical-recur-value
                (original-lexeme frequency until count interval by-second
                 by-minute by-hour by-day by-month-day by-year-day
                 by-week-number by-month by-set-position week-start
                 recurrence-scale skip)))
  (original-lexeme "" :type string :read-only t)
  (frequency :daily :type keyword :read-only t)
  (until nil :type (or null temporal-value) :read-only t)
  (count nil :type (or null integer) :read-only t)
  (interval nil :type (or null integer) :read-only t)
  (by-second nil :type list :read-only t)
  (by-minute nil :type list :read-only t)
  (by-hour nil :type list :read-only t)
  (by-day nil :type list :read-only t)
  (by-month-day nil :type list :read-only t)
  (by-year-day nil :type list :read-only t)
  (by-week-number nil :type list :read-only t)
  (by-month nil :type list :read-only t)
  (by-set-position nil :type list :read-only t)
  (week-start nil :type (or null keyword) :read-only t)
  (recurrence-scale nil :type (or null string) :read-only t)
  (skip nil :type (or null keyword) :read-only t))

(defparameter *ical-recur-part-names*
  '("FREQ" "UNTIL" "COUNT" "INTERVAL" "BYSECOND" "BYMINUTE"
    "BYHOUR" "BYDAY" "BYMONTHDAY" "BYYEARDAY" "BYWEEKNO" "BYMONTH"
    "BYSETPOS" "WKST" "RSCALE" "SKIP"))

(defparameter *ical-recur-frequencies*
  '(("SECONDLY" . :secondly) ("MINUTELY" . :minutely)
    ("HOURLY" . :hourly) ("DAILY" . :daily) ("WEEKLY" . :weekly)
    ("MONTHLY" . :monthly) ("YEARLY" . :yearly)))

(defparameter *ical-recur-weekdays*
  '(("SU" . :su) ("MO" . :mo) ("TU" . :tu) ("WE" . :we)
    ("TH" . :th) ("FR" . :fr) ("SA" . :sa)))

(defun ical-recur-split (text delimiter)
  (loop :with start := 0
        :for position := (position delimiter text :start start)
        :collect (subseq text start position)
        :while position
        :do (setf start (1+ position))))

(defun ical-recur-positive-integer (raw label)
  (if (and (ical-digit-string-p raw)
           (plusp (ical-unsigned-integer raw)))
      (values (ical-unsigned-integer raw) t nil)
      (values nil nil (format nil "~a must be a positive integer" label))))

(defun ical-recur-number (raw signed-p maximum max-digits zero-allowed-p label)
  (let* ((signed-character-p
           (and (plusp (length raw))
                (member (char raw 0) '(#\+ #\-))))
         (digits (if signed-character-p (subseq raw 1) raw)))
    (unless (and (plusp (length digits))
                 (<= (length digits) max-digits)
                 (ical-digit-string-p digits)
                 (or signed-p (not signed-character-p)))
      (return-from ical-recur-number
        (values nil nil (format nil "~a has invalid integer syntax" label))))
    (let* ((magnitude (ical-unsigned-integer digits))
           (value (if (and signed-character-p (char= (char raw 0) #\-))
                      (- magnitude)
                      magnitude)))
      (if (and (<= (abs value) maximum)
               (or zero-allowed-p (not (zerop value))))
          (values value t nil)
          (values nil nil (format nil "~a is outside its permitted range"
                                  label))))))

(defun ical-recur-number-list
    (raw signed-p maximum max-digits zero-allowed-p label)
  (let ((parts (ical-recur-split raw #\,))
        (result nil))
    (when (some (lambda (part) (zerop (length part))) parts)
      (return-from ical-recur-number-list
        (values nil nil (format nil "~a contains an empty list item" label))))
    (dolist (part parts)
      (multiple-value-bind (value valid-p message)
          (ical-recur-number part signed-p maximum max-digits zero-allowed-p
                             label)
        (unless valid-p
          (return-from ical-recur-number-list (values nil nil message)))
        (push value result)))
    (values (nreverse result) t nil)))

(defun ical-rscale-month-list (raw)
  (let ((parts (ical-recur-split raw #\,))
        (result nil))
    (when (some (lambda (part) (zerop (length part))) parts)
      (return-from ical-rscale-month-list
        (values nil nil "BYMONTH contains an empty list item")))
    (dolist (part parts)
      (let* ((length (length part))
             (leap-p (and (plusp length)
                          (char-equal #\L (char part (1- length)))))
             (digits (if leap-p (subseq part 0 (1- length)) part)))
        (unless (and (plusp (length digits))
                     (<= (length digits) 2)
                     (ical-digit-string-p digits)
                     (plusp (ical-unsigned-integer digits)))
          (return-from ical-rscale-month-list
            (values nil nil "RSCALE BYMONTH requires 1*2DIGIT with optional L")))
        (let ((month (ical-unsigned-integer digits)))
          (push (if leap-p (format nil "~dL" month) month) result))))
    (values (nreverse result) t nil)))

(defun ical-recur-weekday
    (raw ordinal-allowed-p label &optional (ordinal-maximum 53))
  (unless (>= (length raw) 2)
    (return-from ical-recur-weekday
      (values nil nil (format nil "~a has no weekday" label))))
  (let* ((weekday-text (string-upcase (subseq raw (- (length raw) 2))))
         (weekday (cdr (assoc weekday-text *ical-recur-weekdays*
                              :test #'string=)))
         (ordinal-text (subseq raw 0 (- (length raw) 2))))
    (unless weekday
      (return-from ical-recur-weekday
        (values nil nil (format nil "~a has an invalid weekday" label))))
    (if (zerop (length ordinal-text))
        (values (%make-ical-recur-weekday nil weekday) t nil)
        (progn
          (unless ordinal-allowed-p
            (return-from ical-recur-weekday
              (values nil nil (format nil "~a does not permit an ordinal"
                                      label))))
          (multiple-value-bind (ordinal valid-p message)
              (ical-recur-number ordinal-text t ordinal-maximum 2 nil label)
            (if valid-p
                (values (%make-ical-recur-weekday ordinal weekday) t nil)
                (values nil nil message)))))))

(defun ical-recur-weekday-list (raw &optional (ordinal-maximum 53))
  (let ((parts (ical-recur-split raw #\,))
        (result nil))
    (when (some (lambda (part) (zerop (length part))) parts)
      (return-from ical-recur-weekday-list
        (values nil nil "BYDAY contains an empty list item")))
    (dolist (part parts)
      (multiple-value-bind (weekday valid-p message)
          (ical-recur-weekday part t "BYDAY" ordinal-maximum)
        (unless valid-p
          (return-from ical-recur-weekday-list (values nil nil message)))
        (push weekday result)))
    (values (nreverse result) t nil)))

(defun ical-recur-until (raw)
  (if (= (length raw) 8)
      (decode-ical-date raw)
      (decode-ical-date-time raw nil)))

(defun ical-recur-parse-parts (raw)
  (let ((parts (ical-recur-split raw #\;))
        (table (make-hash-table :test #'equal)))
    (when (some (lambda (part) (zerop (length part))) parts)
      (return-from ical-recur-parse-parts
        (values nil nil "recurrence rule contains an empty rule part")))
    (dolist (part parts)
      (let ((equals (position #\= part)))
        (unless (and equals (plusp equals) (< equals (1- (length part)))
                     (null (position #\= part :start (1+ equals))))
          (return-from ical-recur-parse-parts
            (values nil nil "recurrence rule part must be NAME=VALUE")))
        (let ((name (string-upcase (subseq part 0 equals)))
              (value (subseq part (1+ equals))))
          (unless (member name *ical-recur-part-names* :test #'string=)
            (return-from ical-recur-parse-parts
              (values nil nil (format nil "unsupported recurrence part ~a"
                                      name))))
          (when (gethash name table)
            (return-from ical-recur-parse-parts
              (values nil nil (format nil "recurrence part ~a is duplicated"
                                      name))))
          (setf (gethash name table) value))))
    (values table t nil)))

(defun decode-ical-recur (raw)
  "Parse and intrinsically validate one RFC 5545 RECUR value."
  (multiple-value-bind (parts parts-valid-p parts-message)
      (ical-recur-parse-parts raw)
    (unless parts-valid-p
      (return-from decode-ical-recur (values nil nil parts-message)))
    (let ((frequency-text (gethash "FREQ" parts)))
      (unless frequency-text
        (return-from decode-ical-recur
          (values nil nil "FREQ is required")))
      (let ((frequency
              (cdr (assoc (string-upcase frequency-text)
                          *ical-recur-frequencies* :test #'string=))))
        (unless frequency
          (return-from decode-ical-recur
            (values nil nil "FREQ has an invalid value")))
        (when (and (gethash "UNTIL" parts) (gethash "COUNT" parts))
          (return-from decode-ical-recur
            (values nil nil "UNTIL and COUNT are mutually exclusive")))
        (let (until count interval by-second by-minute by-hour by-day
              by-month-day by-year-day by-week-number by-month
              by-set-position week-start recurrence-scale skip)
          (labels
              ((fail (message)
                 (return-from decode-ical-recur (values nil nil message)))
               (parse-number-list
                   (name signed-p maximum max-digits zero-allowed-p)
                 (let ((text (gethash name parts)))
                   (when text
                     (multiple-value-bind (value valid-p message)
                         (ical-recur-number-list
                          text signed-p maximum max-digits zero-allowed-p name)
                       (unless valid-p (fail message))
                       value)))))
            (when (gethash "UNTIL" parts)
              (multiple-value-bind (value valid-p message)
                  (ical-recur-until (gethash "UNTIL" parts))
                (unless valid-p (fail message))
                (setf until value)))
            (when (gethash "COUNT" parts)
              (multiple-value-bind (value valid-p message)
                  (ical-recur-positive-integer (gethash "COUNT" parts)
                                                "COUNT")
                (unless valid-p (fail message))
                (setf count value)))
            (when (gethash "INTERVAL" parts)
              (multiple-value-bind (value valid-p message)
                  (ical-recur-positive-integer (gethash "INTERVAL" parts)
                                                "INTERVAL")
                (unless valid-p (fail message))
                (setf interval value)))
            (when (gethash "RSCALE" parts)
              (let ((raw-scale (gethash "RSCALE" parts)))
                (unless (ical-token-p raw-scale)
                  (fail "RSCALE must be an iana-token or x-name"))
                (setf recurrence-scale (string-upcase raw-scale))))
            (when (gethash "SKIP" parts)
              (unless recurrence-scale
                (fail "SKIP must not be present unless RSCALE is present"))
              (let ((raw-skip (string-upcase (gethash "SKIP" parts))))
                (setf skip
                      (cond
                        ((string= raw-skip "OMIT") :omit)
                        ((string= raw-skip "BACKWARD") :backward)
                        ((string= raw-skip "FORWARD") :forward)
                        (t (fail "SKIP must be OMIT, BACKWARD, or FORWARD"))))))
            (setf by-second (parse-number-list "BYSECOND" nil 60 2 t)
                  by-minute (parse-number-list "BYMINUTE" nil 59 2 t)
                  by-hour (parse-number-list "BYHOUR" nil 23 2 t)
                  by-month-day
                  (parse-number-list "BYMONTHDAY" t
                                     (if recurrence-scale 99 31) 2 nil)
                  by-year-day
                  (parse-number-list "BYYEARDAY" t
                                     (if recurrence-scale 999 366) 3 nil)
                  by-week-number
                  (parse-number-list "BYWEEKNO" t
                                     (if recurrence-scale 99 53) 2 nil)
                  by-set-position
                  (parse-number-list "BYSETPOS" t
                                     (if recurrence-scale 999 366) 3 nil))
            (when (gethash "BYMONTH" parts)
              (multiple-value-bind (value valid-p message)
                  (if recurrence-scale
                      (ical-rscale-month-list (gethash "BYMONTH" parts))
                      (ical-recur-number-list
                       (gethash "BYMONTH" parts) nil 12 2 nil "BYMONTH"))
                (unless valid-p (fail message))
                (setf by-month value)))
            (when (gethash "BYDAY" parts)
              (multiple-value-bind (value valid-p message)
                  (ical-recur-weekday-list
                   (gethash "BYDAY" parts) (if recurrence-scale 99 53))
                (unless valid-p (fail message))
                (setf by-day value)))
            (when (gethash "WKST" parts)
              (multiple-value-bind (value valid-p message)
                  (ical-recur-weekday (gethash "WKST" parts) nil "WKST")
                (unless valid-p (fail message))
                (setf week-start (ical-recur-weekday-weekday value))))
            (when (and by-day
                       (some #'ical-recur-weekday-ordinal by-day)
                       (not (member frequency '(:monthly :yearly))))
              (fail "numeric BYDAY is only valid with MONTHLY or YEARLY"))
            (when (and by-day by-week-number (eq frequency :yearly)
                       (some #'ical-recur-weekday-ordinal by-day))
              (fail "numeric BYDAY is invalid with YEARLY and BYWEEKNO"))
            (when (and by-month-day (eq frequency :weekly))
              (fail "BYMONTHDAY is invalid with WEEKLY"))
            (when (and by-year-day
                       (member frequency '(:daily :weekly :monthly)))
              (fail "BYYEARDAY is invalid with DAILY, WEEKLY, or MONTHLY"))
            (when (and by-week-number (not (eq frequency :yearly)))
              (fail "BYWEEKNO is only valid with YEARLY"))
            (when (and by-set-position
                       (not (or by-second by-minute by-hour by-day by-month-day
                                by-year-day by-week-number by-month)))
              (fail "BYSETPOS requires another BYxxx rule part"))
            (values
             (%make-ical-recur-value
              raw frequency until count interval by-second by-minute by-hour
              by-day by-month-day by-year-day by-week-number by-month
              by-set-position week-start recurrence-scale skip)
             t nil)))))))

(defun ical-recur-join (values separator)
  (with-output-to-string (stream)
    (loop :for value :in values
          :for first-p := t :then nil
          :unless first-p :do (write-char separator stream)
          :do (write-string value stream))))

(defun ical-recur-number-list-text (values)
  (ical-recur-join (mapcar #'write-to-string values) #\,))

(defun ical-recur-month-list-text (values)
  (ical-recur-join
   (mapcar (lambda (value)
             (etypecase value
               (integer (write-to-string value))
               (string value)))
           values)
   #\,))

(defun ical-recur-weekday-text (weekday)
  (format nil "~@[~@d~]~a"
          (ical-recur-weekday-ordinal weekday)
          (string-upcase (symbol-name (ical-recur-weekday-weekday weekday)))))

(defun encode-ical-recur (recur)
  "Generate a deterministic RFC 5545 spelling for a parsed RECUR value."
  (unless (ical-recur-value-p recur)
    (model-error :invalid-icalendar-recur recur
                 "value must be a parsed iCalendar recurrence rule"))
  (let ((parts
          (list
           (format nil "FREQ=~a"
                   (car (rassoc (ical-recur-value-frequency recur)
                                *ical-recur-frequencies*)))
           (when (ical-recur-value-recurrence-scale recur)
             (format nil "RSCALE=~a"
                     (ical-recur-value-recurrence-scale recur)))
           (when (ical-recur-value-skip recur)
             (format nil "SKIP=~a"
                     (string-upcase
                      (symbol-name (ical-recur-value-skip recur)))))
           (when (ical-recur-value-until recur)
             (format nil "UNTIL=~a"
                     (temporal-value-original-lexeme
                      (ical-recur-value-until recur))))
           (when (ical-recur-value-count recur)
             (format nil "COUNT=~d" (ical-recur-value-count recur)))
           (when (ical-recur-value-interval recur)
             (format nil "INTERVAL=~d" (ical-recur-value-interval recur)))
           (when (ical-recur-value-by-month recur)
             (format nil "BYMONTH=~a"
                     (ical-recur-month-list-text
                      (ical-recur-value-by-month recur))))
           (when (ical-recur-value-by-week-number recur)
             (format nil "BYWEEKNO=~a"
                     (ical-recur-number-list-text
                      (ical-recur-value-by-week-number recur))))
           (when (ical-recur-value-by-year-day recur)
             (format nil "BYYEARDAY=~a"
                     (ical-recur-number-list-text
                      (ical-recur-value-by-year-day recur))))
           (when (ical-recur-value-by-month-day recur)
             (format nil "BYMONTHDAY=~a"
                     (ical-recur-number-list-text
                      (ical-recur-value-by-month-day recur))))
           (when (ical-recur-value-by-day recur)
             (format nil "BYDAY=~a"
                     (ical-recur-join
                      (mapcar #'ical-recur-weekday-text
                              (ical-recur-value-by-day recur)) #\,)))
           (when (ical-recur-value-by-hour recur)
             (format nil "BYHOUR=~a"
                     (ical-recur-number-list-text
                      (ical-recur-value-by-hour recur))))
           (when (ical-recur-value-by-minute recur)
             (format nil "BYMINUTE=~a"
                     (ical-recur-number-list-text
                      (ical-recur-value-by-minute recur))))
           (when (ical-recur-value-by-second recur)
             (format nil "BYSECOND=~a"
                     (ical-recur-number-list-text
                      (ical-recur-value-by-second recur))))
           (when (ical-recur-value-by-set-position recur)
             (format nil "BYSETPOS=~a"
                     (ical-recur-number-list-text
                      (ical-recur-value-by-set-position recur))))
           (when (ical-recur-value-week-start recur)
             (format nil "WKST=~a"
                     (string-upcase
                      (symbol-name (ical-recur-value-week-start recur))))))))
    (ical-recur-join (remove nil parts) #\;)))
