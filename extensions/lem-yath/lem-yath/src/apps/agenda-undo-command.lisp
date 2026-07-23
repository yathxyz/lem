;;;; Evil-Org remote source-buffer undo command.

(in-package :lem-yath)

(define-command lem-yath-agenda-undo () ()
  "Undo the newest registered remote agenda edit without saving its sources."
  (let* ((agenda-buffer (current-buffer))
         (records (agenda-undo-records agenda-buffer))
         (record (first records)))
    (cond
      ((null record)
       (message "No further undo information"))
      ((not (every #'agenda-undo-context-buffer-live-p
                   (agenda-undo-record-contexts record)))
       (message "Agenda undo failed: a source buffer is no longer available"))
      (t
       ;; Consume first, as GNU Org does, because a partial remote undo cannot
       ;; safely be replayed if a later buffer unexpectedly refuses undo.
       (setf (agenda-undo-records agenda-buffer) (rest records))
       (handler-case
           (progn
             (dolist (context (agenda-undo-record-contexts record))
               (let ((buffer (agenda-undo-context-buffer context)))
                 (unless (buffer-undo (buffer-point buffer))
                   (error "source buffer has no further undo information"))))
             (dolist (function *agenda-undo-post-functions*)
               (funcall function record))
             (setf (buffer-value agenda-buffer
                                 'lem-yath-agenda-restore-entry)
                   (agenda-undo-record-restore-key record))
             (agenda-start-scan agenda-buffer)
             (message "`~a' undone"
                      (agenda-undo-record-label record)))
         (error (condition)
           (message "Agenda undo failed: ~a" condition)))))))

(define-key *lem-yath-agenda-vi-keymap* "u" 'lem-yath-agenda-undo)
