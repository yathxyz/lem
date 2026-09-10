;;;; Load this checkout's recovery systems with installed dependencies, without user init.
(require :asdf)
(defparameter *recovery-source-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))
(load (or (uiop:getenv "LEM_QUICKLISP_SETUP")
          (merge-pathnames ".qlot/setup.lisp" *recovery-source-root*)))
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*recovery-source-root*) :ignore-inherited-configuration))
(setf asdf:*system-definition-search-functions*
      (cons 'asdf/system-registry:sysdef-source-registry-search
            (remove 'asdf/system-registry:sysdef-source-registry-search
                    asdf:*system-definition-search-functions*)))
(defun load-recovery-system (system)
  (flet ((check ()
           (unless (uiop:subpathp (truename (asdf:system-source-directory system))
                                 (truename *recovery-source-root*))
             (error "Recovery system ~a resolved outside this checkout" system))))
    (check)
    (ql:quickload system :silent t)
    (check))
  (format *error-output* "~&Recovery source ~a: ~a~%" system
          (asdf:system-source-directory system)))
