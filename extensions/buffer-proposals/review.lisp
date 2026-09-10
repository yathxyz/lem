(in-package :lem-buffer-proposals)

(defparameter *review-section-limit* (* 64 1024))
(defvar *proposal-review-keymap* (make-keymap :description "Buffer proposal"))

(define-major-mode proposal-review-mode nil
    (:name "Proposal" :keymap *proposal-review-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defun review-section (point title text)
  (insert-string point (format nil "~%--- ~a ---~%" title))
  (if text
      (progn
        (insert-string point (subseq text 0 (min (length text) *review-section-limit*)))
        (when (> (length text) *review-section-limit*)
          (insert-string point
                         (format nil "~%[Display truncated; the stored proposal remains complete.]"))))
      (insert-string point "[Unavailable or larger than the proposal limit.]"))
  (insert-character point #\Newline))

(defun visit-proposal-source (proposal)
  (require-editor-thread)
  (let ((source (%proposal-source proposal)))
    (unless (and source (not (deleted-buffer-p source)))
      (editor-error "The proposal source buffer is no longer open"))
    (setf (current-window) (pop-to-buffer source))
    (if (source-live-p proposal)
        (move-point (buffer-point source) (%proposal-start proposal))
        (progn (move-to-line (buffer-point source) (%proposal-line proposal))
               (move-to-column (buffer-point source) (%proposal-column proposal)))))
  proposal)

(defun proposal-review-buffer (proposal)
  "Render bounded original/current/proposed text and a navigable source link."
  (require-editor-thread)
  (let* ((old (%proposal-review-buffer proposal))
         (buffer (if (and old (not (deleted-buffer-p old))) old
                     (make-buffer (format nil "*Proposal ~a*" (%proposal-id proposal))
                                  :enable-undo-p nil)))
         (location (proposal-source-location proposal)))
    (setf (%proposal-review-buffer proposal) buffer
          (buffer-value buffer 'proposal) proposal
          (buffer-value buffer 'reviewed-generation) (%proposal-generation proposal)
          (buffer-read-only-p buffer) nil)
    (erase-buffer buffer)
    (let ((point (buffer-point buffer)))
      (insert-string point
                     (format nil "Proposal ~a~%State: ~(~a~)~%Captured revision: ~d   Candidate: ~d~%"
                             (%proposal-id proposal) (proposal-state proposal)
                             (%proposal-revision proposal) (%proposal-generation proposal)))
      (when (%proposal-conflict proposal)
        (insert-string point
                       (format nil "Conflict: ~(~a~). Current source has been preserved.~%"
                               (%proposal-conflict proposal))))
      (lem/button:insert-button
       point
       (format nil "Source: ~a:~d:~d"
               (or (getf location :filename) (getf location :buffer-name))
               (getf location :line) (getf location :column))
       (lambda () (visit-proposal-source proposal))
       :proposal-id (%proposal-id proposal) :source-location location)
      (insert-string point (format nil "~2%A accept   K reject   s source   g refresh   q close~%"))
      (review-section point "Captured original" (%proposal-original proposal))
      (review-section point "Current source" (proposal-current-text proposal))
      (review-section point "Proposed replacement" (%proposal-replacement proposal)))
    (change-buffer-mode buffer 'proposal-review-mode)
    (buffer-unmark buffer)
    (buffer-start (buffer-point buffer))
    (setf (buffer-read-only-p buffer) t)
    buffer))

(defun show-proposal (proposal)
  (setf (current-window) (pop-to-buffer (proposal-review-buffer proposal)))
  proposal)

(defun reviewed-proposal ()
  (or (buffer-value (current-buffer) 'proposal)
      (editor-error "This buffer does not review a proposal")))

(define-command proposal-review-accept () ()
  (let ((proposal (reviewed-proposal))
        (generation (buffer-value (current-buffer) 'reviewed-generation)))
    (handler-case
        (progn (apply-proposal proposal :expected-generation generation)
               (visit-proposal-source proposal))
      (proposal-conflict (condition)
        (show-proposal proposal)
        (editor-error "~a" condition)))))

(define-command proposal-review-reject () ()
  (let ((proposal (reviewed-proposal)))
    (reject-proposal proposal)
    (proposal-review-buffer proposal)
    (message "Proposal rejected; source text preserved")))

(define-command proposal-review-source () () (visit-proposal-source (reviewed-proposal)))
(define-command proposal-review-refresh () () (proposal-review-buffer (reviewed-proposal)))

(define-key *proposal-review-keymap* "A" 'proposal-review-accept)
(define-key *proposal-review-keymap* "K" 'proposal-review-reject)
(define-key *proposal-review-keymap* "s" 'proposal-review-source)
(define-key *proposal-review-keymap* "Return" 'proposal-review-source)
(define-key *proposal-review-keymap* "g" 'proposal-review-refresh)
(define-key *proposal-review-keymap* "q" 'quit-active-window)
