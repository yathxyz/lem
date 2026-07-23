;;;; Org-style date input and its terminal calendar.
;;;;
;;;; GNU Org presents a three-month calendar beside `org-read-date' and accepts
;;;; useful partial, named, and relative dates.  Lem has no calendar mode, so
;;;; this module keeps the calendar display-only and drives it from a prompt-
;;;; local keymap.  All callers still receive a validated ISO date.

(in-package :lem-yath)

(define-attribute org-date-reader-selected-attribute
  (t :foreground "#ffffff" :background "#274060" :bold t))

(define-attribute org-date-reader-today-attribute
  (t :foreground :base0D :underline t :bold t))

(defparameter *org-date-month-names*
  #("January" "February" "March" "April" "May" "June"
    "July" "August" "September" "October" "November" "December"))

(defparameter *org-date-weekday-tokens*
  '(("mon" . 0) ("monday" . 0)
    ("tue" . 1) ("tues" . 1) ("tuesday" . 1)
    ("wed" . 2) ("wednesday" . 2)
    ("thu" . 3) ("thur" . 3) ("thurs" . 3) ("thursday" . 3)
    ("fri" . 4) ("friday" . 4)
    ("sat" . 5) ("saturday" . 5)
    ("sun" . 6) ("sunday" . 6)))

(defparameter *org-date-month-tokens*
  '(("jan" . 1) ("january" . 1)
    ("feb" . 2) ("february" . 2)
    ("mar" . 3) ("march" . 3)
    ("apr" . 4) ("april" . 4)
    ("may" . 5)
    ("jun" . 6) ("june" . 6)
    ("jul" . 7) ("july" . 7)
    ("aug" . 8) ("august" . 8)
    ("sep" . 9) ("sept" . 9) ("september" . 9)
    ("oct" . 10) ("october" . 10)
    ("nov" . 11) ("november" . 11)
    ("dec" . 12) ("december" . 12)))

(defstruct org-date-reader-session
  origin-buffer
  origin-state
  selected-date
  today
  selection-rewriter
  buffer
  window
  month-count)

(defvar *org-date-reader-session* nil)

(defun org-date-normalize-input (input)
  (string-downcase
   (ppcre:regex-replace-all
    "[ \\t]+"
    (string-trim '(#\Space #\Tab #\Newline #\Return) input)
    " ")))

(defun org-date-small-year (year now-year)
  "Expand YEAR exactly like Org's rolling two-digit-year window."
  (if (>= year 100)
      year
      (let* ((century (floor now-year 100))
             (offset (- year (mod now-year 100))))
        (cond
          ((> offset 30) (+ (* (1- century) 100) year))
          ((> offset -70) (+ (* century 100) year))
          (t (+ (* (1+ century) 100) year))))))

(defun org-date-components-string (year month day)
  ;; Match Org's default `org-read-date-force-compatible-dates'.  Besides
  ;; preserving Emacs behavior, this keeps live previews of a partially typed
  ;; explicit year representable by Common Lisp universal time.
  (let* ((year (max 1970 (min 2037 year)))
         (date (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))
    (and (valid-iso-date-p date) date)))

(defun org-date-weekday-index (date)
  "Return DATE's Monday-zero weekday index."
  (multiple-value-bind (year month day) (iso-date-components date)
    (multiple-value-bind (second minute hour decoded-day decoded-month
                          decoded-year weekday)
        (decode-universal-time
         (encode-universal-time 0 0 12 day month year 0)
         0)
      (declare (ignore second minute hour decoded-day decoded-month
                       decoded-year))
      weekday)))

(defun org-date-today (&optional (now (get-universal-time)))
  (iso-date-for-time now))

(defun org-date-name-value (token table)
  (cdr (assoc token table :test #'string=)))

(defun org-date-next-month-containing-day (today day prefer-future)
  (multiple-value-bind (year month current-day) (iso-date-components today)
    (declare (ignore current-day))
    (loop :for offset :from 0 :to 24
          :for first := (iso-date-add-calendar
                         (format nil "~4,'0d-~2,'0d-01" year month)
                         offset #\m)
          :when first
            :do (multiple-value-bind (candidate-year candidate-month ignored)
                    (iso-date-components first)
                  (declare (ignore ignored))
                  (alexandria:when-let
                      ((candidate
                         (org-date-components-string
                          candidate-year candidate-month day)))
                    (when (or (not prefer-future)
                              (string>= candidate today))
                      (return candidate)))))))

(defun org-date-month-day (today month day year prefer-future)
  (multiple-value-bind (today-year ignored-month ignored-day)
      (iso-date-components today)
    (declare (ignore ignored-month ignored-day))
    (if year
        (org-date-components-string year month day)
        (or (let ((candidate
                    (org-date-components-string today-year month day)))
              (and candidate
                   (or (not prefer-future) (string>= candidate today))
                   candidate))
            (and prefer-future
                 (org-date-components-string (1+ today-year) month day))))))

(defun org-date-relative-weekday (base target direction count)
  (let* ((current (org-date-weekday-index base))
         (forward (mod (- target current) 7))
         (backward (mod (- current target) 7))
         (delta
           (if (minusp direction)
               (- (if (zerop backward) 7 backward))
               (if (zerop forward) 7 forward))))
    (iso-date-add-calendar
     base
     (+ delta (* (1- count) 7 (if (minusp direction) -1 1)))
     #\d)))

(defun org-date-relative-input (value today default-date now)
  (multiple-value-bind (match groups)
      (ppcre:scan-to-strings "^([+-]{0,2})([0-9]*)([a-z]*)$" value)
    (when match
      (let* ((sign (aref groups 0))
             (number-text (aref groups 1))
             (unit-text (aref groups 2))
             (weekday (org-date-name-value unit-text
                                           *org-date-weekday-tokens*)))
        (when (or (plusp (length sign)) weekday)
          (let* ((count (if (zerop (length number-text))
                            1
                            (parse-integer number-text)))
                 (direction (if (and (plusp (length sign))
                                     (char= (char sign (1- (length sign)))
                                            #\-))
                                -1
                                1))
                 (base (if (= (length sign) 2)
                           (or default-date today)
                           today)))
            (when (<= count 100000)
              (cond
                (weekday
                 (org-date-relative-weekday base weekday direction count))
                ((or (zerop (length unit-text))
                     (string= unit-text "d"))
                 (iso-date-add-calendar base (* direction count) #\d))
                ((member unit-text '("w" "m" "y") :test #'string=)
                 (iso-date-add-calendar
                  base (* direction count) (char unit-text 0)))
                ((string= unit-text "h")
                 (if (= (length sign) 2)
                     (multiple-value-bind (year month day)
                         (iso-date-components base)
                       (iso-date-for-time
                        (+ (encode-universal-time 0 0 12 day month year)
                           (* direction count 3600))))
                     (iso-date-for-time (+ now (* direction count 3600)))))))))))))

(defun org-date-iso-week-date (year week weekday)
  "Return ISO YEAR-WEEK-WEEKDAY (Monday=1) as an ISO date."
  (when (and (plusp year) (<= 1 week 53) (<= 1 weekday 7))
    (setf year (max 1970 (min 2037 year)))
    (let* ((january-four (format nil "~4,'0d-01-04" year))
           (week-one-monday
             (iso-date-add-calendar january-four
                                    (- (org-date-weekday-index january-four))
                                    #\d))
           (date (iso-date-add-calendar
                  week-one-monday (+ (* (1- week) 7) (1- weekday)) #\d)))
      ;; Week 53 is valid only when its Thursday still belongs to YEAR.
      (and date
           (or (< week 53)
               (multiple-value-bind (thursday-year ignored-month ignored-day)
                   (iso-date-components
                    (iso-date-add-calendar date (- 4 weekday) #\d))
                 (declare (ignore ignored-month ignored-day))
                 (= thursday-year year)))
           date))))

(defun org-date-absolute-input (value today now-year prefer-future)
  (labels ((groups (regexp)
             (nth-value 1 (ppcre:scan-to-strings regexp value)))
           (integer (text) (and text (parse-integer text))))
    (or
     (alexandria:when-let
         ((parts (groups "^([0-9]{1,4})-([0-9]{1,2})-([0-9]{1,2})$")))
       (org-date-components-string
        (org-date-small-year (integer (aref parts 0)) now-year)
        (integer (aref parts 1))
        (integer (aref parts 2))))
     (alexandria:when-let
         ((parts (groups "^([0-9]{1,2})/([0-9]{1,2})(?:/([0-9]{1,4}))?$")))
       (let ((year-text (aref parts 2)))
         (org-date-month-day
          today (integer (aref parts 0)) (integer (aref parts 1))
          (and year-text
               (org-date-small-year (integer year-text) now-year))
          prefer-future)))
     (alexandria:when-let
         ((parts (groups "^([0-9]{1,2})\\. ?([0-9]{1,2})\\.?(?: ?([0-9]{4}))?$")))
       (org-date-month-day
        today (integer (aref parts 1)) (integer (aref parts 0))
        (integer (aref parts 2)) prefer-future))
     (alexandria:when-let
         ((parts (groups "^([0-9]{4})-w([0-9]{1,2})-([1-7])$")))
       (org-date-iso-week-date
        (integer (aref parts 0)) (integer (aref parts 1))
        (integer (aref parts 2))))
     (alexandria:when-let
         ((parts (groups "^(?:([0-9]{4}) )?w([0-9]{1,2})(?: ([a-z]+|[1-7]))?$")))
       (let* ((year (or (integer (aref parts 0)) now-year))
              (weekday-token (aref parts 2))
              (weekday
                (cond
                  ((null weekday-token) 1)
                  ((and (= (length weekday-token) 1)
                        (digit-char-p (char weekday-token 0)))
                   (digit-char-p (char weekday-token 0)))
                  (t (alexandria:when-let
                         ((index (org-date-name-value
                                  weekday-token *org-date-weekday-tokens*)))
                       (1+ index))))))
         (and weekday
              (org-date-iso-week-date
               year (integer (aref parts 1)) weekday))))
     (alexandria:when-let
         ((parts (groups "^([a-z]+) ([0-9]{1,2})(?: ([0-9]{1,4}))?$")))
       (alexandria:when-let
           ((month (org-date-name-value (aref parts 0)
                                        *org-date-month-tokens*)))
         (let ((year-text (aref parts 2)))
           (org-date-month-day
            today month (integer (aref parts 1))
            (and year-text
                 (org-date-small-year (integer year-text) now-year))
            prefer-future))))
     (alexandria:when-let
         ((parts (groups "^([0-9]{1,2}) ([a-z]+)(?: ([0-9]{1,4}))?$")))
       (alexandria:when-let
           ((month (org-date-name-value (aref parts 1)
                                        *org-date-month-tokens*)))
         (let ((year-text (aref parts 2)))
           (org-date-month-day
            today month (integer (aref parts 0))
            (and year-text
                 (org-date-small-year (integer year-text) now-year))
            prefer-future))))
     (and (ppcre:scan "^[0-9]{1,2}$" value)
          (org-date-next-month-containing-day
           today (parse-integer value) prefer-future)))))

(defun org-parse-date-input
    (input &key default-date (now (get-universal-time)) (prefer-future t))
  "Parse the useful GNU Org date forms used throughout lem-yath.

This accepts validated ISO and compact numeric dates, English month/weekday
names, ISO weeks, today/tomorrow/yesterday, and Org's single/double relative
forms.  A double sign is relative to DEFAULT-DATE; a single sign is relative
to today."
  (let* ((value (org-date-normalize-input input))
         (today (org-date-today now)))
    (multiple-value-bind (now-year ignored-month ignored-day)
        (iso-date-components today)
      (declare (ignore ignored-month ignored-day))
      (cond
        ((zerop (length value)) nil)
        ((or (string= value ".") (string= value "today")) today)
        ((string= value "tomorrow")
         (iso-date-add-calendar today 1 #\d))
        ((string= value "yesterday")
         (iso-date-add-calendar today -1 #\d))
        (t
         (or (org-date-relative-input value today default-date now)
             (org-date-absolute-input value today now-year prefer-future)))))))

;; Keep the existing internal name while every date consumer moves to the
;; shared reader.  This is source compatibility inside lem-yath, not a shim for
;; old external behavior.
(defun org-parse-planning-date-input
    (input &key default-date (now (get-universal-time)))
  (org-parse-date-input input :default-date default-date :now now))

(defun org-date-center (text width)
  (let* ((text (if (> (length text) width) (subseq text 0 width) text))
         (left (floor (- width (length text)) 2)))
    (format nil "~v@{ ~}~a~v@{ ~}" left text
            (- width left (length text)))))

(defun org-date-render-month (date selected today)
  "Return eight 20-cell month lines and their highlighted spans."
  (multiple-value-bind (year month ignored-day) (iso-date-components date)
    (declare (ignore ignored-day))
    (let* ((first (format nil "~4,'0d-~2,'0d-01" year month))
           (first-column (mod (1+ (org-date-weekday-index first)) 7))
           (days (days-in-month month year))
           (lines (make-array 8 :initial-element ""))
           (spans '()))
      (setf (aref lines 0)
            (org-date-center
             (format nil "~a ~d" (aref *org-date-month-names* (1- month)) year)
             20)
            (aref lines 1) "Su Mo Tu We Th Fr Sa")
      (loop :for row :from 0 :below 6
            :do (let ((cells '()))
                  (loop :for column :from 0 :below 7
                        :for day := (+ 1 (- (+ (* row 7) column)
                                             first-column))
                        :for cell := (if (<= 1 day days)
                                        (format nil "~2d" day)
                                        "  ")
                        :do (push cell cells)
                            (when (<= 1 day days)
                              (let ((candidate
                                      (format nil "~4,'0d-~2,'0d-~2,'0d"
                                              year month day)))
                                (cond
                                  ((string= candidate selected)
                                   (push (list (+ row 2) (* column 3)
                                               (+ (* column 3) 2)
                                               'org-date-reader-selected-attribute)
                                         spans))
                                  ((string= candidate today)
                                   (push (list (+ row 2) (* column 3)
                                               (+ (* column 3) 2)
                                               'org-date-reader-today-attribute)
                                         spans)))))
                        :finally
                           (setf (aref lines (+ row 2))
                                 (format nil "~{~a~^ ~}" (nreverse cells))))))
      (values lines (nreverse spans)))))

(defun org-date-calendar-month-dates (selected count)
  (let ((offsets (if (= count 3) '(-1 0 1) '(0))))
    (mapcar
     (lambda (offset)
       (multiple-value-bind (year month ignored-day)
           (iso-date-components selected)
         (declare (ignore ignored-day))
         (iso-date-add-calendar
          (format nil "~4,'0d-~2,'0d-01" year month) offset #\m)))
     offsets)))

(defun org-date-reader-calendar-width (month-count)
  (+ (* month-count 20) (* (1- month-count) 2)))

(defun org-date-reader-render-calendar (session)
  (let* ((buffer (org-date-reader-session-buffer session))
         (count (org-date-reader-session-month-count session))
         (months (org-date-calendar-month-dates
                  (org-date-reader-session-selected-date session) count))
         (rendered (mapcar
                    (lambda (month)
                      (multiple-value-list
                       (org-date-render-month
                        month
                        (org-date-reader-session-selected-date session)
                        (org-date-reader-session-today session))))
                    months))
         (width (org-date-reader-calendar-width count))
         (help (if (= count 3)
                   "S-arrows: day/week   M-S-arrows: month   C-.: today"
                   "S-arrows   C-.: today")))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (loop :for line :from 0 :below 8
            :do (loop :for item :in rendered
                      :for firstp := t :then nil
                      :unless firstp :do (insert-string (buffer-point buffer) "  ")
                      :do (insert-string (buffer-point buffer)
                                         (aref (first item) line)))
                (insert-character (buffer-point buffer) #\Newline))
      (insert-string (buffer-point buffer) (org-date-center help width))
      (loop :for item :in rendered
            :for month-index :from 0
            :for column-offset := (* month-index 22)
            :do (dolist (span (second item))
                  (destructuring-bind (line start end attribute) span
                    (with-point ((from (buffer-start-point buffer))
                                 (to (buffer-start-point buffer)))
                      (line-offset from line)
                      (line-offset to line)
                      (character-offset from (+ column-offset start))
                      (character-offset to (+ column-offset end))
                      (put-text-property from to :attribute attribute)))))
      (buffer-start (buffer-point buffer))
      (buffer-unmark buffer))
    (when (org-date-reader-session-window session)
      (redraw-display :force t))))

(defun org-date-reader-clear-calendar (&optional
                                          (session *org-date-reader-session*))
  (when session
    (alexandria:when-let ((window (org-date-reader-session-window session)))
      (setf (org-date-reader-session-window session) nil)
      (unless (deleted-window-p window)
        (ignore-errors (delete-window window))))
    (alexandria:when-let ((buffer (org-date-reader-session-buffer session)))
      (setf (org-date-reader-session-buffer session) nil)
      (ignore-errors (delete-buffer buffer)))))

(defun org-date-reader-restore-origin-state (session)
  "Undo prompt/calendar state leakage without changing the caller's mode."
  (let ((buffer (org-date-reader-session-origin-buffer session))
        (state (org-date-reader-session-origin-state session)))
    (when (and buffer state (not (deleted-buffer-p buffer)))
      (setf (lem-vi-mode/core:buffer-state buffer) state)
      (when (eq (current-buffer) buffer)
        (setf (lem-vi-mode/core:current-state) state)))))

(defun org-date-reader-show-calendar ()
  (let ((session *org-date-reader-session*))
    (when (and session
               (>= (display-width) 24)
               (>= (display-height) 13))
      (let* ((count (if (>= (display-width) 68) 3 1))
             (width (org-date-reader-calendar-width count))
             (buffer (make-buffer nil :temporary t :enable-undo-p nil)))
        (setf (org-date-reader-session-month-count session) count
              (org-date-reader-session-buffer session) buffer)
        (setf (variable-value 'line-wrap :buffer buffer) nil)
        (org-date-reader-render-calendar session)
        (handler-case
            (setf (org-date-reader-session-window session)
                  (make-instance
                   'lem:floating-window
                   :buffer buffer
                   :x (max 0 (floor (- (display-width) width) 2))
                   :y 2 :width width :height 9
                   :use-modeline-p nil
                   :cursor-invisible t
                   :clickable nil
                   :background-color nil))
          (error (condition)
            (org-date-reader-clear-calendar session)
            (message "Could not display Org calendar: ~A" condition)))))))

(defun org-date-reader-select (date)
  (let ((session *org-date-reader-session*))
    (when (and session date (valid-iso-date-p date))
      (setf (org-date-reader-session-selected-date session) date)
      (let* ((input (lem/prompt-window::get-input-string))
             (rewriter (org-date-reader-session-selection-rewriter session))
             (replacement (if rewriter
                              (funcall rewriter date input)
                              date)))
        (lem/prompt-window::replace-prompt-input replacement))
      (when (org-date-reader-session-buffer session)
        (org-date-reader-render-calendar session)))))

(defun org-date-reader-move (amount unit)
  (alexandria:when-let*
      ((session *org-date-reader-session*)
       (date (iso-date-add-calendar
              (org-date-reader-session-selected-date session) amount unit)))
    (org-date-reader-select date)))

(define-command org-date-reader-backward-day () ()
  (org-date-reader-move -1 #\d))
(define-command org-date-reader-forward-day () ()
  (org-date-reader-move 1 #\d))
(define-command org-date-reader-backward-week () ()
  (org-date-reader-move -1 #\w))
(define-command org-date-reader-forward-week () ()
  (org-date-reader-move 1 #\w))
(define-command org-date-reader-backward-month () ()
  (org-date-reader-move -1 #\m))
(define-command org-date-reader-forward-month () ()
  (org-date-reader-move 1 #\m))
(define-command org-date-reader-backward-quarter () ()
  (org-date-reader-move -3 #\m))
(define-command org-date-reader-forward-quarter () ()
  (org-date-reader-move 3 #\m))
(define-command org-date-reader-today () ()
  (alexandria:when-let ((session *org-date-reader-session*))
    (org-date-reader-select (org-date-reader-session-today session))))

(define-command org-date-reader-dot () ()
  "Select today at an empty prompt; otherwise insert a literal dot."
  (if (zerop (length (lem/prompt-window::get-input-string)))
      (org-date-reader-today)
      (insert-character (current-point) #\.)))

(defparameter *org-date-reader-keymap*
  (let ((keymap (make-keymap :description "Org date calendar")))
    (define-key keymap "S-Left" 'org-date-reader-backward-day)
    (define-key keymap "S-Right" 'org-date-reader-forward-day)
    (define-key keymap "S-Up" 'org-date-reader-backward-week)
    (define-key keymap "S-Down" 'org-date-reader-forward-week)
    (define-key keymap "M-S-Left" 'org-date-reader-backward-month)
    (define-key keymap "M-S-Right" 'org-date-reader-forward-month)
    (define-key keymap "<" 'org-date-reader-backward-month)
    (define-key keymap ">" 'org-date-reader-forward-month)
    (define-key keymap "C-v" 'org-date-reader-backward-quarter)
    (define-key keymap "M-v" 'org-date-reader-forward-quarter)
    (define-key keymap "." 'org-date-reader-dot)
    (define-key keymap "C-." 'org-date-reader-today)
    keymap))

(defun org-read-date-input
    (prompt default-date parser &key selection-rewriter initial-value
                                  (now (get-universal-time)))
  "Read one raw date-bearing input while displaying its live interpretation.

PARSER receives the raw input and returns its interpreted ISO date or NIL.
SELECTION-REWRITER receives a calendar DATE and current input when calendar
motion should preserve caller-specific information such as a clock time."
  (let* ((today (org-date-today now))
         (session
           (make-org-date-reader-session
            :origin-buffer (current-buffer)
            :origin-state (lem-vi-mode/core:current-state)
            :selected-date (or default-date today)
            :today today
            :selection-rewriter selection-rewriter)))
    (let ((*org-date-reader-session* session)
          (*prompt-after-activate-hook*
            (cons (cons #'org-date-reader-show-calendar 0)
                  *prompt-after-activate-hook*)))
      (unwind-protect
           (prompt-for-string
            prompt
            :initial-value initial-value
            :history-symbol 'org-date-reader
            :edit-callback
            (lambda (input)
              (alexandria:when-let
                  ((date (ignore-errors (funcall parser input))))
                (setf (org-date-reader-session-selected-date session) date)
                (when (org-date-reader-session-buffer session)
                  (ignore-errors
                    (org-date-reader-render-calendar session)))))
            :special-keymap *org-date-reader-keymap*)
        (org-date-reader-clear-calendar session)
        (org-date-reader-restore-origin-state session)))))

(defun org-read-date-prompt
    (label &key default-date (now (get-universal-time)) (prefer-future t))
  "Read and validate a GNU Org-style date for LABEL."
  (let ((default (or default-date (org-date-today now))))
    (loop
      :for input :=
        (org-read-date-input
         (format nil "~a [~a]: " label default)
         default
         (lambda (value)
           (org-parse-date-input value :default-date default :now now
                                      :prefer-future prefer-future))
         :now now)
      :for date :=
        (if (zerop (length (string-trim '(#\Space #\Tab) input)))
            default
            (org-parse-date-input input :default-date default :now now
                                       :prefer-future prefer-future))
      :when date
        :do (return date)
      :do (message
           "Invalid date; try YYYY-MM-DD, Fri, Sep 15, tomorrow, or +2w"))))

;; A direct source reload must not strand a display-only calendar.
(org-date-reader-clear-calendar)
(setf *org-date-reader-session* nil)
