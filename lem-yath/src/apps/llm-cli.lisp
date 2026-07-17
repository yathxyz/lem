;;;; lem-yath apps/llm-cli -- streaming CLI-agent LLM backends.

(in-package :lem-yath)

(defparameter *llm-cli-commands*
  '((:claude-code . "claude")
    (:codex . "codex")
    (:grok . "grok"))
  "CLI executable for each agent backend.")

(defparameter *llm-cli-line-limit* (* 1024 1024)
  "Maximum JSON event line size accepted from an agent CLI.")

(defparameter *llm-cli-command-output-limit* 4000
  "Maximum Codex command output rendered for one activity event.")

(defparameter *llm-cli-session-keys*
  '((:claude-code . lem-yath-llm-claude-code-session-id)
    (:codex . lem-yath-llm-codex-session-id)
    (:grok . lem-yath-llm-grok-session-id)))

(defparameter *llm-backend-default-models*
  '((:openrouter . "openrouter/auto")
    (:perplexity . "sonar")
    (:copilot . "gpt-4.1")
    (:chatgpt-codex . "gpt-5.4")
    (:grok-oauth . "grok-build")
    (:claude-code . "claude-code")
    (:codex . "codex")
    (:grok . "grok-build")))

(defun llm-cli-spec (backend)
  "Return BACKEND's executable name, or NIL."
  (cdr (assoc backend *llm-cli-commands*)))

(defun llm-cli-available-p (backend)
  "True when BACKEND's CLI binary is on PATH."
  (alexandria:when-let ((executable (llm-cli-spec backend)))
    (executable-find executable)))

(defun llm-cli-session-key (backend)
  (or (cdr (assoc backend *llm-cli-session-keys*))
      (error "No session key for LLM backend ~s" backend)))

(defun llm-cli-session-id-valid-p (session-id)
  "Whether SESSION-ID is safe and plausible as one CLI argv value."
  (and (stringp session-id)
       (plusp (length session-id))
       (<= (length session-id) 256)
       (alphanumericp (char session-id 0))
       (every (lambda (character)
                (or (alphanumericp character)
                    (find character "-._:" :test #'char=)))
              session-id)))

(defun llm-cli-session-id (backend &optional (buffer (llm-output-buffer)))
  "Return BACKEND's session id local to BUFFER, or NIL."
  (let ((session-id (and (llm-buffer-live-p buffer)
                         (buffer-value buffer (llm-cli-session-key backend)))))
    (and (llm-cli-session-id-valid-p session-id) session-id)))

(defun llm-cli-store-session-id (buffer backend session-id)
  "Store a validated SESSION-ID for BACKEND in live BUFFER."
  (when (and (llm-buffer-live-p buffer)
             (llm-cli-session-id-valid-p session-id))
    (setf (buffer-value buffer (llm-cli-session-key backend)) session-id)))

(defun llm-buffer-has-backend-session-p (buffer backend)
  "Whether BUFFER carries resumable state for BACKEND."
  (let ((oauth-history-keys
          (and (boundp '*llm-oauth-history-keys*)
               (symbol-value '*llm-oauth-history-keys*))))
    (cond
      ((llm-cli-spec backend)
       (not (null (llm-cli-session-id backend buffer))))
      ((assoc backend oauth-history-keys)
       (or (and (fboundp 'llm-oauth-history)
                (llm-oauth-history backend buffer))
           (loop :for symbol :in '(*llm-oauth-session-keys*
                                   *llm-oauth-cache-keys*)
                 :for table := (and (boundp symbol) (symbol-value symbol))
                 :for key := (cdr (assoc backend table))
                 :thereis (and key (buffer-value buffer key)))))
      (t nil))))

(defun llm-session-output-buffer (backend)
  "Choose the current conversation or shared transcript for BACKEND state."
  (if (llm-conversation-buffer-p)
      (let* ((current (current-buffer))
             (*llm-output-buffer-override* nil)
             (shared (llm-output-buffer)))
        (cond
          ((llm-buffer-has-backend-session-p current backend) current)
          ((llm-buffer-has-backend-session-p shared backend) shared)
          (t current)))
      (llm-output-buffer)))

(define-command lem-yath-llm-new-session () ()
  "Start a fresh conversation for the active stateful LLM backend."
  (let ((buffer (llm-session-output-buffer *llm-backend*)))
    (if (llm-active-request buffer)
        (message "Wait for or abort the active LLM request first")
        (cond
          ((llm-cli-spec *llm-backend*)
           (setf (buffer-value buffer (llm-cli-session-key *llm-backend*)) nil)
           (message "New ~(~a~) conversation will start with the next prompt"
                    *llm-backend*))
          ((llm-oauth-clear-session *llm-backend* buffer)
           (message "New ~(~a~) conversation will start with the next prompt"
                    *llm-backend*))
          (t
           (message "~:(~a~) requests do not currently carry conversation state"
                    *llm-backend*))))))

(defun llm-cli-compose-prompt (prompt)
  (if (plusp (length *llm-system-message*))
      (format nil "System instructions:~%~a~%~%User message:~%~a"
              *llm-system-message* prompt)
      prompt))

(defun llm-cli-command (backend prompt &optional session-id)
  "Build native argv for BACKEND and PROMPT, resuming SESSION-ID when given."
  (when (and session-id (not (llm-cli-session-id-valid-p session-id)))
    (error "Invalid ~a session id" backend))
  (let ((executable (or (llm-cli-spec backend)
                        (error "Unknown LLM CLI backend ~s" backend))))
    (ecase backend
      (:claude-code
       (append (list executable "-p" prompt
                     "--output-format" "stream-json" "--verbose")
               (when session-id (list "--resume" session-id))
               (when (plusp (length *llm-system-message*))
                 (list "--append-system-prompt" *llm-system-message*))))
      (:codex
       (append (list executable "exec")
               (when session-id (list "resume" session-id))
               (list "--json" "-s" "read-only"
                     (llm-cli-compose-prompt prompt))))
      (:grok
       (append (list executable "-p" (llm-cli-compose-prompt prompt)
                     "--output-format" "streaming-json")
               (when session-id (list "-r" session-id))
               (list "-m" "grok-build"
                     "--sandbox" "read-only"
                     "--permission-mode" "dontAsk"
                     "--disable-web-search"
                     "--no-subagents"
                     "--no-plan"))))))

(defun llm-cli-json-get (object key)
  (and (hash-table-p object) (gethash key object)))

(defun llm-cli-sequence-list (value)
  (cond ((vectorp value) (coerce value 'list))
        ((listp value) value)
        (t nil)))

(defun llm-cli-json-string (value)
  (handler-case
      (with-output-to-string (stream) (yason:encode value stream))
    (error () (princ-to-string value))))

(defun llm-cli-value-text (value)
  "Extract readable text from a JSON string, array, or typed object."
  (cond
    ((null value) "")
    ((stringp value) value)
    ((or (vectorp value) (listp value))
     (format nil "~{~a~^~%~}"
             (remove "" (mapcar #'llm-cli-value-text
                                 (llm-cli-sequence-list value))
                     :test #'string=)))
    ((hash-table-p value)
     (or (alexandria:when-let ((text (llm-cli-json-get value "text")))
           (llm-cli-value-text text))
         (alexandria:when-let ((content (llm-cli-json-get value "content")))
           (llm-cli-value-text content))
         (llm-cli-json-string value)))
    (t (princ-to-string value))))

(defun llm-cli-claude-tool-use (block)
  (format nil "~%~%> Claude tool: `~a`~%~%```json~%~a~%```~%"
          (or (llm-cli-json-get block "name") "unknown")
          (llm-cli-json-string (or (llm-cli-json-get block "input")
                                   (make-hash-table :test #'equal)))))

(defun llm-cli-claude-content (content)
  (with-output-to-string (stream)
    (dolist (block (llm-cli-sequence-list content))
      (let ((type (llm-cli-json-get block "type")))
        (cond
          ((string= type "text")
           (write-string (or (llm-cli-json-get block "text") "") stream))
          ((string= type "thinking")
           (format stream "~%~%<details><summary>Thinking</summary>~%~%~a~%~%</details>~%"
                   (or (llm-cli-json-get block "thinking") "")))
          ((string= type "tool_use")
           (write-string (llm-cli-claude-tool-use block) stream))
          ((string= type "tool_result")
           (format stream "~%~%> Claude tool result~:[~; (error)~]~%~%```text~%~a~%```~%"
                   (not (null (llm-cli-json-get block "is_error")))
                   (llm-cli-value-text (llm-cli-json-get block "content")))))))))

(defun llm-cli-claude-event (json)
  (let ((type (llm-cli-json-get json "type")))
    (cond
      ((string= type "assistant")
       (list :text
             (llm-cli-claude-content
              (llm-cli-json-get (llm-cli-json-get json "message") "content"))))
      ((string= type "user")
       (list :text
             (llm-cli-claude-content
              (llm-cli-json-get (llm-cli-json-get json "message") "content"))))
      ((string= type "content_block_delta")
       (let ((delta (llm-cli-json-get json "delta")))
         (when (string= (llm-cli-json-get delta "type") "text_delta")
           (list :text (llm-cli-json-get delta "text")))))
      ((string= type "result")
       (list :session-id (llm-cli-json-get json "session_id")
             :error (and (llm-cli-json-get json "is_error")
                         (or (llm-cli-json-get json "result")
                             "Claude Code returned an error"))))
      (t nil))))

(defun llm-cli-truncate-command-output (output)
  (if (> (length output) *llm-cli-command-output-limit*)
      (concatenate 'string
                   (subseq output 0 *llm-cli-command-output-limit*)
                   (format nil "~%[output truncated]"))
      output))

(defun llm-cli-codex-command-event (item)
  (let* ((status (or (llm-cli-json-get item "status") "unknown"))
         (exit-code (llm-cli-json-get item "exit_code"))
         (command (or (llm-cli-json-get item "command") ""))
         (output (llm-cli-truncate-command-output
                  (or (llm-cli-json-get item "aggregated_output") ""))))
    (format nil "~%[Codex command ~a~@[; exit ~a~]] ~a~%~@[~a~%~]"
            status exit-code command
            (and (plusp (length output)) output))))

(defun llm-cli-codex-file-event (item)
  (with-output-to-string (stream)
    (format stream "~%[Codex file changes]~%")
    (dolist (change (llm-cli-sequence-list
                     (llm-cli-json-get item "changes")))
      (format stream "- ~a ~a~%"
              (or (llm-cli-json-get change "kind") "change")
              (or (llm-cli-json-get change "path") "")))))

(defun llm-cli-codex-event (json)
  (let ((type (llm-cli-json-get json "type")))
    (cond
      ((string= type "thread.started")
       (list :session-id (llm-cli-json-get json "thread_id")))
      ((string= type "item.completed")
       (let* ((item (llm-cli-json-get json "item"))
              (item-type (llm-cli-json-get item "type")))
         (cond
           ((string= item-type "agent_message")
            (list :text (llm-cli-json-get item "text")))
           ((string= item-type "command_execution")
            (list :text (llm-cli-codex-command-event item)))
           ((string= item-type "file_change")
            (list :text (llm-cli-codex-file-event item))))))
      (t nil))))

(defun llm-cli-grok-event (json)
  (let ((type (llm-cli-json-get json "type")))
    (cond
      ((string= type "text") (list :text (llm-cli-json-get json "data")))
      ((string= type "end")
       (list :session-id (llm-cli-json-get json "sessionId")))
      ((string= type "error")
       (list :error (or (llm-cli-json-get json "message")
                        (llm-cli-json-get json "data")
                        "Grok Build request failed")))
      (t nil))))

(defun llm-cli-parse-event (backend line)
  "Parse one native JSON event LINE from BACKEND into a result plist."
  (when (<= (length line) *llm-cli-line-limit*)
    (handler-case
        (let ((json (yason:parse line)))
          (ecase backend
            (:claude-code (llm-cli-claude-event json))
            (:codex (llm-cli-codex-event json))
            (:grok (llm-cli-grok-event json))))
      (error () nil))))

(defun llm-cli-queue-event (request backend event)
  (when event
    (send-event
     (lambda ()
       (when (llm-request-current-p request)
         (let ((buffer (llm-request-buffer request))
               (text (getf event :text))
               (session-id (getf event :session-id))
               (error-text (getf event :error)))
           (when (stringp text)
             (llm-request-insert-now request text))
           (when session-id
             (llm-cli-store-session-id buffer backend session-id))
           (when error-text
             (llm-request-insert-now
              request (format nil "~%[~a error: ~a]~%"
                              backend error-text)))))))))

(defun llm-cli-stream (backend prompt)
  "Run BACKEND for PROMPT, parsing and streaming its native event protocol."
  (unless (llm-cli-available-p backend)
    (message "~a CLI not found on PATH" (llm-cli-spec backend))
    (return-from llm-cli-stream))
  (let ((buffer (llm-output-buffer)))
    (when (llm-active-request buffer)
      (message "An LLM request is already running; use M-x lem-yath-llm-abort")
      (return-from llm-cli-stream))
    (let* ((session-id (llm-cli-session-id backend buffer))
           (command (llm-cli-command backend prompt session-id))
           (insertion-point
             (llm-prepare-response
              buffer
              (format nil
                      "~%## User (~a~:[~; resume~])~%~%~a~%~%## Assistant~%~%"
                      backend session-id prompt))))
      (handler-case
          (let* ((process (uiop:launch-program command
                                               :output :stream
                                               :error-output :output))
                 (request (llm-register-request
                           buffer process backend
                           :prompt prompt
                           :insertion-point insertion-point)))
            (llm-start-request-thread
             request
             (lambda ()
               (unwind-protect
                    (with-open-stream (output (uiop:process-info-output process))
                      (loop :for line := (read-line output nil)
                            :while line
                            :do (llm-cli-queue-event
                                 request backend
                                 (llm-cli-parse-event backend line))))
                 (let ((code (ignore-errors (uiop:wait-process process))))
                   (llm-request-finish
                    request
                    (llm-request-finish-text
                     request code
                     (format nil "~a failed" (llm-cli-spec backend)))))))
             (format nil "lem-yath/llm-~(~a~)" backend)
             (format nil "~%[failed to start ~a request]~%"
                     (llm-cli-spec backend))))
        (error ()
          (llm-unregistered-response-failure-now
           buffer insertion-point
           (format nil "~%[failed to launch ~a]~%"
                   (llm-cli-spec backend))))))))

(defmethod llm-backend-stream ((backend (eql :claude-code)) prompt)
  (llm-cli-stream backend prompt))

(defmethod llm-backend-stream ((backend (eql :codex)) prompt)
  (llm-cli-stream backend prompt))

(defmethod llm-backend-stream ((backend (eql :grok)) prompt)
  (llm-cli-stream backend prompt))

(defun llm-available-backends ()
  "Configured HTTP backends, plus agent CLIs found on PATH."
  (append '(:openrouter :perplexity :copilot :chatgpt-codex :grok-oauth)
        (loop :for (backend . executable) :in *llm-cli-commands*
              :when (executable-find executable)
                :collect backend)))

(define-command lem-yath-llm-set-backend () ()
  "Switch the active LLM backend with Prescient-style filtering."
  (let* ((backends (llm-available-backends))
         (names (mapcar (lambda (backend)
                          (string-downcase (symbol-name backend)))
                        backends))
         (choice (prompt-for-string
                  "LLM backend: "
                  :completion-function (lambda (string)
                                         (prescient-filter string names))
                  :initial-value (string-downcase (symbol-name *llm-backend*))
                  :history-symbol 'lem-yath-llm-backend))
         (backend (find choice backends
                        :key (lambda (candidate)
                               (string-downcase (symbol-name candidate)))
                        :test #'string-equal)))
    (if backend
        (progn
          (unless (eq backend *llm-backend*)
            (setf *llm-model*
                  (or (cdr (assoc backend *llm-backend-default-models*))
                      *llm-model*)))
          (setf *llm-backend* backend)
          (message "LLM backend: ~(~a~) (~a)" backend *llm-model*))
        (message "Unknown or unavailable backend: ~a" choice))))
