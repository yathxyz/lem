;;;; undo-storm.lisp -- T2 workload: 5k edits, full undo, full redo (PF-5).
;;;;
;;;; A single buffer subjected to 5000 mixed edits (insert / delete / newline,
;;;; deterministic seed, moving positions) with undo enabled, then a FULL undo
;;;; back to the starting text and a FULL redo forward again -- the SPEC-PERF
;;;; PF-5 undo-storm row.  This stresses the edit-history record path, the
;;;; inverse-edit apply path, and (crucially) `recompute-undo-position-offset',
;;;; which walks the whole edit history per undo/redo group.
;;;;
;;;; CORRECTNESS CANARY (SPEC-PERF PF-5: "Assert final buffer text equals
;;;; post-edit text ... outside the timed window").  The assert is done ONCE in
;;;; SETUP (which is untimed): SETUP runs the exact edit sequence, records the
;;;; post-edit text, does a full undo (-> base) then full redo (-> post-edit),
;;;; and asserts the redo result is byte-identical to the recorded post-edit
;;;; text -- proving undo/redo round-trips losslessly.  Keeping the assert in
;;;; SETUP (not RUN) is what puts it outside every timed window while still
;;;; re-checking on every bench invocation.  A mismatch aborts the run loudly.
;;;;
;;;; Replayability: SETUP seeds the buffer with undo DISABLED (so the seed is
;;;; never on the undo stack) then enables undo; "start" = the seeded base.  RUN
;;;; is net-zero: 5k edits -> full undo (-> base) -> full redo (-> post-edit) ->
;;;; a final full undo (-> base).  It therefore ends exactly where it began
;;;; (base), so all three timed reps + the warm-up replay from an identical
;;;; state.  The trailing undo is the only addition beyond the spec's
;;;; "edits, undo, redo" session, and exists solely for replay hygiene.

(in-package :cl-user)

(defparameter *bench-t2-undo-edit-count* 5000
  "Mixed edits performed before the full undo/redo (SPEC-PERF PF-5: 5k).")

(defparameter *bench-t2-undo-seed* #x2D57012340000ABC
  "Fixed SplitMix64 seed for the deterministic edit sequence (re-seeded at the
start of every edit run so setup and every timed rep produce identical edits).")

(defparameter *bench-t2-undo-base-text*
  (with-output-to-string (s)
    (dotimes (i 40)
      (format s "seed line ~D: the quick brown fox jumps over the lazy dog~%" i)))
  "Deterministic starting text (\"start\") -- enough material that delete and
newline edits at moving positions are always in-bounds.")

(defun bench-t2-undo-buffer-text (buffer)
  (lem:points-to-string (lem:buffer-start-point buffer)
                        (lem:buffer-end-point buffer)))

(defun bench-t2-undo-perform-edits (buffer)
  "Perform the deterministic 5k mixed-edit sequence on BUFFER (which must be at
the base text), one undo group per edit (a `buffer-undo-boundary' after each),
so a later full undo/redo replays exactly 5k groups."
  (let ((point (lem:buffer-point buffer))
        (rng (bench-make-rng *bench-t2-undo-seed*)))
    (dotimes (i *bench-t2-undo-edit-count*)
      (let* ((size (lem:position-at-point (lem:buffer-end-point buffer)))
             (pos (1+ (bench-rng-below rng (max 1 (1- size))))))
        (lem:move-to-position point pos)
        (case (bench-rng-below rng 3)
          (0 (lem:insert-character point #\x))
          (1 (unless (lem:end-buffer-p point)
               (lem:delete-character point 1)))
          (2 (lem:insert-character point #\Newline))))
      (lem:buffer-undo-boundary buffer))))

(defun bench-t2-undo-drain (fn point)
  "Apply FN (`buffer-undo' or `buffer-redo') until it reports no more work."
  (loop :while (funcall fn point)))

(defun bench-t2-undo-storm-setup ()
  "Seed the buffer (undo disabled), enable undo, and run the correctness canary
once (untimed): edits -> record post-edit -> full undo -> full redo -> assert
equal -> full undo back to base.  Returns the buffer at the base text."
  (let* ((buffer (lem:make-buffer "bench-t2-undo-storm" :temporary t :enable-undo-p nil))
         (point (lem:buffer-point buffer)))
    (lem:insert-string point *bench-t2-undo-base-text*)
    (lem:buffer-enable-undo buffer)
    (let ((base (bench-t2-undo-buffer-text buffer)))
      (bench-t2-undo-perform-edits buffer)
      (let ((post (bench-t2-undo-buffer-text buffer)))
        (bench-t2-undo-drain #'lem:buffer-undo point)
        (assert (string= base (bench-t2-undo-buffer-text buffer)) ()
                "undo-storm canary: full undo did not restore the base text")
        (bench-t2-undo-drain #'lem:buffer-redo point)
        (assert (string= post (bench-t2-undo-buffer-text buffer)) ()
                "undo-storm canary: full redo did not reproduce the post-edit text")
        (bench-t2-undo-drain #'lem:buffer-undo point)))
    buffer))

(defun bench-t2-undo-storm-run (buffer)
  (lem:switch-to-buffer buffer)
  (let ((point (lem:buffer-point buffer)))
    (bench-t2-render)
    ;; 5k mixed edits.
    (bench-t2-undo-perform-edits buffer)
    (bench-t2-render)
    ;; Full undo to start.
    (bench-t2-undo-drain #'lem:buffer-undo point)
    (bench-t2-render)
    ;; Full redo.
    (bench-t2-undo-drain #'lem:buffer-redo point)
    (bench-t2-render)
    ;; Restore to base for replay (trailing undo -- see the file header).
    (bench-t2-undo-drain #'lem:buffer-undo point)))

(register-t2-workload
 :name "undo-storm"
 :setup #'bench-t2-undo-storm-setup
 :run #'bench-t2-undo-storm-run)
