;;;; Opt-in request lifecycle tracing matching the configured gptel diagnostics.
;;;; Trace records are deliberately metadata-only apart from the configured
;;;; bounded prompt preview: credentials, headers, payloads, response text, and
;;;; tool arguments/results never cross this diagnostic boundary.

(in-package :lem-yath)

(defvar *llm-request-trace-enabled* nil
  "Whether LLM request lifecycle events are recorded.")

(defvar *llm-request-trace-buffer-name* "*gptel-requests*"
  "Buffer containing opt-in LLM request lifecycle records.")

(defparameter *llm-request-trace-prompt-limit* 160)

(defvar *llm-request-trace-sequence* 0)

(defstruct llm-request-trace-state
  id
  (chunks 0)
  (characters 0))

(defvar *llm-request-trace-states* (make-hash-table :test #'eq))

(defvar *llm-request-trace-mode-keymap*
  (make-keymap :description '*llm-request-trace-mode-keymap*))

(define-major-mode lem-yath-llm-request-trace-mode nil
    (:name "LLM-Trace" :keymap *llm-request-trace-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-llm-request-trace-mode))
  (list *llm-request-trace-mode-keymap*))

(define-key *llm-request-trace-mode-keymap* "q" 'quit-active-window)

(defun llm-request-trace-timestamp ()
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time (get-universal-time))
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d"
            year month day hour minute second)))

(defun llm-request-trace-buffer ()
  (let ((buffer (or (get-buffer *llm-request-trace-buffer-name*)
                    (make-buffer *llm-request-trace-buffer-name*
                                 :enable-undo-p nil))))
    (unless (mode-active-p buffer 'lem-yath-llm-request-trace-mode)
      (change-buffer-mode buffer 'lem-yath-llm-request-trace-mode))
    buffer))

(defun llm-request-trace-log (control &rest arguments)
  (when *llm-request-trace-enabled*
    (let ((buffer (llm-request-trace-buffer)))
      (with-buffer-read-only buffer nil
        (insert-string
         (buffer-end-point buffer)
         (format nil "[~a] ~?~%"
                 (llm-request-trace-timestamp) control arguments))))))

(defun llm-request-trace-preview (prompt)
  "Return PROMPT as one bounded, non-injecting diagnostic field."
  (when (stringp prompt)
    (let* ((normalized
             (map 'string
                  (lambda (character)
                    (if (graphic-char-p character) character #\Space))
                  prompt))
           (trimmed
             (string-trim '(#\Space #\Tab #\Newline #\Return)
                          normalized)))
      (subseq trimmed 0 (min (length trimmed)
                             *llm-request-trace-prompt-limit*)))))

(defun llm-request-trace-current-preset ()
  (if (boundp '*llm-current-preset*)
      (symbol-value '*llm-current-preset*)
      "<unavailable>"))

(defun llm-request-trace-start (request &key observed-p)
  (when *llm-request-trace-enabled*
    (let ((state (make-llm-request-trace-state
                  :id (incf *llm-request-trace-sequence*))))
      (setf (gethash request *llm-request-trace-states*) state)
      (llm-request-trace-log
       "id=~d event=request-start observed=~:[no~;yes~] preset=~S model=~S backend=~S buffer=~S prompt=~S"
       (llm-request-trace-state-id state)
       observed-p
       (llm-request-trace-current-preset)
       *llm-model*
       (llm-request-backend request)
       (and (llm-buffer-live-p (llm-request-buffer request))
            (buffer-name (llm-request-buffer request)))
       (llm-request-trace-preview (llm-request-prompt request)))
      (llm-request-trace-log
       "id=~d event=backend-start backend=~S"
       (llm-request-trace-state-id state)
       (llm-request-backend request))
      state)))

(defun llm-request-trace-state (request)
  (or (gethash request *llm-request-trace-states*)
      (llm-request-trace-start request :observed-p t)))

(defun llm-request-trace-insert (request string)
  (when *llm-request-trace-enabled*
    (alexandria:when-let ((state (llm-request-trace-state request)))
      (incf (llm-request-trace-state-chunks state))
      (incf (llm-request-trace-state-characters state) (length string))
      (llm-request-trace-log
       "id=~d event=chunk index=~d characters=~d total=~d"
       (llm-request-trace-state-id state)
       (llm-request-trace-state-chunks state)
       (length string)
       (llm-request-trace-state-characters state)))))

(defun llm-request-trace-finish (request reason)
  (let ((state (gethash request *llm-request-trace-states*)))
    (when (and state *llm-request-trace-enabled*)
      (llm-request-trace-log
       "id=~d event=request-finish status=~(~a~) chunks=~d characters=~d"
       (llm-request-trace-state-id state)
       (cond
         ((eq reason :kill) :killed)
         ((llm-request-aborted-now-p request) :aborted)
         (t :complete))
       (llm-request-trace-state-chunks state)
       (llm-request-trace-state-characters state)))
    (remhash request *llm-request-trace-states*)))

(defun llm-request-trace-set-enabled (enabled-p)
  (setf *llm-request-trace-enabled* (not (null enabled-p)))
  (unless *llm-request-trace-enabled*
    (clrhash *llm-request-trace-states*))
  (when *llm-request-trace-enabled*
    (llm-request-trace-log "event=trace-enabled"))
  *llm-request-trace-enabled*)

(define-command lem-yath-llm-request-trace-toggle (argument) (:universal-nil)
  "Toggle request tracing; a positive prefix enables and zero disables it."
  (llm-request-trace-set-enabled
   (if (integerp argument)
       (plusp argument)
       (not *llm-request-trace-enabled*)))
  (message "LLM request tracing ~:[disabled~;enabled~]"
           *llm-request-trace-enabled*))

(define-command lem-yath-llm-request-trace-open () ()
  "Open the gptel-compatible request lifecycle log at its newest event."
  (let* ((buffer (llm-request-trace-buffer))
         (window (pop-to-buffer buffer)))
    ;; Unlike Emacs, Lem's `pop-to-buffer' returns the destination without
    ;; selecting it.  Explicit selection makes q/quit-window restore the
    ;; originating window as the configured diagnostic viewer expects.
    (setf (current-window) window)
    (move-point (buffer-point buffer) (buffer-end-point buffer))))

;; Reloads retain exactly one callback of each kind.
(setf *llm-request-start-functions*
      (remove 'llm-request-trace-start *llm-request-start-functions*))
(push 'llm-request-trace-start *llm-request-start-functions*)
(setf *llm-request-insert-functions*
      (remove 'llm-request-trace-insert *llm-request-insert-functions*))
(push 'llm-request-trace-insert *llm-request-insert-functions*)
(setf *llm-request-finish-functions*
      (remove 'llm-request-trace-finish *llm-request-finish-functions*))
(push 'llm-request-trace-finish *llm-request-finish-functions*)
