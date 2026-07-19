;;;; GNU rectangle-mark-mode parity on top of Lem's text-buffer primitives.

(in-package :lem-yath)

(eval-when (:load-toplevel :execute)
  (when (fboundp 'rectangle-cleanup-for-reload)
    (rectangle-cleanup-for-reload)))

(defvar *rectangle-mode-keymap*
  (make-keymap :description "GNU rectangle mark mode"))
(defvar *killed-rectangle* nil)
(defvar *rectangle-string-history* nil)

(defstruct rectangle-state
  anchor
  anchor-column
  point-column
  overlays
  modified-tick
  preserve-column-p
  allow-edit-p)

(defparameter *rectangle-state-key* :lem-yath-rectangle-state)

(defun rectangle-state (&optional (buffer (current-buffer)))
  (buffer-value buffer *rectangle-state-key*))

(defun rectangle-mode-active-p (&optional (buffer (current-buffer)))
  (member 'lem-yath-rectangle-mark-mode (buffer-minor-modes buffer)))

(defun rectangle-delete-overlays (state)
  (dolist (overlay (rectangle-state-overlays state))
    (delete-overlay overlay))
  (setf (rectangle-state-overlays state) nil))

(defun rectangle-dispose-state (buffer)
  (alexandria:when-let ((state (rectangle-state buffer)))
    (rectangle-delete-overlays state)
    (alexandria:when-let ((anchor (rectangle-state-anchor state)))
      (delete-point anchor))
    (buffer-unbound buffer *rectangle-state-key*)))

(defun rectangle-existing-anchor (buffer)
  (cond
    ((and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
          (lem-vi-mode/visual:visual-p buffer))
     (buffer-mark buffer))
    ((buffer-mark-p buffer)
     (buffer-mark buffer))
    (t
     (buffer-point buffer))))

(defun rectangle-enable ()
  (let* ((buffer (current-buffer))
         (anchor-source (rectangle-existing-anchor buffer))
         (anchor (copy-point anchor-source :left-inserting))
         (state
           (make-rectangle-state
            :anchor anchor
            :anchor-column (point-column anchor-source)
            :point-column (point-column (buffer-point buffer))
            :modified-tick (buffer-modified-tick buffer))))
    (rectangle-dispose-state buffer)
    (setf (buffer-value buffer *rectangle-state-key*) state)
    ;; Convert an existing Evil selection into a rectangle without retaining
    ;; Evil's separate character/line/block overlay and operator semantics.
    (when (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
               (lem-vi-mode/visual:visual-p buffer))
      (lem-vi-mode/visual:vi-visual-end buffer))
    (rectangle-update-overlays buffer)
    (message "Mark set (rectangle mode)")))

(defun rectangle-disable ()
  (rectangle-dispose-state (current-buffer)))

(define-minor-mode lem-yath-rectangle-mark-mode
    (:name "Rectangle"
     :description "Treat point and the saved mark as rectangle corners."
     :keymap *rectangle-mode-keymap*
     :enable-hook 'rectangle-enable
     :disable-hook 'rectangle-disable))

(defun rectangle-end (&optional (buffer (current-buffer)))
  (when (rectangle-mode-active-p buffer)
    (with-current-buffer buffer
      (disable-minor-mode 'lem-yath-rectangle-mark-mode))))

(define-command lem-yath-rectangle-cancel () ()
  "End rectangle marking without changing the buffer."
  (rectangle-end))

(defun rectangle-cleanup-for-reload ()
  (remove-hook *post-command-hook* 'rectangle-post-command)
  (dolist (buffer (buffer-list))
    (when (rectangle-state buffer)
      (with-current-buffer buffer
        (when (rectangle-mode-active-p buffer)
          (disable-minor-mode 'lem-yath-rectangle-mark-mode))
        (rectangle-dispose-state buffer)))))

(defun rectangle-geometry (state &optional (point (current-point)))
  "Return top line, bottom line, left column, and right column for STATE."
  (let* ((anchor (rectangle-state-anchor state))
         (anchor-line (line-number-at-point anchor))
         (point-line (line-number-at-point point))
         (anchor-column (rectangle-state-anchor-column state))
         (point-column (rectangle-state-point-column state)))
    (values (min anchor-line point-line)
            (max anchor-line point-line)
            (min anchor-column point-column)
            (max anchor-column point-column))))

(defun rectangle-line-point (buffer line)
  (let ((point (copy-point (buffer-start-point buffer) :temporary)))
    (move-to-line point line)
    point))

(defun rectangle-update-overlays (&optional (buffer (current-buffer)))
  (alexandria:when-let ((state (rectangle-state buffer)))
    (rectangle-delete-overlays state)
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state (buffer-point buffer))
      (loop :for line :from top :to bottom
            :for base := (rectangle-line-point buffer line)
            :do (with-point ((start base) (end base))
                  (move-to-column start left)
                  (move-to-column end right)
                  (unless (point= start end)
                    (push (make-overlay start end 'region)
                          (rectangle-state-overlays state))))))))

(defun rectangle-post-command ()
  (let* ((buffer (current-buffer))
         (state (rectangle-state buffer)))
    (when (and state (rectangle-mode-active-p buffer))
      (let ((edited-p
              (/= (rectangle-state-modified-tick state)
                  (buffer-modified-tick buffer))))
        (cond
          ((and edited-p (not (rectangle-state-allow-edit-p state)))
           ;; Ordinary editing deactivates Emacs's mark and therefore ends
           ;; rectangle-mark-mode.  Preserve the edit itself.
           (rectangle-end buffer))
          (t
           (unless (rectangle-state-preserve-column-p state)
             (setf (rectangle-state-point-column state)
                   (point-column (buffer-point buffer))))
           (setf (rectangle-state-modified-tick state)
                 (buffer-modified-tick buffer)
                 (rectangle-state-preserve-column-p state) nil
                 (rectangle-state-allow-edit-p state) nil)
           (rectangle-update-overlays buffer)))))))

(remove-hook *post-command-hook* 'rectangle-post-command)
(add-hook *post-command-hook* 'rectangle-post-command)

(defun rectangle-tab-width (buffer)
  (variable-value 'tab-width :default buffer))

(defun rectangle-write-spaces (stream count)
  (when (plusp count)
    (write-string (make-string count :initial-element #\Space) stream)))

(defun rectangle-line-parts (string left right tab-width)
  "Split STRING at display columns LEFT and RIGHT, padding through RIGHT.

Characters spanning a boundary are represented by spaces, matching Emacs's
rectangle coercion at tab or wide-character edges."
  (let ((prefix (make-string-output-stream))
        (middle (make-string-output-stream))
        (suffix (make-string-output-stream))
        (column 0))
    (loop :for character :across string
          :for next :=
            (lem/common/character/string-width-utils:char-width
             character column :tab-size tab-width)
          :do
             (cond
               ((<= next left)
                (write-char character prefix))
               ((>= column right)
                (write-char character suffix))
               ((and (>= column left) (<= next right))
                (write-char character middle))
               (t
                (rectangle-write-spaces
                 prefix (max 0 (- (min next left) column)))
                (rectangle-write-spaces
                 middle
                 (max 0 (- (min next right) (max column left))))
                (rectangle-write-spaces
                 suffix (max 0 (- next (max column right))))))
             (setf column next))
    (when (< column left)
      (rectangle-write-spaces prefix (- left column))
      (setf column left))
    (when (< column right)
      (rectangle-write-spaces middle (- right column)))
    (values (get-output-stream-string prefix)
            (get-output-stream-string middle)
            (get-output-stream-string suffix)
            (lem/common/character/string-width-utils:string-width
             string :tab-size tab-width))))

(defun rectangle-rewrite-line (buffer line string)
  (let ((point (rectangle-line-point buffer line)))
    (with-point ((start point) (end point))
      (line-start start)
      (line-end end)
      (unless (string= string (points-to-string start end))
        (delete-between-points start end)
        (insert-string start string)))))

(defun rectangle-call-with-change-group (buffer function)
  "Call FUNCTION in a retained-undo transaction when BUFFER supports one."
  (let ((group
          (handler-case (buffer-prepare-change-group buffer)
            (error () nil))))
    (if (null group)
        (funcall function)
        (handler-case
            (multiple-value-prog1 (funcall function)
              (buffer-accept-change-group group))
          (error (condition)
            (when (buffer-change-group-active-p group)
              (handler-case (buffer-cancel-change-group group)
                (error ()
                  (when (buffer-change-group-active-p group)
                    (ignore-errors (buffer-abort-change-group group))))))
            (error condition))))))

(defun rectangle-transform-lines (state function)
  "Precompute, then apply FUNCTION to every line in STATE's rectangle."
  (let ((buffer (current-buffer))
        (tab-width (rectangle-tab-width (current-buffer)))
        changes)
    (when (buffer-read-only-p buffer)
      (error 'read-only-error))
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (loop :for line :from top :to bottom
            :for old := (line-string (rectangle-line-point buffer line))
            :for new := (funcall function old left right tab-width line)
            :do (when (find #\Newline new)
                  (editor-error "Rectangle replacement cannot contain a newline."))
                (push (list line new) changes))
      (rectangle-call-with-change-group
       buffer
       (lambda ()
         (dolist (change (nreverse changes))
           (destructuring-bind (line new) change
             (rectangle-rewrite-line buffer line new))))))
    (setf (rectangle-state-allow-edit-p state) t)
    state))

(defun rectangle-extract-lines (state)
  (let ((buffer (current-buffer))
        (tab-width (rectangle-tab-width (current-buffer)))
        result)
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (loop :for line :from top :to bottom
            :for string := (line-string (rectangle-line-point buffer line))
            :do (multiple-value-bind (prefix middle suffix width)
                    (rectangle-line-parts string left right tab-width)
                  (declare (ignore prefix suffix width))
                  (push middle result))))
    (nreverse result)))

(defun rectangle-move-point (line column)
  (move-to-line (current-point) line)
  (move-to-column (current-point) column))

(defun rectangle-delete-transform (fill-p)
  (lambda (string left right tab-width line)
    (declare (ignore line))
    (multiple-value-bind (prefix middle suffix width)
        (rectangle-line-parts string left right tab-width)
      (declare (ignore middle))
      (cond
        ((and (not fill-p) (< width left)) string)
        (t (concatenate 'string prefix suffix))))))

(defun rectangle-clear-transform (fill-p)
  (lambda (string left right tab-width line)
    (declare (ignore line))
    (multiple-value-bind (prefix middle suffix width)
        (rectangle-line-parts string left right tab-width)
      (declare (ignore middle))
      (cond
        ((and (not fill-p) (< width left)) string)
        ((and (not fill-p) (<= width right))
         prefix)
        (t
         (concatenate 'string prefix
                      (make-string (- right left) :initial-element #\Space)
                      suffix))))))

(defun rectangle-open-transform (fill-p)
  (lambda (string left right tab-width line)
    (declare (ignore line))
    (multiple-value-bind (prefix middle suffix width)
        (rectangle-line-parts string left left tab-width)
      (declare (ignore middle))
      (if (and (not fill-p) (<= width left))
          string
          (concatenate 'string prefix
                       (make-string (- right left) :initial-element #\Space)
                       suffix)))))

(defun rectangle-string-transform (replacement)
  (lambda (string left right tab-width line)
    (declare (ignore line))
    (multiple-value-bind (prefix middle suffix width)
        (rectangle-line-parts string left right tab-width)
      (declare (ignore middle width))
      (concatenate 'string prefix replacement suffix))))

(defun rectangle-insert-transform (column inserted)
  (lambda (string left right tab-width line)
    (declare (ignore left right line))
    (multiple-value-bind (prefix middle suffix width)
        (rectangle-line-parts string column column tab-width)
      (declare (ignore middle width))
      (concatenate 'string prefix inserted suffix))))

(defun rectangle-copy-text (lines)
  (format nil "~{~a~^~%~}" lines))

(define-command lem-yath-copy-rectangle-as-kill () ()
  "Copy the active rectangle for C-x r y without changing the ordinary kill ring."
  (let ((state (or (rectangle-state)
                   (editor-error "Rectangle mark mode is not active."))))
    (setf *killed-rectangle* (rectangle-extract-lines state))
    (rectangle-end)
    (message "Rectangle copied")))

(define-command lem-yath-kill-rectangle (&optional fill) (:universal-nil)
  "Delete the active rectangle and save it for C-x r y."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (point-line (line-number-at-point (current-point))))
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (declare (ignore top bottom right))
      (setf *killed-rectangle* (rectangle-extract-lines state))
      (rectangle-transform-lines state (rectangle-delete-transform fill))
      (rectangle-move-point point-line left)
      (rectangle-end))))

(define-command lem-yath-delete-rectangle (&optional fill) (:universal-nil)
  "Delete the active rectangle without saving it."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (point-line (line-number-at-point (current-point))))
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (declare (ignore top bottom right))
      (rectangle-transform-lines state (rectangle-delete-transform fill))
      (rectangle-move-point point-line left)
      (rectangle-end))))

(define-command lem-yath-clear-rectangle (&optional fill) (:universal-nil)
  "Replace the active rectangle with spaces."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (point-line (line-number-at-point (current-point))))
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (declare (ignore top bottom right))
      (rectangle-transform-lines state (rectangle-clear-transform fill))
      (rectangle-move-point point-line left)
      (rectangle-end))))

(define-command lem-yath-open-rectangle (&optional fill) (:universal-nil)
  "Insert the rectangle's width as spaces on each selected line."
  (let ((state (or (rectangle-state)
                   (editor-error "Rectangle mark mode is not active."))))
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (declare (ignore bottom right))
      (rectangle-transform-lines state (rectangle-open-transform fill))
      (rectangle-move-point top left)
      (rectangle-end))))

(define-command lem-yath-string-rectangle () ()
  "Replace each row of the active rectangle with one prompted string."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (replacement
           (prompt-for-string
            "String rectangle: "
            :initial-value (or (first *rectangle-string-history*) "")
            :history-symbol '*rectangle-string-history*)))
    (when (find #\Newline replacement)
      (editor-error "A rectangle string cannot contain a newline."))
    (pushnew replacement *rectangle-string-history* :test #'string=)
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (declare (ignore top right))
      (rectangle-transform-lines state
                                 (rectangle-string-transform replacement))
      (rectangle-move-point
       bottom
       (+ left
          (lem/common/character/string-width-utils:string-width
           replacement :tab-size (rectangle-tab-width (current-buffer)))))
      (rectangle-end))))

(defun rectangle-number-format (format-string number)
  "Render one safe Emacs-style integer FORMAT-STRING."
  (let ((output (make-string-output-stream))
        (index 0)
        (converted-p nil))
    (loop :while (< index (length format-string))
          :for character := (char format-string index)
          :do
             (if (char/= character #\%)
                 (progn (write-char character output) (incf index))
                 (progn
                   (incf index)
                   (when (>= index (length format-string))
                     (editor-error "Incomplete rectangle number format."))
                   (if (char= (char format-string index) #\%)
                       (progn (write-char #\% output) (incf index))
                       (let ((zero-p nil)
                             (width 0))
                         (when (char= (char format-string index) #\0)
                           (setf zero-p t)
                           (incf index))
                         (loop :while (and (< index (length format-string))
                                           (digit-char-p
                                            (char format-string index)))
                               :do (setf width
                                         (+ (* width 10)
                                            (digit-char-p
                                             (char format-string index))))
                                   (incf index))
                         (unless (and (< index (length format-string))
                                      (char= (char format-string index) #\d)
                                      (not converted-p))
                           (editor-error
                            "Rectangle number format needs exactly one %%d conversion."))
                         (incf index)
                         (setf converted-p t)
                         (let* ((rendered (princ-to-string number))
                                (negative-p (minusp number))
                                (digits (if negative-p
                                            (subseq rendered 1)
                                            rendered))
                                (padding (max 0 (- width (length rendered)))))
                           (if zero-p
                               (progn
                                 (when negative-p
                                   (write-char #\- output))
                                 (write-string
                                  (make-string padding :initial-element #\0)
                                  output)
                                 (write-string digits output))
                               (progn
                                 (rectangle-write-spaces output padding)
                                 (write-string rendered output)))))))))
    (unless converted-p
      (editor-error "Rectangle number format needs one %d conversion."))
    (get-output-stream-string output)))

(define-command lem-yath-rectangle-number-lines (&optional prefix) (:universal-nil)
  "Insert consecutive numbers at the active rectangle's left edge."
  (let ((state (or (rectangle-state)
                   (editor-error "Rectangle mark mode is not active."))))
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (declare (ignore right))
      (let* ((start (if prefix
                        (prompt-for-integer "Number to count from: "
                                            :initial-value 1)
                        1))
             (last (+ start (- bottom top)))
             (default-format
               (format nil "%~dd " (length (princ-to-string last))))
             (format-string
               (if prefix
                   (prompt-for-string "Format string: "
                                      :initial-value default-format)
                   default-format))
             (point-line (line-number-at-point (current-point)))
             (point-number (+ start (- point-line top)))
             (point-insert
               (rectangle-number-format format-string point-number)))
        ;; Validate every output before the first edit.
        (loop :for number :from start :to last
              :do (rectangle-number-format format-string number))
        (rectangle-transform-lines
         state
         (lambda (string ignored-left ignored-right tab-width line)
           (declare (ignore ignored-left ignored-right))
           (funcall (rectangle-insert-transform
                     left
                     (rectangle-number-format
                      format-string (+ start (- line top))))
                    string left left tab-width line)))
        (rectangle-move-point
         point-line
         (+ (rectangle-state-point-column state)
            (lem/common/character/string-width-utils:string-width
             point-insert :tab-size (rectangle-tab-width (current-buffer)))))
        (rectangle-end)))))

(defun rectangle-ensure-yank-lines (count)
  (let ((point (current-point)))
    (loop :repeat (1- count)
          :do
      (unless (line-offset point 1)
        (line-end point)
        (insert-character point #\Newline)))))

(define-command lem-yath-yank-rectangle () ()
  "Insert the last C-x r k/M-w rectangle with its upper-left corner at point."
  (unless *killed-rectangle*
    (editor-error "No killed rectangle is available."))
  (let* ((buffer (current-buffer))
         (top (line-number-at-point (current-point)))
         (column (point-column (current-point)))
         (tab-width (rectangle-tab-width buffer))
         (last (car (last *killed-rectangle*))))
    (when (buffer-read-only-p buffer)
      (error 'read-only-error))
    (rectangle-call-with-change-group
     buffer
     (lambda ()
       (rectangle-ensure-yank-lines (length *killed-rectangle*))
       (loop :for inserted :in *killed-rectangle*
             :for line :from top
             :do (let* ((old (line-string (rectangle-line-point buffer line)))
                        (new
                          (funcall
                           (rectangle-insert-transform column inserted)
                           old column column tab-width line)))
                   (rectangle-rewrite-line buffer line new)))))
    (rectangle-move-point
     (+ top (1- (length *killed-rectangle*)))
     (+ column
        (lem/common/character/string-width-utils:string-width
         last :tab-size tab-width)))))

(define-command lem-yath-rectangle-copy-region () ()
  "Copy the active rectangle as newline-separated ordinary kill-ring text."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (text (rectangle-copy-text (rectangle-extract-lines state))))
    (with-killring-context (:appending (continue-flag :kill))
      (copy-to-clipboard-with-killring text))
    (rectangle-end)))

(define-command lem-yath-rectangle-kill-region () ()
  "Kill the active rectangle as newline-separated ordinary kill-ring text."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (text (rectangle-copy-text (rectangle-extract-lines state)))
         (point-line (line-number-at-point (current-point))))
    (multiple-value-bind (top bottom left right)
        (rectangle-geometry state)
      (declare (ignore top bottom right))
      (rectangle-transform-lines state (rectangle-delete-transform nil))
      (with-killring-context (:appending (continue-flag :kill))
        (copy-to-clipboard-with-killring text))
      (rectangle-move-point point-line left)
      (rectangle-end))))

(defun rectangle-vertical-move (delta)
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (point (current-point))
         (column (rectangle-state-point-column state)))
    (unless (line-offset point delta)
      (if (plusp delta)
          (error 'end-of-buffer :point point)
          (error 'beginning-of-buffer :point point)))
    (move-to-column point column)
    (setf (rectangle-state-preserve-column-p state) t)
    (rectangle-update-overlays)))

(define-command lem-yath-rectangle-next-line (&optional (count 1)) (:universal)
  "Move down COUNT logical lines while retaining a virtual rectangle column."
  (rectangle-vertical-move count))

(define-command lem-yath-rectangle-previous-line (&optional (count 1)) (:universal)
  "Move up COUNT logical lines while retaining a virtual rectangle column."
  (rectangle-vertical-move (- count)))

(defun rectangle-horizontal-move (delta)
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (column (+ (rectangle-state-point-column state) delta)))
    (when (minusp column)
      (error 'beginning-of-line :point (current-point)))
    (setf (rectangle-state-point-column state) column
          (rectangle-state-preserve-column-p state) t)
    (move-to-column (current-point) column)
    (rectangle-update-overlays)))

(define-command lem-yath-rectangle-forward-char (&optional (count 1)) (:universal)
  "Move right COUNT rectangle columns, including beyond end of line."
  (rectangle-horizontal-move count))

(define-command lem-yath-rectangle-backward-char (&optional (count 1)) (:universal)
  "Move left COUNT rectangle columns."
  (rectangle-horizontal-move (- count)))

(define-command lem-yath-rectangle-exchange-point-and-mark () ()
  "Exchange or rotate through the active rectangle's four corners."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (anchor (rectangle-state-anchor state))
         (point (current-point))
         (point-line (line-number-at-point point))
         (anchor-line (line-number-at-point anchor))
         (point-column (rectangle-state-point-column state))
         (anchor-column (rectangle-state-anchor-column state))
         (repeat-p (continue-flag :rectangle-exchange)))
    (move-to-line anchor point-line)
    (move-to-column anchor (if repeat-p anchor-column point-column))
    (move-to-line point anchor-line)
    (move-to-column point (if repeat-p point-column anchor-column))
    (setf (rectangle-state-anchor-column state)
          (if repeat-p anchor-column point-column)
          (rectangle-state-point-column state)
          (if repeat-p point-column anchor-column)
          (rectangle-state-preserve-column-p state) t)
    (rectangle-update-overlays)))

(defun rectangle-duplicate-right (count)
  "Duplicate the active rectangle COUNT times to its right and retain it."
  (let* ((state (or (rectangle-state)
                    (editor-error "Rectangle mark mode is not active.")))
         (count (or count 1)))
    (when (plusp count)
      (let ((anchor-line (line-number-at-point
                          (rectangle-state-anchor state)))
            (point-line (line-number-at-point (current-point)))
            (anchor-column (rectangle-state-anchor-column state))
            (point-column (rectangle-state-point-column state))
            (rows (rectangle-extract-lines state)))
        (multiple-value-bind (top bottom left right)
            (rectangle-geometry state)
          (declare (ignore bottom left))
          (rectangle-transform-lines
           state
           (lambda (string ignored-left ignored-right tab-width line)
             (declare (ignore ignored-left ignored-right))
             (funcall
              (rectangle-insert-transform
               right (duplicate-string (nth (- line top) rows) count))
              string right right tab-width line)))
          (move-to-line (rectangle-state-anchor state) anchor-line)
          (move-to-column (rectangle-state-anchor state) anchor-column)
          (rectangle-move-point point-line point-column)
          (setf (rectangle-state-anchor-column state) anchor-column
                (rectangle-state-point-column state) point-column
                (rectangle-state-preserve-column-p state) t
                (rectangle-state-allow-edit-p state) t)
          (rectangle-update-overlays))))))

;;; Active Emacs bindings.  C-o/C-t deliberately remain under Evil's normal
;;; maps, exactly as in the audited editor; their rectangle operations remain
;;; available from C-x r o/t.
(define-key *global-keymap* "C-x Space" 'lem-yath-rectangle-mark-mode)
(define-key *global-keymap* "C-x r c" 'lem-yath-clear-rectangle)
(define-key *global-keymap* "C-x r k" 'lem-yath-kill-rectangle)
(define-key *global-keymap* "C-x r d" 'lem-yath-delete-rectangle)
(define-key *global-keymap* "C-x r y" 'lem-yath-yank-rectangle)
(define-key *global-keymap* "C-x r o" 'lem-yath-open-rectangle)
(define-key *global-keymap* "C-x r t" 'lem-yath-string-rectangle)
(define-key *global-keymap* "C-x r N" 'lem-yath-rectangle-number-lines)
(define-key *global-keymap* "C-x r M-w" 'lem-yath-copy-rectangle-as-kill)

(define-key *rectangle-mode-keymap* 'copy-region
  'lem-yath-rectangle-copy-region)
(define-key *rectangle-mode-keymap* 'kill-region
  'lem-yath-rectangle-kill-region)
(define-key *rectangle-mode-keymap* 'exchange-point-mark
  'lem-yath-rectangle-exchange-point-and-mark)
(define-key *rectangle-mode-keymap* 'next-line
  'lem-yath-rectangle-next-line)
(define-key *rectangle-mode-keymap* 'previous-line
  'lem-yath-rectangle-previous-line)
(define-key *rectangle-mode-keymap* 'forward-char
  'lem-yath-rectangle-forward-char)
(define-key *rectangle-mode-keymap* 'backward-char
  'lem-yath-rectangle-backward-char)
(define-key *rectangle-mode-keymap* "C-x C-x"
  'lem-yath-rectangle-exchange-point-and-mark)
(define-key *rectangle-mode-keymap* "C-n" 'lem-yath-rectangle-next-line)
(define-key *rectangle-mode-keymap* "Down" 'lem-yath-rectangle-next-line)
(define-key *rectangle-mode-keymap* "C-p" 'lem-yath-rectangle-previous-line)
(define-key *rectangle-mode-keymap* "Up" 'lem-yath-rectangle-previous-line)
(define-key *rectangle-mode-keymap* "Right" 'lem-yath-rectangle-forward-char)
(define-key *rectangle-mode-keymap* "Left" 'lem-yath-rectangle-backward-char)
(define-key *rectangle-mode-keymap* "C-g" 'lem-yath-rectangle-cancel)
