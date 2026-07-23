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

(defun llm-mark-settings-custom ()
  "Mark the live request settings as diverged from their loaded preset."
  (when (boundp '*llm-current-preset*)
    (setf (symbol-value '*llm-current-preset*) "custom")))

(defvar *llm-buffer-name* "*lem-yath-llm*")

(defvar *llm-output-buffer-override* nil
  "Dynamically selected output buffer for one interactive LLM dispatch.")

(defvar *llm-response-origin* nil
  "Point where a conversation response should begin for one dispatch.")

(defvar *llm-request-source-buffer* nil
  "Buffer that initiated one request when output is redirected elsewhere.")

(defvar *llm-force-inline-output-p* nil
  "Whether one dispatch should stream at point without conversation mode.")

(defvar *llm-response-open-function* 'llm-response-open-conversation
  "Function that prepares and returns one response insertion point.")

(defvar *llm-response-close-function* 'llm-response-close-now
  "Function captured by one inline request to finish its insertion point.")

(defvar *llm-response-finish-function* nil
  "Optional callback captured by one request after routing cleanup.")

(defvar *llm-response-history* nil
  "Previous response strings to attach to one regenerated response.")

(defvar *llm-response-destination* nil
  "One-shot response destination selected by the full LLM menu.")

(defvar *llm-response-destination-buffer-name* nil
  "Buffer name associated with a one-shot response destination.")

(defvar *llm-response-routing-function* nil
  "Optional function implementing explicit response destinations.")

(defvar *llm-visible-prompt* nil
  "Unexpanded prompt shown in transcripts and request traces for one dispatch.")

(defun llm-visible-prompt (request-prompt)
  "Return the user-visible prompt corresponding to REQUEST-PROMPT."
  (or *llm-visible-prompt* request-prompt))

(defvar *lem-yath-llm-conversation-mode-keymap*
  (make-keymap :description '*lem-yath-llm-conversation-mode-keymap*))

(define-key *lem-yath-llm-conversation-mode-keymap*
  "C-c Return" 'lem-yath-llm-send)

(define-minor-mode lem-yath-llm-conversation-mode
    (:name "LLM"
     :keymap *lem-yath-llm-conversation-mode-keymap*
     :enable-hook 'llm-role-visuals-mode-enable
     :disable-hook 'llm-role-visuals-mode-disable)
  "Insert streamed LLM replies into this buffer at the send position.")

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
                (buffer process backend
                 &key prompt insertion-point tool-context tools-p
                   source-buffer response-close-function
                   response-finish-function response-start response-history
                   model system-message temperature max-tokens use-tools
                   provider-session-id provider-message-id)))
  "One asynchronous LLM request owned by BUFFER."
  buffer
  process
  backend
  prompt
  insertion-point
  response-start
  response-history
  source-buffer
  tool-context
  tools-p
  response-close-function
  response-finish-function
  model
  system-message
  temperature
  max-tokens
  use-tools
  provider-session-id
  provider-message-id
  visual-state
  (aborted-p nil)
  (lock (bt2:make-lock :name "lem-yath/llm-request")))

(defparameter *llm-active-request-key* 'lem-yath-llm-active-request)
(defparameter *llm-forward-request-buffer-key*
  'lem-yath-llm-forward-request-buffer)

(defvar *llm-request-start-functions* nil
  "Editor-thread callbacks run after a request acquires its buffer.")

(defvar *llm-request-insert-functions* nil
  "Editor-thread callbacks run after one request chunk is inserted.")

(defvar *llm-request-finish-functions* nil
  "Editor-thread callbacks run before a request releases display state.")

(defun llm-run-request-functions (functions request &rest arguments)
  "Run request lifecycle FUNCTIONS without letting presentation break I/O."
  (dolist (function functions)
    (handler-case
        (apply function request arguments)
      (error (condition)
        (log:error "LLM request callback ~S failed: ~A" function condition)))))

(defun llm-api-key ()
  (or (uiop:getenv "OPENROUTER_API_KEY")
      (uiop:getenv "OPENAI_API_KEY")))

(defun llm-curl-config-quote (string)
  "Quote STRING for one double-quoted curl config value."
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (case character
                (#\\ (write-string "\\\\" stream))
                (#\" (write-string "\\\"" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (otherwise (write-char character stream))))))

(defun llm-curl-config (method url headers &optional body)
  "Build curl configuration for stdin, including URL, headers, and BODY."
  (with-output-to-string (stream)
    (flet ((option (name value)
             (format stream "~a = \"~a\"~%"
                     name (llm-curl-config-quote value))))
      (option "request" method)
      (dolist (header headers)
        (option "header" (format nil "~a: ~a" (car header) (cdr header))))
      (when body (option "data-binary" body))
      (option "url" url))))

(defun llm-curl-executable-path ()
  "Return the configured curl executable as an existing pathname."
  (let ((pathname (uiop:parse-native-namestring *llm-curl-executable*)))
    (or (and (uiop:absolute-pathname-p pathname)
             (uiop:probe-file* pathname))
        (executable-find *llm-curl-executable*)
        (error "curl is unavailable"))))

(defun llm-curl-arguments (timeout &key stream-p status-p)
  "Return curl argv with all request data reserved for stdin config."
  (append (list (uiop:native-namestring (llm-curl-executable-path))
                "--silent" "--show-error" "--fail-with-body")
          (when stream-p (list "--no-buffer"))
          (when status-p
            (list "--write-out"
                  "\\n__LEM_YATH_HTTP_STATUS__:%{http_code}\\n"))
          (list "--max-time" (princ-to-string timeout) "--config" "-")))

(defun llm-launch-curl-stream (method url headers body timeout &key status-p)
  "Launch a curl stream while keeping request data and secrets off argv."
  (let* ((process
           (uiop:launch-program
            (llm-curl-arguments timeout :stream-p t :status-p status-p)
            :input :stream :output :stream :error-output :output))
         (input (uiop:process-info-input process)))
    (handler-case
        (progn
          (write-string (llm-curl-config method url headers body) input)
          (finish-output input)
          (close input)
          process)
      (error (condition)
        (ignore-errors (close input :abort t))
        (ignore-errors (uiop:terminate-process process :urgent t))
        (ignore-errors (uiop:wait-process process))
        (error condition)))))

(defun llm-initial-messages (prompt &optional (system *llm-system-message*))
  (list (llm-json-object "role" "system" "content" system)
        (llm-json-object "role" "user" "content" prompt)))

(defun llm-request-body-for-messages
    (messages model temperature max-tokens tools)
  (with-output-to-string (s)
    (let ((body (llm-json-object
                 "model" model
                 "stream" t
                 "messages" (coerce messages 'vector))))
      (when temperature
        (setf (gethash "temperature" body) temperature))
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
  (multiple-value-bind (start end) (llm-source-bounds)
    (points-to-string start end)))

(defun llm-source-bounds ()
  "Return gptel-send's source bounds and whether they are an active region."
  (let ((buffer (current-buffer)))
    (if (buffer-mark-p buffer)
        (let ((global-mode (current-global-mode)))
          (values
           (region-beginning-using-global-mode global-mode buffer)
           (region-end-using-global-mode global-mode buffer)
           t))
        (with-point ((end (current-point)))
          (with-point-syntax end
            (skip-chars-forward end #'llm-word-or-punctuation-char-p))
          (values (buffer-start-point buffer) end nil)))))

(defun llm-buffer-live-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun llm-conversation-buffer-p (&optional (buffer (current-buffer)))
  (and (llm-buffer-live-p buffer)
       (ignore-errors
         (mode-active-p buffer 'lem-yath-llm-conversation-mode))))

(defun llm-forward-request-buffer (&optional (buffer (current-buffer)))
  "Return BUFFER's live redirected-output buffer, clearing stale state."
  (when (llm-buffer-live-p buffer)
    (let ((target (buffer-value buffer *llm-forward-request-buffer-key*)))
      (if (and (llm-buffer-live-p target) (llm-active-request target))
          target
          (progn
            (setf (buffer-value buffer *llm-forward-request-buffer-key*) nil)
            nil)))))

(defun llm-output-buffer ()
  (if (llm-buffer-live-p *llm-output-buffer-override*)
      *llm-output-buffer-override*
      (let ((buffer (make-buffer *llm-buffer-name*)))
        (handler-case
            (change-buffer-mode buffer 'lem-markdown-mode:markdown-mode)
          (error () nil))
        buffer)))

(defun llm-current-output-buffer ()
  "Return the request-bearing conversation buffer or shared transcript."
  (let ((current (current-buffer)))
    (cond
      ((llm-active-request current) current)
      ((llm-forward-request-buffer current))
      ((llm-conversation-buffer-p current)
       (let* ((*llm-output-buffer-override* nil)
              (shared (llm-output-buffer)))
         (if (llm-active-request shared) shared current)))
      (t (llm-output-buffer)))))

(defun llm-active-request (buffer)
  (and (llm-buffer-live-p buffer)
       (buffer-value buffer *llm-active-request-key*)))

(defun llm-buffer-append-now (buffer string)
  "Append STRING when BUFFER is still live.  Must run on the editor thread."
  (when (llm-buffer-live-p buffer)
    (insert-string (buffer-end-point buffer) string)
    (redraw-display)))

(defun llm-response-open-conversation (origin)
  "Insert conversation spacing at ORIGIN and return a tracked point."
  (let ((insertion-point (copy-point origin :left-inserting)))
    (insert-string insertion-point (format nil "~2%"))
    insertion-point))

(defun llm-response-open-plain (origin)
  "Return a tracked response point at ORIGIN without inserting decoration."
  (copy-point origin :left-inserting))

(defun llm-prepare-response (buffer shared-heading)
  "Present BUFFER and prepare one response insertion point.
SHARED-HEADING is rendered only for the traditional shared transcript."
  (if (or (llm-conversation-buffer-p buffer) *llm-force-inline-output-p*)
      (progn
        (when (buffer-read-only-p buffer)
          (editor-error "Conversation buffer is read only"))
        (let ((origin (if (and *llm-response-origin*
                               (eq buffer
                                   (point-buffer *llm-response-origin*)))
                          *llm-response-origin*
                          (buffer-point buffer))))
          (funcall (or *llm-response-open-function*
                       #'llm-response-open-conversation)
                   origin)))
      (progn
        (pop-to-buffer buffer)
        (llm-buffer-append-now buffer shared-heading)
        nil)))

(defun llm-request-conversation-p (request)
  (not (null (llm-request-insertion-point request))))

(defun llm-response-insert-now (insertion-point string &key assistant-p)
  (when (and insertion-point (alive-point-p insertion-point)
             (plusp (length string)))
    (if assistant-p
        (insert-string insertion-point string
                       'lem-yath-llm-role :assistant)
        (insert-string insertion-point string))))

(defun llm-response-close-now (insertion-point)
  (when (and insertion-point (alive-point-p insertion-point))
    (insert-string insertion-point (format nil "~2%* ")
                   'lem-yath-llm-role :user)
    (delete-point insertion-point)))

(defun llm-close-insertion-point-now (insertion-point function)
  (funcall (or function #'llm-response-close-now) insertion-point))

(defun llm-response-close-plain (insertion-point)
  "Release INSERTION-POINT without adding a following prompt."
  (when (and insertion-point (alive-point-p insertion-point))
    (delete-point insertion-point)))

(defun llm-run-response-finish-function (request reason)
  (alexandria:when-let ((function
                         (llm-request-response-finish-function request)))
    (handler-case
        (funcall function request reason)
      (error (condition)
        (log:error "LLM response routing callback failed: ~A" condition)))))

(defun llm-clear-forward-request-buffer (request)
  (let ((source (llm-request-source-buffer request))
        (target (llm-request-buffer request)))
    (when (and (llm-buffer-live-p source)
               (eq (buffer-value source *llm-forward-request-buffer-key*)
                   target))
      (setf (buffer-value source *llm-forward-request-buffer-key*) nil))))

(defun llm-unregistered-response-failure-now
    (buffer insertion-point text)
  "Render TEXT and release an insertion point that no request owns."
  (if insertion-point
      (progn
        (llm-response-insert-now insertion-point text :assistant-p t)
        (llm-close-insertion-point-now
         insertion-point *llm-response-close-function*)
        (redraw-display))
      (llm-buffer-append-now buffer text)))

(defun llm-request-current-p (request)
  (let ((buffer (llm-request-buffer request)))
    (and (llm-buffer-live-p buffer)
         (eq request (llm-active-request buffer)))))

(defun llm-request-insert-now (request string)
  "Insert STRING at REQUEST's tracked point, or append to its shared buffer."
  (if (llm-request-conversation-p request)
      (progn
        (llm-response-insert-now (llm-request-insertion-point request)
                                 string :assistant-p t)
        (llm-run-request-functions
         *llm-request-insert-functions* request string)
        (redraw-display))
      (progn
        (llm-buffer-append-now (llm-request-buffer request) string)
        (llm-run-request-functions
         *llm-request-insert-functions* request string))))

(defun llm-request-release-insertion-point (request)
  (dolist (point (list (llm-request-insertion-point request)
                       (llm-request-response-start request)))
    (when (and point (alive-point-p point))
      (ignore-errors (delete-point point))))
  (setf (llm-request-insertion-point request) nil
        (llm-request-response-start request) nil))

(defun llm-request-complete-now (request final-text)
  "Complete current REQUEST on the editor thread."
  (when (llm-request-current-p request)
    (when final-text
      (let ((text (if (llm-request-conversation-p request)
                      (string-right-trim '(#\Newline #\Return) final-text)
                      final-text)))
        (when (plusp (length text))
          (llm-request-insert-now request text))))
    (llm-run-request-functions
     *llm-request-finish-functions* request :complete)
    (when (llm-request-conversation-p request)
      (llm-close-insertion-point-now
       (llm-request-insertion-point request)
       (llm-request-response-close-function request))
      (setf (llm-request-insertion-point request) nil)
      (redraw-display))
    (setf (buffer-value (llm-request-buffer request)
                        *llm-active-request-key*)
          nil)
    (llm-clear-forward-request-buffer request)
    (llm-request-release-insertion-point request)
    (llm-run-response-finish-function request :complete)))

(defun llm-request-append (request string)
  "Append STRING for REQUEST via the editor queue when it is still current."
  (send-event
   (lambda ()
     (when (llm-request-current-p request)
       (llm-request-insert-now request string)))))

(defun llm-request-finish (request final-text)
  "Finish REQUEST on the editor thread, appending FINAL-TEXT when non-NIL."
  (send-event
   (lambda ()
     (llm-request-complete-now request final-text))))

(defun llm-start-request-thread (request function name failure-text)
  "Start FUNCTION for REQUEST and fail it closed when thread creation fails."
  (handler-case
      (bt2:make-thread function :name name)
    (error ()
      (alexandria:when-let ((process (llm-request-process request)))
        (ignore-errors (uiop:terminate-process process :urgent t))
        (ignore-errors (uiop:close-streams process))
        (llm-request-release-process request process))
      (llm-request-complete-now request failure-text)
      nil)))

(defun llm-register-request
    (buffer process backend &key prompt insertion-point tool-context tools-p)
  "Register and return an asynchronous request for BUFFER."
  (let* ((source (or *llm-request-source-buffer* buffer))
         (request (make-llm-request buffer process backend
                                   :prompt prompt
                                   :insertion-point insertion-point
                                   :response-start
                                   (and insertion-point
                                        (copy-point insertion-point
                                                    :right-inserting))
                                   :response-history *llm-response-history*
                                   :source-buffer source
                                   :tool-context tool-context
                                   :tools-p tools-p
                                   :response-close-function
                                   *llm-response-close-function*
                                   :response-finish-function
                                   *llm-response-finish-function*
                                   :model *llm-model*
                                   :system-message *llm-system-message*
                                   :temperature *llm-temperature*
                                   :max-tokens *llm-max-tokens*
                                   :use-tools *llm-use-tools*)))
    (setf (buffer-value buffer *llm-active-request-key*) request)
    (when (and (llm-buffer-live-p source) (not (eq source buffer)))
      (setf (buffer-value source *llm-forward-request-buffer-key*) buffer))
    (llm-run-request-functions *llm-request-start-functions* request)
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
    ((llm-request-aborted-p request) (format nil "~%[request aborted]~%"))
    ((and code (zerop code)) (string #\Newline))
    (t (format nil "~%[~a, exit ~a]~%" failure-label code))))

(define-command lem-yath-llm-abort () ()
  "Abort the active request in the current conversation or shared transcript."
  (let* ((buffer (llm-current-output-buffer))
         (request (llm-active-request buffer)))
    (if (null request)
        (message "No active LLM request")
        (let ((process (llm-request-abort-now request)))
          (when process
            (ignore-errors (uiop:terminate-process process :urgent t))
            (ignore-errors (uiop:close-streams process)))
          (llm-request-complete-now
           request (format nil "~%[request aborted]~%"))
          (message "Aborting ~(~a~) request"
                   (llm-request-backend request))))))

(defun llm-kill-buffer-hook (buffer)
  "Abort asynchronous state owned by BUFFER before BUFFER is deleted."
  ;; A redirected request is owned by its output buffer, but killing the
  ;; originating buffer must still stop it.  Complete it while the source is
  ;; live so routing callbacks can release private sinks and tracked state.
  (alexandria:when-let* ((target (llm-forward-request-buffer buffer))
                         (request (llm-active-request target)))
    (alexandria:when-let ((process (llm-request-abort-now request)))
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:close-streams process)))
    (llm-request-complete-now request nil))
  (alexandria:when-let ((request (llm-active-request buffer)))
    (llm-run-request-functions
     *llm-request-finish-functions* request :kill)
    (setf (buffer-value buffer *llm-active-request-key*) nil)
    (llm-clear-forward-request-buffer request)
    (alexandria:when-let ((process (llm-request-abort-now request)))
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (uiop:close-streams process)))
    (llm-request-release-insertion-point request)))

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'llm-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'llm-kill-buffer-hook)

(defun llm-launch-openrouter-process (key body)
  (llm-launch-curl-stream
   "POST" *llm-endpoint*
   `(("Content-Type" . "application/json")
     ("Authorization" . ,(format nil "Bearer ~a" key)))
   body 300))

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
  (let* ((key (llm-api-key))
         (model *llm-model*)
         (visible-prompt (llm-visible-prompt prompt))
         (system *llm-system-message*)
         (temperature *llm-temperature*)
         (max-tokens *llm-max-tokens*)
         (tools-p *llm-use-tools*)
         (mcp-server-names (copy-list *llm-mcp-server-names*))
         (messages (llm-messages-with-system prompt system)))
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
        (let ((insertion-point
                (llm-prepare-response
                 buffer
                 (format nil "~%## User (~a)~%~%~a~%~%## Assistant~%~%"
                         model visible-prompt)))
              (request nil))
          (handler-case
              (progn
                (setf request
                      (llm-register-request
                       buffer nil :openrouter
                       :prompt visible-prompt
                       :insertion-point insertion-point
                       :tool-context tool-context :tools-p tools-p))
                (llm-start-request-thread
                 request
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
                                (setf
                                 (llm-tool-context-mcp-sessions tool-context)
                                 sessions))
                              (llm-openrouter-loop
                               request key messages
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
                 "lem-yath/llm-openrouter"
                 (format nil "~%[failed to start OpenRouter request]~%")))
            (error ()
              (if request
                  (llm-request-complete-now
                   request (format nil "~%[failed to launch curl]~%"))
                  (llm-unregistered-response-failure-now
                   buffer insertion-point
                   (format nil "~%[failed to launch curl]~%"))))))))))

(defvar *llm-backend* :openrouter
  "Active backend. CLI-agent backends (apps/llm-cli.lisp) add more.")

(defgeneric llm-backend-stream (backend prompt)
  (:documentation "Stream PROMPT's reply into the LLM buffer for BACKEND.")
  (:method ((backend (eql :openrouter)) prompt)
    (llm-stream prompt)))

(defun llm-dispatch-from-current-buffer
    (function &key visible-prompt request-prompt messages)
  "Call FUNCTION with conversation routing for the current buffer.
Read-only conversations follow gptel by falling back to the shared transcript."
  (let ((buffer (current-buffer)))
    (cond
      ((and *llm-response-destination* *llm-response-routing-function*)
       (funcall *llm-response-routing-function*
                buffer visible-prompt request-prompt messages function))
      ((and (not *llm-force-inline-output-p*)
            (not (llm-conversation-buffer-p buffer)))
       (funcall function messages))
      ((buffer-read-only-p buffer)
       (if *llm-force-inline-output-p*
           (editor-error "Inline LLM destination is read only")
           (progn
             (message "Conversation is read only; using the shared LLM buffer")
             (funcall function messages))))
      (t
       (let ((*llm-output-buffer-override* buffer)
             (*llm-response-origin* (current-point)))
         (funcall function messages))))))

(defun llm-dispatch-prompt-from-current-buffer (prompt messages)
  "Dispatch PROMPT with this buffer's live context and typed MESSAGES.
Context is sent to the provider but excluded from the visible transcript and
request trace."
  (let ((source-buffer (current-buffer)))
    (unwind-protect
         (handler-case
             (let* ((request-prompt
                      (llm-context-wrap-prompt source-buffer prompt))
                    (request-messages
                      (and messages
                           (llm-conversation-replace-last-user-content
                            messages request-prompt)))
                    (*llm-visible-prompt* prompt)
                    (*llm-conversation-messages* request-messages))
               (llm-dispatch-from-current-buffer
                (lambda (effective-messages)
                  (let ((*llm-conversation-messages* effective-messages))
                    (llm-backend-stream *llm-backend* request-prompt)))
                :visible-prompt prompt
                :request-prompt request-prompt
                :messages request-messages))
           (error (condition)
             (message "Could not prepare LLM context: ~a" condition)))
      (setf *llm-response-destination* nil
            *llm-response-destination-buffer-name* nil))))

(defun llm-current-prompt-data ()
  "Return the current gptel-style prompt, typed messages, and region flag."
  (multiple-value-bind (start end region-p) (llm-source-bounds)
    (let* ((raw (points-to-string start end))
           (messages
             (and (not region-p)
                  (llm-conversation-buffer-p)
                  (llm-conversation-messages-to-point
                   (current-buffer) end)))
           (text
             (string-trim
              '(#\Space #\Tab #\Newline #\Return)
              (or (and messages
                       (llm-conversation-last-user-content messages))
                  (llm-render-user-text-for-buffer
                   raw (current-buffer))))))
      (values text messages region-p))))

(define-command lem-yath-llm-send () ()
  "Send region (or buffer up to point) to the LLM, streaming the reply
(gptel-send)."
  (multiple-value-bind (text messages) (llm-current-prompt-data)
    (if (zerop (length text))
        (message "Nothing to send")
        (llm-dispatch-prompt-from-current-buffer text messages))))

(define-command lem-yath-llm-ask () ()
  "Prompt for an instruction, prepend it to the region/buffer text, send
(gptel-menu's ad-hoc directive, approximately)."
  (let ((instruction (prompt-for-string "LLM instruction: ")))
    (when (plusp (length instruction))
      (multiple-value-bind (start end region-p) (llm-source-bounds)
        (let* ((raw (points-to-string start end))
               (messages
                 (and (not region-p)
                      (llm-conversation-buffer-p)
                      (llm-conversation-messages-to-point
                       (current-buffer) end)))
               (source
                 (string-trim
                  '(#\Space #\Tab #\Newline #\Return)
                  (or (and messages
                           (llm-conversation-last-user-content messages))
                      (llm-render-user-text-for-buffer
                       raw (current-buffer)))))
               (prompt
                 (if (zerop (length source))
                     instruction
                     (format nil "~a~2%~a" instruction source))))
          (llm-dispatch-prompt-from-current-buffer prompt messages))))))
