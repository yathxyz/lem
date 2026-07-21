(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0)))
(setf *agenda-note-time-function*
      (lambda () (encode-universal-time 0 34 9 12 7 2026 0)))
(setf *org-capture-time-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0)))

(defvar *agenda-test-report-serial* 0)
(defvar *agenda-test-preview-report-serial* 0)
(defvar *agenda-test-note-report-serial* 0)
(defvar *agenda-test-capture-report-serial* 0)
(defvar *agenda-test-drag-report-serial* 0)
(defvar *agenda-test-todo-set-report-serial* 0)
(defvar *agenda-test-original-top-level-org-files* nil)
(defvar *agenda-test-stale-source* nil)

(defun agenda-test-report-path ()
  (or (uiop:getenv "LEM_YATH_AGENDA_REPORT")
      (error "LEM_YATH_AGENDA_REPORT is unset")))

(defun agenda-test-log (format-control &rest arguments)
  (with-open-file (stream (agenda-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream format-control arguments)
    (terpri stream)
    (finish-output stream)))

(defun agenda-test-todo-set-diary-command-watch ()
  (let ((command (and (this-command) (command-name (this-command))))
        (kind (text-property-at (current-point) :agenda-kind)))
    (when (and (member command '(lem-yath-agenda-todo-previousset
                                 lem-yath-agenda-todo-nextset))
               (equal kind "DIARY"))
      (agenda-test-log "TODO-SET-DIARY-COMMAND command=~a kind=~a"
                       command kind))))

(remove-hook *post-command-hook* 'agenda-test-todo-set-diary-command-watch)
(add-hook *post-command-hook* 'agenda-test-todo-set-diary-command-watch)

(defun agenda-test-path (pathname)
  (uiop:native-namestring pathname))

(defun agenda-test-command-name (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command)
        (symbol-name command)
        (princ-to-string command))))

(defun agenda-test-hook-count (function hooks)
  (count function hooks :key #'car :test #'eq))

(defun agenda-test-section-name (line current)
  (cond
    ((string= line "Overdue") "OVERDUE")
    ((string= line "Today") "TODAY")
    ((alexandria:starts-with-subseq "Upcoming (" line) "UPCOMING")
    ((string= line "TODOs") "TODOS")
    (t current)))

(defun agenda-test-report-entries (buffer serial)
  (with-point ((point (buffer-start-point buffer)))
    (loop :with section := "NONE"
          :with warnings-p := nil
          :do (line-start point)
              (let* ((text (line-string point))
                     (file (text-property-at point :agenda-file))
                     (line (text-property-at point :agenda-line)))
                (setf section (agenda-test-section-name text section))
                (when (string= text "Warnings")
                  (setf warnings-p t))
                (when file
                  (agenda-test-log
                   "ENTRY serial=~d section=~a file=~a line=~d text=~s"
                   serial section (agenda-test-path file) line text))
                (when (and warnings-p
                           (not (string= text "Warnings"))
                           (plusp (length text)))
                  (agenda-test-log "WARNING serial=~d text=~s" serial text)))
          :unless (line-offset point 1)
            :do (return))))

(define-command lem-yath-test-agenda-report () ()
  (let* ((serial (incf *agenda-test-report-serial*))
         (buffer (current-buffer))
         (directories (agenda-directories))
         (files (agenda-org-files)))
    (agenda-test-log
     (concatenate
      'string
      "STATIC serial=~d mode=~a date=~a roots=~d files=~d generation=~d "
      "return=~a gr=~a gR=~a t=~a p=~a a=~a C=~a schedule=~a deadline=~a ct=~a tags=~a q=~a "
      "J=~a K=~a H=~a L=~a dd=~a ce=~a shift-left=~a shift-right=~a "
      "dA=~a da=~a dollar=~a archive=~a refile=~a kill-hooks=~d "
      "modified=~a undo=~a "
      "running=~a pending=~a")
     serial
     (symbol-name (buffer-major-mode buffer))
     (today-iso)
     (length directories)
     (length files)
     (agenda-buffer-generation buffer)
     (agenda-test-command-name "Return")
     (agenda-test-command-name "g r")
     (agenda-test-command-name "g R")
     (agenda-test-command-name "t")
     (agenda-test-command-name "p")
     (agenda-test-command-name "a")
     (agenda-test-command-name "C")
     (agenda-test-command-name "C-c C-s")
     (agenda-test-command-name "C-c C-d")
     (agenda-test-command-name "c t")
     (agenda-test-command-name "C-c C-q")
     (agenda-test-command-name "q")
     (agenda-test-command-name "J")
     (agenda-test-command-name "K")
     (agenda-test-command-name "H")
     (agenda-test-command-name "L")
     (agenda-test-command-name "d d")
     (agenda-test-command-name "c e")
     (agenda-test-command-name "Shift-Left")
     (agenda-test-command-name "Shift-Right")
     (agenda-test-command-name "d A")
     (agenda-test-command-name "d a")
     (agenda-test-command-name "$")
     (agenda-test-command-name "C-c C-x C-a")
     (agenda-test-command-name "C-c C-w")
     (agenda-test-hook-count
      'agenda-kill-buffer-cleanup
      (variable-value 'kill-buffer-hook :buffer buffer))
     (if (buffer-modified-p buffer) "yes" "no")
     (if (buffer-enable-undo-p buffer) "yes" "no")
     (if (agenda-scan-running-p buffer) "yes" "no")
     (if (agenda-refresh-pending-p buffer) "yes" "no"))
    (agenda-test-log
     (concatenate
      'string
      "OPEN-MOTION serial=~d tab=~a shift-return=~a gtab=~a "
      "gj=~a gk=~a Cj=~a Ck=~a Mj=~a Mk=~a space=~a backspace=~a delete=~a "
      "mret=~a P=~a")
     serial
     (agenda-test-command-name "Tab")
     (agenda-test-command-name "Shift-Return")
     (agenda-test-command-name "g Tab")
     (agenda-test-command-name "g j")
     (agenda-test-command-name "g k")
     (agenda-test-command-name "C-j")
     (agenda-test-command-name "C-k")
     (agenda-test-command-name "M-j")
     (agenda-test-command-name "M-k")
     (agenda-test-command-name "Space")
     (agenda-test-command-name "Backspace")
     (agenda-test-command-name "Delete")
     (agenda-test-command-name "M-Return")
     (agenda-test-command-name "P"))
    (agenda-test-log
     "TODO-SET-BINDINGS serial=~d previous=~a next=~a fallback-previous=~a fallback-next=~a"
     serial
     (agenda-test-command-name "C-Shift-h")
     (agenda-test-command-name "C-Shift-l")
     (agenda-test-command-name "C-c H")
     (agenda-test-command-name "C-c L"))
    (agenda-test-log "INSPECT-BINDINGS serial=~d tags=~a"
                     serial (agenda-test-command-name "g t"))
    (loop :for directory :in directories
          :for index :from 1
          :do (agenda-test-log "ROOT serial=~d index=~d path=~a"
                               serial index (agenda-test-path directory)))
    (loop :for file :in files
          :for index :from 1
          :do (agenda-test-log "FILE serial=~d index=~d path=~a"
                               serial index (agenda-test-path file)))
    (let ((known-tags (agenda-known-tags)))
      (agenda-test-log "TAG-COMPLETION serial=~d known=~{~a~^,~} items=~{~a~^,~}"
                       serial known-tags
                       (agenda-tag-completion-items ":al" known-tags)))
    (agenda-test-report-entries buffer serial)
    (agenda-test-log "REPORT-DONE serial=~d" serial)))

(defun agenda-test-find-line (text)
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (error "Agenda test text not found: ~s" text))
    (line-start point)
    point))

(define-command lem-yath-test-agenda-goto-public () ()
  (move-point (current-point)
              (agenda-test-find-line "Public visit sentinel")))

(define-command lem-yath-test-agenda-goto-work-todo () ()
  (move-point (current-point)
              (agenda-test-find-line "Work unscheduled sentinel")))

(define-command lem-yath-test-agenda-goto-todo-set () ()
  (move-point (current-point)
              (agenda-test-find-line "Upcoming work sentinel")))

(define-command lem-yath-test-agenda-goto-diary-guard () ()
  (move-point (current-point)
              (agenda-test-find-line "Diary guard sentinel")))

(define-command lem-yath-test-agenda-todo-set-report () ()
  (let* ((original (copy-point (current-point) :temporary))
         (point (agenda-test-find-line "Upcoming work sentinel"))
         (serial (incf *agenda-test-todo-set-report-serial*)))
    (agenda-test-log
     "TODO-SET serial=~d heading=~s current=~a modified=~a"
     serial
     (text-property-at point :agenda-heading)
     (if (point= original point) "yes" "no")
     (if (buffer-modified-p (current-buffer)) "yes" "no"))))

(define-command lem-yath-test-agenda-goto-effort () ()
  (move-point (current-point)
              (agenda-test-find-line "Effort action sentinel")))

(define-command lem-yath-test-agenda-goto-note () ()
  (move-point (current-point)
              (agenda-test-find-line "Note action sentinel")))

(define-command lem-yath-test-agenda-goto-capture () ()
  (move-point (current-point)
              (agenda-test-find-line "Body event sentinel")))

(define-command lem-yath-test-agenda-goto-drag () ()
  (move-point (current-point)
              (agenda-test-find-line "After archive sentinel"))
  (unless (agenda-bulk-find-mark
           (current-buffer)
           (agenda-row-mark-key-at-point (current-point)))
    (agenda-bulk-add-current)))

(define-command lem-yath-test-agenda-drag-report () ()
  (with-point ((original (current-point)))
    (let* ((rows
             (mapcar
              (lambda (entry)
                (cons (car entry)
                      (line-number-at-point
                       (agenda-test-find-line (cdr entry)))))
              '(("after" . "After archive sentinel")
                ("refile" . "Refile action sentinel")
                ("child" . "Refile child sentinel"))))
           (order (mapcar #'car (sort rows #'< :key #'cdr)))
           (key (agenda-row-mark-key-at-point original))
           (serial (incf *agenda-test-drag-report-serial*)))
      (agenda-test-log
       (concatenate
        'string
        "DRAG serial=~d order=~{~a~^,~} current=~a identity=~a "
        "marked=~a marks=~d modified=~a")
       serial order
       (if (search "After archive sentinel" (line-string original))
           "after" "other")
       (if (and (text-property-at original :agenda-file)
                (integerp (text-property-at original :agenda-line))
                (string= (text-property-at original :agenda-heading)
                         "* TODO After archive sentinel"))
           "yes" "no")
       (if (and key
                (char= (or (character-at original) #\Space) #\>)
                (agenda-bulk-row-marked-p (current-buffer) key))
           "yes" "no")
       (length (agenda-bulk-marks))
       (if (buffer-modified-p (current-buffer)) "yes" "no")))
    (move-point (current-point) original)))

(define-command lem-yath-test-agenda-drag-ready () ()
  (unless (agenda-scan-running-p (current-buffer))
    (with-point ((original (current-point)))
      (when (handler-case
                (progn (agenda-test-find-line "After archive sentinel") t)
              (error () nil))
        (move-point (current-point) original)
        (agenda-test-log "DRAG-READY")))))

(defun agenda-test-time-string (time)
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time time)
    (declare (ignore second))
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d"
            year month day hour minute)))

(define-command lem-yath-test-agenda-capture-report () ()
  (let* ((session (or *org-capture-session*
                      (error "No active Org capture session")))
         (request (org-capture-session-request session))
         (origin (org-capture-request-origin-buffer request))
         (origin-point (org-capture-request-origin-point request))
         (text (buffer-text (current-buffer)))
         (serial (incf *agenda-test-capture-report-serial*)))
    (with-current-buffer origin
      (with-point ((unscheduled (buffer-start-point origin))
                   (projected (buffer-start-point origin)))
        (unless (search-forward-regexp
                 unscheduled
                 (ppcre:quote-meta-chars "Work unscheduled sentinel"))
          (error "Unscheduled agenda test row is missing"))
        (line-start unscheduled)
        (unless (search-forward-regexp
                 projected
                 (ppcre:quote-meta-chars "Upcoming work sentinel"))
          (error "Projected agenda test row is missing"))
        (line-start projected)
        (agenda-test-log
         (concatenate
          'string
          "CAPTURE-REPORT serial=~d mode=~a timestamp=~a annotation=~a "
          "origin=~a default=~a prefixed=~a fallback=~a projected=~a")
         serial
         (symbol-name (buffer-major-mode (org-capture-session-capture-buffer
                                          session)))
         (if (search "[2026-07-13 Mon 00:00]" text) "yes" "no")
         (if (search "[[file:" text) "yes" "no")
         (if (search "Body event sentinel" (line-string origin-point))
             "yes" "no")
         (agenda-test-time-string
          (org-capture-request-default-time request))
         (agenda-test-time-string
          (agenda-capture-default-time origin-point t))
         (agenda-test-time-string
          (agenda-capture-default-time unscheduled nil))
         (agenda-test-time-string
          (agenda-capture-default-time projected nil)))))))

(define-command lem-yath-test-agenda-capture-target-report () ()
  (let* ((path (merge-pathnames "todo.org" (workdir)))
         (text (if (uiop:probe-file* path) (uiop:read-file-string path) "")))
    (agenda-test-log
     (concatenate
      'string
      "CAPTURE-TARGET mode=~a origin=~a content=~a timestamp=~a "
      "annotation=~a session=~a")
     (symbol-name (buffer-major-mode (current-buffer)))
     (if (search "Body event sentinel" (line-string (current-point)))
         "yes" "no")
     (if (search "Agenda cursor date capture" text) "yes" "no")
     (if (search "[2026-07-13 Mon 00:00]" text) "yes" "no")
     (if (search "[[file:" text) "yes" "no")
     (if *org-capture-session* "yes" "no"))))

(defun agenda-test-note-source-text ()
  (let* ((point (current-point))
         (file (text-property-at point :agenda-file))
         (line (text-property-at point :agenda-line))
         (heading (text-property-at point :agenda-heading)))
    (multiple-value-bind (buffer source-point)
        (agenda-source-heading-point file line heading "reporting its note")
      (with-current-buffer buffer
        (let ((end (org-subtree-end-point source-point)))
          (values buffer file (points-to-string source-point end)))))))

(define-command lem-yath-test-agenda-note-report () ()
  (multiple-value-bind (buffer file text) (agenda-test-note-source-text)
    (let* ((disk (uiop:read-file-string file))
           (planning (search "SCHEDULED:" text))
           (properties (search ":PROPERTIES:" text))
           (property-end (search ":END:" text))
           (note (search "- Note taken on" text))
           (timestamp (search "Note taken on [2026-07-12 Sun 09:34]" text))
           (first-line (search "Agenda note first line" text))
           (second-line (search "Agenda note second line" text))
           (continuation-backslashes
             (and note first-line
                  (count #\\ text :start note :end first-line)))
           (body (search "Original note body sentinel." text))
           (serial (incf *agenda-test-note-report-serial*)))
      (agenda-test-log
       (concatenate
        'string
        "NOTE-REPORT serial=~d mode=~a modified=~a disk-note=~a notes=~d "
        "content=~a cancelled=~a order=~a undo-records=~d session=~a private=~a")
       serial
       (symbol-name (buffer-major-mode (current-buffer)))
       (if (buffer-modified-p buffer) "yes" "no")
       (if (search "Note taken on" disk) "yes" "no")
       (/ (length (ppcre:all-matches "Note taken on" text)) 2)
       (if (and timestamp first-line second-line
                (= continuation-backslashes 2)
                (< timestamp first-line second-line))
           "yes" "no")
       (if (search "Cancelled agenda note text" text) "yes" "no")
       (if (and planning properties property-end note body
                (< planning properties property-end note body))
           "yes" "no")
       (length (agenda-undo-records (current-buffer)))
       (if *agenda-note-session* "yes" "no")
       (if (find *agenda-note-buffer-name* (buffer-list)
                 :key #'buffer-name :test #'string=)
           "yes" "no")))))

(define-command lem-yath-test-agenda-note-make-stale () ()
  (let* ((session (or *agenda-note-session*
                      (error "No active agenda note")))
         (source (agenda-note-session-source-buffer session))
         (point (agenda-note-session-source-point session)))
    (with-current-buffer source
      (with-point ((end point))
        (line-end end)
        (insert-string end " stale")))
    (agenda-test-log "NOTE-STALE made=yes")))

(define-command lem-yath-test-agenda-note-restore-heading () ()
  (let* ((session (or *agenda-note-session*
                      (error "No active agenda note")))
         (source (agenda-note-session-source-buffer session))
         (point (agenda-note-session-source-point session)))
    (with-current-buffer source
      (with-point ((end point)
                   (start point))
        (line-end end)
        (move-point start end)
        (character-offset start -6)
        (unless (string= (points-to-string start end) " stale")
          (error "The agenda note stale suffix changed"))
        (delete-between-points start end)))
    (agenda-test-log "NOTE-STALE restored=yes")))

(define-command lem-yath-test-agenda-note-session-report () ()
  (let ((session *agenda-note-session*))
    (agenda-test-log
     "NOTE-SESSION active=~a mode=~a draft=~a"
     (if session "yes" "no")
     (symbol-name (buffer-major-mode (current-buffer)))
     (if (and session
              (search "Stale draft sentinel"
                      (buffer-text (agenda-note-session-note-buffer session))))
         "yes" "no"))))

(define-command lem-yath-test-agenda-note-kill-buffer () ()
  (delete-buffer (current-buffer)))

(define-command lem-yath-test-agenda-stale-preview-report () ()
  (agenda-test-log
   "STALE-PREVIEW focus=~a live=~a"
   (if (eq (buffer-major-mode (current-buffer)) 'lem-yath-agenda-mode)
       "agenda" "other")
   (if (agenda-preview-window-live-p) "yes" "no")))

(define-command lem-yath-test-agenda-mutations-ready () ()
  (handler-case
      (progn
        (agenda-test-find-line "Effort action sentinel")
        (agenda-test-log "MUTATIONS-READY"))
    (error () nil)))

(define-command lem-yath-test-agenda-refresh-ready () ()
  (handler-case
      (progn
        (agenda-test-find-line "Refreshed top-level sentinel")
        (agenda-test-log "REFRESH-READY"))
    (error () nil)))

(define-command lem-yath-test-agenda-discovery-ready () ()
  (handler-case
      (progn
        (agenda-test-find-line "Injected agenda root failure")
        (agenda-test-log "DISCOVERY-READY"))
    (error () nil)))

(define-command lem-yath-test-agenda-timestamp-ready () ()
  (handler-case
      (progn
        (agenda-test-find-line "Timestamp prompt planning sentinel")
        (agenda-test-log "TIMESTAMP-READY"))
    (error () nil)))

(define-command lem-yath-test-agenda-goto-delete () ()
  (move-point (current-point)
              (agenda-test-find-line "Delete action sentinel")))

(define-command lem-yath-test-agenda-goto-delete-one-line () ()
  (move-point (current-point)
              (agenda-test-find-line "Delete one-line sentinel")))

(define-command lem-yath-test-agenda-goto-date-shift-planning () ()
  (move-point (current-point)
              (agenda-test-find-line "Date shift planning sentinel")))

(define-command lem-yath-test-agenda-goto-date-shift-event () ()
  (move-point (current-point)
              (agenda-test-find-line "Date shift event sentinel")))

(define-command lem-yath-test-agenda-goto-time-shift-event () ()
  (move-point (current-point)
              (agenda-test-find-line "Time shift event sentinel")))

(define-command lem-yath-test-agenda-goto-timestamp-planning () ()
  (move-point (current-point)
              (agenda-test-find-line "Timestamp prompt planning sentinel")))

(define-command lem-yath-test-agenda-goto-timestamp-event () ()
  (move-point (current-point)
              (agenda-test-find-line "Timestamp prompt event sentinel")))

(define-command lem-yath-test-agenda-goto-timestamp-none () ()
  (move-point (current-point)
              (agenda-test-find-line "Timestamp prompt no-date sentinel")))

(define-command lem-yath-test-agenda-goto-archive () ()
  (move-point (current-point)
              (handler-case
                  (agenda-test-find-line "Archive action sentinel")
                (error ()
                  (agenda-test-find-line "Refile action sentinel")))))

(define-command lem-yath-test-agenda-make-source-stale () ()
  (let* ((file (text-property-at (current-point) :agenda-file))
         (buffer (and file (find-file-buffer file))))
    (unless buffer
      (error "Agenda source buffer is unavailable"))
    (with-current-buffer buffer
      (insert-string (buffer-start-point buffer)
                     (format nil "# unsaved stale line~%")))
    (setf *agenda-test-stale-source* buffer)
    (agenda-test-log "STALE-MADE modified=~a"
                     (if (buffer-modified-p buffer) "yes" "no"))))

(define-command lem-yath-test-agenda-report-stale-source () ()
  (let ((buffer *agenda-test-stale-source*))
    (unless buffer
      (error "No stale agenda source was prepared"))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (let ((first (line-string point)))
          (line-offset point 1)
          (agenda-test-log
           "STALE-SOURCE modified=~a first=~s second=~s"
           (if (buffer-modified-p buffer) "yes" "no")
           first (line-string point)))))))

(define-command lem-yath-test-agenda-clear-stale-source () ()
  (let ((buffer *agenda-test-stale-source*))
    (unless buffer
      (error "No stale agenda source was prepared"))
    (with-current-buffer buffer
      (with-point ((start (buffer-start-point buffer))
                   (end (buffer-start-point buffer)))
        (unless (string= (line-string start) "# unsaved stale line")
          (error "Stale agenda fixture line changed"))
        (unless (line-offset end 1)
          (error "Stale agenda fixture has no following source line"))
        (delete-between-points start end))
      (buffer-unmark buffer))
    (setf *agenda-test-stale-source* nil)))

(define-command lem-yath-test-agenda-point-report () ()
  (let ((file (text-property-at (current-point) :agenda-file))
        (line (text-property-at (current-point) :agenda-line)))
    (agenda-test-log
     "POINT mode=~a file=~a line=~a text=~s"
     (symbol-name (buffer-major-mode (current-buffer)))
     (if file (agenda-test-path file) "none")
     (or line "none")
     (line-string (current-point)))))

(define-command lem-yath-test-agenda-source-report () ()
  (agenda-test-log
   "SOURCE file=~a line=~d mode=~a text=~s"
   (agenda-test-path (buffer-filename (current-buffer)))
   (line-number-at-point (current-point))
   (symbol-name (buffer-major-mode (current-buffer)))
   (line-string (current-point))))

(define-command lem-yath-test-agenda-preview-report () ()
  (let ((serial (incf *agenda-test-preview-report-serial*))
        (window *agenda-preview-window*)
        (agenda-focus-p
          (eq (buffer-major-mode (current-buffer))
              'lem-yath-agenda-mode)))
    (if (or (null window) (deleted-window-p window))
        (agenda-test-log "PREVIEW serial=~d live=no" serial)
        (with-current-window window
          (agenda-test-log
           (concatenate
            'string
            "PREVIEW serial=~d live=yes focus=~a file=~a point=~d view=~d "
            "cursor-y=~d centered=~a")
           serial
           (if agenda-focus-p "agenda" "source")
           (agenda-test-path (buffer-filename (current-buffer)))
           (line-number-at-point (current-point))
           (line-number-at-point (window-view-point window))
           (lem-core::window-cursor-y window)
           (if (= (lem-core::window-cursor-y window)
                  (floor (lem-core::window-height-without-modeline window) 2))
               "yes" "no"))))))

(define-command lem-yath-test-agenda-return () ()
  (alexandria:if-let ((buffer (get-buffer *agenda-buffer-name*)))
    (let ((agenda-window
            (find-if (lambda (window)
                       (and (not (eq window (current-window)))
                            (eq (window-buffer window) buffer)))
                     (get-buffer-windows buffer))))
      (if agenda-window
          (progn
            (quit-active-window)
            (setf (current-window) agenda-window))
          (switch-to-buffer buffer)))
    (error "Agenda buffer no longer exists")))

(defun agenda-test-race-item (text)
  (make-agenda-item
   :keyword "TODO"
   :text text
   :file (merge-pathnames "same.org" (public-org-directory))
   :line 3
   :date nil
   :kind nil))

(define-command lem-yath-test-agenda-race () ()
  (let* ((buffer (current-buffer))
         (old-generation (agenda-next-generation buffer))
         (new-generation (agenda-next-generation buffer)))
    (agenda-render-if-current
     buffer new-generation
     (list (agenda-test-race-item "New generation sentinel")))
    (bt2:make-thread
     (lambda ()
       (sleep 0.25)
       (send-event
        (lambda ()
          (let* ((accepted
                   (agenda-render-if-current
                    buffer old-generation
                    (list (agenda-test-race-item "Old generation sentinel"))))
                 (contents
                   (points-to-string (buffer-start-point buffer)
                                     (buffer-end-point buffer))))
            (agenda-test-log
             "RACE old-accepted=~a new-present=~a old-present=~a generation=~d"
             (if accepted "yes" "no")
             (if (search "New generation sentinel" contents) "yes" "no")
             (if (search "Old generation sentinel" contents) "yes" "no")
             (agenda-buffer-generation buffer))))))
     :name "lem-yath/agenda-race-test")))

(define-command lem-yath-test-agenda-kill () ()
  (let* ((buffer (or (get-buffer *agenda-buffer-name*)
                     (error "Agenda buffer no longer exists")))
         (generation (agenda-next-generation buffer)))
    (kill-buffer buffer)
    (let ((accepted
            (ignore-errors
              (agenda-render-if-current
               buffer generation
               (list (agenda-test-race-item "Killed buffer sentinel"))))))
      (agenda-test-log "KILL live=~a stale-accepted=~a"
                       (if (agenda-buffer-live-p buffer) "yes" "no")
                       (if accepted "yes" "no")))))

(defun agenda-test-failing-top-level-org-files (directory)
  (if (uiop:pathname-equal
       directory (merge-pathnames "mcp/" (public-org-directory)))
      (let ((original *agenda-test-original-top-level-org-files*))
        (setf (symbol-function 'agenda-top-level-org-files) original
              *agenda-test-original-top-level-org-files* nil)
        (error "Injected agenda root failure"))
      (funcall *agenda-test-original-top-level-org-files* directory)))

(define-command lem-yath-test-agenda-root-failure () ()
  (when *agenda-test-original-top-level-org-files*
    (error "Agenda root failure test is already active"))
  (setf *agenda-test-original-top-level-org-files*
        (symbol-function 'agenda-top-level-org-files)
        (symbol-function 'agenda-top-level-org-files)
        #'agenda-test-failing-top-level-org-files)
  (agenda-start-scan (current-buffer)))

(define-command lem-yath-test-agenda-prompt-point-report () ()
  (let ((start (lem/prompt-window::current-prompt-start-point))
        (point (current-point)))
    (agenda-test-log
     "PROMPT-POINT input=~s offset=~d"
     (lem/prompt-window::get-input-string)
     (- (position-at-point point) (position-at-point start)))))

(dolist (keymap (list lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "F5" 'lem-yath-test-agenda-prompt-point-report))

;; Test-only controls avoid prompt timing while leaving the production keys
;; under test (SPC m a, Return, g, and q) untouched.
(define-key *lem-yath-agenda-vi-keymap* "F4" 'lem-yath-test-agenda-report)
(define-key *lem-yath-agenda-vi-keymap* "F5" 'lem-yath-test-agenda-goto-public)
(define-key *lem-yath-agenda-vi-keymap* "F6" 'lem-yath-test-agenda-point-report)
(define-key *lem-yath-agenda-vi-keymap* "F12"
  'lem-yath-test-agenda-goto-work-todo)
(define-key *lem-yath-agenda-vi-keymap* "C-c 0"
  'lem-yath-test-agenda-goto-todo-set)
(define-key *lem-yath-agenda-vi-keymap* "C-c 9"
  'lem-yath-test-agenda-todo-set-report)
(define-key *lem-yath-agenda-vi-keymap* "C-c D"
  'lem-yath-test-agenda-goto-diary-guard)
(define-key *lem-yath-agenda-vi-keymap* "C-c e"
  'lem-yath-test-agenda-goto-effort)
(define-key *lem-yath-agenda-vi-keymap* "C-c 1"
  'lem-yath-test-agenda-goto-note)
(define-key *lem-yath-agenda-vi-keymap* "C-c 4"
  'lem-yath-test-agenda-goto-capture)
(define-key *lem-yath-agenda-vi-keymap* "C-c 5"
  'lem-yath-test-agenda-capture-target-report)
(define-key *lem-yath-agenda-vi-keymap* "C-c 6"
  'lem-yath-test-agenda-goto-drag)
(define-key *lem-yath-agenda-vi-keymap* "C-c 7"
  'lem-yath-test-agenda-drag-report)
(define-key *lem-yath-agenda-vi-keymap* "C-c 8"
  'lem-yath-test-agenda-drag-ready)
(define-key *lem-yath-agenda-vi-keymap* "C-c 2"
  'lem-yath-test-agenda-note-report)
(define-key *lem-yath-agenda-vi-keymap* "C-c 3"
  'lem-yath-test-agenda-stale-preview-report)
(define-key *lem-yath-agenda-vi-keymap* "C-c m"
  'lem-yath-test-agenda-mutations-ready)
(define-key *lem-yath-agenda-vi-keymap* "C-c f"
  'lem-yath-test-agenda-refresh-ready)
(define-key *lem-yath-agenda-vi-keymap* "C-c o"
  'lem-yath-test-agenda-discovery-ready)
(define-key *lem-yath-agenda-vi-keymap* "C-c i"
  'lem-yath-test-agenda-timestamp-ready)
(define-key *lem-yath-agenda-vi-keymap* "C-c d"
  'lem-yath-test-agenda-goto-delete)
(define-key *lem-yath-agenda-vi-keymap* "C-c k"
  'lem-yath-test-agenda-goto-delete-one-line)
(define-key *lem-yath-agenda-vi-keymap* "C-c p"
  'lem-yath-test-agenda-goto-date-shift-planning)
(define-key *lem-yath-agenda-vi-keymap* "C-c r"
  'lem-yath-test-agenda-goto-date-shift-event)
(define-key *lem-yath-agenda-vi-keymap* "C-c h"
  'lem-yath-test-agenda-goto-time-shift-event)
(define-key *lem-yath-agenda-vi-keymap* "C-c v"
  'lem-yath-test-agenda-goto-timestamp-planning)
(define-key *lem-yath-agenda-vi-keymap* "C-c y"
  'lem-yath-test-agenda-goto-timestamp-event)
(define-key *lem-yath-agenda-vi-keymap* "C-c n"
  'lem-yath-test-agenda-goto-timestamp-none)
(define-key *lem-yath-agenda-vi-keymap* "C-c z"
  'lem-yath-test-agenda-clear-stale-source)
(define-key *lem-yath-agenda-vi-keymap* "C-c b"
  'lem-yath-test-agenda-preview-report)
(define-key *lem-yath-agenda-vi-keymap* "F1"
  'lem-yath-test-agenda-goto-archive)
(define-key *lem-yath-agenda-vi-keymap* "F3"
  'lem-yath-test-agenda-make-source-stale)
(define-key *lem-yath-agenda-vi-keymap* "F2"
  'lem-yath-test-agenda-report-stale-source)
(define-key *lem-yath-agenda-vi-keymap* "F9" 'lem-yath-test-agenda-race)
(define-key *lem-yath-agenda-vi-keymap* "F10" 'lem-yath-test-agenda-kill)
(define-key *lem-yath-agenda-vi-keymap* "F11"
  'lem-yath-test-agenda-root-failure)
(define-key *org-vi-normal-keymap* "F7" 'lem-yath-test-agenda-source-report)
(define-key *org-vi-normal-keymap* "F8" 'lem-yath-test-agenda-return)
(define-key *org-vi-insert-keymap* "F7" 'lem-yath-test-agenda-source-report)
(define-key *org-vi-insert-keymap* "F8" 'lem-yath-test-agenda-return)
(define-key *agenda-note-mode-keymap* "F5"
  'lem-yath-test-agenda-note-make-stale)
(define-key *agenda-note-mode-keymap* "F6"
  'lem-yath-test-agenda-note-restore-heading)
(define-key *agenda-note-mode-keymap* "F7"
  'lem-yath-test-agenda-note-session-report)
(define-key *agenda-note-mode-keymap* "F8"
  'lem-yath-test-agenda-note-kill-buffer)
(define-key *org-capture-mode-keymap* "F9"
  'lem-yath-test-agenda-capture-report)
