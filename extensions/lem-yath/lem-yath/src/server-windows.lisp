;;;; Native Windows boundary for the Unix-domain/tmux editor server.

(in-package :lem-yath)

(defun server-buffer-requests (&optional (buffer (current-buffer)))
  (declare (ignore buffer))
  nil)

(defun (setf server-buffer-requests) (requests
                                     &optional (buffer (current-buffer)))
  (declare (ignore buffer))
  requests)

(define-command lem-yath-server-edit-done () ()
  (editor-error "lemclient integration is not available on native Windows"))

(define-command lem-yath-server-save-done () ()
  (editor-error "lemclient integration is not available on native Windows"))

(define-command lem-yath-server-abort () ()
  (editor-error "lemclient integration is not available on native Windows"))

(defun server-start-maybe ()
  nil)

(defun server-shutdown (&optional reason)
  (declare (ignore reason))
  nil)
