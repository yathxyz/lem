(in-package #:lem-structured-notes)

(defun decode-ical-value
    (raw kind &key timezone-id (max-value-characters 16384)
                   (max-binary-octets 8388608))
  "Decode a scalar RFC 5545 value while retaining RAW on every outcome."
  (unless (stringp raw)
    (model-error :invalid-icalendar-value-source raw
                 "iCalendar value source must be a string"))
  (unless (member kind *ical-scalar-value-kinds*)
    (return-from decode-ical-value
      (%make-ical-value
       (if (keywordp kind) kind :unknown) raw raw nil
       (list (make-diagnostic
              :severity :error :code :unsupported-icalendar-value-type
              :message (format nil "Unsupported iCalendar value type ~s" kind)
              :loss-risk :none)))))
  (ical-require-limit max-value-characters
                      "maximum typed iCalendar value size")
  (ical-require-limit max-binary-octets
                      "maximum decoded iCalendar binary size")
  (when (> (length raw) max-value-characters)
    (model-error :icalendar-value-size-limit (length raw)
                 "iCalendar value exceeds the configured character limit"))
  (unless (or (null timezone-id) (non-empty-string-p timezone-id))
    (model-error :invalid-icalendar-timezone-id timezone-id
                 "TZID must be a non-empty string or NIL"))
  (when (and timezone-id (not (member kind '(:time :date-time :period))))
    (return-from decode-ical-value
      (ical-value-failure kind raw "TZID is not valid for this value type")))
  (multiple-value-bind (decoded valid-p message)
      (case kind
        (:binary (decode-ical-binary raw max-binary-octets))
        (:boolean (decode-ical-boolean raw))
        (:integer (decode-ical-integer raw))
        (:float (decode-ical-float raw))
        (:date (decode-ical-date raw))
        (:time (decode-ical-time raw timezone-id))
        (:date-time (decode-ical-date-time raw timezone-id))
        (:duration (decode-ical-duration raw))
        (:period (decode-ical-period raw timezone-id))
        (:recur (decode-ical-recur raw))
        ((:text :uid) (decode-ical-text raw))
        (:request-status (decode-ical-request-status raw))
        ((:uri :cal-address :xml-reference) (decode-ical-uri raw))
        (:utc-offset (decode-ical-utc-offset raw)))
    (if valid-p
        (ical-value-success kind raw decoded)
        (ical-value-failure kind raw message))))

(defun ical-finite-decimal-text (value)
  (unless (rationalp value)
    (model-error :inexact-icalendar-float value
                 "iCalendar FLOAT output requires an exact rational value"))
  (let* ((negative-p (minusp value))
         (numerator (abs (numerator value)))
         (denominator (denominator value))
         (twos 0)
         (fives 0))
    (loop :while (zerop (mod denominator 2))
          :do (incf twos) (setf denominator (/ denominator 2)))
    (loop :while (zerop (mod denominator 5))
          :do (incf fives) (setf denominator (/ denominator 5)))
    (unless (= denominator 1)
      (model-error :non-terminating-icalendar-float value
                   "iCalendar FLOAT cannot represent this rational exactly"))
    (let* ((scale (max twos fives))
           (scaled
             (* numerator
                (expt 2 (- scale twos))
                (expt 5 (- scale fives))))
           (digits (write-to-string scaled))
           (unsigned
             (cond
               ((zerop scale) digits)
               ((> (length digits) scale)
                (format nil "~a.~a"
                        (subseq digits 0 (- (length digits) scale))
                        (subseq digits (- (length digits) scale))))
               (t
                (format nil "0.~a~a"
                        (make-string (- scale (length digits))
                                     :initial-element #\0)
                        digits)))))
      (if (and negative-p (not (zerop numerator)))
          (concatenate 'string "-" unsigned)
          unsigned))))

(defun encode-ical-temporal (temporal value-type)
  (unless (temporal-value-p temporal)
    (model-error :invalid-icalendar-temporal-output temporal
                 "DATE and DATE-TIME output requires a temporal value"))
  (ecase value-type
    (:date
     (unless (and (eq :date (temporal-value-kind temporal))
                  (eq :date (temporal-value-precision temporal)))
       (model-error :invalid-icalendar-date-output temporal
                    "DATE output requires a date-precision temporal value")))
    (:date-time
     (unless (and (member (temporal-value-kind temporal)
                          '(:floating :utc :zoned))
                  (eq :second (temporal-value-precision temporal)))
       (model-error :invalid-icalendar-date-time-output temporal
                    "DATE-TIME output requires second precision"))))
  (let* ((local (temporal-value-local-value temporal))
         (raw
           (remove-if (lambda (character) (member character '(#\- #\:)))
                      local))
         (timezone-id (and (eq :zoned (temporal-value-kind temporal))
                           (temporal-value-timezone-id temporal)))
         (decoded
           (decode-ical-value raw value-type :timezone-id timezone-id)))
    (unless (and (ical-value-valid-p decoded)
                 (let ((round-trip (ical-value-decoded decoded)))
                   (and (eq (temporal-value-kind temporal)
                            (temporal-value-kind round-trip))
                        (string= local (temporal-value-local-value round-trip))
                        (equal (temporal-value-timezone-id temporal)
                               (temporal-value-timezone-id round-trip)))))
      (model-error :invalid-icalendar-temporal-output temporal
                   "temporal value has no exact RFC 5545 representation"))
    (values raw timezone-id)))

(defun encode-ical-time (time)
  (unless (ical-time-value-p time)
    (model-error :invalid-icalendar-time-output time
                 "TIME output requires an iCalendar time value"))
  (values
   (format nil "~2,'0d~2,'0d~2,'0d~:[~;Z~]"
           (ical-time-value-hour time)
           (ical-time-value-minute time)
           (ical-time-value-second time)
           (ical-time-value-utc-p time))
   (ical-time-value-timezone-id time)))

(defun encode-ical-duration (duration)
  "Generate a deterministic RFC 5545 DURATION from a typed duration value."
  (unless (ical-duration-value-p duration)
    (model-error :invalid-icalendar-duration-output duration
                 "DURATION output requires an iCalendar duration value"))
  (with-output-to-string (stream)
    (when (= -1 (ical-duration-value-sign duration))
      (write-char #\- stream))
    (write-char #\P stream)
    (if (plusp (ical-duration-value-weeks duration))
        (format stream "~dW" (ical-duration-value-weeks duration))
        (let ((days (ical-duration-value-days duration))
              (hours (ical-duration-value-hours duration))
              (minutes (ical-duration-value-minutes duration))
              (seconds (ical-duration-value-seconds duration)))
          (when (plusp days) (format stream "~dD" days))
          (if (plusp (+ hours minutes seconds))
              (progn
                (write-char #\T stream)
                (when (plusp hours) (format stream "~dH" hours))
                (when (or (plusp minutes)
                          (and (plusp hours) (plusp seconds)))
                  (format stream "~dM" minutes))
                (when (plusp seconds) (format stream "~dS" seconds)))
              (when (zerop days) (write-string "0D" stream)))))))

(defun ical-duration-output-value (value)
  (cond
    ((ical-duration-value-p value) value)
    ((stringp value)
     (let ((decoded (decode-ical-value value :duration)))
       (unless (ical-value-valid-p decoded)
         (model-error :invalid-icalendar-duration-output value
                      "duration string is not valid RFC 5545 DURATION"))
       (ical-value-decoded decoded)))
    (t
     (model-error :invalid-icalendar-duration-output value
                  "duration output requires a typed value or duration string"))))

(defun ical-period-output-fields (period)
  (cond
    ((ical-period-value-p period)
     (values (ical-period-value-start period)
             (ical-period-value-end period)
             (ical-period-value-duration period)))
    ((recurrence-period-p period)
     (values (recurrence-period-start period)
             (recurrence-period-end period)
             (and (recurrence-period-duration period)
                  (ical-duration-output-value
                   (recurrence-period-duration period)))))
    (t
     (model-error :invalid-icalendar-period-output period
                  "PERIOD output requires an iCalendar or neutral recurrence period"))))

(defun encode-ical-period (period)
  (multiple-value-bind (start end duration)
      (ical-period-output-fields period)
    (multiple-value-bind (start-raw timezone-id)
        (encode-ical-temporal start :date-time)
      (let ((finish
              (if end
                  (multiple-value-bind (end-raw end-timezone-id)
                      (encode-ical-temporal end :date-time)
                    (unless (equal timezone-id end-timezone-id)
                      (model-error :incompatible-icalendar-period-zones period
                                   "PERIOD endpoints require the same timezone"))
                    end-raw)
                  (let ((duration (ical-duration-output-value duration)))
                    (unless (ical-duration-positive-p duration)
                      (model-error :invalid-icalendar-period-duration duration
                                   "PERIOD duration must be positive and non-zero"))
                    (encode-ical-duration duration)))))
        (let* ((raw (format nil "~a/~a" start-raw finish))
               (decoded
                 (decode-ical-value raw :period :timezone-id timezone-id)))
          (unless (ical-value-valid-p decoded)
            (model-error :invalid-icalendar-period-output period
                         "PERIOD has no exact RFC 5545 representation"))
          (values raw timezone-id))))))

(defun encode-ical-uri-value (value kind)
  (let ((raw
          (cond
            ((ical-uri-value-p value) (ical-uri-value-original-lexeme value))
            ((stringp value) value)
            (t
             (model-error :invalid-icalendar-uri-output value
                          "URI output requires a parsed URI or string")))))
    (unless (ical-value-valid-p (decode-ical-value raw kind))
      (model-error :invalid-icalendar-uri-output value
                   "URI output is not an absolute RFC 3986 URI"))
    raw))

(defun encode-ical-recur-value (value)
  (cond
    ((ical-recur-value-p value) (encode-ical-recur value))
    ((stringp value)
     (multiple-value-bind (recur valid-p message) (decode-ical-recur value)
       (unless valid-p
         (model-error :invalid-icalendar-recur-output value message))
       (encode-ical-recur recur)))
    (t
     (model-error :invalid-icalendar-recur-output value
                  "RECUR output requires a parsed rule or rule string"))))

(defun encode-ical-utc-offset (seconds)
  (unless (and (integerp seconds) (<= (- 86399) seconds 86399))
    (model-error :invalid-icalendar-utc-offset-output seconds
                 "UTC-OFFSET output requires integer seconds within 23:59:59"))
  (let* ((magnitude (abs seconds))
         (hour (floor magnitude 3600))
         (remainder (mod magnitude 3600))
         (minute (floor remainder 60))
         (second (mod remainder 60)))
    (format nil "~c~2,'0d~2,'0d~:[~;~2,'0d~]"
            (if (minusp seconds) #\- #\+) hour minute
            (plusp second) second)))

(defun encode-ical-value
    (value kind &key (max-binary-octets 8388608))
  "Encode one typed semantic value, returning RAW and its required TZID.

The second value is NIL unless DATE-TIME, TIME, or PERIOD needs a TZID
parameter.  Property-level VALUE, TZID, and ENCODING selection is intentionally
handled by the property writer."
  (unless (member kind *ical-scalar-value-kinds*)
    (model-error :unsupported-icalendar-value-type kind
                 "cannot encode an unsupported iCalendar value type"))
  (when (ical-value-p value)
    (unless (and (ical-value-valid-p value) (eq kind (ical-value-kind value)))
      (model-error :invalid-icalendar-value-output value
                   "parsed iCalendar value is invalid or has the wrong type"))
    (setf value (ical-value-decoded value)))
  (case kind
    (:binary (values (encode-ical-binary value
                                         :max-decoded-octets max-binary-octets)
                     nil))
    (:boolean
     (unless (member value '(nil t))
       (model-error :invalid-icalendar-boolean-output value
                    "BOOLEAN output requires NIL or T"))
     (values (if value "TRUE" "FALSE") nil))
    (:integer
     (unless (and (integerp value) (<= -2147483648 value 2147483647))
       (model-error :invalid-icalendar-integer-output value
                    "INTEGER output is outside the signed 32-bit range"))
     (values (write-to-string value) nil))
    (:float (values (ical-finite-decimal-text value) nil))
    (:date (encode-ical-temporal value :date))
    (:time (encode-ical-time value))
    (:date-time (encode-ical-temporal value :date-time))
    (:duration
     (values (encode-ical-duration (ical-duration-output-value value)) nil))
    (:period (encode-ical-period value))
    (:recur (values (encode-ical-recur-value value) nil))
    ((:text :uid) (values (encode-ical-text value) nil))
    (:request-status (values (encode-ical-request-status value) nil))
    ((:uri :cal-address :xml-reference)
     (values (encode-ical-uri-value value kind) nil))
    (:utc-offset (values (encode-ical-utc-offset value) nil))))
