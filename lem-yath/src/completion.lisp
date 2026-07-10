;;;; Completion: vertico + orderless + marginalia -> Lem's prompt, upgraded.
;;;; Lem's stock prompt completion is prefix/hyphen matching; we wrap the
;;;; default completion functions with orderless-style space-separated
;;;; substring matching. M-x already shows keybindings per candidate
;;;; (marginalia-style) via the default item collector, which we reuse by
;;;; asking it for the full set and re-filtering.

(in-package :lem-yath)

(defun completion-label (item)
  (handler-case (lem/completion-mode:completion-item-label item)
    (error () (princ-to-string item))))

(defvar *default-command-completion* *prompt-command-completion-function*)
(defvar *default-buffer-completion* *prompt-buffer-completion-function*)

(setf *prompt-command-completion-function*
      (lambda (input &rest args)
        (orderless-filter input
                          (apply *default-command-completion* "" args)
                          :key #'completion-label)))

(setf *prompt-buffer-completion-function*
      (lambda (input &rest args)
        (orderless-filter input
                          (apply *default-buffer-completion* "" args)
                          :key #'completion-label)))

;; vertico-like: show the candidate list immediately, not only on TAB.
(setf *automatic-tab-completion* t)

;; Lem binds Space in the completion popup to insert-space-and-cancel,
;; which kills multi-token orderless input ("roam fi" closes the popup at
;; the space). In a prompt, Space must insert and re-filter instead; in
;; ordinary buffers the stock cancel behavior is right (a space ends the
;; symbol being completed).
(define-command lem-yath-completion-space () ()
  "Insert a space; in a prompt, keep filtering the completion popup."
  (insert-character (current-point) #\Space)
  (let ((prompt (lem/prompt-window:current-prompt-window)))
    (if (and prompt (eq (current-buffer) (window-buffer prompt)))
        (lem/completion-mode:completion-refresh)
        (lem/completion-mode:completion-end))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "Space" 'lem-yath-completion-space)
