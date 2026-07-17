(defpackage :lem-tests/checkpoint
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/checkpoint)

;;; DS-3: crash-recovery checkpoints.
;;;
;;; A checkpoint captures a modified buffer's content in a private file under the
;;; checkpoint directory, without touching the real file and without clearing the
;;; buffer's modified flag. A successful manual save deletes the checkpoint; a
;;; crash leaves it behind. On find-file, a checkpoint newer than the on-disk file
;;; is offered for recovery. These tests bind *CHECKPOINT-DIRECTORY* to a throwaway
;;; directory so they never touch the real $XDG_DATA_HOME/lem/autosave/.

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
  (merge-pathnames (format nil "lem-ds3-~36R/" (random (expt 36 12)))
                   (uiop:temporary-directory)))

(defmacro with-checkpoint-env ((path content) &body body)
  "Bind PATH to a fresh temp file seeded with CONTENT, route checkpoints to a
private throwaway directory, and clean both up afterwards."
  (let ((dir (gensym "DIR")))
    `(let* ((,dir (fresh-checkpoint-dir))
            (lem/checkpoint:*checkpoint-directory* ,dir)
            (,path (namestring
                    (uiop:tmpize-pathname
                     (merge-pathnames "lem-ds3" (uiop:temporary-directory))))))
       (write-file-string ,path ,content)
       (unwind-protect (progn ,@body)
         (uiop:delete-file-if-exists ,path)
         (ignore-errors (uiop:delete-directory-tree
                         ,dir :validate (constantly t)))))))

(defun buffer-string (buffer)
  (lem:points-to-string (lem:buffer-start-point buffer)
                        (lem:buffer-end-point buffer)))

(defun unix-now ()
  (values (sb-ext:get-time-of-day)))

(defun set-mtime (path unix-time)
  (sb-posix:utime (namestring path) unix-time unix-time))

;;; Acceptance 1: checkpoint writes without touching the real file, and leaves the
;;; buffer modified.

(deftest checkpoint-does-not-touch-real-file
  (with-fake-interface ()
    (with-checkpoint-env (path "ORIGINAL")
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (lem:insert-string (lem:buffer-end-point buffer) "-EDIT")
               (lem/checkpoint:checkpoint-buffer buffer)
               (let ((checkpoint (lem/checkpoint:checkpoint-filename path)))
                 (ok (equal "ORIGINAL" (read-file-utf-8 path))
                     "the real file is untouched by the checkpoint")
                 (ok (probe-file checkpoint)
                     "a checkpoint file is written")
                 (ok (equal "ORIGINAL-EDIT" (read-file-utf-8 checkpoint))
                     "the checkpoint holds the buffer's current content")
                 (ok (lem:buffer-modified-p buffer)
                     "the buffer stays modified after checkpointing")))
          (lem:delete-buffer buffer))))))

(deftest unmodified-buffer-is-not-checkpointed
  (with-fake-interface ()
    (with-checkpoint-env (path "ORIGINAL")
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (lem/checkpoint:checkpoint-buffer buffer)
               (ok (not (probe-file (lem/checkpoint:checkpoint-filename path)))
                   "an unmodified buffer produces no checkpoint"))
          (lem:delete-buffer buffer))))))

;;; Acceptance 2: a successful manual save removes the checkpoint (via the
;;; after-save hook installed while checkpoint-mode is enabled).

(deftest manual-save-removes-checkpoint
  (with-fake-interface ()
    (with-checkpoint-env (path "ORIGINAL")
      (lem/checkpoint:checkpoint-mode t)
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (lem:insert-string (lem:buffer-end-point buffer) "-EDIT")
               (lem/checkpoint:checkpoint-buffer buffer)
               (ok (probe-file (lem/checkpoint:checkpoint-filename path))
                   "the checkpoint exists before saving")
               (lem:write-to-file buffer path)
               (ok (not (probe-file (lem/checkpoint:checkpoint-filename path)))
                   "a successful save deletes the checkpoint"))
          (lem:delete-buffer buffer)
          (lem/checkpoint:checkpoint-mode nil))))))

;;; Acceptance 3: on find-file, a newer checkpoint is offered and recovery
;;; restores the edits, leaving the buffer modified and the real file untouched.

(defun seed-checkpoint (path content &key newer)
  "Write CONTENT to PATH's checkpoint file. When NEWER, make the checkpoint newer
than the file; otherwise make it older. Times are set explicitly to avoid
same-second ambiguity."
  (let ((checkpoint (lem/checkpoint:checkpoint-filename path))
        (now (unix-now)))
    (ensure-directories-exist checkpoint)
    (write-file-string checkpoint content)
    (cond (newer
           (set-mtime path (- now 100))
           (set-mtime checkpoint now))
          (t
           (set-mtime path now)
           (set-mtime checkpoint (- now 100))))))

(deftest recover-restores-edits-and-leaves-file-untouched
  (with-fake-interface ()
    (with-checkpoint-env (path "hello")
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (seed-checkpoint path "hello EDITED" :newer t)
               (lem:unread-key (lem:make-key :sym "r"))
               (lem/checkpoint:maybe-offer-recovery buffer)
               (ok (equal "hello EDITED" (buffer-string buffer))
                   "recover replaces the buffer content with the checkpoint")
               (ok (lem:buffer-modified-p buffer)
                   "the recovered buffer is modified")
               (ok (equal "hello" (read-file-utf-8 path))
                   "the real file is untouched until the user saves"))
          (lem:delete-buffer buffer))))))

(deftest ignore-keeps-buffer-and-checkpoint
  (with-fake-interface ()
    (with-checkpoint-env (path "hello")
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (seed-checkpoint path "hello EDITED" :newer t)
               (lem:unread-key (lem:make-key :sym "i"))
               (lem/checkpoint:maybe-offer-recovery buffer)
               (ok (equal "hello" (buffer-string buffer))
                   "ignore leaves the buffer's on-disk content in place")
               (ok (probe-file (lem/checkpoint:checkpoint-filename path))
                   "ignore leaves the checkpoint on disk"))
          (lem:delete-buffer buffer))))))

(deftest delete-choice-removes-checkpoint
  (with-fake-interface ()
    (with-checkpoint-env (path "hello")
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (seed-checkpoint path "hello EDITED" :newer t)
               (lem:unread-key (lem:make-key :sym "d"))
               (lem/checkpoint:maybe-offer-recovery buffer)
               (ok (equal "hello" (buffer-string buffer))
                   "delete leaves the buffer unchanged")
               (ok (not (probe-file (lem/checkpoint:checkpoint-filename path)))
                   "delete removes the checkpoint file"))
          (lem:delete-buffer buffer))))))

(deftest older-checkpoint-is-not-offered
  (with-fake-interface ()
    (with-checkpoint-env (path "hello")
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (seed-checkpoint path "hello STALE" :newer nil)
               ;; No key is queued: an older checkpoint must not prompt. If
               ;; MAYBE-OFFER-RECOVERY prompted, it would block on read-key.
               (lem/checkpoint:maybe-offer-recovery buffer)
               (ok (equal "hello" (buffer-string buffer))
                   "a checkpoint older than the file is left alone"))
          (lem:delete-buffer buffer))))))

;;; The explicit recover-this-file command recovers regardless of timestamps.

(deftest recover-this-file-command-restores-checkpoint
  (with-fake-interface ()
    (with-checkpoint-env (path "hello")
      (let ((buffer (lem:find-file-buffer path))
            (previous (lem:current-buffer)))
        (unwind-protect
             (progn
               (setf (lem:current-buffer) buffer)
               (seed-checkpoint path "hello EDITED" :newer nil)
               (lem/checkpoint:recover-this-file)
               (ok (equal "hello EDITED" (buffer-string buffer))
                   "recover-this-file restores even a same-age checkpoint")
               (ok (lem:buffer-modified-p buffer)
                   "the buffer is modified after recover-this-file"))
          ;; Restore the prior current buffer before deleting ours, so the
          ;; global current buffer never dangles at a deleted buffer.
          (setf (lem:current-buffer) previous)
          (lem:delete-buffer buffer))))))
