;;;; long-line.lisp -- T2 workload: single very-long line (PF-5).
;;;;
;;;; A buffer holding ONE long line (from the committed `long-line-200k' corpus):
;;;; cursor motion across it (character-offset sweeps, beginning/end-of-line),
;;;; net-zero edits at several positions, and both a wrap-OFF and a wrap-ON
;;;; render pass (toggling the `lem:line-wrap' buffer variable).  This is the
;;;; SPEC-PERF PF-5 long-line row.
;;;;
;;;; -------------------------------------------------------------------------
;;;; SIZE CAP (documented deviation -- see bench/README.md): the line is 16 KB
;;;; (16 000 chars), NOT the 80 KB the P2 task text names.  HISTORICAL: when
;;;; this workload was sized, rendering a single text object of >= 24 000 chars
;;;; through the real command path (`redraw-display', wrap ON, cursor at
;;;; end-of-line) EXHAUSTED THE DEFAULT CONTROL STACK -- the certified layout
;;;; folds (verified/layout.lisp `k-sum'/`k-firstn'/`k-clip-chars') recursed
;;;; non-tail with depth = line length; 23 000 rendered fine, 24 000 crashed.
;;;; That crash is FIXED (OPT-1 bug fix, bench/README.md ledger): the folds are
;;;; now mbe tail-recursive :exec twins, and a 300k-char single-line render is
;;;; pinned crash-free by tests/pbt/long-line-render.lisp.  The 16 KB size is
;;;; KEPT: the committed baseline median/band were measured at this size, so
;;;; growing the line is a perf/rebaseline decision (a longer line only scales
;;;; the same redisplay cost OPT-2/OPT-6 track), no longer a crash cap.
;;;; -------------------------------------------------------------------------
;;;;
;;;; Replayability: RUN restores the buffer (net-zero edits: insert a char then
;;;; delete it) and resets wrap + cursor at entry, so every execution renders an
;;;; identical frame sequence.

(in-package :cl-user)

(defparameter *bench-t2-long-line-length* 16000
  "Single-line length in characters (16 KB).  Kept at the size the committed
baseline was measured at; the former ~24 000-char control-stack cliff is fixed
(OPT-1) -- see the file header.")

(defparameter *bench-t2-long-line-sweep-step* 500
  "Cursor sweep stride, in characters (32 steps cover the 16 KB line).")

(defparameter *bench-t2-long-line-edit-positions*
  '(0 2000 4000 6000 8000 10000 12000 15000)
  "Column positions at which a net-zero edit (insert + delete) is performed.")

(defparameter *bench-t2-long-line-passes* 2
  "How many times the wrap-off + wrap-on session is repeated per execution.  The
long-line session is intrinsically fast (a 16 KB line renders in a few ms); a
single pass runs ~75 ms, small enough that one GC or scheduling hiccup is a >20%
swing and the median-of-three gate goes fragile.  Repeating the session (finer
sweep stride + more edit points already widen it) brings the window to ~450 ms,
where noise is proportionally small and the entry gates stably at the 20% band.
Still a faithful long-line session -- just a longer one.")

(defun bench-t2-long-line-setup ()
  "Build the single-long-line buffer once (undo enabled -- realistic editing)."
  (let ((buffer (lem:make-buffer "bench-t2-long-line" :temporary t :enable-undo-p t)))
    (lem:insert-string (lem:buffer-point buffer)
                       (subseq (uiop:read-file-string (bench-ensure-corpus :long-line-200k))
                               0 *bench-t2-long-line-length*))
    buffer))

(defun bench-t2-long-line-sweep (point)
  "Sweep POINT across the line in fixed strides, rendering at each stop.  Uses
`character-offset' (the motion primitive, which returns NIL at the buffer
boundary rather than signalling) so the sweep never overruns the line end."
  (lem:move-to-beginning-of-line)
  (bench-t2-render)
  (loop :repeat (ceiling *bench-t2-long-line-length* *bench-t2-long-line-sweep-step*)
        :do (lem:character-offset point *bench-t2-long-line-sweep-step*)
            (bench-t2-render))
  (lem:move-to-end-of-line)
  (bench-t2-render)
  (lem:move-to-beginning-of-line)
  (bench-t2-render))

(defun bench-t2-long-line-net-zero-edit (point column)
  "Insert a char at COLUMN then delete it (net-zero), rendering after each."
  (lem:move-to-beginning-of-line)
  (lem:character-offset point column)
  (lem:insert-character point #\z)
  (bench-t2-render)
  (lem:character-offset point -1)
  (lem:delete-character point 1)
  (bench-t2-render))

(defun bench-t2-long-line-run (buffer)
  (lem:switch-to-buffer buffer)
  (let ((point (lem:buffer-point buffer)))
    (dotimes (i *bench-t2-long-line-passes*)
      ;; Wrap-OFF pass: horizontal clip, cursor sweep, then net-zero edits.
      (setf (lem:variable-value 'lem:line-wrap :buffer buffer) nil)
      (bench-t2-long-line-sweep point)
      (dolist (column *bench-t2-long-line-edit-positions*)
        (bench-t2-long-line-net-zero-edit point column))
      ;; Wrap-ON pass: the line wraps into many physical rows.
      (setf (lem:variable-value 'lem:line-wrap :buffer buffer) t)
      (bench-t2-long-line-sweep point))))

(register-t2-workload
 :name "long-line"
 :setup #'bench-t2-long-line-setup
 :run #'bench-t2-long-line-run)
