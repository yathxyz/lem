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

;;; Private-file helpers shared with git-rebase and claude-bridge.  The
;;; POSIX server hardens these with ownership and mode checks; on native
;;; Windows the profile directory ACL is the protection.

(defun server-stat-if-present (pathname)
  (handler-case
      (sb-posix:lstat (platform-stat-namestring pathname))
    (sb-posix:syscall-error () nil)))

(defun server-ensure-private-directory (pathname)
  (unless (uiop:absolute-pathname-p pathname)
    (error "Server file path must be absolute: ~a" pathname))
  (let ((directory (uiop:pathname-directory-pathname pathname)))
    (ensure-directories-exist pathname)
    (unless (uiop:directory-exists-p directory)
      (error "Server directory is missing: ~a" directory))
    directory))

(defun server-write-private-file (pathname text)
  (with-open-file (stream pathname
                   :direction :output
                   :if-exists :supersede
                   :if-does-not-exist :create
                   :element-type '(unsigned-byte 8))
    (write-sequence (sb-ext:string-to-octets text :external-format :utf-8)
                    stream)
    (finish-output stream)))

(defun server-delete-owned-path (pathname expected-type)
  ;; CRT stat cannot express sockets and reports no real ownership, so
  ;; only regular files are ever deleted here.
  (when (and pathname
             (= expected-type sb-posix:s-ifreg))
    (let ((stat (server-stat-if-present pathname)))
      (when (and stat
                 (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                    sb-posix:s-ifreg))
        (ignore-errors (delete-file pathname))))))
