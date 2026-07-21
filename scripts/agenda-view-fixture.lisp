(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 17 7 2026 0)))

(defun agenda-view-test-log (control &rest arguments)
  (with-open-file (stream (or (uiop:getenv "LEM_YATH_AGENDA_VIEW_REPORT")
                              (error "Agenda view report path is unset"))
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun agenda-view-test-command-name (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(defun agenda-view-test-date-rows ()
  (let ((section-date nil)
        (rows '()))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (text-property-at point :agenda-section-key)
          (setf section-date (text-property-at point :agenda-view-date)))
        (when (and section-date (agenda-source-row-p point))
          (push (format nil "~a|~a" section-date (line-string point)) rows))
        (unless (line-offset point 1) (return))))
    (nreverse rows)))

(defun agenda-view-test-date-header-count ()
  (let ((count 0))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (text-property-at point :agenda-view-date) (incf count))
        (unless (line-offset point 1) (return))))
    count))

(defun agenda-view-test-entry-count ()
  (let ((count 0))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (agenda-source-row-p point) (incf count))
        (unless (line-offset point 1) (return))))
    count))

(defun agenda-view-test-time-token (time)
  (let ((colon (position #\: time)))
    (format nil "~2,'0d~2,'0d"
            (parse-integer time :end colon)
            (parse-integer time :start (1+ colon)))))

(defun agenda-view-test-timeline ()
  (let ((tokens '())
        (target-date nil))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (text-property-at point :agenda-grid-kind)
          (setf target-date
                (text-property-at point :agenda-display-date))
          (return))
        (unless (line-offset point 1) (return))))
    (unless target-date
      (setf target-date (agenda-view-date-at-point)))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (let ((grid-kind (text-property-at point :agenda-grid-kind))
              (grid-time (text-property-at point :agenda-grid-time))
              (time (text-property-at point :agenda-time))
              (end-time (text-property-at point :agenda-end-time)))
          (cond
            (grid-kind
             (push (format nil "~a-~4,'0d"
                           (if (eq grid-kind :line) "grid" "now")
                           grid-time)
                   tokens))
            ((and time
                  (or (null target-date)
                      (equal target-date
                             (text-property-at point
                                               :agenda-display-date))))
             (push (format nil "item-~a~@[-~a~]"
                           (agenda-view-test-time-token time)
                           (and end-time
                                (agenda-view-test-time-token end-time)))
                   tokens))))
        (unless (line-offset point 1) (return))))
    (nreverse tokens)))

(defun agenda-view-test-matching-dates (needle)
  (let ((dates '()))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (and (agenda-source-row-p point)
                   (search needle (line-string point)))
          (push (text-property-at point :agenda-display-date) dates))
        (unless (line-offset point 1) (return))))
    (nreverse dates)))

(defun agenda-view-test-log-anniversary (label)
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (text-property-at point :agenda-diary-file)
        (agenda-view-test-log
         "ANNIVERSARY ~a date=~a category=~a file=yes text=~s"
         label
         (text-property-at point :agenda-display-date)
         (text-property-at point :agenda-category)
         (line-string point))
        (return-from agenda-view-test-log-anniversary))
      (unless (line-offset point 1) (return)))
    (agenda-view-test-log "ANNIVERSARY ~a missing" label)))

(defun agenda-view-test-log-state (label)
  (let* ((state (agenda-view-state))
         (clock (buffer-value (current-buffer)
                              'lem-yath-agenda-cached-clock-report)))
    (multiple-value-bind (start end) (agenda-view-range)
      (agenda-view-test-log
       "STATE ~a span=~(~a~) start=~a end=~a header=~s point-date=~a headers=~d rows=~d date-rows=~s clock=~a..~a/~a"
       label
       (agenda-view-state-span state)
       start end
       (line-string (buffer-start-point (current-buffer)))
       (agenda-view-date-at-point)
       (agenda-view-test-date-header-count)
       (agenda-view-test-entry-count)
       (agenda-view-test-date-rows)
       (and clock (agenda-clock-report-start-date clock))
       (and clock (agenda-clock-report-end-date clock))
       (and clock (agenda-clock-report-minutes clock))))
    (agenda-view-test-log
     "TIMELINE ~a ~{~a~^,~}" label (agenda-view-test-timeline))
    (agenda-view-test-log
     "HOURLY ~a dates=~{~a~^,~}"
     label (agenda-view-test-matching-dates "Hourly repeat sentinel"))
    (agenda-view-test-log-anniversary label)))

(defmacro define-agenda-view-test-log-command (name label)
  `(define-command ,name () () (agenda-view-test-log-state ,label)))

(define-agenda-view-test-log-command lem-yath-test-view-initial "initial")
(define-agenda-view-test-log-command lem-yath-test-view-week "week")
(define-agenda-view-test-log-command lem-yath-test-view-fortnight "fortnight")
(define-agenda-view-test-log-command lem-yath-test-view-later "later")
(define-agenda-view-test-log-command lem-yath-test-view-earlier "earlier")
(define-agenda-view-test-log-command lem-yath-test-view-today "today")
(define-agenda-view-test-log-command lem-yath-test-view-goto "goto")
(define-agenda-view-test-log-command lem-yath-test-view-month "month")
(define-agenda-view-test-log-command lem-yath-test-view-day "day")
(define-agenda-view-test-log-command lem-yath-test-view-day-prefix "day-prefix")
(define-agenda-view-test-log-command lem-yath-test-view-year "year")
(define-agenda-view-test-log-command lem-yath-test-view-summary "summary")
(define-agenda-view-test-log-command lem-yath-test-view-clock "clock")

(define-command lem-yath-test-view-normal-keys () ()
  (agenda-view-test-log
   "KEYS normal earlier=~a later=~a dispatch=~a today=~a goto=~a refresh=~a refresh-all=~a"
   (agenda-view-test-command-name "[ [")
   (agenda-view-test-command-name "] ]")
   (agenda-view-test-command-name "g D")
   (agenda-view-test-command-name ".")
   (agenda-view-test-command-name "g d")
   (agenda-view-test-command-name "g r")
   (agenda-view-test-command-name "g R")))

(define-command lem-yath-test-view-emacs-keys () ()
  (agenda-view-test-log
   "KEYS emacs g=~a dispatch=~a"
   (agenda-view-test-command-name "g")
   (agenda-view-test-command-name "g D")))

(define-command lem-yath-test-view-goto-grid () ()
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (text-property-at point :agenda-grid-kind)
        (move-point (current-point) point)
        (return-from lem-yath-test-view-goto-grid))
      (unless (line-offset point 1)
        (error "Agenda grid row is missing")))))

(defun agenda-view-test-log-point (label)
  (agenda-view-test-log
   "POINT ~a grid=~a file=~a time=~a end=~a text=~s"
   label
   (text-property-at (current-point) :agenda-grid-kind)
   (and (text-property-at (current-point) :agenda-file) "yes")
   (text-property-at (current-point) :agenda-time)
   (text-property-at (current-point) :agenda-end-time)
   (line-string (current-point))))

(define-command lem-yath-test-view-point-first () ()
  (agenda-view-test-log-point "first"))

(define-command lem-yath-test-view-point-second () ()
  (agenda-view-test-log-point "second"))

(define-command lem-yath-test-view-point-third () ()
  (agenda-view-test-log-point "third"))

(define-command lem-yath-test-view-goto-anniversary () ()
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (text-property-at point :agenda-diary-file)
        (move-point (current-point) point)
        (return-from lem-yath-test-view-goto-anniversary))
      (unless (line-offset point 1)
        (error "Anniversary row is missing")))))

(define-command lem-yath-test-view-anniversary-source () ()
  (agenda-view-test-log
   "ANNIVERSARY-SOURCE file=~a line=~d text=~s"
   (buffer-filename (current-buffer))
   (line-number-at-point (current-point))
   (line-string (current-point)))
  (switch-to-buffer (get-buffer *agenda-buffer-name*)))

(let ((keymap *lem-yath-agenda-mode-keymap*))
  (define-key keymap "C-c z 0" 'lem-yath-test-view-initial)
  (define-key keymap "C-c z 1" 'lem-yath-test-view-week)
  (define-key keymap "C-c z f" 'lem-yath-test-view-fortnight)
  (define-key keymap "C-c z 2" 'lem-yath-test-view-later)
  (define-key keymap "C-c z 3" 'lem-yath-test-view-earlier)
  (define-key keymap "C-c z 4" 'lem-yath-test-view-today)
  (define-key keymap "C-c z 5" 'lem-yath-test-view-goto)
  (define-key keymap "C-c z 6" 'lem-yath-test-view-month)
  (define-key keymap "C-c z 7" 'lem-yath-test-view-day)
  (define-key keymap "C-c z 8" 'lem-yath-test-view-day-prefix)
  (define-key keymap "C-c z 9" 'lem-yath-test-view-year)
  (define-key keymap "C-c z s" 'lem-yath-test-view-summary)
  (define-key keymap "C-c z c" 'lem-yath-test-view-clock)
  (define-key keymap "C-c z n" 'lem-yath-test-view-normal-keys)
  (define-key keymap "C-c z e" 'lem-yath-test-view-emacs-keys)
  (define-key keymap "C-c z g" 'lem-yath-test-view-goto-grid)
  (define-key keymap "C-c z p" 'lem-yath-test-view-point-first)
  (define-key keymap "C-c z P" 'lem-yath-test-view-point-second)
  (define-key keymap "C-c z q" 'lem-yath-test-view-point-third))

(define-key *lem-yath-agenda-mode-keymap* "C-c z a"
  'lem-yath-test-view-goto-anniversary)
(define-key *global-keymap* "C-c z v"
  'lem-yath-test-view-anniversary-source)
