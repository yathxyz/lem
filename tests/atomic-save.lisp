(defpackage :lem-tests/atomic-save
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface)
  (:import-from :lem-tests/eol-roundtrip
                :string->octets
                :read-octets
                :write-octets))
(in-package :lem-tests/atomic-save)

;;; DS-2: saves must be atomic -- write a temp file in the target's directory,
;;; fsync, then rename(2) over the target. Content round-trips byte-for-byte,
;;; permission bits survive, and a symlinked target keeps the symlink while the
;;; real file is updated.

(defmacro with-temp-path ((path &optional (prefix "lem-ds2-atomic")) &body body)
  "Bind PATH to a fresh temp-file namestring and remove it (and any sibling temp
files) afterwards."
  `(let ((,path (namestring
                 (uiop:tmpize-pathname
                  (merge-pathnames ,prefix (uiop:temporary-directory))))))
     (unwind-protect (progn ,@body)
       (uiop:delete-file-if-exists ,path))))

(defun save-through (path)
  "Open PATH, save it unchanged, and return nothing. Runs inside a fake
interface so the save hooks have an editor context."
  (with-fake-interface ()
    (let ((buffer (lem:find-file-buffer path)))
      (unwind-protect (lem:write-to-file buffer path)
        (lem:delete-buffer buffer)))))

(deftest content-round-trips-byte-for-byte
  ;; Reuse the DS-6 corpus byte-comparison helpers.
  (let ((in (string->octets (format nil "alpha~Cbeta~Cgamma~C" #\Lf #\Lf #\Lf))))
    (with-temp-path (path)
      (write-octets path in)
      (save-through path)
      (ok (equalp in (read-octets path))
          "an atomic open->save preserves the bytes exactly"))))

(deftest edited-content-is-written
  (with-temp-path (path)
    (write-octets path (string->octets (format nil "one~C" #\Lf)))
    (with-fake-interface ()
      (let ((buffer (lem:find-file-buffer path)))
        (unwind-protect
             (progn
               (lem:insert-string (lem:buffer-end-point buffer)
                                  (format nil "two~C" #\Lf))
               (lem:write-to-file buffer path)
               (ok (equalp (string->octets (format nil "one~Ctwo~C" #\Lf #\Lf))
                           (read-octets path))
                   "edits reach disk atomically"))
          (lem:delete-buffer buffer))))))

(defun file-mode (path)
  (logand (sb-posix:stat-mode (sb-posix:stat path)) #o777))

(deftest permission-bits-survive-save
  (dolist (mode (list #o644 #o755 #o600))
    (with-temp-path (path)
      (write-octets path (string->octets (format nil "keep me~C" #\Lf)))
      (sb-posix:chmod path mode)
      (save-through path)
      (ok (= mode (file-mode path))
          (format nil "mode ~O is preserved across an atomic save" mode)))))

(defun symlink-p (path)
  (sb-posix:s-islnk (sb-posix:stat-mode (sb-posix:lstat path))))

(deftest save-through-symlink-keeps-the-link
  (with-temp-path (real)
    (let ((link (namestring
                 (uiop:tmpize-pathname
                  (merge-pathnames "lem-ds2-link" (uiop:temporary-directory))))))
      ;; tmpize-pathname created LINK as a regular file; replace it with a
      ;; symlink pointing at REAL.
      (uiop:delete-file-if-exists link)
      (unwind-protect
           (progn
             (write-octets real (string->octets (format nil "before~C" #\Lf)))
             (sb-posix:symlink real link)
             (with-fake-interface ()
               (let ((buffer (lem:find-file-buffer link)))
                 (unwind-protect
                      (progn
                        (lem:insert-string (lem:buffer-end-point buffer)
                                           (format nil "after~C" #\Lf))
                        (lem:write-to-file buffer link))
                   (lem:delete-buffer buffer))))
             (ok (symlink-p link)
                 "the symlink is still a symlink after saving through it")
             (ok (equal real (sb-posix:readlink link))
                 "the symlink still points at the same target")
             (ok (search (string->octets "after") (read-octets real))
                 "the real target received the edit"))
        (uiop:delete-file-if-exists link)
        (uiop:delete-file-if-exists real)))))
