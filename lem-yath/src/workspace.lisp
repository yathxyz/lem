;;;; Machine-contingent workspace roots.  Keep host/environment resolution
;;;; separate from the generic helpers in base.lisp.

(in-package :lem-yath)

(defun resolve-workdir (configured &optional (directory (uiop:getcwd)))
  "Resolve CONFIGURED like Emacs `expand-file-name', defaulting to ~/work."
  (uiop:ensure-directory-pathname
   (expand-file-name
    (if (and configured (plusp (length configured)))
        configured
        "~/work")
    directory)))

(defun configured-workdir ()
  (let ((configured (uiop:getenv "WORKDIR")))
    (if (and configured (plusp (length configured)))
        configured
        (progn
          ;; The live Emacs configuration exports the fallback for later
          ;; packages and subprocesses as well as returning it.
          (setf (uiop:getenv "WORKDIR") "~/work")
          "~/work"))))

(defparameter *workdir*
  (resolve-workdir (configured-workdir))
  "Absolute notes root fixed at startup so later `:cd' cannot retarget writes.")

(defun workdir ()
  "The absolute notes root initialized from $WORKDIR."
  *workdir*)
