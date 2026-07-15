;;;; Entry point, loaded from ~/.config/lem/init.lisp.
;;;; Loads the lem-yath system and records boot status so the TUI test harness
;;;; can assert on it from `lem --eval`.

(in-package :lem-user)

(defvar *lem-yath-root*
  (uiop:pathname-directory-pathname *load-truename*))

(defvar *lem-yath-boot-error* nil
  "NIL on a clean boot, otherwise the load-time error message.")

(defun lem-yath-configure-asdf-output ()
  "Keep direct development-load FASLs out of the configuration source tree."
  (unless (uiop:getenv "ASDF_OUTPUT_TRANSLATIONS")
    (let* ((cache-root
             (uiop:ensure-directory-pathname
              (or (uiop:getenv "XDG_CACHE_HOME")
                  (merge-pathnames #P".cache/" (user-homedir-pathname)))))
           (source-name (uiop:native-namestring *lem-yath-root*))
           (source-relative (string-left-trim '(#\/) source-name))
           (output
             (merge-pathnames
              (format nil "lem-yath/asdf/direct/~A" source-relative)
              cache-root)))
      (ensure-directories-exist (merge-pathnames #P".keep" output))
      (setf (uiop:getenv "ASDF_OUTPUT_TRANSLATIONS")
            (format nil "~A:~A:/nix/store:/nix/store"
                    source-name (uiop:native-namestring output)))
      (asdf:initialize-output-translations))))

(handler-case
    (progn
      (lem-yath-configure-asdf-output)
      (asdf:load-asd (merge-pathnames "lem-yath.asd" *lem-yath-root*))
      (asdf:load-system "lem-yath"))
  (error (e)
    (setf *lem-yath-boot-error* (princ-to-string e))
    (ignore-errors (message "lem-yath failed to load: ~a" e))))
