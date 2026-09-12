(require :asdf)

(defparameter *notes-test-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname *load-truename*)))

(defparameter *notes-repository-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-parent-directory-pathname *notes-test-root*)))

(load (or (uiop:getenv "LEM_QUICKLISP_SETUP")
          (merge-pathnames ".qlot/setup.lisp" *notes-repository-root*)))

;; Dependencies must already be installed. A missing dependency must not turn
;; this local fixture gate into a Quicklisp download.
(let ((fetch (find-symbol "FETCH" "QL-HTTP")))
  (unless (and fetch (fboundp fetch))
    (error "The installed Quicklisp HTTP boundary was not found"))
  (setf (symbol-function fetch)
        (lambda (&rest arguments)
          (declare (ignore arguments))
          (error "Network access is forbidden in the structured-notes gate"))))

(asdf:initialize-source-registry
 `(:source-registry (:tree ,*notes-repository-root*) :ignore-inherited-configuration))

;; A borrowed Qlot installation can prefer its original checkout. This gate
;; must exercise the ASD and every component beside this script.
(setf asdf:*system-definition-search-functions*
      (cons 'asdf/system-registry:sysdef-source-registry-search
            (remove 'asdf/system-registry:sysdef-source-registry-search
                    asdf:*system-definition-search-functions*)))

(asdf:initialize-output-translations
 `(:output-translations
   (t ,(merge-pathnames "asdf/" (uiop:temporary-directory)))
   :ignore-inherited-configuration))

(defun assert-notes-source (system-name)
  (let* ((system (asdf:find-system system-name))
         (expected (truename (merge-pathnames "lem-structured-notes.asd"
                                             *notes-test-root*))))
    (unless (equal expected (truename (asdf:system-source-file system)))
      (error "~a resolved to a different checkout" system-name))
    (labels ((check-component (component)
               (when (typep component 'asdf:source-file)
                 (unless (uiop:subpathp (truename (asdf:component-pathname component))
                                       (truename *notes-test-root*))
                   (error "Component ~a resolved outside this extension"
                          (asdf:component-name component))))
               (when (typep component 'asdf:parent-component)
                 (mapc #'check-component (asdf:component-children component)))))
      (check-component system))
    (format t "~&Test source ~a: ~a~%" system-name expected)))

(defun assert-notes-dependencies ()
  (unless (and (equal '("alexandria")
                      (asdf:system-depends-on (asdf:find-system "lem-structured-notes")))
               (equal '("lem-structured-notes")
                      (asdf:system-depends-on (asdf:find-system "lem-structured-notes/tests"))))
    (error "The focused semantic dependency boundary changed"))
  (let* ((allowed '("lem-structured-notes" "lem-structured-notes/tests"))
         (forbidden '("cxml" "cxml-dom" "cxml-stp" "closure-common" "dexador"
                      "drakma" "cl+ssl" "usocket" "plump" "lem/core"))
         (loaded (asdf:already-loaded-systems)))
    (dolist (name loaded)
      (when (or (and (uiop:string-prefix-p "lem-structured-notes" name)
                     (not (member name allowed :test #'string=)))
                (some (lambda (prefix)
                        (or (string= prefix name)
                            (uiop:string-prefix-p (concatenate 'string prefix "/")
                                                  name)))
                      forbidden))
        (error "Forbidden dependency loaded: ~a" name)))
    (dolist (package '("CXML" "DEXADOR" "DRAKMA" "CL+SSL" "USOCKET" "LEM"))
      (when (find-package package)
        (error "Forbidden runtime package present: ~a" package)))
    (format t "~&Dependency isolation passed: ~{~a~^, ~}~%"
            (sort (copy-list loaded) #'string<))))

(handler-case
    (let ((*compile-verbose* nil)
          (*load-verbose* nil))
      (assert-notes-source "lem-structured-notes")
      (assert-notes-source "lem-structured-notes/tests")
      (assert-notes-dependencies)
      (asdf:load-system "lem-structured-notes/tests")
      (assert-notes-source "lem-structured-notes")
      (assert-notes-source "lem-structured-notes/tests")
      (assert-notes-dependencies)
      (let ((count (length (symbol-value
                           (find-symbol "*TESTS*" "LEM-STRUCTURED-NOTES/TESTS")))))
        (unless (= count 393)
          (error "Expected 390 semantic and 3 URI cases, found ~d" count)))
      (asdf:test-system "lem-structured-notes")
      (assert-notes-dependencies)
      (uiop:quit 0))
  (error (condition)
    (format *error-output* "~&Structured-notes gate failed: ~a~%" condition)
    (uiop:quit 1)))
