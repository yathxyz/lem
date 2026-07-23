;;;; Display-only folding for Claude Code's semantic Org blocks.

(in-package :lem-yath)

(eval-when (:load-toplevel :execute)
  (when (fboundp 'llm-claude-clear-blocks)
    (dolist (buffer (buffer-list))
      (ignore-errors (llm-claude-clear-blocks buffer)))))

(defparameter *llm-claude-tool-collapse-threshold* 8)
(defparameter *llm-claude-blocks-key* 'lem-yath-llm-claude-blocks)
(defparameter +llm-claude-fold-ellipsis+ " [...]")

(defstruct llm-claude-hidden-range
  start
  end)

(defstruct llm-claude-block
  kind
  start
  end
  hidden-range
  ellipsis)

(defun llm-claude-buffer-blocks (&optional (buffer (current-buffer)))
  (buffer-value buffer *llm-claude-blocks-key*))

(defun (setf llm-claude-buffer-blocks) (blocks
                                        &optional (buffer (current-buffer)))
  (setf (buffer-value buffer *llm-claude-blocks-key*) blocks))

(defun llm-claude-delete-hidden-range (range)
  (when range
    (ignore-errors (delete-point (llm-claude-hidden-range-start range)))
    (ignore-errors (delete-point (llm-claude-hidden-range-end range)))))

(defun llm-claude-dispose-block (block)
  (llm-claude-delete-hidden-range (llm-claude-block-hidden-range block))
  (alexandria:when-let ((ellipsis (llm-claude-block-ellipsis block)))
    (ignore-errors (delete-overlay ellipsis)))
  (dolist (point (list (llm-claude-block-start block)
                       (llm-claude-block-end block)))
    (when (and point (alive-point-p point))
      (ignore-errors (delete-point point)))))

(defun llm-claude-clear-blocks (&optional (buffer (current-buffer)))
  "Reveal BUFFER and dispose its Claude block display state."
  (dolist (block (llm-claude-buffer-blocks buffer))
    (llm-claude-dispose-block block))
  (setf (llm-claude-buffer-blocks buffer) nil)
  nil)

(defun llm-claude-range-contains-p (range point)
  (and range
       (alive-point-p (llm-claude-hidden-range-start range))
       (alive-point-p (llm-claude-hidden-range-end range))
       (eq (point-buffer point)
           (point-buffer (llm-claude-hidden-range-start range)))
       (point<= (llm-claude-hidden-range-start range) point)
       (point< point (llm-claude-hidden-range-end range))))

(defun llm-claude-hidden-block-at-point (point)
  (find-if (lambda (block)
             (llm-claude-range-contains-p
              (llm-claude-block-hidden-range block) point))
           (llm-claude-buffer-blocks (point-buffer point))))

(defun llm-claude-line-hidden-p (point)
  "Return whether POINT's logical line is hidden by a Claude block."
  (with-point ((line point))
    (line-start line)
    (not (null (llm-claude-hidden-block-at-point line)))))

(defun llm-claude-block-owner (block)
  "Return the first nonblank line in BLOCK as a temporary point."
  (with-point ((line (llm-claude-block-start block))
               (end (llm-claude-block-end block)))
    (loop
      (with-point ((scan line)
                   (line-end line))
        (line-end line-end)
        (when (point< end line-end)
          (move-point line-end end))
        (loop :while (and (point< scan line-end)
                          (member (character-at scan) '(#\Space #\Tab)))
              :do (character-offset scan 1))
        (when (point< scan line-end)
          (line-start line)
          (return (copy-point line :temporary))))
      (unless (and (point< line end) (line-offset line 1))
        (return nil)))))

(defun llm-claude-block-line-count (block)
  (alexandria:when-let ((owner (llm-claude-block-owner block)))
    (1+ (- (line-number-at-point (llm-claude-block-end block))
           (line-number-at-point owner)))))

(defun llm-claude-block-default-hidden-p (block)
  (case (llm-claude-block-kind block)
    ((:thinking :tool-result) t)
    (:tool (> (or (llm-claude-block-line-count block) 0)
              *llm-claude-tool-collapse-threshold*))
    (otherwise nil)))

(defun llm-claude-make-ellipsis (owner)
  (with-point ((end owner))
    (line-end end)
    (make-line-endings-overlay
     end end 'document-metadata-attribute
     :text +llm-claude-fold-ellipsis+
     :start-point-kind :right-inserting
     :end-point-kind :left-inserting)))

(defun llm-claude-hide-block (block)
  "Hide BLOCK's body while leaving its begin line visible."
  (unless (llm-claude-block-hidden-range block)
    (alexandria:when-let* ((owner (llm-claude-block-owner block))
                           (start (org-line-after owner)))
      (let ((end (llm-claude-block-end block)))
        (when (point< start end)
          (setf (llm-claude-block-hidden-range block)
                (make-llm-claude-hidden-range
                 :start (copy-point start :right-inserting)
                 :end (copy-point end :left-inserting))
                (llm-claude-block-ellipsis block)
                (llm-claude-make-ellipsis owner))))))
  block)

(defun llm-claude-show-block (block)
  "Reveal BLOCK without changing its transcript bytes or semantic property."
  (llm-claude-delete-hidden-range (llm-claude-block-hidden-range block))
  (setf (llm-claude-block-hidden-range block) nil)
  (alexandria:when-let ((ellipsis (llm-claude-block-ellipsis block)))
    (ignore-errors (delete-overlay ellipsis)))
  (setf (llm-claude-block-ellipsis block) nil)
  block)

(defun llm-claude-toggle-block (block)
  (if (llm-claude-block-hidden-range block)
      (llm-claude-show-block block)
      (llm-claude-hide-block block)))

(defun llm-claude-make-block (kind start end)
  (let ((block
          (make-llm-claude-block
           :kind kind
           :start (copy-point start :right-inserting)
           :end (copy-point end :left-inserting))))
    (when (llm-claude-block-default-hidden-p block)
      (llm-claude-hide-block block))
    block))

(defun llm-claude-collect-blocks (start end)
  "Build tracked block objects from semantic properties in START..END."
  (let ((blocks '()))
    (with-point ((point start)
                 (limit end))
      (loop :while (point< point limit)
            :for kind := (text-property-at
                          point *llm-cli-claude-block-property*)
            :do
               (with-point ((next point))
                 (unless (next-single-property-change
                          next *llm-cli-claude-block-property* limit)
                   (move-point next limit))
                 (when kind
                   (push (llm-claude-make-block kind point next) blocks))
                 (move-point point next))))
    (nreverse blocks)))

(defun llm-claude-add-request-blocks (request)
  (let ((buffer (llm-request-buffer request))
        (start (llm-request-response-start request))
        (end (llm-request-insertion-point request)))
    (when (and (llm-buffer-live-p buffer)
               start end (alive-point-p start) (alive-point-p end)
               (point< start end))
      (setf (llm-claude-buffer-blocks buffer)
            (nconc (llm-claude-buffer-blocks buffer)
                   (llm-claude-collect-blocks start end))))))

(defun llm-claude-request-finish (request reason)
  (when (and (eq reason :complete)
             (eq (llm-request-backend request) :claude-code)
             (llm-request-conversation-p request))
    (llm-claude-add-request-blocks request)
    (redraw-display)))

(defun llm-claude-refresh-buffer (&optional (buffer (current-buffer)))
  "Reconstruct default Claude folding from semantic properties in BUFFER."
  (llm-claude-clear-blocks buffer)
  (when (and (llm-buffer-live-p buffer)
             (llm-conversation-buffer-p buffer))
    (setf (llm-claude-buffer-blocks buffer)
          (llm-claude-collect-blocks (buffer-start-point buffer)
                                     (buffer-end-point buffer)))))

(defun llm-claude-blocks-mode-enable ()
  (let ((buffer (current-buffer)))
    (llm-claude-refresh-buffer buffer)
    (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
              'llm-claude-blocks-mode-disable)))

(defun llm-claude-blocks-mode-disable (&optional (buffer (current-buffer)))
  (llm-claude-clear-blocks buffer)
  (remove-hook (variable-value 'kill-buffer-hook :buffer buffer)
               'llm-claude-blocks-mode-disable))

(defun llm-claude-tool-result-blocks (&optional (buffer (current-buffer)))
  (remove-if-not (lambda (block)
                   (eq (llm-claude-block-kind block) :tool-result))
                 (llm-claude-buffer-blocks buffer)))

(define-command lem-yath-llm-claude-toggle-tool-results () ()
  "Toggle every Claude tool-result block, or retain Org TODO behavior."
  (let ((blocks (llm-claude-tool-result-blocks)))
    (if blocks
        (progn
          (mapc #'llm-claude-toggle-block blocks)
          (redraw-display)
          (message "Claude tool results ~:[shown~;hidden~]"
                   (not (null (llm-claude-block-hidden-range
                               (first blocks))))))
        (lem-yath-org-todo))))

(define-key *lem-yath-llm-conversation-mode-keymap*
  "C-c C-t" 'lem-yath-llm-claude-toggle-tool-results)

(setf *llm-request-finish-functions*
      (remove 'llm-claude-request-finish *llm-request-finish-functions*))
(push 'llm-claude-request-finish *llm-request-finish-functions*)

;; A source reload clears old structure instances above; restore live
;; conversation buffers from their semantic text properties immediately.
(dolist (buffer (copy-list (buffer-list)))
  (when (and (llm-buffer-live-p buffer)
             (llm-conversation-buffer-p buffer))
    (ignore-errors (llm-claude-refresh-buffer buffer))))
