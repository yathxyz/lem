(defpackage :lem-daemon/tests/integration
  (:use :cl :rove)
  (:local-nicknames (:client :lem-daemon/client)
                    (:protocol :lem-daemon/protocol)))
(in-package :lem-daemon/tests/integration)

(defun wait-until (predicate &optional (seconds 10))
  (loop :repeat (* seconds 20)
        :when (funcall predicate) :return t
        :do (sleep 0.05)))

(defun send-request (connection type &rest fields)
  (let ((id (client::next-id)))
    (client::client-send
     connection
     (apply #'protocol:make-object
            "version" protocol:+protocol-version+
            "type" type "id" id fields))
    (multiple-value-bind (value error)
        (client::wait-for-response connection id)
      (when error (error "~a" error))
      value)))

(defun eval-primary (connection form)
  (let ((value (send-request connection "eval" "form" form)))
    (protocol:field value "primary")))

(defun visit-nowait (connection pathname &optional (line 1) (column 0))
  (send-request
   connection "visit"
   "wait" "nowait"
   "files" (vector (protocol:make-object
                    "path" (uiop:native-namestring pathname)
                    "line" line "column" column))))

(defstruct asynchronous-response
  thread value error)

(defun start-waiting-visit (connection pathname)
  (let* ((id (client::next-id))
         (response (make-asynchronous-response)))
    (client::client-send
     connection
     (protocol:make-object
      "version" protocol:+protocol-version+
      "type" "visit" "id" id "wait" "wait"
      "files" (vector (protocol:make-object
                       "path" (uiop:native-namestring pathname)
                       "line" 1 "column" 0))))
    (setf (asynchronous-response-thread response)
          (bt2:make-thread
           (lambda ()
             (multiple-value-bind (value error)
                 (client::wait-for-response connection id)
               (setf (asynchronous-response-value response) value
                     (asynchronous-response-error response) error)))
           :name "waiting lemclient integration request"))
    (values response id)))

(defun finish-asynchronous-response (response)
  (bt2:join-thread (asynchronous-response-thread response))
  (values (asynchronous-response-value response)
          (asynchronous-response-error response)))

(deftest daemon-client-round-trip
  (let* ((old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (root (merge-pathnames
                (format nil "lem-daemon-test-~d-~d/"
                        (sb-posix:getpid) (random 1000000000))
                (uiop:temporary-directory)))
         (server-name (format nil "test-~d" (random 1000000000)))
         (endpoint nil)
         (daemon-thread nil)
         (daemon-error nil)
         (admin nil)
         (first nil)
         (second nil)
         (waiting nil))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "marker" root))
           (setf (uiop:getenv "XDG_RUNTIME_DIR")
                 (uiop:native-namestring root)
                 endpoint (protocol:endpoint-pathname server-name)
                 daemon-thread
                 (bt2:make-thread
                  (lambda ()
                    (handler-case
                        (lem:launch
                         (lem:parse-args
                          (list (format nil "--daemon=~a" server-name) "-q")))
                      (error (condition) (setf daemon-error condition))))
                  :name "Lem daemon integration test"))
           (ok (wait-until (lambda () (probe-file endpoint)))
               "named daemon publishes its endpoint")
           (ok (null daemon-error) "daemon starts without an error")
           (let* ((directory (uiop:pathname-directory-pathname endpoint))
                  (directory-stat
                    (sb-posix:lstat (uiop:native-namestring directory)))
                  (socket-stat (sb-posix:lstat (uiop:native-namestring endpoint))))
             (ok (zerop (logand (sb-posix:stat-mode directory-stat) #o077))
                 "runtime directory is owner-private")
             (ok (zerop (logand (sb-posix:stat-mode socket-stat) #o077))
                 "socket is owner-private"))

           (setf admin (client::connect-client server-name))
           (ok (string= "42" (eval-primary admin "(+ 20 22)"))
               "eval returns a structured value")
           (eval-primary admin
                         "(defparameter lem-user::*daemon-test-state* 73)")
           (ok (string= "73"
                        (eval-primary admin "lem-user::*daemon-test-state*"))
               "editor state survives across clients and requests")

           (let ((malformed (client::connect-client server-name)))
             (protocol::write-u32 (1+ protocol:+maximum-message-bytes+)
                                  (client::client-stream malformed))
             (finish-output (client::client-stream malformed))
             (sleep 0.1)
             (client::close-client malformed))
           (ok (string= "6" (eval-primary admin "(* 2 3)"))
               "an oversized request does not damage the daemon")

           (setf first (client::connect-client server-name)
                 second (client::connect-client server-name))
           (ok (string= "attached"
                        (send-request first "attach" "width" 80 "height" 24))
               "first terminal session attaches")
           (ok (string= "attached"
                        (send-request second "attach" "width" 100 "height" 30))
               "second terminal session attaches")
           (ok (string= "3" (eval-primary first "(length (lem:all-frames))"))
               "two client frames coexist with the headless frame")

           (visit-nowait first (asdf:system-relative-pathname
                                :lem-daemon #p"../../docs/daemon-client.md"))
           (visit-nowait second (asdf:system-relative-pathname
                                 :lem-daemon #p"../../README.md"))
           (ok (search "daemon-client.md"
                       (eval-primary first
                                     "(lem:buffer-name (lem:current-buffer))"))
               "first session keeps its selected buffer")
           (ok (search "README.md"
                       (eval-primary second
                                     "(lem:buffer-name (lem:current-buffer))"))
               "second session has an independent selected buffer")

           (visit-nowait second (asdf:system-relative-pathname
                                 :lem-daemon #p"../../docs/daemon-client.md"))
           (eval-primary first
                         "(progn (lem:buffer-start (lem:current-point)) (lem:insert-string (lem:current-point) \"X\") :inserted)")
           (ok (string= "\"X\""
                        (eval-primary second
                                      "(subseq (lem:buffer-text (lem:current-buffer)) 0 1)"))
               "client frames observe shared buffer edits")

           (let ((edit-file (merge-pathnames "blocking-edit.txt" root)))
             (with-open-file (stream edit-file :direction :output
                                               :if-exists :supersede)
               (write-string "before" stream))

             (setf waiting (client::connect-client server-name))
             (multiple-value-bind (response id)
                 (start-waiting-visit waiting edit-file)
               (declare (ignore id))
               (ok (wait-until
                    (lambda ()
                      (string= "1"
                               (eval-primary
                                admin
                                "(length (lem-daemon::request-buffer-list))"))))
                   "blocking visit enters visible server-edit state")
               (eval-primary admin "(lem-daemon:daemon-edit-done)")
               (multiple-value-bind (value error)
                   (finish-asynchronous-response response)
                 (ok (and (null error) (string= "finished" value))
                     "clean finish releases the blocking client")))
             (client::close-client waiting)
             (setf waiting (client::connect-client server-name))

             (multiple-value-bind (response id)
                 (start-waiting-visit waiting edit-file)
               (declare (ignore id))
               (ok (wait-until
                    (lambda ()
                      (string= "1"
                               (eval-primary
                                admin
                                "(length (lem-daemon::request-buffer-list))"))))
                   "a second blocking visit can be established")
               (eval-primary
                admin
                "(progn (lem:buffer-end (lem:current-point)) (lem:insert-string (lem:current-point) \"-saved\") (lem-daemon:daemon-edit-save-and-done))")
               (multiple-value-bind (value error)
                   (finish-asynchronous-response response)
                 (ok (and (null error) (string= "finished" value))
                     "save-and-finish releases the blocking client"))
               (ok (string= "before-saved" (uiop:read-file-string edit-file))
                   "save-and-finish writes the shared buffer"))
             (client::close-client waiting)
             (setf waiting (client::connect-client server-name))

             (multiple-value-bind (response id)
                 (start-waiting-visit waiting edit-file)
               (ok (wait-until
                    (lambda ()
                      (string= "1"
                               (eval-primary
                                admin
                                "(length (lem-daemon::request-buffer-list))"))))
                   "a cancellable blocking visit is pending")
               (client::client-send
                waiting
                (protocol:make-object
                 "version" protocol:+protocol-version+
                 "type" "cancel" "id" (client::next-id) "request" id))
               (multiple-value-bind (value error)
                   (finish-asynchronous-response response)
                 (declare (ignore value))
                 (ok (and error (search "cancelled" error :test #'char-equal))
                     "cancellation releases the client with a useful error")))
             (client::close-client waiting)
             (setf waiting nil))

           (handler-case
               (progn (client::run-shutdown admin nil)
                      (fail "clean shutdown must reject modified buffers"))
             (error (condition)
               (ok (search "Modified buffers" (princ-to-string condition))
                   "normal shutdown reports modified buffers")))
           (ok (probe-file endpoint) "rejected shutdown leaves daemon running")
           (client::run-shutdown admin t)
           (ok (wait-until (lambda () (not (probe-file endpoint))))
               "forced shutdown removes the endpoint")
           (when daemon-thread (bt2:join-thread daemon-thread))
           (setf daemon-thread nil)
           (ok (null daemon-error) "daemon exits cleanly"))
      (dolist (connection (list waiting first second admin))
        (when connection (client::close-client connection)))
      (when (and daemon-thread (bt2:thread-alive-p daemon-thread))
        (ignore-errors
          (bt2:interrupt-thread daemon-thread
                                (lambda () (error "test cleanup"))))
        (ignore-errors (bt2:join-thread daemon-thread)))
      (setf (uiop:getenv "XDG_RUNTIME_DIR") old-runtime)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))
