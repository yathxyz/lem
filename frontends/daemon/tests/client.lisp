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

(defun call-with-shutdown-messages (messages function)
  (let ((path (merge-pathnames (format nil "lem-shutdown-wire-~d.bin" (random 1000000000))
                              (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :error
                                    :element-type '(unsigned-byte 8))
             (dolist (message messages) (protocol:write-message message out)))
           (with-open-file (in path :element-type '(unsigned-byte 8))
             (funcall function (make-instance 'client::client-connection :stream in :transport nil))))
      (when (probe-file path) (delete-file path)))))

(deftest shutdown-needs-terminal-receipt-before-eof
  (flet ((response (id status value)
           (protocol:make-object "type" "response" "id" id "status" status "value" value))
         (read-result (messages)
           (call-with-shutdown-messages messages
             (lambda (connection) (client::wait-for-shutdown connection "stop")))))
    (ok (= 0 (read-result (list (response "stop" "pending" "stopping")
                               (response "stop" "ok" "stopped")))))
    (dolist (messages (list nil
                           (list (response "stop" "pending" "stopping"))
                           (list (response "stop" "ok" "stopping"))
                           (list (response "other" "ok" "stopped"))))
      (ok (signals (read-result messages) 'error)
          "EOF or an early/unrelated receipt cannot confirm completed shutdown"))
    (ok (signals
         (read-result (list (protocol:make-object
                             "type" "response" "id" "stop" "status" "error"
                             "error" (protocol:make-object "code" "shutdown-failed"
                                                          "message" "Checkpoint failed"))))
         'error))))

#+(and sbcl linux)
(deftest shutdown-client-has-a-bounded-wait
  (let* ((old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (root (merge-pathnames (format nil "lem-shutdown-timeout-~d-~d/"
                                       (sb-posix:getpid) (random 1000000000))
                               (uiop:temporary-directory)))
         (backend (lem-daemon/transport:require-local-backend))
         (listener nil) (local nil) (peer nil))
    (unwind-protect
         (progn
           (setf (uiop:getenv "XDG_RUNTIME_DIR") (namestring root)
                 listener (lem-daemon/transport:open-local-listener backend "timeout" 1)
                 local (lem-daemon/transport:connect-local backend "timeout")
                 peer (lem-daemon/transport:accept-local-connection listener))
           (let ((connection (make-instance 'client::client-connection
                                            :transport local
                                            :stream (lem-daemon/transport:local-connection-stream local)))
                 (start (get-internal-real-time)))
             (ok (handler-case
                     (progn (client::run-shutdown connection t :timeout 0.1) nil)
                   (error (condition) (search "did not complete shutdown" (princ-to-string condition)))))
             (ok (< (- (get-internal-real-time) start) (* 2 internal-time-units-per-second)))
             (ok (open-stream-p (lem-daemon/transport:local-connection-stream peer))
                 "timeout does not depend on the peer disconnecting")))
      (when local (lem-daemon/transport:close-local-connection local))
      (when peer (lem-daemon/transport:close-local-connection peer))
      (when listener (lem-daemon/transport:close-local-listener listener))
      (setf (uiop:getenv "XDG_RUNTIME_DIR") old-runtime)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))
