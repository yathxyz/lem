(defpackage :lem-daemon/tests/backpressure
  (:use :cl :rove)
  (:local-nicknames (:daemon :lem-daemon)
                    (:client :lem-daemon/client)
                    (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport)
                    (:integration :lem-daemon/tests/integration)))
(in-package :lem-daemon/tests/backpressure)

(defclass test-transport (transport::local-connection)
  ((closed-p :initform nil :accessor test-transport-closed-p)))

(defmethod transport:close-local-connection ((connection test-transport))
  (setf (test-transport-closed-p connection) t))

(deftest output-queue-has-item-and-byte-limits
  (let ((lem-core::*in-the-editor* nil))
    (dolist (payload (list "small" (make-string 524288 :initial-element #\x)))
      (let* ((transport (make-instance 'test-transport))
             (connection (make-instance 'daemon::daemon-connection
                                         :transport transport :stream nil))
             (message (protocol:make-object "type" "test" "payload" payload))
             (encoded (protocol:encode-message message))
             (bytes (+ 4 (length encoded)))
             (limit (min daemon::+connection-output-message-limit+
                         (floor daemon::+connection-output-byte-limit+ bytes))))
        (dotimes (index limit)
          (declare (ignore index))
          (daemon::daemon-send connection message))
        (ok (not (daemon::connection-closed-p connection))
            "messages within both limits remain queued")
        (ok (= limit (daemon::connection-write-count connection)))
        (ok (= (* bytes limit) (daemon::connection-write-bytes connection)))
        (ok (every (lambda (octets) (equalp octets encoded))
                   (daemon::connection-write-head connection))
            "the queue holds immutable encoded bytes")
        (daemon::daemon-send connection message)
        (ok (and (daemon::connection-closed-p connection)
                 (test-transport-closed-p transport))
            "exceeding either limit closes the stalled transport")
        (ok (and (null (daemon::connection-write-head connection))
                 (zerop (daemon::connection-write-count connection))
                 (zerop (daemon::connection-write-bytes connection)))
            "overflow releases queued payloads")))))

(deftest stopped-reader-does-not-block-other-clients
  (let* ((old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (root (merge-pathnames
                (format nil "lem-backpressure-~d-~d/" (sb-posix:getpid) (random 1000000000))
                (uiop:temporary-directory)))
         (name (format nil "backpressure-~d" (random 1000000000)))
         (thread nil) (failure nil)
         (admin nil) (stalled nil) (healthy nil)
         (server-connection nil) (writer nil) (reader nil) (shutdown-readers nil))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "marker" root))
           (setf (uiop:getenv "XDG_RUNTIME_DIR") (namestring root)
                 thread (bt2:make-thread
                         (lambda ()
                           (handler-case
                               (lem:launch (lem:parse-args
                                            (list (format nil "--daemon=~a" name) "-q")))
                             (error (condition) (setf failure condition))))
                         :name "Lem backpressure test daemon"))
           (setf admin (client::connect-client-with-wait name 10)
                 stalled (client::connect-client name)
                 healthy (client::connect-client name))
           (integration::send-request stalled "attach" "width" 500 "height" 50)
           (integration::send-request healthy "attach" "width" 80 "height" 24)
           ;; The attached peer now stops reading, exactly as a SIGSTOPed
           ;; graphical/terminal process does, while its socket stays open.
           (setf server-connection
                 (bt2:with-lock-held (daemon::*daemon-lock*)
                   (find-if (lambda (connection)
                              (let ((implementation (daemon::connection-implementation connection)))
                                (and implementation
                                     (= 500 (daemon::daemon-implementation-width implementation)))))
                            daemon::*daemon-connections*))
                 writer (daemon::connection-writer server-connection)
                 reader (daemon::connection-reader server-connection))
           (let ((start (get-internal-real-time)))
             (sb-ext:with-timeout 10
               (ok (equal ":RESPONSIVE"
                          (integration::eval-primary
                           admin
                           "(let* ((peer (find-if (lambda (connection) (let ((implementation (lem-daemon::connection-implementation connection))) (and implementation (= 500 (lem-daemon::daemon-implementation-width implementation))))) lem-daemon::*daemon-connections*)) (implementation (lem-daemon::connection-implementation peer))) (lem:with-implementation implementation (dotimes (index 160) (when (lem-daemon::connection-closed-p peer) (return)) (setf (lem-daemon::daemon-implementation-previous-screen implementation) nil) (lem:redraw-display :force t))) :responsive)"))
                   "real redisplay to a stopped reader leaves admin evaluation responsive"))
             (ok (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 10)))
           (ok (integration::wait-until
                (lambda () (and (daemon::connection-closed-p server-connection)
                                (not (bt2:thread-alive-p writer)))))
               "overflow shuts down the socket and releases the blocked writer")
           (ok (integration::wait-until (lambda () (not (bt2:thread-alive-p reader))) 2)
               "overflow also releases the blocked server reader before its peer closes")
           (ok (integration::wait-until
                (lambda () (null (daemon::connection-implementation server-connection)))))
           (ok (equal "2" (integration::eval-primary healthy "(length (lem:all-frames))"))
               "only the stopped peer's frame is removed")
           (ok (equal "42" (integration::eval-primary healthy "(+ 40 2)"))
               "the remaining attached client continues using the daemon")
           (client::close-client stalled)
           (setf stalled (client::connect-client name))
           (integration::send-request stalled "attach" "width" 500 "height" 50)
           (ok (equal "T"
                      (integration::eval-primary
                       admin
                       "(let* ((peer (find-if (lambda (connection) (let ((implementation (lem-daemon::connection-implementation connection))) (and implementation (= 500 (lem-daemon::daemon-implementation-width implementation))))) lem-daemon::*daemon-connections*)) (implementation (lem-daemon::connection-implementation peer))) (lem:with-implementation implementation (dotimes (index 20) (setf (lem-daemon::daemon-implementation-previous-screen implementation) nil) (lem:redraw-display :force t))) (and (not (lem-daemon::connection-closed-p peer)) (plusp (lem-daemon::connection-write-count peer))))"))
               "a second stopped reader retains output below the overflow limits")
           (let ((start (get-internal-real-time)))
             (setf shutdown-readers
                   (bt2:with-lock-held (daemon::*daemon-lock*)
                     (mapcar #'daemon::connection-reader daemon::*daemon-connections*)))
             (sb-ext:with-timeout 5
               (client::run-shutdown admin t)
               (bt2:join-thread thread))
             (ok (< (/ (- (get-internal-real-time) start) internal-time-units-per-second) 5)
                 "shutdown remains bounded with a writer blocked below the queue limits"))
           (ok (every (lambda (reader) (not (bt2:thread-alive-p reader))) shutdown-readers)
               "daemon shutdown joins every server reader while peer sockets remain open")
           (setf thread nil)
           (ok (null failure) "daemon shutdown flushes its success response"))
      ;; Release the non-reading peer first, including on a regression timeout.
      (dolist (connection (list stalled healthy admin))
        (when connection (ignore-errors (client::close-client connection))))
      (when thread
        (ignore-errors
          (let ((stopper (client::connect-client name)))
            (unwind-protect (client::run-shutdown stopper t)
              (client::close-client stopper))))
        (ignore-errors (bt2:join-thread thread)))
      (setf (uiop:getenv "XDG_RUNTIME_DIR") old-runtime)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))
