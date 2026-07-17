(defpackage :lem-tests/revert-buffer
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/revert-buffer)

(defun write-file (path content)
  (with-open-file (stream path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string content stream)))

(defmacro with-temp-file ((path content) &body body)
  `(let ((,path (uiop:with-temporary-file (:pathname p :keep t) p)))
     (unwind-protect
          (progn (write-file ,path ,content)
                 ,@body)
       (uiop:delete-file-if-exists ,path))))

(defun open-disk-changed-buffer (path buffer-content disk-content
                                 &key modify)
  "Open PATH in a buffer whose text is BUFFER-CONTENT, rewrite the file on disk
with DISK-CONTENT, and force `changed-disk-p' to be true.  When MODIFY, leave
the buffer marked as modified."
  (write-file path buffer-content)
  (let ((buffer (lem:find-file-buffer path)))
    (setf (lem:current-buffer) buffer)
    (when modify
      (lem:insert-string (lem:buffer-end-point buffer) "edited")
      (assert (lem:buffer-modified-p buffer)))
    (write-file path disk-content)
    ;; Force an external-change signal deterministically, independent of the
    ;; one-second file-write-date resolution.
    (setf (lem:buffer-last-write-date buffer) 0)
    (assert (lem:changed-disk-p buffer))
    buffer))

(defun buffer-string (buffer)
  (lem:points-to-string (lem:buffer-start-point buffer)
                        (lem:buffer-end-point buffer)))

(deftest modified-buffer-keep-preserves-edits
  (with-fake-interface ()
    (with-temp-file (path "original")
      (let* ((lem-core/commands/file::*last-revert-time* nil)
             (buffer (open-disk-changed-buffer path "original" "changed"
                                               :modify t))
             (before (buffer-string buffer)))
        (lem:unread-key (lem:make-key :sym "n"))
        (lem-core/commands/file::ask-revert-buffer)
        (ok (equal before (buffer-string buffer))
            "keep answer leaves the modified buffer untouched")
        (ok (lem:buffer-modified-p buffer)
            "buffer is still modified after keeping")))))

(deftest modified-buffer-revert-loads-disk-content
  (with-fake-interface ()
    (with-temp-file (path "original")
      (let* ((lem-core/commands/file::*last-revert-time* nil)
             (buffer (open-disk-changed-buffer path "original" "changed"
                                               :modify t)))
        (lem:unread-key (lem:make-key :sym "y"))
        (lem-core/commands/file::ask-revert-buffer)
        (ok (equal "changed" (buffer-string buffer))
            "revert answer replaces buffer with disk content")
        (ok (not (lem:buffer-modified-p buffer))
            "buffer is unmodified after reverting")))))

(deftest unmodified-buffer-reverts-silently
  (with-fake-interface ()
    (with-temp-file (path "original")
      (let* ((lem-core/commands/file::*last-revert-time* nil)
             (buffer (open-disk-changed-buffer path "original" "changed"
                                               :modify nil)))
        ;; No key is fed: an unmodified buffer must revert without prompting.
        (lem-core/commands/file::ask-revert-buffer)
        (ok (equal "changed" (buffer-string buffer))
            "unmodified buffer picks up disk content silently")
        (ok (not (lem:buffer-modified-p buffer))
            "buffer is unmodified after silent revert")))))

(deftest guard-prevents-reentrant-prompt
  (with-fake-interface ()
    (with-temp-file (path "original")
      (let* ((buffer (open-disk-changed-buffer path "original" "changed"
                                               :modify t))
             (before (buffer-string buffer)))
        ;; A single revert answer is queued up front.
        (lem:unread-key (lem:make-key :sym "y"))
        ;; While a prompt is already open the guard must suppress any new
        ;; prompt, and must not consume the queued key.
        (let ((lem-core/commands/file::*asking-revert-buffer-p* t)
              (lem-core/commands/file::*last-revert-time* nil))
          (lem-core/commands/file::ask-revert-buffer))
        (ok (equal before (buffer-string buffer))
            "guarded call does not revert")
        (ok (lem:buffer-modified-p buffer)
            "guarded call leaves the buffer modified")
        ;; The queued key survived; a normal call now consumes it and reverts,
        ;; proving the guarded call neither prompted nor read input.
        (let ((lem-core/commands/file::*last-revert-time* nil))
          (lem-core/commands/file::ask-revert-buffer))
        (ok (equal "changed" (buffer-string buffer))
            "the still-queued answer reverts on the next unguarded call")))))
