;;;; Emacsclient-style file requests for the persistent ncurses editor.
;;;
;;;; Lem's bundled server is a distinct browser frontend.  This module instead
;;;; keeps the configured ncurses process authoritative and accepts bounded,
;;;; owner-only local file requests from the packaged lemclient executable.

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-bsd-sockets)
  #+sbcl (require :sb-posix))

(in-package :lem-yath)

(defparameter *server-protocol-magic* "LEM-YATH-1")
(defparameter *server-field-byte-limit* 4096)
(defparameter *server-file-limit* 64)
(defparameter *server-connection-limit* 64)
(defparameter *server-socket-byte-limit* 100)

(defvar *server-socket* nil)
(defvar *server-socket-pathname* nil)
(defvar *server-pane-pathname* nil)
(defvar *server-accept-thread* nil)
(defvar *server-running-p* nil)
(defvar *server-connections* '())
(defvar *server-requests* '())
(defvar *server-lock* (bt2:make-lock :name "lem-yath/server"))

(defstruct server-location
  pathname
  line
  column)

(defstruct (server-request
            (:constructor %make-server-request (wait-p locations)))
  wait-p
  locations
  origin-buffer
  (buffers '())
  (opened-p nil)
  result
  error
  (lock (bt2:make-lock :name "lem-yath/server-request")))

(defvar *lem-yath-server-edit-mode-keymap*
  (make-keymap :description "lem-yath server edit"))

(define-minor-mode lem-yath-server-edit-mode
    (:name "Server"
     :keymap *lem-yath-server-edit-mode-keymap*))

(defun server-client-pathname ()
  (alexandria:if-let ((override (uiop:getenv "LEM_YATH_CLIENT")))
    (uiop:parse-native-namestring override)
    (executable-find "lemclient")))

(defun server-runtime-directory ()
  (alexandria:if-let ((runtime (uiop:getenv "XDG_RUNTIME_DIR")))
    (merge-pathnames "lem-yath/" (uiop:ensure-directory-pathname runtime))
    (merge-pathnames
     "lem-yath/runtime/"
     (uiop:ensure-directory-pathname
      (or (uiop:getenv "XDG_CACHE_HOME")
          (merge-pathnames ".cache/" (user-homedir-pathname)))))))

(defun server-configured-socket-pathname ()
  (alexandria:if-let ((override (uiop:getenv "LEM_YATH_SERVER_SOCKET")))
    (uiop:parse-native-namestring override)
    (merge-pathnames "server.sock" (server-runtime-directory))))

(defun server-configured-pane-pathname (socket-pathname)
  (alexandria:if-let ((override (uiop:getenv "LEM_YATH_SERVER_PANE_FILE")))
    (uiop:parse-native-namestring override)
    (uiop:parse-native-namestring
     (concatenate 'string (uiop:native-namestring socket-pathname) ".pane"))))

(defun server-stat-if-present (pathname)
  #+sbcl
  (handler-case
      (sb-posix:lstat (uiop:native-namestring pathname))
    (sb-posix:syscall-error () nil))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl nil)

(defun server-owned-private-directory-p (pathname)
  #+sbcl
  (let* ((stat (server-stat-if-present pathname))
         (mode (and stat (sb-posix:stat-mode stat))))
    (and stat
         (= (sb-posix:stat-uid stat) (sb-posix:getuid))
         (= (logand mode sb-posix:s-ifmt) sb-posix:s-ifdir)
         (zerop (logand mode #o077))))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl nil)

(defun server-ensure-private-directory (socket-pathname)
  (unless (uiop:absolute-pathname-p socket-pathname)
    (error "Server socket path must be absolute: ~a" socket-pathname))
  (let ((directory (uiop:pathname-directory-pathname socket-pathname)))
    (ensure-directories-exist socket-pathname)
    #+sbcl
    (progn
      (let ((stat (server-stat-if-present directory)))
        (unless (and stat
                     (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                     (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                        sb-posix:s-ifdir))
          (error "Server directory must be a user-owned real directory: ~a"
                 directory)))
      (sb-posix:chmod (uiop:native-namestring directory) #o700)
      (unless (server-owned-private-directory-p directory)
        (error "Server directory is not private mode 0700: ~a" directory)))
    #-sbcl
    (error "The local editor server requires the supported SBCL runtime")
    directory))

(defun server-socket-pathname-valid-p (pathname)
  #+sbcl
  (let ((stat (server-stat-if-present pathname)))
    (and stat
         (= (sb-posix:stat-uid stat) (sb-posix:getuid))
         (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
            sb-posix:s-ifsock)))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl nil)

(defun server-delete-owned-path (pathname expected-type)
  #+sbcl
  (when pathname
    (let ((stat (server-stat-if-present pathname)))
      (when (and stat
                 (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                 (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                    expected-type))
        (sb-posix:unlink (uiop:native-namestring pathname)))))
  #-sbcl
  (declare (ignore pathname expected-type)))

(defun server-socket-live-p (pathname)
  #+sbcl
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (handler-case
             (progn
               (sb-bsd-sockets:socket-connect
                socket (uiop:native-namestring pathname))
               t)
           (sb-bsd-sockets:socket-error () nil))
      (ignore-errors (sb-bsd-sockets:socket-close socket))))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl nil)

(defun server-tmux-pane-p (pane)
  (and (stringp pane)
       (< 1 (length pane))
       (char= (char pane 0) #\%)
       (every #'digit-char-p (subseq pane 1))))

(defun server-tmux-server-id (tmux)
  (when (and (stringp tmux)
             (<= (length tmux) *server-field-byte-limit*)
             (notany (lambda (character)
                       (member character '(#\Newline #\Return #\Null)))
                     tmux))
    (alexandria:when-let ((separator (position #\, tmux :from-end t)))
      (when (plusp separator)
        (subseq tmux 0 separator)))))

(defun server-write-private-file (pathname text)
  #+sbcl
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring pathname)
                  (logior sb-posix:o-creat sb-posix:o-trunc
                          sb-posix:o-wronly sb-posix:o-nofollow)
                  #o600))
           (sb-posix:fchmod descriptor #o600)
           (let ((stat (sb-posix:fstat descriptor)))
             (unless (and (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                          (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                             sb-posix:s-ifreg))
               (error "Server metadata is not a user-owned regular file")))
           (setf stream
                 (sb-sys:make-fd-stream
                  descriptor :output t :element-type '(unsigned-byte 8)
                  :buffering :full
                  :name (uiop:native-namestring pathname))
                 descriptor nil)
           (write-sequence
            (sb-ext:string-to-octets text :external-format :utf-8) stream)
           (finish-output stream)
           (close stream)
           (setf stream nil))
      (when stream (ignore-errors (close stream :abort t)))
      (when descriptor (ignore-errors (sb-posix:close descriptor)))))
  #-sbcl
  (declare (ignore pathname text)))

(defun server-publish-pane (socket-pathname)
  (let ((pathname (server-configured-pane-pathname socket-pathname))
        (pane (uiop:getenv "TMUX_PANE"))
        (server-id (server-tmux-server-id (uiop:getenv "TMUX"))))
    (when (and (server-tmux-pane-p pane) server-id)
      (server-write-private-file pathname
                                 (format nil "~a~%~a~%" server-id pane))
      (setf *server-pane-pathname* pathname))))

(defun server-read-field (stream &optional (limit *server-field-byte-limit*))
  #+sbcl
  (let ((octets (make-array 64
                            :element-type '(unsigned-byte 8)
                            :adjustable t
                            :fill-pointer 0)))
    (loop
      :for byte := (read-byte stream nil :eof)
      :do
         (when (eq byte :eof)
           (error "Unexpected end of server request"))
         (when (zerop byte)
           (return
             (sb-ext:octets-to-string octets :external-format :utf-8)))
         (when (>= (length octets) limit)
           (error "Server request field exceeds ~d bytes" limit))
         (vector-push-extend byte octets)))
  #-sbcl
  (declare (ignore stream limit))
  #-sbcl
  (error "The local editor server requires SBCL"))

(defun server-read-bounded-integer (stream minimum maximum label)
  (let ((field (server-read-field stream 32)))
    (handler-case
        (let ((value (parse-integer field :junk-allowed nil)))
          (unless (<= minimum value maximum)
            (error "~a is outside the supported range" label))
          value)
      (error ()
        (error "Invalid ~a in server request" label)))))

(defun server-read-request (stream)
  (unless (string= (server-read-field stream 32) *server-protocol-magic*)
    (error "Unsupported server protocol"))
  (let* ((mode (server-read-field stream 16))
         (wait-p (cond ((string= mode "wait") t)
                       ((string= mode "nowait") nil)
                       (t (error "Unsupported server wait mode"))))
         (count (server-read-bounded-integer
                 stream 0 *server-file-limit* "file count"))
         (locations
           (loop :repeat count
                 :collect
                 (make-server-location
                  :line (server-read-bounded-integer
                         stream 1 most-positive-fixnum "line")
                  :column (server-read-bounded-integer
                           stream 0 most-positive-fixnum "column")
                  :pathname (server-read-field stream)))))
    (%make-server-request wait-p locations)))

(defun server-response-line (stream control &rest arguments)
  #+sbcl
  (let* ((text (apply #'format nil control arguments))
         (line (substitute #\Space #\Return
                           (substitute #\Space #\Newline text))))
    (write-sequence
     (sb-ext:string-to-octets
      (concatenate 'string line (string #\Newline))
      :external-format :utf-8)
     stream)
    (finish-output stream))
  #-sbcl
  (declare (ignore stream control arguments)))

(defun server-request-snapshot (request)
  (bt2:with-lock-held ((server-request-lock request))
    (values (server-request-opened-p request)
            (server-request-result request)
            (server-request-error request))))

(defun server-mark-request-opened (request)
  (bt2:with-lock-held ((server-request-lock request))
    (setf (server-request-opened-p request) t)
    (unless (server-request-wait-p request)
      (setf (server-request-result request) :done))))

(defun server-finish-request (request result &optional error)
  (bt2:with-lock-held ((server-request-lock request))
    (unless (server-request-result request)
      (setf (server-request-result request) result
            (server-request-error request) error))))

(defun server-register-request (request)
  (bt2:with-lock-held (*server-lock*)
    (push request *server-requests*)))

(defun server-unregister-request (request)
  (bt2:with-lock-held (*server-lock*)
    (setf *server-requests* (delete request *server-requests* :test #'eq))))

(defun server-register-connection (socket)
  (bt2:with-lock-held (*server-lock*)
    (when (< (length *server-connections*) *server-connection-limit*)
      (push socket *server-connections*)
      t)))

(defun server-unregister-connection (socket)
  (bt2:with-lock-held (*server-lock*)
    (setf *server-connections*
          (delete socket *server-connections* :test #'eq))))

(defun server-wait-for-request (request stream)
  (let ((announced-p nil))
    (loop
      (multiple-value-bind (opened-p result error)
          (server-request-snapshot request)
        (when (and opened-p (not announced-p))
          (server-response-line stream "OPENED")
          (setf announced-p t))
        (when result
          (case result
            (:done (server-response-line stream "DONE"))
            (:abort (server-response-line stream "ABORT"))
            (:error (server-response-line stream "ERROR ~a"
                                          (or error "Editor server stopped"))))
          (return)))
      (sleep 0.05))))

(defun server-handle-connection (socket)
  #+sbcl
  (let ((stream nil)
        (request nil))
    (unwind-protect
         (handler-case
             (progn
               (setf stream
                     (sb-bsd-sockets:socket-make-stream
                      socket :input t :output t
                      :element-type '(unsigned-byte 8)
                      :buffering :none))
               (setf request (server-read-request stream))
               (server-register-request request)
               (send-event (lambda () (server-open-request request)))
               (server-wait-for-request request stream))
           (error (condition)
             (when request
               (server-finish-request request :error
                                      (princ-to-string condition)))
             (when stream
               (ignore-errors
                 (server-response-line stream "ERROR ~a" condition)))))
      (when request (server-unregister-request request))
      (when stream (ignore-errors (close stream :abort t)))
      (server-unregister-connection socket)
      (ignore-errors (sb-bsd-sockets:socket-close socket))))
  #-sbcl
  (declare (ignore socket)))

(defun server-accept-loop (listen-socket)
  #+sbcl
  (loop
    (unless *server-running-p* (return))
    (handler-case
        (let ((socket (sb-bsd-sockets:socket-accept listen-socket)))
          (if (server-register-connection socket)
              (handler-case
                  (bt2:make-thread
                   (lambda () (server-handle-connection socket))
                   :name "lem-yath server client")
                (error ()
                  (server-unregister-connection socket)
                  (ignore-errors
                    (sb-bsd-sockets:socket-close socket))))
              (ignore-errors (sb-bsd-sockets:socket-close socket))))
      (sb-bsd-sockets:socket-error ()
        (unless *server-running-p* (return)))
      (error ()
        (unless *server-running-p* (return)))))
  #-sbcl
  (declare (ignore listen-socket)))

(defun server-buffer-requests (&optional (buffer (current-buffer)))
  (copy-list (buffer-value buffer 'lem-yath-server-requests)))

(defun (setf server-buffer-requests) (requests
                                      &optional (buffer (current-buffer)))
  (setf (buffer-value buffer 'lem-yath-server-requests) requests))

(defun server-buffer-live-p (buffer)
  (and (bufferp buffer) (not (deleted-buffer-p buffer))))

(defun server-disable-buffer-mode (buffer)
  (when (and (server-buffer-live-p buffer)
             (mode-active-p buffer 'lem-yath-server-edit-mode))
    (with-current-buffer buffer
      (lem-yath-server-edit-mode nil))))

(defun server-attach-request (request buffer)
  (setf (server-buffer-requests buffer)
        (adjoin request (server-buffer-requests buffer) :test #'eq))
  (with-current-buffer buffer
    (lem-yath-server-edit-mode t)))

(defun server-detach-request (request)
  (dolist (buffer (copy-list (server-request-buffers request)))
    (when (server-buffer-live-p buffer)
      (setf (server-buffer-requests buffer)
            (delete request (server-buffer-requests buffer) :test #'eq))
      (unless (server-buffer-requests buffer)
        (server-disable-buffer-mode buffer))))
  (setf (server-request-buffers request) '()))

(defun server-resolve-location-pathname (location)
  (let ((pathname
          (uiop:parse-native-namestring
           (server-location-pathname location))))
    (unless (uiop:absolute-pathname-p pathname)
      (error "Client file path is not absolute: ~a" pathname))
    pathname))

(defun server-open-location (location)
  (let* ((pathname (server-resolve-location-pathname location))
         (buffer (find-file-buffer pathname)))
    (unless (bufferp buffer)
      (error "Could not open ~a" pathname))
    buffer))

(defun server-position-location (location buffer)
  (when (eq buffer (current-buffer))
    (move-to-line (current-point) (server-location-line location))
    (move-to-column (current-point) (server-location-column location))))

(defun server-open-request (request)
  "Open REQUEST on the editor thread and publish its first visible buffer."
  (handler-case
      (let* ((origin (current-buffer))
             (locations (server-request-locations request))
             (buffers
               (if locations
                   (remove-duplicates
                    (mapcar #'server-open-location locations)
                    :test #'eq)
                   (list origin))))
        (setf (server-request-origin-buffer request) origin
              (server-request-buffers request) buffers)
        (when (server-request-wait-p request)
          (dolist (buffer buffers)
            (server-attach-request request buffer)))
        (let ((first (first buffers)))
          (when (server-buffer-live-p first)
            (switch-to-buffer first)
            (alexandria:when-let ((location (first locations)))
              (server-position-location location first))))
        (server-mark-request-opened request)
        (redraw-display))
    (error (condition)
      (server-detach-request request)
      (server-finish-request request :error (princ-to-string condition)))))

(defun server-request-next-buffer (requests)
  (loop :for request :in requests
        :thereis (find-if #'server-buffer-live-p
                          (server-request-buffers request))))

(defun server-request-origin (requests)
  (loop :for request :in requests
        :for buffer := (server-request-origin-buffer request)
        :when (server-buffer-live-p buffer)
          :return buffer))

(defun server-complete-buffer (buffer &key navigate)
  (let* ((requests (server-buffer-requests buffer))
         (origin (server-request-origin requests)))
    (setf (server-buffer-requests buffer) '())
    (server-disable-buffer-mode buffer)
    (dolist (request requests)
      (setf (server-request-buffers request)
            (delete buffer (server-request-buffers request) :test #'eq))
      (unless (server-request-buffers request)
        (server-finish-request request :done)))
    (when navigate
      (let ((next (or (server-request-next-buffer requests) origin)))
        (when (and (server-buffer-live-p next)
                   (not (eq next buffer)))
          (switch-to-buffer next))))
    requests))

(defun server-abort-buffer (buffer)
  (let* ((requests (server-buffer-requests buffer))
         (origin (server-request-origin requests)))
    (dolist (request requests)
      (server-detach-request request)
      (server-finish-request request :abort))
    (when (and (server-buffer-live-p origin) (not (eq origin buffer)))
      (switch-to-buffer origin))
    requests))

(define-command lem-yath-server-edit-done () ()
  "Finish the current client request once its buffer is saved."
  (unless (server-buffer-requests)
    (editor-error "This buffer has no waiting lemclient"))
  (when (buffer-modified-p (current-buffer))
    (editor-error "Save this buffer first, or use ZQ/C-c C-k to abort"))
  (server-complete-buffer (current-buffer) :navigate t)
  (message "lemclient request finished"))

(define-command lem-yath-server-save-done () ()
  "Save the current client buffer and finish its request."
  (unless (server-buffer-requests)
    (editor-error "This buffer has no waiting lemclient"))
  (lem-core/commands/file:save-current-buffer)
  (when (buffer-modified-p (current-buffer))
    (editor-error "The client buffer remains modified after saving"))
  (server-complete-buffer (current-buffer) :navigate t)
  (message "Saved; lemclient request finished"))

(define-command lem-yath-server-abort () ()
  "Abort every client request waiting on the current buffer."
  (unless (server-buffer-requests)
    (editor-error "This buffer has no waiting lemclient"))
  (server-abort-buffer (current-buffer))
  (message "lemclient request aborted"))

(define-key *lem-yath-server-edit-mode-keymap* "C-x #"
  'lem-yath-server-edit-done)
(define-key *lem-yath-server-edit-mode-keymap* "C-c C-c"
  'lem-yath-server-save-done)
(define-key *lem-yath-server-edit-mode-keymap* "C-c C-k"
  'lem-yath-server-abort)
(define-key *lem-yath-server-edit-mode-keymap* "Z Z"
  'lem-yath-server-save-done)
(define-key *lem-yath-server-edit-mode-keymap* "Z Q"
  'lem-yath-server-abort)

(defun server-kill-buffer-hook (buffer)
  (when (server-buffer-requests buffer)
    (server-complete-buffer buffer :navigate nil)))

(defun server-configure-editor-environment (client)
  (let ((command (uiop:native-namestring client)))
    ;; Git processes started by this Lem are already in the editor's tmux pane.
    ;; Avoid pane handoff and, more importantly, avoid lemclient's deliberate
    ;; alternate-editor fallback if transient pane metadata cannot be validated.
    (setf (uiop:getenv "GIT_EDITOR")
          (format nil "~a --no-focus" (uiop:escape-shell-token command)))
    (unless (uiop:getenv "VISUAL")
      (setf (uiop:getenv "VISUAL") command))
    (unless (uiop:getenv "EDITOR")
      (setf (uiop:getenv "EDITOR") command))))

(defun server-start ()
  "Start the private local editor server, or reuse an already live one."
  #+sbcl
  (let* ((pathname (server-configured-socket-pathname))
         (native (uiop:native-namestring pathname))
         (octets (sb-ext:string-to-octets native :external-format :utf-8)))
    (when (> (length octets) *server-socket-byte-limit*)
      (error "Server socket path is too long: ~a" pathname))
    (server-ensure-private-directory pathname)
    (let ((existing (server-stat-if-present pathname)))
      (when existing
        (unless (server-socket-pathname-valid-p pathname)
          (error "Refusing non-socket server path: ~a" pathname))
        (if (server-socket-live-p pathname)
            (return-from server-start :existing)
            (server-delete-owned-path pathname sb-posix:s-ifsock))))
    (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (handler-case
          (progn
            (sb-bsd-sockets:socket-bind socket native)
            (sb-posix:chmod native #o600)
            (sb-bsd-sockets:socket-listen socket 16)
            (setf *server-socket* socket
                  *server-socket-pathname* pathname
                  *server-running-p* t)
            (server-publish-pane pathname)
            (setf *server-accept-thread*
                  (bt2:make-thread
                   (lambda () (server-accept-loop socket))
                   :name "lem-yath server accept"))
            :started)
        (error (condition)
          (setf *server-running-p* nil)
          (ignore-errors (sb-bsd-sockets:socket-close socket))
          (server-delete-owned-path pathname sb-posix:s-ifsock)
          (server-delete-owned-path *server-pane-pathname*
                                    sb-posix:s-ifreg)
          (setf *server-socket* nil
                *server-socket-pathname* nil
                *server-pane-pathname* nil
                *server-accept-thread* nil)
          (error condition)))))
  #-sbcl
  (error "The local editor server requires the supported SBCL runtime"))

(defun server-shutdown (&optional (reason "Editor exited"))
  (let (connections requests)
    (setf *server-running-p* nil)
    (bt2:with-lock-held (*server-lock*)
      (setf connections (copy-list *server-connections*)
            requests (copy-list *server-requests*)))
    (dolist (request requests)
      (server-detach-request request)
      (server-finish-request request :error reason))
    #+sbcl
    (progn
      (when *server-socket*
        (ignore-errors (sb-bsd-sockets:socket-close *server-socket*)))
      (dolist (socket connections)
        (ignore-errors (sb-bsd-sockets:socket-close socket)))
      (when (and *server-accept-thread*
                 (bt2:thread-alive-p *server-accept-thread*))
        (ignore-errors (bt2:destroy-thread *server-accept-thread*)))
      (server-delete-owned-path *server-socket-pathname* sb-posix:s-ifsock)
      (server-delete-owned-path *server-pane-pathname* sb-posix:s-ifreg))
    (setf *server-socket* nil
          *server-socket-pathname* nil
          *server-pane-pathname* nil
          *server-accept-thread* nil
          *server-connections* '()
          *server-requests* '())))

(defun server-start-maybe ()
  (alexandria:when-let ((client (server-client-pathname)))
    (handler-case
        (progn
          (server-start)
          (server-configure-editor-environment client))
      (error (condition)
        (message "lemclient server unavailable: ~a" condition)))))

(ignore-errors (server-shutdown "Configuration reloaded"))
(remove-hook *after-init-hook* 'server-start-maybe)
(remove-hook *exit-editor-hook* 'server-shutdown)
(remove-hook (variable-value 'kill-buffer-hook :global t)
             'server-kill-buffer-hook)
(add-hook *exit-editor-hook* 'server-shutdown)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'server-kill-buffer-hook)
(initialize-editor-feature 'server-start-maybe)
