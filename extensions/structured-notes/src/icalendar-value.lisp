(in-package #:lem-structured-notes)

(defstruct (ical-time-value
            (:constructor %make-ical-time-value
                (hour minute second utc-p timezone-id original-lexeme)))
  (hour 0 :type (integer 0 23) :read-only t)
  (minute 0 :type (integer 0 59) :read-only t)
  (second 0 :type (integer 0 60) :read-only t)
  (utc-p nil :type boolean :read-only t)
  (timezone-id nil :type (or null string) :read-only t)
  (original-lexeme nil :type (or null string) :read-only t))

(defun make-ical-time-value
    (&key hour minute second (utc-p nil) timezone-id original-lexeme)
  (unless (and (integerp hour) (<= 0 hour 23)
               (integerp minute) (<= 0 minute 59)
               (integerp second) (<= 0 second 60))
    (model-error :invalid-icalendar-time-fields
                 (list hour minute second)
                 "iCalendar time fields are outside their permitted ranges"))
  (unless (member utc-p '(nil t))
    (model-error :invalid-icalendar-time-utc utc-p
                 "iCalendar UTC marker must be boolean"))
  (unless (or (null timezone-id) (non-empty-string-p timezone-id))
    (model-error :invalid-icalendar-timezone-id timezone-id
                 "iCalendar time TZID must be a non-empty string or NIL"))
  (when (and utc-p timezone-id)
    (model-error :invalid-icalendar-time-zone-coupling timezone-id
                 "a UTC iCalendar time cannot carry TZID"))
  (unless (or (null original-lexeme) (stringp original-lexeme))
    (model-error :invalid-icalendar-time-lexeme original-lexeme
                 "original iCalendar time lexeme must be a string or NIL"))
  (%make-ical-time-value
   hour minute second utc-p timezone-id original-lexeme))

(defstruct (ical-value
            (:constructor %make-ical-value
                (kind raw decoded valid-p diagnostics)))
  (kind :unknown :type keyword :read-only t)
  (raw "" :type string :read-only t)
  decoded
  (valid-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t))

(defstruct (ical-request-status-value
            (:constructor %make-ical-request-status-value
                (code components class description exception-data
                 original-lexeme)))
  (code "" :type string :read-only t)
  (components nil :type list :read-only t)
  (class :unknown
         :type (member :preliminary-success :success :client-error
                       :scheduling-error :unknown)
         :read-only t)
  (description "" :type string :read-only t)
  (exception-data nil :type (or null string) :read-only t)
  (original-lexeme nil :type (or null string) :read-only t))

(defun ical-request-status-code-components (code)
  (when (stringp code)
    (let ((parts nil)
          (start 0))
      (loop :for dot := (position #\. code :start start)
            :do (push (subseq code start dot) parts)
            :if dot :do (setf start (1+ dot)) :else :do (return))
      (setf parts (nreverse parts))
      (and (<= 2 (length parts) 3)
           (every (lambda (part)
                    (and (plusp (length part))
                         (every #'digit-char-p part)))
                  parts)
           parts))))

(defun ical-request-status-class-for-components (components)
  (let* ((major (first components))
         (significant
           (string-left-trim '(#\0) major))
         (normalized (if (zerop (length significant)) "0" significant)))
    (cond ((string= normalized "1") :preliminary-success)
          ((string= normalized "2") :success)
          ((string= normalized "3") :client-error)
          ((string= normalized "4") :scheduling-error)
          (t :unknown))))

(defun make-ical-request-status-value
    (&key code description exception-data original-lexeme)
  "Construct one inert typed RFC 5545 REQUEST-STATUS value."
  (let ((components (ical-request-status-code-components code)))
    (unless components
      (model-error :invalid-icalendar-request-status-code code
                   "REQUEST-STATUS code requires two or three numeric components"))
    (unless (stringp description)
      (model-error :invalid-icalendar-request-status-description description
                   "REQUEST-STATUS description must be TEXT"))
    (unless (or (null exception-data) (stringp exception-data))
      (model-error :invalid-icalendar-request-status-exception-data
                   exception-data
                   "REQUEST-STATUS exception data must be TEXT or NIL"))
    (unless (or (null original-lexeme) (stringp original-lexeme))
      (model-error :invalid-icalendar-request-status-lexeme original-lexeme
                   "REQUEST-STATUS original lexeme must be a string or NIL"))
    ;; Exercise the shared TEXT encoder now so malformed controls fail at the
    ;; public semantic constructor rather than later during output.
    (encode-ical-text description)
    (when exception-data (encode-ical-text exception-data))
    (%make-ical-request-status-value
     (copy-seq code) (mapcar #'copy-seq components)
     (ical-request-status-class-for-components components)
     (copy-seq description) (and exception-data (copy-seq exception-data))
     (and original-lexeme (copy-seq original-lexeme)))))

(defstruct (ical-duration-value
            (:constructor %make-ical-duration-value
                (sign weeks days hours minutes seconds original-lexeme)))
  (sign 1 :type (integer -1 1) :read-only t)
  (weeks 0 :type (integer 0) :read-only t)
  (days 0 :type (integer 0) :read-only t)
  (hours 0 :type (integer 0) :read-only t)
  (minutes 0 :type (integer 0) :read-only t)
  (seconds 0 :type (integer 0) :read-only t)
  (original-lexeme nil :type (or null string) :read-only t))

(defun make-ical-duration-value
    (&key (sign 1) (weeks 0) (days 0) (hours 0) (minutes 0) (seconds 0)
          original-lexeme)
  (unless (member sign '(-1 1))
    (model-error :invalid-icalendar-duration-sign sign
                 "iCalendar duration sign must be -1 or 1"))
  (dolist (field (list weeks days hours minutes seconds))
    (unless (and (integerp field) (not (minusp field)))
      (model-error :invalid-icalendar-duration-field field
                   "iCalendar duration fields must be non-negative integers")))
  (when (and (plusp weeks) (plusp (+ days hours minutes seconds)))
    (model-error :invalid-icalendar-duration-week-coupling weeks
                 "week duration cannot contain day or time fields"))
  (unless (or (null original-lexeme) (stringp original-lexeme))
    (model-error :invalid-icalendar-duration-lexeme original-lexeme
                 "original iCalendar duration lexeme must be a string or NIL"))
  (%make-ical-duration-value
   sign weeks days hours minutes seconds original-lexeme))

(defstruct (ical-period-value
            (:constructor %make-ical-period-value
                (start end duration original-lexeme)))
  (start nil :type temporal-value :read-only t)
  (end nil :type (or null temporal-value) :read-only t)
  (duration nil :type (or null ical-duration-value) :read-only t)
  (original-lexeme nil :type (or null string) :read-only t))

(defparameter *ical-scalar-value-kinds*
  '(:binary :boolean :integer :float :date :time :date-time :duration :period
    :recur :text :uid :xml-reference :request-status :uri :cal-address
    :utc-offset))

(defun ical-value-success (kind raw decoded)
  (%make-ical-value kind raw decoded t nil))

(defun ical-value-failure (kind raw message)
  (%make-ical-value
   kind raw nil nil
   (list (make-diagnostic
          :severity :error :code :invalid-icalendar-value
          :message (format nil "Invalid ~a value: ~a" kind message)
          :loss-risk :none))))

(defun ical-signed-number-parts (raw &key dot-allowed-p)
  (let* ((length (length raw))
         (signed-p (and (plusp length)
                        (member (char raw 0) '(#\+ #\-))))
         (negative-p (and signed-p (char= (char raw 0) #\-)))
         (unsigned (if signed-p (subseq raw 1) raw))
         (dot (and dot-allowed-p (position #\. unsigned))))
    (cond
      ((zerop (length unsigned)) (values nil nil nil nil))
      ((and dot
            (or (zerop dot)
                (= dot (1- (length unsigned)))
                (position #\. unsigned :start (1+ dot))))
       (values nil nil nil nil))
      ((and (or (null dot)
                (and (ical-digit-string-p (subseq unsigned 0 dot))
                     (ical-digit-string-p (subseq unsigned (1+ dot)))))
            (or dot (ical-digit-string-p unsigned)))
       (values unsigned negative-p dot t))
      (t (values nil nil nil nil)))))

(defparameter *ical-base64-alphabet*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun ical-base64-value (character)
  (let ((code (char-code character)))
    (cond
      ((<= (char-code #\A) code (char-code #\Z))
       (- code (char-code #\A)))
      ((<= (char-code #\a) code (char-code #\z))
       (+ 26 (- code (char-code #\a))))
      ((<= (char-code #\0) code (char-code #\9))
       (+ 52 (- code (char-code #\0))))
      ((char= character #\+) 62)
      ((char= character #\/) 63))))

(defun decode-ical-binary (raw max-decoded-octets)
  (let ((length (length raw)))
    (unless (zerop (mod length 4))
      (return-from decode-ical-binary
        (values nil nil "Base64 length must be a multiple of four")))
    (let* ((padding
             (cond
               ((and (>= length 2)
                     (char= (char raw (1- length)) #\=)
                     (char= (char raw (- length 2)) #\=))
                2)
               ((and (plusp length) (char= (char raw (1- length)) #\=)) 1)
               (t 0)))
           (decoded-length (- (* (/ length 4) 3) padding)))
      (when (> decoded-length max-decoded-octets)
        (model-error :icalendar-binary-size-limit decoded-length
                     "decoded iCalendar binary exceeds the configured octet limit"))
      (loop :for index :from 0 :below (- length padding)
            :unless (ical-base64-value (char raw index))
              :do (return-from decode-ical-binary
                    (values nil nil "Base64 contains a non-alphabet character")))
      (loop :for index :from (- length padding) :below length
            :unless (char= (char raw index) #\=)
              :do (return-from decode-ical-binary
                    (values nil nil "Base64 padding is not final")))
      (when (and (plusp length)
                 (position #\= raw :end (- length padding)))
        (return-from decode-ical-binary
          (values nil nil "Base64 padding appears before the final quantum")))
      (when (and (= padding 2)
                 (not (zerop
                       (logand
                        (ical-base64-value (char raw (- length 3))) #b1111))))
        (return-from decode-ical-binary
          (values nil nil "Base64 has non-zero pad bits")))
      (when (and (= padding 1)
                 (not (zerop
                       (logand
                        (ical-base64-value (char raw (- length 2))) #b11))))
        (return-from decode-ical-binary
          (values nil nil "Base64 has non-zero pad bits")))
      (let ((octets (make-array decoded-length
                                :element-type '(unsigned-byte 8)))
            (output 0))
        (loop :for index :from 0 :below length :by 4
              :for a := (ical-base64-value (char raw index))
              :for b := (ical-base64-value (char raw (1+ index)))
              :for c := (if (char= (char raw (+ index 2)) #\=)
                            0
                            (ical-base64-value (char raw (+ index 2))))
              :for d := (if (char= (char raw (+ index 3)) #\=)
                            0
                            (ical-base64-value (char raw (+ index 3))))
              :do
                 (when (< output decoded-length)
                   (setf (aref octets output)
                         (logior (ash a 2) (ash b -4)))
                   (incf output))
                 (when (< output decoded-length)
                   (setf (aref octets output)
                         (logior (ash (logand b #b1111) 4) (ash c -2)))
                   (incf output))
                 (when (< output decoded-length)
                   (setf (aref octets output)
                         (logior (ash (logand c #b11) 6) d))
                   (incf output)))
        (values octets t nil)))))

(defun encode-ical-binary (octets &key (max-decoded-octets 8388608))
  "Encode an inert octet vector as canonical padded Base64."
  (ical-require-limit max-decoded-octets
                      "maximum encoded iCalendar binary size")
  (unless (and (vectorp octets)
               (every (lambda (value)
                        (and (integerp value) (<= 0 value 255)))
                      octets))
    (model-error :invalid-icalendar-binary octets
                 "iCalendar binary must be a vector of octets"))
  (when (> (length octets) max-decoded-octets)
    (model-error :icalendar-binary-size-limit (length octets)
                 "iCalendar binary exceeds the configured octet limit"))
  (with-output-to-string (stream)
    (loop :for index :from 0 :below (length octets) :by 3
          :for remaining := (- (length octets) index)
          :for a := (aref octets index)
          :for b := (if (> remaining 1) (aref octets (1+ index)) 0)
          :for c := (if (> remaining 2) (aref octets (+ index 2)) 0)
          :do
             (write-char (char *ical-base64-alphabet* (ash a -2)) stream)
             (write-char
              (char *ical-base64-alphabet*
                    (logior (ash (logand a #b11) 4) (ash b -4)))
              stream)
             (if (> remaining 1)
                 (write-char
                  (char *ical-base64-alphabet*
                        (logior (ash (logand b #b1111) 2) (ash c -6)))
                  stream)
                 (write-char #\= stream))
             (if (> remaining 2)
                 (write-char
                  (char *ical-base64-alphabet* (logand c #b111111)) stream)
                 (write-char #\= stream)))))

(defun decode-ical-boolean (raw)
  (cond
    ((string-equal raw "TRUE") (values t t nil))
    ((string-equal raw "FALSE") (values nil t nil))
    (t (values nil nil "expected TRUE or FALSE"))))

(defun decode-ical-integer (raw)
  (multiple-value-bind (unsigned negative-p dot valid-p)
      (ical-signed-number-parts raw)
    (declare (ignore dot))
    (unless valid-p
      (return-from decode-ical-integer
        (values nil nil "expected an optional sign and one or more digits")))
    (when (> (length unsigned) 10)
      (return-from decode-ical-integer
        (values nil nil "value is outside the signed 32-bit range")))
    (let* ((magnitude (ical-unsigned-integer unsigned))
           (value (if negative-p (- magnitude) magnitude)))
      (if (<= -2147483648 value 2147483647)
          (values value t nil)
          (values nil nil "value is outside the signed 32-bit range")))))

(defun decode-ical-float (raw)
  (multiple-value-bind (unsigned negative-p dot valid-p)
      (ical-signed-number-parts raw :dot-allowed-p t)
    (unless valid-p
      (return-from decode-ical-float
        (values nil nil
                "expected an optional sign, digits, and optional fractional digits")))
    (let* ((digits (if dot
                       (concatenate 'string (subseq unsigned 0 dot)
                                    (subseq unsigned (1+ dot)))
                       unsigned))
           (scale (if dot
                      (expt 10 (- (length unsigned) dot 1))
                      1))
           (value (/ (ical-unsigned-integer digits) scale)))
      (values (if negative-p (- value) value) t nil))))

(defun ical-leap-year-p (year)
  (and (zerop (mod year 4))
       (or (not (zerop (mod year 100)))
           (zerop (mod year 400)))))

(defun ical-days-in-month (year month)
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (ical-leap-year-p year) 29 28))))

(defparameter +ical-positive-leap-second-utc-dates+
  '("1972-06-30" "1972-12-31" "1973-12-31" "1974-12-31"
    "1975-12-31" "1976-12-31" "1977-12-31" "1978-12-31"
    "1979-12-31" "1981-06-30" "1982-06-30" "1983-06-30"
    "1985-06-30" "1987-12-31" "1989-12-31" "1990-12-31"
    "1992-06-30" "1993-06-30" "1994-06-30" "1995-12-31"
    "1997-06-30" "1998-12-31" "2005-12-31" "2008-12-31"
    "2012-06-30" "2015-06-30" "2016-12-31"))

(defun ical-positive-leap-second-utc-dates ()
  "Return a copy of the positive UTC leap-second insertion-date snapshot.

The snapshot is sourced from the IANA leap-seconds.list published through
IERS Bulletin C, observed 2026-07-27 and expiring 2027-06-28."
  (mapcar #'copy-seq +ical-positive-leap-second-utc-dates+))

(defun ical-positive-leap-second-utc-date-p (year month day)
  "Return true when YEAR MONTH DAY ends with a known positive UTC leap second."
  (and (integerp year) (integerp month) (integerp day)
       (member (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)
               +ical-positive-leap-second-utc-dates+ :test #'string=)))

(defun decode-ical-date-components (raw)
  (unless (and (= (length raw) 8) (ical-digit-string-p raw))
    (return-from decode-ical-date-components
      (values nil nil "expected YYYYMMDD")))
  (let ((year (ical-unsigned-integer (subseq raw 0 4)))
        (month (ical-unsigned-integer (subseq raw 4 6)))
        (day (ical-unsigned-integer (subseq raw 6 8))))
    (unless (and (<= 1 month 12)
                 (<= 1 day (ical-days-in-month year month)))
      (return-from decode-ical-date-components
        (values nil nil "calendar date does not exist")))
    (values (list year month day) t nil)))

(defun decoded-ical-date-local-value (components)
  (destructuring-bind (year month day) components
    (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))

(defun decode-ical-date (raw)
  (multiple-value-bind (components valid-p message)
      (decode-ical-date-components raw)
    (if valid-p
        (values
         (make-temporal-value
          :kind :date :local-value (decoded-ical-date-local-value components)
          :precision :date :original-lexeme raw)
         t nil)
        (values nil nil message))))

(defun ical-date-context-components (date)
  (unless (and (temporal-value-p date)
               (eq :date (temporal-value-kind date)))
    (model-error :invalid-icalendar-time-date-context date
                 "standalone TIME validation requires one typed DATE"))
  (let ((local (temporal-value-local-value date)))
    (unless (and (= 10 (length local))
                 (char= #\- (char local 4))
                 (char= #\- (char local 7)))
      (model-error :invalid-icalendar-time-date-context date
                   "DATE context does not use canonical Gregorian form"))
    (multiple-value-bind (components valid-p message)
        (decode-ical-date-components
         (concatenate 'string (subseq local 0 4)
                      (subseq local 5 7) (subseq local 8 10)))
      (unless valid-p
        (model-error :invalid-icalendar-time-date-context date
                     "DATE context is invalid: ~a" message))
      components)))

(defun validate-ical-time-value-date-context (time date)
  "Validate a standalone TIME against one explicit Gregorian DATE context.

Ordinary seconds need no leap-table lookup.  Second 60 is accepted only for a
UTC 23:59:60 value on a pinned positive-leap insertion date.  Floating and
TZID-qualified leap seconds remain unprovable without an exact timezone
resolver and therefore fail closed."
  (unless (ical-time-value-p time)
    (model-error :invalid-icalendar-time-date-context time
                 "standalone TIME validation requires a typed TIME value"))
  (let ((components (ical-date-context-components date)))
    (when (= 60 (ical-time-value-second time))
      (unless (ical-time-value-utc-p time)
        (model-error :unresolved-icalendar-local-leap-second time
                     "floating or TZID leap seconds require timezone resolution"))
      (unless (and (= 23 (ical-time-value-hour time))
                   (= 59 (ical-time-value-minute time))
                   (apply #'ical-positive-leap-second-utc-date-p components))
        (model-error :invalid-icalendar-positive-leap-second
                     (list time date)
                     "TIME second 60 is not a pinned positive UTC leap second"))))
  time)

(defun decode-ical-time-components (raw)
  (let* ((length (length raw))
         (utc-p (and (= length 7) (char= (char raw 6) #\Z)))
         (digits (if utc-p (subseq raw 0 6) raw)))
    (unless (and (member length '(6 7))
                 (or (= length 6) utc-p)
                 (ical-digit-string-p digits))
      (return-from decode-ical-time-components
        (values nil nil "expected HHMMSS or HHMMSSZ")))
    (let ((hour (ical-unsigned-integer (subseq digits 0 2)))
          (minute (ical-unsigned-integer (subseq digits 2 4)))
          (second (ical-unsigned-integer (subseq digits 4 6))))
      (unless (and (<= 0 hour 23) (<= 0 minute 59) (<= 0 second 60))
        (return-from decode-ical-time-components
          (values nil nil "time-of-day field is out of range")))
      (values (list hour minute second utc-p) t nil))))

(defun decode-ical-time (raw timezone-id)
  (multiple-value-bind (components valid-p message)
      (decode-ical-time-components raw)
    (unless valid-p
      (return-from decode-ical-time (values nil nil message)))
    (destructuring-bind (hour minute second utc-p) components
      (when (and utc-p timezone-id)
        (return-from decode-ical-time
          (values nil nil "TZID cannot be applied to a UTC time")))
      (values
       (%make-ical-time-value hour minute second utc-p timezone-id raw)
       t nil))))

(defun decode-ical-date-time (raw timezone-id)
  (unless (and (member (length raw) '(15 16))
               (char= (char raw 8) #\T))
    (return-from decode-ical-date-time
      (values nil nil "expected YYYYMMDDTHHMMSS with optional Z")))
  (multiple-value-bind (date-components date-valid-p date-message)
      (decode-ical-date-components (subseq raw 0 8))
    (unless date-valid-p
      (return-from decode-ical-date-time (values nil nil date-message)))
    (multiple-value-bind (time-components time-valid-p time-message)
        (decode-ical-time-components (subseq raw 9))
      (unless time-valid-p
        (return-from decode-ical-date-time (values nil nil time-message)))
      (let ((utc-p (fourth time-components)))
        (when (and utc-p timezone-id)
          (return-from decode-ical-date-time
            (values nil nil "TZID cannot be applied to a UTC date-time")))
        (when (and utc-p (= 60 (third time-components))
                   (not (and (= 23 (first time-components))
                             (= 59 (second time-components))
                             (apply #'ical-positive-leap-second-utc-date-p
                                    date-components))))
          (return-from decode-ical-date-time
            (values nil nil
                    "UTC second 60 is not a positive leap second in the pinned table")))
        (let ((kind (cond (utc-p :utc) (timezone-id :zoned) (t :floating))))
          (values
           (make-temporal-value
            :kind kind
            :local-value
            (format nil "~aT~2,'0d:~2,'0d:~2,'0d~:[~;Z~]"
                    (decoded-ical-date-local-value date-components)
                    (first time-components) (second time-components)
                    (third time-components) utc-p)
            :timezone-id timezone-id
            :gap-policy (and (eq kind :zoned) :rfc5545)
            :precision :second
            :original-lexeme raw)
           t nil))))))

(defun ical-read-duration-number (text index)
  (let ((end index))
    (loop :while (and (< end (length text))
                      (ical-ascii-digit-p (char text end)))
          :do (incf end))
    (if (= end index)
        (values nil index nil)
        (values (ical-unsigned-integer (subseq text index end)) end t))))

(defun decode-ical-duration-time (text index)
  (multiple-value-bind (first-value position valid-p)
      (ical-read-duration-number text index)
    (unless (and valid-p (< position (length text)))
      (return-from decode-ical-duration-time
        (values nil nil nil nil "duration time has no component")))
    (let ((designator (char text position))
          (hours 0)
          (minutes 0)
          (seconds 0))
      (incf position)
      (case designator
        (#\H (setf hours first-value))
        (#\M (setf minutes first-value))
        (#\S (setf seconds first-value))
        (otherwise
         (return-from decode-ical-duration-time
           (values nil nil nil nil "duration time has an invalid designator"))))
      (when (= position (length text))
        (return-from decode-ical-duration-time
          (values (list hours minutes seconds) position t nil)))
      (when (char= designator #\S)
        (return-from decode-ical-duration-time
          (values nil nil nil nil "seconds must be the final duration field")))
      (multiple-value-bind (next-value next-position next-valid-p)
          (ical-read-duration-number text position)
        (unless (and next-valid-p (< next-position (length text)))
          (return-from decode-ical-duration-time
            (values nil nil nil nil "duration time has an incomplete field")))
        (let ((next-designator (char text next-position)))
          (incf next-position)
          (cond
            ((and (char= designator #\H) (char= next-designator #\M))
             (setf minutes next-value))
            ((and (char= designator #\M) (char= next-designator #\S))
             (setf seconds next-value))
            (t
             (return-from decode-ical-duration-time
               (values nil nil nil nil
                       "duration time fields are missing or out of order"))))
          (when (= next-position (length text))
            (return-from decode-ical-duration-time
              (values (list hours minutes seconds) next-position t nil)))
          (unless (and (char= designator #\H)
                       (char= next-designator #\M))
            (return-from decode-ical-duration-time
              (values nil nil nil nil "seconds must be the final duration field")))
          (multiple-value-bind (last-value last-position last-valid-p)
              (ical-read-duration-number text next-position)
            (unless (and last-valid-p (< last-position (length text))
                         (char= (char text last-position) #\S)
                         (= (1+ last-position) (length text)))
              (return-from decode-ical-duration-time
                (values nil nil nil nil "duration seconds field is invalid")))
            (setf seconds last-value)
            (values (list hours minutes seconds)
                    (1+ last-position) t nil)))))))

(defun decode-ical-duration (raw)
  (let* ((length (length raw))
         (position 0)
         (sign 1))
    (when (and (< position length)
               (member (char raw position) '(#\+ #\-)))
      (when (char= (char raw position) #\-)
        (setf sign -1))
      (incf position))
    (unless (and (< position length) (char= (char raw position) #\P))
      (return-from decode-ical-duration
        (values nil nil "duration must start with P after its optional sign")))
    (incf position)
    (when (= position length)
      (return-from decode-ical-duration
        (values nil nil "duration has no fields")))
    (when (char= (char raw position) #\T)
      (multiple-value-bind (time-components end valid-p message)
          (decode-ical-duration-time raw (1+ position))
        (declare (ignore end))
        (if valid-p
            (return-from decode-ical-duration
              (values
               (%make-ical-duration-value
                sign 0 0 (first time-components) (second time-components)
                (third time-components) raw)
               t nil))
            (return-from decode-ical-duration (values nil nil message)))))
    (multiple-value-bind (first-value next-position valid-p)
        (ical-read-duration-number raw position)
      (unless (and valid-p (< next-position length))
        (return-from decode-ical-duration
          (values nil nil "duration date or week field is incomplete")))
      (let ((designator (char raw next-position)))
        (incf next-position)
        (cond
          ((char= designator #\W)
           (if (= next-position length)
               (values
                (%make-ical-duration-value sign first-value 0 0 0 0 raw)
                t nil)
               (values nil nil "week duration cannot contain other fields")))
          ((char= designator #\D)
           (cond
             ((= next-position length)
              (values
               (%make-ical-duration-value sign 0 first-value 0 0 0 raw)
               t nil))
             ((char/= (char raw next-position) #\T)
              (values nil nil "day duration can only be followed by T"))
             (t
              (multiple-value-bind (time-components end time-valid-p message)
                  (decode-ical-duration-time raw (1+ next-position))
                (declare (ignore end))
                (if time-valid-p
                    (values
                     (%make-ical-duration-value
                      sign 0 first-value (first time-components)
                      (second time-components) (third time-components) raw)
                     t nil)
                    (values nil nil message))))))
          (t (values nil nil "duration date field must end in D or W")))))))

(defun ical-duration-positive-p (duration)
  (and (= 1 (ical-duration-value-sign duration))
       (plusp (+ (ical-duration-value-weeks duration)
                 (ical-duration-value-days duration)
                 (ical-duration-value-hours duration)
                 (ical-duration-value-minutes duration)
                 (ical-duration-value-seconds duration)))))

(defun ical-period-end-after-start-p (start end)
  (and (eq (temporal-value-kind start) (temporal-value-kind end))
       (equal (temporal-value-timezone-id start)
              (temporal-value-timezone-id end))
       (string< (temporal-value-local-value start)
                (temporal-value-local-value end))))

(defun decode-ical-period (raw timezone-id)
  (let ((slash (position #\/ raw)))
    (unless (and slash (plusp slash) (< slash (1- (length raw)))
                 (null (position #\/ raw :start (1+ slash))))
      (return-from decode-ical-period
        (values nil nil "period must contain exactly one non-edge slash")))
    (let ((start-raw (subseq raw 0 slash))
          (finish-raw (subseq raw (1+ slash))))
      (multiple-value-bind (start start-valid-p start-message)
          (decode-ical-date-time start-raw timezone-id)
        (unless start-valid-p
          (return-from decode-ical-period
            (values nil nil (format nil "period start: ~a" start-message))))
        (if (or (char= (char finish-raw 0) #\P)
                (and (> (length finish-raw) 1)
                     (member (char finish-raw 0) '(#\+ #\-))
                     (char= (char finish-raw 1) #\P)))
            (multiple-value-bind (duration duration-valid-p duration-message)
                (decode-ical-duration finish-raw)
              (cond
                ((not duration-valid-p)
                 (values nil nil
                         (format nil "period duration: ~a" duration-message)))
                ((not (ical-duration-positive-p duration))
                 (values nil nil "period duration must be positive and non-zero"))
                (t
                 (values
                  (%make-ical-period-value start nil duration raw) t nil))))
            (multiple-value-bind (end end-valid-p end-message)
                (decode-ical-date-time finish-raw timezone-id)
              (cond
                ((not end-valid-p)
                 (values nil nil (format nil "period end: ~a" end-message)))
                ((not (ical-period-end-after-start-p start end))
                 (values nil nil
                         "period endpoints are incomparable or not increasing"))
                (t
                 (values
                  (%make-ical-period-value start end nil raw) t nil)))))))))

(defun decode-ical-text (raw)
  (let ((stream (make-string-output-stream)))
    (loop :with length := (length raw)
          :for index :from 0 :below length
          :for character := (char raw index)
          :do
             (cond
               ((ical-control-character-p character)
                (return-from decode-ical-text
                  (values nil nil "text contains a forbidden control character")))
               ((char/= character #\\) (write-char character stream))
               ((= index (1- length))
                (return-from decode-ical-text
                  (values nil nil "text ends with an incomplete backslash escape")))
               (t
                (let ((escaped (char raw (1+ index))))
                  (cond
                    ((member escaped '(#\\ #\; #\,))
                     (write-char escaped stream))
                    ((member escaped '(#\n #\N))
                     (write-char #\Newline stream))
                    (t
                     (return-from decode-ical-text
                       (values nil nil "text contains an undefined backslash escape"))))
                  (incf index)))))
    (values (get-output-stream-string stream) t nil)))

(defun encode-ical-text (text)
  "Encode one RFC 5545 TEXT value without adding list delimiters or folding."
  (unless (stringp text)
    (model-error :invalid-icalendar-text text
                 "iCalendar text must be a string"))
  (with-output-to-string (stream)
    (loop :for character :across text
          :do
             (cond
               ((char= character #\Newline) (write-string "\\n" stream))
               ((char= character #\\) (write-string "\\\\" stream))
               ((char= character #\;) (write-string "\\;" stream))
               ((char= character #\,) (write-string "\\," stream))
               ((ical-control-character-p character)
                (model-error :invalid-icalendar-text-control character
                             "text contains an unsupported control character"))
               (t (write-char character stream))))))

(defun ical-split-request-status-fields (raw)
  (let ((parts nil)
        (start 0)
        (escaped-p nil))
    (loop :for index :from 0 :below (length raw)
          :for character := (char raw index)
          :do
             (cond
               (escaped-p (setf escaped-p nil))
               ((char= character #\\) (setf escaped-p t))
               ((char= character #\;)
                (push (subseq raw start index) parts)
                (setf start (1+ index)))))
    (push (subseq raw start) parts)
    (nreverse parts)))

(defun decode-ical-request-status (raw)
  "Decode STATCODE;STATDESC[;EXTDATA] at unescaped semicolon boundaries."
  (let ((fields (ical-split-request-status-fields raw)))
    (unless (<= 2 (length fields) 3)
      (return-from decode-ical-request-status
        (values nil nil
                "REQUEST-STATUS requires code and description plus optional exception data")))
    (let* ((code (first fields))
           (components (ical-request-status-code-components code)))
      (unless components
        (return-from decode-ical-request-status
          (values nil nil
                  "REQUEST-STATUS code requires two or three numeric components")))
      (multiple-value-bind (description description-valid-p description-message)
          (decode-ical-text (second fields))
        (unless description-valid-p
          (return-from decode-ical-request-status
            (values nil nil
                    (format nil "REQUEST-STATUS description: ~a"
                            description-message))))
        (if (= 3 (length fields))
            (multiple-value-bind
                  (exception-data exception-valid-p exception-message)
                (decode-ical-text (third fields))
              (if exception-valid-p
                  (values
                   (%make-ical-request-status-value
                    code components
                    (ical-request-status-class-for-components components)
                    description exception-data raw)
                   t nil)
                  (values nil nil
                          (format nil "REQUEST-STATUS exception data: ~a"
                                  exception-message))))
            (values
             (%make-ical-request-status-value
              code components
              (ical-request-status-class-for-components components)
              description nil raw)
             t nil))))))

(defun encode-ical-request-status (status)
  (unless (ical-request-status-value-p status)
    (model-error :invalid-icalendar-request-status-output status
                 "REQUEST-STATUS output requires a typed status value"))
  (unless (ical-request-status-code-components
           (ical-request-status-value-code status))
    (model-error :invalid-icalendar-request-status-output status
                 "REQUEST-STATUS output code is invalid"))
  (format nil "~a;~a~@[;~a~]"
          (ical-request-status-value-code status)
          (encode-ical-text
           (ical-request-status-value-description status))
          (and (ical-request-status-value-exception-data status)
               (encode-ical-text
                (ical-request-status-value-exception-data status)))))

(defun decode-ical-utc-offset (raw)
  (unless (and (member (length raw) '(5 7))
               (member (char raw 0) '(#\+ #\-))
               (ical-digit-string-p (subseq raw 1)))
    (return-from decode-ical-utc-offset
      (values nil nil "expected +HHMM, -HHMM, +HHMMSS, or -HHMMSS")))
  (let* ((negative-p (char= (char raw 0) #\-))
         (hour (ical-unsigned-integer (subseq raw 1 3)))
         (minute (ical-unsigned-integer (subseq raw 3 5)))
         (second (if (= (length raw) 7)
                     (ical-unsigned-integer (subseq raw 5 7))
                     0)))
    (unless (and (<= 0 hour 23) (<= 0 minute 59) (<= 0 second 59))
      (return-from decode-ical-utc-offset
        (values nil nil "UTC offset field is out of range")))
    (when (and negative-p (zerop hour) (zerop minute) (zerop second))
      (return-from decode-ical-utc-offset
        (values nil nil "negative zero UTC offset is forbidden")))
    (let ((seconds (+ (* hour 3600) (* minute 60) second)))
      (values (if negative-p (- seconds) seconds) t nil))))
