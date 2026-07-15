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

(defvar *llm-buffer-name* "*lem-yath-llm*")

(defstruct (llm-request
            (:constructor make-llm-request (buffer process backend)))
  "One asynchronous LLM request owned by BUFFER."
  buffer
  process
  backend
  (aborted-p nil))

(defparameter *llm-active-request-key* 'lem-yath-llm-active-request)

(defun llm-api-key ()
  (or (uiop:getenv "OPENROUTER_API_KEY")
      (uiop:getenv "OPENAI_API_KEY")))

(defun llm-request-body (prompt)
  (with-output-to-string (s)
    (yason:encode
     (alexandria:alist-hash-table
      `(("model" . ,*llm-model*)
        ("stream" . t)
        ("temperature" . ,*llm-temperature*)
        ,@(when *llm-max-tokens* `(("max_tokens" . ,*llm-max-tokens*)))
        ("messages" . ,(vector
                        (alexandria:alist-hash-table
                         `(("role" . "system")
                           ("content" . ,*llm-system-message*))
                         :test #'equal)
                        (alexandria:alist-hash-table
                         `(("role" . "user") ("content" . ,prompt))
                         :test #'equal))))
      :test #'equal)
     s)))

(defun llm-delta-content (line)
  "Extract the streamed content delta from one SSE LINE, or NIL."
  (when (and (> (length line) 6)
             (string= "data: " (subseq line 0 6)))
    (let ((payload (subseq line 6)))
      (unless (string= payload "[DONE]")
        (handler-case
            (let* ((json (yason:parse payload))
                   (choices (gethash "choices" json)))
              (when (and choices (plusp (length choices)))
                (let ((delta (gethash "delta" (elt choices 0))))
                  (when delta
                    (let ((content (gethash "content" delta)))
                      (and (stringp content) content))))))
          (error () nil))))))

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

(defun llm-register-request (buffer process backend)
  "Register and return an asynchronous request for BUFFER."
  (let ((request (make-llm-request buffer process backend)))
    (setf (buffer-value buffer *llm-active-request-key*) request)
    request))

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
        (handler-case
            (progn
              (setf (llm-request-aborted-p request) t)
              (uiop:terminate-process (llm-request-process request) :urgent t)
              (ignore-errors
                (uiop:close-streams (llm-request-process request)))
              (llm-buffer-append-now buffer "\n[request aborted]\n")
              (setf (buffer-value buffer *llm-active-request-key*) nil)
              (message "Aborting ~(~a~) request" (llm-request-backend request)))
          (error ()
            (setf (llm-request-aborted-p request) nil)
            (message "Could not abort LLM request"))))))

(defun llm-stream (prompt)
  (let ((key (llm-api-key)))
    (unless key
      (message "Set OPENROUTER_API_KEY (or OPENAI_API_KEY) first")
      (return-from llm-stream))
    (let ((buffer (llm-output-buffer)))
      (when (llm-active-request buffer)
        (message "An LLM request is already running; use M-x lem-yath-llm-abort")
        (return-from llm-stream))
      (pop-to-buffer buffer)
      (llm-buffer-append-now
       buffer
       (format nil "~%## User (~a)~%~%~a~%~%## Assistant~%~%"
               *llm-model* prompt))
      (handler-case
          (let* ((process
                   (uiop:launch-program
                    (list *llm-curl-executable* "-sN" *llm-endpoint*
                          "-H" "Content-Type: application/json"
                          "-H" (format nil "Authorization: Bearer ~a" key)
                          "-d" (llm-request-body prompt))
                    :output :stream
                    :error-output :output))
                 (request (llm-register-request buffer process :openrouter)))
            (bt2:make-thread
             (lambda ()
               (unwind-protect
                    (with-open-stream (out (uiop:process-info-output process))
                      (loop :for line := (read-line out nil)
                            :while line
                            :do (alexandria:when-let
                                    ((chunk (llm-delta-content line)))
                                  (llm-request-append request chunk))))
                 (let ((code (ignore-errors (uiop:wait-process process))))
                   (llm-request-finish
                    request
                    (llm-request-finish-text
                     request code "OpenRouter request failed")))))
             :name "lem-yath/llm-openrouter"))
        (error ()
          (llm-buffer-append-now
           buffer "\n[failed to launch curl]\n"))))))

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
