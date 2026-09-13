(defpackage :lem-daemon/tests/client
  (:use :cl :rove)
  (:local-nicknames (:client :lem-daemon/client)
                    (:protocol :lem-daemon/protocol)))
(in-package :lem-daemon/tests/client)

(deftest attached-edit-requires-exact-completed-request
  (flet ((response (id status &optional code)
           (protocol:make-object
            "type" "response" "id" id "status" status
            "error" (protocol:make-object "code" code "message" "Test failure"))))
    (dolist (status '("pending" "ok"))
      (ok (null (client::frame-message-exit-status (response "input" status) "edit")))
      (ok (null (client::frame-message-exit-status (response "edit" status) nil)))
      (ok (null (client::frame-message-exit-status (response "edit" "pending") "edit"))))
    (ok (eql 0 (client::frame-message-exit-status (response "edit" "ok") "edit")))
    (ok (eql 1 (client::frame-message-exit-status (response "edit" "error" "aborted") "edit")))
    (ok (signals (client::frame-message-exit-status (response "other" "error" "aborted") "edit")
                 'error)
        "an unrelated error is never mistaken for the waiting edit's result")
    (ok (signals (client::frame-message-exit-status (response "edit" "error" "visit-failed") "edit")
                 'error))))

(deftest attached-edit-close-is-not-completion
  (let ((close (protocol:make-object "type" "close" "reason" "client-request")))
    (ok (= 1 (client::frame-message-exit-status close "edit")))
    (ok (= 0 (client::frame-message-exit-status close nil)))
    (ok (= 1 (client::frame-close-status "edit")))
    (ok (= 0 (client::frame-close-status nil)))))

(deftest visible-edit-command-line-contract
  (dolist (flag '("-t" "-c"))
    (multiple-value-bind (mode files wait) (client::parse-client-arguments (list flag "file"))
      (ok (member mode '(:tty :gui))) (ok (equal files '("file"))) (ok wait))
    (multiple-value-bind (mode files wait) (client::parse-client-arguments (list flag "-n" "file"))
      (declare (ignore mode))
      (ok (equal files '("file"))) (ok (null wait)))
    (multiple-value-bind (mode files) (client::parse-client-arguments (list flag))
      (declare (ignore mode)) (ok (null files)))))
