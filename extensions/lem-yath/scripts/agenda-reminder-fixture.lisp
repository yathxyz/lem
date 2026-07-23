(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0)))

(defun agenda-reminder-test-report-path ()
  (or (uiop:getenv "LEM_YATH_AGENDA_REMINDER_REPORT")
      (error "LEM_YATH_AGENDA_REMINDER_REPORT is unset")))

(defun agenda-reminder-test-log (format-control &rest arguments)
  (with-open-file (stream (agenda-reminder-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream format-control arguments)
    (terpri stream)
    (finish-output stream)))

(defun agenda-reminder-test-section (line current)
  (cond
    ((string= line "Overdue") "OVERDUE")
    ((string= line "Today") "TODAY")
    ((alexandria:starts-with-subseq "Upcoming (" line) "UPCOMING")
    ((string= line "TODOs") "TODOS")
    (t current)))

(define-command lem-yath-test-agenda-reminder-report () ()
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop :with section := "NONE"
          :with count := 0
          :do (line-start point)
              (let ((text (line-string point)))
                (setf section (agenda-reminder-test-section text section))
                (when (text-property-at point :agenda-file)
                  (incf count)
                  (agenda-reminder-test-log
                   (concatenate
                    'string
                    "ROW section=~a source=~a display=~a kind=~a "
                    "reminder=~a days=~a time=~a end=~a text=~s")
                   section
                   (or (text-property-at point :agenda-date) "none")
                   (or (text-property-at point :agenda-display-date) "none")
                   (or (text-property-at point :agenda-kind) "none")
                   (or (text-property-at point :agenda-reminder-kind) "none")
                   (or (text-property-at point :agenda-reminder-days) "none")
                   (or (text-property-at point :agenda-time) "none")
                   (or (text-property-at point :agenda-end-time) "none")
                   text)))
          :unless (line-offset point 1)
            :do (agenda-reminder-test-log "DONE rows=~d" count)
                (return))))

(define-command lem-yath-test-agenda-goto-past-reminder () ()
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (and (eq (text-property-at point :agenda-reminder-kind)
                     :scheduled-past)
                 (search "Scheduled past sentinel" (line-string point)))
        (move-point (current-point) point)
        (return-from lem-yath-test-agenda-goto-past-reminder))
      (unless (line-offset point 1)
        (error "Scheduled past reminder row is missing")))))

(define-command lem-yath-test-agenda-reminder-point-report () ()
  (agenda-reminder-test-log
   "POINT source=~a display=~a reminder=~a days=~a text=~s"
   (or (text-property-at (current-point) :agenda-date) "none")
   (or (text-property-at (current-point) :agenda-display-date) "none")
   (or (text-property-at (current-point) :agenda-reminder-kind) "none")
   (or (text-property-at (current-point) :agenda-reminder-days) "none")
   (line-string (current-point))))

(define-key *lem-yath-agenda-vi-keymap* "F4"
  'lem-yath-test-agenda-reminder-report)
(define-key *lem-yath-agenda-vi-keymap* "F5"
  'lem-yath-test-agenda-goto-past-reminder)
(define-key *lem-yath-agenda-vi-keymap* "F6"
  'lem-yath-test-agenda-reminder-point-report)
