;;;; LLM layer: gptel -> a native Lem client for OpenRouter (the Emacs
;;;; config's default backend), streaming via curl on a background thread
;;;; and marshalling chunks onto the editor thread with send-event.
;;;; CLI-agent backends (claude/codex/grok) live in apps/llm-cli.lisp.

(in-package :lem-yath)

(defvar *llm-model* "openrouter/auto"
  "Default model, matching gptel's OpenRouter default.")

(defvar *llm-endpoint* "https://openrouter.ai/api/v1/chat/completions")

(defvar *llm-curl-executable* "curl"
  "curl executable used for OpenRouter transport.")

(defvar *llm-system-message*
  "Short, direct answers. Skip extra context unless it changes correctness."
  "System message from the Emacs quick-lookup startup preset.")

(defvar *llm-temperature* 0.2
  "Sampling temperature from the active Lem LLM preset.")

(defvar *llm-max-tokens* 800
  "Response token cap from the active Lem LLM preset, or NIL.")

(defvar *llm-use-tools* nil
  "Whether the active preset exposes the bounded read-only tool registry.")

(defvar *llm-buffer-name* "*lem-yath-llm*")

(defparameter *llm-max-tool-rounds* 4)
(defparameter *llm-max-tool-calls-per-round* 8)
(defparameter *llm-max-tool-calls-per-request* 24)
(defparameter *llm-stream-line-limit* (* 256 1024))
(defparameter *llm-response-character-limit* (* 4 1024 1024))
(defparameter *llm-tool-argument-character-limit* (* 64 1024))

(defvar *llm-stream-provider-name* "OpenRouter"
  "Provider label used by the shared chat-completions stream parser.")

(defstruct (llm-stream-tool-call
            (:constructor make-llm-stream-tool-call (index)))
  index
  (id "")
  (name "")
  (arguments ""))

(defstruct llm-stream-round
  (content "")
  (tool-calls '())
  finish-reason)

(defstruct (llm-request
            (:constructor make-llm-request
                (buffer process backend &key tool-context tools-p)))
  "One asynchronous LLM request owned by BUFFER."
  buffer
  process
  backend
  tool-context
  tools-p
  (aborted-p nil)
  (lock (bt2:make-lock :name "lem-yath/llm-request")))

(defparameter *llm-active-request-key* 'lem-yath-llm-active-request)

(defun llm-api-key ()
  (or (uiop:getenv "OPENROUTER_API_KEY")
      (uiop:getenv "OPENAI_API_KEY")))

(defun llm-initial-messages (prompt &optional (system *llm-system-message*))
  (list (llm-json-object "role" "system" "content" system)
        (llm-json-object "role" "user" "content" prompt)))

(defun llm-request-body-for-messages
    (messages model temperature max-tokens tools)
  (with-output-to-string (s)
    (let ((body (llm-json-object
                 "model" model
                 "stream" t
                 "temperature" temperature
                 "messages" (coerce messages 'vector))))
      (when max-tokens
        (setf (gethash "max_tokens" body) max-tokens))
      (when tools
        (setf (gethash "tools" body)
              (if (eq tools t) (llm-tool-definitions) tools)))
      (yason:encode body s))))

(defun llm-request-body (prompt)
  "Encode one request using the active preset; retained as a testable API."
  (llm-request-body-for-messages
   (llm-initial-messages prompt) *llm-model* *llm-temperature*
   *llm-max-tokens* *llm-use-tools*))

(defun llm-json-elements (value)
  (cond
    ((vectorp value) (coerce value 'list))
    ((listp value) value)
    (t nil)))

(defun llm-sse-payload (line)
  "Return an SSE data payload and whether LINE was a data record."
  (when (> (length line) *llm-stream-line-limit*)
    (error "LLM provider emitted an oversized SSE line"))
  (if (and (>= (length line) 5)
           (string= "data:" line :end2 5))
      (values (string-left-trim '(#\Space #\Tab) (subseq line 5)) t)
      (values nil nil)))

(defun llm-sse-json (line)
  "Return parsed SSE JSON and flags for a data record and [DONE]."
  (multiple-value-bind (payload data-p) (llm-sse-payload line)
    (cond
      ((not data-p) (values nil nil nil))
      ((string= payload "[DONE]") (values nil t t))
      (t
       (handler-case
           (values (yason:parse payload) t nil)
         (error () (error "LLM provider emitted malformed SSE JSON")))))))

(defun llm-delta-content (line)
  "Extract the streamed content delta from one SSE LINE, or NIL."
  (handler-case
      (multiple-value-bind (json data-p done-p) (llm-sse-json line)
        (declare (ignore data-p))
        (unless done-p
          (let ((choice (first (llm-json-elements
                                (and (hash-table-p json)
                                     (gethash "choices" json))))))
            (when (hash-table-p choice)
              (let* ((delta (gethash "delta" choice))
                     (content (and (hash-table-p delta)
                                   (gethash "content" delta))))
                (and (stringp content) content))))))
    (error () nil)))

(defun llm-bounded-fragment (current fragment maximum label)
  (unless (or (null fragment) (stringp fragment))
    (error "~a emitted a non-string ~a fragment"
           *llm-stream-provider-name* label))
  (let ((combined (concatenate 'string current (or fragment ""))))
    (when (> (length combined) maximum)
      (error "~a emitted oversized ~a data"
             *llm-stream-provider-name* label))
    combined))

(defun llm-stream-tool-call-chunk (table chunk)
  (unless (hash-table-p chunk)
    (error "~a emitted a malformed tool-call chunk"
           *llm-stream-provider-name*))
  (let ((index (gethash "index" chunk)))
    (unless (and (integerp index)
                 (<= 0 index)
                 (< index *llm-max-tool-calls-per-round*))
      (error "~a emitted an invalid tool-call index"
             *llm-stream-provider-name*))
    (let ((call (or (gethash index table)
                    (setf (gethash index table)
                          (make-llm-stream-tool-call index)))))
      (multiple-value-bind (id id-p) (gethash "id" chunk)
        (when id-p
          (setf (llm-stream-tool-call-id call)
                (llm-bounded-fragment
                 (llm-stream-tool-call-id call) id 256 "tool-call id"))))
      (multiple-value-bind (type type-p) (gethash "type" chunk)
        (when (and type-p type (not (string= type "function")))
          (error "~a requested a non-function tool call"
                 *llm-stream-provider-name*)))
      (let ((function (gethash "function" chunk)))
        (when function
          (unless (hash-table-p function)
            (error "~a emitted malformed function-call data"
                   *llm-stream-provider-name*))
          (multiple-value-bind (name name-p) (gethash "name" function)
            (when name-p
              (setf (llm-stream-tool-call-name call)
                    (llm-bounded-fragment
                     (llm-stream-tool-call-name call) name 128
                     "tool name"))))
          (multiple-value-bind (arguments arguments-p)
              (gethash "arguments" function)
            (when arguments-p
              (setf (llm-stream-tool-call-arguments call)
                    (llm-bounded-fragment
                     (llm-stream-tool-call-arguments call) arguments
                     *llm-tool-argument-character-limit* "tool arguments"))))))
      call)))

(defun llm-tool-name-valid-p (name)
  (and (plusp (length name))
       (every (lambda (character)
                (or (alphanumericp character)
                    (member character '(#\_ #\-))))
              name)))

(defun llm-finalize-stream-tool-calls (table)
  (let ((calls (sort (loop :for call :being :each :hash-value :of table
                             :collect call)
                     #'< :key #'llm-stream-tool-call-index)))
    (dolist (call calls)
      (unless (and (plusp (length (llm-stream-tool-call-id call)))
                   (llm-tool-name-valid-p
                    (llm-stream-tool-call-name call)))
        (error "~a emitted an incomplete tool call"
               *llm-stream-provider-name*)))
    calls))

(defun llm-apply-openrouter-choice
    (request choice content calls content-count)
  "Apply one streamed CHOICE and return its new count and finish reason."
  (let ((delta (gethash "delta" choice)))
    (when (hash-table-p delta)
      (let ((chunk (gethash "content" delta)))
        (when (stringp chunk)
          (incf content-count (length chunk))
          (when (> content-count *llm-response-character-limit*)
            (error "~a response exceeded the size limit"
                   *llm-stream-provider-name*))
          (write-string chunk content)
          (llm-request-append request chunk)))
      (dolist (chunk (llm-json-elements (gethash "tool_calls" delta)))
        (llm-stream-tool-call-chunk calls chunk)))
    (let ((reason (gethash "finish_reason" choice)))
      (values content-count (and (stringp reason) reason)))))

(defun llm-read-chat-completions-round
    (request process &optional (provider "OpenRouter"))
  "Read one bounded OpenAI-compatible SSE response from PROCESS.
Return the parsed round and an optional HTTP status marker."
  (let ((content (make-string-output-stream))
        (content-count 0)
        (calls (make-hash-table))
        (finish-reason nil)
        (http-status nil)
        (done-p nil)
        (*llm-stream-provider-name* provider))
    (with-open-stream (out (uiop:process-info-output process))
      (loop :for line := (read-line out nil)
            :while line
            :do
               (cond
                 ((and (>= (length line) 25)
                       (string= line "__LEM_YATH_HTTP_STATUS__:" :end1 25
                                                                 :end2 25))
                  (let ((value (subseq line 25)))
                    (when (and (= (length value) 3)
                               (every #'digit-char-p value))
                      (setf http-status (parse-integer value)))))
                 ((not done-p)
                  (multiple-value-bind (json data-record-p stream-done-p)
                      (llm-sse-json line)
                    (when stream-done-p (setf done-p t))
                    (when (and data-record-p (hash-table-p json))
                      (when (gethash "error" json)
                        (error "~a returned an API error" provider))
                      (let ((choice
                              (first (llm-json-elements
                                      (gethash "choices" json)))))
                        (when (hash-table-p choice)
                          (multiple-value-bind (count reason)
                              (llm-apply-openrouter-choice
                               request choice content calls content-count)
                            (setf content-count count)
                            (when reason (setf finish-reason reason)))))))))))
    (values
     (make-llm-stream-round
      :content (get-output-stream-string content)
      :tool-calls (llm-finalize-stream-tool-calls calls)
      :finish-reason finish-reason)
     http-status)))

(defun llm-read-openrouter-round (request process)
  "Read one bounded OpenRouter SSE response from PROCESS."
  (nth-value 0 (llm-read-chat-completions-round request process)))

(defun llm-word-or-punctuation-char-p (character)
  "Whether CHARACTER has gptel's `w' (word) or `.' (punctuation) syntax."
  (and character
       (or (syntax-word-char-p character)
           (let ((syntax (current-syntax)))
             (not
              (or (syntax-space-char-p character)
                  (member character
                          (lem/buffer/syntax-table:syntax-table-symbol-chars
                           syntax))
                  (syntax-open-paren-char-p character)
                  (syntax-closed-paren-char-p character)
                  (syntax-string-quote-char-p character)
                  (syntax-escape-char-p character)
                  (syntax-expr-prefix-char-p character)
                  (member character
                          (lem/buffer/syntax-table:syntax-table-fence-chars
                           syntax))))))))

(defun llm-source-text ()
  "Return gptel-send's source text without moving the live point.
Use an active region when present.  Otherwise include buffer text through the
end of the current word or punctuation run."
  (let ((buffer (current-buffer)))
    (if (buffer-mark-p buffer)
        (let ((global-mode (current-global-mode)))
          (points-to-string
           (region-beginning-using-global-mode global-mode buffer)
           (region-end-using-global-mode global-mode buffer)))
        (with-point ((end (current-point)))
          (with-point-syntax end
            (skip-chars-forward end #'llm-word-or-punctuation-char-p))
          (points-to-string (buffer-start-point buffer) end)))))

(defun llm-output-buffer ()
  (let ((buffer (make-buffer *llm-buffer-name*)))
    (handler-case
        (change-buffer-mode buffer 'lem-markdown-mode:markdown-mode)
      (error () nil))
    buffer))

(defun llm-buffer-live-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun llm-active-request (buffer)
  (and (llm-buffer-live-p buffer)
       (buffer-value buffer *llm-active-request-key*)))

(defun llm-buffer-append-now (buffer string)
  "Append STRING when BUFFER is still live.  Must run on the editor thread."
  (when (llm-buffer-live-p buffer)
    (insert-string (buffer-end-point buffer) string)
    (redraw-display)))

(defun llm-request-current-p (request)
  (let ((buffer (llm-request-buffer request)))
    (and (llm-buffer-live-p buffer)
         (eq request (llm-active-request buffer)))))

(defun llm-request-append (request string)
  "Append STRING for REQUEST via the editor queue when it is still current."
  (send-event
   (lambda ()
     (when (llm-request-current-p request)
       (llm-buffer-append-now (llm-request-buffer request) string)))))

(defun llm-request-finish (request final-text)
  "Finish REQUEST on the editor thread, appending FINAL-TEXT when non-NIL."
  (send-event
   (lambda ()
     (when (llm-request-current-p request)
       (when final-text
         (llm-buffer-append-now (llm-request-buffer request) final-text))
       (setf (buffer-value (llm-request-buffer request)
                           *llm-active-request-key*)
             nil)))))

(defun llm-register-request
    (buffer process backend &key tool-context tools-p)
  "Register and return an asynchronous request for BUFFER."
  (let ((request (make-llm-request buffer process backend
                                   :tool-context tool-context
                                   :tools-p tools-p)))
    (setf (buffer-value buffer *llm-active-request-key*) request)
    request))

(defun llm-request-aborted-now-p (request)
  (bt2:with-lock-held ((llm-request-lock request))
    (llm-request-aborted-p request)))

(defun llm-request-install-process (request process)
  "Assign PROCESS unless REQUEST has already been aborted."
  (bt2:with-lock-held ((llm-request-lock request))
    (if (llm-request-aborted-p request)
        nil
        (progn (setf (llm-request-process request) process) t))))

(defun llm-request-release-process (request process)
  (bt2:with-lock-held ((llm-request-lock request))
    (when (eq process (llm-request-process request))
      (setf (llm-request-process request) nil))))

(defun llm-request-abort-now (request)
  "Atomically abort REQUEST and return its currently owned process."
  (let ((process nil))
    (bt2:with-lock-held ((llm-request-lock request))
      (unless (llm-request-aborted-p request)
        (setf (llm-request-aborted-p request) t
              process (llm-request-process request)
              (llm-request-process request) nil)))
    (alexandria:when-let* ((context (llm-request-tool-context request))
                           (project-request
                             (llm-tool-context-project-request context)))
      (cancel-project-request project-request))
    (alexandria:when-let* ((context (llm-request-tool-context request))
                           (server-names
                             (llm-tool-context-mcp-server-names context)))
      (llm-mcp-abort-server-names server-names))
    process))

(defun llm-request-finish-text (request code failure-label)
  (cond
    ((llm-request-aborted-p request) "\n[request aborted]\n")
    ((and code (zerop code)) (string #\Newline))
    (t (format nil "~%[~a, exit ~a]~%" failure-label code))))

(define-command lem-yath-llm-abort () ()
  "Abort the active request in the shared LLM buffer."
  (let* ((buffer (llm-output-buffer))
         (request (llm-active-request buffer)))
    (if (null request)
        (message "No active LLM request")
        (let ((process (llm-request-abort-now request)))
          (when process
            (ignore-errors (uiop:terminate-process process :urgent t))
            (ignore-errors (uiop:close-streams process)))
          (llm-buffer-append-now buffer "\n[request aborted]\n")
          (setf (buffer-value buffer *llm-active-request-key*) nil)
          (message "Aborting ~(~a~) request"
                   (llm-request-backend request))))))

(defun llm-launch-openrouter-process (key body)
  (uiop:launch-program
   (list *llm-curl-executable* "-sN" *llm-endpoint*
         "-H" "Content-Type: application/json"
         "-H" (format nil "Authorization: Bearer ~a" key)
         "-d" body)
   :output :stream
   :error-output :output))

(defun llm-openrouter-round (request key body)
  "Run one HTTP/SSE round, returning its parsed response and exit status."
  (let ((process (llm-launch-openrouter-process key body))
        (finished-p nil))
    (unless (llm-request-install-process request process)
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:wait-process process))
      (return-from llm-openrouter-round (values nil nil)))
    (unwind-protect
         (let ((round (llm-read-openrouter-round request process))
               (code (uiop:wait-process process)))
           (setf finished-p t)
           (values round code))
      (unless finished-p
        (ignore-errors (uiop:terminate-process process :urgent t))
        (ignore-errors (uiop:wait-process process)))
      (llm-request-release-process request process))))

(defun llm-stream-tool-call-object (call)
  (llm-json-object
   "id" (llm-stream-tool-call-id call)
   "type" "function"
   "function"
   (llm-json-object
    "name" (llm-stream-tool-call-name call)
    "arguments" (llm-stream-tool-call-arguments call))))

(defun llm-stream-assistant-tool-message (round)
  (llm-json-object
   "role" "assistant"
   "content" (let ((content (llm-stream-round-content round)))
               (and (plusp (length content)) content))
   "tool_calls"
   (coerce (mapcar #'llm-stream-tool-call-object
                   (llm-stream-round-tool-calls round))
           'vector)))

(defun llm-stream-tool-result-message (call result)
  (llm-json-object
   "role" "tool"
   "tool_call_id" (llm-stream-tool-call-id call)
   "content" result))

(defun llm-render-tool-result (request call result)
  (llm-request-append
   request
   (format nil "~2%### Tool result: ~a~2%~a~%"
           (llm-stream-tool-call-name call) result)))

(defun llm-execute-stream-tool-calls (request round)
  "Execute ROUND's calls and return assistant/tool messages for the next turn."
  (let ((messages (list (llm-stream-assistant-tool-message round))))
    (dolist (call (llm-stream-round-tool-calls round) messages)
      (when (llm-request-aborted-now-p request)
        (return-from llm-execute-stream-tool-calls nil))
      (let ((result
              (llm-invoke-tool
               (llm-request-tool-context request)
               (llm-stream-tool-call-name call)
               (llm-stream-tool-call-arguments call))))
        (llm-render-tool-result request call result)
        (setf messages
              (append messages
                      (list (llm-stream-tool-result-message call result))))))))

(defun llm-openrouter-loop
    (request key messages model temperature max-tokens tools)
  "Run the bounded OpenRouter response/tool/response loop for REQUEST."
  (let ((tool-rounds 0)
        (tool-calls 0))
    (handler-case
        (loop
          (when (llm-request-aborted-now-p request) (return))
          (let ((body (llm-request-body-for-messages
                       messages model temperature max-tokens tools)))
            (multiple-value-bind (round code)
                (llm-openrouter-round request key body)
              (when (llm-request-aborted-now-p request) (return))
              (unless (and round (integerp code) (zerop code))
                (llm-request-finish
                 request
                 (llm-request-finish-text
                  request code "OpenRouter request failed"))
                (return))
              (let ((calls (llm-stream-round-tool-calls round)))
                (when (and (string= (or (llm-stream-round-finish-reason round)
                                        "")
                                    "tool_calls")
                           (null calls))
                  (error "OpenRouter ended for tool calls without providing one"))
                (when (null calls)
                  (llm-request-finish request (string #\Newline))
                  (return))
                (unless tools
                  (error "OpenRouter requested tools from a tool-free preset"))
                (when (>= tool-rounds *llm-max-tool-rounds*)
                  (error "LLM tool round limit reached"))
                (when (> (+ tool-calls (length calls))
                         *llm-max-tool-calls-per-request*)
                  (error "LLM tool call limit reached"))
                (incf tool-rounds)
                (incf tool-calls (length calls))
                (let ((tool-messages
                        (llm-execute-stream-tool-calls request round)))
                  (when (llm-request-aborted-now-p request) (return))
                  (setf messages (append messages tool-messages))
                  (llm-request-append
                   request
                   (format nil "~%### Assistant (continued)~2%")))))))
      (error (condition)
        (unless (llm-request-aborted-now-p request)
          (llm-request-finish
           request
           (format nil "~%[OpenRouter protocol error: ~a]~%"
                   condition)))))))

(defun llm-stream (prompt)
  (let ((key (llm-api-key))
        (model *llm-model*)
        (system *llm-system-message*)
        (temperature *llm-temperature*)
        (max-tokens *llm-max-tokens*)
        (tools-p *llm-use-tools*)
        (mcp-server-names (copy-list *llm-mcp-server-names*)))
    (unless key
      (message "Set OPENROUTER_API_KEY (or OPENAI_API_KEY) first")
      (return-from llm-stream))
    (let ((buffer (llm-output-buffer)))
      (when (llm-active-request buffer)
        (message "An LLM request is already running; use M-x lem-yath-llm-abort")
        (return-from llm-stream))
      (let ((tool-context
              (when tools-p
                (handler-case
                    (llm-capture-tool-context mcp-server-names)
                  (error ()
                    (message "Could not capture the LLM project context")
                    (return-from llm-stream))))))
        (pop-to-buffer buffer)
        (llm-buffer-append-now
         buffer
         (format nil "~%## User (~a)~%~%~a~%~%## Assistant~%~%"
                 model prompt))
        (handler-case
            (let ((request
                    (llm-register-request
                     buffer nil :openrouter
                     :tool-context tool-context :tools-p tools-p)))
              (bt2:make-thread
               (lambda ()
                 (unwind-protect
                      (handler-case
                          (let* ((sessions
                                   (and mcp-server-names
                                        (llm-mcp-ensure-servers
                                         mcp-server-names)))
                                 (tools
                                   (and tools-p
                                        (llm-tool-definitions sessions))))
                            (when tool-context
                              (setf (llm-tool-context-mcp-sessions tool-context)
                                    sessions))
                            (llm-openrouter-loop
                             request key (llm-initial-messages prompt system)
                             model temperature max-tokens tools))
                        (error (condition)
                          (unless (llm-request-aborted-now-p request)
                            (llm-request-finish
                             request
                             (format nil "~%[MCP connection error: ~a]~%"
                                     condition)))))
                   (when tool-context
                     (cancel-project-request
                      (llm-tool-context-project-request tool-context)))))
               :name "lem-yath/llm-openrouter"))
          (error ()
            (setf (buffer-value buffer *llm-active-request-key*) nil)
            (llm-buffer-append-now
             buffer "\n[failed to launch curl]\n")))))))

(defvar *llm-backend* :openrouter
  "Active backend. CLI-agent backends (apps/llm-cli.lisp) add more.")

(defgeneric llm-backend-stream (backend prompt)
  (:documentation "Stream PROMPT's reply into the LLM buffer for BACKEND.")
  (:method ((backend (eql :openrouter)) prompt)
    (llm-stream prompt)))

(define-command lem-yath-llm-send () ()
  "Send region (or buffer up to point) to the LLM, streaming the reply
(gptel-send)."
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return)
                           (llm-source-text))))
    (if (zerop (length text))
        (message "Nothing to send")
        (llm-backend-stream *llm-backend* text))))

(define-command lem-yath-llm-ask () ()
  "Prompt for an instruction, prepend it to the region/buffer text, send
(gptel-menu's ad-hoc directive, approximately)."
  (let ((instruction (prompt-for-string "LLM instruction: "))
        (text (string-trim '(#\Space #\Tab #\Newline) (llm-source-text))))
    (when (plusp (length instruction))
      (llm-backend-stream *llm-backend*
                          (if (zerop (length text))
                              instruction
                              (format nil "~a~%~%~a" instruction text))))))

(define-command lem-yath-llm-set-model () ()
  "Choose the OpenRouter model (gptel preset switching, simplified)."
  (let ((model (prompt-for-string "Model: " :initial-value *llm-model*
                                            :history-symbol 'lem-yath-llm-model)))
    (when (plusp (length model))
      (setf *llm-model* model)
      (message "LLM model: ~a" model))))
