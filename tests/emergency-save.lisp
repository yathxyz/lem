(defpackage :lem-tests/emergency-save
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/emergency-save)

;;; DS-8: emergency save on SIGTERM/SIGHUP.
;;;
;;; The signal registration lives in the ncurses frontend and cannot be exercised
;;; headlessly, so these tests drive the frontend-agnostic entry point the handler
;;; calls -- LEM/EMERGENCY-SAVE:EMERGENCY-CHECKPOINT -- and assert it checkpoints
;;; every modified file-backed buffer (via the DS-3 mechanism) without touching the
;;; real files. Checkpoints are routed to a throwaway directory so the real
;;; $XDG_DATA_HOME/lem/autosave/ is never touched.

(defun write-file-string (path content)
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
    (write-string content out)))

(defun read-file-utf-8 (path)
  (with-open-file (in path :direction :input :external-format :utf-8)
    (let ((string (make-string (file-length in))))
      (subseq string 0 (read-sequence string in)))))

(defun fresh-checkpoint-dir ()
  "A unique, empty checkpoint directory pathname under the temp directory."
  (merge-pathnames (format nil "lem-ds8-~36R/" (random (expt 36 12)))
                   (uiop:temporary-directory)))

(defun fresh-temp-file (content)
  "Create a fresh temp file seeded with CONTENT and return its namestring."
  (let ((path (namestring
               (uiop:tmpize-pathname
                (merge-pathnames "lem-ds8" (uiop:temporary-directory))))))
    (write-file-string path content)
    path))

;;; Acceptance: the handler entry point checkpoints every modified buffer, leaves
;;; the real files untouched, and keeps the buffers modified.

(deftest emergency-checkpoint-writes-checkpoints-for-modified-buffers
  (with-fake-interface ()
    (let* ((dir (fresh-checkpoint-dir))
           (lem/checkpoint:*checkpoint-directory* dir)
           (path-a (fresh-temp-file "AAA"))
           (path-b (fresh-temp-file "BBB"))
           (buffer-a (lem:find-file-buffer path-a))
           (buffer-b (lem:find-file-buffer path-b)))
      (unwind-protect
           (progn
             ;; Modify only buffer-a; buffer-b stays clean.
             (lem:insert-string (lem:buffer-end-point buffer-a) "-EDIT")
             (lem/emergency-save:emergency-checkpoint)
             (let ((checkpoint-a (lem/checkpoint:checkpoint-filename path-a))
                   (checkpoint-b (lem/checkpoint:checkpoint-filename path-b)))
               (ok (probe-file checkpoint-a)
                   "the modified buffer is checkpointed")
               (ok (equal "AAA-EDIT" (read-file-utf-8 checkpoint-a))
                   "the checkpoint holds the modified buffer's content")
               (ok (equal "AAA" (read-file-utf-8 path-a))
                   "the real file of the modified buffer is untouched")
               (ok (lem:buffer-modified-p buffer-a)
                   "the buffer stays modified after the emergency checkpoint")
               (ok (not (probe-file checkpoint-b))
                   "an unmodified buffer is not checkpointed")))
        (lem:delete-buffer buffer-a)
        (lem:delete-buffer buffer-b)
        (uiop:delete-file-if-exists path-a)
        (uiop:delete-file-if-exists path-b)
        (ignore-errors
         (uiop:delete-directory-tree dir :validate (constantly t)))))))

;;; The entry point is signal-safe: it must never signal, even with no buffers to
;;; checkpoint, so a dying process can always run it and go on to exit.

(deftest emergency-checkpoint-never-signals
  (with-fake-interface ()
    (let* ((dir (fresh-checkpoint-dir))
           (lem/checkpoint:*checkpoint-directory* dir))
      (unwind-protect
           (ok (null (lem/emergency-save:emergency-checkpoint))
               "emergency-checkpoint returns nil without error")
        (ignore-errors
         (uiop:delete-directory-tree dir :validate (constantly t)))))))
