(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-bsd-sockets)
  #+sbcl (require :sb-posix))

(in-package :lem-daemon/client)

(defparameter +client-capabilities+
  #("visit" "eval" "attach" "input" "redisplay" "resize" "detach"
    "shutdown" "cancel"))

(defvar *request-counter* 0)
(defvar *request-counter-lock* (bt2:make-lock :name "lemclient/request-id"))

(defclass client-connection ()
  ((socket :initarg :socket :reader client-socket)
   (stream :initarg :stream :reader client-stream)
   (write-lock :initform (bt2:make-lock :name "lemclient/write")
               :reader client-write-lock)))

(defun next-id ()
  (format nil "~d-~d" #+sbcl (sb-posix:getpid) #-sbcl 0
          (bt2:with-lock-held (*request-counter-lock*)
            (incf *request-counter*))))

(defun client-send (connection message)
  (bt2:with-lock-held ((client-write-lock connection))
    (protocol:write-message message (client-stream connection))))

(defun close-client (connection)
  (ignore-errors (close (client-stream connection) :abort t))
  #+sbcl
  (ignore-errors (sb-bsd-sockets:socket-close (client-socket connection))))

(defun validate-endpoint (pathname)
  #+sbcl
  (let* ((directory (uiop:pathname-directory-pathname pathname))
         (directory-stat (handler-case
                             (sb-posix:lstat (uiop:native-namestring directory))
                           (sb-posix:syscall-error () nil)))
         (socket-stat (handler-case
                          (sb-posix:lstat (uiop:native-namestring pathname))
                        (sb-posix:syscall-error () nil))))
    (unless (and directory-stat socket-stat
                 (= (sb-posix:stat-uid directory-stat) (sb-posix:getuid))
                 (= (logand (sb-posix:stat-mode directory-stat) sb-posix:s-ifmt)
                    sb-posix:s-ifdir)
                 (zerop (logand (sb-posix:stat-mode directory-stat) #o077))
                 (= (sb-posix:stat-uid socket-stat) (sb-posix:getuid))
                 (= (logand (sb-posix:stat-mode socket-stat) sb-posix:s-ifmt)
                    sb-posix:s-ifsock))
      (error "Daemon endpoint is absent or not owner-private: ~a" pathname)))
  #-sbcl
  (declare (ignore pathname)))

(defun connect-client (server-name)
  #+sbcl
  (let* ((pathname (protocol:endpoint-pathname server-name))
         (socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (validate-endpoint pathname)
    (handler-case
        (progn
          (sb-bsd-sockets:socket-connect socket (uiop:native-namestring pathname))
          (let ((uid (lem-daemon::peer-user-id socket)))
            (unless (and uid (= uid (sb-posix:getuid)))
              (error "Daemon peer identity could not be verified")))
          (let* ((stream (sb-bsd-sockets:socket-make-stream
                          socket :input t :output t
                          :element-type '(unsigned-byte 8) :buffering :none))
                 (connection (make-instance 'client-connection
                                            :socket socket :stream stream)))
            (client-send
             connection
             (protocol:make-object
              "version" protocol:+protocol-version+
              "type" "hello"
              "capabilities" +client-capabilities+))
            (let ((hello (protocol:read-message stream)))
              (unless (and hello
                           (= protocol:+protocol-version+
                              (or (protocol:field hello "version") -1))
                           (string= "hello" (protocol:field hello "type" "")))
                (error "Daemon did not complete protocol negotiation")))
            connection))
      (error (condition)
        (ignore-errors (sb-bsd-sockets:socket-close socket))
        (error condition))))
  #-sbcl
  (declare (ignore server-name))
  #-sbcl
  (error "lemclient local transport is currently supported on SBCL"))

(defun response-error-message (message)
  (let ((error (protocol:field message "error")))
    (if (hash-table-p error)
        (protocol:field error "message" "Daemon request failed")
        "Daemon request failed")))

(defun wait-for-response (connection id &key pending-callback)
  (loop :for message := (protocol:read-message (client-stream connection))
        :while message
        :when (and (string= "response" (protocol:field message "type" ""))
                   (equal id (protocol:field message "id")))
          :do (let ((status (protocol:field message "status")))
                (cond
                  ((string= status "pending")
                   (when pending-callback (funcall pending-callback message)))
                  ((string= status "ok")
                   (return-from wait-for-response
                     (values (protocol:field message "value") nil)))
                  ((string= status "error")
                   (return-from wait-for-response
                     (values nil (response-error-message message))))))
        :finally (return (values nil "Daemon disconnected before responding"))))

(defun request (connection type &rest fields)
  (let ((id (next-id)))
    (client-send connection
                 (apply #'protocol:make-object
                        "version" protocol:+protocol-version+
                        "type" type "id" id fields))
    (values id connection)))

(defun parse-location (argument)
  (when (and (plusp (length argument)) (char= (char argument 0) #\+))
    (let* ((separator (position #\: argument))
           (line-text (subseq argument 1 separator))
           (column-text (and separator (subseq argument (1+ separator)))))
      (handler-case
          (let ((line (parse-integer line-text :junk-allowed nil))
                (column (if column-text
                            (parse-integer column-text :junk-allowed nil)
                            0)))
            (when (and (plusp line) (not (minusp column)))
              (values line column t)))
        (error () nil)))))

(defun canonical-file-entry (filename line column)
  (let ((pathname (merge-pathnames filename (uiop:getcwd))))
    (protocol:make-object
     "path" (uiop:native-namestring pathname)
     "line" line "column" column)))

(defun build-file-entries (arguments)
  (let ((entries '()) (line 1) (column 0) (location-p nil))
    (dolist (argument arguments)
      (multiple-value-bind (new-line new-column parsed-p) (parse-location argument)
        (cond
          (parsed-p
           (when location-p
             (error "A +LINE[:COLUMN] location must precede a file"))
           (setf line new-line column new-column location-p t))
          (t
           (push (canonical-file-entry argument line column) entries)
           (setf line 1 column 0 location-p nil)))))
    (when location-p
      (error "+LINE[:COLUMN] must precede a file"))
    (when (> (length entries) protocol:+maximum-files+)
      (error "At most ~d files may be opened at once" protocol:+maximum-files+))
    (coerce (nreverse entries) 'vector)))

(defun run-visit (connection arguments wait-p)
  (let ((id (next-id)))
    (client-send connection
                 (protocol:make-object
                  "version" protocol:+protocol-version+
                  "type" "visit" "id" id
                  "wait" (if wait-p "wait" "nowait")
                  "files" (build-file-entries arguments)))
    (handler-case
        (multiple-value-bind (value error) (wait-for-response connection id)
          (declare (ignore value))
          (if error (error "~a" error) 0))
      #+sbcl
      (sb-sys:interactive-interrupt ()
        (ignore-errors
          (client-send connection
                       (protocol:make-object
                        "version" protocol:+protocol-version+
                        "type" "cancel" "id" (next-id) "request" id)))
        130))))

(defun run-eval (connection form)
  (let ((id (next-id)))
    (client-send connection
                 (protocol:make-object
                  "version" protocol:+protocol-version+
                  "type" "eval" "id" id "form" form))
    (multiple-value-bind (value error) (wait-for-response connection id)
      (when error (error "~a" error))
      (yason:encode value *standard-output*)
      (terpri)
      0)))

(defun run-shutdown (connection force)
  (let ((id (next-id)))
    (client-send connection
                 (protocol:make-object
                  "version" protocol:+protocol-version+
                  "type" "shutdown" "id" id "force" (and force t)))
    (multiple-value-bind (value error) (wait-for-response connection id)
      (declare (ignore value))
      (if error (error "~a" error) 0))))

(defun ncurses-call (package name &rest arguments)
  (let ((symbol (find-symbol name package)))
    (unless (and symbol (fboundp symbol))
      (error "Terminal client requires the lem-ncurses system"))
    (apply (symbol-function symbol) arguments)))

(defstruct terminal-screen rows)

(defun draw-screen-row (row text)
  (ignore-errors (ncurses-call :charms/ll "MVADDSTR" row 0 text)))

(defun render-screen (message lock screen)
  (let* ((rows (protocol:field message "rows"))
         (changes (protocol:field message "changes"))
         (full-p (eq t (protocol:field message "full")))
         (cursor (protocol:field message "cursor"))
         (x (if (hash-table-p cursor) (protocol:field cursor "x" 0) 0))
         (y (if (hash-table-p cursor) (protocol:field cursor "y" 0) 0)))
    (bt2:with-lock-held (lock)
      (cond
        ((and full-p (typep rows 'sequence) (not (stringp rows)))
         (setf (terminal-screen-rows screen) (coerce rows 'vector))
         (ncurses-call :charms/ll "ERASE")
         (loop :for text :across (terminal-screen-rows screen)
               :for row :from 0
               :do (draw-screen-row row text)))
        ((and (terminal-screen-rows screen)
              (typep changes 'sequence) (not (stringp changes)))
         (loop :for change :in (coerce changes 'list)
               :for row := (protocol:field change "row")
               :for text := (protocol:field change "text")
               :when (and (integerp row) (stringp text)
                          (<= 0 row)
                          (< row (length (terminal-screen-rows screen))))
                 :do (setf (aref (terminal-screen-rows screen) row) text)
                     (draw-screen-row row text))))
      (ignore-errors (ncurses-call :charms/ll "MOVE" y x))
      (ncurses-call :charms/ll "REFRESH"))))

(define-condition terminal-server-exit (condition) ())

(define-condition terminal-server-error (error)
  ((message :initarg :message :reader terminal-server-error-message))
  (:report (lambda (condition stream)
             (write-string (terminal-server-error-message condition) stream))))

(defstruct terminal-control stopping-p)

(defun terminal-reader-loop (connection main-thread render-lock control)
  (let ((screen (make-terminal-screen))
        (reported-p nil))
    (unwind-protect
         (loop :for message := (protocol:read-message (client-stream connection))
               :while message
               :do (cond
                     ((string= "screen" (protocol:field message "type" ""))
                      (render-screen message render-lock screen))
                     ((and (string= "response"
                                    (protocol:field message "type" ""))
                           (string= "error"
                                    (protocol:field message "status" "")))
                      (let ((text (response-error-message message)))
                        (setf reported-p t)
                        (bt2:interrupt-thread
                         main-thread
                         (lambda ()
                           (error 'terminal-server-error :message text)))
                        (return)))))
      (when (and (not reported-p)
                 (not (terminal-control-stopping-p control))
                 (bt2:thread-alive-p main-thread))
        (bt2:interrupt-thread main-thread
                              (lambda () (signal 'terminal-server-exit)))))))

(defun send-input (connection event)
  (let ((id (next-id)))
    (cond
      ((and (consp event) (eq (first event) :paste))
       (client-send connection
                    (protocol:make-object
                     "version" protocol:+protocol-version+
                     "type" "input" "id" id "paste" (second event))))
      ((lem:key-p event)
       (client-send connection
                    (protocol:make-object
                     "version" protocol:+protocol-version+
                     "type" "input" "id" id
                     "ctrl" (and (lem:key-ctrl event) t)
                     "meta" (and (lem:key-meta event) t)
                     "super" (and (lem:key-super event) t)
                     "hyper" (and (lem:key-hyper event) t)
                     "shift" (and (lem:key-shift event) t)
                     "sym" (lem:key-sym event)))))))

(defun send-resize (connection rows columns)
  (when (and rows columns)
    (unwind-protect
         (progn
           (ncurses-call :lem-ncurses/term "RESIZE-TERM")
           (client-send connection
                        (protocol:make-object
                         "version" protocol:+protocol-version+
                         "type" "resize" "id" (next-id)
                         "width" columns "height" rows)))
      (alexandria:when-let
          ((pending (find-symbol "*RESIZE-EVENT-PENDING-P*"
                                 :lem-ncurses/term)))
        (setf (symbol-value pending) nil)))))

(defun run-terminal (connection files)
  (unless (find-package :lem-ncurses)
    (error "This lemclient was built without ncurses support"))
  (let* ((resize-symbol (find-symbol "*RESIZE-HANDLER*" :lem-ncurses/term))
         (old-resize-handler (and resize-symbol
                                  (boundp resize-symbol)
                                  (symbol-value resize-symbol)))
         (control (make-terminal-control))
         (reader nil)
         (render-lock (bt2:make-lock :name "lemclient/render")))
    (when resize-symbol
      (setf (symbol-value resize-symbol)
            (lambda (rows columns) (send-resize connection rows columns))))
    (unwind-protect
         (progn
           (unless (ncurses-call :lem-ncurses/term "TERM-INIT")
             (error "Could not initialize the terminal"))
           (handler-case
               (multiple-value-bind (rows columns)
                   (ncurses-call :lem-ncurses/term "TERMINAL-SIZE")
                 (let ((attach-id (next-id))
                       (main-thread (bt2:current-thread)))
                 (client-send connection
                              (protocol:make-object
                               "version" protocol:+protocol-version+
                               "type" "attach" "id" attach-id
                               "width" (or columns 80) "height" (or rows 24)))
                 (setf reader
                       (bt2:make-thread
                        (lambda ()
                          (terminal-reader-loop connection main-thread
                                                render-lock control))
                        :name "lemclient screen reader"))
                 (when files
                   (let ((visit-id (next-id)))
                     (client-send connection
                                  (protocol:make-object
                                   "version" protocol:+protocol-version+
                                   "type" "visit" "id" visit-id
                                   "wait" "nowait"
                                   "files" (build-file-entries files)))))
                 (let* ((handler-symbol
                          (find-symbol "*BRACKETED-PASTE-HANDLER*"
                                       :lem-ncurses/input))
                        (old-handler (symbol-value handler-symbol)))
                   (unwind-protect
                        (progn
                          (setf (symbol-value handler-symbol)
                                (lambda (text) (list :paste text)))
                          (loop (send-input
                                 connection
                                 (ncurses-call :lem-ncurses/input "GET-EVENT"))))
                       (setf (symbol-value handler-symbol) old-handler)))))
             (terminal-server-exit () 0)))
      (setf (terminal-control-stopping-p control) t)
      (ignore-errors
        (client-send connection
                     (protocol:make-object
                      "version" protocol:+protocol-version+
                      "type" "detach" "id" (next-id))))
      (close-client connection)
      (when (and reader (bt2:thread-alive-p reader))
        (ignore-errors (bt2:join-thread reader)))
      (ignore-errors (ncurses-call :lem-ncurses/term "TERM-FINALIZE"))
      (when (and resize-symbol old-resize-handler)
        (setf (symbol-value resize-symbol) old-resize-handler)))))

(defun print-help ()
  (format t "Usage: lemclient [OPTIONS] [FILE ...]~%\
  -t, --tty                    attach this terminal~%\
  -n, --no-wait                return after files are opened~%\
  -e, --eval FORM              evaluate Common Lisp in the daemon~%\
      --stop-server            stop the daemon if buffers are clean~%\
      --force                  allow --stop-server to discard edits~%\
  -s, --server-name NAME       select a named daemon~%\
  -a, --alternate-editor CMD   run CMD only when no daemon is reachable~%\
  -h, --help                   show this help~%"))

(defun parse-client-arguments (arguments)
  (let ((tty nil) (wait t) (eval nil) (stop nil) (force nil)
        (server "server") (alternate nil) (files '()) (options t))
    (loop :while arguments
          :for argument := (pop arguments)
          :do (cond
                ((and options (string= argument "--")) (setf options nil))
                ((and options (member argument '("-h" "--help") :test #'string=))
                 (return-from parse-client-arguments (values :help)))
                ((and options (member argument '("-t" "--tty") :test #'string=))
                 (setf tty t))
                ((and options (member argument '("-n" "--no-wait") :test #'string=))
                 (setf wait nil))
                ((and options (member argument '("-e" "--eval") :test #'string=))
                 (setf eval (or (pop arguments) (error "--eval requires FORM"))))
                ((and options (string= argument "--stop-server")) (setf stop t))
                ((and options (string= argument "--force")) (setf force t))
                ((and options (member argument '("-s" "--server-name") :test #'string=))
                 (setf server (or (pop arguments)
                                  (error "--server-name requires NAME"))))
                ((and options
                      (member argument '("-a" "--alternate-editor") :test #'string=))
                 (setf alternate (or (pop arguments)
                                     (error "--alternate-editor requires COMMAND"))))
                ((and options (plusp (length argument))
                      (char= (char argument 0) #\-))
                 (error "Unknown option: ~a" argument))
                (t (push argument files))))
    (when (> (count-if #'identity (list tty eval stop)) 1)
      (error "--tty, --eval, and --stop-server are mutually exclusive"))
    (when (and force (not stop)) (error "--force requires --stop-server"))
    (values (cond (tty :tty) (eval :eval) (stop :stop) (t :visit))
            (nreverse files) wait eval force server alternate)))

(defun run-alternate-editor (command files)
  (when (every (lambda (character)
                 (find character '(#\Space #\Tab #\Return #\Newline)))
               command)
    (error "Alternate editor command is empty"))
  (let ((shell-command
          (format nil "~a~{ ~a~}" command
                  (mapcar #'uiop:escape-shell-token files))))
    (uiop:run-program shell-command
                      :input :interactive :output :interactive
                      :error-output :interactive)
    0))

(defun run-client (&optional (arguments (uiop:command-line-arguments)))
  (multiple-value-bind (mode files wait eval force server alternate)
      (parse-client-arguments arguments)
    (when (eq mode :help) (print-help) (return-from run-client 0))
    (let ((connection
            (handler-case (connect-client server)
              (error (condition)
                (if alternate
                    (return-from run-client (run-alternate-editor alternate files))
                    (error "No Lem daemon named ~a is reachable: ~a"
                           server condition))))))
      (unwind-protect
           (ecase mode
             (:visit (run-visit connection files wait))
             (:eval (run-eval connection eval))
             (:stop (run-shutdown connection force))
             (:tty (run-terminal connection files)))
        (unless (eq mode :tty) (close-client connection))))))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (uiop:quit (run-client arguments))
    (error (condition)
      (format *error-output* "lemclient: ~a~%" condition)
      (uiop:quit 2))))
