;;;; GNU Org flagged-agenda note feedback.

(in-package :lem-yath)

(defparameter *agenda-flagging-note-buffer-name* "*Flagging Note*")

(defvar *agenda-flagging-note-repeat-buffer* nil)

(defun agenda-flagging-note-property-at-point
    (&optional (point (current-point)))
  "Return POINT's immediate THEFLAGGINGNOTE agenda-row property."
  (cdr (assoc "THEFLAGGINGNOTE"
              (text-property-at point :agenda-properties)
              :test #'string=)))

(defun agenda-flagged-note-at-point
    (&optional (point (current-point)) (buffer (current-buffer)))
  "Return POINT's THEFLAGGINGNOTE value in the explicit flagged view."
  (let ((state (agenda-view-state buffer)))
    (when (eq (agenda-view-state-command state) :flagged)
      (agenda-flagging-note-property-at-point point))))

(defun agenda-flagging-note-display-text (note)
  "Expand NOTE's literal backslash-n separators for the detail buffer."
  (ppcre:regex-replace-all "\\\\n" note (string #\Newline)))

(defun agenda-flagged-note-display (buffer point)
  "Echo POINT's flagging note after source-row movement in BUFFER."
  (alexandria:when-let ((note (agenda-flagged-note-at-point point buffer)))
    (message "FLAGGING-NOTE ([?] for more info): ~a"
             (ppcre:regex-replace-all "\\\\n" note "//"))))

(defun agenda-flagging-note-show-buffer (note)
  "Show NOTE in Org's non-selected flagging-note split."
  (let* ((source-window (current-window))
         (buffer (make-buffer *agenda-flagging-note-buffer-name*))
         (window nil))
    (with-current-buffer buffer
      (erase-buffer buffer)
      (insert-string (buffer-point buffer)
                     (agenda-flagging-note-display-text note))
      (buffer-start (buffer-point buffer))
      (buffer-unmark buffer))
    (setf window (pop-to-buffer buffer :split-action :sensibly))
    (switch-to-window source-window)
    window))

(defun agenda-flagging-note-delete-property (heading name)
  "Delete immediate property NAME at HEADING and remove an empty drawer."
  (with-point ((drawer heading))
    (agenda-clock-move-after-line drawer)
    (loop :while (ppcre:scan *planning-line-scanner* (line-string drawer))
          :do (agenda-clock-move-after-line drawer))
    (unless (string-equal (agenda-clock-trimmed-line drawer) ":PROPERTIES:")
      (return-from agenda-flagging-note-delete-property nil))
    (let ((found-p nil))
      (with-point ((point drawer))
        (loop :while (line-offset point 1)
              :for line := (agenda-clock-trimmed-line point)
              :do
                 (cond
                   ((string-equal line ":END:") (return))
                   ((org-heading-line-p point)
                    (error "Malformed Org property drawer: missing :END:"))
                   (t
                    (multiple-value-bind (property value)
                        (agenda-filter-property-fields line)
                      (declare (ignore value))
                      (when (and property (string-equal property name))
                        (with-point ((start point) (end point))
                          (line-start start)
                          (unless (line-offset end 1) (line-end end))
                          (delete-between-points start end))
                        (setf found-p t)
                        (return)))))
              :finally
                 (error "Malformed Org property drawer: missing :END:")))
      (when found-p
        (with-point ((next drawer))
          (unless (line-offset next 1)
            (error "Malformed Org property drawer: missing :END:"))
          (when (string-equal (agenda-clock-trimmed-line next) ":END:")
            (with-point ((start drawer) (end next))
              (line-start start)
              (unless (line-offset end 1) (line-end end))
              (delete-between-points start end)))))
      found-p)))

(defun agenda-flagging-note-remove-source (file line expected-heading)
  "Remove FLAGGED and THEFLAGGINGNOTE from one validated source heading."
  (multiple-value-bind (buffer heading)
      (agenda-source-heading-point file line expected-heading "unflagging")
    (with-current-buffer buffer
      (agenda-undo-track-buffer buffer)
      (agenda-flagging-note-delete-property heading "THEFLAGGINGNOTE")
      (agenda-set-heading-tags
       heading
       (remove "FLAGGED" (agenda-heading-tags heading)
               :test #'string-equal))
      (save-buffer buffer)))
  t)

(defun agenda-flagging-note-close-buffer ()
  (alexandria:when-let ((buffer
                         (get-buffer *agenda-flagging-note-buffer-name*)))
    (dolist (window (get-buffer-windows buffer))
      (ignore-errors (delete-window window)))))

(define-command lem-yath-agenda-show-flagging-note () ()
  "Show, copy, or consecutively remove the current row's flagging note."
  (let* ((agenda-buffer (current-buffer))
         (point (current-point))
         (entry-key (agenda-entry-key-at-point point))
         (file (text-property-at point :agenda-file))
         (line (text-property-at point :agenda-line))
         (heading (text-property-at point :agenda-heading))
         (note (agenda-flagging-note-property-at-point point))
         (repeated-p (eq agenda-buffer *agenda-flagging-note-repeat-buffer*)))
    (cond
      ((null file) (message "No linked entry at point"))
      ((and repeated-p
            (prompt-for-y-or-n-p "Unflag and remove any flagging note? "))
       (handler-case
           (progn
             (with-agenda-undo-transaction
                 (agenda-buffer "org-agenda-remove-flag" entry-key)
               (agenda-flagging-note-remove-source file line heading))
             (setf *agenda-flagging-note-repeat-buffer* nil)
             (agenda-flagging-note-close-buffer)
             (agenda-start-scan agenda-buffer)
             (message "Entry unflagged"))
         (error (condition)
           (message "Agenda unflag failed: ~a" condition))))
      ((null note) (message "No flagging note"))
      (t
       (copy-to-clipboard-with-killring note)
       (agenda-flagging-note-show-buffer note)
       (setf *agenda-flagging-note-repeat-buffer* agenda-buffer)
       (message
        "Flagging note pushed to kill ring. Press '?' again to remove tag and note")))))

(defun agenda-flagging-note-post-command ()
  "Forget consecutive `?' state after any other command."
  (unless (eq (and (this-command) (command-name (this-command)))
              'lem-yath-agenda-show-flagging-note)
    (setf *agenda-flagging-note-repeat-buffer* nil)))

(pushnew 'agenda-flagged-note-display *agenda-item-motion-functions*)
(remove-hook *post-command-hook* 'agenda-flagging-note-post-command)
(add-hook *post-command-hook* 'agenda-flagging-note-post-command)

(define-key *lem-yath-agenda-vi-keymap* "?"
  'lem-yath-agenda-show-flagging-note)
(define-key *lem-yath-agenda-vi-keymap* "P"
  'lem-yath-agenda-show-flagging-note)
(define-key *lem-yath-agenda-mode-keymap* "?"
  'lem-yath-agenda-show-flagging-note)
