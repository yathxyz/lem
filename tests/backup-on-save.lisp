(defpackage :lem-tests/backup-on-save
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/backup-on-save)

;;; DS-4: the first save of a session per file copies the pre-save on-disk
;;; content to <file>~, independent of auto-save-mode. A later save in the same
;;; session must not overwrite that backup, so it always holds the content the
;;; file had when it was first opened. With the feature disabled, no backup
;;; appears.

(defun write-file-string (path content)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create
                            :element-type 'character)
    (write-string content out)))

(defmacro with-temp-file ((path content &optional (prefix "lem-ds4")) &body body)
  "Bind PATH to a fresh temp-file namestring seeded with CONTENT and remove it
afterwards."
  `(let ((,path (namestring
                 (uiop:tmpize-pathname
                  (merge-pathnames ,prefix (uiop:temporary-directory))))))
     (write-file-string ,path ,content)
     (unwind-protect (progn ,@body)
       (uiop:delete-file-if-exists ,path))))

(defun backup-namestring (path)
  "The <file>~ backup name the mechanism uses for the on-disk file at PATH."
  (format nil "~A~~" (namestring (truename path))))

(deftest backup-holds-original-across-saves
  (let ((lem/backup-on-save:*backup-on-save* t))
    (with-temp-file (path "ORIGINAL")
      (with-fake-interface ()
        (let ((buffer (lem:find-file-buffer path))
              (backup (backup-namestring path)))
          (unwind-protect
               (progn
                 ;; First edit + save: backup captures the original bytes.
                 (lem:insert-string (lem:buffer-end-point buffer) "-EDIT1")
                 (lem:write-to-file buffer path)
                 (ok (uiop:file-exists-p backup)
                     "a backup file is created on the first save")
                 (ok (equal "ORIGINAL" (uiop:read-file-string backup))
                     "the backup holds the original pre-save content")
                 ;; Second edit + save: the backup must be left untouched.
                 (lem:insert-string (lem:buffer-end-point buffer) "-EDIT2")
                 (lem:write-to-file buffer path)
                 (ok (equal "ORIGINAL" (uiop:read-file-string backup))
                     "the backup still holds the original after a second save")
                 (ok (equal "ORIGINAL-EDIT1-EDIT2" (uiop:read-file-string path))
                     "the real file received both edits"))
            (uiop:delete-file-if-exists backup)
            (lem:delete-buffer buffer)))))))

(deftest disabled-creates-no-backup
  (let ((lem/backup-on-save:*backup-on-save* nil))
    (with-temp-file (path "ORIGINAL")
      (with-fake-interface ()
        (let ((buffer (lem:find-file-buffer path))
              (backup (backup-namestring path)))
          (unwind-protect
               (progn
                 (lem:insert-string (lem:buffer-end-point buffer) "-EDIT")
                 (lem:write-to-file buffer path)
                 (ok (not (uiop:file-exists-p backup))
                     "no backup is created when the feature is disabled"))
            (uiop:delete-file-if-exists backup)
            (lem:delete-buffer buffer)))))))
