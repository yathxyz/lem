(in-package :lem-buffer-proposals)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(buffer-proposal-list buffer-proposal-open)))

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

(defvar *proposal-list-keymap* (make-keymap :description "Buffer proposals"))

(define-major-mode proposal-list-mode nil
    (:name "Proposals" :keymap *proposal-list-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defun proposal-list-label (text limit)
  "Keep untrusted source names on one bounded display line."
  (let ((label (subseq text 0 (min (length text) limit))))
    (map-into label (lambda (character) (if (graphic-char-p character) character #\?)) label)
    (if (> (length text) limit) (concatenate 'string label "...") label)))

(defun open-listed-proposal (id proposal)
  (require-editor-thread)
  (unless (eq proposal (find-proposal id))
    (editor-error "This proposal is no longer retained; refresh the proposal list"))
  (show-proposal proposal))

(defun render-proposal-list (buffer)
  (require-editor-thread)
  (let ((proposals (list-proposals)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((point (buffer-point buffer)))
        (insert-string point
                       (format nil "Buffer proposals (~d)~%Return review   g refresh   q close~2%ID  STATE  SOURCE (line:column)~%"
                               (length proposals)))
        (let ((first-row (position-at-point point)))
          (loop for proposal in proposals repeat 64
                do (let* ((selected proposal)
                          (id (proposal-id proposal))
                          (location (proposal-source-location proposal))
                          (source (proposal-source-buffer proposal)))
                     (with-point ((start point :right-inserting))
                       (lem/button:insert-button
                        point
                        (format nil "~a  ~(~a~)  ~a:~d:~d~a"
                                (proposal-list-label id 128) (proposal-state proposal)
                                (proposal-list-label (or (getf location :filename)
                                                         (getf location :buffer-name)) 256)
                                (getf location :line) (getf location :column)
                                (if (and source (not (deleted-buffer-p source))) "" " [source closed]"))
                        (lambda () (open-listed-proposal id selected)))
                       (insert-character point #\Newline)
                       ;; The row carries identity; its label is never parsed.
                       (put-text-property start point 'listed-proposal (cons id proposal)))))
          (cond ((null proposals) (insert-string point (format nil "No retained proposals.~%")))
                ((> (length proposals) 64)
                 (insert-string point (format nil "Only the first 64 proposals are displayed.~%"))))
          (move-to-position point first-row)))
      (buffer-mark-saved buffer)))
  buffer)

(define-command buffer-proposal-list () ()
  "List retained edit proposals without applying or saving their candidates."
  (require-editor-thread)
  (let ((buffer (or (find-if (lambda (buffer) (buffer-value buffer 'proposal-list)) (buffer-list))
                    (make-buffer (unique-buffer-name "*Buffer Proposals*") :enable-undo-p nil))))
    (setf (buffer-value buffer 'proposal-list) t)
    (change-buffer-mode buffer 'proposal-list-mode)
    (setf (current-window) (pop-to-buffer buffer))
    ;; Switching can restore an older cursor saved for this buffer. Render and
    ;; choose the first row after that restoration, including when reopening.
    (render-proposal-list buffer)
    buffer))

(define-command proposal-list-open-selected () ()
  (require-editor-thread)
  (with-point ((point (current-point)))
    (line-start point)
    (let ((row (text-property-at point 'listed-proposal)))
      (unless row (editor-error "There is no proposal on this line"))
      (open-listed-proposal (car row) (cdr row)))))

(define-command proposal-list-refresh () ()
  (require-editor-thread)
  (unless (buffer-value (current-buffer) 'proposal-list)
    (editor-error "This buffer does not list proposals"))
  (render-proposal-list (current-buffer)))

(defun prompt-for-proposal-id ()
  (require-editor-thread)
  (let ((ids (mapcar #'proposal-id (list-proposals))))
    (unless ids (editor-error "There are no retained proposals"))
    (prompt-for-string "Proposal ID: "
                       :completion-function (lambda (input) (completion-strings input ids)))))

(define-command buffer-proposal-open (id) ((prompt-for-proposal-id))
  "Open a retained proposal by its exact ID for human review."
  (require-editor-thread)
  (let ((proposal (find-proposal id)))
    (unless proposal (editor-error "Unknown or forgotten proposal ID: ~a" id))
    (show-proposal proposal)))

(define-key *proposal-list-keymap* "Return" 'proposal-list-open-selected)
(define-key *proposal-list-keymap* "g" 'proposal-list-refresh)
(define-key *proposal-list-keymap* "q" 'quit-active-window)
