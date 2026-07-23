;;;; Magit-compatible commit selection shared by history actions.

(in-package :lem-yath)

(defun legit-log-selected-commits (&optional (limit 64))
  "Return a valid commit region in display order, or NIL.

Both endpoints must be commit headings.  Detail rows between sibling headings
are ignored, matching Magit's section selection rather than treating the raw
text as revisions."
  (let* ((buffer (current-buffer))
         (visual-p
           (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                (lem-vi-mode/visual:visual-p buffer)))
         (marked-p (buffer-mark-p buffer)))
    (when (and visual-p (lem-vi-mode/visual:visual-block-p buffer))
      (return-from legit-log-selected-commits nil))
    (unless (or visual-p marked-p)
      (return-from legit-log-selected-commits nil))
    (let* ((bounds
             (if visual-p
                 (lem-vi-mode/visual:visual-range buffer)
                 (list (region-beginning buffer) (region-end buffer))))
           (start (point-min (first bounds) (second bounds)))
           (end (point-max (first bounds) (second bounds))))
      (when (point= start end)
        (return-from legit-log-selected-commits nil))
      (with-point ((first-line start)
                   (last-line end))
        (line-start first-line)
        ;; Lem and Vi ranges use an exclusive upper bound.
        (character-offset last-line -1)
        (line-start last-line)
        (unless (and (text-property-at first-line :commit-hash)
                     (text-property-at last-line :commit-hash))
          (return-from legit-log-selected-commits nil))
        (let ((commits '()))
          (loop
            (alexandria:when-let
                ((hash (text-property-at first-line :commit-hash)))
              (push hash commits)
              (when (> (length commits) limit)
                (editor-error "A commit region is limited to ~d commits."
                              limit)))
            (when (point>= first-line last-line)
              (return))
            (unless (line-offset first-line 1)
              (return)))
          (nreverse commits))))))
