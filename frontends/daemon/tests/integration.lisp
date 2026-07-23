(defpackage :lem-daemon/tests/integration
  (:use :cl :rove)
  (:local-nicknames (:client :lem-daemon/client)
                    (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport)))
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

(defun visit-many-nowait (connection entries)
  (send-request connection "visit" "wait" "nowait" "files" entries))

(defun send-key (connection symbol &key ctrl meta shift)
  (send-request connection "input"
                "ctrl" (and ctrl t)
                "meta" (and meta t)
                "shift" (and shift t)
                "sym" symbol))

(defstruct asynchronous-response
  thread value error)

(defun start-waiting-visit-many (connection entries)
  (let* ((id (client::next-id))
         (response (make-asynchronous-response)))
    (client::client-send
     connection
     (protocol:make-object
      "version" protocol:+protocol-version+
      "type" "visit" "id" id "wait" "wait"
      "files" entries))
    (setf (asynchronous-response-thread response)
          (bt2:make-thread
           (lambda ()
             (multiple-value-bind (value error)
                 (client::wait-for-response connection id)
               (setf (asynchronous-response-value response) value
                     (asynchronous-response-error response) error)))
           :name "waiting lemclient integration request"))
    (values response id)))

(defun start-waiting-visit (connection pathname)
  (start-waiting-visit-many
   connection
   (vector (protocol:make-object
            "path" (uiop:native-namestring pathname)
            "line" 1 "column" 0))))

(defun finish-asynchronous-response (response)
  (bt2:join-thread (asynchronous-response-thread response))
  (values (asynchronous-response-value response)
          (asynchronous-response-error response)))

(deftest daemon-client-round-trip
  (let* ((old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (old-git-editor (uiop:getenv "GIT_EDITOR"))
         (old-visual (uiop:getenv "VISUAL"))
         (old-editor (uiop:getenv "EDITOR"))
         (root (merge-pathnames
                (format nil "lem-daemon-test-~d-~d/"
                        (sb-posix:getpid) (random 1000000000))
                (uiop:temporary-directory)))
         (server-name (format nil "test-~d" (random 1000000000)))
         (endpoint nil)
         (metadata nil)
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
                 (uiop:native-namestring root))
           (setf (uiop:getenv "GIT_EDITOR") nil
                 (uiop:getenv "VISUAL") nil
                 (uiop:getenv "EDITOR") nil
                 endpoint (transport:local-endpoint
                           (transport:require-local-backend) server-name)
                 metadata (transport:local-metadata
                           (transport:require-local-backend) server-name)
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
           (let ((expected (format nil "lemclient --server-name ~a" server-name)))
             (ok (wait-until
                  (lambda ()
                    (every (lambda (variable)
                             (string= expected (uiop:getenv variable)))
                           '("GIT_EDITOR" "VISUAL" "EDITOR"))))
                 "daemon clients populate the editor environment"))
           (setf (uiop:getenv "GIT_EDITOR") "preserved-git"
                 (uiop:getenv "VISUAL") "preserved-visual"
                 (uiop:getenv "EDITOR") "preserved-editor")
           (lem-daemon::configure-editor-environment)
           (ok (equal '("preserved-git" "preserved-visual" "preserved-editor")
                      (mapcar #'uiop:getenv
                              '("GIT_EDITOR" "VISUAL" "EDITOR")))
               "daemon startup respects existing editor environment values")
           (let* ((directory (uiop:pathname-directory-pathname endpoint))
                  (directory-stat
                    (sb-posix:lstat (uiop:native-namestring directory)))
                  (socket-stat (sb-posix:lstat (uiop:native-namestring endpoint))))
             (ok (zerop (logand (sb-posix:stat-mode directory-stat) #o077))
                 "runtime directory is owner-private")
             (ok (zerop (logand (sb-posix:stat-mode socket-stat) #o077))
                 "socket is owner-private")
             (let ((metadata-stat
                     (sb-posix:lstat (uiop:native-namestring metadata))))
               (ok (zerop (logand (sb-posix:stat-mode metadata-stat) #o077))
                   "metadata is owner-private")))

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

           (let ((only-terminal (client::connect-client server-name)))
             (unwind-protect
                  (progn
                    (send-request only-terminal "attach"
                                  "width" 80 "height" 24)
                    (send-key only-terminal "x" :ctrl t)
                    (send-key only-terminal "c" :ctrl t))
               (client::close-client only-terminal)))
           (ok (wait-until
                (lambda ()
                  (string= "1"
                           (eval-primary admin "(length (lem:all-frames))"))))
               "closing the last terminal leaves the headless daemon alive")

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

           (let ((transient (client::connect-client server-name)))
             (unwind-protect
                  (progn
                    (send-request transient "attach" "width" 80 "height" 24)
                    (ok (string= "4"
                                 (eval-primary admin "(length (lem:all-frames))"))
                        "a later client can attach an additional frame"))
               (client::close-client transient)))
           (ok (wait-until
                (lambda ()
                  (string= "3"
                           (eval-primary admin "(length (lem:all-frames))"))))
               "a client crash removes only its frame")
           (let ((reconnected (client::connect-client server-name)))
             (unwind-protect
                  (progn
                    (ok (string= "attached"
                                 (send-request reconnected "attach"
                                               "width" 90 "height" 25))
                        "a terminal can reconnect after a disconnect")
                    (send-key reconnected "x" :ctrl t)
                    (send-key reconnected "c" :ctrl t))
               (client::close-client reconnected)))
           (ok (wait-until
                (lambda ()
                  (string= "3"
                           (eval-primary admin "(length (lem:all-frames))"))))
               "C-x C-c detaches a client frame without stopping the daemon")

           (let ((design (asdf:system-relative-pathname
                          :lem-daemon #p"../../docs/daemon-client.md"))
                 (readme (asdf:system-relative-pathname
                          :lem-daemon #p"../../README.md")))
             (visit-many-nowait
              first
              (vector (protocol:make-object
                       "path" (uiop:native-namestring design)
                       "line" 3 "column" 2)
                      (protocol:make-object
                       "path" (uiop:native-namestring readme)
                       "line" 1 "column" 0)))
             (ok (string= "3"
                          (eval-primary
                           first
                           "(lem:line-number-at-point (lem:current-point))"))
                 "a multi-file request positions its first file by line")
             (ok (string= "2"
                          (eval-primary first
                                        "(lem:point-charpos (lem:current-point))"))
                 "a positioned request preserves the requested column")
             (ok (string= "T"
                          (eval-primary
                           first
                           "(not (null (lem:get-buffer \"README.md\")))"))
                 "one request opens every named file"))

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

           (eval-primary
            first
            "(progn (lem:switch-to-buffer (lem:make-buffer \"daemon-input-first\")) :ready)")
           (eval-primary
            second
            "(progn (lem:switch-to-buffer (lem:make-buffer \"daemon-input-second\")) :ready)")
           (send-key first "x" :ctrl t)
           (ok (wait-until
                (lambda ()
                  (string= "T"
                           (eval-primary
                            admin
                            "(not (null lem-core::*routed-input-session*))"))))
               "a prefix key retains ownership of its client session")
           (send-key second "b")
           (send-key first "u")
           (ok (string= "\"\""
                        (eval-primary first
                                      "(lem:buffer-text (lem:current-buffer))"))
               "another client's key does not complete the first prefix")
           (ok (string= "\"b\""
                        (eval-primary second
                                      "(lem:buffer-text (lem:current-buffer))"))
               "deferred input runs in its originating frame")

           (visit-nowait first (asdf:system-relative-pathname
                                :lem-daemon #p"../../docs/daemon-client.md"))
           (visit-nowait second (asdf:system-relative-pathname
                                 :lem-daemon #p"../../docs/daemon-client.md"))
           (eval-primary first
                         "(progn (lem:buffer-start (lem:current-point)) (lem:insert-string (lem:current-point) \"X\") :inserted)")
           (ok (string= "\"X\""
                        (eval-primary second
                                      "(subseq (lem:buffer-text (lem:current-buffer)) 0 1)"))
               "client frames observe shared buffer edits")

           (let ((first-file (merge-pathnames "matrix first;safe.txt" root))
                 (second-file (merge-pathnames "matrix-second.txt" root))
                 (nowait-file (merge-pathnames "matrix-nowait.txt" root))
                 (client-thread nil)
                 (client-status nil)
                 (client-error nil))
             (with-open-file (stream first-file :direction :output
                                                :if-exists :supersede)
               (format stream "alpha~%bravo~%"))
             (with-open-file (stream second-file :direction :output
                                                 :if-exists :supersede)
               (write-string "second" stream))
             (with-open-file (stream nowait-file :direction :output
                                                 :if-exists :supersede)
               (format stream "nowait-one~%nowait-two~%"))
             (eval-primary
              admin
              "(progn (lem:switch-to-buffer (lem:make-buffer \"daemon-matrix-origin\")) :ready)")
             (setf client-thread
                   (bt2:make-thread
                    (lambda ()
                      (handler-case
                          (setf client-status
                                (client:run-client
                                 (list "--server-name" server-name
                                       "+2:3"
                                       (uiop:native-namestring first-file)
                                       (uiop:native-namestring second-file))))
                        (error (condition) (setf client-error condition))))
                    :name "lemclient compatibility matrix"))
             (unwind-protect
                  (progn
                    (ok (wait-until
                         (lambda ()
                           (string= "(\"matrix first;safe.txt\" 2 3)"
                                    (eval-primary
                                     admin
                                     "(list (lem:buffer-name (lem:current-buffer)) (lem:line-number-at-point (lem:current-point)) (lem:point-charpos (lem:current-point)))"))))
                   "blocking multi-file visits begin at the first location")
                    (eval-primary
                     admin
                     "(progn (lem:insert-string (lem:current-point) \"X\") (lem-daemon:daemon-edit-save-and-done))")
                    (ok (bt2:thread-alive-p client-thread)
                        "the client keeps waiting until every file is finished")
                    (ok (string= "(\"matrix-second.txt\" 1)"
                                 (eval-primary
                                  admin
                                  "(list (lem:buffer-name (lem:current-buffer)) (length (lem-daemon::request-buffer-list)))"))
                        "finishing one file advances to the next edit buffer")
                    (eval-primary
                     admin
                     "(progn (lem:buffer-end (lem:current-point)) (lem:insert-string (lem:current-point) \"TWO\") (lem-daemon:daemon-edit-save-and-done))")
                    (bt2:join-thread client-thread)
                    (setf client-thread nil)
                    (ok (and (null client-error) (= 0 client-status))
                        "the native multi-file client returns after the final file")
                    (ok (string= (format nil "alpha~%braXvo~%")
                                 (uiop:read-file-string first-file))
                        "the first positioned edit is saved")
                    (ok (string= "secondTWO" (uiop:read-file-string second-file))
                        "the second edit is saved")
                    (ok (string= "\"daemon-matrix-origin\""
                                 (eval-primary
                                  admin
                                  "(lem:buffer-name (lem:current-buffer))"))
                        "finishing the request restores its origin buffer")
                    (ok (= 0 (client:run-client
                              (list "--server-name" server-name "--no-wait"
                                    "+2:1"
                                    (uiop:native-namestring nowait-file))))
                        "the native no-wait client returns immediately")
                    (ok (string= "(\"matrix-nowait.txt\" 2 1 NIL 0)"
                                 (eval-primary
                                  admin
                                  "(list (lem:buffer-name (lem:current-buffer)) (lem:line-number-at-point (lem:current-point)) (lem:point-charpos (lem:current-point)) (lem:mode-active-p (lem:current-buffer) 'lem-daemon::daemon-edit-mode) (length (lem-daemon::request-buffer-list)))"))
                        "no-wait positioning creates no edit-session state"))
               (when (and client-thread (bt2:thread-alive-p client-thread))
                 (ignore-errors
                   (bt2:interrupt-thread client-thread
                                         (lambda () (error "test cleanup"))))
                 (ignore-errors (bt2:join-thread client-thread)))))

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
             (setf waiting nil)

             (let ((abort-file (merge-pathnames "matrix-abort.txt" root))
                   (abort-thread nil)
                   (abort-status nil)
                   (abort-error nil))
               (with-open-file (stream abort-file :direction :output
                                                   :if-exists :supersede)
                 (write-string "abort-original" stream))
               (eval-primary
                admin
                "(progn (lem:switch-to-buffer (lem:make-buffer \"daemon-abort-origin\")) :ready)")
               (setf abort-thread
                     (bt2:make-thread
                      (lambda ()
                        (handler-case
                            (setf abort-status
                                  (client:run-client
                                   (list "--server-name" server-name
                                         (uiop:native-namestring abort-file))))
                          (error (condition) (setf abort-error condition))))
                      :name "aborting native lemclient"))
               (unwind-protect
                    (progn
                      (ok (wait-until
                           (lambda ()
                             (string= "1"
                                      (eval-primary
                                       admin
                                       "(length (lem-daemon::request-buffer-list))"))))
                          "an abortable blocking visit is pending")
                      (eval-primary
                       admin
                       "(progn (lem:buffer-end (lem:current-point)) (lem:insert-string (lem:current-point) \"-discard\") (lem-daemon:daemon-edit-abort))")
                      (bt2:join-thread abort-thread)
                      (setf abort-thread nil)
                      (ok (and (null abort-error) (= 1 abort-status))
                          "editor-side abort returns the compatible client status")
                      (ok (string= "\"daemon-abort-origin\""
                                   (eval-primary
                                    admin
                                    "(lem:buffer-name (lem:current-buffer))"))
                          "abort restores the request origin")
                      (ok (string= "abort-original"
                                   (uiop:read-file-string abort-file))
                          "abort does not persist the edit")
                      (ok (string= "(\"abort-original-discard\" T NIL)"
                                   (eval-primary
                                    admin
                                    "(let ((buffer (lem:get-buffer \"matrix-abort.txt\"))) (list (lem:buffer-text buffer) (lem-core::buffer-modified-p buffer) (lem:mode-active-p buffer 'lem-daemon::daemon-edit-mode)))"))
                          "abort retains an unsaved, recoverable buffer without edit mode"))
                 (when (and abort-thread (bt2:thread-alive-p abort-thread))
                   (ignore-errors
                     (bt2:interrupt-thread abort-thread
                                           (lambda () (error "test cleanup"))))
                   (ignore-errors (bt2:join-thread abort-thread)))))
             (setf waiting (client::connect-client server-name))

             (eval-primary
              admin
              "(progn (lem:switch-to-buffer (lem:make-buffer \"daemon-zero-file-origin\")) :ready)")
             (multiple-value-bind (response id)
                 (start-waiting-visit-many waiting #())
               (declare (ignore id))
               (ok (wait-until
                    (lambda ()
                      (string= "1"
                               (eval-primary
                                admin
                                "(length (lem-daemon::request-buffer-list))"))))
                   "a zero-file client waits on the current buffer")
               (eval-primary admin "(lem-daemon:daemon-edit-done)")
               (multiple-value-bind (value error)
                   (finish-asynchronous-response response)
                 (ok (and (null error) (string= "finished" value))
                     "clean finish releases a zero-file client")))
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
           (ok (not (probe-file metadata))
               "forced shutdown removes daemon metadata")
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
      (setf (uiop:getenv "GIT_EDITOR") old-git-editor
            (uiop:getenv "VISUAL") old-visual
            (uiop:getenv "EDITOR") old-editor)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))
