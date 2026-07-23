;;;; Dape-compatible Debug Adapter Protocol support.
;;;;
;;;; The configured Emacs eagerly enables Dape's global breakpoint mode and
;;;; leaves Dape's stock C-x C-a map and adapter presets intact.  This module
;;;; owns the equivalent contract directly: global source breakpoints, one
;;;; foreground DAP session, stdio/TCP transports, source navigation, and the
;;;; debugger information/repl buffers.  Adapter processes are always started
;;;; with direct argv lists; no debugger input is interpolated into a shell.

(in-package :lem-yath)

(declaim (ftype function join-left-display-content))

(defparameter *dap-maximum-message-bytes* (* 16 1024 1024))
(defparameter *dap-maximum-header-bytes* 8192)
(defparameter *dap-connect-timeout-seconds* 10)
(defparameter *dap-request-timeout-seconds* 60)
(defparameter *dap-output-character-limit* (* 2 1024 1024))
(defparameter *dap-variable-depth-limit* 2)
(defparameter *dap-variable-count-limit* 500)

(define-attribute dap-breakpoint-attribute
  (t :foreground "red" :bold t))
(define-attribute dap-breakpoint-pending-attribute
  (t :foreground "yellow" :bold t))
(define-attribute dap-stopped-gutter-attribute
  (t :foreground "green" :bold t))
(define-attribute dap-stopped-line-attribute
  (t :background "#253825"))
(define-attribute dap-info-heading-attribute
  (t :foreground "cyan" :bold t))
(define-attribute dap-info-error-attribute
  (t :foreground "red" :bold t))

(defvar *dap-command-keymap*
  (make-keymap :description '*dap-command-keymap*))
(defvar *dap-info-mode-keymap*
  (make-keymap :description '*dap-info-mode-keymap*))
(defvar *dap-repl-mode-keymap*
  (make-keymap :description '*dap-repl-mode-keymap*))

(defstruct dap-breakpoint
  path
  line
  point
  condition
  hit-condition
  log-message
  adapter-id
  verified-p
  message
  temporary-p)

(defstruct dap-function-breakpoint
  name
  condition
  hit-condition
  adapter-id
  verified-p
  message)

(defstruct dap-pending-request
  command
  callback
  sent-at)

(defstruct dap-config
  name
  transport
  command
  command-arguments
  directory
  request
  arguments)

(defstruct (dap-session (:constructor %make-dap-session))
  generation
  config
  (state :starting)
  process
  socket
  stream
  reader-thread
  adapter-output-thread
  adapter-error-thread
  monitor-timer
  (input "")
  (sequence 0)
  (pending (make-hash-table))
  (breakpoint-generations (make-hash-table :test #'equal))
  (write-lock (bt2:make-lock :name "lem-yath/dap-write"))
  (capabilities (make-hash-table :test #'equal))
  initialize-response-p
  launch-sent-p
  initialized-p
  configuration-done-p
  thread-id
  (threads '())
  (frames '())
  frame
  (scopes '())
  (variables '())
  (watch-values '())
  (output "")
  stopped-overlay
  stopped-path
  stopped-line
  stopped-reason
  exit-code
  expected-exit-p
  disconnect-keep-debuggee-p
  restart-config
  (terminal-sequence 0)
  (debuggee-buffers '()))

(defvar *dap-breakpoints* (make-hash-table :test #'equal))
(defvar *dap-function-breakpoints* '())
(defvar *dap-watches* '())
(defvar *dap-session* nil)
(defvar *dap-session-generation* 0)
(defvar *dap-last-config-name* nil)
(defvar *dap-info-navigation* (make-hash-table))
(defvar *dap-info-buffer-name* "*dape-info*")
(defvar *dap-repl-buffer-name* "*dape-repl*")

(defun dap-empty-object ()
  (make-hash-table :test #'equal))

(defun dap-object (&rest key-values)
  "Return a JSON object from alternating string keys and values."
  (unless (evenp (length key-values))
    (error "DAP object requires key/value pairs"))
  (let ((object (dap-empty-object)))
    (loop :for (key value) :on key-values :by #'cddr
          :do (check-type key string)
              (setf (gethash key object) value))
    object))

(defun dap-json-true (value)
  (if value yason:true yason:false))

(defun dap-json-true-p (value)
  (or (eq value t) (eq value yason:true) (eq value :true)))

(defun dap-field (object key &optional default)
  (if (hash-table-p object)
      (multiple-value-bind (value found-p) (gethash key object)
        (if found-p value default))
      default))

(defun dap-response-error-message (response)
  "Return the useful part of a failed DAP response, including ErrorResponse."
  (let* ((message (and response (dap-field response "message")))
         (body (and response (dap-field response "body")))
         (error-object (and body (dap-field body "error")))
         (format-string (and error-object
                             (dap-field error-object "format")))
         (variables (and error-object
                         (dap-field error-object "variables"))))
    (cond
      ((and format-string variables (hash-table-p variables))
       (format nil "~a [~{~a~^, ~}]"
               format-string
               (sort
                (loop :for key :being :the :hash-key :in variables
                        :using (hash-value value)
                      :collect (format nil "~a=~a" key value))
                #'string<)))
      (format-string format-string)
      (message message)
      (t "unknown adapter error"))))

(defun dap-sequence-list (value)
  (typecase value
    (null '())
    (list value)
    (vector (coerce value 'list))
    (t '())))

(defun dap-now-seconds ()
  (/ (get-internal-real-time) internal-time-units-per-second))

(defun dap-trim-string (string limit)
  (if (<= (length string) limit)
      string
      (subseq string (- (length string) limit))))

(defun dap-append-output (session text &optional category)
  (when (and session (stringp text) (plusp (length text)))
    (let ((prefix
            (cond
              ((null category) "")
              ((string= category "stderr") "[stderr] ")
              ((string= category "console") "[console] ")
              ((string= category "telemetry") "[telemetry] ")
              (t ""))))
      (setf (dap-session-output session)
            (dap-trim-string
             (concatenate 'string
                          (dap-session-output session)
                          prefix text)
             *dap-output-character-limit*)))))

(defun dap-native-path (pathname)
  (uiop:native-namestring pathname))

(defun dap-normalize-path (path &optional base)
  "Return a stable absolute native filename for PATH."
  (when path
    (let* ((pathname (pathname path))
           (absolute
             (if (uiop:absolute-pathname-p pathname)
                 pathname
                 (merge-pathnames pathname
                                  (uiop:ensure-directory-pathname
                                   (or base (uiop:getcwd))))))
           (resolved (or (ignore-errors (truename absolute)) absolute)))
      (dap-native-path resolved))))

(defun dap-buffer-path (&optional (buffer (current-buffer)))
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (dap-normalize-path filename (buffer-directory buffer))))

(defun dap-buffer-for-path (path)
  (find path (buffer-list)
        :test #'string=
        :key (lambda (buffer)
               (and (not (deleted-buffer-p buffer))
                    (dap-buffer-path buffer)))))

(defun dap-breakpoint-current-line (breakpoint)
  (let ((point (dap-breakpoint-point breakpoint)))
    (if (and point
             (not (deleted-buffer-p (point-buffer point))))
        (setf (dap-breakpoint-line breakpoint)
              (line-number-at-point point))
        (dap-breakpoint-line breakpoint))))

(defun dap-delete-breakpoint-point (breakpoint)
  (alexandria:when-let ((point (dap-breakpoint-point breakpoint)))
    (setf (dap-breakpoint-line breakpoint)
          (line-number-at-point point))
    (ignore-errors (delete-point point))
    (setf (dap-breakpoint-point breakpoint) nil)))

(defun dap-make-breakpoint-point (buffer line)
  (with-point ((point (buffer-start-point buffer)))
    (move-to-line point (max 1 line))
    (line-start point)
    (copy-point point :left-inserting)))

(defun dap-attach-breakpoints-to-buffer (buffer)
  (alexandria:when-let ((path (dap-buffer-path buffer)))
    (dolist (breakpoint (gethash path *dap-breakpoints*))
      (unless (dap-breakpoint-point breakpoint)
        (setf (dap-breakpoint-point breakpoint)
              (dap-make-breakpoint-point
               buffer (dap-breakpoint-line breakpoint)))))))

(defun dap-detach-breakpoints-from-buffer (&optional (buffer (current-buffer)))
  (alexandria:when-let ((path (dap-buffer-path buffer)))
    (dolist (breakpoint (gethash path *dap-breakpoints*))
      (when (eq buffer
                (and (dap-breakpoint-point breakpoint)
                     (point-buffer (dap-breakpoint-point breakpoint))))
        (dap-delete-breakpoint-point breakpoint)))))

(defun dap-breakpoints-for-path (path)
  (sort (copy-list (gethash path *dap-breakpoints*)) #'<
        :key #'dap-breakpoint-current-line))

(defun dap-breakpoint-at (path line)
  (find line (gethash path *dap-breakpoints*)
        :key #'dap-breakpoint-current-line))

(defun dap-current-breakpoint ()
  (let ((path (dap-buffer-path)))
    (unless path
      (editor-error "Breakpoints require a file-backed buffer"))
    (values (dap-breakpoint-at path
                               (line-number-at-point (current-point)))
            path
            (line-number-at-point (current-point)))))

(defun dap-store-breakpoint (breakpoint)
  (let* ((path (dap-breakpoint-path breakpoint))
         (breakpoints (gethash path *dap-breakpoints*)))
    (push breakpoint breakpoints)
    (setf (gethash path *dap-breakpoints*) breakpoints)
    breakpoint))

(defun dap-remove-breakpoint (breakpoint)
  (let* ((path (dap-breakpoint-path breakpoint))
         (remaining (delete breakpoint (gethash path *dap-breakpoints*))))
    (dap-delete-breakpoint-point breakpoint)
    (if remaining
        (setf (gethash path *dap-breakpoints*) remaining)
        (remhash path *dap-breakpoints*))
    breakpoint))

(defun dap-clear-breakpoint-verification (breakpoint)
  (setf (dap-breakpoint-verified-p breakpoint) nil
        (dap-breakpoint-adapter-id breakpoint) nil
        (dap-breakpoint-message breakpoint) nil)
  breakpoint)

(defun dap-redraw ()
  (ignore-errors (redraw-display :force t)))

(defun dap-source-object (path)
  (dap-object "name" (file-namestring path)
              "path" path))

(defun dap-utf16-code-units (string &optional (end (length string)))
  (loop :for index :below (min end (length string))
        :for code := (char-code (char string index))
        :sum (if (> code #xffff) 2 1)))

(defun dap-point-utf16-column (point)
  (1+ (dap-utf16-code-units (line-string point)
                            (point-charpos point))))

(defun dap-breakpoint-json (breakpoint)
  (let ((object
          (dap-object "line" (dap-breakpoint-current-line breakpoint))))
    (when (dap-breakpoint-condition breakpoint)
      (setf (gethash "condition" object)
            (dap-breakpoint-condition breakpoint)))
    (when (dap-breakpoint-hit-condition breakpoint)
      (setf (gethash "hitCondition" object)
            (dap-breakpoint-hit-condition breakpoint)))
    (when (dap-breakpoint-log-message breakpoint)
      (setf (gethash "logMessage" object)
            (dap-breakpoint-log-message breakpoint)))
    object))

(defun dap-active-session-p (&optional (session *dap-session*))
  (and session
       (eq session *dap-session*)
       (not (member (dap-session-state session)
                    '(:terminated :exited :failed)))))

(defun dap-session-ready-p (&optional (session *dap-session*))
  (and (dap-active-session-p session)
       (dap-session-initialized-p session)))

(defun dap-session-stopped-p (&optional (session *dap-session*))
  (and (dap-active-session-p session)
       (eq (dap-session-state session) :stopped)))

(defun dap-current-session ()
  (unless (dap-active-session-p)
    (editor-error "No active Dape session"))
  *dap-session*)

(defun dap-current-stopped-session ()
  (unless (dap-session-stopped-p)
    (editor-error "The Dape session is not stopped"))
  (unless (integerp (dap-session-thread-id *dap-session*))
    (editor-error "Dape is still loading the stopped thread"))
  *dap-session*)

(defun dap-project-directory (&optional (buffer (current-buffer)))
  "Resolve Dape's cwd without opening Lem's interactive project prompt."
  (let ((directory
          (or (and (buffer-filename buffer)
                   (uiop:pathname-directory-pathname
                    (buffer-filename buffer)))
              (ignore-errors (buffer-directory buffer))
              (uiop:getcwd))))
    (or (ignore-errors (jj-root directory))
        (ignore-errors (git-root directory))
        directory)))

(defun dap-buffer-language (&optional (buffer (current-buffer)))
  (let ((mode (buffer-major-mode buffer))
        (type (and (buffer-filename buffer)
                   (string-downcase
                    (or (pathname-type (buffer-filename buffer)) "")))))
    (cond
      ((eq mode 'lem-python-mode:python-mode) :python)
      ((eq mode 'lem-go-mode:go-mode) :go)
      ((eq mode 'lem-rust-mode:rust-mode) :rust)
      ((typep (ensure-mode-object mode) 'lem-c-mode:c-mode)
       (if (member type '("cc" "cp" "cxx" "cpp" "c++" "hh" "hpp" "hxx")
                   :test #'string=)
           :cpp
           :c))
      (t nil))))

(defun dap-config-names-for-buffer (&optional (buffer (current-buffer)))
  (case (dap-buffer-language buffer)
    (:python '("debugpy"))
    (:go '("dlv" "gdb"))
    ((:rust :c :cpp) '("lldb-dap" "gdb"))
    (otherwise '("debugpy" "dlv" "lldb-dap" "gdb"))))

(defun dap-resolve-command (command)
  (let ((pathname (executable-find command)))
    (unless pathname
      (editor-error "Dape adapter executable is unavailable: ~a" command))
    (dap-native-path pathname)))

(defun dap-make-config (name &optional (buffer (current-buffer)))
  "Materialize one stock Dape-compatible adapter preset for BUFFER."
  (let* ((root (uiop:ensure-directory-pathname
                (dap-project-directory buffer)))
         (root-string (dap-native-path root))
         (filename (dap-buffer-path buffer)))
    (cond
      ((string= name "debugpy")
       (unless filename
         (editor-error "debugpy requires a saved Python buffer"))
       (make-dap-config
        :name name
        :transport :tcp
        :command (dap-resolve-command "python")
        :command-arguments
        '("-m" "debugpy.adapter" "--host" "127.0.0.1" "--port" :port)
        :directory root-string
        :request "launch"
        :arguments
        (dap-object "request" "launch"
                    "type" "python"
                    "cwd" root-string
                    "program" filename
                    "args" #()
                    "justMyCode" yason:false
                    "console" "integratedTerminal"
                    "showReturnValue" yason:true
                    "stopOnEntry" yason:false)))
      ((string= name "dlv")
       (make-dap-config
        :name name
        :transport :tcp
        :command (dap-resolve-command "dlv")
        :command-arguments '("dap" "--listen" :listen)
        :directory root-string
        :request "launch"
        :arguments
        (dap-object "request" "launch"
                    "type" "go"
                    "cwd" root-string
                    "program" root-string)))
      ((string= name "lldb-dap")
       (make-dap-config
        :name name
        :transport :stdio
        :command (dap-resolve-command "lldb-dap")
        :command-arguments '()
        :directory root-string
        :request "launch"
        :arguments
        (dap-object "request" "launch"
                    "type" "lldb-dap"
                    "cwd" root-string
                    "program" (dap-native-path
                                (merge-pathnames "a.out" root)))))
      ((string= name "gdb")
       (make-dap-config
        :name name
        :transport :stdio
        :command (dap-resolve-command "gdb")
        :command-arguments '("--interpreter=dap")
        :directory root-string
        :request "launch"
        :arguments
        (dap-object "request" "launch"
                    "program" (dap-native-path
                                (merge-pathnames "a.out" root))
                    "args" #()
                    "stopAtBeginningOfMainSubprogram" yason:false)))
      (t
       (editor-error "Unknown Dape configuration: ~a" name)))))

(defun dap-prompt-config-name ()
  (let* ((names (dap-config-names-for-buffer))
         (initial
           (if (member *dap-last-config-name* names :test #'string=)
               *dap-last-config-name*
               (first names)))
         (choice
           (prompt-for-string
            "Dape configuration: "
            :initial-value initial
            :completion-function
            (lambda (input) (prescient-filter input names))
            :test-function
            (lambda (input) (member input names :test #'string=))
            :history-symbol 'lem-yath-dape-config)))
    (unless (member choice names :test #'string=)
      (editor-error "Unknown Dape configuration: ~a" choice))
    choice))

;;; Transport ----------------------------------------------------------------

(declaim (ftype function dap-handle-message dap-begin-initialize
                dap-render-info-buffer dap-refresh-stopped-data
                dap-session-fail dap-finalize-session
                dap-call-response-callback))

(defun dap-json-string (object)
  (with-output-to-string (stream)
    (yason:encode object stream)))

(defun dap-wire-message (object)
  (let ((json (dap-json-string object)))
    (format nil "Content-Length: ~d~c~c~c~c~a"
            (babel:string-size-in-octets json :encoding :utf-8)
            #\Return #\Newline #\Return #\Newline json)))

(defun dap-character-utf8-size (character)
  (let ((code (char-code character)))
    (cond
      ((<= code #x7f) 1)
      ((<= code #x7ff) 2)
      ((<= code #xffff) 3)
      (t 4))))

(defun dap-index-after-utf8-bytes (string start byte-count)
  "Return the character index BYTE-COUNT UTF-8 octets after START.
Return NIL when STRING does not contain the complete prefix and signal when a
declared length splits an encoded character."
  (loop :with bytes := 0
        :for index :from start :below (length string)
        :when (= bytes byte-count) :return index
        :do (incf bytes (dap-character-utf8-size (char string index)))
            (when (> bytes byte-count)
              (error "DAP Content-Length splits a UTF-8 character"))
        :finally (return (and (= bytes byte-count) (length string)))))

(defun dap-header-length (header)
  (loop :for line :in (uiop:split-string header
                                          :separator '(#\Newline))
        :for colon := (position #\: line)
        :when (and colon
                   (string-equal
                    "content-length"
                    (string-trim '(#\Space #\Tab #\Return)
                                 (subseq line 0 colon))))
          :do (let* ((text
                       (string-trim '(#\Space #\Tab #\Return)
                                    (subseq line (1+ colon))))
                     (length (parse-integer text :junk-allowed nil)))
                (unless (<= 0 length *dap-maximum-message-bytes*)
                  (error "DAP message length ~d exceeds the ~d-byte limit"
                         length *dap-maximum-message-bytes*))
                (return length))))

(defun dap-header-end (string start)
  (let ((crlf (search (format nil "~c~c~c~c"
                              #\Return #\Newline #\Return #\Newline)
                      string :start2 start))
        (lf (search (format nil "~c~c" #\Newline #\Newline)
                    string :start2 start)))
    (cond
      ((and crlf (or (null lf) (<= crlf lf)))
       (values crlf (+ crlf 4)))
      (lf (values lf (+ lf 2)))
      (t (values nil nil)))))

(defun dap-parse-json-body (body)
  (let ((yason:*parse-json-arrays-as-vectors* t)
        (yason:*parse-json-null-as-keyword* t))
    (yason:parse body)))

(defun dap-deliver-body (session body)
  (when (dap-active-session-p session)
    (handler-case
        (dap-handle-message session (dap-parse-json-body body))
      (error (condition)
        (dap-append-output
         session (format nil "~&[protocol error] ~a~%" condition) "stderr")
        (dap-session-fail session
                          (format nil "Invalid adapter message: ~a" condition))))))

(defun dap-feed-stdio-unchecked (session chunk)
  "Feed one decoded adapter output CHUNK into SESSION's framed parser."
  (unless (and (eq session *dap-session*) (stringp chunk))
    (return-from dap-feed-stdio-unchecked))
  (setf (dap-session-input session)
        (concatenate 'string (dap-session-input session) chunk))
  (loop
    (let* ((input (dap-session-input session))
           (start (search "Content-Length:" input :test #'char-equal)))
      (unless start
        (when (> (length input) *dap-maximum-header-bytes*)
          (let* ((keep (1- (length "Content-Length:")))
                 (cut (- (length input) keep)))
            (dap-append-output session (subseq input 0 cut) "stderr")
            (setf (dap-session-input session) (subseq input cut))))
        (return))
      (when (plusp start)
        (dap-append-output session (subseq input 0 start) "stderr")
        (setf input (subseq input start)
              (dap-session-input session) input
              start 0))
      (multiple-value-bind (header-end body-start)
          (dap-header-end input start)
        (unless header-end
          (when (> (length input) *dap-maximum-header-bytes*)
            (dap-session-fail session "DAP adapter sent an oversized header"))
          (return))
        (when (> (- body-start start) *dap-maximum-header-bytes*)
          (dap-session-fail session "DAP adapter sent an oversized header")
          (return))
        (let* ((header (subseq input start header-end))
               (length (dap-header-length header)))
          (unless length
            (dap-session-fail session "DAP header omitted Content-Length")
            (return))
          (let ((body-end
                  (dap-index-after-utf8-bytes input body-start length)))
            (unless body-end (return))
            (let ((body (subseq input body-start body-end)))
              (setf (dap-session-input session) (subseq input body-end))
              (dap-deliver-body session body))))))))

(defun dap-feed-stdio (session chunk)
  (handler-case
      (dap-feed-stdio-unchecked session chunk)
    (error (condition)
      (when (dap-active-session-p session)
        (dap-append-output
         session (format nil "~&[protocol error] ~a~%" condition) "stderr")
        (dap-session-fail
         session (format nil "Invalid adapter framing: ~a" condition))))))

(defun dap-send-wire (session wire)
  (bt2:with-lock-held ((dap-session-write-lock session))
    (case (dap-config-transport (dap-session-config session))
      (:stdio
       (let ((process (dap-session-process session)))
         (unless (and process (uiop:process-alive-p process))
           (error "DAP adapter process is not alive"))
         (let ((stream (uiop:process-info-input process)))
           (unless stream
             (error "DAP adapter input stream is unavailable"))
           (write-string wire stream)
           (finish-output stream))))
      (:tcp
       (let ((stream (dap-session-stream session)))
         (unless stream
           (error "DAP adapter socket is not connected"))
         (write-sequence (babel:string-to-octets wire :encoding :utf-8)
                         stream)
         (finish-output stream)))
      (otherwise
       (error "Unknown DAP transport")))))

(defun dap-send-object (session object)
  (handler-case
      (progn
        (dap-send-wire session (dap-wire-message object))
        t)
    (error (condition)
      (dap-session-fail session
                        (format nil "Could not write to adapter: ~a" condition))
      nil)))

(defun dap-read-header-octets (stream)
  (let ((octets
          (make-array 128 :element-type '(unsigned-byte 8)
                          :adjustable t :fill-pointer 0)))
    (loop
      :for byte := (read-byte stream nil nil)
      :do (unless byte (return-from dap-read-header-octets nil))
          (vector-push-extend byte octets)
          (when (> (length octets) *dap-maximum-header-bytes*)
            (error "DAP adapter sent an oversized header"))
          (let ((length (length octets)))
            (when (or (and (>= length 4)
                           (= 13 (aref octets (- length 4)))
                           (= 10 (aref octets (- length 3)))
                           (= 13 (aref octets (- length 2)))
                           (= 10 (aref octets (1- length))))
                      (and (>= length 2)
                           (= 10 (aref octets (- length 2)))
                           (= 10 (aref octets (1- length)))))
              (return octets))))))

(defun dap-read-exactly (stream length)
  (let ((octets (make-array length :element-type '(unsigned-byte 8))))
    (loop :with offset := 0
          :while (< offset length)
          :for count := (read-sequence octets stream :start offset)
          :do (when (= count offset)
                (return-from dap-read-exactly nil))
              (setf offset count)
          :finally (return octets))))

(defun dap-read-binary-body (stream)
  (let ((header-octets (dap-read-header-octets stream)))
    (unless header-octets
      (return-from dap-read-binary-body nil))
    (let* ((header (babel:octets-to-string header-octets :encoding :ascii))
           (length (dap-header-length header)))
      (unless length
        (error "DAP header omitted Content-Length"))
      (alexandria:when-let ((body (dap-read-exactly stream length)))
        (babel:octets-to-string body :encoding :utf-8)))))

(defun dap-socket-reader-loop (session)
  (handler-case
      (progn
        (loop :while (and (dap-active-session-p session)
                          (dap-session-stream session))
              :for body := (dap-read-binary-body
                            (dap-session-stream session))
              :while body
              :do (let ((body body))
                    (send-event
                     (lambda ()
                       (dap-deliver-body session body)))))
        (unless (dap-session-expected-exit-p session)
          (send-event
           (lambda ()
             (when (dap-active-session-p session)
               (dap-session-fail session "DAP socket closed unexpectedly"))))))
    (error (condition)
      (unless (dap-session-expected-exit-p session)
        (let ((text (princ-to-string condition)))
          (send-event
           (lambda ()
             (when (eq session *dap-session*)
               (dap-session-fail
                session (format nil "DAP socket failed: ~a" text))))))))))

(defun dap-connect-socket (session port)
  (bt2:make-thread
   (lambda ()
     (let ((deadline (+ (get-universal-time)
                        *dap-connect-timeout-seconds*))
           socket
           last-error)
       (loop :while (and (dap-active-session-p session)
                         (null socket)
                         (<= (get-universal-time) deadline))
             :do (handler-case
                     (setf socket
                           (usocket:socket-connect
                            "127.0.0.1" port
                            :element-type '(unsigned-byte 8)))
                   (error (condition)
                     (setf last-error condition)
                     (sleep 0.05))))
       (if (null socket)
           (let ((text (and last-error (princ-to-string last-error))))
             (send-event
              (lambda ()
                (when (eq session *dap-session*)
                  (dap-session-fail
                   session
                   (format nil "Could not connect to DAP adapter~@[ (~a)~]"
                           text))))))
           (let ((stream (usocket:socket-stream socket)))
             (send-event
              (lambda ()
                (if (dap-active-session-p session)
                    (progn
                      (setf (dap-session-socket session) socket
                            (dap-session-stream session) stream
                            (dap-session-reader-thread session)
                            (bt2:make-thread
                             (lambda () (dap-socket-reader-loop session))
                             :name "lem-yath/dap-socket-reader"))
                      (dap-begin-initialize session))
                    (ignore-errors (usocket:socket-close socket)))))))))
   :name "lem-yath/dap-connect"))

(defun dap-materialize-command-arguments (arguments port)
  (mapcar
   (lambda (argument)
     (case argument
       (:port (princ-to-string port))
       (:listen (format nil "127.0.0.1:~d" port))
       (otherwise argument)))
   arguments))

(defun dap-adapter-output-loop (session stream protocol-p category)
  (handler-case
      (progn
        (loop :for first := (read-char stream nil nil)
              :while first
              :for chunk :=
                (with-output-to-string (output)
                  (write-char first output)
                  (loop :repeat 4095
                        :while (listen stream)
                        :for character := (read-char stream nil nil)
                        :while character
                        :do (write-char character output)))
              :do (let ((chunk chunk))
                    (send-event
                     (lambda ()
                       (when (dap-active-session-p session)
                         (if protocol-p
                             (dap-feed-stdio session chunk)
                             (dap-append-output session chunk category)))))))
        (when (and protocol-p
                   (not (dap-session-expected-exit-p session)))
          (send-event
           (lambda ()
             (when (dap-active-session-p session)
               (dap-session-fail
                session "DAP stdio closed unexpectedly"))))))
    (error (condition)
      (unless (dap-session-expected-exit-p session)
        (let ((text (princ-to-string condition)))
          (send-event
           (lambda ()
             (when (eq session *dap-session*)
               (dap-session-fail
                session (format nil "DAP adapter output failed: ~a" text))))))))))

(defun dap-start-adapter-output-readers (session protocol-p)
  (let* ((process (dap-session-process session))
         (output (uiop:process-info-output process))
         (error-output (uiop:process-info-error-output process)))
    (unless (and output error-output)
      (error "DAP adapter streams are unavailable"))
    (setf (dap-session-adapter-output-thread session)
          (bt2:make-thread
           (lambda ()
             (dap-adapter-output-loop
              session output protocol-p (unless protocol-p "console")))
           :name "lem-yath/dap-adapter-output")
          (dap-session-adapter-error-thread session)
          (bt2:make-thread
           (lambda ()
             (dap-adapter-output-loop session error-output nil "stderr"))
           :name "lem-yath/dap-adapter-error"))))

(defun dap-session-process-alive-p (session)
  (let ((process (dap-session-process session)))
    (and process
         (ignore-errors (uiop:process-alive-p process)))))

(defun dap-monitor-session (session)
  (when (eq session *dap-session*)
    (let ((now (dap-now-seconds))
          (expired '()))
      (maphash
       (lambda (sequence pending)
         (when (> (- now (dap-pending-request-sent-at pending))
                  *dap-request-timeout-seconds*)
           (push (cons sequence pending) expired)))
       (dap-session-pending session))
      (dolist (entry expired)
        (remhash (car entry) (dap-session-pending session))
        (dap-call-response-callback
         session (cdr entry) nil nil
         (dap-object
          "message"
          (format nil "~a request timed out"
                  (dap-pending-request-command (cdr entry)))))))
    (unless (or (dap-session-process-alive-p session)
                (member (dap-session-state session)
                        '(:terminated :exited :failed)))
      (dap-finalize-session
       session :exited
       (if (dap-session-expected-exit-p session)
           "Debug adapter exited"
           "Debug adapter exited unexpectedly")))))

(defun dap-start-monitor (session)
  (let (timer)
    (setf timer
          (start-timer
           (make-timer
            (lambda ()
              (when (and (eq session *dap-session*)
                         (eq timer (dap-session-monitor-timer session)))
                (dap-monitor-session session)))
            :name "lem-yath/dap-monitor")
           250 :repeat t)
          (dap-session-monitor-timer session) timer)))

(defun dap-start-session (config)
  (when *dap-session*
    (when (dap-active-session-p *dap-session*)
      (setf (dap-session-state *dap-session*) :terminated))
    (dap-cleanup-session-resources *dap-session*))
  (let* ((session
           (%make-dap-session
            :generation (incf *dap-session-generation*)
            :config config))
         (tcp-p (eq :tcp (dap-config-transport config)))
         (port (and tcp-p (lem/common/socket:random-available-port)))
         (arguments
           (dap-materialize-command-arguments
            (dap-config-command-arguments config) port))
         (command (cons (dap-config-command config) arguments)))
    (setf *dap-session* session
          *dap-last-config-name* (dap-config-name config))
    (handler-case
        (progn
          (setf (dap-session-process session)
                (uiop:launch-program
                 command
                 :input :stream
                 :output :stream
                 :error-output :stream
                 :directory (dap-config-directory config)
                 :element-type 'character
                 :external-format :utf-8))
          (dap-start-adapter-output-readers session (not tcp-p))
          (dap-start-monitor session)
          (if tcp-p
              (setf (dap-session-reader-thread session)
                    (dap-connect-socket session port))
              (dap-begin-initialize session))
          (message "Starting Dape ~a…" (dap-config-name config))
          session)
      (error (condition)
        (dap-session-fail session (princ-to-string condition))
        (error condition)))))

;;; Protocol lifecycle -------------------------------------------------------

(defun dap-copy-object (object)
  (let ((copy (dap-empty-object)))
    (when (hash-table-p object)
      (maphash (lambda (key value) (setf (gethash key copy) value)) object))
    copy))

(defun dap-send-request (session command &optional arguments callback)
  (unless (dap-active-session-p session)
    (return-from dap-send-request nil))
  (let* ((sequence (incf (dap-session-sequence session)))
         (request (dap-object "seq" sequence
                              "type" "request"
                              "command" command
                              "arguments" (or arguments (dap-empty-object))))
         (pending
           (make-dap-pending-request
            :command command
            :callback callback
            :sent-at (dap-now-seconds))))
    (setf (gethash sequence (dap-session-pending session)) pending)
    (unless (dap-send-object session request)
      (remhash sequence (dap-session-pending session))
      (return-from dap-send-request nil))
    sequence))

(defun dap-send-response (session request &key (success-p t) body message)
  (let ((response
          (dap-object
           "seq" (incf (dap-session-sequence session))
           "type" "response"
           "request_seq" (dap-field request "seq")
           "success" (dap-json-true success-p)
           "command" (or (dap-field request "command") ""))))
    (when body (setf (gethash "body" response) body))
    (when message (setf (gethash "message" response) message))
    (dap-send-object session response)))

(defun dap-capability-p (session name)
  (dap-json-true-p (dap-field (dap-session-capabilities session) name)))

(defun dap-default-exception-filters (session)
  (coerce
   (loop :for filter
           :in (dap-sequence-list
                (dap-field (dap-session-capabilities session)
                           "exceptionBreakpointFilters"))
         :for name := (dap-field filter "filter")
         :when (and (stringp name)
                    (dap-json-true-p (dap-field filter "default")))
           :collect name)
   'vector))

(defun dap-exception-filters (session)
  (dap-sequence-list
   (dap-field (dap-session-capabilities session)
              "exceptionBreakpointFilters")))

(defun dap-send-exception-breakpoints (session &optional completion)
  (dap-send-request
   session "setExceptionBreakpoints"
   (dap-object "filters" (dap-default-exception-filters session))
   (lambda (session success-p body response)
     (declare (ignore body response))
     (when completion
       (funcall completion session success-p)))))

(defun dap-initialize-arguments (session)
  (dap-object
   "clientID" "lem-yath"
   "clientName" "Lem"
   "adapterID" (dap-config-name (dap-session-config session))
   "locale" "en-US"
   "linesStartAt1" yason:true
   "columnsStartAt1" yason:true
   "pathFormat" "path"
   "supportsVariableType" yason:true
   "supportsVariablePaging" yason:false
   "supportsRunInTerminalRequest" yason:true
   "supportsMemoryReferences" yason:true
   "supportsProgressReporting" yason:true
   "supportsInvalidatedEvent" yason:true
   "supportsMemoryEvent" yason:true
   "supportsArgsCanBeInterpretedByShell" yason:false
   "supportsStartDebuggingRequest" yason:false))

(defun dap-begin-initialize (session)
  (unless (and (eq session *dap-session*)
               (eq (dap-session-state session) :starting))
    (return-from dap-begin-initialize))
  (setf (dap-session-state session) :initializing)
  (dap-send-request
   session "initialize" (dap-initialize-arguments session)
   (lambda (session success-p body response)
     (if success-p
         (progn
           (setf (dap-session-capabilities session)
                 (if (hash-table-p body) body (dap-empty-object))
                 (dap-session-initialize-response-p session) t)
           (dap-send-launch session))
         (dap-session-fail
          session
          (format nil "DAP initialize failed: ~a"
                  (or (dap-field response "message") "unknown error")))))))

(defun dap-send-launch (session)
  (when (or (dap-session-launch-sent-p session)
            (not (dap-active-session-p session)))
    (return-from dap-send-launch))
  (let ((config (dap-session-config session)))
    (setf (dap-session-launch-sent-p session) t
          (dap-session-state session) :launching)
    (dap-send-request
     session (dap-config-request config)
     (dap-copy-object (dap-config-arguments config))
     (lambda (session success-p body response)
       (declare (ignore body))
       (unless success-p
         (dap-session-fail
          session
          (format nil "DAP ~a failed: ~a"
                  (dap-config-request config)
                  (dap-response-error-message response))))))))

(defun dap-move-breakpoint-to-line (breakpoint line)
  (when (and (integerp line) (plusp line))
    (setf (dap-breakpoint-line breakpoint) line)
    (alexandria:when-let ((point (dap-breakpoint-point breakpoint)))
      (buffer-start point)
      (move-to-line point line)
      (line-start point))))

(defun dap-apply-breakpoint-response (breakpoint response)
  (when (hash-table-p response)
    (setf (dap-breakpoint-adapter-id breakpoint) (dap-field response "id")
          (dap-breakpoint-verified-p breakpoint)
          (dap-json-true-p (dap-field response "verified"))
          (dap-breakpoint-message breakpoint) (dap-field response "message"))
    (dap-move-breakpoint-to-line breakpoint
                                 (dap-field response "line"))))

(defun dap-send-set-breakpoints (session path &optional completion)
  (let* ((breakpoints (dap-breakpoints-for-path path))
         (generation
           (1+ (gethash path
                        (dap-session-breakpoint-generations session)
                        0)))
         (arguments
           (dap-object "source" (dap-source-object path)
                       "breakpoints"
                       (coerce (mapcar #'dap-breakpoint-json breakpoints)
                               'vector)
                       "sourceModified" yason:false)))
    (setf (gethash path (dap-session-breakpoint-generations session))
          generation)
    (dolist (breakpoint breakpoints)
      (dap-clear-breakpoint-verification breakpoint))
    (dap-send-request
     session "setBreakpoints" arguments
     (lambda (session success-p body response)
       (when (= generation
                (gethash path
                         (dap-session-breakpoint-generations session)))
         (if success-p
             (let ((returned
                     (dap-sequence-list (dap-field body "breakpoints"))))
               (loop :for breakpoint :in breakpoints
                     :for adapter-breakpoint :in returned
                     :do (dap-apply-breakpoint-response
                          breakpoint adapter-breakpoint)))
             (let ((text (or (dap-field response "message")
                             "setBreakpoints failed")))
               (dolist (breakpoint breakpoints)
                 (setf (dap-breakpoint-message breakpoint) text))))
         (dap-redraw))
       (when completion (funcall completion session success-p))))))

(defun dap-function-breakpoint-json (breakpoint)
  (let ((object (dap-object "name" (dap-function-breakpoint-name breakpoint))))
    (when (dap-function-breakpoint-condition breakpoint)
      (setf (gethash "condition" object)
            (dap-function-breakpoint-condition breakpoint)))
    (when (dap-function-breakpoint-hit-condition breakpoint)
      (setf (gethash "hitCondition" object)
            (dap-function-breakpoint-hit-condition breakpoint)))
    object))

(defun dap-apply-function-breakpoint-response (breakpoint response)
  (when (hash-table-p response)
    (setf (dap-function-breakpoint-adapter-id breakpoint)
          (dap-field response "id")
          (dap-function-breakpoint-verified-p breakpoint)
          (dap-json-true-p (dap-field response "verified"))
          (dap-function-breakpoint-message breakpoint)
          (dap-field response "message"))))

(defun dap-send-function-breakpoints (session &optional completion)
  (let ((breakpoints (copy-list *dap-function-breakpoints*)))
    (dap-send-request
     session "setFunctionBreakpoints"
     (dap-object
      "breakpoints"
      (coerce (mapcar #'dap-function-breakpoint-json breakpoints) 'vector))
     (lambda (session success-p body response)
       (if success-p
           (loop :for breakpoint :in breakpoints
                 :for returned :in
                   (dap-sequence-list (dap-field body "breakpoints"))
                 :do (dap-apply-function-breakpoint-response
                      breakpoint returned))
           (dap-append-output
            session
            (format nil "~&[breakpoints] ~a~%"
                    (or (dap-field response "message")
                        "setFunctionBreakpoints failed"))
            "stderr"))
       (when completion (funcall completion session success-p))))))

(defun dap-finish-configuration (session)
  (unless (dap-active-session-p session)
    (return-from dap-finish-configuration))
  (flet ((ready (session success-p body response)
           (declare (ignore body))
           (when (dap-active-session-p session)
             (if success-p
                 (progn
                   (setf (dap-session-configuration-done-p session) t)
                   (unless (eq (dap-session-state session) :stopped)
                     (setf (dap-session-state session) :running))
                   (message "Dape ~a is running"
                            (dap-config-name (dap-session-config session))))
                 (dap-session-fail
                  session
                  (format nil "DAP configurationDone failed: ~a"
                          (or (dap-field response "message")
                              "unknown error")))))))
    (if (dap-capability-p session "supportsConfigurationDoneRequest")
        (dap-send-request session "configurationDone" (dap-empty-object)
                          #'ready)
        (ready session t nil nil))))

(defun dap-configure-session (session)
  (when (or (dap-session-initialized-p session)
            (dap-session-configuration-done-p session)
            (not (dap-active-session-p session)))
    (return-from dap-configure-session))
  (setf (dap-session-initialized-p session) t
        (dap-session-state session) :configuring)
  (let ((tasks '()))
    (maphash
     (lambda (path breakpoints)
       (declare (ignore breakpoints))
       (push (lambda (done)
               (dap-send-set-breakpoints session path done))
             tasks))
     *dap-breakpoints*)
    (when (and *dap-function-breakpoints*
               (dap-capability-p session "supportsFunctionBreakpoints"))
      (push (lambda (done)
              (dap-send-function-breakpoints session done))
            tasks))
    ;; Match Dape's initial policy: only configure exceptions when the adapter
    ;; advertises filters, enabling those whose advertised default is true.
    (when (dap-exception-filters session)
      (push (lambda (done)
              (dap-send-exception-breakpoints session done))
            tasks))
    (if (null tasks)
        (dap-finish-configuration session)
        (let ((remaining (length tasks)))
          (labels ((done (session success-p)
                     (declare (ignore success-p))
                     (when (and (eq session *dap-session*)
                                (zerop (decf remaining)))
                       (dap-finish-configuration session))))
            (dolist (task tasks)
              (funcall task #'done)))))))

(defun dap-valid-environment-key-p (key)
  (and (stringp key)
       (plusp (length key))
       (every (lambda (character)
                (or (alphanumericp character)
                    (char= character #\_)))
              key)
       (not (digit-char-p (char key 0)))))

(defun dap-terminal-environment-arguments (environment)
  (let ((set '()) (unset '()))
    (when (hash-table-p environment)
      (maphash
       (lambda (key value)
         (unless (dap-valid-environment-key-p key)
           (error "Adapter supplied an invalid environment key"))
         (cond
           ((or (eq value :null) (null value))
            (push key unset))
           ((and (stringp value) (not (find #\Null value)))
            (push (format nil "~a=~a" key value) set))
           (t (error "Adapter supplied a non-string environment value"))))
       environment))
    (append (loop :for key :in (sort unset #'string<)
                  :append (list "-u" key))
            (list "--")
            (sort set #'string<))))

(defun dap-run-in-terminal (session request)
  (let (process buffer)
    (handler-case
        (let* ((arguments (dap-field request "arguments"))
               (args (dap-sequence-list (dap-field arguments "args")))
               (cwd (or (dap-field arguments "cwd")
                        (dap-config-directory (dap-session-config session))))
               (environment (dap-field arguments "env")))
          (unless (and args
                       (<= (length args) 256)
                       (every (lambda (arg)
                                (and (stringp arg)
                                     (not (find #\Null arg))))
                              args))
            (error "Adapter supplied invalid terminal arguments"))
          (when (dap-json-true-p
                 (dap-field arguments "argsCanBeInterpretedByShell"))
            (error "Shell-interpreted terminal arguments are not supported"))
          (unless (and (stringp cwd) (uiop:directory-exists-p cwd))
            (error "Adapter supplied an invalid terminal directory"))
          (let* ((env (dap-resolve-command "env"))
                 (command
                   (append (list env)
                           (dap-terminal-environment-arguments environment)
                           args)))
            (setf process
                  (lem-process:run-process
                   command
                   :name
                   (format nil "dape-debuggee-~d-~d"
                           (dap-session-generation session)
                           (incf (dap-session-terminal-sequence session)))
                   :directory cwd
                   :output-callback
                   (lambda (process chunk)
                     (when (eq session *dap-session*)
                       (dap-append-output session chunk))
                     (lem-shell-mode::output-callback process chunk))
                   :output-callback-type :process-input)
                  buffer (lem-shell-mode::create-shell-buffer process))
            (push buffer (dap-session-debuggee-buffers session))
            (switch-to-window (pop-to-buffer buffer))
            ;; processId and shellProcessId are optional in DAP.  Omitting them
            ;; avoids depending on async-process implementation internals.
            (dap-send-response session request :body (dap-empty-object))))
      (error (condition)
        (cond
          ((and buffer (not (deleted-buffer-p buffer)))
           (ignore-errors (kill-buffer buffer)))
          (process
           (ignore-errors (lem-process:delete-process process))))
        (dap-send-response session request :success-p nil
                           :message (princ-to-string condition))))))

(defun dap-handle-reverse-request (session request)
  (let ((command (dap-field request "command")))
    (cond
      ((string= command "runInTerminal")
       (dap-run-in-terminal session request))
      ((string= command "startDebugging")
       (dap-send-response
        session request :success-p nil
        :message "Nested DAP sessions are not enabled in this profile"))
      (t
       (dap-send-response
        session request :success-p nil
        :message (format nil "Unsupported adapter request: ~a" command))))))

(defun dap-call-response-callback (session pending success-p body response)
  (alexandria:when-let ((callback (dap-pending-request-callback pending)))
    (handler-case
        (funcall callback session success-p body response)
      (error (condition)
        (dap-session-fail
         session
         (format nil "DAP ~a callback failed: ~a"
                 (dap-pending-request-command pending) condition))))))

(defun dap-handle-response (session response)
  (let* ((request-sequence (dap-field response "request_seq"))
         (pending (and (integerp request-sequence)
                       (gethash request-sequence
                                (dap-session-pending session)))))
    (unless pending
      (dap-append-output
       session
       (format nil "~&[protocol] response for unknown request ~a~%"
               request-sequence)
       "stderr")
      (return-from dap-handle-response))
    (remhash request-sequence (dap-session-pending session))
    (let ((success-p (dap-json-true-p (dap-field response "success"))))
      (unless success-p
        (dap-append-output
         session
         (format nil "~&[~a] ~a~%"
                 (dap-pending-request-command pending)
                 (dap-response-error-message response))
         "stderr"))
      (dap-call-response-callback
       session pending success-p (dap-field response "body") response))))

(defun dap-update-breakpoint-event (body)
  (let* ((adapter (dap-field body "breakpoint"))
         (id (dap-field adapter "id")))
    (when id
      (maphash
       (lambda (path breakpoints)
         (declare (ignore path))
         (alexandria:when-let
             ((breakpoint
                (find id breakpoints :key #'dap-breakpoint-adapter-id
                                     :test #'equal)))
           (dap-apply-breakpoint-response breakpoint adapter)))
       *dap-breakpoints*)
      (alexandria:when-let
          ((breakpoint
             (find id *dap-function-breakpoints*
                   :key #'dap-function-breakpoint-adapter-id
                   :test #'equal)))
        (dap-apply-function-breakpoint-response breakpoint adapter)))))

(defun dap-remove-stopped-overlay (session)
  (alexandria:when-let ((overlay (dap-session-stopped-overlay session)))
    (ignore-errors (delete-overlay overlay)))
  (setf (dap-session-stopped-overlay session) nil
        (dap-session-stopped-path session) nil
        (dap-session-stopped-line session) nil)
  (dap-redraw))

(defun dap-clear-stopped-location (session)
  (dap-remove-stopped-overlay session)
  (setf (dap-session-stopped-reason session) nil))

(defun dap-handle-event (session event)
  (let ((name (dap-field event "event"))
        (body (dap-field event "body")))
    (cond
      ((string= name "initialized")
       (when (dap-active-session-p session)
         (dap-configure-session session)))
      ((string= name "stopped")
       (when (dap-active-session-p session)
         (setf (dap-session-state session) :stopped
               (dap-session-thread-id session) (dap-field body "threadId")
               (dap-session-stopped-reason session)
               (or (dap-field body "description")
                   (dap-field body "reason")
                   "stopped"))
         (dap-refresh-stopped-data session)
         (message "Dape stopped: ~a" (dap-session-stopped-reason session))))
      ((string= name "continued")
       (when (dap-active-session-p session)
         (setf (dap-session-state session) :running
               (dap-session-frames session) '()
               (dap-session-frame session) nil
               (dap-session-scopes session) '()
               (dap-session-variables session) '())
         (dap-clear-stopped-location session)
         (dap-render-info-buffer session)))
      ((string= name "output")
       (dap-append-output session
                          (or (dap-field body "output") "")
                          (dap-field body "category"))
       (dap-render-info-buffer session))
      ((string= name "breakpoint")
       (dap-update-breakpoint-event body)
       (dap-redraw))
      ((string= name "thread")
       (when (dap-session-stopped-p session)
         (dap-refresh-stopped-data session)))
      ((string= name "invalidated")
       (when (dap-session-stopped-p session)
         (dap-refresh-stopped-data session)))
      ((string= name "capabilities")
       (alexandria:when-let ((capabilities
                              (dap-field body "capabilities")))
         (when (hash-table-p capabilities)
           (maphash
           (lambda (key value)
              (setf (gethash key (dap-session-capabilities session)) value))
            capabilities)
           (when (and (dap-session-configuration-done-p session)
                      (dap-sequence-list
                       (dap-field capabilities
                                  "exceptionBreakpointFilters")))
             (dap-send-exception-breakpoints session)))))
      ((string= name "exited")
       (setf (dap-session-exit-code session) (dap-field body "exitCode"))
       (dap-append-output
        session
        (format nil "~&[exited] code ~a~%" (dap-session-exit-code session))))
      ((string= name "terminated")
       (dap-finalize-session
        session :terminated "Debug session terminated"
        :keep-debuggee-p (dap-session-disconnect-keep-debuggee-p session)))
      ((member name '("progressStart" "progressUpdate" "progressEnd")
               :test #'string=)
       (alexandria:when-let ((message (dap-field body "message")))
         (message "Dape: ~a" message)))
      (t
       ;; Module, loaded-source, process, and memory events are informational;
       ;; keep them available in the protocol log without disturbing focus.
       (when name
         (dap-append-output session (format nil "~&[event] ~a~%" name)))))))

(defun dap-handle-message (session message)
  (unless (hash-table-p message)
    (error "DAP top-level message is not an object"))
  (let ((type (dap-field message "type")))
    (cond
      ((string= type "response") (dap-handle-response session message))
      ((string= type "event") (dap-handle-event session message))
      ((string= type "request") (dap-handle-reverse-request session message))
      (t (error "Unknown DAP message type: ~a" type)))))

;;; Stopped state, source navigation, and information UI --------------------

(defun dap-source-path (session source)
  (alexandria:when-let ((path (dap-field source "path")))
    (dap-normalize-path path
                        (dap-config-directory
                         (dap-session-config session)))))

(defun dap-set-stopped-overlay (session buffer line &optional path)
  (dap-remove-stopped-overlay session)
  (let ((point (buffer-point buffer)))
    (buffer-start point)
    (move-to-line point (max 1 line))
    (line-start point)
    (setf (dap-session-stopped-overlay session)
          (make-line-overlay point 'dap-stopped-line-attribute)
          (dap-session-stopped-path session) path
          (dap-session-stopped-line session) line)
    (switch-to-buffer buffer)
    (move-point (current-point) point)
    (dap-redraw)))

(defun dap-show-source-reference (session frame source reference line)
  (dap-send-request
   session "source"
   (dap-object "source" source "sourceReference" reference)
   (lambda (session success-p body response)
     (cond
       ((and success-p
             (eq frame (dap-session-frame session))
             (dap-session-stopped-p session))
        (let* ((name (or (dap-field source "name")
                         (format nil "source-~a" reference)))
               (buffer-name
                 (format nil "*dape-source: ~a [~d:~a]*"
                         name (dap-session-generation session) reference))
               (buffer (make-buffer buffer-name))
               (content (or (dap-field body "content") "")))
          (with-buffer-read-only buffer nil
            (erase-buffer buffer)
            (insert-string (buffer-start-point buffer) content))
          (setf (buffer-read-only-p buffer) t)
          (dap-set-stopped-overlay session buffer line)))
       ((and (not success-p)
             (eq frame (dap-session-frame session)))
        (dap-append-output
         session
         (format nil "~&[source] ~a~%"
                 (or (dap-field response "message")
                     "could not retrieve adapter source"))
         "stderr"))))))

(defun dap-show-frame-source (session frame)
  (let* ((source (dap-field frame "source"))
         (path (and source (dap-source-path session source)))
         (line (or (dap-field frame "line") 1))
         (reference (and source (dap-field source "sourceReference" 0))))
    (cond
      ((and (integerp reference) (plusp reference))
       (dap-show-source-reference session frame source reference line))
      ((and path (probe-file path))
       (let ((buffer (find-file-buffer path)))
         (dap-attach-breakpoints-to-buffer buffer)
         (dap-set-stopped-overlay session buffer line path)))
      (t
       (dap-append-output
        session
        (format nil "~&[source] unavailable for frame ~a~%"
                (or (dap-field frame "name") "<unnamed>"))
        "stderr")))))

(defun dap-fetch-variables (session reference callback)
  (if (or (not (integerp reference)) (zerop reference))
      (funcall callback session t '())
      (let ((arguments (dap-object "variablesReference" reference)))
        (dap-send-request
         session "variables" arguments
         (lambda (session success-p body response)
           (declare (ignore response))
           (let ((variables
                   (and success-p
                        (dap-sequence-list
                         (dap-field body "variables")))))
             (funcall callback session success-p
                      (if variables
                          (subseq variables 0
                                  (min *dap-variable-count-limit*
                                       (length variables)))
                          '()))))))))

(defun dap-refresh-scopes (session frame)
  (let ((frame-id (dap-field frame "id")))
    (unless (integerp frame-id)
      (return-from dap-refresh-scopes))
    (dap-send-request
     session "scopes" (dap-object "frameId" frame-id)
     (lambda (session success-p body response)
       (declare (ignore response))
       (when (and success-p
                  (eq frame (dap-session-frame session))
                  (dap-session-stopped-p session))
         (let ((scopes (dap-sequence-list (dap-field body "scopes"))))
           (setf (dap-session-scopes session) scopes
                 (dap-session-variables session) '())
           (if (null scopes)
               (dap-render-info-buffer session)
               (let ((remaining (length scopes))
                     (values '()))
                 (dolist (scope scopes)
                   (let ((scope scope))
                     (dap-fetch-variables
                      session (dap-field scope "variablesReference" 0)
                      (lambda (session success-p variables)
                        (when (and success-p
                                   (eq frame (dap-session-frame session)))
                          (push (cons scope variables) values))
                        (decf remaining)
                        (when (and (eq session *dap-session*)
                                   (eq frame (dap-session-frame session))
                                   (dap-session-stopped-p session)
                                   (zerop remaining))
                          (setf (dap-session-variables session)
                                (nreverse values))
                          (dap-render-info-buffer session))))))))))))))

(defun dap-evaluate-expression-async
    (session expression context callback &optional frame)
  (let ((arguments (dap-object "expression" expression
                               "context" context))
        (frame (or frame (dap-session-frame session))))
    (alexandria:when-let ((frame-id (and frame (dap-field frame "id"))))
      (setf (gethash "frameId" arguments) frame-id))
    (dap-send-request
     session "evaluate" arguments
     (lambda (session success-p body response)
       (funcall callback session success-p body response)))))

(defun dap-refresh-watches (session)
  (let ((watches (copy-list *dap-watches*))
        (frame (dap-session-frame session)))
    (if (null watches)
        (progn
          (setf (dap-session-watch-values session) '())
          (dap-render-info-buffer session))
        (let ((remaining (length watches))
              (values '()))
          (dolist (expression watches)
            (let ((expression expression))
              (dap-evaluate-expression-async
               session expression "watch"
               (lambda (session success-p body response)
                 (push (list expression
                             success-p
                             (if success-p
                                 (dap-field body "result" "")
                                 (or (dap-field response "message")
                                     "evaluation failed"))
                             (and success-p (dap-field body "type")))
                       values)
                 (decf remaining)
                 (when (and (eq session *dap-session*)
                            (eq frame (dap-session-frame session))
                            (dap-session-stopped-p session)
                            (equal watches *dap-watches*)
                            (zerop remaining))
                   (setf (dap-session-watch-values session)
                         (nreverse values))
                   (dap-render-info-buffer session))))))))))

(defun dap-select-frame-object (session frame &key (show-source-p t))
  (unless (and frame (member frame (dap-session-frames session) :test #'eq))
    (editor-error "That Dape frame is no longer available"))
  (setf (dap-session-frame session) frame)
  (when show-source-p (dap-show-frame-source session frame))
  (dap-refresh-scopes session frame)
  (dap-refresh-watches session)
  frame)

(defun dap-refresh-stack (session)
  (let ((thread-id (dap-session-thread-id session)))
    (unless (integerp thread-id)
      (setf (dap-session-frames session) '()
            (dap-session-frame session) nil)
      (dap-render-info-buffer session)
      (return-from dap-refresh-stack))
    (dap-send-request
     session "stackTrace"
     (dap-object "threadId" thread-id "startFrame" 0 "levels" 200)
     (lambda (session success-p body response)
       (declare (ignore response))
       (when (and success-p
                  (dap-session-stopped-p session)
                  (eql thread-id (dap-session-thread-id session)))
         (let ((frames (dap-sequence-list (dap-field body "stackFrames"))))
           (setf (dap-session-frames session) frames)
           (if frames
               (dap-select-frame-object session (first frames))
               (progn
                 (setf (dap-session-frame session) nil)
                 (dap-render-info-buffer session)))))))))

(defun dap-refresh-stopped-data (session)
  (unless (dap-session-stopped-p session)
    (return-from dap-refresh-stopped-data))
  (dap-send-request
   session "threads" (dap-empty-object)
   (lambda (session success-p body response)
     (declare (ignore response))
     (when (and success-p (dap-session-stopped-p session))
       (let ((threads (dap-sequence-list (dap-field body "threads"))))
         (setf (dap-session-threads session) threads)
         (unless (find (dap-session-thread-id session) threads
                       :key (lambda (thread) (dap-field thread "id"))
                       :test #'eql)
           (setf (dap-session-thread-id session)
                 (and threads (dap-field (first threads) "id"))))
         (dap-refresh-stack session))))))

(defun dap-frame-source-label (frame)
  (let* ((source (dap-field frame "source"))
         (path (and source (dap-field source "path")))
         (name (or (and source (dap-field source "name")) path "<source>"))
         (line (dap-field frame "line")))
    (format nil "~a~@[:~a~]" name line)))

(defun dap-frame-label (frame)
  (format nil "~a — ~a"
          (or (dap-field frame "name") "<frame>")
          (dap-frame-source-label frame)))

(defun dap-thread-label (thread)
  (format nil "~a: ~a"
          (or (dap-field thread "id") "?")
          (or (dap-field thread "name") "<thread>")))

(defun dap-write-info-line (point text &optional attribute navigation)
  (let ((line (line-number-at-point point)))
    (insert-string point text :attribute attribute)
    (insert-string point (string #\Newline))
    (when navigation
      (setf (gethash line *dap-info-navigation*) navigation))))

(defun dap-render-variable (variable)
  (format nil "  ~a = ~a~@[ : ~a~]"
          (or (dap-field variable "name") "?")
          (or (dap-field variable "value") "")
          (dap-field variable "type")))

(defun dap-render-info-contents (session buffer)
  (clrhash *dap-info-navigation*)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (let ((point (buffer-start-point buffer)))
      (dap-write-info-line
       point
       (format nil "Dape: ~a  state: ~a"
               (dap-config-name (dap-session-config session))
               (string-downcase (symbol-name (dap-session-state session))))
       'dap-info-heading-attribute)
      (when (dap-session-stopped-reason session)
        (dap-write-info-line
         point (format nil "Stopped: ~a" (dap-session-stopped-reason session))))
      (when (dap-session-exit-code session)
        (dap-write-info-line
         point (format nil "Exit code: ~a" (dap-session-exit-code session))))
      (dap-write-info-line point "")
      (dap-write-info-line point "Threads" 'dap-info-heading-attribute)
      (if (dap-session-threads session)
          (dolist (thread (dap-session-threads session))
            (dap-write-info-line
             point
             (format nil "~:[ ~;*~] ~a"
                     (eql (dap-field thread "id")
                          (dap-session-thread-id session))
                     (dap-thread-label thread))
             nil (list :thread thread)))
          (dap-write-info-line point "  <none>"))
      (dap-write-info-line point "")
      (dap-write-info-line point "Stack" 'dap-info-heading-attribute)
      (if (dap-session-frames session)
          (dolist (frame (dap-session-frames session))
            (dap-write-info-line
             point
             (format nil "~:[ ~;*~] ~a"
                     (eq frame (dap-session-frame session))
                     (dap-frame-label frame))
             nil (list :frame frame)))
          (dap-write-info-line point "  <none>"))
      (dap-write-info-line point "")
      (dap-write-info-line point "Variables" 'dap-info-heading-attribute)
      (if (dap-session-variables session)
          (dolist (entry (dap-session-variables session))
            (let ((scope (car entry))
                  (variables (cdr entry)))
              (dap-write-info-line
               point (format nil "~a" (or (dap-field scope "name") "Scope")))
              (if variables
                  (dolist (variable variables)
                    (dap-write-info-line point (dap-render-variable variable)))
                  (dap-write-info-line point "  <empty>"))))
          (dap-write-info-line point "  <unavailable>"))
      (dap-write-info-line point "")
      (dap-write-info-line point "Watches" 'dap-info-heading-attribute)
      (if (dap-session-watch-values session)
          (dolist (entry (dap-session-watch-values session))
            (destructuring-bind (expression success-p result type) entry
              (dap-write-info-line
               point
               (format nil "  ~a = ~a~@[ : ~a~]"
                       expression result type)
               (unless success-p 'dap-info-error-attribute))))
          (dap-write-info-line point "  <none>"))
      (dap-write-info-line point "")
      (dap-write-info-line point "Output" 'dap-info-heading-attribute)
      (let ((output (dap-session-output session)))
        (if (plusp (length output))
            (insert-string point (dap-trim-string output 16000))
            (dap-write-info-line point "  <none>")))
      (buffer-start (buffer-point buffer))))
  (setf (buffer-read-only-p buffer) t)
  (buffer-unmark buffer))

(defun dap-render-info-buffer (session)
  (alexandria:when-let ((buffer (get-buffer *dap-info-buffer-name*)))
    (unless (deleted-buffer-p buffer)
      (dap-render-info-contents session buffer))))

(define-major-mode lem-yath-dap-info-mode
    lem/buffer/fundamental-mode:fundamental-mode
    (:name "Dape-Info" :keymap *dap-info-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-major-mode lem-yath-dap-repl-mode
    lem/buffer/fundamental-mode:fundamental-mode
    (:name "Dape-REPL" :keymap *dap-repl-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defun dap-show-info ()
  (let* ((session (or *dap-session*
                      (editor-error "No Dape session has been started")))
         (buffer (make-buffer *dap-info-buffer-name*)))
    (change-buffer-mode buffer 'lem-yath-dap-info-mode)
    (dap-render-info-contents session buffer)
    (switch-to-buffer buffer)))

(define-command lem-yath-dape-info () ()
  "Show threads, stack, variables, watches, and output for Dape."
  (dap-show-info))

(define-command lem-yath-dape-info-refresh () ()
  "Refresh the current Dape information buffer."
  (let ((session (dap-current-session)))
    (if (dap-session-stopped-p session)
        (dap-refresh-stopped-data session)
        (dap-render-info-buffer session))))

(define-command lem-yath-dape-info-visit () ()
  "Visit the thread or frame on the current Dape information line."
  (let* ((entry (gethash (line-number-at-point (current-point))
                         *dap-info-navigation*))
         (session (dap-current-stopped-session)))
    (case (first entry)
      (:frame (dap-select-frame-object session (second entry)))
      (:thread
       (setf (dap-session-thread-id session)
             (dap-field (second entry) "id"))
       (dap-refresh-stack session))
      (otherwise (message "No Dape item on this line")))))

(define-command lem-yath-dape-info-quit () ()
  "Quit the Dape information window."
  (quit-active-window))

;;; Breakpoint commands and gutter ------------------------------------------

(defun dap-sync-breakpoint-path (path)
  (when (dap-session-ready-p)
    (dap-send-set-breakpoints *dap-session* path))
  (dap-redraw))

(defun dap-create-breakpoint (path line)
  (let ((breakpoint
          (make-dap-breakpoint
           :path path :line line
           :point (and (dap-buffer-for-path path)
                       (dap-make-breakpoint-point
                        (dap-buffer-for-path path) line)))))
    (dap-store-breakpoint breakpoint)))

(defun dap-ensure-current-breakpoint ()
  (multiple-value-bind (breakpoint path line) (dap-current-breakpoint)
    (values (or breakpoint (dap-create-breakpoint path line)) path line)))

(define-command lem-yath-dape-breakpoint-toggle () ()
  "Toggle a source breakpoint on the current line."
  (multiple-value-bind (breakpoint path line) (dap-current-breakpoint)
    (if breakpoint
        (progn
          (dap-remove-breakpoint breakpoint)
          (message "Removed breakpoint at ~a:~d" path line))
        (progn
          (dap-create-breakpoint path line)
          (message "Breakpoint at ~a:~d" path line)))
    (dap-sync-breakpoint-path path)))

(defun dap-set-current-breakpoint-field (reader writer prompt)
  (multiple-value-bind (breakpoint path line) (dap-ensure-current-breakpoint)
    (declare (ignore line))
    (let* ((old (funcall reader breakpoint))
           (value (prompt-for-string prompt :initial-value (or old ""))))
      (funcall writer (unless (zerop (length value)) value) breakpoint)
      (dap-clear-breakpoint-verification breakpoint)
      (dap-sync-breakpoint-path path)
      breakpoint)))

(define-command lem-yath-dape-breakpoint-expression () ()
  "Set or clear the condition on the current source breakpoint."
  (dap-set-current-breakpoint-field
   #'dap-breakpoint-condition
   (lambda (value breakpoint)
     (setf (dap-breakpoint-condition breakpoint) value))
   "Breakpoint condition (empty clears): "))

(define-command lem-yath-dape-breakpoint-hits () ()
  "Set or clear the hit condition on the current source breakpoint."
  (dap-set-current-breakpoint-field
   #'dap-breakpoint-hit-condition
   (lambda (value breakpoint)
     (setf (dap-breakpoint-hit-condition breakpoint) value))
   "Breakpoint hit condition (empty clears): "))

(define-command lem-yath-dape-breakpoint-log () ()
  "Set or clear the log message on the current source breakpoint."
  (dap-set-current-breakpoint-field
   #'dap-breakpoint-log-message
   (lambda (value breakpoint)
     (setf (dap-breakpoint-log-message breakpoint) value))
   "Log breakpoint message (empty clears): "))

(define-command lem-yath-dape-breakpoint-function () ()
  "Toggle a named function breakpoint."
  (let* ((name (prompt-for-string "Function breakpoint: "
                                  :history-symbol
                                  'lem-yath-dape-function-breakpoint))
         (existing
           (find name *dap-function-breakpoints*
                 :key #'dap-function-breakpoint-name :test #'string=)))
    (when (zerop (length name))
      (editor-error "Function name cannot be empty"))
    (if existing
        (progn
          (setf *dap-function-breakpoints*
                (delete existing *dap-function-breakpoints*))
          (message "Removed function breakpoint: ~a" name))
        (progn
          (push (make-dap-function-breakpoint :name name)
                *dap-function-breakpoints*)
          (message "Function breakpoint: ~a" name)))
    (when (and (dap-session-ready-p)
               (dap-capability-p *dap-session*
                                 "supportsFunctionBreakpoints"))
      (dap-send-function-breakpoints *dap-session*))))

(define-command lem-yath-dape-breakpoint-remove-all () ()
  "Remove every source and function breakpoint."
  (let ((paths (loop :for path :being :the :hash-key :in *dap-breakpoints*
                     :collect path)))
    (maphash
     (lambda (path breakpoints)
       (declare (ignore path))
       (dolist (breakpoint breakpoints)
         (dap-delete-breakpoint-point breakpoint)))
     *dap-breakpoints*)
    (clrhash *dap-breakpoints*)
    (setf *dap-function-breakpoints* '())
    (when (dap-session-ready-p)
      (dolist (path paths)
        (dap-send-set-breakpoints *dap-session* path))
      (when (dap-capability-p *dap-session* "supportsFunctionBreakpoints")
        (dap-send-function-breakpoints *dap-session*)))
    (dap-redraw)
    (message "Removed all Dape breakpoints")))

(defun dap-gutter-breakpoint (buffer line)
  (alexandria:when-let ((path (dap-buffer-path buffer)))
    (dap-breakpoint-at path line)))

(defun dap-make-gutter-content (string attribute)
  (lem/buffer/line:make-content
   :string string :attributes `((0 ,(length string) ,attribute))))

(defun dap-gutter-content (buffer point)
  (let* ((line (line-number-at-point point))
         (path (dap-buffer-path buffer))
         (session *dap-session*))
    (cond
      ((and session path
            (equal path (dap-session-stopped-path session))
            (eql line (dap-session-stopped-line session)))
       (dap-make-gutter-content "▶" 'dap-stopped-gutter-attribute))
      ((alexandria:when-let ((breakpoint (dap-gutter-breakpoint buffer line)))
         (if (dap-breakpoint-verified-p breakpoint)
             (dap-make-gutter-content "●" 'dap-breakpoint-attribute)
             (dap-make-gutter-content "○"
                                      'dap-breakpoint-pending-attribute))))
      (t nil))))

(defun dap-breakpoint-mode-enable ()
  (dap-attach-breakpoints-to-buffer (current-buffer)))

(defun dap-breakpoint-mode-disable ()
  (dap-detach-breakpoints-from-buffer (current-buffer)))

(define-minor-mode lem-yath-dap-breakpoint-mode
    (:name "Dape"
     :enable-hook 'dap-breakpoint-mode-enable
     :disable-hook 'dap-breakpoint-mode-disable)
  "Show and maintain Dape breakpoints in programming buffers.")

(defun dap-breakpoint-mode-active-p (buffer)
  (member 'lem-yath-dap-breakpoint-mode (buffer-minor-modes buffer)))

(defun dap-sync-buffer-mode (buffer)
  (unless (deleted-buffer-p buffer)
    (let ((wanted (programming-buffer-p buffer))
          (active (dap-breakpoint-mode-active-p buffer)))
      (cond
        ((and wanted (not active))
         (with-current-buffer buffer
           (lem-yath-dap-breakpoint-mode t)))
        ((and (not wanted) active)
         (with-current-buffer buffer
           (lem-yath-dap-breakpoint-mode nil)))
        (wanted (dap-attach-breakpoints-to-buffer buffer))))))

(defun dap-find-file-hook (buffer)
  (dap-sync-buffer-mode buffer))

(defun dap-post-command-hook ()
  (dap-sync-buffer-mode (current-buffer)))

(defun dap-kill-buffer-hook (&optional (buffer (current-buffer)))
  (dap-detach-breakpoints-from-buffer buffer))

(defmethod lem-core:compute-left-display-area-content
    ((mode lem-yath-dap-breakpoint-mode) buffer point)
  (declare (ignore mode))
  (let ((other-content (call-next-method))
        (content (dap-gutter-content buffer point)))
    (if content
        (join-left-display-content content other-content)
        other-content)))

;;; Execution, inspection, and teardown commands ----------------------------

(defun dap-mark-running (session &key force)
  (when (and (dap-active-session-p session)
             (or force
                 (not (eq (dap-session-state session) :stopped))))
    (setf (dap-session-state session) :running
          (dap-session-frames session) '()
          (dap-session-frame session) nil
          (dap-session-scopes session) '()
          (dap-session-variables session) '())
    (dap-clear-stopped-location session)
    (dap-render-info-buffer session)))

(defun dap-send-thread-command (command &optional extra)
  (let* ((session (dap-current-stopped-session))
         (arguments (dap-object "threadId" (dap-session-thread-id session))))
    (when (dap-capability-p session "supportsSingleThreadExecutionRequests")
      (setf (gethash "singleThread" arguments) yason:false))
    (when extra
      (maphash (lambda (key value) (setf (gethash key arguments) value)) extra))
    (when (and (member command '("next" "stepIn" "stepOut")
                       :test #'string=)
               (dap-capability-p session "supportsSteppingGranularity"))
      (setf (gethash "granularity" arguments) "line"))
    (dap-send-request
     session command arguments
     (lambda (session success-p body response)
       (declare (ignore body))
       (if success-p
           (dap-mark-running session)
           (message "Dape ~a failed: ~a" command
                    (or (dap-field response "message") "unknown error")))))))

(define-command lem-yath-dape-continue () ()
  "Continue the stopped debuggee."
  (dap-send-thread-command "continue"))

(define-command lem-yath-dape-next () ()
  "Step over in the selected thread."
  (dap-send-thread-command "next"))

(define-command lem-yath-dape-step-in () ()
  "Step into in the selected thread."
  (dap-send-thread-command "stepIn"))

(define-command lem-yath-dape-step-out () ()
  "Step out in the selected thread."
  (dap-send-thread-command "stepOut"))

(defun dap-send-pause-for-thread (session thread-id)
  (dap-send-request
   session "pause" (dap-object "threadId" thread-id)
   (lambda (session success-p body response)
     (declare (ignore session body))
     (unless success-p
       (message "Dape pause failed: ~a"
                (or (dap-field response "message") "unknown error"))))))

(define-command lem-yath-dape-pause () ()
  "Pause the running debuggee."
  (let ((session (dap-current-session)))
    (cond
      ((integerp (dap-session-thread-id session))
       (dap-send-pause-for-thread session (dap-session-thread-id session)))
      (t
       (dap-send-request
        session "threads" (dap-empty-object)
        (lambda (session success-p body response)
          (declare (ignore response))
          (let* ((threads (and success-p
                               (dap-sequence-list
                                (dap-field body "threads"))))
                 (id (and threads (dap-field (first threads) "id"))))
            (if (integerp id)
                (progn
                  (setf (dap-session-thread-id session) id)
                  (dap-send-pause-for-thread session id))
                (message "Dape has no pausable thread")))))))))

(define-command lem-yath-dape-restart-frame () ()
  "Restart the selected stack frame when supported by the adapter."
  (let* ((session (dap-current-stopped-session))
         (frame (or (dap-session-frame session)
                    (editor-error "No selected Dape frame"))))
    (unless (dap-capability-p session "supportsRestartFrame")
      (editor-error "This adapter does not support restartFrame"))
    (dap-send-request
     session "restartFrame" (dap-object "frameId" (dap-field frame "id"))
     (lambda (session success-p body response)
       (declare (ignore body))
       (if success-p
           (dap-mark-running session)
           (message "Dape restart-frame failed: ~a"
                    (or (dap-field response "message") "unknown error")))))))

(define-command lem-yath-dape-until () ()
  "Continue the selected thread to the current source position."
  (let* ((session (dap-current-stopped-session))
         (path (or (dap-buffer-path)
                   (editor-error "Run-to-cursor requires a file")))
         (line (line-number-at-point (current-point)))
         (column (dap-point-utf16-column (current-point))))
    (unless (dap-capability-p session "supportsGotoTargetsRequest")
      (editor-error "This adapter does not support run-to-cursor"))
    (dap-send-request
     session "gotoTargets"
     (dap-object "source" (dap-source-object path)
                 "line" line "column" column)
     (lambda (session success-p body response)
       (let* ((targets (and success-p
                            (dap-sequence-list
                             (dap-field body "targets"))))
              (target (first targets)))
         (if target
             (dap-send-request
              session "goto"
              (dap-object "threadId" (dap-session-thread-id session)
                          "targetId" (dap-field target "id"))
              (lambda (session success-p body response)
                (declare (ignore body))
                (if success-p
                    (dap-mark-running session)
                    (message "Dape goto failed: ~a"
                             (or (dap-field response "message")
                                 "unknown error")))))
             (message "Dape found no target at ~a:~d: ~a"
                      path line
                      (or (dap-field response "message") "unsupported"))))))))

(defun dap-restart-session (session)
  (let ((config (dap-session-config session)))
    (if (dap-active-session-p session)
        (progn
          (setf (dap-session-restart-config session) config)
          (dap-disconnect-session session t))
        (dap-start-session config))))

(define-command lem-yath-dape-restart () ()
  "Restart the active Dape session."
  (let ((session (dap-current-session)))
    (if (dap-capability-p session "supportsRestartRequest")
        (progn
          (dap-mark-running session :force t)
          (dap-send-request
           session "restart"
           (dap-object
            "arguments"
            (dap-copy-object
             (dap-config-arguments (dap-session-config session))))
           (lambda (session success-p body response)
             (declare (ignore body))
             (unless success-p
               (message "Adapter restart failed; restarting its process: ~a"
                        (or (dap-field response "message") "unknown error"))
               (dap-restart-session session)))))
        (dap-restart-session session))))

(defun dap-evaluation-initial-value ()
  (or (ignore-errors (identifier-at-point (current-point))) ""))

(define-command lem-yath-dape-evaluate-expression () ()
  "Evaluate an expression in the selected Dape frame."
  (let* ((session (dap-current-stopped-session))
         (expression
           (prompt-for-string "Evaluate: "
                              :initial-value (dap-evaluation-initial-value)
                              :history-symbol 'lem-yath-dape-evaluate)))
    (when (zerop (length expression))
      (editor-error "Expression cannot be empty"))
    (dap-evaluate-expression-async
     session expression "repl"
     (lambda (session success-p body response)
       (declare (ignore session))
       (if success-p
           (message "~a => ~a" expression (dap-field body "result" ""))
           (message "Dape evaluation failed: ~a"
                    (or (dap-field response "message") "unknown error")))))))

(define-command lem-yath-dape-watch-dwim () ()
  "Add an expression to the Dape watch list, or remove an existing one."
  (let* ((session (dap-current-stopped-session))
         (expression
           (prompt-for-string "Watch expression: "
                              :initial-value (dap-evaluation-initial-value)
                              :history-symbol 'lem-yath-dape-watch)))
    (when (zerop (length expression))
      (editor-error "Watch expression cannot be empty"))
    (if (member expression *dap-watches* :test #'string=)
        (progn
          (setf *dap-watches*
                (delete expression *dap-watches* :test #'string=))
          (message "Removed Dape watch: ~a" expression))
        (progn
          (setf *dap-watches* (append *dap-watches* (list expression)))
          (message "Watching: ~a" expression)))
    (dap-refresh-watches session)))

(defun dap-render-repl-buffer (session)
  (let ((buffer (make-buffer *dap-repl-buffer-name*)))
    (change-buffer-mode buffer 'lem-yath-dap-repl-mode)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer)
                     (dap-session-output session)))
    (setf (buffer-read-only-p buffer) t)
    (buffer-end (buffer-point buffer))
    (switch-to-buffer buffer)))

(define-command lem-yath-dape-repl () ()
  "Evaluate in the Dape REPL context and show the transcript."
  (let* ((session (dap-current-stopped-session))
         (expression
           (prompt-for-string "Dape REPL: "
                              :initial-value (dap-evaluation-initial-value)
                              :history-symbol 'lem-yath-dape-repl)))
    (when (zerop (length expression))
      (editor-error "Expression cannot be empty"))
    (dap-evaluate-expression-async
     session expression "repl"
     (lambda (session success-p body response)
       (dap-append-output
        session
        (if success-p
            (format nil "~&> ~a~%~a~%" expression
                    (dap-field body "result" ""))
            (format nil "~&> ~a~%error: ~a~%" expression
                    (or (dap-field response "message") "unknown error"))))
       (dap-render-repl-buffer session)))))

(define-command lem-yath-dape-memory () ()
  "Read memory using the selected frame's instruction reference."
  (let* ((session (dap-current-stopped-session))
         (frame (dap-session-frame session))
         (initial (and frame
                       (dap-field frame "instructionPointerReference")))
         (reference
           (prompt-for-string "Memory reference: "
                              :initial-value (or initial "")
                              :history-symbol 'lem-yath-dape-memory))
         (count (prompt-for-integer "Bytes: " :initial-value 64
                                    :min 1 :max 65536)))
    (unless (dap-capability-p session "supportsReadMemoryRequest")
      (editor-error "This adapter does not support readMemory"))
    (dap-send-request
     session "readMemory"
     (dap-object "memoryReference" reference "offset" 0 "count" count)
     (lambda (session success-p body response)
       (dap-append-output
        session
        (if success-p
            (format nil "~&[memory ~a] address=~a unreadable=~a~%~a~%"
                    reference (dap-field body "address")
                    (or (dap-field body "unreadableBytes") 0)
                    (or (dap-field body "data") ""))
            (format nil "~&[memory] error: ~a~%"
                    (or (dap-field response "message") "unknown error"))))
       (dap-render-repl-buffer session)))))

(define-command lem-yath-dape-disassemble () ()
  "Disassemble around the selected frame when supported."
  (let* ((session (dap-current-stopped-session))
         (frame (dap-session-frame session))
         (reference (and frame
                         (dap-field frame "instructionPointerReference"))))
    (unless (dap-capability-p session "supportsDisassembleRequest")
      (editor-error "This adapter does not support disassemble"))
    (unless reference
      (editor-error "The selected frame has no instruction reference"))
    (dap-send-request
     session "disassemble"
     (dap-object "memoryReference" reference
                 "offset" 0 "instructionOffset" -10
                 "instructionCount" 40 "resolveSymbols" yason:true)
     (lambda (session success-p body response)
       (if success-p
           (dolist (instruction
                     (dap-sequence-list (dap-field body "instructions")))
             (dap-append-output
              session
              (format nil "~&~a  ~@[~a: ~]~a~%"
                      (or (dap-field instruction "address") "")
                      (dap-field instruction "symbol")
                      (or (dap-field instruction "instruction") ""))))
           (dap-append-output
            session
            (format nil "~&[disassemble] error: ~a~%"
                    (or (dap-field response "message") "unknown error"))))
       (dap-render-repl-buffer session)))))

(defun dap-prompt-choice (prompt objects label-function history)
  (let* ((choices (mapcar (lambda (object)
                            (cons (funcall label-function object) object))
                          objects))
         (labels (mapcar #'car choices))
         (choice
           (prompt-for-string
            prompt
            :completion-function
            (lambda (input) (prescient-filter input labels))
            :test-function
            (lambda (input) (member input labels :test #'string=))
            :history-symbol history)))
    (cdr (assoc choice choices :test #'string=))))

(define-command lem-yath-dape-select-thread () ()
  "Select a Dape thread."
  (let* ((session (dap-current-stopped-session))
         (thread (dap-prompt-choice "Dape thread: "
                                    (dap-session-threads session)
                                    #'dap-thread-label
                                    'lem-yath-dape-thread)))
    (unless thread (editor-error "No thread selected"))
    (setf (dap-session-thread-id session) (dap-field thread "id"))
    (dap-refresh-stack session)))

(define-command lem-yath-dape-select-stack () ()
  "Select a Dape stack frame."
  (let* ((session (dap-current-stopped-session))
         (frame (dap-prompt-choice "Dape frame: "
                                   (dap-session-frames session)
                                   #'dap-frame-label
                                   'lem-yath-dape-frame)))
    (unless frame (editor-error "No frame selected"))
    (dap-select-frame-object session frame)))

(define-command lem-yath-dape-select-session () ()
  "Show the foreground Dape session."
  (dap-show-info))

(defun dap-select-relative-frame (delta)
  (let* ((session (dap-current-stopped-session))
         (frames (dap-session-frames session))
         (index (position (dap-session-frame session) frames :test #'eq))
         (target (and index (+ index delta))))
    (unless (and target (<= 0 target) (< target (length frames)))
      (editor-error "No Dape frame in that direction"))
    (dap-select-frame-object session (nth target frames))))

(define-command lem-yath-dape-stack-select-down () ()
  "Select the next older Dape stack frame."
  (dap-select-relative-frame 1))

(define-command lem-yath-dape-stack-select-up () ()
  "Select the next newer Dape stack frame."
  (dap-select-relative-frame -1))

(defun dap-finish-debuggee-buffer (buffer)
  "Close BUFFER's debuggee process and retain its transcript as plain text."
  (unless (deleted-buffer-p buffer)
    (let ((process (lem-shell-mode::buffer-process buffer)))
      (remove-hook (variable-value 'kill-buffer-hook :buffer buffer)
                   'lem-shell-mode::delete-shell-buffer)
      (setf (buffer-value buffer 'process) nil)
      (when process
        (ignore-errors (lem-process:delete-process process))))
    (with-current-buffer buffer
      (change-buffer-mode
       buffer 'lem/buffer/fundamental-mode:fundamental-mode)
      (setf (buffer-read-only-p buffer) t))))

(defun dap-cleanup-session-resources (session &key keep-debuggee-p)
  (when session
    (setf (dap-session-expected-exit-p session) t)
    (alexandria:when-let ((timer (dap-session-monitor-timer session)))
      (ignore-errors (stop-timer timer))
      (setf (dap-session-monitor-timer session) nil))
    (alexandria:when-let ((socket (dap-session-socket session)))
      (ignore-errors (usocket:socket-close socket))
      (setf (dap-session-socket session) nil
            (dap-session-stream session) nil))
    (alexandria:when-let ((process (dap-session-process session)))
      (when (ignore-errors (uiop:process-alive-p process))
        (ignore-errors (uiop:terminate-process process :urgent t)))
      (ignore-errors (uiop:close-streams process))
      (ignore-errors (uiop:wait-process process))
      (setf (dap-session-process session) nil))
    (dolist (accessor (list #'dap-session-reader-thread
                            #'dap-session-adapter-output-thread
                            #'dap-session-adapter-error-thread))
      (alexandria:when-let ((thread (funcall accessor session)))
        (when (and (not (eq thread (bt2:current-thread)))
                   (ignore-errors (bt2:thread-alive-p thread)))
          (ignore-errors (bt2:destroy-thread thread)))))
    (setf (dap-session-reader-thread session) nil
          (dap-session-adapter-output-thread session) nil
          (dap-session-adapter-error-thread session) nil)
    (unless keep-debuggee-p
      (dolist (buffer (dap-session-debuggee-buffers session))
        (ignore-errors (dap-finish-debuggee-buffer buffer))))
    ;; A kept debuggee is owned by its shell buffer from this point on; a later
    ;; Dape session must not reclaim it as part of cleaning the old session.
    (setf (dap-session-debuggee-buffers session) '())
    (clrhash (dap-session-pending session))
    (dap-clear-stopped-location session)))

(defun dap-finalize-session (session state message &key keep-debuggee-p)
  (when (dap-active-session-p session)
    ;; Publish the terminal state before teardown.  Buffer/process cleanup can
    ;; run hooks, so late or reentrant protocol acknowledgements must already
    ;; see this session as inactive.
    (let ((restart-config (dap-session-restart-config session)))
      (setf (dap-session-restart-config session) nil
            (dap-session-state session) state)
    (dap-append-output session (format nil "~&[dape] ~a~%" message))
    (dap-cleanup-session-resources session
                                   :keep-debuggee-p keep-debuggee-p)
    (dap-render-info-buffer session)
      (message "~a" message)
      (when restart-config
        (dap-start-session restart-config)))))

(defun dap-session-fail (session message)
  (dap-finalize-session
   session :failed (format nil "Dape failed: ~a" message)
   :keep-debuggee-p (dap-session-disconnect-keep-debuggee-p session)))

(defun dap-disconnect-session (session terminate-debuggee-p
                               &key keep-debuggee-p)
  (setf (dap-session-disconnect-keep-debuggee-p session) keep-debuggee-p)
  (if (not (dap-active-session-p session))
      (dap-finalize-session session :terminated "Dape session closed"
                            :keep-debuggee-p keep-debuggee-p)
      (let ((arguments
              (dap-object "terminateDebuggee"
                          (dap-json-true terminate-debuggee-p))))
        (dap-send-request
         session "disconnect" arguments
         (lambda (session success-p body response)
           (declare (ignore success-p body response))
           (dap-finalize-session
            session :terminated
            (if terminate-debuggee-p
                "Dape session and debuggee stopped"
                "Dape disconnected; debuggee kept running")
            :keep-debuggee-p keep-debuggee-p))))))

(define-command lem-yath-dape-disconnect-quit () ()
  "Disconnect Dape while leaving the debuggee running."
  (dap-disconnect-session (dap-current-session) nil :keep-debuggee-p t))

(define-command lem-yath-dape-kill () ()
  "Terminate the active debuggee and Dape session."
  (let ((session (dap-current-session)))
    (if (dap-capability-p session "supportsTerminateRequest")
        (dap-send-request
         session "terminate" (dap-object "restart" yason:false)
         (lambda (session success-p body response)
           (declare (ignore success-p body response))
           (when (dap-active-session-p session)
             (dap-disconnect-session session t))))
        (dap-disconnect-session session t))))

(define-command lem-yath-dape-quit () ()
  "Quit every Dape session (one foreground session in this profile)."
  (lem-yath-dape-kill))

(define-command lem-yath-dape () ()
  "Start a stock Dape adapter configuration for the current buffer."
  (when (and (dap-active-session-p)
             (not (prompt-for-y-or-n-p
                   "A Dape session is active; replace it")))
    (return-from lem-yath-dape))
  (let ((name (dap-prompt-config-name)))
    (dap-start-session (dap-make-config name))))

;;; Installation and stock Dape key contract --------------------------------

(define-key *dap-command-keymap* "d" 'lem-yath-dape)
(define-key *dap-command-keymap* "p" 'lem-yath-dape-pause)
(define-key *dap-command-keymap* "c" 'lem-yath-dape-continue)
(define-key *dap-command-keymap* "n" 'lem-yath-dape-next)
(define-key *dap-command-keymap* "s" 'lem-yath-dape-step-in)
(define-key *dap-command-keymap* "o" 'lem-yath-dape-step-out)
(define-key *dap-command-keymap* "r" 'lem-yath-dape-restart)
(define-key *dap-command-keymap* "f" 'lem-yath-dape-restart-frame)
(define-key *dap-command-keymap* "u" 'lem-yath-dape-until)
(define-key *dap-command-keymap* "i" 'lem-yath-dape-info)
(define-key *dap-command-keymap* "R" 'lem-yath-dape-repl)
(define-key *dap-command-keymap* "m" 'lem-yath-dape-memory)
(define-key *dap-command-keymap* "M" 'lem-yath-dape-disassemble)
(define-key *dap-command-keymap* "l" 'lem-yath-dape-breakpoint-log)
(define-key *dap-command-keymap* "e" 'lem-yath-dape-breakpoint-expression)
(define-key *dap-command-keymap* "h" 'lem-yath-dape-breakpoint-hits)
(define-key *dap-command-keymap* "F" 'lem-yath-dape-breakpoint-function)
(define-key *dap-command-keymap* "b" 'lem-yath-dape-breakpoint-toggle)
(define-key *dap-command-keymap* "B" 'lem-yath-dape-breakpoint-remove-all)
(define-key *dap-command-keymap* "t" 'lem-yath-dape-select-thread)
(define-key *dap-command-keymap* "T" 'lem-yath-dape-select-session)
(define-key *dap-command-keymap* "S" 'lem-yath-dape-select-stack)
(define-key *dap-command-keymap* ">" 'lem-yath-dape-stack-select-down)
(define-key *dap-command-keymap* "<" 'lem-yath-dape-stack-select-up)
(define-key *dap-command-keymap* "x" 'lem-yath-dape-evaluate-expression)
(define-key *dap-command-keymap* "w" 'lem-yath-dape-watch-dwim)
(define-key *dap-command-keymap* "D" 'lem-yath-dape-disconnect-quit)
(define-key *dap-command-keymap* "K" 'lem-yath-dape-kill)
(define-key *dap-command-keymap* "q" 'lem-yath-dape-quit)

(define-key *dap-info-mode-keymap* "Return" 'lem-yath-dape-info-visit)
(define-key *dap-info-mode-keymap* "g" 'lem-yath-dape-info-refresh)
(define-key *dap-info-mode-keymap* "q" 'lem-yath-dape-info-quit)
(define-key *dap-repl-mode-keymap* "q" 'lem-yath-dape-info-quit)
(define-key *dap-repl-mode-keymap* "e" 'lem-yath-dape-repl)

(defun enable-lem-yath-dape ()
  "Install Dape's stock prefix and global breakpoint lifecycle idempotently."
  (define-key *global-keymap* "C-x C-a" *dap-command-keymap*)
  (remove-hook *find-file-hook* 'dap-find-file-hook)
  (remove-hook *post-command-hook* 'dap-post-command-hook)
  (remove-hook (variable-value 'kill-buffer-hook :global t)
               'dap-kill-buffer-hook)
  (add-hook *find-file-hook* 'dap-find-file-hook)
  (add-hook *post-command-hook* 'dap-post-command-hook)
  (add-hook (variable-value 'kill-buffer-hook :global t)
            'dap-kill-buffer-hook)
  (dolist (buffer (buffer-list))
    (dap-sync-buffer-mode buffer)))

(initialize-editor-feature 'enable-lem-yath-dape)
