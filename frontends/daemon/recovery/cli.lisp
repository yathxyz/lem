(defpackage :lem-daemon/recovery-cli
  (:use :cl)
  (:local-nicknames (:store :lem-daemon/recovery-store))
  (:export :main))
(in-package :lem-daemon/recovery-cli)

(defun inspect-jobs (directory)
  (when (find-package :lem-core)
    (error "Recovery inspector unexpectedly loaded the editor"))
  (multiple-value-bind (records failures)
      (lem-toolkit/jobs:inspect-job-journal :directory directory)
    (yason:encode
     (store:object
      "records" (coerce records 'vector)
      "errors" (map 'vector (lambda (failure)
                             (store:object "path" (namestring (car failure))
                                           "error" (cdr failure))) failures))
     *standard-output*)
    (terpri)
    (if failures 1 0)))

(defun inspect-records (directory id)
  (when (find-package :lem-core)
    (error "Recovery inspector unexpectedly loaded the editor"))
  (if id
      (write-string (store:field (store:read-record directory id) "text"))
      (multiple-value-bind (records failures) (store:list-records directory)
        (dolist (record records) (remhash "text" record))
        (yason:encode
         (store:object
          "records" (coerce records 'vector)
          "errors" (map 'vector
                        (lambda (failure)
                          (store:object "path" (namestring (car failure))
                                        "error" (cdr failure)))
                        failures))
         *standard-output*)
        (terpri)
        (when failures (return-from inspect-records 1))))
  0)

(defun main ()
  (uiop:quit
   (handler-case
       (let ((arguments (uiop:command-line-arguments)))
         (cond ((equal arguments '("--help"))
                (format t "Usage: lem-recover DIRECTORY [RECORD-ID]~%       lem-recover --jobs DIRECTORY~%List private checkpoint metadata as JSON, export one record's text, or inspect job journals without changing them.~%")
                0)
               ((and (= (length arguments) 2) (equal (first arguments) "--jobs"))
                (inspect-jobs (second arguments)))
               ((and arguments (uiop:string-prefix-p "--" (first arguments)))
                (error "Usage: lem-recover DIRECTORY [RECORD-ID] or --jobs DIRECTORY"))
               ((<= 1 (length arguments) 2)
                (inspect-records (first arguments) (second arguments)))
               (t (error "Usage: lem-recover DIRECTORY [RECORD-ID]"))))
     (error (condition)
       (format *error-output* "lem-recover: ~a~%" condition)
       2))))
