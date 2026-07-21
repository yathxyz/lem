;;;; GNU Org agenda span selection and Evil-Org date navigation.

(in-package :lem-yath)

(defstruct (agenda-view-state (:constructor make-agenda-view-state))
  (span :summary)
  start-date
  pending-date)

(defparameter *agenda-view-weekdays*
  #("Monday" "Tuesday" "Wednesday" "Thursday"
    "Friday" "Saturday" "Sunday"))

(defun agenda-view-state (&optional (buffer (current-buffer)))
  (or (buffer-value buffer 'lem-yath-agenda-view-state)
      (setf (buffer-value buffer 'lem-yath-agenda-view-state)
            (make-agenda-view-state
             :start-date (today-iso (funcall *agenda-now-function*))))))

(defun agenda-view-days-in-month (date)
  (multiple-value-bind (year month day) (agenda-date-components date)
    (declare (ignore day))
    (let* ((first (format nil "~4,'0d-~2,'0d-01" year month))
           (next (agenda-add-calendar first 1 #\m)))
      (- (agenda-date-ordinal next) (agenda-date-ordinal first)))))

(defun agenda-view-days-in-year (date)
  (multiple-value-bind (year month day) (agenda-date-components date)
    (declare (ignore month day))
    (- (agenda-date-ordinal (format nil "~4,'0d-01-01" (1+ year)))
       (agenda-date-ordinal (format nil "~4,'0d-01-01" year)))))

(defun agenda-view-canonical-start (span date)
  "Return GNU Org's canonical starting date for SPAN around DATE."
  (ecase span
    (:summary date)
    (:day date)
    ((:week :fortnight)
     (agenda-add-calendar date (- (org-date-weekday-index date)) #\d))
    (:month
     (multiple-value-bind (year month day) (agenda-date-components date)
       (declare (ignore day))
       (format nil "~4,'0d-~2,'0d-01" year month)))
    (:year
     (multiple-value-bind (year month day) (agenda-date-components date)
       (declare (ignore month day))
       (format nil "~4,'0d-01-01" year)))))

(defun agenda-view-range (&optional (buffer (current-buffer))
                                   (now (funcall *agenda-now-function*)))
  "Return BUFFER's inclusive GNU-style agenda range."
  (let* ((state (agenda-view-state buffer))
         (span (agenda-view-state-span state))
         (start (or (agenda-view-state-start-date state) (today-iso now)))
         (days
           (ecase span
             (:summary (1+ *agenda-upcoming-days*))
             (:day 1)
             (:week 7)
             (:fortnight 14)
             (:month (agenda-view-days-in-month start))
             (:year (agenda-view-days-in-year start)))))
    (values start (agenda-add-calendar start (1- days) #\d))))

(defun agenda-view-header-label (buffer now)
  (let* ((state (agenda-view-state buffer))
         (span (agenda-view-state-span state)))
    (multiple-value-bind (start end) (agenda-view-range buffer now)
      (ecase span
        (:summary start)
        (:day (format nil "Day ~a" start))
        (:week (format nil "Week ~a..~a" start end))
        (:fortnight (format nil "Fortnight ~a..~a" start end))
        (:month (format nil "Month ~a..~a" start end))
        (:year (format nil "Year ~a..~a" start end))))))

(defun agenda-view-sort-items (items)
  (agenda-sort-dated-items items))

(defun agenda-view-date-title (date)
  (format nil "~a  ~a"
          (aref *agenda-view-weekdays* (org-date-weekday-index date))
          date))

(defun agenda-view-span-sections (items start end)
  "Group ITEMS into overdue, one section per displayed date, and TODOs."
  (let ((by-date (make-hash-table :test #'equal))
        (overdue '())
        (todos '()))
    (dolist (item items)
      (let ((date (agenda-item-effective-date item))
            (keyword (agenda-item-keyword item)))
        (cond
          ((agenda-item-event-p item)
           (dolist (occurrence (agenda-event-occurrences item start end))
             (push occurrence
                   (gethash (agenda-item-date occurrence) by-date))))
          ((and date (done-keyword-p keyword) (agenda-planning-item-p item))
           (when (and (string<= start date) (string<= date end))
             (push item (gethash date by-date))))
          ((and date (not (done-keyword-p keyword)))
           (cond
             ((string< date start) (push item overdue))
             ((string<= date end) (push item (gethash date by-date)))))
          ((and (null date) (open-keyword-p keyword))
           (push item todos)))))
    (let ((sections
            (list
             (make-agenda-section
              :key :overdue :title "Overdue"
              :items (agenda-view-sort-items (nreverse overdue))))))
      (loop :for date := start :then (agenda-add-calendar date 1 #\d)
            :do (setf sections
                      (nconc
                       sections
                       (list
                        (make-agenda-section
                         :key :date
                         :title (agenda-view-date-title date)
                         :date date
                         :items
                         (agenda-view-sort-items
                          (nreverse (gethash date by-date)))))))
            :until (string= date end))
      (nconc sections
             (list
              (make-agenda-section
               :key :todos :title "TODOs" :items (nreverse todos)))))))

(defun agenda-view-sections (buffer items now)
  (if (eq (agenda-view-state-span (agenda-view-state buffer)) :summary)
      (multiple-value-bind (start end) (agenda-view-range buffer now)
        (agenda-default-sections items now start end))
      (multiple-value-bind (start end) (agenda-view-range buffer now)
        (agenda-view-span-sections items start end))))

(defun agenda-view-date-at-point (&optional (point (current-point)))
  (or (text-property-at point :agenda-view-date)
      (text-property-at point :agenda-display-date)
      (text-property-at point :agenda-date)))

(defun agenda-view-goto-rendered-date (buffer date)
  "Move to DATE's rendered date header, not an overdue entry with that date."
  (with-point ((point (buffer-start-point buffer)))
    (loop
      (when (equal date (text-property-at point :agenda-view-date))
        (move-point (buffer-point buffer) point)
        (return t))
      (unless (line-offset point 1) (return nil)))))

(defun agenda-view-post-render (buffer)
  (let* ((state (agenda-view-state buffer))
         (date (agenda-view-state-pending-date state)))
    (when date
      (setf (agenda-view-state-pending-date state) nil)
      (agenda-view-goto-rendered-date buffer date))))

(defun agenda-view-current-date (state)
  (or (agenda-view-date-at-point)
      (agenda-view-state-start-date state)
      (today-iso (funcall *agenda-now-function*))))

(defun agenda-view-start-refresh (state pending-date)
  (setf (agenda-view-state-pending-date state) pending-date)
  (agenda-start-scan (current-buffer)))

(defun agenda-view-change-span (span)
  (let* ((state (agenda-view-state))
         (date (agenda-view-current-date state))
         (start (agenda-view-canonical-start span date)))
    (setf (agenda-view-state-span state) span
          (agenda-view-state-start-date state) start)
    (agenda-view-start-refresh state date)
    (message "Switched to ~(~a~) view" span)))

(define-command lem-yath-agenda-view-mode-dispatch () ()
  "Dispatch the configured GNU Org agenda span views."
  (let ((character
          (prompt-for-character
           "View: [d]ay [w]eek for[t]night [m]onth [y]ear [SPC]reset [q]uit: ")))
    (case character
      (#\d (agenda-view-change-span :day))
      (#\w (agenda-view-change-span :week))
      (#\t (agenda-view-change-span :fortnight))
      (#\m (agenda-view-change-span :month))
      (#\y
       (when (prompt-for-y-or-n-p
              "Are you sure you want to compute the agenda for an entire year?")
         (agenda-view-change-span :year)))
      (#\Space (agenda-view-change-span :summary))
      ((#\q #\Q #\Escape) (message "Abort"))
      (otherwise (message "Invalid agenda view key: ~a" character)))))

(defun agenda-view-prefix-count (argument)
  (typecase argument
    (integer argument)
    (null 1)
    (t 4)))

(defun agenda-view-shift-date (date span count)
  (ecase span
    (:summary (agenda-add-calendar date (* 8 count) #\d))
    (:day (agenda-add-calendar date count #\d))
    (:week (agenda-add-calendar date (* 7 count) #\d))
    (:fortnight (agenda-add-calendar date (* 14 count) #\d))
    (:month (agenda-add-calendar date count #\m))
    (:year (agenda-add-calendar date count #\y))))

(defun agenda-view-move (direction argument)
  (let* ((state (agenda-view-state))
         (span (agenda-view-state-span state))
         (count (* direction (agenda-view-prefix-count argument)))
         (point-date (agenda-view-current-date state))
         (start (agenda-view-shift-date
                 (agenda-view-state-start-date state) span count))
         (destination (agenda-view-shift-date point-date span count)))
    (setf (agenda-view-state-start-date state) start)
    (agenda-view-start-refresh state destination)))

(define-command lem-yath-agenda-earlier (argument) (:universal-nil)
  "Move backward by the current agenda span, like Evil-Org [[."
  (agenda-view-move -1 argument))

(define-command lem-yath-agenda-later (argument) (:universal-nil)
  "Move forward by the current agenda span, like Evil-Org ]]."
  (agenda-view-move 1 argument))

(define-command lem-yath-agenda-goto-date () ()
  "Read a date, rebuild the current span from it, and select that date."
  (let* ((state (agenda-view-state))
         (default (agenda-view-current-date state)))
    (multiple-value-bind (date selected-p)
        (agenda-read-date "Agenda date" default)
      (when selected-p
        (setf (agenda-view-state-start-date state) date)
        (agenda-view-start-refresh state date)))))

(define-command lem-yath-agenda-goto-today () ()
  "Select today, rebuilding the current view when it is outside the span."
  (let* ((state (agenda-view-state))
         (today (today-iso (funcall *agenda-now-function*))))
    (unless (agenda-view-goto-rendered-date (current-buffer) today)
      (setf (agenda-view-state-start-date state)
            (agenda-view-canonical-start
             (agenda-view-state-span state) today))
      (agenda-view-start-refresh state today))))

(setf *agenda-sections-function* #'agenda-view-sections
      *agenda-header-label-function* #'agenda-view-header-label
      *agenda-date-range-function* #'agenda-view-range)

(setf *agenda-post-render-functions*
      (cons 'agenda-view-post-render
            (remove 'agenda-view-post-render
                    *agenda-post-render-functions*)))

;; Effective Evil-Org agenda bindings.  `g' is deliberately a prefix: refresh
;; is `gr'/`gR`, matching the configured package rather than the old Lem shim.
(define-key *lem-yath-agenda-vi-keymap* "[ [" 'lem-yath-agenda-earlier)
(define-key *lem-yath-agenda-vi-keymap* "] ]" 'lem-yath-agenda-later)
(define-key *lem-yath-agenda-vi-keymap* "g D"
  'lem-yath-agenda-view-mode-dispatch)
(define-key *lem-yath-agenda-vi-keymap* "." 'lem-yath-agenda-goto-today)
(define-key *lem-yath-agenda-vi-keymap* "g d" 'lem-yath-agenda-goto-date)
