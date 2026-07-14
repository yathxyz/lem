;;;; Project tools: compile (SPC c c) and duplicate-dwim (M-j).

(in-package :lem-yath)

;; Match `recentf-max-saved-items'.  This runs before command-line files are
;; opened.  Lem's dashboard can instantiate the lazy history before user init,
;; so update and, if necessary, trim that already-created object as well.
(setf lem-core/commands/file:*file-history-limit* 300)
(let* ((history (lem-core/commands/file:file-history))
       (limit lem-core/commands/file:*file-history-limit*)
       (data (lem/common/history::history-data history))
       (count (length data)))
  (setf (lem/common/history::history-limit history) limit)
  (when (> count limit)
    ;; History data is oldest to newest, so discard entries from the front.
    (replace data data
             :start1 0
             :end1 limit
             :start2 (- count limit)
             :end2 count)
    (setf (fill-pointer data) limit
          (lem/common/history::history-index history) limit)
    (lem/common/history:save-file history)))

(define-command lem-yath-compile () ()
  "Prompt for a shell command and stream its output into *compilation*.
Runs from the project root; the worker runs on a background thread."
  (let* ((buffer-dir (or (ignore-errors (buffer-directory (current-buffer)))
                         (user-homedir-pathname)))
         (dir (or (ignore-errors
                    (lem-yath-project-root-for-directory buffer-dir))
                  buffer-dir))
         (command (prompt-for-string (format nil "Compile [~a]: " dir)
                                     :history-symbol 'lem-yath-compile)))
    (when (plusp (length command))
      (stream-to-buffer (list "sh" "-c" command) "*compilation*"
                        :directory dir))))

(define-command lem-yath-kill-current-buffer () ()
  "Kill the current buffer, confirming first when it has unsaved changes."
  (kill-buffer (current-buffer)))

(defun duplicate-string (string count)
  (str:repeat count string))

(defun duplicate-current-line (count)
  "Duplicate the current line COUNT times while preserving point."
  (let ((text (concatenate 'string
                           (line-string (current-point))
                           (string #\Newline))))
    (with-point ((saved-point (current-point) :right-inserting)
                 (insertion (current-point) :left-inserting))
      (line-end insertion)
      (cond
        ((end-buffer-p insertion)
         ;; Emacs terminates both the source and its final copy at EOF.
         (unless (start-line-p insertion)
           (insert-character insertion #\Newline)))
        (t
         (character-offset insertion 1)))
      (insert-string insertion (duplicate-string text count))
      (move-point (current-point) saved-point))))

(defun duplicate-visual-block-current-line (buffer count)
  "Match duplicate-dwim under Evil Visual Block and retain its live corners."
  (let ((visual-state (lem-vi-mode/core:buffer-state buffer)))
    (with-point ((saved-mark (buffer-mark buffer) :right-inserting))
      (duplicate-current-line count)
      (setf (buffer-mark buffer) saved-mark
            (lem-vi-mode/core:buffer-state buffer) visual-state))))

(defun duplicate-region-bounds (buffer)
  "Return the active contiguous region in BUFFER, or no values."
  (cond
    ((and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
          (lem-vi-mode/visual:visual-p buffer))
     ;; Evil does not expose its Visual Block as Emacs rectangle-mark-mode or
     ;; as an ordinary active region.  The configured duplicate-dwim therefore
     ;; falls through to duplicate-line while leaving Visual Block active.
     (unless (lem-vi-mode/visual:visual-block-p buffer)
       (destructuring-bind (first second)
           (lem-vi-mode/visual:visual-range buffer)
         (values (point-min first second) (point-max first second)))))
    ((and (not (typep (current-global-mode) 'lem-vi-mode:vi-mode))
          (buffer-mark-p buffer))
     (let ((start (region-beginning buffer))
           (end (region-end buffer)))
       (unless (point= start end)
         (values start end))))))

(defun duplicate-active-region (start end count)
  "Duplicate START..END COUNT times and preserve point and mark orientation."
  (let* ((buffer (point-buffer start))
         (text (points-to-string start end))
         (visual-state
           (when (lem-vi-mode/visual:visual-p buffer)
             (lem-vi-mode/core:buffer-state buffer)))
         (unterminated-linewise-eof-p
           (and visual-state
                (or (lem-vi-mode/visual:visual-line-p buffer)
                    (lem-vi-mode/visual:visual-screen-line-p buffer))
                (end-buffer-p end)
                (or (zerop (length text))
                    (char/= (char text (1- (length text))) #\Newline))))
         (copies
           (if unterminated-linewise-eof-p
               (concatenate 'string
                            (string #\Newline)
                            (duplicate-string
                             (concatenate 'string text (string #\Newline))
                             count))
               (duplicate-string text count))))
    (with-point ((saved-point (buffer-point buffer) :right-inserting)
                 (saved-mark (buffer-mark buffer) :right-inserting)
                 (insertion end :left-inserting))
      (insert-string insertion copies)
      (move-point (buffer-point buffer) saved-point)
      ;; INSERT-STRING deactivates the mark.  SETF reactivates it, and restoring
      ;; the saved Vi state retains VISUAL versus V-LINE as well as orientation.
      (setf (buffer-mark buffer) saved-mark)
      (when visual-state
        (setf (lem-vi-mode/core:buffer-state buffer) visual-state)))))

(define-command lem-yath-duplicate-dwim (&optional (count 1)) (:universal)
  "Duplicate an active contiguous region or the current line COUNT times."
  (let ((count (or count 1))
        (buffer (current-buffer)))
    (when (plusp count)
      (if (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
               (lem-vi-mode/visual:visual-block-p buffer))
          (duplicate-visual-block-current-line buffer count)
          (multiple-value-bind (start end)
              (duplicate-region-bounds buffer)
            (if start
                (duplicate-active-region start end count)
                (duplicate-current-line count)))))))
