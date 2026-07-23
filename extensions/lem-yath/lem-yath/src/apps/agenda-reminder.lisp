;;;; GNU Org scheduled-delay and deadline-prewarning agenda projections.

(in-package :lem-yath)

(defparameter *agenda-deadline-warning-days* 14)
(defparameter *agenda-deadline-past-days* 10000)
(defparameter *agenda-scheduled-delay-days* 0)
(defparameter *agenda-scheduled-past-days* 10000)

(defparameter *agenda-planning-offset-scanner*
  (ppcre:create-scanner "(?:^|[ \\t])--?([0-9]+)([hdwmy])(?:[ \\t]|$)"))

(defparameter *agenda-planning-offset-unit-days*
  '((#\h . 0.041667d0) (#\d . 1d0) (#\w . 7d0)
    (#\m . 30.4d0) (#\y . 365.25d0)))

(defparameter *agenda-priority-scanner*
  (ppcre:create-scanner "(?:^|[ \\t])\\[#([A-C])\\](?:[ \\t]|$)"))

(defun agenda-planning-cookie-days (suffix)
  "Return the Org warning/delay cookie in planning SUFFIX, if present."
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan *agenda-planning-offset-scanner* (or suffix ""))
    (declare (ignore start end))
    (when (and registers (aref registers 0))
      (let* ((amount
               (parse-integer suffix
                              :start (aref registers 0)
                              :end (aref register-ends 0)))
             (unit (char suffix (aref registers 1)))
             (factor (cdr (assoc unit *agenda-planning-offset-unit-days*))))
        (floor (* amount factor))))))

(defun agenda-planning-offset-days (item)
  "Return ITEM's effective deadline warning or scheduled delay in days."
  (or (agenda-planning-cookie-days (agenda-item-planning-suffix item))
      (if (string= (agenda-item-kind item) "DEADLINE")
          *agenda-deadline-warning-days*
          *agenda-scheduled-delay-days*)))

(defun agenda-reminder-item (item today kind days)
  (let ((reminder (copy-agenda-item item)))
    (setf (agenda-item-display-date reminder) today
          (agenda-item-reminder-kind reminder) kind
          (agenda-item-reminder-days reminder) days
          (agenda-item-time reminder) nil
          (agenda-item-end-time reminder) nil)
    reminder))

(defun agenda-item-priority-value (item)
  "Return ITEM's configured GNU Org A/B/C priority value."
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan *agenda-priority-scanner* (agenda-item-text item))
    (declare (ignore start end))
    (* 1000
       (- (char-code #\C)
          (if (and registers (aref registers 0))
              (char-code
               (char (agenda-item-text item) (aref registers 0)))
              (char-code #\B))))))

(defun agenda-item-display-day-offset (item)
  (- (agenda-date-ordinal (agenda-item-effective-date item))
     (agenda-date-ordinal (agenda-item-date item))))

(defun agenda-item-urgency (item)
  "Return ITEM's stock Org urgency on its projected display day."
  (let ((priority (agenda-item-priority-value item)))
    (cond
      ((string= (or (agenda-item-kind item) "") "SCHEDULED")
       (+ priority 99 (agenda-item-display-day-offset item)))
      ((string= (or (agenda-item-kind item) "") "DEADLINE")
       (+ priority (agenda-item-display-day-offset item)))
      (t priority))))

(defun agenda-item-stock-before-p (a b)
  "Compare A and B with the configured stock agenda day strategies."
  (let ((a-time (agenda-item-time-value a))
        (b-time (agenda-item-time-value b)))
    (cond
      ((and a-time b-time) (< a-time b-time))
      (a-time t)
      (b-time nil)
      (t (> (agenda-item-urgency a) (agenda-item-urgency b))))))

(defun agenda-sort-stock-day-items (items)
  "Return ITEMS in stock time-up, urgency-down, stable source order."
  (stable-sort items #'agenda-item-stock-before-p))

(defun agenda-planning-reminder (item today offset-days)
  "Return ITEM's GNU Org reminder projection for TODAY, if visible."
  (unless (done-keyword-p (agenda-item-keyword item))
    (let ((date (agenda-item-date item)))
      (cond
        ((string= (agenda-item-kind item) "SCHEDULED")
         (let ((days (- (agenda-date-ordinal today)
                        (agenda-date-ordinal date))))
           (when (and (plusp days)
                      (>= days offset-days)
                      (<= days *agenda-scheduled-past-days*))
             (agenda-reminder-item item today :scheduled-past days))))
        ((string= (agenda-item-kind item) "DEADLINE")
         (let ((days (- (agenda-date-ordinal date)
                        (agenda-date-ordinal today))))
           (cond
             ((and (plusp days) (<= days offset-days))
              (agenda-reminder-item item today :deadline-upcoming days))
             ((and (minusp days)
                   (<= (- days) *agenda-deadline-past-days*))
              (agenda-reminder-item
               item today :deadline-overdue (- days))))))))))

(defun agenda-project-planning-reminders (items now)
  "Project GNU Org planning reminders without mutating parsed ITEMS."
  (let ((today (today-iso now))
        (projected '()))
    (dolist (item items (nreverse projected))
      (if (agenda-planning-item-p item)
          (let ((offset-days (agenda-planning-offset-days item)))
            ;; A scheduled delay suppresses the base occurrence completely;
            ;; Org only forwards it to today's compilation after the delay.
            (unless (and (string= (agenda-item-kind item) "SCHEDULED")
                         (plusp offset-days))
              (push item projected))
            (alexandria:when-let
                ((reminder (agenda-planning-reminder item today offset-days)))
              (push reminder projected)))
          (push item projected)))))

(defun agenda-reminder-planning-restore-key
    (file line heading preferred-kind default-key)
  "Return a visible row key after editing a delayed planning field."
  (if (not (string= preferred-kind "SCHEDULED"))
      default-key
      (multiple-value-bind (date suffix)
          (org-planning-field-components heading preferred-kind)
        (let ((delay (and date (agenda-planning-cookie-days suffix))))
          (if (not (and delay (plusp delay)))
              default-key
              (let* ((today (today-iso))
                     (elapsed (- (agenda-date-ordinal today)
                                 (agenda-date-ordinal date))))
                (cond
                  ((and (plusp elapsed)
                        (>= elapsed delay)
                        (<= elapsed *agenda-scheduled-past-days*))
                   (list file line preferred-kind date nil nil
                         :scheduled-past))
                  (t
                   (let ((deadline
                           (org-planning-field-date heading "DEADLINE")))
                     (and deadline
                          (list file line "DEADLINE" deadline nil nil nil)))))))))))

(setf *agenda-item-projection-function* 'agenda-project-planning-reminders)
(setf *agenda-planning-restore-key-function*
      'agenda-reminder-planning-restore-key)
(setf *agenda-day-sort-function* 'agenda-sort-stock-day-items)
