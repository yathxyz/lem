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

(defvar *agenda-item-motion-functions* nil
  "Functions called after point moves between source-backed agenda rows.")

(defvar *agenda-item-projection-function* nil
  "Optional function projecting parsed ITEMS for agenda display.

The function receives ITEMS and NOW and returns display items.  Parsed cached
items remain immutable so projections can add reminder rows safely.")

(defvar *agenda-planning-restore-key-function* nil
  "Optional function refining a planning edit's post-refresh row key.")

(defvar *agenda-day-sort-function* nil
  "Optional function returning ITEMS in configured single-day agenda order.")

(defvar *agenda-section-layout-function* nil
  "Optional function interleaving source items and display decorations.")

(defvar *agenda-scan-scope-function* nil
  "Optional function restricting one agenda scan.

The function receives BUFFER, FILES, and discovery FAILURES, and returns three
values: the files to scan, the failures to retain, and an optional predicate
called with a source file and source line.")

;;; --- parsing -------------------------------------------------------------

(defstruct (agenda-item (:constructor make-agenda-item))
  "One parsed heading: its TODO keyword, text, source file/line and date."
  keyword text file line heading date kind event-p end-date repeater time
  end-time range-end-time occurrence-index occurrence-count
  timestamp-line timestamp-source-line timestamp-start timestamp-raw
  timestamp-first-raw timestamp-second-raw timestamp-heading-line-p
  category tags effort top-headline level properties search-text
  planning-suffix metadata-line
  anniversary-year anniversary-month anniversary-day
  display-date reminder-kind reminder-days)

(defstruct (agenda-item-metadata (:constructor make-agenda-item-metadata))
  category tags effort top-headline level properties search-text)

(defstruct (agenda-heading-context (:constructor make-agenda-heading-context))
  level title tags category metadata)

(defstruct (agenda-section (:constructor make-agenda-section))
  key title items date)

(defstruct (agenda-section-decoration
            (:constructor make-agenda-section-decoration))
  "One display-only agenda row with no source identity."
  text properties)

(defparameter *heading-scanner*
  (ppcre:create-scanner
   (format nil "^\\*+\\s+(?:(~{~a~^|~})\\s+)?(.*)$"
           *org-todo-keywords*))
  "Matches an org heading, optionally capturing a leading TODO keyword.")

(defvar *planning-scanner*
  (ppcre:create-scanner
   "(SCHEDULED|DEADLINE):\\s*<(\\d{4}-\\d{2}-\\d{2})([^>]*)>")
  "Match a planning kind, date, and post-date timestamp syntax.")

(defvar *planning-line-scanner*
  (ppcre:create-scanner "^\\s*(?:SCHEDULED|DEADLINE):")
  "Matches an Org planning line immediately below a heading.")

(defvar *active-timestamp-scanner*
  (ppcre:create-scanner "<([^>\\r\\n]+)>(?:--<([^>\\r\\n]+)>)?")
  "Matches one active Org timestamp or timestamp range.")

(defvar *timestamp-date-scanner*
  (ppcre:create-scanner "^(\\d{4}-\\d{2}-\\d{2})(?:\\s|$)")
  "Extracts the date at the start of active timestamp contents.")

(defvar *timestamp-time-range-scanner*
  (ppcre:create-scanner
   "(?:^|\\s)([0-9]{1,2}:[0-9]{2})(?:-([0-9]{1,2}:[0-9]{2}))?(?:\\s|$)")
  "Extracts optional start and end times from active timestamp contents.")

(defvar *timestamp-repeater-scanner*
  (ppcre:create-scanner "(?:^|\\s)([.+]*\\+[0-9]+[hHdDwWmMyY])(?:\\s|$)")
  "Extracts a supported Org repeater cookie.")

(defvar *agenda-plain-time-scanner*
  (ppcre:create-scanner
   "(?i)((?:[012]?[0-9](?::[0-5][0-9](?:am|pm)?|am|pm))(?:--?(?:[012]?[0-9](?::[0-5][0-9](?:am|pm)?|am|pm)))?)")
  "Matches Org's ordinary headline time or time range forms.")

(defvar *agenda-plain-time-component-scanner*
  (ppcre:create-scanner
   "(?i)^([012]?[0-9])(?::([0-5][0-9]))?(am|pm)?$")
  "Parses one component of an ordinary Org headline time.")

(defvar *agenda-org-anniversary-scanner*
  (ppcre:create-scanner
   "^\\s*%%\\(org-anniversary\\s+([0-9]{1,4})\\s+([0-9]{1,2})\\s+([0-9]{1,2})\\)\\s*(.*)$")
  "Matches the safe diary sexp form used by the configured Org sources.")

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

(defun agenda-item-with-planning (item kind date suffix)
  (multiple-value-bind (timestamp-time timestamp-end-time)
      (agenda-timestamp-times suffix)
    (multiple-value-bind (heading-time heading-end-time start end)
        (unless timestamp-time
          (agenda-heading-time-spec (agenda-item-text item)))
      (make-agenda-item
       :keyword (agenda-item-keyword item)
       :text (if start
                 (agenda-remove-heading-time
                  (agenda-item-text item) start end)
                 (agenda-item-text item))
       :file (agenda-item-file item)
       :line (agenda-item-line item)
       :heading (agenda-item-heading item)
       :date date
       :kind kind
       :event-p nil
       :time (or timestamp-time heading-time)
       :end-time (or timestamp-end-time heading-end-time)
       :planning-suffix suffix))))

(defun agenda-item-with-anniversary (item line-number source-line)
  "Return a safe `org-anniversary' diary item parsed from SOURCE-LINE."
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan *agenda-org-anniversary-scanner* source-line)
    (declare (ignore end))
    (when start
      (let* ((year
               (parse-integer source-line
                              :start (aref registers 0)
                              :end (aref register-ends 0)))
             (month
               (parse-integer source-line
                              :start (aref registers 1)
                              :end (aref register-ends 1)))
             (day
               (parse-integer source-line
                              :start (aref registers 2)
                              :end (aref register-ends 2)))
             (date (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))
        (when (valid-iso-date-p date)
          (make-agenda-item
           :text (string-trim
                  '(#\Space #\Tab)
                  (subseq source-line
                          (aref registers 3) (aref register-ends 3)))
           :file (agenda-item-file item)
           :line line-number
           :heading source-line
           :date date
           :kind "DIARY"
           :event-p t
           :metadata-line (agenda-item-line item)
           :anniversary-year year
           :anniversary-month month
           :anniversary-day day))))))

(defun agenda-timestamp-field (scanner contents)
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan scanner contents)
    (declare (ignore start end))
    (when (and registers (aref registers 0))
      (subseq contents (aref registers 0) (aref register-ends 0)))))

(defun agenda-timestamp-times (contents)
  "Return optional start and end times parsed from timestamp CONTENTS."
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan *timestamp-time-range-scanner* contents)
    (declare (ignore start end))
    (when (and registers (aref registers 0))
      (values
       (subseq contents (aref registers 0) (aref register-ends 0))
       (and (aref registers 1)
            (subseq contents
                    (aref registers 1) (aref register-ends 1)))))))

(defun agenda-heading-position-in-opaque-time-context-p (text position)
  "Return true when POSITION is inside a timestamp or bracketed Org link."
  (flet ((inside-p (open close)
           (let ((opening (position open text :end position :from-end t))
                 (closing (position close text :end position :from-end t)))
             (and opening (or (null closing) (> opening closing))))))
    (or (inside-p #\< #\>) (inside-p #\[ #\]))))

(defun agenda-heading-time-boundary-p (text start end)
  "Return true when START..END is not embedded in an Org word."
  (flet ((word-character-p (character)
           (or (alphanumericp character) (char= character #\_))))
    (and (or (zerop start)
             (not (word-character-p (char text (1- start)))))
         (or (= end (length text))
             (not (word-character-p (char text end)))))))

(defun agenda-normalize-plain-time (time)
  "Normalize one stock Org plain TIME to a 24-hour H:MM string."
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan *agenda-plain-time-component-scanner* time)
    (declare (ignore end))
    (unless start (error "Invalid Org headline time ~s" time))
    (let* ((hour
             (parse-integer time
                            :start (aref registers 0)
                            :end (aref register-ends 0)))
           (minute
             (if (aref registers 1)
                 (parse-integer time
                                :start (aref registers 1)
                                :end (aref register-ends 1))
                 0))
           (suffix
             (and (aref registers 2)
                  (string-downcase
                   (subseq time
                           (aref registers 2)
                           (aref register-ends 2)))))
           (normalized-hour
             (cond
               ((null suffix) hour)
               ((string= suffix "am") (if (= hour 12) 0 hour))
               ((= hour 12) 12)
               (t (+ hour 12)))))
      (format nil "~d:~2,'0d" normalized-hour minute))))

(defun agenda-heading-time-spec (text)
  "Return normalized start/end, plus exact removable bounds, from TEXT."
  (loop :with offset := 0
        :while (< offset (length text))
        :do (multiple-value-bind (start end registers register-ends)
                (ppcre:scan *agenda-plain-time-scanner* text :start offset)
              (declare (ignore start))
              (unless (and registers (aref registers 0)) (return))
              (let ((match-start (aref registers 0))
                    (match-end (aref register-ends 0)))
                (if (or (not (agenda-heading-time-boundary-p
                              text match-start match-end))
                        (agenda-heading-position-in-opaque-time-context-p
                         text match-start))
                    (setf offset end)
                    (let* ((raw (subseq text match-start match-end))
                           (separator (ppcre:scan "--?" raw))
                           (first (if separator (subseq raw 0 separator) raw))
                           (second
                             (and separator
                                  (subseq raw
                                          (+ separator
                                             (if (and (< (1+ separator)
                                                         (length raw))
                                                      (char= (char raw
                                                                   (1+ separator))
                                                             #\-))
                                                 2 1))))))
                      (loop :while (and (< match-end (length text))
                                        (member (char text match-end)
                                                '(#\Space #\Tab)))
                            :do (incf match-end))
                      (return
                        (values (agenda-normalize-plain-time first)
                                (and second
                                     (agenda-normalize-plain-time second))
                                match-start match-end))))))))

(defun agenda-remove-heading-time (text start end)
  (string-trim '(#\Space #\Tab)
               (concatenate 'string
                            (subseq text 0 start)
                            (subseq text end))))

(defun agenda-parse-active-timestamp (contents)
  "Return DATE, START-TIME, END-TIME, and REPEATER from CONTENTS."
  (let ((date (agenda-timestamp-field *timestamp-date-scanner* contents)))
    (when (and date (valid-iso-date-p date))
      (multiple-value-bind (time end-time) (agenda-timestamp-times contents)
        (values date time end-time
                (agenda-timestamp-field
                 *timestamp-repeater-scanner* contents))))))

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
                (multiple-value-bind (date time end-time repeater)
                    (agenda-parse-active-timestamp first)
                  (when date
                    (multiple-value-bind (end-date range-end-time)
                        (if second
                            (agenda-parse-active-timestamp second)
                            (values nil nil))
                      (push (list :date date :time time :end-time end-time
                                  :range-end-time range-end-time
                                  :repeater repeater
                                  :end-date end-date
                                  :first-raw (format nil "<~a>" first)
                                  :second-raw
                                  (and second (format nil "<~a>" second))
                                  :start start
                                  :raw (subseq line start end))
                            specs)))))
              (setf offset end))
        :finally (return (nreverse specs))))

(defun agenda-item-with-event
    (item spec source-line-number source-line &optional heading-line-p)
  (let ((text
          (if (and heading-line-p (null (getf spec :end-date)))
              (string-trim
               '(#\Space #\Tab)
               (ppcre:regex-replace-all
                (ppcre:quote-meta-chars (getf spec :raw))
                (agenda-item-text item) ""))
              (agenda-item-text item))))
    (multiple-value-bind (heading-time heading-end-time start end)
        (unless (getf spec :time) (agenda-heading-time-spec text))
      (make-agenda-item
       :keyword (agenda-item-keyword item)
       :text (if start (agenda-remove-heading-time text start end) text)
       :file (agenda-item-file item)
       :line (agenda-item-line item)
       :heading (agenda-item-heading item)
       :date (getf spec :date)
       :kind "TIMESTAMP"
       :event-p t
       :end-date (getf spec :end-date)
       :repeater (getf spec :repeater)
       :time (or (getf spec :time) heading-time)
       :end-time (or (getf spec :end-time) heading-end-time)
       :range-end-time (getf spec :range-end-time)
       :timestamp-line source-line-number
       :timestamp-source-line source-line
       :timestamp-start (getf spec :start)
       :timestamp-raw (getf spec :raw)
       :timestamp-first-raw (getf spec :first-raw)
       :timestamp-second-raw (getf spec :second-raw)
       :timestamp-heading-line-p heading-line-p))))

(defun parse-org-stream (in path)
  "Return parsed agenda items and, as a second value, parser warnings.
Only the planning line immediately below a heading is structural.  A heading
with both SCHEDULED and DEADLINE fields produces one item for each field.
Ordinary active timestamps belong to their containing visible heading."
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
                            (ppcre:scan "(?:^|:)ARCHIVE(?::|\\s*$)" line)))))
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
                                     (ppcre:do-register-groups
                                         (kind date suffix)
                                         (*planning-scanner* line)
                                       (if (valid-iso-date-p date)
                                           (progn
                                             (push
                                              (agenda-item-with-planning
                                               current kind date suffix)
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
                                     (t
                                      (alexandria:if-let
                                          ((anniversary
                                             (agenda-item-with-anniversary
                                              current lineno line)))
                                        (push anniversary items)
                                        (emit-events line lineno)))))))))))
             (finish-current))
           (values (nreverse items) (nreverse warnings))))

(defun parse-org-file (path &optional (contents nil contents-p))
  "Parse PATH from disk, or from supplied immutable CONTENTS when present."
  (handler-case
      (if contents-p
          (with-input-from-string (in contents)
            (parse-org-stream in path))
          (with-open-file (in path :direction :input :external-format :utf-8)
            (parse-org-stream in path)))
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
  "Return Org matching metadata and entry text indexed by heading line."
  (multiple-value-bind (file-category file-tags)
      (agenda-file-filter-metadata lines source)
    (let ((table (make-hash-table :test #'eql))
          (contexts '())
          (current nil)
          (search-lines '())
          (property-eligible-p nil)
          (property-drawer-p nil)
          (block-p nil))
      (labels ((finish-search ()
                 (when current
                   (setf (agenda-item-metadata-search-text
                          (agenda-heading-context-metadata current))
                         (format nil "~{~a~^~%~}" (nreverse search-lines))))
                 (setf search-lines nil))
               (remember-line (line)
                 (when current (push line search-lines))))
        (loop :for line :in lines
              :for line-number :from 1
              :do
                 (cond
                   (block-p
                    (remember-line line)
                    (when (ppcre:scan "(?i)^\\s*#\\+end_" line)
                      (setf block-p nil)))
                   ((ppcre:scan "(?i)^\\s*#\\+begin_" line)
                    (remember-line line)
                    (setf block-p t
                          property-eligible-p nil
                          property-drawer-p nil))
                   (t
                    (multiple-value-bind (level title local-tags)
                        (roam-org-heading-fields line)
                      (if level
                          (progn
                            (finish-search)
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
                                      :top-headline top-title
                                      :level level)))
                              (setf current
                                    (make-agenda-heading-context
                                     :level level
                                     :title title
                                     :tags local-tags
                                     :metadata metadata)
                                    (gethash line-number table) metadata
                                    search-lines (list line))
                              (push current contexts))
                            (setf property-eligible-p t
                                  property-drawer-p nil))
                          (when current
                            (remember-line line)
                            (let ((trimmed
                                    (string-trim
                                     '(#\Space #\Tab #\Return) line)))
                              (cond
                                (property-drawer-p
                                 (if (string-equal trimmed ":END:")
                                     (setf property-drawer-p nil)
                                     (multiple-value-bind (name value)
                                         (agenda-filter-property-fields trimmed)
                                       (when name
                                         (push (cons name value)
                                               (agenda-item-metadata-properties
                                                (agenda-heading-context-metadata
                                                 current)))
                                         (cond
                                           ((and (string= name "CATEGORY")
                                                 (plusp (length value)))
                                            (setf
                                             (agenda-heading-context-category
                                              current)
                                             value
                                             (agenda-item-metadata-category
                                              (agenda-heading-context-metadata
                                               current))
                                             value))
                                           ((string= name "EFFORT")
                                            (setf
                                             (agenda-item-metadata-effort
                                              (agenda-heading-context-metadata
                                               current))
                                             value)))))))
                                ((and property-eligible-p
                                      (ppcre:scan *planning-line-scanner* line)))
                                ((and property-eligible-p
                                      (string-equal trimmed ":PROPERTIES:"))
                                 (setf property-drawer-p t
                                       property-eligible-p nil))
                                (t
                                 (setf property-eligible-p nil))))))))))
        (finish-search))
      table)))

(defun agenda-read-source-lines (source &optional (contents nil contents-p))
  "Return SOURCE lines from disk or supplied immutable CONTENTS."
  (labels ((read-lines (stream)
             (loop :for line := (read-line stream nil nil)
                   :while line :collect line)))
    (if contents-p
        (with-input-from-string (stream contents)
          (read-lines stream))
        (with-open-file (stream source :direction :input
                                       :external-format :utf-8)
          (read-lines stream)))))

(defun agenda-enrich-filter-metadata
    (source items &key (contents nil contents-p) line-predicate)
  "Attach source-derived agenda filter metadata to ITEMS."
  (let* ((lines (if contents-p
                    (agenda-read-source-lines source contents)
                    (agenda-read-source-lines source)))
         (table (agenda-build-filter-metadata lines source))
         (scoped-table
           (and line-predicate
                (agenda-build-filter-metadata
                 (loop :for line :in lines
                       :for line-number :from 1
                       :collect (if (funcall line-predicate line-number)
                                    line
                                    ""))
                 source))))
    (dolist (item items items)
      (let* ((line (or (agenda-item-metadata-line item)
                       (agenda-item-line item)))
             (metadata (gethash line table))
             (scoped-metadata (and scoped-table
                                   (gethash line scoped-table))))
        (when metadata
          (setf (agenda-item-category item)
                (agenda-item-metadata-category metadata)
                (agenda-item-tags item)
                (copy-list (agenda-item-metadata-tags metadata))
                (agenda-item-effort item)
                (agenda-item-metadata-effort metadata)
                (agenda-item-top-headline item)
                (agenda-item-metadata-top-headline metadata)
                (agenda-item-level item)
                (agenda-item-metadata-level metadata)
                (agenda-item-properties item)
                (copy-tree
                 (agenda-item-metadata-properties
                  (or scoped-metadata metadata)))
                (agenda-item-search-text item)
                (if scoped-table
                    (and scoped-metadata
                         (agenda-item-metadata-search-text scoped-metadata))
                    (agenda-item-metadata-search-text metadata))))))))

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
        (ppcre:scan "^[.+]*\\+([0-9]+)([hHdDwWmMyY])$" repeater)
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

(defun agenda-anniversary-text (item year)
  "Expand ITEM's safe anniversary age placeholder for YEAR."
  (ppcre:regex-replace-all
   "%d" (agenda-item-text item)
   (princ-to-string (- year (agenda-item-anniversary-year item)))))

(defun agenda-anniversary-occurrences (item today horizon)
  "Expand ITEM's configured `org-anniversary' through the displayed span."
  (multiple-value-bind (today-year today-month today-day)
      (agenda-date-components today)
    (declare (ignore today-month today-day))
    (multiple-value-bind (horizon-year horizon-month horizon-day)
        (agenda-date-components horizon)
      (declare (ignore horizon-month horizon-day))
      (loop :for year :from (max today-year
                                  (agenda-item-anniversary-year item))
              :to horizon-year
            :for date :=
              (format nil "~4,'0d-~2,'0d-~2,'0d"
                      year
                      (agenda-item-anniversary-month item)
                      (agenda-item-anniversary-day item))
            :when (and (valid-iso-date-p date)
                       (not (string< date today))
                       (string<= date horizon))
              :collect
              (let ((occurrence (agenda-item-occurrence item date)))
                (setf (agenda-item-text occurrence)
                      (agenda-anniversary-text item year))
                occurrence)))))

(defun agenda-remove-event-token-from-text (text token)
  (if token
      (string-trim
       '(#\Space #\Tab)
       (ppcre:regex-replace
        (ppcre:quote-meta-chars token) text ""))
      text))

(defun agenda-item-range-occurrence (item date offset count)
  "Return ITEM as one GNU-style day of a multi-date active range."
  (let ((occurrence
          (agenda-item-occurrence item date (1+ offset) count)))
    (setf (agenda-item-range-end-time occurrence) nil)
    (cond
      ((= count 1)
       (unless (agenda-item-end-time occurrence)
         (setf (agenda-item-end-time occurrence)
               (agenda-item-range-end-time item)))
       (when (agenda-item-timestamp-heading-line-p item)
         (setf (agenda-item-text occurrence)
               (agenda-remove-event-token-from-text
                (agenda-item-text item) (agenda-item-timestamp-raw item)))))
      ((zerop offset)
       (when (agenda-item-timestamp-heading-line-p item)
         (setf (agenda-item-text occurrence)
               (agenda-remove-event-token-from-text
                (agenda-item-text item)
                (agenda-item-timestamp-first-raw item)))))
      ((= offset (1- count))
       (setf (agenda-item-time occurrence)
             (agenda-item-range-end-time item)
             (agenda-item-end-time occurrence) nil)
       (when (agenda-item-timestamp-heading-line-p item)
         (setf (agenda-item-text occurrence)
               (agenda-remove-event-token-from-text
                (agenda-item-text item)
                (agenda-item-timestamp-second-raw item)))))
      (t
       (setf (agenda-item-time occurrence) nil
             (agenda-item-end-time occurrence) nil)))
    occurrence))

(defun agenda-hour-repeater-occurrences (item today horizon amount)
  "Expand ITEM's AMOUNT-hour repeater into one stock agenda row per date."
  (alexandria:when-let ((time-value (agenda-item-time-value item)))
    (multiple-value-bind (year month day)
        (agenda-date-components (agenda-item-date item))
      (multiple-value-bind (today-year today-month today-day)
          (agenda-date-components today)
        (let* ((hour (floor time-value 100))
               (minute (mod time-value 100))
               (base-time
                 (encode-universal-time 0 minute hour day month year))
               (range-start
                 (encode-universal-time
                  0 0 0 today-day today-month today-year))
               (step (* amount 60 60))
               (estimate
                 (max 0 (1- (floor (- range-start base-time) step))))
               (last-date nil)
               (occurrences '()))
          (loop :for index :from estimate
                :for occurrence-time := (+ base-time (* index step))
                :for date := (iso-date-for-time occurrence-time)
                :while (string<= date horizon)
                :when (and (not (string< date today))
                           (not (equal date last-date)))
                  :do (push (agenda-item-occurrence item date)
                            occurrences)
                      (setf last-date date))
          (nreverse occurrences))))))

(defun agenda-event-occurrences (item today horizon)
  "Expand ITEM into event rows intersecting TODAY through HORIZON."
  (let ((base (agenda-item-date item))
        (end (agenda-item-end-date item))
        (repeater (agenda-item-repeater item)))
    (cond
      ((agenda-item-anniversary-year item)
       (agenda-anniversary-occurrences item today horizon))
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
                 :collect (agenda-item-range-occurrence
                           item date offset count)))))
      (repeater
       (multiple-value-bind (amount unit) (agenda-repeater-parts repeater)
         (when (and amount (plusp amount))
           (if (char= unit #\h)
               (agenda-hour-repeater-occurrences
                item today horizon amount)
               (loop :with start :=
                       (agenda-repeater-start-index base today amount unit)
                     :for index :from start
                     :for date :=
                       (agenda-add-calendar base (* index amount) unit)
                     :while (string<= date horizon)
                     :collect (agenda-item-occurrence item date))))))
      ((and (not (string< base today)) (string<= base horizon))
       (list (agenda-item-occurrence item base))))))

;;; --- grouping ------------------------------------------------------------

(defun open-keyword-p (kw)
  (and kw (member kw *agenda-open-keywords* :test #'string=)))

(defun done-keyword-p (kw)
  (and kw (member kw *agenda-done-keywords* :test #'string=)))

(defun agenda-item-effective-date (item)
  "Return ITEM's projected display date or its source timestamp date."
  (or (agenda-item-display-date item) (agenda-item-date item)))

(defun agenda-planning-item-p (item)
  (member (agenda-item-kind item) '("SCHEDULED" "DEADLINE")
          :test #'string=))

(defun agenda-sort-day-items (items)
  "Return ITEMS in the active single-day agenda order."
  (if *agenda-day-sort-function*
      (funcall *agenda-day-sort-function* items)
      items))

(defun agenda-item-time-value (item)
  "Return ITEM's start time as an HHMM integer, or NIL when untimed."
  (alexandria:when-let ((time (agenda-item-time item)))
    (let ((colon (position #\: time)))
      (+ (* 100 (parse-integer time :end colon))
         (parse-integer time :start (1+ colon))))))

(defun agenda-sort-dated-items (items)
  "Sort ITEMS by display date, then by the active single-day strategy."
  (let ((remaining
          (stable-sort
           items
           (lambda (a b)
             (string< (or (agenda-item-effective-date a) "")
                      (or (agenda-item-effective-date b) "")))))
        (result '()))
    (loop :while remaining
          :do (let* ((date (agenda-item-effective-date (first remaining)))
                     (group
                       (loop :while (and remaining
                                         (equal date
                                                (agenda-item-effective-date
                                                 (first remaining))))
                             :collect (pop remaining))))
                (setf result
                      (nconc result (agenda-sort-day-items group)))))
    result))

(defun group-items (items &optional (now (funcall *agenda-now-function*))
                                   start-date horizon-date)
  "Bucket ITEMS into (overdue today upcoming todos), each a list of items.
Given the fixed YYYY-MM-DD format, plain string comparison is correct date
comparison. Completed planning rows remain visible on their exact dates, while
completed unscheduled tasks stay out of the TODO section."
  (let ((today (or start-date (today-iso now)))
        (horizon (or horizon-date
                     (iso-plus-days *agenda-upcoming-days* now)))
        (overdue '()) (today-items '()) (upcoming '()) (todos '()))
    (dolist (item items)
      (let ((date (agenda-item-effective-date item))
            (kw (agenda-item-keyword item)))
        (cond
          ((agenda-item-event-p item)
           (dolist (occurrence
                    (agenda-event-occurrences item today horizon))
             (if (string= (agenda-item-date occurrence) today)
                 (push occurrence today-items)
                 (push occurrence upcoming))))
          ((and date (done-keyword-p kw) (agenda-planning-item-p item))
           (cond
             ((string= date today) (push item today-items))
             ((and (string< today date) (string<= date horizon))
              (push item upcoming))))
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
              (agenda-sort-day-items (nreverse today-items))
              (agenda-sort-dated-items (nreverse upcoming))
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
  (let ((projected
          (if *agenda-item-projection-function*
              (funcall *agenda-item-projection-function* items now)
              items)))
    (if *agenda-sections-function*
        (funcall *agenda-sections-function* buffer projected now)
        (agenda-default-sections projected now))))

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

(defun agenda-item-display-time (item)
  "Return ITEM's start time or complete same-day time range."
  (let ((start (agenda-item-time item))
        (end (agenda-item-end-time item)))
    (and start
         (if end (format nil "~a-~a" start end) start))))

(defun agenda-item-display-text (item)
  "Return ITEM text without the source headline's local tag cookie."
  (let* ((text (agenda-item-text item))
         (heading (agenda-item-heading item))
         (local-tags (if heading (agenda-heading-tag-string heading) "")))
    (if (and (plusp (length local-tags))
             (alexandria:ends-with-subseq local-tags text))
        (string-right-trim
         '(#\Space #\Tab)
         (subseq text 0 (- (length text) (length local-tags))))
        text)))

(defun agenda-display-line (item)
  "One display line for ITEM, including planning kind/date when present."
  (let ((planning
          (if (agenda-item-date item)
              (format nil "  [~a ~a~@[ ~a~]~@[ ~a~]]"
                      (cond
                        ((string= (agenda-item-kind item) "DIARY") "DIARY")
                        ((agenda-item-event-p item) "EVENT")
                        ((eq (agenda-item-reminder-kind item)
                             :scheduled-past)
                         (format nil "Sched.~2dx:"
                                 (agenda-item-reminder-days item)))
                        ((eq (agenda-item-reminder-kind item)
                             :deadline-upcoming)
                         (format nil "In ~3d d.:"
                                 (agenda-item-reminder-days item)))
                        ((eq (agenda-item-reminder-kind item)
                             :deadline-overdue)
                         (format nil "~2d d. ago:"
                                 (agenda-item-reminder-days item)))
                        (t (agenda-item-kind item)))
                      (agenda-item-date item)
                      (agenda-item-display-time item)
                      (and (agenda-item-occurrence-index item)
                           (format nil "~d/~d"
                                   (agenda-item-occurrence-index item)
                                   (agenda-item-occurrence-count item))))
              ""))
        (tags (agenda-item-tags item)))
    (format nil "~12a ~9a ~a~a~@[ ~a~]"
            (format nil "~a:" (or (agenda-item-category item) ""))
            (if (string= (agenda-item-kind item) "DIARY")
                ""
                (or (agenda-item-keyword item) ""))
            (agenda-item-display-text item)
            planning
            (and tags (agenda-tag-string tags)))))

(defun agenda-item-mark-base-key (item)
  "Return ITEM's source-aware identity, excluding duplicate render position."
  (list (uiop:native-namestring (agenda-item-file item))
        (agenda-item-line item)
        (agenda-item-heading item)
        (agenda-item-kind item)
        (agenda-item-date item)
        (agenda-item-time item)
        (agenda-item-occurrence-index item)
        (agenda-item-reminder-kind item)))

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
          (text-property-at point :agenda-reminder-kind)
          (text-property-at point :agenda-duplicate-index))))

(defun insert-agenda-decoration-row (point decoration)
  "Insert display-only DECORATION at POINT."
  (with-point ((start point))
    (insert-string point
                   (format nil "  ~a~%"
                           (agenda-section-decoration-text decoration)))
    (loop :for tail
            :on (agenda-section-decoration-properties decoration) :by #'cddr
          :do (put-text-property start point (first tail) (second tail)))))

(defun insert-agenda-item-row (buffer point item duplicate-counts)
  "Insert source-backed ITEM at POINT with its exact identity properties."
  (let* ((base-key (agenda-item-mark-base-key item))
         (duplicate-index (1+ (gethash base-key duplicate-counts 0)))
         (mark-key (agenda-item-mark-key item duplicate-index))
         (marked-p
           (and *agenda-row-marked-p-function*
                (funcall *agenda-row-marked-p-function* buffer mark-key))))
    (setf (gethash base-key duplicate-counts) duplicate-index)
    (with-point ((start point))
      (insert-string point
                     (format nil "~a ~a~%"
                             (if marked-p ">" " ")
                             (agenda-display-line item)))
      (put-text-property
       start point
       (if (string= (agenda-item-kind item) "DIARY")
           :agenda-diary-file
           :agenda-file)
       (agenda-item-file item))
      (put-text-property start point :agenda-line (agenda-item-line item))
      (put-text-property start point :agenda-heading
                         (agenda-item-heading item))
      (put-text-property start point :agenda-keyword
                         (agenda-item-keyword item))
      (put-text-property start point :agenda-kind (agenda-item-kind item))
      (put-text-property start point :agenda-date (agenda-item-date item))
      (put-text-property start point :agenda-display-date
                         (agenda-item-effective-date item))
      (put-text-property start point :agenda-reminder-kind
                         (agenda-item-reminder-kind item))
      (put-text-property start point :agenda-reminder-days
                         (agenda-item-reminder-days item))
      (put-text-property start point :agenda-time (agenda-item-time item))
      (put-text-property start point :agenda-end-time
                         (agenda-item-end-time item))
      (put-text-property start point :agenda-occurrence-index
                         (agenda-item-occurrence-index item))
      (put-text-property start point :agenda-category
                         (agenda-item-category item))
      (put-text-property start point :agenda-tags (agenda-item-tags item))
      (put-text-property start point :agenda-effort (agenda-item-effort item))
      (put-text-property start point :agenda-top-headline
                         (agenda-item-top-headline item))
      (put-text-property start point :agenda-properties
                         (copy-tree (agenda-item-properties item)))
      (put-text-property start point :agenda-timestamp-line
                         (agenda-item-timestamp-line item))
      (put-text-property start point :agenda-timestamp-source-line
                         (agenda-item-timestamp-source-line item))
      (put-text-property start point :agenda-timestamp-start
                         (agenda-item-timestamp-start item))
      (put-text-property start point :agenda-timestamp-raw
                         (agenda-item-timestamp-raw item))
      (put-text-property start point :agenda-duplicate-index
                         duplicate-index))))

(defun insert-agenda-section (buffer title items duplicate-counts
                              &optional date key now)
  "Insert TITLE and ITEMS with source rows distinct from decorations."
  (let* ((point (buffer-end-point buffer))
         (entries
           (if *agenda-section-layout-function*
               (funcall *agenda-section-layout-function*
                        buffer key date items now)
               items)))
    (with-point ((start point))
      (insert-string point (format nil "~a~%" title))
      (put-text-property start point :agenda-section-key key)
      (when date
        (put-text-property start point :agenda-view-date date)))
    (if (null entries)
        (insert-string point (format nil "  (none)~%"))
        (dolist (entry entries)
          (etypecase entry
            (agenda-section-decoration
             (insert-agenda-decoration-row point entry))
            (agenda-item
             (insert-agenda-item-row buffer point entry duplicate-counts)))))
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
          (text-property-at point :agenda-occurrence-index)
          (text-property-at point :agenda-reminder-kind))))

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
           (agenda-section-key section)
           now))
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

(defun agenda-live-file-buffer (file)
  "Return the live file buffer visiting FILE, without opening a new buffer."
  (find-if
   (lambda (buffer)
     (alexandria:when-let ((pathname (buffer-filename buffer)))
       (ignore-errors (uiop:pathname-equal pathname file))))
   (buffer-list)))

(defun agenda-live-source-snapshots (files)
  "Snapshot modified live FILES on the editor thread for asynchronous scans."
  (loop :for file :in files
        :for buffer := (agenda-live-file-buffer file)
        :when (and buffer (buffer-modified-p buffer))
          :collect
          (cons file
                (points-to-string (buffer-start-point buffer)
                                  (buffer-end-point buffer)))))

(defun agenda-collect-items
    (files discovery-failures snapshots &optional scope-predicate)
  "Return parsed items and failures from immutable scan inputs."
  (handler-case
      (let ((items '())
            (failures (reverse discovery-failures)))
        (dolist (file files)
          (let ((snapshot (assoc file snapshots :test #'uiop:pathname-equal)))
            (multiple-value-bind (parsed errors)
                (if snapshot
                    (parse-org-file file (cdr snapshot))
                    (parse-org-file file))
              (handler-case
                  (let ((line-predicate
                          (and scope-predicate
                               (lambda (line)
                                 (funcall scope-predicate file line)))))
                    (if snapshot
                        (agenda-enrich-filter-metadata
                         file parsed :contents (cdr snapshot)
                         :line-predicate line-predicate)
                        (agenda-enrich-filter-metadata
                         file parsed :line-predicate line-predicate)))
                (error (condition)
                  (push condition errors)))
              (when scope-predicate
                (setf parsed
                      (remove-if-not
                       (lambda (item)
                         (funcall scope-predicate
                                  (agenda-item-file item)
                                  (agenda-item-line item)))
                       parsed)))
              (setf items (nconc items parsed))
              (dolist (error errors)
                (push (cons file error) failures)))))
        (values items (nreverse failures) files))
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
    (buffer generation clock-report-p range-start range-end
     files discovery-failures snapshots scope-predicate)
  "Collect agenda items off-thread and marshal one completion event."
  (multiple-value-bind (items failures collected-files)
      (handler-case
          (agenda-collect-items
           files discovery-failures snapshots scope-predicate)
        (error (condition)
          (values nil (list (cons nil condition)) nil)))
    (let ((clock-report nil))
      (when (and clock-report-p
                 (fboundp 'agenda-clock-collect-report))
        (multiple-value-bind (report report-failures)
            (handler-case
                (agenda-clock-collect-report
                 collected-files range-start range-end scope-predicate)
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
      (multiple-value-bind (files discovery-failures)
          (handler-case
              (agenda-org-files)
            (error (condition)
              (values nil (list (cons nil condition)))))
        (let ((scope-predicate nil))
          (when *agenda-scan-scope-function*
            (multiple-value-setq (files discovery-failures scope-predicate)
              (funcall *agenda-scan-scope-function*
                       buffer files discovery-failures)))
          (let ((snapshots (agenda-live-source-snapshots files)))
            (setf (buffer-value buffer 'lem-yath-agenda-scan-running) t)
            (handler-case
                (bt2:make-thread
                 (lambda ()
                   (agenda-scan-worker
                    buffer generation clock-report-p range-start range-end
                    files discovery-failures snapshots scope-predicate))
                 :name (format nil "lem-yath/agenda-scan-~d" generation))
              (error (condition)
                (setf (buffer-value buffer 'lem-yath-agenda-scan-running) nil
                      (buffer-value buffer 'lem-yath-agenda-refresh-pending) nil)
                (agenda-render-if-current
                 buffer generation nil (list (cons nil condition)))
                (message "Agenda scan could not start: ~a" condition)
                nil))))))))

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
                  (text-property-at (current-point) :agenda-diary-file)
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

(define-command lem-yath-agenda-goto () ()
  "Open the current agenda entry in another window, like Evil-Org Tab."
  (let ((file (or (text-property-at (current-point) :agenda-file)
                  (text-property-at (current-point) :agenda-diary-file)
                  (text-property-at
                   (current-point) :agenda-clock-report-file)))
        (line (or (text-property-at (current-point) :agenda-line)
                  (text-property-at
                   (current-point) :agenda-clock-report-line))))
    (if (null file)
        (message "No agenda entry on this line.")
        (let ((buffer (find-file-buffer file)))
          (when (one-window-p)
            (split-window-sensibly (current-window)))
          (switch-to-window (get-next-window (current-window)))
          (switch-to-buffer buffer)
          (when (integerp line)
            (goto-line line))))))

(defun agenda-source-row-p (point)
  "Return true when POINT names a source-backed agenda or clock-report row."
  (or (text-property-at point :agenda-file)
      (text-property-at point :agenda-diary-file)
      (text-property-at point :agenda-clock-report-file)))

(defun agenda-find-item-point (origin direction)
  "Return the next source-backed row from ORIGIN in DIRECTION, if any."
  (with-point ((point origin))
    (loop :while (line-offset point direction)
          :when (agenda-source-row-p point)
            :return (copy-point point :temporary))))

(defun agenda-move-item (direction count)
  "Move by COUNT source-backed agenda rows in DIRECTION."
  (let ((column (point-column (current-point))))
    (dotimes (_ (max 0 count))
      (alexandria:if-let
          ((target (agenda-find-item-point (current-point) direction)))
        (move-point (current-point) target)
        (return)))
    (move-to-column (current-point) column)
    (when (agenda-source-row-p (current-point))
      (dolist (function *agenda-item-motion-functions*)
        (funcall function (current-buffer) (current-point))))))

(define-command lem-yath-agenda-next-item (&optional (count 1)) (:universal)
  "Move to the next source-backed agenda row."
  (agenda-move-item 1 count))

(define-command lem-yath-agenda-previous-item (&optional (count 1)) (:universal)
  "Move to the previous source-backed agenda row."
  (agenda-move-item -1 count))

(define-command lem-yath-agenda-refresh () ()
  "Re-scan the org files and rebuild the agenda buffer."
  (let ((buffer (get-buffer *agenda-buffer-name*)))
    (if (and buffer (mode-active-p buffer 'lem-yath-agenda-mode))
        (progn
          (when (fboundp 'agenda-undo-clear)
            (agenda-undo-clear buffer))
          (agenda-start-scan buffer))
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
        (agenda-undo-track-buffer buffer)
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
         (preferred-time
           (and preferred-date
                (multiple-value-bind (date suffix)
                    (org-planning-field-components heading preferred-kind)
                  (declare (ignore date))
                  (or (nth-value 0 (agenda-timestamp-times suffix))
                      (nth-value
                       0 (agenda-heading-time-spec
                          (line-string heading)))))))
         (other-kind (if (string= preferred-kind "DEADLINE")
                         "SCHEDULED"
                         "DEADLINE"))
         (other-date (and (null preferred-date)
                          (org-planning-field-date heading other-kind)))
         (other-time
           (and other-date
                (multiple-value-bind (date suffix)
                    (org-planning-field-components heading other-kind)
                  (declare (ignore date))
                  (or (nth-value 0 (agenda-timestamp-times suffix))
                      (nth-value
                       0 (agenda-heading-time-spec
                          (line-string heading))))))))
    (let ((default-key
            (cond
              (preferred-date
               (list file line preferred-kind preferred-date
                     preferred-time nil nil))
              (other-date
               (list file line other-kind other-date other-time nil nil))
              (t
               (list file line nil nil nil nil nil)))))
      (if *agenda-planning-restore-key-function*
          (funcall *agenda-planning-restore-key-function*
                   file line heading preferred-kind default-key)
          default-key))))

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
        (agenda-undo-track-buffer buffer)
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
        (entry-key (agenda-entry-key-at-point (current-point)))
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
                      (with-agenda-undo-transaction
                          (agenda-buffer
                           (format nil "org-agenda-~a"
                                   (string-downcase kind))
                           entry-key)
                        (agenda-apply-source-planning
                         file line heading kind old-date old-extra operation
                         :date date :extra extra))
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
        (agenda-undo-track-buffer buffer)
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
                    (with-agenda-undo-transaction
                        (agenda-buffer "org-agenda-priority" entry-key)
                      (agenda-set-source-priority
                       file line heading direction repeated-p))))
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
        (agenda-undo-track-buffer buffer)
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
                (with-agenda-undo-transaction
                    (agenda-buffer "org-agenda-set-tags" entry-key)
                  (agenda-set-source-tags file line heading tags))
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
                  (with-agenda-undo-transaction
                      (agenda-buffer "org-agenda-todo" entry-key)
                    (agenda-set-source-todo file line heading state))
                  (setf (buffer-value agenda-buffer
                                      'lem-yath-agenda-restore-entry)
                        entry-key)
                  (agenda-start-scan agenda-buffer)
                  (message "TODO state: ~a" (or state "none")))
              (error (condition)
                (message "Agenda TODO failed: ~a" condition))))))))

(defvar *agenda-command-initializer-function* nil
  "Optional function initializing BUFFER for an agenda dispatcher command.")

(defun agenda-open-command (command &optional command-argument restriction)
  "Open the agenda BUFFER for COMMAND, argument, and temporary RESTRICTION."
  (let ((directories (agenda-directories)))
    (unless directories
      (message "No configured Org agenda directory exists.")
      (return-from agenda-open-command))
    (let ((buffer (make-buffer *agenda-buffer-name* :enable-undo-p nil)))
      (setf (buffer-directory buffer) (first directories))
      (change-buffer-mode buffer 'lem-yath-agenda-mode)
      (when *agenda-command-initializer-function*
        (funcall *agenda-command-initializer-function*
                 buffer command command-argument restriction))
      (switch-to-window (pop-to-buffer buffer :split-action :sensibly))
      (agenda-start-scan buffer)
      buffer)))

(define-command lem-yath-agenda-summary () ()
  "Open the configured combined agenda and all-TODO summary."
  (agenda-open-command :summary))

(define-command lem-yath-agenda () ()
  "Prompt for a configured Org agenda command."
  (if (fboundp 'lem-yath-agenda-dispatch)
      (lem-yath-agenda-dispatch)
      (lem-yath-agenda-summary)))

(defvar *lem-yath-agenda-vi-keymap*
  (make-keymap :description '*lem-yath-agenda-vi-keymap*))

(define-key *lem-yath-agenda-vi-keymap* "Return" 'lem-yath-agenda-visit)
(define-key *lem-yath-agenda-vi-keymap* "Tab" 'lem-yath-agenda-goto)
(define-key *lem-yath-agenda-vi-keymap* "Shift-Return" 'lem-yath-agenda-goto)
(define-key *lem-yath-agenda-vi-keymap* "g Tab" 'lem-yath-agenda-goto)
(define-key *lem-yath-agenda-vi-keymap* "g j" 'lem-yath-agenda-next-item)
(define-key *lem-yath-agenda-vi-keymap* "g k" 'lem-yath-agenda-previous-item)
(define-key *lem-yath-agenda-vi-keymap* "C-j" 'lem-yath-agenda-next-item)
(define-key *lem-yath-agenda-vi-keymap* "C-k" 'lem-yath-agenda-previous-item)
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
