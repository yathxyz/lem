(require :asdf)

(defparameter *test-source-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(load (or (uiop:getenv "LEM_QUICKLISP_SETUP")
          (merge-pathnames ".qlot/setup.lisp" *test-source-root*)))

(asdf:initialize-source-registry
 `(:source-registry (:tree ,*test-source-root*) :ignore-inherited-configuration))

;; Qlot prepends a searcher bound to its original checkout. Prefer this
;; checkout when borrowing its installed dependencies from another worktree.
(setf asdf:*system-definition-search-functions*
      (cons 'asdf/system-registry:sysdef-source-registry-search
            (remove 'asdf/system-registry:sysdef-source-registry-search
                    asdf:*system-definition-search-functions*)))

(defun assert-test-source (system)
  (let ((source (asdf:system-source-directory system)))
    (unless (uiop:subpathp (truename source) (truename *test-source-root*))
      (error "Test system ~a resolved outside this checkout: ~a" system source))
    (format t "~&Test source ~a: ~a~%" system source)))

(let ((system (or (first (uiop:command-line-arguments)) "lem-tests")))
  (assert-test-source "lem")
  (assert-test-source system)
  (ql:quickload system :silent t)
  (assert-test-source "lem")
  (assert-test-source system)
  (uiop:quit (if (uiop:symbol-call :rove :run (asdf:find-system system)) 0 1)))
