;;;; lem-yath apps/agenda -- a bounded org-agenda + org-super-agenda view.
;;;;
;;;; The live Emacs configuration gives org-agenda three directory entries:
;;;; $WORKDIR, $PUBLIC_ORG_DIR, and $PUBLIC_ORG_DIR/mcp.  Org expands directory
;;;; entries to their top-level *.org files, not recursive note trees.  The
;;;; native Org mode owns the shared TODO vocabulary; this view renders those
;;;; exact sources as Overdue / Today / Upcoming / TODOs.  Scanning stays off
;;;; the editor thread, with per-buffer generations preventing stale refreshes
;;;; from overwriting newer results.

(in-package :lem-yath)

(defparameter *agenda-buffer-name* "*lem-yath-agenda*"
  "Name of the read-only agenda buffer.")

(defparameter *agenda-upcoming-days* 7
  "How many days ahead the \"Upcoming\" section reaches.")

(defparameter *agenda-todo-keywords* *org-todo-keywords*
  "Heading keywords recognised by the parser, mirroring the Emacs config.")

(defparameter *agenda-open-keywords* *org-open-todo-keywords*
  "Keywords for the unscheduled \"TODOs\" section.")

(defparameter *agenda-done-keywords* *org-done-todo-keywords*
  "Keywords excluded from the dated sections.")

(defvar *agenda-now-function* #'get-universal-time
  "Function returning the current universal time; replaceable in tests.")

;;; --- parsing -------------------------------------------------------------

(defstruct (agenda-item (:constructor make-agenda-item))
  "One parsed heading: its TODO keyword, text, source file/line and date."
  keyword text file line heading date kind event-p end-date repeater time
  occurrence-index occurrence-count)

(defparameter *heading-scanner*
  (ppcre:create-scanner
   (format nil "^\\*+\\s+(?:(~{~a~^|~})\\s+)?(.*)$"
           *org-todo-keywords*))
  "Matches an org heading, optionally capturing a leading TODO keyword.")

(defvar *planning-scanner*
  (ppcre:create-scanner
   "(SCHEDULED|DEADLINE):\\s*<(\\d{4}-\\d{2}-\\d{2})")
  "Matches a SCHEDULED/DEADLINE planning entry and its <YYYY-MM-DD ...> date.")

(defvar *planning-line-scanner*
  (ppcre:create-scanner "^\\s*(?:SCHEDULED|DEADLINE):")
  "Matches an Org planning line immediately below a heading.")

(defvar *active-timestamp-scanner*
  (ppcre:create-scanner "<([^>\\r\\n]+)>(?:--<([^>\\r\\n]+)>)?")
  "Matches one active Org timestamp or timestamp range.")

(defvar *timestamp-date-scanner*
  (ppcre:create-scanner "^(\\d{4}-\\d{2}-\\d{2})(?:\\s|$)")
  "Extracts the date at the start of active timestamp contents.")

(defvar *timestamp-time-scanner*
  (ppcre:create-scanner
   "(?:^|\\s)([0-9]{1,2}:[0-9]{2})(?:-[0-9]{1,2}:[0-9]{2})?(?:\\s|$)")
  "Extracts an optional start time from active timestamp contents.")

(defvar *timestamp-repeater-scanner*
  (ppcre:create-scanner "(?:^|\\s)([.+]*\\+[0-9]+[dDwWmMyY])(?:\\s|$)")
  "Extracts a supported Org repeater cookie.")

(defun agenda-existing-directory (directory)
  (ignore-errors
    (alexandria:when-let ((existing (uiop:directory-exists-p directory)))
      (truename existing))))

(defun agenda-directories ()
  "Existing canonical agenda roots in the live Emacs configuration's order."
  (let* ((public (ignore-errors (public-org-directory)))
         (candidates (remove nil
                             (list (ignore-errors (workdir))
                                   public
                                   (and public
                                        (merge-pathnames "mcp/" public)))))
         (directories '()))
    (dolist (candidate candidates (nreverse directories))
      (alexandria:when-let ((directory (agenda-existing-directory candidate)))
        (unless (find directory directories :test #'uiop:pathname-equal)
          (push directory directories))))))

(defun agenda-top-level-org-files (directory)
  "Canonical files matching Org's default top-level agenda file regexp."
  (loop :for file :in (sort (copy-list (uiop:directory-files directory))
                            #'string-lessp
                            :key #'file-namestring)
        :for name := (file-namestring file)
        :when (and (plusp (length name))
                   (char/= #\. (char name 0))
                   (string= "org" (or (pathname-type file) "")))
          :collect (or (ignore-errors (truename file)) file)))

(defun agenda-org-files ()
  "Return canonical top-level Org files and per-root discovery failures."
  (let ((files '())
        (failures '()))
    (dolist (directory (agenda-directories))
      (handler-case
          (dolist (file (agenda-top-level-org-files directory))
            (unless (find file files :test #'uiop:pathname-equal)
              (push file files)))
        (error (condition)
          (push (cons directory condition) failures))))
    (values (nreverse files) (nreverse failures))))

(defun agenda-item-with-planning (item kind date)
  (make-agenda-item
   :keyword (agenda-item-keyword item)
   :text (agenda-item-text item)
   :file (agenda-item-file item)
   :line (agenda-item-line item)
   :heading (agenda-item-heading item)
   :date date
   :kind kind
   :event-p nil))

(defun agenda-timestamp-field (scanner contents)
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan scanner contents)
    (declare (ignore start end))
    (when (and registers (aref registers 0))
      (subseq contents (aref registers 0) (aref register-ends 0)))))

(defun agenda-parse-active-timestamp (contents)
  "Return DATE, TIME, and REPEATER parsed from timestamp CONTENTS."
  (let ((date (agenda-timestamp-field *timestamp-date-scanner* contents)))
    (when (and date (valid-iso-date-p date))
      (values date
              (agenda-timestamp-field *timestamp-time-scanner* contents)
              (agenda-timestamp-field *timestamp-repeater-scanner* contents)))))

(defun agenda-active-timestamp-specs (line)
  "Return valid active timestamp specifications found in LINE."
  (loop :with offset = 0
        :with specs
        :while (< offset (length line))
        :do (multiple-value-bind (start end registers register-ends)
                (ppcre:scan *active-timestamp-scanner* line :start offset)
              (unless start (return (nreverse specs)))
              (let ((first
                      (subseq line (aref registers 0)
                              (aref register-ends 0)))
                    (second
                      (and (aref registers 1)
                           (subseq line (aref registers 1)
                                   (aref register-ends 1)))))
                (multiple-value-bind (date time repeater)
                    (agenda-parse-active-timestamp first)
                  (when date
                    (let ((end-date
                            (and second
                                 (nth-value
                                  0 (agenda-parse-active-timestamp second)))))
                      (push (list :date date :time time :repeater repeater
                                  :end-date end-date
                                  :raw (subseq line start end))
                            specs)))))
              (setf offset end))
        :finally (return (nreverse specs))))

(defun agenda-item-with-event (item spec &optional heading-line-p)
  (make-agenda-item
   :keyword (agenda-item-keyword item)
   :text (if (and heading-line-p (null (getf spec :end-date)))
             (string-trim
              '(#\Space #\Tab)
              (ppcre:regex-replace-all
               (ppcre:quote-meta-chars (getf spec :raw))
               (agenda-item-text item) ""))
             (agenda-item-text item))
   :file (agenda-item-file item)
   :line (agenda-item-line item)
   :heading (agenda-item-heading item)
   :date (getf spec :date)
   :kind "TIMESTAMP"
   :event-p t
   :end-date (getf spec :end-date)
   :repeater (getf spec :repeater)
   :time (getf spec :time)))

(defun parse-org-file (path)
  "Return parsed agenda items and, as a second value, warnings or read errors.
Only the planning line immediately below a heading is structural.  A heading
with both SCHEDULED and DEADLINE fields produces one item for each field.
Ordinary active timestamps belong to their containing visible heading."
  (handler-case
      (with-open-file (in path :direction :input :external-format :utf-8)
         (let ((items '())
               (warnings '())
               (current nil)
               (current-planned-p nil)
               (planning-line-open-p nil)
               (suppressed-level nil)
               (block-p nil)
               (drawer-p nil))
           (labels ((finish-current ()
                      (when (and current (not current-planned-p))
                        (push current items)))
                    (emit-events (line)
                      (when current
                        (dolist (spec (agenda-active-timestamp-specs line))
                          (push (agenda-item-with-event
                                 current spec
                                 (string= line (agenda-item-heading current)))
                                items))))
                    (comment-heading-p (text)
                      (or (string= text "COMMENT")
                          (alexandria:starts-with-subseq "COMMENT " text)))
                    (archive-heading-p (line)
                      (not (null
                            (ppcre:scan "(?:^|\\s):ARCHIVE:\\s*$" line)))))
             (loop :for line := (read-line in nil)
                   :for lineno :from 1
                   :while line
                   :do
                      (cond
                        (block-p
                         (when (ppcre:scan
                                "(?i)^\\s*#\\+end_" line)
                           (setf block-p nil)))
                        ((ppcre:scan "(?i)^\\s*#\\+begin_" line)
                         (setf block-p t
                               planning-line-open-p nil))
                        (t
                         (multiple-value-bind (start end gs ge)
                             (ppcre:scan *heading-scanner* line)
                           (declare (ignore end))
                           (if start
                               (progn
                                 (finish-current)
                                 (setf drawer-p nil block-p nil)
                                 (let* ((level (org-heading-level-from-line line))
                                        (keyword
                                          (when (aref gs 0)
                                            (subseq line (aref gs 0)
                                                    (aref ge 0))))
                                        (text
                                          (string-trim
                                           '(#\Space #\Tab)
                                           (subseq line (aref gs 1)
                                                   (aref ge 1)))))
                                   (when (and suppressed-level
                                              (<= level suppressed-level))
                                     (setf suppressed-level nil))
                                   (let ((suppressed-p
                                           (or suppressed-level
                                               (comment-heading-p text)
                                               (archive-heading-p line))))
                                     (when (and suppressed-p
                                                (null suppressed-level))
                                       (setf suppressed-level level))
                                     (setf current
                                           (unless suppressed-p
                                             (make-agenda-item
                                              :keyword keyword
                                              :text text
                                              :file path
                                              :line lineno
                                              :heading line
                                              :date nil
                                              :kind nil))
                                           current-planned-p nil
                                           planning-line-open-p
                                           (not suppressed-p))
                                     (unless suppressed-p
                                       (emit-events line)))))
                               (when current
                                 (let ((planning-p
                                         (and planning-line-open-p
                                              (ppcre:scan
                                               *planning-line-scanner* line))))
                                   (when planning-p
                                     (ppcre:do-register-groups (kind date)
                                         (*planning-scanner* line)
                                       (if (valid-iso-date-p date)
                                           (progn
                                             (push
                                              (agenda-item-with-planning
                                               current kind date)
                                              items)
                                             (setf current-planned-p t))
                                           (push
                                            (make-condition
                                             'simple-error
                                             :format-control
                                             "Invalid Org planning date ~s at line ~d"
                                             :format-arguments
                                             (list date lineno))
                                            warnings))))
                                   (setf planning-line-open-p nil)
                                   (cond
                                     ((ppcre:scan
                                       "^\\s*:[[:alnum:]_-]+:\\s*$" line)
                                      (setf drawer-p
                                            (not (ppcre:scan
                                                  "^\\s*:END:\\s*$" line))))
                                     ((and drawer-p
                                           (ppcre:scan
                                            "^\\s*:END:\\s*$" line))
                                      (setf drawer-p nil))
                                     ((or planning-p drawer-p
                                          (ppcre:scan "^\\s*#" line)))
                                     (t (emit-events line))))))))))
             (finish-current))
           (values (nreverse items) (nreverse warnings))))
    (error (condition)
      (values nil (list condition)))))

;;; --- date helpers --------------------------------------------------------

(defun today-iso (&optional (now (funcall *agenda-now-function*)))
  "Today as a YYYY-MM-DD string."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time now)
    (declare (ignore sec min hour))
    (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))

(defun iso-plus-days (days &optional (now (funcall *agenda-now-function*)))
  "Today + DAYS as YYYY-MM-DD, anchored at noon across DST transitions."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time now)
    (declare (ignore sec min hour))
    (multiple-value-bind (new-sec new-min new-hour new-day new-month new-year)
        (decode-universal-time
         (+ (encode-universal-time 0 0 12 day month year)
            (* days 24 60 60)))
      (declare (ignore new-sec new-min new-hour))
      (format nil "~4,'0d-~2,'0d-~2,'0d" new-year new-month new-day))))

(defun agenda-date-components (date)
  (values (parse-integer date :start 0 :end 4)
          (parse-integer date :start 5 :end 7)
          (parse-integer date :start 8 :end 10)))

(defun agenda-date-ordinal (date)
  "Return a timezone-independent day ordinal for DATE."
  (multiple-value-bind (year month day) (agenda-date-components date)
    (floor (encode-universal-time 0 0 12 day month year 0) 86400)))

(defun agenda-add-calendar (date amount unit)
  "Add AMOUNT units UNIT (d, w, m, or y) to DATE."
  (multiple-value-bind (year month day) (agenda-date-components date)
    (ecase unit
      ((#\d #\w)
       (multiple-value-bind (second minute hour new-day new-month new-year)
           (decode-universal-time
            (+ (encode-universal-time 0 0 12 day month year 0)
               (* amount (if (char= unit #\w) 7 1) 86400))
            0)
         (declare (ignore second minute hour))
         (format nil "~4,'0d-~2,'0d-~2,'0d" new-year new-month new-day)))
      (#\m
       (let* ((zero-month (+ (* year 12) (1- month) amount))
              (new-year (floor zero-month 12))
              (new-month (1+ (mod zero-month 12)))
              (new-day (min day (days-in-month new-month new-year))))
         (format nil "~4,'0d-~2,'0d-~2,'0d"
                 new-year new-month new-day)))
      (#\y
       (let* ((new-year (+ year amount))
              (new-day (min day (days-in-month month new-year))))
         (format nil "~4,'0d-~2,'0d-~2,'0d"
                 new-year month new-day))))))

(defun agenda-repeater-parts (repeater)
  (when repeater
    (multiple-value-bind (start end registers register-ends)
        (ppcre:scan "^[.+]*\\+([0-9]+)([dDwWmMyY])$" repeater)
      (declare (ignore end))
      (when start
        (values
         (parse-integer repeater
                        :start (aref registers 0)
                        :end (aref register-ends 0))
         (char-downcase (aref repeater (aref registers 1))))))))

(defun agenda-repeater-start-index (base today amount unit)
  (let ((estimate
          (ecase unit
            ((#\d #\w)
             (let ((step (* amount (if (char= unit #\w) 7 1))))
               (max 0 (ceiling (- (agenda-date-ordinal today)
                                  (agenda-date-ordinal base))
                               step))))
            (#\m
             (multiple-value-bind (base-year base-month base-day)
                 (agenda-date-components base)
               (declare (ignore base-day))
               (multiple-value-bind (today-year today-month today-day)
                   (agenda-date-components today)
                 (declare (ignore today-day))
                 (max 0 (floor (- (+ (* today-year 12) today-month)
                                  (+ (* base-year 12) base-month))
                               amount)))))
            (#\y
             (multiple-value-bind (base-year base-month base-day)
                 (agenda-date-components base)
               (declare (ignore base-month base-day))
               (multiple-value-bind (today-year today-month today-day)
                   (agenda-date-components today)
                 (declare (ignore today-month today-day))
                 (max 0 (floor (- today-year base-year) amount))))))))
    (loop :for index :from estimate
          :for date := (agenda-add-calendar base (* index amount) unit)
          :when (not (string< date today)) :return index)))

(defun agenda-item-occurrence (item date &optional index count)
  (let ((occurrence (copy-agenda-item item)))
    (setf (agenda-item-date occurrence) date
          (agenda-item-end-date occurrence) nil
          (agenda-item-repeater occurrence) nil
          (agenda-item-occurrence-index occurrence) index
          (agenda-item-occurrence-count occurrence) count)
    occurrence))

(defun agenda-event-occurrences (item today horizon)
  "Expand ITEM into event rows intersecting TODAY through HORIZON."
  (let ((base (agenda-item-date item))
        (end (agenda-item-end-date item))
        (repeater (agenda-item-repeater item)))
    (cond
      (end
       (let* ((base-ordinal (agenda-date-ordinal base))
              (count (1+ (- (agenda-date-ordinal end) base-ordinal)))
              (first-offset
                (max 0 (- (agenda-date-ordinal today) base-ordinal)))
              (last-offset
                (min (1- count)
                     (- (agenda-date-ordinal horizon) base-ordinal))))
         (when (plusp count)
           (loop :for offset :from first-offset :to last-offset
                 :for date := (agenda-add-calendar base offset #\d)
                 :collect (agenda-item-occurrence
                           item date (1+ offset) count)))))
      (repeater
       (multiple-value-bind (amount unit) (agenda-repeater-parts repeater)
         (when (and amount (plusp amount))
           (loop :with start :=
                   (agenda-repeater-start-index base today amount unit)
                 :for index :from start
                 :for date :=
                   (agenda-add-calendar base (* index amount) unit)
                 :while (string<= date horizon)
                 :collect (agenda-item-occurrence item date)))))
      ((and (not (string< base today)) (string<= base horizon))
       (list (agenda-item-occurrence item base))))))

;;; --- grouping ------------------------------------------------------------

(defun open-keyword-p (kw)
  (and kw (member kw *agenda-open-keywords* :test #'string=)))

(defun done-keyword-p (kw)
  (and kw (member kw *agenda-done-keywords* :test #'string=)))

(defun group-items (items &optional (now (funcall *agenda-now-function*)))
  "Bucket ITEMS into (overdue today upcoming todos), each a list of items.
Given the fixed YYYY-MM-DD format, plain string comparison is correct date
comparison. Dated DONE/CANCELLED items are dropped from the dated sections."
  (let ((today (today-iso now))
        (horizon (iso-plus-days *agenda-upcoming-days* now))
        (overdue '()) (today-items '()) (upcoming '()) (todos '()))
    (dolist (item items)
      (let ((date (agenda-item-date item))
            (kw (agenda-item-keyword item)))
        (cond
          ((agenda-item-event-p item)
           (dolist (occurrence
                    (agenda-event-occurrences item today horizon))
             (if (string= (agenda-item-date occurrence) today)
                 (push occurrence today-items)
                 (push occurrence upcoming))))
          ((and date (not (done-keyword-p kw)))
           (cond
             ((string< date today) (push item overdue))
             ((string= date today) (push item today-items))
             ((string<= date horizon) (push item upcoming))))
          ((and (null date) (open-keyword-p kw))
           (push item todos)))))
    (flet ((by-date (a b)
             (let ((a-date (or (agenda-item-date a) ""))
                   (b-date (or (agenda-item-date b) "")))
               (or (string< a-date b-date)
                   (and (string= a-date b-date)
                        (string< (or (agenda-item-time a) "")
                                 (or (agenda-item-time b) "")))))))
      (values (stable-sort (nreverse overdue) #'by-date)
              (nreverse today-items)
              (stable-sort (nreverse upcoming) #'by-date)
              (nreverse todos)))))

;;; --- rendering -----------------------------------------------------------

(defun agenda-display-line (item)
  "One display line for ITEM, including planning kind/date when present."
  (let ((planning
          (if (agenda-item-date item)
              (format nil "  [~a ~a~@[ ~a~]~@[ ~a~]]"
                      (if (agenda-item-event-p item)
                          "EVENT"
                          (agenda-item-kind item))
                      (agenda-item-date item)
                      (agenda-item-time item)
                      (and (agenda-item-occurrence-index item)
                           (format nil "~d/~d"
                                   (agenda-item-occurrence-index item)
                                   (agenda-item-occurrence-count item))))
              "")))
    (format nil "~9a ~a~a   (~a:~a)"
            (or (agenda-item-keyword item) "")
            (agenda-item-text item)
            planning
            (file-namestring (agenda-item-file item))
            (agenda-item-line item))))

(defun insert-agenda-section (buffer title items)
  "Insert TITLE and ITEMS with exact source file/line text properties."
  (let ((point (buffer-end-point buffer)))
    (insert-string point (format nil "~a~%" title))
    (if (null items)
        (insert-string point (format nil "  (none)~%"))
        (dolist (item items)
          (with-point ((start point))
            (insert-string point (format nil "  ~a~%" (agenda-display-line item)))
            (put-text-property start point :agenda-file (agenda-item-file item))
            (put-text-property start point :agenda-line (agenda-item-line item))
            (put-text-property start point :agenda-heading
                               (agenda-item-heading item))
            (put-text-property start point :agenda-kind
                               (agenda-item-kind item))
            (put-text-property start point :agenda-date
                               (agenda-item-date item))
            (put-text-property start point :agenda-time
                               (agenda-item-time item))
            (put-text-property start point :agenda-occurrence-index
                               (agenda-item-occurrence-index item)))))
    (insert-string point (format nil "~%"))))

(defun agenda-error-text (condition)
  (let ((text (princ-to-string condition)))
    (substitute #\Space #\Return
                (substitute #\Space #\Newline text))))

(defun insert-agenda-failures (buffer failures)
  (when failures
    (let ((point (buffer-end-point buffer)))
      (insert-string point (format nil "Warnings~%"))
      (dolist (failure failures)
        (insert-string
         point
         (format nil "  ~a: ~a~%"
                 (if (car failure)
                     (let ((name (file-namestring (car failure))))
                       (if (plusp (length name))
                           name
                           (uiop:native-namestring (car failure))))
                     "source discovery")
                 (agenda-error-text (cdr failure))))))))

(defun agenda-entry-key-at-point (point)
  (alexandria:when-let ((file (text-property-at point :agenda-file)))
    (list file
          (text-property-at point :agenda-line)
          (text-property-at point :agenda-kind)
          (text-property-at point :agenda-date)
          (text-property-at point :agenda-time)
          (text-property-at point :agenda-occurrence-index))))

(defun agenda-restore-entry-point (buffer key)
  "Move BUFFER's point to the first rendered row matching KEY."
  (with-point ((point (buffer-start-point buffer)))
    (loop
      (when (equal key (agenda-entry-key-at-point point))
        (move-point (buffer-point buffer) point)
        (return t))
      (unless (line-offset point 1)
        (return nil)))))

(defun render-agenda (buffer items &optional failures)
  "Fill BUFFER with grouped ITEMS and any source FAILURES on the editor thread."
  (let ((now (funcall *agenda-now-function*))
        (restore-key (buffer-value buffer 'lem-yath-agenda-restore-entry)))
    (setf (buffer-value buffer 'lem-yath-agenda-restore-entry) nil)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (multiple-value-bind (overdue today upcoming todos)
          (group-items items now)
        (let ((point (buffer-end-point buffer)))
          (insert-string point (format nil "Agenda  (~a)~%~%" (today-iso now))))
        (insert-agenda-section buffer "Overdue" overdue)
        (insert-agenda-section buffer "Today" today)
        (insert-agenda-section
         buffer (format nil "Upcoming (~a days)" *agenda-upcoming-days*) upcoming)
        (insert-agenda-section buffer "TODOs" todos)
        (insert-agenda-failures buffer failures)))
    (unless (and restore-key (agenda-restore-entry-point buffer restore-key))
      (buffer-start (buffer-point buffer))))
  (setf (buffer-read-only-p buffer) t)
  (buffer-unmark buffer)
  (redraw-display))

(defun agenda-collect-items ()
  "Return all parsed items and a list of per-source failures."
  (handler-case
      (multiple-value-bind (files discovery-failures) (agenda-org-files)
        (let ((items '())
              (failures (reverse discovery-failures)))
          (dolist (file files)
            (multiple-value-bind (parsed errors) (parse-org-file file)
              (setf items (nconc items parsed))
              (dolist (error errors)
                (push (cons file error) failures))))
          (values items (nreverse failures))))
    (error (condition)
      (values nil (list (cons nil condition))))))

(defun agenda-buffer-live-p (buffer)
  (not (null (member buffer (buffer-list) :test #'eq))))

(defun agenda-buffer-generation (buffer)
  (or (buffer-value buffer 'lem-yath-agenda-generation) 0))

(defun agenda-next-generation (buffer)
  (setf (buffer-value buffer 'lem-yath-agenda-generation)
        (1+ (agenda-buffer-generation buffer))))

(defun agenda-render-if-current (buffer generation items &optional failures)
  "Render ITEMS only when GENERATION still owns the live agenda BUFFER."
  (when (and (agenda-buffer-live-p buffer)
             (mode-active-p buffer 'lem-yath-agenda-mode)
             (= generation (agenda-buffer-generation buffer)))
    (render-agenda buffer items failures)
    t))

(defun agenda-scan-running-p (buffer)
  (not (null (buffer-value buffer 'lem-yath-agenda-scan-running))))

(defun agenda-refresh-pending-p (buffer)
  (not (null (buffer-value buffer 'lem-yath-agenda-refresh-pending))))

(defun agenda-scan-worker (buffer generation)
  "Collect agenda items off-thread and marshal one completion event."
  (multiple-value-bind (items failures)
      (handler-case
          (agenda-collect-items)
        (error (condition)
          (values nil (list (cons nil condition)))))
    (send-event
     (lambda ()
       (handler-case
           (agenda-finish-scan buffer generation items failures)
         (error (condition)
           (message "Agenda render failed: ~a" condition)))))))

(defun agenda-launch-scan (buffer generation)
  "Launch GENERATION, maintaining at most one worker for BUFFER."
  (setf (buffer-value buffer 'lem-yath-agenda-scan-running) t)
  (handler-case
      (bt2:make-thread (lambda () (agenda-scan-worker buffer generation))
                       :name (format nil "lem-yath/agenda-scan-~d" generation))
    (error (condition)
      (setf (buffer-value buffer 'lem-yath-agenda-scan-running) nil
            (buffer-value buffer 'lem-yath-agenda-refresh-pending) nil)
      (agenda-render-if-current
       buffer generation nil (list (cons nil condition)))
      (message "Agenda scan could not start: ~a" condition)
      nil)))

(defun agenda-finish-scan (buffer generation items failures)
  "Finish one worker and run at most one coalesced replacement refresh."
  (when (agenda-buffer-live-p buffer)
    (setf (buffer-value buffer 'lem-yath-agenda-scan-running) nil)
    (when (mode-active-p buffer 'lem-yath-agenda-mode)
      (if (agenda-refresh-pending-p buffer)
          (progn
            (setf (buffer-value buffer 'lem-yath-agenda-refresh-pending) nil)
            (agenda-launch-scan buffer (agenda-buffer-generation buffer)))
          (agenda-render-if-current buffer generation items failures)))))

(defun agenda-mark-scanning (buffer)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (insert-string (buffer-end-point buffer) "Scanning..."))
  (setf (buffer-read-only-p buffer) t)
  (buffer-unmark buffer)
  (redraw-display))

(defun agenda-start-scan (buffer)
  "Start or coalesce a generation-guarded asynchronous refresh for BUFFER."
  (let ((generation (agenda-next-generation buffer)))
    (agenda-mark-scanning buffer)
    (if (agenda-scan-running-p buffer)
        (setf (buffer-value buffer 'lem-yath-agenda-refresh-pending) t)
        (progn
          (setf (buffer-value buffer 'lem-yath-agenda-refresh-pending) nil)
          (agenda-launch-scan buffer generation)))
    generation))

;;; --- mode & keymap -------------------------------------------------------

(defun agenda-kill-buffer-cleanup (&optional (buffer (current-buffer)))
  ;; Invalidate any worker that still holds BUFFER before Lem disposes it.
  (when (agenda-buffer-live-p buffer)
    (agenda-next-generation buffer)
    (setf (buffer-value buffer 'lem-yath-agenda-refresh-pending) nil)))

(define-major-mode lem-yath-agenda-mode nil
    (:name "Agenda"
     :keymap *lem-yath-agenda-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t)
  (buffer-disable-undo (current-buffer))
  (add-hook (variable-value 'kill-buffer-hook :buffer (current-buffer))
            'agenda-kill-buffer-cleanup))

(define-command lem-yath-agenda-visit () ()
  "Open the org file for the entry on the current line at its heading."
  (let ((file (text-property-at (current-point) :agenda-file))
        (line (text-property-at (current-point) :agenda-line)))
    (if (null file)
        (message "No agenda entry on this line.")
        (progn
          (find-file file)
          (when (integerp line)
            (goto-line line))))))

(define-command lem-yath-agenda-refresh () ()
  "Re-scan the org files and rebuild the agenda buffer."
  (let ((buffer (get-buffer *agenda-buffer-name*)))
    (if (and buffer (mode-active-p buffer 'lem-yath-agenda-mode))
        (agenda-start-scan buffer)
        (message "No agenda buffer to refresh."))))

(defparameter *agenda-todo-fast-keys*
  '((#\t . "TODO")
    (#\n . "NEXT")
    (#\w . "WAITING")
    (#\h . "HOLD")
    (#\s . "SOMEDAY")
    (#\d . "DONE")
    (#\c . "CANCELLED"))
  "Fast-selection keys from the configured Org TODO sequence.")

(defun agenda-prompt-todo-state ()
  "Return a selected TODO state and true, or NIL/NIL when cancelled."
  (loop
    :for character :=
      (prompt-for-character
       "TODO [t]odo [n]ext [w]ait [h]old [s]omeday [d]one [c]ancelled [SPC] none [q] quit: ")
    :do (cond
          ((null character) (return (values nil nil)))
          ((char= character #\Space) (return (values nil t)))
          ((member character '(#\q #\Q #\Escape) :test #'char=)
           (return (values nil nil)))
          (t
           (alexandria:if-let
               ((entry (assoc (char-downcase character)
                              *agenda-todo-fast-keys*)))
             (return (values (cdr entry) t))
             (message "Unknown TODO key: ~a" character))))))

(defun agenda-set-source-todo (file line expected-heading state)
  "Set one exact agenda source heading to STATE and save it immediately.

EXPECTED-HEADING prevents a stale agenda row from changing a different line."
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
          (error "Agenda source changed; refresh before editing"))
        (org-set-heading-todo-state heading state))
      ;; The Emacs configuration advises `org-agenda-todo' to save its source.
      (save-buffer buffer)))
  state)

(defparameter *agenda-weekday-names*
  #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun"))

(defun agenda-date-with-weekday (date)
  "Return DATE as an active Org timestamp with its computed weekday."
  (unless (valid-iso-date-p date)
    (error "Invalid Org date: ~s" date))
  (let ((year (parse-integer date :start 0 :end 4))
        (month (parse-integer date :start 5 :end 7))
        (day (parse-integer date :start 8 :end 10)))
    (multiple-value-bind (second minute hour decoded-day decoded-month
                          decoded-year weekday)
        (decode-universal-time
         (encode-universal-time 0 0 12 day month year))
      (declare (ignore second minute hour decoded-day decoded-month
                       decoded-year))
      (format nil "<~a ~a>" date (aref *agenda-weekday-names* weekday)))))

(defun agenda-read-date (label)
  "Read a bounded Org date for LABEL, returning DATE and true on success."
  (loop
    :for input := (string-trim '(#\Space #\Tab)
                               (prompt-for-string
                                (format nil "~a date (YYYY-MM-DD or +Nd/+Nw): "
                                        label)))
    :do (cond
          ((zerop (length input)) (return (values nil nil)))
          ((valid-iso-date-p input) (return (values input t)))
          (t
           (multiple-value-bind (start end registers register-ends)
               (ppcre:scan "^\\+([0-9]+)([dDwW])$" input)
             (declare (ignore end))
             (if start
                 (let* ((amount
                          (parse-integer input
                                         :start (aref registers 0)
                                         :end (aref register-ends 0)))
                        (unit (char-downcase (aref input (aref registers 1))))
                        (days (* amount (if (char= unit #\w) 7 1))))
                   (return (values (iso-plus-days days) t)))
                 (message "Invalid date; use YYYY-MM-DD, +Nd, or +Nw")))))))

(defun agenda-set-planning-field (heading kind date)
  "Set KIND to DATE on HEADING's immediate Org planning line."
  (let* ((timestamp (agenda-date-with-weekday date))
         (field (format nil "~a: ~a" kind timestamp))
         (scanner (ppcre:create-scanner
                   (format nil "~a:\\s*<[^>]+>" kind))))
    (with-point ((planning heading))
      (if (and (line-offset planning 1)
               (ppcre:scan *planning-line-scanner* (line-string planning)))
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

(defun agenda-set-source-planning (file line expected-heading kind date)
  "Set one exact agenda source planning KIND to DATE and save immediately."
  (unless (and file (integerp line) (plusp line) expected-heading)
    (error "No mutable agenda heading on this line"))
  (let ((buffer (find-file-buffer file))
        (timestamp nil))
    (with-current-buffer buffer
      (when (buffer-read-only-p buffer)
        (error "Agenda source is read-only: ~a" file))
      (with-point ((heading (buffer-start-point buffer)))
        (unless (or (= line 1) (line-offset heading (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (unless (string= expected-heading (line-string heading))
          (error "Agenda source changed; refresh before editing"))
        (setf timestamp (agenda-set-planning-field heading kind date)))
      (save-buffer buffer))
    timestamp))

(defun agenda-change-planning (kind label)
  "Prompt for and persist planning KIND on the current agenda entry."
  (let ((agenda-buffer (current-buffer))
        (file (text-property-at (current-point) :agenda-file))
        (line (text-property-at (current-point) :agenda-line))
        (heading (text-property-at (current-point) :agenda-heading)))
    (if (null file)
        (message "No agenda entry on this line.")
        (multiple-value-bind (date selected-p) (agenda-read-date label)
          (when selected-p
            (handler-case
                (let ((timestamp
                        (agenda-set-source-planning
                         file line heading kind date)))
                  (setf (buffer-value agenda-buffer
                                      'lem-yath-agenda-restore-entry)
                        (list file line kind date nil nil))
                  (agenda-start-scan agenda-buffer)
                  (message "~a" timestamp))
              (error (condition)
                (message "Agenda ~a failed: ~a" label condition))))))))

(define-command lem-yath-agenda-schedule () ()
  "Set the current agenda heading's SCHEDULED date and save its source."
  (agenda-change-planning "SCHEDULED" "Schedule"))

(define-command lem-yath-agenda-deadline () ()
  "Set the current agenda heading's DEADLINE date and save its source."
  (agenda-change-planning "DEADLINE" "Deadline"))

(defvar *agenda-last-priority-direction* nil)
(defvar *agenda-last-priority-target* nil)

(defun agenda-heading-priority-bounds (heading)
  "Return priority cookie bounds and value on HEADING."
  (let ((line (line-string heading)))
    (multiple-value-bind (start end registers register-ends)
        (ppcre:scan
         (format nil "^\\*+\\s+(?:~a\\s+)?(\\[#([A-Z])\\])(?:\\s+|$)"
                 *org-todo-keyword-pattern*)
         line)
      (declare (ignore start end))
      (when (and registers (aref registers 0))
        (values (aref registers 0)
                (aref register-ends 0)
                (aref line (aref registers 1)))))))

(defun agenda-set-heading-priority (heading priority)
  "Set HEADING's priority cookie to PRIORITY, or remove it when NIL."
  (multiple-value-bind (cookie-start cookie-end old-priority)
      (agenda-heading-priority-bounds heading)
    (with-point ((point heading))
      (line-start point)
      (cond
        (old-priority
         (character-offset point cookie-start)
         (if priority
             (progn
               (character-offset point 2)
               (delete-character point 1)
               (insert-character point priority))
             (let* ((line (line-string heading))
                    (delete-length
                      (+ (- cookie-end cookie-start)
                         (if (and (< cookie-end (length line))
                                  (char= (aref line cookie-end) #\Space))
                             1 0))))
               (delete-character point delete-length))))
        (priority
         (multiple-value-bind (todo-start todo-end todo-state)
             (org-heading-todo-bounds heading)
           (declare (ignore todo-start))
           (if todo-state
               (progn
                 (character-offset point todo-end)
                 (insert-string point (format nil " [#~c]" priority)))
               (let ((line (line-string heading)))
                 (multiple-value-bind (start end)
                     (ppcre:scan "^\\*+\\s+" line)
                   (declare (ignore start))
                   (character-offset point end)
                   (insert-string point (format nil "[#~c] " priority)))))))))
    priority))

(defun agenda-next-priority (current direction repeated-p)
  "Return the GNU Org A/B/C priority reached from CURRENT in DIRECTION."
  (if current
      (ecase direction
        (:up (case current (#\A nil) (#\B #\A) (#\C #\B)))
        (:down (case current (#\A #\B) (#\B #\C) (#\C nil))))
      (if repeated-p
          (ecase direction (:up #\C) (:down #\A))
          #\B)))

(defun agenda-set-source-priority
    (file line expected-heading direction repeated-p)
  "Move one exact source heading priority in DIRECTION and save it."
  (unless (and file (integerp line) (plusp line) expected-heading)
    (error "No mutable agenda heading on this line"))
  (let ((buffer (find-file-buffer file))
        (priority nil))
    (with-current-buffer buffer
      (when (buffer-read-only-p buffer)
        (error "Agenda source is read-only: ~a" file))
      (with-point ((heading (buffer-start-point buffer)))
        (unless (or (= line 1) (line-offset heading (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (unless (string= expected-heading (line-string heading))
          (error "Agenda source changed; refresh before editing"))
        (setf priority
              (agenda-next-priority
               (nth-value 2 (agenda-heading-priority-bounds heading))
               direction repeated-p))
        (agenda-set-heading-priority heading priority))
      (save-buffer buffer))
    priority))

(defun agenda-change-priority (direction)
  "Move the current agenda heading priority in DIRECTION."
  (let* ((agenda-buffer (current-buffer))
         (entry-key (agenda-entry-key-at-point (current-point)))
         (file (text-property-at (current-point) :agenda-file))
         (line (text-property-at (current-point) :agenda-line))
         (heading (text-property-at (current-point) :agenda-heading))
         (target (and file (list file line)))
         (repeated-p
           (and (eq direction *agenda-last-priority-direction*)
                (equal target *agenda-last-priority-target*))))
    (if (null file)
        (progn
          (setf *agenda-last-priority-direction* nil
                *agenda-last-priority-target* nil)
          (message "No agenda entry on this line."))
        (handler-case
            (let ((priority
                    (agenda-set-source-priority
                     file line heading direction repeated-p)))
              (setf *agenda-last-priority-direction* direction
                    *agenda-last-priority-target* target
                    (buffer-value agenda-buffer
                                  'lem-yath-agenda-restore-entry)
                    entry-key)
              (agenda-start-scan agenda-buffer)
              (message "Priority ~a" (or priority "removed")))
          (error (condition)
            (setf *agenda-last-priority-direction* nil
                  *agenda-last-priority-target* nil)
            (message "Agenda priority failed: ~a" condition))))))

(define-command lem-yath-agenda-priority-up () ()
  "Increase the current agenda heading priority and save its source."
  (agenda-change-priority :up))

(define-command lem-yath-agenda-priority-down () ()
  "Decrease the current agenda heading priority and save its source."
  (agenda-change-priority :down))

(defun agenda-heading-string-p (line)
  "Whether LINE starts with a valid Org headline marker."
  (let ((index 0)
        (length (length line)))
    (loop :while (and (< index length) (char= (char line index) #\*))
          :do (incf index))
    (and (plusp index)
         (< index length)
         (member (char line index) '(#\Space #\Tab)))))

(defun agenda-heading-tag-string (heading)
  "Return HEADING's canonical local tag suffix, or the empty string."
  (let* ((line (etypecase heading
                 (string heading)
                 (lem:point (line-string heading))))
         (end (length line)))
    (loop :while (and (plusp end)
                      (member (char line (1- end)) '(#\Space #\Tab)))
          :do (decf end))
    (if (and (agenda-heading-string-p line)
             (> end 2)
             (char= (char line (1- end)) #\:))
        (let ((start end))
          (loop :while (and (plusp start)
                            (org-tag-suffix-character-p
                             (char line (1- start))))
                :do (decf start))
          (if (and (plusp start)
                   (char= (char line start) #\:)
                   (member (char line (1- start)) '(#\Space #\Tab))
                   (loop :for index :from (1+ start) :below (1- end)
                         :thereis (char/= (char line index) #\:)))
              (subseq line start end)
              ""))
        "")))

(defun agenda-tag-character-p (character)
  "Whether CHARACTER is valid inside one Org tag."
  (and (org-tag-suffix-character-p character)
       (char/= character #\:)))

(defun agenda-normalize-tags (input)
  "Return INPUT as ordered, unique Org tags.

Like GNU Org, invalid characters separate tags instead of entering a headline
suffix."
  (let ((tags '())
        (start nil)
        (length (length input)))
    (labels ((finish-tag (end)
               (when start
                 (let ((tag (subseq input start end)))
                   (unless (member tag tags :test #'string=)
                     (push tag tags)))
                 (setf start nil))))
      (loop :for index :from 0 :to length
            :for character := (and (< index length) (char input index))
            :do (if (and character (agenda-tag-character-p character))
                    (unless start (setf start index))
                    (finish-tag index))))
    (nreverse tags)))

(defun agenda-tag-string (tags)
  "Return TAGS in canonical colon-delimited Org syntax."
  (if tags (format nil ":~{~a~^:~}:" tags) ""))

(defun agenda-heading-tags (heading)
  "Return HEADING's ordered local tags."
  (agenda-normalize-tags (agenda-heading-tag-string heading)))

(defun agenda-known-tags ()
  "Return unique local tags found in configured agenda sources."
  (multiple-value-bind (files failures) (agenda-org-files)
    (declare (ignore failures))
    (sort
     (remove-duplicates
      (loop :for file :in files
            :nconc
            (handler-case
                (with-open-file (stream file :direction :input)
                  (loop :for line := (read-line stream nil nil)
                        :while line
                        :nconc (agenda-heading-tags line)))
              (error () nil)))
      :test #'string=)
     #'string-lessp)))

(defun agenda-tag-completion-items (input known-tags)
  "Return canonical full-input completions for INPUT from KNOWN-TAGS."
  (let* ((last-colon (position #\: input :from-end t))
         (prefix (if last-colon
                     (subseq input 0 (1+ last-colon))
                     ":"))
         (fragment (if last-colon
                       (subseq input (1+ last-colon))
                       input)))
    (append
     (when (null (agenda-normalize-tags input))
       (list
        (lem/completion-mode:make-completion-item
         :label "[clear local tags]"
         :insert-text ""
         :accept-action #'lem-yath-prompt-execute)))
     (mapcar (lambda (tag) (format nil "~a~a:" prefix tag))
             (prescient-filter fragment known-tags :category :symbol)))))

(defun agenda-read-tags (heading)
  "Prompt for replacement local tags on HEADING."
  (let ((known-tags (agenda-known-tags)))
    (agenda-normalize-tags
     (prompt-for-string
      "Tags: "
      :initial-value (agenda-heading-tag-string heading)
      :completion-function
      (lambda (input) (agenda-tag-completion-items input known-tags))
      :test-function (constantly t)
      :history-symbol 'lem-yath-agenda-tags))))

(defun agenda-set-heading-tags (heading tags)
  "Replace HEADING's local tag suffix with TAGS."
  (multiple-value-bind (tag-start tag-end blank-start)
      (org-heading-tag-bounds heading)
    (declare (ignore tag-start tag-end))
    (with-point ((start heading)
                 (end heading))
      (line-start start)
      (line-start end)
      (if blank-start
          (character-offset start blank-start)
          (line-end start))
      (line-end end)
      (delete-between-points start end)
      (when tags
        (insert-string start (format nil " ~a" (agenda-tag-string tags)))))
    (when tags
      (org-align-current-heading-tags heading)))
  tags)

(defun agenda-set-source-tags (file line expected-heading tags)
  "Replace one exact source heading's local TAGS and save it."
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
          (error "Agenda source changed; refresh before editing"))
        (agenda-set-heading-tags heading tags))
      ;; The Emacs configuration advises `org-agenda-set-tags' to save its
      ;; source immediately.
      (save-buffer buffer)))
  tags)

(define-command lem-yath-agenda-set-tags () ()
  "Replace the current agenda heading's local tags and save its source."
  (let ((agenda-buffer (current-buffer))
        (entry-key (agenda-entry-key-at-point (current-point)))
        (file (text-property-at (current-point) :agenda-file))
        (line (text-property-at (current-point) :agenda-line))
        (heading (text-property-at (current-point) :agenda-heading)))
    (if (null file)
        (message "No agenda entry on this line.")
        (let ((tags (agenda-read-tags heading)))
          (handler-case
              (progn
                (agenda-set-source-tags file line heading tags)
                (setf (buffer-value agenda-buffer
                                    'lem-yath-agenda-restore-entry)
                      entry-key)
                (agenda-start-scan agenda-buffer)
                (message "Tags: ~a" (agenda-tag-string tags)))
            (error (condition)
              (message "Agenda tags failed: ~a" condition)))))))

(defun agenda-priority-post-command ()
  "Forget priority repetition after any other command."
  (unless (member (and (this-command) (command-name (this-command)))
                  '(lem-yath-agenda-priority-up
                    lem-yath-agenda-priority-down))
    (setf *agenda-last-priority-direction* nil
          *agenda-last-priority-target* nil)))

(define-command lem-yath-agenda-todo () ()
  "Fast-select and persist the TODO state for the agenda row at point."
  (let ((agenda-buffer (current-buffer))
        (entry-key (agenda-entry-key-at-point (current-point)))
        (file (text-property-at (current-point) :agenda-file))
        (line (text-property-at (current-point) :agenda-line))
        (heading (text-property-at (current-point) :agenda-heading)))
    (if (null file)
        (message "No agenda entry on this line.")
        (multiple-value-bind (state selected-p) (agenda-prompt-todo-state)
          (when selected-p
            (handler-case
                (progn
                  (agenda-set-source-todo file line heading state)
                  (setf (buffer-value agenda-buffer
                                      'lem-yath-agenda-restore-entry)
                        entry-key)
                  (agenda-start-scan agenda-buffer)
                  (message "TODO state: ~a" (or state "none")))
              (error (condition)
                (message "Agenda TODO failed: ~a" condition))))))))

(define-command lem-yath-agenda () ()
  "Show grouped actions from the configured top-level Org agenda files."
  (let ((directories (agenda-directories)))
    (unless directories
      (message "No configured Org agenda directory exists.")
      (return-from lem-yath-agenda))
    (let ((buffer (make-buffer *agenda-buffer-name* :enable-undo-p nil)))
      (setf (buffer-directory buffer) (first directories))
      (change-buffer-mode buffer 'lem-yath-agenda-mode)
      (switch-to-window (pop-to-buffer buffer :split-action :sensibly))
      (agenda-start-scan buffer))))

(defvar *lem-yath-agenda-vi-keymap*
  (make-keymap :description '*lem-yath-agenda-vi-keymap*))

(define-key *lem-yath-agenda-vi-keymap* "Return" 'lem-yath-agenda-visit)
(define-key *lem-yath-agenda-vi-keymap* "g" 'lem-yath-agenda-refresh)
(define-key *lem-yath-agenda-vi-keymap* "t" 'lem-yath-agenda-todo)
(define-key *lem-yath-agenda-vi-keymap* "C-c C-s" 'lem-yath-agenda-schedule)
(define-key *lem-yath-agenda-vi-keymap* "C-c C-d" 'lem-yath-agenda-deadline)
(define-key *lem-yath-agenda-vi-keymap* "K" 'lem-yath-agenda-priority-up)
(define-key *lem-yath-agenda-vi-keymap* "J" 'lem-yath-agenda-priority-down)
(define-key *lem-yath-agenda-vi-keymap* "c t" 'lem-yath-agenda-set-tags)
(define-key *lem-yath-agenda-vi-keymap* "C-c C-q" 'lem-yath-agenda-set-tags)
(define-key *lem-yath-agenda-vi-keymap* "q" 'quit-active-window)

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode lem-yath-agenda-mode))
  (declare (ignore mode))
  (list *lem-yath-agenda-vi-keymap*))

(define-key *lem-yath-agenda-mode-keymap* "Return" 'lem-yath-agenda-visit)
(define-key *lem-yath-agenda-mode-keymap* "g" 'lem-yath-agenda-refresh)
(define-key *lem-yath-agenda-mode-keymap* "t" 'lem-yath-agenda-todo)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-s" 'lem-yath-agenda-schedule)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-d" 'lem-yath-agenda-deadline)
(define-key *lem-yath-agenda-mode-keymap* "K" 'lem-yath-agenda-priority-up)
(define-key *lem-yath-agenda-mode-keymap* "J" 'lem-yath-agenda-priority-down)
(define-key *lem-yath-agenda-mode-keymap* "c t" 'lem-yath-agenda-set-tags)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-q" 'lem-yath-agenda-set-tags)
(define-key *lem-yath-agenda-mode-keymap* "q" 'quit-active-window)

(remove-hook *post-command-hook* 'agenda-priority-post-command)
(add-hook *post-command-hook* 'agenda-priority-post-command)
