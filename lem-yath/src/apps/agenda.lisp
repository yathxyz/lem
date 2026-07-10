;;;; lem-yath apps/agenda -- an "agenda-lite" standing in for org-agenda +
;;;; org-super-agenda over org-agenda-files = $WORKDIR.
;;;;
;;;; Emacs uses org-agenda to collect TODO/SCHEDULED/DEADLINE items from every
;;;; *.org file under $WORKDIR and org-super-agenda to group them. We have no
;;;; org-mode, so we scan the same files with a tolerant cl-ppcre parser and
;;;; render a read-only grouped buffer: Overdue / Today / Upcoming / TODOs.
;;;; Scanning runs on a background thread so large note trees don't block the
;;;; editor; the render is marshalled back via send-event.

(in-package :lem-yath)

(defparameter *agenda-buffer-name* "*lem-yath-agenda*"
  "Name of the read-only agenda buffer.")

(defparameter *agenda-upcoming-days* 7
  "How many days ahead the \"Upcoming\" section reaches.")

(defparameter *agenda-todo-keywords* '("TODO" "NEXT" "WAIT" "HOLD" "DONE" "CANCELLED")
  "Heading keywords recognised by the parser, mirroring the Emacs config.")

(defparameter *agenda-open-keywords* '("TODO" "NEXT" "WAIT")
  "Keywords for the unscheduled \"TODOs\" section.")

(defparameter *agenda-done-keywords* '("DONE" "CANCELLED")
  "Keywords excluded from the dated sections.")

;;; --- parsing -------------------------------------------------------------

(defstruct (agenda-item (:constructor make-agenda-item))
  "One parsed heading: its TODO keyword, text, source file/line and date."
  keyword text file line date kind)

(defvar *heading-scanner*
  (ppcre:create-scanner
   "^\\*+\\s+(?:(TODO|NEXT|WAIT|HOLD|DONE|CANCELLED)\\s+)?(.*)$")
  "Matches an org heading, optionally capturing a leading TODO keyword.")

(defvar *planning-scanner*
  (ppcre:create-scanner
   "(SCHEDULED|DEADLINE):\\s*<(\\d{4}-\\d{2}-\\d{2})")
  "Matches a SCHEDULED/DEADLINE planning entry and its <YYYY-MM-DD ...> date.")

(defun agenda-org-files ()
  "Absolute paths of every *.org file under (workdir), recursively.
Uses fd when available (as org-agenda's file scan did), else find. Syncthing
conflict files are skipped. Returns NIL when the workdir is unavailable."
  (let ((root (ignore-errors (workdir))))
    (unless (and root (uiop:directory-exists-p root))
      (return-from agenda-org-files nil))
    (let* ((command (if (executable-find "fd")
                        (list "fd" "--type" "f" "--extension" "org"
                              "." (namestring root))
                        (list "find" (namestring root) "-name" "*.org")))
           (output (ignore-errors
                     (uiop:run-program command :output :string
                                               :ignore-error-status t))))
      (loop :for line :in (uiop:split-string (or output "")
                                             :separator (string #\Newline))
            :for trimmed := (string-trim '(#\Space #\Tab #\Return) line)
            :unless (or (zerop (length trimmed))
                        (search ".sync-conflict-" trimmed))
              :collect trimmed))))

(defun parse-org-file (path)
  "Parse PATH into a list of AGENDA-ITEMs. Tolerant: any read or regex error
yields the items collected so far (or none). A planning line's date is
associated with the most recent heading above it."
  (handler-case
      (with-open-file (in path :direction :input :if-does-not-exist nil
                               :external-format :utf-8)
        (unless in
          (return-from parse-org-file nil))
        (let ((items '())
              (current nil))
          (loop :for line := (read-line in nil)
                :for lineno :from 1
                :while line
                :do (multiple-value-bind (start end gs ge)
                        (ppcre:scan *heading-scanner* line)
                      (declare (ignore end))
                      (cond
                        (start
                         (let ((keyword (when (aref gs 0)
                                          (subseq line (aref gs 0) (aref ge 0))))
                               (text (string-trim
                                      '(#\Space #\Tab)
                                      (subseq line (aref gs 1) (aref ge 1)))))
                           (setf current (make-agenda-item
                                          :keyword keyword
                                          :text text
                                          :file path
                                          :line lineno
                                          :date nil
                                          :kind nil))
                           (push current items)))
                        (current
                         (multiple-value-bind (ps pe pgs pge)
                             (ppcre:scan *planning-scanner* line)
                           (declare (ignore pe))
                           (when (and ps (null (agenda-item-date current)))
                             (setf (agenda-item-kind current)
                                   (subseq line (aref pgs 0) (aref pge 0))
                                   (agenda-item-date current)
                                   (subseq line (aref pgs 1) (aref pge 1)))))))))
          (nreverse items)))
    (error () nil)))

;;; --- date helpers --------------------------------------------------------

(defun today-iso ()
  "Today as a YYYY-MM-DD string."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time))
    (declare (ignore sec min hour))
    (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))

(defun iso-plus-days (days)
  "Today + DAYS as a YYYY-MM-DD string, via universal time math."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (+ (get-universal-time) (* days 24 60 60)))
    (declare (ignore sec min hour))
    (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))

;;; --- grouping ------------------------------------------------------------

(defun open-keyword-p (kw)
  (and kw (member kw *agenda-open-keywords* :test #'string=)))

(defun done-keyword-p (kw)
  (and kw (member kw *agenda-done-keywords* :test #'string=)))

(defun group-items (items)
  "Bucket ITEMS into (overdue today upcoming todos), each a list of items.
Given the fixed YYYY-MM-DD format, plain string comparison is correct date
comparison. Dated DONE/CANCELLED items are dropped from the dated sections."
  (let ((today (today-iso))
        (horizon (iso-plus-days *agenda-upcoming-days*))
        (overdue '()) (today-items '()) (upcoming '()) (todos '()))
    (dolist (item items)
      (let ((date (agenda-item-date item))
            (kw (agenda-item-keyword item)))
        (cond
          ((and date (not (done-keyword-p kw)))
           (cond
             ((string< date today) (push item overdue))
             ((string= date today) (push item today-items))
             ((string<= date horizon) (push item upcoming))))
          ((and (null date) (open-keyword-p kw))
           (push item todos)))))
    (flet ((by-date (a b) (string< (or (agenda-item-date a) "")
                                   (or (agenda-item-date b) ""))))
      (values (sort (nreverse overdue) #'by-date)
              (nreverse today-items)
              (sort (nreverse upcoming) #'by-date)
              (nreverse todos)))))

;;; --- rendering -----------------------------------------------------------

(defun agenda-display-line (item)
  "One display line for ITEM: \"KW  heading   (file:line)\"."
  (format nil "~6a ~a   (~a:~a)"
          (or (agenda-item-keyword item) "")
          (agenda-item-text item)
          (file-namestring (agenda-item-file item))
          (agenda-item-line item)))

(defun insert-agenda-section (buffer title items)
  "Insert a TITLE header and one line per ITEM, tagging each entry line with an
:agenda-file text property so Return can visit the source file."
  (let ((point (buffer-end-point buffer)))
    (insert-string point (format nil "~a~%" title))
    (if (null items)
        (insert-string point (format nil "  (none)~%"))
        (dolist (item items)
          (with-point ((start point))
            (insert-string point (format nil "  ~a~%" (agenda-display-line item)))
            (put-text-property start point :agenda-file (agenda-item-file item)))))
    (insert-string point (format nil "~%"))))

(defun render-agenda (buffer items)
  "Fill BUFFER (on the editor thread) with the grouped agenda for ITEMS."
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (multiple-value-bind (overdue today upcoming todos) (group-items items)
      (let ((point (buffer-end-point buffer)))
        (insert-string point (format nil "Agenda  (~a)~%~%" (today-iso))))
      (insert-agenda-section buffer "Overdue" overdue)
      (insert-agenda-section buffer "Today" today)
      (insert-agenda-section
       buffer (format nil "Upcoming (~a days)" *agenda-upcoming-days*) upcoming)
      (insert-agenda-section buffer "TODOs" todos)))
  (buffer-start (buffer-point buffer))
  (setf (buffer-read-only-p buffer) t)
  (redraw-display))

(defun scan-and-render (buffer)
  "Background worker: collect+parse all org files, then render on the editor
thread. Any failure degrades to an empty agenda rather than an unhandled error."
  (let ((items (handler-case
                   (loop :for file :in (agenda-org-files)
                         :nconc (parse-org-file (pathname file)))
                 (error () nil))))
    (send-event (lambda () (render-agenda buffer items)))))

;;; --- mode & keymap -------------------------------------------------------

(define-major-mode lem-yath-agenda-mode nil
    (:name "Agenda"
     :keymap *lem-yath-agenda-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defun parse-entry-line-number (point)
  "Pull the trailing (file:LINE) line number out of the current display line."
  (let ((string (line-string point)))
    (multiple-value-bind (start end gs ge)
        (ppcre:scan "\\(.*:(\\d+)\\)\\s*$" string)
      (declare (ignore start end))
      (when gs
        (ignore-errors
          (parse-integer (subseq string (aref gs 0) (aref ge 0))))))))

(define-command lem-yath-agenda-visit () ()
  "Open the org file for the entry on the current line at its heading."
  (let ((file (text-property-at (current-point) :agenda-file)))
    (if (null file)
        (message "No agenda entry on this line.")
        (let ((line (parse-entry-line-number (current-point))))
          (find-file file)
          (when line
            (goto-line line))))))

(define-command lem-yath-agenda-refresh () ()
  "Re-scan the org files and rebuild the agenda buffer."
  (let ((buffer (get-buffer *agenda-buffer-name*)))
    (when buffer
      (with-buffer-read-only buffer nil
        (erase-buffer buffer)
        (insert-string (buffer-end-point buffer) "Scanning..."))
      (setf (buffer-read-only-p buffer) t)
      (redraw-display)
      (bt2:make-thread (lambda () (scan-and-render buffer))
                       :name "lem-yath/agenda-scan"))))

(define-command lem-yath-agenda () ()
  "Show a grouped agenda (Overdue/Today/Upcoming/TODOs) over $WORKDIR org files.
Mirrors org-agenda + org-super-agenda. Scanning runs in the background."
  (let ((root (ignore-errors (workdir))))
    (unless (and root (uiop:directory-exists-p root))
      (message "No workdir; nothing to scan for the agenda.")
      (return-from lem-yath-agenda)))
  (let ((buffer (make-buffer *agenda-buffer-name*)))
    (change-buffer-mode buffer 'lem-yath-agenda-mode)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-end-point buffer) "Scanning..."))
    (setf (buffer-read-only-p buffer) t)
    (pop-to-buffer buffer)
    (redraw-display)
    (bt2:make-thread (lambda () (scan-and-render buffer))
                     :name "lem-yath/agenda-scan")))

(define-key *lem-yath-agenda-mode-keymap* "Return" 'lem-yath-agenda-visit)
(define-key *lem-yath-agenda-mode-keymap* "g" 'lem-yath-agenda-refresh)
(define-key *lem-yath-agenda-mode-keymap* "q" 'quit-active-window)
