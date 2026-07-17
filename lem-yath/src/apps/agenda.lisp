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

(defvar *agenda-row-marked-p-function* nil
  "Optional function called with an agenda buffer and stable rendered-row key.")

(defvar *agenda-buffer-cleanup-functions* nil
  "Functions called with an agenda buffer immediately before it is killed.")

(defvar *agenda-item-filter-function* nil
  "Optional function called with an agenda buffer and parsed item.")

(defvar *agenda-section-transform-function* nil
  "Optional function called with a buffer, section keyword, and item list.")

(defvar *agenda-status-function* nil
  "Optional function returning a short status suffix for an agenda buffer.")

(defvar *agenda-sections-function* nil
  "Optional function returning rendered agenda sections for BUFFER and ITEMS.")

(defvar *agenda-header-label-function* nil
  "Optional function returning BUFFER's date-span label.")

(defvar *agenda-date-range-function* nil
  "Optional function returning BUFFER's inclusive start and end dates.")

(defvar *agenda-post-render-functions* nil
  "Functions called with an agenda buffer after a successful render.")

;;; --- parsing -------------------------------------------------------------

(defstruct (agenda-item (:constructor make-agenda-item))
  "One parsed heading: its TODO keyword, text, source file/line and date."
  keyword text file line heading date kind event-p end-date repeater time
  occurrence-index occurrence-count
  timestamp-line timestamp-source-line timestamp-start timestamp-raw
  category tags effort top-headline)

(defstruct (agenda-item-metadata (:constructor make-agenda-item-metadata))
  category tags effort top-headline)

(defstruct (agenda-heading-context (:constructor make-agenda-heading-context))
  level title tags category metadata)

(defstruct (agenda-section (:constructor make-agenda-section))
  key title items date)

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
                                  :start start
                                  :raw (subseq line start end))
                            specs)))))
              (setf offset end))
        :finally (return (nreverse specs))))

(defun agenda-item-with-event
    (item spec source-line-number source-line &optional heading-line-p)
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
   :time (getf spec :time)
   :timestamp-line source-line-number
   :timestamp-source-line source-line
   :timestamp-start (getf spec :start)
   :timestamp-raw (getf spec :raw)))

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
                    (emit-events (line lineno)
                      (when current
                        (dolist (spec (agenda-active-timestamp-specs line))
                          (push (agenda-item-with-event
                                 current spec lineno line
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
                                       (emit-events line lineno)))))
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
                                     (t (emit-events line lineno))))))))))
             (finish-current))
           (values (nreverse items) (nreverse warnings))))
    (error (condition)
      (values nil (list condition)))))

(defun agenda-unique-strings (strings)
  "Return STRINGS in first-seen order without duplicates."
  (remove-duplicates strings :test #'string= :from-end t))

(defun agenda-filter-top-title (title)
  "Normalize TITLE like `org-find-top-headline' for agenda filtering."
  (ppcre:regex-replace
   "^\\[(?:[0-9]+/[0-9]+|%[0-9]+)\\]\\s*" title ""))

(defun agenda-file-filter-metadata (lines source)
  "Return GNU Org's file category and inherited FILETAGS for LINES."
  (let ((category nil)
        (tags '()))
    (dolist (line lines)
      (multiple-value-bind (start end registers register-ends)
          (ppcre:scan
           "(?i)^\\s*#\\+(CATEGORY|FILETAGS):\\s*(.*?)\\s*$" line)
        (declare (ignore start end))
        (when (and registers (aref registers 0))
          (let ((name (string-upcase
                       (subseq line (aref registers 0)
                               (aref register-ends 0))))
                (value (subseq line (aref registers 1)
                               (aref register-ends 1))))
            (cond
              ((and (string= name "CATEGORY")
                    (null category)
                    (plusp (length value)))
               (setf category value))
              ((string= name "FILETAGS")
               (setf tags
                     (nconc tags (agenda-normalize-tags value)))))))))
    (values (or category (pathname-name source))
            (agenda-unique-strings tags))))

(defun agenda-filter-property-fields (line)
  "Return an immediate Org drawer property's name and value from LINE."
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan "^:([A-Za-z0-9_-]+):[ \\t]*(.*?)[ \\t]*$" line)
    (declare (ignore start end))
    (when (and registers (aref registers 0))
      (values
       (string-upcase
        (subseq line (aref registers 0) (aref register-ends 0)))
       (subseq line (aref registers 1) (aref register-ends 1))))))

(defun agenda-heading-inherited-category (contexts file-category)
  (or (loop :for context :in contexts
            :for category := (agenda-heading-context-category context)
            :when (and category (plusp (length category)))
              :return category)
      file-category))

(defun agenda-heading-inherited-tags (contexts file-tags local-tags)
  (agenda-unique-strings
   (append file-tags
           (loop :for context :in (reverse contexts)
                 :nconc (copy-list (agenda-heading-context-tags context)))
           local-tags)))

(defun agenda-build-filter-metadata (lines source)
  "Return a source-line table of category, tags, Effort, and top headline."
  (multiple-value-bind (file-category file-tags)
      (agenda-file-filter-metadata lines source)
    (let ((table (make-hash-table :test #'eql))
          (contexts '())
          (current nil)
          (property-eligible-p nil)
          (property-drawer-p nil)
          (block-p nil))
      (loop :for line :in lines
            :for line-number :from 1
            :do
               (cond
                 (block-p
                  (when (ppcre:scan "(?i)^\\s*#\\+end_" line)
                    (setf block-p nil)))
                 ((ppcre:scan "(?i)^\\s*#\\+begin_" line)
                  (setf block-p t
                        property-eligible-p nil
                        property-drawer-p nil))
                 (t
                  (multiple-value-bind (level title local-tags)
                      (roam-org-heading-fields line)
                    (if level
                        (progn
                          (loop :while (and contexts
                                            (>= (agenda-heading-context-level
                                                 (first contexts))
                                                level))
                                :do (pop contexts))
                          (let* ((top-title
                                   (agenda-filter-top-title
                                    (if contexts
                                        (agenda-heading-context-title
                                         (car (last contexts)))
                                        title)))
                                 (metadata
                                   (make-agenda-item-metadata
                                    :category
                                    (agenda-heading-inherited-category
                                     contexts file-category)
                                    :tags
                                    (agenda-heading-inherited-tags
                                     contexts file-tags local-tags)
                                    :top-headline top-title)))
                            (setf current
                                  (make-agenda-heading-context
                                   :level level
                                   :title title
                                   :tags local-tags
                                   :metadata metadata)
                                  (gethash line-number table) metadata)
                            (push current contexts))
                          (setf property-eligible-p t
                                property-drawer-p nil))
                        (when current
                          (let ((trimmed
                                  (string-trim
                                   '(#\Space #\Tab #\Return) line)))
                            (cond
                              (property-drawer-p
                               (if (string-equal trimmed ":END:")
                                   (setf property-drawer-p nil)
                                   (multiple-value-bind (name value)
                                       (agenda-filter-property-fields trimmed)
                                     (cond
                                       ((and name (string= name "CATEGORY")
                                             (plusp (length value)))
                                        (setf
                                         (agenda-heading-context-category current)
                                         value
                                         (agenda-item-metadata-category
                                          (agenda-heading-context-metadata current))
                                         value))
                                       ((and name (string= name "EFFORT"))
                                        (setf
                                         (agenda-item-metadata-effort
                                          (agenda-heading-context-metadata current))
                                         value))))))
                              ((and property-eligible-p
                                    (ppcre:scan *planning-line-scanner* line)))
                              ((and property-eligible-p
                                    (string-equal trimmed ":PROPERTIES:"))
                               (setf property-drawer-p t
                                     property-eligible-p nil))
                              (t
                               (setf property-eligible-p nil))))))))))
      table)))

(defun agenda-enrich-filter-metadata (source items)
  "Attach source-derived agenda filter metadata to ITEMS."
  (with-open-file (stream source :direction :input :external-format :utf-8)
    (let* ((lines (loop :for line := (read-line stream nil nil)
                        :while line :collect line))
           (table (agenda-build-filter-metadata lines source)))
      (dolist (item items items)
        (alexandria:when-let ((metadata (gethash (agenda-item-line item) table)))
          (setf (agenda-item-category item)
                (agenda-item-metadata-category metadata)
                (agenda-item-tags item)
                (copy-list (agenda-item-metadata-tags metadata))
                (agenda-item-effort item)
                (agenda-item-metadata-effort metadata)
                (agenda-item-top-headline item)
                (agenda-item-metadata-top-headline metadata)))))))

;;; --- date helpers --------------------------------------------------------

(defun today-iso (&optional (now (funcall *agenda-now-function*)))
  "Today as a YYYY-MM-DD string."
  (iso-date-for-time now))

(defun iso-plus-days (days &optional (now (funcall *agenda-now-function*)))
  "Today + DAYS as YYYY-MM-DD, anchored at noon across DST transitions."
  (iso-date-add-calendar (today-iso now) days #\d))

(defun agenda-date-components (date)
  (iso-date-components date))

(defun agenda-date-ordinal (date)
  "Return a timezone-independent day ordinal for DATE."
  (multiple-value-bind (year month day) (agenda-date-components date)
    (floor (encode-universal-time 0 0 12 day month year 0) 86400)))

(defun agenda-add-calendar (date amount unit)
  "Add AMOUNT units UNIT (d, w, m, or y) to DATE."
  (or (iso-date-add-calendar date amount unit)
      (error "Calendar offset leaves the supported ISO date range")))

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

(defun group-items (items &optional (now (funcall *agenda-now-function*))
                                   start-date horizon-date)
  "Bucket ITEMS into (overdue today upcoming todos), each a list of items.
Given the fixed YYYY-MM-DD format, plain string comparison is correct date
comparison. Dated DONE/CANCELLED items are dropped from the dated sections."
  (let ((today (or start-date (today-iso now)))
        (horizon (or horizon-date
                     (iso-plus-days *agenda-upcoming-days* now)))
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

(defun agenda-default-sections
    (items &optional (now (funcall *agenda-now-function*))
                     start-date horizon-date)
  "Return the established grouped summary as renderable sections."
  (multiple-value-bind (overdue today upcoming todos)
      (group-items items now start-date horizon-date)
    (list
     (make-agenda-section :key :overdue :title "Overdue" :items overdue)
     (make-agenda-section
      :key :today
      :title (if (or (null start-date)
                     (string= start-date (today-iso now)))
                 "Today"
                 (format nil "Selected (~a)" start-date))
      :items today
      :date (or start-date (today-iso now)))
     (make-agenda-section
      :key :upcoming
      :title (format nil "Upcoming (~a days)" *agenda-upcoming-days*)
      :items upcoming)
     (make-agenda-section :key :todos :title "TODOs" :items todos))))

(defun agenda-effective-sections (buffer items now)
  (if *agenda-sections-function*
      (funcall *agenda-sections-function* buffer items now)
      (agenda-default-sections items now)))

(defun agenda-effective-header-label (buffer now)
  (if *agenda-header-label-function*
      (funcall *agenda-header-label-function* buffer now)
      (today-iso now)))

(defun agenda-effective-date-range (buffer now)
  "Return BUFFER's inclusive displayed date range."
  (if *agenda-date-range-function*
      (funcall *agenda-date-range-function* buffer now)
      (values (today-iso now) (iso-plus-days *agenda-upcoming-days* now))))

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

(defun agenda-item-mark-base-key (item)
  "Return ITEM's source-aware identity, excluding duplicate render position."
  (list (uiop:native-namestring (agenda-item-file item))
        (agenda-item-line item)
        (agenda-item-heading item)
        (agenda-item-kind item)
        (agenda-item-date item)
        (agenda-item-time item)
        (agenda-item-occurrence-index item)))

(defun agenda-item-mark-key (item duplicate-index)
  "Return ITEM's identity including DUPLICATE-INDEX among identical rows."
  (append (agenda-item-mark-base-key item) (list duplicate-index)))

(defun agenda-row-mark-key-at-point (point)
  "Return POINT's source-aware bulk-mark identity, or NIL off an entry row."
  (alexandria:when-let ((file (text-property-at point :agenda-file)))
    (list (uiop:native-namestring file)
          (text-property-at point :agenda-line)
          (text-property-at point :agenda-heading)
          (text-property-at point :agenda-kind)
          (text-property-at point :agenda-date)
          (text-property-at point :agenda-time)
          (text-property-at point :agenda-occurrence-index)
          (text-property-at point :agenda-duplicate-index))))

(defun insert-agenda-section (buffer title items duplicate-counts
                              &optional date key)
  "Insert TITLE and ITEMS with exact source file/line text properties."
  (let ((point (buffer-end-point buffer)))
    (with-point ((start point))
      (insert-string point (format nil "~a~%" title))
      (put-text-property start point :agenda-section-key key)
      (when date
        (put-text-property start point :agenda-view-date date)))
    (if (null items)
        (insert-string point (format nil "  (none)~%"))
        (dolist (item items)
          (let* ((base-key (agenda-item-mark-base-key item))
                 (duplicate-index (1+ (gethash base-key duplicate-counts 0)))
                 (mark-key (agenda-item-mark-key item duplicate-index))
                 (marked-p
                   (and *agenda-row-marked-p-function*
                        (funcall *agenda-row-marked-p-function*
                                 buffer mark-key))))
            (setf (gethash base-key duplicate-counts) duplicate-index)
            (with-point ((start point))
              (insert-string point
                             (format nil "~a ~a~%"
                                     (if marked-p ">" " ")
                                     (agenda-display-line item)))
              (put-text-property start point :agenda-file
                                 (agenda-item-file item))
              (put-text-property start point :agenda-line
                                 (agenda-item-line item))
              (put-text-property start point :agenda-heading
                                 (agenda-item-heading item))
              (put-text-property start point :agenda-kind
                                 (agenda-item-kind item))
              (put-text-property start point :agenda-date
                                 (agenda-item-date item))
              (put-text-property start point :agenda-time
                                 (agenda-item-time item))
              (put-text-property start point :agenda-occurrence-index
                                 (agenda-item-occurrence-index item))
              (put-text-property start point :agenda-category
                                 (agenda-item-category item))
              (put-text-property start point :agenda-tags
                                 (agenda-item-tags item))
              (put-text-property start point :agenda-effort
                                 (agenda-item-effort item))
              (put-text-property start point :agenda-top-headline
                                 (agenda-item-top-headline item))
              (put-text-property start point :agenda-timestamp-line
                                 (agenda-item-timestamp-line item))
              (put-text-property start point :agenda-timestamp-source-line
                                 (agenda-item-timestamp-source-line item))
              (put-text-property start point :agenda-timestamp-start
                                 (agenda-item-timestamp-start item))
              (put-text-property start point :agenda-timestamp-raw
                                 (agenda-item-timestamp-raw item))
              (put-text-property start point :agenda-duplicate-index
                                 duplicate-index)))))
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

(defun render-agenda (buffer items &optional failures clock-report)
  "Fill BUFFER with grouped ITEMS and any source FAILURES on the editor thread."
  (let ((now (funcall *agenda-now-function*))
        (restore-key (buffer-value buffer 'lem-yath-agenda-restore-entry))
        (duplicate-counts (make-hash-table :test #'equal))
        (visible-items
          (if *agenda-item-filter-function*
              (remove-if-not
               (lambda (item)
                 (funcall *agenda-item-filter-function* buffer item))
               items)
              items)))
    (setf (buffer-value buffer 'lem-yath-agenda-cached-items) items
          (buffer-value buffer 'lem-yath-agenda-cached-failures) failures
          (buffer-value buffer 'lem-yath-agenda-cached-clock-report)
          clock-report
          (buffer-value buffer 'lem-yath-agenda-cache-ready) t)
    (setf (buffer-value buffer 'lem-yath-agenda-restore-entry) nil)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((sections (agenda-effective-sections buffer visible-items now)))
        (when *agenda-section-transform-function*
          (dolist (section sections)
            (setf (agenda-section-items section)
                  (funcall *agenda-section-transform-function*
                           buffer
                           (agenda-section-key section)
                           (agenda-section-items section)))))
        (insert-string
         (buffer-end-point buffer)
         (format nil "Agenda  (~a)~a~%~%"
                 (agenda-effective-header-label buffer now)
                 (if *agenda-status-function*
                     (or (funcall *agenda-status-function* buffer) "")
                     "")))
        (dolist (section sections)
          (insert-agenda-section
           buffer
           (agenda-section-title section)
           (agenda-section-items section)
           duplicate-counts
           (agenda-section-date section)
           (agenda-section-key section)))
        (insert-agenda-failures buffer failures)
        (when (and clock-report
                   (buffer-value buffer 'lem-yath-agenda-clockreport-mode)
                   (fboundp 'agenda-clock-insert-report))
          (agenda-clock-insert-report buffer clock-report))))
    (unless (and restore-key (agenda-restore-entry-point buffer restore-key))
      (buffer-start (buffer-point buffer)))
    (dolist (function *agenda-post-render-functions*)
      (funcall function buffer)))
  (setf (buffer-read-only-p buffer) t)
  (buffer-unmark buffer)
  (redraw-display))

(defun agenda-collect-items ()
  "Return parsed items, per-source failures, and discovered agenda files."
  (handler-case
      (multiple-value-bind (files discovery-failures) (agenda-org-files)
        (let ((items '())
              (failures (reverse discovery-failures)))
          (dolist (file files)
            (multiple-value-bind (parsed errors) (parse-org-file file)
              (handler-case
                  (agenda-enrich-filter-metadata file parsed)
                (error (condition)
                  (push condition errors)))
              (setf items (nconc items parsed))
              (dolist (error errors)
                (push (cons file error) failures))))
          (values items (nreverse failures) files)))
    (error (condition)
      (values nil (list (cons nil condition)) nil))))

(defun agenda-buffer-live-p (buffer)
  (not (null (member buffer (buffer-list) :test #'eq))))

(defun agenda-buffer-generation (buffer)
  (or (buffer-value buffer 'lem-yath-agenda-generation) 0))

(defun agenda-next-generation (buffer)
  (setf (buffer-value buffer 'lem-yath-agenda-generation)
        (1+ (agenda-buffer-generation buffer))))

(defun agenda-render-if-current
    (buffer generation items &optional failures clock-report)
  "Render ITEMS only when GENERATION still owns the live agenda BUFFER."
  (when (and (agenda-buffer-live-p buffer)
             (mode-active-p buffer 'lem-yath-agenda-mode)
             (= generation (agenda-buffer-generation buffer)))
    (render-agenda buffer items failures clock-report)
    t))

(defun agenda-scan-running-p (buffer)
  (not (null (buffer-value buffer 'lem-yath-agenda-scan-running))))

(defun agenda-refresh-pending-p (buffer)
  (not (null (buffer-value buffer 'lem-yath-agenda-refresh-pending))))

(defun agenda-scan-worker
    (buffer generation clock-report-p range-start range-end)
  "Collect agenda items off-thread and marshal one completion event."
  (multiple-value-bind (items failures files)
      (handler-case
          (agenda-collect-items)
        (error (condition)
          (values nil (list (cons nil condition)) nil)))
    (let ((clock-report nil))
      (when (and clock-report-p
                 (fboundp 'agenda-clock-collect-report))
        (multiple-value-bind (report report-failures)
            (handler-case
                (agenda-clock-collect-report files range-start range-end)
              (error (condition)
                (values nil (list (cons nil condition)))))
          (setf clock-report report
                failures (nconc failures report-failures))))
      (send-event
       (lambda ()
         (handler-case
             (agenda-finish-scan
              buffer generation items failures clock-report)
           (error (condition)
             (message "Agenda render failed: ~a" condition))))))))

(defun agenda-launch-scan (buffer generation)
  "Launch GENERATION, maintaining at most one worker for BUFFER."
  (let ((clock-report-p
          (not (null
                (buffer-value buffer 'lem-yath-agenda-clockreport-mode))))
        (now (funcall *agenda-now-function*)))
    (multiple-value-bind (range-start range-end)
        (agenda-effective-date-range buffer now)
      (setf (buffer-value buffer 'lem-yath-agenda-scan-running) t)
      (handler-case
          (bt2:make-thread
           (lambda ()
             (agenda-scan-worker
              buffer generation clock-report-p range-start range-end))
           :name (format nil "lem-yath/agenda-scan-~d" generation))
        (error (condition)
          (setf (buffer-value buffer 'lem-yath-agenda-scan-running) nil
                (buffer-value buffer 'lem-yath-agenda-refresh-pending) nil)
          (agenda-render-if-current
           buffer generation nil (list (cons nil condition)))
          (message "Agenda scan could not start: ~a" condition)
          nil)))))

(defun agenda-finish-scan
    (buffer generation items failures &optional clock-report)
  "Finish one worker and run at most one coalesced replacement refresh."
  (when (agenda-buffer-live-p buffer)
    (setf (buffer-value buffer 'lem-yath-agenda-scan-running) nil)
    (when (mode-active-p buffer 'lem-yath-agenda-mode)
      (if (agenda-refresh-pending-p buffer)
          (progn
            (setf (buffer-value buffer 'lem-yath-agenda-refresh-pending) nil)
            (agenda-launch-scan buffer (agenda-buffer-generation buffer)))
          (agenda-render-if-current
           buffer generation items failures clock-report)))))

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
    (dolist (function *agenda-buffer-cleanup-functions*)
      (funcall function buffer))
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
  (let ((file (or (text-property-at (current-point) :agenda-file)
                  (text-property-at
                   (current-point) :agenda-clock-report-file)))
        (line (or (text-property-at (current-point) :agenda-line)
                  (text-property-at
                   (current-point) :agenda-clock-report-line))))
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

(defun agenda-read-date (label &optional default-date)
  "Read an Org-style date for LABEL, returning DATE and true on success."
  (values
   (org-read-date-prompt
    label
    :default-date (or default-date
                      (org-date-today (funcall *agenda-now-function*)))
    :now (funcall *agenda-now-function*))
   t))

(defun agenda-source-planning-components
    (file line expected-heading kind)
  "Return KIND's date and extra syntax after validating an agenda source row."
  (unless (and file (integerp line) (plusp line) expected-heading)
    (error "No mutable agenda heading on this line"))
  (let ((buffer (find-file-buffer file)))
    (with-current-buffer buffer
      (with-point ((heading (buffer-start-point buffer)))
        (unless (or (= line 1) (line-offset heading (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (unless (string= expected-heading (line-string heading))
          (error "Agenda source changed; refresh before editing"))
        (org-planning-field-components heading kind)))))

(defun agenda-planning-restore-key (file line heading preferred-kind)
  "Choose the best post-refresh row for a just-edited planning field."
  (let* ((preferred-date
           (org-planning-field-date heading preferred-kind))
         (other-kind (if (string= preferred-kind "DEADLINE")
                         "SCHEDULED"
                         "DEADLINE"))
         (other-date (and (null preferred-date)
                          (org-planning-field-date heading other-kind))))
    (cond
      (preferred-date
       (list file line preferred-kind preferred-date nil nil))
      (other-date
       (list file line other-kind other-date nil nil))
      (t
       (list file line nil nil nil nil)))))

(defun agenda-apply-source-planning
    (file line expected-heading kind expected-date expected-extra
     operation &key date extra)
  "Apply one validated planning OPERATION and save its source immediately."
  (unless (and file (integerp line) (plusp line) expected-heading)
    (error "No mutable agenda heading on this line"))
  (let ((buffer (find-file-buffer file))
        (result nil)
        (restore-key nil))
    (with-current-buffer buffer
      (when (buffer-read-only-p buffer)
        (error "Agenda source is read-only: ~a" file))
      (with-point ((heading (buffer-start-point buffer)))
        (unless (or (= line 1) (line-offset heading (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (unless (string= expected-heading (line-string heading))
          (error "Agenda source changed; refresh before editing"))
        (multiple-value-bind (current-date current-extra)
            (org-planning-field-components heading kind)
          (unless (and (equal expected-date current-date)
                       (equal expected-extra current-extra))
            (error "Agenda source planning changed; refresh before editing")))
        (setf result
              (ecase operation
                (:set (org-set-planning-field heading kind date))
                (:delay (org-set-planning-field
                         heading kind date :extra extra))
                (:remove (org-remove-planning-field heading kind))))
        (setf restore-key
              (agenda-planning-restore-key file line heading kind)))
      (save-buffer buffer))
    (values result restore-key)))

(defun agenda-change-planning (kind label argument)
  "Prompt for and persist planning KIND on the current agenda entry."
  (let ((agenda-buffer (current-buffer))
        (file (text-property-at (current-point) :agenda-file))
        (line (text-property-at (current-point) :agenda-line))
        (heading (text-property-at (current-point) :agenda-heading))
        (magnitude (org-prefix-magnitude argument)))
    (if (null file)
        (message "No agenda entry on this line.")
        (handler-case
            (multiple-value-bind (old-date old-extra)
                (agenda-source-planning-components file line heading kind)
              (multiple-value-bind (operation date extra selected-p)
                  (cond
                    ((= magnitude 4)
                     (values :remove nil nil t))
                    ((= magnitude 16)
                     (if old-date
                         (multiple-value-bind (target chosen-p)
                             (agenda-read-date
                              (if (string= kind "DEADLINE")
                                  "Warn starting from"
                                  "Delay until")
                              old-date)
                           (values
                            :delay old-date
                            (and chosen-p
                                 (org-planning-extra-with-delay
                                  old-extra
                                  (abs (- (org-date-day-number target)
                                          (org-date-day-number old-date)))))
                            chosen-p))
                         (progn
                           (message "No ~a information to update"
                                    (string-downcase label))
                           (values nil nil nil nil))))
                    (t
                     (multiple-value-bind (new-date chosen-p)
                         (agenda-read-date (format nil "~a date" label)
                                           old-date)
                       (values :set new-date nil chosen-p))))
                (when (and operation selected-p)
                  (multiple-value-bind (result restore-key)
                      (agenda-apply-source-planning
                       file line heading kind old-date old-extra operation
                       :date date :extra extra)
                    (setf (buffer-value agenda-buffer
                                        'lem-yath-agenda-restore-entry)
                          restore-key)
                    (agenda-start-scan agenda-buffer)
                    (message (if (eq operation :remove)
                                 (if result "Removed ~a" "No ~a to remove")
                                 "~a")
                             (if (eq operation :remove) kind result))))))
          (error (condition)
            (message "Agenda ~a failed: ~a" label condition))))))

(define-command lem-yath-agenda-schedule (argument) (:universal-nil)
  "Set the current agenda heading's SCHEDULED date and save its source."
  (agenda-change-planning "SCHEDULED" "Schedule" argument))

(define-command lem-yath-agenda-deadline (argument) (:universal-nil)
  "Set the current agenda heading's DEADLINE date and save its source."
  (agenda-change-planning "DEADLINE" "Deadline" argument))

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

(defparameter *agenda-tags-prompt-keymap*
  (let ((keymap (make-keymap :description "Org agenda tags")))
    ;; CRM accepts the current valid tag list on Return even while candidates
    ;; for an additional tag remain visible.  Tab retains candidate selection.
    (define-key keymap "Return" 'lem-yath-prompt-execute)
    keymap))

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
      :special-keymap *agenda-tags-prompt-keymap*
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
(define-key *lem-yath-agenda-vi-keymap* "g r" 'lem-yath-agenda-refresh)
(define-key *lem-yath-agenda-vi-keymap* "g R" 'lem-yath-agenda-refresh)
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
  ;; Evil-Org's motion map shadows the base Org agenda map, but C-z Emacs
  ;; state must expose the base bindings (notably the user's custom I/O).
  (unless (lem-yath-emacs-state-p)
    (list *lem-yath-agenda-vi-keymap*)))

(define-key *lem-yath-agenda-mode-keymap* "Return" 'lem-yath-agenda-visit)
(define-key *lem-yath-agenda-mode-keymap* "g" 'lem-yath-agenda-refresh)
(define-key *lem-yath-agenda-mode-keymap* "t" 'lem-yath-agenda-todo)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-s" 'lem-yath-agenda-schedule)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-d" 'lem-yath-agenda-deadline)
(define-key *lem-yath-agenda-mode-keymap* "+" 'lem-yath-agenda-priority-up)
(define-key *lem-yath-agenda-mode-keymap* "-" 'lem-yath-agenda-priority-down)
(define-key *lem-yath-agenda-mode-keymap* "c t" 'lem-yath-agenda-set-tags)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-q" 'lem-yath-agenda-set-tags)
(define-key *lem-yath-agenda-mode-keymap* "q" 'quit-active-window)

(remove-hook *post-command-hook* 'agenda-priority-post-command)
(add-hook *post-command-hook* 'agenda-priority-post-command)
