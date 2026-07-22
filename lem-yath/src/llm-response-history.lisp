;;;; gptel-style regeneration and response-variant history.

(in-package :lem-yath)

(defparameter *llm-response-state-key* 'lem-yath-llm-response-state)
(defparameter *llm-response-variant-limit* 16)
(defparameter *llm-response-variant-character-limit* (* 4 1024 1024))
(defparameter *llm-response-revival-limit* 64)
(defparameter *llm-response-revivals-key* 'lem-yath-llm-response-revivals)
(defparameter *llm-response-variant-diff-buffer-name*
  "*LLM Response Variant Diff*")

(defstruct llm-response-state
  backend
  model
  system-message
  temperature
  max-tokens
  use-tools
  provider-session-id
  provider-message-id
  (history '()))

(defstruct llm-response-revival
  undo-table
  undo-node-id
  start
  text
  state)

(defun llm-response-copy-state (state)
  (let ((copy (copy-llm-response-state state)))
    (setf (llm-response-state-history copy)
          (copy-list (llm-response-state-history state)))
    copy))

(defun llm-response-current-undo-identity (buffer)
  (alexandria:when-let ((node (ignore-errors
                               (buffer-undo-tree-current buffer))))
    (values (lem/buffer/internal::buffer-%undo-tree-table buffer)
            (buffer-undo-tree-node-id node))))

(defun llm-response-prune-revivals (buffer)
  (let ((table (lem/buffer/internal::buffer-%undo-tree-table buffer)))
    (setf (buffer-value buffer *llm-response-revivals-key*)
          (remove-if-not
           (lambda (revival)
             (and (eq table (llm-response-revival-undo-table revival))
                  (gethash (llm-response-revival-undo-node-id revival)
                           table)))
           (buffer-value buffer *llm-response-revivals-key*)))))

(defun llm-response-store-revival (buffer start text state)
  "Remember one semantic response span at BUFFER's current undo-tree node."
  (multiple-value-bind (undo-table undo-node-id)
      (llm-response-current-undo-identity buffer)
    (when (and undo-table undo-node-id state
               (integerp start) (stringp text) (plusp (length text)))
      (llm-response-prune-revivals buffer)
      (let* ((states
               (remove-if
                (lambda (revival)
                  (and (eq undo-table
                           (llm-response-revival-undo-table revival))
                       (= undo-node-id
                          (llm-response-revival-undo-node-id revival))))
                (buffer-value buffer *llm-response-revivals-key*)))
             (revival
               (make-llm-response-revival
                :undo-table undo-table
                :undo-node-id undo-node-id
                :start start
                :text text
                :state (llm-response-copy-state state))))
        (setf (buffer-value buffer *llm-response-revivals-key*)
              (subseq (cons revival states)
                      0 (min *llm-response-revival-limit*
                             (1+ (length states)))))))))

(defun llm-response-revival-for-current-node (buffer)
  (multiple-value-bind (undo-table undo-node-id)
      (llm-response-current-undo-identity buffer)
    (and undo-table undo-node-id
         (find-if
          (lambda (revival)
            (and (eq undo-table
                     (llm-response-revival-undo-table revival))
                 (= undo-node-id
                    (llm-response-revival-undo-node-id revival))))
          (buffer-value buffer *llm-response-revivals-key*)))))

(defun llm-response-restore-revival (revival buffer)
  "Restore response role and history properties without changing undo text."
  (with-point ((start (buffer-start-point buffer)))
    (when (move-to-position start (llm-response-revival-start revival))
      (with-point ((end start))
        (when (and (character-offset
                    end (length (llm-response-revival-text revival)))
                   (string= (points-to-string start end)
                            (llm-response-revival-text revival)))
          (put-text-property start end 'lem-yath-llm-role :assistant)
          (put-text-property
           start end *llm-response-state-key*
           (llm-response-copy-state
            (llm-response-revival-state revival)))
          (llm-response-refresh-visuals buffer)
          t)))))

(defun llm-response-apply-state-at-position
    (buffer position text state)
  "Reapply TEXT's semantic Assistant state at POSITION when bytes still match."
  (with-point ((start (buffer-start-point buffer)))
    (when (move-to-position start position)
      (with-point ((end start))
        (when (and (character-offset end (length text))
                   (string= (points-to-string start end) text))
          (put-text-property start end 'lem-yath-llm-role :assistant)
          (put-text-property start end *llm-response-state-key*
                             (llm-response-copy-state state))
          t)))))

(defun llm-response-started-at-position-p (buffer position)
  (with-point ((point (buffer-start-point buffer)))
    (and (move-to-position point position)
         (eq (text-property-at point 'lem-yath-llm-role) :assistant))))

(defun llm-response-history-move-command-p ()
  (and (this-command)
       (member (symbol-name (command-name (this-command)))
               '("UNDO" "REDO" "VI-UNDO" "VI-REDO"
                 "LEM-YATH-PROJECT-GREP-NORMAL-UNDO")
               :test #'string=)))

(defun llm-response-history-post-command ()
  (when (llm-response-history-move-command-p)
    (let ((buffer (current-buffer)))
      (llm-response-prune-revivals buffer)
      (alexandria:when-let ((revival
                             (llm-response-revival-for-current-node buffer)))
        (llm-response-restore-revival revival buffer)))))

(defun llm-response-bounded-history (responses)
  "Return the newest bounded response strings from RESPONSES."
  (let ((result nil)
        (total 0))
    (dolist (response responses (nreverse result))
      (when (and (stringp response) (plusp (length response)))
        (when (or (>= (length result) *llm-response-variant-limit*)
                  (> (+ total (length response))
                     *llm-response-variant-character-limit*))
          (return (nreverse result)))
        (incf total (length response))
        (push response result)))))

(defun llm-response-at-point-p (&optional (point (current-point)))
  (and (llm-conversation-buffer-p (point-buffer point))
       (eq (llm-role-at-point-keyword point) :assistant)))

(defun llm-response-span-bounds (&optional (point (current-point)))
  "Return temporary start and end points for the assistant span at POINT."
  (unless (llm-response-at-point-p point)
    (editor-error "Point is not in an LLM response"))
  (let ((buffer (point-buffer point)))
    (with-point ((start (llm-role-span-start point :assistant))
                 (end point)
                 (limit (buffer-end-point buffer)))
      (unless (next-single-property-change
               end 'lem-yath-llm-role limit)
        (move-point end limit))
      (values start end))))

(defun llm-response-current-state (&optional (point (current-point)))
  (or (and (llm-response-at-point-p point)
           (text-property-at point *llm-response-state-key*))
      (and (llm-response-at-point-p point)
           (make-llm-response-state
            :backend *llm-backend*
            :model *llm-model*
            :system-message *llm-system-message*
            :temperature *llm-temperature*
            :max-tokens *llm-max-tokens*
            :use-tools *llm-use-tools*))))

(defun llm-response-history-at-point-p (&optional (point (current-point)))
  (alexandria:when-let ((state (llm-response-current-state point)))
    (not (null (llm-response-state-history state)))))

(defun llm-response-state-for-request (request)
  (make-llm-response-state
   :backend (llm-request-backend request)
   :model (llm-request-model request)
   :system-message (llm-request-system-message request)
   :temperature (llm-request-temperature request)
   :max-tokens (llm-request-max-tokens request)
   :use-tools (llm-request-use-tools request)
   :provider-session-id (llm-request-provider-session-id request)
   :provider-message-id (llm-request-provider-message-id request)
   :history
   (llm-response-bounded-history (llm-request-response-history request))))

(defun llm-response-history-finish (request reason)
  "Attach captured request settings and variant history to its response span."
  (declare (ignore reason))
  (let ((start (llm-request-response-start request))
        (end (llm-request-insertion-point request))
        (buffer (llm-request-buffer request)))
    (when (and (not (llm-request-aborted-now-p request))
               (llm-buffer-live-p buffer)
               start end
               (alive-point-p start)
               (alive-point-p end)
               (eq buffer (point-buffer start))
               (eq buffer (point-buffer end))
               (point< start end))
      (let ((position (position-at-point start))
            (text (points-to-string start end))
            (state (llm-response-state-for-request request)))
        (put-text-property start end *llm-response-state-key* state)
        ;; Store after the response closer has sealed its next-prompt edit, so
        ;; this snapshot represents the complete undo-tree state.
        (send-event
         (lambda ()
           (when (and (llm-buffer-live-p buffer)
                      (llm-response-apply-state-at-position
                       buffer position text state))
             (llm-response-store-revival
              buffer position text state))))))))

(defun llm-response-refresh-visuals (buffer)
  (when (fboundp 'llm-role-refresh-static-overlays)
    (llm-role-refresh-static-overlays buffer))
  (redraw-display))

(defun llm-response-replace-variant (direction)
  "Rotate the response at point toward a previous or next variant."
  (multiple-value-bind (start end) (llm-response-span-bounds)
    (let* ((buffer (current-buffer))
           (state (llm-response-current-state start))
           (history (copy-list (llm-response-state-history state)))
           (current (points-to-string start end))
           (replacement
             (if (plusp direction) (first history) (car (last history)))))
      (unless replacement
        (editor-error "No response variants are available"))
      (when (buffer-read-only-p buffer)
        (editor-error "The response buffer is read only"))
      (let* ((new-state (copy-llm-response-state state))
             (new-history
               (if (plusp direction)
                   (append (rest history) (list current))
                   (cons current (butlast history))))
             (offset
               (min (max 0 (- (position-at-point (current-point))
                              (position-at-point start)))
                    (1- (length replacement))))
             (group (buffer-prepare-change-group buffer))
             (accepted-p nil)
             (start-position (position-at-point start))
             (insertion (copy-point start :temporary)))
        (llm-response-store-revival buffer start-position current state)
        (setf (llm-response-state-history new-state)
              (llm-response-bounded-history new-history))
        (unwind-protect
             (progn
               (delete-between-points start end)
               (insert-string insertion replacement
                              'lem-yath-llm-role :assistant
                              *llm-response-state-key* new-state)
               (buffer-accept-change-group group)
               (buffer-undo-boundary buffer)
               (llm-response-store-revival
                buffer start-position replacement new-state)
               (setf accepted-p t)
               (buffer-mark-cancel buffer)
               (move-point (buffer-point buffer) insertion)
               (character-offset (buffer-point buffer) offset))
          (unless accepted-p
            (when (buffer-change-group-active-p group)
              (ignore-errors (buffer-cancel-change-group group)))))
        (llm-response-refresh-visuals buffer)
        (message "Response variant ~:[next~;previous~]"
                 (plusp direction))))))

(define-command lem-yath-llm-response-previous () ()
  "Replace the current response with its previous variant."
  (llm-response-replace-variant 1))

(define-command lem-yath-llm-response-next () ()
  "Replace the current response with its next variant."
  (llm-response-replace-variant -1))

(defun llm-response-variants-supported-p (backend)
  "Whether BACKEND can safely regenerate from Lem's typed transcript."
  (not (member backend '(:claude-code :codex :grok) :test #'eq)))

(defun llm-response-reset-provider-history (backend buffer)
  (when (member backend '(:chatgpt-codex :grok-oauth) :test #'eq)
    (unless (and (fboundp 'llm-oauth-clear-session)
                 (llm-oauth-clear-session backend buffer))
      (editor-error "Could not reset the ~(~a~) provider history" backend))))

(define-command lem-yath-llm-response-regenerate () ()
  "Regenerate the LLM response at point and retain it as a variant."
  (multiple-value-bind (start end) (llm-response-span-bounds)
    (let* ((buffer (current-buffer))
           (state (llm-response-current-state start))
           (backend (llm-response-state-backend state))
           (old-response (points-to-string start end))
           (messages (llm-conversation-messages-to-point buffer start))
           (prompt (llm-conversation-last-user-content messages)))
      (unless (llm-response-variants-supported-p backend)
        (editor-error
         "~:(~a~) owns resumable history and cannot safely regenerate in place"
         backend))
      (unless (and prompt (plusp (length prompt)))
        (editor-error "No preceding user prompt is available"))
      (when (or (buffer-read-only-p buffer) (llm-active-request buffer))
        (editor-error "The response buffer is not available for regeneration"))
      (llm-response-reset-provider-history backend buffer)
      (let* ((position (position-at-point start))
             (offset (- (position-at-point (current-point)) position))
             (group nil)
             (accepted-p nil))
        (llm-response-store-revival buffer position old-response state)
        (setf group (buffer-prepare-change-group buffer))
        (unwind-protect
             (progn
               (move-point (buffer-point buffer) start)
               (delete-between-points start end)
               (let ((*llm-backend* backend)
                     (*llm-model* (llm-response-state-model state))
                     (*llm-system-message*
                       (llm-response-state-system-message state))
                     (*llm-temperature*
                       (llm-response-state-temperature state))
                     (*llm-max-tokens*
                       (llm-response-state-max-tokens state))
                     (*llm-use-tools* (llm-response-state-use-tools state))
                     (*llm-force-inline-output-p* t)
                     (*llm-response-open-function* #'llm-response-open-plain)
                     (*llm-response-close-function* #'llm-response-close-plain)
                     (*llm-response-history*
                       (llm-response-bounded-history
                        (cons old-response
                              (llm-response-state-history state)))))
                 (llm-dispatch-prompt-from-current-buffer prompt messages))
               (when (or (llm-active-request buffer)
                         (llm-response-started-at-position-p buffer position))
                 (buffer-accept-change-group group)
                 (buffer-undo-boundary buffer)
                 (setf accepted-p t)))
          (unless accepted-p
            (when (buffer-change-group-active-p group)
              (ignore-errors (buffer-cancel-change-group group)))
            (llm-response-apply-state-at-position
             buffer position old-response state)
            (move-to-position (buffer-point buffer)
                              (+ position
                                 (min (max 0 offset)
                                      (1- (length old-response)))))
            (llm-response-refresh-visuals buffer)))
        (unless accepted-p
          (message "Regeneration did not start; original response restored"))))))

(define-command lem-yath-llm-response-diff () ()
  "Open a unified diff against the newest previous response variant."
  (multiple-value-bind (start end) (llm-response-span-bounds)
    (let* ((state (llm-response-current-state start))
           (previous (first (llm-response-state-history state))))
      (unless previous
        (editor-error "No previous response variant is available"))
      (let* ((buffer
               (make-buffer *llm-response-variant-diff-buffer-name*
                            :enable-undo-p nil))
             (diff
               (vundo-unified-diff
                (points-to-string start end) previous
                "current-response" "previous-response")))
        (setf (buffer-read-only-p buffer) nil)
        (erase-buffer buffer)
        (insert-string (buffer-start-point buffer) diff)
        (change-buffer-mode buffer 'lem-yath-llm-rewrite-diff-mode)
        (clear-buffer-edit-history buffer)
        (buffer-unmark buffer)
        (setf (buffer-read-only-p buffer) t)
        (buffer-start (buffer-point buffer))
        (llm-rewrite-focus-buffer buffer)))))

(define-command lem-yath-llm-response-mark () ()
  "Select the complete LLM response at point."
  (multiple-value-bind (start end) (llm-response-span-bounds)
    (let ((buffer (current-buffer)))
      (buffer-mark-cancel buffer)
      (move-point (buffer-point buffer) start)
      (if (typep (current-global-mode) 'lem-vi-mode:vi-mode)
          (progn
            (lem-vi-mode/visual:vi-visual-char buffer)
            (move-point (buffer-point buffer) end)
            (character-offset (buffer-point buffer) -1))
          (progn
            (setf (buffer-mark buffer) start)
            (move-point (buffer-point buffer) end))))))

(setf *llm-request-finish-functions*
      (remove 'llm-response-history-finish *llm-request-finish-functions*))
(push 'llm-response-history-finish *llm-request-finish-functions*)

(remove-hook *post-command-hook* 'llm-response-history-post-command)
(add-hook *post-command-hook* 'llm-response-history-post-command -250)
