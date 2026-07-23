;;;; Non-destructive Org subtree folding over Lem's hidden-line primitive.

(in-package :lem-yath)

(eval-when (:load-toplevel :execute)
  (when (fboundp 'org-clear-folds)
    (dolist (buffer (buffer-list))
      (ignore-errors (org-clear-folds buffer)))))

(defparameter +org-fold-ellipsis+ " [...]")

(defstruct org-hidden-range
  start
  end)

(defstruct org-fold
  owner
  state
  ranges
  ellipses
  global-p)

(defvar *org-preserve-folds* nil)

(defun org-buffer-folds (&optional (buffer (current-buffer)))
  (buffer-value buffer 'lem-yath-org-folds))

(defun (setf org-buffer-folds) (folds &optional (buffer (current-buffer)))
  (setf (buffer-value buffer 'lem-yath-org-folds) folds))

(defun org-global-cycle-state (&optional (buffer (current-buffer)))
  (buffer-value buffer 'lem-yath-org-global-cycle-state))

(defun (setf org-global-cycle-state) (state &optional (buffer (current-buffer)))
  (setf (buffer-value buffer 'lem-yath-org-global-cycle-state) state))

(defun org-delete-hidden-range (range)
  (ignore-errors (delete-point (org-hidden-range-start range)))
  (ignore-errors (delete-point (org-hidden-range-end range))))

(defun org-delete-fold (fold)
  (dolist (range (org-fold-ranges fold))
    (org-delete-hidden-range range))
  (dolist (overlay (org-fold-ellipses fold))
    (ignore-errors (delete-overlay overlay)))
  (ignore-errors (delete-point (org-fold-owner fold))))

(defun org-clear-folds (&optional (buffer (current-buffer)))
  "Reveal BUFFER and dispose every tracked fold marker and ellipsis."
  (dolist (fold (org-buffer-folds buffer))
    (org-delete-fold fold))
  (setf (org-buffer-folds buffer) nil
        (org-global-cycle-state buffer) nil)
  nil)

(defun org-range-hidden-p (range point)
  (and (eq (point-buffer point)
           (point-buffer (org-hidden-range-start range)))
       (point<= (org-hidden-range-start range) point)
       (point< point (org-hidden-range-end range))))

(defun org-hidden-range-at-point (point)
  (loop :for fold :in (org-buffer-folds (point-buffer point))
        :thereis (find-if (lambda (range)
                            (org-range-hidden-p range point))
                          (org-fold-ranges fold))))

(defun org-line-hidden-p (point)
  "Buffer-local predicate consumed by Lem's display and vertical movement."
  (with-point ((line point))
    (line-start line)
    (or (not (null (org-hidden-range-at-point line)))
        (and (fboundp 'llm-claude-line-hidden-p)
             (llm-claude-line-hidden-p line)))))

(defun org-make-hidden-range (start end)
  (when (point< start end)
    (make-org-hidden-range
     :start (copy-point start :right-inserting)
     :end (copy-point end :left-inserting))))

(defun org-make-ellipsis (heading)
  (with-point ((end heading))
    (line-end end)
    (make-line-endings-overlay
     end end 'document-metadata-attribute
     :text +org-fold-ellipsis+
     :start-point-kind :right-inserting
     :end-point-kind :left-inserting)))

(defun org-line-after (point)
  (with-point ((next point))
    (line-start next)
    (when (line-offset next 1)
      (copy-point next :temporary))))

(defun org-add-fold (fold &optional (buffer (current-buffer)))
  (push fold (org-buffer-folds buffer))
  fold)

(defun org-fold-at-heading (heading &optional (buffer (point-buffer heading)))
  (find-if (lambda (fold)
             (and (not (org-fold-global-p fold))
                  (same-line-p heading (org-fold-owner fold))))
           (org-buffer-folds buffer)))

(defun org-remove-fold (fold &optional (buffer (current-buffer)))
  (setf (org-buffer-folds buffer)
        (delete fold (org-buffer-folds buffer)))
  (org-delete-fold fold))

(defun org-fold-subtree (heading)
  (alexandria:when-let* ((start (org-line-after heading))
                         (end (org-subtree-end-point heading))
                         (range (org-make-hidden-range start end)))
    (org-add-fold
     (make-org-fold :owner (copy-point heading :right-inserting)
                    :state :folded
                    :ranges (list range)
                    :ellipses (list (org-make-ellipsis heading))
                    :global-p nil))))

(defun org-fold-direct-children (heading)
  "Show direct child headings while hiding body and deeper descendants."
  (let* ((children (org-direct-child-headings heading))
         (subtree-end (org-subtree-end-point heading)))
    (unless children
      (return-from org-fold-direct-children nil))
    (let ((ranges '())
          (ellipses '()))
      (labels ((hide (owner start end)
                 (alexandria:when-let ((range (and start
                                                   (org-make-hidden-range start end))))
                   (push range ranges)
                   (push (org-make-ellipsis owner) ellipses))))
        (hide heading (org-line-after heading) (first children))
        (loop :for rest :on children
              :for child := (first rest)
              :for next := (or (second rest) subtree-end)
              :do (hide child (org-line-after child) next)))
      (org-add-fold
       (make-org-fold :owner (copy-point heading :right-inserting)
                      :state :children
                      :ranges (nreverse ranges)
                      :ellipses (nreverse ellipses)
                      :global-p nil)))))

(defun org-local-cycle-state (heading)
  (alexandria:when-let ((fold (org-fold-at-heading heading)))
    (org-fold-state fold)))

(defun org-cycle-heading (heading)
  (let* ((buffer (point-buffer heading))
         (existing (org-fold-at-heading heading buffer))
         (state (and existing (org-fold-state existing))))
    ;; A local cycle after a global overview starts from a predictable show-all
    ;; state, matching Org's context-sensitive local/global distinction.
    (when (org-global-cycle-state buffer)
      (org-clear-folds buffer)
      (setf existing nil state nil))
    (when existing
      (org-remove-fold existing buffer))
    (case state
      (:folded
       (if (org-fold-direct-children heading)
           :children
           :subtree))
      (:children :subtree)
      (otherwise
       (if (org-fold-subtree heading) :folded :empty)))))

(defun org-all-heading-points (&optional (buffer (current-buffer)))
  (let ((headings '()))
    (with-point ((point (buffer-start-point buffer)))
      (loop
        (when (org-heading-line-p point)
          (push (copy-point point :temporary) headings))
        (unless (line-offset point 1)
          (return))))
    (nreverse headings)))

(defun org-build-global-overview (buffer)
  (let ((ranges '())
        (ellipses '())
        (owner (copy-point (buffer-start-point buffer) :right-inserting)))
    (dolist (heading (org-all-heading-points buffer))
      (when (= 1 (org-heading-level-at heading))
        (alexandria:when-let* ((start (org-line-after heading))
                               (end (org-subtree-end-point heading))
                               (range (org-make-hidden-range start end)))
          (push range ranges)
          (push (org-make-ellipsis heading) ellipses))))
    (org-add-fold
     (make-org-fold :owner owner :state :overview
                    :ranges (nreverse ranges)
                    :ellipses (nreverse ellipses)
                    :global-p t)
     buffer)))

(defun org-build-global-contents (buffer)
  (let ((ranges '())
        (ellipses '())
        (owner (copy-point (buffer-start-point buffer) :right-inserting)))
    (dolist (heading (org-all-heading-points buffer))
      (alexandria:when-let* ((start (org-line-after heading))
                             (end (org-section-end-point heading))
                             (range (org-make-hidden-range start end)))
        (push range ranges)
        (push (org-make-ellipsis heading) ellipses)))
    (org-add-fold
     (make-org-fold :owner owner :state :contents
                    :ranges (nreverse ranges)
                    :ellipses (nreverse ellipses)
                    :global-p t)
     buffer)))

(defun org-cycle-global-visibility (&optional (buffer (current-buffer)))
  (let ((next (case (org-global-cycle-state buffer)
                (:overview :contents)
                (:contents :all)
                (otherwise :overview))))
    ;; Overview hides entire subtrees and contents hides section bodies.  Keep
    ;; point on the nearest heading that survives the new visibility state;
    ;; otherwise the generic post-command reveal guard would immediately undo
    ;; a Shift-Tab issued from body text.
    (when (eq buffer (current-buffer))
      (alexandria:when-let
          ((heading (org-current-heading-point (current-point))))
        (when (eq next :overview)
          (loop :for parent := (org-parent-heading-point heading)
                :while parent
                :do (setf heading parent)))
        (when (member next '(:overview :contents))
          (move-point (current-point) heading))))
    (org-clear-folds buffer)
    (case next
      (:overview (org-build-global-overview buffer))
      (:contents (org-build-global-contents buffer))
      (:all nil))
    (setf (org-global-cycle-state buffer)
          (unless (eq next :all) next))
    next))

(defun org-clear-folds-after-change (start end old-length)
  (declare (ignore end old-length))
  (unless *org-preserve-folds*
    (org-clear-folds (point-buffer start))))

(defun org-reveal-point-after-command ()
  "Reveal folded context when a non-visible-aware command lands inside it."
  (let ((buffer (current-buffer)))
    (cond
      ((and (mode-active-p buffer 'org-mode)
            (org-hidden-range-at-point (current-point)))
       (org-clear-folds buffer)
       (redraw-display))
      ((and (mode-active-p buffer 'org-mode)
            (fboundp 'llm-claude-hidden-block-at-point)
            (llm-claude-hidden-block-at-point (current-point)))
       (llm-claude-show-block
        (llm-claude-hidden-block-at-point (current-point)))
       (redraw-display))
      ((and (org-buffer-folds buffer)
            (not (mode-active-p buffer 'org-mode)))
       ;; Major-mode changes clear the hidden-line editor variable before this
       ;; hook runs; dispose the now-stale marker/ellipsis objects as well.
       (org-clear-folds buffer))
      ((and (fboundp 'llm-claude-buffer-blocks)
            (llm-claude-buffer-blocks buffer)
            (not (llm-conversation-buffer-p buffer)))
       (llm-claude-clear-blocks buffer)))))

(remove-hook *post-command-hook* 'org-reveal-point-after-command)
(add-hook *post-command-hook* 'org-reveal-point-after-command)
