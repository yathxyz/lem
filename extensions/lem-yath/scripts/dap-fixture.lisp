(in-package :lem-yath)

;;; Installed-runtime acceptance fixture for scripts/dap-test.sh.

(defvar *dap-test-report* (uiop:getenv "LEM_YATH_DAP_REPORT"))
(defvar *dap-test-adapter* (uiop:getenv "LEM_YATH_DAP_ADAPTER"))
(defvar *dap-test-file* (uiop:getenv "LEM_YATH_DAP_FILE"))
(defvar *dap-test-adapter-report*
  (uiop:getenv "LEM_YATH_DAP_ADAPTER_REPORT"))
(defvar *dap-test-case-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_DAP_CASE_ROOT")))
(defvar *dap-test-failures* 0)
(defvar *dap-test-stage* :start)
(defvar *dap-test-deadline* (+ (dap-now-seconds) 30))
(defvar *dap-test-timer* nil)
(defvar *dap-test-buffer* nil)
(defvar *dap-test-primary-breakpoint* nil)
(defvar *dap-test-dynamic-breakpoint* nil)
(defvar *dap-test-evaluation* nil)
(defvar *dap-test-memory* nil)
(defvar *dap-test-disassembly* nil)
(defvar *dap-test-real-evaluation* nil)
(defvar *dap-test-current-real-case* nil)
(defvar *dap-test-case-breakpoint* nil)
(defvar *dap-test-case-buffer* nil)
(defvar *dap-test-debuggee-buffer* nil)
(defvar *dap-test-real-cases*
  (list
   (list :label "real-dlv-go" :config "dlv" :transport :tcp
         :file "go/main.go" :line 6 :expression "value")
   (list :label "real-lldb-c" :config "lldb-dap" :transport :stdio
         :file "c/main.c" :line 5 :expression "value")
   (list :label "real-gdb-c" :config "gdb" :transport :stdio
         :file "c/main.c" :line 5 :expression "value")
   (list :label "real-lldb-cpp" :config "lldb-dap" :transport :stdio
         :file "cpp/main.cpp" :line 5 :expression "value")
   (list :label "real-lldb-rust" :config "lldb-dap" :transport :stdio
         :file "rust/main.rs" :line 4 :expression "value")))
(defvar *dap-test-finished-p* nil)
(defvar *dap-test-tick-active-p* nil)

(defun dap-test-report (control &rest arguments)
  (with-open-file (stream *dap-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun dap-test-safe (value)
  (let ((text (princ-to-string value)))
    (map 'string
         (lambda (character)
           (if (member character '(#\Newline #\Return #\Tab))
               #\Space
               character))
         text)))

(defun dap-test-check (condition label &optional detail)
  (dap-test-report "~a ~a~@[ -- ~a~]"
                   (if condition "PASS" "FAIL")
                   label
                   (and detail (dap-test-safe detail)))
  (unless condition (incf *dap-test-failures*))
  condition)

(defun dap-test-binding (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun dap-test-buffer-text (buffer)
  (points-to-string (buffer-start-point buffer) (buffer-end-point buffer)))

(defun dap-test-adapter-events ()
  (if (probe-file *dap-test-adapter-report*)
      (alexandria:read-file-into-string *dap-test-adapter-report*)
      ""))

(defun dap-test-resources-released-p (session)
  (and (null (dap-session-process session))
       (null (dap-session-socket session))
       (null (dap-session-stream session))
       (null (dap-session-reader-thread session))
       (null (dap-session-adapter-output-thread session))
       (null (dap-session-adapter-error-thread session))
       (null (dap-session-monitor-timer session))
       (null (dap-session-debuggee-buffers session))
       (zerop (hash-table-count (dap-session-pending session)))))

(defun dap-test-rejects-framing-p (wire)
  (let* ((config (make-dap-config :name "framing-test" :transport :stdio))
         (session (%make-dap-session :generation -1 :config config)))
    (let ((*dap-session* session))
      (dap-feed-stdio session wire)
      (eq :failed (dap-session-state session)))))

(defun dap-test-reset-deadline (&optional (seconds 20))
  (setf *dap-test-deadline* (+ (dap-now-seconds) seconds)))

(defun dap-test-timeout (label)
  (when (> (dap-now-seconds) *dap-test-deadline*)
    (dap-test-check nil label
                    (and *dap-session*
                         (list (dap-session-state *dap-session*)
                               (dap-session-stopped-reason *dap-session*)
                               (dap-session-output *dap-session*))))
    (dap-test-finish)))

(defun dap-test-static-contract ()
  (dap-test-check
   (eq (dap-test-binding *global-keymap* "C-x C-a")
       *dap-command-keymap*)
   "stock-prefix-is-c-x-c-a")
  (dolist (entry
            '(("d" lem-yath-dape)
              ("p" lem-yath-dape-pause)
              ("c" lem-yath-dape-continue)
              ("n" lem-yath-dape-next)
              ("s" lem-yath-dape-step-in)
              ("o" lem-yath-dape-step-out)
              ("r" lem-yath-dape-restart)
              ("f" lem-yath-dape-restart-frame)
              ("u" lem-yath-dape-until)
              ("i" lem-yath-dape-info)
              ("R" lem-yath-dape-repl)
              ("m" lem-yath-dape-memory)
              ("M" lem-yath-dape-disassemble)
              ("l" lem-yath-dape-breakpoint-log)
              ("e" lem-yath-dape-breakpoint-expression)
              ("h" lem-yath-dape-breakpoint-hits)
              ("F" lem-yath-dape-breakpoint-function)
              ("b" lem-yath-dape-breakpoint-toggle)
              ("B" lem-yath-dape-breakpoint-remove-all)
              ("t" lem-yath-dape-select-thread)
              ("T" lem-yath-dape-select-session)
              ("S" lem-yath-dape-select-stack)
              (">" lem-yath-dape-stack-select-down)
              ("<" lem-yath-dape-stack-select-up)
              ("x" lem-yath-dape-evaluate-expression)
              ("w" lem-yath-dape-watch-dwim)
              ("D" lem-yath-dape-disconnect-quit)
              ("K" lem-yath-dape-kill)
              ("q" lem-yath-dape-quit)))
    (destructuring-bind (key command) entry
      (dap-test-check
       (eq (dap-test-binding *dap-command-keymap* key) command)
       (format nil "stock-key-~a" key))))
  (dolist (program '("python" "debugpy-adapter" "dlv" "gdb" "lldb-dap"))
    (dap-test-check (executable-find program)
                    (format nil "runtime-~a" program)))
  (dolist (entry '(("debugpy" :tcp) ("dlv" :tcp)
                   ("lldb-dap" :stdio) ("gdb" :stdio)))
    (destructuring-bind (name transport) entry
      (let ((config (dap-make-config name *dap-test-buffer*)))
        (dap-test-check (eq transport (dap-config-transport config))
                        (format nil "preset-~a-transport" name)))))
  (let ((debugpy (dap-make-config "debugpy" *dap-test-buffer*)))
    (dap-test-check
     (equal '("-m" "debugpy.adapter" "--host" "127.0.0.1"
              "--port" :port)
            (dap-config-command-arguments debugpy))
     "debugpy-stock-adapter-command")
    (multiple-value-bind (output error-output status)
        (uiop:run-program
         (list (dap-config-command debugpy)
               "-c" "import debugpy.adapter")
         :output :string :error-output :string :ignore-error-status t)
      (declare (ignore output))
      (dap-test-check (eql status 0)
                      "wrapper-python-imports-debugpy-adapter"
                      error-output)))
  (dap-test-check
   (= 1 (dap-index-after-utf8-bytes "λx" 0 2))
   "content-length-counts-utf8-octets")
  (let ((non-bmp-character (code-char #x1f600)))
    (dap-test-check
     (and non-bmp-character
          (= 4
             (dap-utf16-code-units
              (format nil "~cλ~c" #\Tab non-bmp-character))))
     "dap-columns-use-utf16-code-units"))
  (dap-test-check
   (handler-case
       (progn
         (dap-header-length
          (format nil "Content-Length: ~d"
                  (1+ *dap-maximum-message-bytes*)))
         nil)
     (error () t))
   "oversized-protocol-message-is-rejected")
  (dap-test-check
   (dap-test-rejects-framing-p
    (concatenate
     'string
     (format nil "Content-Length: 0~c~c" #\Return #\Newline)
     (make-string *dap-maximum-header-bytes* :initial-element #\X)
     (format nil "~c~c~c~c" #\Return #\Newline #\Return #\Newline)))
   "completed-oversized-header-is-rejected")
  (dap-test-check
   (dap-test-rejects-framing-p
    (format nil "Content-Length: 1~c~c~c~cλ"
            #\Return #\Newline #\Return #\Newline))
   "utf8-splitting-content-length-is-contained")
  (dap-test-check
   (equal '("-u" "DROP" "--" "KEEP=value")
          (dap-terminal-environment-arguments
           (dap-object "KEEP" "value" "DROP" :null)))
   "terminal-environment-is-literal-and-deterministic")
  (dap-test-check
   (handler-case
       (progn
         (dap-terminal-environment-arguments
          (dap-object "BAD-NAME" "value"))
         nil)
     (error () t))
   "invalid-terminal-environment-key-is-rejected")
  (dap-test-check
   (handler-case
       (progn
         (dap-terminal-environment-arguments
          (dap-object "BAD_VALUE" (format nil "bad~cvalue" #\Null)))
         nil)
     (error () t))
   "nul-terminal-environment-value-is-rejected"))

(defun dap-test-prepare-breakpoints ()
  (maphash
   (lambda (path breakpoints)
     (declare (ignore path))
     (dolist (breakpoint breakpoints)
       (dap-delete-breakpoint-point breakpoint)))
   *dap-breakpoints*)
  (clrhash *dap-breakpoints*)
  (setf *dap-function-breakpoints* '())
  (let* ((path (dap-buffer-path *dap-test-buffer*))
         (breakpoint (dap-create-breakpoint path 3)))
    (setf (dap-breakpoint-condition breakpoint) "answer == 42"
          (dap-breakpoint-hit-condition breakpoint) ">= 1"
          (dap-breakpoint-log-message breakpoint) "answer={answer}"
          *dap-test-primary-breakpoint* breakpoint)
    (push (make-dap-function-breakpoint :name "main")
          *dap-function-breakpoints*)
    (dap-test-check (dap-breakpoint-mode-active-p *dap-test-buffer*)
                    "global-breakpoint-mode-is-active")
    (dap-detach-breakpoints-from-buffer *dap-test-buffer*)
    (dap-test-check
     (and (null (dap-breakpoint-point breakpoint))
          (= 3 (dap-breakpoint-line breakpoint)))
     "breakpoint-survives-buffer-detach-in-memory")
    (dap-attach-breakpoints-to-buffer *dap-test-buffer*)
    (dap-test-check (dap-breakpoint-point breakpoint)
                    "breakpoint-reattaches-to-buffer")
    (with-point ((point (buffer-start-point *dap-test-buffer*)))
      (move-to-line point 3)
      (let ((content (dap-gutter-content *dap-test-buffer* point)))
        (dap-test-check
         (and content
              (string= "○" (lem/buffer/line:content-string content)))
         "pending-breakpoint-has-gutter-marker")))))

(defun dap-test-start-session ()
  (let ((config
          (make-dap-config
           :name "test-adapter"
           :transport :stdio
           :command (dap-native-path (executable-find "python"))
           :command-arguments (list *dap-test-adapter*)
           :directory (dap-native-path
                       (uiop:pathname-directory-pathname *dap-test-file*))
           :request "launch"
           :arguments
           (dap-object "request" "launch"
                       "type" "test"
                       "program" *dap-test-file*))))
    (dap-start-session config)
    (setf *dap-test-stage* :wait-initial-stop)
    (dap-test-reset-deadline)))

(defun dap-test-variable-value (name)
  (loop :for entry :in (dap-session-variables *dap-session*)
        :thereis
        (alexandria:when-let
            ((variable (find name (cdr entry)
                             :key (lambda (item) (dap-field item "name"))
                             :test #'string=)))
          (dap-field variable "value"))))

(defun dap-test-check-initial-stop ()
  (let ((session *dap-session*))
    (dap-test-check (eq :stopped (dap-session-state session))
                    "adapter-stops-at-breakpoint")
    (dap-test-check (dap-breakpoint-verified-p
                     *dap-test-primary-breakpoint*)
                    "source-breakpoint-is-verified")
    (dap-test-check
     (search "λ" (or (dap-breakpoint-message
                       *dap-test-primary-breakpoint*) ""))
     "unicode-breakpoint-response-is-decoded")
    (dap-test-check
     (and (first *dap-function-breakpoints*)
          (dap-function-breakpoint-verified-p
           (first *dap-function-breakpoints*))
          (search "function event"
                  (or (dap-function-breakpoint-message
                       (first *dap-function-breakpoints*)) "")))
     "function-breakpoint-event-is-applied")
    (dap-test-check (= 1 (length (dap-session-threads session)))
                    "threads-are-loaded")
    (dap-test-check (= 2 (length (dap-session-frames session)))
                    "stack-frames-are-loaded")
    (dap-test-check (string= "42" (dap-test-variable-value "answer"))
                    "scope-variables-are-loaded")
    (dap-test-check (string= "λ" (dap-test-variable-value "greeting"))
                    "unicode-variable-is-decoded")
    (dap-test-check (search "hello λ debugger"
                            (dap-session-output session))
                    "fragmented-unicode-output-event-is-decoded")
    (let ((expired nil)
          (sequence -1))
      (setf (gethash sequence (dap-session-pending session))
            (make-dap-pending-request
             :command "expired-test-request"
             :sent-at (- (dap-now-seconds)
                         *dap-request-timeout-seconds* 1)
             :callback
             (lambda (session success-p body response)
               (declare (ignore session body))
               (setf expired
                     (and (not success-p)
                          (search "timed out"
                                  (or (dap-field response "message") "")))))))
      (dap-monitor-session session)
      (dap-test-check
       (and expired
            (null (gethash sequence (dap-session-pending session))))
       "expired-request-is-removed-and-reported"))
    (dap-test-check
     (and (equal (dap-session-stopped-path session)
                 (dap-normalize-path *dap-test-file*))
          (= 3 (dap-session-stopped-line session)))
     "stopped-source-location-is-selected")
    (dap-show-info)
    (let ((text (dap-test-buffer-text (current-buffer))))
      (dap-test-check (search "Threads" text) "info-buffer-has-threads")
      (dap-test-check (search "Stack" text) "info-buffer-has-stack")
      (dap-test-check (search "answer = 42" text)
                      "info-buffer-has-variables"))
    (switch-to-buffer *dap-test-buffer*)
    (setf *dap-watches* '("answer"))
    (dap-refresh-watches session)
    (dap-evaluate-expression-async
     session "answer + 1" "repl"
     (lambda (session success-p body response)
       (declare (ignore session))
       (setf *dap-test-evaluation*
             (if success-p
                 (dap-field body "result")
                 (dap-field response "message")))))
    (setf *dap-test-dynamic-breakpoint*
          (dap-create-breakpoint (dap-buffer-path *dap-test-buffer*) 4))
    (dap-sync-breakpoint-path (dap-buffer-path *dap-test-buffer*))
    (setf *dap-test-stage* :wait-inspection)
    (dap-test-reset-deadline)))

(defun dap-test-check-inspection ()
  (let ((session *dap-session*))
    (dap-test-check (search "value(answer + 1) λ"
                            (or *dap-test-evaluation* ""))
                    "evaluate-request-returns-result")
    (dap-test-check
     (and (dap-session-watch-values session)
          (search "value(answer) λ"
                  (third (first (dap-session-watch-values session)))))
     "watch-is-refreshed")
    (dap-test-check (dap-breakpoint-verified-p
                     *dap-test-dynamic-breakpoint*)
                    "live-breakpoint-update-is-verified")
    (dap-send-thread-command "next")
    (setf *dap-test-stage* :wait-next-stop)
    (dap-test-reset-deadline)))

(defun dap-test-check-next-stop ()
  (dap-test-check (string= "next" (dap-session-stopped-reason *dap-session*))
                  "step-over-continues-and-stops")
  (switch-to-buffer *dap-test-buffer*)
  (move-to-line (current-point) 4)
  (lem-yath-dape-until)
  (setf *dap-test-stage* :wait-goto-stop)
  (dap-test-reset-deadline))

(defun dap-test-check-goto-stop ()
  (dap-test-check (string= "goto" (dap-session-stopped-reason *dap-session*))
                  "run-to-cursor-uses-goto-target")
  (lem-yath-dape-restart)
  (setf *dap-test-stage* :wait-restart-stop)
  (dap-test-reset-deadline))

(defun dap-test-check-restart-stop ()
  (let ((session *dap-session*))
    (dap-test-check
     (string= "restart" (dap-session-stopped-reason session))
     "adapter-restart-request-stops-again")
    (dap-send-request
     session "readMemory"
     (dap-object "memoryReference" "0x1000" "offset" 0 "count" 4)
     (lambda (session success-p body response)
       (declare (ignore session))
       (setf *dap-test-memory*
             (if success-p (dap-field body "data")
                 (dap-field response "message")))))
    (dap-send-request
     session "disassemble"
     (dap-object "memoryReference" "0x1000"
                 "instructionOffset" 0 "instructionCount" 2)
     (lambda (session success-p body response)
       (declare (ignore session))
       (setf *dap-test-disassembly*
             (if success-p (dap-field body "instructions")
                 (dap-field response "message")))))
    (setf *dap-test-stage* :wait-memory)
    (dap-test-reset-deadline)))

(defun dap-test-check-memory ()
  (dap-test-check (string= "AQIDBA==" *dap-test-memory*)
                  "read-memory-response-is-available")
  (dap-test-check (= 2 (length (dap-sequence-list *dap-test-disassembly*)))
                  "disassembly-response-is-available")
  (dap-disconnect-session *dap-session* nil :keep-debuggee-p t)
  (setf *dap-test-stage* :wait-disconnect)
  (dap-test-reset-deadline))

(defun dap-test-start-debugpy ()
  ;; The mock already proved conditional/hit serialization.  Use a plain
  ;; breakpoint for the real adapter so this stage tests transport and launch,
  ;; independently of adapter-specific condition syntax.
  (when *dap-test-dynamic-breakpoint*
    (dap-remove-breakpoint *dap-test-dynamic-breakpoint*)
    (setf *dap-test-dynamic-breakpoint* nil))
  (setf (dap-breakpoint-condition *dap-test-primary-breakpoint*) nil
        (dap-breakpoint-hit-condition *dap-test-primary-breakpoint*) nil
        (dap-breakpoint-log-message *dap-test-primary-breakpoint*) nil
        (dap-breakpoint-verified-p *dap-test-primary-breakpoint*) nil
        (dap-breakpoint-adapter-id *dap-test-primary-breakpoint*) nil)
  (switch-to-buffer *dap-test-buffer*)
  (dap-start-session (dap-make-config "debugpy" *dap-test-buffer*))
  (setf *dap-test-stage* :wait-debugpy-stop)
  (dap-test-reset-deadline 45))

(defun dap-test-check-debugpy-stop ()
  (let ((session *dap-session*))
    (dap-test-check
     (and (eq :tcp (dap-config-transport (dap-session-config session)))
          (dap-session-socket session)
          (dap-session-stream session))
     "real-debugpy-uses-loopback-tcp")
    (dap-test-check (string= "debugpy"
                            (dap-config-name (dap-session-config session)))
                    "real-debugpy-session-is-selected")
    (dap-test-check (dap-breakpoint-verified-p
                     *dap-test-primary-breakpoint*)
                    "real-debugpy-verifies-breakpoint")
    (dap-test-check (= 3 (dap-session-stopped-line session))
                    "real-debugpy-stops-on-source-line")
    (dap-test-check (equal '("answer") *dap-watches*)
                    "watch-persists-across-sessions")
    (let ((terminal-buffer
            (find-if-not #'deleted-buffer-p
                         (dap-session-debuggee-buffers session))))
      (setf *dap-test-debuggee-buffer* terminal-buffer)
      (dap-test-check
       (and terminal-buffer
            (eq 'lem-shell-mode::run-shell-mode
                (buffer-major-mode terminal-buffer)))
       "real-debugpy-uses-integrated-terminal"))
    (dap-evaluate-expression-async
     session "answer"
     "repl"
     (lambda (session success-p body response)
       (declare (ignore session))
       (setf *dap-test-real-evaluation*
             (if success-p (dap-field body "result")
                 (dap-field response "message")))))
    (setf *dap-test-stage* :wait-debugpy-evaluation)
    (dap-test-reset-deadline 30)))

(defun dap-test-check-debugpy-evaluation ()
  (dap-test-check (string= "42" *dap-test-real-evaluation*)
                  "real-debugpy-evaluates-in-selected-frame")
  (let ((terminal-buffer
          (find-if-not #'deleted-buffer-p
                       (dap-session-debuggee-buffers *dap-session*))))
    (dap-test-check
     (and terminal-buffer
          (handler-case
              (progn
                (lem-shell-mode::execute-input
                 (buffer-point terminal-buffer) "continue")
                t)
            (error () nil)))
     "real-debugpy-terminal-accepts-input"))
  (dap-send-thread-command "continue")
  (setf *dap-test-stage* :wait-debugpy-exit)
  (dap-test-reset-deadline 45))

(defun dap-test-clear-breakpoints ()
  (maphash
   (lambda (path breakpoints)
     (declare (ignore path))
     (dolist (breakpoint breakpoints)
       (dap-delete-breakpoint-point breakpoint)))
   *dap-breakpoints*)
  (clrhash *dap-breakpoints*)
  (setf *dap-function-breakpoints* '()
        *dap-test-case-breakpoint* nil))

(defun dap-test-start-next-real-case ()
  (if (null *dap-test-real-cases*)
      (dap-test-finish)
      (let* ((case (pop *dap-test-real-cases*))
             (file (merge-pathnames (getf case :file)
                                    *dap-test-case-root*)))
        (setf *dap-test-current-real-case* case
              *dap-test-real-evaluation* nil)
        (dap-test-clear-breakpoints)
        (let ((lem-lsp-mode::*disable* t))
          (setf *dap-test-case-buffer* (find-file-buffer file)))
        (with-current-buffer *dap-test-case-buffer*
          (when (mode-active-p *dap-test-case-buffer*
                               'lem-yath-lint-mode)
            (lem-yath-lint-mode nil)))
        (dap-sync-buffer-mode *dap-test-case-buffer*)
        (setf *dap-test-case-breakpoint*
              (dap-create-breakpoint
               (dap-buffer-path *dap-test-case-buffer*)
               (getf case :line)))
        (switch-to-buffer *dap-test-case-buffer*)
        (let ((config
                (dap-make-config (getf case :config)
                                 *dap-test-case-buffer*)))
          (dap-start-session config))
        (setf *dap-test-stage* :wait-real-case-stop)
        (dap-test-reset-deadline 90))))

(defun dap-test-check-real-case-stop ()
  (let* ((case *dap-test-current-real-case*)
         (label (getf case :label))
         (session *dap-session*))
    (dap-test-check
     (eq (getf case :transport)
         (dap-config-transport (dap-session-config session)))
     (format nil "~a-transport" label))
    (dap-test-check
     (string= (getf case :config)
              (dap-config-name (dap-session-config session)))
     (format nil "~a-adapter" label))
    (dap-test-check (dap-breakpoint-verified-p
                     *dap-test-case-breakpoint*)
                    (format nil "~a-breakpoint-verified" label)
                    (dap-breakpoint-message *dap-test-case-breakpoint*))
    (dap-test-check
     (= (getf case :line) (dap-session-stopped-line session))
     (format nil "~a-source-line" label)
     (dap-session-stopped-line session))
    (dap-evaluate-expression-async
     session (getf case :expression) "watch"
     (lambda (session success-p body response)
       (declare (ignore session))
       (setf *dap-test-real-evaluation*
             (if success-p (dap-field body "result")
                 (dap-field response "message")))))
    (setf *dap-test-stage* :wait-real-case-evaluation)
    (dap-test-reset-deadline 45)))

(defun dap-test-check-real-case-evaluation ()
  (let ((label (getf *dap-test-current-real-case* :label)))
    (dap-test-check (search "42" *dap-test-real-evaluation*)
                    (format nil "~a-frame-evaluation" label)
                    *dap-test-real-evaluation*)
    (dap-send-thread-command "continue")
    (setf *dap-test-stage* :wait-real-case-exit)
    (dap-test-reset-deadline 90)))

(defun dap-test-check-real-case-exit ()
  (let ((label (getf *dap-test-current-real-case* :label))
        (session *dap-session*))
    (dap-test-check
     (eq :terminated (dap-session-state session))
     (format nil "~a-terminates-cleanly" label)
     (dap-session-output session))
    (dap-test-check
     (or (null (dap-session-exit-code session))
         (eql 0 (dap-session-exit-code session)))
     (format nil "~a-debuggee-exit-code" label)
     (dap-session-exit-code session))
    (dap-test-check
     (dap-test-resources-released-p session)
     (format nil "~a-releases-session-resources" label))
    (dap-test-start-next-real-case)))

(defun dap-test-finish ()
  (unless *dap-test-finished-p*
    (setf *dap-test-finished-p* t)
    (when *dap-test-timer*
      (stop-timer *dap-test-timer*)
      (setf *dap-test-timer* nil))
    (when (dap-active-session-p)
      (dap-cleanup-session-resources *dap-session*)
      (setf (dap-session-state *dap-session*) :terminated))
    (maphash
     (lambda (path breakpoints)
       (declare (ignore path))
       (dolist (breakpoint breakpoints)
         (dap-delete-breakpoint-point breakpoint)))
     *dap-breakpoints*)
    (clrhash *dap-breakpoints*)
    (setf *dap-function-breakpoints* '()
          *dap-watches* '())
    (dap-test-report "SUMMARY ~a failures=~d"
                     (if (zerop *dap-test-failures*) "PASS" "FAIL")
                     *dap-test-failures*)))

(defun dap-test-tick ()
  (unless (or *dap-test-finished-p* *dap-test-tick-active-p*)
    (setf *dap-test-tick-active-p* t)
    (unwind-protect
         (handler-case
             (case *dap-test-stage*
          (:start
           ;; Repeating timer notifications can accumulate while a synchronous
           ;; prerequisite check is running.  Leave :START before doing work so
           ;; a nested/queued tick cannot create a second adapter session.
           (setf *dap-test-stage* :starting)
           (setf *dap-test-buffer*
                 (or (dap-buffer-for-path
                      (dap-normalize-path *dap-test-file*))
                     (find-file-buffer *dap-test-file*)))
           (with-current-buffer *dap-test-buffer*
             (when (mode-active-p *dap-test-buffer* 'lem-yath-lint-mode)
               (lem-yath-lint-mode nil)))
           (dap-sync-buffer-mode *dap-test-buffer*)
           (dap-test-static-contract)
           (dap-test-prepare-breakpoints)
           (dap-test-start-session))
          (:wait-initial-stop
           (if (and (dap-session-stopped-p)
                    (dap-session-variables *dap-session*)
                    (dap-breakpoint-verified-p
                     *dap-test-primary-breakpoint*))
               (dap-test-check-initial-stop)
               (dap-test-timeout "initial-stop-timed-out")))
          (:wait-inspection
           (if (and *dap-test-evaluation*
                    (dap-session-watch-values *dap-session*)
                    (dap-breakpoint-verified-p
                     *dap-test-dynamic-breakpoint*))
               (dap-test-check-inspection)
               (dap-test-timeout "inspection-timed-out")))
          (:wait-next-stop
           (if (and (dap-session-stopped-p)
                    (string= "next"
                             (dap-session-stopped-reason *dap-session*)))
               (dap-test-check-next-stop)
               (dap-test-timeout "step-over-timed-out")))
          (:wait-goto-stop
           (if (and (dap-session-stopped-p)
                    (string= "goto"
                             (dap-session-stopped-reason *dap-session*)))
               (dap-test-check-goto-stop)
               (dap-test-timeout "run-to-cursor-timed-out")))
          (:wait-restart-stop
           (if (and (dap-session-stopped-p)
                    (string= "restart"
                             (dap-session-stopped-reason *dap-session*)))
               (dap-test-check-restart-stop)
               (dap-test-timeout "restart-timed-out")))
          (:wait-memory
           (if (and *dap-test-memory* *dap-test-disassembly*)
               (dap-test-check-memory)
               (dap-test-timeout "memory-requests-timed-out")))
          (:wait-disconnect
           (if (eq :terminated (dap-session-state *dap-session*))
               (progn
                 (dap-test-check
                  (search "disconnect" (dap-test-adapter-events))
                  "disconnect-request-reaches-adapter")
                 (dap-test-check
                  (dap-session-disconnect-keep-debuggee-p *dap-session*)
                  "disconnect-records-keep-debuggee-intent")
                 (let ((state (dap-session-state *dap-session*)))
                   (dap-session-fail *dap-session* "late failure")
                   (dap-test-check
                    (eq state (dap-session-state *dap-session*))
                    "terminal-session-state-is-monotonic"))
                 (dap-test-start-debugpy))
               (dap-test-timeout "disconnect-timed-out")))
          (:wait-debugpy-stop
           (if (and (dap-session-stopped-p)
                    (dap-breakpoint-verified-p
                     *dap-test-primary-breakpoint*)
                    (dap-session-frame *dap-session*))
               (dap-test-check-debugpy-stop)
               (dap-test-timeout "real-debugpy-stop-timed-out")))
          (:wait-debugpy-evaluation
           (if *dap-test-real-evaluation*
               (dap-test-check-debugpy-evaluation)
               (dap-test-timeout "real-debugpy-evaluation-timed-out")))
          (:wait-debugpy-exit
           (if (member (dap-session-state *dap-session*)
                       '(:terminated :exited :failed))
               (progn
                 (dap-test-check
                  (eq :terminated (dap-session-state *dap-session*))
                  "real-debugpy-terminates-cleanly"
                  (dap-session-output *dap-session*))
                 (dap-test-check
                  (eql 0 (dap-session-exit-code *dap-session*))
                  "real-debugpy-debuggee-exits-zero"
                  (dap-session-exit-code *dap-session*))
                 (dap-test-check
                  (dap-test-resources-released-p *dap-session*)
                  "real-debugpy-releases-session-resources")
                 (dap-test-check
                 (and *dap-test-debuggee-buffer*
                       (not (deleted-buffer-p *dap-test-debuggee-buffer*))
                       (eq 'lem/buffer/fundamental-mode:fundamental-mode
                           (buffer-major-mode *dap-test-debuggee-buffer*))
                       (buffer-read-only-p *dap-test-debuggee-buffer*))
                  "real-debugpy-retains-read-only-terminal-transcript")
                 (setf *dap-watches* '())
                 (dap-test-start-next-real-case))
               (dap-test-timeout "real-debugpy-exit-timed-out")))
          (:wait-real-case-stop
           (cond
             ((and (dap-session-stopped-p)
                   (dap-breakpoint-verified-p
                    *dap-test-case-breakpoint*)
                   (dap-session-frame *dap-session*))
              (dap-test-check-real-case-stop))
             ((member (dap-session-state *dap-session*)
                      '(:terminated :exited :failed))
              (dap-test-check
               nil
               (format nil "~a-stopped-before-exit"
                       (getf *dap-test-current-real-case* :label))
               (dap-session-output *dap-session*))
              (dap-test-finish))
             (t
              (dap-test-timeout
               (format nil "~a-stop-timed-out"
                       (getf *dap-test-current-real-case* :label))))))
          (:wait-real-case-evaluation
           (if *dap-test-real-evaluation*
               (dap-test-check-real-case-evaluation)
               (dap-test-timeout
                (format nil "~a-evaluation-timed-out"
                        (getf *dap-test-current-real-case* :label)))))
          (:wait-real-case-exit
           (if (member (dap-session-state *dap-session*)
                       '(:terminated :exited :failed))
               (dap-test-check-real-case-exit)
               (dap-test-timeout
                (format nil "~a-exit-timed-out"
                        (getf *dap-test-current-real-case* :label))))))
           (error (condition)
             (dap-test-check nil "unhandled-test-error" condition)
             (dap-test-finish)))
      (setf *dap-test-tick-active-p* nil))))

(setf *dap-test-timer*
      (start-timer
       (make-timer 'dap-test-tick :name "lem-yath-dap-test")
       50 :repeat t))
