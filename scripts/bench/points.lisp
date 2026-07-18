;;;; points.lisp -- T1 entry: marker relocation (SPEC-PERF PF-4).
;;;;
;;;; Measures the per-edit marker-relocation cost as a function of how many
;;;; registered points sit in the affected region: 10, 100, and 1000 points on
;;;; the edited line.  A single-character insert/delete relocates exactly the
;;;; registered points of the target line (src/buffer/internal/buffer-insert.lisp
;;;; `kernel-shift-markers'), so registering N points on that line exercises the
;;;; certified per-point map (`shift-point-insert' / `-delete') N times per edit
;;;; -- the O(N) relocation an overlay-heavy buffer pays.
;;;;
;;;; The op is net-zero (insert "x", then delete it), so the buffer and all N
;;;; points return to their starting state every op; each timed section rebuilds
;;;; the fixture, so repetitions are reproducible.  This entry runs in the
;;;; production `:release' engine mode.

(in-package :cl-user)

(defparameter *bench-points-line* 1000
  "The line the points are registered on and the edit happens at.")

(defparameter *bench-points-line-width* 60)

(defun bench-points-line-start ()
  "Absolute buffer position of the start of the edit line."
  (+ 1 (* *bench-points-line* (1+ *bench-points-line-width*))))

(defun bench-points-make-buffer ()
  "A 2000-line x 60-char buffer (undo inhibited during construction)."
  (let* ((buffer (lem:make-buffer (symbol-name (gensym "bench-points-"))
                                  :temporary t :enable-undo-p t))
         (point (lem:buffer-point buffer)))
    (lem/buffer/internal::with-inhibit-undo ()
      (dotimes (i 2000)
        (lem/buffer/internal::insert-string/point
         point (make-string *bench-points-line-width* :initial-element #\a))
        (lem/buffer/internal::insert-string/point point (string #\newline))))
    buffer))

(defun bench-points-setup (n)
  "Return a setup thunk: build the buffer, register N points spread across the
edit line, and position the edit point at the line's midpoint."
  (lambda ()
    (let* ((buffer (bench-points-make-buffer))
           (point (lem:buffer-point buffer))
           (line-start (bench-points-line-start)))
      ;; N points spread across the edit line (charpos cycles 0..width; several
      ;; may share a charpos, which is legitimate -- many markers can coexist).
      (dotimes (i n)
        (let ((p (lem:copy-point (lem:buffer-point buffer)
                                 (if (evenp i) :left-inserting :right-inserting))))
          (lem:move-to-position p (+ line-start (mod i (1+ *bench-points-line-width*))))))
      (lem:move-to-position point (+ line-start (floor *bench-points-line-width* 2)))
      point)))

(defun bench-points-op (point count)
  "Net-zero edit relocating the region's registered points twice per op."
  (dotimes (i count)
    (lem/buffer/internal::insert-string/point point "x")
    (lem:character-offset point -1)
    (lem/buffer/internal::delete-char/point point 1)))

;;;; Iteration counts (window >= 10 ms; sized so relocation dominates).
(defparameter *bench-points-inner*
  '((10 . 2500) (100 . 1200) (1000 . 250)))

(dolist (spec *bench-points-inner*)
  (destructuring-bind (n . inner) spec
    (register-bench-entry
     :name (format nil "points/~D" n)
     :unit "us/op"
     :inner inner
     :setup (bench-points-setup n)
     :op #'bench-points-op)))
