;;;; Evil-Org agenda source preview without leaving the agenda window.

(in-package :lem-yath)

(defvar *agenda-preview-window* nil)
(defvar *agenda-preview-repeat-buffer* nil)

(defun agenda-preview-window-live-p ()
  (and *agenda-preview-window*
       (not (deleted-window-p *agenda-preview-window*))))

(defun agenda-preview-row-source (&optional (point (current-point)))
  "Return POINT's file, line, and expected heading source identity."
  (values
   (or (text-property-at point :agenda-file)
       (text-property-at point :agenda-diary-file)
       (text-property-at point :agenda-clock-report-file))
   (or (text-property-at point :agenda-line)
       (text-property-at point :agenda-clock-report-line))
   (text-property-at point :agenda-heading)))

(defun agenda-preview-validated-source-point (file line expected-heading)
  "Open FILE and return its validated source BUFFER and POINT at LINE."
  (unless (and file (integerp line) (plusp line))
    (error "No linked entry at point"))
  (let ((buffer (find-file-buffer file)))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (unless (or (= line 1) (line-offset point (1- line)))
          (error "Agenda source line no longer exists; refresh the agenda"))
        (when (and expected-heading
                   (not (string= expected-heading (line-string point))))
          (error "Agenda source changed; refresh before previewing"))
        (values buffer (copy-point point :temporary))))))

(defun agenda-preview-target-window (agenda-window)
  "Return the ordinary window used to show a source from AGENDA-WINDOW."
  (when (one-window-p)
    (split-window-sensibly agenda-window))
  (get-next-window agenda-window))

(defun agenda-preview-show-source (&key recenter remember)
  "Show the current source without selecting it.

RECENTER centers its row.  REMEMBER makes it the Space/Backspace scroll
target, matching `org-agenda-show-window'."
  (multiple-value-bind (file line expected-heading)
      (agenda-preview-row-source)
    (multiple-value-bind (buffer point)
        (agenda-preview-validated-source-point file line expected-heading)
      (let* ((agenda-window (current-window))
             (target-window (agenda-preview-target-window agenda-window)))
        (unwind-protect
             (progn
               (switch-to-window target-window)
               (switch-to-buffer buffer)
               (move-point (current-point) point)
               (when (and (mode-active-p buffer 'org-mode)
                          (org-hidden-range-at-point (current-point)))
                 (org-clear-folds buffer))
               (if recenter
                   (window-recenter target-window)
                   (window-see target-window nil))
               (when remember
                 (setf *agenda-preview-window* target-window)))
          (switch-to-window agenda-window))
        target-window))))

(defun agenda-preview-page-size (window)
  (max 1 (- (window-height window) 2)))

(defun agenda-preview-scroll (direction)
  "Scroll the remembered source window one page in DIRECTION."
  (when (agenda-preview-window-live-p)
    (let ((amount (agenda-preview-page-size *agenda-preview-window*)))
      (if (minusp direction)
          (lem-core/commands/window:scroll-up
           amount *agenda-preview-window*)
          (lem-core/commands/window:scroll-down
           amount *agenda-preview-window*))
      (redraw-display :force t)
      t)))

(define-command lem-yath-agenda-show-and-scroll-up () ()
  "Show the current source; repeated calls scroll its window forward."
  (let ((agenda-buffer (current-buffer)))
    (handler-case
        (if (and (eq agenda-buffer *agenda-preview-repeat-buffer*)
                 (agenda-preview-window-live-p))
            (agenda-preview-scroll 1)
            (progn
              (agenda-preview-show-source :remember t)
              (setf *agenda-preview-repeat-buffer* agenda-buffer)))
      (error (condition)
        (setf *agenda-preview-repeat-buffer* nil)
        (message "Agenda preview failed: ~a" condition)))))

(define-command lem-yath-agenda-show-scroll-down () ()
  "Scroll the source window remembered by agenda Space backward."
  (agenda-preview-scroll -1))

(define-command lem-yath-agenda-recenter-source () ()
  "Display and center the current agenda source without changing focus."
  (handler-case
      (agenda-preview-show-source :recenter t)
    (error (condition)
      (message "Agenda preview failed: ~a" condition))))

(defun agenda-preview-post-command ()
  "Forget repeated Space state after any other command."
  (unless (eq (and (this-command) (command-name (this-command)))
              'lem-yath-agenda-show-and-scroll-up)
    (setf *agenda-preview-repeat-buffer* nil)))

(defun agenda-preview-cleanup (buffer)
  (when (eq buffer *agenda-preview-repeat-buffer*)
    (setf *agenda-preview-repeat-buffer* nil))
  (unless (agenda-preview-window-live-p)
    (setf *agenda-preview-window* nil)))

(remove-hook *post-command-hook* 'agenda-preview-post-command)
(add-hook *post-command-hook* 'agenda-preview-post-command)
(pushnew 'agenda-preview-cleanup *agenda-buffer-cleanup-functions*)

(define-key *lem-yath-agenda-vi-keymap* "Space"
  'lem-yath-agenda-show-and-scroll-up)
(define-key *lem-yath-agenda-vi-keymap* "Backspace"
  'lem-yath-agenda-show-scroll-down)
(define-key *lem-yath-agenda-vi-keymap* "Delete"
  'lem-yath-agenda-show-scroll-down)
(define-key *lem-yath-agenda-vi-keymap* "M-Return"
  'lem-yath-agenda-recenter-source)
