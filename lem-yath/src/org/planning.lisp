;;;; Org scheduling and deadline editing shared with the agenda UI.

(in-package :lem-yath)

(defvar *org-planning-now-function* #'get-universal-time
  "Function returning the current universal time; replaceable in tests.")

(defparameter *org-planning-weekday-names*
  #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))

(defparameter *org-planning-line-scanner*
  (ppcre:create-scanner "^\\s*(?:SCHEDULED|DEADLINE):")
  "Match the structural planning line immediately below an Org heading.")

(defparameter *org-timestamp-scanner*
  (ppcre:create-scanner
   "(<|\\[)([0-9]{4}-[0-9]{2}-[0-9]{2})(?:\\s+[A-Za-z]{3})?(?:\\s+([0-9]{1,2}:[0-9]{2})(?:-([0-9]{1,2}:[0-9]{2}))?)?((?:\\s+[^>\\]\\r\\n]+)?)(>|\\])")
  "Match one ordinary active or inactive Org timestamp on a single line.")

(defstruct (%org-timestamp-token
            (:constructor %make-org-timestamp-token))
  start end active-p date time end-time extra)

(defun org-date-weekday-name (date)
  (multiple-value-bind (year month day) (iso-date-components date)
    (multiple-value-bind (second minute hour decoded-day decoded-month
                          decoded-year weekday)
        (decode-universal-time
         (encode-universal-time 0 0 12 day month year 0)
         0)
      (declare (ignore second minute hour decoded-day decoded-month
                       decoded-year))
      (aref *org-planning-weekday-names* weekday))))

(defun org-date-with-weekday (date)
  "Return DATE as an active Org timestamp with its computed weekday."
  (unless (valid-iso-date-p date)
    (error "Invalid Org date: ~s" date))
  (format nil "<~a ~a>" date (org-date-weekday-name date)))

(defun org-planning-today (&optional
                             (now (funcall *org-planning-now-function*)))
  (iso-date-for-time now))

(defun org-planning-field-scanner
    (kind &optional capture-date-p capture-extra-p)
  (ppcre:create-scanner
   (cond
     (capture-extra-p
      (format nil
              "~a:\\s*<([0-9]{4}-[0-9]{2}-[0-9]{2})(?:\\s+[A-Za-z]{3})?((?:\\s+[^>\\r\\n]+)?)>"
              kind))
     (capture-date-p
      (format nil
              "~a:\\s*<([0-9]{4}-[0-9]{2}-[0-9]{2})(?:\\s+[^>\\r\\n]*)?>"
              kind))
     (t
      (format nil "~a:\\s*<[^>\\r\\n]+>" kind)))))

(defun org-planning-field-components (heading kind)
  "Return KIND's ISO date and post-weekday contents below HEADING."
  (with-point ((planning heading))
    (when (and (line-offset planning 1)
               (ppcre:scan *org-planning-line-scanner*
                           (line-string planning)))
      (let ((line (line-string planning)))
        (multiple-value-bind (start end registers register-ends)
            (ppcre:scan (org-planning-field-scanner kind nil t) line)
          (declare (ignore start end))
          (when (and registers (aref registers 0))
            (let* ((date (subseq line (aref registers 0)
                                 (aref register-ends 0)))
                   (extra-start (aref registers 1))
                   (extra
                     (and extra-start
                          (string-trim
                           '(#\Space #\Tab)
                           (subseq line extra-start
                                   (aref register-ends 1))))))
              (values date
                      (and extra (plusp (length extra)) extra)))))))))

(defun org-planning-field-date (heading kind)
  "Return KIND's ISO date from HEADING's immediate planning line."
  (org-planning-field-components heading kind))

(defun org-read-planning-date (heading kind label)
  "Prompt for LABEL's date, defaulting to KIND's existing date or today."
  (let ((default (or (org-planning-field-date heading kind)
                     (org-planning-today))))
    (org-read-date-prompt
     (format nil "~a date" label)
     :default-date default
     :now (funcall *org-planning-now-function*))))

(defun org-planning-timestamp (date &optional extra)
  (format nil "<~a ~a~@[ ~a~]>"
          date (org-date-weekday-name date)
          (and extra (plusp (length extra)) extra)))

(defun org-set-planning-field
    (heading kind date &key (extra nil extra-supplied-p))
  "Set KIND to DATE on HEADING's immediate Org planning line."
  (unless extra-supplied-p
    (setf extra (nth-value 1 (org-planning-field-components heading kind))))
  (let* ((timestamp (org-planning-timestamp date extra))
         (field (format nil "~a: ~a" kind timestamp))
         (scanner (org-planning-field-scanner kind)))
    (with-point ((planning heading))
      (if (and (line-offset planning 1)
               (ppcre:scan *org-planning-line-scanner*
                           (line-string planning)))
          (let ((line (line-string planning)))
            (multiple-value-bind (start end) (ppcre:scan scanner line)
              (line-start planning)
              (if start
                  (progn
                    (character-offset planning start)
                    (delete-character planning (- end start))
                    (insert-string planning field))
                  (insert-string planning (concatenate 'string field " ")))))
          (progn
            (move-point planning heading)
            (line-end planning)
            (insert-string planning (format nil "~%~a" field)))))
    timestamp))

(defun org-prefix-magnitude (argument)
  (typecase argument
    (integer (abs argument))
    (null 0)
    (t 4)))

(defun org-planning-delay-cookie-p (token)
  (not (null (ppcre:scan "^-{1,2}[0-9]+[hdwmy]$" token))))

(defun org-planning-extra-with-delay (extra days)
  "Replace EXTRA's final warning/delay cookie with -DAYSd."
  (let* ((tokens (if (and extra (plusp (length extra)))
                     (ppcre:split "\\s+" extra)
                     nil))
         (position (position-if #'org-planning-delay-cookie-p
                                tokens :from-end t))
         (kept
           (loop :for token :in tokens
                 :for index :from 0
                 :unless (and position (= index position))
                   :collect token)))
    (format nil "~{~a~^ ~}"
            (append kept (list (format nil "-~dd" days))))))

(defun org-date-day-number (date)
  (multiple-value-bind (year month day) (iso-date-components date)
    (floor (encode-universal-time 0 0 12 day month year 0) 86400)))

(defun org-update-planning-delay (heading kind label)
  "Prompt for and update KIND's warning or delay cookie below HEADING."
  (multiple-value-bind (date extra)
      (org-planning-field-components heading kind)
    (unless date
      (message "No ~a information to update" (string-downcase label))
      (return-from org-update-planning-delay nil))
    (let* ((target
             (org-read-date-prompt
              (if (string= kind "DEADLINE")
                  "Warn starting from"
                  "Delay until")
              :default-date date
              :now (funcall *org-planning-now-function*)))
           (days (abs (- (org-date-day-number target)
                         (org-date-day-number date))))
           (updated-extra (org-planning-extra-with-delay extra days)))
      (org-set-planning-field heading kind date :extra updated-extra))))

(defun org-delete-complete-line (point)
  (with-point ((start point)
               (end point))
    (line-start start)
    (line-start end)
    (if (line-offset end 1)
        (delete-between-points start end)
        (progn
          (unless (start-buffer-p start)
            (character-offset start -1))
          (delete-between-points start (buffer-end-point
                                        (point-buffer start)))))))

(defun org-remove-planning-field (heading kind)
  "Remove KIND from HEADING's planning line and return whether it existed."
  (with-point ((planning heading))
    (unless (and (line-offset planning 1)
                 (ppcre:scan *org-planning-line-scanner*
                             (line-string planning)))
      (return-from org-remove-planning-field nil))
    (let* ((line (line-string planning))
           (scanner (org-planning-field-scanner kind)))
      (unless (ppcre:scan scanner line)
        (return-from org-remove-planning-field nil))
      (let* ((without (ppcre:regex-replace-all scanner line ""))
             (indent-end (or (position-if-not
                              (lambda (character)
                                (member character '(#\Space #\Tab)))
                              line)
                             (length line)))
             (indent (subseq line 0 indent-end))
             (body (string-trim '(#\Space #\Tab) without)))
        (if (zerop (length body))
            (org-delete-complete-line planning)
            (progn
              (line-start planning)
              (delete-character planning (length line))
              (insert-string planning (concatenate 'string indent body))))
        t))))

(defun org-change-planning (kind label argument)
  (alexandria:if-let ((heading (org-current-heading-point)))
    (let ((magnitude (org-prefix-magnitude argument)))
      (cond
        ((buffer-read-only-p (current-buffer))
         (editor-error "Org buffer is read-only"))
        ((= magnitude 4)
         (org-clear-folds (current-buffer))
         (message (if (org-remove-planning-field heading kind)
                      "Removed ~a" "No ~a to remove")
                  kind))
        ((= magnitude 16)
         (alexandria:when-let ((timestamp
                                (org-update-planning-delay
                                 heading kind label)))
           (org-clear-folds (current-buffer))
           (message "~a" timestamp)))
        (t
         (let ((date (org-read-planning-date heading kind label)))
           (org-clear-folds (current-buffer))
           (message "~a" (org-set-planning-field heading kind date))))))
    (message "No Org heading at point")))

(define-command lem-yath-org-schedule (argument) (:universal-nil)
  "Set this heading's SCHEDULED date; a prefix removes it."
  (org-change-planning "SCHEDULED" "Schedule" argument))

(define-command lem-yath-org-deadline (argument) (:universal-nil)
  "Set this heading's DEADLINE date; a prefix removes it."
  (org-change-planning "DEADLINE" "Deadline" argument))

;;; --- ordinary timestamps ------------------------------------------------

(defparameter *org-timestamp-command-names*
  '(lem-yath-org-timestamp lem-yath-org-timestamp-inactive)
  "Commands which can form a timestamp range when used successively.")

(defvar *org-last-command-was-timestamp-p* nil
  "Whether the preceding completed editor command inserted a timestamp.")

(defun org-timestamp-command-p (&optional (command (this-command)))
  (and (typep command 'lem/common/command:primary-command)
       (member (command-name command) *org-timestamp-command-names*)))

(defun org-timestamp-post-command ()
  "Break timestamp-range succession after any unrelated command."
  (unless (org-timestamp-command-p)
    (setf *org-last-command-was-timestamp-p* nil)))

(defun org-timestamp-match-part (line starts ends index)
  (let ((start (and starts (aref starts index))))
    (and start (subseq line start (aref ends index)))))

(defun org-normalize-clock-time (text)
  (multiple-value-bind (start end starts ends)
      (ppcre:scan "^([0-9]{1,2}):([0-9]{2})$" text)
    (declare (ignore end))
    (when start
      (let ((hour (parse-integer text :start (aref starts 0)
                                 :end (aref ends 0)))
            (minute (parse-integer text :start (aref starts 1)
                                   :end (aref ends 1))))
        (when (and (<= 0 hour 23) (<= 0 minute 59))
          (format nil "~2,'0d:~2,'0d" hour minute))))))

(defun org-parse-clock-spec (text)
  "Return normalized start/end times and true when TEXT is a clock spec."
  (let* ((separator (position #\- text))
         (start (org-normalize-clock-time
                 (if separator (subseq text 0 separator) text)))
         (end (and separator
                   (org-normalize-clock-time
                    (subseq text (1+ separator))))))
    (values start end (and start (or (null separator) end)))))

(defun org-timestamp-token-at-point (&optional (point (current-point)))
  "Return the ordinary Org timestamp containing or ending at POINT."
  (let ((line (line-string point))
        (column (point-charpos point))
        (offset 0))
    (loop
      (multiple-value-bind (start end starts ends)
          (ppcre:scan *org-timestamp-scanner* line :start offset)
        (unless start (return nil))
        (let* ((opening (org-timestamp-match-part line starts ends 0))
               (date (org-timestamp-match-part line starts ends 1))
               (time-text (org-timestamp-match-part line starts ends 2))
               (end-time-text (org-timestamp-match-part line starts ends 3))
               (extra (string-trim
                       '(#\Space #\Tab)
                       (or (org-timestamp-match-part line starts ends 4) "")))
               (closing (org-timestamp-match-part line starts ends 5))
               (active-p (and (string= opening "<")
                              (string= closing ">")))
               (inactive-p (and (string= opening "[")
                                (string= closing "]")))
               (time (and time-text
                          (org-normalize-clock-time time-text)))
               (end-time (and end-time-text
                              (org-normalize-clock-time end-time-text))))
          (when (and (or active-p inactive-p)
                     (valid-iso-date-p date)
                     (or (null time-text) time)
                     (or (null end-time-text) end-time)
                     (<= start column end))
            (return
              (%make-org-timestamp-token
               :start start :end end :active-p active-p :date date
               :time time :end-time end-time :extra extra))))
        (setf offset (max (1+ start) end))))))

(defun org-timestamp-text (date active-p &key time end-time extra)
  (let ((opening (if active-p #\< #\[))
        (closing (if active-p #\> #\])))
    (format nil "~c~a ~a~@[ ~a~]~@[-~a~]~@[ ~a~]~c"
            opening date (org-date-weekday-name date)
            time end-time
            (and extra (plusp (length extra)) extra)
            closing)))

(defun org-timestamp-default-input (token now force-time-p)
  (let ((date (if token
                  (%org-timestamp-token-date token)
                  (org-planning-today now)))
        (time (and token (%org-timestamp-token-time token)))
        (end-time (and token (%org-timestamp-token-end-time token))))
    (when (and force-time-p (null time))
      (multiple-value-bind (second minute hour)
          (decode-universal-time now)
        (declare (ignore second))
        (setf time (format nil "~2,'0d:~2,'0d" hour minute))))
    (format nil "~a~@[ ~a~]~@[-~a~]" date time end-time)))

(defun org-parse-timestamp-input (input default-date now)
  "Return date, start time, end time, and true for Org-style timestamp INPUT."
  (let ((value (string-trim '(#\Space #\Tab) input)))
    (cond
      ((zerop (length value)) (values default-date nil nil t))
      (t
       (multiple-value-bind (time end-time clock-p)
           (org-parse-clock-spec value)
         (when clock-p
           (return-from org-parse-timestamp-input
             (values default-date time end-time t))))
       (alexandria:when-let
           ((date (org-parse-date-input
                   value :default-date default-date :now now)))
         (return-from org-parse-timestamp-input
           (values date nil nil t)))
       (alexandria:when-let ((separator (position #\Space value :from-end t)))
         (let ((date-text (string-trim '(#\Space #\Tab)
                                       (subseq value 0 separator)))
               (clock-text (string-trim '(#\Space #\Tab)
                                        (subseq value (1+ separator)))))
           (multiple-value-bind (time end-time clock-p)
               (org-parse-clock-spec clock-text)
             (alexandria:when-let
                 ((date (and clock-p
                             (org-parse-date-input
                              date-text :default-date default-date :now now))))
               (return-from org-parse-timestamp-input
                 (values date time end-time t))))))
       (values nil nil nil nil)))))

(defun org-timestamp-calendar-rewrite (date input)
  "Replace INPUT's date with DATE while retaining a final clock specification."
  (let* ((value (string-trim '(#\Space #\Tab) input))
         (separator (position #\Space value :from-end t))
         (candidate (if separator
                        (subseq value (1+ separator))
                        value)))
    (multiple-value-bind (time end-time clock-p)
        (org-parse-clock-spec candidate)
      (declare (ignore time end-time))
      (if clock-p
          (format nil "~a ~a" date candidate)
          date))))

(defun org-read-timestamp-values (token label now force-time-p)
  (let* ((default-input
           (org-timestamp-default-input token now force-time-p))
         (default-date (if token
                           (%org-timestamp-token-date token)
                           (org-planning-today now))))
    (loop
      :for input :=
        (string-trim
         '(#\Space #\Tab)
         (org-read-date-input
          (format nil "~a [~a] (date and optional time): "
                  label default-input)
          default-date
          (lambda (value)
            (multiple-value-bind (date time end-time valid-p)
                (org-parse-timestamp-input
                 (if (zerop (length value)) default-input value)
                 default-date now)
              (declare (ignore time end-time))
              (and valid-p date)))
          :now now
          :selection-rewriter #'org-timestamp-calendar-rewrite))
      :do
         (when (zerop (length input))
           (setf input default-input))
         (multiple-value-bind (date time end-time valid-p)
             (org-parse-timestamp-input input default-date now)
           (when valid-p
             (when (and force-time-p (null time))
               (multiple-value-bind (second minute hour)
                   (decode-universal-time now)
                 (declare (ignore second))
                 (setf time (format nil "~2,'0d:~2,'0d" hour minute))))
             (return (values date time end-time))))
         (message
          "Invalid timestamp; use DATE, DATE HH:MM, or DATE HH:MM-HH:MM"))))

(defun org-replace-timestamp-token (token text &optional leave-after-p)
  (let* ((point (current-point))
         (relative (- (point-charpos point)
                      (%org-timestamp-token-start token))))
    (line-start point)
    (character-offset point (%org-timestamp-token-start token))
    (delete-character point (- (%org-timestamp-token-end token)
                               (%org-timestamp-token-start token)))
    (insert-string point text)
    (line-start point)
    (character-offset point
                      (if leave-after-p
                          (+ (%org-timestamp-token-start token)
                             (length text))
                          (+ (%org-timestamp-token-start token)
                             (min (max relative 0)
                                  (1- (length text)))))))
  text)

(defun org-append-timestamp-range-end (token text)
  "Insert TEXT as a range end immediately after TOKEN."
  (let ((point (current-point)))
    (line-start point)
    (character-offset point (%org-timestamp-token-end token))
    (insert-string point (concatenate 'string "--" text)))
  text)

(defun org-insert-or-replace-timestamp (inactive-p argument)
  (let* ((token (org-timestamp-token-at-point))
         (range-end-p (and token *org-last-command-was-timestamp-p*))
         (now (funcall *org-planning-now-function*))
         (magnitude (org-prefix-magnitude argument))
         (force-time-p (>= magnitude 4))
         (immediate-p (>= magnitude 16)))
    ;; A failed or cancelled invocation must not leave a range continuation.
    (setf *org-last-command-was-timestamp-p* nil)
    (when (buffer-read-only-p (current-buffer))
      (editor-error "Org buffer is read-only"))
    (multiple-value-bind (date time end-time)
        (if immediate-p
            (multiple-value-bind (second minute hour)
                (decode-universal-time now)
              (declare (ignore second))
              (values (org-planning-today now)
                      (format nil "~2,'0d:~2,'0d" hour minute)
                      nil))
            (org-read-timestamp-values token
                                       (if inactive-p
                                           "Inactive timestamp"
                                           "Timestamp")
                                       now force-time-p))
      (let ((text
              (org-timestamp-text
               date (not inactive-p)
               :time time :end-time end-time
               :extra (and token
                           (not range-end-p)
                           (%org-timestamp-token-extra token)))))
        (cond
          (range-end-p
           (org-append-timestamp-range-end token text))
          (token
           (org-replace-timestamp-token token text t))
          (t
           (insert-string (current-point) text)))
        (setf *org-last-command-was-timestamp-p* t)
        (message "~[Inserted~;Updated~;Inserted range end~] ~a"
                 (cond (range-end-p 2) (token 1) (t 0)) text)
        text))))

(defun org-shift-timestamp-at-point (days)
  "Shift the timestamp at point by DAYS, preserving its other syntax."
  (alexandria:when-let ((token (org-timestamp-token-at-point)))
    (when (buffer-read-only-p (current-buffer))
      (editor-error "Org buffer is read-only"))
    (let* ((date (or (iso-date-add-calendar
                      (%org-timestamp-token-date token) days #\d)
                     (editor-error "Timestamp leaves the supported date range")))
           (text
             (org-timestamp-text
              date (%org-timestamp-token-active-p token)
              :time (%org-timestamp-token-time token)
              :end-time (%org-timestamp-token-end-time token)
              :extra (%org-timestamp-token-extra token))))
      (org-replace-timestamp-token token text)
      (message "~a" text)
      t)))

(define-command lem-yath-org-timestamp (argument) (:universal-nil)
  "Insert or update an active Org timestamp."
  (org-insert-or-replace-timestamp nil argument))

(define-command lem-yath-org-timestamp-inactive (argument) (:universal-nil)
  "Insert or update an inactive Org timestamp."
  (org-insert-or-replace-timestamp t argument))

(define-key *org-mode-keymap* "C-c C-s" 'lem-yath-org-schedule)
(define-key *org-mode-keymap* "C-c C-d" 'lem-yath-org-deadline)
(define-key *org-mode-keymap* "C-c ." 'lem-yath-org-timestamp)
(define-key *org-mode-keymap* "C-c !" 'lem-yath-org-timestamp-inactive)

(remove-hook *post-command-hook* 'org-timestamp-post-command)
(add-hook *post-command-hook* 'org-timestamp-post-command)
