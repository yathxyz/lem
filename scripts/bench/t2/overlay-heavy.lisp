;;;; overlay-heavy.lisp -- T2 workload: editing with thousands of overlays (PF-5).
;;;;
;;;; A buffer carrying 2000 registered overlays (a mix of single-line and
;;;; multi-line spans, via the frozen `lem:make-overlay' API) subjected to 500
;;;; net-zero edits at positions interleaved with the overlay boundaries, with a
;;;; full redisplay every 10 edits -- the SPEC-PERF PF-5 overlay-heavy row.
;;;;
;;;; Every non-temporary overlay registers two points in the buffer, so this
;;;; stresses (a) marker relocation: each edit shifts every overlay point that
;;;; lies after the edit position (2000 overlays = 4000 registered points), and
;;;; (b) overlay-aware redisplay: each forced frame must gather and paint the
;;;; overlays intersecting the visible window region.  The edits sweep the first
;;;; N lines where the overlays live and the view follows the cursor, so every
;;;; frame has real overlays to render.
;;;;
;;;; Replayability: the 2000 overlays are built ONCE in SETUP and persist across
;;;; reps (never deleted).  RUN's edits are net-zero (insert a char, delete it),
;;;; so the text -- and therefore every overlay point, which returns to its
;;;; original position -- is invariant; RUN resets the cursor at entry.  Every
;;;; execution thus renders the identical frame sequence.  The buffer is the
;;;; pinned `lisp-500k' corpus (~13 000 lines), plenty for a 2000-line overlay
;;;; band with headroom.

(in-package :cl-user)

(defparameter *bench-t2-overlay-count* 2000
  "Registered overlays (SPEC-PERF PF-5: thousands).")

(defparameter *bench-t2-overlay-band-lines* 2000
  "The overlays (and the edit sweep) span the first N lines of the buffer.")

(defparameter *bench-t2-overlay-edit-count* 500
  "Net-zero edits performed (SPEC-PERF PF-5: 500).")

(defparameter *bench-t2-overlay-redisplay-every* 10
  "Force a full redisplay once per this many edits (SPEC-PERF PF-5).")

(defun bench-t2-overlay-make-one (buffer line multi-line-p)
  "Register one overlay on BUFFER: a single-line span (a few columns on LINE) or
a multi-line span (LINE .. LINE+2), using the frozen `lem:make-overlay'."
  (lem:with-point ((start (lem:buffer-point buffer))
                   (end (lem:buffer-point buffer)))
    (lem:move-to-line start line)
    (lem:line-start start)
    (lem:character-offset start 2)               ; a couple of columns in
    (cond
      (multi-line-p
       (lem:move-to-line end (min (+ line 2) *bench-t2-overlay-band-lines*))
       (lem:line-end end))
      (t
       (lem:move-to-line end line)
       (lem:line-start end)
       (lem:character-offset end 8)))
    ;; Guard against a degenerate (end <= start) span on a short line.
    (when (lem:point< start end)
      (lem:make-overlay start end 'lem:region))))

(defun bench-t2-overlay-heavy-setup ()
  "Build the lisp-500k buffer and register 2000 overlays deterministically
across the first band of lines (even index -> single-line, odd -> multi-line)."
  (let ((buffer (lem:make-buffer "bench-t2-overlay-heavy" :temporary t :enable-undo-p nil)))
    (lem:insert-string (lem:buffer-point buffer)
                       (uiop:read-file-string (bench-ensure-corpus :lisp-500k)))
    (let ((overlays '()))
      (dotimes (i *bench-t2-overlay-count*)
        ;; Spread overlays evenly through the band; interleave the two kinds.
        (let ((line (1+ (mod (* i 7) (1- *bench-t2-overlay-band-lines*))))
              (ov nil))
          (setf ov (bench-t2-overlay-make-one buffer line (oddp i)))
          (when ov (push ov overlays))))
      (list buffer (nreverse overlays)))))

(defun bench-t2-overlay-heavy-run (state)
  (destructuring-bind (buffer overlays) state
    (declare (ignore overlays))
    (lem:switch-to-buffer buffer)
    (lem:move-to-beginning-of-buffer)
    (bench-t2-render)
    (let ((point (lem:buffer-point buffer)))
      (dotimes (i *bench-t2-overlay-edit-count*)
        ;; Move to an edit position interleaved with the overlay boundaries:
        ;; the same stride the overlays were laid on, offset so the edits land
        ;; near overlay starts rather than exactly on them.
        (let ((line (1+ (mod (+ 3 (* i 7)) (1- *bench-t2-overlay-band-lines*)))))
          (lem:move-to-line point line)
          (lem:line-start point)
          (lem:character-offset point 4))
        ;; Net-zero edit: insert then delete the same character.
        (lem:insert-character point #\z)
        (lem:character-offset point -1)
        (lem:delete-character point 1)
        ;; Full redisplay every N edits, view following the cursor.
        (when (zerop (mod (1+ i) *bench-t2-overlay-redisplay-every*))
          (lem:window-see (lem:current-window))
          (bench-t2-render))))))

(register-t2-workload
 :name "overlay-heavy"
 :setup #'bench-t2-overlay-heavy-setup
 :run #'bench-t2-overlay-heavy-run)
