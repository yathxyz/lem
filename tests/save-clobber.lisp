(defpackage :lem-tests/save-clobber
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/save-clobber)

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

(defun buffer-string (buffer)
  (lem:points-to-string (lem:buffer-start-point buffer)
                        (lem:buffer-end-point buffer)))

(defun open-disk-changed-buffer (path buffer-content disk-content)
  "Open PATH in a modified buffer holding BUFFER-CONTENT, rewrite the file on
disk with DISK-CONTENT, and force `changed-disk-p' to be true (independent of
the one-second file-write-date resolution)."
  (write-file path buffer-content)
  (let ((buffer (lem:find-file-buffer path)))
    (setf (lem:current-buffer) buffer)
    (lem:insert-string (lem:buffer-end-point buffer) "edited")
    (assert (lem:buffer-modified-p buffer))
    (write-file path disk-content)
    (setf (lem:buffer-last-write-date buffer) 0)
    (assert (lem:changed-disk-p buffer))
    buffer))

(deftest declining-clobber-prompt-keeps-disk-content
  (with-fake-interface ()
    (with-temp-file (path "original")
      (let ((buffer (open-disk-changed-buffer path "original" "external")))
        (lem:unread-key (lem:make-key :sym "n"))
        (ok (null (lem-core/commands/file:save-buffer buffer))
            "declining reports nothing was written")
        (ok (equal "external" (uiop:read-file-string path))
            "disk keeps the other process's content")
        (ok (lem:buffer-modified-p buffer)
            "buffer stays modified after declining")))))

(deftest accepting-clobber-prompt-overwrites-disk
  (with-fake-interface ()
    (with-temp-file (path "original")
      (let ((buffer (open-disk-changed-buffer path "original" "external")))
        (lem:unread-key (lem:make-key :sym "y"))
        (ok (lem-core/commands/file:save-buffer buffer)
            "accepting reports the file was written")
        (ok (equal (buffer-string buffer) (uiop:read-file-string path))
            "disk is overwritten with the buffer's content")
        (ok (not (lem:buffer-modified-p buffer))
            "buffer is unmodified after saving")))))

(deftest unchanged-file-saves-without-prompting
  (with-fake-interface ()
    (with-temp-file (path "original")
      (let ((buffer (lem:find-file-buffer path)))
        (setf (lem:current-buffer) buffer)
        (lem:insert-string (lem:buffer-end-point buffer) "edited")
        (assert (not (lem:changed-disk-p buffer)))
        ;; No key is queued: an unchanged file must save without a prompt.
        (ok (lem-core/commands/file:save-buffer buffer)
            "saving an unchanged file succeeds")
        (ok (equal (buffer-string buffer) (uiop:read-file-string path))
            "buffer content is written to disk")
        (ok (not (lem:buffer-modified-p buffer))
            "buffer is unmodified after saving")))))
