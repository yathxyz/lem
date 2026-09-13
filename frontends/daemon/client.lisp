(in-package :lem-daemon/client)

(defparameter +client-capabilities+
  #("visit" "eval" "attach" "input" "redisplay" "resize" "detach"
    "shutdown" "cancel"))

(defvar *request-counter* 0)
(defvar *request-counter-lock* (bt2:make-lock :name "lemclient/request-id"))

(defclass client-connection ()
  ((transport :initarg :transport :reader client-transport)
   (stream :initarg :stream :reader client-stream)
   (write-lock :initform (bt2:make-lock :name "lemclient/write")
               :reader client-write-lock)))

(defun next-id ()
  (format nil "~d-~d"
          (transport:backend-process-id (transport:require-local-backend))
          (bt2:with-lock-held (*request-counter-lock*)
            (incf *request-counter*))))

(defun client-send (connection message)
  (bt2:with-lock-held ((client-write-lock connection))
    (protocol:write-message message (client-stream connection))))

(defun close-client (connection)
  (transport:close-local-connection (client-transport connection)))

(defun connect-client (server-name)
  (let ((local-connection
          (transport:connect-local (transport:require-local-backend)
                                   server-name)))
    (handler-case
        (let* ((stream (transport:local-connection-stream local-connection))
               (connection (make-instance 'client-connection
                                          :transport local-connection
                                          :stream stream)))
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
          connection)
      (error (condition)
        (transport:close-local-connection local-connection)
        (error condition)))))

(defun response-error-message (message)
  (let ((error (protocol:field message "error")))
    (if (hash-table-p error)
        (protocol:field error "message" "Daemon request failed")
        "Daemon request failed")))

(defun connect-client-with-wait (server-name seconds)
  "Retry connection failures for SECONDS while a supervised daemon starts."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (handler-case (return (connect-client server-name))
        (error (condition)
          (when (>= (get-internal-real-time) deadline)
            (error condition))
          (sleep 0.05))))))

(defun response-error-code (message)
  (let ((error (protocol:field message "error")))
    (and (hash-table-p error) (protocol:field error "code"))))

(defun frame-close-status (edit-id)
  "Closing an attached frame cannot finish an outstanding external edit."
  (if edit-id 1 0))

(defun frame-message-exit-status (message edit-id)
  "Return an exit status only for closure or the exact waiting edit's result."
  (cond
    ((equal "close" (protocol:field message "type"))
     (frame-close-status edit-id))
    ((equal "response" (protocol:field message "type"))
     (let ((ours (and edit-id (equal edit-id (protocol:field message "id")))))
       (cond
         ((equal "error" (protocol:field message "status"))
          (if (and ours (equal "aborted" (response-error-code message)))
              1
              (error "~a" (response-error-message message))))
         ((and ours (equal "ok" (protocol:field message "status"))) 0))))))

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
                     (values nil
                             (response-error-message message)
                             (response-error-code message))))))
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
        (multiple-value-bind (value error code)
            (wait-for-response connection id)
          (declare (ignore value))
          (cond ((null error) 0)
                ((string= code "aborted") 1)
                (t (error "~a" error))))
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

(defstruct terminal-screen rows foreground background cursor-shape cursor-color mouse-enabled)

(defun terminal-face-bits (foreground background flags)
  (check-type flags (integer 0 7))
  (ncurses-call :lem-ncurses/attribute "ATTRIBUTE-TO-BITS"
                (lem:make-attribute :foreground foreground :background background
                                    :bold (logtest 1 flags)
                                    :underline (logtest 2 flags)
                                    :reverse (logtest 4 flags))))

(defun draw-screen-text (row column text foreground background flags)
  (check-type text string)
  (ncurses-call :charms/ll "ATTRSET" (terminal-face-bits foreground background flags))
  (ignore-errors (ncurses-call :charms/ll "MVADDSTR" row column text)))

(defun draw-screen-row (row data foreground background)
  (draw-screen-text row 0 (protocol:field data "text") foreground background 0)
  (dolist (run (coerce (protocol:field data "runs") 'list))
    (destructuring-bind (column text run-foreground run-background flags) (coerce run 'list)
      (check-type column (integer 0 1000))
      (draw-screen-text row column text (or run-foreground foreground)
                        (or run-background background) flags)))
  (ncurses-call :charms/ll "ATTRSET" 0))

(defun render-screen-content (message screen)
  (let* ((rows (protocol:field message "rows"))
         (changes (protocol:field message "changes"))
         (full-p (eq t (protocol:field message "full")))
         (foreground (protocol:field message "foreground"))
         (background (protocol:field message "background"))
         (theme-changed-p (not (and (equal foreground (terminal-screen-foreground screen))
                                   (equal background (terminal-screen-background screen)))))
         (cursor (protocol:field message "cursor"))
         (x (protocol:field cursor "x" 0))
         (y (protocol:field cursor "y" 0))
         (shape (protocol:field cursor "shape"))
         (color (lem-daemon::wire-color (protocol:field cursor "color"))))
    (progn
      (when full-p (setf (terminal-screen-rows screen) (coerce rows 'vector)))
      (when (terminal-screen-rows screen)
        (dolist (change (coerce changes 'list))
          (let ((row (protocol:field change "row")))
            (unless (and (integerp row) (<= 0 row) (< row (length (terminal-screen-rows screen))))
              (error "Invalid screen row: ~s" row))
            (setf (aref (terminal-screen-rows screen) row) change)))
        (if (or full-p theme-changed-p)
            (progn
              (ncurses-call :charms/ll "ERASE")
              (loop :for data :across (terminal-screen-rows screen)
                    :for row :from 0
                    :do (draw-screen-row row data foreground background)))
            (dolist (change (coerce changes 'list))
              (draw-screen-row (protocol:field change "row") change foreground background))))
      (setf (terminal-screen-foreground screen) foreground
            (terminal-screen-background screen) background)
      (let ((mouse-enabled (eq t (protocol:field message "mouse")))
            (escape-delay (protocol:field message "escape-delay")))
        (check-type escape-delay (integer 0 1000))
        (setf (lem:variable-value (find-symbol "ESCAPE-DELAY" :lem-ncurses/config) :global)
              escape-delay
              (lem:variable-value 'lem:mouse-mode :global) mouse-enabled)
        (unless (eq mouse-enabled (terminal-screen-mouse-enabled screen))
          (ncurses-call :lem-ncurses/mouse
                        (if mouse-enabled "ENABLE-MOUSE-REPORTING" "DISABLE-MOUSE-REPORTING"))
          (setf (terminal-screen-mouse-enabled screen) mouse-enabled)))
      (unless (equal shape (terminal-screen-cursor-shape screen))
        (ncurses-call :lem-ncurses/term "UPDATE-CURSOR-SHAPE"
                      (cond ((equal shape "box") :box)
                            ((equal shape "bar") :bar)
                            ((equal shape "underline") :underline)
                            (t (error "Invalid cursor shape: ~s" shape))))
        (setf (terminal-screen-cursor-shape screen) shape))
      (unless (equal color (terminal-screen-cursor-color screen))
        (ncurses-call :lem-ncurses/term "WRITE-TERMINAL-STRING"
                      (format nil "~c]12;~a~c" #\Esc color #\Bell))
        (setf (terminal-screen-cursor-color screen) color))
      (ignore-errors (ncurses-call :charms/ll "MOVE" y x))
      (ncurses-call :charms/ll "REFRESH"))))

(defun render-screen (message lock screen)
  (bt2:with-lock-held (lock)
    (ncurses-call :lem-ncurses/term "CALL-WITH-INPUT-RESIZE-LOCK"
                  (lambda () (render-screen-content message screen)))))

(define-condition terminal-server-exit (condition)
  ((status :initarg :status :reader terminal-server-exit-status)))

(define-condition terminal-server-error (error)
  ((message :initarg :message :reader terminal-server-error-message))
  (:report (lambda (condition stream)
             (write-string (terminal-server-error-message condition) stream))))

(define-condition stop-terminal-reader (condition) ())

(defstruct terminal-control
  (lock (bt2:make-lock :name "lemclient/terminal-control"))
  stopping-p reader-started-p)

(defun terminal-reader-loop (connection main-thread render-lock control screen &optional edit-id)
  (let ((reported-p nil))
    (labels ((fail (message)
               (setf reported-p t)
               (when (and (not (terminal-control-stopping-p control))
                          (bt2:thread-alive-p main-thread))
                 (bt2:interrupt-thread
                  main-thread
                  (lambda ()
                    (unless (terminal-control-stopping-p control)
                      (error 'terminal-server-error :message message)))))))
      (handler-case
          (unwind-protect
               (handler-case
                   (progn
                     (bt2:with-lock-held ((terminal-control-lock control))
                       (when (terminal-control-stopping-p control)
                         (return-from terminal-reader-loop))
                       (setf (terminal-control-reader-started-p control) t))
                     (loop :for message := (protocol:read-message (client-stream connection))
                           :while message
                           :do (cond
                                 ((string= "screen" (protocol:field message "type" ""))
                                  (render-screen message render-lock screen))
                                 (t
                                  (let ((status (frame-message-exit-status message edit-id)))
                                    (when status
                                      (setf reported-p t)
                                      (bt2:interrupt-thread
                                       main-thread
                                       (lambda ()
                                         (unless (terminal-control-stopping-p control)
                                           (signal 'terminal-server-exit :status status))))
                                      (return)))))))
                 (error (condition) (fail (princ-to-string condition))))
            (bt2:with-lock-held ((terminal-control-lock control))
              (setf (terminal-control-reader-started-p control) nil))
            (unless reported-p (fail "Daemon disconnected before closing this client")))
        (stop-terminal-reader () nil)))))

(defun stop-terminal-reader (control reader)
  (let ((started-p
          (bt2:with-lock-held ((terminal-control-lock control))
            (setf (terminal-control-stopping-p control) t)
            (terminal-control-reader-started-p control))))
    (when reader
      (when (and started-p (bt2:thread-alive-p reader))
        (ignore-errors
          (bt2:interrupt-thread
           reader (lambda ()
                    (when (terminal-control-reader-started-p control)
                      (signal 'stop-terminal-reader))))))
      (bt2:join-thread reader))))

(defun send-input (connection event)
  (let ((id (next-id)))
    (cond
      ((and (consp event) (eq (first event) :mouse))
       (client-send connection
                    (protocol:make-object
                     "version" protocol:+protocol-version+
                     "type" "input" "id" id "mouse" (second event))))
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

(defun terminal-mouse-event (kind x y button wheel-x wheel-y)
  (list :mouse
        (protocol:make-object
         "kind" (string-downcase kind) "x" x "y" y
         "button" (ecase button
                    ((nil) 0) (:button-1 1) (:button-2 2) (:button-3 3) (:button-4 4))
         "clicks" 1 "dx" wheel-x "dy" wheel-y)))

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

(defun run-terminal (connection files wait-p)
  (unless (find-package :lem-ncurses)
    (error "This lemclient was built without ncurses support"))
  (let* ((entries (build-file-entries files))
         (visit-id (and files (next-id)))
         (edit-id (and wait-p visit-id))
         (resize-symbol (find-symbol "*RESIZE-HANDLER*" :lem-ncurses/term))
         (old-resize-handler (and resize-symbol
                                  (boundp resize-symbol)
                                  (symbol-value resize-symbol)))
         (control (make-terminal-control))
         (screen (make-terminal-screen))
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
                                                render-lock control screen edit-id))
                        :name "lemclient screen reader"))
                 (when files
                   (client-send connection
                                (protocol:make-object
                                 "version" protocol:+protocol-version+
                                 "type" "visit" "id" visit-id
                                 "wait" (if wait-p "wait" "nowait")
                                 "files" entries)))
                 (let* ((handler-symbol
                          (find-symbol "*BRACKETED-PASTE-HANDLER*"
                                       :lem-ncurses/input))
                        (old-handler (symbol-value handler-symbol))
                        (mouse-handler-symbol (find-symbol "*MOUSE-EVENT-HANDLER*" :lem-ncurses/mouse))
                        (old-mouse-handler (symbol-value mouse-handler-symbol)))
                   (unwind-protect
                        (progn
                          (setf (symbol-value handler-symbol)
                                (lambda (text) (list :paste text))
                                (symbol-value mouse-handler-symbol) #'terminal-mouse-event)
                          (loop (send-input
                                 connection
                                 (ncurses-call :lem-ncurses/input "GET-EVENT"))))
                       (setf (symbol-value handler-symbol) old-handler
                             (symbol-value mouse-handler-symbol) old-mouse-handler)))))
             (terminal-server-exit (condition) (terminal-server-exit-status condition))))
      (stop-terminal-reader control reader)
      (ignore-errors
        (client-send connection
                     (protocol:make-object
                      "version" protocol:+protocol-version+
                      "type" "detach" "id" (next-id))))
      (close-client connection)
      (when (terminal-screen-cursor-color screen)
        (ignore-errors
          (ncurses-call :lem-ncurses/term "WRITE-TERMINAL-STRING"
                        (format nil "~c]112~c" #\Esc #\Bell))))
      (ignore-errors (ncurses-call :lem-ncurses/term "TERM-FINALIZE"))
      (when (and resize-symbol old-resize-handler)
        (setf (symbol-value resize-symbol) old-resize-handler)))))

(defun print-help ()
  (format t "Usage: lemclient [OPTIONS] [FILE ...]~%\
  -t, --tty                    attach this terminal; FILEs wait for edit completion~%\
  -c, --create-frame           attach a graphical client; FILEs wait for completion~%\
  -n, --no-wait                visit without an edit request; -t/-c stay attached~%\
  -e, --eval FORM              evaluate Common Lisp in the daemon~%\
      --stop-server            stop the daemon if buffers are clean~%\
      --force                  allow --stop-server to discard edits~%\
  -s, --server-name NAME       select a named daemon~%\
      --wait-for-server SECS  retry connection failures during startup~%\
  -a, --alternate-editor CMD   run CMD only when no daemon is reachable~%\
  -h, --help                   show this help~%\
With -t/-c and no FILEs, stay attached until the frame is closed.~%\
For waiting edits: C-c C-c saves and finishes; C-x # finishes without saving;~%\
C-c C-k aborts. Closing before completion returns failure.~%"))

(defun parse-client-arguments (arguments)
  (let ((tty nil) (gui nil) (wait t) (eval nil) (stop nil) (force nil)
        (server "server") (alternate nil) (startup-wait 0) (files '()) (options t))
    (loop :while arguments
          :for argument := (pop arguments)
          :do (cond
                ((and options (string= argument "--")) (setf options nil))
                ((and options (member argument '("-h" "--help") :test #'string=))
                 (return-from parse-client-arguments (values :help)))
                ((and options (member argument '("-t" "--tty") :test #'string=))
                 (setf tty t))
                ((and options (member argument '("-c" "--create-frame") :test #'string=))
                 (setf gui t))
                ((and options (member argument '("-n" "--no-wait") :test #'string=))
                 (setf wait nil))
                ((and options (member argument '("-e" "--eval") :test #'string=))
                 (setf eval (or (pop arguments) (error "--eval requires FORM"))))
                ((and options (string= argument "--stop-server")) (setf stop t))
                ((and options (string= argument "--force")) (setf force t))
                ((and options (string= argument "--wait-for-server"))
                 (let ((value (pop arguments)))
                   (unless (and value (plusp (length value))
                                (every #'digit-char-p value))
                     (error "--wait-for-server requires non-negative integer seconds"))
                   (setf startup-wait (parse-integer value))))
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
    (when (> (count-if #'identity (list tty gui eval stop)) 1)
      (error "--tty, --create-frame, --eval, and --stop-server are mutually exclusive"))
    (when (and force (not stop)) (error "--force requires --stop-server"))
    (values (cond (tty :tty) (gui :gui) (eval :eval) (stop :stop) (t :visit))
            (nreverse files) wait eval force server alternate startup-wait)))

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
  (multiple-value-bind (mode files wait eval force server alternate startup-wait)
      (parse-client-arguments arguments)
    (when (eq mode :help) (print-help) (return-from run-client 0))
    (let ((connection
            (handler-case (connect-client-with-wait server startup-wait)
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
             (:gui (uiop:symbol-call :lem-daemon/sdl-client :run-graphical connection files wait))
             (:tty (run-terminal connection files wait)))
        (unless (eq mode :tty) (close-client connection))))))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (uiop:quit (run-client arguments))
    (error (condition)
      (format *error-output* "lemclient: ~a~%" condition)
      (uiop:quit 2))))
