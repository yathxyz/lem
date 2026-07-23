(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-bsd-sockets)
  #+sbcl (require :sb-posix))

(in-package :lem-daemon)

(defparameter +connection-limit+ 64)
(defparameter +capabilities+
  #("visit" "eval" "attach" "input" "redisplay" "resize" "detach"
    "shutdown" "cancel"))

(defvar *daemon-name* "server")
(defvar *daemon-socket* nil)
(defvar *daemon-endpoint* nil)
(defvar *daemon-metadata* nil)
(defvar *daemon-endpoint-identity* nil)
(defvar *daemon-metadata-identity* nil)
(defvar *daemon-accept-thread* nil)
(defvar *daemon-running-p* nil)
(defvar *daemon-root-implementation* nil)
(defvar *daemon-connections* '())
(defvar *daemon-requests* '())
(defvar *daemon-lock* (bt2:make-lock :name "lem-daemon/state"))

(define-condition stop-accept-loop (condition) ())

(defclass daemon-connection ()
  ((socket :initarg :socket :reader connection-socket)
   (stream :initarg :stream :reader connection-stream)
   (write-lock :initform (bt2:make-lock :name "lem-daemon/write")
               :reader connection-write-lock)
   (implementation :initform nil :accessor connection-implementation)
   (closed-p :initform nil :accessor connection-closed-p)
   (negotiated-p :initform nil :accessor connection-negotiated-p)))

(defstruct (daemon-request (:constructor make-daemon-request (id connection kind)))
  id
  connection
  kind
  (buffers '())
  origin-buffer
  (cancelled-p nil)
  (completed-p nil))

(defvar *daemon-edit-mode-keymap*
  (make-keymap :description "daemon client edit"))

(define-minor-mode daemon-edit-mode
    (:name "DaemonEdit" :keymap *daemon-edit-mode-keymap*))

(define-key *daemon-edit-mode-keymap* "C-x #" 'daemon-edit-done)
(define-key *daemon-edit-mode-keymap* "C-c C-c" 'daemon-edit-save-and-done)
(define-key *daemon-edit-mode-keymap* "C-c C-k" 'daemon-edit-abort)

(defun daemon-running-p () *daemon-running-p*)
(defun daemon-endpoint () *daemon-endpoint*)

(defun hash-values-vector (table)
  (let ((values '()))
    (maphash (lambda (key value) (declare (ignore key)) (push value values)) table)
    (coerce (nreverse values) 'vector)))

(defun daemon-send (connection message)
  (unless (connection-closed-p connection)
    (handler-case
        (bt2:with-lock-held ((connection-write-lock connection))
          (protocol:write-message message (connection-stream connection)))
      (error ()
        (setf (connection-closed-p connection) t)
        nil))))

(defun response (connection id &rest fields)
  (daemon-send
   connection
   (apply #'protocol:make-object
          "version" protocol:+protocol-version+
          "type" "response"
          "id" id
          fields)))

(defun response-ok (connection id &optional value)
  (response connection id "status" "ok" "value" value))

(defun response-error (connection id code message)
  (response connection id
            "status" "error"
            "error" (protocol:make-object "code" code "message" message)))

(defun register-request (request)
  (bt2:with-lock-held (*daemon-lock*)
    (push request *daemon-requests*)))

(defun unregister-request (request)
  (bt2:with-lock-held (*daemon-lock*)
    (setf *daemon-requests* (delete request *daemon-requests* :test #'eq))))

(defun find-request (connection id)
  (bt2:with-lock-held (*daemon-lock*)
    (find-if (lambda (request)
               (and (eq connection (daemon-request-connection request))
                    (equal id (daemon-request-id request))))
             *daemon-requests*)))

(defun request-buffer-list (&optional (buffer (current-buffer)))
  (copy-list (buffer-value buffer 'lem-daemon-requests)))

(defun (setf request-buffer-list) (requests &optional (buffer (current-buffer)))
  (setf (buffer-value buffer 'lem-daemon-requests) requests))

(defun live-buffer-p (buffer)
  (and (bufferp buffer) (not (deleted-buffer-p buffer))))

(defun attach-request-to-buffer (request buffer)
  (setf (request-buffer-list buffer)
        (adjoin request (request-buffer-list buffer) :test #'eq))
  (with-current-buffer buffer (daemon-edit-mode t)))

(defun detach-request (request)
  (dolist (buffer (copy-list (daemon-request-buffers request)))
    (when (live-buffer-p buffer)
      (setf (request-buffer-list buffer)
            (delete request (request-buffer-list buffer) :test #'eq))
      (unless (request-buffer-list buffer)
        (with-current-buffer buffer (daemon-edit-mode nil)))))
  (setf (daemon-request-buffers request) '()))

(defun complete-request (request status &optional value)
  (unless (daemon-request-completed-p request)
    (setf (daemon-request-completed-p request) t)
    (detach-request request)
    (unregister-request request)
    (if (string= status "ok")
        (response-ok (daemon-request-connection request)
                     (daemon-request-id request) value)
        (response-error (daemon-request-connection request)
                        (daemon-request-id request) status
                        (or value status)))))

(defun complete-buffer-requests (buffer abort-p)
  (let ((requests (request-buffer-list buffer)))
    (dolist (request requests)
      (if abort-p
          (complete-request request "aborted" "File request aborted")
          (progn
            (setf (daemon-request-buffers request)
                  (delete buffer (daemon-request-buffers request) :test #'eq))
            (setf (request-buffer-list buffer)
                  (delete request (request-buffer-list buffer) :test #'eq))
            (unless (daemon-request-buffers request)
              (complete-request request "ok" "finished")))))
    (unless (request-buffer-list buffer)
      (with-current-buffer buffer (daemon-edit-mode nil)))
    requests))

(define-command daemon-edit-done () ()
  "Finish waiting daemon clients without saving this buffer."
  (unless (request-buffer-list)
    (editor-error "This buffer has no waiting lemclient request"))
  (complete-buffer-requests (current-buffer) nil)
  (message "lemclient request finished"))

(define-command daemon-edit-save-and-done () ()
  "Save this buffer and finish its waiting daemon clients."
  (unless (request-buffer-list)
    (editor-error "This buffer has no waiting lemclient request"))
  (save-current-buffer)
  (complete-buffer-requests (current-buffer) nil)
  (message "Saved; lemclient request finished"))

(define-command daemon-edit-abort () ()
  "Abort the waiting daemon clients without closing this buffer."
  (unless (request-buffer-list)
    (editor-error "This buffer has no waiting lemclient request"))
  (complete-buffer-requests (current-buffer) t)
  (message "lemclient request aborted"))

(defun require-string (message name &optional (maximum 65536))
  (let ((value (protocol:field message name)))
    (unless (and (stringp value) (<= (length value) maximum))
      (error "Field ~a must be a string of at most ~d characters" name maximum))
    value))

(defun require-integer (message name minimum maximum)
  (let ((value (protocol:field message name)))
    (unless (and (integerp value) (<= minimum value maximum))
      (error "Field ~a must be between ~d and ~d" name minimum maximum))
    value))

(defun request-id (message)
  (let ((id (protocol:field message "id")))
    (unless (or (stringp id) (integerp id))
      (error "Request id must be a string or integer"))
    id))

(defun visit-location (entry)
  (unless (hash-table-p entry) (error "File entry must be an object"))
  (let* ((native (require-string entry "path" 4096))
         (pathname (uiop:parse-native-namestring native))
         (line (require-integer entry "line" 1 most-positive-fixnum))
         (column (require-integer entry "column" 0 most-positive-fixnum)))
    (unless (uiop:absolute-pathname-p pathname)
      (error "Client file path must be absolute: ~a" native))
    (values pathname line column)))

(defun handle-visit-on-editor (request message)
  (handler-case
      (let ((implementation
              (or (connection-implementation
                   (daemon-request-connection request))
                  *daemon-root-implementation*)))
        (when implementation (activate-implementation implementation))
        (let ((entries (protocol:field message "files"))
            (wait-p (string= "wait" (protocol:field message "wait" "wait"))))
        (unless (and (typep entries 'sequence)
                     (not (stringp entries))
                     (<= (length entries) protocol:+maximum-files+))
          (error "files must be an array of at most ~d entries"
                 protocol:+maximum-files+))
        (let ((origin (current-buffer)) (buffers '()) (first-location nil))
          (loop :for entry :in (coerce entries 'list)
                :do (multiple-value-bind (pathname line column)
                        (visit-location entry)
                      (let ((buffer (find-file-buffer pathname)))
                        (unless (bufferp buffer)
                          (error "Could not open ~a" pathname))
                        (unless first-location
                          (setf first-location (list buffer line column)))
                        (pushnew buffer buffers :test #'eq))))
          (when (null buffers) (push origin buffers))
          (setf buffers (nreverse buffers)
                (daemon-request-origin-buffer request) origin
                (daemon-request-buffers request) buffers)
          (when wait-p
            (dolist (buffer buffers) (attach-request-to-buffer request buffer)))
          (when first-location
            (destructuring-bind (buffer line column) first-location
              (switch-to-buffer buffer)
              (move-to-line (current-point) line)
              (move-to-column (current-point) column)))
          (redraw-display :force t)
          (if wait-p
              (response (daemon-request-connection request)
                        (daemon-request-id request)
                        "status" "pending" "value" "opened")
              (complete-request request "ok" "opened")))))
    (error (condition)
      (complete-request request "visit-error" (princ-to-string condition)))))

(defun readable-value (value)
  (let ((*print-length* 100)
        (*print-level* 20)
        (*print-circle* t))
    (let ((text (write-to-string value :readably t)))
      (if (> (length text) 65536)
          (concatenate 'string (subseq text 0 65536) "...")
          text))))

(defun handle-eval-on-editor (request form-string)
  (alexandria:when-let
      ((implementation
         (or (connection-implementation (daemon-request-connection request))
             *daemon-root-implementation*)))
    (activate-implementation implementation))
  (if (daemon-request-cancelled-p request)
      (complete-request request "cancelled" "Request cancelled")
      (handler-case
          (multiple-value-bind (form position)
              (read-from-string form-string nil :eof)
            (when (eq form :eof) (error "Evaluation form is empty"))
            (unless (every (lambda (character)
                             (find character '(#\Space #\Tab #\Newline #\Return)))
                           (subseq form-string position))
              (error "Evaluation request contains trailing data"))
            (let* ((*package* (find-package :lem-user))
                   (values (multiple-value-list (eval form)))
                   (printed (map 'vector #'readable-value values)))
              (complete-request
               request "ok"
               (protocol:make-object
                "values" printed
                "count" (length printed)
                "primary" (if (plusp (length printed)) (aref printed 0) "NIL")))))
        (error (condition)
          (complete-request request "evaluation-error"
                            (princ-to-string condition))))))

(defun activate-implementation (implementation)
  (unless (eq (implementation) implementation)
    (let ((old-frame (current-frame)))
      (when old-frame
        (let ((old-window (frame-current-window old-frame)))
          (when (and old-window
                     (eq (window-buffer old-window) (current-buffer)))
            (move-point (lem-core::%window-point old-window)
                        (buffer-point (current-buffer)))))))
    (setf lem-core::*implementation* implementation)
    (alexandria:when-let ((frame (get-frame implementation)))
      (let* ((window (frame-current-window frame))
             (buffer (window-buffer window)))
        (setf (current-buffer) buffer)
        (move-point (buffer-point buffer) (lem-core::%window-point window))))))

(defun redraw-other-sessions (active)
  (unwind-protect
       (dolist (connection (bt2:with-lock-held (*daemon-lock*)
                             (copy-list *daemon-connections*)))
         (let ((implementation (connection-implementation connection)))
           (when (and implementation (not (eq implementation active))
                      (get-frame implementation))
             (activate-implementation implementation)
             (redraw-display :force t))))
    (activate-implementation active)))

(defun handle-attach-on-editor (connection id width height)
  (when (connection-implementation connection)
    (error "Connection already owns a frame"))
  (let ((implementation (make-instance 'daemon-implementation
                                       :connection connection
                                       :width width :height height)))
    (setf (connection-implementation connection) implementation)
    (with-implementation implementation
      (let ((frame (make-frame nil)))
        (map-frame implementation frame)
        (setup-frame frame (primordial-buffer))))
    (activate-implementation implementation)
    (redraw-display :force t)
    (response-ok connection id "attached")))

(defun detach-connection-frame-on-editor (connection)
  (alexandria:when-let ((implementation (connection-implementation connection)))
    (with-implementation implementation
      (alexandria:when-let ((frame (get-frame implementation)))
        (unmap-frame implementation)
        (teardown-frame frame)))
    (setf (connection-implementation connection) nil)
    (when (eq (implementation) implementation)
      (activate-implementation *daemon-root-implementation*))))

(defun bool-field (message name)
  (eq t (protocol:field message name)))

(defun handle-message (connection message)
  (unless (= protocol:+protocol-version+
             (or (protocol:field message "version") -1))
    (error "Unsupported protocol version"))
  (let ((type (require-string message "type" 32)))
    (unless (connection-negotiated-p connection)
      (unless (string= type "hello")
        (error "First message must be hello"))
      (setf (connection-negotiated-p connection) t)
      (return-from handle-message
        (daemon-send connection
                     (protocol:make-object
                      "version" protocol:+protocol-version+
                      "type" "hello"
                      "capabilities" +capabilities+))))
    (let ((id (request-id message)))
      (cond
        ((string= type "visit")
         (let ((request (make-daemon-request id connection :visit)))
           (register-request request)
           (send-event (lambda () (handle-visit-on-editor request message)))))
        ((string= type "eval")
         (let ((request (make-daemon-request id connection :eval))
               (form (require-string message "form" 262144)))
           (register-request request)
           (send-event (lambda () (handle-eval-on-editor request form)))))
        ((string= type "attach")
         (let ((width (require-integer message "width" 20 1000))
               (height (require-integer message "height" 5 1000)))
           (send-event
            (lambda ()
              (handler-case (handle-attach-on-editor connection id width height)
                (error (condition)
                  (response-error connection id "attach-error"
                                  (princ-to-string condition))))))))
        ((string= type "input")
         (let ((implementation (or (connection-implementation connection)
                                   (error "Connection has no attached frame"))))
           (cond
             ((protocol:field message "paste")
              (let ((text (require-string message "paste" 262144)))
                (send-event
                 (lambda ()
                   (activate-implementation implementation)
                   (insert-bracketed-paste (current-point) text)
                   (redraw-display :force t)
                   (redraw-other-sessions implementation)))))
             (t
              (let ((key (make-key
                          :ctrl (bool-field message "ctrl")
                          :meta (bool-field message "meta")
                          :super (bool-field message "super")
                          :hyper (bool-field message "hyper")
                          :shift (bool-field message "shift")
                          :sym (require-string message "sym" 64))))
                (send-event
                 (lem-core::make-routed-input-event
                  connection
                  (lambda () (activate-implementation implementation))
                  key))
                (send-event
                 (lambda () (redraw-other-sessions implementation))))))
           (response-ok connection id "accepted")))
        ((string= type "resize")
         (let ((implementation (or (connection-implementation connection)
                                   (error "Connection has no attached frame")))
               (width (require-integer message "width" 20 1000))
               (height (require-integer message "height" 5 1000)))
           (send-event
            (lambda ()
              (with-implementation implementation
                (setf (daemon-implementation-width implementation) width
                      (daemon-implementation-height implementation) height)
                (lem-core::adjust-all-window-size)
                (redraw-display :force t))))
           (response-ok connection id "accepted")))
        ((string= type "redisplay")
         (let ((implementation (or (connection-implementation connection)
                                   (error "Connection has no attached frame"))))
           (send-event (lambda ()
                         (with-implementation implementation
                           (redraw-display :force t))))
           (response-ok connection id "accepted")))
        ((string= type "detach")
         (send-event (lambda () (detach-connection-frame-on-editor connection)))
         (response-ok connection id "detached"))
        ((string= type "cancel")
         (let* ((target (protocol:field message "request"))
                (request (find-request connection target)))
           (if request
               (progn
                 (setf (daemon-request-cancelled-p request) t)
                 (send-event (lambda ()
                               (complete-request request "cancelled"
                                                 "Request cancelled")))
                 (response-ok connection id "cancelled"))
               (response-error connection id "not-found" "Request not found"))))
        ((string= type "shutdown")
         (let ((force (bool-field message "force")))
           (send-event
            (lambda ()
              (let ((modified (modified-buffers)))
                (if (and modified (not force))
                    (response-error
                     connection id "modified-buffers"
                     (format nil "Modified buffers exist: ~{~a~^, ~}"
                             (mapcar #'buffer-name modified)))
                    (progn
                      (response-ok connection id "stopping")
                      (exit-editor))))))))
        (t (response-error connection id "unknown-request"
                           (format nil "Unknown request type: ~a" type)))))))

(defun cancel-connection-requests-on-editor (connection)
  (dolist (request (bt2:with-lock-held (*daemon-lock*)
                     (remove-if-not
                      (lambda (request)
                        (eq connection (daemon-request-connection request)))
                      (copy-list *daemon-requests*))))
    (setf (daemon-request-cancelled-p request) t)
    (complete-request request "disconnected" "Client disconnected")))

(defun close-connection (connection)
  (unless (connection-closed-p connection)
    (setf (connection-closed-p connection) t))
  (ignore-errors (close (connection-stream connection) :abort t))
  (ignore-errors (sb-bsd-sockets:socket-close (connection-socket connection)))
  (bt2:with-lock-held (*daemon-lock*)
    (setf *daemon-connections*
          (delete connection *daemon-connections* :test #'eq)))
  (when lem-core::*in-the-editor*
    (send-event (lambda ()
                  (cancel-connection-requests-on-editor connection)
                  (detach-connection-frame-on-editor connection)
                  (lem-core::cancel-routed-input-session connection)))))

#+sbcl
(progn
  (sb-alien:define-alien-type linux-ucred
      (sb-alien:struct linux-ucred (pid sb-alien:int)
                                   (uid sb-alien:unsigned-int)
                                   (gid sb-alien:unsigned-int)))
  (sb-alien:define-alien-routine ("getsockopt" %getsockopt-ucred) sb-alien:int
    (fd sb-alien:int)
    (level sb-alien:int)
    (option sb-alien:int)
    (value (* linux-ucred))
    (length (* sb-alien:unsigned-int))))

(defun peer-user-id (socket)
  #+(and sbcl linux)
  (sb-alien:with-alien ((credential linux-ucred)
                        (length sb-alien:unsigned-int
                                (sb-alien:alien-size linux-ucred :bytes)))
    (when (zerop (%getsockopt-ucred
                  (sb-bsd-sockets:socket-file-descriptor socket)
                  1 17 (sb-alien:addr credential) (sb-alien:addr length)))
      (sb-alien:slot credential 'uid)))
  #-(and sbcl linux)
  (declare (ignore socket))
  #-(and sbcl linux) nil)

(defun validate-peer (socket)
  #+(and sbcl linux)
  (let ((uid (peer-user-id socket)))
    (unless (and uid (= uid (sb-posix:getuid)))
      (error "Refusing local client whose user identity could not be verified")))
  #-(and sbcl linux)
  (declare (ignore socket)))

(defun serve-connection (socket)
  (let ((connection nil))
    (unwind-protect
         (handler-case
             (progn
               (validate-peer socket)
               (let ((stream (sb-bsd-sockets:socket-make-stream
                              socket :input t :output t
                              :element-type '(unsigned-byte 8)
                              :buffering :none)))
                 (setf connection (make-instance 'daemon-connection
                                                 :socket socket :stream stream))
                 (bt2:with-lock-held (*daemon-lock*)
                   (push connection *daemon-connections*))
                 (loop :for message := (protocol:read-message stream)
                       :while message
                       :do (handler-case (handle-message connection message)
                             (error (condition)
                               (response-error connection
                                               (protocol:field message "id")
                                               "invalid-request"
                                               (princ-to-string condition)))))))
           (error () nil))
      (if connection
          (close-connection connection)
          (ignore-errors (sb-bsd-sockets:socket-close socket))))))

(defun accept-loop (socket)
  (loop :while *daemon-running-p*
        :do (handler-case
                (let ((client (sb-bsd-sockets:socket-accept socket)))
                  (if (bt2:with-lock-held (*daemon-lock*)
                        (< (length *daemon-connections*) +connection-limit+))
                      (bt2:make-thread (lambda () (serve-connection client))
                                       :name "Lem daemon client")
                      (sb-bsd-sockets:socket-close client)))
              (sb-bsd-sockets:socket-error ()
                (unless *daemon-running-p* (return)))
              (error ()
                (unless *daemon-running-p* (return))))))

(defun stat-path (pathname)
  (handler-case (sb-posix:lstat (uiop:native-namestring pathname))
    (sb-posix:syscall-error () nil)))

(defun stat-kind-p (stat kind)
  (and stat (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt) kind)))

(defun ensure-private-runtime-directory (endpoint)
  (let ((directory (uiop:pathname-directory-pathname endpoint)))
    (ensure-directories-exist endpoint)
    (let ((stat (stat-path directory)))
      (unless (and (stat-kind-p stat sb-posix:s-ifdir)
                   (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
        (error "Daemon runtime directory is not a user-owned directory: ~a"
               directory))
      (sb-posix:chmod (uiop:native-namestring directory) #o700)
      (unless (zerop (logand (sb-posix:stat-mode (stat-path directory)) #o077))
        (error "Daemon runtime directory is not private: ~a" directory)))))

(defun socket-live-p (pathname)
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (handler-case
             (progn
               (sb-bsd-sockets:socket-connect
                socket (uiop:native-namestring pathname))
               t)
           (sb-bsd-sockets:socket-error () nil))
      (ignore-errors (sb-bsd-sockets:socket-close socket)))))

(defun prepare-endpoint (endpoint)
  (ensure-private-runtime-directory endpoint)
  (let* ((stat (stat-path endpoint))
         (identity (and stat (cons (sb-posix:stat-dev stat)
                                   (sb-posix:stat-ino stat)))))
    (when stat
      (unless (and (stat-kind-p stat sb-posix:s-ifsock)
                   (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
        (error "Refusing unsafe existing daemon endpoint: ~a" endpoint))
      (when (socket-live-p endpoint)
        (error "A daemon is already running at ~a" endpoint))
      (delete-owned-path endpoint identity sb-posix:s-ifsock))))

(defun path-identity (pathname)
  (alexandria:when-let ((stat (stat-path pathname)))
    (cons (sb-posix:stat-dev stat) (sb-posix:stat-ino stat))))

(defun delete-owned-path (pathname identity expected-kind)
  (when (and pathname identity)
    (let ((stat (stat-path pathname)))
      (when (and (stat-kind-p stat expected-kind)
                 (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                 (equal identity (cons (sb-posix:stat-dev stat)
                                       (sb-posix:stat-ino stat))))
        (sb-posix:unlink (uiop:native-namestring pathname))))))

(defun write-metadata (pathname endpoint)
  (with-open-file (stream pathname :direction :output :if-exists :error
                                   :if-does-not-exist :create)
    (yason:encode
     (protocol:make-object "version" protocol:+protocol-version+
                           "pid" (sb-posix:getpid)
                           "name" *daemon-name*
                           "endpoint" (uiop:native-namestring endpoint))
     stream))
  (sb-posix:chmod (uiop:native-namestring pathname) #o600)
  (path-identity pathname))

(defun start-daemon-transport ()
  (let* ((endpoint (protocol:endpoint-pathname *daemon-name*))
         (metadata (protocol:metadata-pathname *daemon-name*))
         (native (uiop:native-namestring endpoint)))
    (when (> (length (sb-ext:string-to-octets native :external-format :utf-8)) 100)
      (error "Daemon endpoint path is too long: ~a" endpoint))
    (prepare-endpoint endpoint)
    (when (stat-path metadata)
      (let* ((stat (stat-path metadata))
             (identity (and stat (cons (sb-posix:stat-dev stat)
                                       (sb-posix:stat-ino stat)))))
        (unless (and (stat-kind-p stat sb-posix:s-ifreg)
                     (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
          (error "Refusing unsafe daemon metadata: ~a" metadata))
        (delete-owned-path metadata identity sb-posix:s-ifreg)))
    (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (handler-case
          (progn
            (sb-bsd-sockets:socket-bind socket native)
            (sb-posix:chmod native #o600)
            (sb-bsd-sockets:socket-listen socket 64)
            (setf *daemon-socket* socket
                  *daemon-endpoint* endpoint
                  *daemon-metadata* metadata
                  *daemon-endpoint-identity* (path-identity endpoint)
                  *daemon-running-p* t)
            (setf *daemon-metadata-identity*
                  (write-metadata metadata endpoint))
            (setf *daemon-accept-thread*
                  (bt2:make-thread
                   (lambda ()
                     (handler-case (accept-loop socket)
                       (stop-accept-loop () nil)))
                                   :name "Lem daemon accept")))
        (error (condition)
          (ignore-errors (sb-bsd-sockets:socket-close socket))
          (delete-owned-path endpoint (path-identity endpoint) sb-posix:s-ifsock)
          (error condition))))))

(defun stop-daemon-transport ()
  (setf *daemon-running-p* nil)
  (when *daemon-socket*
    (ignore-errors (sb-bsd-sockets:socket-close *daemon-socket*)))
  (dolist (connection (bt2:with-lock-held (*daemon-lock*)
                        (copy-list *daemon-connections*)))
    (close-connection connection))
  (when (and *daemon-accept-thread*
             (not (eq *daemon-accept-thread* (bt2:current-thread))))
    (when (bt2:thread-alive-p *daemon-accept-thread*)
      (ignore-errors
        (bt2:interrupt-thread
         *daemon-accept-thread*
         (lambda () (error 'stop-accept-loop)))))
    (ignore-errors (bt2:join-thread *daemon-accept-thread*)))
  (delete-owned-path *daemon-endpoint* *daemon-endpoint-identity*
                     sb-posix:s-ifsock)
  (delete-owned-path *daemon-metadata* *daemon-metadata-identity*
                     sb-posix:s-ifreg)
  (setf *daemon-socket* nil *daemon-endpoint* nil *daemon-metadata* nil
        *daemon-endpoint-identity* nil *daemon-metadata-identity* nil
        *daemon-accept-thread* nil
        *daemon-connections* '() *daemon-requests* '()))

(defun stop-daemon (&key force)
  (if (and (modified-buffers) (not force))
      (error "Modified buffers prevent daemon shutdown")
      (exit-editor)))

(defun invoke-daemon (function &optional (name "server"))
  (unless (protocol:valid-server-name-p name)
    (error "Unsafe daemon name: ~s" name))
  (let* ((*daemon-name* name)
         (implementation (make-instance 'daemon-implementation)))
    (setf *daemon-root-implementation* implementation)
    (unwind-protect
         (lem-core::invoke-frontend function :implementation implementation)
      (setf *daemon-root-implementation* nil))))
