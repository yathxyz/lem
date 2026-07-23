(in-package :lem-yath)

(defstruct agenda-drag-line
  text
  properties)

(defun agenda-drag-source-row-p (point)
  "Return non-NIL when POINT is on a source-backed agenda row."
  (or (text-property-at point :agenda-file)
      (text-property-at point :agenda-diary-file)))

(defun agenda-drag-snapshot (point)
  "Snapshot POINT's complete line text and text-property map."
  (make-agenda-drag-line
   :text (line-string point)
   :properties
   (copy-tree (lem/buffer/line:line-plist (point-line point)))))

(defun agenda-drag-range (direction count)
  "Return the source rows crossed by dragging COUNT lines in DIRECTION.

The rows are returned in buffer order, or NIL when the move would cross a
header, decoration, or buffer boundary."
  (with-point ((scan (current-point)))
    (line-start scan)
    (unless (agenda-drag-source-row-p scan)
      (return-from agenda-drag-range nil))
    (let ((points (list (copy-point scan :temporary))))
      (dotimes (_ count)
        (unless (and (line-offset scan direction)
                     (progn
                       (line-start scan)
                       (agenda-drag-source-row-p scan)))
          (return-from agenda-drag-range nil))
        (push (copy-point scan :temporary) points))
      (if (minusp direction) points (nreverse points)))))

(defun agenda-drag-replace-range (points direction)
  "Rotate complete agenda lines at POINTS in DIRECTION."
  (let* ((snapshots (mapcar #'agenda-drag-snapshot points))
         (ordered
           (if (plusp direction)
               (append (rest snapshots) (list (first snapshots)))
               (cons (car (last snapshots)) (butlast snapshots))))
         (moved-offset (if (plusp direction) (1- (length points)) 0)))
    ;; Agenda owns this read-only display buffer.  Replacing complete line
    ;; objects through Lem's renderer fast path avoids normal editing hooks,
    ;; undo records, marker shifts, and modified state for this display-only
    ;; operation.
    (loop :for point :in points
          :for snapshot :in ordered
          :for line := (point-line point)
          :do (lem/buffer/line:set-line-string
               (agenda-drag-line-text snapshot) line)
              (setf (lem/buffer/line:line-plist line)
                    (copy-tree (agenda-drag-line-properties snapshot))))
    (move-point (current-point) (first points))
    (line-start (current-point))
    (line-offset (current-point) moved-offset)
    (redraw-display :force t)))

(defun agenda-drag-count (argument)
  (max 1
       (typecase argument
         (integer (abs argument))
         (null 1)
         (t 4))))

(defun agenda-drag-current-line (direction argument)
  "Drag the current agenda row in DIRECTION by ARGUMENT lines."
  (let* ((count (agenda-drag-count argument))
         (points (agenda-drag-range direction count)))
    (if points
        (agenda-drag-replace-range points direction)
        ;; This is the exact diagnostic used by pinned Org 9.8.5 for both
        ;; forward and backward failures.
        (message "Cannot move line forward"))))

(define-command lem-yath-agenda-drag-line-forward (argument) (:universal-nil)
  "Drag the current agenda row forward by ARGUMENT display lines."
  (agenda-drag-current-line 1 argument))

(define-command lem-yath-agenda-drag-line-backward (argument) (:universal-nil)
  "Drag the current agenda row backward by ARGUMENT display lines."
  (agenda-drag-current-line -1 argument))

(define-key *lem-yath-agenda-vi-keymap* "M-j"
  'lem-yath-agenda-drag-line-forward)
(define-key *lem-yath-agenda-vi-keymap* "M-k"
  'lem-yath-agenda-drag-line-backward)
