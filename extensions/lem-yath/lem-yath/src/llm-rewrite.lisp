;;;; Staged gptel-style region rewriting for a terminal editor.

(in-package :lem-yath)

(define-attribute llm-rewrite-waiting-attribute
  (t :background "#3d3218"))

(define-attribute llm-rewrite-ready-attribute
  (t :background "#143d2b" :bold t))

(defparameter *llm-rewrite-states-key* 'lem-yath-llm-rewrite-states)
(defparameter *llm-rewrite-preview-state-key*
  'lem-yath-llm-rewrite-preview-state)
(defparameter *llm-rewrite-preview-buffer-prefix* "*LLM Rewrite: ")
(defparameter *llm-rewrite-diff-buffer-name* "*LLM Rewrite Diff*")
(defparameter *llm-rewrite-response-limit* (* 4 1024 1024))
(defvar *llm-rewrite-sequence* 0)

(defstruct llm-rewrite-state
  id
  source-buffer
  start
  end
  original
  response
  instruction
  overlay
  preview-buffer
  backend
  model
  (generation 0 :type fixnum)
  (discarded-p nil :type boolean))

(defvar *llm-rewrite-preview-mode-keymap*
  (make-keymap :description '*llm-rewrite-preview-mode-keymap*))

(defvar *llm-rewrite-diff-mode-keymap*
  (make-keymap :description '*llm-rewrite-diff-mode-keymap*))

(define-major-mode lem-yath-llm-rewrite-preview-mode nil
    (:name "LLM-Rewrite" :keymap *llm-rewrite-preview-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-major-mode lem-yath-llm-rewrite-diff-mode lem-patch-mode:patch-mode
    (:name "LLM-Rewrite-Diff" :keymap *llm-rewrite-diff-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-llm-rewrite-preview-mode))
  (list *llm-rewrite-preview-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-llm-rewrite-diff-mode))
  (list *llm-rewrite-diff-mode-keymap*))

(declaim (ftype function vundo-unified-diff))

(defun llm-rewrite-states (&optional (buffer (current-buffer)))
  (when (llm-buffer-live-p buffer)
    (let ((states
            (remove-if-not
             (lambda (state)
               (and (not (llm-rewrite-state-discarded-p state))
                    (eq buffer (llm-rewrite-state-source-buffer state))
                    (alive-point-p (llm-rewrite-state-start state))
                    (alive-point-p (llm-rewrite-state-end state))))
             (or (buffer-value buffer *llm-rewrite-states-key*) '()))))
      (setf (buffer-value buffer *llm-rewrite-states-key*) states)
      states)))

(defun llm-rewrite-state-at-point
    (&optional (buffer (current-buffer)) (point (buffer-point buffer)))
  (or (buffer-value buffer *llm-rewrite-preview-state-key*)
      (find-if
       (lambda (state)
         (and (eq buffer (llm-rewrite-state-source-buffer state))
              (point<= (llm-rewrite-state-start state)
                       point
                       (llm-rewrite-state-end state))))
       (llm-rewrite-states buffer))))

(defun llm-rewrite-delete-preview (state)
  (alexandria:when-let ((buffer (llm-rewrite-state-preview-buffer state)))
    (setf (llm-rewrite-state-preview-buffer state) nil)
    (when (llm-buffer-live-p buffer)
      (setf (buffer-value buffer *llm-rewrite-preview-state-key*) nil)
      (ignore-errors (delete-buffer buffer)))))

(defun llm-rewrite-remove-state (state)
  (let ((source (llm-rewrite-state-source-buffer state)))
    (unless (llm-rewrite-state-discarded-p state)
      (setf (llm-rewrite-state-discarded-p state) t)
      (alexandria:when-let ((overlay (llm-rewrite-state-overlay state)))
        (setf (llm-rewrite-state-overlay state) nil)
        (ignore-errors (delete-overlay overlay)))
      (dolist (point (list (llm-rewrite-state-start state)
                           (llm-rewrite-state-end state)))
        (when (and point (alive-point-p point))
          (ignore-errors (delete-point point))))
      (when (llm-buffer-live-p source)
        (setf (buffer-value source *llm-rewrite-states-key*)
              (delete state
                      (buffer-value source *llm-rewrite-states-key*)
                      :test #'eq)))
      (llm-rewrite-delete-preview state)))
  nil)

(defun llm-rewrite-source-text (state)
  (let ((source (llm-rewrite-state-source-buffer state)))
    (when (and (llm-buffer-live-p source)
               (alive-point-p (llm-rewrite-state-start state))
               (alive-point-p (llm-rewrite-state-end state)))
      (points-to-string (llm-rewrite-state-start state)
                        (llm-rewrite-state-end state)))))

(defun llm-rewrite-overlap-p (buffer start end)
  (some
   (lambda (state)
     (and (point< start (llm-rewrite-state-end state))
          (point< (llm-rewrite-state-start state) end)))
   (llm-rewrite-states buffer)))

(defun llm-rewrite-programming-buffer-p (buffer)
  (and (fboundp 'buffer-list-mode-derived-p)
       (buffer-list-mode-derived-p
        (buffer-major-mode buffer) 'lem/language-mode:language-mode)
       (not (member (buffer-major-mode buffer)
                    '(org-mode lem-markdown-mode:markdown-mode)
                    :test #'eq))))

(defun llm-rewrite-directive (buffer)
  (let ((language
          (string-downcase
           (or (ignore-errors (mode-name (buffer-major-mode buffer)))
               (symbol-name (buffer-major-mode buffer))))))
    (if (llm-rewrite-programming-buffer-p buffer)
        (format nil
                (concatenate
                 'string
                 "You are a ~a programmer. Follow my instructions and refactor "
                 "the ~a code I provide. Generate ONLY the complete replacement "
                 "code, without explanation or markdown fences. Do not abbreviate, "
                 "report progress, or ask for clarification.")
                language language)
        (format nil
                (concatenate
                 'string
                 "You are a ~a editor. Follow my instructions and improve or "
                 "rewrite the text I provide. Generate ONLY the replacement text, "
                 "without explanation or markdown fences. Do not report progress.")
                language))))

(defun llm-rewrite-request-prompt (state candidate instruction)
  (let* ((source (llm-rewrite-state-source-buffer state))
         (rendered
           (with-current-buffer source
             (llm-render-user-text-for-buffer candidate source)))
         (prompt
           (format nil
                   "~a~2%What is the required change? I will generate only the final replacement.~2%~a"
                   rendered instruction)))
    (llm-context-wrap-prompt source prompt)))

(defun llm-rewrite-preview-name (state)
  (let* ((source-name (buffer-name (llm-rewrite-state-source-buffer state)))
         (usable (subseq source-name 0 (min (length source-name) 80))))
    (format nil "~a~a #~d*"
            *llm-rewrite-preview-buffer-prefix* usable
            (llm-rewrite-state-id state))))

(defun llm-rewrite-preview-text (state)
  (format nil
          (concatenate
           'string
           "LLM rewrite ready~%"
           "Source: ~a~%"
           "Backend: ~(~a~) / ~a~%"
           "Instruction: ~a~2%"
           "A accept   K reject   r iterate   D diff   M merge   q keep pending~2%"
           "--- Proposed replacement ---~%~a")
          (buffer-name (llm-rewrite-state-source-buffer state))
          (llm-rewrite-state-backend state)
          (llm-rewrite-state-model state)
          (llm-rewrite-state-instruction state)
          (llm-rewrite-state-response state)))

(defun llm-rewrite-focus-buffer (buffer)
  "Display BUFFER and make its window receive subsequent key events."
  (when (llm-buffer-live-p buffer)
    (setf (current-window) (pop-to-buffer buffer))))

(defun llm-rewrite-show-preview (state)
  (when (and (not (llm-rewrite-state-discarded-p state))
             (llm-buffer-live-p (llm-rewrite-state-source-buffer state))
             (stringp (llm-rewrite-state-response state)))
    (let ((buffer
            (or (and (llm-buffer-live-p
                      (llm-rewrite-state-preview-buffer state))
                     (llm-rewrite-state-preview-buffer state))
                (make-buffer (llm-rewrite-preview-name state)
                             :enable-undo-p nil))))
      (setf (llm-rewrite-state-preview-buffer state) buffer
            (buffer-value buffer *llm-rewrite-preview-state-key*) state
            (buffer-read-only-p buffer) nil)
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer)
                     (llm-rewrite-preview-text state))
      (insert-character (buffer-end-point buffer) #\Newline)
      (change-buffer-mode buffer 'lem-yath-llm-rewrite-preview-mode)
      (clear-buffer-edit-history buffer)
      (buffer-unmark buffer)
      (setf (buffer-read-only-p buffer) t)
      (buffer-start (buffer-point buffer))
      (llm-rewrite-focus-buffer buffer)
      (redraw-display))))

(defun llm-rewrite-set-overlay-ready (state ready-p)
  (alexandria:when-let ((overlay (llm-rewrite-state-overlay state)))
    (set-overlay-attribute
     (ensure-attribute
      (if ready-p
          'llm-rewrite-ready-attribute
          'llm-rewrite-waiting-attribute))
     overlay))
  (redraw-display))

(defun llm-rewrite-normalize-response (state text)
  (when (> (length text) *llm-rewrite-response-limit*)
    (editor-error "LLM rewrite exceeded ~d characters"
                  *llm-rewrite-response-limit*))
  (if (and (plusp (length (llm-rewrite-state-original state)))
           (char= (char (llm-rewrite-state-original state)
                        (1- (length (llm-rewrite-state-original state))))
                  #\Newline)
           (or (zerop (length text))
               (not (char= (char text (1- (length text))) #\Newline))))
      (concatenate 'string text (string #\Newline))
      text))

(defun llm-rewrite-response-finish-function (state sink generation)
  (lambda (request reason)
    (declare (ignore reason))
    (let ((text
            (and (llm-buffer-live-p sink)
                 (points-to-string (buffer-start-point sink)
                                   (buffer-end-point sink)))))
      (when (llm-buffer-live-p sink)
        (delete-buffer sink))
      (when (and (not (llm-rewrite-state-discarded-p state))
                 (= generation (llm-rewrite-state-generation state)))
        (cond
          ((or (llm-request-aborted-now-p request)
               (null text)
               (zerop (length text)))
           (if (llm-rewrite-state-response state)
               (llm-rewrite-set-overlay-ready state t)
               (llm-rewrite-remove-state state)))
          (t
           (handler-case
               (progn
                 (setf (llm-rewrite-state-response state)
                       (llm-rewrite-normalize-response state text))
                 (llm-rewrite-set-overlay-ready state t)
                 (llm-rewrite-show-preview state)
                 (message
                  "LLM rewrite ready: A accept, K reject, r iterate, D diff"))
             (error (condition)
               (if (llm-rewrite-state-response state)
                   (llm-rewrite-set-overlay-ready state t)
                   (llm-rewrite-remove-state state))
               (message "Could not stage LLM rewrite: ~a" condition)))))))))

(defun llm-rewrite-dispatch (state candidate instruction)
  (let* ((source (llm-rewrite-state-source-buffer state))
         (request-prompt
           (llm-rewrite-request-prompt state candidate instruction))
         (generation (incf (llm-rewrite-state-generation state)))
         (sink
           (make-buffer
            (format nil " *lem-yath-llm-rewrite-~d*"
                    (incf *llm-rewrite-sequence*))
            :enable-undo-p nil)))
    (setf (llm-rewrite-state-instruction state) instruction
          (llm-rewrite-state-backend state) *llm-backend*
          (llm-rewrite-state-model state) *llm-model*)
    (llm-rewrite-set-overlay-ready state nil)
    (handler-case
        (let ((*llm-request-source-buffer* source)
              (*llm-output-buffer-override* sink)
              (*llm-force-inline-output-p* t)
              (*llm-response-origin* (buffer-start-point sink))
              (*llm-response-open-function* #'llm-response-open-plain)
              (*llm-response-close-function* #'llm-response-close-plain)
              (*llm-response-finish-function*
                (llm-rewrite-response-finish-function
                 state sink generation))
              (*llm-visible-prompt* (format nil "Rewrite: ~a" instruction))
              (*llm-conversation-messages* nil)
              (*llm-system-message* (llm-rewrite-directive source)))
          (llm-backend-stream *llm-backend* request-prompt))
      (error (condition)
        (when (llm-buffer-live-p sink)
          (delete-buffer sink))
        (if (llm-rewrite-state-response state)
            (llm-rewrite-set-overlay-ready state t)
            (llm-rewrite-remove-state state))
        (editor-error "Could not start LLM rewrite: ~a" condition)))
    ;; A backend can refuse before registering a request.  Preserve an older
    ;; proposal during iteration, but do not leave an empty initial rewrite.
    (when (and (llm-buffer-live-p sink) (not (llm-active-request sink)))
      (delete-buffer sink)
      (if (llm-rewrite-state-response state)
          (llm-rewrite-set-overlay-ready state t)
          (llm-rewrite-remove-state state)))))

(defun llm-rewrite-create-from-region (instruction)
  (multiple-value-bind (start end region-p) (llm-source-bounds)
    (unless region-p
      (editor-error "Select a region to rewrite"))
    (when (point= start end)
      (editor-error "The rewrite region is empty"))
    (let ((source (current-buffer)))
      (when (buffer-read-only-p source)
        (editor-error "The rewrite source is read only"))
      (when (or (llm-active-request source)
                (llm-forward-request-buffer source))
        (editor-error "The source buffer already owns an LLM request"))
      (when (llm-rewrite-overlap-p source start end)
        (editor-error "The selected region overlaps a pending LLM rewrite"))
      (let* ((original (points-to-string start end))
             (state
               (make-llm-rewrite-state
                :id (incf *llm-rewrite-sequence*)
                :source-buffer source
                :start (copy-point start :right-inserting)
                :end (copy-point end :left-inserting)
                :original original
                :instruction instruction
                :backend *llm-backend*
                :model *llm-model*))
             (overlay
               (make-overlay start end 'llm-rewrite-waiting-attribute)))
        (setf (llm-rewrite-state-overlay state) overlay)
        (push state (buffer-value source *llm-rewrite-states-key*))
        (when (lem-vi-mode/visual:visual-p)
          (lem-vi-mode/visual:vi-visual-end source))
        (buffer-mark-cancel source)
        (llm-rewrite-dispatch state original instruction)
        state))))

(defun llm-rewrite-required-state ()
  (or (llm-rewrite-state-at-point)
      (editor-error "Point is not on a pending LLM rewrite")))

(defun llm-rewrite-ready-state ()
  (let ((state (llm-rewrite-required-state)))
    (unless (stringp (llm-rewrite-state-response state))
      (editor-error "The LLM rewrite is still running"))
    state))

(defun llm-rewrite-return-to-source (state)
  (let ((source (llm-rewrite-state-source-buffer state)))
    (llm-rewrite-focus-buffer source)))

(defun llm-rewrite-replace-source (state replacement)
  (let* ((source (llm-rewrite-state-source-buffer state))
         (start (llm-rewrite-state-start state))
         (end (llm-rewrite-state-end state)))
    (unless (and (llm-buffer-live-p source)
                 (alive-point-p start)
                 (alive-point-p end))
      (editor-error "The LLM rewrite source is no longer available"))
    (when (buffer-read-only-p source)
      (editor-error "The LLM rewrite source is read only"))
    (let ((group (buffer-prepare-change-group source))
          (accepted-p nil)
          (insertion (copy-point start :temporary)))
      (unwind-protect
           (progn
             (delete-between-points start end)
             (insert-string insertion replacement)
             (buffer-accept-change-group group)
             (buffer-undo-boundary source)
             (setf accepted-p t)
             (buffer-mark-cancel source)
             (move-point (buffer-point source) insertion))
        (unless accepted-p
          (when (buffer-change-group-active-p group)
            (ignore-errors (buffer-cancel-change-group group))))))
    (llm-rewrite-return-to-source state)
    (llm-rewrite-remove-state state)
    (jump-feedback-pulse-line (buffer-point source))))

(define-command lem-yath-llm-rewrite-accept () ()
  "Replace the tracked source region with its pending LLM rewrite."
  (let ((state (llm-rewrite-ready-state)))
    (llm-rewrite-replace-source state (llm-rewrite-state-response state))
    (message "Accepted LLM rewrite")))

(define-command lem-yath-llm-rewrite-reject () ()
  "Discard the pending LLM rewrite without changing source text."
  (let ((state (llm-rewrite-ready-state)))
    (llm-rewrite-return-to-source state)
    (llm-rewrite-remove-state state)
    (message "Cleared pending LLM rewrite")))

(define-command lem-yath-llm-rewrite-iterate () ()
  "Ask the model to revise the pending replacement."
  (let* ((state (llm-rewrite-ready-state))
         (instruction (prompt-for-string "Rewrite instruction: ")))
    (when (plusp (length instruction))
      (llm-rewrite-dispatch
       state (llm-rewrite-state-response state) instruction))))

(defun llm-rewrite-merge-text (state)
  (let ((current (llm-rewrite-source-text state))
        (response (llm-rewrite-state-response state)))
    (format nil
            "<<<<<<< original~%~a~:[~%~;~]=======~%~a~:[~%~;~]>>>>>>> ~(~a~)~%"
            current
            (and (plusp (length current))
                 (char= (char current (1- (length current))) #\Newline))
            response
            (and (plusp (length response))
                 (char= (char response (1- (length response))) #\Newline))
            (llm-rewrite-state-backend state))))

(define-command lem-yath-llm-rewrite-merge () ()
  "Replace the source region with simple conflict markers for manual merging."
  (let ((state (llm-rewrite-ready-state)))
    (llm-rewrite-replace-source state (llm-rewrite-merge-text state))
    (message "Inserted LLM rewrite as a merge conflict")))

(define-command lem-yath-llm-rewrite-diff () ()
  "Open a bounded unified diff for the pending replacement."
  (let* ((state (llm-rewrite-ready-state))
         (source (llm-rewrite-state-source-buffer state))
         (buffer
           (make-buffer *llm-rewrite-diff-buffer-name* :enable-undo-p nil))
         (diff
           (vundo-unified-diff
            (llm-rewrite-source-text state)
            (llm-rewrite-state-response state)
            (format nil "current:~a" (buffer-name source))
            (format nil "rewrite:~a" (buffer-name source)))))
    (setf (buffer-read-only-p buffer) nil)
    (erase-buffer buffer)
    (insert-string (buffer-start-point buffer) diff)
    (change-buffer-mode buffer 'lem-yath-llm-rewrite-diff-mode)
    (clear-buffer-edit-history buffer)
    (buffer-unmark buffer)
    (setf (buffer-read-only-p buffer) t)
    (buffer-start (buffer-point buffer))
    (llm-rewrite-focus-buffer buffer)))

(define-command lem-yath-llm-rewrite-preview-quit () ()
  "Close the rewrite preview while retaining the pending proposal."
  (let ((state (llm-rewrite-required-state)))
    (llm-rewrite-return-to-source state)
    (llm-rewrite-delete-preview state)
    (message "LLM rewrite remains pending at the highlighted region")))

(defun llm-rewrite-actions-keymap ()
  (let ((keymap (make-keymap :description "Pending LLM rewrite")))
    (setf (lem/transient::keymap-show-p keymap) t)
    (dolist
        (entry '(("A" "accept replacement")
                 ("K" "reject replacement")
                 ("r" "iterate")
                 ("D" "unified diff")
                 ("M" "insert merge conflict")
                 ("q" "keep pending")))
      (define-key keymap (first entry) 'nop-command)
      (setf (lem-core::prefix-description
             (lem-core::keymap-find
              keymap (lem-core::parse-keyspec (first entry))))
            (second entry)))
    keymap))

(defun llm-rewrite-action-command (key)
  (cdr (assoc key
              '(("A" . lem-yath-llm-rewrite-accept)
                ("K" . lem-yath-llm-rewrite-reject)
                ("r" . lem-yath-llm-rewrite-iterate)
                ("D" . lem-yath-llm-rewrite-diff)
                ("M" . lem-yath-llm-rewrite-merge))
              :test #'string=)))

(defun llm-rewrite-open-actions ()
  (llm-rewrite-ready-state)
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (llm-rewrite-actions-keymap)))
         (redraw-display)
         (let* ((key (read-key))
                (name (lem-core::keyseq-to-string (list key))))
           (lem/transient::hide-transient)
           (unless (or (string= name "q") (string= name "Escape"))
             (alexandria:if-let ((command (llm-rewrite-action-command name)))
               (call-command command nil)
               (message "No rewrite action is bound to ~a" name)))))
    (lem/transient::hide-transient)))

(define-command lem-yath-llm-rewrite () ()
  "Start a gptel-style region rewrite or act on the pending rewrite at point."
  (if (buffer-mark-p (current-buffer))
      (let ((instruction (prompt-for-string "Rewrite instruction: ")))
        (when (plusp (length instruction))
          (llm-rewrite-create-from-region instruction)))
      (llm-rewrite-open-actions)))

(defun llm-rewrite-kill-buffer-hook (buffer)
  (dolist (state (copy-list (llm-rewrite-states buffer)))
    (llm-rewrite-remove-state state)))

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'llm-rewrite-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'llm-rewrite-kill-buffer-hook)

(define-key *llm-rewrite-preview-mode-keymap* "A"
  'lem-yath-llm-rewrite-accept)
(define-key *llm-rewrite-preview-mode-keymap* "K"
  'lem-yath-llm-rewrite-reject)
(define-key *llm-rewrite-preview-mode-keymap* "r"
  'lem-yath-llm-rewrite-iterate)
(define-key *llm-rewrite-preview-mode-keymap* "D"
  'lem-yath-llm-rewrite-diff)
(define-key *llm-rewrite-preview-mode-keymap* "M"
  'lem-yath-llm-rewrite-merge)
(define-key *llm-rewrite-preview-mode-keymap* "q"
  'lem-yath-llm-rewrite-preview-quit)

(define-key *llm-rewrite-diff-mode-keymap* "q" 'quit-active-window)
(define-key *llm-rewrite-diff-mode-keymap* "Z Z" 'quit-active-window)
(define-key *llm-rewrite-diff-mode-keymap* "Z Q" 'quit-active-window)
