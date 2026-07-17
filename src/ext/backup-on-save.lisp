(defpackage :lem/backup-on-save
  (:use :cl :lem)
  (:documentation
   "DS-4 mechanism: back up the pre-save content of a file to <file>~ on the
first save of a session, independent of auto-save-mode. The mechanism is off by
default; the fork's daily-driver-defaults layer enables it. See SPEC.md, DS-4.")
  (:export :*backup-on-save*
           :backup-on-save)
  #+sbcl
  (:lock t))
(in-package :lem/backup-on-save)

(defvar *backup-on-save* nil
  "When non-nil, the first save of a session for each file copies the file's
pre-save on-disk content to <file>~ before the save overwrites it. Subsequent
saves in the same session leave that backup untouched, so it always holds the
content the file had when it was first opened this session.")

(defvar *backed-up-files* (make-hash-table :test 'equal)
  "Set of file truenames (namestrings) already backed up this session.")

(defun backup-filename (filename)
  "Return the ~-suffixed backup name for FILENAME, in the same directory."
  (format nil "~A~~" filename))

(defun backup-on-save (buffer)
  "BEFORE-SAVE-HOOK function. On the first save of BUFFER's file this session,
copy the current on-disk content to <file>~ before the save overwrites it. Does
nothing when *BACKUP-ON-SAVE* is nil, the buffer has no filename, or the file
does not yet exist on disk."
  (when *backup-on-save*
    (let ((filename (buffer-filename buffer)))
      (when filename
        (let ((truename (probe-file filename)))
          (when truename
            (let ((key (namestring truename)))
              (unless (gethash key *backed-up-files*)
                (uiop:copy-file truename (backup-filename key))
                (setf (gethash key *backed-up-files*) t)))))))))
