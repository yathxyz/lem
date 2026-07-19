;;;; redisplay.lisp -- T1 entry: full redisplay compute (SPEC-PERF PF-4).
;;;;
;;;; The redisplay-compute cost of a 200x50 frame, measured through the RECORDING
;;;; FAKE-INTERFACE (frontends/fake-interface/fake-interface.lisp, the VK-12
;;;; frontend) so the whole display pipeline runs -- logical-line construction,
;;;; the certified wrap/clip layout kernel (verified/layout.lisp via
;;;; src/display/physical-line.lisp), object building and per-row rendering --
;;;; but NO terminal I/O: the recording `render-line' just records cells into a
;;;; grid.  `redraw-buffer' with force=t clears the display cache every call, so
;;;; each op is a full recompute (not a cache hit) and the number is the cost of
;;;; painting a frame from scratch.  This is the pattern
;;;; tests/pbt/screen-projection.lisp uses (make-window + redraw-buffer under a
;;;; recording interface).
;;;;
;;;; Three buffers (SPEC-PERF PF-4):
;;;;   redisplay/plain        -- 300 short text lines
;;;;   redisplay/long-line    -- one long single line, wrap off (horizontal clip)
;;;;   redisplay/many-overlay -- 300 lines with 1000 registered overlays
;;;;
;;;; DEVIATION (recorded in bench/README.md): the long-line buffer is 50 KB, not
;;;; the 200 KB of PF-4's edit/points long line.  HISTORICAL: when this entry was
;;;; sized, redisplaying a single text object of >= ~50 650 chars exhausted the
;;;; default control stack (the certified layout folds `k-sum'/`k-firstn'/
;;;; `k-clip-chars' recursed non-tail with depth = line length).  That crash is
;;;; FIXED (OPT-1 bug fix, bench/README.md ledger): the folds are mbe
;;;; tail-recursive :exec twins, and a 300k-char render is pinned crash-free by
;;;; tests/pbt/long-line-render.lisp.  The 50 KB size is KEPT for baseline
;;;; comparability -- the committed median/band were measured at this size, and
;;;; the entry's job (the single-huge-object clip path) does not need a longer
;;;; line; resizing it is a perf/rebaseline decision for OPT-2/OPT-6, not a
;;;; crash cap.
;;;;
;;;; The recording interface is installed as the process implementation once at
;;;; load time (the timed op runs outside any `with-recording-interface' dynamic
;;;; scope), and the three windows/buffers are built once; force redisplay is
;;;; idempotent (it neither edits the buffer nor changes overlay state), so every
;;;; section re-renders the same fixture.

(in-package :cl-user)

;;;; ------------------------------------------------------------------
;;;; Persistent recording interface + frame
;;;; ------------------------------------------------------------------

(ql:quickload :lem-fake-interface :silent t)

(defparameter *bench-redisplay-frame-width* 200)
(defparameter *bench-redisplay-frame-height* 50)

(setf lem-core::*implementation*
      (make-instance 'lem-fake-interface:recording-fake-interface))
(lem-core:setup-first-frame)

;;;; ------------------------------------------------------------------
;;;; Fixture buffers/windows (built once; force redraw is idempotent)
;;;; ------------------------------------------------------------------

(defun bench-redisplay-window (buffer)
  "A standalone (non-current) window of the fixed frame geometry over BUFFER."
  (lem-core::make-window buffer 0 0
                         *bench-redisplay-frame-width*
                         *bench-redisplay-frame-height*
                         nil))

(defun bench-redisplay-plain-buffer ()
  (let ((buffer (lem:make-buffer "bench-redisplay-plain" :temporary t :enable-undo-p nil)))
    (dotimes (i 300)
      (lem:insert-string (lem:buffer-point buffer)
                         (format nil "line ~D some ordinary words of text here~%" i)))
    buffer))

(defun bench-redisplay-long-line-buffer ()
  (let ((buffer (lem:make-buffer "bench-redisplay-longline" :temporary t :enable-undo-p nil)))
    (setf (lem:variable-value 'lem:line-wrap :buffer buffer) nil)
    (lem:insert-string (lem:buffer-point buffer)
                       (subseq (uiop:read-file-string (bench-ensure-corpus :long-line-200k))
                               0 50000))
    buffer))

(defun bench-redisplay-many-overlay-buffer ()
  (let ((buffer (lem:make-buffer "bench-redisplay-overlay" :temporary t :enable-undo-p nil)))
    (dotimes (i 300)
      (lem:insert-string (lem:buffer-point buffer)
                         (format nil "line ~D some ordinary words of text here~%" i)))
    (let ((attribute (lem:ensure-attribute 'lem:region t)))
      (dotimes (i 1000)
        (let ((start (lem:copy-point (lem:buffer-start-point buffer) :right-inserting)))
          (lem:move-to-line start (1+ (mod i 300)))
          (let ((end (lem:copy-point start :left-inserting)))
            (lem:line-end end)
            (lem:make-overlay start end attribute)))))
    buffer))

(defparameter *bench-redisplay-windows*
  (list :plain        (bench-redisplay-window (bench-redisplay-plain-buffer))
        :long-line    (bench-redisplay-window (bench-redisplay-long-line-buffer))
        :many-overlay (bench-redisplay-window (bench-redisplay-many-overlay-buffer)))
  "One pre-built window per fixture; force redisplay re-renders it identically.")

;;;; ------------------------------------------------------------------
;;;; Op / registration (window >= 10 ms per section)
;;;; ------------------------------------------------------------------

(defun bench-redisplay-op (window count)
  "Full (force) redisplay compute of WINDOW COUNT times."
  (let ((implementation (lem:implementation))
        (buffer (lem:window-buffer window)))
    (dotimes (i count)
      (lem-core::redraw-buffer implementation buffer window t))))

(defparameter *bench-redisplay-inner*
  '((:plain . 35) (:long-line . 4) (:many-overlay . 4))
  "Iteration counts: plain ~0.5-0.7 ms/op, long-line ~7 ms/op, overlay ~5 ms/op.")

(dolist (spec *bench-redisplay-inner*)
  (destructuring-bind (kind . inner) spec
    (let ((window (getf *bench-redisplay-windows* kind)))
      (register-bench-entry
       :name (format nil "redisplay/~(~A~)" kind)
       :unit "us/op"
       :inner inner
       :setup (lambda () window)
       :op #'bench-redisplay-op))))
