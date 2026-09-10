;;;; sbcl --script scripts/lem-recovery.lisp DIRECTORY [RECORD-ID]
;;;; Lists record metadata as JSON, or exports one record's text to stdout.
;;;; Runs independently of a daemon, frontend, editor loop, and Lem user init.
(load (merge-pathnames "recovery-source.lisp" *load-truename*))
(load-recovery-system "lem-daemon/recovery-store")
(let* ((arguments (uiop:command-line-arguments))
       (directory (first arguments))
       (id (second arguments)))
  (unless (and directory (<= (length arguments) 2))
    (error "Usage: sbcl --script scripts/lem-recovery.lisp DIRECTORY [RECORD-ID]"))
  (when (find-package :lem-core) (error "Recovery inspector unexpectedly loaded the editor"))
  (if id
      (write-string (lem-daemon/recovery-store:field
                     (lem-daemon/recovery-store:read-record directory id) "text"))
      (multiple-value-bind (records failures) (lem-daemon/recovery-store:list-records directory)
        (dolist (record records) (remhash "text" record))
        (yason:encode
         (lem-daemon/recovery-store:object
          "records" (coerce records 'vector)
          "errors" (coerce (mapcar (lambda (failure)
                                    (lem-daemon/recovery-store:object
                                     "path" (namestring (car failure)) "error" (cdr failure))) failures)
                           'vector)) *standard-output*))))
