;;;; Evil-Org agenda note sessions with GNU Org's effective log-note syntax.

(in-package :lem-yath)

(eval-when (:load-toplevel :execute)
  (when (fboundp 'agenda-note-cleanup-for-reload)
    (agenda-note-cleanup-for-reload)))

(defparameter *agenda-note-buffer-name* "*Org Note*")
(defparameter *agenda-note-buffer-character-limit* (* 1024 1024))
(defparameter *agenda-note-time-function* #'get-universal-time)

(defvar *agenda-note-mode-keymap* (make-keymap))
(defvar *agenda-note-session* nil)

(defstruct agenda-note-session
  agenda-buffer
  agenda-window
  agenda-pop-state
  agenda-point
  agenda-entry-key
  agenda-state
  source-buffer
  source-point
  expected-heading
  note-buffer
  closing-p)

(define-minor-mode lem-yath-agenda-note-mode
    (:name "Org-Note"
     :description "Finish or abort an Org agenda note"
     :keymap *agenda-note-mode-keymap*))

(defun agenda-note-buffer-live-p (buffer)
  (and (bufferp buffer) (not (deleted-buffer-p buffer))))

(defun agenda-note-agenda-live-p (session)
  (let ((buffer (agenda-note-session-agenda-buffer session)))
    (and (agenda-note-buffer-live-p buffer)
         (mode-active-p buffer 'lem-yath-agenda-mode))))

(defun agenda-note-source-live-p (session)
  (let ((buffer (agenda-note-session-source-buffer session))
        (point (agenda-note-session-source-point session)))
    (and (agenda-note-buffer-live-p buffer)
         point
         (alive-point-p point)
         (eq (point-buffer point) buffer))))

(defun agenda-note-release-points (session)
  (dolist (point (list (agenda-note-session-agenda-point session)
                       (agenda-note-session-source-point session)))
    (when point (ignore-errors (delete-point point))))
  (setf (agenda-note-session-agenda-point session) nil
        (agenda-note-session-source-point session) nil))

(defun agenda-note-disable-session (session)
  (let ((agenda (agenda-note-session-agenda-buffer session))
        (source (agenda-note-session-source-buffer session))
        (note (agenda-note-session-note-buffer session)))
    (when (agenda-note-buffer-live-p agenda)
      (with-current-buffer agenda
        (remove-hook (variable-value 'kill-buffer-hook :buffer agenda)
                     'agenda-note-origin-kill-buffer-hook)))
    (when (agenda-note-buffer-live-p source)
      (with-current-buffer source
        (remove-hook (variable-value 'kill-buffer-hook :buffer source)
                     'agenda-note-source-kill-buffer-hook)))
    (when (agenda-note-buffer-live-p note)
      (with-current-buffer note
        (remove-hook (variable-value 'kill-buffer-hook :buffer note)
                     'agenda-note-buffer-kill-hook)
        (setf (buffer-value note 'lem-yath-agenda-note-session) nil)
        (when (mode-active-p note 'lem-yath-agenda-note-mode)
          (lem-yath-agenda-note-mode nil))))))

(defun agenda-note-clear-session (session)
  (unless (agenda-note-session-closing-p session)
    (setf (agenda-note-session-closing-p session) t)
    (agenda-note-disable-session session)
    (agenda-note-release-points session)
    (when (eq *agenda-note-session* session)
      (setf *agenda-note-session* nil))))

(defun agenda-note-delete-private-buffer (buffer)
  (when (agenda-note-buffer-live-p buffer)
    (with-global-variable-value (kill-buffer-hook nil)
      (delete-buffer buffer))))

(defun agenda-note-restore-agenda (session)
  "Restore SESSION's agenda window, logical row, and Vi state."
  (unless (agenda-note-agenda-live-p session)
    (error "The originating agenda no longer exists"))
  (let ((window (agenda-note-session-agenda-window session))
        (buffer (agenda-note-session-agenda-buffer session))
        (point (agenda-note-session-agenda-point session))
        (key (agenda-note-session-agenda-entry-key session)))
    (when (and window (not (deleted-window-p window)))
      (setf (current-window) window)
      (setf (lem-core::window-pop-to-buffer-state window)
            (agenda-note-session-agenda-pop-state session)))
    (unless (eq (current-buffer) buffer)
      (switch-to-buffer buffer nil nil))
    (cond
      ((and key (agenda-restore-entry-point buffer key)))
      ((and point (alive-point-p point))
       (move-point (current-point) point))
      (t
       (buffer-start (current-point))))
    (alexandria:when-let ((state (agenda-note-session-agenda-state session)))
      (setf (lem-vi-mode/core:current-state) state))))

(defun agenda-note-buffer-text (buffer)
  (let ((characters (- (position-at-point (buffer-end-point buffer))
                       (position-at-point (buffer-start-point buffer)))))
    (when (> characters *agenda-note-buffer-character-limit*)
      (error "The Org note exceeds the ~d-character safety limit"
             *agenda-note-buffer-character-limit*))
    (let ((text (points-to-string (buffer-start-point buffer)
                                  (buffer-end-point buffer))))
      (when (> (length (babel:string-to-octets text :encoding :utf-8))
               *agenda-note-buffer-character-limit*)
        (error "The UTF-8 Org note exceeds the safety limit"))
      text)))

(defun agenda-note-strip-instructions (text)
  "Remove GNU Org's leading instruction comments and trailing whitespace."
  (loop
    :for stripped :=
      (ppcre:regex-replace
       "\\A# [^\\r\\n]*(?:\\r?\\n|\\z)[ \\t\\r\\n]*" text "")
    :while (not (string= stripped text))
    :do (setf text stripped))
  (string-right-trim '(#\Space #\Tab #\Return #\Newline) text))

(defun agenda-note-render-entry (text time)
  "Render TEXT using the active configuration's default Org note heading."
  (let* ((body (agenda-note-strip-instructions text))
         (lines (unless (string= body "") (ppcre:split "\\r?\\n" body)))
         (heading (format nil "- Note taken on ~a"
                          (inactive-org-timestamp time))))
    (with-output-to-string (stream)
      (write-string heading stream)
      (when lines
        (write-string " \\\\" stream)
        (dolist (line lines)
          (terpri stream)
          (unless (string= line "")
            (write-string "  " stream)
            (write-string line stream))))
      (terpri stream))))

(defun agenda-note-move-after-line (point)
  "Move POINT to the following line, creating the trailing newline if needed."
  (unless (line-offset point 1)
    (line-end point)
    (insert-string point (string #\Newline))
    (unless (line-offset point 1)
      (error "Could not create an Org note insertion line")))
  (line-start point)
  point)

(defun agenda-note-skip-valid-property-drawer (point)
  "Move POINT past an immediate valid property drawer, if one exists."
  (when (string-equal (agenda-clock-trimmed-line point) ":PROPERTIES:")
    (with-point ((scan point))
      (loop :while (line-offset scan 1)
            :for line := (agenda-clock-trimmed-line scan)
            :when (string-equal line ":END:")
              :do (move-point point scan)
                  (agenda-note-move-after-line point)
                  (return-from agenda-note-skip-valid-property-drawer t)
            :when (org-heading-line-p scan)
              :do (return nil))))
  nil)

(defun agenda-note-insertion-point (heading)
  "Return GNU Org's effective newest-first log-note location for HEADING."
  (with-point ((point heading))
    (agenda-note-move-after-line point)
    (when (ppcre:scan *planning-line-scanner* (line-string point))
      (agenda-note-move-after-line point))
    (agenda-note-skip-valid-property-drawer point)
    ;; `org-log-states-order-reversed' is at its configured default, so the
    ;; new note precedes any existing note list or ordinary body text.
    (loop :while (and (zerop (length (string-trim '(#\Space #\Tab #\Return)
                                                   (line-string point))))
                      (line-offset point 1))
          :do (line-start point))
    (copy-point point :temporary)))

(defun agenda-note-validate-source (session)
  "Return SESSION's exact writable source heading or fail closed."
  (unless (agenda-note-source-live-p session)
    (error "The Org note source no longer exists"))
  (let ((buffer (agenda-note-session-source-buffer session))
        (point (agenda-note-session-source-point session))
        (expected (agenda-note-session-expected-heading session)))
    (with-current-buffer buffer
      (when (buffer-read-only-p buffer)
        (error "Agenda note source is read-only: ~a"
               (or (buffer-filename buffer) (buffer-name buffer))))
      (unless (and (org-heading-line-p point)
                   (string= expected (line-string point)))
        (error "Agenda source changed; the note was not stored"))
      (copy-point point :temporary))))

(defun agenda-note-insert-source (session text)
  "Insert one unsaved ordinary source edit for SESSION and TEXT."
  (let ((heading (agenda-note-validate-source session))
        (buffer (agenda-note-session-source-buffer session)))
    (with-current-buffer buffer
      (buffer-undo-boundary buffer)
      (with-point ((insertion (agenda-note-insertion-point heading)))
        (insert-string insertion text))
      (buffer-undo-boundary buffer)))
  t)

(defun agenda-note-open-session (agenda-buffer agenda-window agenda-point
                                  entry-key source-buffer source-point heading)
  (let ((buffer nil)
        (session nil)
        (opened-p nil))
    (unwind-protect
         (progn
           (when (find *agenda-note-buffer-name* (buffer-list)
                       :key #'buffer-name :test #'string=)
             (error "The private Org note buffer name is already in use"))
           (setf buffer (make-buffer *agenda-note-buffer-name*))
           (with-buffer-read-only buffer nil
             (erase-buffer buffer)
             (change-buffer-mode buffer 'org-mode)
             (insert-string
              (buffer-start-point buffer)
              (format nil
                      (concatenate
                       'string
                       "# Insert note for this entry.~%"
                       "# Finish with C-c C-c, or cancel with C-c C-k.~%~%")))
             (buffer-end (buffer-point buffer)))
           (setf session
                 (make-agenda-note-session
                  :agenda-buffer agenda-buffer
                  :agenda-window agenda-window
                  :agenda-pop-state
                  (lem-core::window-pop-to-buffer-state agenda-window)
                  :agenda-point agenda-point
                  :agenda-entry-key entry-key
                  :agenda-state (lem-vi-mode/core:current-state)
                  :source-buffer source-buffer
                  :source-point source-point
                  :expected-heading heading
                  :note-buffer buffer)
                 *agenda-note-session* session
                 (buffer-value buffer 'lem-yath-agenda-note-session) session)
           (add-hook (variable-value 'kill-buffer-hook :buffer agenda-buffer)
                     'agenda-note-origin-kill-buffer-hook)
           (add-hook (variable-value 'kill-buffer-hook :buffer source-buffer)
                     'agenda-note-source-kill-buffer-hook)
           (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                     'agenda-note-buffer-kill-hook)
           (switch-to-buffer buffer nil nil)
           (buffer-end (current-point))
           (lem-yath-agenda-note-mode t)
           (setf (buffer-minor-modes buffer)
                 (cons 'lem-yath-agenda-note-mode
                       (remove 'lem-yath-agenda-note-mode
                               (buffer-minor-modes buffer))))
           (setf (lem-vi-mode/core:buffer-state buffer)
                 'lem-vi-mode/states:insert
                 opened-p t)
           (message "Insert note; finish with C-c C-c or cancel with C-c C-k."))
      (unless opened-p
        (when session (agenda-note-clear-session session))
        (unless session
          (ignore-errors (delete-point agenda-point))
          (ignore-errors (delete-point source-point)))
        (agenda-note-delete-private-buffer buffer)))))

(defun agenda-note-focus-existing ()
  (alexandria:when-let ((session *agenda-note-session*))
    (let ((buffer (agenda-note-session-note-buffer session)))
      (if (agenda-note-buffer-live-p buffer)
          (progn
            (switch-to-buffer buffer nil nil)
            (message "Finish with C-c C-c or abort with C-c C-k.")
            t)
          (progn
            (agenda-note-clear-session session)
            nil)))))

(define-command lem-yath-agenda-add-note () ()
  "Edit a time-stamped note for the exact source entry at point."
  (when (agenda-note-focus-existing)
    (return-from lem-yath-agenda-add-note nil))
  (let* ((agenda-buffer (current-buffer))
         (agenda-window (current-window))
         (point (current-point))
         (file (text-property-at point :agenda-file))
         (line (text-property-at point :agenda-line))
         (heading (text-property-at point :agenda-heading))
         (entry-key (agenda-entry-key-at-point point)))
    (if (null file)
        (message "No agenda entry on this line.")
        (handler-case
            (multiple-value-bind (source-buffer source-point)
                (agenda-source-heading-point file line heading "adding a note")
              (agenda-note-open-session
               agenda-buffer agenda-window
               (copy-point point :right-inserting)
               entry-key source-buffer
               (copy-point source-point :right-inserting)
               heading))
          (error (condition)
            (message "Agenda note failed: ~a" condition))))))

(define-command lem-yath-agenda-note-save-guard () ()
  (editor-error "Use C-c C-c to store or C-c C-k to abort this note."))

(define-command lem-yath-agenda-note-finalize () ()
  "Store the note as an unsaved source-buffer edit and restore the agenda."
  (let ((session *agenda-note-session*))
    (unless (and session
                 (eq (current-buffer)
                     (agenda-note-session-note-buffer session)))
      (editor-error "There is no active Org agenda note in this buffer."))
    (handler-case
        (let* ((note (agenda-note-session-note-buffer session))
               (text (agenda-note-render-entry
                      (agenda-note-buffer-text note)
                      (funcall *agenda-note-time-function*))))
          (agenda-note-insert-source session text)
          (agenda-note-restore-agenda session)
          (agenda-note-clear-session session)
          (agenda-note-delete-private-buffer note)
          (message "Note stored"))
      (error (condition)
        (message "Agenda note failed: ~a" condition)))))

(define-command lem-yath-agenda-note-abort () ()
  "Discard the private note buffer and restore the agenda without mutation."
  (let ((session *agenda-note-session*))
    (unless (and session
                 (eq (current-buffer)
                     (agenda-note-session-note-buffer session)))
      (editor-error "There is no active Org agenda note in this buffer."))
    (let ((note (agenda-note-session-note-buffer session)))
      (when (agenda-note-agenda-live-p session)
        (agenda-note-restore-agenda session))
      (agenda-note-clear-session session)
      (agenda-note-delete-private-buffer note)
      (message "Note aborted."))))

(defun agenda-note-buffer-kill-hook (&optional (buffer (current-buffer)))
  (alexandria:when-let
      ((session (buffer-value buffer 'lem-yath-agenda-note-session)))
    (unless (agenda-note-session-closing-p session)
      (when (agenda-note-agenda-live-p session)
        (ignore-errors (agenda-note-restore-agenda session)))
      (agenda-note-clear-session session))))

(defun agenda-note-origin-kill-buffer-hook (&optional (buffer (current-buffer)))
  (when (and *agenda-note-session*
             (eq buffer (agenda-note-session-agenda-buffer
                         *agenda-note-session*)))
    (let ((session *agenda-note-session*)
          (note (agenda-note-session-note-buffer *agenda-note-session*)))
      (agenda-note-clear-session session)
      (agenda-note-delete-private-buffer note))))

(defun agenda-note-source-kill-buffer-hook (&optional (buffer (current-buffer)))
  (when (and *agenda-note-session*
             (eq buffer (agenda-note-session-source-buffer
                         *agenda-note-session*)))
    (let ((session *agenda-note-session*)
          (note (agenda-note-session-note-buffer *agenda-note-session*)))
      (when (agenda-note-agenda-live-p session)
        (ignore-errors (agenda-note-restore-agenda session)))
      (agenda-note-clear-session session)
      (agenda-note-delete-private-buffer note)
      (message "Org note aborted because its source buffer was killed."))))

(defun agenda-note-agenda-cleanup (buffer)
  (when (and *agenda-note-session*
             (eq buffer (agenda-note-session-agenda-buffer
                         *agenda-note-session*)))
    (agenda-note-origin-kill-buffer-hook buffer)))

(defun agenda-note-cleanup-for-reload ()
  (alexandria:when-let ((session *agenda-note-session*))
    (let ((note (agenda-note-session-note-buffer session)))
      (when (agenda-note-agenda-live-p session)
        (ignore-errors (agenda-note-restore-agenda session)))
      (agenda-note-clear-session session)
      (agenda-note-delete-private-buffer note))))

(pushnew 'agenda-note-agenda-cleanup *agenda-buffer-cleanup-functions*)

(define-key *agenda-note-mode-keymap* "C-c C-c"
  'lem-yath-agenda-note-finalize)
(define-key *agenda-note-mode-keymap* "C-c C-k"
  'lem-yath-agenda-note-abort)
(define-key *agenda-note-mode-keymap* "C-x C-s"
  'lem-yath-agenda-note-save-guard)

(define-key *lem-yath-agenda-vi-keymap* "a" 'lem-yath-agenda-add-note)
(define-key *lem-yath-agenda-mode-keymap* "z" 'lem-yath-agenda-add-note)
(define-key *lem-yath-agenda-mode-keymap* "C-c C-z"
  'lem-yath-agenda-add-note)
