;;;; GNU Org flagged-agenda note feedback.

(in-package :lem-yath)

(defun agenda-flagged-note-at-point
    (&optional (point (current-point)) (buffer (current-buffer)))
  "Return POINT's THEFLAGGINGNOTE value in the explicit flagged view."
  (let ((state (agenda-view-state buffer)))
    (when (eq (agenda-view-state-command state) :flagged)
      (cdr (assoc "THEFLAGGINGNOTE"
                  (text-property-at point :agenda-properties)
                  :test #'string=)))))

(defun agenda-flagged-note-display (buffer point)
  "Echo POINT's flagging note after source-row movement in BUFFER."
  (alexandria:when-let ((note (agenda-flagged-note-at-point point buffer)))
    (message "FLAGGING-NOTE ([?] for more info): ~a"
             (ppcre:regex-replace-all "\\\\n" note "//"))))

(pushnew 'agenda-flagged-note-display *agenda-item-motion-functions*)
