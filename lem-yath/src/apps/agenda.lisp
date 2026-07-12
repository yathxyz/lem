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
  keyword text file line date kind)

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
   :date date
   :kind kind))

(defun parse-org-file (path)
  "Return parsed agenda items and, as a second value, warnings or read errors.
Only the planning line immediately below a heading is structural.  A heading
with both SCHEDULED and DEADLINE fields produces one item for each field."
  (handler-case
      (with-open-file (in path :direction :input :external-format :utf-8)
         (let ((items '())
               (warnings '())
               (current nil)
               (current-planned-p nil)
               (planning-line-open-p nil))
           (labels ((finish-current ()
                      (when (and current (not current-planned-p))
                        (push current items))))
             (loop :for line := (read-line in nil)
                   :for lineno :from 1
                   :while line
                   :do (multiple-value-bind (start end gs ge)
                           (ppcre:scan *heading-scanner* line)
                         (declare (ignore end))
                         (if start
                             (progn
                               (finish-current)
                               (let ((keyword
                                       (when (aref gs 0)
                                         (subseq line (aref gs 0) (aref ge 0))))
                                     (text
                                       (string-trim
                                        '(#\Space #\Tab)
                                        (subseq line (aref gs 1) (aref ge 1)))))
                                 (setf current
                                       (make-agenda-item
                                        :keyword keyword
                                        :text text
                                        :file path
                                        :line lineno
                                        :date nil
                                        :kind nil)
                                       current-planned-p nil
                                       planning-line-open-p t)))
                             (when (and current planning-line-open-p)
                               (when (ppcre:scan *planning-line-scanner* line)
                                 (ppcre:do-register-groups (kind date)
                                     (*planning-scanner* line)
                                   (if (valid-iso-date-p date)
                                       (progn
                                         (push (agenda-item-with-planning
                                                current kind date)
                                               items)
                                         (setf current-planned-p t))
                                       (push
                                        (make-condition
                                         'simple-error
                                         :format-control
                                         "Invalid Org planning date ~s at line ~d"
                                         :format-arguments (list date lineno))
                                        warnings))))
                               (setf planning-line-open-p nil)))))
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
          ((and date (not (done-keyword-p kw)))
           (cond
             ((string< date today) (push item overdue))
             ((string= date today) (push item today-items))
             ((string<= date horizon) (push item upcoming))))
          ((and (null date) (open-keyword-p kw))
           (push item todos)))))
    (flet ((by-date (a b) (string< (or (agenda-item-date a) "")
                                   (or (agenda-item-date b) ""))))
      (values (stable-sort (nreverse overdue) #'by-date)
              (nreverse today-items)
              (stable-sort (nreverse upcoming) #'by-date)
              (nreverse todos)))))

;;; --- rendering -----------------------------------------------------------

(defun agenda-display-line (item)
  "One display line for ITEM, including planning kind/date when present."
  (let ((planning
          (if (agenda-item-date item)
              (format nil "  [~a ~a]"
                      (agenda-item-kind item) (agenda-item-date item))
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
            (put-text-property start point :agenda-line (agenda-item-line item)))))
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

(defun render-agenda (buffer items &optional failures)
  "Fill BUFFER with grouped ITEMS and any source FAILURES on the editor thread."
  (let ((now (funcall *agenda-now-function*)))
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
        (insert-agenda-failures buffer failures))))
  (buffer-start (buffer-point buffer))
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
(define-key *lem-yath-agenda-vi-keymap* "q" 'quit-active-window)

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode lem-yath-agenda-mode))
  (declare (ignore mode))
  (list *lem-yath-agenda-vi-keymap*))

(define-key *lem-yath-agenda-mode-keymap* "Return" 'lem-yath-agenda-visit)
(define-key *lem-yath-agenda-mode-keymap* "g" 'lem-yath-agenda-refresh)
(define-key *lem-yath-agenda-mode-keymap* "q" 'quit-active-window)
