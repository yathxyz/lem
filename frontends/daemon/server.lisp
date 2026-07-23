(in-package :lem-daemon)

(defparameter +connection-limit+ 64)
(defparameter +capabilities+
  #("visit" "eval" "attach" "input" "redisplay" "resize" "detach"
    "shutdown" "cancel"))

(defvar *daemon-name* "server")
(defvar *daemon-listener* nil)
(defvar *daemon-endpoint* nil)
(defvar *daemon-accept-thread* nil)
(defvar *daemon-running-p* nil)
(defvar *daemon-root-implementation* nil)
(defvar *daemon-connections* '())
(defvar *daemon-requests* '())
(defvar *daemon-lock* (bt2:make-lock :name "lem-daemon/state"))

(define-condition stop-accept-loop (condition) ())

(defclass daemon-connection ()
  ((transport :initarg :transport :reader connection-transport)
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
(define-key *daemon-edit-mode-keymap* "Z Z" 'daemon-edit-save-and-done)
(define-key *daemon-edit-mode-keymap* "Z Q" 'daemon-edit-abort)

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

(defun restore-request-origin (request)
  (let ((origin (daemon-request-origin-buffer request)))
    (when (live-buffer-p origin)
      (switch-to-buffer origin))))

(defun complete-buffer-requests (buffer abort-p)
  (let ((requests (request-buffer-list buffer)))
    (dolist (request requests)
      (if abort-p
          (progn
            (complete-request request "aborted" "File request aborted")
            (restore-request-origin request))
          (progn
            (setf (daemon-request-buffers request)
                  (delete buffer (daemon-request-buffers request) :test #'eq))
            (setf (request-buffer-list buffer)
                  (delete request (request-buffer-list buffer) :test #'eq))
            (if (daemon-request-buffers request)
                (switch-to-buffer (first (daemon-request-buffers request)))
                (progn
                  (complete-request request "ok" "finished")
                  (restore-request-origin request))))))
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
  (let ((restore (if (get-frame active)
                     active
                     *daemon-root-implementation*)))
    (unwind-protect
         (dolist (connection (bt2:with-lock-held (*daemon-lock*)
                               (copy-list *daemon-connections*)))
           (let ((implementation (connection-implementation connection)))
             (when (and implementation (not (eq implementation active))
                        (get-frame implementation))
               (activate-implementation implementation)
               (redraw-display :force t))))
      (activate-implementation restore))))

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

(defmethod lem-if:close-frontend ((implementation daemon-implementation))
  (alexandria:when-let
      ((connection (daemon-implementation-connection implementation)))
    (daemon-send connection
                 (protocol:make-object
                  "version" protocol:+protocol-version+
                  "type" "close" "reason" "client-request"))
    (detach-connection-frame-on-editor connection)
    t))

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
  (transport:close-local-connection (connection-transport connection))
  (bt2:with-lock-held (*daemon-lock*)
    (setf *daemon-connections*
          (delete connection *daemon-connections* :test #'eq)))
  (when lem-core::*in-the-editor*
    (send-event (lambda ()
                  (cancel-connection-requests-on-editor connection)
                  (detach-connection-frame-on-editor connection)
                  (lem-core::cancel-routed-input-session connection)))))

(defun serve-connection (local-connection)
  (let ((connection nil))
    (unwind-protect
         (handler-case
             (let ((stream
                     (transport:local-connection-stream local-connection)))
               (setf connection (make-instance 'daemon-connection
                                               :transport local-connection
                                               :stream stream))
               (bt2:with-lock-held (*daemon-lock*)
                 (push connection *daemon-connections*))
               (loop :for message := (protocol:read-message stream)
                     :while message
                     :do (handler-case (handle-message connection message)
                           (error (condition)
                             (response-error connection
                                             (protocol:field message "id")
                                             "invalid-request"
                                             (princ-to-string condition))))))
           (error () nil))
      (if connection
          (close-connection connection)
          (transport:close-local-connection local-connection)))))

(defun accept-loop (listener)
  (loop :while *daemon-running-p*
        :do (handler-case
                (let ((client (transport:accept-local-connection listener)))
                  (if (bt2:with-lock-held (*daemon-lock*)
                        (< (length *daemon-connections*) +connection-limit+))
                      (bt2:make-thread (lambda () (serve-connection client))
                                       :name "Lem daemon client")
                      (transport:close-local-connection client)))
              (error ()
                (unless *daemon-running-p* (return))))))

(defun configure-editor-environment ()
  (let ((command (format nil "lemclient --server-name ~a" *daemon-name*)))
    (dolist (variable '("GIT_EDITOR" "VISUAL" "EDITOR"))
      (unless (uiop:getenv variable)
        (setf (uiop:getenv variable) command)))))

(defun start-daemon-transport ()
  (let* ((backend (transport:require-local-backend))
         (listener (transport:open-local-listener
                    backend *daemon-name* +connection-limit+)))
    (setf *daemon-listener* listener
          *daemon-endpoint* (transport:local-listener-endpoint listener)
          *daemon-running-p* t
          *daemon-accept-thread*
          (bt2:make-thread
           (lambda ()
             (handler-case (accept-loop listener)
               (stop-accept-loop () nil)))
           :name "Lem daemon accept"))
    (configure-editor-environment)))

(defun stop-daemon-transport ()
  (setf *daemon-running-p* nil)
  (when *daemon-listener*
    (transport:close-local-listener *daemon-listener*))
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
  (setf *daemon-listener* nil *daemon-endpoint* nil *daemon-accept-thread* nil
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
