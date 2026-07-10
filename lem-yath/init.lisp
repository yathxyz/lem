;;;; Entry point, loaded from ~/.config/lem/init.lisp.
;;;; Loads the lem-yath system and records boot status so the TUI test harness
;;;; can assert on it from `lem --eval`.

(in-package :lem-user)

(defvar *lem-yath-root*
  (uiop:pathname-directory-pathname *load-truename*))

(defvar *lem-yath-boot-error* nil
  "NIL on a clean boot, otherwise the load-time error message.")

(handler-case
    (progn
      (asdf:load-asd (merge-pathnames "lem-yath.asd" *lem-yath-root*))
      (asdf:load-system "lem-yath"))
  (error (e)
    (setf *lem-yath-boot-error* (princ-to-string e))
    (ignore-errors (message "lem-yath failed to load: ~a" e))))
