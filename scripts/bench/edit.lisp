;;;; edit.lisp -- T1 entry: edit-latency (SPEC-PERF PF-4; was scripts/bench-edit.lisp).
;;;;
;;;; Edit throughput through the buffer mutation primitives, undo enabled and 8
;;;; extra registered points present (marker relocation active), on two corpora:
;;;;   normal   -- a 2000-line x 60-char buffer, edited at line 1000
;;;;   longline -- the PI-1 200 KB single-line corpus, edited at char 100 000
;;;; and two ops:
;;;;   insert-delete -- insert a char, then delete it (a keystroke round-trip)
;;;;   newline       -- insert a newline (split), then delete it (join)
;;;;
;;;; Both ops are NET-ZERO: the buffer, its line lengths, and every registered
;;;; point return to their starting state after each op.  This is a deliberate
;;;; departure from the historical one-directional insert / delete scenarios
;;;; (recorded in bench/README.md): a one-directional op grows or shrinks the
;;;; edited line, so its per-op cost depends on the iteration count -- and under
;;;; :paranoid the certified wf-buffer re-walks the whole (growing) line every
;;;; edit, making the entry O(n^2) in the iteration count and impossible to size
;;;; for a stable window.  The net-zero round-trip keeps the line length fixed,
;;;; so the number is iteration-count-independent, gate-stable, and still covers
;;;; insert, delete, split, and join cost.
;;;;
;;;; Each scenario runs in both edit-engine modes: `:release' (the production
;;;; fast path) and `:paranoid' (the certified per-edit wf-buffer assertion,
;;;; bound dynamically per timed section).  The paranoid/release ratio is the
;;;; tracked "paranoid tax" (SPEC-VK soak decision datum), recorded in
;;;; bench/README.md.  Each timed section rebuilds a fresh fixture via `:setup'.

(in-package :cl-user)

;;;; ------------------------------------------------------------------
;;;; Fixtures
;;;; ------------------------------------------------------------------

(defun bench-edit-fresh-buffer ()
  (lem:make-buffer (symbol-name (gensym "bench-edit-")) :temporary t :enable-undo-p t))

(defun bench-make-normal-buffer ()
  "A 2000-line x 60-char buffer (undo recording inhibited during construction)."
  (let* ((buffer (bench-edit-fresh-buffer))
         (point (lem:buffer-point buffer)))
    (lem/buffer/internal::with-inhibit-undo ()
      (dotimes (i 2000)
        (lem/buffer/internal::insert-string/point point (make-string 60 :initial-element #\a))
        (lem/buffer/internal::insert-string/point point (string #\newline))))
    buffer))

(defun bench-make-longline-buffer ()
  "A single-line buffer holding the 200 KB long-line corpus."
  (let* ((buffer (bench-edit-fresh-buffer))
         (point (lem:buffer-point buffer))
         (content (uiop:read-file-string (bench-ensure-corpus :long-line-200k))))
    (lem/buffer/internal::with-inhibit-undo ()
      (lem/buffer/internal::insert-string/point point content))
    buffer))

(defun bench-spread-points (buffer positions)
  "Register a left/right-inserting point at each of POSITIONS so marker
relocation runs on every edit (identical to the VK-4 bench's 8 extra points)."
  (loop :for pos :in positions
        :for kind := :left-inserting :then (if (eq kind :left-inserting)
                                               :right-inserting
                                               :left-inserting)
        :do (let ((p (lem:copy-point (lem:buffer-point buffer) kind)))
              (lem:move-to-position p pos))))

(defparameter *bench-normal-mid* (+ 1 (* 1000 61) 30)
  "Absolute buffer position of line 1000, column 30 (the normal-buffer edit
point).")

(defparameter *bench-normal-extras*
  (list 200 5000 30000 60000
        (+ *bench-normal-mid* 100) (+ *bench-normal-mid* 2000)
        100000 120000))

(defparameter *bench-longline-mid* 100000)

(defparameter *bench-longline-extras*
  (list 100 50000 99000 100500 150000 199000 20000 180000))

;;;; ------------------------------------------------------------------
;;;; Ops (net-zero; mode bound dynamically around the whole timed section)
;;;; ------------------------------------------------------------------

(defun bench-edit-op (kind mode)
  (let ((insert (ecase kind
                  (:insert-delete "x")
                  (:newline (string #\newline)))))
    (lambda (point count)
      (let ((lem/buffer/internal::*edit-engine-mode* mode))
        (dotimes (i count)
          (lem/buffer/internal::insert-string/point point insert)
          (lem:character-offset point (- (length insert)))
          (lem/buffer/internal::delete-char/point point (length insert)))))))

(defun bench-edit-setup (buffer-maker mid extras)
  "Return a per-section setup thunk: build the buffer, register the extra
points, and position the edit point at MID."
  (lambda ()
    (let* ((buffer (funcall buffer-maker))
           (point (lem:buffer-point buffer)))
      (bench-spread-points buffer extras)
      (lem:move-to-position point mid)
      point)))

;;;; ------------------------------------------------------------------
;;;; Iteration counts (window >= 10 ms; per-op cost is inner-independent)
;;;; ------------------------------------------------------------------

(defun bench-edit-inner (buffer kind mode)
  (ecase mode
    (:release
     (ecase buffer
       (:normal   (ecase kind (:insert-delete 2500) (:newline 2500)))
       (:longline (ecase kind (:insert-delete 30)   (:newline 30)))))
    (:paranoid
     (ecase buffer
       (:normal   (ecase kind (:insert-delete 1500) (:newline 2000)))
       (:longline (ecase kind (:insert-delete 2)    (:newline 2)))))))

;;;; ------------------------------------------------------------------
;;;; Registration
;;;; ------------------------------------------------------------------

(dolist (mode '(:release :paranoid))
  (dolist (buf (list (list :normal   #'bench-make-normal-buffer
                           *bench-normal-mid* *bench-normal-extras*)
                     (list :longline #'bench-make-longline-buffer
                           *bench-longline-mid* *bench-longline-extras*)))
    (destructuring-bind (buf-key buffer-maker mid extras) buf
      (dolist (kind '((:insert-delete . "insert-delete")
                      (:newline . "newline")))
        (register-bench-entry
         :name (format nil "edit/~(~A~)/~A/~(~A~)" buf-key (cdr kind) mode)
         :unit "us/op"
         :inner (bench-edit-inner buf-key (car kind) mode)
         :setup (bench-edit-setup buffer-maker mid extras)
         :op (bench-edit-op (car kind) mode))))))
