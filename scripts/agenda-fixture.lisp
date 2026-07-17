(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0)))

(defvar *agenda-test-report-serial* 0)
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
      "return=~a g=~a t=~a schedule=~a deadline=~a ct=~a tags=~a q=~a "
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
     (agenda-test-command-name "g")
     (agenda-test-command-name "t")
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

(define-command lem-yath-test-agenda-goto-effort () ()
  (move-point (current-point)
              (agenda-test-find-line "Effort action sentinel")))

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

(define-command lem-yath-test-agenda-return () ()
  (alexandria:if-let ((buffer (get-buffer *agenda-buffer-name*)))
    (switch-to-buffer buffer)
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
(define-key *lem-yath-agenda-vi-keymap* "C-c e"
  'lem-yath-test-agenda-goto-effort)
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
