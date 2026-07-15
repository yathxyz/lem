;;;; Recenter and pulse accepted Consult/imenu-style destinations.
;;;;
;;;; The Emacs profile configures Pulsar with a 30 ms delay and four fading
;;;; iterations.  It does not enable Pulsar's broad command or window-change
;;;; hooks, so callers opt in only after committing a real destination.

(in-package :lem-yath)

(define-attribute lem-yath-jump-pulse-1-attribute
  (t :background "red"))
(define-attribute lem-yath-jump-pulse-2-attribute
  (t :background "#b90019"))
(define-attribute lem-yath-jump-pulse-3-attribute
  (t :background "#71001a"))
(define-attribute lem-yath-jump-pulse-4-attribute
  (t :background "#350717"))

(defparameter *jump-feedback-delay-ms* 30
  "Delay between configured Pulsar-style fade increments.")

(defparameter *jump-feedback-stage-attributes*
  '(lem-yath-jump-pulse-1-attribute
    lem-yath-jump-pulse-2-attribute
    lem-yath-jump-pulse-3-attribute
    lem-yath-jump-pulse-4-attribute)
  "The four configured Pulsar-style fade stages, brightest first.")

(defstruct jump-feedback-pulse
  overlay
  timer
  (stage 0 :type fixnum)
  (active-p t :type boolean))

(defvar *jump-feedback-current-pulse* nil)

(defun jump-feedback-cancel (&optional (pulse *jump-feedback-current-pulse*))
  "Stop PULSE and remove its display-only line overlay.

It is safe to call this after a buffer was killed or from a stale queued timer
notification."
  (when pulse
    (setf (jump-feedback-pulse-active-p pulse) nil)
    (alexandria:when-let ((timer (jump-feedback-pulse-timer pulse)))
      (setf (jump-feedback-pulse-timer pulse) nil)
      (ignore-errors (stop-timer timer)))
    (alexandria:when-let ((overlay (jump-feedback-pulse-overlay pulse)))
      (setf (jump-feedback-pulse-overlay pulse) nil)
      (ignore-errors (delete-overlay overlay)))
    (when (eq pulse *jump-feedback-current-pulse*)
      (setf *jump-feedback-current-pulse* nil))
    (ignore-errors (redraw-display)))
  nil)

(defun jump-feedback-step (pulse)
  "Advance one fade stage for PULSE, ignoring superseded callbacks."
  (if (and (jump-feedback-pulse-active-p pulse)
           (eq pulse *jump-feedback-current-pulse*))
      (let* ((stage (incf (jump-feedback-pulse-stage pulse)))
             (attribute (nth stage *jump-feedback-stage-attributes*))
             (overlay (jump-feedback-pulse-overlay pulse)))
        (if (and attribute overlay)
            (handler-case
                (progn
                  (set-overlay-attribute (ensure-attribute attribute)
                                         overlay)
                  (redraw-display))
              (error () (jump-feedback-cancel pulse)))
            (jump-feedback-cancel pulse)))
      (jump-feedback-cancel pulse)))

(defun jump-feedback-pulse-line (&optional (point (current-point)))
  "Pulse the complete line at POINT using the configured four-stage fade."
  (jump-feedback-cancel)
  (let* ((overlay
           (make-line-overlay
            point
            (ensure-attribute (first *jump-feedback-stage-attributes*))))
         (pulse (make-jump-feedback-pulse :overlay overlay)))
    (setf *jump-feedback-current-pulse* pulse
          (jump-feedback-pulse-timer pulse)
          (start-timer
           (make-timer (lambda () (jump-feedback-step pulse))
                       :name "lem-yath jump feedback"
                       :handle-function
                       (lambda (condition)
                         (declare (ignore condition))
                         (jump-feedback-cancel pulse)))
           *jump-feedback-delay-ms*
           :repeat t))
    (redraw-display)
    pulse))

(defun jump-feedback-after-jump
    (&optional (point (current-point)) (window (current-window)))
  "Recenter WINDOW and briefly pulse the accepted destination at POINT."
  (window-recenter window)
  (jump-feedback-pulse-line point))

;; Loading the module again must not leave an overlay or timer owned by the
;; previous definition alive.
(jump-feedback-cancel)
