;;;; LLM layer: gptel -> a native Lem client for OpenRouter (the Emacs
;;;; config's default backend), streaming via curl on a background thread
;;;; and marshalling chunks onto the editor thread with send-event.
;;;; CLI-agent backends (claude/codex/grok) live in apps/llm-cli.lisp.

(in-package :lem-yath)

(defvar *llm-model* "openrouter/auto"
  "Default model, matching gptel's OpenRouter default.")

(defvar *llm-endpoint* "https://openrouter.ai/api/v1/chat/completions")

(defvar *llm-system-message* "Very short answers. Be helpful."
  "Same system message as the Emacs gptel setup.")

(defvar *llm-buffer-name* "*lem-yath-llm*")

(defun llm-api-key ()
  (or (uiop:getenv "OPENROUTER_API_KEY")
      (uiop:getenv "OPENAI_API_KEY")))

(defun llm-request-body (prompt)
  (with-output-to-string (s)
    (yason:encode
     (alexandria:alist-hash-table
      `(("model" . ,*llm-model*)
        ("stream" . t)
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

(defun llm-source-text ()
  "Region if a mark is active, else the buffer up to point (gptel's rule)."
  (let ((buffer (current-buffer)))
    (if (buffer-mark-p buffer)
        (points-to-string (region-beginning buffer) (region-end buffer))
        (points-to-string (buffer-start-point buffer) (current-point)))))

(defun llm-output-buffer ()
  (let ((buffer (make-buffer *llm-buffer-name*)))
    (handler-case
        (change-buffer-mode buffer 'lem-markdown-mode:markdown-mode)
      (error () nil))
    buffer))

(defun llm-stream (prompt)
  (let ((key (llm-api-key)))
    (unless key
      (message "Set OPENROUTER_API_KEY (or OPENAI_API_KEY) first")
      (return-from llm-stream))
    (let ((buffer (llm-output-buffer)))
      (pop-to-buffer buffer)
      (append-text buffer (format nil "~%## User (~a)~%~%~a~%~%## Assistant~%~%"
                                  *llm-model* prompt))
      (let ((process (uiop:launch-program
                      (list "curl" "-sN" *llm-endpoint*
                            "-H" "Content-Type: application/json"
                            "-H" (format nil "Authorization: Bearer ~a" key)
                            "-d" (llm-request-body prompt))
                      :output :stream
                      :error-output :stream)))
        (bt2:make-thread
         (lambda ()
           (unwind-protect
                (with-open-stream (out (uiop:process-info-output process))
                  (loop :for line := (read-line out nil)
                        :while line
                        :do (alexandria:when-let ((chunk (llm-delta-content line)))
                              (append-text buffer chunk))))
             (let ((code (ignore-errors (uiop:wait-process process))))
               (if (and code (zerop code))
                   (append-text buffer (string #\Newline))
                   (append-line buffer (format nil "~%[llm request failed, curl exit ~a]" code))))))
         :name "lem-yath/llm")))))

(defvar *llm-backend* :openrouter
  "Active backend. CLI-agent backends (apps/llm-cli.lisp) add more.")

(defgeneric llm-backend-stream (backend prompt)
  (:documentation "Stream PROMPT's reply into the LLM buffer for BACKEND.")
  (:method ((backend (eql :openrouter)) prompt)
    (llm-stream prompt)))

(define-command lem-yath-llm-send () ()
  "Send region (or buffer up to point) to the LLM, streaming the reply
(gptel-send)."
  (let ((text (string-trim '(#\Space #\Tab #\Newline) (llm-source-text))))
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
