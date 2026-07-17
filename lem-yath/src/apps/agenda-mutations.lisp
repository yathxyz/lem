;;;; Durable Evil-Org and GNU Org agenda mutations.

(in-package :lem-yath)

(defvar *agenda-confirm-kill* 1
  "Confirm agenda subtree deletion above this many nonblank source lines.")

(defvar *agenda-last-date-shift-unit* nil)

(defparameter *agenda-duration-scanner*
  (ppcre:create-scanner
   (concatenate
    'string
    "^\\s*(?:"
    "[0-9]+(?:\\.[0-9]*)?"
    "|[0-9]+(?::[0-9]{2}){1,2}"
    "|(?:[0-9]+(?:\\.[0-9]*)?\\s*(?:min|h|d|w|m|y)\\s*)+"
    "(?:[0-9]+(?::[0-9]{2}){1,2})?"
    ")\\s*$"))
  "The pinned Org duration forms accepted by `org-set-effort'.")

(defun agenda-source-heading-point (file line expected-heading action)
  "Return FILE's validated source buffer and heading point for ACTION."
  (unless (and file (integerp line) (plusp line) expected-heading)
    (error "No mutable agenda heading on this line"))
  (let ((buffer (find-file-buffer file)))
    (with-current-buffer buffer
      (when (buffer-read-only-p buffer)
        (error "Agenda source is read-only: ~a" file))
      (with-point ((heading (buffer-start-point buffer)))
        (unless (or (= line 1) (line-offset heading (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (unless (string= expected-heading (line-string heading))
          (error "Agenda source changed; refresh before ~a" action))
        (values buffer (copy-point heading :temporary))))))

(defun agenda-subtree-nonblank-line-count (text)
  (count-if (lambda (line)
              (plusp (length (string-trim '(#\Space #\Tab #\Return) line))))
            (ppcre:split "\\n" text)))

(defun agenda-source-subtree-info (file line expected-heading)
  "Return the exact subtree text, following line, nonblank count, and buffer."
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point file line expected-heading "deleting")
    (with-current-buffer buffer
      (let ((end (org-subtree-end-point heading)))
        (unless end
          (error "Agenda row no longer names an Org subtree"))
        (let ((subtree (points-to-string heading end)))
          (values subtree
                  (unless (end-buffer-p end) (line-number-at-point end))
                  (agenda-subtree-nonblank-line-count subtree)
                  (buffer-name buffer)))))))

(defun agenda-delete-source-subtree (file line expected-heading expected-text)
  "Delete EXPECTED-TEXT from one validated Org subtree and save immediately."
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point file line expected-heading "deleting")
    (with-current-buffer buffer
      (let* ((end (org-subtree-end-point heading))
             (actual (and end (points-to-string heading end)))
             (original-modified-p (buffer-modified-p buffer)))
        (unless (and actual (string= expected-text actual))
          (error "Agenda source subtree changed; refresh before deleting"))
        (delete-between-points heading end)
        (handler-case
            (save-buffer buffer)
          (error (condition)
            (insert-string heading expected-text)
            (unless original-modified-p (buffer-unmark buffer))
            (error condition))))))
  t)

(defun agenda-key-after-subtree-deletion (key file start-line end-line)
  "Adjust KEY's source line after deleting FILE's source line interval."
  (when key
    (let ((adjusted (copy-list key)))
      (when (and end-line
                 (uiop:pathname-equal (first adjusted) file)
                 (>= (second adjusted) end-line))
        (decf (second adjusted) (- end-line start-line)))
      adjusted)))

(defun agenda-kill-neighbor-key (origin file start-line end-line)
  "Return the nearest surviving rendered key after deleting one subtree."
  (labels ((scan (direction)
             (with-point ((point origin))
               (loop :while (line-offset point direction)
                     :for key := (agenda-entry-key-at-point point)
                     :when (and key
                                (not (agenda-archive-row-in-subtree-p
                                      point file start-line end-line)))
                       :return key))))
    (or (agenda-key-after-subtree-deletion
         (scan 1) file start-line end-line)
        (scan -1))))

(define-command lem-yath-agenda-kill-entry () ()
  "Confirm when needed, delete the selected Org subtree, save, and refresh."
  (let* ((agenda-buffer (current-buffer))
         (origin (copy-point (current-point) :temporary))
         (file (text-property-at origin :agenda-file))
         (line (text-property-at origin :agenda-line))
         (heading (text-property-at origin :agenda-heading)))
    (if (null file)
        (message "No agenda entry on this line.")
        (handler-case
            (multiple-value-bind (subtree end-line nonblank-lines buffer-name)
                (agenda-source-subtree-info file line heading)
              (if (and (or (eq *agenda-confirm-kill* t)
                           (and (numberp *agenda-confirm-kill*)
                                (> nonblank-lines *agenda-confirm-kill*)))
                       (not (prompt-for-y-or-n-p
                             (format nil
                                     "Delete entry with ~d lines in buffer ~s?"
                                     nonblank-lines buffer-name))))
                  (message "Agenda deletion cancelled")
                  (progn
                    (agenda-delete-source-subtree file line heading subtree)
                    (setf (buffer-value agenda-buffer
                                        'lem-yath-agenda-restore-entry)
                          (agenda-kill-neighbor-key
                           origin file line end-line))
                    (agenda-start-scan agenda-buffer)
                    (message "Agenda item and source killed"))))
          (error (condition)
            (message "Agenda deletion failed: ~a" condition))))))

(defun agenda-duration-p (value)
  (or (string= value "")
      (not (null (ppcre:scan *agenda-duration-scanner* value)))))

(defun agenda-effort-property-line (value)
  (format nil ":Effort:~a~a"
          (make-string 3 :initial-element #\Space) value))

(defun agenda-replace-current-line (point text)
  (line-start point)
  (with-point ((end point))
    (line-end end)
    (delete-between-points point end))
  (insert-string point text)
  text)

(defun agenda-set-heading-effort (heading value)
  "Set VALUE in HEADING's immediate property drawer with GNU Org spacing."
  (with-point ((point heading))
    (agenda-clock-move-after-line point)
    (loop :while (ppcre:scan *planning-line-scanner* (line-string point))
          :do (agenda-clock-move-after-line point))
    (if (string-equal (agenda-clock-trimmed-line point) ":PROPERTIES:")
        (loop :while (line-offset point 1)
              :for line := (agenda-clock-trimmed-line point)
              :do (cond
                    ((string-equal line ":END:")
                     (line-start point)
                     (insert-string point
                                    (format nil "~a~%"
                                            (agenda-effort-property-line value)))
                     (return value))
                    ((org-heading-line-p point)
                     (error "Malformed Org property drawer: missing :END:"))
                    (t
                     (when (ppcre:scan "(?i)^:EFFORT:\\s*" line)
                       (agenda-replace-current-line
                        point (agenda-effort-property-line value))
                       (return value))))
              :finally
                 (error "Malformed Org property drawer: missing :END:"))
        (progn
          (line-start point)
          (insert-string
           point
           (format nil ":PROPERTIES:~%~a~%:END:~%"
                   (agenda-effort-property-line value)))
          value))))

(defun agenda-set-source-effort (file line expected-heading value)
  "Set one exact source heading's Effort property and save immediately."
  (unless (agenda-duration-p value)
    (error "Invalid duration format: ~s" value))
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point file line expected-heading "setting Effort")
    (with-current-buffer buffer
      (agenda-set-heading-effort heading value)
      (save-buffer buffer)))
  value)

(define-command lem-yath-agenda-set-effort () ()
  "Prompt for and persist the selected agenda heading's Effort property."
  (let ((agenda-buffer (current-buffer))
        (entry-key (agenda-entry-key-at-point (current-point)))
        (file (text-property-at (current-point) :agenda-file))
        (line (text-property-at (current-point) :agenda-line))
        (heading (text-property-at (current-point) :agenda-heading)))
    (if (null file)
        (message "No agenda entry on this line.")
        (let ((value (prompt-for-string "Effort: ")))
          (handler-case
              (progn
                (agenda-set-source-effort file line heading value)
                (setf (buffer-value agenda-buffer
                                    'lem-yath-agenda-restore-entry)
                      entry-key)
                (agenda-start-scan agenda-buffer)
                (message "Effort is now ~a" value))
            (error (condition)
              (message "Agenda Effort failed: ~a" condition)))))))

(defun agenda-clock-minutes (time)
  (+ (* 60 (parse-integer time :end 2))
     (parse-integer time :start 3)))

(defun agenda-shift-clock-value (date time minutes)
  (let ((total (+ (agenda-clock-minutes time) minutes)))
    (multiple-value-bind (day-offset minute-of-day) (floor total 1440)
      (let ((new-date (or (iso-date-add-calendar date day-offset #\d)
                          (error "Timestamp leaves the supported date range"))))
        (values new-date
                (format nil "~2,'0d:~2,'0d"
                        (floor minute-of-day 60)
                        (mod minute-of-day 60)))))))

(defun agenda-replace-timestamp-token-at-point (point token text)
  "Replace TOKEN with TEXT on POINT's source line, without ambient point state."
  (line-start point)
  (character-offset point (%org-timestamp-token-start token))
  (delete-character point (- (%org-timestamp-token-end token)
                             (%org-timestamp-token-start token)))
  (insert-string point text)
  text)

(defun agenda-shift-timestamp-token (point unit amount)
  "Shift the timestamp token at POINT and return its new values and text."
  (let ((token (or (org-timestamp-token-at-point point)
                   (error "Cannot find time stamp"))))
    (let* ((old-date (%org-timestamp-token-date token))
           (old-time (%org-timestamp-token-time token))
           (old-end-time (%org-timestamp-token-end-time token))
           (new-date old-date)
           (new-time old-time)
           (new-end-time old-end-time)
           (changed-p nil))
      (ecase unit
        (:day
         (setf new-date
               (or (iso-date-add-calendar old-date amount #\d)
                   (error "Timestamp leaves the supported date range"))
               changed-p (/= amount 0)))
        ((:hour :minute)
         (when old-time
           (let ((minutes (* amount (if (eq unit :hour) 60 1))))
             (multiple-value-setq (new-date new-time)
               (agenda-shift-clock-value old-date old-time minutes))
             (when old-end-time
               (setf new-end-time
                     (nth-value 1
                       (agenda-shift-clock-value
                        old-date old-end-time minutes))))
             (setf changed-p t)))))
      (let ((text
              (org-timestamp-text
               new-date (%org-timestamp-token-active-p token)
               :time new-time :end-time new-end-time
               :extra (%org-timestamp-token-extra token))))
        (when changed-p
          (agenda-replace-timestamp-token-at-point point token text))
        (values new-date new-time changed-p text old-date)))))

(defun agenda-shift-past-to-today-amount
    (date unit amount direction range-p)
  (if (and (eq unit :day) (= amount 1) (= direction 1) (not range-p)
           (string< date (today-iso)))
      (- (agenda-date-ordinal (today-iso)) (agenda-date-ordinal date))
      (* direction amount)))

(defun agenda-shift-event-source
    (file heading-line expected-heading timestamp-line expected-source-line
     timestamp-start expected-raw unit amount direction)
  "Shift one exactly identified ordinary event timestamp and save its source."
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point
       file heading-line expected-heading "shifting its timestamp")
    (declare (ignore heading))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (unless (or (= timestamp-line 1)
                    (line-offset point (1- timestamp-line)))
          (error "Agenda timestamp line no longer exists; refresh the agenda"))
        (unless (string= expected-source-line (line-string point))
          (error "Agenda timestamp source changed; refresh before editing"))
        (let* ((range-p (not (null (ppcre:scan ">--<" expected-raw))))
               (old-line (line-string point))
               (old-modified-p (buffer-modified-p buffer))
               (raw-end (+ timestamp-start (length expected-raw))))
          (unless (and (<= raw-end (length old-line))
                       (string= expected-raw
                                (subseq old-line timestamp-start raw-end)))
            (error "Agenda timestamp moved; refresh before editing"))
          (line-start point)
          (character-offset point timestamp-start)
          (let* ((token (or (org-timestamp-token-at-point point)
                            (error "Cannot find time stamp")))
                 (old-date (%org-timestamp-token-date token))
                 (effective
                   (agenda-shift-past-to-today-amount
                    old-date unit amount direction range-p)))
            (handler-case
                (multiple-value-bind
                      (new-date new-time changed-p first-text ignored-old-date)
                    (agenda-shift-timestamp-token point unit effective)
                  (declare (ignore ignored-old-date))
                  (when range-p
                    (line-start point)
                    (character-offset point
                                      (+ timestamp-start
                                         (length first-text) 2))
                    (agenda-shift-timestamp-token point unit effective))
                  (save-buffer buffer)
                  (values new-date new-time changed-p
                          (- (agenda-date-ordinal new-date)
                             (agenda-date-ordinal old-date))))
              (error (condition)
                (agenda-replace-current-line point old-line)
                (unless old-modified-p (buffer-unmark buffer))
                (error condition)))))))))

(defun agenda-planning-timestamp-start (line kind)
  (multiple-value-bind (start end)
      (ppcre:scan (org-planning-field-scanner kind) line)
    (and start (position #\< line :start start :end end))))

(defun agenda-shift-planning-source
    (file line expected-heading kind expected-date unit amount direction)
  "Shift one validated SCHEDULED or DEADLINE timestamp and save its source."
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point file line expected-heading "shifting its date")
    (with-current-buffer buffer
      (with-point ((planning heading))
        (unless (line-offset planning 1)
          (error "Agenda planning line no longer exists; refresh the agenda"))
        (let* ((old-line (line-string planning))
               (start (agenda-planning-timestamp-start old-line kind))
               (old-modified-p (buffer-modified-p buffer)))
          (unless start
            (error "Agenda planning field changed; refresh before editing"))
          (line-start planning)
          (character-offset planning start)
          (let* ((token (or (org-timestamp-token-at-point planning)
                            (error "Cannot find time stamp")))
                 (old-date (%org-timestamp-token-date token)))
            (unless (string= old-date expected-date)
              (error "Agenda planning date changed; refresh before editing"))
            (let ((effective
                    (agenda-shift-past-to-today-amount
                     old-date unit amount direction nil)))
              (handler-case
                  (multiple-value-bind
                        (new-date new-time changed-p text ignored-old-date)
                      (agenda-shift-timestamp-token planning unit effective)
                    (declare (ignore text ignored-old-date))
                    (save-buffer buffer)
                    (values new-date new-time changed-p
                            (- (agenda-date-ordinal new-date)
                               (agenda-date-ordinal old-date))))
                (error (condition)
                  (agenda-replace-current-line planning old-line)
                  (unless old-modified-p (buffer-unmark buffer))
                  (error condition))))))))))

(defun agenda-date-shift-unit-and-amount (argument)
  "Interpret GNU Org's ordinary, universal, and continued date shifts."
  (let ((magnitude (org-prefix-magnitude argument)))
    (cond
      ((= magnitude 16) (values :minute 5))
      ((= magnitude 4) (values :hour 1))
      ((and (zerop magnitude)
            (member *agenda-last-date-shift-unit* '(:hour :minute)))
       (values *agenda-last-date-shift-unit*
               (if (eq *agenda-last-date-shift-unit* :minute) 5 1)))
      (t (values :day (max 1 magnitude))))))

(defun agenda-shift-restore-key (entry-key day-offset new-time event-p)
  (let ((key (copy-list entry-key)))
    (when (fourth key)
      (setf (fourth key)
            (or (iso-date-add-calendar (fourth key) day-offset #\d)
                (fourth key))))
    (when event-p (setf (fifth key) new-time))
    key))

(defun agenda-shift-current-date (direction argument)
  "Shift the selected agenda timestamp in DIRECTION and persist it."
  (let* ((agenda-buffer (current-buffer))
         (point (current-point))
         (entry-key (agenda-entry-key-at-point point))
         (file (text-property-at point :agenda-file))
         (line (text-property-at point :agenda-line))
         (heading (text-property-at point :agenda-heading))
         (kind (text-property-at point :agenda-kind))
         (date (text-property-at point :agenda-date))
         (timestamp-line (text-property-at point :agenda-timestamp-line))
         (timestamp-source-line
           (text-property-at point :agenda-timestamp-source-line))
         (timestamp-start (text-property-at point :agenda-timestamp-start))
         (timestamp-raw (text-property-at point :agenda-timestamp-raw))
         (event-p (string= (or kind "") "TIMESTAMP")))
    (cond
      ((null file) (message "No agenda entry on this line."))
      ((null date) (message "No timestamp on this agenda line."))
      (t
       (multiple-value-bind (unit amount)
           (agenda-date-shift-unit-and-amount argument)
         (handler-case
             (multiple-value-bind (new-date new-time changed-p day-offset)
                 (if event-p
                     (agenda-shift-event-source
                      file line heading timestamp-line timestamp-source-line
                      timestamp-start timestamp-raw unit amount direction)
                     (agenda-shift-planning-source
                      file line heading kind date unit amount direction))
               (declare (ignore new-date))
               (setf *agenda-last-date-shift-unit* unit
                     (buffer-value agenda-buffer
                                   'lem-yath-agenda-restore-entry)
                     (agenda-shift-restore-key
                      entry-key day-offset new-time event-p))
               (agenda-start-scan agenda-buffer)
               (message (if changed-p
                            "Time stamp changed"
                            "Time stamp has no shiftable time")))
           (error (condition)
             (setf *agenda-last-date-shift-unit* nil)
             (message "Agenda date shift failed: ~a" condition))))))))

(define-command lem-yath-agenda-date-earlier (argument) (:universal-nil)
  "Move the selected agenda timestamp earlier like Evil-Org H."
  (agenda-shift-current-date -1 argument))

(define-command lem-yath-agenda-date-later (argument) (:universal-nil)
  "Move the selected agenda timestamp later like Evil-Org L."
  (agenda-shift-current-date 1 argument))

(defun agenda-timestamp-token-signature (token)
  "Return TOKEN's source identity independent of its temporary point."
  (list (%org-timestamp-token-start token)
        (%org-timestamp-token-end token)
        (%org-timestamp-token-active-p token)
        (%org-timestamp-token-date token)
        (%org-timestamp-token-time token)
        (%org-timestamp-token-end-time token)
        (%org-timestamp-token-extra token)))

(defun agenda-planning-timestamp-target
    (file line expected-heading kind expected-date)
  "Return the validated source buffer, point, and planning timestamp token."
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point file line expected-heading
                                   "changing its timestamp")
    (with-current-buffer buffer
      (with-point ((planning heading))
        (unless (line-offset planning 1)
          (error "Agenda planning line no longer exists; refresh the agenda"))
        (let* ((source-line (line-string planning))
               (start (agenda-planning-timestamp-start source-line kind)))
          (unless start
            (error "Cannot find time stamp"))
          (line-start planning)
          (character-offset planning start)
          (let ((token (or (org-timestamp-token-at-point planning)
                           (error "Cannot find time stamp"))))
            (unless (string= expected-date
                             (%org-timestamp-token-date token))
              (error "Agenda planning date changed; refresh before editing"))
            (values buffer (copy-point planning :temporary) token)))))))

(defun agenda-event-timestamp-target
    (file heading-line expected-heading timestamp-line expected-source-line
     timestamp-start expected-raw)
  "Return the validated source buffer, point, and ordinary timestamp token."
  (unless (and (integerp timestamp-line) (plusp timestamp-line)
               (integerp timestamp-start) (not (minusp timestamp-start))
               expected-source-line expected-raw)
    (error "Cannot find time stamp"))
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point file heading-line expected-heading
                                   "changing its timestamp")
    (declare (ignore heading))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (unless (or (= timestamp-line 1)
                    (line-offset point (1- timestamp-line)))
          (error "Agenda timestamp line no longer exists; refresh the agenda"))
        (let* ((source-line (line-string point))
               (raw-end (+ timestamp-start (length expected-raw))))
          (unless (string= expected-source-line source-line)
            (error "Agenda timestamp source changed; refresh before editing"))
          (unless (and (<= raw-end (length source-line))
                       (string= expected-raw
                                (subseq source-line timestamp-start raw-end)))
            (error "Agenda timestamp moved; refresh before editing"))
          (line-start point)
          (character-offset point timestamp-start)
          (values buffer (copy-point point :temporary)
                  (or (org-timestamp-token-at-point point)
                      (error "Cannot find time stamp"))))))))

(defun agenda-read-timestamp-replacement (token argument)
  "Read the replacement for TOKEN using GNU Org's prefix behavior."
  (let* ((now (funcall *agenda-now-function*))
         (magnitude (org-prefix-magnitude argument))
         (immediate-p (= magnitude 16)))
    (multiple-value-bind (date time end-time)
        (if immediate-p
            (multiple-value-bind (second minute hour)
                (decode-universal-time now)
              (declare (ignore second))
              (values (org-planning-today now)
                      (format nil "~2,'0d:~2,'0d" hour minute)
                      nil))
            (org-read-timestamp-values token "Date" now (plusp magnitude)))
      (values
       date time
       (org-timestamp-text
        date (%org-timestamp-token-active-p token)
        :time time :end-time end-time
        :extra (%org-timestamp-token-extra token))))))

(defun agenda-rewrite-source-timestamp (buffer point token text)
  "Replace TOKEN at POINT as one unsaved remote undo transaction."
  (with-current-buffer buffer
    (let ((group nil)
          (accepted-p nil))
      (buffer-undo-boundary buffer)
      (setf group (buffer-prepare-change-group buffer))
      (unwind-protect
           (progn
             (line-start point)
             (character-offset point (%org-timestamp-token-start token))
             (delete-character
              point (- (%org-timestamp-token-end token)
                       (%org-timestamp-token-start token)))
             (insert-string point text)
             (buffer-accept-change-group group)
             (setf accepted-p t)
             (buffer-undo-boundary buffer))
        (unless accepted-p
          (when (and group (buffer-change-group-active-p group))
            (ignore-errors (buffer-cancel-change-group group)))))))
  text)

(defun agenda-date-prompt-restore-key
    (entry-key old-source-date new-date new-time event-p)
  "Return the best refreshed row key after changing one source timestamp."
  (let ((key (copy-list entry-key)))
    (when key
      (if event-p
          (let* ((displayed-date (fourth key))
                 (offset (and displayed-date
                              (- (agenda-date-ordinal displayed-date)
                                 (agenda-date-ordinal old-source-date)))))
            (setf (fourth key)
                  (if offset
                      (agenda-add-calendar new-date offset #\d)
                      new-date)
                  (fifth key) new-time))
          (setf (fourth key) new-date
                (fifth key) nil)))
    key))

(defun agenda-date-prompt-target
    (event-p file line heading kind date timestamp-line
     timestamp-source-line timestamp-start timestamp-raw)
  (if event-p
      (agenda-event-timestamp-target
       file line heading timestamp-line timestamp-source-line
       timestamp-start timestamp-raw)
      (progn
        (unless (member kind '("SCHEDULED" "DEADLINE") :test #'string=)
          (error "Cannot find time stamp"))
        (agenda-planning-timestamp-target file line heading kind date))))

(define-command lem-yath-agenda-date-prompt (argument) (:universal-nil)
  "Prompt for and change the exact timestamp represented by the agenda row."
  (let* ((agenda-buffer (current-buffer))
         (point (current-point))
         (entry-key (agenda-entry-key-at-point point))
         (file (text-property-at point :agenda-file))
         (line (text-property-at point :agenda-line))
         (heading (text-property-at point :agenda-heading))
         (kind (text-property-at point :agenda-kind))
         (date (text-property-at point :agenda-date))
         (timestamp-line (text-property-at point :agenda-timestamp-line))
         (timestamp-source-line
           (text-property-at point :agenda-timestamp-source-line))
         (timestamp-start (text-property-at point :agenda-timestamp-start))
         (timestamp-raw (text-property-at point :agenda-timestamp-raw))
         (event-p (string= (or kind "") "TIMESTAMP")))
    (cond
      ((null file) (message "No agenda entry on this line."))
      ((null date) (message "Cannot find time stamp"))
      (t
       (handler-case
           (multiple-value-bind (buffer source-point token)
               (agenda-date-prompt-target
                event-p file line heading kind date timestamp-line
                timestamp-source-line timestamp-start timestamp-raw)
             (declare (ignore source-point))
             (let ((signature (agenda-timestamp-token-signature token))
                   (old-source-date (%org-timestamp-token-date token)))
               (multiple-value-bind (new-date new-time text)
                   (agenda-read-timestamp-replacement token argument)
                 (multiple-value-bind
                       (current-buffer current-point current-token)
                     (agenda-date-prompt-target
                      event-p file line heading kind date timestamp-line
                      timestamp-source-line timestamp-start timestamp-raw)
                   (unless (and (eq buffer current-buffer)
                                (equal signature
                                       (agenda-timestamp-token-signature
                                        current-token)))
                     (error "Agenda timestamp changed while prompting"))
                   (let ((restore-key
                           (agenda-date-prompt-restore-key
                            entry-key old-source-date new-date new-time
                            event-p)))
                     (agenda-rewrite-source-timestamp
                      current-buffer current-point current-token text)
                     (setf (buffer-value agenda-buffer
                                         'lem-yath-agenda-restore-entry)
                           restore-key))
                   (agenda-start-scan agenda-buffer)
                   (message "Time stamp changed to ~a" text)))))
         (error (condition)
           (message "Agenda timestamp edit failed: ~a" condition)))))))

(defun agenda-date-shift-post-command ()
  (unless (member (and (this-command) (command-name (this-command)))
                  '(lem-yath-agenda-date-earlier
                    lem-yath-agenda-date-later
                    lem/universal-argument::universal-argument-default))
    (setf *agenda-last-date-shift-unit* nil)))

;; Effective Evil-Org agenda bindings.
(define-key *lem-yath-agenda-vi-keymap* "d d" 'lem-yath-agenda-kill-entry)
(define-key *lem-yath-agenda-vi-keymap* "c e" 'lem-yath-agenda-set-effort)
(define-key *lem-yath-agenda-vi-keymap* "H" 'lem-yath-agenda-date-earlier)
(define-key *lem-yath-agenda-vi-keymap* "L" 'lem-yath-agenda-date-later)
(define-key *lem-yath-agenda-vi-keymap* "p" 'lem-yath-agenda-date-prompt)

;; GNU aliases that do not collide with Evil-Org remain reachable in Vi state.
(dolist (keys '("C-c C-x e"))
  (define-key *lem-yath-agenda-vi-keymap* keys 'lem-yath-agenda-set-effort))
(dolist (keys '("Shift-Left" "C-c C-x Left"))
  (define-key *lem-yath-agenda-vi-keymap* keys 'lem-yath-agenda-date-earlier))
(dolist (keys '("Shift-Right" "C-c C-x Right"))
  (define-key *lem-yath-agenda-vi-keymap* keys 'lem-yath-agenda-date-later))

;; The base map is exposed in buffer-local Emacs state.
(define-key *lem-yath-agenda-mode-keymap* "C-k" 'lem-yath-agenda-kill-entry)
(define-key *lem-yath-agenda-mode-keymap* "e" 'lem-yath-agenda-set-effort)
(define-key *lem-yath-agenda-mode-keymap* ">" 'lem-yath-agenda-date-prompt)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-x e"
  'lem-yath-agenda-set-effort)
(dolist (keys '("Shift-Left" "C-c C-x Left"))
  (define-key *lem-yath-agenda-mode-keymap* keys 'lem-yath-agenda-date-earlier))
(dolist (keys '("Shift-Right" "C-c C-x Right"))
  (define-key *lem-yath-agenda-mode-keymap* keys 'lem-yath-agenda-date-later))

(remove-hook *post-command-hook* 'agenda-date-shift-post-command)
(add-hook *post-command-hook* 'agenda-date-shift-post-command)
