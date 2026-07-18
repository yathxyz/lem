;;;; gptel-style one-shot response destinations and dry-run request inspection.

(in-package :lem-yath)

(defparameter *llm-request-preview-buffer-name* "*gptel-request-preview*")
(defvar *llm-redirect-buffer-sequence* 0)

(defvar *llm-request-preview-mode-keymap*
  (make-keymap :description '*llm-request-preview-mode-keymap*))

(define-major-mode lem-yath-llm-request-preview-mode nil
    (:name "LLM-Request" :keymap *llm-request-preview-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-llm-request-preview-mode))
  (list *llm-request-preview-mode-keymap*))

(define-key *llm-request-preview-mode-keymap* "q" 'quit-active-window)

(defun llm-response-destination-label ()
  (case *llm-response-destination*
    (:echo "echo area")
    (:kill-ring "kill-ring")
    (:buffer
     (format nil "buffer ~a" *llm-response-destination-buffer-name*))
    (:conversation
     (format nil "LLM session ~a" *llm-response-destination-buffer-name*))
    (otherwise "current/default")))

(defun llm-valid-response-buffer-name-p (name)
  (and (stringp name)
       (plusp (length name))
       (<= (length name) 256)
       (not (some (lambda (character)
                    (let ((code (char-code character)))
                      (or (< code 32) (= code 127))))
                  name))))

(defun llm-select-response-destination (destination &optional buffer-name)
  (when (and buffer-name (not (llm-valid-response-buffer-name-p buffer-name)))
    (editor-error "Invalid LLM response buffer name"))
  (setf *llm-response-destination* destination
        *llm-response-destination-buffer-name* buffer-name)
  (message "Next LLM response: ~a" (llm-response-destination-label)))

(define-command lem-yath-llm-response-current () ()
  "Restore the ordinary response destination for the next request."
  (llm-select-response-destination nil))

(define-command lem-yath-llm-response-echo () ()
  "Send the next response to the echo area."
  (llm-select-response-destination :echo))

(define-command lem-yath-llm-response-kill-ring () ()
  "Copy the next completed response to the kill ring."
  (llm-select-response-destination :kill-ring))

(define-command lem-yath-llm-response-buffer () ()
  "Insert the next response at point in another buffer."
  (let ((name (prompt-for-buffer "Output to buffer: " :existing nil)))
    (when name
      (llm-select-response-destination :buffer name))))

(defun llm-default-conversation-buffer-name ()
  (format nil "*~:(~a~)*" *llm-backend*))

(define-command lem-yath-llm-response-conversation () ()
  "Send the next exchange to an existing or new LLM conversation."
  (let ((name
          (prompt-for-buffer
           "Existing or new LLM session: "
           :default (llm-default-conversation-buffer-name)
           :existing nil)))
    (when name
      (llm-select-response-destination :conversation name))))

(defun llm-response-target-buffer (name source)
  (let ((target (make-buffer name)))
    (when (eq target source)
      (editor-error "Choose a response buffer other than the source buffer"))
    (when (buffer-read-only-p target)
      (editor-error "Response buffer is read only: ~a" name))
    (when (llm-active-request target)
      (editor-error "Response buffer already owns an LLM request: ~a" name))
    target))

(defun llm-append-conversation-prompt (buffer prompt)
  "Append PROMPT as one user turn in BUFFER and return its end point."
  (let* ((point (buffer-end-point buffer))
         (penultimate (character-at point -2))
         (last (character-at point -1)))
    (if (and penultimate last
             (char= penultimate #\*)
             (char= last #\Space))
        (insert-string point prompt)
        (progn
          (unless (start-buffer-p point)
            (unless (char= (or (character-at point -1) #\Newline) #\Newline)
              (insert-character point #\Newline))
            (insert-character point #\Newline))
          (insert-string point (format nil "* ~a" prompt))))
    (buffer-end (buffer-point buffer))
    (buffer-end-point buffer)))

(defun llm-conversation-response-target
    (source visible-prompt request-prompt messages function)
  (declare (ignore request-prompt))
  (let* ((name *llm-response-destination-buffer-name*)
         (existing (get-buffer name))
         (target (llm-response-target-buffer name source)))
    (when (and existing (not (llm-conversation-buffer-p target)))
      (editor-error "Buffer is not an LLM conversation: ~a" name))
    (unless existing
      (change-buffer-mode target 'org-mode)
      (with-current-buffer target
        (lem-yath-llm-conversation-mode t)))
    (llm-append-conversation-prompt target visible-prompt)
    (let ((response-origin (buffer-end-point target)))
      (let ((*llm-request-source-buffer* source)
            (*llm-output-buffer-override* target)
            (*llm-response-origin* response-origin))
        ;; gptel's `g' destination changes only where the exchange is
        ;; displayed.  The provider request still uses the source buffer's
        ;; context; the resulting typed target transcript becomes reusable
        ;; history when the user continues from that session.
        (funcall function messages))
      (pop-to-buffer target))))

(defun llm-buffer-response-target (source messages function)
  (let ((target
          (llm-response-target-buffer
           *llm-response-destination-buffer-name* source)))
    (let ((*llm-request-source-buffer* source)
          (*llm-output-buffer-override* target)
          (*llm-force-inline-output-p* t)
          (*llm-response-origin* (buffer-point target))
          (*llm-response-open-function* #'llm-response-open-plain)
          (*llm-response-close-function* #'llm-response-close-plain))
      (funcall function messages))
    (pop-to-buffer target)))

(defun llm-redirect-response-text (buffer)
  (when (llm-buffer-live-p buffer)
    (string-trim '(#\Space #\Tab #\Newline #\Return)
                 (points-to-string (buffer-start-point buffer)
                                   (buffer-end-point buffer)))))

(defun llm-redirect-response-finish-function (destination buffer backend)
  (lambda (request reason)
    (declare (ignore reason))
    (let ((text (llm-redirect-response-text buffer)))
      (when (and text
                 (not (llm-request-aborted-now-p request))
                 (plusp (length text)))
        (ecase destination
          (:echo
           (message "~:(~a~) response: ~a" backend text))
          (:kill-ring
           (copy-to-clipboard-with-killring text)
           (message "~:(~a~) response copied to the kill ring" backend))))
      (when (llm-buffer-live-p buffer)
        (delete-buffer buffer)))))

(defun llm-hidden-response-target (source destination messages function)
  (let* ((name
           (format nil " *lem-yath-llm-redirect-~d*"
                   (incf *llm-redirect-buffer-sequence*)))
         (target (make-buffer name :enable-undo-p nil))
         (backend *llm-backend*))
    (let ((*llm-request-source-buffer* source)
          (*llm-output-buffer-override* target)
          (*llm-force-inline-output-p* t)
          (*llm-response-origin* (buffer-start-point target))
          (*llm-response-open-function* #'llm-response-open-plain)
          (*llm-response-close-function* #'llm-response-close-plain)
          (*llm-response-finish-function*
            (llm-redirect-response-finish-function
             destination target backend)))
      (funcall function messages))
    ;; Backends can refuse synchronously before registering a request (for
    ;; example when credentials are absent).  Do not retain an empty sink.
    (when (and (llm-buffer-live-p target) (not (llm-active-request target)))
      (delete-buffer target))))

(defun llm-dispatch-selected-response
    (source visible-prompt request-prompt messages function)
  "Route one request according to the full-menu destination selection."
  (case *llm-response-destination*
    (:buffer
     (llm-buffer-response-target source messages function))
    (:conversation
     (llm-conversation-response-target
      source visible-prompt request-prompt messages function))
    ((:echo :kill-ring)
     (llm-hidden-response-target
      source *llm-response-destination* messages function))
    (otherwise (funcall function messages))))

(setf *llm-response-routing-function* #'llm-dispatch-selected-response)

(defun llm-request-preview-object ()
  "Return a credential-free normalized preview of the next LLM request."
  (multiple-value-bind (prompt messages) (llm-current-prompt-data)
    (when (zerop (length prompt))
      (editor-error "Nothing to inspect"))
    (let* ((source (current-buffer))
           (request-prompt (llm-context-wrap-prompt source prompt))
           (request-messages
             (and messages
                  (llm-conversation-replace-last-user-content
                   messages request-prompt)))
           (*llm-conversation-messages* request-messages)
           (object
             (llm-json-object
              "format" "lem-yath-normalized-request-v1"
              "dry_run" yason:true
              "backend" (string-downcase (symbol-name *llm-backend*))
              "model" *llm-model*
              "system" *llm-system-message*
              "temperature" *llm-temperature*
              "max_tokens" *llm-max-tokens*
              "use_tools" (if *llm-use-tools* yason:true yason:false)
              "mcp_servers" (coerce *llm-mcp-server-names* 'vector)
              "response_destination" (llm-response-destination-label)
              "messages"
              (coerce (llm-messages-with-system
                       request-prompt *llm-system-message*)
                      'vector))))
      (when *llm-use-tools*
        (setf (gethash "tools" object) (llm-tool-definitions)))
      object)))

(defun llm-request-preview-json ()
  (yason:with-output-to-string* (:indent 2)
    (yason:encode (llm-request-preview-object))))

(define-command lem-yath-llm-inspect-request-json () ()
  "Inspect the next normalized LLM request without dispatching it."
  (let ((buffer
          (make-buffer *llm-request-preview-buffer-name* :enable-undo-p nil))
        (json (llm-request-preview-json)))
    (setf (buffer-read-only-p buffer) nil)
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer) json)
    (insert-character (buffer-end-point buffer) #\Newline)
    (change-buffer-mode buffer 'lem-yath-llm-request-preview-mode)
    (clear-buffer-edit-history buffer)
    (buffer-unmark buffer)
    (setf (buffer-read-only-p buffer) t)
    (buffer-start (buffer-point buffer))
    (switch-to-buffer buffer)))
