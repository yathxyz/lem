;;;; Terminal-native equivalents of the active gptel role overlays, header
;;;; indicator, and synthetic streaming cursor.  Everything here is display
;;;; state: transcript bytes and role properties remain the provider boundary.

(in-package :lem-yath)

(define-attribute llm-role-user-badge-attribute
  (t :foreground "#6b4f00" :background "#f4d58d" :bold t))

(define-attribute llm-role-assistant-badge-attribute
  (t :foreground "#0f3d3e" :background "#9dd9d2" :bold t))

;; The Emacs face uses a nearly white assistant background.  A dark teal keeps
;; the same visual grouping without erasing syntax colors in a dark terminal.
(define-attribute llm-role-assistant-span-attribute
  (t :background "#16383a"))

(define-attribute llm-role-header-label-attribute
  (t :foreground "#989898"))

(define-attribute llm-stream-cursor-attribute
  (t :foreground "#0d0e1c" :background "#9dd9d2" :bold t))

(defvar *llm-role-visuals-enabled* t
  "Whether conversation role badges and assistant span tint are displayed.")

(defparameter *llm-role-visual-overlays-key*
  'lem-yath-llm-role-visual-overlays)

(defstruct llm-visual-state
  assistant-overlay
  cursor-overlay)

(defun llm-role-at-point-keyword (point &optional offset)
  (if (eq (if offset
              (text-property-at point 'lem-yath-llm-role offset)
              (text-property-at point 'lem-yath-llm-role))
          :assistant)
      :assistant
      :user))

(defun llm-role-whitespace-p (character)
  (member character '(#\Space #\Tab #\Newline #\Return)))

(defun llm-role-static-overlays (buffer)
  (buffer-value buffer *llm-role-visual-overlays-key*))

(defun (setf llm-role-static-overlays) (value buffer)
  (setf (buffer-value buffer *llm-role-visual-overlays-key*) value))

(defun llm-role-clear-static-overlays (buffer)
  (dolist (overlay (llm-role-static-overlays buffer))
    (delete-overlay overlay))
  (setf (llm-role-static-overlays buffer) nil))

(defun llm-role-track-static-overlay (buffer overlay)
  (overlay-put overlay :lem-yath-llm-role-visual :assistant)
  (push overlay (llm-role-static-overlays buffer))
  overlay)

(defun llm-role-refresh-static-overlays (buffer)
  "Rebuild assistant tint overlays from BUFFER's semantic role properties."
  (llm-role-clear-static-overlays buffer)
  (when (and *llm-role-visuals-enabled*
             (llm-buffer-live-p buffer)
             (llm-conversation-buffer-p buffer))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer))
                   (limit (buffer-end-point buffer)))
        (loop :while (point< point limit)
              :for role := (llm-role-at-point-keyword point)
              :do
                 (with-point ((next point))
                   (unless (next-single-property-change
                            next 'lem-yath-llm-role limit)
                     (move-point next limit))
                   (when (eq role :assistant)
                     (llm-role-track-static-overlay
                      buffer
                      (make-overlay
                       point next 'llm-role-assistant-span-attribute
                       :start-point-kind :right-inserting
                       :end-point-kind :right-inserting)))
                   (move-point point next)))))))

(defun llm-role-span-start (point role)
  "Return the semantic ROLE span boundary containing the character at POINT."
  (with-point ((probe point)
               (start (buffer-start-point (point-buffer point))))
    ;; previous-single-property-change examines the character before PROBE.
    ;; Advancing once therefore starts within the character at POINT.
    (character-offset probe 1)
    (loop
      (unless (previous-single-property-change
               probe 'lem-yath-llm-role start)
        (move-point probe start)
        (return probe))
      (if (or (point= probe start)
              (not (eq role (llm-role-at-point-keyword probe -1))))
          (return probe)))))

(defun llm-role-span-content-start (point)
  "Return the first non-whitespace point in POINT's semantic role span."
  (let ((role (llm-role-at-point-keyword point)))
    (with-point ((scan (llm-role-span-start point role)))
      (loop :for character := (character-at scan)
            :while (and character
                        (eq role (llm-role-at-point-keyword scan))
                        (llm-role-whitespace-p character))
            :do (character-offset scan 1))
      (when (and (character-at scan)
                 (eq role (llm-role-at-point-keyword scan)))
        scan))))

(defun llm-role-line-first-content (point)
  (with-point ((scan point)
               (end point))
    (line-start scan)
    (line-end end)
    (loop :for character := (character-at scan)
          :while (and (point< scan end)
                      character
                      (llm-role-whitespace-p character))
          :do (character-offset scan 1))
    (and (point< scan end) scan)))

(defun llm-role-gutter-content (buffer point)
  "Return a fixed-width role badge at the first content line of each span."
  (when (and *llm-role-visuals-enabled*
             (llm-conversation-buffer-p buffer)
             (with-point ((start (buffer-start-point buffer))
                          (end (buffer-end-point buffer)))
               (point< start end)))
    (let ((label "            ")
          (attribute nil))
      (alexandria:when-let ((content (llm-role-line-first-content point)))
        (alexandria:when-let ((span-content
                               (llm-role-span-content-start content)))
          (when (point= content span-content)
            (if (eq (llm-role-at-point-keyword content) :assistant)
                (setf label "[Assistant] "
                      attribute 'llm-role-assistant-badge-attribute)
                (setf label "[User]      "
                      attribute 'llm-role-user-badge-attribute)))))
      (lem/buffer/line:make-content
       :string label
       :attributes (when attribute `((0 ,(length label) ,attribute)))))))

(defmethod compute-left-display-area-content
    ((mode lem-yath-llm-conversation-mode) buffer point)
  (declare (ignore mode))
  (join-left-display-content
   (call-next-method)
   (llm-role-gutter-content buffer point)))

(defun llm-role-modeline-role (window)
  (let ((buffer (window-buffer window)))
    (if (and *llm-role-visuals-enabled*
             (llm-conversation-buffer-p buffer))
        (if (eq (llm-role-at-point-keyword (window-point window)) :assistant)
            (values " Assistant " 'llm-role-assistant-badge-attribute)
            (values " User " 'llm-role-user-badge-attribute))
        "")))

(defun llm-role-modeline-label (window)
  (if (and *llm-role-visuals-enabled*
           (llm-conversation-buffer-p (window-buffer window)))
      (values " Editing" 'llm-role-header-label-attribute)
      ""))

(defun llm-visual-delete-overlay (overlay)
  (when overlay
    (delete-overlay overlay)))

(defun llm-visual-delete-cursor (state)
  (when state
    (llm-visual-delete-overlay (llm-visual-state-cursor-overlay state))
    (setf (llm-visual-state-cursor-overlay state) nil)))

(defun llm-visual-make-cursor (point)
  (with-point ((end point))
    (line-end end)
    (let ((overlay
            (if (point= point end)
                (make-line-endings-overlay
                 point point 'llm-stream-cursor-attribute :text "▌")
                (progn
                  (move-point end point)
                  (character-offset end 1)
                  (make-overlay point end 'llm-stream-cursor-attribute)))))
      (overlay-put overlay :lem-yath-llm-stream-cursor t)
      overlay)))

(defun llm-visual-update-cursor (request)
  (alexandria:when-let* ((state (llm-request-visual-state request))
                         (point (llm-request-insertion-point request)))
    (llm-visual-delete-cursor state)
    (when (and (alive-point-p point)
               (llm-buffer-live-p (llm-request-buffer request)))
      (setf (llm-visual-state-cursor-overlay state)
            (llm-visual-make-cursor point)))))

(defun llm-visual-make-active-assistant-overlay (request)
  (alexandria:when-let ((point (llm-request-insertion-point request)))
    (when (and *llm-role-visuals-enabled* (alive-point-p point))
      (let ((overlay
              (make-overlay
               point point 'llm-role-assistant-span-attribute
               :start-point-kind :right-inserting
               :end-point-kind :left-inserting)))
        (overlay-put overlay :lem-yath-llm-role-visual :active-assistant)
        overlay))))

(defun llm-visual-stop-request (request &key refresh-p)
  (alexandria:when-let ((state (llm-request-visual-state request)))
    (llm-visual-delete-cursor state)
    (llm-visual-delete-overlay
     (llm-visual-state-assistant-overlay state))
    (setf (llm-request-visual-state request) nil))
  (when (and refresh-p
             (llm-buffer-live-p (llm-request-buffer request)))
    (llm-role-refresh-static-overlays (llm-request-buffer request))))

(defun llm-visual-request-start (request)
  (when (llm-request-conversation-p request)
    (llm-visual-stop-request request)
    (let ((buffer (llm-request-buffer request)))
      (when (and (llm-buffer-live-p buffer)
                 (llm-conversation-buffer-p buffer))
        (llm-role-refresh-static-overlays buffer)
        (let ((state
                (make-llm-visual-state
                 :assistant-overlay
                 (llm-visual-make-active-assistant-overlay request))))
          (setf (llm-request-visual-state request) state)
          (llm-visual-update-cursor request))))))

(defun llm-visual-request-insert (request string)
  (declare (ignore string))
  (when (llm-request-conversation-p request)
    (llm-visual-update-cursor request)))

(defun llm-visual-request-finish (request reason)
  (llm-visual-stop-request
   request :refresh-p (and (not (eq reason :kill))
                           *llm-role-visuals-enabled*)))

(defun llm-role-visuals-mode-enable ()
  (let ((buffer (current-buffer)))
    (llm-role-refresh-static-overlays buffer)
    (when (fboundp 'llm-claude-blocks-mode-enable)
      (funcall 'llm-claude-blocks-mode-enable))
    (alexandria:when-let ((request (llm-active-request buffer)))
      (llm-visual-request-start request))))

(defun llm-role-visuals-mode-disable ()
  (let ((buffer (current-buffer)))
    (when (fboundp 'llm-claude-blocks-mode-disable)
      (funcall 'llm-claude-blocks-mode-disable))
    (alexandria:when-let ((request (llm-active-request buffer)))
      (llm-visual-stop-request request))
    (llm-role-clear-static-overlays buffer)))

(defun llm-role-sync-buffer (buffer)
  (when (llm-buffer-live-p buffer)
    (llm-role-clear-static-overlays buffer)
    (when (llm-conversation-buffer-p buffer)
      (when *llm-role-visuals-enabled*
        (llm-role-refresh-static-overlays buffer))
      (alexandria:when-let ((request (llm-active-request buffer)))
        (llm-visual-request-start request)))))

(defun llm-role-sync-all-buffers ()
  (dolist (buffer (copy-list (buffer-list)))
    (llm-role-sync-buffer buffer))
  (redraw-display))

(define-command lem-yath-llm-role-visuals-toggle () ()
  "Toggle gptel-style role badges and assistant span highlighting."
  (setf *llm-role-visuals-enabled* (not *llm-role-visuals-enabled*))
  (llm-role-sync-all-buffers)
  (message "LLM role visuals ~:[disabled~;enabled~]"
           *llm-role-visuals-enabled*))

;; Keep reload ownership singular and preserve the Emacs header's two faces as
;; adjacent modeline elements in Lem's one-row terminal UI.
(modeline-remove-status-list 'llm-role-modeline-label)
(modeline-remove-status-list 'llm-role-modeline-role)
(modeline-add-status-list 'llm-role-modeline-role)
(modeline-add-status-list 'llm-role-modeline-label)

(setf *llm-request-start-functions*
      (remove 'llm-visual-request-start *llm-request-start-functions*))
(push 'llm-visual-request-start *llm-request-start-functions*)
(setf *llm-request-insert-functions*
      (remove 'llm-visual-request-insert *llm-request-insert-functions*))
(push 'llm-visual-request-insert *llm-request-insert-functions*)
(setf *llm-request-finish-functions*
      (remove 'llm-visual-request-finish *llm-request-finish-functions*))
(push 'llm-visual-request-finish *llm-request-finish-functions*)

(llm-role-sync-all-buffers)
