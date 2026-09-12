(defpackage :lem-daemon/recovery-cli
  (:use :cl)
  (:local-nicknames (:store :lem-daemon/recovery-store))
  (:export :main))
(in-package :lem-daemon/recovery-cli)

(defun inspect-jobs (directory &key after (limit 64))
  (when (find-package :lem-core)
    (error "Recovery inspector unexpectedly loaded the editor"))
  (multiple-value-bind (records failures page)
      (lem-toolkit/jobs:inspect-job-journal :directory directory :after after :limit limit)
    (yason:encode
     (store:object
      "records" (coerce records 'vector) "page" page
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

(defun inspect-jobs-arguments (arguments)
  (unless arguments
    (error "Usage: lem-recover --jobs DIRECTORY [--after ID] [--limit 1..64] (missing directory)"))
  (let ((directory (first arguments)) (after nil) (limit 64) (seen nil))
    (loop for (key value) on (rest arguments) by #'cddr
          do (unless (and value (member key '("--after" "--limit") :test #'equal)
                          (not (member key seen :test #'equal)))
               (error "Expected unique --after ID or --limit 1..64 options"))
             (push key seen)
             (cond ((equal key "--after") (setf after value))
                   (t (unless (and (<= 1 (length value) 2) (every #'digit-char-p value))
                        (error "Invalid job page limit"))
                      (setf limit (parse-integer value)))))
    (inspect-jobs directory :after after :limit limit)))

(defun main ()
  (uiop:quit
   (handler-case
       (let ((arguments (uiop:command-line-arguments)))
         (cond ((equal arguments '("--help"))
                (format t "Usage: lem-recover DIRECTORY [RECORD-ID]~%       lem-recover --jobs DIRECTORY [--after ID] [--limit 1..64]~%List private checkpoint metadata as JSON, export one record's text, or inspect job journals without changing them.~%")
                0)
               ((equal (first arguments) "--jobs")
                (inspect-jobs-arguments (rest arguments)))
               ((and arguments (uiop:string-prefix-p "--" (first arguments)))
                (error "Usage: lem-recover DIRECTORY [RECORD-ID] or --jobs DIRECTORY"))
               ((<= 1 (length arguments) 2)
                (inspect-records (first arguments) (second arguments)))
               (t (error "Usage: lem-recover DIRECTORY [RECORD-ID]"))))
     (error (condition)
       (format *error-output* "lem-recover: ~a~%" condition)
       2))))
