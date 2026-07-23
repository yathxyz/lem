;;;; lem-yath apps/claude-code -- project-aware Claude Code editor session.

(in-package :lem-yath)

(defvar *claude-code-command-candidates*
  '(("ccr" "code")
    ("claude"))
  "Direct argv candidates for the configured Claude Code frontend.")

(defparameter *claude-code-event-buffer-limit* (* 4 1024 1024))

(defclass lem-yath-claude-code-context (lem-claude-code::context)
  ((directory :initarg :directory :reader lem-yath-claude-code-directory)
   (command :initarg :command :reader lem-yath-claude-code-command)))

(defun claude-code-resolve-command ()
  (loop :for candidate :in *claude-code-command-candidates*
        :for executable := (and (consp candidate)
                                (stringp (first candidate))
                                (executable-find (first candidate)))
        :when executable
          :return (cons (uiop:native-namestring executable)
                        (rest candidate))))

(defun claude-code-project-directory (buffer)
  (or (lem-yath-project-root-for-directory (buffer-directory buffer))
      (buffer-directory buffer)
      (uiop:getcwd)))

(defun claude-code-session-live-p (session)
  (let ((buffer (lem/interactive-mode::session-output-buffer session)))
    (and buffer (not (deleted-buffer-p buffer)))))

(defun claude-code-report-error (session condition)
  (send-event
   (lambda ()
     (when (claude-code-session-live-p session)
       (ignore-errors (lem/interactive-mode:stop-loading session))
       (message "Claude Code request failed: ~a" condition)))))

(defun claude-code-request-argv (context input session-id)
  (append (lem-yath-claude-code-command context)
          (list "--output-format" "stream-json"
                "--verbose"
                "--print" input
                "--mcp-config"
                (uiop:native-namestring (claude-bridge-start))
                "--allowedTools" (claude-bridge-allowed-tools)
                "--disallowedTools" "Edit,Write,NotebookEdit"
                "--append-system-prompt"
                (concatenate
                 'string
                 "Use the connected Lem MCP tools to inspect the live editor. "
                 "Do not mutate files directly. Present proposed whole-buffer "
                 "changes with openDiff, wait for the user's decision, and check "
                 "it with checkDiff before continuing.")
                "--permission-mode" "acceptEdits")
          (when session-id (list "--resume" session-id))))

(defun claude-code-dispatch-line (line callback)
  (let ((line (string-right-trim '(#\Return) line)))
    (unless (alexandria:emptyp line)
      (let ((value
              (handler-case (yason:parse line)
                (error (condition)
                  (error "Malformed Claude Code event ~S: ~A"
                         (subseq line 0 (min 200 (length line)))
                         condition)))))
        (funcall callback value)
        (string= "result" (gethash "type" value))))))

(defun claude-code-dispatch-complete-lines (buffer callback)
  (let ((start 0)
        (done nil))
    (loop :for newline := (position #\Newline buffer :start start)
          :while newline
          :do (when (claude-code-dispatch-line
                     (subseq buffer start newline) callback)
                (setf done t))
              (setf start (1+ newline)))
    (values (subseq buffer start) done)))

(defun claude-code-run-query (session context input)
  "Run one Claude Code JSONL request for the interactive SESSION."
  (let ((process
          (async-process:create-process
           (claude-code-request-argv
            context input (lem-claude-code::session-id session))
           :directory (lem-yath-claude-code-directory context))))
    (bt2:make-thread
     (lambda ()
       (unwind-protect
            (handler-case
                (let ((buffer "")
                      (done nil))
                  (labels ((deliver (value)
                             (send-event
                              (lambda ()
                                (when (claude-code-session-live-p session)
                                  (lem-claude-code::handle-response
                                   session value))))))
                    (loop :until done
                          :do (alexandria:when-let
                                  ((data (async-process:process-receive-output
                                          process)))
                                (setf buffer
                                      (concatenate 'string buffer data))
                                (when (> (length buffer)
                                         *claude-code-event-buffer-limit*)
                                  (error "Claude Code event exceeds the size limit")))
                              (multiple-value-setq (buffer done)
                                (claude-code-dispatch-complete-lines
                                 buffer #'deliver))
                              (unless (or done
                                          (async-process:process-alive-p process))
                                (when (plusp (length buffer))
                                  (setf done
                                        (claude-code-dispatch-line
                                         buffer #'deliver)))
                                (unless done
                                  (error
                                   "Claude Code exited before a result event")))
                              (unless done (sleep 0.05)))))
              (error (condition)
                (claude-code-report-error session condition)))
         (when (async-process:process-alive-p process)
           (ignore-errors (async-process:delete-process process)))))
     :name "Lem-yath Claude Code thread")))

(defmethod lem/interactive-mode:execute-input :around
    (session (mode lem-claude-code::claude-code-query-mode) input)
  (declare (ignore mode))
  (let ((context (lem/interactive-mode:session-context session)))
    (if (not (typep context 'lem-yath-claude-code-context))
        (call-next-method)
        (unless (alexandria:emptyp input)
          (lem/interactive-mode:start-loading session "Responding...")
          (handler-case
              (claude-code-run-query session context input)
            (error (condition)
              (claude-code-report-error session condition)))))))

(define-command lem-yath-claude-code () ()
  "Open a project-aware Claude Code interactive session."
  (alexandria:if-let ((command (claude-code-resolve-command)))
    (let* ((origin (current-buffer))
           (context
             (make-instance
              'lem-yath-claude-code-context
              :directory (claude-code-project-directory origin)
              :command command)))
      (prog1
          (lem/interactive-mode:run
           :buffer-name "*Claude Code*"
           :input-buffer-mode 'lem-claude-code::claude-code-query-mode
           :output-buffer-mode 'lem-claude-code::claude-code-output-mode
           :copy-prompt-to-output-buffer nil
           :input-text-attribute-in-output-buffer
           'lem-claude-code::prompt-attribute
           :context context)
        (setf (lem-vi-mode/core:buffer-state)
              'lem-vi-mode/states:insert)))
    (message "Claude Code is unavailable (tried ccr and claude)")))
