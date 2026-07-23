;;;; Standard Emacs diary entry creation from dated agenda rows.

(in-package :lem-yath)

(defvar *agenda-diary-file* nil)

(defun agenda-diary-file ()
  (or *agenda-diary-file*
      (merge-pathnames ".emacs.d/diary" (user-homedir-pathname))))

(defun agenda-diary-date-at-point (&optional (point (current-point)))
  (or (agenda-view-date-at-point point)
      (error "Don't know which date to use for diary entry")))

(defun agenda-diary-date-components (date)
  (multiple-value-bind (year month day) (agenda-date-components date)
    (values year month day
            (subseq (aref *org-date-month-names* (1- month)) 0 3)
            (aref *agenda-view-weekdays* (org-date-weekday-index date)))))

(defun agenda-diary-entry-prefix (kind date &optional other-date interval)
  (multiple-value-bind (year month day month-name weekday)
      (agenda-diary-date-components date)
    (ecase kind
      (:day (format nil "~a ~d, ~d" month-name day year))
      (:weekly weekday)
      (:monthly (format nil "* ~d" day))
      (:yearly (format nil "~a ~d" month-name day))
      (:anniversary
       (format nil "%%(diary-anniversary ~d ~d ~d)" month day year))
      (:cyclic
       (format nil "%%(diary-cyclic ~d ~d ~d ~d)"
               interval month day year))
      (:block
       (unless other-date
         (error "No mark set in this buffer"))
       (let ((start date)
             (end other-date))
         (when (> (agenda-date-ordinal start) (agenda-date-ordinal end))
           (rotatef start end))
         (multiple-value-bind (end-year end-month end-day)
             (agenda-date-components end)
           (multiple-value-bind (start-year start-month start-day)
               (agenda-date-components start)
             (format nil "%%(diary-block ~d ~d ~d ~d ~d ~d)"
                     start-month start-day start-year
                     end-month end-day end-year))))))))

(defun agenda-diary-local-variables-offset (contents)
  "Return the offset of a trailing Local Variables block, when present."
  (let ((start (max 0 (- (length contents) 3000))))
    (nth-value 0
               (ppcre:scan "(?m)^Local Variables:" contents :start start))))

(defun agenda-diary-entry-text (prefix nonmarking-p leading-newline-p)
  (format nil "~:[~;~%~]~:[~;&~]~a "
          leading-newline-p nonmarking-p prefix))

(defun agenda-diary-open-entry (prefix nonmarking-p)
  "Open the configured diary and insert PREFIX without saving it."
  (let* ((path (agenda-diary-file))
         (buffer (find-file-buffer path)))
    (when (buffer-read-only-p buffer)
      (error "Diary file is read-only: ~a" path))
    (let* ((contents
             (points-to-string (buffer-start-point buffer)
                               (buffer-end-point buffer)))
           (local-offset (agenda-diary-local-variables-offset contents))
           (offset (or local-offset (length contents)))
           (leading-newline-p
             (and (plusp offset)
                  (not (char= (char contents (1- offset)) #\Newline))))
           (entry
             (agenda-diary-entry-text
              prefix nonmarking-p leading-newline-p))
           (text (if local-offset
                     (concatenate 'string entry (string #\Newline))
                     entry)))
      (with-point ((point (buffer-start-point buffer)))
        (character-offset point offset)
        (insert-string point text))
      (switch-to-window (pop-to-buffer buffer :split-action :sensibly))
      (move-point (buffer-point buffer) (buffer-start-point buffer))
      (character-offset (buffer-point buffer) (+ offset (length entry))))
    buffer))

(defun agenda-diary-mark-date ()
  (let ((buffer (current-buffer)))
    (and (buffer-mark-p buffer)
         (agenda-view-date-at-point (buffer-mark buffer)))))

(define-command lem-yath-agenda-diary-entry (argument) (:universal-nil)
  "Insert a standard Emacs diary entry for the agenda date at point."
  (let* ((date (agenda-diary-date-at-point))
         (character
           (prompt-for-character
            (concatenate
             'string
             "Diary entry: [d]ay [w]eekly [m]onthly [y]early "
             "[a]nniversary [b]lock [c]yclic")))
         (kind (case character
                 (#\d :day) (#\w :weekly) (#\m :monthly)
                 (#\y :yearly) (#\a :anniversary)
                 (#\b :block) (#\c :cyclic))))
    (if (null kind)
        (message "No command associated with <~a>" character)
        (let ((interval
                (and (eq kind :cyclic)
                     (prompt-for-integer "Repeat every how many days: "
                                         :initial-value 1))))
          (if (and interval (not (plusp interval)))
              (message "Repeat interval must be positive")
              (handler-case
                  (agenda-diary-open-entry
                   (agenda-diary-entry-prefix
                    kind date (and (eq kind :block)
                                   (agenda-diary-mark-date))
                    interval)
                   (not (null argument)))
                (error (condition)
                  (message "Diary entry failed: ~a" condition))))))))

(define-key *lem-yath-agenda-vi-keymap* "i" 'lem-yath-agenda-diary-entry)
(define-key *lem-yath-agenda-mode-keymap* "i" 'lem-yath-agenda-diary-entry)
