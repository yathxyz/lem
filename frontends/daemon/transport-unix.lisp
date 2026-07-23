#+(and sbcl linux)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets)
  (require :sb-posix))

#+(and sbcl linux)
(in-package :lem-daemon/transport)

#+(and sbcl linux)
(progn
  (defclass unix-local-backend (local-backend) ())

  (defclass unix-local-listener (local-listener)
    ((socket :initarg :socket :reader unix-listener-socket)
     (endpoint :initarg :endpoint :reader local-listener-endpoint)
     (metadata :initarg :metadata :reader unix-listener-metadata)
     (endpoint-identity :initarg :endpoint-identity
                        :reader unix-listener-endpoint-identity)
     (metadata-identity :initarg :metadata-identity
                        :reader unix-listener-metadata-identity)
     (closed-p :initform nil :accessor unix-listener-closed-p)))

  (defclass unix-local-connection (local-connection)
    ((socket :initarg :socket :reader unix-connection-socket)
     (stream :initarg :stream :reader local-connection-stream)
     (closed-p :initform nil :accessor unix-connection-closed-p)))

  (sb-alien:define-alien-type linux-ucred
      (sb-alien:struct linux-ucred (pid sb-alien:int)
                                   (uid sb-alien:unsigned-int)
                                   (gid sb-alien:unsigned-int)))
  (sb-alien:define-alien-routine ("getsockopt" %getsockopt-ucred) sb-alien:int
    (fd sb-alien:int)
    (level sb-alien:int)
    (option sb-alien:int)
    (value (* linux-ucred))
    (length (* sb-alien:unsigned-int)))

  (defun unix-runtime-directory ()
    (if (uiop:getenvp "XDG_RUNTIME_DIR")
        (merge-pathnames "lem/"
                         (uiop:ensure-directory-pathname
                          (uiop:getenv "XDG_RUNTIME_DIR")))
        (merge-pathnames
         "lem/runtime/"
         (uiop:ensure-directory-pathname
          (or (uiop:getenv "XDG_CACHE_HOME")
              (merge-pathnames ".cache/" (user-homedir-pathname)))))))

  (defun checked-server-name (server-name)
    (unless (protocol:valid-server-name-p server-name)
      (error "Unsafe server name: ~s" server-name))
    server-name)

  (defmethod backend-process-id ((backend unix-local-backend))
    (declare (ignore backend))
    (sb-posix:getpid))

  (defmethod local-endpoint ((backend unix-local-backend) server-name)
    (declare (ignore backend))
    (merge-pathnames (format nil "~a.sock" (checked-server-name server-name))
                     (unix-runtime-directory)))

  (defmethod local-metadata ((backend unix-local-backend) server-name)
    (declare (ignore backend))
    (merge-pathnames (format nil "~a.json" (checked-server-name server-name))
                     (unix-runtime-directory)))

  (defun stat-path (pathname)
    (handler-case (sb-posix:lstat (uiop:native-namestring pathname))
      (sb-posix:syscall-error () nil)))

  (defun stat-kind-p (stat kind)
    (and stat (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt) kind)))

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

  (defun peer-user-id (socket)
    (sb-alien:with-alien ((credential linux-ucred)
                          (length sb-alien:unsigned-int
                                  (sb-alien:alien-size linux-ucred :bytes)))
      (when (zerop (%getsockopt-ucred
                    (sb-bsd-sockets:socket-file-descriptor socket)
                    1 17 (sb-alien:addr credential) (sb-alien:addr length)))
        (sb-alien:slot credential 'uid))))

  (defun validate-peer (socket role)
    (let ((uid (peer-user-id socket)))
      (unless (and uid (= uid (sb-posix:getuid)))
        (error "Refusing local ~a whose user identity could not be verified"
               role))))

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

  (defun prepare-metadata (metadata)
    (alexandria:when-let ((stat (stat-path metadata)))
      (let ((identity (cons (sb-posix:stat-dev stat) (sb-posix:stat-ino stat))))
        (unless (and (stat-kind-p stat sb-posix:s-ifreg)
                     (= (sb-posix:stat-uid stat) (sb-posix:getuid)))
          (error "Refusing unsafe daemon metadata: ~a" metadata))
        (delete-owned-path metadata identity sb-posix:s-ifreg))))

  (defun write-metadata (pathname endpoint server-name)
    (with-open-file (stream pathname :direction :output :if-exists :error
                                     :if-does-not-exist :create)
      (yason:encode
       (protocol:make-object "version" protocol:+protocol-version+
                             "pid" (sb-posix:getpid)
                             "name" server-name
                             "endpoint" (uiop:native-namestring endpoint))
       stream))
    (sb-posix:chmod (uiop:native-namestring pathname) #o600)
    (path-identity pathname))

  (defmethod open-local-listener
      ((backend unix-local-backend) server-name backlog)
    (let* ((endpoint (local-endpoint backend server-name))
           (metadata (local-metadata backend server-name))
           (native (uiop:native-namestring endpoint)))
      (when (> (length (sb-ext:string-to-octets native :external-format :utf-8))
               100)
        (error "Daemon endpoint path is too long: ~a" endpoint))
      (prepare-endpoint endpoint)
      (prepare-metadata metadata)
      (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
        (handler-case
            (progn
              (sb-bsd-sockets:socket-bind socket native)
              (sb-posix:chmod native #o600)
              (sb-bsd-sockets:socket-listen socket backlog)
              (make-instance
               'unix-local-listener
               :socket socket
               :endpoint endpoint
               :metadata metadata
               :endpoint-identity (path-identity endpoint)
               :metadata-identity (write-metadata metadata endpoint server-name)))
          (error (condition)
            (ignore-errors (sb-bsd-sockets:socket-close socket))
            (delete-owned-path endpoint (path-identity endpoint)
                               sb-posix:s-ifsock)
            (error condition))))))

  (defun make-unix-connection (socket role)
    (handler-case
        (progn
          (validate-peer socket role)
          (make-instance
           'unix-local-connection
           :socket socket
           :stream (sb-bsd-sockets:socket-make-stream
                    socket :input t :output t
                    :element-type '(unsigned-byte 8) :buffering :none)))
      (error (condition)
        (ignore-errors (sb-bsd-sockets:socket-close socket))
        (error condition))))

  (defmethod accept-local-connection ((listener unix-local-listener))
    (make-unix-connection
     (sb-bsd-sockets:socket-accept (unix-listener-socket listener))
     "client"))

  (defun validate-endpoint (pathname)
    (let* ((directory (uiop:pathname-directory-pathname pathname))
           (directory-stat (stat-path directory))
           (socket-stat (stat-path pathname)))
      (unless (and directory-stat socket-stat
                   (= (sb-posix:stat-uid directory-stat) (sb-posix:getuid))
                   (stat-kind-p directory-stat sb-posix:s-ifdir)
                   (zerop (logand (sb-posix:stat-mode directory-stat) #o077))
                   (= (sb-posix:stat-uid socket-stat) (sb-posix:getuid))
                   (stat-kind-p socket-stat sb-posix:s-ifsock))
        (error "Daemon endpoint is absent or not owner-private: ~a" pathname))))

  (defmethod connect-local ((backend unix-local-backend) server-name)
    (let* ((pathname (local-endpoint backend server-name))
           (socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (validate-endpoint pathname)
      (handler-case
          (progn
            (sb-bsd-sockets:socket-connect
             socket (uiop:native-namestring pathname))
            (make-unix-connection socket "daemon peer"))
        (error (condition)
          (ignore-errors (sb-bsd-sockets:socket-close socket))
          (error condition)))))

  (defmethod close-local-connection ((connection unix-local-connection))
    (unless (unix-connection-closed-p connection)
      (setf (unix-connection-closed-p connection) t)
      (ignore-errors (close (local-connection-stream connection) :abort t))
      (ignore-errors
        (sb-bsd-sockets:socket-close (unix-connection-socket connection))))
    nil)

  (defmethod close-local-listener ((listener unix-local-listener))
    (unless (unix-listener-closed-p listener)
      (setf (unix-listener-closed-p listener) t)
      (ignore-errors
        (sb-bsd-sockets:socket-close (unix-listener-socket listener)))
      (delete-owned-path (local-listener-endpoint listener)
                         (unix-listener-endpoint-identity listener)
                         sb-posix:s-ifsock)
      (delete-owned-path (unix-listener-metadata listener)
                         (unix-listener-metadata-identity listener)
                         sb-posix:s-ifreg))
    nil)

  (setf *local-backend* (make-instance 'unix-local-backend)))
