;;;; One-shot gptel prompt capture into today's Org-roam daily note.

(in-package :lem-yath)

(defparameter *llm-capture-prompt-character-limit* 4096)

(defun llm-capture-prompt (input)
  "Return a safe one-line heading and request prompt from INPUT."
  (unless (stringp input)
    (editor-error "An LLM capture prompt must be text"))
  (let ((prompt (string-trim '(#\Space #\Tab) input)))
    (when (zerop (length prompt))
      (editor-error "An LLM capture prompt cannot be blank"))
    (when (> (length prompt) *llm-capture-prompt-character-limit*)
      (editor-error "The LLM capture prompt exceeds ~d characters"
                    *llm-capture-prompt-character-limit*))
    (when (some (lambda (character)
                  (let ((code (char-code character)))
                    (or (< code 32) (= code 127))))
                prompt)
      (editor-error "An LLM capture prompt cannot contain control characters"))
    prompt))

(defun llm-capture-property-value (value)
  (with-output-to-string (stream)
    (loop :for character :across value
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return nil)
                (otherwise (write-char character stream))))))

(defun llm-capture-backend-name ()
  (case *llm-backend*
    (:openrouter "OpenRouter")
    (:perplexity "Perplexity")
    (:copilot "GitHub Copilot")
    (:chatgpt-codex "ChatGPT Codex")
    (:grok-oauth "Grok Build OAuth")
    (:claude-code "Claude Code")
    (:codex "Codex")
    (:grok "Grok Build")
    (otherwise
     (string-capitalize (string-downcase (symbol-name *llm-backend*))))))

(defun llm-capture-settings-properties ()
  "Return gptel-compatible properties for the active Lem request settings."
  (if (and (boundp '*llm-current-preset*)
           (stringp *llm-current-preset*)
           (not (string= *llm-current-preset* "custom")))
      (list (cons "GPTEL_PRESET" *llm-current-preset*))
      (append
       (list (cons "GPTEL_BACKEND" (llm-capture-backend-name))
             (cons "GPTEL_MODEL" *llm-model*)
             (cons "GPTEL_SYSTEM"
                   (llm-capture-property-value *llm-system-message*)))
       (when *llm-temperature*
         (list (cons "GPTEL_TEMPERATURE"
                     (format nil "~a" *llm-temperature*))))
       (when *llm-max-tokens*
         (list (cons "GPTEL_MAX_TOKENS"
                     (format nil "~d" *llm-max-tokens*))))
       (when *llm-use-tools*
         (list
          (cons "GPTEL_TOOLS"
                "project_root list_project_files search_project read_project_file read_emacs_symbol"))))))

(defun llm-capture-properties (prompt id)
  (append (list (cons "ID" id)
                (cons "GPTEL_TOPIC" prompt))
          (llm-capture-settings-properties)))

(defun llm-capture-heading-text (prompt id)
  (with-output-to-string (stream)
    (format stream "* ~a :llm:~%:PROPERTIES:~%" prompt)
    (dolist (property (llm-capture-properties prompt id))
      (format stream ":~a: ~a~%" (car property) (cdr property)))
    (format stream ":END:~%")))

(defun llm-capture-append-heading (buffer prompt)
  "Append PROMPT as a tagged daily heading and return its generated ID."
  (when (buffer-read-only-p buffer)
    (editor-error "Today's daily note is read only"))
  (let ((id (uuid-v4))
        (point (buffer-end-point buffer)))
    (let ((last (character-at point -1)))
      (when (and last (char/= last #\Newline))
        (insert-character point #\Newline)))
    (insert-character point #\Newline)
    (insert-string point (llm-capture-heading-text prompt id))
    (buffer-end (buffer-point buffer))
    id))

(defun llm-capture-close-response (insertion-point)
  "Finish a one-shot daily response without creating another Org heading."
  (when (and insertion-point (alive-point-p insertion-point))
    (insert-character insertion-point #\Newline)
    (delete-point insertion-point)))

(define-command yath/llm-capture () ()
  "Capture an initial prompt under today's daily note and send it to the LLM."
  (let ((prompt
          (llm-capture-prompt
           (prompt-for-string "Type in your prompt: "))))
    (multiple-value-bind (date) (decoded-date-strings)
      (open-daily-note date))
    (let ((buffer (current-buffer)))
      (when (llm-active-request buffer)
        (editor-error "Today's daily note already owns an LLM request"))
      (llm-capture-append-heading buffer prompt)
      (let ((*llm-force-inline-output-p* t)
            (*llm-response-close-function* #'llm-capture-close-response))
        (llm-dispatch-prompt-from-current-buffer prompt nil)))))
