;;;; Org scheduling and deadline editing shared with the agenda UI.

(in-package :lem-yath)

(defvar *org-planning-now-function* #'get-universal-time
  "Function returning the current universal time; replaceable in tests.")

(defparameter *org-planning-weekday-names*
  #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))

(defparameter *org-planning-line-scanner*
  (ppcre:create-scanner "^\\s*(?:SCHEDULED|DEADLINE):")
  "Match the structural planning line immediately below an Org heading.")

(defun org-date-with-weekday (date)
  "Return DATE as an active Org timestamp with its computed weekday."
  (unless (valid-iso-date-p date)
    (error "Invalid Org date: ~s" date))
  (multiple-value-bind (year month day) (iso-date-components date)
    (multiple-value-bind (second minute hour decoded-day decoded-month
                          decoded-year weekday)
        (decode-universal-time
         (encode-universal-time 0 0 12 day month year 0)
         0)
      (declare (ignore second minute hour decoded-day decoded-month
                       decoded-year))
      (format nil "<~a ~a>" date
              (aref *org-planning-weekday-names* weekday)))))

(defun org-planning-today (&optional
                             (now (funcall *org-planning-now-function*)))
  (iso-date-for-time now))

(defun org-parse-planning-date-input
    (input &key default-date
                (now (funcall *org-planning-now-function*)))
  "Parse the bounded GNU Org date forms supported by planning commands.

Absolute ISO dates, `.`, and signed day/week/month/year offsets are accepted.
A doubled sign applies the offset to DEFAULT-DATE rather than today."
  (let ((value (string-trim '(#\Space #\Tab) input)))
    (cond
      ((valid-iso-date-p value) value)
      ((string= value ".") (org-planning-today now))
      (t
       (multiple-value-bind (start end registers register-ends)
           (ppcre:scan "^([+-]{1,2})([0-9]+)([dDwWmMyY]?)$" value)
         (declare (ignore end))
         (when start
           (let* ((sign (subseq value
                                (aref registers 0)
                                (aref register-ends 0)))
                  (magnitude
                    (parse-integer value
                                   :start (aref registers 1)
                                   :end (aref register-ends 1)))
                  (unit-start (aref registers 2))
                  (unit (if (and unit-start
                                 (< unit-start (aref register-ends 2)))
                            (char value unit-start)
                            #\d))
                  (base (if (= (length sign) 2)
                            (or default-date (org-planning-today now))
                            (org-planning-today now)))
                  (amount (if (char= (char sign 0) #\-)
                              (- magnitude)
                              magnitude)))
             (when (<= magnitude 100000)
               (ignore-errors
                 (iso-date-add-calendar base amount unit))))))))))

(defun org-planning-field-scanner (kind &optional capture-date-p)
  (ppcre:create-scanner
   (if capture-date-p
       (format nil
               "~a:\\s*<([0-9]{4}-[0-9]{2}-[0-9]{2})(?:\\s+[^>\\r\\n]*)?>"
               kind)
       (format nil "~a:\\s*<[^>\\r\\n]+>" kind))))

(defun org-planning-field-date (heading kind)
  "Return KIND's ISO date from HEADING's immediate planning line."
  (with-point ((planning heading))
    (when (and (line-offset planning 1)
               (ppcre:scan *org-planning-line-scanner*
                           (line-string planning)))
      (let ((line (line-string planning)))
        (multiple-value-bind (start end registers register-ends)
            (ppcre:scan (org-planning-field-scanner kind t) line)
          (declare (ignore start end))
          (when (and registers (aref registers 0))
            (subseq line (aref registers 0) (aref register-ends 0))))))))

(defun org-read-planning-date (heading kind label)
  "Prompt for LABEL's date, defaulting to KIND's existing date or today."
  (let ((default (or (org-planning-field-date heading kind)
                     (org-planning-today))))
    (loop
      :for input :=
        (string-trim
         '(#\Space #\Tab)
         (prompt-for-string
          (format nil "~a date [~a] (YYYY-MM-DD or relative): "
                  label default)))
      :for date :=
        (if (zerop (length input))
            default
            (org-parse-planning-date-input input :default-date default))
      :when date :return date
      :do (message
           "Invalid date; use YYYY-MM-DD, ., or +/-N[d/w/m/y]"))))

(defun org-set-planning-field (heading kind date)
  "Set KIND to DATE on HEADING's immediate Org planning line."
  (let* ((timestamp (org-date-with-weekday date))
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

(defun org-change-planning (kind label remove-p)
  (alexandria:if-let ((heading (org-current-heading-point)))
    (cond
      ((buffer-read-only-p (current-buffer))
       (editor-error "Org buffer is read-only"))
      (remove-p
       (org-clear-folds (current-buffer))
       (message (if (org-remove-planning-field heading kind)
                    "Removed ~a" "No ~a to remove")
                kind))
      (t
       (let ((date (org-read-planning-date heading kind label)))
         (org-clear-folds (current-buffer))
         (message "~a" (org-set-planning-field heading kind date)))))
    (message "No Org heading at point")))

(define-command lem-yath-org-schedule (argument) (:universal-nil)
  "Set this heading's SCHEDULED date; a prefix removes it."
  (org-change-planning "SCHEDULED" "Schedule" argument))

(define-command lem-yath-org-deadline (argument) (:universal-nil)
  "Set this heading's DEADLINE date; a prefix removes it."
  (org-change-planning "DEADLINE" "Deadline" argument))

(define-key *org-mode-keymap* "C-c C-s" 'lem-yath-org-schedule)
(define-key *org-mode-keymap* "C-c C-d" 'lem-yath-org-deadline)
