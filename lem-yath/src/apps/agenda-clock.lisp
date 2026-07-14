;;;; lem-yath apps/agenda-clock -- Evil-Org agenda clocks and bulk marks.
;;;;
;;;; Effective Emacs parity is deliberately state-specific.  Evil-Org's
;;;; motion map shadows the user's base I/O bindings with GNU Org's single
;;;; global clock, while Emacs state exposes the user's concurrent delegated
;;;; clocks.  Bulk marks retain live source points, just like Org markers, so
;;;; earlier clock insertions cannot redirect later marked operations.

(in-package :lem-yath)

(defvar *agenda-clock-now-function* nil
  "Optional clock time source; NIL follows `*agenda-now-function*'.")

(defvar *agenda-active-clock* nil
  "The single GNU Org-style clock started by this Lem process.")

(defparameter *agenda-clock-open-line-scanner*
  (ppcre:create-scanner
   "^\\s*CLOCK: \\[(\\d{4})-(\\d{2})-(\\d{2})\\s+[^]\\s]+\\s+(\\d{2}):(\\d{2})\\]\\s*$"))

(defstruct (agenda-clock-target (:constructor make-agenda-clock-target))
  point file heading kind date time occurrence-index duplicate-index)

(defstruct (agenda-clock-record (:constructor make-agenda-clock-record))
  point file start-time)

(defstruct (agenda-active-clock (:constructor make-agenda-active-clock))
  clock-point heading-point file heading start-time)

(defun agenda-clock-now ()
  (funcall (or *agenda-clock-now-function* *agenda-now-function*)))

(defun agenda-clock-file-key (file)
  (uiop:native-namestring file))

(defun agenda-clock-timestamp (time)
  (multiple-value-bind (second minute hour day month year weekday)
      (decode-universal-time time)
    (declare (ignore second))
    (format nil "[~4,'0d-~2,'0d-~2,'0d ~a ~2,'0d:~2,'0d]"
            year month day (aref *agenda-weekday-names* weekday) hour minute)))

(defun agenda-clock-line-start-time (line)
  "Return the universal start time from an exact open Org clock LINE."
  (multiple-value-bind (start end registers register-ends)
      (ppcre:scan *agenda-clock-open-line-scanner* line)
    (declare (ignore end))
    (when start
      (flet ((field (index)
               (parse-integer line
                              :start (aref registers index)
                              :end (aref register-ends index))))
        (encode-universal-time 0 (field 4) (field 3)
                               (field 2) (field 1) (field 0))))))

(defun agenda-clock-duration (start end)
  (let* ((seconds (- end start))
         (hours (floor seconds 3600))
         (minutes (floor (mod seconds 3600) 60)))
    (format nil "~2d:~2,'0d" hours minutes)))

;;; --- exact source targets ------------------------------------------------

(defun agenda-clock-locate-source-heading
    (file line expected-heading &optional writable-p)
  "Return a live point for exact FILE/LINE/EXPECTED-HEADING.

The numeric agenda row is validated before a persistent point is created.
Marked rows subsequently use that point and therefore survive preceding
insertions in the same source buffer."
  (unless (and file (integerp line) (plusp line) expected-heading)
    (error "No mutable agenda heading on this line"))
  (let ((buffer (find-file-buffer file))
        (result nil))
    (with-current-buffer buffer
      (when (and writable-p (buffer-read-only-p buffer))
        (error "Agenda source is read-only: ~a" file))
      (with-point ((heading (buffer-start-point buffer)))
        (unless (or (= line 1) (line-offset heading (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (unless (and (org-heading-line-p heading)
                     (string= expected-heading (line-string heading)))
          (error "Agenda source changed; refresh before editing"))
        ;; `org-agenda-new-marker' uses insertion type T: text inserted at
        ;; the marker belongs before the heading and the marker follows it.
        (setf result (copy-point heading :left-inserting))))
    result))

(defun agenda-clock-target-from-row (&optional (point (current-point)))
  "Create a persistent exact-source target for the agenda row at POINT."
  (let ((file (text-property-at point :agenda-file))
        (line (text-property-at point :agenda-line))
        (heading (text-property-at point :agenda-heading)))
    (unless file (error "No agenda entry on this line"))
    (make-agenda-clock-target
     :point (agenda-clock-locate-source-heading file line heading)
     :file file
     :heading heading
     :kind (text-property-at point :agenda-kind)
     :date (text-property-at point :agenda-date)
     :time (text-property-at point :agenda-time)
     :occurrence-index (text-property-at point :agenda-occurrence-index)
     :duplicate-index (text-property-at point :agenda-duplicate-index))))

(defun agenda-clock-delete-target (target)
  (when target
    (ignore-errors (delete-point (agenda-clock-target-point target)))))

(defun agenda-clock-target-valid-p (target &optional writable-p)
  (let* ((point (agenda-clock-target-point target))
         (buffer (and point (point-buffer point))))
    (and point
         (alive-point-p point)
         buffer
         (not (deleted-buffer-p buffer))
         (buffer-filename buffer)
         (uiop:pathname-equal (buffer-filename buffer)
                              (agenda-clock-target-file target))
         (or (not writable-p) (not (buffer-read-only-p buffer)))
         (org-heading-line-p point)
         (string= (line-string point)
                  (agenda-clock-target-heading target)))))

(defun agenda-clock-validate-target (target &optional writable-p)
  (unless (agenda-clock-target-valid-p target writable-p)
    (error "Agenda source changed; refresh before editing"))
  (agenda-clock-target-point target))

(defun agenda-clock-target-mark-key (target)
  "Return TARGET's current rendered-row key, or NIL when it is stale."
  (when (agenda-clock-target-valid-p target)
    (list (agenda-clock-file-key (agenda-clock-target-file target))
          (line-number-at-point (agenda-clock-target-point target))
          (agenda-clock-target-heading target)
          (agenda-clock-target-kind target)
          (agenda-clock-target-date target)
          (agenda-clock-target-time target)
          (agenda-clock-target-occurrence-index target)
          (agenda-clock-target-duplicate-index target))))

(defun agenda-clock-target-entry-key (target)
  "Return TARGET's current six-field agenda restoration key."
  (when (agenda-clock-target-valid-p target)
    (list (agenda-clock-target-file target)
          (line-number-at-point (agenda-clock-target-point target))
          (agenda-clock-target-kind target)
          (agenda-clock-target-date target)
          (agenda-clock-target-time target)
          (agenda-clock-target-occurrence-index target))))

;;; --- bulk marks ----------------------------------------------------------

(defun agenda-bulk-marks (&optional (buffer (current-buffer)))
  (buffer-value buffer 'lem-yath-agenda-bulk-marks))

(defun (setf agenda-bulk-marks) (marks &optional (buffer (current-buffer)))
  (setf (buffer-value buffer 'lem-yath-agenda-bulk-marks) marks))

(defun agenda-bulk-find-mark (buffer key)
  (find key (agenda-bulk-marks buffer)
        :key #'agenda-clock-target-mark-key :test #'equal))

(defun agenda-bulk-row-marked-p (buffer key)
  (not (null (agenda-bulk-find-mark buffer key))))

(defparameter *agenda-row-source-properties*
  '(:agenda-file :agenda-line :agenda-heading :agenda-kind :agenda-date
    :agenda-time :agenda-occurrence-index :agenda-duplicate-index))

(defun agenda-bulk-set-row-prefix (point marked-p)
  (with-point ((line point))
    (line-start line)
    (unless (agenda-row-mark-key-at-point line)
      (error "No agenda entry on this line"))
    (let ((properties
            (mapcar (lambda (property)
                      (cons property (text-property-at line property)))
                    *agenda-row-source-properties*))
          (buffer (point-buffer line)))
      (with-buffer-read-only buffer nil
        (delete-character line 1)
        (insert-character line (if marked-p #\> #\Space))
        (with-point ((end line))
          (line-end end)
          (dolist (property properties)
            (put-text-property line end (car property) (cdr property)))))
      (buffer-unmark buffer))))

(defun agenda-bulk-add-current ()
  (let* ((buffer (current-buffer))
         (key (agenda-row-mark-key-at-point (current-point))))
    (unless key (error "Nothing to mark at point"))
    (unless (agenda-bulk-find-mark buffer key)
      (push (agenda-clock-target-from-row) (agenda-bulk-marks buffer)))
    (agenda-bulk-set-row-prefix (current-point) t)))

(defun agenda-bulk-remove-current ()
  (let* ((buffer (current-buffer))
         (key (agenda-row-mark-key-at-point (current-point)))
         (mark (and key (agenda-bulk-find-mark buffer key))))
    (when mark
      (setf (agenda-bulk-marks buffer)
            (delete mark (agenda-bulk-marks buffer) :count 1 :test #'eq))
      (agenda-clock-delete-target mark)
      (agenda-bulk-set-row-prefix (current-point) nil))
    (not (null mark))))

(defun agenda-bulk-next-row (&optional (direction 1))
  (with-point ((point (current-point)))
    (loop :while (line-offset point direction)
          :when (agenda-row-mark-key-at-point point)
            :do (move-point (current-point) point)
                (return t))))

(defun agenda-bulk-message (prefix)
  (let ((count (length (agenda-bulk-marks))))
    (message "~d ~a marked for bulk action" count prefix)))

(defun agenda-bulk-map-rows (function)
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (agenda-row-mark-key-at-point point)
        (funcall function point))
      (unless (line-offset point 1) (return)))))

(defun agenda-bulk-clear (&optional (buffer (current-buffer)) rewrite-p)
  (dolist (mark (agenda-bulk-marks buffer))
    (agenda-clock-delete-target mark))
  (setf (agenda-bulk-marks buffer) nil)
  (when (and rewrite-p (not (deleted-buffer-p buffer)))
    (with-current-buffer buffer
      (agenda-bulk-map-rows
       (lambda (point) (agenda-bulk-set-row-prefix point nil))))))

(defun agenda-bulk-buffer-cleanup (buffer)
  (agenda-bulk-clear buffer nil))

(define-command lem-yath-agenda-bulk-mark () ()
  "Mark the current entry and advance, like base Org agenda m."
  (handler-case
      (progn
        (agenda-bulk-add-current)
        (agenda-bulk-next-row)
        (agenda-bulk-message "entries"))
    (error (condition) (message "Agenda mark failed: ~a" condition))))

(define-command lem-yath-agenda-bulk-unmark () ()
  "Unmark the current entry and advance, like base Org agenda u."
  (if (agenda-bulk-remove-current)
      (progn
        (agenda-bulk-next-row)
        (message "~d entries left marked for bulk action"
                 (length (agenda-bulk-marks))))
      (message "No entry to unmark here")))

(define-command lem-yath-agenda-bulk-toggle () ()
  "Toggle the current entry's mark and advance, like Evil-Org m."
  (handler-case
      (progn
        (if (agenda-bulk-find-mark
             (current-buffer)
             (agenda-row-mark-key-at-point (current-point)))
            (agenda-bulk-remove-current)
            (agenda-bulk-add-current))
        (agenda-bulk-next-row)
        (message "~d entries marked for bulk action"
                 (length (agenda-bulk-marks))))
    (error (condition) (message "Agenda mark failed: ~a" condition))))

(define-command lem-yath-agenda-bulk-mark-all () ()
  "Mark every agenda entry, like Org agenda *."
  (handler-case
      (let ((original (copy-point (current-point) :temporary)))
        (agenda-bulk-map-rows
         (lambda (point)
           (unless (agenda-bulk-find-mark
                    (current-buffer) (agenda-row-mark-key-at-point point))
             (move-point (current-point) point)
             (agenda-bulk-add-current))))
        (move-point (current-point) original)
        (message "~d entries marked for bulk action"
                 (length (agenda-bulk-marks))))
    (error (condition) (message "Agenda mark-all failed: ~a" condition))))

(define-command lem-yath-agenda-bulk-toggle-all () ()
  "Invert every agenda entry mark, like Evil-Org ~ and base Org M-*."
  (handler-case
      (let ((original (copy-point (current-point) :temporary)))
        (agenda-bulk-map-rows
         (lambda (point)
           (move-point (current-point) point)
           (if (agenda-bulk-find-mark
                (current-buffer) (agenda-row-mark-key-at-point point))
               (agenda-bulk-remove-current)
               (agenda-bulk-add-current))))
        (move-point (current-point) original)
        (message "~d entries marked for bulk action"
                 (length (agenda-bulk-marks))))
    (error (condition) (message "Agenda toggle-all failed: ~a" condition))))

(define-command lem-yath-agenda-bulk-mark-regexp () ()
  "Mark entry rows whose rendered text matches a prompted regexp."
  (handler-case
      (let* ((pattern (prompt-for-string "Mark entries matching regexp: "))
             (scanner (ppcre:create-scanner pattern))
             (count 0))
        (agenda-bulk-map-rows
         (lambda (point)
           (when (and (ppcre:scan scanner (line-string point))
                      (not (agenda-bulk-find-mark
                            (current-buffer)
                            (agenda-row-mark-key-at-point point))))
             (move-point (current-point) point)
             (agenda-bulk-add-current)
             (incf count))))
        (if (plusp count)
            (message "~d entries marked for bulk action"
                     (length (agenda-bulk-marks)))
            (message "No entry matching this regexp.")))
    (error (condition) (message "Agenda regexp mark failed: ~a" condition))))

(define-command lem-yath-agenda-bulk-unmark-all () ()
  "Remove every agenda bulk mark."
  (if (null (agenda-bulk-marks))
      (message "No entry to unmark")
      (progn
        (agenda-bulk-clear (current-buffer) t)
        (message "0 entries marked for bulk action"))))

;;; --- semantic open clock records ----------------------------------------

(defun agenda-clock-open-record-at-point (point file)
  (unless (org-inside-block-p point)
    (alexandria:when-let ((start-time
                           (agenda-clock-line-start-time
                            (line-string point))))
      (make-agenda-clock-record
       :point (copy-point point :temporary)
       :file file
       :start-time start-time))))

(defun agenda-clock-open-records-at-heading (target)
  "Return exact semantic open clocks in TARGET's heading section only."
  (let ((heading (agenda-clock-validate-target target))
        (records '()))
    (with-point ((point heading))
      (loop :while (line-offset point 1)
            :until (org-heading-line-p point)
            :for record := (agenda-clock-open-record-at-point
                            point (agenda-clock-target-file target))
            :when record :do (push record records)))
    (nreverse records)))

(defun agenda-clock-open-records-in-file (file)
  "Return every semantic open Org clock in FILE."
  (let ((buffer (find-file-buffer file))
        (records '())
        (inside-heading-p nil))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (loop
          (when (org-heading-line-p point)
            (setf inside-heading-p t))
          (when inside-heading-p
            (alexandria:when-let
                ((record (agenda-clock-open-record-at-point point file)))
              (push record records)))
          (unless (line-offset point 1) (return)))))
    (nreverse records)))

(defun agenda-clock-trimmed-line (point)
  (string-trim '(#\Space #\Tab) (line-string point)))

(defun agenda-clock-find-logbook-end (heading)
  "Return the closing :END: of the first valid LOGBOOK in HEADING's section."
  (with-point ((point heading))
    (loop :while (line-offset point 1)
          :until (org-heading-line-p point)
          :when (and (not (org-inside-block-p point))
                     (string-equal (agenda-clock-trimmed-line point)
                                   ":LOGBOOK:"))
            :do (with-point ((end point))
                  (loop :while (line-offset end 1)
                        :until (org-heading-line-p end)
                        :when (and (not (org-inside-block-p end))
                                   (string-equal
                                    (agenda-clock-trimmed-line end) ":END:"))
                          :do (return-from agenda-clock-find-logbook-end
                                (copy-point end :temporary)))))))

(defun agenda-clock-move-after-line (point)
  "Move POINT to the next line, creating a trailing line when necessary."
  (unless (line-offset point 1)
    (line-end point)
    (insert-string point (format nil "~%"))
    (unless (line-offset point 1)
      (error "Could not create Org metadata line")))
  (line-start point)
  point)

(defun agenda-clock-body-insertion-point (heading)
  "Return where Org's default LOGBOOK belongs below HEADING metadata."
  (with-point ((point heading))
    (agenda-clock-move-after-line point)
    (loop :while (ppcre:scan *planning-line-scanner* (line-string point))
          :do (agenda-clock-move-after-line point))
    (when (string-equal (agenda-clock-trimmed-line point) ":PROPERTIES:")
      (with-point ((property-start point))
        (let ((closed-p nil))
          (loop :while (line-offset point 1)
                :when (string-equal (agenda-clock-trimmed-line point) ":END:")
                  :do (setf closed-p t)
                      (return)
                :when (org-heading-line-p point)
                  :do (return))
          (if closed-p
              (agenda-clock-move-after-line point)
              (move-point point property-start)))))
    (copy-point point :temporary)))

(defun agenda-clock-insert-open-line (target start-time)
  "Insert one default-drawer clock for TARGET and return its live line point."
  (let* ((heading (agenda-clock-validate-target target t))
         (buffer (point-buffer heading))
         (timestamp (agenda-clock-timestamp start-time))
         (logbook-end (agenda-clock-find-logbook-end heading))
         (clock-point nil))
    (with-current-buffer buffer
      (if logbook-end
          (progn
            (setf clock-point (copy-point logbook-end :right-inserting))
            (insert-string logbook-end (format nil "CLOCK: ~a~%" timestamp)))
          (with-point ((insertion (agenda-clock-body-insertion-point heading)))
            (insert-string insertion (format nil ":LOGBOOK:~%"))
            (unless (line-offset insertion 1)
              (error "Could not create Org clock drawer"))
            (setf clock-point (copy-point insertion :right-inserting))
            (insert-string insertion
                           (format nil "CLOCK: ~a~%:END:~%" timestamp)))))
    (values clock-point timestamp)))

(defun agenda-clock-active-record-p (record)
  (and *agenda-active-clock*
       (alive-point-p (agenda-active-clock-clock-point *agenda-active-clock*))
       (eq (point-buffer (agenda-clock-record-point record))
           (point-buffer
            (agenda-active-clock-clock-point *agenda-active-clock*)))
       (same-line-p (agenda-clock-record-point record)
                    (agenda-active-clock-clock-point *agenda-active-clock*))))

(defun agenda-clock-clear-active ()
  (when *agenda-active-clock*
    (ignore-errors
      (delete-point (agenda-active-clock-clock-point *agenda-active-clock*)))
    (ignore-errors
      (delete-point (agenda-active-clock-heading-point *agenda-active-clock*)))
    (setf *agenda-active-clock* nil)))

(defun agenda-clock-close-record (record end-time)
  "Close RECORD at END-TIME, preserving indentation and Org duration shape."
  (let* ((point (agenda-clock-record-point record))
         (line (and (alive-point-p point) (line-string point)))
         (start (and line (agenda-clock-line-start-time line))))
    (unless (and start (= start (agenda-clock-record-start-time record)))
      (error "Clock start line changed before it could be stopped"))
    (let* ((active-p (agenda-clock-active-record-p record))
           (timestamp (agenda-clock-timestamp end-time))
           (duration (agenda-clock-duration start end-time))
           (replacement
             (format nil "~a--~a => ~a"
                     (string-right-trim '(#\Space #\Tab) line)
                     timestamp duration)))
      (with-point ((end point))
        (line-end end)
        (delete-between-points point end)
        (insert-string point replacement))
      (when active-p (agenda-clock-clear-active))
      duration)))

(defun agenda-clock-save-target-buffer (target)
  (save-buffer (point-buffer (agenda-clock-validate-target target))))

(defun agenda-clock-refresh (agenda-buffer restore-target)
  (setf (buffer-value agenda-buffer 'lem-yath-agenda-restore-entry)
        (and restore-target
             (agenda-clock-target-entry-key restore-target)))
  (agenda-start-scan agenda-buffer))

;;; --- stock global clock in Vi state -------------------------------------

(defun agenda-clock-active-valid-p (&optional writable-p)
  (and *agenda-active-clock*
       (let ((clock (agenda-active-clock-clock-point *agenda-active-clock*))
             (heading (agenda-active-clock-heading-point *agenda-active-clock*)))
         (and (alive-point-p clock)
              (alive-point-p heading)
              (not (deleted-buffer-p (point-buffer clock)))
              (eq (point-buffer clock) (point-buffer heading))
              (or (not writable-p)
                  (not (buffer-read-only-p (point-buffer clock))))
              (string= (line-string heading)
                       (agenda-active-clock-heading *agenda-active-clock*))
              (eql (agenda-clock-line-start-time (line-string clock))
                   (agenda-active-clock-start-time *agenda-active-clock*))))))

(defun agenda-clock-active-same-target-p (target)
  (and (agenda-clock-active-valid-p)
       (eq (point-buffer (agenda-clock-target-point target))
           (point-buffer
            (agenda-active-clock-heading-point *agenda-active-clock*)))
       (same-line-p (agenda-clock-target-point target)
                    (agenda-active-clock-heading-point
                     *agenda-active-clock*))))

(defun agenda-clock-stop-active (end-time)
  (unless (agenda-clock-active-valid-p t)
    (error "No running clock"))
  (let* ((active *agenda-active-clock*)
         (buffer (point-buffer (agenda-active-clock-clock-point active)))
         (record
           (make-agenda-clock-record
            :point (copy-point (agenda-active-clock-clock-point active)
                               :temporary)
            :file (agenda-active-clock-file active)
            :start-time (agenda-active-clock-start-time active)))
         (duration (agenda-clock-close-record record end-time)))
    (save-buffer buffer)
    duration))

(define-command lem-yath-agenda-clock-in () ()
  "Start GNU Org's single global clock on the current agenda item."
  (let ((agenda-buffer (current-buffer))
        (target nil)
        (changed-p nil))
    (unwind-protect
         (handler-case
             (progn
               (setf target (agenda-clock-target-from-row))
               (agenda-clock-validate-target target t)
               (if (agenda-clock-active-same-target-p target)
                   (message "Clock continues in ~s"
                            (agenda-clock-target-heading target))
                   (progn
                     (let ((now (agenda-clock-now)))
                       (when *agenda-active-clock*
                         (agenda-clock-stop-active now)
                         (setf changed-p t))
                       (multiple-value-bind (clock-point timestamp)
                           (agenda-clock-insert-open-line target now)
                         (setf *agenda-active-clock*
                               (make-agenda-active-clock
                                :clock-point clock-point
                                :heading-point
                                (copy-point
                                 (agenda-clock-target-point target)
                                 :left-inserting)
                                :file (agenda-clock-target-file target)
                                :heading (agenda-clock-target-heading target)
                                :start-time now)
                               changed-p t)
                         (agenda-clock-save-target-buffer target)
                         (message "Clock starts at ~a" timestamp)))
                     (when changed-p
                       (agenda-clock-refresh agenda-buffer target)))))
           (error (condition)
             (message "Agenda clock-in failed: ~a" condition)))
      (agenda-clock-delete-target target))))

(define-command lem-yath-agenda-clock-out () ()
  "Stop the GNU Org-style global clock, independent of agenda point."
  (let ((agenda-buffer (current-buffer))
        (restore-target nil))
    (unwind-protect
         (handler-case
             (progn
               (when (agenda-row-mark-key-at-point (current-point))
                 (setf restore-target (agenda-clock-target-from-row)))
               (let* ((now (agenda-clock-now))
                      (timestamp (agenda-clock-timestamp now))
                      (duration (agenda-clock-stop-active now)))
                 (agenda-clock-refresh agenda-buffer restore-target)
                 (message "Clock stopped at ~a after ~a" timestamp duration)))
           (error (condition)
             (message "Agenda clock-out failed: ~a" condition)))
      (agenda-clock-delete-target restore-target))))

;;; --- user's concurrent Emacs-state clocks -------------------------------

(defun agenda-clock-marked-targets ()
  "Return marked targets in Org's oldest-mark-first processing order."
  (reverse (copy-list (agenda-bulk-marks))))

(defun agenda-clock-marked-restore-target (targets)
  "Return the marked TARGET corresponding to the current rendered row.

The source line is intentionally ignored: a live source point can remain
valid after an insertion even though the unrefreshed agenda row is numeric."
  (let ((key (agenda-row-mark-key-at-point (current-point))))
    (or (and key
             (find-if
              (lambda (target)
                (and (string= (first key)
                              (agenda-clock-file-key
                               (agenda-clock-target-file target)))
                     (equal (cddr key)
                            (list (agenda-clock-target-heading target)
                                  (agenda-clock-target-kind target)
                                  (agenda-clock-target-date target)
                                  (agenda-clock-target-time target)
                                  (agenda-clock-target-occurrence-index target)
                                  (agenda-clock-target-duplicate-index target)))))
              targets))
        (first targets))))

(defun agenda-clock-start-additional (target start-time)
  (agenda-clock-validate-target target t)
  (if (agenda-clock-open-records-at-heading target)
      :already-open
      (progn
        (multiple-value-bind (point timestamp)
            (agenda-clock-insert-open-line target start-time)
          (declare (ignore timestamp))
          ;; Delegated clocks intentionally do not become the global clock.
          (delete-point point))
        (agenda-clock-save-target-buffer target)
        :started)))

(define-command lem-yath-agenda-clock-in-additional () ()
  "Start delegated clocks for marked rows, or the current row."
  (let ((agenda-buffer (current-buffer))
        (owned-target nil)
        (restore-target nil))
    (unwind-protect
         (handler-case
             (let* ((marked (agenda-clock-marked-targets))
                    (targets
                      (or marked
                          (list (setf owned-target
                                      (agenda-clock-target-from-row)))))
                    (start-time (agenda-clock-now))
                    (started 0)
                    (already-open 0))
               (setf restore-target
                     (if marked
                         (agenda-clock-marked-restore-target marked)
                         owned-target))
               ;; Validate every marker before the first source mutation.
               (dolist (target targets)
                 (agenda-clock-validate-target target t))
               (dolist (target targets)
                 (ecase (agenda-clock-start-additional target start-time)
                   (:started (incf started))
                   (:already-open (incf already-open))))
               (when (plusp started)
                 (agenda-clock-refresh agenda-buffer restore-target))
               (message "Started ~d delegated clock~:p~@[; ~d already open~]"
                        started
                        (and (plusp already-open) already-open)))
           (error (condition)
             (message "Agenda delegated clock-in failed: ~a" condition)))
      (agenda-clock-delete-target owned-target))))

(defun agenda-clock-close-target-records (target end-time)
  (agenda-clock-validate-target target t)
  (let ((records (agenda-clock-open-records-at-heading target))
        (count 0))
    (dolist (record records)
      (agenda-clock-close-record record end-time)
      (incf count))
    (when (plusp count)
      (agenda-clock-save-target-buffer target))
    count))

(defun agenda-clock-close-all-agenda-files (end-time)
  (multiple-value-bind (files failures) (agenda-org-files)
    (declare (ignore failures))
    (let ((records '())
          (buffers '()))
      (dolist (file files)
        (setf records
              (nconc records (agenda-clock-open-records-in-file file))))
      ;; Reject a read-only/stale batch before changing its first clock.
      (dolist (record records)
        (let ((buffer (point-buffer (agenda-clock-record-point record))))
          (when (or (deleted-buffer-p buffer) (buffer-read-only-p buffer))
            (error "Agenda source is read-only: ~a"
                   (agenda-clock-record-file record)))))
      (dolist (record records)
        (let ((buffer (point-buffer (agenda-clock-record-point record))))
          (agenda-clock-close-record record end-time)
          (pushnew buffer buffers :test #'eq)))
      (dolist (buffer buffers) (save-buffer buffer))
      (length records))))

(define-command lem-yath-agenda-clock-out-open-clocks () ()
  "Stop marked-heading clocks, or every open clock in all agenda files."
  (let ((agenda-buffer (current-buffer))
        (restore-target nil)
        (owned-restore-target nil))
    (unwind-protect
         (handler-case
             (let* ((targets (agenda-clock-marked-targets))
                    (end-time (agenda-clock-now))
                    (count 0))
               (setf restore-target
                     (if targets
                         (agenda-clock-marked-restore-target targets)
                         (when (agenda-row-mark-key-at-point (current-point))
                           (setf owned-restore-target
                                 (agenda-clock-target-from-row)))))
               (if targets
                   (progn
                     (dolist (target targets)
                       (agenda-clock-validate-target target t))
                     (dolist (target targets)
                       (incf count
                             (agenda-clock-close-target-records
                              target end-time))))
                   (setf count
                         (agenda-clock-close-all-agenda-files end-time)))
               (when (plusp count)
                 (agenda-clock-refresh agenda-buffer restore-target))
               (message "Stopped ~d open Org clock~:p" count))
           (error (condition)
             (message "Agenda delegated clock-out failed: ~a" condition)))
      (agenda-clock-delete-target owned-restore-target))))

;;; --- state-specific bindings --------------------------------------------

(setf *agenda-row-marked-p-function* #'agenda-bulk-row-marked-p)
(pushnew 'agenda-bulk-buffer-cleanup *agenda-buffer-cleanup-functions*)

;; Evil-Org motion state.
(define-key *lem-yath-agenda-vi-keymap* "I" 'lem-yath-agenda-clock-in)
(define-key *lem-yath-agenda-vi-keymap* "O" 'lem-yath-agenda-clock-out)
(define-key *lem-yath-agenda-vi-keymap* "m" 'lem-yath-agenda-bulk-toggle)
(define-key *lem-yath-agenda-vi-keymap* "~" 'lem-yath-agenda-bulk-toggle-all)
(define-key *lem-yath-agenda-vi-keymap* "*" 'lem-yath-agenda-bulk-mark-all)
(define-key *lem-yath-agenda-vi-keymap* "%" 'lem-yath-agenda-bulk-mark-regexp)
(define-key *lem-yath-agenda-vi-keymap* "M" 'lem-yath-agenda-bulk-unmark-all)

;; Base Org agenda map, reached in the user's C-z Emacs state.
(define-key *lem-yath-agenda-mode-keymap* "I"
  'lem-yath-agenda-clock-in-additional)
(define-key *lem-yath-agenda-mode-keymap* "O"
  'lem-yath-agenda-clock-out-open-clocks)
(define-key *lem-yath-agenda-mode-keymap* "m" 'lem-yath-agenda-bulk-mark)
(define-key *lem-yath-agenda-mode-keymap* "M-m" 'lem-yath-agenda-bulk-toggle)
(define-key *lem-yath-agenda-mode-keymap* "*" 'lem-yath-agenda-bulk-mark-all)
(define-key *lem-yath-agenda-mode-keymap* "M-*"
  'lem-yath-agenda-bulk-toggle-all)
(define-key *lem-yath-agenda-mode-keymap* "%"
  'lem-yath-agenda-bulk-mark-regexp)
(define-key *lem-yath-agenda-mode-keymap* "u" 'lem-yath-agenda-bulk-unmark)
(define-key *lem-yath-agenda-mode-keymap* "U"
  'lem-yath-agenda-bulk-unmark-all)
