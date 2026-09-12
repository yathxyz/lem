;;; Local fixtures extracted without loading the umbrella test suites.
(in-package #:lem-structured-notes/tests)

(defun signaled-model-code (thunk)
  (semantic-model-error-code
   (assert-signals 'semantic-model-error thunk)))

(defun specification-path (name)
  (merge-pathnames (format nil "spec/~a" name)
                   (asdf:system-source-directory "lem-structured-notes")))

(defun split-tab-fields (line)
  (loop :with start := 0
        :for end := (position #\Tab line :start start)
        :collect (subseq line start end)
        :while end
        :do (setf start (1+ end))))

(defun read-tabular-file (pathname display-name)
  (with-open-file (stream pathname
                          :direction :input
                          :external-format :utf-8)
    (let ((header (split-tab-fields (read-line stream nil "")))
          (rows nil))
      (loop :for line := (read-line stream nil nil)
            :while line
            :unless (zerop (length line))
              :do (let ((fields (split-tab-fields line)))
                    (unless (= (length header) (length fields))
                      (fail-test "~a row has ~d fields; expected ~d: ~s"
                                 display-name (length fields) (length header)
                                 line))
                    (push (pairlis header fields) rows)))
      (values header (nreverse rows)))))

(defun read-tabular-specification (name)
  (read-tabular-file (specification-path name) name))

(defun row-value (column row)
  (cdr (assoc column row :test #'string=)))

(defun test-sync-store-directory ()
  (loop :for pathname :=
          (merge-pathnames
           (format nil "lem-caldav-sync-test-~36r/"
                   (random (expt 36 12)))
           (uiop:temporary-directory))
        :unless (probe-file pathname)
          :do (return pathname)))

(defmacro with-test-sync-store ((directory) &body body)
  `(let ((,directory (test-sync-store-directory)))
     (unwind-protect
          (progn ,@body)
       (when (probe-file ,directory)
         (uiop:delete-directory-tree
         ,directory :validate t :if-does-not-exist :ignore)))))
